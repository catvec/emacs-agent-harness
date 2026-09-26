;;; harness-acp-agent-integration-test.el --- Agent over ACP -*- lexical-binding: t; -*-

;;; Commentary:

;; DESIGN.md requires every feature to be verified both through the local
;; Emacs side and through a remote ACP client.  This suite drives the real
;; session + tools + agent stack with a scripted provider, once over the
;; in-process transport (the local UI's path) and once over TCP (a remote
;; client's path), and checks the streamed session/update notifications.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-acp)
(require 'harness-acp-inprocess)
(require 'harness-acp-tcp)
(require 'harness-session)
(require 'harness-tools)
(require 'harness-agent)
(require 'harness-test-helpers)

(harness-module-load 'harness-acp)
(harness-module-load 'harness-acp-tcp)
(harness-module-load 'harness-tools)
(harness-module-load 'harness-session)
(harness-module-load 'harness-agent)

(defvar harness-acp-agent-integration-test--responses nil)
(defvar harness-acp-agent-integration-test--updates nil)
(defvar harness-acp-agent-integration-test--responses-consumed nil)

(defun harness-acp-agent-integration-test--install-provider ()
  "Install a scripted provider service."
  (setq harness-acp-agent-integration-test--responses nil
        harness-acp-agent-integration-test--updates nil)
  (harness-service-register
   "provider"
   :module 'harness-acp-agent-integration-test
   :methods
   (list
    (cons 'complete
          (lambda (request)
            (let* ((response (or (pop harness-acp-agent-integration-test--responses)
                                 (list :text "default"))))
              (dolist (delta (append (plist-get response :text-deltas) nil))
                (when-let* ((callback (plist-get request :on-text)))
                  (funcall callback delta)))
              (let ((deferred (harness-deferred-new)))
                (run-at-time 0.001 nil
                             (lambda ()
                               (harness-deferred-resolve
                                deferred
                                (harness-plist-omit-nil
                                 (list :text (plist-get response :text)
                                       :tool-calls (plist-get response :tool-calls)
                                       :stop-reason (or (plist-get response :stop-reason)
                                                        "end_turn")
                                       :usage (plist-get response :usage))))))
                deferred))))
    (cons 'models (lambda (&rest _args)
                    (vector (list :id "mock/mock-model" :name "Mock"
                                  :provider "mock" :context-window 100000))))
    (cons 'price (lambda (&rest _args) nil)))))

(defun harness-acp-agent-integration-test--install-tools ()
  "Register the echo tool."
  (harness-tool-register
   "echo"
   :description "Echo text."
   :schema '(:type "object" :properties (:text (:type "string")) :required ["text"])
   :kind 'read
   :read-only t
   :module 'harness-acp-agent-integration-test
   :handler (lambda (arguments _context) (format "echo:%s" (plist-get arguments :text)))))

(defun harness-acp-agent-integration-test--collect (client)
  "Register notification collectors on CLIENT."
  (harness-acp-connection-register-method
   client "session/update"
   (lambda (_connection params)
     (setq harness-acp-agent-integration-test--updates
           (append harness-acp-agent-integration-test--updates (list params))))))

(defun harness-acp-agent-integration-test--request (client method &optional params)
  "Send METHOD to CLIENT and return its settled result."
  (let ((deferred (harness-acp-connection-request client method params)))
    (harness-test-settle deferred 15)
    (when (harness-deferred-rejected-p deferred)
      (signal 'harness-error
              (list (format "ACP %s failed: %S" method (harness-deferred-value deferred)))))
    (harness-deferred-value deferred)))

(defun harness-acp-agent-integration-test--update-kinds ()
  "Return the kinds of the collected session updates."
  (mapcar (lambda (params) (plist-get (plist-get params :update) :sessionUpdate))
          harness-acp-agent-integration-test--updates))

(defun harness-acp-agent-integration-test--update-texts (kind)
  "Return the text of collected updates of KIND."
  (mapcar (lambda (params)
            (let ((content (plist-get (plist-get params :update) :content)))
              (if (vectorp content)
                  (plist-get (aref content 0) :text)
                (plist-get content :text))))
          (seq-filter (lambda (params)
                        (equal (plist-get (plist-get params :update) :sessionUpdate) kind))
                      harness-acp-agent-integration-test--updates)))

(defun harness-acp-agent-integration-test--run-flow (client directory)
  "Drive a full prompt turn on CLIENT in DIRECTORY."
  (harness-acp-agent-integration-test--collect client)
  (harness-acp-agent-integration-test--request
   client "initialize"
   (list :protocolVersion 1
         :clientCapabilities (list :fs (list :readTextFile t :writeTextFile t))
         :clientInfo (list :name "test-client" :version "1.0")))
  (let* ((created (harness-acp-agent-integration-test--request
                   client "session/new" (list :cwd directory :mcpServers [])))
         (session-id (plist-get created :sessionId)))
    (should session-id)
    (setq harness-acp-agent-integration-test--responses
          (list (list :text-deltas '("hel" "lo") :text "hello"
                      :stop-reason "end_turn"
                      :usage '(:input-tokens 5 :output-tokens 2))))
    (let ((result (harness-acp-agent-integration-test--request
                   client "session/prompt"
                   (list :sessionId session-id
                         :prompt (vector (list :type "text" :text "hi"))))))
      (should (equal (plist-get result :stopReason) "end_turn")))
    session-id))

(ert-deftest harness-acp-agent-local-inprocess-flow ()
  (let* ((harness-session-storage-directory (make-temp-file "harness-acp-agent-" t))
         (directory (make-temp-file "harness-acp-agent-project-" t))
         (pair nil))
    (unwind-protect
        (progn
          (clrhash harness-session--active)
          (clrhash harness-session--project-ids)
          (harness-acp-agent-integration-test--install-provider)
          (harness-acp-agent-integration-test--install-tools)
          (setq pair (harness-acp-inprocess-pair))
          (let ((session-id (harness-acp-agent-integration-test--run-flow (cdr pair) directory)))
            (should (member "agent_message_chunk"
                            (harness-acp-agent-integration-test--update-kinds)))
            (should (member "hello" (harness-acp-agent-integration-test--update-texts
                                     "agent_message_chunk")))
            (should (member "user_message_chunk"
                            (harness-acp-agent-integration-test--update-kinds)))
            ;; The session also appears in session/list and reports usage.
            (let ((listed (harness-acp-agent-integration-test--request
                           (cdr pair) "session/list" (list :cwd directory))))
              (should (= (length (plist-get listed :sessions)) 1)))
            (let ((info (harness-service-call "session" 'info :session-id session-id)))
              (should (equal (plist-get (plist-get info :usage) :input) 5)))))
      (when pair (harness-acp-connection-close (car pair) "test over"))
      (delete-directory directory t))))

(ert-deftest harness-acp-agent-remote-tcp-tool-flow ()
  (let* ((harness-session-storage-directory (make-temp-file "harness-acp-agent-" t))
         (directory (make-temp-file "harness-acp-agent-project-" t))
         (server nil)
         (client nil))
    (unwind-protect
        (progn
          (clrhash harness-session--active)
          (clrhash harness-session--project-ids)
          (harness-acp-agent-integration-test--install-provider)
          (harness-acp-agent-integration-test--install-tools)
          (setq server (harness-acp-tcp-server 0))
          (setq client (harness-acp-tcp-connect "127.0.0.1" (process-contact server :service)))
          (harness-acp-agent-integration-test--collect client)
          (harness-acp-agent-integration-test--request
           client "initialize" (list :protocolVersion 1))
          (let* ((created (harness-acp-agent-integration-test--request
                           client "session/new" (list :cwd directory :mcpServers [])))
                 (session-id (plist-get created :sessionId)))
            (setq harness-acp-agent-integration-test--responses
                  (list (list :tool-calls (vector (list :id "c1" :name "echo"
                                                        :arguments '(:text "remote")))
                              :stop-reason "tool_use")
                        (list :text "done" :stop-reason "end_turn")))
            (let ((result (harness-acp-agent-integration-test--request
                           client "session/prompt"
                           (list :sessionId session-id
                                 :prompt (vector (list :type "text" :text "use it"))))))
              (should (equal (plist-get result :stopReason) "end_turn")))
            (should (member "tool_call" (harness-acp-agent-integration-test--update-kinds)))
            (should (member "tool_call_update"
                            (harness-acp-agent-integration-test--update-kinds)))
            (should (member "done" (harness-acp-agent-integration-test--update-texts
                                    "agent_message_chunk")))))
      (when client (harness-acp-connection-close client "test over"))
      (when server (delete-process server))
      (delete-directory directory t))))

(provide 'harness-acp-agent-integration-test)
;;; harness-acp-agent-integration-test.el ends here
