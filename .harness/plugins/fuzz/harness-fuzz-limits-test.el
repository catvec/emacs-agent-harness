;;; harness-fuzz-limits-test.el --- Shared retry and pool oracles -*- lexical-binding: t; -*-
(require 'harness-test-helpers)
(require 'harness-fuzz)

(ert-deftest harness-fuzz-limits-rate-burst-is-bounded-and-every-session-recovers ()
  (let ((summary (harness-fuzz-limits--check
                  (unibyte-string 1 1 0 0 2 1 0 1 0 2 0 3 0 4 0 5 8 0 2 4))))
    (should (= 8 (plist-get summary :sessions)))
    (should (>= (plist-get summary :prefix-checks) 8))
    (should (> (plist-get summary :wait-failures) 0))
    (should (> (plist-get summary :logical) 6))
    (should (= (plist-get summary :starts) (plist-get summary :ends)))))

(ert-deftest harness-fuzz-limits-corpus-survives-http-stream-outages-and-cancellation ()
  (let ((target (harness-fuzz-target-get 'shared-rate-limits)))
    (dolist (seed (harness-fuzz-target-seeds target))
      (let ((summary (harness-fuzz-limits--check seed)))
        (should (>= (plist-get summary :starts) 8))
        (should (= (plist-get summary :starts) (plist-get summary :ends)))))))

(ert-deftest harness-fuzz-limits-oracle-rejects-lost-retry-budgets ()
  (let ((call (symbol-function 'harness-call)))
    (cl-letf (((symbol-function 'harness-call)
               (lambda (method &rest args)
                 (when (eq method 'provider/complete)
                   (setq args (cons (harness-plist-remove (car args) :harness-retry-request) (cdr args))))
                 (apply call method args))))
      (let ((error (should-error
                    (harness-fuzz-limits--check (unibyte-string 1 1 0 0 2 2 0 1 8 0 2 4)))))
        (should (string-match-p "budget\\|unfinished" (error-message-string error)))))))

(ert-deftest harness-fuzz-limits-oracle-rejects-a-stranded-caller-after-work-finishes ()
  (let ((call (symbol-function 'harness-call)))
    (cl-letf (((symbol-function 'harness-call)
               (lambda (method &rest args)
                 (let ((answer (apply call method args)))
                   (if (eq method 'agent/prompt) (harness-make-promise) answer)))))
      (should-error (harness-fuzz-limits--check "")))))

(ert-deftest harness-fuzz-limits-never-uses-live-state-and-bounds-input ()
  (let ((harness-started t)) (should-error (harness-fuzz-limits--check "")))
  (should (= 24 (length (harness-fuzz-limits-decode (make-string 1024 255))))))

(provide 'harness-fuzz-limits-test)
;;; harness-fuzz-limits-test.el ends here
