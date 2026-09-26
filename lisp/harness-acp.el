;;; harness-acp.el --- Agent Client Protocol over pluggable transports -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; ACP v1 (<https://agentclientprotocol.com/protocol/v1/overview>) as
;; JSON-RPC 2.0 message plists.  This module is the projection of the
;; harness state layer onto the wire: it dispatches ACP methods to kernel
;; services and turns harness events into `session/update' notifications.
;; It contains no session, model or UI logic.
;;
;; JSON representation follows Emacs' own convention, because that is what
;; `json-serialize' and `json-parse-string' round-trip by default:
;;
;;   JSON object  <-> plist          ({} parses to nil, use a hash table to send {})
;;   JSON array   <-> vector         ([] parses to [], send [] not nil)
;;   JSON true    <-> t
;;   JSON false   <-> :false         (truthiness trap: test with `eq', see
;;                                    `harness-acp-json-true-p')
;;   JSON null    <-> :null          (omit optional keys instead of sending null)
;;
;; Messages are plists.  A request is (:jsonrpc "2.0" :id ID :method M
;; :params P), a notification the same without :id, a response (:jsonrpc
;; "2.0" :id ID :result R) and an error (:jsonrpc "2.0" :id ID :error
;; (:code C :message M :data D)).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'harness-core)

(define-error 'harness-acp-error "Agent Client Protocol error")
(define-error 'harness-acp-closed "ACP connection closed" 'harness-error)

(defconst harness-acp-protocol-version 1
  "ACP major protocol version implemented by this module.")

(defconst harness-acp-error-codes
  '((parse-error . -32700)
    (invalid-request . -32600)
    (method-not-found . -32601)
    (invalid-params . -32602)
    (internal-error . -32603))
  "JSON-RPC standard error codes.")

(defconst harness-acp-agent-info
  '(:name "emacs-agent-harness" :title "Emacs Agent Harness" :version "0.1.0")
  "Implementation information sent by the agent role.")

(defun harness-acp-json-true-p (value)
  "Return non-nil when VALUE is the JSON true, not merely non-nil.
Parsed JSON false is the keyword :false, which is non-nil in Lisp."
  (eq value t))

(defun harness-acp-plist-omit-nil (plist)
  "Return PLIST without entries whose value is nil.
JSON cannot round-trip a nil plist value: the serializer writes {}.  Use
this for optional fields instead of sending `:null'."
  (harness-plist-omit-nil plist))

;;; Messages

(defun harness-acp-request-message (id method &optional params)
  "Build a request message for ID calling METHOD with PARAMS."
  (let ((message (list :jsonrpc "2.0" :id id :method method)))
    (when params (setq message (append message (list :params params))))
    message))

(defun harness-acp-notification-message (method &optional params)
  "Build a notification message for METHOD with PARAMS."
  (let ((message (list :jsonrpc "2.0" :method method)))
    (when params (setq message (append message (list :params params))))
    message))

(defun harness-acp-result-message (id result)
  "Build a response message for ID with RESULT."
  (list :jsonrpc "2.0" :id id :result (or result (make-hash-table))))

(defun harness-acp-error-message (id code message &optional data)
  "Build an error response for ID with CODE, MESSAGE and DATA."
  (let ((error (list :code code :message message)))
    (when data (setq error (append error (list :data data))))
    (list :jsonrpc "2.0" :id id :error error)))

(defun harness-acp-request-p (message)
  "Return non-nil when MESSAGE is a request."
  (and (plist-get message :method)
       (plist-member message :id)))

(defun harness-acp-notification-p (message)
  "Return non-nil when MESSAGE is a notification."
  (and (plist-get message :method)
       (not (plist-member message :id))))

(defun harness-acp-response-p (message)
  "Return non-nil when MESSAGE is a response."
  (and (not (plist-member message :method))
       (plist-member message :id)
       (or (plist-member message :result) (plist-member message :error))))

(defun harness-acp-serialize (message)
  "Serialize MESSAGE to a JSON string."
  (json-serialize message))

(defun harness-acp-parse (string)
  "Parse STRING into a message plist."
  (json-parse-string string :object-type 'plist))

;;; Transports

(cl-defstruct (harness-acp-transport (:constructor harness-acp-transport-create))
  name send-fn close-fn)

(defun harness-acp-transport-send (transport message)
  "Send MESSAGE over TRANSPORT."
  (when (harness-acp-transport-send-fn transport)
    (funcall (harness-acp-transport-send-fn transport) message)))

(defun harness-acp-transport-close (transport)
  "Close TRANSPORT."
  (when (harness-acp-transport-close-fn transport)
    (funcall (harness-acp-transport-close-fn transport))))

;;; Connections

(cl-defstruct (harness-acp-connection (:constructor harness-acp-connection--make))
  role                                  ; 'agent or 'client
  transport
  (pending (make-hash-table :test #'equal)) ; id -> (deferred . method)
  (handlers (make-hash-table :test #'equal)) ; method -> fn(connection, params)
  (close-hooks nil)
  (next-id 0)
  closed
  (state (make-hash-table :test #'equal))
  protocol-version
  client-info
  client-capabilities
  agent-info
  agent-capabilities)

(defun harness-acp-connection-create (role transport)
  "Create a ROLE connection over TRANSPORT."
  (harness-acp-connection--make :role role :transport transport))

(defun harness-acp-connection-register-method (connection method function)
  "Call FUNCTION for METHOD on CONNECTION.
FUNCTION is called with two arguments, CONNECTION and the params plist,
and may return a value or a deferred."
  (puthash method function (harness-acp-connection-handlers connection)))

(defun harness-acp-connection-unregister-method (connection method)
  "Remove the handler for METHOD on CONNECTION."
  (remhash method (harness-acp-connection-handlers connection)))

(defun harness-acp-connection-set (connection key value)
  "Store VALUE under KEY in CONNECTION's private state."
  (puthash key value (harness-acp-connection-state connection)))

(defun harness-acp-connection-get (connection key)
  "Return CONNECTION's private state under KEY."
  (gethash key (harness-acp-connection-state connection)))

(defun harness-acp-connection-send (connection message)
  "Send MESSAGE over CONNECTION."
  (when (harness-acp-connection-closed connection)
    (signal 'harness-acp-closed (list "Connection is closed")))
  (harness-acp-transport-send (harness-acp-connection-transport connection) message)
  message)

(defun harness-acp-connection-notify (connection method &optional params)
  "Send a notification METHOD with PARAMS over CONNECTION."
  (harness-acp-connection-send
   connection (harness-acp-notification-message method params)))

(defun harness-acp-connection-request (connection method &optional params &rest args)
  "Send a request calling METHOD with PARAMS and return a deferred.
ARGS accepts :timeout SECONDS; when it elapses the deferred is rejected."
  (declare (indent 2))
  (let* ((id (cl-incf (harness-acp-connection-next-id connection)))
         (deferred (harness-deferred-new))
         (timeout (plist-get args :timeout)))
    (puthash id (cons deferred method) (harness-acp-connection-pending connection))
    (when timeout
      (run-at-time timeout nil
                   (lambda ()
                     (when (gethash id (harness-acp-connection-pending connection))
                       (remhash id (harness-acp-connection-pending connection))
                       (harness-deferred-reject
                        deferred (cons 'harness-acp-error
                                       (list -32603 "Request timed out" nil)))))))
    (harness-deferred-on-cancel deferred
                                (lambda ()
                                  (harness-acp-connection-cancel-request connection id)))
    (condition-case err
        (harness-acp-connection-send
         connection (harness-acp-request-message id method params))
      (error
       (remhash id (harness-acp-connection-pending connection))
       (harness-deferred-reject deferred (cons (car err) (cdr err)))))
    deferred))

(defun harness-acp-connection-cancel-request (connection id)
  "Forget the pending request ID on CONNECTION and notify the peer.
Notifies with the `$/cancelRequest' JSON-RPC extension, which peers may
ignore."
  (when (gethash id (harness-acp-connection-pending connection))
    (remhash id (harness-acp-connection-pending connection))
    (condition-case nil
        (harness-acp-connection-notify connection "$/cancelRequest" (list :id id))
      (harness-acp-closed nil))))

(defun harness-acp-connection-respond (connection id result)
  "Respond to request ID on CONNECTION with RESULT."
  (harness-acp-connection-send connection (harness-acp-result-message id result)))

(defun harness-acp-connection-fail (connection id code message &optional data)
  "Respond to request ID on CONNECTION with an error."
  (harness-acp-connection-send connection (harness-acp-error-message id code message data)))

(defun harness-acp-connection-on-close (connection function)
  "Call FUNCTION when CONNECTION closes."
  (push function (harness-acp-connection-close-hooks connection)))

(defun harness-acp-connection-close (connection &optional reason)
  "Close CONNECTION, rejecting pending requests.
REASON is a human-readable string."
  (unless (harness-acp-connection-closed connection)
    (setf (harness-acp-connection-closed connection) t)
    (let ((pending nil))
      (maphash (lambda (id entry) (push (cons id entry) pending))
               (harness-acp-connection-pending connection))
      (clrhash (harness-acp-connection-pending connection))
      (dolist (entry pending)
        (harness-deferred-reject
         (car (cdr entry))
         (cons 'harness-acp-closed (list (or reason "Connection closed"))))))
    (harness-acp-transport-close (harness-acp-connection-transport connection))
    (dolist (hook (harness-acp-connection-close-hooks connection))
      (condition-case err (funcall hook) (error (harness-log "close hook error: %S" err))))
    (setf (harness-acp-connection-close-hooks connection) nil)))

;;; Receiving

(defun harness-acp-connection-receive (connection message)
  "Process an incoming MESSAGE on CONNECTION."
  (harness-log "acp recv %s: %S" (harness-acp-connection-role connection) message)
  (cond
   ((harness-acp-request-p message)
    (harness-acp--handle-request connection message))
   ((harness-acp-notification-p message)
    (harness-acp--handle-notification connection message))
   ((harness-acp-response-p message)
    (harness-acp--handle-response connection message))
   (t
    (harness-log "acp ignoring malformed message: %S" message))))

(defun harness-acp--handle-request (connection message)
  "Handle an incoming request MESSAGE on CONNECTION."
  (let* ((id (plist-get message :id))
         (method (plist-get message :method))
         (params (plist-get message :params))
         (handler (gethash method (harness-acp-connection-handlers connection))))
    (if (null handler)
        (harness-acp-connection-fail
         connection id
         (alist-get 'method-not-found harness-acp-error-codes)
         (format "Method not found: %s" method))
      (condition-case err
          (let ((result (funcall handler connection params)))
            (if (harness-deferred-p result)
                (harness-deferred-then
                 result
                 (lambda (value)
                   (unless (harness-acp-connection-closed connection)
                     (harness-acp-connection-respond connection id value)))
                 (lambda (error)
                   (unless (harness-acp-connection-closed connection)
                     (harness-acp--respond-error connection id error))))
              (harness-acp-connection-respond connection id result)))
        (error
         (harness-acp--respond-error connection id (cons (car err) (cdr err))))))))

(defun harness-acp--respond-error (connection id error)
  "Respond to ID on CONNECTION with the reduced ERROR."
  (let ((data (cdr error)))
    (cond
     ((eq (car error) 'harness-acp-error)
      (let ((code (nth 0 data))
            (message (nth 1 data))
            (extra (nth 2 data)))
        (harness-acp-connection-fail connection id (or code -32603) message extra)))
     ((eq (car error) 'harness-user-error)
      (harness-acp-connection-fail
       connection id (alist-get 'invalid-params harness-acp-error-codes)
       (or (car data) "Invalid request")))
     (t
      (harness-acp-connection-fail
       connection id
       (alist-get 'internal-error harness-acp-error-codes)
       (format "%s: %s" (car error) (or (car data) "error")))))))

(defun harness-acp--handle-notification (connection message)
  "Handle an incoming notification MESSAGE on CONNECTION."
  (let* ((method (plist-get message :method))
         (handler (gethash method (harness-acp-connection-handlers connection))))
    (when handler
      (condition-case err
          (funcall handler connection (plist-get message :params))
        (error (harness-log "acp notification %s failed: %S" method err))))))

(defun harness-acp--handle-response (connection message)
  "Handle an incoming response MESSAGE on CONNECTION."
  (let* ((id (plist-get message :id))
         (entry (gethash id (harness-acp-connection-pending connection))))
    (if (null entry)
        (harness-log "acp response for unknown id %S" id)
      (remhash id (harness-acp-connection-pending connection))
      (let ((deferred (car entry)))
        (if (plist-member message :error)
            (let* ((error (plist-get message :error))
                   (code (plist-get error :code))
                   (text (plist-get error :message))
                   (data (plist-get error :data)))
              (harness-deferred-reject
               deferred (cons 'harness-acp-error (list code text data))))
          (harness-deferred-resolve deferred (plist-get message :result)))))))

;;; Agent-side method table

(defun harness-acp-agent-started (connection)
  "Install the standard agent method table on CONNECTION.
Returns CONNECTION."
  (dolist (entry harness-acp-agent-methods)
    (harness-acp-connection-register-method connection (car entry) (cdr entry)))
  (push connection harness-acp--agent-connections)
  (harness-acp-connection-on-close
   connection
   (lambda ()
     (setq harness-acp--agent-connections (delq connection harness-acp--agent-connections))))
  connection)

(defvar harness-acp-agent-methods
  '(("initialize" . harness-acp--method-initialize)
    ("session/new" . harness-acp--method-session-new)
    ("session/load" . harness-acp--method-session-load)
    ("session/resume" . harness-acp--method-session-resume)
    ("session/close" . harness-acp--method-session-close)
    ("session/list" . harness-acp--method-session-list)
    ("session/delete" . harness-acp--method-session-delete)
    ("session/prompt" . harness-acp--method-session-prompt)
    ("session/cancel" . harness-acp--method-session-cancel)
    ("session/set_mode" . harness-acp--method-session-set-mode)
    ("session/set_config_option" . harness-acp--method-session-set-config-option)
    ("_harness/session/info" . harness-acp--method-session-info)
    ("_harness/session/fork" . harness-acp--method-session-fork)
    ("_harness/session/rename" . harness-acp--method-session-rename)
    ("_harness/session/entries" . harness-acp--method-session-entries)
    ("_harness/agent/configuration" . harness-acp--method-agent-configuration)
    ("_harness/skills/list" . harness-acp--method-skills-list)
    ("_harness/skills/load" . harness-acp--method-skills-load)
    ("_harness/ping" . harness-acp--method-ping)
    ("_harness/version" . harness-acp--method-version))
  "ACP method table for the agent role.")

(defconst harness-acp-agent-capabilities
  (list :loadSession t
        :promptCapabilities (list :image t :audio t :embeddedContext t)
        :mcpCapabilities (list :http t)
        :sessionCapabilities (list :list (make-hash-table)
                                   :delete (make-hash-table)
                                   :close (make-hash-table)
                                   :resume (make-hash-table))
        :_meta (list :harness (list :version harness-version
                                    :sessionStatus t
                                    :queue t
                                    :forks t)))
  "Capabilities advertised by the agent role.")

(defun harness-acp--method-initialize (connection params)
  "Handle the initialize request on CONNECTION with PARAMS."
  (setf (harness-acp-connection-client-info connection) (plist-get params :clientInfo)
        (harness-acp-connection-client-capabilities connection) (plist-get params :clientCapabilities))
  (let* ((requested (plist-get params :protocolVersion))
         (version (if (and requested (<= requested harness-acp-protocol-version))
                      requested
                    harness-acp-protocol-version)))
    (setf (harness-acp-connection-protocol-version connection) version)
    (harness-log "acp client initialized: version %s info %S" version
                 (harness-acp-connection-client-info connection))
    (list :protocolVersion version
          :agentCapabilities harness-acp-agent-capabilities
          :agentInfo harness-acp-agent-info
          :authMethods [])))

(defun harness-acp--method-ping (_connection _params)
  "Handle _harness/ping."
  (list :pong t :time (harness-iso-time)))

(defun harness-acp--method-version (_connection _params)
  "Handle _harness/version."
  (list :name "emacs-agent-harness" :version harness-version
        :protocolVersion harness-acp-protocol-version))

(defun harness-acp--session-service (method &rest args)
  "Call session service METHOD with ARGS, or signal a protocol error."
  (if (harness-service-available-p "session" method)
      (apply #'harness-service-call "session" method args)
    (signal 'harness-acp-error
            (list (alist-get 'method-not-found harness-acp-error-codes)
                  (format "No session service method: %s" method)
                  nil))))

(defun harness-acp--method-session-prompt (_connection params)
  "Handle session/prompt with PARAMS."
  (unless (harness-service-available-p "agent" 'prompt)
    (signal 'harness-acp-error
            (list (alist-get 'method-not-found harness-acp-error-codes)
                  "No agent service; cannot run prompts" nil)))
  (let ((result (harness-service-call "agent" 'prompt
                                      :session-id (plist-get params :sessionId)
                                      :prompt (plist-get params :prompt)
                                      :meta (plist-get params :_meta))))
    (if (harness-deferred-p result)
        (harness-deferred-then result #'harness-acp--prompt-result)
      (harness-acp--prompt-result result))))

(defun harness-acp--prompt-result (stop-reason)
  "Convert a service stop reason to a session/prompt result."
  (list :stopReason (or stop-reason "end_turn")))

(defun harness-acp--method-session-cancel (_connection params)
  "Handle the session/cancel notification with PARAMS."
  (when (harness-service-available-p "agent" 'cancel)
    (harness-service-call "agent" 'cancel :session-id (plist-get params :sessionId)))
  nil)

(defun harness-acp--method-session-new (connection params)
  "Handle session/new with PARAMS on CONNECTION."
  (let* ((result (harness-acp--session-service
                  'create
                  :cwd (plist-get params :cwd)
                  :additional-directories (plist-get params :additionalDirectories)
                  :title (plist-get params :title)))
         (session-id (plist-get result :sessionId)))
    (unless session-id
      (signal 'harness-acp-error
              (list (alist-get 'internal-error harness-acp-error-codes)
                    "Session service did not return a sessionId"
                    nil)))
    (harness-acp-connection-track-session connection session-id)
    (append
     (list :sessionId session-id)
     (harness-acp--session-configuration session-id))))

(defun harness-acp--method-session-load (connection params)
  "Handle session/load with PARAMS on CONNECTION."
  (let* ((session-id (plist-get params :sessionId))
         (entries nil))
    (harness-acp--session-service
     'load
     :session-id session-id
     :cwd (plist-get params :cwd))
    (setq entries (harness-acp--session-service 'entries :session-id session-id))
    (harness-acp-connection-track-session connection session-id)
    (let ((replay (lambda (loaded)
                    (dolist (entry (append loaded nil))
                      (harness-acp-agent-send-update connection session-id entry))
                    (let ((configuration (harness-acp--session-configuration session-id)))
                      (when configuration
                        (harness-acp-agent-send-update
                         connection session-id
                         (list :sessionUpdate "config_option_update"
                               :configOptions (plist-get configuration :configOptions)))))
                    (make-hash-table))))
      (if (harness-deferred-p entries)
          (harness-deferred-then entries replay)
        (funcall replay entries)))))

(defun harness-acp--method-session-resume (connection params)
  "Handle session/resume with PARAMS on CONNECTION."
  (let ((session-id (plist-get params :sessionId)))
    (harness-acp--session-service
     'load :session-id session-id :cwd (plist-get params :cwd))
    (harness-acp-connection-track-session connection session-id)
    (append (list :sessionId session-id)
            (harness-acp--session-configuration session-id))))

(defun harness-acp--method-session-close (connection params)
  "Handle session/close with PARAMS on CONNECTION."
  (let ((session-id (plist-get params :sessionId)))
    (when (harness-service-available-p "agent" 'cancel)
      (ignore-errors (harness-service-call "agent" 'cancel :session-id session-id)))
    (harness-acp--session-service 'close :session-id session-id)
    (harness-acp-connection-untrack-session connection session-id)
    (make-hash-table)))

(defun harness-acp--method-session-list (_connection params)
  "Handle session/list with PARAMS."
  (let* ((result (harness-acp--session-service
                  'list :cwd (plist-get params :cwd)
                  :cursor (plist-get params :cursor)))
         (sessions (plist-get result :sessions)))
    (list :sessions (vconcat (mapcar #'harness-acp--session-info sessions))
          :nextCursor (or (plist-get result :nextCursor) :null))))

(defun harness-acp--session-info (info)
  "Project a harness session INFO onto an ACP SessionInfo object.
Harness extras are namespaced under _meta.harness."
  (let ((projected (harness-acp-plist-omit-nil
                    (list :sessionId (plist-get info :sessionId)
                          :cwd (plist-get info :cwd)
                          :title (plist-get info :title)
                          :updatedAt (plist-get info :updatedAt)
                          :additionalDirectories (plist-get info :additionalDirectories)
                          :_meta (list :harness
                                       (harness-acp-plist-omit-nil
                                        (list :status (plist-get info :status)
                                              :model (plist-get info :model)
                                              :permissionMode (plist-get info :permissionMode)
                                              :mode (plist-get info :mode)
                                              :unread (plist-get info :unread)
                                              :usage (plist-get info :usage)
                                              :cost (plist-get info :cost)
                                              :parentId (plist-get info :parentId)
                                              :forkEntryId (plist-get info :forkEntryId)
                                              :projectRoot (plist-get info :projectRoot)
                                              :messageCount (plist-get info :messageCount))))))))
    projected))

(defun harness-acp--method-session-info (_connection params)
  "Handle the _harness/session/info extension with PARAMS.
Unlike session/list this is a harness extension between our own client
and server, so it returns the complete info plist including _meta."
  (harness-acp--session-service 'info :session-id (plist-get params :sessionId)))

(defun harness-acp--method-session-fork (_connection params)
  "Handle the _harness/session/fork extension with PARAMS."
  (harness-acp--session-service 'fork
                                :session-id (plist-get params :sessionId)
                                :entry-id (plist-get params :entryId)
                                :title (plist-get params :title)))

(defun harness-acp--method-session-rename (_connection params)
  "Handle the _harness/session/rename extension with PARAMS."
  (harness-acp--session-service 'rename
                                :session-id (plist-get params :sessionId)
                                :title (plist-get params :title))
  (make-hash-table))

(defun harness-acp--method-session-entries (_connection params)
  "Handle the _harness/session/entries extension with PARAMS.
Returns the raw transcript entries (with ids and times)."
  (let ((entries (harness-acp--session-service 'entries
                                               :session-id (plist-get params :sessionId))))
    (if (harness-deferred-p entries)
        (harness-deferred-then entries (lambda (value) (list :entries (or value []))))
      (list :entries (or entries [])))))

(defun harness-acp--method-agent-configuration (_connection params)
  "Handle the _harness/agent/configuration extension with PARAMS."
  (let ((session-id (plist-get params :sessionId)))
    (cond
     ((harness-service-available-p "agent" 'configuration)
      (harness-service-call "agent" 'configuration :session-id session-id))
     ((harness-service-available-p "session" 'configuration)
      (harness-service-call "session" 'configuration :session-id session-id))
     (t (list :configOptions [])))))

(defun harness-acp--method-skills-list (_connection params)
  "Handle the _harness/skills/list extension with PARAMS."
  (if (harness-service-available-p "skill" 'list)
      (list :skills (harness-service-call "skill" 'list :cwd (plist-get params :cwd)))
    (list :skills [])))

(defun harness-acp--method-skills-load (_connection params)
  "Handle the _harness/skills/load extension with PARAMS."
  (unless (harness-service-available-p "skill" 'load)
    (signal 'harness-acp-error
            (list (alist-get 'method-not-found harness-acp-error-codes)
                  "No skills service is loaded" nil)))
  (harness-service-call "skill" 'load
                        :name (plist-get params :name)
                        :cwd (plist-get params :cwd)))

(defun harness-acp--method-session-delete (_connection params)
  "Handle session/delete with PARAMS."
  (harness-acp--session-service 'delete :session-id (plist-get params :sessionId))
  (make-hash-table))

(defun harness-acp--method-session-set-mode (_connection params)
  "Handle session/set_mode with PARAMS."
  (let ((service (harness-acp--config-service 'set-mode)))
    (when service
      (harness-service-call service 'set-mode
                            :session-id (plist-get params :sessionId)
                            :mode-id (plist-get params :modeId))))
  (make-hash-table))

(defun harness-acp--config-service (method)
  "Return the service that owns configuration METHOD, or signal.
The agent service owns model and thinking configuration because only it
knows the provider; the session service is the fallback."
  (cond ((harness-service-available-p "agent" method) "agent")
        ((harness-service-available-p "session" method) "session")
        (t (signal 'harness-acp-error
                   (list (alist-get 'method-not-found harness-acp-error-codes)
                         (format "No service provides %s" method)
                         nil)))))

(defun harness-acp--method-session-set-config-option (_connection params)
  "Handle session/set_config_option with PARAMS."
  (let* ((session-id (plist-get params :sessionId))
         (result (harness-service-call
                  (harness-acp--config-service 'set-config)
                  'set-config
                  :session-id session-id
                  :config-id (plist-get params :configId)
                  :value (plist-get params :value))))
    (list :configOptions (or (plist-get result :configOptions) []))))

(defun harness-acp--session-configuration (session-id)
  "Return :modes and :configOptions for SESSION-ID, if services provide them."
  (when (or (harness-service-available-p "agent" 'configuration)
            (harness-service-available-p "session" 'configuration))
    (let ((configuration (harness-service-call (harness-acp--config-service 'configuration)
                                               'configuration :session-id session-id)))
      (harness-acp-plist-omit-nil
       (list :modes (plist-get configuration :modes)
             :configOptions (plist-get configuration :configOptions))))))

;;; Agent-side session tracking and notifications

(defvar harness-acp--agent-connections nil
  "Agent-role connections that are still open.")

(defun harness-acp-connection-track-session (connection session-id)
  "Remember that CONNECTION follows SESSION-ID."
  (let ((sessions (or (harness-acp-connection-get connection 'sessions)
                      (let ((table (make-hash-table :test #'equal)))
                        (harness-acp-connection-set connection 'sessions table)
                        table))))
    (puthash session-id t sessions)))

(defun harness-acp-connection-untrack-session (connection session-id)
  "Forget that CONNECTION follows SESSION-ID."
  (when-let* ((sessions (harness-acp-connection-get connection 'sessions)))
    (remhash session-id sessions)))

(defun harness-acp-connection-tracks-session-p (connection session-id)
  "Return non-nil when CONNECTION follows SESSION-ID."
  (when-let* ((sessions (harness-acp-connection-get connection 'sessions)))
    (gethash session-id sessions)))

(defun harness-acp-agent-send-update (connection session-id update)
  "Send UPDATE as a session/update notification to CONNECTION for SESSION-ID.
Root-level harness bookkeeping fields are removed; ACP reserves root keys
and the same values travel in _meta.harness."
  (harness-acp-connection-notify
   connection "session/update"
   (list :sessionId session-id
         :update (harness-acp--strip-entry-extras update))))

(defun harness-acp--strip-entry-extras (entry)
  "Return ENTRY without root-level :id and :time fields."
  (if (or (plist-member entry :id) (plist-member entry :time))
      (cl-loop for (key value) on entry by #'cddr
               unless (memq key '(:id :time)) append (list key value))
    entry))

(defun harness-acp--broadcast-update (session-id update)
  "Send UPDATE for SESSION-ID to every agent connection following it."
  (dolist (connection harness-acp--agent-connections)
    (when (and (not (harness-acp-connection-closed connection))
               (harness-acp-connection-tracks-session-p connection session-id))
      (condition-case err
          (harness-acp-agent-send-update connection session-id update)
        (error (harness-log "acp update failed: %S" err))))))

(defun harness-acp--bridge-session-entry (payload)
  "Forward a transcript entry event PAYLOAD as a session/update."
  (harness-acp--broadcast-update (plist-get payload :session-id)
                                 (plist-get payload :entry)))

(defun harness-acp--bridge-session-info (payload)
  "Forward a session metadata event PAYLOAD as session_info_update."
  (harness-acp--broadcast-update
   (plist-get payload :session-id)
   (harness-acp-plist-omit-nil
    (list :sessionUpdate "session_info_update"
          :title (plist-get payload :title)
          :updatedAt (plist-get payload :updatedAt)))))

(defun harness-acp--bridge-session-config (payload)
  "Forward a configuration event PAYLOAD as config_option_update."
  (harness-acp--broadcast-update
   (plist-get payload :session-id)
   (list :sessionUpdate "config_option_update"
         :configOptions (or (plist-get payload :config-options) []))))

(defun harness-acp--bridge-session-usage (payload)
  "Forward a usage event PAYLOAD as usage_update."
  (let ((update (list :sessionUpdate "usage_update"
                      :used (or (plist-get payload :used) 0)
                      :size (or (plist-get payload :size) 0))))
    (when-let* ((cost (plist-get payload :cost)))
      (setq update (append update (list :cost cost))))
    (harness-acp--broadcast-update (plist-get payload :session-id) update)))

(defun harness-acp--bridge-session-status (payload)
  "Forward a status event PAYLOAD as the _harness/session_status extension."
  (let ((notification (harness-acp-plist-omit-nil
                       (list :sessionId (plist-get payload :session-id)
                             :status (plist-get payload :status)
                             :previous (plist-get payload :previous)
                             :title (plist-get payload :title)
                             :cwd (plist-get payload :cwd)
                             :model (plist-get payload :model)
                             :permissionMode (plist-get payload :permission-mode)
                             :unread (plist-get payload :unread)))))
    (dolist (connection harness-acp--agent-connections)
      (when (not (harness-acp-connection-closed connection))
        (condition-case err
            (harness-acp-connection-notify connection "_harness/session_status" notification)
          (error (harness-log "acp status failed: %S" err)))))))

(defun harness-acp--bridge-sessions-changed (_payload)
  "Tell all clients that the session list changed."
  (dolist (connection harness-acp--agent-connections)
    (when (not (harness-acp-connection-closed connection))
      (condition-case err
          (harness-acp-connection-notify connection "_harness/sessions_changed" (make-hash-table))
        (error (harness-log "acp sessions_changed failed: %S" err))))))

;;; Module

(defun harness-acp-connection-closed-p (connection)
  "Return non-nil when CONNECTION is closed."
  (harness-acp-connection-closed connection))

(defun harness-acp-setup ()
  "Set up the ACP module."
  (harness-on 'session-entry-added #'harness-acp--bridge-session-entry
              :module 'harness-acp)
  (harness-on 'session-info-updated #'harness-acp--bridge-session-info
              :module 'harness-acp)
  (harness-on 'session-config-changed #'harness-acp--bridge-session-config
              :module 'harness-acp)
  (harness-on 'session-usage-changed #'harness-acp--bridge-session-usage
              :module 'harness-acp)
  (harness-on 'session-status-changed #'harness-acp--bridge-session-status
              :module 'harness-acp)
  (harness-on 'session-created #'harness-acp--bridge-sessions-changed
              :module 'harness-acp)
  (harness-on 'session-deleted #'harness-acp--bridge-sessions-changed
              :module 'harness-acp)
  (harness-service-register
   "acp"
   :module 'harness-acp
   :doc "Agent Client Protocol connections."
   :methods '((agent-started . harness-acp-agent-started)
              (connection-create . harness-acp-connection-create))))

(defun harness-acp-teardown ()
  "Tear down the ACP module."
  (setq harness-acp--agent-connections nil))

(harness-module-define 'harness-acp
  :version harness-version
  :description "Agent Client Protocol over pluggable transports."
  :requires '((harness-core "0.1.0"))
  :provides '(harness-acp)
  :setup #'harness-acp-setup
  :teardown #'harness-acp-teardown)

(provide 'harness-acp)
;;; harness-acp.el ends here
