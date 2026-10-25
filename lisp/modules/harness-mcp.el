;;; harness-mcp.el --- MCP host: tool servers that run in the session's sandbox  -*- lexical-binding: t; -*-

;;; Commentary:

;; The harness core brokers; it does not run what an agent asks for.  A
;; tool that touches files or starts code at the agent's direction runs
;; in a process the OS confines to the directories the session may use,
;; and the core talks to that process over a pipe in the Model Context
;; Protocol (lisp/harness-mcp-protocol.el), the way any MCP host talks
;; to a server it starts.  Nothing in the pipe is code: a request names
;; a tool of the server and gives its arguments, and the server, which
;; can reach only what the jail shows it, does the work.  Whatever the
;; permission chain, a judge or a prompt decided, the kernel decides
;; what that process can touch, so no other tool can be used to get
;; around it.  This module is the host: it starts the servers, keeps
;; them, sends them calls and brings their results back.
;;
;; A server is declared with `harness-mcp-define-server': the program to
;; start (`:command', a function of the call's context), the sandbox it
;; runs in (`:profile', by default the session's: the same mounts a bash
;; command of the session gets -- its working directory and worktree, its
;; own temporary directory, the directories granted to it, the skills
;; directories, and whatever the filter `tools/sandbox-options' adds) and
;; how long it lives.  A call, `harness-mcp-call', finds or starts the
;; server's process for the call's session and sends `tools/call'.
;; Starting follows the sandbox policy as a bash command does: with
;; `required' and no backend the call fails, it never runs unconfined;
;; with `preferred' and no backend the process runs unconfined, with a
;; warning in the log, and the status says so.
;;
;; One process serves one session (`:scope session'), started when its
;; first call arrives and stopped when it has been idle for
;; `harness-mcp-idle-seconds', when the session is deleted, when the
;; harness shuts down or reloads, or when the session's sandbox changes:
;; the mounts are fixed at start, so a directory granted to the session
;; or taken away from it starts a new process, once the one running is
;; idle.  A program that serves one request at a time (`:serial', the
;; default) is sent them one at a time, and the host's own queue holds the
;; rest, so a call's timeout runs from when it was sent.  A call that
;; runs past its timeout, or a program that dies, ends the process: it
;; cannot be told to stop what it is doing, and a call that was waiting
;; behind it starts a fresh one.
;;
;; What a server may announce to the harness is only what its
;; declaration lists (`:events'): a `notifications/message' whose
;; `logger' is \"harness\" and whose data is {\"event\": NAME, \"args\":
;; [...]}, which this module emits as the harness event NAME.  Progress
;; notifications go to the call's `:report' function.
;;
;; The Emacs a client lends the harness is a server too, one the host
;; does not start: `:external' servers are given connections with
;; `harness-mcp-attach', whose messages the owner of the transport (the
;; ACP connection, in lisp/modules/harness-acp.el) sends and receives.
;; They get no sandbox, since the program on the other end is the
;; user's own Emacs; what bounds them is the fixed vocabulary of
;; their tools.
;;
;; Methods: `mcp/servers' (what runs, for the access view and the
;; tests), `mcp/stop'.  Neither can be called over ACP.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-mcp-protocol)

(declare-function harness-tools-shell-sandbox-profile "harness-tools-shell" (ctx cwd &rest options))
(declare-function harness-tools-shell-wrap-profile "harness-tools-shell" (profile command))

(defcustom harness-mcp-idle-seconds 300
  "Seconds a server's process may be idle before the harness stops it.
It starts again when the session's next call needs it.  A server's
declaration may ask for another time."
  :type 'integer :group 'harness)

(defconst harness-mcp--init-timeout 30
  "Seconds a server has to answer `initialize' before it is given up on.")

(defconst harness-mcp--call-timeout 120
  "Seconds a call may take when its caller names no timeout.")

(defconst harness-mcp--max-line-bytes (* 128 1024 1024)
  "Longest message a server may send, in characters.
A server that sends more is stopped: nothing a tool returns is read
whole at that size, and the harness would hold it all in memory.")

(defconst harness-mcp--stderr-keep 8000
  "Characters of a server's standard error kept for a message about it.")

(defconst harness-mcp--idle-check 30
  "Seconds between looks at the servers that have been idle too long.")

(defconst harness-mcp--kill-grace 2
  "Seconds a stopped server has to exit on its own before it is killed.")

;;;; Declared servers

(defvar harness-mcp--servers (make-hash-table :test 'eq)
  "Server name (a symbol) -> the plist `harness-mcp-define-server' made.")

(cl-defun harness-mcp-define-server (name &key title doc command profile (scope 'session)
                                          (serial t) idle events external env
                                          (init-timeout harness-mcp--init-timeout))
  "Declare the MCP server NAME, a symbol, and return NAME.
TITLE and DOC say what it is.  COMMAND is a function of the call's
context (the plist a tool handler gets, with `:session-id', `:cwd' and
`:host') returning the program and its arguments, a list of strings.
PROFILE is a function of that context returning the sandbox profile the
program runs in (see `harness-tools-shell-sandbox-profile'); the default
is the session's own, the one a bash command of it gets.  A profile that
cannot be had signals why, and the call fails with that.  Neither is
used by an EXTERNAL server, whose connections come from
`harness-mcp-attach'.

SCOPE is `session' (one process per session) or `global' (one).  SERIAL
non-nil sends the process one request at a time; IDLE overrides
`harness-mcp-idle-seconds'; EVENTS lists the harness events the server
may announce (see the Commentary); ENV is an alist of environment
variables for the process; INIT-TIMEOUT is how many seconds it has to
answer `initialize'.  Declaring a name again replaces the declaration,
as a reload does; processes already running keep going until they stop."
  (unless (symbolp name) (error "An MCP server's name is a symbol: %S" name))
  (unless (or external (functionp command))
    (error "MCP server %s needs a :command function, or to be :external" name))
  (puthash name (list :name name :title title :doc doc :command command :profile profile
                      :scope scope :serial serial :idle idle :events events
                      :external external :env env :init-timeout init-timeout)
           harness-mcp--servers)
  name)

(defun harness-mcp-server-declared-p (name)
  "Non-nil when an MCP server NAME is declared."
  (and (gethash name harness-mcp--servers) t))

(defun harness-mcp--decl (server)
  "Return the declaration of SERVER, or signal why there is none."
  (or (gethash server harness-mcp--servers)
      (signal 'harness-error (list (format "No MCP server %s is declared" server)))))

;;;; Connections

(cl-defstruct (harness-mcp--conn (:constructor harness-mcp--conn-create) (:copier nil))
  "A connection to a server: a process the host started, or an attached transport."
  server key proc send (state 'starting) profile confined
  (pending (make-hash-table :test 'eql)) (progress (make-hash-table :test 'equal))
  (next-id 0) partial (partial-size 0) tools info
  started last-used stderr scope ready-timer)

(defvar harness-mcp--conns (make-hash-table :test 'equal)
  "(SERVER . SCOPE) -> the `harness-mcp--conn' serving it, if any.")

(defvar harness-mcp--queues (make-hash-table :test 'equal)
  "(SERVER . SCOPE) -> the calls waiting for that connection, oldest first.")

(defvar harness-mcp--idle-timer nil
  "The timer that stops servers that have been idle too long.")

(defun harness-mcp--reason (err)
  "Return the message of ERR, a rejection or an error."
  (if (and (consp err) (symbolp (car err)) (stringp (cadr err)) (null (cddr err)))
      (cadr err)
    (harness-error-message err)))

(defun harness-mcp--scope-key (decl ctx key)
  "Return the scope of a call with CTX under DECL: KEY, else the session, else t."
  (cond (key key)
        ((or (eq (plist-get decl :scope) 'global)
             ;; A server the harness does not start, whose transport came
             ;; with a client: one connection, whatever the session.
             (plist-get decl :external))
         t)
        (t (or (plist-get ctx :session-id) t))))

(defun harness-mcp--trim-stderr (conn)
  "Keep only the tail of CONN's standard error buffer."
  (when-let* ((buffer (harness-mcp--conn-stderr conn))
              (_ (buffer-live-p buffer)))
    (with-current-buffer buffer
      (when (> (buffer-size) (* 2 harness-mcp--stderr-keep))
        (let ((inhibit-read-only t))
          (delete-region (point-min) (- (point-max) harness-mcp--stderr-keep)))))))

(defun harness-mcp--stderr-tail (conn)
  "Return the last of what CONN's process wrote to standard error, or nil."
  (when-let* ((buffer (harness-mcp--conn-stderr conn))
              (_ (buffer-live-p buffer)))
    (let ((text (string-trim (with-current-buffer buffer (buffer-string)))))
      (and (not (string-empty-p text))
           (harness-truncate-end (string-join (last (split-string text "\n" t) 4) " | ") 400)))))

(defun harness-mcp--inflight (conn)
  "Return how many calls CONN's server is working on."
  (let ((n 0))
    (maphash (lambda (_ entry) (when (plist-get entry :call) (cl-incf n)))
             (harness-mcp--conn-pending conn))
    n))

;;;; Sending and receiving

(defun harness-mcp--send (conn message)
  "Send MESSAGE to the server of CONN."
  (funcall (harness-mcp--conn-send conn) message))

(defun harness-mcp--fail-pending (conn reason)
  "Reject every request CONN is waiting on, for REASON, a message."
  (let (entries)
    (maphash (lambda (_ entry) (push entry entries)) (harness-mcp--conn-pending conn))
    (clrhash (harness-mcp--conn-pending conn))
    (clrhash (harness-mcp--conn-progress conn))
    (dolist (entry entries)
      (when-let* ((timer (plist-get entry :timer))) (cancel-timer timer))
      (harness-reject (plist-get entry :promise) (list 'harness-error reason)))))

(defun harness-mcp--stop-process (proc)
  "Stop PROC, a server's process: ask it to finish, kill it if it does not."
  (ignore-errors (process-send-eof proc))
  (let ((tree (ignore-errors (harness-process-tree (process-id proc) nil))))
    (run-at-time harness-mcp--kill-grace nil
                 (lambda ()
                   (when (process-live-p proc)
                     (when tree (harness-kill-process-tree tree 'kill))
                     (ignore-errors (delete-process proc)))))
    ;; A server stuck in a call does not read its input: it is told to go.
    (when tree (harness-kill-process-tree tree 'term))))

(defun harness-mcp--close (conn reason &optional keep-process fail-queue)
  "Close CONN for REASON, a message: fail what it waits on and stop its process.
CONN is forgotten, so the next call starts a new one, for the calls
waiting in line.  KEEP-PROCESS non-nil leaves the process alone, which
has exited on its own.  FAIL-QUEUE non-nil fails the calls in line too:
the server could not start, and starting it again would only repeat
that.  A process of ours that goes before it is ready fails them too,
whether FAIL-QUEUE says so or not."
  (unless (eq (harness-mcp--conn-state conn) 'closed)
    (let ((starting (eq (harness-mcp--conn-state conn) 'starting)))
      (setf (harness-mcp--conn-state conn) 'closed)
      (when-let* ((timer (harness-mcp--conn-ready-timer conn))) (cancel-timer timer))
      (let ((key (harness-mcp--conn-key conn))
            (tail (harness-mcp--stderr-tail conn)))
        (when (eq (gethash key harness-mcp--conns) conn)
          (remhash key harness-mcp--conns))
        (let ((why (if tail (format "%s (it said: %s)" reason tail) reason)))
          (harness-mcp--fail-pending conn why)
          ;; A process that goes before it is ready cannot serve the calls
          ;; in line, and starting it again would only repeat that; nor do
          ;; the calls waiting for a server that was stopped start it anew.
          (when (or fail-queue (and starting (harness-mcp--conn-proc conn)))
            (harness-mcp--fail-queue
             key (if (and starting (not fail-queue))
                     (format "The MCP server %s did not start: %s" (car key) why)
                   (format "The MCP server %s %s" (car key) why)))))
      (when-let* ((proc (harness-mcp--conn-proc conn))
                  (_ (and (not keep-process) (process-live-p proc))))
        (harness-mcp--stop-process proc))
      (when-let* ((buffer (harness-mcp--conn-stderr conn)))
        (run-at-time 5 nil (lambda () (when (buffer-live-p buffer) (kill-buffer buffer)))))
      (harness-log 'debug "mcp: closed %S: %s" key reason)
      ;; What waited for this connection starts a new one.
      (harness-run-soon #'harness-mcp--pump key)))))

(defun harness-mcp--request (conn method params timeout &optional extra)
  "Send CONN the request METHOD with PARAMS; return a promise of its result.
The promise rejects with the server's error, and when TIMEOUT seconds
pass without an answer, which also closes CONN: a server stuck in a
call cannot be told to stop.  EXTRA is more for the request's entry,
which the answer and the notifications about it find by the request's id."
  (let* ((id (cl-incf (harness-mcp--conn-next-id conn)))
         (promise (harness-make-promise))
         (timer (run-at-time timeout nil #'harness-mcp--timed-out conn id timeout))
         (entry (append (list :promise promise :method method :timer timer) extra)))
    (puthash id entry (harness-mcp--conn-pending conn))
    (condition-case err
        (harness-mcp--send conn (harness-mcp-request id method params))
      (error
       (remhash id (harness-mcp--conn-pending conn))
       (cancel-timer timer)
       (harness-reject promise (list 'harness-error
                                     (format "Could not send to the MCP server: %s"
                                             (harness-error-message err))))))
    promise))

(defun harness-mcp--timed-out (conn id seconds)
  "Give up on the request ID of CONN, which waited SECONDS, and stop the server."
  (when-let* ((entry (gethash id (harness-mcp--conn-pending conn))))
    (ignore-errors (harness-mcp--send conn (harness-mcp-notification
                                            "notifications/cancelled"
                                            (list :requestId id :reason "timed out"))))
    (let ((message (format "The MCP server %s did not answer %s within %ss"
                           (car (harness-mcp--conn-key conn)) (plist-get entry :method) seconds)))
      (remhash id (harness-mcp--conn-pending conn))
      (harness-reject (plist-get entry :promise) (list 'harness-error message)))
    (harness-mcp--close conn (format "it did not answer within %ss" seconds))))

(defun harness-mcp--settle (conn message)
  "Hand the result or error MESSAGE of CONN to the request it answers."
  (let* ((id (plist-get message :id))
         (entry (and id (gethash id (harness-mcp--conn-pending conn)))))
    (if (null entry)
        (harness-log 'debug "mcp: %S answered a request nobody waits on (%S)"
                     (harness-mcp--conn-key conn) id)
      (remhash id (harness-mcp--conn-pending conn))
      (when-let* ((token (plist-get entry :token))) (remhash token (harness-mcp--conn-progress conn)))
      (when-let* ((timer (plist-get entry :timer))) (cancel-timer timer))
      (setf (harness-mcp--conn-last-used conn) (float-time))
      (if (eq (harness-mcp-message-kind message) 'error)
          (harness-reject (plist-get entry :promise)
                          (list 'harness-error
                                (format "MCP server %s: %s" (car (harness-mcp--conn-key conn))
                                        (or (plist-get (plist-get message :error) :message)
                                            "an error without a message"))))
        (harness-resolve (plist-get entry :promise) (plist-get message :result)))
      ;; Room for the next call in line.
      (harness-mcp--pump (harness-mcp--conn-key conn)))))

(defun harness-mcp--announce (conn params)
  "Emit the harness event a server announced in the log message PARAMS, if allowed.
Only a `notifications/message' of logger \"harness\" counts, and only for
an event the server's declaration lists; anything else is logged."
  (let* ((decl (gethash (car (harness-mcp--conn-key conn)) harness-mcp--servers))
         (data (plist-get params :data))
         (event (and (equal (plist-get params :logger) "harness") (consp data) (plist-get data :event)))
         (symbol (and (stringp event) (intern event))))
    (cond
     ((and symbol (memq symbol (plist-get decl :events)))
      (apply #'harness-emit symbol (plist-get data :args)))
     (event
      (harness-log 'warn "mcp: %S announced the event %s, which its declaration does not allow"
                   (harness-mcp--conn-key conn) event))
     (t (harness-log 'debug "mcp: %S says: %s" (harness-mcp--conn-key conn)
                     (harness-truncate-end (format "%S" data) 300))))))

(defun harness-mcp--serve-request (conn message)
  "Answer MESSAGE, a request the server of CONN made of the host."
  (let ((id (plist-get message :id)))
    (harness-mcp--send
     conn (if (equal (plist-get message :method) "ping")
              (harness-mcp-response id nil)
            (harness-mcp-error-response id harness-mcp-error-method-not-found
                                        (format "The harness answers no %s" (plist-get message :method)))))))

(defun harness-mcp-receive (conn message)
  "Take MESSAGE, one decoded JSON-RPC message from the server of CONN.
A transport that is not a process of ours (`harness-mcp-attach') calls
this for what comes from the other end."
  (setf (harness-mcp--conn-last-used conn) (float-time))
  (pcase (harness-mcp-message-kind message)
    ((or 'result 'error) (harness-mcp--settle conn message))
    ('request (harness-mcp--serve-request conn message))
    ('notification
     (let ((params (plist-get message :params)))
       (pcase (plist-get message :method)
         ("notifications/progress"
          (when-let* ((report (gethash (plist-get params :progressToken) (harness-mcp--conn-progress conn)))
                      (text (plist-get params :message)))
            (funcall report text)))
         ("notifications/message" (harness-mcp--announce conn params))
         ("notifications/tools/list_changed" (setf (harness-mcp--conn-tools conn) nil))
         (_ nil))))
    (_ (harness-log 'warn "mcp: %S sent something that is no message" (harness-mcp--conn-key conn)))))

;;;; The process of a server

(defun harness-mcp--filter (conn chunk)
  "Take CHUNK, text from the process of CONN: complete lines are messages."
  (let ((parts (split-string chunk "\n")))
    (cl-incf (harness-mcp--conn-partial-size conn) (length chunk))
    (if (null (cdr parts))
        (push chunk (harness-mcp--conn-partial conn))
      (let ((first t) (lines nil))
        (while (cdr parts)
          (push (if first
                    (apply #'concat (nreverse (cons (car parts) (harness-mcp--conn-partial conn))))
                  (car parts))
                lines)
          (setq first nil parts (cdr parts)))
        (setf (harness-mcp--conn-partial conn) (list (car parts))
              (harness-mcp--conn-partial-size conn) (length (car parts)))
        (dolist (line (nreverse lines))
          (unless (or (string-empty-p line) (eq (harness-mcp--conn-state conn) 'closed))
            (condition-case err
                (harness-mcp-receive conn (harness-mcp-decode-line line))
              (error (harness-log 'warn "mcp: %S sent a line that is no message: %s"
                                  (harness-mcp--conn-key conn) (harness-error-message err))))))))
    (when (> (harness-mcp--conn-partial-size conn) harness-mcp--max-line-bytes)
      (harness-mcp--close conn "it sent a message too long to read"))))

(defun harness-mcp--spawn (key decl entry)
  "Start the process of the server KEY, declared as DECL, for the call ENTRY.
Return the connection, in state `starting'.  Signals why it cannot run,
such as a policy that requires a sandbox there is none of."
  (let* ((argv (funcall (plist-get entry :wrap)))
         (ctx (plist-get entry :ctx))
         (name (format "harness-mcp-%s" (car key)))
         (stderr (generate-new-buffer (format " *%s-stderr*" name) t))
         (cwd (let ((c (plist-get ctx :cwd)))
                (if (and (stringp c) (not (file-remote-p c)) (file-directory-p c)) c temporary-file-directory)))
         (conn (harness-mcp--conn-create :server (car key) :key key
                                         :profile (plist-get entry :profile)
                                         :confined (plist-get entry :confined)
                                         :started (float-time) :last-used (float-time)
                                         :scope (cdr key) :stderr stderr))
         (process-environment (append (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair)))
                                              (plist-get decl :env))
                                      process-environment))
         (default-directory (file-name-as-directory cwd)))
    (condition-case err
        (setf (harness-mcp--conn-proc conn)
              (make-process :name name :command argv :connection-type 'pipe :noquery t
                            :coding 'utf-8-unix :stderr stderr
                            :filter (lambda (_proc chunk) (harness-mcp--filter conn chunk))
                            :sentinel (lambda (proc _event)
                                        (unless (process-live-p proc)
                                          (harness-mcp--close
                                           conn (format "it exited (%s)" (process-exit-status proc)) t)))))
      (error (kill-buffer stderr) (signal (car err) (cdr err))))
    (when-let* ((ep (get-buffer-process stderr)))
      (set-process-query-on-exit-flag ep nil)
      (set-process-filter ep (lambda (p chunk)
                               (when (buffer-live-p (process-buffer p))
                                 (with-current-buffer (process-buffer p)
                                   (goto-char (point-max))
                                   (insert chunk)))
                               (harness-mcp--trim-stderr conn))))
    (setf (harness-mcp--conn-send conn)
          (let ((proc (harness-mcp--conn-proc conn)))
            (lambda (message) (harness-process-send proc (harness-mcp-encode-line message)))))
    conn))

;;;; Starting a connection

(defconst harness-mcp--client-info
  (list :name "emacs-agent-harness" :version "3")
  "What the host tells a server it is.")

(defun harness-mcp--handshake (conn decl)
  "Send `initialize' on CONN, and become ready when the server has answered."
  (harness-then
   (harness-mcp--request conn "initialize"
                         (list :protocolVersion harness-mcp-protocol-version
                               :capabilities :empty
                               :clientInfo harness-mcp--client-info)
                         (plist-get decl :init-timeout))
   (lambda (result)
     (unless (eq (harness-mcp--conn-state conn) 'closed)
       (setf (harness-mcp--conn-info conn) (plist-get result :serverInfo))
       (harness-mcp--send conn (harness-mcp-notification "notifications/initialized"))
       (setf (harness-mcp--conn-state conn) 'ready
             (harness-mcp--conn-last-used conn) (float-time))
       (harness-mcp--pump (harness-mcp--conn-key conn)))
     nil)
   (lambda (err)
     (harness-mcp--close conn (format "did not start: %s" (harness-mcp--reason err)) nil t)
     nil)))

(defun harness-mcp--start (key entry)
  "Start the server KEY for the call ENTRY, which waits for it."
  (let ((decl (plist-get entry :decl)))
    (condition-case err
        (let ((conn (harness-mcp--spawn key decl entry)))
          (puthash key conn harness-mcp--conns)
          (harness-log 'debug "mcp: started %S (%s)" key
                       (if (plist-get entry :confined) "sandboxed" "NOT sandboxed"))
          (harness-mcp--handshake conn decl))
      (error
       (harness-mcp--fail-queue key (format "The MCP server %s could not start: %s" (car key)
                                            (harness-error-message err)))))))

(defun harness-mcp--fail-queue (key message)
  "Reject every call waiting for the server KEY, for MESSAGE."
  (let ((queue (gethash key harness-mcp--queues)))
    (remhash key harness-mcp--queues)
    (dolist (entry queue)
      (harness-reject (plist-get entry :promise) (list 'harness-error message)))))

;;;; The queue of a server

(defun harness-mcp--send-entry (conn entry)
  "Send the waiting call ENTRY on CONN, and settle its promise with the answer."
  (let* ((token (and (plist-get entry :report) (format "p-%s" (harness-short-id 10))))
         (params (plist-get entry :params))
         (params (if token
                     (plist-put (copy-sequence params) :_meta
                                (append (list :progressToken token) (plist-get params :_meta)))
                   params))
         (promise (harness-mcp--request conn (plist-get entry :method) params
                                        (or (plist-get entry :timeout) harness-mcp--call-timeout)
                                        (list :call t :token token))))
    (when token
      (puthash token (plist-get entry :report) (harness-mcp--conn-progress conn)))
    (harness-then promise
                  (lambda (result) (harness-resolve (plist-get entry :promise) result) nil)
                  (lambda (err) (harness-reject (plist-get entry :promise) err) nil))))

(defun harness-mcp--pump (key)
  "Send the calls waiting for the server KEY that can go, start it if it must."
  (let* ((queue (gethash key harness-mcp--queues))
         (entry (car queue))
         (conn (gethash key harness-mcp--conns)))
    (when entry
      (let ((decl (plist-get entry :decl)))
        (cond
         ((and (or (null conn) (eq (harness-mcp--conn-state conn) 'closed)) (plist-get decl :external))
          (harness-mcp--fail-queue key (format "No %s is attached to the harness"
                                               (or (plist-get decl :title) (car key)))))
         ((or (null conn) (eq (harness-mcp--conn-state conn) 'closed))
          (when conn (remhash key harness-mcp--conns))
          (harness-mcp--start key entry))
         ((eq (harness-mcp--conn-state conn) 'starting) nil)
         ;; The sandbox changed: its mounts are fixed at start, so a new
         ;; process serves this call, once the old one is done.
         ((and (not (plist-get decl :external))
               (not (equal (harness-mcp--conn-profile conn) (plist-get entry :profile))))
          (when (zerop (harness-mcp--inflight conn))
            (harness-mcp--close conn "the session's sandbox changed")))
         ((and (plist-get decl :serial) (> (harness-mcp--inflight conn) 0)) nil)
         (t
          (puthash key (cdr queue) harness-mcp--queues)
          (harness-mcp--send-entry conn entry)
          (unless (plist-get decl :serial) (harness-mcp--pump key))))))))

;;;; Calling a server

(defun harness-mcp--context-meta (ctx)
  "Return the call context a tool of the server is given, from CTX."
  (let (meta)
    (dolist (pair '((:sessionId . :session-id) (:cwd . :cwd) (:host . :host) (:callId . :call-id)))
      (when-let* ((value (plist-get ctx (cdr pair))))
        (setq meta (append meta (list (car pair) value)))))
    meta))

(defun harness-mcp--confined-p (profile)
  "Non-nil when a command run under PROFILE is confined by the sandbox."
  (let ((cwd (plist-get profile :cwd)))
    (and (stringp cwd) (harness-method-exists-p 'sandbox/confined-p)
         (condition-case nil (harness-call 'sandbox/confined-p cwd) (error nil))
         t)))

(defun harness-mcp--launch (decl ctx)
  "Return (WRAP PROFILE-KEY CONFINED) for the server DECL on a call with CTX.
WRAP is a function that returns the program to run, wrapped for the
sandbox; it is only called when a process starts.  PROFILE-KEY is a
hash of what the process is, which tells a running process from one
the call needs.  CONFINED says whether the sandbox will apply.  Signals
why the server may not run."
  (let* ((argv (funcall (plist-get decl :command) ctx))
         (cwd (or (plist-get ctx :cwd) default-directory))
         (profile (progn
                    (unless (or (plist-get decl :profile) (fboundp 'harness-tools-shell-sandbox-profile))
                      (require 'harness-tools-shell nil t))
                    (cond ((plist-get decl :profile) (funcall (plist-get decl :profile) ctx))
                          ((fboundp 'harness-tools-shell-sandbox-profile)
                           (harness-tools-shell-sandbox-profile ctx cwd))
                          (t (error "The sandbox is not available: the tools-shell module is not loaded"))))))
    (list (lambda () (harness-tools-shell-wrap-profile profile argv))
          (secure-hash 'sha1 (prin1-to-string (list argv profile)))
          (harness-mcp--confined-p profile))))

(defun harness-mcp--submit (server method params ctx key timeout report)
  "Queue METHOD with PARAMS for SERVER on behalf of CTX; return (PROMISE . ENTRY).
KEY, TIMEOUT and REPORT are as for `harness-mcp-call'."
  (let* ((decl (harness-mcp--decl server))
         (launch (and (not (plist-get decl :external)) (harness-mcp--launch decl ctx)))
         (promise (harness-make-promise))
         (entry (list :promise promise :decl decl :ctx ctx :method method :params params
                      :wrap (nth 0 launch) :profile (nth 1 launch) :confined (nth 2 launch)
                      :timeout timeout :report report))
         (qkey (cons server (harness-mcp--scope-key decl ctx key))))
    (puthash qkey (append (gethash qkey harness-mcp--queues) (list entry)) harness-mcp--queues)
    (harness-mcp--pump qkey)
    (cons promise entry)))

(cl-defun harness-mcp-call (server tool arguments &key ctx timeout meta report key)
  "Call TOOL of the MCP server SERVER with ARGUMENTS; return a promise.
It resolves to the CallToolResult (see `harness-mcp-protocol'), and
rejects when the server could not be started, did not answer in TIMEOUT
seconds, died, or answered with an error of the protocol.  CTX is the
context of the call, a tool handler's: it decides which process serves
it (the session's) and what the server is told of the call.  META is
more for the request's `_meta'; REPORT, a function of a string, gets the
server's progress messages; KEY serves an `:external' server's call from
the connection of that key, not the newest."
  (condition-case err
      (let ((context (harness-mcp--context-meta ctx)))
        (car (harness-mcp--submit
              server "tools/call"
              (list :name tool :arguments (or arguments :empty)
                    :_meta (append (and context (list harness-mcp-context-key context)) meta))
              ctx key timeout report)))
    (error (harness-rejected err))))

(defun harness-mcp-call-tool (server tool input ctx &optional timeout meta key)
  "Call TOOL of SERVER with INPUT for a harness tool's call under CTX.
Return a promise of the harness tool RESULT: the server's result with
what it carried across (`harness-mcp-call-result-to-tool-result'), and
`:meta' saying which server answered and whether it ran in the sandbox.
A failure of the host is a RESULT that is an error, never a rejection.
META is more for the request's `_meta' (a plist, keys as the server
reads them).  KEY names the process that serves the call, where the
session's own would not do: a call that needs a sandbox of its own,
with mounts the session's lacks, takes a key that says which, and gets
a process for it.  A key that is a cons `(SESSION . REST)' belongs to
SESSION, whose deletion stops the process."
  (condition-case err
      (let* ((context (harness-mcp--context-meta ctx))
             (submitted (harness-mcp--submit
                         server "tools/call"
                         (list :name tool :arguments (or input :empty)
                               :_meta (append (and context (list harness-mcp-context-key context)) meta))
                         ctx key timeout (plist-get ctx :report)))
             (confined (plist-get (cdr submitted) :confined)))
        (harness-then
         (car submitted)
         (lambda (result)
           (let ((tool-result (harness-mcp-call-result-to-tool-result result)))
             (plist-put tool-result :meta
                        (append (plist-get tool-result :meta)
                                (list :mcp (symbol-name server) :sandboxed (and confined t))))))
         (lambda (err)
           (list :content (format "The %s tool could not run: %s" tool (harness-mcp--reason err))
                 :is-error t :meta (list :mcp (symbol-name server) :sandboxed (and confined t))))))
    (error (harness-resolved
            (list :content (format "The %s tool could not run: %s" tool (harness-mcp--reason err))
                  :is-error t :meta (list :mcp (symbol-name server)))))))

(defun harness-mcp-tools (server &optional ctx key)
  "Return a promise of the tools SERVER lists, for the session of CTX.
The list is kept for the connection until the server says it changed."
  (let* ((decl (harness-mcp--decl server))
         (conn (gethash (cons server (harness-mcp--scope-key decl ctx key)) harness-mcp--conns)))
    (if (and conn (harness-mcp--conn-tools conn))
        (harness-resolved (harness-mcp--conn-tools conn))
      (harness-then
       (car (harness-mcp--submit server "tools/list" nil ctx key nil nil))
       (lambda (result)
         (let ((tools (plist-get result :tools))
               (conn (gethash (cons server (harness-mcp--scope-key decl ctx key)) harness-mcp--conns)))
           (when conn (setf (harness-mcp--conn-tools conn) tools))
           tools))))))

;;;; Attached transports

(cl-defun harness-mcp-attach (server send &key key)
  "Attach a transport to the `:external' MCP server SERVER; return its connection.
SEND is a function of one message, the host's request or notification
to the server on the other end.  KEY names the connection (the client's
id) when a server can have several; a call that names no key uses the
one of the scope `t', which the owner of the transport keeps pointing at
the connection that should serve.  The caller gives what comes back to
`harness-mcp-receive'.  The host starts with `initialize' as it does
with a process."
  (let* ((decl (harness-mcp--decl server))
         (scope (or key t))
         (qkey (cons server scope))
         (old (gethash qkey harness-mcp--conns))
         (conn (harness-mcp--conn-create :server server :key qkey :send send :confined nil
                                         :started (float-time) :last-used (float-time) :scope scope)))
    (unless (plist-get decl :external)
      (error "MCP server %s is started by the harness; nothing can be attached to it" server))
    (when old (harness-mcp--close old "a new connection replaced it" t))
    (puthash qkey conn harness-mcp--conns)
    (harness-mcp--handshake conn decl)
    conn))

(defun harness-mcp-detach (conn &optional reason)
  "Close the attached CONN, for REASON: its transport is gone."
  (harness-mcp--close conn (or reason "its transport closed") t))

;;;; Stopping

(defun harness-mcp-stop (&optional server scope reason)
  "Stop the processes of SERVER (default: all) for SCOPE (default: any).
Calls in flight and calls waiting for them fail with REASON: stopping a
server is not answered by starting another.  Return how many were
stopped."
  (let (conns)
    (maphash (lambda (key conn)
               (when (and (or (null server) (eq (car key) server))
                          (or (null scope) (equal (cdr key) scope)))
                 (push conn conns)))
             harness-mcp--conns)
    (dolist (conn conns)
      (harness-mcp--close conn (or reason "it was stopped") nil t))
    (length conns)))

(defun harness-mcp--scope-of-session-p (scope session-id)
  "Non-nil when SCOPE, a connection's, belongs to SESSION-ID.
It is the session's own scope, or a key `(SESSION-ID . REST)' that a
call with a sandbox of its own took (see `harness-mcp-call-tool')."
  (or (equal scope session-id)
      (and (consp scope) (equal (car scope) session-id))))

(defun harness-mcp--on-session-deleted (session-id &rest _)
  "Stop what runs for SESSION-ID, which is gone, and drop its waiting calls."
  (let (keys)
    (maphash (lambda (key _)
               (when (harness-mcp--scope-of-session-p (cdr key) session-id) (push key keys)))
             harness-mcp--queues)
    (dolist (key keys) (harness-mcp--fail-queue key "The session was deleted")))
  (let (conns)
    (maphash (lambda (key conn)
               (when (harness-mcp--scope-of-session-p (cdr key) session-id) (push conn conns)))
             harness-mcp--conns)
    (dolist (conn conns)
      (harness-mcp--close conn "the session was deleted" nil t))))

(defun harness-mcp--stop-idle ()
  "Stop the servers whose processes have been idle too long."
  (let ((now (float-time)) idle)
    (maphash (lambda (_ conn)
               (let* ((decl (gethash (harness-mcp--conn-server conn) harness-mcp--servers))
                      (limit (or (plist-get decl :idle) harness-mcp-idle-seconds)))
                 (when (and (harness-mcp--conn-proc conn)
                            (eq (harness-mcp--conn-state conn) 'ready)
                            (zerop (harness-mcp--inflight conn))
                            (null (gethash (harness-mcp--conn-key conn) harness-mcp--queues))
                            (> (- now (harness-mcp--conn-last-used conn)) limit))
                   (push conn idle))))
             harness-mcp--conns)
    (dolist (conn idle)
      (harness-mcp--close conn "it was idle"))))

;;;; Status

(defun harness-mcp-status ()
  "Describe the servers that run: a list of plists, one per connection.
Each has `:server', `:scope' (the session, or t), `:state', `:pid' (nil
for an attached transport), `:sandboxed', `:started', `:last-used',
`:inflight', `:waiting' (calls queued for it) and `:info' (what the
server said it is)."
  (let (rows)
    (maphash (lambda (key conn)
               (push (list :server (car key) :scope (cdr key)
                           :state (harness-mcp--conn-state conn)
                           :pid (and (harness-mcp--conn-proc conn) (process-id (harness-mcp--conn-proc conn)))
                           :sandboxed (and (harness-mcp--conn-confined conn) t)
                           :started (harness-mcp--conn-started conn)
                           :last-used (harness-mcp--conn-last-used conn)
                           :inflight (harness-mcp--inflight conn)
                           :waiting (length (gethash key harness-mcp--queues))
                           :info (harness-mcp--conn-info conn))
                     rows))
             harness-mcp--conns)
    (sort rows (lambda (a b) (< (plist-get a :started) (plist-get b :started))))))

(harness-defmethod mcp/servers ()
  "Return the MCP servers that run, as `harness-mcp-status' describes them.
Not callable over ACP."
  (harness-mcp-status))

(harness-defmethod mcp/stop (&optional server scope)
  "Stop the MCP server processes of SERVER (default every one) for SCOPE.
Return how many stopped.  Not callable over ACP."
  (harness-mcp-stop (and server (if (symbolp server) server (intern server))) scope))

;;;; Module

(defun harness-mcp--shutdown ()
  "Stop every server, and the timer that stops the idle ones."
  (when harness-mcp--idle-timer (cancel-timer harness-mcp--idle-timer))
  (setq harness-mcp--idle-timer nil)
  (harness-mcp-stop nil nil "the harness is shutting down"))

(defun harness-mcp--init ()
  "Watch for the sessions that end and the servers that idle."
  (harness-on 'session/deleted #'harness-mcp--on-session-deleted 85)
  (when harness-mcp--idle-timer (cancel-timer harness-mcp--idle-timer))
  (setq harness-mcp--idle-timer
        (run-at-time harness-mcp--idle-check harness-mcp--idle-check #'harness-mcp--stop-idle))
  (add-hook 'kill-emacs-hook #'harness-mcp--shutdown))

(harness-define-module 'mcp
  :doc "MCP host: starts tool servers in the session's sandbox and calls them."
  :requires '(config)
  :init #'harness-mcp--init
  :shutdown #'harness-mcp--shutdown)

(provide 'harness-mcp)
;;; harness-mcp.el ends here
