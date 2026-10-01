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
(declare-function harness-provider-claude-close "harness-provider-claude")
(declare-function harness-provider-claude-close-all "harness-provider-claude")
(declare-function harness-provider-claude--command "harness-provider-claude")
(declare-function harness-provider-claude-session-process "harness-provider-claude")

(defun harness-provider-claude-test--setup ()
  "Fresh bus with the provider registry and the Claude provider loaded."
  (harness-test-reset-bus)
  (harness-test-load-module 'provider)
  (harness-test-load-module 'provider-claude)
  (setq harness-provider-claude-program (harness-test-fixture "fake-claude.py"))
  (clrhash harness-provider-claude--sessions))

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
      (should (> (plist-get usage :context) 0)))
    (should (eq 'end-turn (plist-get (harness-provider-claude-test--find events 'done) :stop-reason)))
    (should (= 1 (cl-count 'done types)))
    (harness-provider-claude-close "integration")))

(provide 'harness-provider-claude-test)
;;; harness-provider-claude-test.el ends here
