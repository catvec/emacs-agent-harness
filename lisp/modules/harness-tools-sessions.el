;;; harness-tools-sessions.el --- Tools to inspect and drive other sessions and tasks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Lets an agent see and steer the rest of the harness: the other
;; sessions and the task board.
;;
;; Sessions:
;; - `session_list' lists sessions (this project by default) with
;;   status, model, usage and whether they wait on the user.
;; - `session_search' finds sessions whose transcript contains a string.
;;   It greps the node logs on disk in a subprocess, so transcripts are
;;   never loaded into memory just to be searched.
;; - `session_read' shows the recent transcript of one session.
;; - `session_send' sends a message: it starts a turn on an idle
;;   session, steers a running one, or queues for the next turn; it can
;;   wait for the reply.
;; - `session_control' cancels a turn, resumes, closes or renames a
;;   session, or answers a question it asked with ask_user.
;; - `session_wait' waits until sessions stop running (or become idle,
;;   blocked, start running, or change at all).
;;
;; Tasks (when the `tasks' module is loaded):
;; - `task_list', `task_submit', `task_control' (start, message, cancel,
;;   merge, verify, reject, complete, archive, restore, delete) and
;;   `task_wait'.
;;
;; Nothing here grants permissions: a session's permission requests and
;; permission mode are left to the user, and tasks are submitted with
;; the task defaults.  Reading and waiting are `read' tools; anything
;; that changes another session is `meta' and goes through the
;; permission chain like any other action.
;;
;; Waits never block: each is an entry in `harness-tools-sessions--waiters'
;; re-checked by one subscriber whenever a session or task changes, and
;; settled by its condition, its timeout, or the end of the waiting turn.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)
(require 'harness-tools)

(defvar harness-state-directory)

(defcustom harness-tools-sessions-wait-default 600
  "Seconds `session_wait' and `task_wait' wait when the call gives no timeout."
  :type 'number :group 'harness)

(defcustom harness-tools-sessions-wait-max 3600
  "Longest wait, in seconds, a `session_wait' or `task_wait' call may ask for."
  :type 'number :group 'harness)

(defcustom harness-tools-sessions-grep-program "grep"
  "Program `session_search' runs over the transcript logs."
  :type 'string :group 'harness)

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
  "Return the one-line listing of session plist S."
  (let ((u (plist-get s :usage))
        (pending (harness-tools-sessions--pending-text s)))
    (concat
     (format "%s  %-8s %-8s %s  model %s, %s, cost %s, updated %s"
             (plist-get s :id) (plist-get s :status) (plist-get s :kind)
             (format "%S" (or (plist-get s :name) "(unnamed)"))
             (plist-get s :model)
             (abbreviate-file-name (or (plist-get s :cwd) ""))
             (harness-format-spend u)
             (harness-relative-time (plist-get s :updated)))
     (if (plist-get s :parent-id) (format ", parent %s" (harness-tools-sessions--short (plist-get s :parent-id))) "")
     (if (plist-get s :queue) (format ", %d queued" (length (plist-get s :queue))) "")
     (if pending (format "\n    waiting on the user: %s" pending) ""))))

(defun harness-tools-sessions--node-text (node)
  "Return the readable text of transcript NODE.
A tool call reads as the tool's name, as the model knows it, and its input."
  (pcase (plist-get node :kind)
    ('tool-call (format "%s %s" (or (plist-get node :tool) (plist-get node :title) "")
                        (if (plist-get node :input) (harness-json-encode (plist-get node :input)) "")))
    ('tool-result (or (plist-get node :output) ""))
    (_ (or (plist-get node :content) ""))))

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
  "Handler of session_list."
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
  :description "List harness sessions with id, status (idle, running, blocked, inactive), kind, name, model, working directory, cost and what each one waits on. Defaults to the open sessions of this project; set include_inactive for closed ones and all_projects for every project. Session ids (or a unique prefix, or a unique name) are accepted by the other session_* tools."
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

