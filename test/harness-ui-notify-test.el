;;; harness-ui-notify-test.el --- The mode line's session notifier  -*- lexical-binding: t; -*-

;;; Commentary:

;; The notifier is in every mode line, so it holds what is worth a
;; glance from any buffer: the sessions that wait for you and the ones
;; at work.  The session cache is stubbed: no harness runs.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui-notify)

(defun harness-ui-notify-test--shown (sessions)
  "Return the notifier's text, without properties, for SESSIONS."
  (cl-letf (((symbol-function 'harness-ui-sessions) (lambda (&optional _) sessions))
            ((symbol-function 'harness-ui-notify--flash) #'ignore)
            ((symbol-function 'force-mode-line-update) #'ignore))
    (let ((harness-ui-notify--last-blocked 0))
      (harness-ui-notify-refresh)
      (substring-no-properties harness-ui-notify--string))))

(ert-deftest harness-ui-notify-counts-what-needs-a-look ()
  "The notifier counts the sessions that wait for you and the ones at work.
An idle session needs nothing: idle ones count only with
`harness-ui-notify-show-idle', and while every session is idle the
notifier is gone."
  (let ((harness-ui-notify--string "")
        (idle '((:id "a" :status "idle") (:id "b" :status "idle")))
        (icon (lambda (name n) (concat (substring-no-properties (harness-ui-icon name))
                                       (number-to-string n)))))
    (should-not (default-value 'harness-ui-notify-show-idle))
    (should (equal "" (harness-ui-notify-test--shown idle)))
    (let ((harness-ui-notify-show-idle t))
      (should (string-search (funcall icon 'harness-icon-idle 2) (harness-ui-notify-test--shown idle))))
    (let ((text (harness-ui-notify-test--shown
                 (append idle '((:id "c" :status "running") (:id "d" :status "blocked")
                                (:id "e" :status "blocked"))))))
      (should (string-prefix-p " harness" text))
      (should (string-search (funcall icon 'harness-icon-blocked 2) text))
      (should (string-search (funcall icon 'harness-icon-running 1) text))
      (should-not (string-search (funcall icon 'harness-icon-idle 2) text)))))

(provide 'harness-ui-notify-test)

;;; harness-ui-notify-test.el ends here
