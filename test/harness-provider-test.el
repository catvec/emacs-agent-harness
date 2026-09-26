;;; harness-provider-test.el --- Tests for the provider registry -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-provider)
(require 'harness-test-helpers)

(harness-module-load 'harness-provider)

(defun harness-provider-test--reset ()
  "Remove every provider a test registered."
  (dolist (name (hash-table-keys harness-provider--registry))
    (harness-provider-unregister name)))

(defun harness-provider-test--register-mock (&optional name)
  "Register a mock provider called NAME (default \"mock\")."
  (harness-provider-register
   (or name "mock")
   :description "Mock provider."
   :capabilities '(streaming tool-calls)
   :models (list (list :model "mock-model" :name "Mock Model"
                       :context-window 1000 :input-price 1.0 :output-price 2.0))
   :complete (lambda (request)
               (let ((deferred (harness-deferred-new)))
                 (when-let* ((on-text (plist-get request :on-text)))
                   (funcall on-text "hello"))
                 (harness-deferred-resolve
                  deferred (list :text "hello"
                                 :stop-reason "end_turn"
                                 :usage (list :input-tokens 10 :output-tokens 2)))))))

(ert-deftest harness-provider-register-get-list ()
  (harness-provider-test--reset)
  (harness-provider-test--register-mock)
  (should (harness-provider-get "mock"))
  (should (equal (harness-provider-name (harness-provider-get "mock")) "mock"))
  (should (member "mock" (mapcar #'harness-provider-name (harness-provider-list))))
  (harness-provider-unregister "mock")
  (should-not (harness-provider-get "mock")))

(ert-deftest harness-provider-resolve-model ()
  (should (equal (harness-provider-resolve "openai/gpt-5") '("openai" . "gpt-5")))
  (should (equal (harness-provider-resolve "openrouter/anthropic/claude")
                 '("openrouter" . "anthropic/claude")))
  (should-error (harness-provider-resolve "bare-model") :type 'harness-user-error))

(ert-deftest harness-provider-models-combines-providers ()
  (harness-provider-test--reset)
  (harness-provider-test--register-mock)
  (harness-provider-register
   "other"
   :description "Other provider."
   :models (let ((deferred (harness-deferred-new)))
             (run-at-time 0.01 nil
                          (lambda ()
                            (harness-deferred-resolve
                             deferred (list (list :model "other-model")))))
             deferred))
  (let* ((deferred (harness-provider-models))
         (models (progn (harness-test-settle deferred) (harness-deferred-value deferred))))
    (should (vectorp models))
    (should (= (length models) 2))
    (should (equal (sort (mapcar (lambda (model) (plist-get model :id)) (append models nil))
                         #'string<)
                   '("mock/mock-model" "other/other-model")))
    (let ((mock (seq-find (lambda (model) (equal (plist-get model :id) "mock/mock-model"))
                          (append models nil))))
      (should (equal (plist-get mock :provider) "mock"))
      (should (equal (plist-get mock :context-window) 1000))
      (should (= (plist-get mock :input-price) 1.0)))))

(ert-deftest harness-provider-complete-dispatch ()
  (harness-provider-test--reset)
  (harness-provider-test--register-mock)
  (let* ((text nil)
         (deferred (harness-provider-complete
                    (list :model "mock/mock-model"
                          :on-text (lambda (delta) (setq text (concat text delta))))))
         (result (progn (harness-test-settle deferred) (harness-deferred-value deferred))))
    (should (equal text "hello"))
    (should (equal (plist-get result :text) "hello"))
    (should (equal (plist-get result :stop-reason) "end_turn"))
    (should-error (harness-provider-complete (list :model "nope/model"))
                  :type 'harness-user-error)))

(ert-deftest harness-provider-estimate-tokens ()
  (should (= (harness-provider-estimate-tokens "") 0))
  (should (= (harness-provider-estimate-tokens "abcd") 1))
  (should (= (harness-provider-estimate-tokens "abcde") 2)))

(ert-deftest harness-provider-cost-from-prices ()
  (let ((cost (harness-provider-cost-from-prices
               '(:input 1.0 :output 2.0 :cache-read 0.1)
               '(:input-tokens 1000000 :output-tokens 1000000 :cache-read 1000000))))
    (should (< (abs (- (plist-get cost :amount) 3.1)) 1e-9))
    (should (equal (plist-get cost :currency) "USD")))
  (should-not (harness-provider-cost-from-prices nil '(:input-tokens 1))))

(ert-deftest harness-provider-price-uses-provider ()
  (harness-provider-test--reset)
  (harness-provider-register
   "priced"
   :description "Priced provider."
   :models '((:model "m" :input-price 10.0 :output-price 20.0))
   :price (lambda (_model _usage) '(:amount 0.5 :currency "USD")))
  (should (equal (harness-provider-price "priced/m" '(:input-tokens 1))
                 '(:amount 0.5 :currency "USD"))))

(ert-deftest harness-provider-messages-from-entries ()
  (let* ((entries
          (vector
           (list :sessionUpdate "user_message_chunk"
                 :content (list :type "text" :text "read the file"))
           (list :sessionUpdate "agent_thought_chunk"
                 :content (list :type "text" :text "thinking..."))
           (list :sessionUpdate "agent_message_chunk"
                 :content (list :type "text" :text "On it"))
           (list :sessionUpdate "tool_call" :toolCallId "call-1" :name "read"
                 :rawInput "{\"path\":\"/tmp/x\"}")
           (list :sessionUpdate "tool_call_update" :toolCallId "call-1" :status "completed"
                 :content (vector (list :type "content"
                                        :content (list :type "text" :text "file body"))))
           (list :sessionUpdate "_harness/system_hint"
                 :content (list :type "text" :text "model changed"))
           (list :sessionUpdate "usage_update" :used 10 :size 100)
           (list :sessionUpdate "user_message_chunk"
                 :content (list :type "text" :text "thanks"))))
         (messages (harness-provider-messages-from-entries entries)))
    (should (= (length messages) 4))
    ;; 1: user
    (should (equal (plist-get (aref messages 0) :role) "user"))
    ;; 2: assistant with thinking, text and the tool call
    (let ((assistant (aref messages 1)))
      (should (equal (plist-get assistant :role) "assistant"))
      (let ((types (mapcar (lambda (part) (plist-get part :type))
                           (append (plist-get assistant :content) nil))))
        (should (equal types '("thinking" "text" "tool-call"))))
      (let ((call (seq-find (lambda (part) (equal (plist-get part :type) "tool-call"))
                            (append (plist-get assistant :content) nil))))
        (should (equal (plist-get call :name) "read"))
        (should (equal (plist-get call :arguments) '(:path "/tmp/x")))))
    ;; 3: tool result
    (let ((tool (aref messages 2)))
      (should (equal (plist-get tool :role) "tool"))
      (let ((result (aref (plist-get tool :content) 0)))
        (should (equal (plist-get result :tool-call-id) "call-1"))
        (should-not (plist-get result :is-error))))
    ;; 4: the second user message; hints and usage never reach the model
    (should (equal (plist-get (aref messages 3) :role) "user"))
    (should (equal (plist-get (aref (plist-get (aref messages 3) :content) 0) :text)
                   "thanks"))))

(ert-deftest harness-provider-service-surface ()
  (harness-provider-test--reset)
  (harness-provider-test--register-mock)
  (let ((providers (harness-service-call "provider" 'list)))
    (should (vectorp providers))
    (should (equal (plist-get (aref providers 0) :name) "mock")))
  (let* ((models-deferred (harness-service-call "provider" 'models))
         (models (progn (harness-test-settle models-deferred)
                        (harness-deferred-value models-deferred))))
    (should (= (length models) 1)))
  (let* ((completion (harness-service-call "provider" 'complete :model "mock/mock-model"))
         (result (progn (harness-test-settle completion) (harness-deferred-value completion))))
    (should (equal (plist-get result :text) "hello")))
  (should (= (harness-service-call "provider" 'count-tokens
                                   :model "mock/mock-model" :text "abcd")
             1)))

(provide 'harness-provider-test)
;;; harness-provider-test.el ends here