(defun harness-tools-sessions--snippet (text query regexp)
  "Return the part of TEXT around the first match of QUERY (a REGEXP when non-nil)."
  (let* ((case-fold-search t)
         (text (replace-regexp-in-string "[ \t\n\r]+" " " text))
         (pos (ignore-errors (string-match (if regexp query (regexp-quote query)) text))))
    (if (not pos)
        (harness-truncate-end text 160)
      (let ((from (max 0 (- pos 70)))
            (to (min (length text) (+ (match-end 0) 90))))
        (concat (if (> from 0) "…" "") (substring text from to) (if (< to (length text)) "…" ""))))))

(defun harness-tools-sessions--parse-hits (stdout)
  "Return ((SESSION-ID . NODE) …) from grep STDOUT, in output order."
  (let (hits)
    (dolist (line (split-string stdout "\n" t))
      (when (string-match "\\`\\(?:.*/\\)?\\([^/:]+\\)\\.nodes\\.jsonl:\\(.*\\)\\'" line)
        (let ((sid (match-string 1 line))
              (node (ignore-errors (harness-json-parse (match-string 2 line)))))
          (when (stringp (plist-get node :kind))
            (setq node (plist-put node :kind (intern (plist-get node :kind)))))
          (when node (push (cons sid node) hits)))))
    (nreverse hits)))

