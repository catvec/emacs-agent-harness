;;; harness-bedrock-mock.el --- A fake Bedrock endpoint for tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; A small HTTP/1.1 server inside Emacs that answers the way Amazon
;; Bedrock does, so the provider can be driven end to end through curl
;; without an AWS account: ConverseStream as a binary event stream,
;; Converse as JSON, ListFoundationModels and ListInferenceProfiles.
;; Every request's Signature Version 4 signature (or bearer token) is
;; checked against the example keys below.
;;
;; A test (or the manual check in the dev daemon) starts it with a
;; handler that maps each request to a response, and points an
;; endpoint's `:endpoint-url' and `:control-url' at it:
;;
;;   (harness-bedrock-mock-start #'harness-bedrock-mock-agent-handler)
;;
;; The keys are the example keys of the AWS documentation, not real
;; ones.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-util)
(require 'harness-provider-bedrock)

(defconst harness-bedrock-mock-key-id "AKIDEXAMPLE"
  "Access key id the mock accepts (the AWS documentation's example).")

(defconst harness-bedrock-mock-key-secret "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
  "Secret key the mock accepts (the AWS documentation's example).")

(defconst harness-bedrock-mock-api-key "bedrock-api-key-EXAMPLE"
  "Bearer token the mock accepts.")

(cl-defstruct (harness-bedrock-mock (:constructor harness-bedrock-mock--make) (:copier nil))
  "A running mock endpoint."
  server port handler (requests nil) (connections nil))

;;;; Event stream encoding

(defun harness-bedrock-mock--u32 (n)
  "Return N as four big-endian bytes."
  (unibyte-string (logand (ash n -24) 255) (logand (ash n -16) 255) (logand (ash n -8) 255) (logand n 255)))

(defun harness-bedrock-mock-encode (headers payload)
  "Encode one event stream message with string HEADERS and PAYLOAD.
HEADERS is an alist of (NAME . STRING-VALUE)."
  (let* ((block (apply #'concat
                       (mapcar (lambda (h)
                                 (let ((name (encode-coding-string (car h) 'utf-8 t))
                                       (value (encode-coding-string (cdr h) 'utf-8 t)))
                                   (concat (unibyte-string (length name)) name
                                           (unibyte-string 7 (ash (length value) -8) (logand (length value) 255))
                                           value)))
                               headers)))
         (payload (if (multibyte-string-p payload) (encode-coding-string payload 'utf-8 t) payload))
         (prelude (concat (harness-bedrock-mock--u32 (+ 16 (length block) (length payload)))
                          (harness-bedrock-mock--u32 (length block))))
         (message (concat prelude (harness-bedrock-mock--u32 (harness-bedrock--crc32 prelude)) block payload)))
    (concat message (harness-bedrock-mock--u32 (harness-bedrock--crc32 message)))))

(defun harness-bedrock-mock-event (type payload)
  "Return the encoded ConverseStream event TYPE carrying PAYLOAD (a plist).
Like Bedrock, the payload gets a padding field `p'."
  (harness-bedrock-mock-encode
   `((":event-type" . ,type) (":content-type" . "application/json") (":message-type" . "event"))
   (harness-json-encode (append payload '(:p "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNO")))))

(defun harness-bedrock-mock-exception (type message)
  "Return an encoded exception message of TYPE saying MESSAGE."
  (harness-bedrock-mock-encode
   `((":exception-type" . ,type) (":content-type" . "application/json") (":message-type" . "exception"))
   (harness-json-encode (list :message message))))

