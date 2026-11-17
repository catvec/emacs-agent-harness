;;; harness-test-runner-test.el --- Test results cannot hide a red suite  -*- lexical-binding: t; -*-

;;; Code:

(require 'harness-test-helpers)

(defun harness-test-runner-test--command (root &rest args)
  "Run ARGS in ROOT, returning (EXIT . OUTPUT)."
  (with-temp-buffer
    (let ((default-directory root))
      (cons (apply #'call-process (car args) nil t nil (cdr args)) (buffer-string)))))

(defun harness-test-runner-test--git (root &rest args)
  "Run git ARGS in ROOT, signaling with its output if it fails."
  (let ((result (apply #'harness-test-runner-test--command root "git" args)))
    (unless (equal 0 (car result)) (error "git %S: %s" args (cdr result)))
    (string-trim (cdr result))))

(defun harness-test-runner-test--write (root file text)
  "Write TEXT to FILE under ROOT."
  (let ((path (expand-file-name file root)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert text))))

(defmacro harness-test-runner-test-with (&rest body)
  "Run BODY in a tiny checkout of test.sh, with an Emacs test double."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let* ((root (file-name-as-directory dir))
            (process-environment (copy-sequence process-environment)))
       (make-directory (expand-file-name "scripts" root) t)
       (copy-file (expand-file-name "scripts/test.sh" harness-test-root)
                  (expand-file-name "scripts/test.sh" root))
       (harness-test-runner-test--write root ".gitignore" "scripts/.dev/\n")
       ;; A module's test lives beside it, not under test/.
       (harness-test-runner-test--write root "lisp/modules/harness-fixture.el"
                                        ";;; harness-fixture.el --- A fixture  -*- lexical-binding: t; -*-\n")
       (harness-test-runner-test--write root "lisp/modules/harness-fixture-test.el" "; fixture\n")
       ;; Exercise the actual runner, not ERT again.  It must write
       ;; `running' before invoking any suite, even after a prior pass.
       (harness-test-runner-test--write
        root "bin/emacs"
        (concat "#!/bin/bash\n"
                "if ! python3 -c 'import json; assert json.load(open(\"scripts/.dev/test-stamp.json\"))[\"result\"] == \"running\"'; then exit 9; fi\n"
                "echo 'Ran 1 tests, 1 results as expected, 0 unexpected'\n"
                "exit \"${HARNESS_TEST_FAKE_STATUS:-0}\"\n"))
       (set-file-modes (expand-file-name "bin/emacs" root) #o755)
       (setenv "PATH" (concat (expand-file-name "bin" root) path-separator (getenv "PATH")))
       (setenv "HARNESS_TEST_JOBS" "1")
       (setenv "HARNESS_TEST_FAKE_STATUS" "0")
       (setenv "HARNESS_TEST_LOGS" nil)
       (setenv "HARNESS_TEST_TIMINGS" nil)
       (harness-test-runner-test--git root "init" "-q")
       (harness-test-runner-test--git root "config" "user.name" "Harness Test")
       (harness-test-runner-test--git root "config" "user.email" "test@example.invalid")
       (harness-test-runner-test--git root "config" "commit.gpgsign" "false")
       (harness-test-runner-test--git root "add" "-A")
       (harness-test-runner-test--git root "commit" "-qm" "fixture")
       ,@body)))

(defun harness-test-runner-test--stamp (root)
  "Read the actual runner's record from ROOT."
  (harness-json-parse
   (harness-read-file (expand-file-name "scripts/.dev/test-stamp.json" root))))

(ert-deftest harness-test-runner-full-pass-records-the-clean-tested-commit ()
  (harness-test-runner-test-with
    (let ((result (harness-test-runner-test--command root "bash" "scripts/test.sh")))
      (should (equal 0 (car result)))
      (should (string-match-p "TEST RESULT: PASS (full run)" (cdr result))))
    (let ((stamp (harness-test-runner-test--stamp root)))
      (should (equal "full" (plist-get stamp :kind)))
      (should (equal "pass" (plist-get stamp :result)))
      (should (equal (harness-test-runner-test--git root "rev-parse" "HEAD")
                     (plist-get stamp :head)))
      (should (eq :false (plist-get stamp :dirty)))
      (should (equal 1 (plist-get stamp :files)))
      (should-not (plist-get stamp :failed)))
    (should (equal 0 (car (harness-test-runner-test--command
                          root "bash" "scripts/test.sh" "--status"))))))

(ert-deftest harness-test-runner-failure-cannot-leave-a-previous-pass-standing ()
  (harness-test-runner-test-with
    (should (equal 0 (car (harness-test-runner-test--command root "bash" "scripts/test.sh"))))
    ;; The double also verifies the old pass is replaced by `running'.
    (setenv "HARNESS_TEST_FAKE_STATUS" "1")
    (let ((result (harness-test-runner-test--command root "bash" "scripts/test.sh")))
      (should (equal 1 (car result)))
      (should (string-match-p "TEST RESULT: FAIL (full run)" (cdr result))))
    (let ((stamp (harness-test-runner-test--stamp root)))
      (should (equal "fail" (plist-get stamp :result)))
      (should (equal '("lisp/modules/harness-fixture-test.el") (plist-get stamp :failed))))
    (let ((status (harness-test-runner-test--command root "bash" "scripts/test.sh" "--status")))
      (should (equal 1 (car status)))
      (should (string-match-p "FAILED: lisp/modules/harness-fixture-test.el" (cdr status))))))

(ert-deftest harness-test-runner-failure-output-says-to-repair-every-failure ()
  "A failing run must say, itself, that every failure is to be repaired.
The rule has to reach the agent in the output of the run that failed, not only
in a document it may not have read, and the run must stay failed while it says
so: a baseline failure is still a failure."
  (harness-test-runner-test-with
    (let ((result (harness-test-runner-test--command root "bash" "scripts/test.sh")))
      (should (equal 0 (car result)))
      ;; A passing run is a plain report of what passed.
      (should-not (string-match-p "TEST FAILURES" (cdr result))))
    (setenv "HARNESS_TEST_FAKE_STATUS" "1")
    (let ((result (harness-test-runner-test--command root "bash" "scripts/test.sh")))
      ;; The directive, and the same nonzero status the run had before.
      (should (equal 1 (car result)))
      (should (string-match-p
               "TEST FAILURES: investigate and repair EVERY one of them"
               (cdr result)))
      (should (string-match-p "already on main" (cdr result)))
      (should (string-match-p
               "also fails at the branch's base is still a failure" (cdr result)))
      (should (string-match-p "Do not skip, delete, weaken" (cdr result)))
      ;; It names the suites to repair, after the summary.
      (should (string-match-p
               "failed suites, each to be repaired" (cdr result)))
      (should (string-match-p "TEST RESULT: FAIL (full run)" (cdr result))))
    ;; The saved record of the run carries it too, and --status says it while
    ;; still refusing the run.
    (should (equal "fail" (plist-get (harness-test-runner-test--stamp root) :result)))
    (let ((status (harness-test-runner-test--command
                   root "bash" "scripts/test.sh" "--status")))
      (should (equal 1 (car status)))
      (should (string-match-p
               "investigate and repair EVERY one of them" (cdr status))))))

(ert-deftest harness-test-runner-selected-pass-is-not-a-full-pass ()
  (harness-test-runner-test-with
    (should (equal 0 (car (harness-test-runner-test--command root "bash" "scripts/test.sh"))))
    (should (equal 0 (car (harness-test-runner-test--command
                          root "bash" "scripts/test.sh" "lisp/modules/harness-fixture-test.el"))))
    (should (equal "selected" (plist-get (harness-test-runner-test--stamp root) :kind)))
    (let ((status (harness-test-runner-test--command root "bash" "scripts/test.sh" "--status")))
      (should (equal 1 (car status)))
      (should (string-match-p "selected suites are not a full run" (cdr status))))))

(ert-deftest harness-test-runner-a-stale-pass-names-no-failures ()
  "A run that passed on another commit has nothing to repair, and says so.
The directive names failures and tells the reader to repair every one of
them.  Printed for a run that passed, it points at failures that are not
there and sends the reader looking through the logs of a green run; what
such a record needs is the run again, on the commit that is there now."
  (harness-test-runner-test-with
    (should (equal 0 (car (harness-test-runner-test--command root "bash" "scripts/test.sh"))))
    (harness-test-runner-test--write root "notes" "a change after the run\n")
    (harness-test-runner-test--git root "add" "-A")
    (harness-test-runner-test--git root "commit" "-qm" "after the run")
    (let ((status (harness-test-runner-test--command root "bash" "scripts/test.sh" "--status")))
      ;; It still refuses to call the tree verified.
      (should (equal 1 (car status)))
      (should (string-match-p "HEAD changed since the run" (cdr status)))
      ;; But it does not invent failures, and it says what to do instead.
      (should-not (string-match-p "TEST FAILURES" (cdr status)))
      (should-not (string-match-p "investigate and repair" (cdr status)))
      (should (string-match-p "Run the full suite again on this commit" (cdr status))))))

(ert-deftest harness-test-runner-status-refuses-a-stale-or-dirty-result ()
  (harness-test-runner-test-with
    (should (equal 1 (car (harness-test-runner-test--command
                          root "bash" "scripts/test.sh" "--status"))))
    (should (equal 0 (car (harness-test-runner-test--command root "bash" "scripts/test.sh"))))
    (harness-test-runner-test--write root "notes" "a change after the run\n")
    (let ((status (harness-test-runner-test--command root "bash" "scripts/test.sh" "--status")))
      (should (equal 1 (car status)))
      (should (string-match-p "uncommitted changes" (cdr status))))
    (harness-test-runner-test--git root "add" "-A")
    (harness-test-runner-test--git root "commit" "-qm" "after the run")
    (let ((status (harness-test-runner-test--command root "bash" "scripts/test.sh" "--status")))
      (should (equal 1 (car status)))
      (should (string-match-p "HEAD changed since the run" (cdr status))))
    ;; A pass made while dirty must not turn into a clean-tree pass.
    (harness-test-runner-test--write root "notes" "dirty while tested\n")
    (should (equal 0 (car (harness-test-runner-test--command root "bash" "scripts/test.sh"))))
    (should (eq t (plist-get (harness-test-runner-test--stamp root) :dirty)))
    (should (equal 1 (car (harness-test-runner-test--command
                          root "bash" "scripts/test.sh" "--status"))))))

(ert-deftest harness-test-runner-status-refuses-an-unfinished-run ()
  (harness-test-runner-test-with
    (harness-test-runner-test--write root "scripts/.dev/test-stamp.json"
                                     "{\"format\":1,\"result\":\"running\",\"failed\":[]}")
    (let ((status (harness-test-runner-test--command root "bash" "scripts/test.sh" "--status")))
      (should (equal 1 (car status)))
      (should (string-match-p "TEST RESULT: RUNNING" (cdr status))))))

(ert-deftest harness-test-runner-finds-a-test-beside-its-module ()
  "The runner discovers a module's test beside it, and a repository suite in test/."
  (harness-test-runner-test-with
    (harness-test-runner-test--write root "test/harness-repository-test.el" "; repository\n")
    (let ((result (harness-test-runner-test--command root "bash" "scripts/test.sh")))
      (should (equal 0 (car result))))
    (let ((stamp (harness-test-runner-test--stamp root)))
      (should (equal "full" (plist-get stamp :kind)))
      (should (equal 2 (plist-get stamp :files))))
    ;; Named files run where they are, test/ or beside their module.
    (should (equal 0 (car (harness-test-runner-test--command
                           root "bash" "scripts/test.sh"
                           "test/harness-repository-test.el"))))))

(ert-deftest harness-test-runner-changed-module-runs-the-test-beside-it ()
  "A changed module runs its sibling test, not every suite."
  (harness-test-runner-test-with
    (harness-test-runner-test--write root "lisp/modules/harness-fixture.el"
                                     ";;; harness-fixture.el --- Changed  -*- lexical-binding: t; -*-\n")
    (let* ((result (harness-test-runner-test--command root "bash" "scripts/test.sh" "--changed"))
           (output (cdr result)))
      (should (equal 0 (car result)))
      (should (string-match-p "test.sh --changed: 1 suite(s) to run:" output))
      (should (string-match-p "lisp/modules/harness-fixture-test.el" output))
      (should-not (string-match-p "running every suite" output)))
    (let ((stamp (harness-test-runner-test--stamp root)))
      (should (equal "selected" (plist-get stamp :kind)))
      (should (equal 1 (plist-get stamp :files))))))

(provide 'harness-test-runner-test)
;;; harness-test-runner-test.el ends here
