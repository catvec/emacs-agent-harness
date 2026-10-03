;;; harness-ui-review.el --- The review banner of a task's session  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session that is a task waiting for review shows a banner above its
;; compose box: that the work is done and waits for the user, with the
;; buttons that act on it -- [Verify], which accepts the work and merges
;; its branch, [Send back], and [Report], which shows the final message
;; and evidence the session handed in (`hand_in').  It is the board's
;; Ready for review, in the session itself: the same face and the same
;; wording, so accepting work is one action wherever the user is.
;;
;; While the banner shows, the compose box writes the feedback that sends
;; the task back: C-c C-c takes what the box holds to the task's session,
;; which works on it again and comes back for review (`harness-chat-send-function').
;; The banner disappears when the task leaves review, whoever moved it.
;;
;; The banner is a panel of the chat buffer (`harness-chat-panel-functions'),
;; so it shows in the session's own window, in a BTW over it, and in a
;; task's session opened from the board -- the width is the window's.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-tasks)

(defvar harness-chat-panel-functions)
(defvar harness-chat-send-function)
(defvar harness-chat-placeholder)
(defvar harness-chat-mode-map)
(defvar harness-ui-session-id)
(defvar harness-compose-redraw-function)
(declare-function harness-ui-report-popout "harness-ui-report" (task))

(defgroup harness-ui-review nil
  "Reviewing a task's work in its own session." :group 'harness-ui)

(defface harness-chat-review-face
  '((((background light)) :background "#e6f4e6" :extend t)
    (((background dark)) :background "#1f3a22" :extend t))
  "Background of the review banner: the board's Ready for review, in the session."
  :group 'harness-ui-review)

(defvar harness-ui-review--tasks (make-hash-table :test 'equal)
  "Session id -> the task record of that session, as last heard.")

(defvar harness-ui-review--asked (make-hash-table :test 'equal)
  "Session ids whose task was looked up once.")

(defun harness-ui-review--chat-buffer (sid)
  "Return the live chat buffer showing session SID, or nil."
  (cl-find-if (lambda (buffer)
                (eq (buffer-local-value 'harness-ui-session-id buffer) sid))
              (buffer-list)))

(defun harness-ui-review--redraw (sid)
  "Draw the tail of SID's chat buffer again, when it shows."
  (when-let* ((buffer (harness-ui-review--chat-buffer sid)))
    (with-current-buffer buffer
      (when (functionp harness-compose-redraw-function)
        (funcall harness-compose-redraw-function)))))

(defun harness-ui-review--fetch (sid)
  "Look up whether SID is a task's, and show its banner when it is.
Uses `task/for-session'; a session that is no task's is remembered as
such, so the lookup happens once per session."
  (harness-ui-call
   "_harness/task/for-session" (list :session-id sid)
   (lambda (task)
     (if (and task (plist-get task :id))
         (puthash sid task harness-ui-review--tasks)
       (remhash sid harness-ui-review--tasks))
     (harness-ui-review--redraw sid))
   #'ignore))

(defun harness-ui-review--task (sid)
  "Return SID's task record when it is a task's, else nil."
  (when (and (stringp sid) (not (string-empty-p sid)))
    (unless (gethash sid harness-ui-review--asked)
      (puthash sid t harness-ui-review--asked)
      (harness-ui-review--fetch sid))
    (gethash sid harness-ui-review--tasks)))

(defun harness-ui-review--reviewing-p (task)
  "Non-nil when TASK waits for the user's review, not archived."
  (and task
       (equal (plist-get task :state) "review")
       (not (harness-json-true-p (plist-get task :archived)))))

;;;; The banner

(defun harness-ui-review--button (label command help)
  "Return a button string LABEL running COMMAND with HELP."
  (propertize (buttonize label (lambda (_) (funcall command)) nil help)
              "mouse-face" 'highlight))

(defun harness-ui-review-verify ()
  "Accept this task's work: verify it, which merges its branch."
  (interactive)
  (let* ((sid harness-ui-session-id)
         (task (gethash sid harness-ui-review--tasks)))
    (unless (harness-ui-review--reviewing-p task)
      (user-error "This session is not waiting for your review"))
    (harness-ui-call "_harness/task/verify" (list :id (plist-get task :id)) #'ignore
                     (lambda (e) (message "Could not verify: %s" (harness-error-message e))))
    (message "Verified")))

(defun harness-ui-review-reject ()
  "Send this task's work back: type what to change in the box, C-c C-c sends it."
  (interactive)
  (let* ((sid harness-ui-session-id)
         (task (gethash sid harness-ui-review--tasks)))
    (unless (harness-ui-review--reviewing-p task)
      (user-error "This session is not waiting for your review"))
    (setq-local harness-chat-placeholder "What should change? C-c C-c sends it back")
    (with-no-warnings (when (fboundp 'harness-compose-update-placeholder)
                        (harness-compose-update-placeholder)))
    (when-let* ((window (get-buffer-window (current-buffer))))
      (set-window-point window (or harness-compose-end (point-max))))
    (message "Write what should change in the box; C-c C-c sends it back")))

(defun harness-ui-review--send (text attachments)
  "Send TEXT and ATTACHMENTS back to the task in review.
Runs from `harness-chat-send-function' while the banner shows."
  (let* ((sid harness-ui-session-id)
         (task (gethash sid harness-ui-review--tasks)))
    (unless (harness-ui-review--reviewing-p task)
      (user-error "This session is not waiting for your review"))
    (if (and (harness-string-blank-p text) (null attachments))
        (user-error "Sending the work back needs feedback: type what should change")
      (harness-ui-call "_harness/task/reject"
                       (list :id (plist-get task :id) :feedback text :attachments attachments)
                       (lambda (_) (message "Sent back: the session works on your feedback"))
                       (lambda (e) (message "Could not send it back: %s" (harness-error-message e)))))))

(defun harness-ui-review--banner (task)
  "Return the banner string for TASK, waiting for review.
It reads as the board's Ready for review card: the mark, the heading,
what verifying does, and the buttons, with the keys beside them."
  (let* ((title (harness-ui-tasks--title task))
         (merges (and (plist-get task :worktree) (not (harness-json-true-p (plist-get task :merged)))))
         (verify-help (if merges "Accept the work; its branch merges and the task is done"
                        "Accept the work; the task is done")))
    (concat
     " " (propertize (concat (harness-ui-icon 'harness-icon-task-review) " Ready for review")
                    'face 'harness-task-review-face)
     (propertize "   this session is a task waiting for you" 'face 'harness-dim-face)
     "\n"
     "   " (propertize title 'face 'bold)
     (propertize (if merges " is done; verify it to merge its branch, or send it back with what to change."
                   " is done; verify it, or send it back with what to change.")
                 'face 'harness-dim-face 'wrap-prefix "   ")
     "\n   "
     (harness-ui-review--button "[Verify]" #'harness-ui-review-verify verify-help)
     "  " (propertize "C-c C-v" 'face 'harness-chat-key-face)
     "   "
     (harness-ui-review--button "[Send back]" #'harness-ui-review-reject
                                "Type the feedback in the box below, then C-c C-c")
     "  " (propertize "C-c C-R" 'face 'harness-chat-key-face)
     (when (and (plist-get task :report) (fboundp 'harness-ui-report-popout))
       (concat "   " (harness-ui-review--button "[Report]" (lambda () (harness-ui-report-popout task))
                                                "The final message and evidence it handed in")))
     "\n"
     "   " (propertize "C-c C-c in the box sends what you write back to this task."
                    'face 'harness-hint-face)
     "\n ")))

(defun harness-ui-review--panel ()
  "Return the review banner when this session's task waits for review.
On `harness-chat-panel-functions': nil for a session that is no task's,
one that is not in review, or before the task is known.  While it
shows, the compose box takes feedback (`harness-chat-send-function')."
  (let* ((sid harness-ui-session-id)
         (task (harness-ui-review--task sid))
         (review (harness-ui-review--reviewing-p task)))
    (if review
        (progn
          (setq-local harness-chat-send-function #'harness-ui-review--send)
          ;; The review background, as the board's Ready for review has it:
          ;; the chat panel's own background stays out of it.
          (let ((banner (harness-ui-review--banner task)))
            (if (fboundp 'harness-chat--face)
                (harness-chat--face banner 'harness-chat-review-face)
              banner)))
      ;; Not in review: the box is the session's own again.
      (when (eq harness-chat-send-function #'harness-ui-review--send)
        (setq-local harness-chat-send-function nil))
      nil)))

;;;; Keys and events

(defun harness-ui-review--keys ()
  "Bind the banner's keys in the chat buffer, over the chat's own."
  (define-key harness-chat-mode-map (kbd "C-c C-v") #'harness-ui-review-verify)
  (define-key harness-chat-mode-map (kbd "C-c C-R") #'harness-ui-review-reject))

(defun harness-ui-review--on-event (event args)
  "Follow tasks: the banner of an open session follows its task, and a
session that becomes a task's, or stops being one, is looked up again."
  (pcase event
    ((or "task/changed" "task/review" "task/done")
     (let ((task (car args)))
       (when-let* ((sid (plist-get task :session)))
         (puthash sid task harness-ui-review--tasks)
         (harness-ui-review--redraw sid))))
    ("task/deleted"
     (let ((id (car args)))
       (maphash (lambda (sid task)
                  (when (equal (plist-get task :id) id)
                    (remhash sid harness-ui-review--tasks)
                    (harness-ui-review--redraw sid)))
                (copy-hash-table harness-ui-review--tasks))))))

(defun harness-ui-review--setup ()
  "Put the review banner in this chat buffer, before its panels."
  (add-hook 'harness-chat-panel-functions #'harness-ui-review--panel t))

(defun harness-ui-review--init ()
  "Add the banner to every chat buffer and follow task events."
  (with-eval-after-load 'harness-ui-chat
    (harness-ui-review--keys)
    (add-hook 'harness-chat-mode-hook #'harness-ui-review--setup))
  (add-hook 'harness-ui-event-functions #'harness-ui-review--on-event))

(harness-define-module 'ui-review
  :doc "The review banner of a task's session: verify it or send it back."
  :requires '(ui ui-tasks ui-report)
  :init #'harness-ui-review--init)

(provide 'harness-ui-review)
;;; harness-ui-review.el ends here
