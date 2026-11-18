;;; harness-workspace.el --- Persistent workspace chat: threads, episodes and one timeline -*- lexical-binding: t; -*-

;;; Commentary:

;; Workspace mode is one chat over many topics.  A workspace is a named,
;; long-lived assistant with a root directory and a list of threads.  A
;; thread is a topic; each live stretch of a thread is an *episode*, an
;; ordinary harness session of kind `workspace'.  A new episode starts
;; from a fresh *brief* built from the thread and from the workspace's
;; Logseq knowledge graph (harness-workspace-knowledge.el), not from a
;; compacted transcript.  The user sees the episodes and the
;; harness events between them as one timeline.
;;
;; This module is the state layer.  It knows nothing about a buffer.  It
;; persists:
;;
;;   workspaces/ID.json           the workspace, its threads and settings
;;   workspaces/ID.timeline.jsonl one line per message, divider or event
;;
;; A thread's live episode is a session; its transcript is the session's,
;; so the old episode stays whole, searchable and openable after the
;; workspace has moved on.  The module subscribes to the sessions' node
;; and turn events to grow the timeline and the thread summary.
;;
;; Routing is deliberately conservative and local.  An explicit thread,
;; an explicit `/new', a thread title in the message, or the last thread
;; when nothing says otherwise; a topic marker makes a new thread, and a
;; thread is a small document the message is ranked against by the words
;; each holds, so a thread that holds none of a message never keeps it.
;; No model is asked to place a message.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-store)
(require 'harness-session)
(require 'harness-agent)
(require 'harness-small)
(require 'harness-project)
(require 'harness-tools)

(defvar harness-state-directory)

(defgroup harness-workspace nil
  "Persistent workspace chats."
  :group 'harness
  :prefix "harness-workspace-")

(defcustom harness-workspace-directory (expand-file-name "~/workspace/")
  "Default root directory of a new workspace."
  :type 'directory
  :group 'harness-workspace)

(defcustom harness-workspace-model nil
  "Model a workspace episode runs on, or nil for the configured model."
  :type '(choice (const :tag "Configured model" nil)
                 (string :tag "Model" :names model))
  :group 'harness-workspace)

(defcustom harness-workspace-thinking nil
  "Thinking level a workspace episode runs at, or nil for the session default."
  :type '(choice (const :tag "Default" nil) (string :tag "Level"))
  :group 'harness-workspace)

(defcustom harness-workspace-permission-mode 'auto
  "Permission mode of a workspace episode."
  :type '(choice (const ask) (const accept-edits) (const auto) (const yolo))
  :group 'harness-workspace)

(defcustom harness-workspace-non-interactive nil
  "Whether a workspace episode starts non-interactive."
  :type 'boolean
  :group 'harness-workspace)

(defcustom harness-workspace-brief-chars 16000
  "Most characters a workspace brief may hold."
  :type 'integer
  :group 'harness-workspace)

(defcustom harness-workspace-brief-recent 8
  "Messages of the thread a brief quotes."
  :type 'integer
  :group 'harness-workspace)

(defcustom harness-workspace-recall 8
  "Knowledge blocks a brief recalls from the Logseq graph."
  :type 'integer
  :group 'harness-workspace)

(defcustom harness-workspace-episode-context 0.6
  "Share of an episode's context window at which a new episode starts.
The old transcript is kept; the new episode starts from a fresh brief."
  :type 'number
  :group 'harness-workspace)

(defcustom harness-workspace-notification-cutoff 2.0
  "Seconds a reply waits for its neighbours before one notification goes.
A workspace whose several threads finish near each other notifies once
at the cutoff, naming every thread whose reply is ready; a thread that
finishes later notifies on its own."
  :type 'number
  :group 'harness-workspace)

(defcustom harness-workspace-episode-turns 120
  "Turns after which a workspace episode is continued in a new one."
  :type 'integer
  :group 'harness-workspace)

(defcustom harness-workspace-thread-idle-hours 8
  "Hours after which a message starts a new episode in the same thread."
  :type 'number
  :group 'harness-workspace)

(defcustom harness-workspace-max-message-chars 50000
  "Most characters of one message the timeline keeps."
  :type 'integer
  :group 'harness-workspace)

(defcustom harness-workspace-notify t
  "Whether the workspace sends a notification when a reply is ready.
The harness's notification module must be loaded."
  :type 'boolean
  :group 'harness-workspace)

(defconst harness-workspace--directory "workspaces"
  "Directory under the state directory that holds workspace records.")

(defvar harness-workspace--table (make-hash-table :test 'equal)
  "Workspace id -> workspace plist.")

(defvar harness-workspace--loaded nil
  "Non-nil once the workspace records were read from the store.")

(defvar harness-workspace--subscribed nil
  "Non-nil once the module subscribed to the harness's events.")

(defvar harness-workspace--handling (make-hash-table :test 'equal)
  "Session ids whose node event is already being handled.
A node-added event can arrive while the timeline is written; the
subscription must not recurse into itself.")

;;;; Small helpers

(defun harness-workspace--id (prefix)
  "Return a fresh id starting with PREFIX."
  (concat prefix (harness-short-id 10)))

(defun harness-workspace--file (id &optional suffix)
  "Return the state file of workspace ID with SUFFIX."
  (concat harness-workspace--directory "/" id (or suffix ".json")))

(defun harness-workspace--timeline-file (id)
  "Return the timeline file of workspace ID."
  (harness-workspace--file id ".timeline.jsonl"))

(defun harness-workspace--now ()
  "Return the current time as a float."
  (float-time))

(defun harness-workspace--symbol (value)
  "Return VALUE as a symbol, a JSON string included."
  (cond ((symbolp value) value)
        ((stringp value) (intern value))
        (t value)))

(defun harness-workspace--get (id)
  "Return workspace ID or signal."
  (harness-workspace--load)
  (or (gethash id harness-workspace--table)
      (signal 'harness-error (list (format "No workspace %s" id)))))

(defun harness-workspace--index (list id)
  "Return the position of ID in LIST, or nil."
  (cl-position id list :test #'equal))

(defun harness-workspace--thread (workspace id)
  "Return the thread ID of WORKSPACE, or nil."
  (cl-find id (plist-get workspace :threads)
           :key (lambda (thread) (plist-get thread :id)) :test #'equal))

(defun harness-workspace--thread-index (workspace id)
  "Return the position of thread ID in WORKSPACE, or nil."
  (cl-position id (plist-get workspace :threads)
               :key (lambda (thread) (plist-get thread :id)) :test #'equal))

(defun harness-workspace--put-thread (workspace thread)
  "Put THREAD into WORKSPACE, replacing the thread with the same id."
  (let* ((threads (plist-get workspace :threads))
         (pos (harness-workspace--thread-index workspace (plist-get thread :id))))
    (setf (plist-get workspace :threads)
          (if pos
              (progn (setcar (nthcdr pos threads) thread) threads)
            (append threads (list thread))))))

(defun harness-workspace--session-ext (session-id)
  "Return the workspace ext of SESSION-ID, or nil."
  (when (and (stringp session-id)
             (harness-method-exists-p 'session/exists-p)
             (harness-call 'session/exists-p session-id))
    (plist-get (harness-call 'session/get session-id) :ext)))

(defun harness-workspace--episode-p (session-id)
  "Return SESSION-ID's workspace ext when it is an episode, else nil."
  (let ((ext (harness-workspace--session-ext session-id)))
    (and (plist-get ext :workspace) ext)))

(defun harness-workspace--session-running-p (session-id)
  "Non-nil when SESSION-ID has a turn in flight."
  (and (harness-method-exists-p 'agent/running)
       (harness-call 'agent/running session-id)))

(defun harness-workspace--session-record (session-id)
  "Return the session plist of SESSION-ID, or nil when it is gone."
  (when (and (stringp session-id)
             (harness-method-exists-p 'session/exists-p)
             (harness-call 'session/exists-p session-id))
    (harness-call 'session/get session-id)))

(defun harness-workspace--session-state (session-id)
  "Return the state of SESSION-ID as the workspace shows it."
  (if-let* ((session (harness-workspace--session-record session-id)))
      (let ((status (plist-get session :status)))
        (cond ((eq status 'running) "live")
              ((eq status 'blocked) "waiting")
              ((eq status 'idle) "live")
              (t "parked")))
    "parked"))

(defun harness-workspace--episode-status (thread session)
  "Return the state of THREAD's live episode, SESSION being its record.
That is \"running\", \"blocked\", \"idle\", \"failed\", \"stopped\",
\"inactive\" or, with no live episode, \"parked\".  A turn that ended
with an error stays failed, and one the user cancelled stopped, until
the next turn starts."
  (cond
   ((null session) "parked")
   (t (pcase (plist-get session :status)
        ('running "running")
        ('blocked "blocked")
        ('inactive "inactive")
        ('idle (pcase (plist-get thread :last-stop)
                 ("error" "failed")
                 ("cancelled" "stopped")
                 (_ "idle")))
        (_ "idle")))))

;;;; Persistence

(defun harness-workspace--load ()
  "Read every workspace record once."
  (unless harness-workspace--loaded
    (setq harness-workspace--loaded t)
    (clrhash harness-workspace--table)
    (dolist (name (harness-call 'store/list harness-workspace--directory "\\.json\\'"))
      (let ((workspace (harness-call 'store/load name)))
        (when (and (listp workspace) (plist-get workspace :id))
          (puthash (plist-get workspace :id) workspace harness-workspace--table))))))

(defun harness-workspace--save (workspace)
  "Persist WORKSPACE and announce it."
  (let ((workspace (plist-put (copy-sequence workspace) :updated (harness-workspace--now))))
    (puthash (plist-get workspace :id) workspace harness-workspace--table)
    (harness-call 'store/save (harness-workspace--file (plist-get workspace :id)) workspace)
    (harness-emit 'workspace/changed (plist-get workspace :id)
                  (harness-workspace--view workspace))
    workspace))

(defun harness-workspace--settings (workspace)
  "Return the settings WORKSPACE's episodes start with, as a plist.
That is its own model, thinking level, permission mode and interactive
switch, else the workspace options (`harness-workspace-model' and the
ones beside it), else the harness's configured defaults at its root.
It is what a parked thread reads, and what a client names before the
first message starts an episode."
  (let* ((root (or (plist-get workspace :root) default-directory))
         (defaults
          (list :model (or (plist-get workspace :model)
                           harness-workspace-model
                           (harness-session--config 'harness-model root))
                :thinking (or (plist-get workspace :thinking)
                              harness-workspace-thinking
                              (harness-session--config 'harness-thinking root))
                :permission-mode (harness-workspace--symbol
                                  (or (plist-get workspace :permission-mode)
                                      harness-workspace-permission-mode))
                :non-interactive (harness-json-true-p
                                  (if (plist-member workspace :non-interactive)
                                      (plist-get workspace :non-interactive)
                                    (or harness-workspace-non-interactive
                                        (harness-session--config
                                         'harness-non-interactive root)))))))
    defaults))

(defun harness-workspace--thread-setting (thread key defaults)
  "Return what THREAD uses for setting KEY.
DEFAULTS are the workspace's own (`harness-workspace--settings').  A
live episode's value is its own even when nil, which means the model's
or the harness's own default."
  (let ((live (plist-get thread :live)))
    (if-let* ((session (and live (harness-workspace--session-record live))))
        (plist-get session key)
      (plist-get defaults key))))

(defun harness-workspace--thread-activity (thread)
  "Return what THREAD's live episode does now, as `agent/activity' does.
Nil when it has no live episode, the episode is not running, or the
harness has no agent activity to report."
  (when-let* ((live (plist-get thread :live))
              (session (harness-workspace--session-record live))
              ((eq (plist-get session :status) 'running))
              ((harness-method-exists-p 'agent/activity)))
    (ignore-errors (harness-call 'agent/activity live))))

(defun harness-workspace--view (workspace)
  "Return WORKSPACE as clients read it, with thread states.
Each thread carries `:state' as clients have always read it (`live',
`waiting', `merged' or `parked'), the finer `:episode-status'
(`running', `blocked', `idle', `failed', `stopped', `inactive' or
`parked'), `:pending', what its live episode waits on, `:activity',
what the running turn does now, and the settings it runs or would run
with: `:model', `:thinking', `:permission-mode' and `:non-interactive'
from its live episode, else the workspace's defaults."
  (let* ((defaults (harness-workspace--settings workspace))
         (threads (mapcar (lambda (thread)
                            (let* ((live (plist-get thread :live))
                                   (session (and live (harness-workspace--session-record live)))
                                   (state (cond ((plist-get thread :merged-into) "merged")
                                                ((null session) "parked")
                                                ((eq (plist-get session :status) 'running) "live")
                                                ((eq (plist-get session :status) 'blocked) "waiting")
                                                ((eq (plist-get session :status) 'idle) "live")
                                                (t "parked"))))
                              (append (copy-sequence thread)
                                      (list :state state
                                            :episode-status (harness-workspace--episode-status thread session)
                                            :pending (plist-get session :pending)
                                            :activity (harness-workspace--thread-activity thread)
                                            :model (harness-workspace--thread-setting
                                                    thread :model defaults)
                                            :thinking (harness-workspace--thread-setting
                                                       thread :thinking defaults)
                                            :permission-mode (harness-workspace--thread-setting
                                                              thread :permission-mode defaults)
                                            :non-interactive (harness-workspace--thread-setting
                                                              thread :non-interactive defaults)))))
                          (plist-get workspace :threads)))
         (threads (sort threads
                        (lambda (a b)
                          (cond ((and (plist-get a :pinned) (not (plist-get b :pinned))) t)
                                ((and (plist-get b :pinned) (not (plist-get a :pinned))) nil)
                                (t (> (or (plist-get a :last-at) 0)
                                      (or (plist-get b :last-at) 0))))))))
    (let ((view (copy-sequence workspace)))
      (setf (plist-get view :threads) threads)
      ;; The workspace's own settings too, so a client names the model
      ;; before its first thread exists.
      (setf (plist-get view :model) (plist-get defaults :model)
            (plist-get view :thinking) (plist-get defaults :thinking)
            (plist-get view :permission-mode) (plist-get defaults :permission-mode)
            (plist-get view :non-interactive) (plist-get defaults :non-interactive))
      (setf (plist-get view :graph)
            (or (plist-get view :graph)
                (when (harness-method-exists-p 'logseq/root)
                  (harness-call 'logseq/root))))
      view)))

(defun harness-workspace--append (workspace entry)
  "Append ENTRY to WORKSPACE's timeline and announce it."
  (let* ((id (plist-get workspace :id))
         (entry (plist-put (copy-sequence entry) :at (or (plist-get entry :at) (harness-workspace--now)))))
    (harness-call 'store/append (harness-workspace--timeline-file id) entry)
    (harness-emit 'workspace/timeline-appended id entry)
    entry))

;;;; Threads and episodes

(defun harness-workspace--knowledge-touch (workspace thread &optional status)
  "Bring THREAD's page in WORKSPACE's Logseq graph up to date.
STATUS is `active' or `parked'.  A graph that cannot be written does
not break the thread: it is logged and the chat goes on."
  (when (harness-method-exists-p 'knowledge/thread-touch)
    (condition-case err
        (harness-call 'knowledge/thread-touch
                      (plist-get workspace :id) (plist-get thread :id) status)
      (error
       (harness-log 'warn "workspace: knowledge page update failed: %s"
                    (harness-error-message err))
       nil))))

(defun harness-workspace--thread-page (workspace thread)
  "Make sure THREAD of WORKSPACE has a page in the Logseq graph.
Return its name, or nil when the graph cannot be written."
  (when (harness-method-exists-p 'knowledge/thread-page)
    (condition-case err
        (harness-call 'knowledge/thread-page
                      (plist-get workspace :id) (plist-get thread :id))
      (error
       (harness-log 'warn "workspace: no knowledge page for %s: %s"
                    (plist-get thread :id) (harness-error-message err))
       nil))))

(defun harness-workspace--new-thread (workspace title &optional project)
  "Create a thread called TITLE in WORKSPACE, on PROJECT.
Return the thread record."
  (let ((thread (list :id (harness-workspace--id "th-")
                      :title (harness-workspace--title title)
                      :status "parked"
                      :project (or project (plist-get workspace :root))
                      :episodes nil
                      :live nil
                      :summary ""
                      :pinned nil
                      :created (harness-workspace--now)
                      :last-at (harness-workspace--now))))
    (harness-workspace--put-thread workspace thread)
    (when-let* ((page (harness-workspace--thread-page workspace thread)))
      (setf (plist-get thread :page) page))
    thread))

(defun harness-workspace--title (text)
  "Return a short thread title from TEXT."
  (let* ((line (car (split-string (or text "") "\n" t)))
         (line (string-trim (replace-regexp-in-string "[[:space:]]+" " " line))))
    (cond ((string-empty-p line) "New thread")
          ((> (length line) 60) (concat (substring line 0 57) "…"))
          (t line))))

(defun harness-workspace--episode-context-used (session-id)
  "Return (USED . WINDOW) for SESSION-ID's context."
  (let* ((session (harness-call 'session/get session-id))
         (usage (plist-get session :usage))
         (used (or (plist-get usage :context) 0))
         (window (or (plist-get session :context-window) 0)))
    (cons used window)))

(defun harness-workspace--episode-too-long-p (session-id)
  "Non-nil when SESSION-ID should be continued in a new episode."
  (let* ((pair (harness-workspace--episode-context-used session-id))
         (used (car pair))
         (window (cdr pair))
         (session (harness-call 'session/get session-id))
         (turns (or (plist-get (plist-get session :usage) :turns) 0)))
    (or (and (> window 0)
             (>= used (* window harness-workspace-episode-context)))
        (and (> harness-workspace-episode-turns 0)
             (>= turns harness-workspace-episode-turns)))))

(defun harness-workspace--thread-idle-p (thread)
  "Non-nil when THREAD's live episode has been idle past the configured hours."
  (let ((hours harness-workspace-thread-idle-hours)
        (live (plist-get thread :live)))
    (and live (> hours 0)
         (> (- (harness-workspace--now) (or (plist-get thread :last-at) 0))
            (* 3600 hours)))))

(defun harness-workspace--park (workspace thread &optional why)
  "Park THREAD of WORKSPACE, leaving its episode open and its transcript whole.
WHY is kept in the thread's summary for the next brief."
  (when (plist-get thread :live)
    (when why
      (setf (plist-get thread :summary)
            (string-trim (concat (or (plist-get thread :summary) "") "\n" why))))
    (setf (plist-get thread :live) nil
          (plist-get thread :status) "parked")
    (harness-workspace--put-thread workspace thread)
    (harness-workspace--knowledge-touch workspace thread "parked")
    (harness-workspace--save workspace)
    (harness-emit 'workspace/thread-changed (plist-get workspace :id) thread)))

(defun harness-workspace--start-episode (workspace thread &optional reason)
  "Start a new episode of THREAD in WORKSPACE.
REASON is `new-thread', `revived' or `long-context'; it is written to
the divider the user sees.  Return the session id."
  (let* ((wid (plist-get workspace :id))
         (number (1+ (length (plist-get thread :episodes))))
         (cwd (file-name-as-directory
               (expand-file-name (or (plist-get thread :project)
                                     (plist-get workspace :root)))))
         (project (or (plist-get thread :project)
                      (plist-get workspace :project)
                      cwd))
         (plist (append
                 (list :kind 'workspace
                       :cwd cwd
                       :project project
                       :name (format "%s · %d" (plist-get thread :title) number)
                       :permission-mode (harness-workspace--symbol
                                         (or (plist-get workspace :permission-mode)
                                             harness-workspace-permission-mode))
                       :non-interactive (if (plist-member workspace :non-interactive)
                                            (plist-get workspace :non-interactive)
                                          harness-workspace-non-interactive)
                       :ext (append
                             (list :workspace wid
                                   :thread (plist-get thread :id)
                                   :episode number)
                             ;; The workspace's skill selection is intent
                             ;; the episode resolves afresh: what it may
                             ;; read is still its own grant of a computer.
                             (when (plist-get workspace :skills)
                               (list :skill-selection-inherited
                                     (append (plist-get workspace :skills) nil)))))
                 (when-let* ((model (or (plist-get workspace :model)
                                        harness-workspace-model)))
                   (list :model model))
                 (when-let* ((thinking (or (plist-get workspace :thinking)
                                           harness-workspace-thinking)))
                   (list :thinking thinking))))
         (session (apply #'harness-call 'session/create plist))
         (sid (plist-get session :id)))
    (setf (plist-get thread :live) sid
          (plist-get thread :status) "live"
          ;; The last stop was the old episode's: a new episode starts
          ;; without one, running or idle, never failed or stopped.
          (plist-get thread :last-stop) nil)
    (setf (plist-get thread :episodes)
          (append (plist-get thread :episodes) (list sid)))
    (harness-workspace--put-thread workspace thread)
    (harness-workspace--knowledge-touch workspace thread "active")
    (harness-workspace--save workspace)
    (let ((divider (harness-workspace--append
                    workspace
                    (list :kind 'divider
                          :thread (plist-get thread :id)
                          :episode sid
                          :reason (or reason 'new-thread)
                          :title (plist-get thread :title)))))
      (harness-emit 'workspace/episode-changed wid thread sid divider))
    sid))

;;;; Briefs

(defun harness-workspace--graph (workspace)
  "Return the Logseq graph WORKSPACE keeps its knowledge in."
  (or (plist-get workspace :graph)
      (when (harness-method-exists-p 'logseq/root)
        (harness-call 'logseq/root))))

(defun harness-workspace--recent (workspace thread limit)
  "Return the last LIMIT message entries of THREAD."
  (let ((wanted (plist-get thread :id))
        (out nil))
    (dolist (entry (harness-workspace--timeline-internal (plist-get workspace :id)))
      (when (and (equal (plist-get entry :thread) wanted)
                 (eq (harness-workspace--entry-kind entry) 'message))
        (push entry out)))
    (harness-workspace--resolve-entries
     (last (nreverse out) (or limit 0)))))

(defun harness-workspace--entry-kind (entry)
  "Return ENTRY's kind as a symbol, JSON or not."
  (let ((kind (plist-get entry :kind)))
    (cond ((symbolp kind) kind)
          ((stringp kind) (intern kind))
          (t nil))))

(defun harness-workspace--entry-role (entry)
  "Return ENTRY's role as a symbol."
  (let ((role (plist-get entry :role)))
    (cond ((symbolp role) role)
          ((stringp role) (intern role))
          (t nil))))

(defun harness-workspace--clip-text (text)
  "Return TEXT clipped to the most a timeline message keeps."
  (if (> (length text) harness-workspace-max-message-chars)
      (concat (substring text 0 harness-workspace-max-message-chars) "\n…")
    text))

(defun harness-workspace--entry-text (entry)
  "Return ENTRY's text, clipped."
  (harness-workspace--clip-text (or (plist-get entry :text) "")))

(defun harness-workspace--node-text (entry)
  "Return the session text of ENTRY, or its stored text when the node is gone.
A message entry names the episode and node it came from.  The node is
the transcript's own copy of the words, so it is what a client reads:
the timeline captured the node when its first chunk opened it, and the
rest of a streamed answer is written to the node."
  (let ((node-id (plist-get entry :node))
        (session (plist-get entry :episode))
        (stored (harness-workspace--entry-text entry)))
    (if (or (not (stringp node-id)) (not (stringp session))
            (not (harness-method-exists-p 'session/node))
            (not (harness-call 'session/exists-p session)))
        stored
      (condition-case err
          (let ((node (harness-call 'session/node session node-id)))
            (if (and node
                     (stringp (plist-get node :content))
                     (not (string-blank-p (plist-get node :content))))
                (harness-workspace--clip-text (plist-get node :content))
              stored))
        (error
         (harness-log 'warn "workspace: cannot read node %s of %s: %s"
                      node-id session (error-message-string err))
         stored)))))

(defun harness-workspace--resolve-entry (entry)
  "Return ENTRY with a message's text read from its node."
  (if (eq (harness-workspace--entry-kind entry) 'message)
      (let ((text (harness-workspace--node-text entry)))
        (if (equal text (or (plist-get entry :text) ""))
            entry
          (plist-put (copy-sequence entry) :text text)))
    entry))

(defun harness-workspace--resolve-entries (entries)
  "Return ENTRIES with message text read from their nodes."
  (mapcar #'harness-workspace--resolve-entry entries))

(defun harness-workspace--timeline-internal (id)
  "Return every timeline entry of workspace ID, oldest first."
  (harness-call 'store/read-all (harness-workspace--timeline-file id)))

(defun harness-workspace--knowledge-recall (workspace thread text)
  "Return knowledge blocks for TEXT in WORKSPACE's thread THREAD."
  (when (harness-method-exists-p 'knowledge/recall)
    (condition-case err
        (harness-call 'knowledge/recall
                      (plist-get workspace :id)
                      (plist-get thread :id)
                      text)
      (error
       (harness-log 'warn "workspace: recall failed: %s" (error-message-string err))
       nil))))

(defun harness-workspace--knowledge-index (workspace)
  "Return the navigation index of WORKSPACE's graph, or nil.
That is the small list the dream keeps of the pages it maintains, which
a brief carries so that the search and the curated graph work together."
  (when (harness-method-exists-p 'knowledge/index)
    (condition-case err
        (let ((index (harness-call 'knowledge/index (plist-get workspace :id))))
          (and (stringp index) (not (string-blank-p index)) index))
      (error
       (harness-log 'warn "workspace: the knowledge index failed: %s"
                    (error-message-string err))
       nil))))

(defun harness-workspace--task-lines (workspace thread)
  "Return a short task digest for WORKSPACE's THREAD."
  (when (harness-method-exists-p 'task/list)
    (condition-case err
        (let* ((project (or (plist-get thread :project) (plist-get workspace :root)))
               (tasks (harness-call 'task/list project))
               (open (cl-remove-if (lambda (task)
                                     (member (format "%s" (plist-get task :state))
                                             '("done" "cancelled")))
                                   tasks)))
          (when open
            (mapconcat (lambda (task)
                         (format "- %s [%s]%s"
                                 (or (plist-get task :title) "task")
                                 (or (plist-get task :column) (plist-get task :state) "open")
                                 (if-let* ((session (plist-get task :session)))
                                     (format " %s" session)
                                   "")))
                       (seq-take open 5) "\n")))
      (error
       (harness-log 'warn "workspace: task digest failed: %s" (error-message-string err))
       nil))))

(defun harness-workspace--brief (workspace thread text)
  "Build the brief for a new episode of THREAD, about TEXT."
  (let* ((recent (harness-workspace--recent workspace thread harness-workspace-brief-recent))
         (recall (harness-workspace--knowledge-recall workspace thread text))
         (tasks (harness-workspace--task-lines workspace thread))
         (summary (plist-get thread :summary))
         (parts
          (delq nil
                (list
                 (format "[Workspace %s]" (or (plist-get workspace :name) "Home"))
                 (let ((instructions (plist-get workspace :instructions)))
                   (and (stringp instructions) (not (string-blank-p instructions))
                        (format "Instructions: %s" (string-trim instructions))))
                 (format "Thread: %s" (or (plist-get thread :title) "New thread"))
                 (format "Project: %s" (or (plist-get thread :project) (plist-get workspace :root)))
                 (and summary (not (string-blank-p summary))
                      (format "Thread state:\n%s" (string-trim summary)))
                 (let ((next (plist-get thread :next-action)))
                   (and (stringp next) (not (string-blank-p next))
                        (format "Next action: %s" (string-trim next))))
                 (and tasks (format "Work:\n%s" tasks))
                 (and recent
                      (format "Recent:\n%s"
                              (mapconcat
                               (lambda (entry)
                                 (format "%s: %s"
                                         (if (eq (harness-workspace--entry-role entry) 'assistant)
                                             "Agent" "You")
                                         (harness-workspace--entry-text entry)))
                               recent "\n")))
                 (and recall
                      (format "Knowledge:\n%s"
                              (mapconcat
                               (lambda (card)
                                 (format "- [%s] %s"
                                         (or (plist-get card :page) "graph")
                                         (plist-get card :text)))
                               recall "\n")))
                 ;; The curated graph's own list of what it knows, so a
                 ;; brief carries the index the dream keeps beside the
                 ;; blocks a search recalled.
                 (let ((index (harness-workspace--knowledge-index workspace)))
                   (and index (format "Index:\n%s" index)))
                 (format "Knowledge graph: %s" (harness-workspace--graph workspace))
                 "Answer the user's message.  Use knowledge_search for anything not in this brief and knowledge_write for what is worth keeping in the graph; do not invent knowledge.  memory_save is only for small behavioral notes about how the user wants work done.")))
         (brief (string-trim (mapconcat #'identity parts "\n\n"))))
    (if (> (length brief) harness-workspace-brief-chars)
        (concat (substring brief 0 harness-workspace-brief-chars) "\n\n[Brief cut to fit.]")
      brief)))

;;;; Routing

;; A message goes to a thread, and a topic switch starts a new one.  The
;; decision is local and asks no model: each thread is a small document
;; made of its title, its summary and its last messages, and a message is
;; ranked against them as a query is ranked against documents.  A
;; thread's score is the share of the message's own words it holds, a
;; rarer word weighing more and a word in the title three times one in a
;; message.  A message whose words no thread holds starts a new thread,
;; and anything else stays where the person was writing, because a wrong
;; split is more annoying than a slightly long thread.  With an embedding
;; model configured, the threads' meanings re-rank a close call.

(defcustom harness-workspace-router-threshold 0.2
  "How much of a message a thread must hold to be its topic.
The score is the share of the message's content words a thread's title,
summary and last messages hold, from 0 to 1.  A rarer word counts more
than a common one, a word in the title counts three times one in a
message, and a word repeated in one place counts a little more.  At or
above this share the thread is about the message; below it a message
with new words of its own may start a new thread."
  :type 'number
  :group 'harness-workspace)

(defcustom harness-workspace-router-recent 6
  "Messages of a thread the router reads for its words."
  :type 'integer
  :group 'harness-workspace)

(defcustom harness-workspace-router-semantic t
  "Whether an embedding model re-ranks a close routing call.
When non-nil and `harness-workspace-knowledge-embedding-model' names a
model, the message and each thread's digest are embedded, and a thread
the words do not separate is placed by meaning.  Nil keeps routing to
words alone.  Without an embedding model no model is asked."
  :type 'boolean
  :group 'harness-workspace)

(defcustom harness-workspace-router-timeout 2
  "Seconds the semantic re-rank may take before the words decide."
  :type 'number
  :group 'harness-workspace)

(defconst harness-workspace--stop-words
  '("a" "about" "after" "again" "against" "all" "also" "am" "an" "and" "any" "are" "as"
    "at" "be" "because" "been" "before" "being" "below" "between" "both" "but" "by"
    "can" "could" "did" "do" "does" "doing" "done" "down" "during" "each" "few" "for"
    "from" "further" "get" "got" "had" "has" "have" "having" "he" "her" "here" "hers"
    "him" "his" "how" "i" "if" "in" "into" "is" "it" "its" "just" "let" "lets" "like"
    "me" "more" "most" "my" "no" "nor" "not" "now" "of" "off" "on" "once" "only" "or"
    "other" "our" "ours" "out" "over" "own" "please" "same" "she" "should" "so" "some"
    "such" "than" "that" "the" "their" "theirs" "them" "then" "there" "these" "they"
    "this" "those" "through" "to" "too" "under" "until" "up" "very" "was" "we" "were"
    "what" "when" "where" "which" "while" "who" "whom" "why" "will" "with" "would"
    "you" "your" "yours")
  "Words that say nothing about a topic.
A thread is found by the words a person would name it with, so these
are left out of the router's scores and its freshness test.")

(defconst harness-workspace--topic-cues
  '("new topic" "different topic" "another topic" "change the subject"
    "change of subject" "change topic" "different subject" "unrelated"
    "separate thread" "start over" "start a new thread" "new thread"
    "on another note" "off topic" "switching topics" "switch topics"
    "let's switch" "lets switch" "move on to" "moving on" "moving on to"
    "new conversation" "fresh start")
  "Phrases that say the subject changed.
A phrase with a thread's name in the same message names that thread
instead (`switch to the kitchen thread').")

(defun harness-workspace--topic-title (text)
  "Return TEXT as a thread title, without the phrase that announced it.
\"new topic: taxes\" is titled \"taxes\"; a message with no such
phrase keeps its words."
  (let ((title (string-trim (or text "")))
        (case-fold-search t))
    (dolist (cue harness-workspace--topic-cues)
      (when (string-match-p (concat "\\`\\s-*" (regexp-quote cue) "\\b") title)
        (setq title (string-trim
                     (replace-regexp-in-string
                      (concat "\\`\\s-*" (regexp-quote cue)
                              "\\(?:\\s-*[:·—–-]\\s-*\\|\\s-+\\)")
                      "" title)))))
    (if (string-blank-p title) (string-trim (or text "")) title)))

(defconst harness-workspace--soft-cues
  '("what about" "how about" "by the way" "speaking of" "separately"
    "another thing" "one more thing" "quick question" "new question"
    "on a different note" "different question" "change of plan")
  "Phrases that often start another topic.
They only start a new thread when the current thread's words do not
explain the rest of the message (`what about the countertop?' in the
kitchen thread stays there).")

(defconst harness-workspace--continuation-words
  '("again" "also" "and" "another" "but" "continue" "elaborate" "expand"
    "explain" "further" "longer" "more" "next" "previous" "rewrite"
    "shorter" "so" "still" "summarize" "summarise" "then" "this" "those"
    "tweak" "update")
  "Words that tie a message to what came before it.")

(defun harness-workspace--words (text)
  "Return the words of TEXT, lowercased."
  (split-string (downcase (or text "")) "[^[:alnum:]_'-]+" t))

(defun harness-workspace--content-words (text)
  "Return the distinct words of TEXT that say something about its topic."
  (delete-dups
   (cl-remove-if (lambda (word)
                   (or (< (length word) 3)
                       (member word harness-workspace--stop-words)))
                 (harness-workspace--words text))))

(defun harness-workspace--term-counts (text)
  "Return a hash of TEXT's content words and how often each occurs."
  (let ((counts (make-hash-table :test 'equal)))
    (dolist (word (harness-workspace--words text))
      (when (and (>= (length word) 3)
                 (not (member word harness-workspace--stop-words)))
        (puthash word (1+ (gethash word counts 0)) counts)))
    counts))

(defconst harness-workspace--route-fields
  '((title . 3.0) (summary . 2.0) (message . 1.0))
  "How much a word in each part of a thread counts toward its score.
A title names the topic, a summary states it, and a message may only
pass through it.")

(defun harness-workspace--phrase-p (phrases text)
  "Non-nil when TEXT holds one of PHRASES as whole words."
  (let ((text (downcase (or text ""))))
    (cl-some (lambda (phrase)
               (string-match-p
                (concat "\\(?:\\`\\|[^[:alnum:]]\\)"
                        (regexp-quote phrase)
                        "\\(?:\\'\\|[^[:alnum:]]\\)")
                text))
             phrases)))

(defun harness-workspace--mentions-p (text title)
  "Non-nil when TEXT names the thread called TITLE.
That is the whole title in the text, or two thirds of its own words, at
least two of them."
  (let ((text (downcase (or text "")))
        (title (string-trim (downcase (or title "")))))
    (or (and (not (string-empty-p title))
             (string-match-p (regexp-quote title) text))
        (let ((words (harness-workspace--content-words title)))
          (and (>= (length words) 2)
               (let ((hits (cl-count-if
                            (lambda (word)
                              (string-match-p
                               (concat "\\b" (regexp-quote word) "\\b") text))
                            words)))
                 (and (>= hits 2) (>= (/ hits (float (length words))) 0.6))))))))

(defun harness-workspace--named-thread (workspace text &optional except)
  "Return the thread of WORKSPACE that TEXT names, or nil.
EXCEPT is a thread id to leave out."
  (cl-find-if (lambda (thread)
                (and (not (equal (plist-get thread :id) except))
                     (harness-workspace--mentions-p text (plist-get thread :title))))
              (plist-get workspace :threads)))

(defun harness-workspace--route-index (workspace)
  "Return the passages of WORKSPACE's threads, and the words they use.
The answer is `(:passages PASSAGES :df HASH :count N :digests HASH)'.
A passage is a plist of `:thread' (an id), `:field' (`title', `summary'
or `message'), `:text' and `:counts', its content words.  DF maps a word
to the number of passages that hold it, and DIGESTS maps a thread id to
the text its meaning is read from: its title, state and newest message."
  (let ((recent (make-hash-table :test 'equal))
        (digests (make-hash-table :test 'equal))
        (passages nil))
    (dolist (entry (harness-workspace--timeline-internal (plist-get workspace :id)))
      (when (and (eq (harness-workspace--entry-kind entry) 'message)
                 (plist-get entry :thread))
        (let ((text (harness-workspace--entry-text entry)))
          (unless (string-blank-p text)
            (push text (gethash (plist-get entry :thread) recent))))))
    (dolist (thread (plist-get workspace :threads))
      (let* ((id (plist-get thread :id))
             (summary (string-trim
                       (mapconcat #'identity
                                  (delq nil (list (plist-get thread :summary)
                                                  (plist-get thread :next-action)))
                                  "\n")))
             (messages (seq-take (gethash id recent) harness-workspace-router-recent))
             (parts (append (delq nil (list (plist-get thread :title)
                                            (plist-get thread :summary)
                                            (plist-get thread :next-action)))
                            (seq-take messages 1))))
        (puthash id (string-trim (mapconcat #'identity parts "\n")) digests)
        (dolist (passage (append
                          (list (list :thread id :field 'title
                                      :text (or (plist-get thread :title) "")))
                          (unless (string-blank-p summary)
                            (list (list :thread id :field 'summary :text summary)))
                          (mapcar (lambda (text)
                                    (list :thread id :field 'message :text text))
                                  messages)))
          (push (plist-put passage :counts
                           (harness-workspace--term-counts (plist-get passage :text)))
                passages))))
    (let ((df (make-hash-table :test 'equal)))
      (dolist (passage passages)
        (let (seen)
          (maphash (lambda (word _) (push word seen)) (plist-get passage :counts))
          (dolist (word seen)
            (puthash word (1+ (gethash word df 0)) df))))
      (list :passages passages :df df :count (length passages) :digests digests))))

(defun harness-workspace--route-idf (index word)
  "Return the weight of WORD in INDEX.
A word no passage holds weighs like one a single passage holds, so a
message full of new words is not judged against a corpus that keeps
growing."
  (let* ((n (plist-get index :count))
         (df (max 1 (gethash word (plist-get index :df) 0))))
    (if (< n 1)
        0.0
      (log (1+ (/ (- n df 0.5) (+ df 0.5)))))))

(defun harness-workspace--route-match (index word thread)
  "Return how strongly WORD names THREAD in INDEX, from 0 to 3.
A word in the title counts three times one in a message; a word
repeated in one passage grows sublinearly and never past the field's
weight."
  (let ((best 0.0))
    (dolist (passage (plist-get index :passages))
      (when (equal (plist-get passage :thread) thread)
        (let ((count (gethash word (plist-get passage :counts) 0)))
          (when (> count 0)
            (setq best (max best (* (alist-get (plist-get passage :field)
                                                harness-workspace--route-fields)
                                    (1+ (log count)))))))))
    (min 3.0 best)))

(defun harness-workspace--route-score (index text thread)
  "Return how much of TEXT's subject THREAD holds in INDEX, from 0 to 1.
TEXT's content words are weighed by how rare they are in the workspace,
and the score is the share of that weight THREAD holds, a word in its
title worth three and one in a message worth one."
  (let ((words (harness-workspace--term-counts text))
        (total 0.0) (held 0.0))
    (maphash (lambda (word _)
               (let ((weight (harness-workspace--route-idf index word)))
                 (cl-incf total weight)
                 (cl-incf held (* weight (harness-workspace--route-match
                                          index word thread)))))
             words)
    (if (<= total 0) 0.0 (min 1.0 (/ held (* 3.0 total))))))

(defun harness-workspace--route-scores (index text threads)
  "Return an alist of THREAD and how much of TEXT's subject it holds."
  (mapcar (lambda (thread)
            (cons thread (harness-workspace--route-score
                          index text (plist-get thread :id))))
          threads))

(defun harness-workspace--route-score-of (scores thread)
  "Return THREAD's score in SCORES, or 0."
  (or (cdr (assq thread scores)) 0.0))

(defun harness-workspace--route-best (scores current)
  "Return (THREAD . SCORE) of the thread SCORES ranks highest, CURRENT aside.
Only a thread with a title is weighed.  CURRENT is left out because
the message is first weighed against it, and a message that fits it
never reaches this."
  (let (best)
    (dolist (pair scores)
      (let ((thread (car pair)))
        (unless (or (eq thread current)
                    (string-blank-p (or (plist-get thread :title) "")))
          (when (and (> (cdr pair) 0)
                     (or (null best) (> (cdr pair) (cdr best))))
            (setq best pair)))))
    best))

(defun harness-workspace--route-held-p (index text thread)
  "Non-nil when THREAD holds any of TEXT's content words in INDEX."
  (let (held)
    (maphash (lambda (word _)
               (unless held
                 (when (> (harness-workspace--route-match index word thread) 0)
                   (setq held t))))
             (harness-workspace--term-counts text))
    held))

(defun harness-workspace--fresh-p (index text thread)
  "Non-nil when TEXT is a subject THREAD has not used at all.
It must hold at least three content words of its own, none of them in
the thread, and none of the words that tie a message to the one before
it."
  (and thread
       (>= (hash-table-count (harness-workspace--term-counts text)) 3)
       (not (harness-workspace--phrase-p harness-workspace--continuation-words text))
       (not (harness-workspace--route-held-p index text (plist-get thread :id)))))

(defconst harness-workspace--router-margin 0.1
  "How far another thread's score must lead the current one's to take a message.
A margin keeps a message that fits both threads about as well in the
thread the person was just writing in.")

(defconst harness-workspace--router-meaning-weight 0.5
  "How far a thread's meaning may lift its word score, from 0 to 1.
The meaning score is a cosine; the lift is a share of what the word
score leaves open, so meaning can place a thread the words did not, and
cannot undo the words of a clear match.")

(defun harness-workspace--router-meaning (index text scores)
  "Return SCORES with each thread's meaning blended in, or nil.
Asks the knowledge module for the cosine of TEXT and each thread's
digest when `harness-workspace-router-semantic' is on and an embedding
model is configured.  Nil keeps the words' own scores."
  (when (and harness-workspace-router-semantic
             (harness-method-exists-p 'knowledge/nearest)
             (bound-and-true-p harness-workspace-knowledge-embedding-model))
    (let ((threads (mapcar #'car scores)))
      (when-let* ((meanings
                   (condition-case err
                       (harness-call
                        'knowledge/nearest
                        text
                        (mapcar (lambda (thread)
                                  (gethash (plist-get thread :id)
                                           (plist-get index :digests)))
                                threads)
                        harness-workspace-router-timeout)
                     (error
                      (harness-log 'warn "workspace router: meaning failed: %s"
                                   (error-message-string err))
                      nil))))
        (cl-loop for thread in threads
                 for meaning in meanings
                 collect (cons thread
                               (let ((score (cdr (assq thread scores))))
                                 (if (numberp meaning)
                                     (+ score (* harness-workspace--router-meaning-weight
                                                 (max 0.0 meaning)
                                                 (- 1.0 score)))
                                   score))))))))

(defun harness-workspace--route-by-score (index text current scores)
  "Return (THREAD ACTION WHY) for TEXT, ranked by SCORES.
The current thread keeps a message it holds above the threshold; another
thread takes one it holds much better, or one the current thread holds
nothing of; a subject no thread holds starts a thread; anything else
stays where the person was writing."
  (let* ((held (harness-workspace--route-score-of scores current))
         (best (harness-workspace--route-best scores current)))
    (cond
     ((and current (> held harness-workspace-router-threshold))
      (list current 'continue 'ranked))
     ((and best
           (>= (cdr best) harness-workspace-router-threshold)
           (> (cdr best) (+ held harness-workspace--router-margin)))
      (let ((thread (car best)))
        (list thread (if (plist-get thread :live) 'continue 'revive) 'ranked)))
     ((harness-workspace--fresh-p index text current)
      (list nil 'new 'fresh))
     ;; A message the current thread holds nothing of does not continue
     ;; it, even when a continuation word ties it to the turn before it:
     ;; it goes to a thread that holds some of it, when one does.
     ((and current best
           (not (harness-workspace--route-held-p
                 index text (plist-get current :id))))
      (let ((thread (car best)))
        (list thread (if (plist-get thread :live) 'continue 'revive) 'ranked)))
     (t (list current 'continue 'ranked)))))

(defun harness-workspace--route-other (scores current)
  "Return the thread SCORES ranks highest above the threshold, CURRENT aside."
  (let ((best (harness-workspace--route-best scores current)))
    (when (and best (>= (cdr best) harness-workspace-router-threshold))
      (car best))))

(defun harness-workspace--force-continue-p (opts)
  "Non-nil when OPTS name `:force-continue', JSON or not.
A client that sends the words instead of the option says `/continue'."
  (or (harness-json-true-p (plist-get opts :force-continue))
      (and (stringp (plist-get opts :command))
           (member (downcase (plist-get opts :command)) '("/continue" "continue")))))

(defun harness-workspace--route (workspace text opts)
  "Return (THREAD ACTION WHY) for TEXT in WORKSPACE.
ACTION is `continue', `revive' or `new'; WHY says what it was decided
from: `explicit', `command', `named', `cue', `selected', `first',
`ranked' or `fresh'.  THREAD is nil for a new thread.  OPTS may name
`:thread' (a preference: the thread a client has selected),
`:force-thread' (a binding: that thread whatever the message says),
`:force-continue', `:force-new' and `:command'."
  (let* ((requested (or (plist-get opts :force-thread) (plist-get opts :thread)))
         (forced (and requested (harness-workspace--thread workspace requested)))
         (_ (when (and (plist-get opts :force-thread) (null forced))
              (signal 'harness-error
                      (list (format "No thread %s" (plist-get opts :force-thread))))))
         (current (and (plist-get workspace :last-thread)
                       (harness-workspace--thread workspace (plist-get workspace :last-thread))))
         (named (harness-workspace--named-thread
                 workspace text (and current (plist-get current :id))))
         (live (and current (plist-get current :live)))
         ;; A bound thread and a message that says continue are hard
         ;; signals: neither a cue nor another thread's name overrides
         ;; the client that asked for it.
         (hard (or (harness-workspace--force-continue-p opts)
                   (plist-get opts :force-thread)
                   (string-match-p "\\`/continue\\(?:[ \t\n]\\|\\'\\)" text)))
         (index (harness-workspace--route-index workspace))
         (scores (harness-workspace--route-scores
                  index text (plist-get workspace :threads)))
         (held (harness-workspace--route-score-of scores current))
         (words (hash-table-count (harness-workspace--term-counts text)))
         (decide
          (cond
           ;; A client that binds the thread, or a message that says
           ;; continue: no other signal overrides it.
           ((and hard (or forced current))
            (let ((thread (or forced current)))
              (list thread (if (plist-get thread :live) 'continue 'revive) 'explicit)))
           ((harness-json-true-p (plist-get opts :force-new))
            (list nil 'new 'command))
           ((string-match-p "\\`/new\\(?:[ \t\n]\\|\\'\\)" text)
            (list nil 'new 'command))
           ;; A thread named in the message is its subject, even when
           ;; the message is phrased as a switch to it.
           (named (list named 'revive 'named))
           ;; A phrase that says the subject changed.
           ((harness-workspace--phrase-p harness-workspace--topic-cues text)
            (list nil 'new 'cue))
           ;; A client's selected thread, when it is not the thread the
           ;; last message went to: the person picked it.
           ((and forced (not (equal (plist-get forced :id)
                                    (and current (plist-get current :id)))))
            (list forced (if (plist-get forced :live) 'continue 'revive) 'selected))
           ;; "What about X?": the current thread keeps it when X is its;
           ;; an older thread it clearly names takes it; otherwise the
           ;; phrase is a new subject.
           ((harness-workspace--phrase-p harness-workspace--soft-cues text)
            (let* ((ranked (or (harness-workspace--router-meaning index text scores)
                               scores))
                   (held (harness-workspace--route-score-of ranked current))
                   (other (harness-workspace--route-other ranked current)))
              (cond
               ;; The thread that holds the message best takes it, even
               ;; the current one, when it holds it at all: `what about
               ;; the countertop?' in the kitchen thread stays there.
               ((and current (> held 0)
                     (or (null other)
                         (> held (harness-workspace--route-score-of ranked other))))
                (list current 'continue 'ranked))
               (other
                (list other (if (plist-get other :live) 'continue 'revive) 'ranked))
               (t (list nil 'new 'cue)))))
           ((null current)
            (list nil 'new 'first))
           ;; A turn in flight takes a message that belongs to it; only
           ;; a clearly different subject starts another thread.
           ((and live (harness-workspace--session-running-p live)
                 (or (< words 3) (> held 0)))
            (list current 'continue 'ranked))
           ;; Everything else is what the scores say.
           (t (harness-workspace--route-by-score
               index text current
               (or (harness-workspace--router-meaning index text scores)
                   scores)))))
         (action (cadr decide))
         (thread (car decide))
         (why (nth 2 decide)))
    (cond
     ((eq action 'new)
      (list nil 'new why))
     ((null thread)
      (list current 'continue why))
     ((and current (equal (plist-get thread :id) (plist-get current :id)))
      (list current
            (if (and live
                     (or (harness-workspace--episode-too-long-p live)
                         (harness-workspace--thread-idle-p current)))
                'revive
              'continue)
            why))
     ((plist-get thread :live)
      (list thread 'continue why))
     (t
      (list thread 'revive why)))))


;;;; Session events

(defun harness-workspace--note-thread (workspace thread role text)
  "Update THREAD's summary and last time from ROLE's TEXT."
  (let ((time (harness-workspace--now)))
    (setf (plist-get thread :last-at) time)
    (when (eq role 'assistant)
      (setf (plist-get thread :summary)
            (truncate-string-to-width (string-trim (or text "")) 400 nil nil "…")))
    (harness-workspace--put-thread workspace thread)
    (harness-workspace--save workspace)
    (harness-emit 'workspace/thread-changed (plist-get workspace :id) thread)))

(defun harness-workspace--record-message (workspace thread session role node)
  "Record NODE as a message of THREAD in WORKSPACE.
A user message keeps its provenance: the thread it was addressed to as
`:origin', the thread whose episode answers it as `:handling', and the
profile it arrived through.  The router may put a message in another
thread than the one the person picked, and a reassignment moves it
afterwards, so both are written when the message is.  An assistant
message has the provenance of the thread it answers in."
  (let ((text (or (plist-get node :content) "")))
    (unless (string-blank-p text)
      (let* ((meta (plist-get node :meta))
             (moved (plist-get meta :reassigned))
             (prov (if (eq role 'user)
                       (list :origin (or (plist-get meta :origin)
                                         (plist-get thread :id))
                             :handling (or (plist-get meta :handling)
                                           (plist-get thread :id))
                             :profile (or (plist-get meta :profile)
                                          (harness-workspace--profile workspace thread))
                             :reassigned moved)
                     (list :origin (plist-get thread :id)
                           :handling (plist-get thread :id)
                           :profile (harness-workspace--profile workspace thread))))
             (entry (harness-workspace--append
                     workspace
                     (append
                      (list :kind 'message
                            :thread (plist-get thread :id)
                            :episode session
                            :role role
                            :text (if (> (length text) harness-workspace-max-message-chars)
                                      (substring text 0 harness-workspace-max-message-chars)
                                    text)
                            :node (plist-get node :id))
                      ;; An explicit nil would read as "not given"; leave a
                      ;; key out when it says nothing.
                      (cl-loop for (key value) on prov by #'cddr
                               when value append (list key value))))))
        (harness-workspace--note-thread workspace thread role text)
        entry))))

(defun harness-workspace--on-node-added (session-id node)
  "Grow a workspace timeline from a node added to SESSION-ID."
  (when-let* (((not (gethash session-id harness-workspace--handling)))
              (ext (harness-workspace--episode-p session-id))
              (wid (plist-get ext :workspace))
              (tid (plist-get ext :thread))
              (workspace (gethash wid harness-workspace--table))
              (thread (harness-workspace--thread workspace tid))
              (kind (harness-workspace--entry-kind node))
              ((memq kind '(user assistant plan)))
              ((not (plist-get (plist-get node :meta) :workspace-brief))))
    (puthash session-id t harness-workspace--handling)
    (unwind-protect
        (harness-workspace--record-message
         workspace thread session-id
         (if (eq kind 'user) 'user 'assistant)
         node)
      (remhash session-id harness-workspace--handling))))

(defun harness-workspace--on-node-updated (session-id node transient)
  "Keep a thread's summary from NODE, the final text of SESSION-ID's reply.
The timeline entry reads its text from the node when it is read; the
thread summary is a copy, so it is brought up to date when the stream
ends rather than when the first chunk opens the node."
  (when (and (not transient)
             (eq (harness-workspace--entry-kind node) 'assistant))
    (let ((text (plist-get node :content)))
      (when (and (stringp text) (not (string-blank-p text)))
        (when-let* ((ext (harness-workspace--episode-p session-id))
                    (workspace (gethash (plist-get ext :workspace)
                                        harness-workspace--table))
                    (thread (harness-workspace--thread
                             workspace (plist-get ext :thread))))
          (harness-workspace--note-thread workspace thread 'assistant text))))))

(defun harness-workspace--on-turn-started (session-id &rest _)
  "Clear the failed or stopped mark of SESSION-ID's episode.
A new turn is a new chance: the episode reads running, not what its
last turn ended with."
  (when-let* ((ext (harness-workspace--episode-p session-id))
              (workspace (gethash (plist-get ext :workspace) harness-workspace--table))
              (thread (harness-workspace--thread workspace (plist-get ext :thread)))
              ((equal (plist-get thread :live) session-id))
              ((plist-get thread :last-stop)))
    (setf (plist-get thread :last-stop) nil)
    (harness-workspace--put-thread workspace thread)
    (harness-workspace--save workspace)
    (harness-emit 'workspace/thread-changed (plist-get workspace :id) thread)))

(defun harness-workspace--on-turn-ended (session-id &optional reason)
  "Mark the episode of SESSION-ID idle in its workspace.
REASON is why the turn ended; an error stays marked failed, and a turn
the user cancelled stopped, until the episode starts another.  A reply
that is ready waits at the notification cutoff: several threads that
finish near each other notify once, and one that finishes later notifies
on its own."
  (when-let* ((ext (harness-workspace--episode-p session-id))
              (workspace (gethash (plist-get ext :workspace) harness-workspace--table))
              (thread (harness-workspace--thread workspace (plist-get ext :thread))))
    (setf (plist-get thread :last-stop) (and reason (format "%s" reason)))
    ;; The key may be new: put the thread back, not only its plist.
    (harness-workspace--put-thread workspace thread)
    (harness-workspace--save workspace)
    (harness-emit 'workspace/thread-changed (plist-get workspace :id) thread)
    (when (and (eq (harness-workspace--symbol reason) 'end-turn)
               harness-workspace-notify)
      (harness-workspace--queue-notification workspace thread session-id))))

;;;; Provenance

;; A workspace is one conversation over several threads, so every message
;; it shows has two places: the thread and profile it *came from* (its
;; origin), and the thread it is *handled in*.  Routing makes the two
;; differ; a reassignment changes the second after the first was already
;; recorded.  Keeping both on the entry means the timeline never loses
;; where a message began, and a client can say "asked in Kitchen, handled
;; in Tiles" without a second store.
;;
;; The profile is the voice or text surface the words arrived through.  A
;; workspace has a default profile (`:profile', "text" unless set); a
;; thread may name its own; an entry keeps what it was sent from.  Nothing
;; is inferred from a client's identity: the sender says which profile it
;; is, and a message without one takes the thread's.

(defconst harness-workspace--default-profile "text"
  "The profile a workspace's messages come from when nothing says otherwise.")

(defun harness-workspace--profile (workspace &optional thread)
  "Return the profile of WORKSPACE, or of its THREAD when it names one.
A profile is a short name people read, such as \"text\", \"voice\" or a
surface a client registered.  A thread's own profile wins over the
workspace's; a workspace without one is \"text\"."
  (or (and thread (plist-get thread :profile))
      (plist-get workspace :profile)
      harness-workspace--default-profile))

(defun harness-workspace--provenance (workspace thread &optional opts)
  "Return the provenance plist for a message routed to THREAD in WORKSPACE.
OPTS may name `:profile' (the surface it arrived through) and `:origin'
(the thread it was first addressed to, when a client already knows it).
The answer holds `:profile', `:origin' and `:handling', the thread whose
episode answers it, so a message keeps its own origin when the router
puts it in another thread."
  (let* ((origin (or (plist-get opts :origin)
                     (and thread (plist-get thread :id))))
         (profile (or (plist-get opts :profile)
                      (harness-workspace--profile workspace thread))))
    (list :profile profile
          :origin origin
          :handling (and thread (plist-get thread :id)))))

(defun harness-workspace--entry-provenance (entry)
  "Return ENTRY's provenance as a plist, with what it does not say filled in.
An entry written before provenance existed has none: its origin and
handling are its thread, and its profile is the default, so a client
reads one shape from every entry."
  (let* ((thread (plist-get entry :thread))
         (profile (plist-get entry :profile)))
    (list :profile (or (and (stringp profile) (not (string-empty-p profile)) profile)
                       harness-workspace--default-profile)
          :origin (or (plist-get entry :origin) thread)
          :handling (or (plist-get entry :handling) thread)
          :reassigned (plist-get entry :reassigned))))

(defun harness-workspace--origin-label (workspace entry)
  "Return the words naming where ENTRY came from, or nil when that is plain.
Nil when the message came from the thread that handles it and from the
workspace's own profile: there is nothing to say.  Otherwise the origin
thread's title when it is another thread, and the profile when it is not
the workspace's default."
  (let* ((prov (harness-workspace--entry-provenance entry))
         (origin (plist-get prov :origin))
         (handling (plist-get prov :handling))
         (profile (plist-get prov :profile))
         (default (harness-workspace--profile workspace))
         (thread (and origin (harness-workspace--thread workspace origin)))
         (title (or (and thread (plist-get thread :title))
                    (and origin (plist-get entry :origin-title)))))
    (cond
     ((and (equal origin handling) (equal profile default)) nil)
     ((and title (not (equal origin handling)))
      (if (equal profile default)
          (format "From %s" title)
        (format "From %s · %s" title profile)))
     ((not (equal profile default)) (format "From %s" profile))
     (t nil))))

(defun harness-workspace--reassigned-label (workspace entry)
  "Return the words naming where ENTRY was moved to, or nil.
Nil when the message was never reassigned.  The words name the thread
it went to and who moved it, so a reader can tell a person's decision
from the mediator's."
  (let* ((prov (harness-workspace--entry-provenance entry))
         (moved (plist-get prov :reassigned)))
    (when moved
      (let* ((to (if (consp moved) (plist-get moved :to) moved))
             (by (and (consp moved) (plist-get moved :by)))
             (thread (and to (harness-workspace--thread workspace to)))
             (title (or (and thread (plist-get thread :title)) to)))
        (if (and (stringp by) (not (string-empty-p by)))
            (format "Reassigned to %s · %s" title by)
          (format "Reassigned to %s" title))))))

(defun harness-workspace--entry-origin-thread (workspace entry)
  "Return the thread ENTRY came from in WORKSPACE, or nil."
  (let ((origin (plist-get (harness-workspace--entry-provenance entry) :origin)))
    (and origin (harness-workspace--thread workspace origin))))

;;;; Notifications, one at a time

;; A workspace runs several threads at once, so several replies can be
;; ready within moments of each other.  One notification per reply would
;; stack up in the notification centre and say the same thing twice; one
;; notification that named each thread as it finished would have to be
;; sent before the next thread finished.  So a reply ready waits for the
;; cutoff (`harness-workspace-notification-cutoff') and the workspace
;; sends one notification naming every thread whose reply is ready.  A
;; thread that finishes after the notification goes notifies on its own:
;; its arrival starts a new wait.  A reply whose episode the user is
;; already reading is not news and is left out of the words, though it
;; still counts as ready.

(defvar harness-workspace--notification-timer nil
  "Timer that sends the workspace's grouped notification, or nil.")

(defvar harness-workspace--notification-ready nil
  "Workspace ids whose replies are ready and not yet notified, newest last.")

(defvar harness-workspace--notification-threads nil
  "Alist of workspace id -> thread ids whose replies are ready.")

(defun harness-workspace--queue-notification (workspace thread session-id)
  "Note that THREAD of WORKSPACE has a reply ready from SESSION-ID.
The workspace sends one notification at the cutoff naming every thread
whose reply is ready, not one per reply."
  (let ((id (plist-get workspace :id))
        (tid (plist-get thread :id)))
    (unless (member id harness-workspace--notification-ready)
      (setq harness-workspace--notification-ready
            (append harness-workspace--notification-ready (list id))))
    (let ((threads (assoc id harness-workspace--notification-threads)))
      (if threads
          (unless (member tid (cdr threads))
            (setcdr threads (append (cdr threads) (list tid))))
        (setq harness-workspace--notification-threads
              (append harness-workspace--notification-threads
                      (list (cons id (list tid)))))))
    (ignore session-id)
    (harness-workspace--schedule-notification)))

(defun harness-workspace--schedule-notification ()
  "Send the grouped notification at the cutoff, if one is not scheduled."
  (unless (timerp harness-workspace--notification-timer)
    (setq harness-workspace--notification-timer
          (run-at-time (max 0 harness-workspace-notification-cutoff) nil
                       #'harness-workspace--send-notification))))

(defun harness-workspace--send-notification ()
  "Send one notification naming every workspace thread whose reply is ready."
  (setq harness-workspace--notification-timer nil)
  (let ((ready harness-workspace--notification-ready)
        (threads harness-workspace--notification-threads))
    (setq harness-workspace--notification-ready nil
          harness-workspace--notification-threads nil)
    (when (and ready (harness-method-exists-p 'notification/send))
      (let* ((names nil)
             (count 0)
             (workspace-id nil))
        (dolist (id ready)
          (when-let* ((workspace (gethash id harness-workspace--table)))
            (setq workspace-id (or workspace-id id))
            (dolist (tid (or (cdr (assoc id threads)) nil))
              (when-let* ((thread (harness-workspace--thread workspace tid)))
                (cl-incf count)
                (when (< (length names) 5)
                  (push (or (plist-get thread :title) tid) names))))))
        (when (> count 0)
          (let ((title (if (= count 1)
                           (format "Reply ready: %s" (car names))
                         (format "%d replies ready" count)))
                (body (if (= count 1)
                          "A workspace thread answered."
                        (format "Workspace threads answered: %s"
                                (string-join (nreverse names) ", ")))))
            (harness-catch
             (harness-call-async 'notification/send
                                 (list :title title :body body :urgency 'normal
                                       :source "workspace" :kind "workspace-reply"
                                       :workspace workspace-id)
                                 '(system))
             (lambda (err)
               (harness-log 'warn "workspace: could not notify about %s: %s"
                            workspace-id (harness-error-message err))
               nil))))))))

;;;; Inbox

;; The workspace's inbox is the messages that wait to be sent to a
;; session: what a person or a module queued, and what a running turn has
;; not taken yet.  It is not a second queue.  Each item is the session's
;; own queue item or steering entry, read where it stands, so sending,
;; withdrawing or answering it elsewhere is seen here at once and nothing
;; is copied, moved or cancelled behind the session's back.
;;
;; A scope says which sessions to read: one thread's episode, one session,
;; every thread of the workspace, or every workspace.  An item says where
;; it stands honestly: `queued' in the session's queue, `waiting' when a
;; running turn holds it as steering or behind a gate, and `unavailable'
;; when the session cannot be read -- a stopped harness, an episode that
;; went away -- with no guess about what it would have held.

(defconst harness-workspace--inbox-states '("queued" "waiting" "unavailable")
  "The states an inbox item may be in.")

(defun harness-workspace--session-queue-items (session-id)
  "Return SESSION-ID's queue as inbox items, or nil when it cannot be read.
Each item is (:session :id :thread :title :text :state :at :from :why):
the session's own queue item with where it stands added."
  (when (and (stringp session-id)
             (harness-method-exists-p 'session/get)
             (harness-call 'session/exists-p session-id))
    (let ((record (harness-call 'session/get session-id)))
      (mapcar (lambda (item)
                (list :session session-id
                      :id (plist-get item :id)
                      :text (or (plist-get item :text) "")
                      :at (plist-get item :ts)
                      :from (plist-get item :from)
                      :attachments (plist-get item :attachments)
                      :state "queued"))
              (plist-get record :queue)))))

(defun harness-workspace--session-steering-items (session-id)
  "Return the messages SESSION-ID's running turn has not taken, as inbox items.
Those are the session's own `:steering' entries.  A message a gate holds
says what it waits for in `:why', so a client shows it as waiting rather
than as a message the model already read."
  (when (and (stringp session-id)
             (harness-method-exists-p 'session/get)
             (harness-call 'session/exists-p session-id))
    (let ((record (harness-call 'session/get session-id)))
      (mapcar (lambda (item)
                (append (list :session session-id
                              :id (plist-get item :id)
                              :text (or (plist-get item :text) "")
                              :at (plist-get item :ts)
                              :state "waiting")
                        (and (plist-get item :from) (list :from (plist-get item :from)))
                        (and (plist-get item :why) (list :why (plist-get item :why)))))
              (plist-get record :steering)))))

(defun harness-workspace--inbox-thread-sessions (thread)
  "Return the sessions of THREAD an inbox reads: its live episode.
The episode's own queue and steering are the only places its messages
wait; the thread's older episodes are closed and have none."
  (let ((live (plist-get thread :live)))
    (when (and (stringp live) (harness-call 'session/exists-p live))
      (list live))))

(defun harness-workspace--inbox-items (workspace thread &optional session)
  "Return the inbox items of THREAD in WORKSPACE, or of SESSION.
The items are the session's queue, then the messages its running turn
holds, each with the workspace and thread it waits in and its own
provenance added.  A session that cannot be read says so as one item in
the `unavailable' state rather than reading as empty: an empty inbox and
an unreadable one are different facts, and a person acting on the first
would miss the second."
  (let* ((sessions (if session
                       (list session)
                     (and thread (harness-workspace--inbox-thread-sessions thread))))
         (title (or (and thread (plist-get thread :title)) "Thread"))
         (workspace-name (or (plist-get workspace :name) (plist-get workspace :id)))
         (items nil))
    (dolist (sid sessions)
      (let ((queue (harness-workspace--session-queue-items sid))
            (steering (harness-workspace--session-steering-items sid)))
        (if (and (null queue) (null steering) (not (harness-workspace--session-readable-p sid)))
            (push (list :session sid
                        :workspace (plist-get workspace :id)
                        :workspace-name workspace-name
                        :thread (and thread (plist-get thread :id))
                        :title title :text "" :state "unavailable"
                        :why "Session unavailable" :at (harness-workspace--now))
                  items)
          (dolist (item (append queue steering))
            (let ((copy (copy-sequence item)))
              (setf (plist-get copy :workspace) (plist-get workspace :id)
                    (plist-get copy :workspace-name) workspace-name
                    (plist-get copy :thread) (and thread (plist-get thread :id))
                    (plist-get copy :title) title)
              (push copy items))))))
    (nreverse items)))

(defun harness-workspace--session-readable-p (session-id)
  "Non-nil when SESSION-ID exists and can be read."
  (and (stringp session-id)
       (harness-method-exists-p 'session/exists-p)
       (harness-call 'session/exists-p session-id)))

(defun harness-workspace--inbox-sort (items)
  "Return ITEMS in the order they will be sent: oldest first, then by id.
A message with no time sorts first, so an entry a harness wrote without
one is not pushed behind everything."
  (sort (copy-sequence items)
        (lambda (a b)
          (let ((ta (plist-get a :at)) (tb (plist-get b :at)))
            (cond ((and ta tb (not (equal ta tb))) (< ta tb))
                  ((and ta (null tb)) nil)
                  ((and (null ta) tb) t)
                  (t (string< (format "%s" (plist-get a :id))
                              (format "%s" (plist-get b :id)))))))))

(defun harness-workspace--inbox-counts (items)
  "Return how many ITEMS are in each state, as a plist."
  (list :queued (cl-count-if (lambda (item) (equal "queued" (plist-get item :state))) items)
        :waiting (cl-count-if (lambda (item) (equal "waiting" (plist-get item :state))) items)
        :unavailable (cl-count-if (lambda (item) (equal "unavailable" (plist-get item :state))) items)))

(defun harness-workspace--on-session-deleted (session-id &optional session &rest _)
  "Park a thread whose episode SESSION-ID was deleted.
SESSION is its record, still in the event, because the session is gone
from the store by the time this runs."
  (when-let* ((ext (plist-get session :ext))
              (workspace (gethash (plist-get ext :workspace) harness-workspace--table))
              (thread (harness-workspace--thread workspace (plist-get ext :thread))))
    (when (equal (plist-get thread :live) session-id)
      (harness-workspace--park workspace thread "Its episode was deleted."))))

;;;; Methods

(harness-defmethod workspace/create (&rest plist)
  "Create a workspace.  PLIST may set :name, :root, :graph, :project,
:model, :thinking, :permission-mode, :non-interactive, :skills,
:instructions and :profile.  :graph is the Logseq graph its knowledge
lives in; the default is the configured graph
(`harness-logseq-directory').  :skills is the skill selection its
episodes inherit (see the skills module's `skills/selection'): durable
references such as `OWNER/NAME', `@VERSION' or `#FINGERPRINT', optional
with a leading `?', never a copy of a grant.  It is resolved afresh for
each episode against what the computers the episode may use offer then.
:profile names the surface its messages usually arrive through, such as
\"voice\"; a message that names none takes it, and \"text\" is the
default."
  (harness-workspace--load)
  (let* ((root (file-name-as-directory
                (expand-file-name (or (plist-get plist :root)
                                      harness-workspace-directory))))
         (name (or (plist-get plist :name)
                   (let ((base (file-name-nondirectory (directory-file-name root))))
                     (if (string-empty-p base) "Home" base))))
         (project (or (plist-get plist :project) root))
         (workspace (list :id (harness-workspace--id "w-")
                          :name name
                          :root root
                          :project project
                          :graph (expand-file-name
                                  (or (plist-get plist :graph)
                                      (if (harness-method-exists-p 'logseq/root)
                                          (harness-call 'logseq/root)
                                        "~/logseq")))
                          :instructions (plist-get plist :instructions)
                          :model (plist-get plist :model)
                          :thinking (plist-get plist :thinking)
                          :permission-mode (or (plist-get plist :permission-mode)
                                               harness-workspace-permission-mode)
                          :non-interactive (if (plist-member plist :non-interactive)
                                               (plist-get plist :non-interactive)
                                             harness-workspace-non-interactive)
                          :profile (or (plist-get plist :profile)
                                       harness-workspace--default-profile)
                          :skills (append (plist-get plist :skills) nil)
                          :threads nil
                          :last-thread nil
                          :created (harness-workspace--now)
                          :updated (harness-workspace--now))))
    (harness-ensure-directory root)
    (harness-workspace--save workspace)))

(harness-defmethod workspace/list (&optional filter)
  "List workspaces, newest last.  FILTER may name a root."
  (harness-workspace--load)
  (let ((all (mapcar #'harness-workspace--view
                     (hash-table-values harness-workspace--table))))
    (when-let* ((root (plist-get filter :root)))
      (setq all (cl-remove-if-not
                 (lambda (workspace) (equal (plist-get workspace :root) root)) all)))
    (sort all (lambda (a b) (string< (or (plist-get a :name) "")
                                     (or (plist-get b :name) ""))))))

(harness-defmethod workspace/get (id)
  "Return workspace ID with its threads."
  (harness-workspace--view (harness-workspace--get id)))

(harness-defmethod workspace/update (id &rest plist)
  "Change workspace ID.  PLIST may set its name, root, project, defaults
or instructions."
  (let* ((workspace (harness-workspace--get id))
         (root (plist-get plist :root)))
    (dolist (key '(:name :project :model :thinking :permission-mode
                   :non-interactive :instructions :profile :skills))
      (when (plist-member plist key)
        (setf (plist-get workspace key) (plist-get plist key))))
    (when root
      (setf (plist-get workspace :root)
            (file-name-as-directory (expand-file-name root)))
      (harness-ensure-directory (plist-get workspace :root)))
    (when-let* ((graph (plist-get plist :graph)))
      (setf (plist-get workspace :graph)
            (file-name-as-directory (expand-file-name graph))))
    (harness-workspace--save workspace)))

(harness-defmethod workspace/delete (id &optional delete-sessions delete-graph)
  "Delete workspace ID.  With DELETE-SESSIONS close its episodes too.
The Logseq graph is the user's and is never deleted, so DELETE-GRAPH
changes nothing; the pages the workspace wrote stay in the graph."
  (let ((workspace (harness-workspace--get id)))
    (when (harness-json-true-p delete-sessions)
      (dolist (thread (plist-get workspace :threads))
        (dolist (session (plist-get thread :episodes))
          (when (and (stringp session)
                     (harness-call 'session/exists-p session)
                     (harness-method-exists-p 'session/deactivate))
            (ignore-errors (harness-call 'session/deactivate session))))))
    (harness-call 'store/delete (harness-workspace--file id))
    (harness-call 'store/delete (harness-workspace--timeline-file id))
    (remhash id harness-workspace--table)
    (harness-emit 'workspace/deleted id)
    (list :deleted id :sessions (and (harness-json-true-p delete-sessions) t)
          :graph (and (harness-json-true-p delete-graph) t))))

(harness-defmethod workspace/open (id &optional thread)
  "Return workspace ID and the thread a client should show, creating no episode.
THREAD, when given, is the thread the person asked for; a thread the
workspace does not hold signals, so a client shows a mistake rather than
opening the wrong conversation.  Nothing is started, copied or moved: a
thread with no live episode stays without one until a message arrives."
  (let* ((workspace (harness-workspace--get id))
         (wanted (or thread (plist-get workspace :last-thread)))
         (found (and wanted (harness-workspace--thread workspace wanted))))
    (when (and thread (null found))
      (signal 'harness-error (list (format "No thread %s" thread))))
    (list :workspace (harness-workspace--view workspace)
          :thread found
          :episode (and found (plist-get found :live)))))

(harness-defmethod workspace/status (id)
  "Return what the workspace ID knows about its state."
  (let* ((workspace (harness-workspace--get id))
         (threads (plist-get workspace :threads))
         (live (cl-count-if (lambda (thread) (plist-get thread :live)) threads))
         (knowledge (when (harness-method-exists-p 'knowledge/status)
                      (condition-case err
                          (harness-call 'knowledge/status id)
                        (error
                         (harness-log 'warn "workspace: knowledge status failed: %s"
                                      (harness-error-message err))
                         nil))))
         (box (when (harness-method-exists-p 'workspace/box/status)
                (condition-case err
                    (harness-call 'workspace/box/status id)
                  (error
                   (harness-log 'warn "workspace: box status failed: %s"
                                (harness-error-message err))
                   nil)))))
    (list :id id :name (plist-get workspace :name)
          :threads (length threads) :live live
          :last-thread (plist-get workspace :last-thread)
          :knowledge knowledge :box box)))

(harness-defmethod workspace/resources/status (id)
  "Return workspace ID's browser, wallet, access and credential resources.
The browser section is the box's own Firefox profile when the computer
runs: sites, cookie counts, saved site sessions, storage and cache
sizes, never a cookie value or a password.  The wallet stays
unavailable because no payment broker is part of this harness.  The
credentials are the harness's declared secrets, through the
secret-sandbox module.  The answer is metadata only."
  (harness-workspace--get id)
  (let* ((module (harness-method-exists-p 'secret-sandbox/secrets))
         (secrets (when module
                    (condition-case err
                        (harness-call 'secret-sandbox/secrets)
                      (error
                       (harness-log 'warn "workspace: listing secrets failed: %s"
                                    (harness-error-message err))
                       nil))))
         (secret-status (when (harness-method-exists-p 'secret-sandbox/status)
                          (condition-case nil
                              (harness-call 'secret-sandbox/status)
                            (error nil))))
         (box (when (harness-method-exists-p 'workspace/box/status)
                (condition-case err
                    (harness-call 'workspace/box/status id)
                  (error
                   (harness-log 'warn "workspace: box status failed: %s"
                                (harness-error-message err))
                   nil))))
         (box-running (and box (harness-json-true-p (plist-get box :running))))
         (browser (and box-running
                       (harness-method-exists-p 'workspace/box/browser)
                       (condition-case err
                           (harness-call 'workspace/box/browser id)
                         (error
                          (harness-log 'warn "workspace: browser resources failed: %s"
                                       (harness-error-message err))
                          nil))))
         (box-reason (or (plist-get box :reason)
                         (and (not box-running)
                              (list :code "box-not-running"
                                    :text "workspace computer not running"))))
         (browser-reason (cond (browser nil)
                               (box-running
                                (list :code "browser-unavailable"
                                      :text "browser profile unavailable"))
                               (t box-reason)))
         (credentials
          (mapcar (lambda (secret)
                    (list :label (plist-get secret :label)
                          :fingerprint (plist-get secret :fingerprint)
                          :usable (and (plist-get secret :usable) t)
                          :error (plist-get secret :error)
                          :last-use (plist-get secret :last-use)))
                  secrets)))
    (list :workspace id
          :status (cond (browser "ready")
                        (module "ready")
                        (t "unavailable"))
          :reason (cond (browser nil)
                        (module nil)
                        (t (or (plist-get box-reason :code) "box-not-running")))
          :metadata-only t
          :box box
          :browser browser
          :wallet nil
          :access nil
          :audit nil
          :browser-status (if browser "ready" "unavailable")
          :browser-reason browser-reason
          :wallet-status "unavailable"
          :wallet-reason (list :code "wallet-unavailable"
                               :text "no payment broker")
          :credentials credentials
          :credentials-status
          (list :status (cond ((null secret-status) "unavailable")
                              ((plist-get secret-status :locked) "ready")
                              (t "needs-approval"))
                :mask (plist-get secret-status :mask)
                :locked (plist-get secret-status :locked)
                :why (plist-get secret-status :why)
                :count (length secrets)))))

(harness-defmethod workspace/wallet/authorization/create (id &rest plist)
  "Ask for a bounded purchase authorization for workspace ID.
PLIST names the card reference, amount, currency, cap kind, merchant
scope, expiry and fee policy.  The payment broker is staged: nothing
is created, the answer is `:status \"unavailable\"\' with `:reason
\"wallet-unavailable\"\' and `:changed nil', and PLIST is never echoed back,
because it may name a card reference."
  (harness-workspace--get id)
  (ignore plist)
  (list :workspace id :status "unavailable" :reason "wallet-unavailable"
        :metadata-only t :changed nil
        :browser nil :wallet nil :access nil :audit nil))

(harness-defmethod workspace/wallet/authorization/revoke (id authorization)
  "Revoke purchase AUTHORIZATION in workspace ID and return the resources.
The payment broker is staged: nothing is revoked, the answer is
`:status \"unavailable\"\' with `:reason \"wallet-unavailable\"\' and `:changed
nil\'."
  (harness-workspace--get id)
  (unless (and (stringp authorization) (not (harness-string-blank-p authorization)))
    (signal 'harness-error (list "Revoking needs an authorization id")))
  (list :workspace id :status "unavailable" :reason "wallet-unavailable"
        :metadata-only t :authorization authorization :changed nil
        :browser nil :wallet nil :access nil :audit nil))

(harness-defmethod workspace/wallet/purchase/decide (id purchase decision)
  "Decide a proposed PURCHASE in workspace ID: allow or deny it.
DECISION is \"allow\" or \"deny\".  The payment broker is staged:
nothing is charged or declined, the answer is `:status
\"unavailable\"\' with `:reason \"wallet-unavailable\"\' and `:changed nil'."
  (harness-workspace--get id)
  (unless (member decision '("allow" "deny"))
    (signal 'harness-error (list (format "Unknown purchase decision: %s" decision))))
  (list :workspace id :status "unavailable" :reason "wallet-unavailable"
        :metadata-only t :purchase purchase :decision decision :changed nil
        :browser nil :wallet nil :access nil :audit nil))

(harness-defmethod workspace/prompt (id text &optional opts)
  "Send TEXT to workspace ID and return the turn's promise.
OPTS may name `:thread' (the thread a client has selected: a
preference), `:force-thread' (a binding: that thread whatever the
message says), `:force-continue', `:force-new', `:command',
`:channel', `:profile' and `:origin'.  The workspace routes TEXT to the
thread's live episode, starts a new episode in the thread, or starts a
new thread.  A new episode is given a brief first.  `:profile' names the
surface the words arrived through, such as \"voice\"; `:origin' names the
thread the person addressed the message to when a client already knows
it.  Both are written to the message's node and its timeline entry as
provenance, so a message the router puts in another thread still says
where it began."
  (unless (and (stringp text) (not (string-blank-p text)))
    (signal 'harness-error (list "Empty workspace message")))
  (let* ((workspace (harness-workspace--get id))
         (clean (replace-regexp-in-string
                 "\\`/\\(?:new\\|continue\\)\\(?:[ \t\n]+\\|\\'\\)" "" text))
         (clean (if (string-blank-p clean) "New thread" clean))
         (route (harness-workspace--route workspace text opts))
         (thread (car route))
         (action (cadr route))
         (why (nth 2 route)))
    (when (eq action 'new)
      (setq thread (harness-workspace--new-thread
                    workspace (harness-workspace--topic-title clean))))
    (let* ((live (plist-get thread :live))
           (long (and live (harness-workspace--episode-too-long-p live)))
           (new-episode-p (or (eq action 'new) (eq action 'revive) (null live))))
      (when (and live (eq action 'revive))
        (harness-workspace--park workspace thread "Continued in a new episode."))
      (unless (plist-get thread :live)
        (let ((reason (cond ((eq action 'new) 'new-thread)
                            (long 'long-context)
                            ((plist-get thread :episodes) 'revived)
                            (t 'new-thread))))
          (harness-workspace--start-episode workspace thread reason)))
      (let ((session (plist-get thread :live)))
        (setf (plist-get workspace :last-thread) (plist-get thread :id))
        (harness-workspace--save workspace)
        (when (and new-episode-p (plist-get thread :episodes))
          (let ((brief (harness-workspace--brief workspace thread clean)))
            (harness-call 'session/append
                          session
                          (list :kind 'user :content brief
                                :meta (list :from (harness-sender-system "workspace")
                                            :workspace-brief t)))
            (harness-workspace--append
             workspace
             (list :kind 'brief
                   :thread (plist-get thread :id)
                   :episode session
                   :why why
                   :text brief
                   :tokens (ceiling (/ (length brief) 4.0))))))
        (harness-emit 'workspace/thread-changed id thread)
        ;; The message's provenance travels on its node: the thread it was
        ;; addressed to, the thread whose episode answers it, and the
        ;; profile it arrived through.  The timeline reads it back, and so
        ;; does a client that opens the episode's transcript.
        (harness-call 'agent/prompt session clean
                      (list :meta (harness-workspace--provenance workspace thread opts)))))))

(harness-defmethod workspace/cancel (id &optional thread)
  "Cancel the live turn of workspace ID, or of THREAD."
  (let* ((workspace (harness-workspace--get id))
         (thread (if thread
                     (harness-workspace--thread workspace thread)
                   (and (plist-get workspace :last-thread)
                        (harness-workspace--thread workspace (plist-get workspace :last-thread))))))
    (when-let* ((session (and thread (plist-get thread :live))))
      (ignore-errors (harness-call 'agent/cancel session)))
    (list :cancelled (and thread (plist-get thread :live)))))

(harness-defmethod workspace/timeline (id &optional opts)
  "Return timeline entries of workspace ID, oldest first.
OPTS may name `:limit', `:before' (an index), `:thread', `:kinds'."
  (let* ((entries (harness-workspace--timeline-internal id))
         (thread (plist-get opts :thread))
         (kinds (plist-get opts :kinds))
         (limit (or (plist-get opts :limit) 200))
         (before (plist-get opts :before)))
    (when thread
      (let* ((workspace (harness-workspace--get id))
             (found (harness-workspace--thread workspace thread))
             (related (cons thread (plist-get found :merged-from))))
        (setq entries (cl-remove-if-not
                       (lambda (entry) (member (plist-get entry :thread) related))
                       entries))))
    (when kinds
      (let ((wanted (mapcar (lambda (kind) (if (symbolp kind) kind (intern kind))) kinds)))
        (setq entries (cl-remove-if-not
                       (lambda (entry) (memq (harness-workspace--entry-kind entry) wanted))
                       entries))))
    (let* ((end (if before (min before (length entries)) (length entries)))
           (page (last (cl-subseq entries 0 end) (max 0 (min limit end)))))
      (harness-workspace--resolve-entries page))))

(harness-defmethod workspace/inbox (id &optional opts)
  "Return the messages that wait to be sent in workspace ID.
The inbox is read where the messages stand -- each session's own queue
and the messages its running turn has not taken -- so sending,
withdrawing or answering one elsewhere is seen here at once.  Nothing
is copied into a second queue.

OPTS may name `:scope', `:thread' and `:session':

  \"workspace\"  every thread of the workspace; the default
  \"thread\"     the thread `:thread' names, else the workspace's last
  \"session\"    the session `:session' names, or the one `:thread' has
  \"all\"        every workspace's threads as well

Each item is (:session :workspace :workspace-name :thread :title :text
:at :from :why :state): `:state' is \"queued\" in the session's queue,
\"waiting\" for a message a running turn has not taken, or \"unavailable\"
when the session cannot be read.  `:workspace' and `:workspace-name'
name the workspace the message waits in, so a row of the \"all\" scope
says which workspace it belongs to as well as which thread.  The answer
is (:workspace :scope :items :counts :threads :revision): `:threads'
names each thread with items and its counts, and `:revision' moves with
every change a client should notice.  `:name' names the workspace itself,
so a header says which workspace's inbox it shows."
  (let* ((workspace (harness-workspace--get id))
         (scope (or (plist-get opts :scope) "workspace"))
         (session (plist-get opts :session))
         (thread-id (plist-get opts :thread))
         (threads (plist-get workspace :threads))
         (items nil)
         (groups nil))
    (cond
     ((equal scope "session")
      (setq items (harness-workspace--inbox-items workspace nil session)))
     ((equal scope "thread")
      (let ((thread (if thread-id
                        (harness-workspace--thread workspace thread-id)
                      (and (plist-get workspace :last-thread)
                           (harness-workspace--thread workspace (plist-get workspace :last-thread))))))
        (setq items (harness-workspace--inbox-items workspace thread session))))
     ((equal scope "all")
      (dolist (other (hash-table-values harness-workspace--table))
        (dolist (thread (plist-get other :threads))
          (let ((found (harness-workspace--inbox-items other thread)))
            (when found
              (push (list :workspace (plist-get other :id)
                          :name (plist-get other :name)
                          :thread (plist-get thread :id)
                          :title (plist-get thread :title)
                          :items found
                          :counts (harness-workspace--inbox-counts found))
                    groups)
              (setq items (append items found)))))))
     (t
      (dolist (thread threads)
        (let ((found (harness-workspace--inbox-items workspace thread)))
          (when found
            (push (list :workspace id :name (plist-get workspace :name)
                        :thread (plist-get thread :id)
                        :title (plist-get thread :title)
                        :items found
                        :counts (harness-workspace--inbox-counts found))
                  groups)
            (setq items (append items found)))))))
    (let ((items (harness-workspace--inbox-sort items)))
      (list :workspace id
            :name (or (plist-get workspace :name) id)
            :scope scope
            :items items
            :counts (harness-workspace--inbox-counts items)
            :threads (nreverse groups)
            :revision (or (plist-get workspace :inbox-revision) 0)))))

(defun harness-workspace--bump-inbox (workspace)
  "Move WORKSPACE's inbox revision, so a client knows its view is old.
The revision is kept with the workspace record: a client compares what
it drew with what the harness answers, and drops a view that is older."
  (setf (plist-get workspace :inbox-revision)
        (1+ (or (plist-get workspace :inbox-revision) 0)))
  workspace)

(defun harness-workspace--on-session-queue-changed (session-id &rest _)
  "Announce a workspace inbox change when SESSION-ID's queue or steering changed.
A session's queue is where its messages wait; a workspace whose episode
it is reads that queue as its inbox, so a change there changes what waits
to be sent in the workspace, and a client showing the inbox redraws."
  (when-let* ((ext (harness-workspace--episode-p session-id))
              (workspace (gethash (plist-get ext :workspace) harness-workspace--table)))
    (harness-workspace--bump-inbox workspace)
    (harness-emit 'workspace/inbox-changed (plist-get workspace :id))))

(defun harness-workspace--find-queue-item (workspace thread qid)
  "Return (SESSION . ITEM) for queued item QID in THREAD, or nil.
WORKSPACE is the workspace the thread belongs to; a thread the
workspace no longer holds has nothing to find."
  (when (and thread (harness-workspace--thread workspace (plist-get thread :id)))
    (cl-loop for sid in (harness-workspace--inbox-thread-sessions thread)
             for found = (cl-find qid (harness-workspace--session-queue-items sid)
                                 :key (lambda (item) (plist-get item :id)) :test #'equal)
             when found return (cons sid found))))

(defun harness-workspace--find-steering-item (workspace thread node)
  "Return (SESSION . ITEM) for steering message NODE in THREAD, or nil.
WORKSPACE is the workspace the thread belongs to; a thread the
workspace no longer holds has nothing to find."
  (when (and thread (harness-workspace--thread workspace (plist-get thread :id)))
    (cl-loop for sid in (harness-workspace--inbox-thread-sessions thread)
             for found = (cl-find node (harness-workspace--session-steering-items sid)
                                 :key (lambda (item) (plist-get item :id)) :test #'equal)
             when found return (cons sid found))))

(defun harness-workspace--delivered-p (session-id node)
  "Non-nil when NODE is a message SESSION-ID's transcript already holds.
That is the honest test of whether a reassignment can still move the
message: a node in the transcript was read by the model, so nothing can
retract it, while a queued or steering message has not been."
  (and (stringp session-id) (stringp node)
       (harness-workspace--session-readable-p session-id)
       (when (harness-method-exists-p 'session/node)
         (condition-case nil
             (let ((found (harness-call 'session/node session-id node)))
               (and found
                    (equal "user" (format "%s" (plist-get found :kind)))
                    t))
           (error nil)))))

(defun harness-workspace--reassign-target (workspace to)
  "Return the thread TO names in WORKSPACE, or signal.
TO is a thread id.  A target that does not exist is a mistake a client
can show, not a message quietly lost, so this signals."
  (let ((thread (and (stringp to) (harness-workspace--thread workspace to))))
    (unless thread
      (signal 'harness-error (list (format "No thread %s" to))))
    thread))

(defun harness-workspace--last-user-entry (workspace thread)
  "Return the last user message entry of THREAD in WORKSPACE, or nil."
  (car (last (cl-remove-if-not
              (lambda (entry)
                (and (eq (harness-workspace--entry-kind entry) 'message)
                     (eq (harness-workspace--entry-role entry) 'user)
                     (equal (plist-get entry :thread) (plist-get thread :id))))
              (harness-workspace--timeline-internal (plist-get workspace :id))))))

(defun harness-workspace--reassign-session (workspace target)
  "Return the session that takes a message reassigned to TARGET.
TARGET is a thread of WORKSPACE.  Its live episode is that session;
a thread with none starts one, as a message to it would, so the
message is queued somewhere real instead of being reported as queued
with no session to queue it in."
  (or (plist-get target :live)
      (harness-workspace--start-episode workspace target 'revived)))
(defun harness-workspace--forward-message (workspace from-thread to-thread text opts)
  "Send TEXT to TO-THREAD of WORKSPACE, named as coming from FROM-THREAD.
The message is the user's, marked with the origin thread and profile so
the target's transcript says where it began; it starts a turn in the
target's episode as any workspace message does.  Return the session id.

The target's timeline entry keeps the origin, not the destination: the
thread the words were first addressed to stays `:origin', TO-THREAD is
`:handling', and `:reassigned' says who moved it and where to.  A reader
therefore sees both where a message began and who answers it, and the
original thread's own entry is left as it was."
  (let* ((profile (or (plist-get opts :profile)
                      (plist-get opts :origin-profile)
                      (harness-workspace--profile workspace from-thread)))
         (origin (or (plist-get opts :origin)
                     (and from-thread (plist-get from-thread :id))))
         (origin-title (and from-thread (plist-get from-thread :title)))
         (by (or (plist-get opts :by) "mediator"))
         (note (format "Reassigned from %s%s\n\n"
                       (or origin-title "another thread")
                       (if (and profile (not (equal profile harness-workspace--default-profile)))
                           (format " (%s)" profile)
                         "")))
         (body (concat note text))
         (meta (append (list :profile profile
                             :origin origin
                             :handling (plist-get to-thread :id))
                       (and (plist-get opts :origin-title)
                            (list :origin-title (plist-get opts :origin-title)))
                       (list :reassigned (list :from origin
                                               :to (plist-get to-thread :id)
                                               :by by)))))
    ;; The target thread's episode starts when it has none, as a message does.
    (unless (plist-get to-thread :live)
      (harness-workspace--start-episode workspace to-thread 'revived))
    (let ((session (plist-get to-thread :live)))
      (harness-call 'agent/prompt session body
                    (list :from (harness-sender-system "workspace")
                          :meta meta))
      session)))

(defun harness-workspace--reassign-reference (workspace message &optional opts)
  "Return the message MESSAGE names in WORKSPACE as a plist, or nil.
MESSAGE is a plist naming `:node' or `:queue', the string \"last\" for
the last user message the workspace shows, or a text.  The answer is
\(:node NODE :queue QID :text TEXT :thread THREAD :session SESSION):
the thread the message stands in and the session whose queue or turn
holds it when it does.  A reference that names a node the workspace no
longer shows is answered from what its timeline kept, so a message the
user still sees can be moved.  A message nothing holds answers nil."
  (let* ((last (and (equal message "last") t))
         (node (and (consp message) (plist-get message :node)))
         (qid (and (consp message) (plist-get message :queue)))
         (text (cond ((and (stringp message) (not last)) message)
                     ((and (consp message) (stringp (plist-get message :text)))
                      (plist-get message :text))))
         (thread-id (or (and (consp message) (plist-get message :thread))
                        (and last (plist-get opts :thread))
                        (plist-get workspace :last-thread)))
         (thread (and thread-id (harness-workspace--thread workspace thread-id)))
         (entry (cond
                 (last (harness-workspace--last-user-entry workspace thread))
                 ((and node thread)
                  (cl-find node (harness-workspace--timeline-internal (plist-get workspace :id))
                           :key (lambda (item) (plist-get item :node)) :test #'equal))
                 (t nil)))
         (found (cond
                 ((and node thread) (harness-workspace--find-steering-item workspace thread node))
                 (t nil)))
         (session (or (car-safe found) (and entry (plist-get entry :episode))
                      (plist-get opts :session)))
         (text (or text (and entry (harness-workspace--entry-text entry)))))
    (cond
     ((and (stringp text) (not (string-blank-p text))
           (or node qid entry last))
      (list :node (or node (and entry (plist-get entry :node)))
            :queue qid
            :text text
            :thread (or (and entry (plist-get entry :thread)) thread-id)
            :session session))
     (t nil))))

(harness-defmethod workspace/reassign (id message to &optional opts)
  "Reassign MESSAGE to thread TO in workspace ID; return what happened.
MESSAGE is a message reference and TO the thread id that should handle
it.  A reference is a plist with `:node' (the message's node id) or
`:queue' (a queued item's id), the string \"last\" for the last user
message the workspace shows, or the text itself when neither is given.

The message is moved when nothing has read it yet: a queued item leaves
its session's queue and is queued in the target's, so the model never
sees it in the wrong thread.  A message a running turn holds as
steering is withdrawn and queued there too.  A message the transcript
already holds cannot be retracted, so its text is forwarded to the
target as a message that names the thread it came from and its own
outcome stays visible in the origin thread's transcript: nothing is
deleted, rewritten or claimed to have moved.

OPTS may name `:by' (who moved it, \"mediator\" by default) and
`:profile' (the surface it arrived through).  The answer is (:status
:thread :session :node :text :origin :delivery): `:status' is
\"queued\", \"waiting\", \"forwarded\", \"repeated\", \"stale\" or
\"unreachable\"; `:delivery' is \"queued\", \"delivered\" or
\"uncertain\" and says what became of the original message.  Repeating
the same reassignment is a no-op that returns the first answer with
`:status' \"repeated\": a second client acting on the same message does
not send it twice."
  (let* ((workspace (harness-workspace--get id))
         (target (harness-workspace--reassign-target workspace to))
         (ref (harness-workspace--reassign-reference workspace message opts))
         (origin (plist-get ref :thread))
         (origin-thread (and origin (harness-workspace--thread workspace origin)))
         (node (plist-get ref :node))
         (qid (plist-get ref :queue))
         (text (plist-get ref :text))
         (key (harness-workspace--reassign-key id origin node qid text (plist-get target :id))))
    (cond
     ((null ref)
      (list :status "stale" :thread to :session nil :text nil
            :delivery "uncertain" :why "No message" :key key))
     ((and origin (equal origin (plist-get target :id)))
      (list :status "stale" :thread to :session (plist-get target :live)
            :node node :text text :origin origin :delivery "uncertain"
            :why "Already there" :key key))
     (t
      (let ((done (harness-workspace--reassignment-record id key)))
        (if done
            (append (plist-put (copy-sequence done) :status "repeated")
                    (list :key key))
          (harness-workspace--do-reassign workspace target origin-thread ref key opts)))))))

(defun harness-workspace--reassign-key (id origin node qid text target)
  "Return the key naming one reassignment in workspace ID.
The same message moved to the same target is one reassignment, however
many clients ask: the key is the message's node or queue id when it has
one, else a digest of its text and origin.  The target is part of the
key, because moving the same message to another thread is a different
reassignment and has to happen, not answer from the first one's record."
  (let ((what (cond ((and (stringp node) (not (string-empty-p node))) node)
                    ((and (stringp qid) (not (string-empty-p qid))) qid)
                    ((stringp text) (secure-hash 'sha1 (format "%s\n%s" (or origin "") text))))))
    (format "%s/%s/%s/%s" id (or origin "?") what (or target "?"))))

(defun harness-workspace--reassignment-record (id key)
  "Return the answer of the reassignment KEY of workspace ID, or nil.
A record is kept in the workspace's own state so a repeated request
finds it, and the timeline keeps the same answer as an entry."
  (let ((workspace (harness-workspace--get id)))
    (cdr (assoc key (plist-get workspace :reassignments)))))

(defconst harness-workspace--reassignments-kept 50
  "Reassignments a workspace remembers, so a repeat finds its answer.
A record is what a second client's request for the same message is
answered with; past this many, the oldest is forgotten, and a repeat
of it is resolved from where the message stands now.")

(defun harness-workspace--record-reassignment (workspace key result)
  "Keep RESULT under KEY in WORKSPACE, so a repeated request finds it.
The newest `harness-workspace--reassignments-kept' records are kept, so
a long-lived workspace does not grow a record per message it ever
moved."
  (let* ((kept (cl-remove-if (lambda (cell) (equal (car cell) key))
                              (plist-get workspace :reassignments)))
         (kept (last (append kept (list (cons key result)))
                     harness-workspace--reassignments-kept)))
    (setf (plist-get workspace :reassignments) kept)
    (harness-workspace--save workspace)))

(defun harness-workspace--do-reassign (workspace target origin-thread ref key opts)
  "Move or forward the message REF to TARGET in WORKSPACE; return the answer.
REF is the reference `workspace/reassign' resolved, ORIGIN-THREAD its
thread when it still exists, and KEY names the request.  See
`workspace/reassign' for the states."
  (let* ((node (plist-get ref :node))
         (qid (plist-get ref :queue))
         (text (plist-get ref :text))
         (origin (plist-get ref :thread))
         (origin-session (plist-get ref :session))
         (by (or (plist-get opts :by) "mediator"))
         (target-session (plist-get target :live))
         (delivered (and node (harness-workspace--delivered-p origin-session node)))
         (queue-found (and (not delivered)
                           origin-thread
                           (or (and qid (harness-workspace--find-queue-item workspace origin-thread qid))
                               (and node (harness-workspace--find-queue-item workspace origin-thread node)))))
         (steering-found (and (not delivered) (not queue-found)
                              origin-thread
                              (and node (harness-workspace--find-steering-item workspace origin-thread node))))
         (result nil))
    (cond
     ;; The model already read it: the transcript cannot be rewritten.
     (delivered
      (let ((session (harness-workspace--forward-message workspace origin-thread target text opts)))
        (setq result (list :status "forwarded" :thread (plist-get target :id)
                           :session session :node node :text text :origin origin
                           :by by :delivery "delivered"
                           :why "Already delivered"))))
     ;; A queued message moves: out of the origin's queue, into the target's.
     (queue-found
      (let* ((origin-sid (car queue-found))
             ;; The item's own id, which a reference by node does not name.
             (moved (plist-get (cdr queue-found) :id))
             (target-sid (harness-workspace--reassign-session workspace target)))
        (harness-call 'session/queue-remove origin-sid moved)
        (harness-call 'session/queue target-sid text nil
                      (harness-sender-system "workspace"))
        (setq result (list :status "queued" :thread (plist-get target :id)
                           :session target-sid :node node :queue moved :text text
                           :origin origin :by by :delivery "queued"
                           :why "Not yet delivered"))))
     ;; A message the running turn holds goes the same way.
     (steering-found
      (let ((origin-sid (car steering-found)))
        (condition-case err
            (let ((target-sid (harness-workspace--reassign-session workspace target)))
              (harness-call 'agent/withdraw origin-sid node)
              (harness-call 'session/queue target-sid text nil
                            (harness-sender-system "workspace"))
              (setq result (list :status "queued" :thread (plist-get target :id)
                                 :session target-sid :node node :text text
                                 :origin origin :by by :delivery "queued"
                                 :why "Held by a running turn")))
          (error
           (setq result (list :status "forwarded" :thread (plist-get target :id)
                              :session (harness-workspace--forward-message
                                        workspace origin-thread target text opts)
                              :node node :text text :origin origin :by by
                              :delivery "uncertain"
                              :why (harness-error-message err)))))))
     ;; Nothing holds it: the message is gone from every place it could wait.
     (t
      (setq result (list :status "stale" :thread (plist-get target :id)
                         :session target-session :node node :text text
                         :origin origin :by by :delivery "uncertain"
                         :why "No longer waiting"))))
    ;; The timeline keeps the move, so the target and the user read it later.
    (when (member (plist-get result :status) '("queued" "forwarded"))
      (let ((entry (harness-workspace--append
                    workspace
                    (list :kind 'reassignment
                          :thread (plist-get target :id)
                          :from-thread origin
                          :origin origin
                          :handling (plist-get target :id)
                          :profile (or (plist-get opts :profile)
                                       (harness-workspace--profile workspace origin-thread))
                          :by by
                          :status (plist-get result :status)
                          :delivery (plist-get result :delivery)
                          :node node
                          :queue qid
                          :text text))))
        (setq result (plist-put result :entry (plist-get entry :at)))))
    (harness-workspace--record-reassignment workspace key result)
    (harness-emit 'workspace/reassigned (plist-get workspace :id)
                  (plist-get result :thread) result)
    result))

(harness-defmethod workspace/threads (id &optional filter)
  "Return the threads of workspace ID, newest first."
  (let* ((workspace (harness-workspace--get id))
         (threads (plist-get (harness-workspace--view workspace) :threads)))
    (when-let* ((status (plist-get filter :status)))
      (setq threads (cl-remove-if-not
                     (lambda (thread) (equal (plist-get thread :state) status)) threads)))
    threads))

(harness-defmethod workspace/thread (id thread)
  "Return THREAD of workspace ID with its episodes."
  (let ((found (harness-workspace--thread (harness-workspace--get id) thread)))
    (unless found (signal 'harness-error (list (format "No thread %s" thread))))
    found))

(harness-defmethod workspace/thread/create (id title &optional plist)
  "Create a thread TITLE in workspace ID and return it."
  (let* ((workspace (harness-workspace--get id))
         (thread (harness-workspace--new-thread workspace title (plist-get plist :project))))
    (when (plist-member plist :pinned)
      (setf (plist-get thread :pinned) (plist-get plist :pinned)))
    (harness-workspace--save workspace)
    (harness-emit 'workspace/thread-changed id thread)
    thread))

(harness-defmethod workspace/thread/update (id thread &rest plist)
  "Change THREAD of workspace ID."
  (let* ((workspace (harness-workspace--get id))
         (found (harness-workspace--thread workspace thread)))
    (unless found (signal 'harness-error (list (format "No thread %s" thread))))
    (dolist (key '(:title :status :pinned :project :summary :next-action))
      (when (plist-member plist key)
        (setf (plist-get found key) (plist-get plist key))))
    (harness-workspace--put-thread workspace found)
    (harness-workspace--knowledge-touch workspace found)
    (harness-workspace--save workspace)
    (harness-emit 'workspace/thread-changed id found)
    found))

(harness-defmethod workspace/thread/merge (id from into)
  "Merge thread FROM of workspace ID into thread INTO.
The timeline is not rewritten: FROM is parked, marked `merged`, and
names INTO, so the timeline of INTO includes both threads' entries and
the old episode stays whole."
  (let* ((workspace (harness-workspace--get id))
         (source (harness-workspace--thread workspace from))
         (target (harness-workspace--thread workspace into)))
    (unless source (signal 'harness-error (list (format "No thread %s" from))))
    (unless target (signal 'harness-error (list (format "No thread %s" into))))
    (when (equal from into)
      (signal 'harness-error (list "A thread cannot merge into itself")))
    (if (equal (plist-get source :merged-into) into)
        target
      (when (plist-get source :live)
        (harness-workspace--park workspace source
                                 (format "Merged into %s." (or (plist-get target :title) into))))
      (setf (plist-get source :status) "merged"
            (plist-get source :merged-into) into
            (plist-get source :state) "merged")
      (setf (plist-get target :merged-from)
            (append (plist-get target :merged-from) (list from)))
      (harness-workspace--put-thread workspace source)
      (harness-workspace--put-thread workspace target)
      (harness-workspace--save workspace)
      (harness-emit 'workspace/thread-changed id source)
      (harness-emit 'workspace/thread-changed id target)
      target)))

(harness-defmethod workspace/thread/park (id thread)
  "Park THREAD of workspace ID at the next turn boundary."
  (let* ((workspace (harness-workspace--get id))
         (found (harness-workspace--thread workspace thread)))
    (unless found (signal 'harness-error (list (format "No thread %s" thread))))
    (harness-workspace--park workspace found)
    found))

(harness-defmethod workspace/thread/revive (id thread &optional opts)
  "Start a new episode of THREAD in workspace ID."
  (ignore opts)
  (let* ((workspace (harness-workspace--get id))
         (found (harness-workspace--thread workspace thread)))
    (unless found (signal 'harness-error (list (format "No thread %s" thread))))
    (when (plist-get found :live)
      (harness-workspace--park workspace found "Continued in a new episode."))
    (harness-workspace--start-episode workspace found 'revived)))

(harness-defmethod workspace/thread/delete (id thread &optional delete-sessions)
  "Remove THREAD from workspace ID; its page and episodes stay by default."
  (let* ((workspace (harness-workspace--get id))
         (found (harness-workspace--thread workspace thread)))
    (unless found (signal 'harness-error (list (format "No thread %s" thread))))
    (when (harness-json-true-p delete-sessions)
      (dolist (session (plist-get found :episodes))
        (when (and (stringp session) (harness-call 'session/exists-p session)
                   (harness-method-exists-p 'session/deactivate))
          (ignore-errors (harness-call 'session/deactivate session)))))
    (setf (plist-get workspace :threads)
          (cl-remove-if (lambda (item) (equal (plist-get item :id) thread))
                        (plist-get workspace :threads)))
    (when (equal (plist-get workspace :last-thread) thread)
      (setf (plist-get workspace :last-thread) nil))
    (harness-workspace--save workspace)
    (harness-emit 'workspace/thread-changed id (list :id thread :deleted t))
    (list :deleted thread)))

(harness-defmethod workspace/episode (id thread &optional episode)
  "Return the session and state of THREAD's episode in workspace ID."
  (let* ((workspace (harness-workspace--get id))
         (found (harness-workspace--thread workspace thread)))
    (unless found (signal 'harness-error (list (format "No thread %s" thread))))
    (let ((session (or episode (plist-get found :live)
                       (car (last (plist-get found :episodes))))))
      (unless (and session (harness-call 'session/exists-p session))
        (signal 'harness-error (list (format "No episode for %s" thread))))
      (list :thread found :session (harness-call 'session/get session)))))

(harness-defmethod workspace/context (id &optional thread episode)
  "Return the last brief of workspace ID's THREAD."
  (let* ((workspace (harness-workspace--get id))
         (found (if thread (harness-workspace--thread workspace thread)
                   (and (plist-get workspace :last-thread)
                        (harness-workspace--thread workspace (plist-get workspace :last-thread))))))
    (when found
      (let ((entries (harness-workspace--timeline-internal id)))
        (car (last (cl-remove-if-not
                    (lambda (entry)
                      (and (eq (harness-workspace--entry-kind entry) 'brief)
                           (equal (plist-get entry :thread) (plist-get found :id))
                           (or (null episode) (equal (plist-get entry :episode) episode))))
                    entries)))))))

(harness-defmethod workspace/brief (id &optional opts)
  "Return a compact digest of workspace ID for the chat or voice."
  (ignore opts)
  (let* ((workspace (harness-workspace--get id))
         (threads (plist-get (harness-workspace--view workspace) :threads))
         (live (cl-remove-if-not (lambda (thread) (plist-get thread :live)) threads))
         (last (car (sort (copy-sequence threads)
                          (lambda (a b) (> (or (plist-get a :last-at) 0)
                                           (or (plist-get b :last-at) 0)))))))
    (list :workspace (plist-get workspace :name)
          :threads (length threads)
          :live (length live)
          :last-thread (and last (plist-get last :title))
          :last-state (and last (plist-get last :state))
          :knowledge (when (harness-method-exists-p 'knowledge/status)
                       (condition-case nil
                           (harness-call 'knowledge/status id)
                         (error nil)))
          :tasks (when (harness-method-exists-p 'task/list)
                   (ignore-errors (harness-call 'task/list (plist-get workspace :root))))
          :box (when (harness-method-exists-p 'workspace/box/status)
                 (ignore-errors (harness-call 'workspace/box/status id))))))

;;;; Opening a thread

;; A person asks for a thread by name -- "open the kitchen thread" -- and
;; the workspace answers by showing it.  That is navigation, so it is its
;; own tool: ordinary routing never calls it, because routing already
;; updates the handling-thread label in the one conversation the person is
;; reading.  The tool opens an existing thread and nothing else: no episode
;; starts, no state is copied, no ownership moves and no message is sent.  A
;; thread of another workspace than the episode's is not found, so a request
;; cannot open a conversation the caller cannot already see.

(defun harness-workspace--tool-episode (ctx)
  "Return (WORKSPACE . THREAD) of the episode in CTX, or signal.
WORKSPACE is the id the episode belongs to and THREAD the thread it
answers in; a session that is not a workspace episode has neither, and
the tool that asked says so rather than opening an unrelated page."
  (let* ((session-id (plist-get ctx :session-id))
         (session (and session-id (harness-call 'session/get session-id)))
         (ext (plist-get session :ext))
         (workspace (plist-get ext :workspace)))
    (unless workspace
      (signal 'harness-error (list "Workspace episode only")))
    (cons workspace (plist-get ext :thread))))

(defun harness-workspace--thread-by-name (workspace name)
  "Return the one thread of WORKSPACE that NAME names, or nil.
NAME is a thread id or words of its title.  An exact id wins; otherwise
the one thread whose title holds every word of NAME.  Two threads that
both match answer nil, so the caller asks rather than opening the wrong
conversation."
  (let ((threads (plist-get (harness-workspace--view workspace) :threads)))
    (or (and (stringp name)
             (cl-find name threads
                      :key (lambda (thread) (plist-get thread :id))
                      :test #'equal))
        (let* ((words (harness-workspace--content-words (or name "")))
               (found (cl-remove-if-not
                       (lambda (thread)
                         (let ((title (downcase (or (plist-get thread :title) ""))))
                           (and words
                                (cl-every (lambda (word)
                                            (string-match-p
                                             (regexp-quote (downcase word)) title))
                                          words))))
                       threads)))
          (and (= 1 (length found)) (car found))))))

(defun harness-workspace--open-thread-params (workspace thread)
  "Return the navigation PARAMS that show THREAD of WORKSPACE.
The project is the thread's own, so the Emacs view opens the workspace
the thread belongs to; the thread travels beside it."
  (list :view "workspace"
        :project (file-name-as-directory
                  (expand-file-name (or (plist-get thread :project)
                                        (plist-get workspace :root)
                                        default-directory)))
        :workspace (plist-get workspace :id)
        :thread (plist-get thread :id)))

(defun harness-workspace--tool-open-thread (input ctx)
  "Handler of workspace_open_thread with INPUT and CTX.
INPUT names the thread by `:thread' (an id, or words of its title) and
may name another workspace by `:workspace'.  The answer names the thread
and what the view did, or says why nothing opened."
  (let* ((pair (harness-workspace--tool-episode ctx))
         (workspace-id (or (plist-get input :workspace) (car pair)))
         (workspace (harness-workspace--get workspace-id))
         (name (or (plist-get input :thread) (plist-get input :title)))
         (thread (harness-workspace--thread-by-name workspace name)))
    (cond
     ((null thread)
      (harness-tool-error
       (format "No thread %S in workspace %s."
               (or name "")
               (or (plist-get workspace :name) workspace-id))))
     ((not (harness-method-exists-p 'emacs/request))
      (harness-tool-error "No Emacs is attached to the harness."))
     (t
      (harness-then
       (harness-tools-ask-emacs
        "harness_open"
        (harness-workspace--open-thread-params workspace thread))
       (lambda (answer)
         (harness-tool-ok
          (format "Opened %s · %s"
                  (or (plist-get thread :title) (plist-get thread :id))
                  (or (plist-get answer :status) "loading"))))
       (lambda (reason)
         (harness-tool-error (harness-tools-reason reason))))))))

(harness-define-tool "workspace_open_thread"
  :label "Open thread"
  :description "Show one existing workspace thread in the user's Emacs, for a request such as \"open the kitchen thread\". Name it by id or by words of its title. Opening is navigation only: it starts no episode, sends no message, copies no state and transfers nothing. An ordinary routed message never needs it, because the workspace conversation already shows which thread handles each exchange."
  :schema '(:type "object"
            :properties (:thread
                         (:type "string"
                          :description "Thread id, or words of its title.")
                         :workspace
                         (:type "string"
                          :description "Another workspace's id; this episode's by default."))
            :required ("thread"))
  :kind 'read
  :subject (lambda (input) (plist-get input :thread))
  :handler #'harness-workspace--tool-open-thread)

;;;; Reassigning a message

;; A message that went to the wrong thread is corrected with one
;; operation, `workspace/reassign', which the two clients and this tool
;; all call: a tool with an idea of its own would be a third place that
;; sends a message.  The tool resolves the words of a request -- "move
;; that to the kitchen thread" -- into a node and a thread id, and it
;; refuses rather than guessing when a name fits more than one thread.

(defun harness-workspace--tool-reassign (input ctx)
  "Handler of workspace_reassign with INPUT and CTX.
INPUT names the message (`:message', the node id, the string \"last\" or
the words, \"last\" by default) and the thread (`:thread', an id or
words of its title).  The answer is the reassignment's own answer, so
the caller reads the same status a client shows."
  (let* ((pair (harness-workspace--tool-episode ctx))
         (workspace (harness-workspace--get (car pair)))
         (target (harness-workspace--thread-by-name workspace (plist-get input :thread))))
    (cond
     ((null target)
      (harness-tool-error
       (format "No thread %S in workspace %s."
               (or (plist-get input :thread) "")
               (or (plist-get workspace :name) (plist-get workspace :id)))))
     (t
      (let ((result (harness-call 'workspace/reassign
                                  (plist-get workspace :id)
                                  (or (plist-get input :message) "last")
                                  (plist-get target :id)
                                  (list :by "mediator"
                                        :thread (cdr pair)))))
        (harness-tool-ok
         (harness-workspace--reassign-words result (plist-get workspace :id))))))))

(defun harness-workspace--reassign-words (result workspace)
  "Return RESULT of a reassignment in WORKSPACE as the words a reader gets.
The status says what happened and the delivery says what became of the
copy in the thread the message was written in, so a message moved before
anything read it is never confused with one the model already had."
  (let* ((status (format "%s" (or (plist-get result :status) "stale")))
         (thread (plist-get result :thread))
         (record (and thread
                      (harness-workspace--thread (harness-workspace--get workspace) thread)))
         (title (or (and record (plist-get record :title)) thread))
         (delivery (format "%s" (or (plist-get result :delivery) "uncertain")))
         (why (plist-get result :why)))
    (cond
     ((equal status "queued")
      (format "Queued · %s. The target reads it next; the origin never did." title))
     ((equal status "waiting")
      (format "Waiting · %s. A running turn held it and no longer does; the target reads it next." title))
     ((equal status "forwarded")
      (format "Forwarded · %s · %s. The origin already read it, so its text was sent on as corrected context; nothing was retracted." title delivery))
     ((equal status "repeated")
      (format "Repeated · %s. An earlier request for this message already answered; nothing was sent again." title))
     ((equal status "stale")
      (format "Stale · %s. Nothing holds the message any more, so it was not sent again." (or why title)))
     ((equal status "unreachable")
      (format "Unreachable · %s. The target cannot be read, so the message stays where it was." (or why title)))
     (t (format "%s · %s." (capitalize status) title)))))

(harness-define-tool "workspace_reassign"
  :label "Reassign message"
  :description "Move one user message of this workspace to the thread that should handle it, when the user says it went to the wrong one (\"that was for the kitchen thread\"). Name the thread by id or by words of its title; name the message by its node id, or leave it out for the last user message the workspace shows. A message nothing has read yet leaves its queue and is queued in the target's; one the transcript already holds is forwarded as corrected context that names the thread it came from, because a delivered message cannot be retracted. The answer says which happened. This moves one message: it does not pin later messages to the target, open a chat, undo work or transfer a task. Ask the user which message and which thread when either is unclear rather than calling this on a guess."
  :schema '(:type "object"
            :properties (:thread
                         (:type "string"
                          :description "Thread id, or words of its title: the thread that should handle the message.")
                         :message
                         (:type "string"
                          :description "The message's node id, the words themselves, or \"last\" (the default) for the last user message the workspace shows."))
            :required ("thread"))
  :kind 'write
  :subject (lambda (input) (plist-get input :thread))
  :handler #'harness-workspace--tool-reassign)

(defun harness-workspace--tools (tools session)
  "Offer the workspace's own tools to an episode, and to no one else.
TOOLS are the names another filter left; SESSION is the session plist.
The open-thread and reassign tools act on the workspace the session is
an episode of, so a session that is not one gets neither."
  (let ((workspace (plist-get (plist-get session :ext) :workspace)))
    (if (or (null session) workspace)
        (delete-dups (append (list "workspace_open_thread" "workspace_reassign") tools))
      (cl-remove-if (lambda (name) (member name '("workspace_open_thread" "workspace_reassign")))
                    tools))))

;;;; Events and module

(defun harness-workspace--system-prompt (prompt session)
  "Append the workspace's instructions to PROMPT for SESSION.
Only an episode gets them; a normal session is unchanged."
  (let ((ext (plist-get session :ext)))
    (if (not (plist-get ext :workspace))
        prompt
      (concat prompt
              "\n\nWorkspace: you are the user's persistent workspace.  The user sees one chat; threads are the topics inside it.  "
              "Your knowledge is the user's Logseq graph: use knowledge_search for anything the brief did not give you, and knowledge_write when the user asks you to remember, when a decision is made, or when a commitment or open loop is created.  When the words of the brief do not match, knowledge_search's mode semantic finds blocks by meaning once an embedding model is set.  "
              "Write one concise block per piece of knowledge and cite the pages you used as [[Page]].  Write only when the turn settled something worth keeping -- a decision, a fact, a commitment, an open loop -- and write nothing on a turn that settled nothing, which is most of them.  Never claim to remember something you did not retrieve.  "
              (when (harness-tool-get "memory_save")
                "The memory tools are not for knowledge: memory_save is only for small behavioral notes about how the user wants work done.  ")
              "Work that must outlive this conversation, touch a repository, be reviewed, or run in parallel belongs on the task board; use task_list, task_submit and task_control for it.  "
              "Do small, self-contained work here; do not do a task's work in the chat and then submit a task for it."))))

(defun harness-workspace--install-acp ()
  "Expose the workspace methods and events to ACP clients."
  (when (boundp 'harness-acp-extra-method-prefixes)
    (add-to-list 'harness-acp-extra-method-prefixes "workspace/")
    (add-to-list 'harness-acp-extra-method-prefixes "knowledge/"))
  (when (boundp 'harness-acp-extra-events)
    (dolist (event '(workspace/changed workspace/deleted workspace/timeline-appended
                     workspace/thread-changed workspace/episode-changed
                     workspace/context-built workspace/knowledge-changed
                     workspace/reassigned workspace/inbox-changed
                     workspace/dream-finished))
      (add-to-list 'harness-acp-extra-events event))))

(defun harness-workspace--init ()
  "Load the workspaces and follow the episodes."
  (harness-workspace--load)
  (harness-workspace--install-acp)
  ;; The computer is part of the workspace's first slice: load it with
  ;; the workspace, so a harness prepared for workspace mode has a real
  ;; screen and says why when it cannot.
  (condition-case err
      (progn
        (require 'harness-workspace-box nil t)
        (when (harness-module-get 'workspace-box)
          (harness-module-start 'workspace-box)))
    (error
     (harness-log 'warn "workspace: computer module failed: %s"
                  (harness-error-message err))))
  (with-eval-after-load 'harness-acp (harness-workspace--install-acp))
  (unless harness-workspace--subscribed
    (setq harness-workspace--subscribed t)
    (harness-on 'session/node-added #'harness-workspace--on-node-added)
    (harness-on 'session/node-updated #'harness-workspace--on-node-updated)
    (harness-on 'agent/turn-started #'harness-workspace--on-turn-started)
    (harness-on 'agent/turn-ended #'harness-workspace--on-turn-ended)
    (harness-on 'session/deleted #'harness-workspace--on-session-deleted)
    (harness-on 'session/queue-changed #'harness-workspace--on-session-queue-changed)
    (harness-on 'session/steering-changed #'harness-workspace--on-session-queue-changed)
    (harness-add-filter 'agent/system-prompt #'harness-workspace--system-prompt)
    (harness-add-filter 'agent/tools #'harness-workspace--tools 40)))

(defun harness-workspace--shutdown ()
  "Stop following the episodes.  The records stay on disk."
  (when (timerp harness-workspace--notification-timer)
    (cancel-timer harness-workspace--notification-timer)
    (setq harness-workspace--notification-timer nil))
  (when harness-workspace--subscribed
    (setq harness-workspace--subscribed nil)
    (harness-off (cons 'session/node-added #'harness-workspace--on-node-added))
    (harness-off (cons 'session/node-updated #'harness-workspace--on-node-updated))
    (harness-off (cons 'agent/turn-started #'harness-workspace--on-turn-started))
    (harness-off (cons 'agent/turn-ended #'harness-workspace--on-turn-ended))
    (harness-off (cons 'session/deleted #'harness-workspace--on-session-deleted))
    (harness-off (cons 'session/queue-changed #'harness-workspace--on-session-queue-changed))
    (harness-off (cons 'session/steering-changed #'harness-workspace--on-session-queue-changed))
    (harness-remove-filter 'agent/system-prompt #'harness-workspace--system-prompt)
    (harness-remove-filter 'agent/tools #'harness-workspace--tools)))

(harness-declare-event 'workspace/changed "(ID WORKSPACE) when a workspace record changed.")
(harness-declare-event 'workspace/deleted "(ID) when a workspace was deleted.")
(harness-declare-event 'workspace/timeline-appended "(ID ENTRY) when a timeline entry was appended.")
(harness-declare-event 'workspace/thread-changed "(ID THREAD) when a thread changed.")
(harness-declare-event 'workspace/episode-changed "(ID THREAD SESSION DIVIDER) when an episode started or ended.")
(harness-declare-event 'workspace/context-built "(ID THREAD BRIEF) when a brief was built.")
(harness-declare-event 'workspace/knowledge-changed "(WORKSPACE OP) when a block was written to the workspace's Logseq graph.")
(harness-declare-event 'workspace/reassigned "(ID THREAD RESULT) when a message was moved to another thread.")
(harness-declare-event 'workspace/inbox-changed "(ID) when what waits to be sent in a workspace changed.")
(harness-declare-event 'workspace/dream-finished "(WORKSPACE RESULT) when a dream changed the workspace's Logseq graph.")

(harness-define-module 'workspace
  :doc "Persistent workspace chat: one timeline over topic threads and episodes."
  :requires '(store session agent project workspace-knowledge)
  :init #'harness-workspace--init
  :shutdown #'harness-workspace--shutdown)

(provide 'harness-workspace)
;;; harness-workspace.el ends here
