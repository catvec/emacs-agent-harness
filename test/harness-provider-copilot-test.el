;;; harness-provider-copilot-test.el --- Tests for the GitHub Copilot CLI provider  -*- lexical-binding: t; -*-
;;; Commentary:

;; Unit tests drive the provider against test/fixtures/fake-copilot.py,
;; which speaks the CLI's headless JSON-RPC protocol without a network.
;; The integration test at the end talks to the real `copilot' and only
;; runs with HARNESS_INTEGRATION=1 and a logged-in CLI.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-provider)

(defvar harness-provider-copilot-program)
(defvar harness-provider-copilot-interrupt-timeout)
(defvar harness-provider-copilot-startup-timeout)
(defvar harness-provider-copilot-default-model)
(defvar harness-provider-copilot--sessions)
(defvar harness-provider-copilot--status)
(defvar harness-provider-copilot--asked)
(defvar harness-provider-copilot--refresh)
(defvar harness-provider-copilot--probe)
(defvar harness-provider-copilot--catalogue)
(declare-function harness-provider-copilot-close "harness-provider-copilot")
(declare-function harness-provider-copilot-close-all "harness-provider-copilot")
(declare-function harness-provider-copilot-session-process "harness-provider-copilot")
(declare-function harness-provider-copilot-session-main "harness-provider-copilot")
(declare-function harness-provider-copilot--make-session "harness-provider-copilot")
(declare-function harness-provider-copilot--drop-stale-entries "harness-provider-copilot")
(declare-function harness-provider-copilot--effort "harness-provider-copilot")
(declare-function harness-provider-copilot-frame "harness-provider-copilot")
(declare-function harness-provider-copilot-read-frames "harness-provider-copilot")
(declare-function harness-provider-copilot-prompt "harness-provider-copilot")
(declare-function harness-provider-copilot-call-usage "harness-provider-copilot")
(declare-function harness-provider-copilot-quota-changes "harness-provider-copilot")
(declare-function harness-provider-copilot-account-info "harness-provider-copilot")
(declare-function harness-provider-copilot-model-from-entry "harness-provider-copilot")
(declare-function harness-provider-copilot-tool-result "harness-provider-copilot")
(declare-function harness-provider-copilot-session-config "harness-provider-copilot")

(defvar harness-provider-copilot-test--dirs nil
  "Alist of (SESSION-ID . DIRECTORY), so a session keeps its directory.")

(defun harness-provider-copilot-test--setup ()
  "Fresh bus with the provider registry and the Copilot provider loaded.
Processes, the account status and the probe of earlier tests go."
  (harness-test-reset-bus)
  (harness-test-load-module 'provider)
  (harness-test-load-module 'provider-copilot)
  (setq harness-provider-copilot-program (harness-test-fixture "fake-copilot.py"))
  (harness-provider-copilot-close-all)
  (clrhash harness-provider-copilot--sessions)
  (clrhash harness-provider-copilot--catalogue)
  (setq harness-provider-copilot--status nil
        harness-provider-copilot--asked nil
        harness-provider-copilot--refresh nil
        harness-provider-copilot--probe nil
        harness-provider-copilot-test--dirs nil))

(defun harness-provider-copilot-test--near (a b)
  "Non-nil when numbers A and B are equal within rounding."
  (and (numberp a) (numberp b) (< (abs (- a b)) 1e-9)))

(defconst harness-provider-copilot-test--echo-tool
  '(:name "echo" :description "Echo TEXT back to the caller."
    :schema (:type "object"
             :properties (:text (:type "string" :description "Text to echo"))
             :required ("text")))
  "Tool spec passed directly in requests; no tool module is loaded.")

(defun harness-provider-copilot-test--session (sid)
  "Return the session plist of SID, with a directory of its own."
  (let ((dir (or (alist-get sid harness-provider-copilot-test--dirs nil nil #'equal)
                 (setf (alist-get sid harness-provider-copilot-test--dirs nil nil #'equal)
                       (harness-test-temp-dir)))))
    (list :id sid :cwd dir)))

(defun harness-provider-copilot-test--request (sid text &rest extra)
  "Build a request for session SID with user TEXT and EXTRA plist keys."
  (harness-plist-merge
   (list :model "copilot:gpt-5.4"
         :session (harness-provider-copilot-test--session sid)
         :system "You are a test agent"
         :messages (list (list :role 'user :content (list (list :type "text" :text text))))
         :tools (list harness-provider-copilot-test--echo-tool))
   extra))

(defun harness-provider-copilot-test--run (request &optional timeout on-tool)
  "Run REQUEST to completion; return (EVENTS . HANDLE).
Wait at most TIMEOUT seconds (default 10) for the done event.  ON-TOOL,
when given, is called with each tool-call event; by default the echo
tool is answered with \"echo: TEXT\"."
  (let (events)
    (setq request
          (plist-put (copy-sequence request) :on-event
                     (lambda (ev)
                       (push ev events)
                       (when (eq (plist-get ev :type) 'tool-call)
                         (if on-tool
                             (funcall on-tool ev)
                           (funcall (plist-get ev :respond)
                                    (list :content (format "echo: %s"
                                                           (plist-get (plist-get ev :input) :text))
                                          :is-error nil)))))))
    (let ((handle (harness-call 'provider/complete request)))
      (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type))))
                         (or timeout 10) "done event")
      (cons (nreverse events) handle))))

(defun harness-provider-copilot-test--types (events)
  "Return the list of event types in EVENTS."
  (mapcar (lambda (e) (plist-get e :type)) events))

(defun harness-provider-copilot-test--find (events type)
  "Return the first event of TYPE in EVENTS."
  (cl-find type events :key (lambda (e) (plist-get e :type))))

(defun harness-provider-copilot-test--text (events &optional type)
  "Concatenate the deltas of TYPE (default text) in EVENTS."
  (mapconcat (lambda (e) (if (eq (plist-get e :type) (or type 'text)) (plist-get e :delta) ""))
             events ""))

(defun harness-provider-copilot-test--done (events)
  "Return the stop reason of the done event in EVENTS."
  (plist-get (harness-provider-copilot-test--find events 'done) :stop-reason))

(defun harness-provider-copilot-test--log-file ()
  "Return a fresh path for the fixture's request log."
  (let ((file (make-temp-file "harness-copilot-log-")))
    (delete-file file)
    file))

(defun harness-provider-copilot-test--log (file)
  "Return what the fixture logged in FILE, oldest first."
  (when (file-exists-p file)
    (mapcar #'harness-json-parse (split-string (harness-read-file file) "\n" t))))

(defun harness-provider-copilot-test--requests (file method)
  "Return the params of every METHOD request logged in FILE."
  (delq nil (mapcar (lambda (e) (and (equal (plist-get e :method) method) (or (plist-get e :params) :empty)))
                    (harness-provider-copilot-test--log file))))

(defun harness-provider-copilot-test--starts (file)
  "Return the start records (argv, directory) of session processes logged in FILE.
The probe that lists models when the provider module starts runs in
`temporary-file-directory' itself and is left out."
  (let ((tmp (file-name-as-directory (file-truename temporary-file-directory))))
    (cl-remove-if-not (lambda (e)
                        (and (plist-get e :start)
                             (not (equal tmp (file-name-as-directory (file-truename (plist-get e :cwd)))))))
                      (harness-provider-copilot-test--log file))))

