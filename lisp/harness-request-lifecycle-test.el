;;; harness-request-lifecycle-test.el --- Request ownership contracts -*- lexical-binding: t; -*-
(require 'harness-test-helpers)
(require 'harness-request-lifecycle)

(ert-deftest harness-request-lifecycle-finish-fences-reentry-before-preparing ()
  (let ((control (harness-request-lifecycle-create)) seen)
    (harness-request-lifecycle-finish
     control (lambda (value) (push value seen))
     (lambda ()
       (should-not (harness-request-lifecycle-open-p control))
       (harness-request-lifecycle-finish control #'ignore (lambda () (ert-fail "reentered")) 'wrong)
       'answer)
     'fallback)
    (should (equal '(answer) seen))
    (should (eq 'finished (harness-request-lifecycle-phase control)))))

(ert-deftest harness-request-lifecycle-preparation-errors-cannot-lose-delivery ()
  (dolist (stage '(prepare error-handler))
    (let ((control (harness-request-lifecycle-create)) seen)
      (should-error
       (harness-request-lifecycle-finish
        control (lambda (value) (push value seen)) (lambda () (error "prepare")) 'fallback
        (and (eq stage 'error-handler) (lambda (_err) (error "error handler")))))
      (should (equal '(fallback) seen))
      (harness-request-lifecycle-finish control #'ignore (lambda () (ert-fail "reopened")) nil))))

(ert-deftest harness-request-lifecycle-converts-failure-without-replacing-valid-results ()
  (let ((control (harness-request-lifecycle-create)) seen)
    (harness-request-lifecycle-finish
     control (lambda (value) (push value seen)) (lambda () (error "prepare")) 'fallback
     (lambda (_err) 'protocol-error))
    (should (equal '(protocol-error) seen)))
  (let* ((control (harness-request-lifecycle-create)) (value (list :valid t)) delivered)
    (harness-request-lifecycle-finish control (lambda (result) (setq delivered result))
                                      (lambda () value) nil)
    (should (eq value delivered))))

(ert-deftest harness-request-lifecycle-delivery-failure-does-not-redeliver ()
  (let ((control (harness-request-lifecycle-create)) (attempts 0))
    (should-error (harness-request-lifecycle-finish
                   control (lambda (_) (cl-incf attempts) (error "delivery")) (lambda () 'answer) nil))
    (harness-request-lifecycle-finish control (lambda (_) (cl-incf attempts)) (lambda () 'again) nil)
    (should (= 1 attempts))))

(ert-deftest harness-request-lifecycle-cancellation-belongs-to-the-late-producer ()
  (let ((old (harness-request-lifecycle-create)) (new (harness-request-lifecycle-create))
        (old-count 0) (new-count 0))
    (harness-request-lifecycle-cancel old)
    (harness-request-lifecycle-set-cancel new (lambda () (cl-incf new-count)))
    (harness-request-lifecycle-set-cancel old (lambda () (cl-incf old-count)))
    (harness-request-lifecycle-cancel old)
    (should (= 1 old-count))
    (should (= 0 new-count))
    (should-error (harness-request-lifecycle-set-cancel old #'ignore))))

(ert-deftest harness-request-lifecycle-cancellation-fences-reentry-and-permits-failure-retry ()
  (let ((control (harness-request-lifecycle-create)) (attempts 0))
    (harness-request-lifecycle-set-cancel
     control (lambda ()
               (cl-incf attempts)
               (harness-request-lifecycle-cancel control)
               (when (= attempts 1) (error "cancel failed"))))
    (should-error (harness-request-lifecycle-cancel control))
    (should (= 1 attempts))
    (harness-request-lifecycle-cancel control)
    (harness-request-lifecycle-cancel control)
    (should (= 2 attempts))))

(ert-deftest harness-request-cancel-scope-isolates-failures-and-late-acquisition ()
  (let ((scope (harness-request-cancel-scope-create)) (first 0) (second 0) (late 0))
    (harness-request-cancel-scope-add scope 'second (lambda () (cl-incf second)))
    (harness-request-cancel-scope-add scope 'first (lambda () (cl-incf first) (error "cancel failed")))
    (should-error (harness-request-cancel-scope-cancel scope))
    (should (= 1 second))
    (harness-request-cancel-scope-add scope 'late (lambda () (cl-incf late)))
    (should (= 1 late))
    (should-error (harness-request-cancel-scope-cancel scope))
    (should (= 2 first))
    (should (= 1 second late))))

(provide 'harness-request-lifecycle-test)
;;; harness-request-lifecycle-test.el ends here
