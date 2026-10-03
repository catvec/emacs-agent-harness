;;; harness-provider-bedrock-test.el --- Tests for the AWS Bedrock provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; Signature Version 4 is checked against AWS's published test suite
;; and the event stream decoder against AWS's test vectors (both in
;; test/fixtures).  Unit tests drive the provider through a fake
;; `harness-http-request' replaying canned ConverseStream bytes; the
;; end-to-end tests go through curl to the mock endpoint of
;; harness-bedrock-mock.el, which checks every signature, and one runs
;; a whole agent turn with a tool call against it.  Integration tests
;; (tag `integration', HARNESS_INTEGRATION=1 and AWS credentials) talk
;; to Bedrock itself.

;;; Code:

(require 'harness-test-helpers)
(require 'auth-source)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-bedrock)
(require 'harness-bedrock-mock)

;;;; Isolation

(defmacro harness-bedrock-test-with-env (vars &rest body)
  "Run BODY without the AWS settings of the real environment, then with VARS.
VARS is a list of (NAME VALUE) as for `with-environment-variables'."
  (declare (indent 1))
  `(let ((harness-bedrock--aws-program nil)
         (auth-sources nil)
         (harness-bedrock--max-retries 3))
     (with-environment-variables
         (("AWS_ACCESS_KEY_ID" nil) ("AWS_SECRET_ACCESS_KEY" nil) ("AWS_SESSION_TOKEN" nil)
          ("AWS_PROFILE" nil) ("AWS_DEFAULT_PROFILE" nil) ("AWS_REGION" nil) ("AWS_DEFAULT_REGION" nil)
          ("AWS_BEARER_TOKEN_BEDROCK" nil)
          ("AWS_CONFIG_FILE" "/nonexistent/harness-bedrock-test/config")
          ("AWS_SHARED_CREDENTIALS_FILE" "/nonexistent/harness-bedrock-test/credentials")
          ("AWS_ENDPOINT_URL_BEDROCK_RUNTIME" nil) ("AWS_ENDPOINT_URL_BEDROCK" nil)
          ("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" nil) ("AWS_CONTAINER_CREDENTIALS_FULL_URI" nil)
          ("AWS_WEB_IDENTITY_TOKEN_FILE" nil))
       (with-environment-variables ,(or vars '(("HARNESS_BEDROCK_TEST" "1")))
         (clrhash harness-bedrock--kept-keys)
         (clrhash harness-bedrock--quirks)
         (clrhash harness-bedrock--responses)
         ,@body))))

(defmacro harness-bedrock-test-with-keys (&rest body)
  "Run BODY with the AWS documentation's example keys in the environment."
  (declare (indent 0))
  `(harness-bedrock-test-with-env (("AWS_ACCESS_KEY_ID" ,harness-bedrock-mock-key-id)
                                   ("AWS_SECRET_ACCESS_KEY" ,harness-bedrock-mock-key-secret))
     ,@body))

;;;; Fake HTTP layer

(defvar harness-bedrock-test--requests nil
  "Requests the fake HTTP layer saw, newest first: (:url :method :headers :body :json :args).")

(defvar harness-bedrock-test--responses nil
  "List of (URL-REGEXP . RESPONSE) the fake answers from.
The first entry whose regexp matches answers.  It is used up when a
later entry matches too, so entries for one URL answer in turn.
RESPONSE is (:status N :headers ALIST :chunks (BYTES ...)), (:status N
:body STRING), (:error ERR) for a transport failure, or (:hang t).")

(defun harness-bedrock-test--fake-request (url &rest args)
  "Record a request to URL with ARGS and answer it from the canned responses."
  (let* ((cell (cl-find-if (lambda (c) (string-match-p (car c) url)) harness-bedrock-test--responses))
         (response (cdr cell))
         (body (plist-get args :body))
         (handle (make-harness-http-handle :url url :callback (plist-get args :callback)
                                           :on-chunk (plist-get args :on-chunk) :started (float-time))))
    (when (and cell (cl-find-if (lambda (c) (string-match-p (car c) url))
                                (cdr (memq cell harness-bedrock-test--responses))))
      (setq harness-bedrock-test--responses (delq cell harness-bedrock-test--responses)))
    (push (list :url url :method (or (plist-get args :method) "GET") :headers (plist-get args :headers)
                :body body
                :json (and body (ignore-errors (harness-json-parse (decode-coding-string body 'utf-8))))
                :args args)
          harness-bedrock-test--requests)
    (unless (or (null response) (plist-get response :hang))
      (harness-run-soon
       (lambda ()
         (unless (harness-http-handle-cancelled handle)
           (if (plist-get response :error)
               (funcall (plist-get args :callback) nil nil "" (plist-get response :error))
             (let ((status (or (plist-get response :status) 200))
                   (headers (plist-get response :headers)))
               (when (plist-get args :on-headers)
                 (funcall (plist-get args :on-headers) status headers))
               (if (plist-get args :on-chunk)
                   (progn
                     (dolist (chunk (or (plist-get response :chunks) (list (or (plist-get response :body) ""))))
                       (funcall (plist-get args :on-chunk) chunk))
                     (funcall (plist-get args :callback) status headers "" nil))
                 (funcall (plist-get args :callback) status headers (or (plist-get response :body) "") nil))))))))
    handle))

(defmacro harness-bedrock-test-with-fake (responses &rest body)
  "Run BODY with `harness-http-request' replaced by a fake serving RESPONSES."
  (declare (indent 1))
  `(let ((harness-bedrock-test--requests nil)
         (harness-bedrock-test--responses (copy-sequence ,responses)))
     (cl-letf (((symbol-function 'harness-http-request) #'harness-bedrock-test--fake-request))
       ,@body)))

(defvar harness-bedrock-test-endpoint '(:id testrock :label "Test Bedrock" :region "us-east-1")
  "An endpoint for unit tests, at the regional AWS URL.")

(defconst harness-bedrock-test-sonnet "anthropic.claude-sonnet-4-5-20250929-v1:0"
  "A model whose defaults are known: budget thinking, caching, 64k output.")

(defun harness-bedrock-test--complete (endpoint request &optional timeout)
  "Run REQUEST against ENDPOINT, collecting events until `done'.
Return (EVENTS . HANDLE), EVENTS oldest first."
  (let* ((events nil)
         (request (plist-put (copy-sequence request) :on-event (lambda (e) (push e events))))
         (handle (harness-bedrock--complete endpoint request)))
    (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type))))
                       (or timeout 5) "done event")
    (cons (reverse events) handle)))

(defun harness-bedrock-test--types (events)
  "Return the `:type' of every event in EVENTS."
  (mapcar (lambda (e) (plist-get e :type)) events))

