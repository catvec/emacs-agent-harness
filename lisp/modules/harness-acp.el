;;; harness-acp.el --- Agent Client Protocol server and client  -*- lexical-binding: t; -*-

;;; Commentary:

;; The only way a UI talks to the harness.  This file is both halves of
;; the Agent Client Protocol (ACP, JSON-RPC 2.0, one message per line):
;;
;; - The server side turns bus methods into ACP methods and bus events
;;   into `session/update' notifications.  Standard ACP methods
;;   (`initialize', `session/new', `session/prompt', ...) are mapped by
;;   hand; every other bus method under an allowed prefix is callable
;;   as `_harness/NAME' with its arguments passed by name.
;;
;; - The client side (`harness-acp-connect', `harness-acp-request',
;;   `harness-acp-notify', `harness-acp-set-handler') is what every UI
;;   module codes against.  A local connection dispatches Lisp objects
;;   straight into the server without JSON; a TCP connection speaks the
;;   wire protocol to a harness running elsewhere.  Both deliver the
;;   same shapes: everything a client receives is wire-normalised
;;   (symbols become strings), so a UI is written once.
;;
;; Nothing here blocks: transports use process filters, results are
;; promises, and every callback into a client runs from the command
;; loop through `harness-run-soon', never inside the caller's frame.
;;
;; The module has no requirements.  The server dispatches to whatever
;; bus methods exist, so it loads and the client API works even when
;; the session or agent modules are absent.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-state-directory)

(defvar harness-version)

;;;; Customisation

(defcustom harness-acp-port 0
  "TCP port of the ACP server.  0 picks an ephemeral port."
  :type 'integer :group 'harness)

(defcustom harness-acp-host "127.0.0.1"
  "Address the ACP server binds by default."
  :type 'string :group 'harness)

(defcustom harness-acp-allow-remote nil
  "When non-nil the ACP server may bind a non-loopback address.
Set `harness-acp-token' as well, or anybody who can reach the port
controls your sessions."
  :type 'boolean :group 'harness)

(defcustom harness-acp-token nil
  "Shared secret for TCP clients, or nil for no authentication.
When set, a TCP client must call `authenticate' with {\"token\": …}
before any other method (except `initialize'); a TCP client made with
`harness-acp-connect' authenticates automatically with this value.
Local in-process connections never need it."
  :type '(choice (const :tag "None" nil) string) :group 'harness)

(defvar harness-acp--server-enabled t
  "Start the TCP server when the module initialises.")

(defconst harness-acp--session-debounce 0.05
  "Seconds of quiet before a changed session is pushed as `_harness/session'.")

;;;; Constants

(defconst harness-acp-protocol-version 1 "ACP protocol version spoken here.")

(defconst harness-acp-error-parse -32700)
(defconst harness-acp-error-invalid-request -32600)
(defconst harness-acp-error-method-not-found -32601)
(defconst harness-acp-error-invalid-params -32602)
(defconst harness-acp-error-method -32603
  "A method failed: JSON-RPC's internal error, which ACP leaves to agents.")
(defconst harness-acp-error-unauthenticated -32000
  "ACP's `auth_required': the client must call `authenticate' first.
Clients answer it by offering the `authMethods' of `initialize', so it
is never used for any other failure.")
(defconst harness-acp-error-transport -32003)

(define-error 'acp-error "ACP error" 'harness-error)
(define-error 'harness-acp-invalid-params "Invalid ACP parameters" 'harness-error)

(defconst harness-acp-extension-prefixes
  '("session/" "agent/" "provider/" "tools/list" "usage/" "fallback/" "worktree/" "merge/"
    "config/" "skills/" "permission/" "compaction/" "handoff/" "naming/" "sandbox/status"
    "harness/api" "harness/version" "harness/reload" "harness-dev/" "question/" "project/" "task/"
    "notification/" "acp/remote-" "pet/" "version/" "insights/")
  "Bus method name prefixes callable as `_harness/NAME'.")

(defconst harness-acp--enum-keys
  '(:status :kind :permission-mode :behavior :scope :group-by :period :days :tier)
  "Keys whose string values are interned back to symbols on the way in.")

(defconst harness-acp--modes
  '((ask "Ask" "Reads inside the project are allowed; everything else asks.")
    (accept-edits "Accept edits" "Reads and writes inside the project are allowed; commands and network ask.")
    (auto "Auto" "A cheap model judges each call; falls back to asking.")
    (yolo "YOLO" "Everything inside the project is allowed; outside still asks."))
  "Permission modes as ACP session modes: (ID NAME DESCRIPTION).")

(defconst harness-acp--permission-options
  '((:optionId "allow-once" :name "Allow" :kind "allow_once")
    (:optionId "allow-session" :name "Allow for this session" :kind "allow_always")
    (:optionId "allow-always" :name "Always allow" :kind "allow_always")
    (:optionId "deny-once" :name "Deny" :kind "reject_once")
    (:optionId "deny-always" :name "Always deny" :kind "reject_always"))
  "Options offered with a `session/request_permission' for a tool call.")

(defconst harness-acp--dir-permission-options
  '((:optionId "allow-once" :name "Allow once" :kind "allow_once")
    (:optionId "allow-session" :name "Allow directory for this session" :kind "allow_always")
    (:optionId "allow-always" :name "Always allow directory" :kind "allow_always")
    (:optionId "deny-once" :name "Deny" :kind "reject_once")
    (:optionId "deny-always" :name "Always deny directory" :kind "reject_always"))
  "Options offered when a tool call reaches outside the allowed directories.
A client that shows the request's `_harness.pattern' can answer for
another pattern; the names speak of the directory, the default.")

(defconst harness-acp--forwarded-events
  '(session/created session/deleted session/queue-changed session/pending-changed
    session/status agent/turn-started agent/turn-ended agent/quota
    provider/models-updated provider/quota-updated provider/pricing-warning usage/budget-warning usage/budgets-changed
    usage/reported-changed usage/rate-updated
    fallback/changed fallback/switched
    merge/queued merge/started merge/conflict merge/finished
    worktree/created worktree/removed worktree/locked worktree/unlocked session/forked session/head-moved
    question/answered task/changed task/deleted task/review task/done permission/dir-allowed permission/dir-revoked
    config/changed harness/reloaded tools/file-written acp/remote-changed pet/changed pet/said version/checked)
  "Bus events forwarded verbatim as `_harness/event' notifications.")