(defun harness-tools-sessions--search (input ctx)
  "Handler of session_search."
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
          (append (list harness-tools-sessions-grep-program "-i" "-H" (format "--max-count=%d" (* 4 per-session))
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
                              (let ((case-fold-search t))
                                (string-match-p (regexp-quote query) (harness-tools-sessions--node-text node)))))
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
                                           (format "\n    [%s %s] %s" (plist-get n :kind) (plist-get n :id)
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
  :description "Search the transcripts of other sessions (messages, thinking, tool calls and results) and their names for a string, case-insensitively. Returns the matching sessions, newest first, with snippets and node ids; read one with session_read. Searches this project unless all_projects is set; closed sessions are included."
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
  "Handler of session_read."
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
                   (format "[%s %s] %s" (plist-get n :kind) (plist-get n :id)
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

;;;; session_send

(defun harness-tools-sessions--from (ctx)
  "Return the header that marks a message as sent by CTX's session."
  (let* ((sid (plist-get ctx :session-id))
         (s (ignore-errors (harness-call 'session/get sid))))
    (format "[Message from session %s%s]\n\n" sid
            (if (plist-get s :name) (format " %S" (plist-get s :name)) ""))))

(defun harness-tools-sessions--send (input ctx)
  "Handler of session_send."
  (let* ((sid (harness-tools-sessions--other (plist-get input :session_id) ctx "message"))
         (text (or (plist-get input :message) ""))
         (queue (equal (plist-get input :mode) "queue"))
         (wait (harness-json-true-p (plist-get input :wait)))
         (s (harness-call 'session/get sid))
         (running (eq (harness-tools-sessions--status sid) 'running)))
    (when (harness-string-blank-p text) (signal 'harness-error (list "session_send needs a message")))
    (when (eq (plist-get s :status) 'inactive) (harness-call 'session/resume sid))
    (let* ((body (concat (harness-tools-sessions--from ctx) text))
           (promise (harness-call 'agent/prompt sid body (and queue (list :queue t))))
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
  "Handler of session_control."
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
               ((harness-string-blank-p answer) (signal 'harness-error (list "answer needs an answer"))))
         (harness-call 'question/answer sid (plist-get q :id) (list :answer answer))
         (harness-tool-ok (format "Answered %S in %s." (plist-get (plist-get q :payload) :question) sid))))
      (_ (signal 'harness-error (list (format "Unknown action %S" action)))))))

(harness-define-tool "session_control"
  :label "Control session"
  :description "Control another session. action=cancel stops its running turn; resume reopens a closed session; close deactivates it (it can be resumed later); rename sets its name; answer replies to a question it asked with ask_user (question_id may be omitted when there is one). Permission requests are left to the user."
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

;;;; Waiting

(defvar harness-tools-sessions--waiters (make-hash-table :test 'equal)
  "Wait id -> (:check FN :finish FN :session-id ID) for running waits.
CHECK returns non-nil once the wait's condition holds; FINISH settles
the wait with a reason symbol (met, timeout or cancelled).")

(defun harness-tools-sessions--poke (&rest _)
  "Re-check every running wait (subscribed to session and task events)."
  (maphash (lambda (_ w)
             (when (ignore-errors (funcall (plist-get w :check)))
               (funcall (plist-get w :finish) 'met)))
           (copy-hash-table harness-tools-sessions--waiters)))

(defun harness-tools-sessions--on-turn-ended (session-id &rest _)
  "Settle the waits made by SESSION-ID's turn, which has ended, then re-check."
  (maphash (lambda (_ w)
             (when (equal (plist-get w :session-id) session-id)
               (funcall (plist-get w :finish) 'cancelled)))
           (copy-hash-table harness-tools-sessions--waiters))
  (harness-tools-sessions--poke))

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
                       (funcall resolve (condition-case err (funcall report why)
                                          (error (harness-tool-error (harness-error-message err)))))))))
      (if (funcall check)
          (funcall resolve (funcall report 'met))
        (puthash id (list :check check :finish finish :session-id (plist-get ctx :session-id))
                 harness-tools-sessions--waiters)
        (setq timer (run-at-time timeout nil finish 'timeout))))))

(defun harness-tools-sessions--timeout (input)
  "Return the wait timeout in seconds INPUT asks for, clamped."
  (let ((v (plist-get input :timeout_seconds)))
    (max 1 (min harness-tools-sessions-wait-max
                (if (numberp v) v harness-tools-sessions-wait-default)))))

(defun harness-tools-sessions--reached-p (sid until baseline)
  "Non-nil when session SID satisfies UNTIL; BASELINE is its state at the start."
  (if (not (harness-call 'session/exists-p sid))
      t
    (let ((status (harness-tools-sessions--status sid)))
      (pcase until
        ("idle" (eq status 'idle))
        ("blocked" (eq status 'blocked))
        ("running" (eq status 'running))
        ("changed" (not (equal baseline (harness-tools-sessions--state sid))))
        (_ (not (eq status 'running)))))))

(defun harness-tools-sessions--state (sid)
  "Return what `changed' compares for SID: status, head and pending ids."
  (and (harness-call 'session/exists-p sid)
       (let ((s (harness-call 'session/get sid)))
         (list (harness-tools-sessions--status sid) (plist-get s :head)
               (mapcar (lambda (p) (plist-get p :id)) (plist-get s :pending))))))

(defun harness-tools-sessions--session-wait (input ctx)
  "Handler of session_wait."
  (let* ((ids (mapcar (lambda (r) (harness-tools-sessions--other r ctx "wait on"))
                      (harness-tools-sessions--refs input :session_id :session_ids)))
         (until (or (plist-get input :until) "stopped"))
         (any (equal (plist-get input :mode) "any"))
         (baselines (mapcar #'harness-tools-sessions--state ids))
         (timeout (harness-tools-sessions--timeout input))
         (started (float-time)))
    (unless ids (signal 'harness-error (list "session_wait needs session_id or session_ids")))
    (harness-tools-sessions--wait
     ctx timeout
     (lambda ()
       (funcall (if any #'cl-some #'cl-every)
                (lambda (pair) (harness-tools-sessions--reached-p (car pair) until (cdr pair)))
                (cl-mapcar #'cons ids baselines)))
     (lambda (why)
       (harness-tool-ok
        (concat (pcase why
                  ('met (format "Done waiting after %s (until %s)." (harness-format-duration (- (float-time) started)) until))
                  ('timeout (format "Still waiting after %ss; the condition (until %s) did not hold. Call session_wait again to keep waiting." timeout until))
                  (_ "The wait was interrupted."))
                "\n\n"
                (mapconcat (lambda (sid) (harness-tools-sessions--describe sid)) ids "\n\n")))))))

(harness-define-tool "session_wait"
  :label "Wait for sessions"
  :description "Wait for other sessions without polling. until=stopped (default) returns when each session is no longer running (its turn ended, it is blocked on the user, or it closed); idle, blocked and running wait for that status; changed waits for any new status, message or pending request. mode=all (default) waits for every session, any for the first. Returns each session's status, what it waits on and its last reply; on timeout it returns the same report, not an error."
  :schema '(:type "object"
            :properties (:session_id (:type "string" :description "A session id, unique id prefix or unique name.")
                         :session_ids (:type "array" :items (:type "string") :description "Several sessions.")
                         :until (:type "string" :enum ("stopped" "idle" "blocked" "running" "changed"))
                         :mode (:type "string" :enum ("all" "any"))
                         :timeout_seconds (:type "number" :description "Give up after this long (default 600, at most 3600).")))
  :kind 'read
  :timeout 3700
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

(defun harness-tools-sessions--task-line (task)
  "Return the listing of TASK.
Its title on the board, the name of its session once it has one, comes
before its prompt."
  (let* ((sid (plist-get task :session))
         (session (and sid (harness-call 'session/exists-p sid) (harness-call 'session/get sid)))
         (title (plist-get session :name))
         (pending (and session (harness-tools-sessions--pending-text session))))
    (concat
     (format "%s  %-11s %s%s" (plist-get task :id) (plist-get task :column)
             (if (harness-string-blank-p title) "" (format "%S: " title))
             (harness-truncate-end (harness-first-line (or (plist-get task :prompt) "")) 100))
     (format "\n    state %s%s%s%s%s%s%s"
             (plist-get task :state)
             (if (plist-get task :outcome) (format " (%s)" (plist-get task :outcome)) "")
             (if sid (format ", session %s %s" sid (if session (harness-tools-sessions--status sid) "deleted")) "")
             (if (plist-get task :branch) (format ", branch %s" (plist-get task :branch)) "")
             (cond ((plist-get task :merge-status) (format ", merge %s" (plist-get task :merge-status)))
                   ((harness-json-true-p (plist-get task :merged)) ", merged")
                   (t ""))
             (if (harness-json-true-p (plist-get task :verified)) ", verified" "")
             (let ((rounds (length (plist-get task :feedback))))
               (if (> rounds 0) (format ", sent back %d time%s" rounds (if (= rounds 1) "" "s")) "")))
     (if (plist-get task :archived) ", archived" "")
     (if pending (format "\n    waiting on the user: %s" pending) ""))))

(defun harness-tools-sessions--task-list (input ctx)
  "Handler of task_list."
  (harness-tools-sessions--tasks-p)
  (let* ((cwd (unless (harness-json-true-p (plist-get input :all_projects)) (plist-get ctx :cwd)))
         (column (let ((c (plist-get input :column))) (and c (intern c))))
         (archived (harness-json-true-p (plist-get input :include_archived)))
         (tasks (cl-remove-if-not
                 (lambda (task) (and (or archived (not (plist-get task :archived)))
                                     (or (null column) (eq column (plist-get task :column)))))
                 (harness-call 'task/list cwd))))
    (harness-tool-ok
     (if tasks
         (mapconcat #'harness-tools-sessions--task-line tasks "\n")
       "No tasks match."))))

(harness-define-tool "task_list"
  :label "List tasks"
  :description "List the task board: tasks (one session each, usually in its own worktree, done once the user verified the work and it merged) with their title (their session's name, once it has one), prompt, column (pending, needs-input, active, review, done), state, session, branch, merge status and review status. A task in review has finished and waits for the user to verify it or send it back. Defaults to this project's unarchived tasks. Inspect a task's work with session_read on its session."
  :schema '(:type "object"
            :properties (:column (:type "string" :enum ("pending" "needs-input" "active" "review" "done"))
                         :include_archived (:type "boolean" :description "Include archived tasks (default false).")
                         :all_projects (:type "boolean" :description "Every project (default false).")))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :column))
  :handler #'harness-tools-sessions--task-list)

(defun harness-tools-sessions--task-submit (input ctx)
  "Handler of task_submit."
  (harness-tools-sessions--tasks-p)
  (let* ((prompt (or (plist-get input :prompt) ""))
         (cwd (or (plist-get input :cwd) (plist-get ctx :cwd)))
         (refine (harness-json-true-p (plist-get input :refine)))
         (opts (append (and (plist-get input :model) (list :model (plist-get input :model)))
                       (and (plist-get input :thinking) (list :thinking (plist-get input :thinking)))
                       (and refine (list :refine t))))
         (task (harness-call 'task/submit cwd prompt opts)))
    (harness-tool-ok (concat (if refine "Added to the backlog; an agent is writing it up.\n" "Submitted.\n")
                             (harness-tools-sessions--task-line task))
                     :meta (list :task-id (plist-get task :id)))))

(harness-define-tool "task_submit"
  :label "Submit task"
  :description "Add a task to the task board. The task runs in its own session (in a git project, in a fresh worktree whose branch is merged back through the merge queue) with the task defaults for permissions; it starts when a slot is free. By default finished work waits in review until the user verifies it (task_control verify) or sends it back (task_control reject). With refine=true it goes to the backlog instead: an agent briefly writes it up, read-only, and it waits in pending until someone starts it (task_control start), which is how to record work for later. Returns the task id; follow it with task_wait or task_list."
  :schema '(:type "object"
            :properties (:prompt (:type "string" :description "What the task should do; self-contained, the task does not see this conversation.")
                         :cwd (:type "string" :description "Project directory (default: this session's).")
                         :model (:type "string" :description "Model id (default: the task default).")
                         :thinking (:type "string" :description "Thinking level (default: the task default).")
                         :refine (:type "boolean" :description "Write it up for the backlog instead of starting it (default false)."))
            :required ("prompt"))
  :kind 'meta
  :subject (lambda (input) (harness-first-line (plist-get input :prompt) 60))
  :handler #'harness-tools-sessions--task-submit)

(defun harness-tools-sessions--task-control (input _ctx)
  "Handler of task_control."
  (harness-tools-sessions--tasks-p)
  (let* ((task (harness-tools-sessions--task (plist-get input :task_id)))
         (id (plist-get task :id))
         (action (or (plist-get input :action) "")))
    (pcase action
      ("start" (harness-call 'task/start id))
      ("message"
       (let ((text (or (plist-get input :message) "")))
         (when (harness-string-blank-p text) (signal 'harness-error (list "message needs a message")))
         (if (eq (plist-get task :state) 'pending)
             (harness-call 'task/update id (concat (plist-get task :prompt) "\n\n" text) (plist-get task :attachments))
           (harness-call 'task/prompt id text))))
      ("cancel" (harness-call 'task/cancel id))
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
      (_ (signal 'harness-error (list (format "Unknown action %S" action)))))
    (harness-tool-ok
     (if (ignore-errors (harness-call 'task/get id))
         (format "%s done.\n%s" action (harness-tools-sessions--task-line (harness-call 'task/get id)))
       (format "%s done; task %s is gone." action id)))))

(harness-define-tool "task_control"
  :label "Control task"
  :description "Act on a task. start runs a pending task now; message sends a follow-up to its session (or, while pending, appends to its prompt); cancel drops a pending task or stops a working one's turn; merge retries the merge queue after a failed merge; verify accepts the work of a task in review (its branch then merges and it is done); reject sends a task in review back to its session with the feedback in message, to work on it again; complete marks it done by hand; archive hides a done task (removing a merged task's worktree); restore unarchives; delete forgets the task (its session and worktree are kept)."
  :schema '(:type "object"
            :properties (:task_id (:type "string" :description "Task id or unique prefix.")
                         :action (:type "string" :enum ("start" "message" "cancel" "merge" "verify" "reject" "complete" "archive" "restore" "delete"))
                         :message (:type "string" :description "Text, for message; the feedback, for reject."))
            :required ("task_id" "action"))
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
            ("changed" (not (equal (list column (plist-get task :state) (plist-get task :merge-status)) baseline)))
            ;; Finished work waits for the user's review, and a backlog
            ;; task that is written up for someone to start it.
            (_ (or (memq column '(done needs-input review))
                   (and (eq (plist-get task :state) 'pending) (plist-get task :backlog) t))))))))

(defun harness-tools-sessions--task-wait (input ctx)
  "Handler of task_wait."
  (harness-tools-sessions--tasks-p)
  (let* ((ids (mapcar (lambda (r) (plist-get (harness-tools-sessions--task r) :id))
                      (harness-tools-sessions--refs input :task_id :task_ids)))
         (until (or (plist-get input :until) "settled"))
         (any (equal (plist-get input :mode) "any"))
         (baselines (mapcar (lambda (id) (let ((task (harness-call 'task/get id)))
                                           (list (plist-get task :column) (plist-get task :state) (plist-get task :merge-status))))
                            ids))
         (timeout (harness-tools-sessions--timeout input))
         (started (float-time)))
    (unless ids (signal 'harness-error (list "task_wait needs task_id or task_ids")))
    (harness-tools-sessions--wait
     ctx timeout
     (lambda ()
       (funcall (if any #'cl-some #'cl-every)
                (lambda (pair) (harness-tools-sessions--task-reached-p (car pair) until (cdr pair)))
                (cl-mapcar #'cons ids baselines)))
     (lambda (why)
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
                 ids "\n\n")))))))

(harness-define-tool "task_wait"
  :label "Wait for tasks"
  :description "Wait for tasks without polling. until=settled (default) returns when each task is done, needs input or waits in review for the user to verify it, or is written up and waits in the backlog for someone to start it; done, needs-input, active and review wait for that column; changed waits for any change of column, state or merge status. mode=all (default) waits for every task, any for the first. Returns each task's line and its session's last reply; on timeout it returns the same report, not an error."
  :schema '(:type "object"
            :properties (:task_id (:type "string" :description "A task id or unique prefix.")
                         :task_ids (:type "array" :items (:type "string") :description "Several tasks.")
                         :until (:type "string" :enum ("settled" "done" "needs-input" "active" "review" "changed"))
                         :mode (:type "string" :enum ("all" "any"))
                         :timeout_seconds (:type "number" :description "Give up after this long (default 600, at most 3600).")))
  :kind 'read
  :timeout 3700
  :subject (lambda (input) (string-join (harness-tools-sessions--refs input :task_id :task_ids) " "))
  :handler #'harness-tools-sessions--task-wait)

;;;; Registration

(defun harness-tools-sessions--init ()
  "Subscribe the waits to session and task events (idempotent)."
  (dolist (ev '(session/status session/changed session/deleted session/pending-changed
                agent/turn-started task/changed task/deleted))
    (harness-on ev #'harness-tools-sessions--poke 90))
  (harness-on 'agent/turn-ended #'harness-tools-sessions--on-turn-ended 90))

(harness-tools-sessions--init)

(harness-define-module 'tools-sessions
  :doc "Tools to list, search, read, message, control and wait on sessions and tasks."
  :requires '(tools session agent)
  :init #'harness-tools-sessions--init)

(provide 'harness-tools-sessions)
;;; harness-tools-sessions.el ends here
