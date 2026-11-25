;;; harness-fuzz-session-test.el --- Normal turn soak oracles -*- lexical-binding: t; -*-
(require 'harness-test-helpers)
(require 'harness-fuzz)
(require 'harness-provider-openai)

(ert-deftest harness-fuzz-session-ordinary-turns-exercise-the-real-tool-catalog ()
  (let ((first (harness-fuzz-session--check
                (apply #'unibyte-string (cl-loop for i below 24 append (list 1 (+ 2 (* i 3))))) t))
        (last (harness-fuzz-session--check (unibyte-string 1 74 1 77) t)))
    (should-not (plist-get first :changes))
    (should (>= (plist-get first :tools) 70))
    ;; These seeds together call every tool declaration through the dispatcher.
    (should (= (plist-get first :tools)
               (length (delete-dups (append (plist-get first :called) (plist-get last :called))))))
    (should (> (plist-get first :requests) (plist-get first :turns)))
    (should (> (plist-get first :executions) 70))))

(ert-deftest harness-fuzz-session-cache-mutations-survive-normal-turns-and-reload ()
  (let ((summary (harness-fuzz-session--check
                  (apply #'unibyte-string (cl-loop for i below 12 append (list i (+ 32 i)))))))
    (should (= 15 (plist-get summary :turns)))
    (should (= 2 (plist-get summary :reloads)))
    (dolist (action '(schema description effort thinking system model reload reset-schema history dialect))
      (should (memq action (plist-get summary :changes))))))

(ert-deftest harness-fuzz-session-late-catalogue-changes-effort-on-the-wire ()
  (let ((efforts (plist-get (harness-fuzz-session--check (unibyte-string 4 0)) :efforts)))
    (should (equal '(:effort "high") (car efforts)))
    (should (member '(:effort "max") (cdr efforts)))))

(ert-deftest harness-fuzz-session-oracle-rejects-a-contained-turn-error ()
  (let ((finish (symbol-function 'harness-openai--stream-finish)))
    (cl-letf (((symbol-function 'harness-openai--stream-finish)
               (lambda (stream reason &optional error)
                 (funcall finish stream (if (eq reason 'end-turn) 'error reason)
                          (or error "injected terminal failure")))))
      (should-error (harness-fuzz-session--check "")))))

(ert-deftest harness-fuzz-session-oracle-rejects-a-tool-error-even-if-turn-continues ()
  (let ((null-tool (symbol-function 'harness-fuzz-session--null-tool)))
    (cl-letf (((symbol-function 'harness-fuzz-session--null-tool)
               (lambda (tool handler &rest rest)
                 (apply null-tool tool
                        (lambda (&rest args)
                          (apply handler args)
                          '(:is-error t :content "injected tool failure"))
                        rest))))
      (should-error (harness-fuzz-session--check "")))))

(ert-deftest harness-fuzz-session-oracle-rejects-an-unsettled-turn ()
  (let ((await (symbol-function 'harness-test-await)))
    (cl-letf (((symbol-function 'harness-test-await)
               (lambda (_promise &rest _) (funcall await (harness-make-promise) 0.02))))
      (should-error (harness-fuzz-session--check "")))))

(ert-deftest harness-fuzz-session-input-is-bounded-and-live-state-is-refused ()
  (should (= 24 (length (harness-fuzz-session-decode (make-string 1024 255)))))
  (let ((harness-started t)) (should-error (harness-fuzz-session--check ""))))

(provide 'harness-fuzz-session-test)
;;; harness-fuzz-session-test.el ends here
