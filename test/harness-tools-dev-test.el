;;; harness-tools-dev-test.el --- Tests for the open_harness tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; The tool and method that run a checkout's harness in an Emacs of its
;; own (harness-tools-dev.el).  A fake scripts/dev.sh in a temp checkout
;; records what the launcher ran, so no Emacs is started here.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-tools)

(defmacro harness-tools-dev-test-with (&rest body)
  "Load the tools registry and tools-dev on a fresh bus; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(tools tools-dev))
       (harness-test-load-module m))
     ,@body))

(ert-deftest harness-tools-dev-socket-is-stable-and-distinct ()
  "A checkout always opens under the same socket, another under another."
  (harness-tools-dev-test-with
    (let ((a (harness-test-harness-checkout))
          (b (harness-test-harness-checkout)))
      (should (string-prefix-p "harness-dev-" (harness-tools-dev-socket a)))
      (should (equal (harness-tools-dev-socket a) (harness-tools-dev-socket a)))
      (should-not (equal (harness-tools-dev-socket a) (harness-tools-dev-socket b)))
      (should (string-prefix-p (expand-file-name "scripts/.dev/" a)
                               (harness-tools-dev-state a (harness-tools-dev-socket a)))))))

(ert-deftest harness-tools-dev-checkout-detection ()
  "A checkout is harness.el and scripts/dev.sh side by side."
  (harness-tools-dev-test-with
    (let ((dir (harness-test-harness-checkout))
          (plain (harness-test-temp-dir)))
      (should (harness-tools-dev-checkout-p dir))
      (should (harness-tools-dev-checkout-p harness-test-root))
      (should-not (harness-tools-dev-checkout-p plain))
      (should-not (harness-tools-dev-checkout-p nil))
      (delete-file (expand-file-name "scripts/dev.sh" dir))
      (should-not (harness-tools-dev-checkout-p dir)))))

(ert-deftest harness-tools-dev-tool-is-for-this-project-only ()
  "The tool is offered in a harness checkout, and nowhere else."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (here (list :cwd dir))
           (elsewhere (list :cwd (harness-test-temp-dir)))
           (names (list "open_harness" "bash")))
      (should (equal '("open_harness" "bash") (harness-tools-dev--tools names here)))
      (should (equal '("bash") (harness-tools-dev--tools names elsewhere)))
      ;; The catalogue (no session) keeps it.
      (should (equal '("open_harness" "bash") (harness-tools-dev--tools names nil)))
      ;; The real filter chain `tools/list' runs.
      (should (member "open_harness" (harness-run-filter 'agent/tools names here)))
      (should-not (member "open_harness" (harness-run-filter 'agent/tools names elsewhere)))
      ;; A task worktree counts through the session's :worktree too.
      (let ((worktree (list :cwd (harness-test-temp-dir) :worktree dir)))
        (should (member "open_harness" (harness-run-filter 'agent/tools names worktree)))))))

(ert-deftest harness-tools-dev-tool-runs-the-live-loop ()
  "The tool runs the checkout's scripts/dev.sh with its own socket."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (result (harness-test-await (harness-tools-dev--open nil (list :cwd dir)))))
      (should-not (plist-get result :is-error))
      (should (string-match-p (regexp-quote (harness-tools-dev-socket dir))
                              (plist-get result :content)))
      (let ((calls (harness-test-dev-invocations dir)))
        (should (= 1 (length calls)))
        (should (file-equal-p dir (cdr (assoc "cwd" (car calls)))))
        (should (equal "start" (cdr (assoc "args" (car calls)))))
        (should (equal (harness-tools-dev-socket dir) (cdr (assoc "socket" (car calls)))))))))

(ert-deftest harness-tools-dev-tool-refuses-other-directories ()
  "A path that is not a harness checkout is an error, before anything runs."
  (harness-tools-dev-test-with
    (let ((plain (harness-test-temp-dir)))
      (let ((result (harness-tools-dev--open (list :path plain) (list :cwd plain))))
        (should (plist-get result :is-error))
        (should (string-match-p "not a checkout" (plist-get result :content)))
        (should-not (file-exists-p (expand-file-name "invocation.log" plain)))))))

(ert-deftest harness-tools-dev-method-opens-a-checkout ()
  "The board's method starts the checkout and returns its info."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (info (harness-test-await (harness-call 'harness-dev/open dir))))
      (should (equal dir (plist-get info :path)))
      (should (equal (harness-tools-dev-socket dir) (plist-get info :socket)))
      (should-not (plist-get info :focused))
      (should (= 1 (length (harness-test-dev-invocations dir)))))))

(ert-deftest harness-tools-dev-method-focuses-the-frame ()
  "With focus the instance's frame is raised through its own dev loop."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (info (harness-test-await (harness-call 'harness-dev/open dir t))))
      (should (plist-get info :focused))
      (let ((calls (harness-test-dev-invocations dir)))
        (should (= 2 (length calls)))
        (should (equal "start" (cdr (assoc "args" (car calls)))))
        (should (equal "eval (harness-dev-focus)" (cdr (assoc "args" (cadr calls)))))))))

(provide 'harness-tools-dev-test)
;;; harness-tools-dev-test.el ends here
