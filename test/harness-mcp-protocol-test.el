;;; harness-mcp-protocol-test.el --- The MCP messages and the server dispatcher  -*- lexical-binding: t; -*-

;;; Commentary:

;; lisp/harness-mcp-protocol.el is the part of the Model Context
;; Protocol the harness's servers and its host share: the messages,
;; the line framing, the results of a tool call and a dispatcher that
;; answers one decoded message.  Nothing here starts a process.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-mcp-protocol)

(defun harness-mcp-protocol-test--server (&rest tools)
  "Return a server named \"test\" with TOOLS, a list of (NAME . HANDLER)."
  (harness-mcp-make-server
   :name "test" :title "Test" :version "9" :instructions "Be careful."
   :tools (mapcar (lambda (entry)
                    (harness-mcp-make-tool :name (car entry) :title (upcase (car entry))
                                           :description (format "The %s tool." (car entry))
                                           :schema '(:type "object" :properties (:x (:type "string")))
                                           :handler (cdr entry)))
                  tools)))

(defun harness-mcp-protocol-test--serve (server method &optional params transport)
  "Send METHOD with PARAMS to SERVER as request 7; return the response."
  (let ((response (harness-mcp-serve server (harness-mcp-request 7 method params) transport)))
    (if (harness-promise-p response) (harness-test-await response) response)))

;;;; Messages and framing

