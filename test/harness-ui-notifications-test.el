;;; harness-ui-notifications-test.el --- The UI's side of desktop notifications  -*- lexical-binding: t; -*-

;;; Commentary:

;; The UI shows the notifications the harness asks it to show
;; (`_harness/client/notify') and opens what one is about when it is
;; clicked.  The desktop itself is stubbed: nothing shows for real.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)
(require 'harness-ui-tasks)

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
    (cl-letf (((symbol-function 'harness-ui-visit-session) (lambda (sid &rest _) (push sid opened))))
      ;; By default, its session, in its project.
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

(ert-deftest harness-ui-notifications-forgotten-click-lists-the-waiting ()
  "A click on a notification this Emacs no longer knows lists the sessions waiting for you.
macOS keeps notifications past a restart of the Emacs that showed them."
  (let ((waiting 0) (listed 0)
        (harness-notifications-desktop--actions nil)
        (harness-notifications-desktop-unknown-click-function #'harness-ui--unknown-notification-clicked))
    (cl-letf (((symbol-function 'harness-ui-notify-show-waiting) (lambda () (cl-incf waiting)))
              ((symbol-function 'harness-sessions) (lambda () (interactive) (cl-incf listed))))
      (harness-notifications-desktop-clicked "n-from-before-a-restart")
      (harness-test-wait (lambda () (= waiting 1)) 2 "the waiting sessions")
      ;; Without the mode line's notifier, the session list.
      (cl-letf (((symbol-function 'harness-ui-notify-show-waiting) nil))
        (harness-ui--unknown-notification-clicked))
      (should (= 1 listed))
      (should (= 1 waiting)))))

(ert-deftest harness-ui-notifications-click-through-emacsclient ()
  "A click a terminal-notifier notification hears through emacsclient opens what it is about."
  (let ((clicked nil)
        (harness-notifications-desktop--actions nil))
    (cl-letf (((symbol-function 'harness-notifications-desktop-notify)
               (lambda (&rest params)
                 ;; As the terminal-notifier backend keeps it.
                 (harness-notifications-desktop--remember-action "n1" (plist-get params :on-action))
                 (harness-resolved '(:backend terminal-notifier))))
              ((symbol-function 'harness-ui--notification-clicked) (lambda (params) (setq clicked params))))
      (harness-ui--show-notification '(:title "Needs you: x" :session "s1" :project "/p/"))
      ;; What emacsclient evaluates when the notification is clicked.
      (should-not (harness-notifications-desktop-clicked "n1"))
      (harness-test-wait (lambda () clicked) 2 "the click")
      (should (equal "s1" (plist-get clicked :session))))))

(ert-deftest harness-ui-notifications-click-switches-to-the-tasks-project ()
  "A click on a task's notification switches to its project before the board opens.
The task's project may be a worktree, which belongs to its repository's
main checkout (`harness-files-owning-checkout')."
  (let* ((events nil) (roots nil)
         (here (file-name-as-directory (expand-file-name default-directory)))
         (harness-ui-switch-project-function (lambda (root) (push root roots) 'switched)))
    (cl-letf (((symbol-function 'harness-files-owning-checkout)
               (lambda (root) (push (list 'checkout root) events) here))
              ((symbol-function 'harness-ui-session) (lambda (_id) nil))
              ((symbol-function 'harness-tasks)
               (lambda (&rest args) (push (cons 'board args) events) (generate-new-buffer " *task board*"))))
      (unwind-protect
          (progn
            (should (harness-ui-tasks--on-notification '(:task "t1" :project "/task-worktree/")))
            ;; The switch comes first, then the board for the task's project.
            (should (equal '((board "/task-worktree/") (checkout "/task-worktree/"))
                           events))
            (should (equal (list here) roots)))
        (dolist (b (buffer-list))
          (when (string-prefix-p " *task board*" (buffer-name b)) (kill-buffer b)))))))

(ert-deftest harness-ui-notifications-click-switches-to-the-sessions-project ()
  "The session a notification names, when the harness has it, says the project.
Its project is used rather than the notification's, which may be a task's
worktree of another directory.  This is the board a task opens on when no
chat module can show its session."
  (let* ((events nil) (roots nil)
         (here (file-name-as-directory (expand-file-name default-directory)))
         (harness-ui-open-session-function nil)
         (harness-ui-switch-project-function (lambda (root) (push root roots))))
    (cl-letf (((symbol-function 'harness-files-owning-checkout)
               (lambda (root) (push (list 'checkout root) events) here))
              ((symbol-function 'harness-ui-session)
               (lambda (_id) (list :id "s1" :project "/session-project/")))
              ((symbol-function 'harness-tasks)
               (lambda (&rest args) (push (cons 'board args) events) (generate-new-buffer " *task board*"))))
      (unwind-protect
          (progn
            (should (harness-ui-tasks--on-notification
                     '(:task "t1" :project "/task-worktree/" :session "s1")))
            (should (equal '((board "/task-worktree/") (checkout "/session-project/"))
                           events))
            (should (equal (list here) roots)))
        (dolist (b (buffer-list))
          (when (string-prefix-p " *task board*" (buffer-name b)) (kill-buffer b)))))))

(ert-deftest harness-ui-notifications-click-opens-the-board-without-switching ()
  "With project switching off the board still opens, and no project is looked up."
  (let* ((events nil)
         (harness-ui-switch-project-function nil))
    (cl-letf (((symbol-function 'harness-files-owning-checkout)
               (lambda (root) (push (list 'checkout root) events) root))
              ((symbol-function 'harness-tasks)
               (lambda (&rest args) (push (cons 'board args) events) (generate-new-buffer " *task board*"))))
      (unwind-protect
          (progn
            (should (harness-ui-tasks--on-notification '(:task "t1" :project "/task-worktree/")))
            (should (equal '((board "/task-worktree/")) events)))
        (dolist (b (buffer-list))
          (when (string-prefix-p " *task board*" (buffer-name b)) (kill-buffer b)))))))

(ert-deftest harness-ui-notifications-click-opens-the-board-when-switching-fails ()
  "A project that cannot be resolved or switched to does not keep the board from opening."
  (let* ((events nil)
         (harness-ui-switch-project-function (lambda (_root) (error "No workspace for it"))))
    (cl-letf (((symbol-function 'harness-files-owning-checkout)
               (lambda (&rest _) (error "No checkout")))
              ((symbol-function 'harness-ui-session) (lambda (_id) nil))
              ((symbol-function 'harness-tasks)
               (lambda (&rest args) (push (cons 'board args) events) (generate-new-buffer " *task board*"))))
      (unwind-protect
          (progn
            (should (harness-ui-tasks--on-notification '(:task "t1" :project "/task-worktree/")))
            (should (equal '((board "/task-worktree/")) events)))
        (dolist (b (buffer-list))
          (when (string-prefix-p " *task board*" (buffer-name b)) (kill-buffer b)))))))

(ert-deftest harness-ui-notifications-click-opens-the-tasks-session ()
  "A click on a task's notification opens its session's chat, not the board.
A task is looked at and handled in its session, which shows in the task's
project (visiting a session switches to it first); the board is for a task
with no session to show.  The click goes through the whole chain, the
task module taking the notification before the default does, so the
session opens once."
  (let ((visited nil) (boards nil)
        (harness-ui-open-session-function (lambda (_id) (current-buffer))))
    (cl-letf (((symbol-function 'harness-ui-session)
               (lambda (id) (list :id id :project "/session-project/")))
              ((symbol-function 'harness-ui-visit-session)
               (lambda (sid &rest _) (push sid visited)))
              ((symbol-function 'harness-tasks)
               (lambda (&rest args) (push args boards) nil)))
      (should (harness-ui-tasks--on-notification
               '(:task "t1" :project "/task-worktree/" :session "s1")))
      (should (equal '("s1") visited))
      (should-not boards)
      ;; As the click arrives, with the module's hook installed.
      (setq visited nil)
      (harness-ui--notification-clicked
       '(:title "Ready for review: x" :task "t1" :project "/task-worktree/" :session "s1"))
      (should (equal '("s1") visited))
      (should-not boards))))

(ert-deftest harness-ui-notifications-click-opens-the-board-without-a-session-to-show ()
  "A task's notification opens the board when its session cannot be shown.
That is a task with no session in the notification, one whose session the
harness no longer has, and any task when no chat module is loaded to show
a session; a notification about a session alone is left to the default,
which opens the session."
  (let ((visited nil) (boards nil))
    (cl-letf (((symbol-function 'harness-ui-visit-session)
               (lambda (sid &rest _) (push sid visited)))
              ((symbol-function 'harness-ui-tasks-visit-task)
               (lambda (id project &optional session) (push (list id project session) boards))))
      ;; No session in the notification.
      (let ((harness-ui-open-session-function (lambda (_id) (current-buffer))))
        (cl-letf (((symbol-function 'harness-ui-session) (lambda (id) (list :id id))))
          (should (harness-ui-tasks--on-notification '(:task "t1" :project "/p/")))
          ;; A session the harness no longer has.
          (cl-letf (((symbol-function 'harness-ui-session) (lambda (_id) nil)))
            (should (harness-ui-tasks--on-notification '(:task "t2" :project "/p/" :session "gone"))))
          ;; An empty one.
          (should (harness-ui-tasks--on-notification '(:task "t3" :project "/p/" :session "")))))
      ;; No chat module to show it.
      (let ((harness-ui-open-session-function nil))
        (cl-letf (((symbol-function 'harness-ui-session) (lambda (id) (list :id id))))
          (should (harness-ui-tasks--on-notification '(:task "t4" :project "/p/" :session "s4")))))
      (should-not visited)
      (should (equal '(("t4" "/p/" "s4") ("t3" "/p/" "") ("t2" "/p/" "gone") ("t1" "/p/" nil))
                     boards))
      ;; About a session and nothing else: not the task module's to take.
      (let ((harness-ui-open-session-function (lambda (_id) (current-buffer))))
        (cl-letf (((symbol-function 'harness-ui-session) (lambda (id) (list :id id))))
          (should-not (harness-ui-tasks--on-notification '(:session "s5")))))
      (should (= 4 (length boards))))))

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
