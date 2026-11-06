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
       (harness-test-runner-test--write root "test/harness-fixture-test.el" "; fixture\n")
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
      (should (equal '("test/harness-fixture-test.el") (plist-get stamp :failed))))
    (let ((status (harness-test-runner-test--command root "bash" "scripts/test.sh" "--status")))
      (should (equal 1 (car status)))
      (should (string-match-p "FAILED: test/harness-fixture-test.el" (cdr status))))))

(ert-deftest harness-test-runner-selected-pass-is-not-a-full-pass ()
  (harness-test-runner-test-with
    (should (equal 0 (car (harness-test-runner-test--command root "bash" "scripts/test.sh"))))
    (should (equal 0 (car (harness-test-runner-test--command
                          root "bash" "scripts/test.sh" "test/harness-fixture-test.el"))))
    (should (equal "selected" (plist-get (harness-test-runner-test--stamp root) :kind)))
    (let ((status (harness-test-runner-test--command root "bash" "scripts/test.sh" "--status")))
      (should (equal 1 (car status)))
      (should (string-match-p "selected suites are not a full run" (cdr status))))))

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

(provide 'harness-test-runner-test)
;;; harness-test-runner-test.el ends here
