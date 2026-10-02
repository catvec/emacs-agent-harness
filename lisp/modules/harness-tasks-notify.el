;;; harness-tasks-notify.el --- Notify the user about their tasks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Task mode works while the user is elsewhere.  This module tells them
;; when a task needs them or got done, through the notifications module
;; (a desktop notification, a push to their phone):
;;
;; - review: a task's finished work waits for the user to verify it or
;;   send it back (`task/review').  The notification quotes the start of
;;   the agent's last reply, which usually says what it did.
;; - done: the harness got a task done: its branch merged, or its turn
;;   ended with nothing to merge or review (`task/done' with `merged' or
;;   `finished').  A task the user verified with nothing left to merge,
;;   or marked done, is their own doing and needs no news.
;; - needs-input (off by default): a task's column turns needs-input:
;;   its session asks a question or for a permission, or it stopped part
;;   way.  Not when the user cancelled it.
;;
;; `harness-tasks-notify-events' picks which of these notify, and
;; `harness-tasks-notify-providers' where they go.  Every notification
;; names its task, session and project, so clicking a desktop
;; notification opens the task on its board.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-tasks-notify-events '(review done)
  "Which task events notify you.
`review'       a task's work waits for you to verify it or send it back;
`done'         a task is done: its branch merged, or its turn ended with
               nothing to merge or review (not when you completed it);
`needs-input'  a task needs you: its session asks a question or for a
               permission, or it stopped part way (not when cancelled)."
  :type '(set (const :tag "Ready for review" review)
              (const :tag "Done" done)
              (const :tag "Needs your input" needs-input))
  :group 'harness)

(defcustom harness-tasks-notify-providers nil
  "Notification providers task notifications go to, by name.
nil sends them where `harness-notifications-providers' says."
  :type '(choice (const :tag "The default providers" nil) (repeat symbol))
  :group 'harness)

(defconst harness-tasks-notify-reply-chars 200
  "Characters of the agent's last reply a review notification quotes.")

(defvar harness-tasks-notify--columns (make-hash-table :test 'equal)
  "Task id -> the column it was last seen in.")

;;;; What a notification says

(defun harness-tasks-notify--session (task)
  "Return the session plist of TASK, or nil."
  (let ((sid (plist-get task :session)))
    (and sid
         (or (not (harness-method-exists-p 'session/exists-p))
             (harness-call 'session/exists-p sid))
         (ignore-errors (harness-call 'session/get sid)))))

(defun harness-tasks-notify--title (task session)
  "Return TASK's title: its SESSION's name, else its prompt's first line."
  (let ((name (plist-get session :name)))
    (harness-truncate-end
     (if (harness-string-blank-p name)
         (let ((line (harness-first-line (or (plist-get task :prompt) ""))))
           (string-trim (if (string-match "\\`#+[ \t]+" line) (substring line (match-end 0)) line)))
       (string-trim name))
     80)))

(defun harness-tasks-notify--project (task)
  "Return the name of TASK's project."
  (let ((root (plist-get task :project)))
    (cond ((not (stringp root)) "Task")
          ((harness-method-exists-p 'project/name) (harness-call 'project/name root))
          (t (file-name-nondirectory (directory-file-name root))))))