(defmacro harness-provider-copilot-test--with-env (vars &rest body)
  "Run BODY with the environment strings VARS added."
  (declare (indent 1))
  `(let ((process-environment (append ,vars process-environment)))
     ,@body))

(defun harness-provider-copilot-test--process (sid)
  "Return the CLI process serving SID, or nil."
  (when-let* ((entry (gethash sid harness-provider-copilot--sessions)))
    (harness-provider-copilot-session-process entry)))

;;;; Framing and conversions

(ert-deftest harness-provider-copilot-framing ()
  "Messages are framed by byte length and survive any split."
  (harness-provider-copilot-test--setup)
  (let* ((frame (harness-provider-copilot-frame '(:jsonrpc "2.0" :id 1 :method "x" :params (:text "héllo ✓"))))
         (sep (string-search "\r\n\r\n" frame)))
    (should-not (multibyte-string-p frame))
    (should (string-prefix-p "Content-Length: " frame))
    (should (= (string-to-number (substring frame (length "Content-Length: ") sep))
               (- (length frame) sep 4)))
    ;; Two messages and part of a third come back as two and a rest.
    (let* ((second (harness-provider-copilot-frame '(:jsonrpc "2.0" :id 2 :result (:ok t))))
           (out (harness-provider-copilot-read-frames (concat frame second (substring frame 0 30)))))
      (should (= 2 (length (car out))))
      (should (equal "héllo ✓" (harness-plist-get-in (harness-json-parse (car (car out))) '(:params :text))))
      (should (equal 2 (plist-get (harness-json-parse (cadr (car out))) :id)))
      (should (equal (substring frame 0 30) (cdr out))))
    ;; Byte by byte, through the multibyte characters.
    (let ((rest "") (bodies nil))
      (dotimes (i (length frame))
        (let ((out (harness-provider-copilot-read-frames (concat rest (substring frame i (1+ i))))))
          (setq bodies (append bodies (car out)) rest (cdr out))))
      (should (= 1 (length bodies)))
      (should (equal "héllo ✓" (harness-plist-get-in (harness-json-parse (car bodies)) '(:params :text))))
      (should (equal "" rest)))
    ;; Stray output and lower-case headers.
    (let ((out (harness-provider-copilot-read-frames
                (concat "Warning: stray output\r\n\r\n"
                        (replace-regexp-in-string "Content-Length" "content-length" frame)))))
      (should (= 1 (length (car out))))
      (should (equal "" (cdr out))))))

(ert-deftest harness-provider-copilot-prompt-from-trailing-messages ()
  "Only what follows the last assistant message is sent; images become blobs."
  (harness-provider-copilot-test--setup)
  (let ((img (make-temp-file "harness-img-" nil ".png")))
    (with-temp-file img (insert "png"))
    (unwind-protect
        (let ((prompt (harness-provider-copilot-prompt
                       (list :messages
                             (list '(:role user :content ((:type "text" :text "old")))
                                   '(:role assistant :content ((:type "text" :text "reply")))
                                   '(:role user :content ((:type "tool_result" :tool_use_id "x" :content "skip")))
                                   (list :role 'user :content
                                         (list '(:type "text" :text "new")
                                               '(:type "image" :mime "image/jpeg" :data "QUJD")
                                               (list :type "image" :path img)
                                               '(:type "file" :path "/tmp/notes.txt")
                                               '(:type "text" :text "more"))))))))
          (should (equal "new\n\n[attached file: /tmp/notes.txt]\n\nmore" (car prompt)))
          (should (= 2 (length (cdr prompt))))
          (should (equal '(:type "blob" :data "QUJD" :mimeType "image/jpeg" :displayName "image")
                         (car (cdr prompt))))
          (should (equal (base64-encode-string "png") (plist-get (cadr (cdr prompt)) :data)))
          (should (equal (file-name-nondirectory img) (plist-get (cadr (cdr prompt)) :displayName))))
      (delete-file img)))
  ;; An image alone still says something; nothing new says nothing.
  (should (equal "See the attached image."
                 (car (harness-provider-copilot-prompt
                       '(:messages ((:role user :content ((:type "image" :data "QUJD")))))))))
  (should-not (harness-provider-copilot-prompt
               '(:messages ((:role user :content ((:type "text" :text "hi")))
                            (:role assistant :content ((:type "text" :text "hello"))))))))

(ert-deftest harness-provider-copilot-session-config ()
  "Sessions get only the harness tools and the harness system prompt."
  (harness-provider-copilot-test--setup)
  (let* ((config (harness-provider-copilot-session-config
                  (harness-provider-copilot-test--request "cfg" "hi" :model "copilot:default"
                                                          :thinking "high")))
         (tool (aref (plist-get config :tools) 0)))
    (should (equal harness-provider-copilot-default-model (plist-get config :model)))
    (should (equal "high" (plist-get config :reasoningEffort)))
    (should (equal ["echo"] (plist-get config :availableTools)))
    (should (equal "echo" (plist-get tool :name)))
    (should (eq t (plist-get tool :skipPermission)))
    (should (eq t (plist-get tool :overridesBuiltInTool)))
    (should (equal "string" (harness-plist-get-in tool '(:parameters :properties :text :type))))
    (should (equal '(:mode "replace" :content "You are a test agent") (plist-get config :systemMessage)))
    (should (equal '(:enabled :false) (plist-get config :toolSearch)))
    (should (file-name-absolute-p (plist-get config :workingDirectory))))
  ;; Without tools nothing is available, built-in tools included.
  (let ((config (harness-provider-copilot-session-config
                 (harness-provider-copilot-test--request "cfg" "hi" :tools nil :system nil))))
    (should (equal [] (plist-get config :availableTools)))
    (should-not (plist-member config :systemMessage))
    (should-not (plist-member config :reasoningEffort))))

(ert-deftest harness-provider-copilot-effort-levels ()
  "Thinking levels map onto the efforts each model has."
  (harness-provider-copilot-test--setup)
  (puthash "claude-sonnet-5" '(:name "claude-sonnet-5" :thinking-levels ("low" "medium" "high"))
           harness-provider-copilot--catalogue)
  (puthash "gpt-5-mini" '(:name "gpt-5-mini") harness-provider-copilot--catalogue)
  (should (equal "medium" (harness-provider-copilot--effort "claude-sonnet-5" "medium")))
  (should (equal "high" (harness-provider-copilot--effort "claude-sonnet-5" "xhigh")))
  (should (equal "high" (harness-provider-copilot--effort "claude-sonnet-5" "max")))
  (should (equal "low" (harness-provider-copilot--effort "claude-sonnet-5" "minimal")))
  (should-not (harness-provider-copilot--effort "gpt-5-mini" "high"))
  (should (equal "max" (harness-provider-copilot--effort "unknown-model" "max")))
  (should-not (harness-provider-copilot--effort "claude-sonnet-5" nil)))

(ert-deftest harness-provider-copilot-call-usage ()
  "Usage counts uncached input as the CLI itself does."
  (harness-provider-copilot-test--setup)
  ;; Itemized usage wins.
  (let ((u (harness-provider-copilot-call-usage
            '(:model "gpt-5.4" :inputTokens 2112 :outputTokens 7 :cacheReadTokens 2000 :cacheWriteTokens 100
              :cost 1.0 :finishReason "stop"
              :copilotUsage (:totalNanoAiu 1500000000
                             :tokenDetails ((:tokenType "input" :tokenCount 12)
                                            (:tokenType "cache_read" :tokenCount 2000)
                                            (:tokenType "cache_write" :tokenCount 60)
                                            (:tokenType "cache_write_1h" :tokenCount 40)
                                            (:tokenType "output" :tokenCount 9)))))))
    (should (= 12 (plist-get u :input)))
    (should (= 2000 (plist-get u :cache-read)))
    (should (= 100 (plist-get u :cache-write)))
    (should (= 9 (plist-get u :output)))
    (should (= 2112 (plist-get u :context)))
    (should (= 1500000000 (plist-get u :nano-aiu)))
    (should (= 1.0 (plist-get u :requests)))
    (should (equal "stop" (plist-get u :finish))))
  ;; Without it, cached tokens come off the input total.
  (let ((u (harness-provider-copilot-call-usage
            '(:model "m" :inputTokens 500 :outputTokens 20 :cacheReadTokens 400 :cost 0.33))))
    (should (= 100 (plist-get u :input)))
    (should (= 400 (plist-get u :cache-read)))
    (should (= 0 (plist-get u :cache-write)))
    (should (= 500 (plist-get u :context)))
    (should-not (plist-get u :nano-aiu)))
  ;; Results for tools.
  (should (equal '(:textResultForLlm "ok" :resultType "success")
                 (harness-provider-copilot-tool-result '(:content "ok" :is-error nil))))
  (should (equal '(:textResultForLlm "no" :resultType "failure" :error "no")
                 (harness-provider-copilot-tool-result '(:content "no" :is-error t)))))

(ert-deftest harness-provider-copilot-model-conversion ()
  "models.list entries become catalogue entries."
  (harness-provider-copilot-test--setup)
  (let ((m (harness-provider-copilot-model-from-entry
            '(:id "claude-sonnet-5" :name "Claude Sonnet 5"
              :capabilities (:supports (:vision t :reasoningEffort t)
                             :limits (:max_prompt_tokens 168000 :max_output_tokens 32000))
              :policy (:state "enabled")
              :billing (:multiplier 1 :tokenPrices (:inputPrice 300 :outputPrice 1500 :cacheReadPrice 30
                                                    :cacheWritePrice 375 :batchSize 1000000))
              :supportedReasoningEfforts ("low" "medium" "high")))))
    (should (equal "claude-sonnet-5" (plist-get m :name)))
    (should (equal "Claude Sonnet 5" (plist-get m :label)))
    (should (= 200000 (plist-get m :context-window)))
    (should (= 32000 (plist-get m :max-output)))
    (should (equal '("text" "image") (plist-get m :input-modalities)))
    (should (equal '("low" "medium" "high") (plist-get m :thinking-levels)))
    (let ((p (plist-get m :pricing)))
      (should (harness-provider-copilot-test--near 3.0 (plist-get p :input)))
      (should (harness-provider-copilot-test--near 15.0 (plist-get p :output)))
      (should (harness-provider-copilot-test--near 0.3 (plist-get p :cache-read)))
      (should (harness-provider-copilot-test--near 3.75 (plist-get p :cache-write)))))
  (should-not (harness-provider-copilot-model-from-entry
               '(:id "secret" :capabilities nil :policy (:state "disabled"))))
  (let ((m (harness-provider-copilot-model-from-entry '(:id "gpt-5.4-mini" :capabilities nil))))
    (should (equal "GPT-5.4 mini" (plist-get m :label)))
    (should (equal '("text") (plist-get m :input-modalities)))
    (should-not (plist-get m :context-window))))

(ert-deftest harness-provider-copilot-account-and-quota ()
  "The auth status says who pays; quota snapshots become windows."
  (harness-provider-copilot-test--setup)
  (let ((info (harness-provider-copilot-account-info
               '(:isAuthenticated t :authType "user" :login "octocat" :host "https://github.com"
                 :copilotPlan "individual_pro_plus")))
        (out (harness-provider-copilot-account-info '(:isAuthenticated :false))))
    (should (eq 'subscription (plist-get info :billing)))
    (should (equal "pro_plus" (plist-get info :plan)))
    (should (equal "Copilot Pro+" (plist-get info :plan-label)))
    (should (equal "user" (plist-get info :auth)))
    (should (equal "octocat" (harness-plist-get-in info '(:account :login))))
    (should-not (plist-get out :billing)))
  (let* ((changes (harness-provider-copilot-quota-changes
                   '(:premium_interactions
                     (:isUnlimitedEntitlement :false :entitlementRequests 1500 :usedRequests 450
                      :remainingPercentage 70.0 :overage 0 :overageAllowedWithExhaustedQuota t
                      :usageAllowedWithExhaustedQuota t :resetDate "2026-11-01T00:00:00Z"
                      :tokenBasedBilling t :overageEntitlement 5000)
                     :chat (:isUnlimitedEntitlement t :entitlementRequests -1 :usedRequests 0
                            :remainingPercentage 100.0))))
         (windows (plist-get changes :windows))
         (w (car windows)))
    (should (= 1 (length windows)))
    (should (equal "credits" (plist-get w :name)))
    (should (equal "AI credits this month (450 of 1500)" (plist-get w :label)))
    (should (harness-provider-copilot-test--near 0.3 (plist-get w :used)))
    (should (= (float-time (parse-iso8601-time-string "2026-11-01T00:00:00Z")) (plist-get w :resets)))
    (should (plist-get changes :available))
    (should (eq t (harness-plist-get-in changes '(:extra :enabled))))
    (should (harness-provider-copilot-test--near 50.0 (harness-plist-get-in changes '(:extra :limit))))
    (should (equal "allowed" (plist-get changes :limit-status)))
    (should-not (plist-get changes :using-extra)))
  ;; Premium requests on the legacy billing, used up with extra usage on.
  (let* ((changes (harness-provider-copilot-quota-changes
                   '(:premium_interactions
                     (:entitlementRequests 300 :usedRequests 300 :remainingPercentage 0
                      :overage 25 :overageAllowedWithExhaustedQuota t))))
         (w (car (plist-get changes :windows))))
    (should (equal "premium" (plist-get w :name)))
    (should (= 1.0 (plist-get w :used)))
    (should (plist-get changes :using-extra))
    (should (harness-provider-copilot-test--near 1.0 (harness-plist-get-in changes '(:extra :used)))))
  ;; Used up without extra usage: calls are refused.
  (should (equal "rejected"
                 (plist-get (harness-provider-copilot-quota-changes
                             '(:premium_interactions (:entitlementRequests 50 :remainingPercentage 0
                                                      :overageAllowedWithExhaustedQuota :false)))
                            :limit-status))))

;;;; Catalogue

(ert-deftest harness-provider-copilot-models-and-capabilities ()
  "The catalogue comes from models.list through a probe that then exits."
  (harness-provider-copilot-test--setup)
  (let* ((models (harness-test-await (harness-call 'provider/models t) 20))
         (find (lambda (id) (cl-find id models :key (lambda (m) (plist-get m :id)) :test #'equal)))
         (gpt (funcall find "copilot:gpt-5.4"))
         (mini (funcall find "copilot:gpt-5-mini")))
    ;; The disabled model is left out and the default comes first.
    (should (= 3 (length models)))
    (should (equal "copilot:claude-sonnet-5" (plist-get (car models) :id)))
    (should-not (funcall find "copilot:secret-model"))
    (should (= 400000 (plist-get gpt :context-window)))
    (should (equal "GitHub Copilot" (plist-get gpt :provider-label)))
    (should (member "image" (plist-get gpt :input-modalities)))
    (should-not (member "image" (plist-get mini :input-modalities)))
    (should (equal '("low" "medium" "high" "xhigh") (plist-get gpt :thinking-levels)))
    (should (harness-provider-copilot-test--near 1.25 (plist-get (plist-get gpt :pricing) :input)))
    (should (harness-provider-copilot-test--near 10.0 (plist-get (plist-get gpt :pricing) :output)))
    (let ((caps (harness-call 'provider/capabilities "copilot:gpt-5.4")))
      (should (plist-get caps :hosted-loop))
      (should (plist-get caps :fork))
      (should (plist-get caps :vision))
      (should (eq 'hosted (plist-get caps :compaction))))
    (should-not (plist-get (harness-call 'provider/capabilities "copilot:gpt-5-mini") :vision))
    ;; Logging in told who pays.
    (should (eq 'subscription (plist-get harness-provider-copilot--status :billing)))
    (harness-test-wait (lambda () (null harness-provider-copilot--probe)) 15 "the probe to exit")))

(ert-deftest harness-provider-copilot-models-before-login ()
  "Before `copilot login' the CLI's built-in list of models stands in."
  (harness-provider-copilot-test--setup)
  (harness-provider-copilot-test--with-env '("HARNESS_FAKE_COPILOT_AUTH=none")
    (let ((models (harness-test-await (harness-call 'provider/models t) 20)))
      (should (equal '("copilot:claude-sonnet-5" "copilot:gpt-5.4-mini" "copilot:gemini-3.8-flash")
                     (mapcar (lambda (m) (plist-get m :id)) models)))
      (should (equal "GPT-5.4 mini" (plist-get (nth 1 models) :label)))
      (should (equal "Gemini 3.8 Flash" (plist-get (nth 2 models) :label))))))

;;;; Turns

(ert-deftest harness-provider-copilot-turn-with-hosted-tool-call ()
  (harness-provider-copilot-test--setup)
  (let* ((log (harness-provider-copilot-test--log-file))
         (request (harness-provider-copilot-test--request "s1" "please call echo with ping" :thinking "high")))
    (harness-provider-copilot-test--with-env (list (concat "HARNESS_FAKE_COPILOT_LOG=" log) "NODE_DEBUG=x")
      (let* ((events (car (harness-provider-copilot-test--run request)))
             (types (harness-provider-copilot-test--types events)))
        ;; Order: start, state, tool call, text, usage, done.
        (should (eq 'start (car types)))
        (should (< (cl-position 'provider-state types) (cl-position 'tool-call types)))
        (should (< (cl-position 'tool-call types) (cl-position 'text types)))
        (should (< (cl-position 'text types) (cl-position 'usage types)))
        (should (eq 'done (car (last types))))
        (should (= 1 (cl-count 'done types)))
        (should (eq 'end-turn (harness-provider-copilot-test--done events)))
        ;; The provider state names the Copilot session.
        (let ((state (plist-get (harness-provider-copilot-test--find events 'provider-state) :state)))
          (should (stringp (plist-get state :copilot-session-id)))
          (should (equal "gpt-5.4" (plist-get state :model)))
          (should-not (plist-get state :fork-pending)))
        ;; The tool call, served through :respond.
        (let ((call (harness-provider-copilot-test--find events 'tool-call)))
          (should (equal "echo" (plist-get call :name)))
          (should (equal "call_fake_1" (plist-get call :id)))
          (should (equal "ping" (plist-get (plist-get call :input) :text)))
          (should (functionp (plist-get call :respond))))
        ;; Deltas only: the complete messages repeat what streamed.
        (should (equal "hello" (harness-provider-copilot-test--text events)))
        (should (equal "hmm" (harness-provider-copilot-test--text events 'thinking)))
        ;; Two model calls, one credit each; the plan pays.
        (let ((u (harness-provider-copilot-test--find events 'usage)))
          (should (= 24 (plist-get u :input)))
          (should (= 14 (plist-get u :output)))
          (should (= 4000 (plist-get u :cache-read)))
          (should (= 200 (plist-get u :cache-write)))
          (should (= 2112 (plist-get u :context)))
          (should (eq 'subscription (plist-get u :billing)))
          (should (equal "pro" (plist-get u :plan)))
          (should (equal 0.0 (plist-get u :cost)))
          (should (harness-provider-copilot-test--near 0.02 (plist-get u :list-cost))))
        ;; The turn heard about the plan's quota.
        (should (equal "credits" (plist-get (car (plist-get (harness-provider-copilot-test--find events 'quota)
                                                            :windows))
                                            :name))))
      ;; What the fake was asked.
      (let* ((create (car (harness-provider-copilot-test--requests log "session.create")))
             (tool (car (plist-get create :tools))))
        (should (equal "gpt-5.4" (plist-get create :model)))
        (should (equal "high" (plist-get create :reasoningEffort)))
        (should (equal '("echo") (plist-get create :availableTools)))
        (should (equal "echo" (plist-get tool :name)))
        (should (eq t (plist-get tool :skipPermission)))
        (should (equal "replace" (harness-plist-get-in create '(:systemMessage :mode))))
        (should (equal "You are a test agent" (harness-plist-get-in create '(:systemMessage :content))))
        (should (eq t (plist-get create :streaming)))
        (should (equal (file-truename (plist-get (plist-get request :session) :cwd))
                       (file-name-as-directory (file-truename (plist-get create :workingDirectory))))))
      (let ((send (car (harness-provider-copilot-test--requests log "session.send"))))
        (should (equal "please call echo with ping" (plist-get send :prompt))))
      (let ((result (car (harness-provider-copilot-test--requests log "session.tools.handlePendingToolCall"))))
        (should (equal "req-1" (plist-get result :requestId)))
        (should (equal "echo: ping" (harness-plist-get-in result '(:result :textResultForLlm))))
        (should (equal "success" (harness-plist-get-in result '(:result :resultType)))))
      (let ((start (car (harness-provider-copilot-test--starts log))))
        (should (equal '("--headless" "--no-auto-update" "--stdio") (plist-get start :argv)))
        (should-not (plist-get start :node_debug))
        (should (equal (file-truename (plist-get (plist-get request :session) :cwd))
                       (file-name-as-directory (file-truename (plist-get start :cwd)))))))
    (harness-provider-copilot-close "s1")))

(ert-deftest harness-provider-copilot-second-turn-reuses-process-and-session ()
  (harness-provider-copilot-test--setup)
  (let ((log (harness-provider-copilot-test--log-file)))
    (harness-provider-copilot-test--with-env (list (concat "HARNESS_FAKE_COPILOT_LOG=" log))
      (let* ((first (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s2" "hi"))))
             (proc1 (harness-provider-copilot-test--process "s2"))
             (id (plist-get (plist-get (harness-provider-copilot-test--find first 'provider-state) :state)
                            :copilot-session-id))
             (second (car (harness-provider-copilot-test--run
                           (harness-provider-copilot-test--request
                            "s2" "again"
                            :provider-state (list :copilot-session-id id)
                            :messages (list '(:role user :content ((:type "text" :text "hi")))
                                            '(:role assistant :content ((:type "text" :text "hello")))
                                            '(:role user :content ((:type "text" :text "call echo again")))))))))
        (should (process-live-p proc1))
        (should (eq proc1 (harness-provider-copilot-test--process "s2")))
        (should (eq 'end-turn (harness-provider-copilot-test--done first)))
        (should (eq 'end-turn (harness-provider-copilot-test--done second)))
        ;; Only the new message went out, and it took the tool path.
        (should (harness-provider-copilot-test--find second 'tool-call))
        (should (equal '("hi" "call echo again")
                       (mapcar (lambda (p) (plist-get p :prompt))
                               (harness-provider-copilot-test--requests log "session.send"))))
        ;; One process, one session: nothing was opened twice.
        (should (= 1 (length (harness-provider-copilot-test--starts log))))
        (should (= 1 (length (harness-provider-copilot-test--requests log "session.create"))))
        (should-not (harness-provider-copilot-test--requests log "session.resume"))
        (harness-provider-copilot-close "s2")
        (should-not (process-live-p proc1))))))

(ert-deftest harness-provider-copilot-settings-change-applies-in-place ()
  "A new thinking level resumes the open session again, in the same process."
  (harness-provider-copilot-test--setup)
  (let ((log (harness-provider-copilot-test--log-file)))
    (harness-provider-copilot-test--with-env (list (concat "HARNESS_FAKE_COPILOT_LOG=" log))
      (let* ((first (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s3" "hi"))))
             (id (plist-get (plist-get (harness-provider-copilot-test--find first 'provider-state) :state)
                            :copilot-session-id))
             (proc1 (harness-provider-copilot-test--process "s3")))
        (harness-provider-copilot-test--run
         (harness-provider-copilot-test--request "s3" "hi" :thinking "low" :provider-state (list :copilot-session-id id)))
        (should (eq proc1 (harness-provider-copilot-test--process "s3")))
        (let ((resume (harness-provider-copilot-test--requests log "session.resume")))
          (should (= 1 (length resume)))
          (should (equal id (plist-get (car resume) :sessionId)))
          (should (equal "low" (plist-get (car resume) :reasoningEffort))))))
    (harness-provider-copilot-close "s3")))

(ert-deftest harness-provider-copilot-resume-after-restart ()
  "The provider state's session is resumed in a new process."
  (harness-provider-copilot-test--setup)
  (let ((log (harness-provider-copilot-test--log-file)))
    (harness-provider-copilot-test--with-env (list (concat "HARNESS_FAKE_COPILOT_LOG=" log))
      (let ((events (car (harness-provider-copilot-test--run
                          (harness-provider-copilot-test--request
                           "s4" "hi" :provider-state '(:copilot-session-id "old-9" :model "gpt-5.4"))))))
        (should (eq 'end-turn (harness-provider-copilot-test--done events)))
        (should (equal "old-9" (plist-get (plist-get (harness-provider-copilot-test--find events 'provider-state) :state)
                                          :copilot-session-id)))
        (should (equal '("old-9") (mapcar (lambda (p) (plist-get p :sessionId))
                                          (harness-provider-copilot-test--requests log "session.resume"))))
        (should-not (harness-provider-copilot-test--requests log "session.create"))))
    (should (harness-provider-copilot-close "s4"))
    (should-not (harness-provider-copilot-close "s4"))))

(ert-deftest harness-provider-copilot-resume-failure-starts-over ()
  "A conversation the CLI cannot find gives way to a new one, with a hint."
  (harness-provider-copilot-test--setup)
  (let* ((events (car (harness-provider-copilot-test--run
                       (harness-provider-copilot-test--request
                        "s5" "hi" :provider-state '(:copilot-session-id "missing-1")))))
         (hint (harness-provider-copilot-test--find events 'hint))
         (state (plist-get (harness-provider-copilot-test--find events 'provider-state) :state)))
    (should (string-match-p "could not resume" (plist-get hint :text)))
    (should (string-match-p "Session not found" (plist-get hint :text)))
    (should (stringp (plist-get state :copilot-session-id)))
    (should-not (equal "missing-1" (plist-get state :copilot-session-id)))
    (should (eq 'end-turn (harness-provider-copilot-test--done events))))
  (harness-provider-copilot-close "s5"))

(ert-deftest harness-provider-copilot-fork-copies-the-session ()
  (harness-provider-copilot-test--setup)
  (let ((state (harness-test-await (harness-call 'provider/fork "copilot:gpt-5.4"
                                                 '(:copilot-session-id "parent-1" :model "gpt-5.4"))))
        (log (harness-provider-copilot-test--log-file)))
    (should (equal "parent-1" (plist-get state :copilot-session-id)))
    (should (plist-get state :fork-pending))
    (should (null (harness-test-await (harness-call 'provider/fork "copilot:gpt-5.4" nil))))
    (harness-provider-copilot-test--with-env (list (concat "HARNESS_FAKE_COPILOT_LOG=" log))
      (let* ((events (car (harness-provider-copilot-test--run
                           (harness-provider-copilot-test--request "child" "hi" :provider-state state))))
             (new (plist-get (harness-provider-copilot-test--find events 'provider-state) :state)))
        (should (equal '("parent-1") (mapcar (lambda (p) (plist-get p :sessionId))
                                             (harness-provider-copilot-test--requests log "sessions.fork"))))
        (should (string-prefix-p "fork-" (plist-get new :copilot-session-id)))
        (should (equal (plist-get new :copilot-session-id)
                       (plist-get (car (harness-provider-copilot-test--requests log "session.resume")) :sessionId)))
        (should-not (plist-get new :fork-pending))
        (should (eq 'end-turn (harness-provider-copilot-test--done events)))
        ;; The fork is the child's own conversation: it stays.
        (should-not (harness-provider-copilot-test--requests log "sessions.delete"))))
    (harness-provider-copilot-close "child")))

(ert-deftest harness-provider-copilot-side-request-on-a-fork ()
  "A request on a fork of the live conversation (session naming) runs beside it."
  (harness-provider-copilot-test--setup)
  (let ((log (harness-provider-copilot-test--log-file)))
    (harness-provider-copilot-test--with-env (list (concat "HARNESS_FAKE_COPILOT_LOG=" log))
      (let* ((first (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s6" "hi"))))
             (main (plist-get (plist-get (harness-provider-copilot-test--find first 'provider-state) :state)
                              :copilot-session-id))
             (proc (harness-provider-copilot-test--process "s6"))
             (fork (harness-test-await (harness-call 'provider/fork "copilot:gpt-5.4"
                                                     (list :copilot-session-id main))))
             (side (car (harness-provider-copilot-test--run
                         (harness-provider-copilot-test--request
                          "s6" "Give the conversation a title" :tools nil :system "You write titles"
                          :provider-state fork)))))
        (should (equal "hello" (harness-provider-copilot-test--text side)))
        (should (eq 'end-turn (harness-provider-copilot-test--done side)))
        ;; Nothing to persist, nothing restarted, and the fork goes away.
        (should-not (harness-provider-copilot-test--find side 'provider-state))
        (should (eq proc (harness-provider-copilot-test--process "s6")))
        (should (equal main (harness-provider-copilot-session-main (gethash "s6" harness-provider-copilot--sessions))))
        (let ((fork-id (plist-get (car (harness-provider-copilot-test--requests log "session.resume")) :sessionId)))
          (should (string-prefix-p "fork-" fork-id))
          (harness-test-wait (lambda () (harness-provider-copilot-test--requests log "sessions.delete")) 5 "delete")
          (should (equal fork-id (plist-get (car (harness-provider-copilot-test--requests log "session.detach"))
                                            :sessionId)))
          (should (equal fork-id (plist-get (car (harness-provider-copilot-test--requests log "sessions.delete"))
                                            :sessionId))))
        ;; The side session had no tools at all.
        (should (equal nil (plist-get (car (harness-provider-copilot-test--requests log "session.resume"))
                                      :availableTools)))
        ;; The conversation carries on where it was.
        (let ((third (car (harness-provider-copilot-test--run
                           (harness-provider-copilot-test--request
                            "s6" "more" :provider-state (list :copilot-session-id main))))))
          (should (eq 'end-turn (harness-provider-copilot-test--done third)))
          (should (eq proc (harness-provider-copilot-test--process "s6")))
          (should (equal (list main (plist-get (car (harness-provider-copilot-test--requests log "session.resume"))
                                               :sessionId)
                               main)
                         (mapcar (lambda (p) (plist-get p :sessionId))
                                 (harness-provider-copilot-test--requests log "session.send"))))
          (should (= 1 (length (harness-provider-copilot-test--requests log "session.resume")))))))
    (harness-provider-copilot-close "s6")))

(ert-deftest harness-provider-copilot-cancel-aborts-the-turn ()
  (harness-provider-copilot-test--setup)
  (let* ((log (harness-provider-copilot-test--log-file))
         events
         (request (plist-put (harness-provider-copilot-test--request "s7" "hang here")
                             :on-event (lambda (ev) (push ev events)))))
    (harness-provider-copilot-test--with-env (list (concat "HARNESS_FAKE_COPILOT_LOG=" log))
      (let ((handle (harness-call 'provider/complete request)))
        (harness-test-wait (lambda () (harness-provider-copilot-test--find events 'text)) 10 "first delta")
        (funcall (plist-get handle :cancel))
        (funcall (plist-get handle :cancel))
        (harness-test-wait (lambda () (harness-provider-copilot-test--find events 'done)) 10 "done")
        (accept-process-output nil 0.2)
        (should (= 1 (cl-count 'done (harness-provider-copilot-test--types events))))
        (should (eq 'cancelled (harness-provider-copilot-test--done events)))
        (should (= 1 (length (harness-provider-copilot-test--requests log "session.abort"))))
        ;; The process survived the abort and serves the next turn.
        (let ((proc (harness-provider-copilot-test--process "s7")))
          (should (process-live-p proc))
          (let ((again (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s7" "hi")))))
            (should (eq 'end-turn (harness-provider-copilot-test--done again)))
            (should (eq proc (harness-provider-copilot-test--process "s7")))))))
    (harness-provider-copilot-close "s7")))

(ert-deftest harness-provider-copilot-cancel-kills-when-abort-ignored ()
  (harness-provider-copilot-test--setup)
  (let* ((harness-provider-copilot-interrupt-timeout 0.3)
         (log (harness-provider-copilot-test--log-file))
         events
         (request (plist-put (harness-provider-copilot-test--request "s8" "hang ignore")
                             :on-event (lambda (ev) (push ev events)))))
    (harness-provider-copilot-test--with-env (list (concat "HARNESS_FAKE_COPILOT_LOG=" log))
      (let* ((handle (harness-call 'provider/complete request))
             (proc (progn (harness-test-wait (lambda () (harness-provider-copilot-test--find events 'text)) 10 "first delta")
                          (harness-provider-copilot-test--process "s8"))))
        (funcall (plist-get handle :cancel))
        (harness-test-wait (lambda () (harness-provider-copilot-test--find events 'done)) 10 "done")
        (accept-process-output nil 0.2)
        (should (= 1 (cl-count 'done (harness-provider-copilot-test--types events))))
        (should (eq 'cancelled (harness-provider-copilot-test--done events)))
        (should-not (process-live-p proc))
        ;; The next turn resumes the conversation in a new process.
        (let* ((id (plist-get (plist-get (harness-provider-copilot-test--find events 'provider-state) :state)
                              :copilot-session-id))
               (again (car (harness-provider-copilot-test--run
                            (harness-provider-copilot-test--request
                             "s8" "hi" :provider-state (list :copilot-session-id id))))))
          (should (eq 'end-turn (harness-provider-copilot-test--done again)))
          (should (= 2 (length (harness-provider-copilot-test--starts log))))
          (should (equal (list id) (mapcar (lambda (p) (plist-get p :sessionId))
                                           (harness-provider-copilot-test--requests log "session.resume")))))))
    (harness-provider-copilot-close "s8")))

(ert-deftest harness-provider-copilot-cancel-during-a-tool-call ()
  "A turn cancelled while the harness runs a tool ends once; a late result is harmless."
  (harness-provider-copilot-test--setup)
  (let* (events respond handle)
    (setq handle (harness-call
                  'provider/complete
                  (plist-put (harness-provider-copilot-test--request "s9" "call echo")
                             :on-event (lambda (ev)
                                         (push ev events)
                                         (when (eq (plist-get ev :type) 'tool-call)
                                           (setq respond (plist-get ev :respond))
                                           (harness-run-soon (lambda () (funcall (plist-get handle :cancel)))))))))
    (harness-test-wait (lambda () (harness-provider-copilot-test--find events 'done)) 10 "done")
    (should (eq 'cancelled (harness-provider-copilot-test--done events)))
    (should (= 1 (cl-count 'done (harness-provider-copilot-test--types events))))
    (funcall respond '(:content "late" :is-error nil))
    (accept-process-output nil 0.2)
    (should (process-live-p (harness-provider-copilot-test--process "s9")))
    ;; The conversation goes on.
    (let ((again (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s9" "hi")))))
      (should (eq 'end-turn (harness-provider-copilot-test--done again)))))
  (harness-provider-copilot-close "s9"))

(ert-deftest harness-provider-copilot-process-death-is-an-error ()
  (harness-provider-copilot-test--setup)
  (let* ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s10" "die now"))))
         (done (harness-provider-copilot-test--find events 'done)))
    (should (eq 'error (plist-get done :stop-reason)))
    (should (string-match-p "exited with status 3" (plist-get done :error)))
    (should (string-match-p "dying on request" (plist-get done :error)))
    ;; The next turn starts a new process transparently.
    (let ((again (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s10" "hi")))))
      (should (eq 'end-turn (harness-provider-copilot-test--done again)))))
  (harness-provider-copilot-close "s10"))

(ert-deftest harness-provider-copilot-turn-errors-and-limits ()
  "A session error ends the turn with it; the output limit says max-tokens."
  (harness-provider-copilot-test--setup)
  (let* ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s11" "fail please"))))
         (done (harness-provider-copilot-test--find events 'done)))
    (should (eq 'error (plist-get done :stop-reason)))
    (should (equal "Copilot: You have no AI credits left" (plist-get done :error))))
  (let ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s11" "long answer")))))
    (should (eq 'max-tokens (harness-provider-copilot-test--done events))))
  (let* ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s11" "compact first"))))
         (hints (mapcar (lambda (e) (plist-get e :text))
                        (cl-remove-if-not (lambda (e) (eq (plist-get e :type) 'hint)) events))))
    (should (cl-some (lambda (h) (string-match-p "Context compacted by Copilot: 150k → 12.0k tokens" h)) hints))
    (should (eq 'end-turn (harness-provider-copilot-test--done events))))
  (harness-provider-copilot-close "s11"))

(ert-deftest harness-provider-copilot-permission-requests-are-answered ()
  "The harness's own tools are approved: the harness asks the user itself."
  (harness-provider-copilot-test--setup)
  (let ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s12" "permission")))))
    (should (equal "approve-once hello" (harness-provider-copilot-test--text events)))
    (should (eq 'end-turn (harness-provider-copilot-test--done events))))
  (harness-provider-copilot-close "s12"))

(ert-deftest harness-provider-copilot-images-go-as-attachments ()
  (harness-provider-copilot-test--setup)
  (let ((log (harness-provider-copilot-test--log-file)))
    (harness-provider-copilot-test--with-env (list (concat "HARNESS_FAKE_COPILOT_LOG=" log))
      (harness-provider-copilot-test--run
       (harness-provider-copilot-test--request
        "s13" "x" :messages (list '(:role user :content ((:type "text" :text "what is this?")
                                                         (:type "image" :mime "image/png" :data "QUJD"))))))
      (let ((send (car (harness-provider-copilot-test--requests log "session.send"))))
        (should (equal "what is this?" (plist-get send :prompt)))
        (should (equal '((:type "blob" :data "QUJD" :mimeType "image/png" :displayName "image"))
                       (plist-get send :attachments))))))
  (harness-provider-copilot-close "s13"))

;;;; Clear errors

(ert-deftest harness-provider-copilot-not-logged-in ()
  "A CLI that is not logged in says so at once, and keeps no process."
  (harness-provider-copilot-test--setup)
  (harness-provider-copilot-test--with-env '("HARNESS_FAKE_COPILOT_AUTH=none")
    (let* ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s14" "hi"))))
           (done (harness-provider-copilot-test--find events 'done)))
      (should (eq 'error (plist-get done :stop-reason)))
      (should (string-match-p "not logged in" (plist-get done :error)))
      (should (string-match-p "copilot login" (plist-get done :error)))
      (should-not (harness-provider-copilot-test--find events 'provider-state))
      (should-not (process-live-p (harness-provider-copilot-test--process "s14")))))
  ;; Logged in later, the same session works.
  (let ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s14" "hi")))))
    (should (eq 'end-turn (harness-provider-copilot-test--done events))))
  (harness-provider-copilot-close "s14"))

(ert-deftest harness-provider-copilot-missing-program ()
  "Without the program there are no models and turns say how to install it."
  (harness-provider-copilot-test--setup)
  (setq harness-provider-copilot-program "/nonexistent/bin/copilot")
  (should-not (harness-test-await (harness-call 'provider/models t)))
  (let* ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s15" "hi"))))
         (done (harness-provider-copilot-test--find events 'done)))
    (should (eq 'error (plist-get done :stop-reason)))
    (should (string-match-p "not found" (plist-get done :error)))
    (should (string-match-p "npm install -g @github/copilot" (plist-get done :error))))
  (harness-provider-copilot-close "s15"))

(ert-deftest harness-provider-copilot-protocol-versions ()
  "Too old a protocol is refused with advice; a CLI without `connect' is asked with `ping'."
  (harness-provider-copilot-test--setup)
  (harness-provider-copilot-test--with-env '("HARNESS_FAKE_COPILOT_PROTOCOL=2")
    (let ((done (harness-provider-copilot-test--find
                 (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s16" "hi")))
                 'done)))
      (should (eq 'error (plist-get done :stop-reason)))
      (should (string-match-p "speaks protocol 2" (plist-get done :error)))
      (should (string-match-p "copilot update" (plist-get done :error)))))
  (harness-provider-copilot-close "s16")
  (harness-provider-copilot-test--with-env '("HARNESS_FAKE_COPILOT_NO_CONNECT=1")
    (let ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s16" "hi")))))
      (should (eq 'end-turn (harness-provider-copilot-test--done events)))))
  (harness-provider-copilot-close "s16"))

(ert-deftest harness-provider-copilot-startup-timeout ()
  "A program that never answers is given up on instead of hanging the turn."
  (harness-provider-copilot-test--setup)
  (let ((harness-provider-copilot-startup-timeout 0.5))
    (harness-provider-copilot-test--with-env '("HARNESS_FAKE_COPILOT_SILENT=1")
      (let* ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s17" "hi") 10)))
             (done (harness-provider-copilot-test--find events 'done)))
        (should (eq 'error (plist-get done :stop-reason)))
        (should (string-match-p "did not answer within" (plist-get done :error)))
        (should-not (process-live-p (harness-provider-copilot-test--process "s17"))))))
  (harness-provider-copilot-close "s17"))

;;;; Billing and quota

(ert-deftest harness-provider-copilot-quota-report ()
  "`provider/quota' reports the plan and its monthly allowance."
  (harness-provider-copilot-test--setup)
  (let ((updates nil))
    (harness-on 'provider/quota-updated (lambda (pid quota) (push (cons pid quota) updates)))
    (let* ((q (harness-test-await (harness-call 'provider/quota "copilot" t) 20))
           (w (car (plist-get q :windows))))
      (should (eq 'subscription (plist-get q :billing)))
      (should (equal "pro" (plist-get q :plan)))
      (should (equal "Copilot Pro" (plist-get q :plan-label)))
      (should (equal "octocat" (harness-plist-get-in q '(:account :login))))
      (should (= 1 (length (plist-get q :windows))))
      (should (equal "credits" (plist-get w :name)))
      (should (harness-provider-copilot-test--near 0.3 (plist-get w :used)))
      (should (harness-provider-copilot-test--near 50.0 (harness-plist-get-in q '(:extra :limit))))
      (should (numberp (plist-get q :updated)))
      (should-not (plist-get q :using-extra))
      (should (eq 'copilot (car (car updates))))
      ;; A fresh report is not fetched again.
      (should (eq q (harness-test-await (harness-call 'provider/quota 'copilot)))))
    (harness-test-wait (lambda () (null harness-provider-copilot--probe)) 15 "the probe to exit")))

(ert-deftest harness-provider-copilot-extra-usage-is-billed ()
  "Past the allowance with extra usage on, turns cost their credits."
  (harness-provider-copilot-test--setup)
  (harness-provider-copilot-test--with-env '("HARNESS_FAKE_COPILOT_EXHAUSTED=1")
    (let* ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s18" "hi"))))
           (u (harness-provider-copilot-test--find events 'usage)))
      (should (eq 'extra-usage (plist-get u :billing)))
      (should (harness-provider-copilot-test--near 0.01 (plist-get u :cost)))
      (should (harness-provider-copilot-test--near 0.01 (plist-get u :list-cost)))
      (should (plist-get (harness-test-await (harness-call 'provider/quota 'copilot)) :using-extra))))
  (harness-provider-copilot-close "s18"))

(ert-deftest harness-provider-copilot-premium-request-billing ()
  "Calls reported only in premium requests are left for the catalogue to price."
  (harness-provider-copilot-test--setup)
  (harness-provider-copilot-test--with-env '("HARNESS_FAKE_COPILOT_LEGACY=1")
    (let* ((events (car (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s19" "hi"))))
           (u (harness-provider-copilot-test--find events 'usage))
           (q (harness-provider-copilot-test--find events 'quota)))
      (should (eq 'subscription (plist-get u :billing)))
      (should (equal 0.0 (plist-get u :cost)))
      (should (plist-member u :list-cost))
      (should-not (plist-get u :list-cost))
      (should (= 12 (plist-get u :input)))
      (should (equal "premium" (plist-get (car (plist-get q :windows)) :name)))))
  (harness-provider-copilot-close "s19"))

;;;; Lifecycle

(ert-deftest harness-provider-copilot-session-events-close-process ()
  (harness-provider-copilot-test--setup)
  (harness-provider-copilot-test--run (harness-provider-copilot-test--request "s20" "hi"))
  (let ((proc (harness-provider-copilot-test--process "s20")))
    (should (process-live-p proc))
    (harness-emit 'session/deleted "s20")
    (should-not (process-live-p proc))
    (should-not (gethash "s20" harness-provider-copilot--sessions))))

(ert-deftest harness-provider-copilot-reload-drops-old-records ()
  "Records made before the latest slots were added are closed on load."
  (harness-provider-copilot-test--setup)
  (let ((old (apply #'record 'harness-provider-copilot-session "old" (make-list 10 nil)))
        (new (harness-provider-copilot--make-session :id "new")))
    (puthash "old" old harness-provider-copilot--sessions)
    (puthash "new" new harness-provider-copilot--sessions)
    (harness-provider-copilot--drop-stale-entries)
    (should-not (gethash "old" harness-provider-copilot--sessions))
    (should (eq new (gethash "new" harness-provider-copilot--sessions)))))

;;;; Integration

(ert-deftest harness-provider-copilot-integration-real-cli ()
  "A real turn through a logged-in `copilot': streamed text and a hosted tool call."
  :tags '(integration)
  (harness-test-skip-unless-integration)
  (harness-test-reset-bus)
  (harness-test-load-module 'provider)
  (harness-test-load-module 'provider-copilot)
  ;; Earlier tests point the program at the fixture; use the real CLI here.
  (setq harness-provider-copilot-program
        (eval (car (get 'harness-provider-copilot-program 'standard-value)) t))
  (skip-unless (executable-find harness-provider-copilot-program))
  (clrhash harness-provider-copilot--sessions)
  (let* ((models (harness-test-await (harness-call 'provider/models t) 120))
         (model (or (cl-find-if (lambda (m) (equal (plist-get m :name) harness-provider-copilot-default-model))
                                models)
                    (car models)))
         (calls nil)
         (request (harness-provider-copilot-test--request
                   "integration"
                   "Call the echo tool with text=ping, then report exactly what it returned."
                   :model (plist-get model :id)))
         (result (harness-provider-copilot-test--run
                  request 300
                  (lambda (ev)
                    (push ev calls)
                    (funcall (plist-get ev :respond)
                             (list :content (format "echo: %s" (plist-get (plist-get ev :input) :text))
                                   :is-error nil)))))
         (events (car result))
         (types (harness-provider-copilot-test--types events)))
    (message "integration model: %s" (plist-get model :id))
    (message "integration events: %S" types)
    (message "integration text: %s" (harness-provider-copilot-test--text events))
    (should (eq 'start (car types)))
    (should (>= (length calls) 1))
    (should (equal "echo" (plist-get (car calls) :name)))
    (should (equal "ping" (plist-get (plist-get (car calls) :input) :text)))
    (should (string-match-p "ping" (harness-provider-copilot-test--text events)))
    (let ((state (plist-get (harness-provider-copilot-test--find events 'provider-state) :state)))
      (should (stringp (plist-get state :copilot-session-id))))
    (let ((usage (harness-provider-copilot-test--find events 'usage)))
      (should (> (plist-get usage :context) 0))
      (should (memq (plist-get usage :billing) '(subscription extra-usage))))
    (should (eq 'end-turn (harness-provider-copilot-test--done events)))
    (should (= 1 (cl-count 'done types)))
    (harness-provider-copilot-close "integration")))

(provide 'harness-provider-copilot-test)
;;; harness-provider-copilot-test.el ends here
