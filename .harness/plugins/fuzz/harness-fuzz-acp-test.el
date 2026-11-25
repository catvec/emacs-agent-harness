;;; harness-fuzz-acp-test.el --- Valid ACP scenario oracles -*- lexical-binding: t; -*-
(require 'harness-test-helpers)
(require 'harness-fuzz)

(ert-deftest harness-fuzz-acp-grammar-covers-every-standard-command ()
  (should (equal (sort (append harness-fuzz-acp-methods nil) #'string<)
                 (sort (hash-table-keys harness-acp--standard-methods) #'string<)))
  (let ((summary (harness-fuzz-acp--check
                  (apply #'unibyte-string
                         (cl-loop for opcode below 9 append (list opcode (+ 128 opcode)))))))
    (dolist (method (append harness-fuzz-acp-methods nil))
      ;; Cancellation is a notification and intentionally has no reply ID.
      (unless (equal method "session/cancel")
        (should (member method (plist-get summary :methods)))))
    (should (= (plist-get summary :rpcs) (plist-get summary :responses)))
    (should (= (plist-get summary :starts) (plist-get summary :ends)))))

(ert-deftest harness-fuzz-acp-duplicate-tools-and-cancellation-are-exercised ()
  (let ((normal (harness-fuzz-acp--check (unibyte-string 3 1)))
        (cancelled (harness-fuzz-acp--check (unibyte-string 3 1 4 0 3 0))))
    (should (= 1 (plist-get normal :effects)))
    (should (= 0 (plist-get cancelled :effects)))
    (should (>= (plist-get cancelled :starts) 3))))

(ert-deftest harness-fuzz-acp-oracle-detects-lost-rpc-delivery ()
  (let ((encode (symbol-function 'harness-json-encode)))
    (cl-letf (((symbol-function 'harness-json-encode)
               (lambda (value)
                 (funcall encode
                          (if (and (listp value) (plist-member value :result) (plist-get value :id))
                              (plist-put (copy-sequence value) :id (+ 100 (plist-get value :id)))
                            value)))))
      (should-error (harness-fuzz-acp--check "")))))

(ert-deftest harness-fuzz-acp-arbitrary-bytes-always-reach-valid-command-scenarios ()
  (dotimes (seed 16)
    (ert-info ((format "seed %s" seed))
      (let* ((bytes (apply #'unibyte-string
                           (cl-loop for i below 32 collect (mod (+ (* seed 71) (* i 29)) 256))))
             (summary (harness-fuzz-acp--check bytes)))
        (should (> (plist-get summary :rpcs) 10))
        (should (= (plist-get summary :rpcs) (plist-get summary :responses)))
        (should (= (plist-get summary :starts) (plist-get summary :ends)))))))

(ert-deftest harness-fuzz-acp-stateful-target-refuses-a-live-harness ()
  (let ((harness-started t))
    (should-error (harness-fuzz-acp--check ""))))

(provide 'harness-fuzz-acp-test)
;;; harness-fuzz-acp-test.el ends here