(defun harness-tasks-notify--last-reply (session-id)
  "Return the text SESSION-ID's last turn ended on, or nil.
That is its last assistant message after the last message the user
sent; steering messages within the turn do not end the search."
  (catch 'found
    (dolist (node (reverse (harness-call 'session/nodes session-id)))
      (pcase (plist-get node :kind)
        ((or 'assistant "assistant") (throw 'found (plist-get node :content)))
        ((or 'user "user") (unless (plist-get (plist-get node :meta) :steering) (throw 'found nil)))))
    nil))

(defun harness-tasks-notify--squash (text max)
  "Return TEXT on one line, its whitespace collapsed, at most MAX characters."
  (harness-truncate-end (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text)) max))

(defun harness-tasks-notify--why (task session)
  "Say why TASK, with SESSION, needs the user."
  (let ((pending (car (plist-get session :pending)))
        (outcome (plist-get task :outcome))
        (err (plist-get task :error)))
    (cond
     (pending (if (member (format "%s" (plist-get pending :kind)) '("question"))
                  "has a question for you"
                "needs your permission"))
     (outcome (concat (format "stopped: %s" outcome)
                      (if (harness-string-blank-p err) ""
                        (concat ", " (harness-tasks-notify--squash err 120)))))
     (t "needs your input"))))

;;;; Sending

(defun harness-tasks-notify--send (task kind title body)
  "Notify the user about TASK: KIND of notification, TITLE and BODY."
  (if (not (harness-method-exists-p 'notification/send))
      (harness-log 'warn "tasks-notify: the notifications module is not loaded")
    (harness-catch
     (harness-call-async 'notification/send
                         (list :title title :body body :urgency 'normal
                               :source "tasks" :kind kind
                               :task (plist-get task :id) :session (plist-get task :session)
                               :project (plist-get task :project))
                         harness-tasks-notify-providers)
     (lambda (err)
       (harness-log 'warn "tasks-notify: could not notify about task %s: %s"
                    (plist-get task :id) (harness-error-message err))
       nil))))

(defun harness-tasks-notify--on-review (task)
  "Tell the user TASK's work waits for their review."
  (when (memq 'review harness-tasks-notify-events)
    (let* ((session (harness-tasks-notify--session task))
           (reply (and session (harness-tasks-notify--last-reply (plist-get session :id)))))
      (harness-tasks-notify--send
       task "task-review"
       (format "Ready for review: %s" (harness-tasks-notify--title task session))
       (format "%s: %s" (harness-tasks-notify--project task)
               (if (harness-string-blank-p reply)
                   "waits for you to verify it or send it back"
                 (harness-tasks-notify--squash reply harness-tasks-notify-reply-chars)))))))

(defun harness-tasks-notify--on-done (task how)
  "Tell the user TASK is done, when HOW says the harness got it there.
HOW `merged' or `finished' notifies; `verified' and `completed' are the
user's own doing."
  (let ((how (if (stringp how) (intern how) how)))
    (when (and (memq 'done harness-tasks-notify-events) (memq how '(merged finished)))
      (let ((session (harness-tasks-notify--session task))
            (base (plist-get task :base)))
        (harness-tasks-notify--send
         task "task-done"
         (format "Task done: %s" (harness-tasks-notify--title task session))
         (format "%s: %s" (harness-tasks-notify--project task)
                 (cond ((not (eq how 'merged)) "finished")
                       ((harness-string-blank-p base) "merged")
                       (t (format "merged into %s" base)))))))))

(defun harness-tasks-notify--on-changed (task)
  "Follow TASK's column; tell the user when it turns needs-input.
Only a change from another column it was seen in notifies, and never
for a task the user cancelled."
  (let* ((id (plist-get task :id))
         (column (plist-get task :column))
         (column (if (stringp column) (intern column) column))
         (before (gethash id harness-tasks-notify--columns 'unseen)))
    (puthash id column harness-tasks-notify--columns)
    (when (and (memq 'needs-input harness-tasks-notify-events)
               (eq column 'needs-input)
               (not (memq before '(unseen needs-input)))
               (not (member (format "%s" (plist-get task :outcome)) '("cancelled"))))
      (let ((session (harness-tasks-notify--session task)))
        (harness-tasks-notify--send
         task "task-needs-input"
         (format "Task needs you: %s" (harness-tasks-notify--title task session))
         (format "%s: %s" (harness-tasks-notify--project task)
                 (harness-tasks-notify--why task session)))))))

(defun harness-tasks-notify--on-deleted (id)
  "Forget task ID."
  (remhash id harness-tasks-notify--columns))

;;;; Module

(defconst harness-tasks-notify--subscriptions
  '((task/review . harness-tasks-notify--on-review)
    (task/done . harness-tasks-notify--on-done)
    (task/changed . harness-tasks-notify--on-changed)
    (task/deleted . harness-tasks-notify--on-deleted))
  "The events this module follows, with their handlers.")

(defun harness-tasks-notify--init ()
  "Follow the task events (idempotent)."
  (dolist (sub harness-tasks-notify--subscriptions)
    (harness-on (car sub) (cdr sub))))

(defun harness-tasks-notify--shutdown ()
  "Stop following the task events."
  (dolist (sub harness-tasks-notify--subscriptions)
    (harness-off (cons (car sub) (cdr sub)))))

(harness-define-module 'tasks-notify
  :doc "Notifies you when a task's work waits for your review or a task is done (and, opt-in, when one needs your input)."
  :requires '(tasks notifications)
  :init #'harness-tasks-notify--init
  :shutdown #'harness-tasks-notify--shutdown)

(provide 'harness-tasks-notify)
;;; harness-tasks-notify.el ends here
