;;; harness-openai-integration-test.el --- Full stack over real HTTP -*- lexical-binding: t; -*-

;;; Commentary:

;; The deepest end-to-end test: ACP in-process client -> agent -> real
;; provider registry -> real OpenAI-compatible provider -> real async HTTP
;; client -> canned SSE server; tool call executed through the real tool
;; registry; result fed back; final streamed answer asserted.  Nothing is
;; faked except the model server itself.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'harness-core)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-tools)
(require 'harness-acp)
(require 'harness-acp-inprocess)
(require 'harness-session)
(require 'harness-agent)
(require 'harness-test-helpers)

(harness-module-load 'harness-http)
(harness-module-load 'harness-provider)
(harness-module-load 'harness-provider-openai)
(harness-module-load 'harness-tools)
(harness-module-load 'harness-acp)
(harness-module-load 'harness-session)
(harness-module-load 'harness-agent)

(defvar harness-openai-integration-test--requests nil
  "HTTP requests the canned server received, oldest first.")

(defun harness-openai-integration-test--chunk (delta)
  "An SSE chunk whose choice delta is DELTA."
  (list :choices (vector (list :delta delta))))

(defun harness-openai-integration-test--finish (reason)
  "An SSE chunk reporting finish reason REASON."
  (list :choices (vector (list :delta (make-hash-table) :finish_reason reason))))

(defun harness-openai-integration-test--sse (payloads)
  "Build an SSE HTTP response from PAYLOADS (strings or plists)."
  (harness-test-http-response
   200 '(("Content-Type" . "text/event-stream"))
   (concat (mapconcat (lambda (payload)
                        (concat "data: "
                                (if (stringp payload)
                                    payload
                                  (json-serialize payload))
                                "\n\n"))
                      payloads "")
           "data: [DONE]\n\n")))

(defun harness-openai-integration-test--responses ()
  "The two scripted model responses: a tool call, then the answer."
  (list
   ;; First model response: text plus a tool call.
   (list (harness-openai-integration-test--chunk '(:content "Let me check. "))
         (harness-openai-integration-test--chunk
          '(:tool_calls [(:index 0
                          :id "call-1"
                          :function (:name "echo"
                                     :arguments "{\"text\":\"hi\"}"))]))
         (harness-openai-integration-test--finish "tool_calls")
         (list :usage (list :prompt_tokens 10 :completion_tokens 5)))
   ;; Second response: the final answer.
   (list (harness-openai-integration-test--chunk '(:content "The tool said hi."))
         (harness-openai-integration-test--finish "stop")
         (list :usage (list :prompt_tokens 25 :completion_tokens 7)))))

(defun harness-openai-integration-test--start-server ()
  "Start a canned server answering chat completions with the scripted turns."
  (let ((queue (harness-openai-integration-test--responses)))
    (harness-test-http-server
     (lambda (process request)
       (push request harness-openai-integration-test--requests)
       (let ((payloads (or (pop queue) (list "[DONE]"))))
         ;; Close after the response so the close-delimited client resolves.
         (run-at-time 0.1 nil
                      (lambda ()
                        (when (process-live-p process)
                          (delete-process process))))
         (list (harness-openai-integration-test--sse payloads)))))))

(defun harness-openai-integration-test--update-kinds (updates)
  "sessionUpdate kinds of UPDATES, oldest first."
  (mapcar (lambda (params)
            (plist-get (plist-get params :update) :sessionUpdate))
          (reverse updates)))

(defun harness-openai-integration-test--update-text (updates)
  "All text in UPDATES, oldest first."
  (mapconcat (lambda (params)
               (let ((content (plist-get (plist-get params :update) :content)))
                 (if (vectorp content)
                     (or (plist-get (aref content 0) :text) "")
                   (or (plist-get content :text) ""))))
             (reverse updates) ""))

(ert-deftest harness-openai-full-turn ()
  (let* ((harness-session-storage-directory (make-temp-file "harness-openai-" t))
         (directory (make-temp-file "harness-openai-project-" t))
         (harness-openai-integration-test--requests nil)
         (server nil)
         (pair nil)
         (updates nil))
    (unwind-protect
        (progn
          (clrhash harness-session--active)
          (clrhash harness-session--project-ids)
          (harness-tool-register
           "echo"
           :description "Echo text."
           :schema '(:type "object" :properties (:text (:type "string")) :required ["text"])
           :kind 'read :read-only t :module 'harness-openai-integration-test
           :handler (lambda (arguments _context) (format "echo:%s" (plist-get arguments :text))))
          (setq server (harness-openai-integration-test--start-server))
          (harness-provider-openai-register-instance
           (list :name "test-openai"
                 :base-url (format "http://127.0.0.1:%s/v1" (process-contact server :service))
                 :api-key "test-key"
                 :models '(("mock-model" :context-window 5000
                            :input-price 1.0 :output-price 2.0))))
          (setq pair (harness-acp-inprocess-pair))
          (harness-acp-connection-register-method
           (cdr pair) "session/update"
           (lambda (_connection params) (push params updates)))
          (let ((client (cdr pair)))
            (let ((deferred (harness-acp-connection-request
                             client "initialize" (list :protocolVersion 1))))
              (harness-test-settle deferred 5)
              (should (harness-deferred-resolved-p deferred)))
            (let* ((deferred (harness-acp-connection-request
                              client "session/new" (list :cwd directory :mcpServers [])))
                   (created (progn (harness-test-settle deferred 5)
                                   (harness-deferred-value deferred)))
                   (session-id (plist-get created :sessionId)))
              (should session-id)
              (let ((config (harness-acp-connection-request
                             client "session/set_config_option"
                             (list :sessionId session-id :configId "model"
                                   :value "test-openai/mock-model"))))
                (harness-test-settle config 5))
              (let ((prompt (harness-acp-connection-request
                             client "session/prompt"
                             (list :sessionId session-id
                                   :prompt (vector (list :type "text"
                                                         :text "use the tool"))))))
                (harness-test-settle prompt 20)
                (should (harness-deferred-resolved-p prompt))
                (should (equal (plist-get (harness-deferred-value prompt) :stopReason)
                               "end_turn")))
              ;; The canned server saw both completion requests.  A third
              ;; request may follow for automatic session naming.
              (should (<= 2 (length harness-openai-integration-test--requests)))
              (let* ((with-tool-result
                      (seq-find (lambda (request)
                                  (string-match-p "\"role\":\"tool\"" request))
                                (reverse harness-openai-integration-test--requests)))
                     (body (progn
                             (string-match "\r\n\r\n" with-tool-result)
                             (json-parse-string
                              (substring with-tool-result (match-end 0))
                              :object-type 'plist)))
                     (messages (append (plist-get body :messages) nil))
                     (tool-message (seq-find (lambda (message)
                                               (equal (plist-get message :role) "tool"))
                                             messages)))
                (should with-tool-result)
                (should tool-message)
                (should (equal (plist-get tool-message :tool_call_id) "call-1"))
                (should (string-match-p "echo:hi" (plist-get tool-message :content))))
              (let ((kinds (harness-openai-integration-test--update-kinds updates)))
                (should (member "tool_call" kinds))
                (should (member "tool_call_update" kinds))
                (should (member "agent_message_chunk" kinds)))
              (should (string-match-p "The tool said hi\\."
                                      (harness-openai-integration-test--update-text updates)))
              (let ((info (harness-service-call "session" 'info :session-id session-id)))
                (should (= (plist-get (plist-get info :usage) :input) 35))
                (should (= (plist-get (plist-get info :usage) :output) 12))
                (should (< 0 (plist-get (plist-get info :cost) :amount))))))
      (when pair (harness-acp-connection-close (car pair) "test over"))
      (harness-tool-unregister "echo")
      (harness-provider-unregister "test-openai")
      (harness-test-http-cleanup)
      (ignore-errors (delete-directory directory t))))))

(provide 'harness-openai-integration-test)
;;; harness-openai-integration-test.el ends here
