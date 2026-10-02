;;; harness-tasks-notify-test.el --- Tests for task notifications  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tasks run on the demo provider with the real state layer; their
;; notifications go to a fake provider that keeps them.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo-delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-model)
(defvar harness-acp-server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-notifications-providers)
(defvar harness-notifications--providers)
(defvar harness-tasks-notify-events)
(defvar harness-tasks-notify-providers)
(defvar harness-tasks-notify--columns)
(declare-function harness-tasks--forget-stores "harness-tasks")
(declare-function harness-acp--drop-client "harness-acp")
(declare-function harness-notifications-define-provider "harness-notifications")

(defmacro harness-tasks-notify-test-with (&rest body)
  "Run BODY with tasks on the demo provider and task notifications on.
`got' lists the notifications the provider `capture' received, oldest
first.  Finished tasks are done at once unless BODY turns
`harness-tasks-require-verification' on."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks acp
                          notifications tasks-notify))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-tasks-notify--columns)
     (harness-tasks--forget-stores)
     (setq harness-tasks--loaded t
           harness-tasks--dirty nil
           harness-acp--clients nil)
     (let* ((harness-provider-demo-delay 0.005)
            (harness-provider-demo-script-override
             '((:type text :delta "Fixed the parser:\n\n- the   tests pass") (:type done :stop-reason end-turn)))
            (harness-naming-auto nil)
            (harness-tasks-max-running 3)
            (harness-tasks-require-verification nil)
            (harness-tasks-permission-mode 'auto)
            (harness-tasks-non-interactive t)
            (harness-tasks-model "demo:scripted")
            (harness-acp-token nil)
            (harness-tasks-notify-events '(review done))
            (harness-tasks-notify-providers nil)
            (harness-notifications--providers
             (mapcar (lambda (cell) (cons (car cell) (cdr cell))) harness-notifications--providers))
            (harness-notifications-providers '(capture))
            (received nil)
            (default-directory dir)
            (project (file-name-nondirectory (directory-file-name dir))))
       (ignore project)
       (harness-notifications-define-provider 'capture :send (lambda (n) (push n received) nil))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (cl-flet ((got () (reverse received))
                 (forget () (setq received nil)))
         (unwind-protect (progn ,@body)
           (dolist (c (copy-sequence harness-acp--clients))
             (harness-acp--drop-client c)))))))

(defun harness-tasks-notify-test--submit (prompt)
  "Submit a task with PROMPT; return its id."
  (plist-get (harness-call 'task/submit default-directory prompt) :id))

(defun harness-tasks-notify-test--wait-state (id state)
  "Wait until task ID is in STATE."
  (harness-test-wait (lambda () (eq state (plist-get (harness-call 'task/get id) :state))) 5
                     (format "task %s to become %s" id state)))

(defun harness-tasks-notify-test--settle ()
  "Let the notifications sent asynchronously arrive."
  (harness-test-wait (lambda () t) 1)
  (dotimes (_ 5) (accept-process-output nil 0.01)))

(ert-deftest harness-tasks-notify-review ()
  (harness-tasks-notify-test-with
    (let ((harness-tasks-require-verification t))
      (let* ((id (harness-tasks-notify-test--submit "# Fix the parser\nIt breaks on tabs."))
             (sid (plist-get (harness-call 'task/get id) :session)))
        (harness-tasks-notify-test--wait-state id 'review)
        (harness-test-wait (lambda () (got)) 5 "the notification")
        (should (= 1 (length (got))))
        (let ((n (car (got))))
          ;; The session has no name: the prompt's first line, without its #.
          (should (equal "Ready for review: Fix the parser" (plist-get n :title)))
          ;; The start of the agent's last reply, on one line.
          (should (equal (concat project ": Fixed the parser: - the tests pass") (plist-get n :body)))
          (should (equal '("tasks" "task-review" normal) (list (plist-get n :source) (plist-get n :kind)
                                                              (plist-get n :urgency))))
          (should (equal (list id sid (plist-get (harness-call 'task/get id) :project))
                         (list (plist-get n :task) (plist-get n :session) (plist-get n :project)))))
        ;; Verifying it is the user's doing: no news of its completion.
        (forget)
        (harness-call 'task/verify id)
        (harness-tasks-notify-test--wait-state id 'done)
        (harness-tasks-notify-test--settle)
        (should (null (got)))))))

(ert-deftest harness-tasks-notify-review-names-the-session ()
  (harness-tasks-notify-test-with
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override '((:type done :stop-reason end-turn))))
      (let* ((id (harness-tasks-notify-test--submit "fix the parser"))
             (sid (plist-get (harness-call 'task/get id) :session)))
        (harness-call 'session/update sid :name "Parser handles tabs")
        (harness-tasks-notify-test--wait-state id 'review)
        (harness-test-wait (lambda () (got)) 5 "the notification")
        (should (equal "Ready for review: Parser handles tabs" (plist-get (car (got)) :title)))
        ;; No reply to quote.
        (should (equal (concat project ": waits for you to verify it or send it back")
                       (plist-get (car (got)) :body)))))))

(ert-deftest harness-tasks-notify-done ()
  (harness-tasks-notify-test-with
    (let ((id (harness-tasks-notify-test--submit "fix the parser")))
      (harness-tasks-notify-test--wait-state id 'done)
      (harness-test-wait (lambda () (got)) 5 "the notification")
      (should (= 1 (length (got))))
      (let ((n (car (got))))
        (should (equal "Task done: fix the parser" (plist-get n :title)))
        (should (equal (concat project ": finished") (plist-get n :body)))
        (should (equal "task-done" (plist-get n :kind)))
        (should (equal id (plist-get n :task)))))
    ;; Marked done by hand: the user knows.
    (forget)
    (let ((harness-tasks-max-running 0))
      (harness-call 'task/complete (harness-tasks-notify-test--submit "later"))
      (harness-tasks-notify-test--settle)
      (should (null (got))))))

(ert-deftest harness-tasks-notify-done-text-when-merged ()
  "The body of a merged task's notification names the branch it merged into."
  (harness-tasks-notify-test-with
    (let ((got-texts nil))
      (cl-letf (((symbol-function 'harness-tasks-notify--send)
                 (lambda (_task kind title body) (push (list kind title body) got-texts))))
        (harness-tasks-notify--on-done (list :id "t-1" :prompt "Add CSV export" :project dir :base "main") 'merged)
        (harness-tasks-notify--on-done (list :id "t-2" :prompt "Add CSV export" :project dir) "merged")
        (harness-tasks-notify--on-done (list :id "t-3" :prompt "Add CSV export" :project dir) 'verified)
        (harness-tasks-notify--on-done (list :id "t-4" :prompt "Add CSV export" :project dir) 'completed))
      (should (equal (list (list "task-done" "Task done: Add CSV export" (concat project ": merged"))
                           (list "task-done" "Task done: Add CSV export" (concat project ": merged into main")))
                     got-texts)))))

(ert-deftest harness-tasks-notify-needs-input-is-opt-in ()
  (harness-tasks-notify-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "the model is overloaded"))))
      ;; Off by default.
      (let ((id (harness-tasks-notify-test--submit "will fail")))
        (harness-test-wait (lambda () (eq 'needs-input (plist-get (harness-call 'task/get id) :column))) 5 "needs-input")
        (harness-tasks-notify-test--settle)
        (should (null (got))))
      ;; On: once, saying why.
      (let ((harness-tasks-notify-events '(review done needs-input)))
        (let ((id (harness-tasks-notify-test--submit "will fail too")))
          (harness-test-wait (lambda () (got)) 5 "the notification")
          (harness-tasks-notify-test--settle)
          (should (= 1 (length (got))))
          (let ((n (car (got))))
            (should (equal "Task needs you: will fail too" (plist-get n :title)))
            (should (equal (concat project ": stopped: error") (plist-get n :body)))
            (should (equal "task-needs-input" (plist-get n :kind)))
            (should (equal id (plist-get n :task)))))))))

(ert-deftest harness-tasks-notify-needs-input-reasons ()
  (harness-tasks-notify-test-with
    (let ((harness-tasks-notify-events '(needs-input))
          (sent nil))
      (cl-letf (((symbol-function 'harness-tasks-notify--send)
                 (lambda (_task _kind title body) (push (cons title body) sent)))
                ((symbol-function 'harness-tasks-notify--session)
                 (lambda (task) (plist-get task :fake-session))))
        (cl-flet ((change (id column &rest props)
                    (harness-tasks-notify--on-changed (append (list :id id :column column :prompt "a task" :project dir)
                                                              props))))
          ;; First seen needing input (after a restart, say): no news.
          (change "t-1" 'needs-input :outcome 'error)
          (should (null sent))
          (change "t-2" 'active)
          (change "t-2" 'needs-input :fake-session '(:pending ((:id "p1" :kind question))))
          (change "t-2" 'needs-input :fake-session '(:pending ((:id "p1" :kind question))))
          (change "t-3" 'active)
          (change "t-3" 'needs-input :fake-session '(:pending ((:id "p1" :kind permission))))
          (change "t-4" "active")
          (change "t-4" "needs-input" :outcome "merge-failed" :error "merge failed:\n  conflict in x.el")
          ;; The user stopped it: they know.
          (change "t-5" 'active)
          (change "t-5" 'needs-input :outcome 'cancelled)
          (should (equal (list (cons "Task needs you: a task" (concat project ": has a question for you"))
                               (cons "Task needs you: a task" (concat project ": needs your permission"))
                               (cons "Task needs you: a task"
                                     (concat project ": stopped: merge-failed, merge failed: conflict in x.el")))
                         (reverse sent)))
          ;; A deleted task is forgotten.
          (harness-tasks-notify--on-deleted "t-2")
          (should-not (gethash "t-2" harness-tasks-notify--columns)))))))

(ert-deftest harness-tasks-notify-events-and-providers ()
  (harness-tasks-notify-test-with
    (let ((other nil))
      (harness-notifications-define-provider 'other :send (lambda (n) (push n other) nil))
      ;; Nothing chosen: nothing sent.
      (let ((harness-tasks-notify-events nil))
        (harness-tasks-notify-test--wait-state (harness-tasks-notify-test--submit "quiet") 'done)
        (harness-tasks-notify-test--settle)
        (should (null (got))))
      ;; Its own providers.
      (let ((harness-tasks-notify-providers '(other)))
        (harness-tasks-notify-test--wait-state (harness-tasks-notify-test--submit "elsewhere") 'done)
        (harness-test-wait (lambda () other) 5 "the notification")
        (should (null (got)))
        (should (equal "Task done: elsewhere" (plist-get (car other) :title)))))))

(ert-deftest harness-tasks-notify-module-follows-and-stops ()
  (harness-tasks-notify-test-with
    (harness-tasks-notify--shutdown)
    (harness-tasks-notify-test--wait-state (harness-tasks-notify-test--submit "unwatched") 'done)
    (harness-tasks-notify-test--settle)
    (should (null (got)))
    ;; Starting again twice subscribes once.
    (harness-tasks-notify--init)
    (harness-tasks-notify--init)
    (harness-tasks-notify-test--wait-state (harness-tasks-notify-test--submit "watched") 'done)
    (harness-test-wait (lambda () (got)) 5 "the notification")
    (harness-tasks-notify-test--settle)
    (should (= 1 (length (got))))))

(provide 'harness-tasks-notify-test)
;;; harness-tasks-notify-test.el ends here
