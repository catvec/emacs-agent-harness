;;; harness-workspace.el --- Persistent workspace chat: threads, episodes and one timeline -*- lexical-binding: t; -*-

;;; Commentary:

;; Workspace mode is one chat over many topics.  A workspace is a named,
;; long-lived assistant with a root directory and a list of threads.  A
;; thread is a topic; each live stretch of a thread is an *episode*, an
;; ordinary harness session of kind `workspace'.  A new episode starts
;; from a fresh *brief* built from the thread and from the memory store,
;; not from a compacted transcript.  The user sees the episodes and the
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
;; Routing is deliberately conservative.  An explicit thread, an explicit
;; `/new', the only live episode, a thread title in the message, or the
;; last thread when nothing says otherwise; a topic marker makes a new
;; thread.  A model router can be added later without changing the shape
;; of `workspace/prompt'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-store)
(require 'harness-session)
(require 'harness-agent)
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
  "Memory notes a brief recalls."
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

(defun harness-workspace--session-state (session-id)
  "Return the state of SESSION-ID as the workspace shows it."
  (if (not (and (stringp session-id) (harness-call 'session/exists-p session-id)))
      "parked"
    (let ((status (plist-get (harness-call 'session/get session-id) :status)))
      (cond ((eq status 'running) "live")
            ((eq status 'blocked) "waiting")
            ((eq status 'idle) "live")
            (t "parked")))))

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

(defun harness-workspace--view (workspace)
  "Return WORKSPACE as clients read it, with thread states."
  (let* ((threads (mapcar (lambda (thread)
                            (let* ((live (plist-get thread :live))
                                   (state (if live
                                              (harness-workspace--session-state live)
                                            "parked")))
                              (append (copy-sequence thread) (list :state state))))
                          (plist-get workspace :threads)))
         (threads (sort threads
                        (lambda (a b)
                          (cond ((and (plist-get a :pinned) (not (plist-get b :pinned))) t)
                                ((and (plist-get b :pinned) (not (plist-get a :pinned))) nil)
                                (t (> (or (plist-get a :last-at) 0)
                                      (or (plist-get b :last-at) 0))))))))
    (let ((view (copy-sequence workspace)))
      (setf (plist-get view :threads) threads)
      view)))

(defun harness-workspace--append (workspace entry)
  "Append ENTRY to WORKSPACE's timeline and announce it."
  (let* ((id (plist-get workspace :id))
         (entry (plist-put (copy-sequence entry) :at (or (plist-get entry :at) (harness-workspace--now)))))
    (harness-call 'store/append (harness-workspace--timeline-file id) entry)
    (harness-emit 'workspace/timeline-appended id entry)
    entry))

;;;; Threads and episodes

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
                       :ext (list :workspace wid
                                  :thread (plist-get thread :id)
                                  :episode number))
                 (when-let* ((model (or (plist-get workspace :model)
                                        harness-workspace-model)))
                   (list :model model))
                 (when-let* ((thinking (or (plist-get workspace :thinking)
                                           harness-workspace-thinking)))
                   (list :thinking thinking))))
         (session (apply #'harness-call 'session/create plist))
         (sid (plist-get session :id)))
    (setf (plist-get thread :live) sid
          (plist-get thread :status) "live")
    (setf (plist-get thread :episodes)
          (append (plist-get thread :episodes) (list sid)))
    (harness-workspace--put-thread workspace thread)
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

(defun harness-workspace--memory-recall (workspace thread text)
  "Return memory cards for TEXT in WORKSPACE's thread THREAD."
  (when (harness-method-exists-p 'memory/search)
    (condition-case err
        (harness-call 'memory/search
                      (plist-get workspace :id)
                      (string-trim (concat (plist-get thread :title) " " text))
                      (list :limit harness-workspace-recall
                            :thread (plist-get thread :id)))
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
         (recall (harness-workspace--memory-recall workspace thread text))
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
                      (format "Relevant memory:\n%s"
                              (mapconcat
                               (lambda (card)
                                 (format "- [%s] %s"
                                         (or (plist-get card :thread) "note")
                                         (plist-get card :text)))
                               recall "\n")))
                 "Answer the user's message.  Use memory_search for anything not in this brief; do not invent a memory.")))
         (brief (string-trim (mapconcat #'identity parts "\n\n"))))
    (if (> (length brief) harness-workspace-brief-chars)
        (concat (substring brief 0 harness-workspace-brief-chars) "\n\n[Brief cut to fit.]")
      brief)))

;;;; Routing

(defconst harness-workspace--topic-cues
  '("new topic" "different topic" "another topic" "unrelated" "switch to"
    "start over" "something else" "on another note" "separate thread")
  "Words that start a new thread when no thread title matches.")

(defun harness-workspace--tokens (text)
  "Return the meaningful words of TEXT, lowercased."
  (let (out)
    (dolist (word (split-string (downcase (or text "")) "[^[:alnum:]_]+" t))
      (when (>= (length word) 3) (push word out)))
    (delete-dups (nreverse out))))

(defun harness-workspace--thread-score (thread text)
  "Return how many words of TEXT name THREAD."
  (let* ((haystack (downcase (concat (or (plist-get thread :title) "") " "
                                     (or (plist-get thread :summary) "") " "
                                     (or (plist-get thread :project) ""))))
         (tokens (harness-workspace--tokens text)))
    (cl-loop for token in tokens
             count (string-match-p (regexp-quote token) haystack))))

(defun harness-workspace--best-thread (workspace text &optional except)
  "Return the thread of WORKSPACE that TEXT names best, or nil.
EXCEPT is a thread id to leave out."
  (let (best best-score)
    (dolist (thread (plist-get workspace :threads))
      (unless (equal (plist-get thread :id) except)
        (let ((score (harness-workspace--thread-score thread text)))
          (when (and (> score 0) (or (null best-score) (> score best-score)))
            (setq best thread best-score score)))))
    best))

(defun harness-workspace--cue-p (text)
  "Non-nil when TEXT says it is a new topic."
  (let ((text (downcase (or text ""))))
    (cl-some (lambda (cue) (string-match-p (regexp-quote cue) text))
             harness-workspace--topic-cues)))

(defun harness-workspace--route (workspace text opts)
  "Return (THREAD . ACTION) for TEXT in WORKSPACE.
ACTION is `continue', `revive' or `new'.  OPTS may name `:thread',
`:force-new' or `:force-continue'."
  (let* ((requested (plist-get opts :thread))
         (current (when-let* ((id (plist-get workspace :last-thread)))
                    (harness-workspace--thread workspace id)))
         (named (harness-workspace--best-thread
                 workspace text
                 (and current (plist-get current :id))))
         (live (and current (plist-get current :live))))
    (cond
     ((and requested (harness-workspace--thread workspace requested))
      (let ((thread (harness-workspace--thread workspace requested)))
        (cons thread (if (plist-get thread :live) 'continue 'revive))))
     ((harness-json-true-p (plist-get opts :force-new))
      (cons nil 'new))
     ((string-match-p "\\`/new\\(?:[ \t\n]\\|\\'\\)" text)
      (cons nil 'new))
     ((and current live (harness-workspace--session-running-p live)
           (not (harness-json-true-p (plist-get opts :force-new))))
      (cons current 'continue))
     ((harness-workspace--cue-p text)
      (cons nil 'new))
     ((and named (> (harness-workspace--thread-score named text) 1))
      (cons named 'revive))
     ((and current live
           (let ((last (or (plist-get current :last-at) 0)))
             (> (- (harness-workspace--now) last)
                (* 3600 harness-workspace-thread-idle-hours))))
      (cons current 'revive))
     ((and current live)
      (if (harness-workspace--episode-too-long-p live)
          (cons current 'revive)
        (cons current 'continue)))
     (current
      (cons current 'revive))
     (t
      (cons nil 'new)))))

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

(defun harness-workspace--on-turn-ended (session-id &rest _)
  "Mark the episode of SESSION-ID idle in its workspace."
  (when-let* ((ext (harness-workspace--episode-p session-id))
              (workspace (gethash (plist-get ext :workspace) harness-workspace--table))
              (thread (harness-workspace--thread workspace (plist-get ext :thread))))
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
  "Create a workspace.  PLIST may set :name, :root, :project, :model,
:thinking, :permission-mode, :non-interactive and :instructions."
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
                          :instructions (plist-get plist :instructions)
                          :model (plist-get plist :model)
                          :thinking (plist-get plist :thinking)
                          :permission-mode (or (plist-get plist :permission-mode)
                                               harness-workspace-permission-mode)
                          :non-interactive (if (plist-member plist :non-interactive)
                                               (plist-get plist :non-interactive)
                                             harness-workspace-non-interactive)
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
                   :non-interactive :instructions))
      (when (plist-member plist key)
        (setf (plist-get workspace key) (plist-get plist key))))
    (when root
      (setf (plist-get workspace :root)
            (file-name-as-directory (expand-file-name root)))
      (harness-ensure-directory (plist-get workspace :root)))
    (harness-workspace--save workspace)))

(harness-defmethod workspace/delete (id &optional delete-sessions delete-graph)
  "Delete workspace ID.  With DELETE-SESSIONS close its episodes too.
DELETE-GRAPH is accepted for the future Logseq integration; this
implementation keeps no graph of its own."
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
         (memory (when (harness-method-exists-p 'memory/status)
                   (harness-call 'memory/status id))))
    (list :id id :name (plist-get workspace :name)
          :threads (length threads) :live live
          :last-thread (plist-get workspace :last-thread)
          :memory memory)))

(harness-defmethod workspace/resources/status (id)
  "Return workspace ID's browser, wallet, access and credential resources.
The box and the payment broker are staged, so the browser and wallet
sections are empty and say so.  Credentials are the harness's own
declared secrets, read through the secret-sandbox module when it is
loaded: label, fingerprint, usability, error and last use, never a
value.  The answer is metadata only."
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
         (credentials
          (mapcar (lambda (secret)
                    (list :label (plist-get secret :label)
                          :fingerprint (plist-get secret :fingerprint)
                          :usable (and (plist-get secret :usable) t)
                          :error (plist-get secret :error)
                          :last-use (plist-get secret :last-use)))
                  secrets)))
    (list :workspace id
          :status (if module "ready" "unavailable")
          :reason (unless module "box-staged")
          :metadata-only t
          :browser nil :wallet nil :access nil :audit nil
          :browser-status "unavailable"
          :wallet-status "unavailable"
          :credentials credentials
          :credentials-status
          (list :status (cond ((null secret-status) "unavailable")
                              ((plist-get secret-status :locked) "ready")
                              (t "needs-approval"))
                :mask (plist-get secret-status :mask)
                :locked (plist-get secret-status :locked)
                :why (plist-get secret-status :why)
                :count (length secrets)))))
(harness-defmethod workspace/browser/clear (id scope &optional origin kinds)
  "Clear browser data in workspace ID and return the resources answer.
SCOPE is \"profile\" or \"site\"; ORIGIN names the site for the latter.
KINDS lists what to clear: \"cookies\", \"storage\", \"cache\" or
\"permissions\".  The box is staged: nothing is cleared, the answer is
`:status \"unavailable\"\' with `:reason \"box-staged\"\' and `:changed
nil\', and no value is part of it."
  (harness-workspace--get id)
  (unless (member scope '("profile" "site"))
    (signal 'harness-error (list (format "Unknown browser scope: %s" scope))))
  (when (and (equal scope "site")
             (not (and (stringp origin) (not (harness-string-blank-p origin)))))
    (signal 'harness-error (list "A site clear needs an origin")))
  (list :workspace id :status "unavailable" :reason "box-staged"
        :metadata-only t :scope scope :origin origin
        :kinds (append kinds nil) :changed nil
        :browser nil :wallet nil :access nil :audit nil))

(harness-defmethod workspace/browser/login/forget (id login)
  "Forget the saved site LOGIN in workspace ID and return the resources.
The box is staged: nothing is forgotten, the answer is `:status
\"unavailable\"\' with `:reason \"box-staged\"\' and `:changed nil', and
no cookie or token is part of it."
  (harness-workspace--get id)
  (unless (and (stringp login) (not (harness-string-blank-p login)))
    (signal 'harness-error (list "Forgetting a login needs its id")))
  (list :workspace id :status "unavailable" :reason "box-staged"
        :metadata-only t :login login :changed nil
        :browser nil :wallet nil :access nil :audit nil))

(harness-defmethod workspace/wallet/authorization/create (id &rest plist)
  "Ask for a bounded purchase authorization for workspace ID.
PLIST names the card reference, amount, currency, cap kind, merchant
scope, expiry and fee policy.  The payment broker is staged: nothing
is created, the answer is `:status \"unavailable\"\' with `:reason
\"box-staged\"\' and `:changed nil', and PLIST is never echoed back,
because it may name a card reference."
  (harness-workspace--get id)
  (ignore plist)
  (list :workspace id :status "unavailable" :reason "box-staged"
        :metadata-only t :changed nil
        :browser nil :wallet nil :access nil :audit nil))

(harness-defmethod workspace/wallet/authorization/revoke (id authorization)
  "Revoke purchase AUTHORIZATION in workspace ID and return the resources.
The payment broker is staged: nothing is revoked, the answer is
`:status \"unavailable\"\' with `:reason \"box-staged\"\' and `:changed
nil\'."
  (harness-workspace--get id)
  (unless (and (stringp authorization) (not (harness-string-blank-p authorization)))
    (signal 'harness-error (list "Revoking needs an authorization id")))
  (list :workspace id :status "unavailable" :reason "box-staged"
        :metadata-only t :authorization authorization :changed nil
        :browser nil :wallet nil :access nil :audit nil))

(harness-defmethod workspace/wallet/purchase/decide (id purchase decision)
  "Decide a proposed PURCHASE in workspace ID: allow or deny it.
DECISION is \"allow\" or \"deny\".  The payment broker is staged:
nothing is charged or declined, the answer is `:status
\"unavailable\"\' with `:reason \"box-staged\"\' and `:changed nil'."
  (harness-workspace--get id)
  (unless (member decision '("allow" "deny"))
    (signal 'harness-error (list (format "Unknown purchase decision: %s" decision))))
  (list :workspace id :status "unavailable" :reason "box-staged"
        :metadata-only t :purchase purchase :decision decision :changed nil
        :browser nil :wallet nil :access nil :audit nil))

(harness-defmethod workspace/prompt (id text &optional opts)
  "Send TEXT to workspace ID and return the turn's promise.
OPTS may name `:thread', `:force-new' or `:channel'.  The workspace
routes TEXT to the thread's live episode, starts a new episode in the
thread, or starts a new thread.  A new episode is given a brief first."
  (unless (and (stringp text) (not (string-blank-p text)))
    (signal 'harness-error (list "Empty workspace message")))
  (let* ((workspace (harness-workspace--get id))
         (clean (replace-regexp-in-string "\\`/new\\(?:[ \t\n]+\\|\\'\\)" "" text))
         (clean (if (string-blank-p clean) "New thread" clean))
         (route (harness-workspace--route workspace text opts))
         (thread (car route))
         (action (cdr route)))
    (when (eq action 'new)
      (setq thread (harness-workspace--new-thread workspace clean)))
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
      (setq entries (cl-remove-if-not
                     (lambda (entry) (equal (plist-get entry :thread) thread)) entries)))
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
    (dolist (key '(:title :status :pinned :project :summary))
      (when (plist-member plist key)
        (setf (plist-get found key) (plist-get plist key))))
    (harness-workspace--put-thread workspace found)
    (harness-workspace--save workspace)
    (harness-emit 'workspace/thread-changed id found)
    found))

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
          :memory (when (harness-method-exists-p 'memory/status)
                    (harness-call 'memory/status id))
          :tasks (when (harness-method-exists-p 'task/list)
                   (ignore-errors (harness-call 'task/list (plist-get workspace :root)))))))

;;;; Events and module

(defun harness-workspace--system-prompt (prompt session)
  "Append the workspace's instructions to PROMPT for SESSION.
Only an episode gets them; a normal session is unchanged."
  (let ((ext (plist-get session :ext)))
    (if (not (plist-get ext :workspace))
        prompt
      (concat prompt
              "\n\nWorkspace: you are the user's persistent workspace.  The user sees one chat; threads are the topics inside it.  "
              "Use memory_search for anything the brief did not give you and memory_write when the user asks you to remember, when a decision is made, or when a commitment is created.  "
              "Cite the pages you used as [[Page]].  Never claim to remember something you did not retrieve.  "
              "Work that must outlive this conversation, touch a repository, be reviewed, or run in parallel belongs on the task board; use task_list, task_submit and task_control for it.  "
              "Do small, self-contained work here; do not do a task's work in the chat and then submit a task for it."))))

(defun harness-workspace--install-acp ()
  "Expose the workspace methods and events to ACP clients."
  (when (boundp 'harness-acp-extra-method-prefixes)
    (add-to-list 'harness-acp-extra-method-prefixes "workspace/")
    (add-to-list 'harness-acp-extra-method-prefixes "memory/"))
  (when (boundp 'harness-acp-extra-events)
    (dolist (event '(workspace/changed workspace/deleted workspace/timeline-appended
                     workspace/thread-changed workspace/episode-changed
                     workspace/context-built workspace/memory-changed))
      (add-to-list 'harness-acp-extra-events event))))

(defun harness-workspace--init ()
  "Load the workspaces and follow the episodes."
  (harness-workspace--load)
  (harness-workspace--install-acp)
  (with-eval-after-load 'harness-acp (harness-workspace--install-acp))
  (unless harness-workspace--subscribed
    (setq harness-workspace--subscribed t)
    (harness-on 'session/node-added #'harness-workspace--on-node-added)
    (harness-on 'session/node-updated #'harness-workspace--on-node-updated)
    (harness-on 'agent/turn-ended #'harness-workspace--on-turn-ended)
    (harness-on 'session/deleted #'harness-workspace--on-session-deleted)
    (harness-add-filter 'agent/system-prompt #'harness-workspace--system-prompt)))

(defun harness-workspace--shutdown ()
  "Stop following the episodes.  The records stay on disk."
  (when harness-workspace--subscribed
    (setq harness-workspace--subscribed nil)
    (harness-off (cons 'session/node-added #'harness-workspace--on-node-added))
    (harness-off (cons 'session/node-updated #'harness-workspace--on-node-updated))
    (harness-off (cons 'agent/turn-ended #'harness-workspace--on-turn-ended))
    (harness-off (cons 'session/deleted #'harness-workspace--on-session-deleted))
    (harness-remove-filter 'agent/system-prompt #'harness-workspace--system-prompt)))

(harness-declare-event 'workspace/changed "(ID WORKSPACE) when a workspace record changed.")
(harness-declare-event 'workspace/deleted "(ID) when a workspace was deleted.")
(harness-declare-event 'workspace/timeline-appended "(ID ENTRY) when a timeline entry was appended.")
(harness-declare-event 'workspace/thread-changed "(ID THREAD) when a thread changed.")
(harness-declare-event 'workspace/episode-changed "(ID THREAD SESSION DIVIDER) when an episode started or ended.")
(harness-declare-event 'workspace/context-built "(ID THREAD BRIEF) when a brief was built.")
(harness-declare-event 'workspace/memory-changed "(WORKSPACE OP) when a memory write was indexed.")

(harness-define-module 'workspace
  :doc "Persistent workspace chat: one timeline over topic threads and episodes."
  :requires '(store session agent project workspace-memory)
  :init #'harness-workspace--init
  :shutdown #'harness-workspace--shutdown)

(provide 'harness-workspace)
;;; harness-workspace.el ends here
