;;; harness-acp-test.el --- Tests for ACP protocol and transports -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'harness-core)
(require 'harness-acp)
(require 'harness-acp-inprocess)
(require 'harness-test-helpers)

(harness-module-load 'harness-acp)

;; Declare the events the ACP bridges watch for.  In the full harness the
;; session module declares these; these unit tests do not load it.
(harness-event-define 'session-entry-added :module 'harness-acp-test)
(harness-event-define 'session-info-updated :module 'harness-acp-test)
(harness-event-define 'session-config-changed :module 'harness-acp-test)
(harness-event-define 'session-usage-changed :module 'harness-acp-test)
(harness-event-define 'session-status-changed :module 'harness-acp-test)
(harness-event-define 'session-created :module 'harness-acp-test)
(harness-event-define 'session-deleted :module 'harness-acp-test)

(defun harness-acp-test--pair ()
  "Return a fresh (AGENT . CLIENT) in-process pair."
  (let ((pair (harness-acp-inprocess-pair)))
    (harness-acp-connection-register-method
     (car pair) "test/echo"
     (lambda (_connection params) (list :echo (plist-get params :value))))
    (harness-acp-connection-register-method
     (car pair) "test/notify"
     (lambda (_connection params) (setq harness-acp-test--notified params)))
    (harness-acp-connection-register-method
     (car pair) "test/deferred"
     (lambda (_connection _params)
       (let ((deferred (harness-deferred-new)))
         (run-at-time 0.01 nil (lambda () (harness-deferred-resolve deferred :later)))
         deferred)))
    (harness-acp-connection-register-method
     (car pair) "test/signal"
     (lambda (_connection _params) (error "handler exploded")))
    (harness-acp-connection-register-method
     (car pair) "test/protocol-error"
     (lambda (_connection _params)
       (signal 'harness-acp-error (list -32602 "bad params" '(:field "x")))))
    pair))

(defvar harness-acp-test--notified nil)

(ert-deftest harness-acp-request-response ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (result nil))
    (harness-deferred-then
     (harness-acp-connection-request client "test/echo" (list :value 41))
     (lambda (value) (setq result value)))
    (should (equal result '(:echo 41)))))

(ert-deftest harness-acp-notification ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair)))
    (setq harness-acp-test--notified nil)
    (harness-acp-connection-notify client "test/notify" (list :value "hey"))
    (should (equal harness-acp-test--notified '(:value "hey")))))

(ert-deftest harness-acp-method-not-found ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (error-seen nil))
    (harness-deferred-then
     (harness-acp-connection-request client "test/absent" nil)
     nil
     (lambda (error) (setq error-seen error)))
    (should (eq (car error-seen) 'harness-acp-error))
    (should (eq (nth 0 (cdr error-seen)) -32601))))

(ert-deftest harness-acp-handler-error-is-internal-error ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (error-seen nil))
    (harness-deferred-then
     (harness-acp-connection-request client "test/signal" nil)
     nil
     (lambda (error) (setq error-seen error)))
    (should (eq (nth 0 (cdr error-seen)) -32603))))

(ert-deftest harness-acp-protocol-error-passthrough ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (error-seen nil))
    (harness-deferred-then
     (harness-acp-connection-request client "test/protocol-error" nil)
     nil
     (lambda (error) (setq error-seen error)))
    (should (eq (nth 0 (cdr error-seen)) -32602))
    (should (equal (nth 1 (cdr error-seen)) "bad params"))
    (should (equal (nth 2 (cdr error-seen)) '(:field "x")))))

(ert-deftest harness-acp-deferred-handler ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (result nil))
    (harness-deferred-then
     (harness-acp-connection-request client "test/deferred" nil)
     (lambda (value) (setq result value)))
    (should (harness-test-wait-for (lambda () (equal result :later))))))

(ert-deftest harness-acp-timeout ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (agent (car pair))
         (error-seen nil))
    (harness-acp-connection-register-method
     agent "test/never"
     (lambda (_connection _params) (harness-deferred-new)))
    (let ((deferred (harness-acp-connection-request client "test/never" nil :timeout 0.05)))
      (harness-deferred-then deferred nil (lambda (error) (setq error-seen error)))
      (should (harness-test-settle deferred))
      (should (eq (car error-seen) 'harness-acp-error))
      (should (eq (nth 0 (cdr error-seen)) -32603)))))

(ert-deftest harness-acp-close-rejects-pending ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (agent (car pair))
         (error-seen nil))
    (harness-acp-connection-register-method
     agent "test/never" (lambda (_connection _params) (harness-deferred-new)))
    (let ((deferred (harness-acp-connection-request client "test/never" nil)))
      (harness-deferred-then deferred nil (lambda (error) (setq error-seen error)))
      (harness-acp-connection-close agent "gone")
      (should (eq (car error-seen) 'harness-acp-closed)))))

(ert-deftest harness-acp-unknown-response-ignored ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair)))
    (harness-acp-connection-receive
     client (list :jsonrpc "2.0" :id 99999 :result (make-hash-table)))
    (should t)))

(ert-deftest harness-acp-json-round-trip ()
  (let* ((message (harness-acp-request-message
                   1 "session/prompt"
                   (list :sessionId "s1"
                         :prompt (vector (list :type "text" :text "hi\nthere"))
                         :flag t
                         :no :false)))
         (parsed (harness-acp-parse (harness-acp-serialize message))))
    (should (equal (plist-get parsed :method) "session/prompt"))
    (should (equal (plist-get (plist-get parsed :params) :sessionId) "s1"))
    (should (equal (aref (plist-get (plist-get parsed :params) :prompt) 0)
                   '(:type "text" :text "hi\nthere")))
    (should (harness-acp-json-true-p (plist-get (plist-get parsed :params) :flag)))
    (should (eq (plist-get (plist-get parsed :params) :no) :false))))

(ert-deftest harness-acp-plist-omit-nil ()
  (should (equal (harness-acp-plist-omit-nil '(:a 1 :b nil :c :false))
                 '(:a 1 :c :false))))

;;; Agent method table against fake services

(defvar harness-acp-test--sessions nil)

(defun harness-acp-test--install-fakes ()
  "Install minimal session and agent services for the protocol tests."
  (setq harness-acp-test--sessions nil)
  (harness-service-register
   "session"
   :module 'harness-acp-test
   :doc "Fake session service."
   :methods
   (list
    (cons 'create
          (lambda (&rest args)
            (let ((session (list :sessionId "sess-1"
                                 :cwd (plist-get args :cwd)
                                 :title (plist-get args :title))))
              (push session harness-acp-test--sessions)
              session)))
    (cons 'load (lambda (&rest _) nil))
    (cons 'close (lambda (&rest _) nil))
    (cons 'entries (lambda (&rest _) []))
    (cons 'configuration
          (lambda (&rest _)
            (list :configOptions
                  (vector (list :id "model" :name "Model" :type "select"
                                :currentValue "test-model"
                                :options (vector (list :value "test-model" :name "Test")))))))
    (cons 'list (lambda (&rest _) (list :sessions [])))
    (cons 'delete (lambda (&rest _) nil))
    (cons 'set-mode (lambda (&rest _) nil))
    (cons 'set-config (lambda (&rest _) (list :configOptions [])))))
  (harness-service-register
   "agent"
   :module 'harness-acp-test
   :doc "Fake agent service."
   :methods
   (list (cons 'prompt (lambda (&rest _args) "end_turn"))
         (cons 'cancel (lambda (&rest _) nil)))))

(ert-deftest harness-acp-initialize ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (result nil))
    (harness-deferred-then
     (harness-acp-connection-request
      client "initialize"
      (list :protocolVersion 1
            :clientCapabilities (list :fs (list :readTextFile t :writeTextFile t))
            :clientInfo (list :name "test-client" :version "1.0")))
     (lambda (value) (setq result value)))
    (should (= (plist-get result :protocolVersion) 1))
    (should (harness-acp-json-true-p (plist-get (plist-get result :agentCapabilities) :loadSession)))
    (should (equal (plist-get (plist-get result :agentInfo) :name) "emacs-agent-harness"))))

(ert-deftest harness-acp-session-new-and-configuration ()
  (harness-acp-test--install-fakes)
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (result nil))
    (harness-deferred-then
     (harness-acp-connection-request client "session/new" (list :cwd "/tmp" :mcpServers []))
     (lambda (value) (setq result value)))
    (should (equal (plist-get result :sessionId) "sess-1"))
    (should (vectorp (plist-get result :configOptions)))
    (let ((model (aref (plist-get result :configOptions) 0)))
      (should (equal (plist-get model :id) "model")))
    (should (harness-acp-connection-tracks-session-p (car pair) "sess-1"))))

(ert-deftest harness-acp-session-prompt-stop-reason ()
  (harness-acp-test--install-fakes)
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (result nil))
    (harness-deferred-then
     (harness-acp-connection-request
      client "session/prompt"
      (list :sessionId "sess-1" :prompt (vector (list :type "text" :text "hello"))))
     (lambda (value) (setq result value)))
    (should (equal (plist-get result :stopReason) "end_turn"))))

(ert-deftest harness-acp-session-new-without-service-is-error ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (error-seen nil))
    ;; Remove any fake session service other tests installed.
    (harness-service-unregister "session")
    (harness-deferred-then
     (harness-acp-connection-request client "session/new" (list :cwd "/tmp"))
     nil
     (lambda (error) (setq error-seen error)))
    (should (eq (nth 0 (cdr error-seen)) -32601))))

(ert-deftest harness-acp-extension-methods ()
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (version nil)
         (pong nil))
    (harness-deferred-then
     (harness-acp-connection-request client "_harness/version" nil)
     (lambda (value) (setq version value)))
    (harness-deferred-then
     (harness-acp-connection-request client "_harness/ping" nil)
     (lambda (value) (setq pong value)))
    (should (equal (plist-get version :version) "0.1.0"))
    (should (harness-acp-json-true-p (plist-get pong :pong)))))

;;; Event bridging

(ert-deftest harness-acp-bridges-transcript-entries-to-session-update ()
  (harness-acp-test--install-fakes)
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (updates nil))
    (harness-acp-connection-register-method
     client "session/update"
     (lambda (_connection params) (push params updates)))
    (harness-acp-connection-request client "session/new" (list :cwd "/tmp" :mcpServers []))
    (harness-emit 'session-entry-added
                  :session-id "sess-1"
                  :entry (list :sessionUpdate "agent_message_chunk"
                               :messageId "m1"
                               :content (list :type "text" :text "hello")))
    (should (= (length updates) 1))
    (should (equal (plist-get (plist-get (car updates) :update) :sessionUpdate)
                   "agent_message_chunk"))))

(ert-deftest harness-acp-does-not-send-updates-for-untracked-sessions ()
  (harness-acp-test--install-fakes)
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (updates nil))
    (harness-acp-connection-register-method
     client "session/update"
     (lambda (_connection params) (push params updates)))
    (harness-emit 'session-entry-added
                  :session-id "stranger"
                  :entry (list :sessionUpdate "agent_message_chunk"))
    (should-not updates)))

(ert-deftest harness-acp-bridges-usage-and-status ()
  (harness-acp-test--install-fakes)
  (let* ((pair (harness-acp-test--pair))
         (client (cdr pair))
         (usage nil)
         (status nil))
    (harness-acp-connection-register-method
     client "session/update"
     (lambda (_connection params)
       (when (equal (plist-get (plist-get params :update) :sessionUpdate) "usage_update")
         (setq usage params))))
    (harness-acp-connection-register-method
     client "_harness/session_status"
     (lambda (_connection params) (setq status params)))
    (harness-acp-connection-request client "session/new" (list :cwd "/tmp" :mcpServers []))
    (harness-emit 'session-usage-changed
                  :session-id "sess-1" :used 10 :size 100
                  :cost (list :amount 0.01 :currency "USD"))
    (harness-emit 'session-status-changed
                  :session-id "sess-1" :status "running" :previous "idle")
    (should (equal (plist-get (plist-get usage :update) :used) 10))
    (should (equal (plist-get usage :update) '(:sessionUpdate "usage_update"
                                                                :used 10 :size 100
                                                                :cost (:amount 0.01 :currency "USD"))))
    (should (equal (plist-get status :status) "running"))))

;;; In-process transport

(ert-deftest harness-acp-inprocess-connect ()
  (let* ((pair (harness-acp-test--pair))
         (agent (car pair))
         (client (harness-acp-inprocess-connect agent))
         (result nil))
    (harness-acp-connection-register-method
     agent "test/echo" (lambda (_connection params) (plist-get params :value)))
    (harness-deferred-then
     (harness-acp-connection-request client "test/echo" (list :value :hello))
     (lambda (value) (setq result value)))
    (should (eq result :hello))))

(ert-deftest harness-acp-refresh-installs-new-methods ()
  ;; A hot reload can add extension methods after the connection exists.
  (require 'harness-acp-inprocess)
  (harness-module-load 'harness-acp)
  (harness-module-load 'harness-acp-inprocess)
  (let* ((pair (harness-acp-inprocess-pair))
         (client (cdr pair)))
    (unwind-protect
        (progn
          (harness-acp-agent-started (car pair))
          (harness-acp-connection-register-method
           (car pair) "test/echo" (lambda (_connection params) (plist-get params :value)))
          (harness-acp-refresh-agent-methods)
          (let ((deferred (harness-acp-connection-request
                           client "test/echo" (list :value "hi"))))
            (harness-test-settle deferred 5)
            (should (harness-deferred-resolved-p deferred))
            (should (equal (harness-deferred-value deferred) "hi"))))
      (harness-acp-connection-close client "test over")
      (harness-acp-connection-close (car pair) "test over"))))

(provide 'harness-acp-test)
;;; harness-acp-test.el ends here
