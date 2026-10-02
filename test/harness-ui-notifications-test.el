;;; harness-ui-notifications-test.el --- The UI's side of desktop notifications  -*- lexical-binding: t; -*-

;;; Commentary:

;; The UI shows the notifications the harness asks it to show
;; (`_harness/client/notify') and opens what one is about when it is
;; clicked.  The desktop itself is stubbed: nothing shows for real.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)

(defun harness-ui-notifications-test--answer (params)
  "Dispatch a `_harness/client/notify' request with PARAMS; return the answer."
  (let ((answer nil) (answered nil))
    (harness-ui--dispatch "_harness/client/notify" params
                          (lambda (r) (setq answer r answered t)))
    (harness-test-wait (lambda () answered) 2 "the answer")
    answer))

(ert-deftest harness-ui-notifications-request-shows-it ()
  (let ((shown nil))
    (cl-letf (((symbol-function 'harness-notifications-desktop-notify)
               (lambda (&rest params) (push params shown) (harness-resolved '(:backend notify-send :id 5)))))
      (should (equal '(:backend "notify-send")
                     (harness-ui-notifications-test--answer
                      '(:id "n-1" :title "Ready for review: x" :body "B" :urgency "critical"
                        :session "s1" :task "t1" :project "/p/"))))
      (let ((params (car shown)))
        (should (equal '("Ready for review: x" "B" "critical")
                       (list (plist-get params :title) (plist-get params :body) (plist-get params :urgency))))
        ;; About a session and a task: a click opens it.
        (should (functionp (plist-get params :on-action))))
      ;; About nothing to open: not clickable.
      (harness-ui-notifications-test--answer '(:title "Test notification"))
      (should-not (plist-get (car shown) :on-action)))))

(ert-deftest harness-ui-notifications-request-failure-is-an-error-answer ()
  (cl-letf (((symbol-function 'harness-notifications-desktop-notify)
             (lambda (&rest _) (harness-rejected '(error "No way to show desktop notifications here")))))
    (let ((answer (harness-ui-notifications-test--answer '(:title "T"))))
      (should (harness-acp-error-value-p answer))
      (should (equal "No way to show desktop notifications here" (harness-acp-error-value-message answer))))))

(ert-deftest harness-ui-notifications-click-waits-for-the-command-loop ()
  "The click comes from a process filter or a D-Bus handler; the UI acts after."
  (let ((clicked nil))
    (cl-letf (((symbol-function 'harness-notifications-desktop-notify)
               (lambda (&rest params)
                 (funcall (plist-get params :on-action))
                 (harness-resolved '(:backend notify-send))))
              ((symbol-function 'harness-ui--notification-clicked) (lambda (params) (setq clicked params))))
      (harness-ui--show-notification '(:title "T" :task "t1" :project "/p/"))
      (should-not clicked)
      (harness-test-wait (lambda () clicked) 2 "the click")
      (should (equal "t1" (plist-get clicked :task))))))

(ert-deftest harness-ui-notifications-click-opens-what-it-is-about ()
  (let ((opened nil) (handled nil)
        (harness-ui-notification-functions nil))
    (cl-letf (((symbol-function 'harness-ui-display-session) (lambda (sid &rest _) (push sid opened))))
      ;; By default, its session.
      (harness-ui--notification-clicked '(:session "s1"))
      (should (equal '("s1") opened))
      ;; A UI module that knows better takes it.
      (add-hook 'harness-ui-notification-functions
                (lambda (n) (push n handled) (plist-get n :task)))
      (harness-ui--notification-clicked '(:session "s2" :task "t2"))
      (should (equal '("s1") opened))
      (harness-ui--notification-clicked '(:session "s3"))
      (should (equal '("s3" "s1") opened))
      (should (= 2 (length handled)))
      ;; Nothing to open: nothing opens.
      (harness-ui--notification-clicked '(:title "T"))
      (should (= 2 (length opened))))))

(ert-deftest harness-ui-notifications-summary ()
  (should (equal "system sent (notify-send, in the UI); gotify skipped (not set up); mail failed (refused)"
                 (harness-ui--notification-summary
                  '(:id "n-1" :results ((:provider "system" :status "sent" :detail "notify-send, in the UI")
                                        (:provider "gotify" :status "skipped" :error "not set up")
                                        (:provider "mail" :status "failed" :error "refused"))))))
  (should (equal "no notification provider is enabled"
                 (harness-ui--notification-summary '(:id "n-1" :results nil))))
  (should (string-match-p "dropped" (harness-ui--notification-summary '(:id "n-1" :dropped t)))))

(ert-deftest harness-ui-notifications-test-command ()
  (let ((asked nil) (shown nil))
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (method params callback &rest _)
                 (setq asked (list method params))
                 (funcall callback '(:id "n-1" :results ((:provider "system" :status "sent" :detail "dbus"))))))
              ((symbol-function 'message) (lambda (fmt &rest args) (setq shown (apply #'format fmt args)))))
      (harness-test-notifications)
      (should (equal "_harness/notification/send" (car asked)))
      (should (equal "Test notification" (plist-get (plist-get (cadr asked) :notification) :title)))
      (should (equal "Harness notifications: system sent (dbus)" shown)))))

(provide 'harness-ui-notifications-test)
;;; harness-ui-notifications-test.el ends here
