;;; harness-tools-sessions.el --- Tools to inspect and drive other sessions and tasks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Lets an agent see and steer the rest of the harness: the other
;; sessions and the task board.
;;
;; Sessions:
;; - `session_list' lists sessions (this project by default) with
;;   status, model, usage, priority and whether they wait on the user.
;; - `session_search' finds sessions whose transcript contains a string.
;;   It greps the node logs on disk in a subprocess, so transcripts are
;;   never loaded into memory just to be searched.
;; - `session_read' shows the recent transcript of one session.
;; - `session_history' searches and reads the calling session's own
;;   conversation from before its last compaction or handoff, which the
;;   model holds only as a summary, a transcript file or not at all; the
;;   note a compaction ends with points the model at it (see
;;   `harness-compaction--history-note').
;; - `session_send' sends a message: it starts a turn on an idle
;;   session, steers a running one, or queues for the next turn; it can
;;   wait for the reply.
;; - `session_control' cancels a turn, resumes, closes or renames a
;;   session, or answers a question it asked with ask_user.  The
;;   harness's own question about a cold prompt cache (harness-cowboy.el)
;;   is left to the user, as permission requests are.
;; - `session_move' moves a session, this one by default, to another
;;   working directory and that directory's project.  The user confirms
;;   every move, in every permission mode (see session_move below).
;; - `session_wait' does not wait: it registers a wake-up and returns at
;;   once, and the session is sent a message of its own when the other
;;   sessions stop running (or become idle, blocked, start running, or
;;   change at all).
;; - `set_non_interactive' turns non-interactive mode on or off for
;;   this session, another one, or every current session and task of
;;   every project, with `session/set-all' and `task/set-all' as the
;;   UI's `harness-set-non-interactive-all' does.
;; - `set_priority' gives one session -- this one by default, a task's
;;   through the session `task_list' names -- or every current session
;;   and task of every project a priority: low, medium or high, the
;;   priority plugin's one vocabulary (`priority/set',
;;   `priority/set-all').  A task's priority is its session's.
;;
;; Tasks (when the `tasks' module is loaded):
;; - `task_list', `task_submit' (with a priority: low, medium or high),
;;   `task_control' (start, message, cancel, merge, verify, reject,
;;   complete, archive, restore, delete, priority) and `task_wait'.
;;   `task_control''s priority action sets the task's session's, since
;;   that is where a task's priority lives.
;;
;; Nothing here grants permissions: a session's permission requests and
;; permission mode are left to the user, and tasks are submitted with
;; the task defaults.  Reading and waiting are `read' tools; anything
;; that changes another session is `meta' and goes through the
;; permission chain like any other action.  A move changes what a
;; session may reach, so only the user decides it.  Turning
;; non-interactive mode on takes the user out of the loop, so the
;; permission chain asks the user about it every time, in every
;; permission mode, and neither the judge nor a rule can allow it (see
;; `harness-perms--away-request'); a non-interactive session has nobody
;; to ask, so its request is denied.  Turning it off needs no one's
;; leave.
;;
;; Waits run without blocking the harness: each is an entry in
;; `harness-tools-sessions--waiters' re-checked by one subscriber
;; whenever a session or task changes, and settled by its condition, its
;; timeout, or the end of the waiting turn.  A wait made by a call
;; (`task_wait') settles with a result for its promise; a registered one
;; (`session_wait') outlives the turn that made it and sends the session
;; a message of its own when an event settles it.
;;
;; The subscriber is not the only way a wait is looked at: a slow safety
;; re-check (`harness-tools-sessions-wait-recheck') runs while any wait
;; does, so a change that no subscribed event announced -- a subscriber
;; lost to a reload, a session settled by a module of its own, a finish
;; that happened before the wait was made -- cannot leave a wait or a
;; registration while its condition already holds.  This matters most
;; for a sub-agent: `spawn_agent' returns as soon as its child starts,
;; but a wait made once that child has finished has nothing left to
;; announce, and `--reached-p' settles a changed wait on an idle or
;; closed session: nothing new of its own is coming from it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)
(require 'harness-priority)
(require 'harness-tools)

(defvar harness-state-directory)

(defconst harness-tools-sessions--wait-default 600
  "Seconds `task_wait' waits when the call gives no timeout.")

(defconst harness-tools-sessions--wait-max 3600
  "Longest wait, in seconds, a `session_wait' or `task_wait' call may ask for.")

(defcustom harness-tools-sessions-wait-recheck 2
  "Seconds between the safety re-checks of running waits, or nil for none.
A wait is settled the moment its condition first holds, as the events
that announce a session's or task's changes tell the module to look
again; this is a floor under those events, so a change none of them
announced -- a subscriber lost to a reload, a status a module set on its
own, a finish that happened before the wait was made -- cannot leave a
wait or a registration while its condition already holds.  The
re-check is a walk over the running waits; with none running, nothing
runs."
  :type '(choice (const :tag "No safety re-check" nil)
                 (number :tag "Seconds"))
  :safe (lambda (v) (or (null v) (and (numberp v) (> v 0))))
  :group 'harness)

(defconst harness-tools-sessions--grep-program "grep"
  "Program `session_search' runs over the transcript logs.")

(defconst harness-tools-sessions--piece 50000
  "Length of the pieces of a long text a regexp is run over one at a time.
A regexp like `a.*b' overflows the matcher over a line of a megabyte,
but not over a piece this long; see `harness-tools-sessions--locate'.")

;;;; Formatting

(defun harness-tools-sessions--short (id)
  "Return the first eight characters of ID."
  (if (stringp id) (substring id 0 (min 8 (length id))) ""))

(defun harness-tools-sessions--pending-text (session)
  "Return a one-line description of what SESSION waits on, or nil."
  (let ((pending (plist-get session :pending)))
    (when pending
      (mapconcat (lambda (p)
                   (let ((payload (plist-get p :payload)))
                     (pcase (plist-get p :kind)
                       ((or 'question "question")
                        (format "question %s: %s" (plist-get p :id)
                                (harness-truncate-end (harness-first-line (or (plist-get payload :question) "")) 100)))
                       ((or 'permission "permission")
                        (format "permission for %s" (or (plist-get payload :tool) (plist-get payload :title) "a tool")))
                       (k (format "%s %s" k (plist-get p :id))))))
                 pending "; "))))

(defun harness-tools-sessions--line (s)
  "Return the one-line listing of session plist S.
A priority of its own that is not the default shows after the figures,
as \", priority high\": it is what the queues the session's work waits
in go by (see the priority plugin)."
  (let ((u (plist-get s :usage))
        (pending (harness-tools-sessions--pending-text s))
        (level (harness-priority-of-ext (plist-get s :ext))))
    (concat
     (format "%s  %-8s %-8s %s  model %s, %s, cost %s, updated %s"
             (plist-get s :id) (plist-get s :status) (plist-get s :kind)
             (format "%S" (or (plist-get s :name) "(unnamed)"))
             (plist-get s :model)
             (abbreviate-file-name (or (plist-get s :cwd) ""))
             (harness-format-spend u)
             (harness-relative-time (plist-get s :updated)))
     (if (and level (not (eq level harness-priority-default)))
         (format ", priority %s" level) "")
     (if (plist-get s :parent-id) (format ", parent %s" (harness-tools-sessions--short (plist-get s :parent-id))) "")
     (if (plist-get s :queue) (format ", %d queued" (length (plist-get s :queue))) "")
     (if pending (format "\n    waiting on the user: %s" pending) ""))))

(defun harness-tools-sessions--node-text (node)
  "Return the readable text of transcript NODE.
A tool call reads as the tool's name, as the model knows it, and its input."
  (pcase (plist-get node :kind)
    ('tool-call (format "%s %s" (or (plist-get node :tool) (plist-get node :title) "")
                        (if (plist-get node :input) (harness-json-encode-text (plist-get node :input)) "")))
    ('tool-result (or (plist-get node :output) ""))
    (_ (or (plist-get node :content) ""))))

(defun harness-tools-sessions--tag (node)
  "Return the tag that opens the line of transcript NODE: its kind and id.
A user message the user did not write says who sent it."
  (let ((from (and (eq (plist-get node :kind) 'user) (harness-node-sender node))))
    (format "[%s %s%s]" (plist-get node :kind) (plist-get node :id)
            (if from (concat ", from " (harness-sender-description from)) ""))))

(defun harness-tools-sessions--last-reply (session-id)
  "Return the last assistant text of SESSION-ID, or nil."
  (let ((node (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'assistant)
                                           (not (harness-string-blank-p (plist-get n :content)))))
                          (reverse (harness-call 'session/nodes session-id (list :limit 50))))))
    (and node (plist-get node :content))))

(defun harness-tools-sessions--describe (session-id &optional reply-chars)
  "Return the status of SESSION-ID with its last reply cut to REPLY-CHARS."
  (if (not (harness-call 'session/exists-p session-id))
      (format "%s: deleted" session-id)
    (let* ((s (harness-call 'session/get session-id))
           (reply (harness-tools-sessions--last-reply session-id))
           (pending (harness-tools-sessions--pending-text s)))
      (concat (format "%s %S: %s" session-id (or (plist-get s :name) "(unnamed)")
                      (harness-tools-sessions--status session-id))
              (if pending (format "\n  waiting on the user: %s" pending) "")
              (if reply
                  (format "\n  last reply:\n%s"
                          (harness-truncate-end reply (or reply-chars 2000)))
                "")))))

;;;; Resolving references

(defun harness-tools-sessions--resolve (ref)
  "Return the session id REF names: an id, a unique id prefix or a unique name."
  (let ((ref (string-trim (format "%s" (or ref "")))))
    (when (string-empty-p ref) (signal 'harness-error (list "A session id is required")))
    (if (harness-call 'session/exists-p ref)
        ref
      (let* ((all (harness-call 'session/list))
             (hits (or (cl-remove-if-not (lambda (s) (string-prefix-p ref (plist-get s :id))) all)
                       (cl-remove-if-not (lambda (s) (equal (downcase ref) (downcase (or (plist-get s :name) ""))))
                                         all))))
        (pcase (length hits)
          (1 (plist-get (car hits) :id))
          (0 (signal 'harness-error (list (format "No session matches %s; use session_list to find ids" ref))))
          (_ (signal 'harness-error
                     (list (format "%s matches %d sessions (%s); give more of the id"
                                   ref (length hits)
                                   (mapconcat (lambda (s) (harness-tools-sessions--short (plist-get s :id)))
                                              hits ", "))))))))))

(defun harness-tools-sessions--other (ref ctx verb)
  "Resolve REF to a session id other than CTX's own; VERB names the action."
  (let ((id (harness-tools-sessions--resolve ref)))
    (when (equal id (plist-get ctx :session-id))
      (signal 'harness-error (list (format "A session cannot %s itself" verb))))
    id))

(defun harness-tools-sessions--refs (input key keys)
  "Return the list of references INPUT gives under KEY or the array KEYS."
  (let ((one (plist-get input key))
        (many (plist-get input keys)))
    (delete-dups (delq nil (append (and one (list one)) (append many nil))))))

;;;; Project scope

(defun harness-tools-sessions--main-root (dir cache)
  "Return the main checkout root of DIR, memoised in hash table CACHE."
  (when dir
    (or (gethash dir cache)
        (puthash dir (or (ignore-errors (harness-files-main-root dir)) dir) cache))))

(defun harness-tools-sessions--scope (input ctx)
  "Return a predicate on session plists for INPUT's project scope.
Without all_projects it keeps sessions of CTX's project, worktrees included."
  (if (harness-json-true-p (plist-get input :all_projects))
      #'always
    (let* ((cache (make-hash-table :test 'equal))
           (self (ignore-errors (harness-call 'session/get (plist-get ctx :session-id))))
           (root (harness-tools-sessions--main-root
                  (or (plist-get self :project) (plist-get ctx :cwd)) cache)))
      (lambda (s)
        (equal root (harness-tools-sessions--main-root
                     (or (plist-get s :project) (plist-get s :cwd)) cache))))))

;;;; session_list

(defun harness-tools-sessions--status (session-id)
  "Return the effective status of SESSION-ID: running as soon as a turn exists."
  (let ((status (plist-get (harness-call 'session/get session-id) :status)))
    (if (and (not (eq status 'blocked))
             (harness-method-exists-p 'agent/running)
             (harness-call 'agent/running session-id))
        'running
      status)))

(defun harness-tools-sessions--list (input ctx)
  "Handler of session_list.
INPUT is the tool call's input plist and CTX its context."
  (let* ((scope (harness-tools-sessions--scope input ctx))
         (status (let ((s (plist-get input :status))) (and s (intern s))))
         (kind (let ((k (plist-get input :kind))) (and k (intern k))))
         (parent (and (plist-get input :parent_id)
                      (harness-tools-sessions--resolve (plist-get input :parent_id))))
         (inactive (harness-json-true-p (plist-get input :include_inactive)))
         (name (plist-get input :name))
         (limit (or (plist-get input :limit) 50))
         (sessions (cl-remove-if-not
                    (lambda (s)
                      (and (funcall scope s)
                           (or inactive status (not (eq (plist-get s :status) 'inactive)))
                           (or (null status) (eq status (plist-get s :status)))
                           (or (null kind) (eq kind (plist-get s :kind)))
                           (or (null parent) (equal parent (plist-get s :parent-id)))
                           (or (null name) (string-match-p (regexp-quote (downcase name))
                                                           (downcase (or (plist-get s :name) ""))))))
                    (harness-call 'session/list)))
         (shown (seq-take sessions limit))
         (self (plist-get ctx :session-id)))
    (harness-tool-ok
     (if (null sessions)
         "No sessions match."
       (concat
        (mapconcat (lambda (s) (concat (harness-tools-sessions--line s)
                                       (if (equal (plist-get s :id) self) "  (this session)" "")))
                   shown "\n")
        (if (> (length sessions) (length shown))
            (format "\n… %d more; narrow the filters or raise limit" (- (length sessions) (length shown)))
          ""))))))

(harness-define-tool "session_list"
  :label "List sessions"
  :description "List harness sessions with id, status (idle, running, blocked, inactive), kind, name, model, working directory, cost, priority (when it is not the default medium) and what each one waits on. A task's priority is its session's. Defaults to the open sessions of this project; set include_inactive for closed ones and all_projects for every project. Session ids (or a unique prefix, or a unique name) are accepted by the other session_* tools."
  :schema '(:type "object"
            :properties (:status (:type "string" :enum ("idle" "running" "blocked" "inactive")
                                  :description "Only sessions in this status.")
                         :kind (:type "string" :description "Only sessions of this kind (main, fork, subagent, btw…).")
                         :parent_id (:type "string" :description "Only children of this session.")
                         :name (:type "string" :description "Only sessions whose name contains this text.")
                         :include_inactive (:type "boolean" :description "Include closed sessions (default false).")
                         :all_projects (:type "boolean" :description "Every project, not just this one (default false).")
                         :limit (:type "integer" :description "Most sessions to show (default 50).")))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (or (plist-get input :status) (plist-get input :name)))
  :handler #'harness-tools-sessions--list)

;;;; session_search

(defun harness-tools-sessions--json-fragment (text)
  "Return TEXT as it appears inside a JSON string."
  (let ((s (json-serialize text)))
    (substring s 1 -1)))

(defun harness-tools-sessions--locate (text query regexp)
  "Return (START . END) of the first match of QUERY in TEXT, or nil.
QUERY is literal text, or a regexp when REGEXP is non-nil; case is
ignored.  Literal text is found by one linear scan, however long TEXT
is.  A regexp that overflows the matcher over the whole of TEXT, as
`a.*b' does over a line of a megabyte, runs over overlapping pieces of
`harness-tools-sessions--piece' characters instead; a regexp Emacs
cannot read finds nothing."
  (let ((re (if regexp query (regexp-quote query)))
        (case-fold-search t))
    (condition-case nil
        (and (string-match re text) (cons (match-beginning 0) (match-end 0)))
      (invalid-regexp nil)
      (error
       (let ((len (length text))
             (piece harness-tools-sessions--piece))
         ;; Each piece overlaps the next by half, so a match up to half a
         ;; piece long lies whole in one of them.
         (cl-loop for at from 0 below len by (/ piece 2)
                  for part = (substring text at (min len (+ at piece)))
                  when (ignore-errors (string-match re part))
                  return (cons (+ at (match-beginning 0)) (+ at (match-end 0)))))))))

(defun harness-tools-sessions--squeeze (text)
  "Return TEXT with each run of whitespace made one space."
  (replace-regexp-in-string "[ \t\n\r]+" " " text t t))

(defun harness-tools-sessions--snippet (text query regexp)
  "Return the part of TEXT around the first match of QUERY (a REGEXP when non-nil).
The snippet is one line, its whitespace squeezed: up to 70 characters
before the match, the match and up to 90 after it, cut 300 characters
after the start of a long match.  Only a window of TEXT around the
match is read, so a node of megabytes costs no more than a short one."
  (let ((len (length text))
        (match (harness-tools-sessions--locate text query regexp)))
    (if (not match)
        (let ((head (harness-tools-sessions--squeeze (substring text 0 (min len 2000)))))
          (harness-truncate-end (if (> len 2000) (concat head "…") head) 160))
      (let* ((start (car match))
             (end (cdr match))
             ;; Squeezing shortens whitespace, so read more than is shown.
             (from (max 0 (- start 400)))
             (to (min len (+ end 400) (+ start 2000)))
             (upto (lambda (pos) (harness-tools-sessions--squeeze (substring text from pos))))
             (window (funcall upto to))
             (s (length (funcall upto start)))
             (e (length (funcall upto (min end to))))
             (b (max 0 (- s 70)))
             (a (min (length window) (+ e 90) (+ s 300))))
        (concat (if (or (> from 0) (> b 0)) "…" "")
                (substring window b a)
                (if (or (< to len) (< a (length window))) "…" ""))))))

(defun harness-tools-sessions--parse-hits (stdout)
  "Return ((SESSION-ID . NODE) …) from grep STDOUT, in output order.
A line of STDOUT holds a whole node, which can be megabytes long:
`harness-grep-hit' splits it without a regexp."
  (let (hits)
    (dolist (line (split-string stdout "\n" t))
      (when-let* ((hit (harness-grep-hit line ".nodes.jsonl")))
        (let ((node (ignore-errors (harness-json-parse (cdr hit)))))
          (when (stringp (plist-get node :kind))
            (setq node (plist-put node :kind (intern (plist-get node :kind)))))
          (when node (push (cons (car hit) node) hits)))))
    (nreverse hits)))

(defun harness-tools-sessions--search (input ctx)
  "Handler of session_search.
INPUT is the tool call's input plist and CTX its context."
  (let* ((query (or (plist-get input :query) ""))
         (regexp (harness-json-true-p (plist-get input :regexp)))
         (scope (harness-tools-sessions--scope input ctx))
         (self (plist-get ctx :session-id))
         (max-sessions (or (plist-get input :max_sessions) 20))
         (per-session (or (plist-get input :max_matches) 3))
         (dir (expand-file-name "sessions" harness-state-directory))
         (candidates (cl-remove-if-not
                      (lambda (s) (and (funcall scope s) (not (equal (plist-get s :id) self))))
                      (harness-call 'session/list)))
         (by-id (let ((h (make-hash-table :test 'equal)))
                  (dolist (s candidates h) (puthash (plist-get s :id) s h))))
         (files (cl-loop for s in candidates
                         for f = (expand-file-name (format "%s.nodes.jsonl" (plist-get s :id)) dir)
                         when (file-exists-p f) collect f)))
    (when (harness-string-blank-p query) (signal 'harness-error (list "session_search needs a query")))
    ;; Names match too, without reading any log.
    (let ((name-hits (cl-remove-if-not
                      (lambda (s) (let ((case-fold-search t))
                                    (ignore-errors (string-match-p (if regexp query (regexp-quote query))
                                                                   (or (plist-get s :name) "")))))
                      candidates)))
      (harness-then
       (if (null files)
           (harness-resolved (list :exit 1 :stdout ""))
         (harness-run-command
          (append (list harness-tools-sessions--grep-program "-i" "-H" (format "--max-count=%d" (* 4 per-session))
                        (if regexp "-E" "-F") "-e"
                        ;; In the log, text sits inside JSON strings.
                        (if regexp query (harness-tools-sessions--json-fragment query))
                        "--")
                  files)
          :cwd dir :timeout 60 :name "harness-session-search"))
       (lambda (r)
         (unless (memq (plist-get r :exit) '(0 1))
           (signal 'harness-error (list (format "search failed: %s" (string-trim (or (plist-get r :stderr) (format "%s" (plist-get r :exit))))))))
         (let ((grouped (make-hash-table :test 'equal)) order)
           (dolist (hit (harness-tools-sessions--parse-hits (plist-get r :stdout)))
             (let ((sid (car hit)) (node (cdr hit)))
               (when (and (gethash sid by-id)
                          (memq (plist-get node :kind) '(user assistant thinking tool-call tool-result plan compaction))
                          ;; A literal can match the JSON escapes of a line but not its text.
                          (or regexp
                              (harness-tools-sessions--locate (harness-tools-sessions--node-text node) query nil)))
                 (unless (gethash sid grouped) (push sid order))
                 (puthash sid (append (gethash sid grouped) (list node)) grouped))))
           (dolist (s name-hits)
             (unless (gethash (plist-get s :id) grouped)
               (push (plist-get s :id) order)
               (puthash (plist-get s :id) nil grouped)))
           (let* ((ids (sort (nreverse order)
                             (lambda (a b) (> (or (plist-get (gethash a by-id) :updated) 0)
                                              (or (plist-get (gethash b by-id) :updated) 0)))))
                  (shown (seq-take ids max-sessions)))
             (harness-tool-ok
              (if (null ids)
                  (format "No session mentions %S." query)
                (concat
                 (mapconcat
                  (lambda (sid)
                    (let ((nodes (gethash sid grouped)))
                      (concat (harness-tools-sessions--line (gethash sid by-id))
                              (mapconcat (lambda (n)
                                           (format "\n    %s %s" (harness-tools-sessions--tag n)
                                                   (harness-tools-sessions--snippet
                                                    (harness-tools-sessions--node-text n) query regexp)))
                                         (seq-take nodes per-session) "")
                              (if (> (length nodes) per-session)
                                  (format "\n    … %d more matches" (- (length nodes) per-session))
                                ""))))
                  shown "\n")
                 (if (> (length ids) (length shown))
                     (format "\n… %d more sessions match" (- (length ids) (length shown)))
                   "")))))))))))

(harness-define-tool "session_search"
  :label "Search sessions"
  :description "Search the transcripts of other sessions (messages, thinking, tool calls and results) and their names for a string, case-insensitively. Returns the matching sessions, newest first, with snippets and node ids; read one with session_read. Searches this project unless all_projects is set; closed sessions are included. This session's own conversation from before a compaction is searched with session_history instead."
  :schema '(:type "object"
            :properties (:query (:type "string" :description "Text to find.")
                         :regexp (:type "boolean" :description "Treat query as an extended regular expression (default false).")
                         :all_projects (:type "boolean" :description "Search every project (default false).")
                         :max_sessions (:type "integer" :description "Most sessions to return (default 20).")
                         :max_matches (:type "integer" :description "Snippets per session (default 3)."))
            :required ("query"))
  :kind 'read
  :coalescable t
  :timeout 90
  :subject (lambda (input) (harness-first-line (plist-get input :query) 60))
  :handler #'harness-tools-sessions--search)

;;;; session_read

(defun harness-tools-sessions--read (input _ctx)
  "Handler of session_read.
INPUT is the tool call's input plist."
  (let* ((sid (harness-tools-sessions--resolve (plist-get input :session_id)))
         (s (harness-call 'session/get sid))
         (limit (or (plist-get input :limit) 20))
         (chars (or (plist-get input :max_chars) 1500))
         (kinds (mapcar #'intern (append (plist-get input :kinds) nil)))
         (before (plist-get input :before))
         (all (harness-call 'session/nodes sid (and before (list :before before))))
         (nodes (if kinds
                    (cl-remove-if-not (lambda (n) (memq (plist-get n :kind) kinds)) all)
                  (cl-remove-if (lambda (n) (memq (plist-get n :kind) '(hint))) all)))
         (shown (last nodes limit)))
    (harness-tool-ok
     (concat
      (harness-tools-sessions--line s)
      (if (plist-get s :plan) (format "\nPlan:\n%s" (harness-truncate-end (plist-get s :plan) chars)) "")
      (if (plist-get s :todos)
          (concat "\nTodos:\n"
                  (mapconcat (lambda (td) (format "  %s %s" (pcase (plist-get td :status)
                                                              ((or 'done "done") "[x]")
                                                              ((or 'in-progress "in-progress") "[~]")
                                                              (_ "[ ]"))
                                                  (plist-get td :text)))
                             (plist-get s :todos) "\n"))
        "")
      (format "\n\nTranscript (%d of %d nodes%s):\n" (length shown) (length nodes)
              (if (> (length nodes) (length shown))
                  (format "; earlier ones with before=%s" (plist-get (car shown) :id))
                ""))
      (mapconcat (lambda (n)
                   (format "%s %s" (harness-tools-sessions--tag n)
                           (harness-truncate-end (harness-tools-sessions--node-text n) chars)))
                 shown "\n")))))

(harness-define-tool "session_read"
  :label "Read session"
  :description "Read another session: its status, plan, todos and the last nodes of its transcript (user and assistant messages, thinking, tool calls and results). Page back with before=<node id> from the previous result."
  :schema '(:type "object"
            :properties (:session_id (:type "string" :description "Session id, unique id prefix or unique name.")
                         :limit (:type "integer" :description "Most nodes to show, newest last (default 20).")
                         :before (:type "string" :description "Show nodes before this node id.")
                         :kinds (:type "array" :items (:type "string" :enum ("user" "assistant" "thinking" "tool-call" "tool-result" "plan" "compaction" "hint"))
                                 :description "Only these node kinds (default: all but hints).")
                         :max_chars (:type "integer" :description "Characters kept per node (default 1500)."))
            :required ("session_id"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (harness-tools-sessions--short (plist-get input :session_id)))
  :handler #'harness-tools-sessions--read)

;;;; session_history

(defconst harness-tools-sessions--history-kinds
  '(user assistant thinking tool-call tool-result plan compaction)
  "The kinds of node session_history shows and searches by default.")

(defconst harness-tools-sessions--history-whole 20000
  "Characters of the node session_history shows whole, by default.")

(defconst harness-tools-sessions--history-around 2
  "Nodes before and after the node session_history shows whole.")

(defun harness-tools-sessions--boundary (path)
  "Return the position in PATH of the node this conversation opens with, or nil.
That is its last compaction node, or its last handoff note when that
comes later: what the model is sent starts there, and the nodes before
it reach the model only as that node tells of them -- a summary, a
transcript file, or nothing."
  (cl-position-if (lambda (n) (or (eq (plist-get n :kind) 'compaction) (harness-node-handoff n)))
                  path :from-end t))

(defun harness-tools-sessions--when (node)
  "Return when NODE was written, as a short date and time, or nil."
  (let ((ts (plist-get node :ts)))
    (and (numberp ts) (format-time-string "%b %-d %H:%M" ts))))

(defun harness-tools-sessions--history-scope (path boundary all)
  "Describe what session_history looks through, for its first line.
PATH is the conversation, BOUNDARY the position of the node it opens
with or nil, ALL non-nil when the whole of it is looked through."
  (let* ((node (and boundary (nth boundary path)))
         (what (cond ((null node) nil)
                     ((harness-node-handoff node)
                      (format "the handoff from %s"
                              (or (plist-get (harness-node-handoff node) :from) "another model")))
                     (t (format "the %scompaction"
                                (let ((kind (harness-node-compaction-kind node)))
                                  (if (member kind '("summary" "brief" "transcript" "fresh"))
                                      (concat kind " ")
                                    ""))))))
         (stamp (and node (format "[%s %s, %s]" (plist-get node :kind) (plist-get node :id)
                                  (or (harness-tools-sessions--when node) "undated")))))
    (cond ((null node)
           (format "This conversation was never compacted: all %d nodes are in your context already."
                   (length path)))
          (all (format "The whole conversation, %d nodes, %s %s included." (length path) what stamp))
          (t (format "The conversation before %s %s: %d nodes your context holds only as that node tells of them."
                     what stamp boundary)))))

(defun harness-tools-sessions--history-line (node chars &optional query regexp)
  "Return the line of NODE in session_history's answer.
Its tag and date, then its text cut to CHARS, or the snippet around
QUERY (a REGEXP when non-nil) when one is given."
  (let ((text (harness-tools-sessions--node-text node))
        (stamp (harness-tools-sessions--when node)))
    (format "%s%s %s" (harness-tools-sessions--tag node)
            (if stamp (format " (%s)" stamp) "")
            (if query
                (harness-tools-sessions--snippet text query regexp)
              (harness-truncate-end text chars)))))

(defun harness-tools-sessions--history-node (path node-id chars)
  "Return session_history's answer for node NODE-ID of PATH: whole, in context.
Its text is cut to CHARS; the nodes around it are shown short."
  (let ((at (cl-position node-id path :key (lambda (n) (plist-get n :id)) :test #'equal))
        (around harness-tools-sessions--history-around))
    (unless at
      (signal 'harness-error
              (list (format "No node %s in this session's conversation; session_history with query finds ids"
                            node-id))))
    (let ((from (max 0 (- at around)))
          (to (min (length path) (+ at around 1))))
      (mapconcat (lambda (i)
                   (let ((n (nth i path)))
                     (if (= i at)
                         (format "%s%s, the node asked for:\n%s"
                                 (harness-tools-sessions--tag n)
                                 (let ((stamp (harness-tools-sessions--when n)))
                                   (if stamp (format " (%s)" stamp) ""))
                                 (harness-truncate-end (harness-tools-sessions--node-text n) chars))
                       (harness-tools-sessions--history-line n 300))))
                 (number-sequence from (1- to)) "\n"))))

(defun harness-tools-sessions--history (input ctx)
  "Handler of session_history."
  (let* ((sid (plist-get ctx :session-id))
         (path (harness-call 'session/nodes sid))
         (boundary (harness-tools-sessions--boundary path))
         (all (harness-json-true-p (plist-get input :all)))
         (scope (if (and boundary (not all)) (seq-take path boundary) path))
         (query (let ((q (plist-get input :query))) (and (not (harness-string-blank-p q)) q)))
         (regexp (harness-json-true-p (plist-get input :regexp)))
         (node-id (let ((id (plist-get input :node_id))) (and (not (harness-string-blank-p id)) id)))
         (before (let ((id (plist-get input :before))) (and (not (harness-string-blank-p id)) id)))
         (limit (max 1 (or (plist-get input :limit) 20)))
         (kinds (or (mapcar #'intern (append (plist-get input :kinds) nil))
                    harness-tools-sessions--history-kinds))
         (header (harness-tools-sessions--history-scope path boundary all)))
    (harness-tool-ok
     (if node-id
         (concat header "\n\n"
                 (harness-tools-sessions--history-node
                  path node-id (or (plist-get input :max_chars) harness-tools-sessions--history-whole)))
       (let* ((upto (if before
                        (or (cl-position before scope :key (lambda (n) (plist-get n :id)) :test #'equal)
                            (signal 'harness-error
                                    (list (format "No node %s in what session_history looks through" before))))
                      (length scope)))
              (nodes (cl-remove-if-not (lambda (n) (memq (plist-get n :kind) kinds)) (seq-take scope upto)))
              (chars (or (plist-get input :max_chars) 1500)))
         (if query
             (let* ((hits (nreverse
                           (cl-remove-if-not
                            (lambda (n) (harness-tools-sessions--locate
                                         (harness-tools-sessions--node-text n) query regexp))
                            nodes)))
                    (shown (seq-take hits limit)))
               (concat header "\n\n"
                       (if (null hits)
                           (format "Nothing%s mentions %S." (if before (format " before %s" before) "") query)
                         (concat
                          (format "%d node%s mention%s %S, newest first%s:\n"
                                  (length hits) (if (= 1 (length hits)) "" "s")
                                  (if (= 1 (length hits)) "s" "") query
                                  (if before (format ", before %s" before) ""))
                          (mapconcat (lambda (n) (harness-tools-sessions--history-line n chars query regexp))
                                     shown "\n")
                          (if (> (length hits) (length shown))
                              (format "\n… %d older; page back with before=%s"
                                      (- (length hits) (length shown)) (plist-get (car (last shown)) :id))
                            "")
                          "\nRead a node whole with node_id."))))
           (let ((shown (last nodes limit)))
             (concat header "\n\n"
                     (if (null shown)
                         (format "Nothing to show%s." (if before (format " before %s" before) ""))
                       (concat
                        (format "%d of %d nodes, oldest first%s:\n" (length shown) (length nodes)
                                (if (> (length nodes) (length shown))
                                    (format "; earlier ones with before=%s" (plist-get (car shown) :id))
                                  ""))
                        (mapconcat (lambda (n) (harness-tools-sessions--history-line n chars)) shown "\n")
                        "\nRead a node whole with node_id; find one with query."))))))))))

(harness-define-tool "session_history"
  :label "Session history"
  :description "Search and read this session's own conversation from before its last compaction (or a handoff from another model): the part your context holds only as a summary, a pointer to a transcript file, or not at all. Use it when you need something from back then -- what was asked, decided, tried, found or changed -- rather than guessing or redoing the work. query finds the messages, thinking, tool calls and results that mention it, newest first, with snippets and node ids; node_id shows one node whole with the nodes around it; with neither, the last nodes before the compaction, oldest first. Page back with before=<node id>. all=true looks through the whole conversation, the part since the compaction included. For other sessions, use session_search and session_read."
  :schema '(:type "object"
            :properties (:query (:type "string" :description "Text to find, case-insensitively.")
                         :regexp (:type "boolean" :description "Treat query as an Emacs regular expression (default false).")
                         :node_id (:type "string" :description "Show this node whole, with the nodes around it.")
                         :before (:type "string" :description "Only nodes before this node id: pages back.")
                         :limit (:type "integer" :description "Most nodes or matches to show (default 20).")
                         :max_chars (:type "integer" :description "Characters kept per node (default 1500; 20000 for node_id).")
                         :kinds (:type "array" :items (:type "string" :enum ("user" "assistant" "thinking" "tool-call" "tool-result" "plan" "compaction" "hint"))
                                 :description "Only these node kinds (default: all but hints).")
                         :all (:type "boolean" :description "Look through the whole conversation, not just the part before the compaction (default false).")))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (or (and (plist-get input :query) (harness-first-line (plist-get input :query) 60))
                               (plist-get input :node_id)))
  :handler #'harness-tools-sessions--history)

;;;; session_send

(defun harness-tools-sessions--from (ctx)
  "Return the header that marks a message as sent by CTX's session."
  (let* ((sid (plist-get ctx :session-id))
         (s (ignore-errors (harness-call 'session/get sid))))
    (format "[Message from session %s%s]\n\n" sid
            (if (plist-get s :name) (format " %S" (plist-get s :name)) ""))))

(defun harness-tools-sessions--sender (ctx)
  "Return the sender of a message CTX's session sends (see `agent/prompt')."
  (let ((sid (plist-get ctx :session-id)))
    (harness-sender-session (or (ignore-errors (harness-call 'session/get sid)) (list :id sid)))))

(defun harness-tools-sessions--send (input ctx)
  "Handler of session_send.
INPUT is the tool call's input plist and CTX its context."
  (let* ((sid (harness-tools-sessions--other (plist-get input :session_id) ctx "message"))
         (text (or (plist-get input :message) ""))
         (queue (equal (plist-get input :mode) "queue"))
         (wait (harness-json-true-p (plist-get input :wait)))
         (s (harness-call 'session/get sid))
         (running (eq (harness-tools-sessions--status sid) 'running)))
    (when (harness-string-blank-p text) (signal 'harness-error (list "session_send needs a message")))
    (when (eq (plist-get s :status) 'inactive) (harness-call 'session/resume sid))
    (let* ((body (concat (harness-tools-sessions--from ctx) text))
           (promise (harness-call 'agent/prompt sid body
                                  (append (list :from (harness-tools-sessions--sender ctx))
                                          (and queue (list :queue t)))))
           (how (cond (queue "queued for its next turn")
                      (running "delivered as steering to its running turn")
                      (t "delivered; it started a turn"))))
      (if (or queue (not wait))
          (progn
            ;; The turn's own failures surface in that session; keep them out of the log here.
            (harness-catch promise #'ignore)
            (harness-tool-ok (format "Message %s (session %s). Use session_wait to wait for its reply." how sid)))
        (harness-then promise
                      (lambda (result)
                        (harness-tool-ok
                         (format "Message %s; the turn ended: %s%s\n\n%s" how (plist-get result :stop-reason)
                                 (if (plist-get result :error) (format " (%s)" (plist-get result :error)) "")
                                 (harness-tools-sessions--describe sid 8000)))))))))

(harness-define-tool "session_send"
  :label "Message session"
  :description "Send a message to another session, as the user would. An idle or closed session starts a turn; a running one gets it as steering at its next step; mode=queue holds it for the session's next turn instead. The message is marked as coming from this session. wait=true returns once the turn ends, with the session's reply; otherwise it returns at once (follow with session_wait)."
  :schema '(:type "object"
            :properties (:session_id (:type "string" :description "Session id, unique id prefix or unique name.")
                         :message (:type "string" :description "The message.")
                         :mode (:type "string" :enum ("send" "queue") :description "send (default) or queue for the next turn.")
                         :wait (:type "boolean" :description "Wait for the turn to end and return the reply (default false)."))
            :required ("session_id" "message"))
  :kind 'meta
  :timeout 3600
  :subject (lambda (input) (string-trim (format "%s %s" (harness-tools-sessions--short (plist-get input :session_id))
                                                (harness-first-line (plist-get input :message) 50))))
  :handler #'harness-tools-sessions--send)

;;;; session_control

(defun harness-tools-sessions--control (input ctx)
  "Handler of session_control.
INPUT is the tool call's input plist and CTX its context."
  (let* ((action (or (plist-get input :action) ""))
         (sid (harness-tools-sessions--other (plist-get input :session_id) ctx action)))
    (pcase action
      ("cancel"
       (harness-tool-ok (if (harness-call 'agent/cancel sid)
                            (format "Cancelling the turn of %s." sid)
                          (format "%s had no running turn." sid))))
      ("resume"
       (harness-call 'session/resume sid)
       (harness-tool-ok (format "Resumed %s; it is %s." sid (harness-tools-sessions--status sid))))
      ("close"
       (when (eq (harness-tools-sessions--status sid) 'running)
         (signal 'harness-error (list (format "%s is running; cancel it first" sid))))
       (harness-call 'session/deactivate sid)
       (harness-tool-ok (format "Closed %s; it stays in the session list and can be resumed." sid)))
      ("rename"
       (let ((name (string-trim (or (plist-get input :name) ""))))
         (when (string-empty-p name) (signal 'harness-error (list "rename needs a name")))
         (harness-call 'session/update sid :name name)
         (harness-tool-ok (format "Renamed %s to %S." sid name))))
      ("answer"
       (unless (harness-method-exists-p 'question/answer)
         (signal 'harness-error (list "Questions are not available")))
       (let* ((questions (harness-call 'question/pending sid))
              (qid (plist-get input :question_id))
              (q (if qid
                     (cl-find qid questions :key (lambda (it) (plist-get it :id)) :test #'equal)
                   (and (= 1 (length questions)) (car questions))))
              (answer (or (plist-get input :answer) "")))
         (cond ((null questions) (signal 'harness-error (list (format "%s has no open question" sid))))
               ((null q) (signal 'harness-error
                                 (list (format "Give question_id, one of: %s"
                                               (mapconcat (lambda (it) (format "%s" (plist-get it :id))) questions ", ")))))
               ;; What a cold prompt cache is worth spending is the
               ;; user's call (harness-cowboy.el), not another agent's.
               ((plist-get (plist-get q :payload) :cowboy)
                (signal 'harness-error
                        (list (format "Question %s asks the user what to do about %s's cold prompt cache; that is left to the user"
                                      (plist-get q :id) sid))))
               ((harness-string-blank-p answer) (signal 'harness-error (list "answer needs an answer"))))
         (harness-call 'question/answer sid (plist-get q :id) (list :answer answer))
         (harness-tool-ok (format "Answered %S in %s." (plist-get (plist-get q :payload) :question) sid))))
      (_ (signal 'harness-error (list (format "Unknown action %S" action)))))))

(harness-define-tool "session_control"
  :label "Control session"
  :description "Control another session. action=cancel stops its running turn; resume reopens a closed session; close deactivates it (it can be resumed later); rename sets its name; answer replies to a question it asked with ask_user (question_id may be omitted when there is one). Permission requests, and the harness's question about a cold prompt cache, are left to the user."
  :schema '(:type "object"
            :properties (:session_id (:type "string" :description "Session id, unique id prefix or unique name.")
                         :action (:type "string" :enum ("cancel" "resume" "close" "rename" "answer"))
                         :name (:type "string" :description "New name, for rename.")
                         :question_id (:type "string" :description "Question to answer, for answer.")
                         :answer (:type "string" :description "The answer, for answer."))
            :required ("session_id" "action"))
  :kind 'meta
  :subject (lambda (input) (string-trim (format "%s %s" (or (plist-get input :action) "")
                                                (harness-tools-sessions--short (plist-get input :session_id)))))
  :handler #'harness-tools-sessions--control)

;;;; set_non_interactive

(defun harness-tools-sessions--plural (n word)
  "Return N WORDs, as \"1 session\" or \"2 sessions\"."
  (format "%d %s%s" n word (if (= n 1) "" "s")))

(defun harness-tools-sessions--set-all-non-interactive (value)
  "Set non-interactive mode to VALUE (t or :false) on everything current.
That is every active session and the session of every current task, of
every project (`session/set-all' with `:active' and `:tasks'), then the
current tasks' records (`task/set-all'), which a task's next start
uses; the task sessions already changed are not told twice.  The same
two calls as `harness-set-non-interactive-all'.  Return (SESSIONS
. TASKS), the ids that changed."
  (let ((sessions (harness-call 'session/set-all (list :non-interactive value)
                                (list :active t :tasks t)))
        (tasks (and (harness-method-exists-p 'task/set-all)
                    (harness-call 'task/set-all (list :non-interactive value)))))
    (cons sessions tasks)))

(defun harness-tools-sessions--set-non-interactive (input ctx)
  "Handler of set_non_interactive, with the call's INPUT and CTX.
It runs only once the permission chain allowed the call, which for
turning the mode on means the user confirmed it: see
`harness-perms--away-request'.  One session, CTX's own by default, or
with `all' everything current (see
`harness-tools-sessions--set-all-non-interactive').  The default for
new sessions is the user's to change, so it is left alone."
  (let* ((on (harness-json-true-p (plist-get input :enabled)))
         (value (if on t :false))
         (word (if on "on" "off"))
         (ref (let ((r (plist-get input :session_id)))
                (and (stringp r) (not (harness-string-blank-p r)) r))))
    (cond
     ((and ref (harness-json-true-p (plist-get input :all)))
      (harness-tool-error "Give session_id or all, not both"))
     ((harness-json-true-p (plist-get input :all))
      (pcase-let ((`(,sessions . ,tasks) (harness-tools-sessions--set-all-non-interactive value)))
        (harness-tool-ok
         (format "Non-interactive mode is %s for every current session and task of every project: %s and %s changed, the others had it %s already. %s"
                 word (harness-tools-sessions--plural (length sessions) "session")
                 (harness-tools-sessions--plural (length tasks) "task") word
                 (if on "From now on the auto-mode judge decides what would ask the user there, and a denied call is to be worked around rather than waited on."
                   "The user is asked again what the sessions' permission modes leave open.")))))
     (t
      (let* ((sid (if ref (harness-tools-sessions--resolve ref) (plist-get ctx :session-id)))
             (session (harness-call 'session/get sid))
             (task (and (harness-method-exists-p 'task/for-session)
                        (harness-call 'task/for-session sid)))
             (changed (not (harness-setting-equal-p :non-interactive value
                                                    (plist-get session :non-interactive)))))
        (when changed
          (harness-call 'session/update sid :non-interactive value))
        ;; Its task's record too, for the task's next start; the session,
        ;; changed already, is not told twice.
        (when (and task (harness-method-exists-p 'task/set-all))
          (harness-call 'task/set-all (list :non-interactive value)
                        (list :ids (list (plist-get task :id)))))
        (harness-tool-ok
         (format "Non-interactive mode %s %s for %s."
                 (if changed "is now" "was already") word
                 (if (equal sid (plist-get ctx :session-id)) "this session"
                   (format "session %s %S" sid (or (plist-get session :name) "(unnamed)"))))))))))

(harness-define-tool "set_non_interactive"
  :label "Non-interactive mode"
  :description "Turn non-interactive mode on or off, for this session, another one, or every current session and task of every project (all=true), when the user asks you to: before they leave, say, or once they are back. In a non-interactive session nobody is asked: the auto-mode judge decides what would ask the user, and a denied call is to be worked around rather than waited on. Turning it on always asks the user to confirm, in every permission mode, and the call waits for the answer; a non-interactive session cannot ask, so its request to turn it on is denied at once. Turning it off needs no confirmation. The default for new sessions is left to the user."
  :schema '(:type "object"
            :properties (:enabled (:type "boolean" :description "true to turn non-interactive mode on, false to turn it off.")
                         :session_id (:type "string" :description "The session to change: id, unique id prefix or unique name. Default: this session.")
                         :all (:type "boolean" :description "Change every current session and task of every project instead (default false).")
                         :reason (:type "string" :description "Why; shown to the user when they are asked to confirm."))
            :required ("enabled"))
  :kind 'meta
  :subject (lambda (input)
             (string-trim (format "%s %s" (if (harness-json-true-p (plist-get input :enabled)) "on" "off")
                                  (if (harness-json-true-p (plist-get input :all)) "all"
                                    (harness-tools-sessions--short (plist-get input :session_id))))))
  :handler #'harness-tools-sessions--set-non-interactive)

;;;; set_priority

(defun harness-tools-sessions--priority-p ()
  "Signal unless the priority module is loaded."
  (unless (harness-method-exists-p 'priority/set)
    (signal 'harness-error (list "The priority module is not loaded, so a session has no priority"))))

(defun harness-tools-sessions--set-all-priority (level)
  "Give every current session and task session LEVEL; return the ids changed.
That is every active session and the session of every current task, of
every project: `priority/set-all' with `:active' and `:tasks', the
filter `session/select' reads, and the one call the UI's
`harness-set-priority-all' makes.  A session already carrying LEVEL of
its own is left alone."
  (harness-call 'priority/set-all (symbol-name level) (list :active t :tasks t)))

(defun harness-tools-sessions--set-priority (input ctx)
  "Handler of set_priority, with the call's INPUT and CTX.
One session, CTX's own by default, or with `all' every current session
and task of every project.  A priority is the session's -- a task's is
its session's, the one `task_list' names -- and it orders the queues
the session's work waits in: the higher it is, the sooner its calls and
its commands go when the machine is busy (see the tool slots)."
  (harness-tools-sessions--priority-p)
  (let* ((value (plist-get input :priority))
         (ref (let ((r (plist-get input :session_id)))
                (and (stringp r) (not (harness-string-blank-p r)) r)))
         (level (if (harness-string-blank-p value)
                    (signal 'harness-error (list "priority needs priority: low, medium or high"))
                  (harness-priority-read value))))
    (cond
     ((and ref (harness-json-true-p (plist-get input :all)))
      (harness-tool-error "Give session_id or all, not both"))
     ((harness-json-true-p (plist-get input :all))
      (let ((changed (harness-tools-sessions--set-all-priority level)))
        (harness-tool-ok
         (format "Priority is now %s for every current session and task of every project: %s changed, the others already had it. When the machine is busy the work of the higher ones is served first."
                 (symbol-name level)
                 (harness-tools-sessions--plural (length changed) "session")))))
     (t
      (let* ((sid (if ref (harness-tools-sessions--resolve ref) (plist-get ctx :session-id)))
             (session (harness-call 'session/get sid))
             (was (harness-priority-of-ext (plist-get session :ext))))
        (harness-call 'priority/set sid (symbol-name level))
        (harness-tool-ok
         (format "Priority %s %s for %s."
                 (if (eq level was) "was already" "is now")
                 (symbol-name level)
                 (if (equal sid (plist-get ctx :session-id)) "this session"
                   (format "session %s %S" sid (or (plist-get session :name) "(unnamed)"))))))))))

(harness-define-tool "set_priority"
  :label "Set priority"
  :description "Give a session a priority: low, medium (the default) or high. The higher it is, the sooner the session's calls and commands go while the machine is busy (the tool slots), so a high session is served before a medium one and a low one last. A task's priority is its session's (task_list names that session), and a task waiting for a slot starts by it, so this is how a task's priority is changed; every task has its session from submission. One session, this session by default, or with all=true every current session and task of every project."
  :schema '(:type "object"
            :properties (:session_id (:type "string" :description "The session to change: id, unique id prefix or unique name. Default: this session.")
                         :priority (:type "string" :enum ("low" "medium" "high")
                                    :description "The new priority, for the session (or for every session, with all).")
                         :all (:type "boolean" :description "Give every current session and task of every project this priority instead (default false)."))
            :required ("priority"))
  :kind 'meta
  :subject (lambda (input)
             (string-trim (format "%s %s" (or (plist-get input :priority) "")
                                  (if (harness-json-true-p (plist-get input :all)) "all"
                                    (harness-tools-sessions--short (plist-get input :session_id))))))
  :handler #'harness-tools-sessions--set-priority)

;;;; session_move
;;
;; A session started in one directory that works on another moves
;; there, and the session list files it under the other project.  The
;; user confirms every move, in every permission mode: it changes the
;; directories the session may reach.  The call's own stage in the
;; permission chain asks (`harness-tools-sessions--move-gate'), ahead of
;; the jail, the mode, the standing rules and the judge, and hands the
;; handler what the user confirmed; the handler moves nothing else.

(declare-function harness-perms-confirm "harness-perms" (request next &rest prompt))

(defvar harness-tools-sessions--confirmed (make-symbol "confirmed")
  "Marks the input of a session_move call the user confirmed.
Only the call's permission stage puts it there, and no input a model
sends can hold it: the handler never moves a session unasked.  A
`defvar', so a reload keeps it and a prompt answered after one still
moves the session.")

(defun harness-tools-sessions--move-target (input self)
  "Return the id of the session a session_move call with INPUT moves.
That is INPUT's session_id, by default SELF, the calling session."
  (let ((ref (plist-get input :session_id)))
    (if (or (null ref) (harness-string-blank-p (format "%s" ref)))
        self
      (harness-tools-sessions--resolve ref))))

(defun harness-tools-sessions--move-prompt (check self keep why)
  "Return (TITLE . REASON), the prompt that has the user confirm CHECK.
CHECK is what `session/move-check' says of the move; SELF is the
calling session's id, KEEP whether the old directory stays allowed and
WHY the reason the agent gave."
  (let* ((selfp (equal (plist-get check :id) self))
         (who (if selfp "this session"
                (format "%s" (or (plist-get check :name)
                                 (harness-tools-sessions--short (plist-get check :id))))))
         (old (abbreviate-file-name (plist-get check :old-cwd)))
         (new (abbreviate-file-name (plist-get check :cwd)))
         (project (plist-get check :project))
         (moves (format "%s from %s to %s%s"
                        (if selfp "This session moves" (format "Session %s moves" who))
                        old new
                        (if (and project (not (equal (file-name-as-directory project) (plist-get check :cwd))))
                            (format " (project %s)" (abbreviate-file-name project))
                          ""))))
    ;; The title is the tool's label and the call's subject, as the call
    ;; shows them: the directory, after the session when it is another.
    (cons (if selfp (format "Move session: %s" new) (format "Move session: %s → %s" who new))
          (concat
           (cond (selfp (concat "When this turn ends, " (downcase (substring moves 0 1)) (substring moves 1)
                                (format "; %s is allowed for the rest of the turn" new)))
                 ((plist-get check :defer) (concat moves " when the turn it is running ends"))
                 (t moves))
           (if keep (format ", and keeps access to %s." old) (format "; access to %s is not kept." old))
           " Its next turn starts a new provider conversation there, which gets the transcript."
           (if (and (stringp why) (not (harness-string-blank-p why)))
               (format " The agent says: %s" (string-trim why))
             "")))))

(defun harness-tools-sessions--move-gate (decision next request)
  "Have the user confirm REQUEST when it calls session_move, then go on with NEXT.
Other requests go on with DECISION as it is.
A `permission/decide' stage, at 6, ahead of the jail: a move changes
the directories a session may reach, so the user decides each one,
whatever the permission mode, the standing rules or the judge would
say, and the decision handed to NEXT is final.  The handler gets the
move the user confirmed (`harness-tools-sessions--confirmed'), the
directory absolute.  A move that cannot be made asks nobody: its
handler says why.  Moving a session back to where it works only
cancels the move it waits to make, and asks nobody either."
  (if (not (equal (plist-get request :tool) "session_move"))
      (funcall next decision)
    (let* ((input (plist-get request :input))
           (self (plist-get (plist-get request :session) :id))
           (keep (and (harness-json-true-p (plist-get input :keep_old_directory)) t))
           (check (condition-case err
                      (harness-call 'session/move-check (harness-tools-sessions--move-target input self)
                                    (format "%s" (or (plist-get input :directory) "")))
                    (error (harness-tools-reason err))))
           (confirmed (and (consp check)
                           (list :session_id (plist-get check :id) :directory (plist-get check :cwd)
                                 :keep_old_directory keep :confirmed harness-tools-sessions--confirmed))))
      (cond
       ((stringp check)
        (funcall next (list :behavior 'allow :final t :input (list :refused check)
                            :reason "the session cannot move; there is nothing to confirm")))
       ((plist-get check :cancel)
        (funcall next (list :behavior 'allow :final t :input confirmed
                            :reason "the session stays where it works; only the move it waits to make goes")))
       ((not (fboundp 'harness-perms-confirm))
        (funcall next (list :behavior 'deny :final t
                            :reason "moving a session needs the user's confirmation, and nothing can ask for it")))
       (t
        (pcase-let ((`(,title . ,reason) (harness-tools-sessions--move-prompt check self keep (plist-get input :reason))))
          (harness-perms-confirm (plist-put (copy-sequence request) :input (harness-plist-remove input :reason))
                                 next
                                 :title title :reason reason
                                 :paths (list (plist-get check :cwd))
                                 :input confirmed
                                 :hint "Do not ask again unless the user wants it; work where the session is.")))))))

(defun harness-tools-sessions--move (input ctx)
  "Handler of session_move: make the move the user confirmed.
INPUT comes from the call's permission stage, not from the model; CTX
is the tool context, which names the calling session.  A move that
can no longer be made, things having changed while the user was asked,
fails with the harness's reason."
  (cond
   ((plist-get input :refused) (harness-tool-error (plist-get input :refused)))
   ((not (eq (plist-get input :confirmed) harness-tools-sessions--confirmed))
    (harness-tool-error "session_move needs the user's confirmation, and none was asked for"))
   (t
    (condition-case err
        (harness-tools-sessions--make-move input ctx)
      (harness-error (harness-tool-error (harness-tools-reason err)))))))

(defun harness-tools-sessions--make-move (input ctx)
  "Make the move INPUT names, which the user confirmed, and report it.
CTX is the tool context, which names the calling session."
  (let* ((sid (plist-get input :session_id))
         (self (plist-get ctx :session-id))
         (selfp (equal sid self))
         (before (harness-call 'session/get sid))
         (old (plist-get before :cwd))
         (result (harness-call 'session/move sid (plist-get input :directory)
                               :keep-old-dir (plist-get input :keep_old_directory)))
         (move (plist-get result :move))
         (new (abbreviate-file-name (or (plist-get move :cwd) (plist-get result :cwd))))
         (who (if selfp "This session" (format "Session %s" (or (plist-get result :name) (harness-tools-sessions--short sid)))))
         (project (abbreviate-file-name (or (plist-get move :project) (plist-get result :project) ""))))
    (cond
     ((and (null move) (equal (plist-get result :cwd) old))
      (harness-tool-ok (format "%s stays in %s; the move it was waiting to make is cancelled."
                               who (abbreviate-file-name old))))
     ((and move selfp)
      (when (harness-method-exists-p 'permission/allow-dir)
        (harness-call 'permission/allow-dir sid (plist-get move :cwd) 'turn))
      (harness-tool-ok
       (format "This session moves to %s (project %s) when this turn ends. Until then its working directory stays %s, so give paths in %s as absolute paths; it is allowed for the rest of this turn.%s The next turn starts a new provider conversation there, which gets the transcript."
               new project (abbreviate-file-name old) new
               (if (plist-get move :keep-old-dir) (format " %s stays allowed after the move." (abbreviate-file-name old)) ""))))
     (move
      (harness-tool-ok (format "%s is running a turn; it moves to %s (project %s) when that turn ends." who new project)))
     (t
      (harness-tool-ok
       (format "%s moved from %s to %s and is listed under project %s.%s Its next turn starts a new provider conversation there, which gets the transcript."
               who (abbreviate-file-name old) new project
               (if (plist-get input :keep_old_directory)
                   (format " %s stays allowed." (abbreviate-file-name old))
                 "")))))))

(harness-define-tool "session_move"
  :label "Move session"
  :description "Move a session to another working directory, and with it to that directory's project: for a session started in one place that works on another. The user is always asked to confirm, in every permission mode, since the session then reaches the new directory instead of the old one (keep_old_directory keeps the old one allowed too). session_id defaults to this session. This session, or another one running a turn, moves when its turn ends; until then its working directory stays the old one, and the new one is allowed for the rest of the turn. A moved session's next turn starts a new provider conversation in the new directory, which gets the transcript. Sessions in worktrees, task sessions and sessions with merges queued cannot move; a non-interactive session cannot ask. Moving a session back to where it works cancels a move it waits to make."
  :schema '(:type "object"
            :properties (:directory (:type "string" :description "The new working directory, absolute or relative to the session's current one.")
                         :session_id (:type "string" :description "Session id, unique id prefix or unique name; default: this session.")
                         :keep_old_directory (:type "boolean" :description "Keep the old working directory allowed (default false).")
                         :reason (:type "string" :description "Why the session should move; shown to the user."))
            :required ("directory"))
  :kind 'meta
  :subject (lambda (input)
             (string-trim (format "%s%s"
                                  (let ((ref (plist-get input :session_id)))
                                    (if (and (stringp ref) (not (harness-string-blank-p ref)))
                                        (concat (harness-tools-sessions--short ref) " → ")
                                      ""))
                                  (or (plist-get input :directory) ""))))
  :handler #'harness-tools-sessions--move)

;;;; Waiting

(defvar harness-tools-sessions--waiters (make-hash-table :test 'equal)
  "Wait id -> (:check FN :finish FN :session-id ID) for running waits.
CHECK returns non-nil once the wait's condition holds; FINISH settles
the wait, taking `met', `timeout' or `cancelled'.  A wait made by a
call (`task_wait') settles with a result for its promise.  One
registered by `session_wait' carries `:wake' t (and the `:label' its
outstanding line shows): it outlives the turn that made it and wakes
its session with a message when an event settles it.")

(defun harness-tools-sessions--wait-title (sid)
  "Return how a wait's note names session SID."
  (let* ((short (harness-tools-short-id sid))
         (session (ignore-errors (harness-call 'session/get sid)))
         (name (plist-get session :name)))
    (if (and (stringp name) (not (harness-string-blank-p name)))
        (format "%s (%s): " name short)
      (format "%s: " short))))

(defun harness-tools-sessions--note-watch (ctx ids)
  "Show what the sessions IDS are doing, under the call CTX runs.
Each session's note is made when an event about it arrives, and the
call's note carries all of them (see `harness-tools-session-note').
Return a function that stops the watching; nothing happens, and it is
a no-op, when the call can show no note."
  (if (not (plist-get ctx :note))
      #'ignore
    (let* ((notes (make-hash-table :test 'equal))
           (push (lambda ()
                   (harness-tools-note
                    ctx (string-join (delq nil (mapcar (lambda (sid) (gethash sid notes)) ids)) "\n"))))
           (stops (mapcar (lambda (sid)
                            (harness-tools-watch-session
                             sid
                             (lambda (text) (puthash sid text notes) (funcall push))
                             (list :title (harness-tools-sessions--wait-title sid) :recap t)))
                          ids)))
      (lambda () (mapc #'funcall stops)))))

(defun harness-tools-sessions--poke (&rest _)
  "Re-check every running wait (subscribed to session and task events)."
  (maphash (lambda (_ w)
             (when (ignore-errors (funcall (plist-get w :check)))
               (funcall (plist-get w :finish) 'met)))
           (copy-hash-table harness-tools-sessions--waiters)))

(defvar harness-tools-sessions--recheck-timer nil
  "Timer of the safety re-check of the running waits, or nil for none.")

(defun harness-tools-sessions--arm-recheck ()
  "Keep the waits' safety re-check armed while any wait runs.
See `harness-tools-sessions-wait-recheck': this is the floor under the
events that settle waits, so none can be left by a change nothing
announced."
  (when (and harness-tools-sessions-wait-recheck
             (not harness-tools-sessions--recheck-timer)
             (> (hash-table-count harness-tools-sessions--waiters) 0))
    (setq harness-tools-sessions--recheck-timer
          (run-at-time harness-tools-sessions-wait-recheck nil
                       #'harness-tools-sessions--recheck))))

(defun harness-tools-sessions--recheck ()
  "Look at every running wait once, and keep the next re-check armed."
  (setq harness-tools-sessions--recheck-timer nil)
  (harness-tools-sessions--poke)
  (harness-tools-sessions--arm-recheck))

(defun harness-tools-sessions--disarm-recheck ()
  "Stop the safety re-check of the waits when none of them waits any more."
  (when (and harness-tools-sessions--recheck-timer
             (zerop (hash-table-count harness-tools-sessions--waiters)))
    (cancel-timer harness-tools-sessions--recheck-timer)
    (setq harness-tools-sessions--recheck-timer nil)))

(defun harness-tools-sessions--on-turn-ended (session-id reason &rest _)
  "Settle the waits of SESSION-ID, whose turn ended with REASON, then re-check.
A wait made by a call of the turn settles as cancelled: its call went
with the turn.  A registered wait (`harness-tools-sessions--watch')
outlives it -- the message it sends is what settles it -- except after a
turn the user cancelled, when it goes too: a turn the user stopped is
not one to start another on (as `harness-supervisor--flush' has it)."
  (maphash (lambda (_ w)
             (when (and (equal (plist-get w :session-id) session-id)
                        (or (not (plist-get w :wake))
                            (eq reason 'cancelled)))
               (funcall (plist-get w :finish) 'cancelled)))
           (copy-hash-table harness-tools-sessions--waiters))
  (harness-tools-sessions--poke))

(defun harness-tools-sessions--outstanding (value session-id)
  "Add what SESSION-ID waits for to VALUE (see `agent/outstanding').
A registered wait (`session_wait') outlives the turn that made it, so a
task whose session's turn ended stays active, waiting, while this says
something."
  (let (labels)
    (maphash (lambda (_ w)
               (when (and (plist-get w :wake) (equal (plist-get w :session-id) session-id))
                 (push (plist-get w :label) labels)))
             harness-tools-sessions--waiters)
    (if (null labels)
        value
      (let ((text (format "Waiting on %s" (string-join (nreverse labels) ", "))))
        (if (and (stringp value) (not (harness-string-blank-p value)))
            (concat value "; " text)
          text)))))

(defun harness-tools-sessions--wait (ctx timeout check report)
  "Return a promise of REPORT's result once CHECK holds or TIMEOUT seconds pass.
CTX is the tool context; REPORT is called with met, timeout or cancelled."
  (harness-with-promise (resolve reject)
    (ignore reject)
    (let* ((id (harness-short-id 12))
           (timer nil)
           (finish (lambda (why)
                     (when (gethash id harness-tools-sessions--waiters)
                       (remhash id harness-tools-sessions--waiters)
                       (when timer (cancel-timer timer))
                       (harness-tools-sessions--disarm-recheck)
                       (funcall resolve (condition-case err (funcall report why)
                                          (error (harness-tool-error (harness-error-message err)))))))))
      (if (funcall check)
          (funcall resolve (funcall report 'met))
        (puthash id (list :check check :finish finish :session-id (plist-get ctx :session-id))
                 harness-tools-sessions--waiters)
        (harness-tools-sessions--arm-recheck)
        (setq timer (run-at-time timeout nil finish 'timeout))))))

(defun harness-tools-sessions--timeout (input)
  "Return the wait timeout in seconds INPUT asks for, clamped."
  (let ((v (plist-get input :timeout_seconds)))
    (max 1 (min harness-tools-sessions--wait-max
                (if (numberp v) v harness-tools-sessions--wait-default)))))

(defun harness-tools-sessions--wake-timeout (input)
  "Return the seconds INPUT asks to be woken after without its condition, or nil.
A registered wait has no timeout of its own: it is woken by its
condition, however long that takes, unless the call gives one."
  (let ((v (plist-get input :timeout_seconds)))
    (and (numberp v) (> v 0) (min harness-tools-sessions--wait-max v))))

(defun harness-tools-sessions--until-phrase (until)
  "Return UNTIL, a wait's condition, as a few words."
  (pcase until
    ("stopped" "stop running")
    ("idle" "become idle")
    ("blocked" "wait on the user")
    ("running" "start running")
    ("changed" "change in any way")
    (_ (format "reach %s" until))))

(defun harness-tools-sessions--wait-condition (ids until any)
  "Return how a wait on IDS until UNTIL reads, as a clause.
ANY says only one of them has to reach it."
  (format "%s %s %s"
          (if any "any of" "all of")
          (string-join (mapcar #'harness-tools-sessions--short ids) ", ")
          (harness-tools-sessions--until-phrase until)))

(defun harness-tools-sessions--wait-report (ids until why started &optional timeout)
  "Return the report of a wait on IDS that settled WHY, started at STARTED.
TIMEOUT is the seconds it was given, for the text of a timeout.  The
text is the same whether the call returns it (the condition already
held) or a later message brings it (the wait was registered), so the
model reads it the same either way."
  (concat (pcase why
            ('met (format "Done waiting after %s (until %s)."
                          (harness-format-duration (- (float-time) started)) until))
            ('timeout (format "Still waiting after %ss; the condition (until %s) did not hold. Register session_wait again to keep waiting."
                              timeout until))
            (_ "The wait was dropped."))
          "\n\n"
          (mapconcat (lambda (sid) (harness-tools-sessions--describe sid)) ids "\n\n")))

(defun harness-tools-sessions--wake (session-id text)
  "Wake SESSION-ID with TEXT, a message of the harness's own, sent soon.
An idle session starts a turn on it and a running one is steered, as a
supervisor's report arrives; a session that is gone is left alone.  The
message is from the harness (\"session wait\"), so transcripts do not
show it as the user's."
  (when (harness-call 'session/exists-p session-id)
    (harness-run-soon
     (lambda ()
       (when (harness-call 'session/exists-p session-id)
         (harness-catch
          (harness-call-async 'agent/prompt session-id text (list :from (harness-sender-system "session wait")))
          (lambda (err)
            (harness-log 'warn "tools-sessions: waking %s failed: %s"
                         session-id (harness-error-message err)))))))))

(defun harness-tools-sessions--watch (ctx input ids until any check report)
  "Register a wake-up for the session in CTX and return its tool result.
CHECK returns non-nil once the wait's condition holds (IDS until UNTIL,
ANY of them enough); the session is then woken with (REPORT `met') as a
message of its own, and reported to `agent/outstanding' as \"Waiting on
IDS\" until then.  The registration outlives the turn that made it: only
the event that settles it, its timeout (INPUT's `timeout_seconds'), or a
turn the user cancelled ends it (see
`harness-tools-sessions--on-turn-ended').  The call itself returns at
once and blocks nothing."
  (let* ((caller (plist-get ctx :session-id))
         (id (harness-short-id 12))
         (timeout (harness-tools-sessions--wake-timeout input))
         (timer nil)
         (finish (lambda (why)
                   (when (gethash id harness-tools-sessions--waiters)
                     (remhash id harness-tools-sessions--waiters)
                     (when timer (cancel-timer timer))
                     (harness-tools-sessions--disarm-recheck)
                     (when (memq why '(met timeout))
                       (harness-tools-sessions--wake caller (funcall report why)))))))
    (if (funcall check)
        (harness-tool-ok (funcall report 'met))
      (puthash id (list :check check :finish finish :session-id caller :wake t
                        :label (string-join (mapcar #'harness-tools-sessions--short ids) ", "))
               harness-tools-sessions--waiters)
      (harness-tools-sessions--arm-recheck)
      (when timeout (setq timer (run-at-time timeout nil finish 'timeout)))
      (harness-tool-ok
       (format (concat "Waiting in the background: you will be woken with a message when %s. "
                       "Carry on with other work, and do not poll.%s")
               (harness-tools-sessions--wait-condition ids until any)
               (if timeout
                   (format " If that has not happened in %ss, you are woken then instead." timeout)
                 ""))))))

(defun harness-tools-sessions--reached-p (sid until baseline)
  "Non-nil when session SID satisfies UNTIL; BASELINE is its state at the start.
A `changed' wait is met by any new state of the session and also by an
idle or closed one: a session that is not running and not waiting on
the user has nothing new of its own coming, so asking for a change that
can never come would only leave the wait or its registration unsettled
(a registered wait may have no timeout at all).  It is what a wait made
on a sub-agent meets: `spawn_agent' returns as soon as its child
starts, but a wait can still be made once that child has finished -- by
a session that only looks later, or a third one -- and then nothing is
left to announce.  A blocked session is left to the wait: its turn is
not over, and it changes when its question is answered."
  (if (not (harness-call 'session/exists-p sid))
      t
    (let ((status (harness-tools-sessions--status sid)))
      (pcase until
        ("idle" (eq status 'idle))
        ("blocked" (eq status 'blocked))
        ("running" (eq status 'running))
        ("changed" (or (memq status '(idle inactive))
                       (not (equal baseline (harness-tools-sessions--state sid)))))
        (_ (not (eq status 'running)))))))

(defun harness-tools-sessions--state (sid)
  "Return what `changed' compares for SID: status, head and pending ids."
  (and (harness-call 'session/exists-p sid)
       (let ((s (harness-call 'session/get sid)))
         (list (harness-tools-sessions--status sid) (plist-get s :head)
               (mapcar (lambda (p) (plist-get p :id)) (plist-get s :pending))))))

(defun harness-tools-sessions--session-wait (input ctx)
  "Handler of session_wait: register a wake-up for the sessions INPUT names.
The call returns at once, with the report itself when the condition
already holds and a registration otherwise; when an event makes the
condition hold, the session in CTX is woken with the same report as a
message of the harness's own."
  (let* ((ids (mapcar (lambda (r) (harness-tools-sessions--other r ctx "wait on"))
                      (harness-tools-sessions--refs input :session_id :session_ids)))
         (until (or (plist-get input :until) "stopped"))
         (any (equal (plist-get input :mode) "any"))
         (baselines (mapcar #'harness-tools-sessions--state ids))
         (timeout (harness-tools-sessions--wake-timeout input))
         (started (float-time)))
    (unless ids (signal 'harness-error (list "session_wait needs session_id or session_ids")))
    (harness-tools-sessions--watch
     ctx input ids until any
     (lambda ()
       (funcall (if any #'cl-some #'cl-every)
                (lambda (pair) (harness-tools-sessions--reached-p (car pair) until (cdr pair)))
                (cl-mapcar #'cons ids baselines)))
     (lambda (why) (harness-tools-sessions--wait-report ids until why started timeout)))))

(harness-define-tool "session_wait"
  :label "Wait for sessions"
  :description "Wait for other sessions without blocking: the call registers a wake-up and returns at once, and when the condition holds the session is sent a message of the harness's own reporting the sessions. until=stopped (default) waits for a session to stop running (its turn ended: it is idle, blocked on the user, or closed); idle, blocked and running wait for that status; changed waits for any new status, message or pending request, and is met at once by an idle or closed session, whose own work is over and from which nothing new of its own is coming -- so a wait on a sub-agent that has already finished settles rather than ask for a change that can never come. mode=all (default) waits for every session, any for the first. The registration outlives the turn that made it, so nothing is left hanging; with timeout_seconds you are woken with the report anyway if the condition still does not hold by then, and the registration ends. If the condition already holds the report is the call's result. Never poll or wait in a loop: register, and carry on."
  :schema '(:type "object"
            :properties (:session_id (:type "string" :description "A session id, unique id prefix or unique name.")
                         :session_ids (:type "array" :items (:type "string") :description "Several sessions.")
                         :until (:type "string" :enum ("stopped" "idle" "blocked" "running" "changed"))
                         :mode (:type "string" :enum ("all" "any"))
                         :timeout_seconds (:type "number" :description "Wake me anyway after this long, without blocking (default: wait for the condition, however long it takes).")))
  :kind 'read
  :subject (lambda (input) (mapconcat #'harness-tools-sessions--short
                                      (harness-tools-sessions--refs input :session_id :session_ids) " "))
  :handler #'harness-tools-sessions--session-wait)

;;;; Tasks

(defun harness-tools-sessions--tasks-p ()
  "Signal unless the tasks module is loaded."
  (unless (harness-method-exists-p 'task/list)
    (signal 'harness-error (list "Task mode (the tasks module) is not loaded"))))

(defun harness-tools-sessions--task (ref)
  "Return the task REF names: an id or a unique id prefix."
  (let* ((ref (string-trim (format "%s" (or ref ""))))
         (hits (cl-remove-if-not (lambda (task) (string-prefix-p ref (plist-get task :id)))
                                 (harness-call 'task/list))))
    (when (string-empty-p ref) (signal 'harness-error (list "A task id is required")))
    (or (cl-find ref hits :key (lambda (task) (plist-get task :id)) :test #'equal)
        (pcase (length hits)
          (1 (car hits))
          (0 (signal 'harness-error (list (format "No task %s; use task_list to find ids" ref))))
          (_ (signal 'harness-error (list (format "%s matches %d tasks; give more of the id" ref (length hits)))))))))

(defun harness-tools-sessions--task-times (task)
  "Return when TASK was created and finished, as a task line has it."
  (let ((created (plist-get task :created))
        (finished (plist-get task :finished)))
    (concat (if (numberp created) (format ", created %s" (harness-relative-time created)) "")
            (if (numberp finished) (format ", finished %s" (harness-relative-time finished)) ""))))

(defun harness-tools-sessions--task-line (task &optional self)
  "Return the listing of TASK.
Its title on the board, once it has one, comes before its prompt: the
name of its session, else its own, which a task has from submission --
it gets its session then, named with the title once it comes.  A
backlog task says on its state line that it waits in the backlog for
someone to start it, so it does not read as a queued pending task.
When SELF, a session id, is TASK's session, the line says \"(this
task)\"."
  (let* ((sid (plist-get task :session))
         (session (and sid (harness-call 'session/exists-p sid) (harness-call 'session/get sid)))
         (title (if (harness-string-blank-p (plist-get session :name))
                    (plist-get task :name)
                  (plist-get session :name)))
         (backlog (and (equal (format "%s" (plist-get task :column)) "backlog") t))
         (pending (and session (harness-tools-sessions--pending-text session))))
    (concat
     (format "%s  %-11s %s%s%s" (plist-get task :id) (plist-get task :column)
             (if (harness-string-blank-p title) "" (format "%S: " title))
             (harness-truncate-end (harness-first-line (or (plist-get task :prompt) "")) 100)
             (if (and self sid (equal sid self)) "  (this task)" ""))
     (format "\n    state %s%s%s%s%s%s%s%s%s%s%s%s"
             (plist-get task :state)
             (if backlog
                 (if (eq (plist-get task :state) 'pending)
                     ", backlog, waits to be started"
                   ", backlog, being written up")
               "")
             (if (plist-get task :outcome) (format " (%s)" (plist-get task :outcome)) "")
             (let ((priority (plist-get task :priority)))
               (if (and priority (not (equal (format "%s" priority) "medium")))
                   (format ", priority %s" priority)
                 ""))
             (if (plist-get task :duplicate-of) (format ", duplicate of %s" (plist-get task :duplicate-of)) "")
             (harness-tools-sessions--task-times task)
             (if sid (format ", session %s %s" sid (if session (harness-tools-sessions--status sid) "deleted")) "")
             (if (plist-get task :branch) (format ", branch %s" (plist-get task :branch)) "")
             (cond ((plist-get task :merge-status) (format ", merge %s" (plist-get task :merge-status)))
                   ((harness-json-true-p (plist-get task :merged)) ", merged")
                   (t ""))
             (if (and (harness-json-true-p (plist-get task :main-tree)) (not (plist-get task :worktree)))
                 ", main tree (no worktree)" "")
             (if (harness-json-true-p (plist-get task :verified)) ", verified" "")
             (let ((rounds (length (plist-get task :feedback))))
               (if (> rounds 0) (format ", sent back %d time%s" rounds (if (= rounds 1) "" "s")) "")))
     (if (plist-get task :archived) ", archived" "")
     ;; A backlog task waits for a person, never for the queue: the
     ;; suspension is not what holds it back, and it says so above.
     (if (and (eq (plist-get task :state) 'pending) (not backlog)
              (harness-json-true-p (plist-get task :queue-suspended)))
         ", waiting while the queue is suspended" "")
     (if pending (format "\n    waiting on the user: %s" pending) ""))))

(defun harness-tools-sessions--task-queue-line (tasks)
  "Say which of TASKS' projects have a suspended pending queue, else nothing.
A suspended queue starts no waiting task on its own: one waits until
its queue is resumed or it is started by hand."
  (let ((projects (cl-remove-duplicates
                   (cl-loop for task in tasks
                            when (harness-json-true-p (plist-get task :queue-suspended))
                            collect (or (plist-get task :project) (plist-get task :cwd)))
                   :test #'equal)))
    (cond
     ((null projects) "")
     ((null (cdr projects))
      (format "Queue suspended for %s: its waiting tasks start only when one is started by hand or the queue is resumed.\n"
              (abbreviate-file-name (directory-file-name (car projects)))))
     (t (format "Queues suspended: %s; their waiting tasks start only by hand until resumed.\n"
                (mapconcat (lambda (p) (abbreviate-file-name (directory-file-name p))) projects ", "))))))

(defun harness-tools-sessions--task-list (input ctx)
  "Handler of task_list.
INPUT is the tool call's input plist and CTX its context."
  (harness-tools-sessions--tasks-p)
  (let* ((cwd (unless (harness-json-true-p (plist-get input :all_projects)) (plist-get ctx :cwd)))
         (column (let ((c (plist-get input :column))) (and c (intern c))))
         (archived (harness-json-true-p (plist-get input :include_archived)))
         (limit (let ((n (plist-get input :limit))) (and (numberp n) (>= n 1) (truncate n))))
         (tasks (cl-remove-if-not
                 (lambda (task) (and (or archived (not (plist-get task :archived)))
                                     (or (null column) (eq column (plist-get task :column)))))
                 (harness-call 'task/list cwd)))
         ;; The list is oldest first: the most recent are its end.
         (shown (if (and limit (> (length tasks) limit)) (last tasks limit) tasks))
         (hidden (- (length tasks) (length shown)))
         (self (plist-get ctx :session-id)))
    (harness-tool-ok
     (concat (harness-tools-sessions--task-queue-line tasks)
             (if tasks
                 (concat (if (> hidden 0)
                             (format "… %d older task%s not shown; raise limit to see them\n" hidden (if (= hidden 1) "" "s"))
                           "")
                         (mapconcat (lambda (task) (harness-tools-sessions--task-line task self)) shown "\n"))
               "No tasks match.")))))

(harness-define-tool "task_list"
  :label "List tasks"
  :description "List the task board: tasks (one session each, usually in its own worktree, or in the project's main tree when submitted with main_tree, done once the user verified the work and it merged) with their title (their session's name, else the one a task is given as soon as it is submitted), prompt, column (pending, backlog, needs-input, active, review, merging, done), state, priority (shown when it is low or high rather than medium; waiting tasks start highest priority first), when they were created and finished, session, branch, merge status and review status. Pending holds only tasks waiting for a slot: they start on their own as slots free, by priority. A task in the backlog (task_submit with refine) waits for a person to start it (task_control start) and says so, \"backlog, waits to be started\"; the queue never starts it. A task in review has finished and waits for the user to verify it or send it back; one in merging holds a place in the merge queue (queued, merging, or its session resolving conflicts). A suspended queue (task_control suspend-queue) is named before the tasks, and its queued pending tasks say so: they start only by hand (task_control start) or when the queue is resumed. Defaults to this project's unarchived tasks, oldest first; limit keeps the most recent ones. The task this session works on says (this task). Inspect a task's work with session_read on its session."
  :schema '(:type "object"
            :properties (:column (:type "string" :enum ("pending" "backlog" "needs-input" "active" "review" "merging" "done"))
                         :include_archived (:type "boolean" :description "Include archived tasks (default false).")
                         :all_projects (:type "boolean" :description "Every project (default false).")
                         :limit (:type "integer" :description "Show only this many tasks, the most recently created (default all).")))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :column))
  :handler #'harness-tools-sessions--task-list)

(defun harness-tools-sessions--task-submit (input ctx)
  "Handler of task_submit.
INPUT is the tool call's input plist and CTX its context."
  (harness-tools-sessions--tasks-p)
  (let* ((prompt (or (plist-get input :prompt) ""))
         (cwd (or (plist-get input :cwd) (plist-get ctx :cwd)))
         (refine (harness-json-true-p (plist-get input :refine)))
         (main-tree (harness-json-true-p (plist-get input :main_tree)))
         (opts (append (and (plist-get input :model) (list :model (plist-get input :model)))
                       (and (plist-get input :thinking) (list :thinking (plist-get input :thinking)))
                       (and (plist-get input :priority) (list :priority (plist-get input :priority)))
                       (and main-tree (list :main-tree t))
                       (and refine (list :refine t))))
         (task (harness-call 'task/submit cwd prompt opts)))
    (harness-tool-ok (concat (cond (refine "Added to the backlog; an agent is writing it up.\n")
                                   (main-tree "Submitted to the project's main tree.\n")
                                   (t "Submitted.\n"))
                             (harness-tools-sessions--task-line task))
                     :meta (list :task-id (plist-get task :id)))))

(harness-define-tool "task_submit"
  :label "Submit task"
  :description "Add a task to the task board. The task runs in its own session (in a git project, in a fresh worktree whose branch is merged back through the merge queue) with the task defaults for permissions; it starts when its project has a free slot (the limit on running tasks applies to each project separately, and counts only the tasks' own top-level sessions at work: sub-agents, forks and the merge queue never take a slot), and waiting tasks take free slots by priority: high before medium (the default) before low, oldest first among equals. While the project's queue is suspended (task_control suspend-queue) nothing starts it on its own; the task waits until the queue is resumed or someone starts it with task_control start. By default finished work waits in review until the user verifies it (task_control verify) or sends it back (task_control reject). With refine=true it goes to the backlog instead: an agent briefly writes it up, read-only, and it waits in pending until someone starts it (task_control start), which is how to record work for later. With main_tree=true it works in the project's main checkout instead of a worktree: no branch, nothing merges, and its changes take effect in the checkout itself -- for work that has to touch it, such as cleaning up uncommitted changes. Returns the task id; follow it with task_wait or task_list."
  :schema '(:type "object"
            :properties (:prompt (:type "string" :description "What the task should do; self-contained, the task does not see this conversation.")
                         :cwd (:type "string" :description "Project directory (default: this session's).")
                         :model (:type "string" :description "Model id (default: the task default).")
                         :thinking (:type "string" :description "Thinking level (default: the task default).")
                         :priority (:type "string" :enum ("low" "medium" "high")
                                    :description "Where it waits when its project's slots are full: high starts before medium, medium before low (default medium).")
                         :refine (:type "boolean" :description "Write it up for the backlog instead of starting it (default false).")
                         :main_tree (:type "boolean" :description "Work in the project's main checkout, with no worktree and nothing to merge (default false)."))
            :required ("prompt"))
  :kind 'meta
  :subject (lambda (input) (harness-first-line (plist-get input :prompt) 60))
  :handler #'harness-tools-sessions--task-submit)

(defun harness-tools-sessions--task-queue (input ctx action)
  "Suspend or resume the pending queue ACTION names, for task_control.
INPUT carries the tool's input, CTX its context: the project is the
calling session's own, or the one INPUT's `:cwd' names."
  (let* ((cwd (or (plist-get input :cwd) (plist-get ctx :cwd)))
         (method (if (equal action "suspend-queue") 'task/suspend-queue 'task/resume-queue)))
    (unless cwd
      (signal 'harness-error (list (format "%s needs the project: call it from a session with a directory, or give cwd" action))))
    (let* ((state (harness-call method cwd))
           (project (plist-get state :project))
           (suspended (harness-json-true-p (plist-get state :suspended))))
      (harness-tool-ok
       (format "%s of %s.\n%s"
               (if suspended "Queue suspended" "Queue resumed")
               (abbreviate-file-name (directory-file-name project))
               (if suspended
                   "No pending task of the project starts on its own now; one already at work goes on, and task_control start still starts a task by hand."
                 "Waiting tasks start again now, by priority, up to the project's limit."))))))

(defun harness-tools-sessions--task-control (input ctx)
  "Handler of task_control.
INPUT is the tool call's input plist and CTX its context.
A message to a task's session is the calling session's, as
session_send's is: it opens with the header naming that session and
goes with it as the sender, so a task waiting for review takes it for
no review of the user's (`harness-tasks--on-message').  Only reject
sends work back."
  (harness-tools-sessions--tasks-p)
  (let ((action (or (plist-get input :action) "")))
    (if (member action '("suspend-queue" "resume-queue"))
        (harness-tools-sessions--task-queue input ctx action)
      (let* ((task (harness-tools-sessions--task (plist-get input :task_id)))
             (id (plist-get task :id)))
        (pcase action
          ("start" (harness-call 'task/start id))
          ("message"
           (let ((text (or (plist-get input :message) "")))
             (when (harness-string-blank-p text) (signal 'harness-error (list "message needs a message")))
             (if (and (eq (plist-get task :state) 'pending) (not (plist-get task :returned)))
                 (harness-call 'task/update id (concat (plist-get task :prompt) "\n\n" text) (plist-get task :attachments))
               (harness-call 'task/prompt id (concat (harness-tools-sessions--from ctx) text) nil
                             (list :from (harness-tools-sessions--sender ctx))))))
          ("cancel" (harness-call 'task/cancel id))
          ("return-to-pending" (harness-call 'task/return-to-pending id))
          ("merge" (harness-call 'task/merge id))
          ("verify" (harness-call 'task/verify id))
          ("reject"
           (let ((text (or (plist-get input :message) "")))
             (when (harness-string-blank-p text)
               (signal 'harness-error (list "reject needs the feedback in message")))
             (harness-call 'task/reject id text)))
          ("complete" (harness-call 'task/complete id))
          ("archive" (harness-call 'task/archive id))
          ("restore" (harness-call 'task/archive id t))
          ("delete" (harness-call 'task/delete id))
          ("priority"
           (let ((priority (plist-get input :priority)))
             (when (harness-string-blank-p priority)
               (signal 'harness-error (list "priority needs priority: low, medium or high")))
             (harness-tools-sessions--priority-p)
             (let ((sid (plist-get task :session)))
               ;; A task's priority is its session's, and only that record
               ;; holds one; a task waiting for a slot has its session already.
               (unless sid
                 (signal 'harness-error
                         (list (format "Task %s has no session, so setting its priority is not possible" id))))
               (harness-call 'priority/set sid priority))))
          (_ (signal 'harness-error (list (format "Unknown action %S" action)))))
        (harness-tool-ok
         (if-let* ((task (ignore-errors (harness-call 'task/get id))))
             (format "%s.\n%s"
                     (pcase action
                       ("priority" (format "Priority %s" (harness-priority-of-task task)))
                       ("return-to-pending" "Returned to pending; it starts again where it stopped")
                       (_ (concat action " done")))
                     (harness-tools-sessions--task-line task))
           (format "%s done; task %s is gone." action id)))))))

(harness-define-tool "task_control"
  :label "Control task"
  :description "Act on a task, or on its project's pending queue. start runs a pending task now, whatever the limit or a suspended queue; message sends a follow-up to its session, marked as coming from this session (while pending, it appends to the prompt instead -- a task returned to pending that waits with its queue suspended keeps the message and gets it when it starts, otherwise it starts now); cancel drops a pending task or stops a working one's turn; return-to-pending stops a working task's turn and puts it back at the front of its project's pending queue, keeping its session, branch and worktree so it carries on where it stopped when it starts again; reject sends a task in review back to its session with the feedback in message, to work on it again (with the queue suspended the task waits in pending with the feedback kept instead); merge retries the merge queue after a failed merge; verify accepts the work of a task in review (its branch then merges and it is done); complete marks it done by hand; archive hides a done task (removing a merged task's worktree); restore unarchives; delete forgets the task (its session and worktree are kept); priority sets its priority to the given one (low, medium or high), given to the task's session, which is where a task's priority lives (`harness-priority-of-task'), and which reorders the tasks waiting for a slot: high starts before medium, medium before low. suspend-queue stops a project's pending tasks from starting on their own -- the queue waits until resume-queue, while start still starts a task -- and resume-queue starts them again at once, by priority; both act on the project of cwd (default: this session's) and need no task_id."
  :schema '(:type "object"
            :properties (:task_id (:type "string" :description "Task id or unique prefix; not needed by suspend-queue and resume-queue.")
                         :action (:type "string" :enum ("start" "message" "cancel" "return-to-pending" "merge" "verify" "reject" "complete" "archive" "restore" "delete" "priority" "suspend-queue" "resume-queue"))
                         :message (:type "string" :description "Text, for message; the feedback, for reject.")
                         :priority (:type "string" :enum ("low" "medium" "high") :description "The new priority, for priority.")
                         :cwd (:type "string" :description "Project directory, for suspend-queue and resume-queue (default: this session's)."))
            :required ("action"))
  :kind 'meta
  :subject (lambda (input) (string-trim (format "%s %s" (or (plist-get input :action) "") (or (plist-get input :task_id) ""))))
  :handler #'harness-tools-sessions--task-control)

(defun harness-tools-sessions--task-reached-p (id until baseline)
  "Non-nil when task ID satisfies UNTIL; BASELINE is its view at the start."
  (let ((task (ignore-errors (harness-call 'task/get id))))
    (or (null task)
        (let ((column (plist-get task :column)))
          (pcase until
            ("done" (eq column 'done))
            ("needs-input" (eq column 'needs-input))
            ("active" (eq column 'active))
            ("review" (eq column 'review))
            ("merging" (eq column 'merging))
            ("changed" (not (equal (list column (plist-get task :state) (plist-get task :merge-status)) baseline)))
            ;; Finished work waits for the user's review, and a backlog
            ;; task that is written up for someone to start it.
            (_ (or (memq column '(done needs-input review))
                   (and (eq (plist-get task :state) 'pending) (plist-get task :backlog) t))))))))

(defun harness-tools-sessions--task-wait (input ctx)
  "Handler of task_wait.
INPUT is the tool call's input plist and CTX its context."
  (harness-tools-sessions--tasks-p)
  (let* ((refs (harness-tools-sessions--refs input :task_id :task_ids))
         (tasks (mapcar #'harness-tools-sessions--task refs))
         (ids (mapcar (lambda (task) (plist-get task :id)) tasks))
         (sessions (delq nil (mapcar (lambda (task) (plist-get task :session)) tasks)))
         (until (or (plist-get input :until) "settled"))
         (any (equal (plist-get input :mode) "any"))
         (baselines (mapcar (lambda (id) (let ((task (harness-call 'task/get id)))
                                           (list (plist-get task :column) (plist-get task :state) (plist-get task :merge-status))))
                            ids))
         (timeout (harness-tools-sessions--timeout input))
         (started (float-time)))
    (unless ids (signal 'harness-error (list "task_wait needs task_id or task_ids")))
    (let ((unwatch (harness-tools-sessions--note-watch ctx sessions)))
      (harness-tools-sessions--wait
       ctx timeout
       (lambda ()
         (funcall (if any #'cl-some #'cl-every)
                  (lambda (pair) (harness-tools-sessions--task-reached-p (car pair) until (cdr pair)))
                  (cl-mapcar #'cons ids baselines)))
       (lambda (why)
         (funcall unwatch)
         (harness-tool-ok
          (concat (pcase why
                    ('met (format "Done waiting after %s (until %s)." (harness-format-duration (- (float-time) started)) until))
                    ('timeout (format "Still waiting after %ss; the condition (until %s) did not hold. Call task_wait again to keep waiting." timeout until))
                    (_ "The wait was interrupted."))
                  "\n\n"
                  (mapconcat
                   (lambda (id)
                     (let ((task (ignore-errors (harness-call 'task/get id))))
                       (if (not task)
                           (format "%s: deleted" id)
                         (let* ((sid (plist-get task :session))
                                (reply (and sid (harness-call 'session/exists-p sid)
                                            (harness-tools-sessions--last-reply sid))))
                           (concat (harness-tools-sessions--task-line task)
                                   (if reply (format "\n    last reply:\n%s" (harness-truncate-end reply 2000)) ""))))))
                   ids "\n\n"))))))))

(harness-define-tool "task_wait"
  :label "Wait for tasks"
  :description "Wait for tasks without polling. until=settled (default) returns when each task is done, needs input or waits in review for the user to verify it, or is written up and waits in the backlog for someone to start it; done, needs-input, active, review and merging wait for that column; changed waits for any change of column, state or merge status. mode=all (default) waits for every task, any for the first. Returns each task's line and its session's last reply; on timeout it returns the same report, not an error."
  :schema '(:type "object"
            :properties (:task_id (:type "string" :description "A task id or unique prefix.")
                         :task_ids (:type "array" :items (:type "string") :description "Several tasks.")
                         :until (:type "string" :enum ("settled" "done" "needs-input" "active" "review" "merging" "changed"))
                         :mode (:type "string" :enum ("all" "any"))
                         :timeout_seconds (:type "number" :description "Give up after this long (default 600, at most 3600).")))
  :kind 'read
  :timeout 3700
  :subject (lambda (input) (string-join (harness-tools-sessions--refs input :task_id :task_ids) " "))
  :handler #'harness-tools-sessions--task-wait)

;;;; Registration

(defun harness-tools-sessions--init ()
  "Subscribe the waits to session and task events (idempotent).
Install the stage that has the user confirm session_move, too: the tool
is registered at load time, and must never be offered without it."
  (dolist (ev '(session/status session/changed session/deleted session/pending-changed
                session/node-added session/head-moved
                agent/turn-started task/changed task/deleted))
    (harness-on ev #'harness-tools-sessions--poke 90))
  (harness-on 'agent/turn-ended #'harness-tools-sessions--on-turn-ended 90)
  (harness-add-filter 'agent/outstanding #'harness-tools-sessions--outstanding)
  (harness-add-filter 'permission/decide #'harness-tools-sessions--move-gate 6))

(harness-tools-sessions--init)

(harness-define-module 'tools-sessions
  :doc "Tools to list, search, read, message, control, move and wait on sessions and tasks."
  :requires '(tools session agent)
  :init #'harness-tools-sessions--init)

(provide 'harness-tools-sessions)
;;; harness-tools-sessions.el ends here
