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
  "Record NODE as a message of THREAD in WORKSPACE."
  (let ((text (or (plist-get node :content) "")))
    (unless (string-blank-p text)
      (let ((entry (harness-workspace--append
                    workspace
                    (list :kind 'message
                          :thread (plist-get thread :id)
                          :episode session
                          :role role
                          :text (if (> (length text) harness-workspace-max-message-chars)
                                    (substring text 0 harness-workspace-max-message-chars)
                                  text)
                          :node (plist-get node :id)))))
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
the user cancelled stopped, until the episode starts another."
  (when-let* ((ext (harness-workspace--episode-p session-id))
              (workspace (gethash (plist-get ext :workspace) harness-workspace--table))
              (thread (harness-workspace--thread workspace (plist-get ext :thread))))
    (setf (plist-get thread :last-stop) (and reason (format "%s" reason)))
    ;; The key may be new: put the thread back, not only its plist.
    (harness-workspace--put-thread workspace thread)
    (harness-workspace--save workspace)
    (harness-emit 'workspace/thread-changed (plist-get workspace :id) thread)))

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
:model, :thinking, :permission-mode, :non-interactive, :skills and
:instructions.  :graph is the Logseq graph its knowledge lives in; the
default is the configured graph (`harness-logseq-directory').  :skills
is the skill selection its episodes inherit (see the skills module's
`skills/selection'): durable references such as `OWNER/NAME',
`@VERSION' or `#FINGERPRINT', optional with a leading `?', never a copy
of a grant.  It is resolved afresh for each episode against what the
computers the episode may use offer then."
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
                   :non-interactive :instructions :skills))
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

(harness-defmethod workspace/open (id)
  "Return workspace ID and its last thread, creating no episode."
  (let* ((workspace (harness-workspace--get id))
         (thread (and (plist-get workspace :last-thread)
                      (harness-workspace--thread workspace (plist-get workspace :last-thread)))))
    (list :workspace (harness-workspace--view workspace)
          :thread thread
          :episode (and thread (plist-get thread :live)))))

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
message says), `:force-continue', `:force-new', `:command' and
`:channel'.  The workspace routes TEXT to the thread's live episode,
starts a new episode in the thread, or starts a new thread.  A new
episode is given a brief first."
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
        (harness-call 'agent/prompt session clean)))))

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
                     workspace/context-built workspace/knowledge-changed))
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
    (harness-add-filter 'agent/system-prompt #'harness-workspace--system-prompt)))

(defun harness-workspace--shutdown ()
  "Stop following the episodes.  The records stay on disk."
  (when harness-workspace--subscribed
    (setq harness-workspace--subscribed nil)
    (harness-off (cons 'session/node-added #'harness-workspace--on-node-added))
    (harness-off (cons 'session/node-updated #'harness-workspace--on-node-updated))
    (harness-off (cons 'agent/turn-started #'harness-workspace--on-turn-started))
    (harness-off (cons 'agent/turn-ended #'harness-workspace--on-turn-ended))
    (harness-off (cons 'session/deleted #'harness-workspace--on-session-deleted))
    (harness-remove-filter 'agent/system-prompt #'harness-workspace--system-prompt)))

(harness-declare-event 'workspace/changed "(ID WORKSPACE) when a workspace record changed.")
(harness-declare-event 'workspace/deleted "(ID) when a workspace was deleted.")
(harness-declare-event 'workspace/timeline-appended "(ID ENTRY) when a timeline entry was appended.")
(harness-declare-event 'workspace/thread-changed "(ID THREAD) when a thread changed.")
(harness-declare-event 'workspace/episode-changed "(ID THREAD SESSION DIVIDER) when an episode started or ended.")
(harness-declare-event 'workspace/context-built "(ID THREAD BRIEF) when a brief was built.")
(harness-declare-event 'workspace/knowledge-changed "(WORKSPACE OP) when a block was written to the workspace's Logseq graph.")

(harness-define-module 'workspace
  :doc "Persistent workspace chat: one timeline over topic threads and episodes."
  :requires '(store session agent project workspace-knowledge)
  :init #'harness-workspace--init
  :shutdown #'harness-workspace--shutdown)

(provide 'harness-workspace)
;;; harness-workspace.el ends here
