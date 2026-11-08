;;; harness-errors-test.el --- Tests for the error details reporter  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-errors)

(defmacro harness-errors-test--with-reporter (&rest body)
  "Run BODY with the reporter installed, and take it out again."
  (declare (indent 0))
  `(unwind-protect
       (progn (harness-error-report-install) ,@body)
     (harness-error-report-uninstall)))

(defun harness-errors-test--text ()
  "Return the contents of the details file, or nil when it does not exist."
  (let ((file (harness-error-details-path)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(ert-deftest harness-errors-report-has-details-context-and-backtrace ()
  "A report names the error, session, task, what failed and the stack."
  (harness-test-with-temp-state
    (let* ((backtrace "   0  (car 1)\n   1  (harness-test-caller)")
           (file (harness-error-report '(wrong-type-argument listp 1)
                                       :context "promise callback"
                                       :session "session-abc"
                                       :task "task-abc"
                                       :backtrace backtrace)))
      (should (equal file (harness-error-details-path)))
      (should (file-exists-p file))
      (let ((text (harness-errors-test--text)))
        (should (string-match-p "HARNESS ERROR" text))
        (should (string-search "wrong-type-argument" text))
        (should (string-search "promise callback" text))
        (should (string-search "session-abc" text))
        (should (string-search "task-abc" text))
        (should (string-search "Stack trace:" text))
        (should (string-search "harness-test-caller" text))))))

(ert-deftest harness-errors-report-uses-the-trace-of-the-signal ()
  "A catcher's report has the stack taken when the error was signalled.
The trace is longer than the handler that catches it: it names the
function that failed, not only the promise plumbing around it."
  (harness-test-with-temp-state
    (harness-errors-test--with-reporter
      (let ((harness-error-report-session "session-trace"))
        (harness-then (harness-resolved 1)
                      (lambda (value) (car value))))
      (let ((text (harness-errors-test--text)))
        (should text)
        (should (string-search "promise handler" text))
        (should (string-search "session-trace" text))
        (should (string-search "Stack trace:" text))
        (should (string-match-p "harness-errors-test" text))))))

(ert-deftest harness-errors-subscriber-failure-is-reported ()
  "An event subscriber that signals is reported, and other subscribers go on."
  (harness-test-with-temp-state
    (harness-errors-test--with-reporter
      (harness-test-reset-bus)
      (let ((ran nil))
        (harness-on 'test/broken (lambda () (error "subscriber boom")))
        (harness-on 'test/broken (lambda () (setq ran t)))
        (should (= 2 (harness-emit 'test/broken)))
        (should ran)))
    (let ((text (harness-errors-test--text)))
      (should (string-search "subscriber for test/broken" text))
      (should (string-search "subscriber boom" text))
      (should (string-search "Stack trace:" text)))))

(ert-deftest harness-errors-filter-failure-is-reported ()
  "A sync filter that signals is reported and the chain goes on."
  (harness-test-with-temp-state
    (harness-errors-test--with-reporter
      (harness-test-reset-bus)
      (harness-add-filter 'test/filter (lambda (_value) (error "filter boom")) 10)
      (harness-add-filter 'test/filter (lambda (value) (1+ value)) 20)
      (should (= 2 (harness-run-filter 'test/filter 1))))
    (let ((text (harness-errors-test--text)))
      (should (string-search "filter test/filter" text))
      (should (string-search "filter boom" text)))))

(ert-deftest harness-errors-module-init-failure-is-reported ()
  "A module whose init signals is reported with the module named."
  (harness-test-with-temp-state
    (harness-errors-test--with-reporter
      (harness-test-reset-bus)
      (harness-define-module 'test-broken
        :doc "A module whose init fails."
        :init (lambda () (error "module boom")))
      (should-not (harness-module-start 'test-broken))
      (should (eq (harness-module-state (harness-module-get 'test-broken)) 'failed)))
    (let ((text (harness-errors-test--text)))
      (should (string-search "module test-broken initialising" text))
      (should (string-search "module boom" text)))))

(ert-deftest harness-errors-task-id-comes-from-the-session ()
  "A report has the task id the session works on, when there is one."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (harness-register-method 'task/for-session
                             (lambda (session-id)
                               (and (equal session-id "session-task")
                                    (list :id "task-derived"))))
    (harness-error-report '(error "task boom") :session "session-task")
    (let ((text (harness-errors-test--text)))
      (should (string-search "session-task" text))
      (should (string-search "task-derived" text)))))

(ert-deftest harness-errors-timer-failure-is-reported ()
  "An error in a timer is reported with the trace from where it was signalled.
`timer-event-handler' catches it and only shows a message otherwise."
  (harness-test-with-temp-state
    (harness-errors-test--with-reporter
      (run-at-time 0 nil (lambda () (error "timer boom")))
      (harness-test-wait (lambda () (file-exists-p (harness-error-details-path))) 2
                         "the timer error report"))
    (let ((text (harness-errors-test--text)))
      (should (string-search "Where:   timer" text))
      (should (string-search "timer boom" text))
      (should (string-search "Stack trace:" text)))))