(defun harness-bedrock-test--text (events)
  "Concatenate the text deltas in EVENTS."
  (mapconcat (lambda (e) (if (eq (plist-get e :type) 'text) (plist-get e :delta) "")) events ""))

(defun harness-bedrock-test--chunks (bytes size)
  "Split BYTES into chunks of SIZE bytes."
  (harness-bedrock-mock--pieces bytes size))

(defun harness-bedrock-test--request (text)
  "Return a request for the Sonnet model whose user says TEXT."
  (list :model (concat "testrock:" harness-bedrock-test-sonnet)
        :messages `((:role user :content ((:type "text" :text ,text))))))

;;;; Crypto primitives

(ert-deftest harness-provider-bedrock-crypto-primitives ()
  (should (equal "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                 (harness-bedrock--sha256 "")))
  ;; RFC 4231, test cases 1, 2 and 6 (a key longer than the block).
  (should (equal "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
                 (harness-bedrock--hex (harness-bedrock--hmac (make-string 20 #x0b) "Hi There"))))
  (should (equal "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
                 (harness-bedrock--hex (harness-bedrock--hmac "Jefe" "what do ya want for nothing?"))))
  (should (equal "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
                 (harness-bedrock--hex
                  (harness-bedrock--hmac (apply #'unibyte-string (make-list 131 #xaa))
                                         "Test Using Larger Than Block-Size Key - Hash Key First"))))
  ;; The CRC-32 check value, and multibyte text hashes as UTF-8.
  (should (= #xCBF43926 (harness-bedrock--crc32 "123456789")))
  (should (equal (harness-bedrock--sha256 (encode-coding-string "héllo" 'utf-8))
                 (harness-bedrock--sha256 "héllo"))))

;;;; Signature Version 4

(defun harness-bedrock-test--read (file)
  "Return the text of FILE, read as UTF-8."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
    (buffer-string)))

(defun harness-bedrock-test--parse-request (text)
  "Parse the HTTP request TEXT of the test suite into (METHOD PATH HEADERS BODY).
Folded header lines continue the header above them."
  (let* ((split (string-search "\n\n" text))
         (head (if split (substring text 0 split) (string-trim-right text "\n+")))
         (body (if split (substring text (+ split 2)) ""))
         (lines (split-string head "\n"))
         (request-line (car lines))
         (method (car (split-string request-line " ")))
         (path (substring request-line (1+ (length method)) (string-match " HTTP/[0-9.]+\\'" request-line)))
         (headers nil))
    (dolist (line (cdr lines))
      (if (and headers (string-match-p "\\`[ \t]" line))
          (setcdr (car headers) (concat (cdar headers) "\n" line))
        (when (string-match "\\`\\([^:]+\\):\\(.*\\)\\'" line)
          (push (cons (match-string 1 line) (match-string 2 line)) headers))))
    (list method path (nreverse headers) body)))

(ert-deftest harness-provider-bedrock-sigv4-aws-test-suite ()
  "Every case of the AWS Signature Version 4 test suite signs as published."
  (let ((root (harness-test-fixture "aws-sigv4"))
        (cases 0))
    (dolist (dir (directory-files root t "\\`[a-z]"))
      (when (file-directory-p dir)
        (pcase-let* ((read (lambda (name) (harness-bedrock-test--read (expand-file-name name dir))))
                     (`(,method ,path ,headers ,body) (harness-bedrock-test--parse-request (funcall read "request.txt")))
                     (context (json-parse-string (funcall read "context.json")
                                                 :object-type 'plist :null-object nil :false-object nil))
                     (keys (plist-get context :credentials))
                     (signed (harness-bedrock-sigv4
                              :method method :url (concat "https://example.amazonaws.com" path)
                              :headers headers :body body
                              :access-key-id (plist-get keys :access_key_id)
                              :secret-access-key (plist-get keys :secret_access_key)
                              :session-token (and (not (plist-get context :omit_session_token))
                                                  (plist-get keys :token))
                              :region (plist-get context :region)
                              :service (plist-get context :service)
                              :time (parse-iso8601-time-string (plist-get context :timestamp))
                              :sign-body (plist-get context :sign_body)))
                     (authorization (and (string-match "^Authorization:\\(.*\\)$" (funcall read "header-signed-request.txt"))
                                         (match-string 1 (funcall read "header-signed-request.txt")))))
          (ert-info ((file-name-nondirectory dir) :prefix "case: ")
            (should (equal (funcall read "header-canonical-request.txt") (plist-get signed :canonical-request)))
            (should (equal (funcall read "header-string-to-sign.txt") (plist-get signed :string-to-sign)))
            (should (equal (string-trim (funcall read "header-signature.txt")) (plist-get signed :signature)))
            (should (equal authorization (cdr (assoc "Authorization" (plist-get signed :headers))))))
          (cl-incf cases))))
    (should (>= cases 30))))

(ert-deftest harness-provider-bedrock-sigv4-signing-key-and-bedrock-urls ()
  ;; The key derivation example of the AWS documentation.
  (should (equal "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d"
                 (harness-bedrock--hex (harness-bedrock--signing-key
                                        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" "20120215" "us-east-1" "iam"))))
  ;; A model id's colon is escaped in the path and signed escaped twice.
  (let* ((url "https://bedrock-runtime.us-east-1.amazonaws.com/model/us.anthropic.claude-sonnet-4-5-20250929-v1%3A0/converse-stream")
         (signed (harness-bedrock-sigv4 :method "POST" :url url :headers '(("Content-Type" . "application/json"))
                                        :body "{}" :access-key-id "AKID" :secret-access-key "SECRET"
                                        :session-token "TOKEN" :region "us-east-1" :service "bedrock"
                                        :time (parse-iso8601-time-string "2026-10-01T12:00:00Z")))
         (canonical (plist-get signed :canonical-request)))
    (should (string-prefix-p "POST\n/model/us.anthropic.claude-sonnet-4-5-20250929-v1%253A0/converse-stream\n\n"
                             canonical))
    (should (string-match-p "^host:bedrock-runtime.us-east-1.amazonaws.com$" canonical))
    (should (string-match-p "^x-amz-security-token:TOKEN$" canonical))
    (should (string-suffix-p (concat "\ncontent-type;host;x-amz-date;x-amz-security-token\n"
                                     (harness-bedrock--sha256 "{}"))
                             canonical))
    (should (equal '("Host" "X-Amz-Date" "X-Amz-Security-Token" "Authorization")
                   (mapcar #'car (plist-get signed :headers))))
    (should (string-match-p "\\`AWS4-HMAC-SHA256 Credential=AKID/20261001/us-east-1/bedrock/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, Signature=[0-9a-f]\\{64\\}\\'"
                            (cdr (assoc "Authorization" (plist-get signed :headers))))))
  (should (equal "arn%3Aaws%3Abedrock%3Aus-east-1%3A123456789012%3Aapplication-inference-profile%2Fabc"
                 (harness-bedrock--uri-encode "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/abc")))
  (should (equal "maxResults=1000&nextToken=a%2Fb%3D&type=SYSTEM_DEFINED"
                 (harness-bedrock--canonical-query "type=SYSTEM_DEFINED&maxResults=1000&nextToken=a%2Fb%3D")))
  (should (equal "127.0.0.1:8080" (harness-bedrock--host-header "http://127.0.0.1:8080/model")))
  (should (equal "gateway.example.com" (harness-bedrock--host-header "https://gateway.example.com:443/x")))
  (should (equal "/base/model/" (harness-bedrock--normalize-path "/base//model/./")))
  (should (equal '("https" "h.example" 8443 "/a/b" "q=1") (harness-bedrock--split-url "https://H.example:8443/a/b?q=1"))))

;;;; Event streams

(defun harness-bedrock-test--bytes (file)
  "Return the bytes of FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun harness-bedrock-test--expected-header-value (header)
  "Return the value the decoder should give for HEADER of a decoded vector."
  (let ((value (plist-get header :value)))
    (pcase (plist-get header :type)
      (0 t)
      (1 :false)
      ((or 6 7 9) (base64-decode-string value))
      (_ value))))

(ert-deftest harness-provider-bedrock-eventstream-aws-test-vectors ()
  "The AWS event stream test vectors decode, and corrupted ones are refused."
  (let ((root (harness-test-fixture "aws-eventstream")))
    (dolist (name '("all_headers" "empty_message" "int32_header" "payload_no_headers" "payload_one_str_header"))
      (let* ((bytes (harness-bedrock-test--bytes (expand-file-name (concat "encoded/positive/" name) root)))
             (expected (json-parse-string (harness-bedrock-test--read
                                           (expand-file-name (concat "decoded/positive/" name) root))
                                          :object-type 'plist :array-type 'list :false-object :false))
             (message (harness-bedrock-eventstream-decode bytes)))
        (ert-info (name :prefix "vector: ")
          (should (= (plist-get expected :total_length) (length bytes)))
          (should (= (logand (plist-get expected :prelude_crc) #xFFFFFFFF) (harness-bedrock--crc32 bytes 0 8)))
          (should (= (logand (plist-get expected :message_crc) #xFFFFFFFF)
                     (harness-bedrock--crc32 bytes 0 (- (length bytes) 4))))
          (should (equal (base64-decode-string (plist-get expected :payload)) (plist-get message :payload)))
          (should (equal (mapcar (lambda (h) (cons (plist-get h :name) (harness-bedrock-test--expected-header-value h)))
                                 (plist-get expected :headers))
                         (plist-get message :headers))))))
    (dolist (name '("corrupted_header_len" "corrupted_headers" "corrupted_length" "corrupted_payload"))
      (let ((bytes (harness-bedrock-test--bytes (expand-file-name (concat "encoded/negative/" name) root)))
            (expected (string-trim (harness-bedrock-test--read (expand-file-name (concat "decoded/negative/" name) root)))))
        (ert-info (name :prefix "vector: ")
          (should (equal (list expected)
                         (cdr (should-error (harness-bedrock-eventstream-decode bytes)
                                            :type 'harness-bedrock-eventstream-error)))))))))

(ert-deftest harness-provider-bedrock-eventstream-split-anywhere ()
  "Messages split across chunks at any byte decode the same."
  (let* ((messages (list (harness-bedrock-mock-event "messageStart" '(:role "assistant"))
                         (harness-bedrock-mock-event "contentBlockDelta"
                                                     '(:contentBlockIndex 0 :delta (:text "héllo ✓")))
                         (harness-bedrock-mock-exception "throttlingException" "slow down")
                         (harness-bedrock-mock-usage 3 4)))
         (bytes (apply #'concat messages)))
    (should-not (multibyte-string-p bytes))
    (dolist (size '(1 2 5 12 13 64 100000))
      (let* ((got nil)
             (decoder (harness-bedrock-eventstream-decoder (lambda (m) (push m got)))))
        (dolist (chunk (harness-bedrock-test--chunks bytes size)) (funcall decoder chunk))
        (setq got (nreverse got))
        (ert-info ((format "%d" size) :prefix "chunk size: ")
          (should (= 4 (length got)))
          (should (equal "contentBlockDelta" (cdr (assoc ":event-type" (plist-get (nth 1 got) :headers)))))
          (should (equal "héllo ✓" (harness-plist-get-in (harness-bedrock--payload-json (plist-get (nth 1 got) :payload))
                                                         '(:delta :text))))
          (should (equal "exception" (cdr (assoc ":message-type" (plist-get (nth 2 got) :headers))))))))
    ;; A corrupted byte is noticed, whichever chunk it lands in.
    (let ((bad (copy-sequence bytes))
          (decoder (harness-bedrock-eventstream-decoder #'ignore)))
      (aset bad 30 (logxor (aref bad 30) 1))
      (should-error (dolist (chunk (harness-bedrock-test--chunks bad 7)) (funcall decoder chunk))
                    :type 'harness-bedrock-eventstream-error))))

;;;; Converse request bodies

(ert-deftest harness-provider-bedrock-messages-to-converse ()
  (harness-bedrock-test-with-env ()
    (let* ((request
            (list :messages
                  '((:role user :content ((:type "text" :text "look")
                                          (:type "image" :mime "image/png" :data "QUJD")
                                          (:type "text" :text "   ")
                                          (:type "file" :path "/tmp/notes.txt")))
                    (:role assistant :content ((:type "thinking" :text "hmm")
                                               (:type "text" :text "calling")
                                               (:type "tool_use" :id "toolu_1" :name "echo" :input (:value "a"))
                                               (:type "tool_use" :id "call/2 bad id" :name "noop" :input :empty)))
                    (:role tool :content ((:type "tool_result" :tool_use_id "toolu_1" :content "a!")))
                    (:role user :content ((:type "tool_result" :tool_use_id "call/2 bad id" :content "" :is_error t)
                                          (:type "text" :text "and now?")))
                    (:role system :content "Also be kind.")
                    (:role assistant :content ((:type "tool_use" :id "toolu_3" :name "echo" :input (:value "b"))))
                    (:role user :content ((:type "text" :text "no result given")
                                          (:type "tool_result" :tool_use_id "toolu_orphan" :content "stray"))))))
           (converted (harness-bedrock--messages request))
           (messages (plist-get converted :messages)))
      (should (equal '("Also be kind.") (plist-get converted :system)))
      (should (equal '("user" "assistant" "user" "assistant" "user") (mapcar (lambda (m) (plist-get m :role)) messages)))
      ;; Blank text goes, images become image blocks, files are described.
      (should (equal '((:text "look")
                       (:image (:format "png" :source (:bytes "QUJD")))
                       (:text "[attached file: /tmp/notes.txt]"))
                     (plist-get (nth 0 messages) :content)))
      ;; Thinking without a signature cannot go back; tool ids are made valid.
      (should (equal '((:text "calling")
                       (:toolUse (:toolUseId "toolu_1" :name "echo" :input (:value "a")))
                       (:toolUse (:toolUseId "call_2_bad_id" :name "noop" :input :empty)))
                     (plist-get (nth 1 messages) :content)))
      ;; Tool results of consecutive user-side messages merge, results first.
      (should (equal '((:toolResult (:toolUseId "toolu_1" :content ((:text "a!")) :status "success"))
                       (:toolResult (:toolUseId "call_2_bad_id" :content ((:text "(no output)")) :status "error"))
                       (:text "and now?"))
                     (plist-get (nth 2 messages) :content)))
      ;; A call without a result gets one; a result without a call becomes text.
      (should (equal '((:toolResult (:toolUseId "toolu_3" :content ((:text "No result was recorded for this call."))
                                    :status "error"))
                       (:text "no result given")
                       (:text "[result of tool call toolu_orphan]\nstray"))
                     (plist-get (nth 4 messages) :content)))
      ;; Without tools, calls and results are text.
      (let ((flat (plist-get (harness-bedrock--messages request :tools nil) :messages)))
        (should-not (string-search "toolUse" (harness-json-encode flat)))
        (should-not (string-search "toolResult" (harness-json-encode flat)))
        (should (equal '(:text "[called tool echo with {\"value\":\"a\"}]") (nth 1 (plist-get (nth 1 flat) :content)))))
      ;; A conversation must start with the user.
      (should (equal "user" (plist-get (car (plist-get (harness-bedrock--messages
                                                       '(:messages ((:role assistant :content "hi")
                                                                    (:role user :content "yes"))))
                                                      :messages))
                                       :role)))
      ;; Signed thinking goes back, and so does a remembered response.
      (let* ((signed '(:messages ((:role user :content "q")
                                  (:role assistant :content ((:type "thinking" :text "t" :signature "S")
                                                             (:type "text" :text "a"))))))
             (with (plist-get (nth 1 (plist-get (harness-bedrock--messages signed) :messages)) :content))
             (without (plist-get (nth 1 (plist-get (harness-bedrock--messages signed :reasoning nil) :messages)) :content)))
        (should (equal '((:reasoningContent (:reasoningText (:text "t" :signature "S"))) (:text "a")) with))
        (should (equal '((:text "a")) without)))
      (puthash "toolu_1" (cons (float-time) '((:reasoningContent (:reasoningText (:text "plan" :signature "SIG")))
                                              (:text "calling")
                                              (:toolUse (:toolUseId "toolu_1" :name "echo" :input (:value "a")))
                                              (:toolUse (:toolUseId "call_2_bad_id" :name "noop" :input :empty))))
               harness-bedrock--responses)
      (let ((again (plist-get (harness-bedrock--messages request) :messages)))
        (should (equal '(:reasoningContent (:reasoningText (:text "plan" :signature "SIG")))
                       (car (plist-get (nth 1 again) :content))))
        (should (= 4 (length (plist-get (nth 1 again) :content)))))
      (should-not (string-search "reasoningContent"
                                 (harness-json-encode (harness-bedrock--messages request :reasoning nil)))))))

(ert-deftest harness-provider-bedrock-flattens-non-ascii-tool-calls ()
  ;; A flattened call is text inside the body's JSON: as bytes it made the
  ;; body fail to encode once a call had non-ASCII input.
  (let* ((value "\N{U+2717} caf\N{U+E9} \N{U+2026}")
         (flat (harness-bedrock--flatten-tools
                (list (list :toolUse (list :toolUseId "t1" :name "echo" :input (list :value value)))))))
    (should (equal (list (list :text (format "[called tool echo with {\"value\":\"%s\"}]" value))) flat))
    (should (equal flat (harness-json-parse (harness-json-encode flat))))))

(ert-deftest harness-provider-bedrock-request-body ()
  (harness-bedrock-test-with-env ()
    (let* ((endpoint '(:id testrock :region "us-east-1" :request-fields (:anthropic_beta ("beta-1"))))
           (tools '((:name "echo" :description "Echo it."
                     :schema (:type "object" :properties (:value (:type "string")) :required ("value")))
                    (:name "noop" :description "")))
           (request (list :system "Be terse." :thinking "high" :tools tools
                          :messages '((:role user :content "one")
                                      (:role assistant :content "two")
                                      (:role user :content "three"))))
           (sonnet (harness-bedrock--model-info endpoint harness-bedrock-test-sonnet))
           (body (harness-bedrock--body endpoint sonnet request)))
      ;; Tools: the description only when there is one, a schema always.
      (should (equal '((:toolSpec (:name "echo"
                                   :inputSchema (:json (:type "object" :properties (:value (:type "string"))
                                                        :required ("value")))
                                   :description "Echo it."))
                       (:toolSpec (:name "noop" :inputSchema (:json (:type "object" :properties :empty)))))
                     (harness-plist-get-in body '(:toolConfig :tools))))
      ;; Cache points: after the system prompt and at the end of the last two user messages.
      (should (equal '((:text "Be terse.") (:cachePoint (:type "default"))) (plist-get body :system)))
      (should (equal '((:text "one") (:cachePoint (:type "default")))
                     (plist-get (nth 0 (plist-get body :messages)) :content)))
      (should (equal '((:text "two")) (plist-get (nth 1 (plist-get body :messages)) :content)))
      (should (equal '((:text "three") (:cachePoint (:type "default")))
                     (plist-get (nth 2 (plist-get body :messages)) :content)))
      ;; Sonnet 4.5 thinks within a budget, below its output limit.
      (should (equal '(:maxTokens 32000) (plist-get body :inferenceConfig)))
      (should (equal '(:anthropic_beta ("beta-1") :thinking (:type "enabled" :budget_tokens 20000))
                     (plist-get body :additionalModelRequestFields)))
      ;; It all encodes.
      (should (string-search "\"cachePoint\":{\"type\":\"default\"}" (harness-json-encode body)))
      ;; Options leave out cache points and tools.
      (let ((plain (harness-bedrock--body endpoint sonnet request '(:no-cache t :no-tools t))))
        (should-not (string-search "cachePoint" (harness-json-encode plain)))
        (should-not (plist-get plain :toolConfig)))
      ;; Adaptive models get an effort level they accept.
      (let ((opus (harness-bedrock--body '(:id x) (harness-bedrock--model-info '(:id x) "global.anthropic.claude-opus-5-5")
                                         '(:thinking "max" :messages ((:role user :content "q"))))))
        (should (equal '(:thinking (:type "adaptive") :output_config (:effort "max"))
                       (plist-get opus :additionalModelRequestFields)))
        (should (equal '(:maxTokens 32000) (plist-get opus :inferenceConfig))))
      (let ((opus46 (harness-bedrock--body '(:id x) (harness-bedrock--model-info '(:id x) "us.anthropic.claude-opus-4-6-v1")
                                           '(:thinking "xhigh" :messages ((:role user :content "q"))))))
        (should (equal "high" (harness-plist-get-in opus46 '(:additionalModelRequestFields :output_config :effort)))))
      ;; Without a thinking level no thinking is asked for.
      (should (equal '(:anthropic_beta ("beta-1"))
                     (plist-get (harness-bedrock--body endpoint sonnet '(:messages ((:role user :content "q"))))
                                :additionalModelRequestFields)))
      ;; Llama: no cache points, no thinking, its own output limit.
      (let ((llama (harness-bedrock--body '(:id x) (harness-bedrock--model-info '(:id x) "meta.llama3-1-8b-instruct-v1:0")
                                          '(:system "s" :thinking "high" :messages ((:role user :content "q"))))))
        (should-not (string-search "cachePoint" (harness-json-encode llama)))
        (should-not (plist-get llama :additionalModelRequestFields))
        (should (equal '(:maxTokens 2048) (plist-get llama :inferenceConfig))))
      ;; An unknown model gets no output limit unless the endpoint sets one.
      (should-not (plist-get (harness-bedrock--body '(:id x) (harness-bedrock--model-info '(:id x) "acme.mystery-v1")
                                                    '(:messages ((:role user :content "q"))))
                             :inferenceConfig))
      (should (equal '(:maxTokens 1000)
                     (plist-get (harness-bedrock--body '(:id x :max-tokens 1000)
                                                       (harness-bedrock--model-info '(:id x) "acme.mystery-v1")
                                                       '(:messages ((:role user :content "q"))))
                                :inferenceConfig)))
      ;; Remembered reasoning goes back only to a model that thinks in this request.
      (puthash "toolu_r" (cons (float-time) '((:reasoningContent (:reasoningText (:text "plan" :signature "SIG")))
                                              (:toolUse (:toolUseId "toolu_r" :name "echo" :input (:v "x")))))
               harness-bedrock--responses)
      (let ((loop '(:tools ((:name "echo" :description "Echo."))
                    :messages ((:role user :content "go")
                               (:role assistant :content ((:type "tool_use" :id "toolu_r" :name "echo" :input (:v "x"))))
                               (:role user :content ((:type "tool_result" :tool_use_id "toolu_r" :content "x")))))))
        (cl-flet ((reasons (model &optional level)
                    (and (string-search "reasoningContent"
                                        (harness-json-encode
                                         (harness-bedrock--body '(:id x) (harness-bedrock--model-info '(:id x) model)
                                                                (append (list :thinking level) loop))))
                         t)))
          (should (reasons "us.anthropic.claude-opus-5-5"))
          (should (reasons "global.anthropic.claude-fable-5-1"))
          (should-not (reasons "us.anthropic.claude-sonnet-4-6"))
          (should (reasons "us.anthropic.claude-sonnet-4-6" "high"))
          (should-not (reasons harness-bedrock-test-sonnet))
          (should (reasons harness-bedrock-test-sonnet "low"))))
      ;; Caching can be forced on or turned off.
      (let ((harness-bedrock--prompt-caching nil))
        (should-not (string-search "cachePoint" (harness-json-encode (harness-bedrock--body endpoint sonnet request)))))
      (should (string-search "cachePoint"
                             (harness-json-encode
                              (harness-bedrock--body '(:id x :prompt-caching always)
                                                     (harness-bedrock--model-info '(:id x) "acme.mystery-v1")
                                                     '(:system "s" :messages ((:role user :content "q"))))))))))

;;;; Streams to events

(defun harness-bedrock-test--reasoning-tool-stream ()
  "Return a ConverseStream reply that reasons, talks and calls read_file."
  (concat
   (harness-bedrock-mock-event "messageStart" '(:role "assistant"))
   (harness-bedrock-mock-event "contentBlockDelta" '(:contentBlockIndex 0 :delta (:reasoningContent (:text "Let me"))))
   (harness-bedrock-mock-event "contentBlockDelta" '(:contentBlockIndex 0 :delta (:reasoningContent (:text " think"))))
   (harness-bedrock-mock-event "contentBlockDelta" '(:contentBlockIndex 0 :delta (:reasoningContent (:signature "sig-123"))))
   (harness-bedrock-mock-event "contentBlockStop" '(:contentBlockIndex 0))
   (harness-bedrock-mock-event "contentBlockDelta" '(:contentBlockIndex 1 :delta (:text "Hello")))
   (harness-bedrock-mock-event "contentBlockDelta" '(:contentBlockIndex 1 :delta (:text " world")))
   (harness-bedrock-mock-event "contentBlockStop" '(:contentBlockIndex 1))
   (harness-bedrock-mock-event "contentBlockStart"
                               '(:contentBlockIndex 2 :start (:toolUse (:toolUseId "tooluse_abc" :name "read_file"))))
   (harness-bedrock-mock-event "contentBlockDelta" '(:contentBlockIndex 2 :delta (:toolUse (:input "{\"pa"))))
   (harness-bedrock-mock-event "contentBlockDelta" '(:contentBlockIndex 2 :delta (:toolUse (:input "th\": \"/tmp/x\"}"))))
   (harness-bedrock-mock-event "contentBlockStop" '(:contentBlockIndex 2))
   (harness-bedrock-mock-event "messageStop" '(:stopReason "tool_use"))
   (harness-bedrock-mock-usage 100 20 50 10)))

(ert-deftest harness-provider-bedrock-converse-stream-to-events ()
  (harness-bedrock-test-with-keys
    (harness-bedrock-test-with-fake
        `(("converse-stream" . (:status 200 :headers (("content-type" . "application/vnd.amazon.eventstream"))
                                :chunks ,(harness-bedrock-test--chunks (harness-bedrock-test--reasoning-tool-stream) 13))))
      (let* ((events (car (harness-bedrock-test--complete
                           harness-bedrock-test-endpoint
                           (append (harness-bedrock-test--request "read /tmp/x") '(:thinking "low")))))
             (req (car harness-bedrock-test--requests))
             (headers (plist-get req :headers)))
        (should (equal '(start thinking thinking text text usage tool-call done) (harness-bedrock-test--types events)))
        (should (equal "Let me think" (mapconcat (lambda (e) (or (and (eq (plist-get e :type) 'thinking) (plist-get e :delta)) ""))
                                                 events "")))
        (should (equal "Hello world" (harness-bedrock-test--text events)))
        (should (equal '(:type usage :input 100 :output 20 :cache-read 50 :cache-write 10 :cost nil :billing api :context 160)
                       (nth 5 events)))
        (should (equal '(:type tool-call :id "tooluse_abc" :name "read_file" :input (:path "/tmp/x") :respond nil)
                       (nth 6 events)))
        (should (equal '(:type done :stop-reason tool-use) (car (last events))))
        ;; The request: the regional URL, model id escaped, signed, binary.
        (should (equal "https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-sonnet-4-5-20250929-v1%3A0/converse-stream"
                       (plist-get req :url)))
        (should (equal "POST" (plist-get req :method)))
        (should (eq t (plist-get (plist-get req :args) :binary)))
        (should (string-prefix-p "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/" (cdr (assoc "Authorization" headers))))
        (should (equal "bedrock-runtime.us-east-1.amazonaws.com" (cdr (assoc "Host" headers))))
        (should (assoc "X-Amz-Date" headers))
        (should (equal "application/json" (cdr (assoc "Content-Type" headers))))
        (should (equal '((:text "read /tmp/x") (:cachePoint (:type "default")))
                       (plist-get (car (plist-get (plist-get req :json) :messages)) :content)))
        (should (equal '(:thinking (:type "enabled" :budget_tokens 4000))
                       (plist-get (plist-get req :json) :additionalModelRequestFields)))
        ;; The reasoning is kept, and goes back with the tool call in the next request.
        (let ((history (list :model (concat "testrock:" harness-bedrock-test-sonnet) :thinking "low"
                             :messages '((:role user :content "read /tmp/x")
                                         (:role assistant :content ((:type "thinking" :text "Let me think")
                                                                    (:type "text" :text "Hello world")
                                                                    (:type "tool_use" :id "tooluse_abc" :name "read_file"
                                                                     :input (:path "/tmp/x"))))
                                         (:role user :content ((:type "tool_result" :tool_use_id "tooluse_abc"
                                                                :content "contents")))))))
          (should (equal '((:reasoningContent (:reasoningText (:text "Let me think" :signature "sig-123")))
                           (:text "Hello world")
                           (:toolUse (:toolUseId "tooluse_abc" :name "read_file" :input (:path "/tmp/x"))))
                         (plist-get (nth 1 (plist-get (harness-bedrock--messages history) :messages)) :content))))))))

(ert-deftest harness-provider-bedrock-text-reply-and-usage ()
  (harness-bedrock-test-with-keys
    (harness-bedrock-test-with-fake
        `(("converse-stream" . (:chunks ,(harness-bedrock-test--chunks
                                          (harness-bedrock-mock-text-stream "Hi there, how are you?" 12 7) 50))))
      (let ((events (car (harness-bedrock-test--complete harness-bedrock-test-endpoint
                                                         (harness-bedrock-test--request "hi")))))
        (should (equal '(start text text text text text usage done) (harness-bedrock-test--types events)))
        (should (equal "Hi there, how are you?" (harness-bedrock-test--text events)))
        (should (equal '(:type usage :input 12 :output 7 :cache-read 0 :cache-write 0 :cost nil :billing api :context 12)
                       (nth 6 events)))
        (should (equal '(:type done :stop-reason end-turn) (car (last events))))
        ;; Plain text replies leave nothing to remember.
        (should (zerop (hash-table-count harness-bedrock--responses)))))))

(ert-deftest harness-provider-bedrock-stop-reasons-and-errors ()
  (harness-bedrock-test-with-keys
    (cl-flet ((run (response)
                (harness-bedrock-test-with-fake `(("converse" . ,response))
                  (car (harness-bedrock-test--complete harness-bedrock-test-endpoint
                                                       (harness-bedrock-test--request "go"))))))
      (should (equal '(:type done :stop-reason max-tokens)
                     (car (last (run `(:chunks (,(harness-bedrock-mock-text-stream "partial" 1 1 "max_tokens"))))))))
      (let ((done (car (last (run `(:chunks (,(harness-bedrock-mock-text-stream "x" 1 1 "guardrail_intervened"))))))))
        (should (eq 'error (plist-get done :stop-reason)))
        (should (string-match-p "guardrail" (plist-get done :error))))
      (should (string-match-p "context window"
                              (plist-get (car (last (run `(:chunks (,(harness-bedrock-mock-text-stream
                                                                       "x" 1 1 "model_context_window_exceeded"))))))
                                         :error)))
      ;; An exception after output was streamed ends the turn; it is not retried.
      (let ((events (run `(:chunks (,(concat (harness-bedrock-mock-event "messageStart" '(:role "assistant"))
                                             (harness-bedrock-mock-event "contentBlockDelta"
                                                                         '(:contentBlockIndex 0 :delta (:text "Hal")))
                                             (harness-bedrock-mock-exception "modelStreamErrorException"
                                                                             "The model stream broke")))))))
        (should (equal '(start text done) (harness-bedrock-test--types events)))
        (should (equal "modelStreamErrorException: The model stream broke" (plist-get (car (last events)) :error))))
      ;; HTTP errors carry the AWS error type and message.
      (let ((done (car (last (run '(:status 400 :headers (("x-amzn-errortype" . "ValidationException:http://internal.amazon.com/coral/com.amazon.bedrock/"))
                                    :body "{\"message\":\"Malformed input request: #: required key [messages] not found\"}"))))))
        (should (equal "HTTP 400 ValidationException: Malformed input request: #: required key [messages] not found"
                       (plist-get done :error))))
      (should (string-match-p "HTTP 403 AccessDeniedException: not authorized"
                              (plist-get (car (last (run '(:status 403 :body "{\"__type\":\"com.amazon#AccessDeniedException\",\"Message\":\"not authorized\"}"))))
                                         :error)))
      ;; Transport failures, corrupt streams and streams cut short.
      (should (string-match-p "connection refused"
                              (plist-get (car (last (run '(:error (curl "curl exited 7: connection refused"))))) :error)))
      (let ((bad (harness-bedrock-mock-text-stream "x")))
        (aset bad 9 (logxor (aref bad 9) 255))
        (should (string-match-p "unreadable response stream: Prelude checksum mismatch"
                                (plist-get (car (last (run `(:chunks (,bad))))) :error))))
      (should (string-match-p "ended before the model finished"
                              (plist-get (car (last (run `(:chunks (,(harness-bedrock-mock-event "messageStart"
                                                                                                  '(:role "assistant")))))))
                                         :error))))))

(ert-deftest harness-provider-bedrock-retries-throttling ()
  (harness-bedrock-test-with-keys
    (cl-letf (((symbol-function 'harness-bedrock--retry-delay) (lambda (_) 0)))
      (harness-bedrock-test-with-fake
          `(("converse-stream" . (:status 429 :headers (("x-amzn-errortype" . "ThrottlingException"))
                                  :body "{\"message\":\"Too many tokens, please wait before trying again.\"}"))
            ("converse-stream" . (:chunks (,(harness-bedrock-mock-exception "throttlingException" "Slow down"))))
            ("converse-stream" . (:chunks (,(harness-bedrock-mock-text-stream "finally")))))
        (let ((events (car (harness-bedrock-test--complete harness-bedrock-test-endpoint
                                                           (harness-bedrock-test--request "go")))))
          (should (equal '(start hint hint text text usage done) (harness-bedrock-test--types events)))
          (should (string-match-p "HTTP 429 ThrottlingException: Too many tokens.*retrying in 0 s (1 of 3)"
                                  (plist-get (nth 1 events) :text)))
          (should (string-match-p "throttlingException: Slow down; retrying in 0 s (2 of 3)" (plist-get (nth 2 events) :text)))
          (should (equal "finally" (harness-bedrock-test--text events)))
          (should (= 3 (length harness-bedrock-test--requests)))))
      ;; Retries run out.
      (let ((harness-bedrock--max-retries 1))
        (harness-bedrock-test-with-fake
            '(("converse-stream" . (:status 503 :body "{\"message\":\"busy\"}"))
              ("converse-stream" . (:status 503 :body "{\"message\":\"still busy\"}")))
          (let ((events (car (harness-bedrock-test--complete harness-bedrock-test-endpoint
                                                             (harness-bedrock-test--request "go")))))
            (should (equal '(start hint done) (harness-bedrock-test--types events)))
            (should (equal "HTTP 503: still busy" (plist-get (car (last events)) :error)))))))))

(ert-deftest harness-provider-bedrock-adjusts-to-what-a-model-rejects ()
  (harness-bedrock-test-with-keys
    (let ((tools '((:name "echo" :description "Echo." :schema (:type "object" :properties (:v (:type "string")))))))
      ;; Cache points refused: asked again without them, and remembered.
      (harness-bedrock-test-with-fake
          `(("converse-stream" . (:status 400 :headers (("x-amzn-errortype" . "ValidationException"))
                                  :body "{\"message\":\"You invoked an unsupported model or your request did not allow prompt caching.\"}"))
            ("converse-stream" . (:chunks (,(harness-bedrock-mock-text-stream "ok")))))
        (let ((events (car (harness-bedrock-test--complete
                            harness-bedrock-test-endpoint
                            (append (harness-bedrock-test--request "go") (list :system "s" :tools tools))))))
          (should (equal '(:type done :stop-reason end-turn) (car (last events))))
          (should (= 2 (length harness-bedrock-test--requests)))
          (should (string-search "cachePoint" (plist-get (cadr harness-bedrock-test--requests) :body)))
          (should-not (string-search "cachePoint" (plist-get (car harness-bedrock-test--requests) :body)))
          (should (plist-get (gethash (concat "testrock/" harness-bedrock-test-sonnet) harness-bedrock--quirks) :no-cache))))
      ;; Streamed tool use refused: the request goes to Converse, unstreamed.
      (harness-bedrock-test-with-fake
          '(("converse-stream" . (:status 400 :body "{\"message\":\"This model doesn't support tool use in streaming mode.\"}"))
            ("/converse\\'" . (:status 200 :headers (("content-type" . "application/json"))
                               :body "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"text\":\"Calling.\"},{\"toolUse\":{\"toolUseId\":\"tooluse_9\",\"name\":\"echo\",\"input\":{\"v\":\"x\"}}}]}},\"stopReason\":\"tool_use\",\"usage\":{\"inputTokens\":30,\"outputTokens\":9,\"totalTokens\":39},\"metrics\":{\"latencyMs\":200}}")))
        (let* ((endpoint '(:id mistral :region "us-east-1"))
               (events (car (harness-bedrock-test--complete
                             endpoint (list :model "mistral:mistral.mistral-large-2407-v1:0" :tools tools
                                            :messages '((:role user :content "go")))))))
          (should (equal '(start text usage tool-call done) (harness-bedrock-test--types events)))
          (should (equal '(:type tool-call :id "tooluse_9" :name "echo" :input (:v "x") :respond nil) (nth 3 events)))
          (should (string-suffix-p "/converse" (plist-get (car harness-bedrock-test--requests) :url)))
          ;; The next request knows already.
          (setq harness-bedrock-test--responses
                '(("/converse\\'" . (:status 200 :headers (("content-type" . "application/json"))
                                     :body "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"text\":\"Done.\"}]}},\"stopReason\":\"end_turn\",\"usage\":{\"inputTokens\":5,\"outputTokens\":1,\"totalTokens\":6}}"))))
          (let ((n (length harness-bedrock-test--requests))
                (again (car (harness-bedrock-test--complete
                             endpoint (list :model "mistral:mistral.mistral-large-2407-v1:0" :tools tools
                                            :messages '((:role user :content "go")))))))
            (should (equal "Done." (harness-bedrock-test--text again)))
            (should (= (1+ n) (length harness-bedrock-test--requests))))))
      ;; Tools refused altogether: asked again without them.
      (harness-bedrock-test-with-fake
          `(("converse-stream" . (:status 400 :body "{\"message\":\"This model doesn't support tool use.\"}"))
            ("converse-stream" . (:chunks (,(harness-bedrock-mock-text-stream "plain")))))
        (let ((events (car (harness-bedrock-test--complete
                            '(:id deep :region "us-east-1")
                            (list :model "deep:deepseek.r1-v1:0" :tools tools :messages '((:role user :content "go")))))))
          (should (equal "plain" (harness-bedrock-test--text events)))
          (should-not (plist-get (plist-get (car harness-bedrock-test--requests) :json) :toolConfig)))))))

(ert-deftest harness-provider-bedrock-cancel-emits-done-once ()
  (harness-bedrock-test-with-keys
    (harness-bedrock-test-with-fake '(("converse-stream" . (:hang t)))
      (let* ((events nil)
             (handle (harness-bedrock--complete
                      harness-bedrock-test-endpoint
                      (plist-put (harness-bedrock-test--request "hi") :on-event (lambda (e) (push e events))))))
        (should (equal '(start) (harness-bedrock-test--types events)))
        (funcall (plist-get handle :cancel))
        (funcall (plist-get handle :cancel))
        (should (equal '(start done) (harness-bedrock-test--types (reverse events))))
        (should (equal '(:type done :stop-reason cancelled) (car events)))
        ;; Late data or a late callback from the transport is ignored.
        (let ((args (plist-get (car harness-bedrock-test--requests) :args)))
          (funcall (plist-get args :on-chunk) (harness-bedrock-mock-text-stream "late"))
          (funcall (plist-get args :callback) 200 nil "" nil))
        (should (= 2 (length events)))))))

;;;; Credentials

(defun harness-bedrock-test--write (dir name text)
  "Write TEXT to file NAME in DIR and return its path."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert text))
    file))

(defun harness-bedrock-test--auth (endpoint &optional quiet)
  "Return the keys ENDPOINT resolves to, or (error . MESSAGE)."
  (condition-case err
      (harness-test-await (harness-bedrock--auth endpoint quiet))
    (error (cons 'error (harness-error-message err)))))

(ert-deftest harness-provider-bedrock-credential-sources ()
  (let ((dir (harness-test-temp-dir)))
    (unwind-protect
        (let ((config (harness-bedrock-test--write
                       dir "config"
                       (concat "[default]\nregion = eu-west-1\n\n"
                               "[profile work]\nregion = ap-southeast-2\n"
                               "credential_process = " (expand-file-name "print-keys" dir) "\n"
                               "s3 =\n  max_concurrent_requests = 20\n\n"
                               "[profile static]\naws_access_key_id = AKIDSTATIC\n"
                               "aws_secret_access_key = static/secret+key=\n")))
              (shared (harness-bedrock-test--write
                       dir "credentials"
                       "# keys\n[default]\naws_access_key_id = AKIDDEFAULT\naws_secret_access_key = default/secret=\naws_session_token = TOKDEFAULT\n"))
              (counter (expand-file-name "runs" dir)))
          (harness-bedrock-test--write
           dir "print-keys"
           (format "#!/bin/sh\necho run >> %s\necho '{\"Version\": 1, \"AccessKeyId\": \"AKIDPROCESS\", \"SecretAccessKey\": \"process/secret\", \"SessionToken\": \"TOKPROCESS\", \"Expiration\": \"2099-01-01T00:00:00Z\"}'\n"
                   (shell-quote-argument counter)))
          (set-file-modes (expand-file-name "print-keys" dir) #o700)
          ;; Nothing configured: an explanation, or nil when listing quietly.
          (harness-bedrock-test-with-env ()
            (let ((result (harness-bedrock-test--auth '(:id plain))))
              (should (eq 'error (car result)))
              (should (string-match-p "AWS_BEARER_TOKEN_BEDROCK" (cdr result)))
              (should (string-match-p "AWS_PROFILE" (cdr result)))
              (should (string-match-p "bedrock-runtime.us-east-1.amazonaws.com" (cdr result))))
            (should (null (harness-bedrock-test--auth '(:id plain) t)))
            (should (equal '(:type none :source "none") (harness-bedrock-test--auth '(:id open :auth none)))))
          ;; An API key wins over keys in the environment.
          (harness-bedrock-test-with-env (("AWS_BEARER_TOKEN_BEDROCK" "bedrock-api-key-1")
                                          ("AWS_ACCESS_KEY_ID" "AKIDENV") ("AWS_SECRET_ACCESS_KEY" "env/secret"))
            (should (equal "bedrock-api-key-1" (plist-get (harness-bedrock-test--auth '(:id e)) :token)))
            (let ((keys (harness-bedrock-test--auth '(:id e :auth sigv4))))
              (should (equal '("AKIDENV" "env/secret" nil)
                             (list (plist-get keys :access-key-id) (plist-get keys :secret-access-key)
                                   (plist-get keys :session-token))))))
          ;; The profile files: the default profile, its region, and an explicit profile.
          (harness-bedrock-test-with-env (("AWS_CONFIG_FILE" config) ("AWS_SHARED_CREDENTIALS_FILE" shared)
                                          ("AWS_ACCESS_KEY_ID" "AKIDENV") ("AWS_SECRET_ACCESS_KEY" "env/secret"))
            (should (equal "AKIDENV" (plist-get (harness-bedrock-test--auth '(:id e)) :access-key-id)))
            (should (equal "eu-west-1" (harness-bedrock--region '(:id e))))
            (let ((keys (harness-bedrock-test--auth '(:id e :profile "static"))))
              (should (equal '("AKIDSTATIC" "static/secret+key=") (list (plist-get keys :access-key-id)
                                                                        (plist-get keys :secret-access-key))))))
          (harness-bedrock-test-with-env (("AWS_CONFIG_FILE" config) ("AWS_SHARED_CREDENTIALS_FILE" shared))
            (let ((keys (harness-bedrock-test--auth '(:id d))))
              (should (equal '("AKIDDEFAULT" "default/secret=" "TOKDEFAULT")
                             (list (plist-get keys :access-key-id) (plist-get keys :secret-access-key)
                                   (plist-get keys :session-token)))))
            (should (equal "https://bedrock-runtime.eu-west-1.amazonaws.com" (harness-bedrock--runtime-url '(:id d))))
            ;; credential_process runs once; its keys are kept until they expire.
            (let ((keys (harness-bedrock-test--auth '(:id w :profile "work"))))
              (should (equal '("AKIDPROCESS" "process/secret" "TOKPROCESS")
                             (list (plist-get keys :access-key-id) (plist-get keys :secret-access-key)
                                   (plist-get keys :session-token))))
              (should (plist-get keys :command)))
            (should (equal "AKIDPROCESS" (plist-get (harness-bedrock-test--auth '(:id w :profile "work")) :access-key-id)))
            (should (= 1 (length (split-string (harness-bedrock-test--read counter) "\n" t))))
            (should (equal "ap-southeast-2" (harness-bedrock--region '(:id w :profile "work"))))
            (with-environment-variables (("AWS_REGION" "us-west-2"))
              (should (equal "us-west-2" (harness-bedrock--region '(:id w :profile "work"))))
              (should (equal "ca-central-1" (harness-bedrock--region '(:id w :profile "work" :region "ca-central-1")))))))
      (delete-directory dir t)))
  ;; auth-source: user apikey is an API key, any other user an access key id.
  (harness-bedrock-test-with-env ()
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest args)
                 (pcase (plist-get args :host)
                   ("bedrock-runtime.us-east-1.amazonaws.com"
                    (list (list :host "bedrock-runtime.us-east-1.amazonaws.com" :user "apikey"
                                :secret (lambda () "bedrock-api-key-from-authinfo"))))
                   ("keys.example"
                    (list (list :host "keys.example" :user "AKIDAUTHSOURCE" :secret (lambda () "authinfo/secret"))))))))
      (should (equal "bedrock-api-key-from-authinfo" (plist-get (harness-bedrock-test--auth '(:id a)) :token)))
      (should (eq 'error (car (harness-bedrock-test--auth '(:id a :auth sigv4)))))
      (let ((keys (harness-bedrock-test--auth '(:id a :auth-source-host "keys.example"))))
        (should (equal '(sigv4 "AKIDAUTHSOURCE" "authinfo/secret")
                       (list (plist-get keys :type) (plist-get keys :access-key-id) (plist-get keys :secret-access-key)))))))
  ;; A :credentials function, returning keys or a promise of them.
  (harness-bedrock-test-with-env ()
    (should (equal "AKIDFN" (plist-get (harness-bedrock-test--auth
                                        (list :id 'f :credentials (lambda () '(:access-key-id "AKIDFN" :secret-access-key "s"))))
                                       :access-key-id)))
    (should (equal "tok" (plist-get (harness-bedrock-test--auth
                                     (list :id 'f :credentials (lambda () (harness-resolved '(:bearer-token "tok")))))
                                    :token)))))

(ert-deftest harness-provider-bedrock-request-auth-headers ()
  (harness-bedrock-test-with-env ()
    (let ((url "https://gateway.example.com:8443/bedrock/model/m/converse-stream"))
      ;; Bearer: just the header.
      (should (equal '(("Content-Type" . "application/json") ("Authorization" . "Bearer tok"))
                     (harness-bedrock--request-headers '(:id g) '(:type bearer :token "tok") "POST" url "{}" "us-east-1"
                                                       '(("Content-Type" . "application/json")))))
      ;; Signed: Host first, with the port, and the endpoint's own signing names.
      (let ((headers (harness-bedrock--request-headers
                      '(:id g :signing-service "execute-api" :signing-region "eu-west-1"
                        :headers (("X-Gateway-Team" . "harness")))
                      '(:type sigv4 :access-key-id "AKID" :secret-access-key "secret" :session-token "tok")
                      "POST" url "{}" "us-east-1" '(("Content-Type" . "application/json")))))
        (should (equal '("Host" "Content-Type" "X-Amz-Date" "X-Amz-Security-Token" "Authorization" "X-Gateway-Team")
                       (mapcar #'car headers)))
        (should (equal "gateway.example.com:8443" (cdr (assoc "Host" headers))))
        (should (string-match-p "/eu-west-1/execute-api/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-security-token,"
                                (cdr (assoc "Authorization" headers)))))
      ;; An endpoint header replaces the provider's.
      (should (equal '(("authorization" . "Custom 1"))
                     (harness-bedrock--request-headers '(:id g :headers (("authorization" . "Custom 1"))) '(:type none)
                                                       "GET" url "" "us-east-1")))
      (should (equal '(("authorization" . "Custom 1"))
                     (harness-bedrock--request-headers '(:id g :headers (("authorization" . "Custom 1")))
                                                       '(:type bearer :token "t") "GET" url "" "us-east-1")))))
  ;; Secrets never reach an error.
  (should (equal "bad [redacted] and [redacted]"
                 (harness-bedrock--redact "bad SECRETSECRET and TOKENTOKEN"
                                          '(:secret-access-key "SECRETSECRET" :session-token "TOKENTOKEN")))))

;;;; Models

(defun harness-bedrock-test--listing-responses ()
  "Return fake responses for the model listing APIs, from the mock's data."
  (list (cons "/foundation-models" (list :status 200 :body (harness-json-encode harness-bedrock-mock-models)))
        (cons "type=APPLICATION" (list :status 200 :body "{\"inferenceProfileSummaries\":[]}"))
        (cons "type=SYSTEM_DEFINED&nextToken=1"
              (list :status 200 :body (harness-json-encode
                                       (list :inferenceProfileSummaries (list (nth 1 harness-bedrock-mock-profiles))))))
        (cons "type=SYSTEM_DEFINED"
              (list :status 200 :body (harness-json-encode
                                       (list :inferenceProfileSummaries (list (nth 0 harness-bedrock-mock-profiles))
                                             :nextToken "1"))))))

(ert-deftest harness-provider-bedrock-model-catalogue ()
  (harness-bedrock-test-with-keys
    (harness-bedrock-clear-models-cache)
    (unwind-protect
        (harness-bedrock-test-with-fake (harness-bedrock-test--listing-responses)
          (let* ((models (harness-test-await (harness-bedrock--models harness-bedrock-test-endpoint)))
                 (by-name (lambda (name) (cl-find name models :key (lambda (m) (plist-get m :name)) :test #'equal))))
            (should (equal '("Global Claude Opus 5.5" "Llama 3.1 8B Instruct" "Nova Pro" "US Anthropic Claude Sonnet 4.5")
                           (mapcar (lambda (m) (plist-get m :label)) models)))
            ;; Embedding models and models only reachable through a profile are left out.
            (should-not (funcall by-name "amazon.titan-embed-text-v2:0"))
            (should-not (funcall by-name "anthropic.claude-sonnet-4-5-20250929-v1:0"))
            (let ((sonnet (funcall by-name "us.anthropic.claude-sonnet-4-5-20250929-v1:0")))
              (should (= 200000 (plist-get sonnet :context-window)))
              (should (= 64000 (plist-get sonnet :max-output)))
              (should (equal '("text" "image") (plist-get sonnet :input-modalities)))
              (should (equal '("low" "medium" "high") (plist-get sonnet :thinking-levels)))
              (should (equal '(:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75) (plist-get sonnet :pricing)))
              (should (equal "anthropic.claude-sonnet-4-5-20250929-v1:0" (plist-get sonnet :base)))
              (should (eq t (plist-get (plist-get sonnet :capabilities) :prompt-caching))))
            (let ((opus (funcall by-name "global.anthropic.claude-opus-5-5")))
              (should (= 1000000 (plist-get opus :context-window)))
              (should (eq 'adaptive (plist-get opus :thinking-style))))
            (should (= 300000 (plist-get (funcall by-name "amazon.nova-pro-v1:0") :context-window)))
            (should (equal '("text" "image") (plist-get (funcall by-name "amazon.nova-pro-v1:0") :input-modalities)))
            (let ((llama (funcall by-name "meta.llama3-1-8b-instruct-v1:0")))
              (should (= 128000 (plist-get llama :context-window)))
              (should (equal '("text") (plist-get llama :input-modalities)))
              (should-not (plist-get llama :thinking-levels))
              (should-not (plist-get (plist-get llama :capabilities) :vision)))
            ;; Four signed GETs on the control plane: models, two pages of profiles, application profiles.
            (should (= 4 (length harness-bedrock-test--requests)))
            (dolist (r harness-bedrock-test--requests)
              (should (string-prefix-p "https://bedrock.us-east-1.amazonaws.com/" (plist-get r :url)))
              (should (string-prefix-p "AWS4-HMAC-SHA256 " (cdr (assoc "Authorization" (plist-get r :headers))))))
            ;; The second listing is served from the cache, and requests use what it knows.
            (harness-test-await (harness-bedrock--models harness-bedrock-test-endpoint))
            (should (= 4 (length harness-bedrock-test--requests)))
            (should (eq 'budget (plist-get (harness-bedrock--model-info harness-bedrock-test-endpoint
                                                                        "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
                                           :thinking-style)))
            ;; The provider normaliser builds full ids.
            (should (equal "testrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0"
                           (plist-get (harness-provider--normalise-model
                                       (make-harness-provider :id 'testrock :label "T")
                                       (funcall by-name "us.anthropic.claude-sonnet-4-5-20250929-v1:0"))
                                      :id)))))
      (harness-bedrock-clear-models-cache))))

(ert-deftest harness-provider-bedrock-model-catalogue-static-and-failing ()
  ;; Static models are not listed but filled in from the defaults.
  (harness-bedrock-test-with-env ()
    (harness-bedrock-clear-models-cache)
    (harness-bedrock-test-with-fake nil
      (let ((models (harness-test-await
                     (harness-bedrock--models '(:id gw :models ("us.anthropic.claude-haiku-4-5-20251001-v1:0"
                                                                (:name "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/xyz"
                                                                 :label "Team Sonnet" :base "anthropic.claude-sonnet-4-5-20250929-v1:0")
                                                                (:name "acme.mystery-v1" :context-window 8000)))))))
        (should-not harness-bedrock-test--requests)
        (should (equal '(200000 200000 8000) (mapcar (lambda (m) (plist-get m :context-window)) models)))
        (should (equal "Team Sonnet" (plist-get (nth 1 models) :label)))
        (should (equal '(:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75) (plist-get (nth 1 models) :pricing)))
        (should-not (plist-get (nth 2 models) :pricing))))
    (harness-bedrock-clear-models-cache))
  ;; Nothing configured: no request and no warning.
  (harness-bedrock-test-with-env ()
    (harness-bedrock-test-with-fake nil
      (should (null (harness-test-await (harness-bedrock--models '(:id quiet)))))
      (should-not harness-bedrock-test--requests)))
  ;; A failing listing resolves to nil with a warning and is not cached.
  (harness-bedrock-test-with-keys
    (harness-bedrock-test-with-fake '(("bedrock.us-east-1" . (:status 403 :body "{\"message\":\"not allowed to list\"}")))
      (let ((warnings nil))
        (let ((harness-log-hook (list (lambda (level msg) (when (eq level 'warn) (push msg warnings))))))
          (should (null (harness-test-await (harness-bedrock--models '(:id failing :region "us-east-1"))))))
        (should (cl-some (lambda (w) (string-match-p "ListFoundationModels failed: HTTP 403: not allowed to list" w))
                         warnings))
        (should-not (gethash 'failing harness-bedrock--models-cache))))))

(ert-deftest harness-provider-bedrock-registration ()
  (should (harness-provider-get 'bedrock))
  (should (equal "AWS Bedrock" (harness-provider-label (harness-provider-get 'bedrock))))
  (should (equal harness-bedrock-tiers (harness-provider-tiers (harness-provider-get 'bedrock))))
  (should (memq 'provider (harness-module-requires (harness-module-get 'provider-bedrock))))
  (let ((saved harness-bedrock-endpoints))
    (unwind-protect
        (progn
          (customize-set-variable 'harness-bedrock-endpoints
                                  (append saved '((:id work :label "Work" :region "eu-central-1")
                                                  (:id "Bad Id") (:label "no id"))))
          (should (harness-provider-get 'work))
          (should (string-match-p "bedrock-runtime.eu-central-1" (harness-provider-doc (harness-provider-get 'work))))
          (customize-set-variable 'harness-bedrock-endpoints saved)
          (should-not (harness-provider-get 'work))
          (should (harness-provider-get 'bedrock)))
      (setq harness-bedrock-endpoints saved)
      (harness-bedrock--register-all))))

;;;; End to end through curl

(defmacro harness-bedrock-test-with-mock (handler &rest body)
  "Run BODY with `mock' bound to a mock endpoint answering with HANDLER."
  (declare (indent 1))
  `(let ((mock (harness-bedrock-mock-start ,handler)))
     (unwind-protect (progn ,@body)
       (harness-bedrock-mock-stop mock))))

(ert-deftest harness-provider-bedrock-end-to-end-through-curl ()
  (skip-unless harness-http--curl-program)
  (harness-bedrock-test-with-env (("AWS_ACCESS_KEY_ID" harness-bedrock-mock-key-id)
                                  ("AWS_SECRET_ACCESS_KEY" harness-bedrock-mock-key-secret)
                                  ("AWS_SESSION_TOKEN" "session-token-EXAMPLE"))
    (harness-bedrock-test-with-mock #'harness-bedrock-mock-agent-handler
      (let* ((endpoint (harness-bedrock-mock-endpoint mock :id 'mockrock))
             (model "mockrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0")
             (tools '((:name "list_dir" :description "List a directory."
                       :schema (:type "object" :properties (:path (:type "string"))))))
             (first (car (harness-bedrock-test--complete
                          endpoint (list :model model :system "Working directory: /tmp/project/\n" :tools tools
                                         :messages '((:role user :content "please call `list_dir` now")))
                          10)))
             (call (cl-find 'tool-call first :key (lambda (e) (plist-get e :type)))))
        ;; The mock checked the signature, session token included.
        (should (equal '(nil) (mapcar (lambda (r) (plist-get r :auth-problem)) (harness-bedrock-mock-requests mock))))
        (should (equal "session-token-EXAMPLE"
                       (cdr (assoc "x-amz-security-token" (plist-get (car (harness-bedrock-mock-requests mock)) :headers)))))
        (should (equal "/model/us.anthropic.claude-sonnet-4-5-20250929-v1%3A0/converse-stream"
                       (plist-get (car (harness-bedrock-mock-requests mock)) :path)))
        (should (equal '(start text usage tool-call done) (harness-bedrock-test--types first)))
        (should (equal "Calling list_dir.\n" (harness-bedrock-test--text first)))
        (should (equal "list_dir" (plist-get call :name)))
        (should (equal '(:path "/tmp/project/") (plist-get call :input)))
        (should (= 1200 (plist-get (cl-find 'usage first :key (lambda (e) (plist-get e :type))) :input)))
        ;; The tool result goes back; the mock quotes it.
        (let ((second (car (harness-bedrock-test--complete
                            endpoint
                            (list :model model :system "Working directory: /tmp/project/\n" :tools tools
                                  :messages `((:role user :content "please call `list_dir` now")
                                              (:role assistant :content ((:type "text" :text "Calling list_dir.\n")
                                                                         (:type "tool_use" :id ,(plist-get call :id)
                                                                          :name "list_dir" :input ,(plist-get call :input))))
                                              (:role user :content ((:type "tool_result" :tool_use_id ,(plist-get call :id)
                                                                     :content "a.txt\nb.txt")))))
                            10))))
          (should (equal '(:type done :stop-reason end-turn) (car (last second))))
          (should (equal "The tool answered: a.txt\nb.txt" (harness-bedrock-test--text second))))
        ;; The catalogue through curl, signed too.
        (harness-bedrock-clear-models-cache)
        (unwind-protect
            (let ((models (harness-test-await (harness-bedrock--models endpoint) 10)))
              (should (= 4 (length models)))
              (should (cl-every (lambda (r) (null (plist-get r :auth-problem))) (harness-bedrock-mock-requests mock))))
          (harness-bedrock-clear-models-cache))
        ;; A wrong secret is refused by the mock, and said so.
        (with-environment-variables (("AWS_SECRET_ACCESS_KEY" "not-the-secret"))
          (let ((done (car (last (car (harness-bedrock-test--complete
                                       endpoint (list :model model :messages '((:role user :content "hi")))
                                       10))))))
            (should (eq 'error (plist-get done :stop-reason)))
            (should (string-match-p "HTTP 403 UnrecognizedClientException: Mock: signature mismatch" (plist-get done :error)))
            (should-not (string-search "not-the-secret" (plist-get done :error)))))))))

(ert-deftest harness-provider-bedrock-end-to-end-api-key ()
  (skip-unless harness-http--curl-program)
  (harness-bedrock-test-with-env (("AWS_BEARER_TOKEN_BEDROCK" harness-bedrock-mock-api-key))
    (harness-bedrock-test-with-mock #'harness-bedrock-mock-agent-handler
      (let ((events (car (harness-bedrock-test--complete
                          (harness-bedrock-mock-endpoint mock :id 'mockrock)
                          '(:model "mockrock:amazon.nova-pro-v1:0" :messages ((:role user :content "héllo ✓")))
                          10))))
        (should (equal "You said: héllo ✓" (harness-bedrock-test--text events)))
        (should (equal '(:type done :stop-reason end-turn) (car (last events))))
        (should (null (plist-get (car (harness-bedrock-mock-requests mock)) :auth-problem)))))))

;;;; A whole agent turn

(ert-deftest harness-provider-bedrock-agent-tool-round-trip ()
  "A session on a Bedrock model streams, calls a tool, answers, and records usage."
  (skip-unless harness-http--curl-program)
  (harness-bedrock-test-with-keys
    (harness-bedrock-test-with-mock #'harness-bedrock-mock-agent-handler
      (harness-test-with-temp-state
        (harness-test-reset-bus)
        (dolist (m '(store project config provider provider-bedrock tools session agent usage))
          (harness-test-load-module m))
        (unwind-protect
            (let ((harness-bedrock-endpoints (list (harness-bedrock-mock-endpoint mock :id 'mockrock :label "Mock Bedrock"))))
              (harness-bedrock--register-all)
              (clrhash harness-sessions)
              (clrhash harness-tools)
              (clrhash harness-agent--turns)
              (harness-bedrock-clear-models-cache)
              (harness-add-filter 'permission/decide
                                  (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
              (harness-define-tool "list_dir" :label "List directory" :description "List a directory." :kind 'read
                                   :schema '(:type "object" :properties (:path (:type "string")) :required ("path"))
                                   :handler (lambda (input _ctx) (format "listing of %s: a.txt" (plist-get input :path))))
              ;; The catalogue lists the Bedrock models with their context windows.
              (let* ((models (harness-await (harness-call 'provider/models t) 10))
                     (sonnet (cl-find "mockrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0" models
                                      :key (lambda (m) (plist-get m :id)) :test #'equal)))
                (should sonnet)
                (should (= 200000 (plist-get sonnet :context-window)))
                (should (equal "Mock Bedrock" (plist-get sonnet :provider-label))))
              (let* ((cwd (harness-test-temp-dir))
                     (id (plist-get (harness-call 'session/create :cwd cwd
                                                  :model "mockrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0")
                                    :id))
                     (result (harness-await (harness-call 'agent/prompt id "please call `list_dir` here") 20))
                     (nodes (harness-call 'session/nodes id)))
                (should (eq 'end-turn (plist-get result :stop-reason)))
                (should (equal '(user assistant tool-call tool-result assistant) (mapcar (lambda (n) (plist-get n :kind)) nodes)))
                (should (equal "list_dir" (plist-get (nth 2 nodes) :tool)))
                (should (string-match-p "listing of .*: a.txt" (plist-get (nth 3 nodes) :output)))
                (should (string-match-p "The tool answered: listing of" (plist-get (nth 4 nodes) :content)))
                ;; Usage: two calls with their tokens, priced from the catalogue.
                (let ((usage (plist-get (harness-call 'session/get id) :usage))
                      (totals (harness-call 'usage/totals :session id)))
                  (should (= 2700 (plist-get usage :input)))
                  (should (= 70 (plist-get usage :output)))
                  (should (= 1 (plist-get usage :turns)))
                  (should (= 2 (plist-get totals :calls)))
                  (should (= 2700 (plist-get totals :input)))
                  (should (= 70 (plist-get totals :output)))
                  (should (< (abs (- (plist-get totals :cost) (/ (+ (* 2700 3.0) (* 70 15.0)) 1e6))) 1e-9)))))
          ;; Back to the configured endpoints.
          (harness-bedrock--register-all)
          (harness-bedrock-clear-models-cache))))))

;;;; Integration

(defun harness-bedrock-test--integration-model ()
  "Return the model the integration tests use."
  (concat "bedrock:" (or (getenv "HARNESS_BEDROCK_TEST_MODEL") "us.anthropic.claude-haiku-4-5-20251001-v1:0")))

(defun harness-bedrock-test--run-live (request)
  "Send REQUEST through the bus and return its events oldest first."
  (let ((events nil))
    (harness-call 'provider/complete (plist-put (copy-sequence request) :on-event (lambda (e) (push e events))))
    (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type)))) 120 "live done")
    (reverse events)))

(ert-deftest harness-provider-bedrock-integration-text ()
  :tags '(integration)
  (harness-test-skip-unless-integration)
  (skip-unless (or (getenv "AWS_BEARER_TOKEN_BEDROCK") (getenv "AWS_ACCESS_KEY_ID") (getenv "AWS_PROFILE")))
  (let* ((events (harness-bedrock-test--run-live
                  (list :model (harness-bedrock-test--integration-model)
                        :system "You answer with a single word." :max-tokens 50
                        :messages '((:role user :content ((:type "text" :text "Say the word pong.")))))))
         (usage (cl-find 'usage events :key (lambda (e) (plist-get e :type)))))
    (should (equal '(:type done :stop-reason end-turn) (car (last events))))
    (should (string-match-p "pong" (downcase (harness-bedrock-test--text events))))
    (should (> (plist-get usage :input) 0))
    (should (> (plist-get usage :output) 0))))

(ert-deftest harness-provider-bedrock-integration-tool-round-trip ()
  :tags '(integration)
  (harness-test-skip-unless-integration)
  (skip-unless (or (getenv "AWS_BEARER_TOKEN_BEDROCK") (getenv "AWS_ACCESS_KEY_ID") (getenv "AWS_PROFILE")))
  (let* ((tools '((:name "echo" :description "Echo VALUE back through the tool runtime."
                   :schema (:type "object" :properties (:value (:type "string" :description "Text to echo"))
                            :required ("value")))))
         (user '(:role user :content ((:type "text" :text "Call the echo tool with the value \"marble\". Then report the tool's exact output back to me."))))
         (first (harness-bedrock-test--run-live
                 (list :model (harness-bedrock-test--integration-model) :tools tools :max-tokens 400
                       :messages (list user))))
         (call (cl-find 'tool-call first :key (lambda (e) (plist-get e :type)))))
    (should call)
    (should (equal "marble" (plist-get (plist-get call :input) :value)))
    (should (equal '(:type done :stop-reason tool-use) (car (last first))))
    (let* ((assistant (list :role 'assistant
                            :content (append
                                      (let ((text (harness-bedrock-test--text first)))
                                        (unless (string-empty-p text) (list (list :type "text" :text text))))
                                      (list (list :type "tool_use" :id (plist-get call :id)
                                                  :name "echo" :input (plist-get call :input))))))
           (result (list :role 'tool :content (list (list :type "tool_result" :tool_use_id (plist-get call :id)
                                                          :content "ZEBRA-4242"))))
           (second (harness-bedrock-test--run-live
                    (list :model (harness-bedrock-test--integration-model) :tools tools :max-tokens 400
                          :messages (list user assistant result)))))
      (should (equal '(:type done :stop-reason end-turn) (car (last second))))
      (should (string-match-p "ZEBRA-4242" (harness-bedrock-test--text second))))))

;;;; Customize types

(ert-deftest harness-provider-bedrock-types-name-every-key ()
  "The settings page offers every key of an endpoint and of a model family."
  (let ((endpoint harness-bedrock--endpoint-type)
        (family (cadr harness-bedrock--model-defaults-type)))
    (should (null (cl-set-difference (harness-test-documented-keys 'harness-bedrock-endpoints)
                                     (harness-test-option-keys endpoint))))
    (should (null (cl-set-difference (harness-test-documented-keys 'harness-bedrock--model-defaults)
                                     (harness-test-option-keys (car (last family))))))
    (harness-test-check-record-type endpoint)
    (harness-test-check-record-type (car (last family)))
    (should (memq :tiers (harness-test-option-keys endpoint)))
    (should (eq harness-provider-tiers-type (get 'harness-bedrock-tiers 'custom-type)))
    (should (harness-test-fits-p endpoint (plist-get (cdr endpoint) :value)))
    (should (harness-test-fits-p family (plist-get (cdr family) :value)))
    ;; The model tables are internal constants now (`docs/configuration-audit.md'),
    ;; so only the endpoint option still has a customize type of its own.
    (dolist (sym '(harness-bedrock-endpoints))
      (should (harness-test-fits-p (get sym 'custom-type) (eval (car (get sym 'standard-value)) t))))
    ;; Keys set in Lisp that the type does not name still fit.
    (should (harness-test-fits-p (get 'harness-bedrock-endpoints 'custom-type)
                                 '((:id x :list-models nil :inference-profiles :false :credentials ignore
                                    :models ("m" (:name "arn" :label "Mine" :base "b" :odd 1))))))
    (should (harness-test-fits-p harness-bedrock--model-defaults-type
                                 '(("x" :thinking-levels ("unheard-of") :foo 1) ("y"))))))

(provide 'harness-provider-bedrock-test)
;;; harness-provider-bedrock-test.el ends here