(ert-deftest harness-mcp-protocol-messages-have-the-shape-json-rpc-wants ()
  (should (equal '(:jsonrpc "2.0" :id 1 :method "ping") (harness-mcp-request 1 "ping")))
  (should (equal '(:jsonrpc "2.0" :id "a" :method "m" :params (:k 1)) (harness-mcp-request "a" "m" '(:k 1))))
  (should (equal '(:jsonrpc "2.0" :method "notifications/initialized")
                 (harness-mcp-notification "notifications/initialized")))
  (should (equal '(:jsonrpc "2.0" :id 3 :result (:ok t)) (harness-mcp-response 3 '(:ok t))))
  ;; Nothing to say is the empty object, never null.
  (should (equal '(:jsonrpc "2.0" :id 3 :result :empty) (harness-mcp-response 3 nil)))
  (should (equal '(:jsonrpc "2.0" :id 4 :error (:code -32601 :message "no" :data (:why "x")))
                 (harness-mcp-error-response 4 -32601 "no" '(:why "x"))))
  (should (equal '(:jsonrpc "2.0" :id nil :error (:code -32700 :message "bad"))
                 (harness-mcp-error-response nil -32700 "bad"))))

(ert-deftest harness-mcp-protocol-tells-what-a-message-is ()
  (should (eq 'request (harness-mcp-message-kind (harness-mcp-request 0 "ping"))))
  (should (eq 'notification (harness-mcp-message-kind (harness-mcp-notification "x"))))
  (should (eq 'result (harness-mcp-message-kind (harness-mcp-response 1 '(:a 1)))))
  (should (eq 'error (harness-mcp-message-kind (harness-mcp-error-response 1 -1 "m"))))
  (should (eq 'error (harness-mcp-message-kind (harness-mcp-error-response nil -32700 "m"))))
  (should-not (harness-mcp-message-kind '(:jsonrpc "2.0")))
  (should-not (harness-mcp-message-kind nil))
  (should-not (harness-mcp-message-kind "text")))

(ert-deftest harness-mcp-protocol-a-line-carries-one-message-whatever-its-text ()
  (let* ((message (harness-mcp-request 5 "tools/call"
                                       (list :name "t" :arguments (list :text "one\ntwo\r\nthree ✓ 日本 \"q\" \\"))))
         (line (harness-mcp-encode-line message)))
    (should (string-suffix-p "\n" line))
    (should (= 1 (cl-count ?\n line)))
    (let ((back (harness-mcp-decode-line (string-trim-right line "\n"))))
      (should (equal 5 (plist-get back :id)))
      (should (equal "one\ntwo\r\nthree ✓ 日本 \"q\" \\"
                     (plist-get (plist-get (plist-get back :params) :arguments) :text))))))

(ert-deftest harness-mcp-protocol-refuses-what-is-not-a-message ()
  (should-error (harness-mcp-decode-line "not json at all") :type 'error)
  (should-error (harness-mcp-decode-line "[1,2,3]") :type 'error)
  (should-error (harness-mcp-decode-line "{\"hello\":1}") :type 'error)
  (should-error (harness-mcp-decode-line "") :type 'error))

;;;; Results

(ert-deftest harness-mcp-protocol-call-results-read-back ()
  (let ((ok (harness-mcp-call-result "fine"))
        (bad (harness-mcp-call-result "broke" :is-error t :structured '(:n 1))))
    (should (equal "fine" (harness-mcp-result-text ok)))
    (should-not (harness-mcp-result-error-p ok))
    (should (harness-mcp-result-error-p bad))
    (should (equal '(:n 1) (harness-mcp-result-structured bad)))
    (should (equal "a\nb" (harness-mcp-result-text
                           '(:content ((:type "text" :text "a") (:type "image" :data "x" :mimeType "image/png")
                                       (:type "text" :text "b"))))))))

(ert-deftest harness-mcp-protocol-a-tool-result-crosses-with-everything-it-holds ()
  (let* ((result (list :content "line one\nline two" :is-error nil
                       :attachments (list (list :path "/tmp/a.png" :mime "image/png" :size 12 :name "a.png"))
                       :images (list (list :path "/tmp/a.png" :mime "image/png"))
                       :meta (list :exit 0 :duration 0.5)))
         (wire (harness-mcp-decode-line (string-trim-right
                                         (harness-mcp-encode-line
                                          (harness-mcp-response 1 (harness-mcp-tool-result-to-call-result result)))
                                         "\n")))
         (back (harness-mcp-call-result-to-tool-result (plist-get wire :result))))
    (should (equal "line one\nline two" (plist-get back :content)))
    (should-not (plist-get back :is-error))
    (should (equal "/tmp/a.png" (plist-get (car (plist-get back :attachments)) :path)))
    (should (equal "image/png" (plist-get (car (plist-get back :images)) :mime)))
    (should (equal 0 (plist-get (plist-get back :meta) :exit)))
    ;; The text is where MCP puts text, so any client reads it.
    (should (equal "line one\nline two" (harness-mcp-result-text (plist-get wire :result)))))
  (let ((back (harness-mcp-call-result-to-tool-result
               (harness-mcp-tool-result-to-call-result (list :content "no" :is-error t)))))
    (should (plist-get back :is-error))))

(ert-deftest harness-mcp-protocol-a-result-from-another-server-is-read-as-text ()
  (let ((back (harness-mcp-call-result-to-tool-result
               '(:content ((:type "text" :text "hi") (:type "image" :data "AAAA" :mimeType "image/png"))
                 :isError :false :structuredContent (:rows 3)))))
    (should (string-prefix-p "hi" (plist-get back :content)))
    (should (string-search "1 non-text block omitted" (plist-get back :content)))
    (should (equal '(:rows 3) (plist-get back :structured)))
    (should-not (plist-get back :is-error))))

;;;; The dispatcher

(ert-deftest harness-mcp-protocol-initialize-negotiates-the-version ()
  (let* ((server (harness-mcp-protocol-test--server))
         (new (harness-mcp-protocol-test--serve server "initialize" '(:protocolVersion "2024-11-05")))
         (odd (harness-mcp-protocol-test--serve server "initialize" '(:protocolVersion "1999-01-01"))))
    (should (equal 7 (plist-get new :id)))
    (should (equal "2024-11-05" (plist-get (plist-get new :result) :protocolVersion)))
    (should (equal harness-mcp-protocol-version (plist-get (plist-get odd :result) :protocolVersion)))
    (let ((result (plist-get new :result)))
      (should (equal "test" (plist-get (plist-get result :serverInfo) :name)))
      (should (equal "9" (plist-get (plist-get result :serverInfo) :version)))
      (should (equal "Be careful." (plist-get result :instructions)))
      (should (plist-member (plist-get result :capabilities) :tools)))))

(ert-deftest harness-mcp-protocol-lists-its-tools-with-their-schemas ()
  (let* ((server (harness-mcp-protocol-test--server (cons "one" #'ignore) (cons "two" #'ignore)))
         (tools (plist-get (plist-get (harness-mcp-protocol-test--serve server "tools/list") :result) :tools)))
    (should (equal '("one" "two") (mapcar (lambda (tool) (plist-get tool :name)) tools)))
    (should (equal "object" (plist-get (plist-get (car tools) :inputSchema) :type)))
    (should (equal "ONE" (plist-get (car tools) :title)))
    (should (equal "The one tool." (plist-get (car tools) :description)))))

(ert-deftest harness-mcp-protocol-calls-a-tool-and-answers-what-it-returns ()
  (let* ((seen nil)
         (server (harness-mcp-protocol-test--server
                  (cons "echo" (lambda (arguments context)
                                 (setq seen (list arguments (plist-get context :request-id)))
                                 (format "got %s" (plist-get arguments :x))))
                  (cons "result" (lambda (_arguments _context)
                                   (list :content "plain" :is-error nil :attachments (list (list :path "/p")))))
                  (cons "block" (lambda (_arguments _context)
                                  (harness-mcp-call-result "as a block" :is-error t)))))
         (call (lambda (name) (plist-get (harness-mcp-protocol-test--serve
                                          server "tools/call" (list :name name :arguments '(:x "hi")))
                                         :result))))
    (should (equal "got hi" (harness-mcp-result-text (funcall call "echo"))))
    (should (equal '((:x "hi") 7) seen))
    (let ((r (funcall call "result")))
      (should (equal "plain" (harness-mcp-result-text r)))
      (should (equal "/p" (plist-get (car (plist-get (harness-mcp-call-result-to-tool-result r) :attachments)) :path))))
    (let ((r (funcall call "block")))
      (should (harness-mcp-result-error-p r))
      (should (equal "as a block" (harness-mcp-result-text r))))))

(ert-deftest harness-mcp-protocol-a-failing-tool-is-a-result-and-an-unknown-one-an-error ()
  (let* ((server (harness-mcp-protocol-test--server (cons "boom" (lambda (&rest _) (error "It broke: %s" "badly")))))
         (failed (harness-mcp-protocol-test--serve server "tools/call" '(:name "boom")))
         (unknown (harness-mcp-protocol-test--serve server "tools/call" '(:name "nope")))
         (method (harness-mcp-protocol-test--serve server "resources/list")))
    (should (harness-mcp-result-error-p (plist-get failed :result)))
    (should (string-search "It broke: badly" (harness-mcp-result-text (plist-get failed :result))))
    (should (equal harness-mcp-error-invalid-params (plist-get (plist-get unknown :error) :code)))
    (should (string-search "nope" (plist-get (plist-get unknown :error) :message)))
    (should (equal harness-mcp-error-method-not-found (plist-get (plist-get method :error) :code)))
    (should (equal 7 (plist-get method :id)))))

(ert-deftest harness-mcp-protocol-a-tool-may-answer-later ()
  (let* ((promise (harness-make-promise))
         (server (harness-mcp-protocol-test--server
                  (cons "later" (lambda (&rest _) promise))
                  (cons "rejects" (lambda (&rest _) (harness-rejected '(error "Nope"))))))
         (response (harness-mcp-serve server (harness-mcp-request 9 "tools/call" '(:name "later")))))
    (should (harness-promise-p response))
    (should-not (harness-promise-settled-p response))
    (harness-resolve promise "done at last")
    (let ((message (harness-test-await response)))
      (should (equal 9 (plist-get message :id)))
      (should (equal "done at last" (harness-mcp-result-text (plist-get message :result)))))
    (let ((message (harness-mcp-protocol-test--serve server "tools/call" '(:name "rejects"))))
      (should (harness-mcp-result-error-p (plist-get message :result)))
      (should (string-search "Nope" (harness-mcp-result-text (plist-get message :result)))))))

(ert-deftest harness-mcp-protocol-progress-goes-out-only-when-asked-for ()
  (let* ((sent nil)
         (server (harness-mcp-protocol-test--server
                  (cons "slow" (lambda (_arguments context)
                                 (funcall (plist-get context :progress) 1 4 "a quarter")
                                 "done")))))
    (harness-mcp-protocol-test--serve server "tools/call" '(:name "slow" :_meta (:progressToken "tok"))
                                      (list :notify (lambda (message) (push message sent))))
    (should (= 1 (length sent)))
    (let ((params (plist-get (car sent) :params)))
      (should (equal "notifications/progress" (plist-get (car sent) :method)))
      (should (equal "tok" (plist-get params :progressToken)))
      (should (equal 1 (plist-get params :progress)))
      (should (equal 4 (plist-get params :total)))
      (should (equal "a quarter" (plist-get params :message))))
    (setq sent nil)
    ;; No token, no notification; and no transport, no harm.
    (harness-mcp-protocol-test--serve server "tools/call" '(:name "slow") (list :notify (lambda (m) (push m sent))))
    (harness-mcp-protocol-test--serve server "tools/call" '(:name "slow" :_meta (:progressToken "t")))
    (should-not sent)))

(ert-deftest harness-mcp-protocol-notifications-get-no-answer ()
  (let ((server (harness-mcp-protocol-test--server)))
    (should-not (harness-mcp-server-initialized server))
    (should-not (harness-mcp-serve server (harness-mcp-notification "notifications/initialized")))
    (should (harness-mcp-server-initialized server))
    (should-not (harness-mcp-cancelled-p server 4))
    (should-not (harness-mcp-serve server (harness-mcp-notification "notifications/cancelled" '(:requestId 4))))
    (should (harness-mcp-cancelled-p server 4))
    (should-not (harness-mcp-serve server (harness-mcp-notification "notifications/unheard-of")))
    ;; A response is not for a server to answer.
    (should-not (harness-mcp-serve server (harness-mcp-response 1 nil)))))

(ert-deftest harness-mcp-protocol-ping-answers-with-the-empty-object ()
  (let ((response (harness-mcp-protocol-test--serve (harness-mcp-protocol-test--server) "ping")))
    (should (equal :empty (plist-get response :result)))
    (should (equal "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}"
                   (string-trim-right (harness-mcp-encode-line response) "\n")))))

(provide 'harness-mcp-protocol-test)
;;; harness-mcp-protocol-test.el ends here
