;;; harness-provider-claude-test.el --- Tests for the Claude Code provider  -*- lexical-binding: t; -*-
;;; Commentary:

;; Unit tests drive the provider against test/fixtures/fake-claude.py,
;; which speaks the CLI's stream-json protocol without a network.  The
;; integration test at the end talks to the real `claude' and only runs
;; with HARNESS_INTEGRATION=1.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-provider)

(defvar harness-provider-claude-program)
(defvar harness-provider-claude-interrupt-timeout)
(defvar harness-provider-claude--sessions)
(defvar harness-provider-claude--status)
(defvar harness-provider-claude--asked)
(defvar harness-provider-claude--probe)
(declare-function harness-provider-claude-close "harness-provider-claude")
(declare-function harness-provider-claude-close-all "harness-provider-claude")
(declare-function harness-provider-claude--command "harness-provider-claude")
(declare-function harness-provider-claude-session-process "harness-provider-claude")
(declare-function harness-provider-claude-account-info "harness-provider-claude")
(declare-function harness-provider-claude--usage-changes "harness-provider-claude")
(declare-function harness-provider-claude--usage-windows "harness-provider-claude")
(declare-function harness-provider-claude--windows "harness-provider-claude")
(declare-function harness-provider-claude--merge-windows "harness-provider-claude")
(declare-function harness-provider-claude--drop-stale-entries "harness-provider-claude")
(declare-function harness-provider-claude--make-session "harness-provider-claude")

(defun harness-provider-claude-test--setup ()
  "Fresh bus with the provider registry and the Claude provider loaded.
Processes, the usage report and the quota probe of earlier tests go."
  (harness-test-reset-bus)
  (harness-test-load-module 'provider)
  (harness-test-load-module 'provider-claude)
  (setq harness-provider-claude-program (harness-test-fixture "fake-claude.py"))
  (harness-provider-claude-close-all)
  (clrhash harness-provider-claude--sessions)
  (setq harness-provider-claude--status nil
        harness-provider-claude--asked nil
        harness-provider-claude--probe nil))

(defun harness-provider-claude-test--near (a b)
  "Non-nil when numbers A and B are equal within rounding."
  (and (numberp a) (numberp b) (< (abs (- a b)) 1e-9)))

(defconst harness-provider-claude-test--echo-tool
  '(:name "echo" :description "Echo TEXT back to the caller."
    :schema (:type "object"
             :properties (:text (:type "string" :description "Text to echo"))
             :required ("text")))
  "Tool spec passed directly in requests; no tool module is loaded.")

(defun harness-provider-claude-test--request (sid text &rest extra)
  "Build a request for session SID with user TEXT and EXTRA plist keys."
  (harness-plist-merge
   (list :model "claude:claude-fable-5-1"
         :session (list :id sid :cwd (harness-test-temp-dir))
         :system "You are a test agent"
         :messages (list (list :role 'user :content (list (list :type "text" :text text))))
         :tools (list harness-provider-claude-test--echo-tool))
   extra))

(defun harness-provider-claude-test--run (request &optional timeout on-tool)
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

(defun harness-provider-claude-test--types (events)
  "Return the list of event types in EVENTS."
  (mapcar (lambda (e) (plist-get e :type)) events))

(defun harness-provider-claude-test--find (events type)
  "Return the first event of TYPE in EVENTS."
  (cl-find type events :key (lambda (e) (plist-get e :type))))

(defun harness-provider-claude-test--text (events)
  "Concatenate the text deltas in EVENTS."
  (mapconcat (lambda (e) (if (eq (plist-get e :type) 'text) (plist-get e :delta) "")) events ""))

(defun harness-provider-claude-test--argv-file ()
  "Return a fresh path for the fixture's argv dump."
  (make-temp-file "harness-claude-argv-"))

(defun harness-provider-claude-test--read-argv (file)
  "Parse the fixture's argv dump FILE."
  (harness-test-wait (lambda () (> (or (harness-file-size file) 0) 0)) 5 "argv file")
  (harness-json-parse (harness-read-file file)))

;;;; Unit tests

(ert-deftest harness-provider-claude-models-and-capabilities ()
  (harness-provider-claude-test--setup)
  (let* ((models (harness-test-await (harness-call 'provider/models t)))
         (fable (cl-find "claude:claude-fable-5-1" models :key (lambda (m) (plist-get m :id)) :test #'equal)))
    (should fable)
    (should (equal "Claude Fable 5.1" (plist-get fable :label)))
    (should (= 1000000 (plist-get fable :context-window)))
    (should (equal '(:input 10.0 :output 50.0 :cache-read 0.25 :cache-write 12.5)
                   (plist-get fable :pricing)))
    (should (member "image" (plist-get fable :input-modalities)))
    (should (equal '("low" "medium" "high" "xhigh" "max") (plist-get fable :thinking-levels)))
    (should (= 4 (cl-count 'claude models :key (lambda (m) (plist-get m :provider)))))
    (let ((caps (harness-call 'provider/capabilities "claude:claude-sonnet-5")))
      (should (plist-get caps :hosted-loop))
      (should (plist-get caps :fork))
      (should (eq 'hosted (plist-get caps :compaction)))
      (should (plist-get caps :cost-reported)))))

(ert-deftest harness-provider-claude-command-line ()
  (harness-provider-claude-test--setup)
  (let ((cmd (harness-provider-claude--command "claude-opus-5-5" "high" "sys" "abc" t)))
    (should (equal (car cmd) harness-provider-claude-program))
    (should (member "-p" cmd))
    (should (equal '("--tools" "") (seq-subseq cmd (cl-position "--tools" cmd :test #'equal)
                                              (+ 2 (cl-position "--tools" cmd :test #'equal)))))
    (should (member "--strict-mcp-config" cmd))
    (should (equal "bypassPermissions" (nth (1+ (cl-position "--permission-mode" cmd :test #'equal)) cmd)))
    (should (equal "claude-opus-5-5" (nth (1+ (cl-position "--model" cmd :test #'equal)) cmd)))
    (should (equal "high" (nth (1+ (cl-position "--effort" cmd :test #'equal)) cmd)))
    (should (equal "sys" (nth (1+ (cl-position "--system-prompt" cmd :test #'equal)) cmd)))
    (should (equal "abc" (nth (1+ (cl-position "--resume" cmd :test #'equal)) cmd)))
    (should (member "--fork-session" cmd))
    (let ((mcp (harness-json-parse (nth (1+ (cl-position "--mcp-config" cmd :test #'equal)) cmd))))
      (should (equal "sdk" (harness-plist-get-in mcp '(:mcpServers :harness :type))))))
  ;; Optional pieces are omitted when absent.
  (let ((cmd (harness-provider-claude--command "claude-sonnet-5" nil nil nil nil)))
    (should-not (member "--effort" cmd))
    (should-not (member "--system-prompt" cmd))
    (should-not (member "--resume" cmd))
    (should-not (member "--fork-session" cmd))))

(ert-deftest harness-provider-claude-turn-with-hosted-tool-call ()
  (harness-provider-claude-test--setup)
  (let* ((argv-file (harness-provider-claude-test--argv-file))
         (process-environment (append (list (concat "HARNESS_FAKE_CLAUDE_ARGV=" argv-file)
                                            "CLAUDECODE=1")
                                      process-environment))
         (request (harness-provider-claude-test--request "s1" "please call echo with ping" :thinking "low"))
         (events (car (harness-provider-claude-test--run request)))
         (types (harness-provider-claude-test--types events)))
    ;; Order: start, state, tool call, text, quota, usage, done.
    (should (eq 'start (car types)))
    (should (< (cl-position 'provider-state types) (cl-position 'tool-call types)))
    (should (< (cl-position 'tool-call types) (cl-position 'text types)))
    (should (< (cl-position 'text types) (cl-position 'usage types)))
    (should (eq 'done (car (last types))))
    (should (= 1 (cl-count 'done types)))
    ;; Provider state carries the CLI session id.
    (let ((state (plist-get (harness-provider-claude-test--find events 'provider-state) :state)))
      (should (string-prefix-p "fake-" (plist-get state :cli-session-id)))
      (should (equal "claude-fable-5-1" (plist-get state :model))))
    ;; Tool call: prefix stripped, id from the assistant tool_use block.
    (let ((call (harness-provider-claude-test--find events 'tool-call)))
      (should (equal "echo" (plist-get call :name)))
      (should (equal "toolu_fake_1" (plist-get call :id)))
      (should (equal "ping" (plist-get (plist-get call :input) :text)))
      (should (functionp (plist-get call :respond))))
    ;; Our own result echo is not re-emitted; empty thinking is dropped.
    (should-not (memq 'tool-result types))
    (should-not (memq 'thinking types))
    (should (equal "hello" (harness-provider-claude-test--text events)))
    ;; Usage with cost and context; done end-turn.
    (let ((usage (harness-provider-claude-test--find events 'usage)))
      (should (= 0.01 (plist-get usage :cost)))
      (should (= 7 (plist-get usage :output)))
      (should (= 2000 (plist-get usage :cache-read)))
      (should (= 100 (plist-get usage :cache-write)))
      (should (= 2112 (plist-get usage :context))))
    (should (eq 'end-turn (plist-get (harness-provider-claude-test--find events 'done) :stop-reason)))
    ;; Quota windows were reported and remembered.
    (let ((q (harness-provider-claude-test--find events 'quota)))
      (should (equal "5h" (plist-get (car (plist-get q :windows)) :name)))
      (should (= 0.09 (plist-get (car (plist-get q :windows)) :used))))
    (should (equal "5h" (plist-get (car (plist-get (harness-test-await (harness-call 'provider/quota 'claude)) :windows)) :name)))
    ;; The command line the fixture saw.
    (let* ((dump (harness-provider-claude-test--read-argv argv-file))
           (argv (plist-get dump :argv)))
      (should (member "--include-partial-messages" argv))
      (should (equal "low" (nth (1+ (cl-position "--effort" argv :test #'equal)) argv)))
      (should (equal "You are a test agent" (nth (1+ (cl-position "--system-prompt" argv :test #'equal)) argv)))
      (should-not (member "--resume" argv))
      (should (null (plist-get dump :claudecode)))
      (should (equal (file-truename (plist-get (plist-get request :session) :cwd))
                     (file-name-as-directory (file-truename (plist-get dump :cwd))))))
    (harness-provider-claude-close "s1")))

(ert-deftest harness-provider-claude-second-turn-reuses-process ()
  (harness-provider-claude-test--setup)
  (let* ((first (harness-provider-claude-test--run (harness-provider-claude-test--request "s2" "hi")))
         (proc1 (harness-provider-claude-session-process (gethash "s2" harness-provider-claude--sessions)))
         (second (harness-provider-claude-test--run
                  (harness-provider-claude-test--request
                   "s2" "again"
                   :messages (list '(:role user :content ((:type "text" :text "hi")))
                                   '(:role assistant :content ((:type "text" :text "hello")))
                                   '(:role user :content ((:type "text" :text "call echo again")))))))
         (proc2 (harness-provider-claude-session-process (gethash "s2" harness-provider-claude--sessions))))
    (should (process-live-p proc1))
    (should (eq proc1 proc2))
    (should (eq 'end-turn (plist-get (harness-provider-claude-test--find (car first) 'done) :stop-reason)))
    (should (eq 'end-turn (plist-get (harness-provider-claude-test--find (car second) 'done) :stop-reason)))
    ;; Only the trailing user message was sent, and it triggered the tool path.
    (should (harness-provider-claude-test--find (car second) 'tool-call))
    (should-not (harness-provider-claude-test--find (car first) 'tool-call))
    (harness-provider-claude-close "s2")
    (should-not (process-live-p proc1))))

(ert-deftest harness-provider-claude-settings-change-restarts-with-resume ()
  (harness-provider-claude-test--setup)
  (let* ((argv-file (harness-provider-claude-test--argv-file))
         (process-environment (cons (concat "HARNESS_FAKE_CLAUDE_ARGV=" argv-file) process-environment))
         (first (car (harness-provider-claude-test--run (harness-provider-claude-test--request "s3" "hi"))))
         (id (plist-get (plist-get (harness-provider-claude-test--find first 'provider-state) :state) :cli-session-id))
         (proc1 (harness-provider-claude-session-process (gethash "s3" harness-provider-claude--sessions))))
    (harness-provider-claude-test--run (harness-provider-claude-test--request "s3" "hi" :thinking "max"))
    (let ((proc2 (harness-provider-claude-session-process (gethash "s3" harness-provider-claude--sessions)))
          (argv (plist-get (harness-provider-claude-test--read-argv argv-file) :argv)))
      (should-not (eq proc1 proc2))
      (should (equal id (nth (1+ (cl-position "--resume" argv :test #'equal)) argv)))
      (should (equal "max" (nth (1+ (cl-position "--effort" argv :test #'equal)) argv)))
      (should-not (member "--fork-session" argv)))
    (harness-provider-claude-close "s3")))

(ert-deftest harness-provider-claude-cancel-produces-one-done ()
  (harness-provider-claude-test--setup)
  (let* (events
         (request (plist-put (harness-provider-claude-test--request "s4" "hang here")
                             :on-event (lambda (ev) (push ev events))))
         (handle (harness-call 'provider/complete request)))
    (harness-test-wait (lambda () (harness-provider-claude-test--find events 'text)) 10 "first delta")
    (funcall (plist-get handle :cancel))
    (funcall (plist-get handle :cancel))
    (harness-test-wait (lambda () (harness-provider-claude-test--find events 'done)) 10 "done")
    (accept-process-output nil 0.2)
    (should (= 1 (cl-count 'done (harness-provider-claude-test--types events))))
    (should (eq 'cancelled (plist-get (harness-provider-claude-test--find events 'done) :stop-reason)))
    ;; The process survived the interrupt and serves the next turn.
    (let ((proc (harness-provider-claude-session-process (gethash "s4" harness-provider-claude--sessions))))
      (should (process-live-p proc))
      (let ((again (car (harness-provider-claude-test--run (harness-provider-claude-test--request "s4" "hi")))))
        (should (eq 'end-turn (plist-get (harness-provider-claude-test--find again 'done) :stop-reason)))
        (should (eq proc (harness-provider-claude-session-process (gethash "s4" harness-provider-claude--sessions))))))
    (harness-provider-claude-close "s4")))

(ert-deftest harness-provider-claude-cancel-kills-when-interrupt-ignored ()
  (harness-provider-claude-test--setup)
  (let* ((harness-provider-claude-interrupt-timeout 0.3)
         events
         (request (plist-put (harness-provider-claude-test--request "s5" "hang ignore")
                             :on-event (lambda (ev) (push ev events))))
         (handle (harness-call 'provider/complete request))
         (proc (harness-provider-claude-session-process (gethash "s5" harness-provider-claude--sessions))))
    (harness-test-wait (lambda () (harness-provider-claude-test--find events 'text)) 10 "first delta")
    (funcall (plist-get handle :cancel))
    (harness-test-wait (lambda () (harness-provider-claude-test--find events 'done)) 10 "done")
    (accept-process-output nil 0.2)
    (should (= 1 (cl-count 'done (harness-provider-claude-test--types events))))
    (should (eq 'cancelled (plist-get (harness-provider-claude-test--find events 'done) :stop-reason)))
    (should-not (process-live-p proc))
    (harness-provider-claude-close "s5")))

(ert-deftest harness-provider-claude-process-death-is-an-error ()
  (harness-provider-claude-test--setup)
  (let* ((events (car (harness-provider-claude-test--run (harness-provider-claude-test--request "s6" "die now"))))
         (done (harness-provider-claude-test--find events 'done)))
    (should (eq 'error (plist-get done :stop-reason)))
    (should (string-match-p "exited with status 3" (plist-get done :error)))
    (should (string-match-p "dying on request" (plist-get done :error)))
    ;; The next turn respawns transparently.
    (let ((again (car (harness-provider-claude-test--run (harness-provider-claude-test--request "s6" "hi")))))
      (should (eq 'end-turn (plist-get (harness-provider-claude-test--find again 'done) :stop-reason))))
    (harness-provider-claude-close "s6")))

(ert-deftest harness-provider-claude-fork-resumes-with-fork-session ()
  (harness-provider-claude-test--setup)
  (let* ((state (harness-test-await (harness-call 'provider/fork "claude:claude-fable-5-1"
                                                  '(:cli-session-id "parent-123" :model "m"))))
         (argv-file (harness-provider-claude-test--argv-file))
         (process-environment (cons (concat "HARNESS_FAKE_CLAUDE_ARGV=" argv-file) process-environment)))
    (should (equal "parent-123" (plist-get state :cli-session-id)))
    (should (plist-get state :fork-pending))
    (should (null (harness-test-await (harness-call 'provider/fork "claude:claude-fable-5-1" nil))))
    (let* ((events (car (harness-provider-claude-test--run
                         (harness-provider-claude-test--request "child" "hi" :provider-state state))))
           (argv (plist-get (harness-provider-claude-test--read-argv argv-file) :argv))
           (new-state (plist-get (harness-provider-claude-test--find events 'provider-state) :state)))
      (should (equal "parent-123" (nth (1+ (cl-position "--resume" argv :test #'equal)) argv)))
      (should (member "--fork-session" argv))
      (should (string-prefix-p "forked-" (plist-get new-state :cli-session-id)))
      (should-not (plist-get new-state :fork-pending))
      (should (eq 'end-turn (plist-get (harness-provider-claude-test--find events 'done) :stop-reason))))
    (harness-provider-claude-close "child")))

(ert-deftest harness-provider-claude-resume-after-close ()
  (harness-provider-claude-test--setup)
  (let* ((argv-file (harness-provider-claude-test--argv-file))
         (process-environment (cons (concat "HARNESS_FAKE_CLAUDE_ARGV=" argv-file) process-environment))
         (events (car (harness-provider-claude-test--run
                       (harness-provider-claude-test--request "s7" "hi" :provider-state '(:cli-session-id "old-9")))))
         (argv (plist-get (harness-provider-claude-test--read-argv argv-file) :argv)))
    (should (equal "old-9" (nth (1+ (cl-position "--resume" argv :test #'equal)) argv)))
    (should-not (member "--fork-session" argv))
    (should (equal "old-9" (plist-get (plist-get (harness-provider-claude-test--find events 'provider-state) :state)
                                      :cli-session-id)))
    (should (harness-provider-claude-close "s7"))
    (should-not (harness-provider-claude-close "s7"))))

(ert-deftest harness-provider-claude-session-events-close-process ()
  (harness-provider-claude-test--setup)
  (harness-provider-claude-test--run (harness-provider-claude-test--request "s8" "hi"))
  (let ((proc (harness-provider-claude-session-process (gethash "s8" harness-provider-claude--sessions))))
    (should (process-live-p proc))
    (harness-emit 'session/deleted "s8")
    (should-not (process-live-p proc))
    (should-not (gethash "s8" harness-provider-claude--sessions))))

(ert-deftest harness-provider-claude-image-blocks-and-trailing-messages ()
  (harness-provider-claude-test--setup)
  (let* ((img (make-temp-file "harness-img-" nil ".png"))
         (request (list :messages
                        (list '(:role user :content ((:type "text" :text "old")))
                              '(:role assistant :content ((:type "text" :text "reply")))
                              (list :role 'user :content
                                    (list '(:type "text" :text "new")
                                          '(:type "image" :mime "image/jpeg" :data "QUJD")
                                          (list :type "image" :path img)
                                          '(:type "tool_result" :tool_use_id "x" :content "skip")))))))
    (with-temp-file img (insert "png"))
    (let ((blocks (harness-provider-claude--user-blocks request)))
      (should (= 3 (length blocks)))
      (should (equal "new" (plist-get (car blocks) :text)))
      (should (equal "image/jpeg" (harness-plist-get-in (nth 1 blocks) '(:source :media_type))))
      (should (equal "QUJD" (harness-plist-get-in (nth 1 blocks) '(:source :data))))
      (should (equal (base64-encode-string "png") (harness-plist-get-in (nth 2 blocks) '(:source :data)))))
    (delete-file img)))

;;;; Billing and quota

(defconst harness-provider-claude-test--usage-report
  "{\"session\":{\"total_cost_usd\":0.25,\"total_api_duration_ms\":0,\"total_duration_ms\":22671,\"model_usage\":{}},\"subscription_type\":\"max\",\"rate_limits_available\":true,\"rate_limits\":{\"five_hour\":{\"utilization\":8,\"resets_at\":\"2026-10-01T09:39:59.819728+00:00\",\"limit_dollars\":null,\"locked_reason\":null},\"seven_day\":{\"utilization\":57,\"resets_at\":\"2026-10-03T13:59:59.819752+00:00\"},\"seven_day_opus\":null,\"seven_day_sonnet\":null,\"extra_usage\":{\"is_enabled\":false,\"monthly_limit\":5000,\"used_credits\":0,\"utilization\":0,\"currency\":\"USD\",\"decimal_places\":2,\"disabled_reason\":\"out_of_credits\"},\"limits\":[{\"kind\":\"session\",\"group\":\"session\",\"percent\":8,\"severity\":\"normal\",\"resets_at\":\"2026-10-01T09:39:59.819728+00:00\",\"scope\":null,\"is_active\":false},{\"kind\":\"weekly_all\",\"group\":\"weekly\",\"percent\":57,\"severity\":\"normal\",\"resets_at\":\"2026-10-03T13:59:59.819752+00:00\",\"scope\":null,\"is_active\":true},{\"kind\":\"weekly_scoped\",\"group\":\"weekly\",\"percent\":50,\"severity\":\"normal\",\"resets_at\":\"2026-10-03T13:59:59.819934+00:00\",\"scope\":{\"model\":{\"id\":null,\"display_name\":\"Fable\"},\"surface\":null},\"is_active\":false}],\"spend\":{\"used\":{\"amount_minor\":0,\"currency\":\"USD\",\"exponent\":2},\"limit\":{\"amount_minor\":5000,\"currency\":\"USD\",\"exponent\":2},\"percent\":0,\"enabled\":false,\"disabled_reason\":\"out_of_credits\"}}}"
  "A get_usage answer of Claude Code 2.1.286 logged in to Claude Max.")

(ert-deftest harness-provider-claude-account-billing ()
  "The initialize answer's account says who pays: a plan or the API."
  (harness-provider-claude-test--setup)
  (let ((sub (harness-provider-claude-account-info
              '(:email "user@example.com" :organization "user@example.com's Organization"
                :subscriptionType "Claude Max" :apiProvider "firstParty")))
        (key (harness-provider-claude-account-info
              '(:tokenSource "claude.ai" :apiKeySource "ANTHROPIC_API_KEY" :apiProvider "firstParty")))
        (bedrock (harness-provider-claude-account-info '(:apiProvider "bedrock")))
        (bearer (harness-provider-claude-account-info
                 '(:tokenSource "ANTHROPIC_AUTH_TOKEN" :apiProvider "firstParty")))
        (old (harness-provider-claude-account-info '(:email "user@example.com" :subscriptionType "Claude API")))
        (unknown (harness-provider-claude-account-info '(:tokenSource "none"))))
    (should (eq 'subscription (plist-get sub :billing)))
    (should (equal "max" (plist-get sub :plan)))
    (should (equal "Claude Max" (plist-get sub :plan-label)))
    (should (equal "claude.ai" (plist-get sub :auth)))
    (should (equal "user@example.com" (harness-plist-get-in sub '(:account :email))))
    (should (eq 'api (plist-get key :billing)))
    (should (equal "ANTHROPIC_API_KEY" (plist-get key :auth)))
    (should-not (plist-get key :plan))
    (should-not (plist-get key :account))
    (should (eq 'api (plist-get bedrock :billing)))
    (should (equal "bedrock" (plist-get bedrock :auth)))
    (should (eq 'api (plist-get bearer :billing)))
    ;; Old CLIs called subscriptions "Claude API"; the email still tells.
    (should (eq 'subscription (plist-get old :billing)))
    (should-not (plist-get old :plan))
    (should-not (plist-get unknown :billing))))

(ert-deftest harness-provider-claude-usage-report-and-rate-limits ()
  "Usage reports and rate limit events become quota windows."
  (harness-provider-claude-test--setup)
  (let* ((changes (harness-provider-claude--usage-changes
                   (harness-json-parse harness-provider-claude-test--usage-report)))
         (windows (plist-get changes :windows))
         (extra (plist-get changes :extra)))
    (should (equal "max" (plist-get changes :plan)))
    (should (equal "Claude Max" (plist-get changes :plan-label)))
    (should (eq 'subscription (plist-get changes :billing)))
    (should (plist-get changes :available))
    (should (equal '("5h" "7d" "7d Fable") (mapcar (lambda (w) (plist-get w :name)) windows)))
    (should (= 0.08 (plist-get (nth 0 windows) :used)))
    (should (= 0.57 (plist-get (nth 1 windows) :used)))
    (should (equal "Current session (5 hours)" (plist-get (nth 0 windows) :label)))
    (should (equal "This week, Fable" (plist-get (nth 2 windows) :label)))
    (should (equal "Fable" (plist-get (nth 2 windows) :model)))
    (should (= 1790847599.0 (plist-get (nth 0 windows) :resets)))
    (should (plist-get (nth 1 windows) :active))
    (should-not (plist-get (nth 0 windows) :active))
    (should-not (plist-get extra :enabled))
    (should (= 50.0 (plist-get extra :limit)))
    (should (= 0.0 (plist-get extra :used)))
    (should (equal "out_of_credits" (plist-get extra :disabled-reason)))
    ;; Reports without `limits' name each window instead.
    (let ((named (harness-provider-claude--usage-windows
                  '(:five_hour (:utilization 12 :resets_at "2026-10-01T09:39:59Z")
                    :seven_day_opus (:utilization 30)))))
      (should (equal '("5h" "7d Opus") (mapcar (lambda (w) (plist-get w :name)) named)))
      (should (= 0.12 (plist-get (car named) :used))))
    ;; An API key has no plan quota.
    (let ((api (harness-provider-claude--usage-changes
                '(:session (:total_cost_usd 0) :subscription_type nil :rate_limits_available :false))))
      (should (plist-member api :windows))
      (should-not (plist-get api :windows))
      (should-not (plist-get api :available)))
    ;; A CLI that answered nothing useful changes nothing.
    (should-not (harness-provider-claude--usage-changes nil))
    ;; Rate limit events update the windows they name and keep the rest.
    (let ((merged (harness-provider-claude--merge-windows
                   windows
                   (harness-provider-claude--windows
                    '(:unifiedWindows (:five_hour (:utilization 0.2 :resetsAt 1790847600)
                                       :seven_day_sonnet (:utilization 0.1)))))))
      (should (equal '("5h" "7d" "7d Fable" "7d Sonnet") (mapcar (lambda (w) (plist-get w :name)) merged)))
      (should (= 0.2 (plist-get (car merged) :used)))
      (should (= 1790847600.0 (plist-get (car merged) :resets)))
      (should (equal "Current session (5 hours)" (plist-get (car merged) :label))))))

(ert-deftest harness-provider-claude-subscription-turns-cost-nothing ()
  "A Claude subscription pays: turns cost 0, with their API price as list cost."
  (harness-provider-claude-test--setup)
  (let ((process-environment (cons "HARNESS_FAKE_CLAUDE_AUTH=subscription" process-environment))
        (updates nil))
    (harness-on 'provider/quota-updated (lambda (pid quota) (push (cons pid quota) updates)))
    (let* ((first (car (harness-provider-claude-test--run (harness-provider-claude-test--request "sub1" "hi"))))
           (second (car (harness-provider-claude-test--run (harness-provider-claude-test--request "sub1" "again")))))
      ;; The CLI reports running totals of 0.01 and 0.02: each turn is 0.01.
      (dolist (events (list first second))
        (let ((u (harness-provider-claude-test--find events 'usage)))
          (should (eq 'subscription (plist-get u :billing)))
          (should (equal "max" (plist-get u :plan)))
          (should (equal 0.0 (plist-get u :cost)))
          (should (harness-provider-claude-test--near 0.01 (plist-get u :list-cost)))))
      ;; The turn heard about the plan's quota.
      (let ((q (harness-provider-claude-test--find first 'quota)))
        (should (member "7d Fable" (mapcar (lambda (w) (plist-get w :name)) (plist-get q :windows)))))
      (let ((q (harness-test-await (harness-call 'provider/quota 'claude))))
        (should (eq 'subscription (plist-get q :billing)))
        (should (equal "max" (plist-get q :plan)))
        (should (equal "Claude Max" (plist-get q :plan-label)))
        (should (equal "user@example.com" (harness-plist-get-in q '(:account :email))))
        (should (equal '("5h" "7d" "7d Fable") (mapcar (lambda (w) (plist-get w :name)) (plist-get q :windows))))
        ;; The rate limit event of the turn refreshed the 5-hour window.
        (should (= 0.09 (plist-get (car (plist-get q :windows)) :used)))
        (should (= 50.0 (harness-plist-get-in q '(:extra :limit))))
        (should (numberp (plist-get q :updated)))
        (should-not (plist-get q :using-extra)))
      (should updates)
      (should (eq 'claude (car (car updates))))
      (should (eq 'subscription (plist-get (cdr (car updates)) :billing))))
    (harness-provider-claude-close "sub1")))

(ert-deftest harness-provider-claude-extra-usage-is-billed ()
  "Past the plan's limit with extra usage on, turns cost their API price."
  (harness-provider-claude-test--setup)
  (let* ((process-environment (append '("HARNESS_FAKE_CLAUDE_AUTH=subscription" "HARNESS_FAKE_CLAUDE_OVERAGE=1")
                                      process-environment))
         (events (car (harness-provider-claude-test--run (harness-provider-claude-test--request "ex1" "hi"))))
         (u (harness-provider-claude-test--find events 'usage)))
    (should (eq 'extra-usage (plist-get u :billing)))
    (should (harness-provider-claude-test--near 0.01 (plist-get u :cost)))
    (should (harness-provider-claude-test--near 0.01 (plist-get u :list-cost)))
    (should (plist-get (harness-test-await (harness-call 'provider/quota 'claude)) :using-extra))
    (harness-provider-claude-close "ex1")))

(ert-deftest harness-provider-claude-api-key-turns-are-billed ()
  "With an API key a turn costs what the CLI estimates, and there is no quota."
  (harness-provider-claude-test--setup)
  (let* ((process-environment (cons "HARNESS_FAKE_CLAUDE_AUTH=api" process-environment))
         (first (car (harness-provider-claude-test--run (harness-provider-claude-test--request "api1" "hi"))))
         (second (car (harness-provider-claude-test--run (harness-provider-claude-test--request "api1" "again")))))
    (dolist (events (list first second))
      (let ((u (harness-provider-claude-test--find events 'usage)))
        (should (eq 'api (plist-get u :billing)))
        (should (harness-provider-claude-test--near 0.01 (plist-get u :cost)))
        (should (harness-provider-claude-test--near 0.01 (plist-get u :list-cost)))
        (should-not (plist-get u :plan))))
    (should-not (harness-provider-claude-test--find first 'quota))
    (let ((q (harness-test-await (harness-call 'provider/quota 'claude))))
      (should (eq 'api (plist-get q :billing)))
      (should (equal "ANTHROPIC_API_KEY" (plist-get q :auth)))
      (should-not (plist-get q :windows)))
    (harness-provider-claude-close "api1")))

(ert-deftest harness-provider-claude-resume-counts-only-new-spend ()
  "A resumed CLI session restores its earlier spend; only the new turn counts."
  (harness-provider-claude-test--setup)
  (let* ((process-environment (cons "HARNESS_FAKE_CLAUDE_AUTH=api" process-environment))
         (events (car (harness-provider-claude-test--run
                       (harness-provider-claude-test--request "r1" "hi" :provider-state '(:cli-session-id "old-1")))))
         (u (harness-provider-claude-test--find events 'usage)))
    ;; The fake reports 0.06 in all, 0.05 of it restored.
    (should (harness-provider-claude-test--near 0.01 (plist-get u :cost))))
  (harness-provider-claude-close "r1")
  ;; A CLI that cannot report usage leaves the first resumed turn unpriced,
  ;; so the session prices it from the catalogue; the next turn is exact.
  (let* ((first (car (harness-provider-claude-test--run
                      (harness-provider-claude-test--request "r2" "hi" :provider-state '(:cli-session-id "old-2")))))
         (second (car (harness-provider-claude-test--run (harness-provider-claude-test--request "r2" "again")))))
    (should (plist-member (harness-provider-claude-test--find first 'usage) :cost))
    (should-not (plist-get (harness-provider-claude-test--find first 'usage) :cost))
    (should (harness-provider-claude-test--near 0.01 (plist-get (harness-provider-claude-test--find second 'usage) :cost))))
  (harness-provider-claude-close "r2"))

(ert-deftest harness-provider-claude-quota-probe-without-sessions ()
  "With no CLI running, `provider/quota' asks a probe that makes no model call."
  (harness-provider-claude-test--setup)
  (let* ((argv-file (harness-provider-claude-test--argv-file))
         (process-environment (append (list "HARNESS_FAKE_CLAUDE_AUTH=subscription"
                                            (concat "HARNESS_FAKE_CLAUDE_ARGV=" argv-file))
                                      process-environment))
         (q (harness-test-await (harness-call 'provider/quota "claude" t) 15)))
    (should (eq 'subscription (plist-get q :billing)))
    (should (equal "Claude Max" (plist-get q :plan-label)))
    (should (= 3 (length (plist-get q :windows))))
    ;; The probe exits once it has answered, and served no MCP tools.
    (harness-test-wait (lambda () (null harness-provider-claude--probe)) 10 "the probe to exit")
    (let ((argv (plist-get (harness-provider-claude-test--read-argv argv-file) :argv)))
      (should-not (member "--mcp-config" argv))
      (should-not (member "--model" argv)))
    ;; A fresh report is not fetched again.
    (should (eq q (harness-test-await (harness-call 'provider/quota 'claude))))))

(ert-deftest harness-provider-claude-reload-drops-old-records ()
  "Records made before the latest slots were added are closed on load."
  (harness-provider-claude-test--setup)
  (let ((old (apply #'record 'harness-provider-claude-session "old" (make-list 14 nil)))
        (new (harness-provider-claude--make-session :id "new")))
    (puthash "old" old harness-provider-claude--sessions)
    (puthash "new" new harness-provider-claude--sessions)
    (harness-provider-claude--drop-stale-entries)
    (should-not (gethash "old" harness-provider-claude--sessions))
    (should (eq new (gethash "new" harness-provider-claude--sessions)))))

;;;; Integration

(ert-deftest harness-provider-claude-integration-real-cli ()
  :tags '(integration)
  (harness-test-skip-unless-integration)
  (harness-test-reset-bus)
  (harness-test-load-module 'provider)
  (harness-test-load-module 'provider-claude)
  ;; Earlier tests point the program at the fixture; use the real CLI here.
  (setq harness-provider-claude-program
        (eval (car (get 'harness-provider-claude-program 'standard-value)) t))
  (clrhash harness-provider-claude--sessions)
  (let* ((calls nil)
         (request (harness-provider-claude-test--request
                   "integration"
                   "Call the echo tool with text=ping, then report exactly what it returned."
                   :thinking "low"))
         (result (harness-provider-claude-test--run
                  request 180
                  (lambda (ev)
                    (push ev calls)
                    (funcall (plist-get ev :respond)
                             (list :content (format "echo: %s" (plist-get (plist-get ev :input) :text))
                                   :is-error nil)))))
         (events (car result))
         (types (harness-provider-claude-test--types events)))
    (message "integration events: %S" types)
    (message "integration text: %s" (harness-provider-claude-test--text events))
    (should (eq 'start (car types)))
    (should (= 1 (length calls)))
    (should (equal "echo" (plist-get (car calls) :name)))
    (should (equal "ping" (plist-get (plist-get (car calls) :input) :text)))
    (should (string-match-p "ping" (harness-provider-claude-test--text events)))
    (let ((state (plist-get (harness-provider-claude-test--find events 'provider-state) :state)))
      (should (stringp (plist-get state :cli-session-id))))
    (let ((usage (harness-provider-claude-test--find events 'usage)))
      (should (numberp (plist-get usage :cost)))
      (should (> (plist-get usage :context) 0))
      ;; The account decides who pays; the list price is this turn's alone.
      (should (memq (plist-get usage :billing) '(api subscription extra-usage)))
      (should (numberp (plist-get usage :list-cost)))
      (when (eq (plist-get usage :billing) 'subscription)
        (should (= 0.0 (plist-get usage :cost)))
        (should (plist-get (harness-test-await (harness-call 'provider/quota 'claude) 30) :windows))))
    (should (eq 'end-turn (plist-get (harness-provider-claude-test--find events 'done) :stop-reason)))
    (should (= 1 (cl-count 'done types)))
    (harness-provider-claude-close "integration")))

(provide 'harness-provider-claude-test)
;;; harness-provider-claude-test.el ends here