(defun harness-bedrock-mock-usage (input output &optional cache-read cache-write)
  "Return a metadata event with INPUT, OUTPUT, CACHE-READ and CACHE-WRITE tokens."
  (harness-bedrock-mock-event
   "metadata"
   (list :usage (list :inputTokens input :outputTokens output
                      :cacheReadInputTokens (or cache-read 0) :cacheWriteInputTokens (or cache-write 0)
                      :totalTokens (+ input output (or cache-read 0) (or cache-write 0)))
         :metrics '(:latencyMs 120))))

(defun harness-bedrock-mock-text-stream (text &optional input output stop)
  "Return the event stream bytes of a reply saying TEXT.
INPUT and OUTPUT are the token counts reported, STOP the stop reason."
  (concat
   (harness-bedrock-mock-event "messageStart" '(:role "assistant"))
   (apply #'concat
          (mapcar (lambda (piece)
                    (harness-bedrock-mock-event "contentBlockDelta"
                                                (list :contentBlockIndex 0 :delta (list :text piece))))
                  (harness-bedrock-mock--pieces text 5)))
   (harness-bedrock-mock-event "contentBlockStop" '(:contentBlockIndex 0))
   (harness-bedrock-mock-event "messageStop" (list :stopReason (or stop "end_turn")))
   (harness-bedrock-mock-usage (or input 10) (or output 5))))

(defun harness-bedrock-mock-tool-stream (text id name input &optional usage)
  "Return the event stream bytes of a reply saying TEXT, then calling tool NAME.
ID is the tool use id and INPUT its input (a plist); USAGE is
\(INPUT-TOKENS OUTPUT-TOKENS)."
  (concat
   (harness-bedrock-mock-event "messageStart" '(:role "assistant"))
   (harness-bedrock-mock-event "contentBlockDelta" (list :contentBlockIndex 0 :delta (list :text text)))
   (harness-bedrock-mock-event "contentBlockStop" '(:contentBlockIndex 0))
   (harness-bedrock-mock-event "contentBlockStart"
                               (list :contentBlockIndex 1 :start (list :toolUse (list :toolUseId id :name name))))
   (apply #'concat
          (mapcar (lambda (piece)
                    (harness-bedrock-mock-event "contentBlockDelta"
                                                (list :contentBlockIndex 1 :delta (list :toolUse (list :input piece)))))
                  (harness-bedrock-mock--pieces (harness-json-encode input) 4)))
   (harness-bedrock-mock-event "contentBlockStop" '(:contentBlockIndex 1))
   (harness-bedrock-mock-event "messageStop" '(:stopReason "tool_use"))
   (apply #'harness-bedrock-mock-usage (or usage '(20 8)))))

(defun harness-bedrock-mock--pieces (string size)
  "Split STRING into pieces of SIZE characters."
  (let (out)
    (while (> (length string) size)
      (push (substring string 0 size) out)
      (setq string (substring string size)))
    (nreverse (cons string out))))

;;;; Requests

(defun harness-bedrock-mock--parse-time (amz-date)
  "Return the Lisp time of AMZ-DATE, as in X-Amz-Date."
  (encode-time (list (string-to-number (substring amz-date 13 15))
                     (string-to-number (substring amz-date 11 13))
                     (string-to-number (substring amz-date 9 11))
                     (string-to-number (substring amz-date 6 8))
                     (string-to-number (substring amz-date 4 6))
                     (string-to-number (substring amz-date 0 4))
                     nil nil t)))

(defun harness-bedrock-mock--check-auth (mock request)
  "Return nil when REQUEST to MOCK is authenticated, else what is wrong with it."
  (let* ((headers (plist-get request :headers))
         (auth (cdr (assoc "authorization" headers))))
    (cond
     ((null auth) "no Authorization header")
     ((string-prefix-p "Bearer " auth)
      (unless (equal auth (concat "Bearer " harness-bedrock-mock-api-key)) "wrong API key"))
     ((string-match "\\`AWS4-HMAC-SHA256 Credential=\\([^/]+\\)/[0-9]+/\\([^/]+\\)/\\([^/]+\\)/aws4_request, SignedHeaders=\\([^,]+\\), Signature=\\([0-9a-f]+\\)\\'"
                    auth)
      (let* ((key-id (match-string 1 auth))
             (region (match-string 2 auth))
             (service (match-string 3 auth))
             (signature (match-string 5 auth))
             (signed (split-string (match-string 4 auth) ";"))
             (date (cdr (assoc "x-amz-date" headers)))
             (missing (cl-remove-if (lambda (h) (assoc h headers)) signed))
             (expected
              (and date (null missing)
                   (plist-get
                    (harness-bedrock-sigv4
                     :method (plist-get request :method)
                     :url (format "http://127.0.0.1:%d%s" (harness-bedrock-mock-port mock) (plist-get request :target))
                     :headers (cl-remove-if (lambda (h) (or (not (member (car h) signed))
                                                            (member (car h) '("x-amz-date" "x-amz-security-token"))))
                                            headers)
                     :body (plist-get request :body)
                     :access-key-id key-id :secret-access-key harness-bedrock-mock-key-secret
                     :session-token (cdr (assoc "x-amz-security-token" headers))
                     :region region :service service
                     :time (harness-bedrock-mock--parse-time date))
                    :signature))))
        (cond ((not (equal key-id harness-bedrock-mock-key-id)) "unknown access key id")
              ((null date) "no X-Amz-Date header")
              (missing (format "signed headers missing: %s" missing))
              ((not (member "host" signed)) "Host is not signed")
              ((not (equal signature expected)) "signature mismatch"))))
     (t "unknown authorization scheme"))))

(defun harness-bedrock-mock--respond (proc response)
  "Send RESPONSE, a plist, on connection PROC.
Keys: `:status', `:headers', `:body' (sent whole), `:chunks' (sent one
at a time, `:delay' seconds apart), or `:hang' to never answer."
  (unless (plist-get response :hang)
    (let* ((status (or (plist-get response :status) 200))
           (headers (append (list (cons "Content-Type" (or (plist-get response :content-type)
                                                            (if (plist-get response :chunks)
                                                                "application/vnd.amazon.eventstream"
                                                              "application/json")))
                                  (cons "Connection" "close"))
                            (plist-get response :headers)))
           (head (concat (format "HTTP/1.1 %d %s\r\n" status (if (< status 300) "OK" "Error"))
                         (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers "")
                         "\r\n"))
           (chunks (or (plist-get response :chunks)
                       (list (let ((b (or (plist-get response :body) "")))
                               (if (multibyte-string-p b) (encode-coding-string b 'utf-8 t) b)))))
           (delay (or (plist-get response :delay) 0.002)))
      (process-send-string proc head)
      (cl-labels ((next (rest)
                    (when (process-live-p proc)
                      (if (null rest)
                          (process-send-eof proc)
                        (process-send-string proc (car rest))
                        (run-at-time delay nil #'next (cdr rest))))))
        (next chunks)))))

(defun harness-bedrock-mock--handle (mock proc request)
  "Answer REQUEST, received by MOCK on PROC."
  (let ((problem (harness-bedrock-mock--check-auth mock request)))
    (setq request (plist-put request :auth-problem problem))
    (push request (harness-bedrock-mock-requests mock))
    (harness-bedrock-mock--respond
     proc
     (if problem
         (list :status 403 :headers '(("x-amzn-ErrorType" . "UnrecognizedClientException:http://internal.amazon.com/coral/com.amazon.coral.service/"))
               :body (harness-json-encode (list :message (format "Mock: %s" problem))))
       (condition-case err
           (funcall (harness-bedrock-mock-handler mock) request)
         (error (list :status 500 :body (harness-json-encode (list :message (format "Mock handler failed: %S" err))))))))))

(defun harness-bedrock-mock--filter (mock proc data)
  "Collect DATA arriving on connection PROC of MOCK; answer complete requests."
  (let ((buffer (concat (or (process-get proc 'buffer) "") data)))
    (process-put proc 'buffer buffer)
    (when (and (not (process-get proc 'handled)) (string-match "\r\n\r\n" buffer))
      (let* ((head-end (match-end 0))
             (lines (split-string (substring buffer 0 (match-beginning 0)) "\r\n"))
             (request-line (split-string (car lines) " "))
             (headers (mapcar (lambda (l)
                                (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" l)
                                  (cons (downcase (match-string 1 l)) (match-string 2 l))))
                              (cdr lines)))
             (headers (delq nil headers))
             (length (string-to-number (or (cdr (assoc "content-length" headers)) "0")))
             (body (substring buffer head-end)))
        (when (>= (length body) length)
          (process-put proc 'handled t)
          (let* ((target (nth 1 request-line))
                 (path (car (split-string target "?")))
                 (query (cadr (split-string target "?"))))
            (harness-bedrock-mock--handle
             mock proc
             (list :method (car request-line) :target target :path path :query query
                   :headers headers :body (substring body 0 length)
                   :json (ignore-errors (harness-json-parse (decode-coding-string (substring body 0 length) 'utf-8)))))))))))

(defun harness-bedrock-mock-start (handler)
  "Start a mock Bedrock endpoint on 127.0.0.1 answering with HANDLER.
HANDLER takes a request plist (:method :path :query :headers :body
:json) and returns a response plist (see `harness-bedrock-mock--respond').
Return the mock; `harness-bedrock-mock-url' gives its URL."
  (let* ((mock (harness-bedrock-mock--make :handler handler))
         (server (make-network-process
                  :name "harness-bedrock-mock" :server t :host "127.0.0.1" :service t
                  :family 'ipv4 :coding 'binary :noquery t
                  :filter (lambda (proc data) (harness-bedrock-mock--filter mock proc data))
                  :log (lambda (_server connection _message)
                         (set-process-query-on-exit-flag connection nil)
                         (push connection (harness-bedrock-mock-connections mock)))
                  :sentinel #'ignore)))
    (setf (harness-bedrock-mock-server mock) server
          (harness-bedrock-mock-port mock) (process-contact server :service))
    mock))

(defun harness-bedrock-mock-url (mock)
  "Return the base URL of MOCK."
  (format "http://127.0.0.1:%d" (harness-bedrock-mock-port mock)))

(defun harness-bedrock-mock-stop (mock)
  "Stop MOCK and close its connections."
  (dolist (p (harness-bedrock-mock-connections mock))
    (when (process-live-p p) (delete-process p)))
  (when (process-live-p (harness-bedrock-mock-server mock))
    (delete-process (harness-bedrock-mock-server mock))))

(defun harness-bedrock-mock-endpoint (mock &rest plist)
  "Return an endpoint plist pointing at MOCK, with PLIST added."
  (append plist (list :endpoint-url (harness-bedrock-mock-url mock)
                      :control-url (harness-bedrock-mock-url mock)
                      :region "us-east-1")))

;;;; A scripted agent

(defconst harness-bedrock-mock-models
  '(:modelSummaries
    ((:modelArn "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0"
      :modelId "anthropic.claude-sonnet-4-5-20250929-v1:0" :modelName "Claude Sonnet 4.5"
      :providerName "Anthropic" :inputModalities ("TEXT" "IMAGE") :outputModalities ("TEXT")
      :responseStreamingSupported t :inferenceTypesSupported ("INFERENCE_PROFILE")
      :modelLifecycle (:status "ACTIVE"))
     (:modelArn "arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-pro-v1:0"
      :modelId "amazon.nova-pro-v1:0" :modelName "Nova Pro" :providerName "Amazon"
      :inputModalities ("TEXT" "IMAGE" "VIDEO") :outputModalities ("TEXT")
      :responseStreamingSupported t :inferenceTypesSupported ("ON_DEMAND" "INFERENCE_PROFILE")
      :modelLifecycle (:status "ACTIVE"))
     (:modelArn "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"
      :modelId "amazon.titan-embed-text-v2:0" :modelName "Titan Text Embeddings V2" :providerName "Amazon"
      :inputModalities ("TEXT") :outputModalities ("EMBEDDING") :responseStreamingSupported :false
      :inferenceTypesSupported ("ON_DEMAND") :modelLifecycle (:status "ACTIVE"))
     (:modelArn "arn:aws:bedrock:us-east-1::foundation-model/meta.llama3-1-8b-instruct-v1:0"
      :modelId "meta.llama3-1-8b-instruct-v1:0" :modelName "Llama 3.1 8B Instruct" :providerName "Meta"
      :inputModalities ("TEXT") :outputModalities ("TEXT") :responseStreamingSupported t
      :inferenceTypesSupported ("ON_DEMAND") :modelLifecycle (:status "ACTIVE"))))
  "A ListFoundationModels answer.")

(defconst harness-bedrock-mock-profiles
  '((:inferenceProfileName "US Anthropic Claude Sonnet 4.5"
     :inferenceProfileId "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
     :inferenceProfileArn "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0"
     :models ((:modelArn "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0")
              (:modelArn "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0"))
     :status "ACTIVE" :type "SYSTEM_DEFINED")
    (:inferenceProfileName "Global Claude Opus 5.5"
     :inferenceProfileId "global.anthropic.claude-opus-5-5"
     :inferenceProfileArn "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-opus-5-5"
     :models ((:modelArn "arn:aws:bedrock:::foundation-model/anthropic.claude-opus-5-5"))
     :status "ACTIVE" :type "SYSTEM_DEFINED"))
  "System-defined inference profiles, served one per page.")

(defun harness-bedrock-mock-listing (request)
  "Answer the model listing REQUEST, or return nil when it is not one."
  (pcase (plist-get request :path)
    ("/foundation-models" (list :status 200 :body (harness-json-encode harness-bedrock-mock-models)))
    ("/inference-profiles"
     (let* ((query (or (plist-get request :query) ""))
            (application (string-match-p "type=APPLICATION" query))
            (page (if (string-match "nextToken=\\([^&]+\\)" query) (string-to-number (match-string 1 query)) 0))
            (profiles (if application nil harness-bedrock-mock-profiles)))
       (list :status 200
             :body (harness-json-encode
                    (append (list :inferenceProfileSummaries (harness-json-array
                                                              (let ((p (nth page profiles))) (and p (list p)))))
                            (when (< (1+ page) (length profiles))
                              (list :nextToken (number-to-string (1+ page)))))))))))

(defun harness-bedrock-mock--last-message (json)
  "Return the last message of the Converse request JSON."
  (car (last (plist-get json :messages))))

(defun harness-bedrock-mock-agent-handler (request)
  "Answer REQUEST like a model that calls a tool once, then reports its result.
A user message that names a tool in backquotes, as in \"call
\\=`list_dir\\=`\", gets that tool called with the session directory read
from the system prompt; a tool result gets a reply quoting it; anything
else is echoed.  Model listings are answered too."
  (or (harness-bedrock-mock-listing request)
      (let* ((json (plist-get request :json))
             (last (harness-bedrock-mock--last-message json))
             (result (cl-find-if (lambda (b) (plist-get b :toolResult)) (plist-get last :content)))
             (text (string-join (delq nil (mapcar (lambda (b) (plist-get b :text)) (plist-get last :content))) " "))
             (system (string-join (delq nil (mapcar (lambda (b) (plist-get b :text)) (plist-get json :system))) "\n"))
             (cwd (and (string-match "Working directory: \\([^\n]+\\)" system) (match-string 1 system)))
             (tool (and (string-match "`\\([a-z_]+\\)[`']" text) (match-string 1 text)))
             (stream (cond
                      (result
                       (harness-bedrock-mock-text-stream
                        (format "The tool answered: %s"
                                (harness-truncate-end
                                 (string-trim (or (plist-get (car (harness-plist-get-in result '(:toolResult :content)))
                                                             :text)
                                                  ""))
                                 120))
                        1500 40))
                      (tool
                       (harness-bedrock-mock-tool-stream
                        (format "Calling %s.\n" tool) (concat "tooluse_" (harness-short-id 10)) tool
                        (list :path (or cwd "/tmp")) '(1200 30)))
                      (t (harness-bedrock-mock-text-stream (format "You said: %s" text) 900 20)))))
        (list :status 200 :chunks (harness-bedrock-mock--pieces stream 37)))))

(provide 'harness-bedrock-mock)
;;; harness-bedrock-mock.el ends here
