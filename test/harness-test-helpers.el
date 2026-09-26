;;; harness-test-helpers.el --- Shared test utilities -*- lexical-binding: t; -*-

;;; Commentary:

;; Small helpers every suite can use.  Kept free of state so that loading
;; it cannot affect a module under test.

;;; Code:

(require 'harness-core)

(defun harness-test-wait-for (predicate &optional seconds)
  "Wait up to SECONDS (default 2) for PREDICATE to return non-nil.
Processes timers and process output while waiting."
  (let ((end (+ (float-time) (or seconds 2))))
    (while (and (not (funcall predicate)) (< (float-time) end))
      (accept-process-output nil 0.02)
      (sit-for 0.01))
    (funcall predicate)))

(defun harness-test-settle (deferred &optional seconds)
  "Wait up to SECONDS for DEFERRED to settle, and return it."
  (harness-test-wait-for (lambda () (not (harness-deferred-pending-p deferred))) seconds)
  deferred)

(defun harness-test-rejection (deferred &optional seconds)
  "Wait for DEFERRED to settle and return its rejection value."
  (harness-test-settle deferred seconds)
  (harness-deferred-value deferred))

(provide 'harness-test-helpers)
;;; harness-test-helpers.el ends here