(defvar harness-acp-authorize-functions nil
  "Functions deciding that a client may call methods without authenticating.
Each is called with the `harness-acp-client'; the first non-nil answer
lets it in.  The remote access module lets paired devices in this way.")

(defvar harness-acp-auth-methods-functions nil
  "Functions returning extra auth methods `initialize' advertises to a client.
Each is called with the `harness-acp-client' and returns a list of ACP
`AuthMethod' plists (:id :name :description), listed before the token.")

(defvar harness-acp-authenticate-functions nil
  "Functions answering `authenticate' for the auth methods they advertise.
Each is called with the client, the method id and the request params,
and returns nil when the method is not its own, else a value or a
promise: once it resolves the client is authenticated; a rejection
\(an `acp-error' list) is the answer the client gets.")

;;;; Structures

(cl-defstruct (harness-acp-connection (:constructor harness-acp--make-connection)
                                      (:copier nil))
  "A client's end of an ACP connection (what a UI holds)."
  kind                               ; local | tcp
  address                            ; nil for local, "host:port" for tcp
  process                            ; tcp socket
  client                             ; server-side peer record (local only)
  handler                            ; (METHOD PARAMS RESPOND)
  (next-id 0)
  (pending (make-hash-table :test 'equal)) ; id -> promise
  (buffer "")                        ; unparsed tail of the last chunk
  outbox                             ; lines queued while connecting
  (open t)
  on-close)

(cl-defstruct (harness-acp-client (:constructor harness-acp--make-client)
                                  (:copier nil))
  "The server's record of one connected client."
  kind                               ; local | tcp | another transport's symbol
  process                            ; tcp socket
  connection                         ; the `harness-acp-connection' (local only)
  (buffer "")
  authenticated
  initialized
  capabilities
  (next-id 0)
  (pending (make-hash-table :test 'equal)) ; id -> (lambda (result error))
  ;; Slots added later go last, so clients made before a reload keep working.
  writer                             ; (CLIENT JSON-TEXT) for other transports
  remote                             ; plist of a client on another device, else nil
  active)                            ; `float-time' of its last request or notification

(cl-defstruct (harness-acp-error-value (:constructor harness-acp--make-error-value)
                                       (:copier nil))
  "An error a client hands to a RESPOND function instead of a result."
  code message data)

(defvar harness-acp--server nil "The listening TCP process, or nil.")
(defvar harness-acp--clients nil "Every connected client, TCP and local.")

(defun harness-acp--client-get (client slot)
  "Return SLOT of CLIENT, nil when CLIENT predates the slot.
A reload keeps connected clients, whose records lack the slots added
since they were made."
  (and (> (length client) (cl-struct-slot-offset 'harness-acp-client slot))
       (cl-struct-slot-value 'harness-acp-client slot client)))

(defun harness-acp--client-set (client slot value)
  "Set SLOT of CLIENT to VALUE, unless CLIENT predates the slot."
  (when (> (length client) (cl-struct-slot-offset 'harness-acp-client slot))
    (setf (cl-struct-slot-value 'harness-acp-client slot client) value)))

(defun harness-acp-client-remote-info (client)
  "Return the plist describing CLIENT's device when it is on another one, else nil.
Transports serving other devices set it (see `harness-acp-add-client')."
  (harness-acp--client-get client 'remote))

;;;; Wire shapes

(defun harness-acp--sym (value)
  "Return VALUE as a symbol when it is a string or symbol, else nil."
  (cond ((symbolp value) value)
        ((stringp value) (intern value))
        (t nil)))

(defun harness-acp--version ()
  "Return the harness version string."
  (if (boundp 'harness-version) harness-version "unknown"))

(defun harness-acp--plist-p (obj)
  "Non-nil when OBJ looks like a keyword plist."
  (and (consp obj) (keywordp (car obj))))

(defun harness-acp--normalise (obj)
  "Return OBJ in wire shape: what a TCP client would see after JSON.
Symbols become strings (t, nil and `:false' stay), `:empty' becomes
nil (an empty object parses to nil), vectors become lists, keyword
keys of plists are kept.  The result shares no structure with OBJ."
  (cond
   ((null obj) nil)
   ((eq obj t) t)
   ((eq obj :false) :false)
   ((eq obj :empty) nil)
   ((stringp obj) obj)
   ((numberp obj) obj)
   ((symbolp obj) (symbol-name obj))
   ((harness-acp--plist-p obj)
    (let (out)
      (while (consp obj)
        (push (car obj) out)
        (push (harness-acp--normalise (cadr obj)) out)
        (setq obj (cddr obj)))
      (nreverse out)))
   ((consp obj)
    (let (out)
      (while (consp obj)
        (push (harness-acp--normalise (car obj)) out)
        (setq obj (cdr obj)))
      (when obj (push (harness-acp--normalise obj) out))
      (nreverse out)))
   ((vectorp obj) (mapcar #'harness-acp--normalise (append obj nil)))
   ((hash-table-p obj)
    (let (out)
      (maphash (lambda (k v)
                 (push (if (keywordp k) k (intern (format ":%s" k))) out)
                 (push (harness-acp--normalise v) out))
               obj)
      (nreverse out)))
   (t (format "%s" obj))))

(defun harness-acp--intern-enums (obj)
  "Return OBJ with string values under `harness-acp--enum-keys' interned.
Walks nested plists and lists."
  (cond
   ((harness-acp--plist-p obj)
    (let (out)
      (while (consp obj)
        (let ((k (car obj)) (v (cadr obj)))
          (push k out)
          (push (if (and (memq k harness-acp--enum-keys) (stringp v))
                    (intern v)
                  (harness-acp--intern-enums v))
                out))
        (setq obj (cddr obj)))
      (nreverse out)))
   ((consp obj) (mapcar #'harness-acp--intern-enums obj))
   (t obj)))

(defun harness-acp--kebab-key (key)
  "Return keyword KEY with camelCase turned into kebab-case.
For example :sessionId becomes :session-id."
  (let ((name (symbol-name key))
        (case-fold-search nil))
    (if (string-match-p "[A-Z]" name)
        (intern (downcase (replace-regexp-in-string "\\([a-z0-9]\\)\\([A-Z]\\)" "\\1-\\2" name t)))
      key)))

(defun harness-acp--kebab-keys (plist)
  "Return PLIST with its top-level keys passed through `harness-acp--kebab-key'."
  (let (out)
    (while (consp plist)
      (push (if (keywordp (car plist)) (harness-acp--kebab-key (car plist)) (car plist)) out)
      (push (cadr plist) out)
      (setq plist (cddr plist)))
    (nreverse out)))

(defun harness-acp--param (params key &optional required)
  "Return KEY from PARAMS; signal invalid params when REQUIRED and missing."
  (let ((v (plist-get params key)))
    (when (and required (or (null v) (equal v "")))
      (signal 'harness-acp-invalid-params (list (format "%s is required" (substring (symbol-name key) 1)))))
    v))

(defun harness-acp--acp-tool-kind (kind)
  "Map a harness tool KIND (read write exec net meta) to an ACP tool kind."
  (pcase (harness-acp--sym kind)
    ('read "read") ('write "edit") ('exec "execute") ('net "fetch") (_ "other")))

(defun harness-acp--tool-kind-of (tool-name)
  "Return the ACP tool kind of TOOL-NAME, looked up through `tools/get'."
  (harness-acp--acp-tool-kind
   (and tool-name (harness-method-exists-p 'tools/get)
        (plist-get (ignore-errors (harness-call 'tools/get tool-name)) :kind))))

(defun harness-acp--error-triplet (err)
  "Return (CODE MESSAGE DATA) for ERR, an error object or rejection value."
  (pcase err
    (`(acp-error ,code ,message . ,rest) (list code message (car rest)))
    (`(harness-no-such-method . ,_)
     (list harness-acp-error-method-not-found (format "Method not found: %s" (harness-error-message err)) nil))
    (`(harness-acp-invalid-params ,detail . ,_)
     (list harness-acp-error-invalid-params (format "Invalid params: %s" detail) nil))
    (`(wrong-number-of-arguments . ,_)
     (list harness-acp-error-invalid-params (format "Invalid params: %s" (harness-error-message err)) nil))
    (_ (list harness-acp-error-method (harness-error-message err)
             (and (consp err) (symbolp (car err)) (list :type (symbol-name (car err))))))))

(defun harness-acp--message (id &optional result error)
  "Build a JSON-RPC response plist for ID with RESULT or ERROR (CODE MESSAGE DATA)."
  (if error
      (list :jsonrpc "2.0" :id id
            :error (list :code (nth 0 error) :message (nth 1 error) :data (nth 2 error)))
    (list :jsonrpc "2.0" :id id :result result)))

;;;; Line framing

(defun harness-acp--split-lines (buffer chunk)
  "Append CHUNK to BUFFER; return (LINES . REST) where REST has no newline."
  (let* ((text (concat buffer chunk))
         (lines nil)
         (start 0)
         nl)
    (while (setq nl (string-search "\n" text start))
      (let ((line (string-trim-right (substring text start nl) "\r")))
        (unless (string-empty-p (string-trim line)) (push line lines)))
      (setq start (1+ nl)))
    (cons (nreverse lines) (substring text start))))

(defun harness-acp--parse (line)
  "Parse LINE as a JSON-RPC message plist, or return nil on failure."
  (condition-case nil
      (let ((msg (harness-json-parse line)))
        (and (harness-acp--plist-p msg) msg))
    (error nil)))

;;;; Server: sending to clients

(defun harness-acp--client-send (client msg)
  "Deliver MSG (a JSON-RPC plist) to CLIENT."
  (pcase (harness-acp-client-kind client)
    ('local
     (let ((conn (harness-acp-client-connection client)))
       (when (and conn (harness-acp-connection-open conn))
         (harness-run-soon #'harness-acp--conn-receive conn (harness-acp--normalise msg)))))
    ('tcp
     (let ((proc (harness-acp-client-process client)))
       (when (process-live-p proc)
         (condition-case err
             (process-send-string proc (concat (harness-json-encode msg) "\n"))
           (error
            (harness-log 'warn "acp: send to %s failed: %s" (process-name proc) (harness-error-message err))
            (harness-acp--drop-client client))))))
    (kind
     (let ((writer (harness-acp--client-get client 'writer)))
       (when (and writer (memq client harness-acp--clients))
         (condition-case err
             (funcall writer client (harness-json-encode msg))
           (error
            (harness-log 'warn "acp: send to a %s client failed: %s" kind (harness-error-message err))
            (harness-acp--drop-client client))))))))

(defun harness-acp--client-notify (client method params)
  "Send notification METHOD with PARAMS to CLIENT."
  (harness-acp--client-send client (list :jsonrpc "2.0" :method method :params params)))

(defun harness-acp--client-request (client method params callback)
  "Send request METHOD with PARAMS to CLIENT; CALLBACK gets (RESULT ERROR)."
  (let ((id (cl-incf (harness-acp-client-next-id client))))
    (puthash id callback (harness-acp-client-pending client))
    (harness-acp--client-send client (list :jsonrpc "2.0" :id id :method method :params params))))

(defun harness-acp--broadcast (method params)
  "Send notification METHOD with PARAMS to every connected client."
  (dolist (client harness-acp--clients)
    (harness-acp--client-notify client method params)))

(defun harness-acp--broadcast-update (sid update)
  "Send `session/update' UPDATE for session SID to every client."
  (when harness-acp--clients
    (harness-acp--broadcast "session/update" (list :sessionId sid :update update))))

(defun harness-acp--request-clients (method params on-answer)
  "Send request METHOD PARAMS to all clients; ON-ANSWER gets the first result.
Later answers and error responses are ignored.  Without a client the
request is logged and stays pending on the session."
  (if (null harness-acp--clients)
      (harness-log 'warn "acp: %s (%s) but no client is connected; it stays pending"
                   method (plist-get params :sessionId))
    (let ((answered nil))
      (dolist (client harness-acp--clients)
        (harness-acp--client-request
         client method params
         (lambda (result error)
           (unless answered
             (if error
                 (harness-log 'debug "acp: %s declined by a client: %S" method error)
               (setq answered t)
               (condition-case err
                   (funcall on-answer result)
                 (error (harness-log 'error "acp: handling the answer to %s failed: %S" method err)))))))))))

(harness-defmethod client/request (method params)
  "Send request METHOD with PARAMS to the connected clients (the UI).
Return a promise of the first successful answer.  It rejects at once
when no client is connected and when every client declines.  It is for
chores any client may do, such as showing a desktop notification; a
tool never asks a client to do its work (see `emacs/request').  Not
callable over ACP."
  (harness-with-promise (resolve reject)
    (let ((clients (copy-sequence harness-acp--clients)))
      (if (null clients)
          (funcall reject (list 'harness-error (format "%s: no UI client is connected" method)))
        (let ((left (length clients)) (answered nil))
          (dolist (client clients)
            (harness-acp--client-request
             client method params
             (lambda (result error)
               (cl-decf left)
               (unless answered
                 (cond ((null error) (setq answered t) (funcall resolve result))
                       ((zerop left)
                        (funcall reject (list 'harness-error
                                              (format "%s: %s" method
                                                      (or (and (listp error) (plist-get error :message))
                                                          error)))))))))))))))

;;;; Server: an Emacs lent to the harness

;; Every tool runs here, in the harness.  The tools about the user's
;; Emacs (its buffers, its windows, its symbols) reach that Emacs as a
;; resource, the way the file tools reach a TRAMP host; it is never
;; where a tool runs, and no request evaluates code in it.  An Emacs
;; lends itself by advertising `_harness.emacs' among the
;; `clientCapabilities' of `initialize'
;; (lisp/harness-emacs-endpoint.el), the way ACP clients offer an agent
;; their files with `fs'.  A client that lends nothing, such as a phone,
;; is never asked; a harness no Emacs is attached to (headless) runs
;; every other tool as usual.

(defun harness-acp--emacs-info (client)
  "Return the plist CLIENT advertised for the Emacs it lends, or nil."
  (let ((info (plist-get (plist-get (harness-acp-client-capabilities client) :_harness) :emacs)))
    (and (harness-json-true-p info) (if (listp info) info (list :lent t)))))

(defun harness-acp--emacs-clients ()
  "Return the clients that lend an Emacs, the most recently active first.
Only clients that may call methods count: one that lent an Emacs but
never authenticated would otherwise be asked for the user's buffers, or
answer for the user's Emacs with what it likes."
  ;; A copy: `cl-remove-if-not' may return the list itself, and `sort'
  ;; reorders the list it is given.
  (sort (copy-sequence
         (cl-remove-if-not (lambda (client)
                             (and (harness-acp--emacs-info client)
                                  (not (harness-acp--auth-needed-p client))))
                           harness-acp--clients))
        (lambda (a b) (> (or (harness-acp--client-get a 'active) 0)
                         (or (harness-acp--client-get b 'active) 0)))))

(harness-defmethod emacs/attached ()
  "Return the Emacsen lent to the harness, the one `emacs/request' asks first.
Each is the plist its client advertised (`:version', `:pid', `:host')
plus `:transport' (local, tcp, ...), `:remote' (non-nil for a client on
another device) and `:active', when it last asked the harness anything.
Empty when the harness runs headless, or none of its clients is an Emacs."
  (mapcar (lambda (client)
            (append (harness-plist-remove (harness-acp--emacs-info client) :transport :remote :active)
                    (list :transport (harness-acp-client-kind client)
                          :remote (and (harness-acp-client-remote-info client) t)
                          :active (harness-acp--client-get client 'active))))
          (harness-acp--emacs-clients)))

(harness-defmethod emacs/request (method params)
  "Send `_harness/emacs/METHOD' with PARAMS to the Emacs lent to the harness.
Return a promise of its answer.  Exactly one Emacs is asked, never every
client: the most recently active of those that lend one, which is where
the user is.  The promise rejects at once when none is attached, with
the Emacs's message when it refuses, and when it disconnects first.
The tools of tools-emacs use it; see lisp/harness-emacs-endpoint.el for
the methods.  Not callable over ACP."
  (harness-with-promise (resolve reject)
    (let ((client (car (harness-acp--emacs-clients))))
      (if (null client)
          (funcall reject (list 'harness-error
                                "no Emacs is attached to the harness: it runs headless, or none of its clients is an Emacs"))
        (harness-acp--client-request
         client (concat "_harness/emacs/" method) params
         (lambda (result error)
           (cond
            ((null error) (funcall resolve result))
            ((and (listp error) (eql (plist-get error :code) harness-acp-error-transport))
             (funcall reject (list 'harness-error "the user's Emacs disconnected before it answered")))
            (t (funcall reject (list 'harness-error
                                     (format "%s" (or (and (listp error) (plist-get error :message))
                                                      error))))))))))))

(defun harness-acp--drop-client (client)
  "Forget CLIENT and fail whatever it still owed."
  (when (memq client harness-acp--clients)
    (setq harness-acp--clients (delq client harness-acp--clients))
    (let ((pending (harness-acp-client-pending client)) cbs)
      (maphash (lambda (_ cb) (push cb cbs)) pending)
      (clrhash pending)
      (dolist (cb cbs)
        (ignore-errors (funcall cb nil (list :code harness-acp-error-transport :message "client disconnected")))))
    (let ((proc (harness-acp-client-process client))
          (conn (harness-acp-client-connection client)))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when conn (harness-acp--conn-shutdown conn "closed by server")))
    (harness-log 'debug "acp: client left (%d connected)" (length harness-acp--clients))))

;;;; Server: receiving from clients

(defun harness-acp--server-receive (client msg)
  "Dispatch MSG, a JSON-RPC plist from CLIENT."
  (let ((method (plist-get msg :method))
        (has-id (plist-member msg :id))
        (id (plist-get msg :id)))
    ;; What a client asks for shows where the user is; its answers to
    ;; the harness's own requests do not (see `harness-acp--emacs-clients').
    (when (stringp method)
      (harness-acp--client-set client 'active (float-time)))
    (cond
     ((and (stringp method) has-id) (harness-acp--handle-request client id method (plist-get msg :params)))
     ((stringp method) (harness-acp--handle-notification client method (plist-get msg :params)))
     (has-id (harness-acp--handle-response client id msg))
     (t (harness-acp--client-send
         client (harness-acp--message nil nil (list harness-acp-error-invalid-request "Invalid request" nil)))))))

(defun harness-acp--handle-request (client id method params)
  "Run METHOD with PARAMS for CLIENT and answer request ID."
  (let ((reply (lambda (result error) (harness-acp--client-send client (harness-acp--message id result error)))))
    (condition-case err
        (harness-then (harness-as-promise (harness-acp--invoke client method params))
                      (lambda (result) (funcall reply result nil))
                      (lambda (e) (funcall reply nil (harness-acp--error-triplet e))))
      (error (funcall reply nil (harness-acp--error-triplet err))))))

(defun harness-acp--handle-notification (client method params)
  "Run METHOD with PARAMS for CLIENT; failures are only logged.
Notifications under `$/' are left alone: by the JSON-RPC convention
they belong to the implementation, such as the `$/ping' heartbeats
some mobile clients send to keep their connection open."
  (unless (string-prefix-p "$/" method)
    (condition-case err
        (let ((v (harness-acp--invoke client method params)))
          (when (harness-promise-p v)
            (harness-catch v (lambda (e) (harness-log 'warn "acp: notification %s failed: %S" method e)))))
      (error (harness-log 'warn "acp: notification %s failed: %S" method err)))))

(defun harness-acp--handle-response (client id msg)
  "Route MSG, CLIENT's answer to the request ID, to the waiting callback."
  (let ((cb (gethash id (harness-acp-client-pending client))))
    (if (null cb)
        (harness-log 'debug "acp: response to unknown request %S" id)
      (remhash id (harness-acp-client-pending client))
      (funcall cb (plist-get msg :result) (plist-get msg :error)))))

(defvar harness-acp--standard-methods (make-hash-table :test 'equal)
  "ACP method name -> function (CLIENT PARAMS).")

(defun harness-acp--auth-needed-p (client)
  "Non-nil when CLIENT must authenticate before calling methods.
A client from another device always must, unless a function of
`harness-acp-authorize-functions' lets it in; one from this machine
must when `harness-acp-token' is set."
  (and (not (harness-acp-client-authenticated client))
       (or harness-acp-token (harness-acp-client-remote-info client))
       (not (run-hook-with-args-until-success 'harness-acp-authorize-functions client))))

(defun harness-acp--invoke (client method params)
  "Return the value or promise of calling METHOD with PARAMS for CLIENT."
  (let ((params (harness-acp--intern-enums params))
        (standard (gethash method harness-acp--standard-methods)))
    (cond
     ((and (harness-acp-client-remote-info client) (harness-corporate-p))
      (signal 'acp-error (list harness-acp-error-unauthenticated
                               "Corporate mode is on: this harness serves no other device" nil)))
     ((and (not (member method '("authenticate" "initialize")))
           (harness-acp--auth-needed-p client))
      (signal 'acp-error (list harness-acp-error-unauthenticated
                               "Authentication required: call authenticate first" nil)))
     (standard (funcall standard client params))
     ((string-prefix-p "_harness/" method)
      (harness-acp--call-extension (substring method (length "_harness/")) params))
     (t (signal 'harness-no-such-method (list method))))))

;;;; Extension methods: bus methods by name

(defun harness-acp--extension-allowed-p (name)
  "Non-nil when bus method NAME (a string) may be called over ACP."
  (cl-some (lambda (p) (string-prefix-p p name)) harness-acp-extension-prefixes))

(defun harness-acp--extension-methods ()
  "Return the names of every callable extension method, sorted."
  (cl-remove-if-not #'harness-acp--extension-allowed-p
                    (mapcar (lambda (m) (symbol-name (plist-get m :name))) (harness-methods))))

(defun harness-acp--map-params (fn params)
  "Return the argument list for FN built from the ACP PARAMS object.
Keys of PARAMS are matched to FN's argument names (camelCase is
accepted for kebab-case names); `&rest' receives the remaining keys as
a plist; missing `&optional' arguments become nil.  A missing required
argument or an unknown key signals `harness-acp-invalid-params'.  A
list PARAMS, or {\"args\": [...]}, is taken as positional arguments."
  (let ((arglist (help-function-arglist fn t)))
    (cond
     ((and (consp params) (not (keywordp (car params)))) params)
     ((and (consp params) (equal (harness-plist-keys params) '(:args))
           (listp (plist-get params :args)))
      (plist-get params :args))
     ((not (listp arglist)) (if params (list params) nil))
     (t
      (let ((remaining (harness-acp--kebab-keys params))
            (mode 'required)
            positional rest)
        (dolist (arg arglist)
          (pcase arg
            ('&optional (setq mode 'optional))
            ('&rest (setq mode 'rest))
            (_
             (if (eq mode 'rest)
                 (setq rest remaining remaining nil)
               (let* ((key (intern (concat ":" (downcase (symbol-name arg)))))
                      (cell (plist-member remaining key)))
                 (cond
                  (cell (push (cadr cell) positional)
                        (setq remaining (harness-plist-remove remaining key)))
                  ((eq mode 'required)
                   (signal 'harness-acp-invalid-params
                           (list (format "missing parameter %s" (substring (symbol-name key) 1)))))
                  (t (push nil positional))))))))
        (when remaining
          (signal 'harness-acp-invalid-params
                  (list (format "unknown parameter(s) %s"
                                (mapconcat (lambda (k) (substring (symbol-name k) 1))
                                           (harness-plist-keys remaining) ", ")))))
        (append (nreverse positional) rest))))))

(defun harness-acp--call-extension (name params)
  "Call bus method NAME (a string) with PARAMS mapped onto its arguments."
  (let ((sym (intern-soft name)))
    (unless (and sym (harness-acp--extension-allowed-p name) (harness-method-exists-p sym))
      (signal 'harness-no-such-method (list name)))
    (let ((m (gethash sym harness--methods)))
      (apply #'harness-call sym (harness-acp--map-params (harness-method-fn m) params)))))

;;;; Standard ACP methods

(defmacro harness-acp--define-standard (name arglist &rest body)
  "Register ACP method NAME (a string) as a function with ARGLIST and BODY.
ARGLIST is (CLIENT PARAMS)."
  (declare (indent 2))
  `(puthash ,name (lambda ,arglist ,@body) harness-acp--standard-methods))

(harness-acp--define-standard "initialize" (client params)
  (setf (harness-acp-client-initialized client) t
        (harness-acp-client-capabilities client) (plist-get params :clientCapabilities))
  (when-let* ((emacs (harness-acp--emacs-info client)))
    (harness-log 'info "acp: a %s client lends its Emacs (pid %s on %s)"
                 (harness-acp-client-kind client) (plist-get emacs :pid) (plist-get emacs :host)))
  (list :protocolVersion harness-acp-protocol-version
        :agentCapabilities (list :loadSession t
                                 :promptCapabilities (list :image t :audio t :embeddedContext t))
        :agentInfo (list :name "emacs-agent-harness" :version (harness-acp--version))
        :authMethods (harness-json-array (harness-acp--auth-methods client))
        :_harness (list :methods (harness-acp--extension-methods)
                        :events (mapcar (lambda (e) (symbol-name (car e))) (harness-events)))))

(defun harness-acp--auth-methods (client)
  "Return the ACP auth methods `initialize' advertises to CLIENT.
Those of `harness-acp-auth-methods-functions' come first, then the
shared secret when `harness-acp-token' is set."
  (append (cl-mapcan (lambda (fn)
                       (condition-case err (copy-sequence (funcall fn client))
                         (error (harness-log 'warn "acp: auth methods from %s failed: %S" fn err) nil)))
                     harness-acp-auth-methods-functions)
          (and harness-acp-token
               (list (list :id "token" :name "Shared secret"
                           :description "Call authenticate with {\"token\": …}")))))

(harness-acp--define-standard "authenticate" (client params)
  (let ((token (plist-get params :token))
        (method (plist-get params :methodId))
        (accept (lambda (_) (setf (harness-acp-client-authenticated client) t) :empty)))
    (cond
     ;; Nothing to prove: a local client while no token is set, or one
     ;; a function of `harness-acp-authorize-functions' lets in.
     ((not (harness-acp--auth-needed-p client)) (funcall accept nil))
     ((and (stringp token) harness-acp-token (string= token harness-acp-token)) (funcall accept nil))
     ((stringp token) (signal 'acp-error (list harness-acp-error-unauthenticated "Invalid token" nil)))
     ((let ((answer (run-hook-with-args-until-success 'harness-acp-authenticate-functions
                                                       client method params)))
        (and answer (harness-then (harness-as-promise answer) accept))))
     (t (signal 'acp-error (list harness-acp-error-unauthenticated
                                 (if (member method '(nil "token"))
                                     "Invalid token"
                                   (format "Unknown authentication method %s" method))
                                 nil))))))

(defun harness-acp--modes-plist (session)
  "Return the ACP modes object for SESSION."
  (list :currentModeId (format "%s" (or (plist-get session :permission-mode) 'ask))
        :availableModes (mapcar (lambda (m) (list :id (symbol-name (nth 0 m)) :name (nth 1 m)
                                                  :description (nth 2 m)))
                                harness-acp--modes)))

(harness-acp--define-standard "session/new" (_client params)
  (let* ((cwd (harness-acp--param params :cwd t))
         (extra (harness-acp--kebab-keys (plist-get params :_harness)))
         (session (apply #'harness-call 'session/create :cwd cwd extra)))
    (when (plist-get params :mcpServers)
      (harness-log 'info "acp: mcpServers ignored for session %s" (plist-get session :id)))
    (list :sessionId (plist-get session :id)
          :modes (harness-acp--modes-plist session))))

(harness-acp--define-standard "session/load" (client params)
  (let* ((sid (harness-acp--param params :sessionId t))
         (session (harness-call 'session/resume sid)))
    (dolist (node (harness-call 'session/nodes sid))
      (dolist (update (harness-acp--node-updates node nil))
        (harness-acp--client-notify client "session/update" (list :sessionId sid :update update))))
    (harness-acp--client-notify client "session/update"
                                (list :sessionId sid
                                      :update (list :sessionUpdate "_harness/session" :session session)))
    :empty))

(defun harness-acp--block-from-acp (block)
  "Turn an ACP prompt content BLOCK into a harness content block."
  (pcase (plist-get block :type)
    ("text" (list :type "text" :text (or (plist-get block :text) "")))
    ("image" (list :type "image" :mime (plist-get block :mimeType) :data (plist-get block :data)))
    ("audio" (list :type "audio" :mime (plist-get block :mimeType) :data (plist-get block :data)))
    ("resource_link"
     (let ((uri (or (plist-get block :uri) "")))
       (list :type "file" :path (string-remove-prefix "file://" uri)
             :size (plist-get block :size) :mime (plist-get block :mimeType)
             :name (plist-get block :name))))
    ("resource"
     (list :type "text" :text (or (plist-get (plist-get block :resource) :text) "")))
    (other (list :type "text" :text (format "[unsupported content block: %s]" other)))))

(defun harness-acp--stop-result (result)
  "Map the agent's turn RESULT (:stop-reason …) to an ACP prompt result."
  (let* ((reason (harness-acp--sym (plist-get result :stop-reason)))
         (stop (pcase reason
                 ((or 'end-turn 'nil) "end_turn")
                 ('cancelled "cancelled")
                 ('max-tokens "max_tokens")
                 (_ "refusal"))))
    (list :stopReason stop
          :_harness (list :reason (and reason (symbol-name reason))
                          :error (plist-get result :error)
                          :duration (plist-get result :duration)))))

(harness-acp--define-standard "session/prompt" (_client params)
  (let ((sid (harness-acp--param params :sessionId t))
        (blocks (mapcar #'harness-acp--block-from-acp (plist-get params :prompt))))
    (unless (harness-method-exists-p 'agent/prompt)
      (signal 'harness-no-such-method (list 'agent/prompt)))
    (harness-then (harness-call-async 'agent/prompt sid blocks) #'harness-acp--stop-result)))

(harness-acp--define-standard "session/cancel" (_client params)
  (let ((sid (harness-acp--param params :sessionId t)))
    (when (harness-method-exists-p 'agent/cancel)
      (harness-call 'agent/cancel sid))
    :empty))

(harness-acp--define-standard "session/set_mode" (_client params)
  (let* ((sid (harness-acp--param params :sessionId t))
         (mode (harness-acp--sym (harness-acp--param params :modeId t))))
    (unless (assq mode harness-acp--modes)
      (signal 'harness-acp-invalid-params (list (format "unknown mode %s" mode))))
    (harness-call 'session/update sid :permission-mode mode)
    :empty))

(harness-acp--define-standard "session/set_model" (_client params)
  (let ((sid (harness-acp--param params :sessionId t))
        (model (harness-acp--param params :modelId t)))
    (harness-call 'session/update sid :model model)
    :empty))

;;;; Bus methods owned by this module

(harness-defmethod harness/api ()
  "Describe the bus (methods, events, filters, modules) in wire shape."
  (harness-acp--normalise (harness-describe-api)))

(harness-defmethod harness/version ()
  "Return the harness and Emacs versions."
  (list :version (harness-acp--version) :emacs emacs-version
        :protocolVersion harness-acp-protocol-version))

;;;; Bus events -> notifications

(defun harness-acp--node-updates (node live)
  "Return the `session/update' objects announcing NODE.
With LIVE non-nil the node was just appended and assistant/thinking
text arrives through `agent/stream', so no chunk is produced for it;
during a replay the full content is sent as one chunk."
  (let* ((kind (harness-acp--sym (plist-get node :kind)))
         (meta (list :nodeId (plist-get node :id)))
         (text (lambda () (list :type "text" :text (or (plist-get node :content) ""))))
         out)
    (pcase kind
      ('user
       ;; A message the user did not write says who sent it, so a client
       ;; that reads chunks alone can tell it from the user's.
       (push (list :sessionUpdate "user_message_chunk" :content (funcall text)
                   :_harness (append meta (and (harness-node-sender node) (list :from (harness-node-sender node)))))
             out))
      ((and (or 'assistant 'thinking) (guard (not live)))
       (push (list :sessionUpdate (if (eq kind 'thinking) "agent_thought_chunk" "agent_message_chunk")
                   :content (funcall text) :_harness meta)
             out))
      ;; A call the harness recorded says who did, as a message does.
      ('tool-call
       (push (list :sessionUpdate "tool_call"
                   :toolCallId (plist-get node :call-id)
                   :title (or (plist-get node :title) (plist-get node :tool))
                   :kind (harness-acp--tool-kind-of (plist-get node :tool))
                   :status "in_progress"
                   :rawInput (plist-get node :input)
                   :_harness (append meta (list :tool (plist-get node :tool))
                                     (and (harness-outside-node-p node) (list :from (harness-node-sender node)))))
             out))
      ('tool-result
       (let ((output (or (plist-get node :output) "")))
         (push (list :sessionUpdate "tool_call_update"
                     :toolCallId (plist-get node :call-id)
                     :status (if (harness-json-true-p (plist-get node :is-error)) "failed" "completed")
                     :content (list (list :type "content" :content (list :type "text" :text output)))
                     :rawOutput output
                     :_harness (append meta (list :attachments (plist-get node :attachments))
                                       (and (harness-outside-node-p node) (list :from (harness-node-sender node)))))
               out))))
    (push (list :sessionUpdate "_harness/node" :node node) out)
    (nreverse out)))

(defun harness-acp--on-stream (sid node-id kind delta)
  "Forward an `agent/stream' delta for SID's node NODE-ID of KIND as DELTA."
  (when harness-acp--clients
    (harness-acp--broadcast-update
     sid (list :sessionUpdate (if (eq (harness-acp--sym kind) 'thinking) "agent_thought_chunk" "agent_message_chunk")
               :content (list :type "text" :text delta)
               :_harness (list :nodeId node-id)))))

(defun harness-acp--on-activity (sid activity)
  "Forward what the running turn of session SID does now, ACTIVITY.
Nil means the turn ended; see `agent/activity' for the shape."
  (when harness-acp--clients
    (harness-acp--broadcast-update sid (list :sessionUpdate "_harness/activity" :activity activity))))

(defun harness-acp--on-node-added (sid node)
  "Announce NODE appended to session SID."
  (when harness-acp--clients
    (dolist (update (harness-acp--node-updates node t))
      (harness-acp--broadcast-update sid update))))

(defun harness-acp--on-node-updated (sid node transient)
  "Announce a finalised change of NODE in session SID unless TRANSIENT."
  (when (and harness-acp--clients (not transient))
    (harness-acp--broadcast-update sid (list :sessionUpdate "_harness/node" :node node))))

(defun harness-acp--send-session (sid session)
  "Push SESSION for SID as a `_harness/session' update."
  (unless (and (harness-method-exists-p 'session/exists-p)
               (not (harness-call 'session/exists-p sid)))
    (harness-acp--broadcast-update sid (list :sessionUpdate "_harness/session" :session session))))

(defun harness-acp--on-session-changed (sid session)
  "Debounce `session/changed' for SID and push SESSION when it settles."
  (when harness-acp--clients
    (harness-debounce (concat "acp-session-" sid) harness-acp--session-debounce
                      #'harness-acp--send-session sid session)))

(defun harness-acp--on-session-updated (sid changes)
  "Announce a permission mode change in CHANGES of session SID."
  (when (and harness-acp--clients (plist-member changes :permission-mode))
    (harness-acp--broadcast-update
     sid (list :sessionUpdate "current_mode_update"
               :currentModeId (format "%s" (plist-get changes :permission-mode))))))

(defun harness-acp--on-todos (sid todos)
  "Announce TODOS of session SID as an ACP plan."
  (when harness-acp--clients
    (harness-acp--broadcast-update
     sid (list :sessionUpdate "plan"
               :entries (mapcar (lambda (todo)
                                  (list :content (or (plist-get todo :text) (plist-get todo :content) "")
                                        :status (pcase (harness-acp--sym (plist-get todo :status))
                                                  ((or 'in-progress 'in_progress) "in_progress")
                                                  ((or 'done 'completed) "completed")
                                                  (_ "pending"))
                                        :priority "medium"))
                                todos)))))

(defun harness-acp--on-session-deleted (sid _session)
  "Announce that session SID is gone."
  (when harness-acp--clients
    (harness-acp--broadcast-update sid (list :sessionUpdate "_harness/session_deleted"))))

(defun harness-acp--on-any-event (event args)
  "Forward EVENT with ARGS as `_harness/event' when it is in the forwarded set."
  (when (and harness-acp--clients (memq event harness-acp--forwarded-events))
    (harness-acp--broadcast "_harness/event" (list :event (symbol-name event) :args (harness-json-array args)))))

;;;; Bus events -> requests to the client

(defun harness-acp--call-safely (method &rest args)
  "Call bus METHOD with ARGS, logging instead of signalling."
  (if (harness-method-exists-p method)
      (condition-case err
          (apply #'harness-call method args)
        (error (harness-log 'warn "acp: %s failed: %S" method err)))
    (harness-log 'warn "acp: no %s method to deliver the answer to" method)))

(defun harness-acp--option-answer (option &optional pattern)
  "Turn a permission OPTION id like \"allow-session\" into an answer plist.
PATTERN, a string, is the pattern the client answered for, when it
edited the request's."
  (let* ((parts (split-string (format "%s" (or option "deny-once")) "-"))
         (behavior (if (equal (car parts) "allow") 'allow 'deny))
         (scope (intern (or (cadr parts) "once"))))
    (append (list :behavior behavior :scope (if (memq scope '(once session always)) scope 'once))
            (and (stringp pattern) (not (string-blank-p pattern)) (list :pattern pattern)))))

(defun harness-acp--offered-options (payload)
  "Return the ACP options for a permission request with PAYLOAD.
A directory prompt is worded for directories; when PAYLOAD lists its
`:options' (ids such as `allow-session'), only those are offered, so
an agent's own directory request has no \"Allow once\"."
  (let* ((all (if (plist-get payload :dir) harness-acp--dir-permission-options
                harness-acp--permission-options))
         (ids (mapcar (lambda (o) (format "%s" o)) (append (plist-get payload :options) nil))))
    (or (and ids (cl-remove-if-not (lambda (o) (member (plist-get o :optionId) ids)) all))
        all)))

(defun harness-acp--on-permission-requested (sid pending)
  "Ask the connected clients to decide PENDING permission request of SID.
A request about a path outside the allowed directories carries the glob
pattern it is answered for in `_harness.pattern'; a client may answer
for another one with `_harness.pattern' in its result, next to the
outcome.  A shell command's request carries where it runs in
`_harness.cwd', and in `_harness.paths' what it is about."
  (let* ((payload (or (plist-get pending :payload) pending))
         (pid (plist-get pending :id)))
    (harness-acp--request-clients
     "session/request_permission"
     (list :sessionId sid
           :toolCall (list :toolCallId (or (plist-get payload :call-id) pid)
                           :title (or (plist-get payload :title) (plist-get payload :tool) "tool call")
                           :kind (harness-acp--acp-tool-kind (plist-get payload :kind))
                           :rawInput (plist-get payload :input))
           :options (harness-acp--offered-options payload)
           :_harness (list :pendingId pid
                           :tool (plist-get payload :tool)
                           :paths (plist-get payload :paths)
                           :cwd (plist-get payload :cwd)
                           :dir (plist-get payload :dir)
                           :pattern (plist-get payload :pattern)
                           :reason (plist-get payload :reason)))
     (lambda (result)
       (let* ((outcome (plist-get result :outcome))
              (selected (equal (format "%s" (plist-get outcome :outcome)) "selected"))
              (answer (if selected
                          (harness-acp--option-answer (plist-get outcome :optionId)
                                                      (plist-get (plist-get result :_harness) :pattern))
                        (list :behavior 'deny :scope 'once))))
         (harness-acp--call-safely 'permission/answer sid pid answer))))))

(defun harness-acp--on-question-asked (sid pending)
  "Ask the connected clients to answer PENDING question of session SID.
`diagrams', when the options have them, holds one per option:
{type: \"ascii\", text} or {type: \"image\", path, mime}."
  (let* ((payload (or (plist-get pending :payload) pending))
         (pid (plist-get pending :id)))
    (harness-acp--request-clients
     "_harness/ask_user"
     (append (list :sessionId sid :requestId pid
                   :question (plist-get payload :question)
                   :options (plist-get payload :options))
             (and (plist-get payload :diagrams) (list :diagrams (plist-get payload :diagrams))))
     (lambda (result)
       (harness-acp--call-safely 'question/answer sid pid (plist-get result :answer))))))

(defun harness-acp--subscribe ()
  "Subscribe the named event handlers; safe to call repeatedly."
  (harness-on 'agent/stream #'harness-acp--on-stream)
  (harness-on 'agent/activity-changed #'harness-acp--on-activity)
  (harness-on 'session/node-added #'harness-acp--on-node-added)
  (harness-on 'session/node-updated #'harness-acp--on-node-updated)
  (harness-on 'session/changed #'harness-acp--on-session-changed)
  (harness-on 'session/updated #'harness-acp--on-session-updated)
  (harness-on 'session/todos #'harness-acp--on-todos)
  (harness-on 'session/deleted #'harness-acp--on-session-deleted)
  (harness-on 'permission/requested #'harness-acp--on-permission-requested)
  (harness-on 'question/asked #'harness-acp--on-question-asked)
  (harness-on '* #'harness-acp--on-any-event))

;;;; TCP server

(defun harness-acp--loopback-p (host)
  "Non-nil when HOST names the local machine only."
  (or (member host '("127.0.0.1" "localhost" "::1" "local" "loopback"))
      (string-prefix-p "127." host)))

(defun harness-acp--client-for (proc)
  "Return the client record of socket PROC, creating one when needed."
  (or (process-get proc 'harness-acp-client)
      (let ((client (harness-acp--make-client :kind 'tcp :process proc)))
        (process-put proc 'harness-acp-client client)
        (push client harness-acp--clients)
        client)))

(defun harness-acp--server-log (_server proc _message)
  "Register the newly accepted connection PROC."
  (set-process-query-on-exit-flag proc nil)
  (set-process-coding-system proc 'utf-8-unix 'utf-8-unix)
  (set-process-filter proc #'harness-acp--server-filter)
  (set-process-sentinel proc #'harness-acp--server-sentinel)
  (harness-acp--client-for proc)
  (harness-log 'debug "acp: client connected (%d connected)" (length harness-acp--clients)))

(defun harness-acp--server-filter (proc chunk)
  "Buffer CHUNK from client socket PROC and dispatch complete lines."
  (let* ((client (harness-acp--client-for proc))
         (split (harness-acp--split-lines (harness-acp-client-buffer client) chunk)))
    (setf (harness-acp-client-buffer client) (cdr split))
    (dolist (line (car split))
      (let ((msg (harness-acp--parse line)))
        (if msg
            (harness-run-soon #'harness-acp--server-receive client msg)
          (harness-acp--client-send
           client (harness-acp--message nil nil (list harness-acp-error-parse "Parse error" nil))))))))

(defun harness-acp--server-sentinel (proc event)
  "Clean up after PROC when EVENT says a socket closed."
  (cond
   ((eq proc harness-acp--server)
    (unless (process-live-p proc)
      (harness-log 'info "acp: server stopped (%s)" (string-trim event))
      (setq harness-acp--server nil)))
   ((not (process-live-p proc))
    (let ((client (process-get proc 'harness-acp-client)))
      (when client (harness-acp--drop-client client))))))

;;;; Other transports

;; A module serving ACP over another transport (WebSocket, say) hands
;; each connection to the server with these: it registers a client,
;; passes every JSON-RPC message the client sends to
;; `harness-acp-client-receive', and the server writes back through the
;; client's WRITER.

(cl-defun harness-acp-add-client (kind &key process writer remote)
  "Register and return a client that reached the server through another transport.
KIND names the transport (a symbol other than `local' and `tcp').
WRITER is called with (CLIENT JSON-TEXT) for every message to the
client.  PROCESS is its socket, deleted when the client is dropped.
REMOTE, a plist such as (:address \"192.168.1.23\"), marks a client on
another device: it must authenticate whatever `harness-acp-token' says,
unless `harness-acp-authorize-functions' let it in, and corporate mode
refuses it."
  (let ((client (harness-acp--make-client :kind kind :process process
                                          :writer writer :remote remote)))
    (push client harness-acp--clients)
    (harness-log 'debug "acp: %s client connected (%d connected)" kind (length harness-acp--clients))
    client))

(defun harness-acp-client-receive (client text)
  "Dispatch TEXT, one JSON-RPC message CLIENT sent, from the command loop.
Text that does not parse is answered with a parse error."
  (let ((msg (harness-acp--parse text)))
    (if msg
        (harness-run-soon #'harness-acp--server-receive client msg)
      (harness-acp--client-send
       client (harness-acp--message nil nil (list harness-acp-error-parse "Parse error" nil))))))

(defun harness-acp-drop-client (client)
  "Disconnect CLIENT and fail whatever it still owed."
  (harness-acp--drop-client client))

(defun harness-acp--server-contact ()
  "Return (:host :port) of the running server, or nil."
  (when (and harness-acp--server (process-live-p harness-acp--server))
    (list :host (process-contact harness-acp--server :host)
          :port (process-contact harness-acp--server :service))))

(defun harness-acp-server-address ()
  "Return \"host:port\" of the running ACP server, or nil."
  (let ((c (harness-acp--server-contact)))
    (and c (format "%s:%s" (plist-get c :host) (plist-get c :port)))))

(harness-defmethod acp/start (&rest opts)
  "Start the ACP TCP server; OPTS `:host' and `:port' override the defaults.
Return (:host :port).  Already running: return the current address."
  (or (harness-acp--server-contact)
      (let ((host (or (plist-get opts :host) harness-acp-host))
            (port (or (plist-get opts :port) harness-acp-port)))
        (unless (harness-acp--loopback-p host)
          (cond
           ((harness-corporate-p)
            (signal 'harness-error
                    (list (format "acp: refusing to bind %s: corporate mode is on, so ACP is served on this machine only" host))))
           ((not harness-acp-allow-remote)
            (signal 'harness-error
                    (list (format "acp: refusing to bind %s; set `harness-acp-allow-remote' (and a token) first" host))))))
        (setq harness-acp--server
              (make-network-process :name "harness-acp-server" :server t
                                    :host host :service port
                                    :coding 'utf-8-unix :noquery t
                                    :filter #'harness-acp--server-filter
                                    :sentinel #'harness-acp--server-sentinel
                                    :log #'harness-acp--server-log))
        (harness-log 'info "acp: listening on %s" (harness-acp-server-address))
        (harness-acp--write-address-file (harness-acp-server-address))
        (harness-acp--server-contact))))

(defun harness-acp--address-file ()
  "Return the file that advertises the server address to stdio bridges."
  (expand-file-name "acp-address" harness-state-directory))

(defun harness-acp--write-address-file (address)
  "Write ADDRESS (or delete the file when nil) for `scripts/harness-acp-stdio'.
With `harness-acp-token' set, also write it to acp-token, readable only
by the user, so the bridge can authenticate for the editor it serves."
  (condition-case err
      (let ((file (harness-acp--address-file))
            (token-file (expand-file-name "acp-token" harness-state-directory)))
        (if address
            (progn
              (harness-write-file-atomically file (concat address "\n"))
              (when harness-acp-token
                (with-file-modes #o600
                  (harness-write-file-atomically token-file (concat harness-acp-token "\n")))))
          (when (file-exists-p file) (delete-file file))
          (when (file-exists-p token-file) (delete-file token-file))))
    (error (harness-log 'warn "acp: cannot write address file: %S" err))))

(harness-defmethod acp/stop ()
  "Stop the ACP TCP server and disconnect its TCP clients."
  (dolist (client (copy-sequence harness-acp--clients))
    (when (eq (harness-acp-client-kind client) 'tcp)
      (harness-acp--drop-client client)))
  (when harness-acp--server
    (let ((proc harness-acp--server))
      (setq harness-acp--server nil)
      (when (process-live-p proc) (delete-process proc))))
  (harness-acp--write-address-file nil)
  t)

(harness-defmethod acp/status ()
  "Return (:running BOOL :host :port :clients N) for the TCP server."
  (let ((c (harness-acp--server-contact)))
    (list :running (if c t :false)
          :host (plist-get c :host) :port (plist-get c :port)
          :clients (length harness-acp--clients)
          :tcp-clients (cl-count 'tcp harness-acp--clients :key #'harness-acp-client-kind))))

;;;; Client API

(defun harness-acp--parse-address (address)
  "Return (HOST . PORT) for ADDRESS, a \"host:port\" string or such a cons."
  (cond
   ((consp address)
    (cons (car address) (if (stringp (cdr address)) (string-to-number (cdr address)) (cdr address))))
   ((and (stringp address) (string-match "\\`\\(.*\\):\\([0-9]+\\)\\'" address))
    (cons (let ((h (match-string 1 address))) (if (string-empty-p h) "127.0.0.1" h))
          (string-to-number (match-string 2 address))))
   (t (signal 'acp-error (list harness-acp-error-transport (format "Bad ACP address %S" address) nil)))))

(defun harness-acp-connect (&optional address)
  "Open an ACP connection and return it.
ADDRESS nil connects in-process to this harness (no JSON, no socket);
\"HOST:PORT\" or (HOST . PORT) connects over TCP to a harness there.
A TCP connection authenticates with `harness-acp-token' when it is set.
Set a handler with `harness-acp-set-handler' to receive notifications
and requests, then call `harness-acp-initialize'."
  (if (null address)
      (let* ((conn (harness-acp--make-connection :kind 'local))
             (client (harness-acp--make-client :kind 'local :connection conn :authenticated t)))
        (setf (harness-acp-connection-client conn) client)
        (push client harness-acp--clients)
        conn)
    (pcase-let ((`(,host . ,_) (harness-acp--parse-address address)))
      (when (and (harness-corporate-p) (not (harness-acp--loopback-p host)))
        (signal 'acp-error (list harness-acp-error-transport
                                 (format "Corporate mode is on: no connection to a harness on %s" host)
                                 nil))))
    (pcase-let* ((`(,host . ,port) (harness-acp--parse-address address))
                 (conn (harness-acp--make-connection :kind 'tcp :address (format "%s:%d" host port)))
                 (proc (make-network-process :name "harness-acp-client"
                                             :host host :service port
                                             :coding 'utf-8-unix :noquery t :nowait t
                                             :filter #'harness-acp--conn-filter
                                             :sentinel #'harness-acp--conn-sentinel)))
      (process-put proc 'harness-acp-connection conn)
      (setf (harness-acp-connection-process conn) proc)
      (when harness-acp-token
        (harness-acp-authenticate conn harness-acp-token))
      conn)))

(defun harness-acp-connected-p (conn)
  "Non-nil while CONN is open and, for TCP, its socket is established."
  (and (harness-acp-connection-p conn)
       (harness-acp-connection-open conn)
       (pcase (harness-acp-connection-kind conn)
         ('local t)
         ('tcp (let ((proc (harness-acp-connection-process conn)))
                 (and proc (process-live-p proc) (eq (process-status proc) 'open)))))))

(defun harness-acp-open-p (conn)
  "Non-nil while CONN can carry messages: connected or, for TCP, connecting.
What is sent while a TCP socket connects waits and goes out once it is
established, so a connection still connecting need not be replaced."
  (and (harness-acp-connection-p conn)
       (harness-acp-connection-open conn)
       (pcase (harness-acp-connection-kind conn)
         ('local t)
         ('tcp (let ((proc (harness-acp-connection-process conn)))
                 (and proc (process-live-p proc)))))))

(defun harness-acp-set-handler (conn fn)
  "Deliver what arrives on CONN to FN, called as (METHOD PARAMS RESPOND).
For a notification RESPOND is nil.  For a request from the agent
RESPOND is a function taking the result plist; answer an error with
`harness-acp-respond-error'.  Requests without a handler are refused.
RESPOND returns non-nil when the answer went out, and nil when it could
not: CONN closed since the request came, as when the UI connects again,
or the request was answered already.  An answer kept for later (a
permission prompt waiting for the user) must then reach the harness
another way, such as the bus method that answers it."
  (setf (harness-acp-connection-handler conn) fn))

(defun harness-acp-on-close (conn fn)
  "Call FN with no arguments once CONN closes, from either side."
  (push fn (harness-acp-connection-on-close conn)))

(defun harness-acp-respond-error (respond code message &optional data)
  "Answer the request behind RESPOND with a JSON-RPC error CODE, MESSAGE and DATA.
Return what RESPOND does: non-nil when the answer went out."
  (funcall respond (harness-acp--make-error-value :code code :message message :data data)))

(defun harness-acp--conn-send (conn msg)
  "Send MSG (a JSON-RPC plist) from CONN to the server."
  (unless (harness-acp-connection-open conn)
    (signal 'acp-error (list harness-acp-error-transport "connection closed" nil)))
  (pcase (harness-acp-connection-kind conn)
    ('local (harness-acp--server-receive (harness-acp-connection-client conn) msg))
    ('tcp
     (let ((proc (harness-acp-connection-process conn))
           (line (concat (harness-json-encode msg) "\n")))
       (cond
        ((not (process-live-p proc))
         (signal 'acp-error (list harness-acp-error-transport "connection closed" nil)))
        ((eq (process-status proc) 'connect)
         (setf (harness-acp-connection-outbox conn)
               (append (harness-acp-connection-outbox conn) (list line))))
        (t (process-send-string proc line)))))))

(defun harness-acp-request (conn method params)
  "Call METHOD with PARAMS over CONN; return a promise of the result plist.
The promise is rejected with (acp-error CODE MESSAGE DATA) on a
JSON-RPC error or when the transport fails."
  (let ((promise (harness-make-promise)))
    (if (not (harness-acp-connection-open conn))
        (harness-reject promise (list 'acp-error harness-acp-error-transport "connection closed" nil))
      (let ((id (cl-incf (harness-acp-connection-next-id conn))))
        (puthash id promise (harness-acp-connection-pending conn))
        (condition-case err
            (harness-acp--conn-send conn (list :jsonrpc "2.0" :id id :method method :params params))
          (error
           (remhash id (harness-acp-connection-pending conn))
           (harness-reject promise (if (eq (car-safe err) 'acp-error) err
                                     (list 'acp-error harness-acp-error-transport
                                           (harness-error-message err) nil)))))))
    promise))

(defun harness-acp-notify (conn method params)
  "Send notification METHOD with PARAMS over CONN; no answer is expected."
  (condition-case err
      (harness-acp--conn-send conn (list :jsonrpc "2.0" :method method :params params))
    (error (harness-log 'warn "acp: notify %s failed: %s" method (harness-error-message err))))
  nil)

(defun harness-acp-initialize (conn &optional client-capabilities)
  "Send `initialize' over CONN with CLIENT-CAPABILITIES.
Return a promise of the initialize result."
  (harness-acp-request conn "initialize"
                       (list :protocolVersion harness-acp-protocol-version
                             :clientCapabilities (or client-capabilities
                                                     (list :fs (list :readTextFile :false :writeTextFile :false)
                                                           :terminal :false)))))

(defun harness-acp-authenticate (conn token)
  "Send `authenticate' with TOKEN over CONN; return a promise."
  (harness-acp-request conn "authenticate" (list :methodId "token" :token token)))

(defun harness-acp-close (conn &optional reason)
  "Close CONN.  Pending requests are rejected and on-close functions run.
REASON, a short string such as \"replaced\" (default \"closed\"), says
why: the rejections carry it (see `harness-acp-closed-reason'), so a
client that let go of CONN on purpose can tell them from failures."
  (when (harness-acp-connection-open conn)
    (let ((kind (harness-acp-connection-kind conn))
          (client (harness-acp-connection-client conn))
          (proc (harness-acp-connection-process conn)))
      ;; Shut down first: deleting the socket runs its sentinel, whose
      ;; reason would otherwise be the one the rejections carry.
      (harness-acp--conn-shutdown conn (or reason "closed"))
      (pcase kind
        ('local (when client (harness-acp--drop-client client)))
        ('tcp (when (and proc (process-live-p proc)) (delete-process proc)))))))

(defun harness-acp-closed-reason (err)
  "Return why the connection closed when that is what rejected ERR, else nil.
ERR is the rejection of a request that was pending as its connection
closed: the REASON of `harness-acp-close', or what the socket reported
when it closed by itself, such as \"connection broken by remote peer\"."
  (and (eq (car-safe err) 'acp-error)
       (eql (nth 1 err) harness-acp-error-transport)
       (plist-get (nth 3 err) :closed)))

(defun harness-acp--conn-shutdown (conn reason)
  "Mark CONN closed for REASON, reject its pending requests and run on-close."
  (when (harness-acp-connection-open conn)
    (setf (harness-acp-connection-open conn) nil)
    (let ((pending (harness-acp-connection-pending conn))
          (message (if (string-prefix-p "connection" reason) reason (format "connection %s" reason)))
          promises)
      (maphash (lambda (_ p) (push p promises)) pending)
      (clrhash pending)
      (dolist (p promises)
        (harness-run-soon #'harness-reject p
                          (list 'acp-error harness-acp-error-transport message (list :closed reason)))))
    (dolist (fn (harness-acp-connection-on-close conn))
      (harness-run-soon (lambda ()
                          (condition-case err (funcall fn)
                            (error (harness-log 'error "acp: on-close hook failed: %S" err))))))))

(defun harness-acp--conn-filter (proc chunk)
  "Buffer CHUNK from the server socket PROC and deliver complete messages."
  (let ((conn (process-get proc 'harness-acp-connection)))
    (when conn
      (let ((split (harness-acp--split-lines (harness-acp-connection-buffer conn) chunk)))
        (setf (harness-acp-connection-buffer conn) (cdr split))
        (dolist (line (car split))
          (let ((msg (harness-acp--parse line)))
            (if msg
                (harness-run-soon #'harness-acp--conn-receive conn msg)
              (harness-log 'warn "acp: unparsable line from server: %s" (harness-truncate-end line 120)))))))))

(defun harness-acp--conn-sentinel (proc event)
  "React to EVENT on the client socket PROC: flush on open, shut down on close."
  (let ((conn (process-get proc 'harness-acp-connection)))
    (when conn
      (cond
       ((eq (process-status proc) 'open)
        (let ((lines (harness-acp-connection-outbox conn)))
          (setf (harness-acp-connection-outbox conn) nil)
          (dolist (line lines)
            (condition-case err (process-send-string proc line)
              (error (harness-log 'warn "acp: flush failed: %s" (harness-error-message err)))))))
       ((not (process-live-p proc))
        (harness-acp--conn-shutdown conn (string-trim event)))))))

(defun harness-acp--conn-receive (conn msg)
  "Handle MSG (already in wire shape) that arrived on CONN."
  (when (harness-acp-connection-open conn)
    (let ((method (plist-get msg :method))
          (has-id (plist-member msg :id))
          (id (plist-get msg :id)))
      (cond
       ((stringp method)
        (harness-acp--conn-dispatch conn method (plist-get msg :params) (and has-id id)))
       (has-id
        (let ((promise (gethash id (harness-acp-connection-pending conn))))
          (if (null promise)
              (harness-log 'debug "acp: response to unknown request %S" id)
            (remhash id (harness-acp-connection-pending conn))
            (if (plist-member msg :error)
                (let ((e (plist-get msg :error)))
                  (harness-reject promise (list 'acp-error (plist-get e :code) (plist-get e :message)
                                                (plist-get e :data))))
              (harness-resolve promise (plist-get msg :result))))))
       (t (harness-log 'debug "acp: ignoring message %S" msg))))))

(defun harness-acp--conn-dispatch (conn method params id)
  "Hand METHOD with PARAMS to CONN's handler; ID non-nil means a request."
  (let* ((handler (harness-acp-connection-handler conn))
         (done nil)
         ;; Returns non-nil when the answer went out (see `harness-acp-set-handler').
         (respond (and id
                       (lambda (value)
                         (unless done
                           (setq done t)
                           (condition-case err
                               (progn
                                 (harness-acp--conn-send
                                  conn (if (harness-acp-error-value-p value)
                                           (harness-acp--message id nil (list (harness-acp-error-value-code value)
                                                                              (harness-acp-error-value-message value)
                                                                              (harness-acp-error-value-data value)))
                                         (harness-acp--message id value)))
                                 t)
                             (error (harness-log 'warn "acp: could not send response: %s"
                                                 (harness-error-message err))
                                    nil)))))))
    (cond
     ((null handler)
      (when respond
        (harness-acp-respond-error respond harness-acp-error-method-not-found
                                   (format "No handler on this client for %s" method))))
     (t (condition-case err
            (funcall handler method params respond)
          (error
           (harness-log 'error "acp: client handler failed on %s: %S" method err)
           (when respond
             (harness-acp-respond-error respond harness-acp-error-method (harness-error-message err)))))))))

;;;; Corporate mode

(defun harness-acp--on-corporate-mode ()
  "Apply `harness-corporate-mode' turned on to the running server.
Run from `harness-corporate-mode-change-hook'.  Clients on other
devices are dropped, and a server listening beyond this machine moves
to the loopback address, on the same port when it is free."
  (when (harness-corporate-p)
    (dolist (client (copy-sequence harness-acp--clients))
      (when (harness-acp-client-remote-info client)
        (harness-acp--drop-client client)))
    (let ((contact (harness-acp--server-contact)))
      (when (and contact (not (harness-acp--loopback-p (format "%s" (plist-get contact :host)))))
        (harness-log 'info "acp: corporate mode is on; serving on 127.0.0.1 only")
        (harness-call 'acp/stop)
        (condition-case err
            (harness-call 'acp/start :host "127.0.0.1" :port (plist-get contact :port))
          (error (harness-log 'warn "acp: could not listen on 127.0.0.1 again: %s"
                              (harness-error-message err))))))))

;;;; Module

(defun harness-acp--init ()
  "Subscribe to bus events and start the TCP server when enabled."
  (add-hook 'harness-corporate-mode-change-hook #'harness-acp--on-corporate-mode)
  (harness-acp--subscribe)
  (when harness-acp--server-enabled
    (condition-case err
        (harness-call 'acp/start)
      (error (harness-log 'warn "acp: TCP server not started: %s" (harness-error-message err))))))

(defun harness-acp--shutdown ()
  "Stop the TCP server."
  (harness-call 'acp/stop))

(harness-define-module 'acp
  :doc "Agent Client Protocol: local and TCP transports, server and client."
  :requires nil
  :init #'harness-acp--init
  :shutdown #'harness-acp--shutdown)

;; A reload does not initialise a running module again: subscribe the
;; handlers this version adds now.
(when (harness-module-ready-p 'acp)
  (add-hook 'harness-corporate-mode-change-hook #'harness-acp--on-corporate-mode)
  (harness-acp--subscribe))

(provide 'harness-acp)
;;; harness-acp.el ends here
