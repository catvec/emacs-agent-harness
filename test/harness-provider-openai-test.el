;;; harness-provider-openai-test.el --- Tests for the OpenAI provider -*- lexical-binding: t; -*-

;;; Commentary:

;; The provider is tested against a canned HTTP server: real socket, real
;; SSE parsing, no network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'harness-core)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-test-helpers)

(harness-module-load 'harness-provider)
(harness-module-load 'harness-provider-openai)

(defvar harness-provider-openai-test--requests nil
  "Requests captured by the canned server, oldest first.")

(defmacro harness-provider-openai-test--with-server (responder &rest body)
  "Run BODY with a canned server and a test provider instance.
RESPONDER is called with (PROCESS REQUEST) and returns response parts.
Inside BODY, `test-base-url' is bound to the instance URL."
  (declare (indent 1))
  `(unwind-protect
       (let* ((harness-provider-openai-test--requests nil)
              (server (harness-test-http-server
                       (lambda (process request)
                         (push request harness-provider-openai-test--requests)
                         (funcall ,responder process request))))
              (test-base-url (format "http://127.0.0.1:%s/v1"
                                     (process-contact server :service))))
         ,@body)
     (harness-test-http-cleanup)))

(defun harness-provider-openai-test--sse (payloads)
  "Build an SSE response body from PAYLOADS (strings or plists)."
  (mapconcat (lambda (payload)
               (concat "data: "
                       (if (stringp payload) payload (json-serialize payload))
                       "\n\n"))
             payloads ""))

(defun harness-provider-openai-test--sse-response (payloads &optional headers)
  "Build an SSE HTTP response with PAYLOADS."
  (list (encode-coding-string
         (concat "HTTP/1.1 200 OK\r\n"
                 "Content-Type: text/event-stream\r\n"
                 "Cache-Control: no-cache\r\n"
                 (mapconcat (lambda (header) (format "%s: %s\r\n" (car header) (cdr header)))
                            headers)
                 "\r\n"
                 (harness-provider-openai-test--sse payloads))
         'utf-8)))

(defun harness-provider-openai-test--register (base-url &rest properties)
  "Register a test instance at BASE-URL with PROPERTIES."
  (harness-provider-openai-register-instance
   (append (list :name "test-openai"
                 :base-url base-url
                 :api-key "test-key"
                 :thinking-param "reasoning_effort"
                 :models '(("test-model" :context-window 1000
                            :input-price 1.0 :output-price 2.0)))
           properties)))

(defun harness-provider-openai-test--run (request)
  "Complete REQUEST and return the settled result, signalling on error."
  (let ((deferred (harness-provider-complete request)))
    (harness-test-settle deferred 5)
    (when (harness-deferred-rejected-p deferred)
      (signal 'harness-provider-error (list (harness-deferred-value deferred))))
    (harness-deferred-value deferred)))

(defun harness-provider-openai-test--split-request (request-string)
  "Split REQUEST-STRING into (HEADERS . BODY)."
  (if (string-match "\r\n\r\n" request-string)
      (cons (substring request-string 0 (match-beginning 0))
            (substring request-string (match-end 0)))
    (cons request-string "")))

(defun harness-provider-openai-test--last-body ()
  "Parse the body of the most recent captured request."
  (pcase-let* ((`(,_headers . ,body)
                (harness-provider-openai-test--split-request
                 (car harness-provider-openai-test--requests))))
    (json-parse-string body :object-type 'plist)))

(ert-deftest harness-provider-openai-streaming-happy-path ()
  (harness-provider-openai-test--with-server
      (lambda (process _request)
        (run-at-time 0.05 nil
                     (lambda () (when (process-live-p process) (delete-process process))))
        (harness-provider-openai-test--sse-response
         (list '(:choices [(:delta (:content "Hel"))])
               '(:choices [(:delta (:content "lo"))])
               '(:choices [(:delta (:reasoning_content "hm"))])
               '(:choices [(:delta (:tool_calls [(:index 0 :id "call_1"
                                                 :function (:name "read"
                                                            :arguments "{\"path\""))]))])
               '(:choices [(:delta (:tool_calls [(:index 0
                                                  :function (:arguments ":\"/tmp/x\"}"))]))])
               '(:choices [(:delta () :finish_reason "tool_calls")])
               '(:usage (:prompt_tokens 11 :completion_tokens 7
                         :prompt_tokens_details (:cached_tokens 3)))
               "[DONE]")))
    (harness-provider-openai-test--register test-base-url)
    (let* ((text nil)
           (thought nil)
           (tool-updates nil)
           (result (harness-provider-openai-test--run
                    (list :model "test-openai/test-model"
                          :system "Be brief."
                          :messages (vector (list :role "user"
                                                  :content (vector (list :type "text"
                                                                         :text "read x"))))
                          :tools (vector (list :name "read"
                                               :description "Read a file"
                                               :input-schema (list :type "object"
                                                                   :properties (list :path (list :type "string"))
                                                                   :required ["path"])))
                          :max-output-tokens 128
                          :thinking "high"
                          :on-text (lambda (delta) (setq text (concat text delta)))
                          :on-thought (lambda (delta) (setq thought (concat thought delta)))
                          :on-tool-call (lambda (call) (push call tool-updates))))))
      (should (equal text "Hello"))
      (should (equal thought "hm"))
      (should (equal (plist-get result :text) "Hello"))
      (should (equal (plist-get result :thinking) "hm"))
      (should (equal (plist-get result :stop-reason) "tool_use"))
      (should (= (length (plist-get result :tool-calls)) 1))
      (let ((call (aref (plist-get result :tool-calls) 0)))
        (should (equal (plist-get call :id) "call_1"))
        (should (equal (plist-get call :name) "read"))
        (should (equal (plist-get call :arguments) '(:path "/tmp/x"))))
      (should (equal (plist-get (plist-get result :usage) :input-tokens) 11))
      (should (equal (plist-get (plist-get result :usage) :output-tokens) 7))
      (should (equal (plist-get (plist-get result :usage) :cache-read) 3))
      ;; The request itself: model, system message, tools, streaming flags.
      (let ((body (harness-provider-openai-test--last-body)))
        (should (equal (plist-get body :model) "test-model"))
        (should (eq (plist-get body :stream) t))
        (should (equal (plist-get body :max_completion_tokens) 128))
        (should (equal (plist-get body :reasoning_effort) "high"))
        (should (equal (plist-get (aref (plist-get body :messages) 0) :role) "system"))
        (should (equal (plist-get (aref (plist-get body :messages) 0) :content) "Be brief."))
        (should (equal (plist-get (aref (plist-get body :messages) 1) :role) "user"))
        (should (equal (plist-get (aref (plist-get body :tools) 0) :type) "function"))
        (should (equal (plist-get (plist-get (aref (plist-get body :tools) 0) :function) :name)
                       "read"))))))

(ert-deftest harness-provider-openai-plain-text-stream ()
  (harness-provider-openai-test--with-server
      (lambda (process _request)
        (run-at-time 0.05 nil
                     (lambda () (when (process-live-p process) (delete-process process))))
        (harness-provider-openai-test--sse-response
         (list '(:choices [(:delta (:content "done") :finish_reason "stop")])
               "[DONE]")))
    (harness-provider-openai-test--register test-base-url)
    (let ((result (harness-provider-openai-test--run
                   (list :model "test-openai/test-model"
                         :messages (vector (list :role "user"
                                                 :content (vector (list :type "text"
                                                                        :text "hi"))))))))
      (should (equal (plist-get result :text) "done"))
      (should (equal (plist-get result :stop-reason) "end_turn"))
      (should-not (plist-get result :thinking))
      (should (= (length (plist-get result :tool-calls)) 0)))))

(ert-deftest harness-provider-openai-http-error-is-provider-error ()
  (harness-provider-openai-test--with-server
      (lambda (_process _request)
        (list (harness-test-http-response
               401 '() "{\"error\":{\"message\":\"Invalid API key\"}}")))
    (harness-provider-openai-test--register test-base-url)
    (let ((deferred (harness-provider-complete
                     (list :model "test-openai/test-model"
                           :messages (vector (list :role "user"
                                                   :content (vector (list :type "text"
                                                                          :text "hi"))))))))
      (harness-test-settle deferred 5)
      (should (harness-deferred-rejected-p deferred))
      (should (eq (car (harness-deferred-value deferred)) 'harness-provider-error))
      (should (string-match-p "Invalid API key"
                              (format "%S" (harness-deferred-value deferred)))))))

(ert-deftest harness-provider-openai-missing-key-is-provider-error ()
  (setenv "HARNESS_TEST_OPENAI_KEY" nil)
  (harness-provider-openai-register-instance
   '(:name "test-openai"
     :base-url "http://127.0.0.1:1/v1"
     :api-key-env "HARNESS_TEST_OPENAI_KEY"
     :models (("test-model"))))
  (let ((deferred (harness-provider-complete
                   (list :model "test-openai/test-model"
                         :messages (vector)))))
    (harness-test-settle deferred 2)
    (should (harness-deferred-rejected-p deferred))
    (should (string-match-p "HARNESS_TEST_OPENAI_KEY"
                            (format "%S" (harness-deferred-value deferred))))))

(ert-deftest harness-provider-openai-fetches-models-and-merges ()
  (harness-provider-openai-test--with-server
      (lambda (_process _request)
        (list (harness-test-http-response
               200 '() "{\"data\":[{\"id\":\"fetched-model\"}]}")))
    (let ((instance (list :name "test-openai"
                          :base-url test-base-url
                          :api-key "test-key"
                          :fetch-models t
                          :models '(("static-model" :context-window 5)))))
      (let* ((deferred (harness-provider-openai--models instance))
             (models (progn (harness-test-settle deferred 5)
                            (harness-deferred-value deferred))))
        (should (equal (sort (mapcar (lambda (model) (plist-get model :model)) models)
                             #'string<)
                       '("fetched-model" "static-model")))))))

(ert-deftest harness-provider-openai-price ()
  (harness-provider-openai-test--with-server
      (lambda (_process _request) nil)
    (harness-provider-openai-test--register test-base-url)
    (let ((cost (harness-provider-price
                 "test-openai/test-model"
                 '(:input-tokens 1000000 :output-tokens 1000000 :cache-read 0))))
      (should (< (abs (- (plist-get cost :amount) 3.0)) 1e-9)))))

(ert-deftest harness-provider-openai-tool-result-conversion ()
  (let ((messages (harness-provider-messages-from-entries
                   (vector (list :sessionUpdate "tool_call" :toolCallId "c1" :name "bash"
                                 :rawInput "{}")
                           (list :sessionUpdate "tool_call_update" :toolCallId "c1"
                                 :status "completed"
                                 :content (vector (list :type "content"
                                                        :content (list :type "text"
                                                                       :text "output"))))))))
    (let* ((converted (harness-provider-openai--messages messages))
           (tool-message (aref converted 1)))
      (should (equal (plist-get tool-message :role) "tool"))
      (should (equal (plist-get tool-message :tool_call_id) "c1"))
      (should (equal (plist-get tool-message :content) "output"))
      (let ((call (aref (plist-get (aref converted 0) :tool_calls) 0)))
        (should (equal (plist-get call :id) "c1"))
        (should (equal (plist-get (plist-get call :function) :name) "bash"))))))

(provide 'harness-provider-openai-test)
;;; harness-provider-openai-test.el ends here
