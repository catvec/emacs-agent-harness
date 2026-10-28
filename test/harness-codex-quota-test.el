;;; harness-codex-quota-test.el --- Read-only Codex CLI quota tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; The app-server here is a small, fabricated shell process.  Tests never
;; run the installed Codex CLI, read credentials, or contact OpenAI.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-codex-quota)

(defun harness-codex-quota-test--script (account limits)
  "Make a fake app-server answering ACCOUNT and LIMITS as JSON objects."
  (let ((file (make-temp-file "harness-fake-codex-" nil ".sh")))
    (with-temp-file file
      (insert (format (concat "#!/bin/sh\nread init\nprintf '%%s\\n' '%s'\n"
                              "read initialized\nread account\n"
                              "case \"$account\" in *'\"refreshToken\":false'*) ;; "
                              "*) printf '%%s\\n' '{\"id\":2,\"error\":{}}'; exit 0;; esac\n"
                              "printf '%%s\\n' '%s'\nread limits\nprintf '%%s\\n' '%s'\n")
                      "{\"id\":1,\"result\":{\"userAgent\":\"fake\"}}"
                      (harness-json-encode (list :id 2 :result account))
                      (harness-json-encode (list :id 3 :result limits)))))
    (set-file-modes file #o700)
    file))

(ert-deftest harness-codex-quota-protocol-reads-real-window-durations ()
  "The bounded app-server protocol maps the CLI's windows, without tokens."
  (let* ((script (harness-codex-quota-test--script
                  '(:account (:type "chatgpt" :email "same@example.org" :planType "plus"))
                  '(:rateLimits (:limitId "codex" :planType "plus"
                                 :primary (:usedPercent 34 :windowDurationMins 300 :resetsAt 2000000000)
                                 :secondary (:usedPercent 76 :windowDurationMins 10080 :resetsAt 2000600000)))))
         (harness-codex-quota-program script))
    (unwind-protect
        (let* ((answer (harness-test-await (harness-codex-quota-read)))
               (quota (plist-get answer :quota))
               (windows (plist-get quota :windows)))
          (should (eq 'ok (plist-get answer :status)))
          (should (equal "same@example.org" (plist-get answer :email)))
          (should (equal '("5h" "7d") (mapcar (lambda (w) (plist-get w :name)) windows)))
          (should (equal '(0.34 0.76) (mapcar (lambda (w) (plist-get w :used)) windows)))
          (should (equal "codex-cli" (plist-get quota :source)))
          (should (plist-get quota :informational))
          (should-not (string-match-p "access-token\|Bearer\|refresh-token" (format "%S" answer))))
      (delete-file script))))

(ert-deftest harness-codex-quota-protocol-refuses-an-api-key-account ()
  "An API key account is not a ChatGPT login whose usage can be shown."
  (let* ((script (harness-codex-quota-test--script
                  '(:account (:type "apiKey"))
                  '(:rateLimits (:primary (:usedPercent 5 :windowDurationMins 300)))))
         (harness-codex-quota-program script))
    (unwind-protect
        (should (eq 'no-account
                    (plist-get (harness-test-await (harness-codex-quota-read)) :status)))
      (delete-file script))))

(ert-deftest harness-codex-quota-protocol-does-not-invent-null-windows ()
  "A missing allowance is not a zero-percent allowance."
  (let* ((script (harness-codex-quota-test--script
                  '(:account (:type "chatgpt" :email "same@example.org"))
                  '(:rateLimits (:primary :null :secondary :null))))
         (harness-codex-quota-program script))
    (unwind-protect
        (should (eq 'no-quota
                    (plist-get (harness-test-await (harness-codex-quota-read)) :status)))
      (delete-file script))))

(ert-deftest harness-codex-quota-protocol-missing-program-is-safe ()
  "No CLI is a sanitized status, never a thrown credential error."
  (let ((harness-codex-quota-program "/nonexistent/harness-codex-quota"))
    (should (eq 'missing
                (plist-get (harness-test-await (harness-codex-quota-read)) :status)))))

(ert-deftest harness-codex-quota-selects-only-codex-bucket ()
  "A multi-bucket response must not display another model's allowance."
  (should-not (harness-codex-quota--quota
               '(:rateLimitsByLimitId (:other (:primary (:usedPercent 90 :windowDurationMins 300)))
                 :rateLimits (:limitId "other" :primary (:usedPercent 90 :windowDurationMins 300)))))
  (should-not (harness-codex-quota--quota
               '(:rateLimits (:limitId "other" :primary (:usedPercent 90 :windowDurationMins 300)))))
  (let* ((quota (harness-codex-quota--quota
                 '(:rateLimitsByLimitId
                   (:codex (:primary (:usedPercent 8 :windowDurationMins 300))
                    :other (:primary (:usedPercent 90 :windowDurationMins 300)))
                   :rateLimits (:limitId "other" :primary (:usedPercent 90 :windowDurationMins 300)))))
         (windows (plist-get quota :windows)))
    (should (= 0.08 (plist-get (car windows) :used)))
    (should (= 1 (length windows))))
  (should-not (harness-codex-quota--quota
               '(:rateLimits (:primary (:usedPercent 12 :windowDurationMins :null))))))

(defun harness-codex-quota-test--raw-script (body)
  "Create an executable fake CLI that runs shell BODY."
  (let ((file (make-temp-file "harness-fake-codex-" nil ".sh")))
    (with-temp-file file (insert "#!/bin/sh\n" body "\n"))
    (set-file-modes file #o700)
    file))

(ert-deftest harness-codex-quota-protocol-failures-are-sanitized ()
  "Bad JSON, server error and premature exit never expose server output."
  (dolist (body '("read init; printf '%s\\n' '{invalid json token=SECRET}'"
                  "read init; printf '%s\\n' '{\"id\":1,\"error\":{\"message\":\"SECRET\"}}'"
                  "exit 5"))
    (let* ((script (harness-codex-quota-test--raw-script body))
           (harness-codex-quota-program script))
      (unwind-protect
          (let ((result (harness-test-await (harness-codex-quota-read))))
            (should (eq 'error (plist-get result :status)))
            (should-not (string-match-p "SECRET" (format "%S" result))))
        (delete-file script)))))

(ert-deftest harness-codex-quota-protocol-timeout-terminates-server ()
  "A stuck app-server returns a sanitized timeout rather than hanging the UI."
  (let* ((script (harness-codex-quota-test--raw-script "read init; sleep 2"))
         (harness-codex-quota-program script)
         (harness-codex-quota--timeout 0.05))
    (unwind-protect
        (should (eq 'timeout (plist-get (harness-test-await (harness-codex-quota-read)) :status)))
      (delete-file script))))

(provide 'harness-codex-quota-test)
;;; harness-codex-quota-test.el ends here