(ert-deftest harness-errors-a-catcher-reports-without-the-global-install ()
  "A harness boundary reports even before the global hooks are installed."
  (harness-test-with-temp-state
    (let ((harness-error-report--installed nil))
      (harness-test-reset-bus)
      (harness-on 'test/not-installed (lambda () (error "not installed boom")))
      (harness-emit 'test/not-installed))
    (let ((text (harness-errors-test--text)))
      (should text)
      (should (string-search "not installed boom" text)))))

(ert-deftest harness-errors-details-file-goes-in-the-state-directory ()
  "The default details file is one common path under the state directory."
  (harness-test-with-temp-state
    (should (equal (expand-file-name "error-details.log" harness-state-directory)
                   (harness-error-details-path)))
    (let ((harness-error-details-file "elsewhere.log"))
      (should (equal (expand-file-name "elsewhere.log" harness-state-directory)
                     (harness-error-details-path))))))

(ert-deftest harness-errors-file-rotates-at-its-limit ()
  "A file past the limit is kept as FILE.1 and a new one starts."
  (harness-test-with-temp-state
    (let ((harness-error-details-max-bytes 100))
      (harness-error-report '(error "first report"))
      (should (file-exists-p (harness-error-details-path)))
      (harness-error-report '(error "second report"))
      (should (file-exists-p (concat (harness-error-details-path) ".1")))
      (with-temp-buffer
        (insert-file-contents (concat (harness-error-details-path) ".1"))
        (should (string-search "first report" (buffer-string))))
      (should (string-search "second report" (harness-errors-test--text))))))

(ert-deftest harness-errors-unwritable-file-does-not-signal ()
  "A report that cannot be written is logged, not signalled."
  (harness-test-with-temp-state
    (let ((harness-error-details-file "/dev/null/no-error-details.log"))
      (should-not (harness-error-report '(error "not written"))))))

(ert-deftest harness-errors-look-like-a-refusal-or-a-bug ()
  "Deliberate refusals are not bugs; a wrong type or missing function is."
  (should-not (harness-error-report-internal-p '(error "Missing path")))
  (should-not (harness-error-report-internal-p '(user-error "Not now")))
  (should-not (harness-error-report-internal-p '(harness-error "No session")))
  (should-not (harness-error-report-internal-p '(file-missing "No file")))
  (should (harness-error-report-internal-p '(wrong-type-argument listp 1)))
  (should (harness-error-report-internal-p '(void-function harness-nope)))
  (should (harness-error-report-internal-p '(wrong-number-of-arguments foo 2))))

(ert-deftest harness-errors-log-filter-masks-secrets-in-a-report ()
  "A report is filtered as a log line is, so a known secret is not written."
  (harness-test-with-temp-state
    (let ((harness-log-filter-function
           (lambda (text) (string-replace "hunter2" "[masked]" text))))
      (harness-error-report '(error "the password is %s" "hunter2")))
    (let ((text (harness-errors-test--text)))
      (should (string-search "[masked]" text))
      (should-not (string-search "hunter2" text)))))

(ert-deftest harness-errors-reporting-can-be-turned-off ()
  "With reporting off nothing is written, even by an installed catcher."
  (harness-test-with-temp-state
    (harness-errors-test--with-reporter
      (let ((harness-error-reporting nil))
        (harness-error-report-maybe '(error "not kept") :context "test")))
    (should-not (file-exists-p (harness-error-details-path)))))

(defun harness-errors-test--ensure-methods ()
  "Register the `errors/…' methods again when a test has reset the bus."
  (unless (harness-method-exists-p 'errors/recent)
    (load "harness-errors" nil t)))

(ert-deftest harness-errors-reports-are-read-back-from-the-file ()
  "A report written to the details file is read back as a plist.
The newest is first, the stack is kept, and the session and task ids
are there to filter on."
  (harness-test-with-temp-state
    (harness-error-report '(wrong-type-argument listp 1)
                          :context "promise handler"
                          :session "session-one" :task "task-one"
                          :backtrace "   0  car (1)\n   1  harness-test-caller ()")
    (harness-error-report '(void-function harness-nope)
                          :context "timer"
                          :session "session-two"
                          :backtrace "   0  harness-nope ()")
    (let ((reports (harness-error-reports)))
      (should (= 2 (length reports)))
      (should (equal "session-two" (plist-get (car reports) :session)))
      (should (equal "timer" (plist-get (car reports) :where)))
      (should (equal "(void-function harness-nope)" (plist-get (car reports) :error)))
      (should (string-search "harness-nope" (plist-get (car reports) :trace)))
      (should (string-search "HARNESS ERROR" (plist-get (car reports) :text)))
      (should-not (plist-get (car reports) :task))
      (should (equal "session-one" (plist-get (cadr reports) :session)))
      (should (equal "task-one" (plist-get (cadr reports) :task)))
      (should (string-search "car (1)" (plist-get (cadr reports) :trace))))
    ;; A limit, and the session and task filters.
    (should (= 1 (length (harness-error-reports 1))))
    (should (equal "session-two" (plist-get (car (harness-error-reports 1)) :session)))
    (should (= 1 (length (harness-error-reports nil "session-one"))))
    (should (= 1 (length (harness-error-reports nil nil "task-one"))))
    (should-not (harness-error-reports nil "session-none"))))

(ert-deftest harness-errors-no-file-gives-no-reports ()
  "A harness that never wrote a report reads back none, and says where they go."
  (harness-test-with-temp-state
    (harness-errors-test--ensure-methods)
    (should-not (harness-error-reports))
    (let ((path (harness-call 'errors/path)))
      (should (equal (harness-error-details-path) (plist-get path :file)))
      (should-not (plist-get path :exists))
      (should-not (plist-get path :size)))))

(ert-deftest harness-errors-methods-read-the-file ()
  "The harness reads its own details through `errors/recent' and `errors/path'."
  (harness-test-with-temp-state
    (harness-errors-test--ensure-methods)
    (harness-error-report '(error "method boom") :context "subscriber"
                          :session "session-methods")
    (let ((path (harness-call 'errors/path))
          (recent (harness-call 'errors/recent 1 "session-methods")))
      (should (equal (harness-error-details-path) (plist-get path :file)))
      (should (plist-get path :exists))
      (should (numberp (plist-get path :size)))
      (should (equal (concat (harness-error-details-path) ".1")
                     (plist-get (plist-get path :rotated) :file)))
      (should (= 1 (length recent)))
      (should (string-search "method boom" (plist-get (car recent) :text))))
    ;; The limit is a number of reports, and the method says so.
    (should-error (harness-call 'errors/recent "many") :type 'harness-error)))

(ert-deftest harness-errors-tool-reads-the-reports ()
  "The read_harness_errors tool returns the reports and names what it reads."
  (harness-test-with-temp-state
    (require 'harness-tools)
    (harness-error-report '(error "tool boom") :context "filter"
                          :session "session-tool")
    (let ((tool (harness-tool-get "read_harness_errors")))
      (should tool)
      (should (eq 'read (harness-tool-kind tool)))
      (should (equal (harness-error-details-files)
                     (harness-tools--call-paths tool '(:limit 1) nil)))
      (let ((result (funcall (harness-tool-handler tool) '(:limit 1) nil)))
        (should-not (plist-get result :is-error))
        (should (string-search "tool boom" (plist-get result :content)))
        (should (string-search "session-tool" (plist-get result :content)))
        (should (= 1 (plist-get (plist-get result :meta) :reports))))
      ;; A filter that matches nothing says so, and names the file.
      (let ((result (funcall (harness-tool-handler tool) '(:session "session-none") nil)))
        (should (string-search "No harness error reports" (plist-get result :content)))
        (should (string-search (harness-error-details-path) (plist-get result :content)))))))

(ert-deftest harness-errors-system-prompt-names-the-file ()
  "The agent is told the details file exists and that it needs permission.
The prompt names no path: it is the same words in every run of the
harness, so a session resumed after a restart still sends the same
prompt, and the provider's cache still serves it."
  (require 'harness-agent)
  (let ((prompt (harness-agent--system-prompt
                 (list :id "session-prompt" :cwd "/tmp" :model "model" :project "/tmp"))))
    (should (string-search "Harness errors:" prompt))
    (should-not (string-search (harness-error-details-path) prompt))
    (should (string-match-p "cannot read that file by default" prompt))
    (should (string-search "read_harness_errors" prompt))))

(provide 'harness-errors-test)
;;; harness-errors-test.el ends here
