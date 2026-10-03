;;; harness-ui-review.el --- Reviewing a task: the banner of its session and of its report  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task waiting for review shows a banner wherever its work is looked
;; at: that the work is done and waits for the user, with the buttons
;; that act on it -- [Verify], which accepts the work and merges its
;; branch, and [Send back].  It is the board's Ready for review: the
;; same mark and the same wording, so accepting work is one action
;; wherever the user is.  One banner, one set of commands and keys, in
;; two places:
;;
;;   the session  above its compose box, a chat panel
;;                (`harness-chat-panel-functions'), with [Report] too,
;;                which shows the final message and evidence it handed
;;                in (`hand_in'); in the session's own window, in a BTW
;;                over it, and in a task's session opened from the board
;;                -- the width is the window's;
;;   the report   at the end of its report popout, after the evidence
;;                (`harness-ui-report-panel-functions'), so the work is
;;                accepted or sent back where it is read.
;;
;; Under the banner the compose box writes the feedback that sends the
;; task back: C-c C-c takes what the box holds to the task's session,
;; which works on it again and comes back for review
;; (`harness-chat-send-function' in the session,
;; `harness-ui-report-compose-functions' in the report).  While the
;; banner shows, `harness-ui-review-mode' binds C-c C-v to verify and
;; C-c C-R to send back, anywhere in the buffer.  The banner disappears
;; when the task leaves review, whoever moved it, and its keys with it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-tasks)
(require 'harness-ui-report)

(defvar harness-chat-panel-functions)
(defvar harness-chat-send-function)
(defvar harness-chat-placeholder)
(defvar harness-chat-mode-map)
(defvar harness-ui-session-id)

(defgroup harness-ui-review nil
  "Reviewing a task's work in its own session and its report." :group 'harness-ui)

(defface harness-chat-review-face
  '((((background light)) :background "#e6f4e6" :extend t)
    (((background dark)) :background "#1f3a22" :extend t))
  "Background of the review banner: the board's Ready for review, in the session."
  :group 'harness-ui-review)

(defconst harness-ui-review--feedback-hint "What should change? C-c C-c sends it back"
  "The empty box's hint while it takes the feedback that sends a task back.")

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

;;;; The task under review

(defun harness-ui-review--current-task ()
  "Return the task this buffer shows, which has to wait for review.
In a report popout that is the task of the report; in a chat buffer,
the task of its session."
  (let* ((report (harness-ui-report-task))
         (task (or report (gethash harness-ui-session-id harness-ui-review--tasks))))
    (unless (harness-ui-review--reviewing-p task)
      (user-error (if report "This task is not waiting for your review"
                    "This session is not waiting for your review")))
    task))

(defun harness-ui-review-verify ()
  "Accept the work of the task this buffer shows: verify it.
Its branch then merges and the task is done.  In a task's session or in
its report popout, while it waits for review."
  (interactive)
  (let ((task (harness-ui-review--current-task)))
    (harness-ui-call "_harness/task/verify" (list :id (plist-get task :id)) #'ignore
                     (lambda (e) (message "Could not verify: %s" (harness-error-message e))))
    (message "Verified")))

(defun harness-ui-review-reject ()
  "Send the work of the task this buffer shows back: say what should change.
Point goes to the compose box, whose C-c C-c sends what you write there
back to the task.  In a task's session or in its report popout, while
it waits for review."
  (interactive)
  (harness-ui-review--current-task)
  ;; A report's box asks for the feedback already; a session's says so now.
  (when (derived-mode-p 'harness-chat-mode)
    (setq-local harness-chat-placeholder harness-ui-review--feedback-hint)
    (harness-compose-update-placeholder))
  (when-let* ((window (get-buffer-window (current-buffer))))
    (select-window window)
    (goto-char (or harness-compose-end (point-max))))
  (message "Write what should change in the box; C-c C-c sends it back"))

(defun harness-ui-review--send (text attachments)
  "Send the task this buffer shows back, TEXT and ATTACHMENTS its feedback.
What the compose box sends while the banner shows: a session's through
`harness-chat-send-function', a report popout's as the box's SUBMIT."
  (let ((task (harness-ui-review--current-task)))
    (if (and (harness-string-blank-p text) (null attachments))
        (user-error "Sending the work back needs feedback: type what should change")
      (harness-ui-call "_harness/task/reject"
                       (list :id (plist-get task :id) :feedback text :attachments attachments)
                       (lambda (_) (message "Sent back: the session works on your feedback"))
                       (lambda (e) (message "Could not send it back: %s" (harness-error-message e)))))))

;;;; The banner

(defun harness-ui-review--button (label command help)
  "Return a button string LABEL running COMMAND with HELP."
  (buttonize label (lambda (_) (funcall command)) nil help))

(defun harness-ui-review--key (key)
  "Return KEY as the banner shows a key beside its button."
  (propertize key 'face (if (facep 'harness-chat-key-face) 'harness-chat-key-face 'help-key-binding)))

(defun harness-ui-review--banner (task)
  "Return the banner string for TASK, waiting for review.
It reads as the board's Ready for review card: the mark, the heading,
what verifying does, and the buttons, with the keys beside them.  It
shows in the task's session, above the box, with a [Report] button when
the task handed one in, and at the end of that report's popout, above
the box there: drawn in the popout's buffer (`harness-ui-report-task'),
it speaks of the task and leaves [Report] out."
  (let* ((in-report (harness-ui-report-task))
         (title (harness-ui-tasks--title task))
         (merges (and (plist-get task :worktree) (not (harness-json-true-p (plist-get task :merged)))))
         (verify-help (if merges "Accept the work; its branch merges and the task is done"
                        "Accept the work; the task is done")))
    (concat
     " " (propertize (concat (harness-ui-icon 'harness-icon-task-review) " Ready for review")
                    'face 'harness-task-review-face)
     (propertize (if in-report "   this task is waiting for you" "   this session is a task waiting for you")
                 'face 'harness-dim-face)
     "\n"
     "   " (propertize title 'face 'bold)
     (propertize (if merges " is done; verify it to merge its branch, or send it back with what to change."
                   " is done; verify it, or send it back with what to change.")
                 'face 'harness-dim-face 'wrap-prefix "   ")
     "\n   "
     (harness-ui-review--button "[Verify]" #'harness-ui-review-verify verify-help)
     "  " (harness-ui-review--key "C-c C-v")
     "   "
     (harness-ui-review--button "[Send back]" #'harness-ui-review-reject
                                "Type the feedback in the box below, then C-c C-c")
     "  " (harness-ui-review--key "C-c C-R")
     (when (and (not in-report) (plist-get task :report))
       (concat "   " (harness-ui-review--button "[Report]" (lambda () (harness-ui-report-popout task))
                                                "The final message and evidence it handed in")))
     "\n"
     "   " (propertize "C-c C-c in the box sends what you write back to this task."
                    'face 'harness-hint-face)
     "\n ")))

(defun harness-ui-review--face (banner)
  "Return BANNER on the review background, under its own faces.
The board's Ready for review has it: a panel's own background stays out."
  (let ((s (copy-sequence banner)))
    (add-face-text-property 0 (length s) 'harness-chat-review-face t s)
    s))

;;;; Keys

(defvar harness-ui-review-mode-map (make-sparse-keymap)
  "Keys of a buffer showing a task that waits for your review.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-ui-review-mode-map))
  (define-key map (kbd "C-c C-v") #'harness-ui-review-verify)
  (define-key map (kbd "C-c C-R") #'harness-ui-review-reject))

(define-minor-mode harness-ui-review-mode
  "Keys to review the task this buffer shows, on while its banner shows.
In a task's session and in its report popout, while the task waits for
your review: \\<harness-ui-review-mode-map>\\[harness-ui-review-verify] verifies it and \\[harness-ui-review-reject] sends it back, with what the
compose box holds as the feedback.  Elsewhere, and once the task has
left review, the keys are the buffer's own (C-c C-v attaches the
clipboard to the box).

\\{harness-ui-review-mode-map}"
  :lighter nil :keymap harness-ui-review-mode-map :group 'harness-ui-review)

;; The banner's keys in the harness menu, while they are on.
(put 'harness-ui-review-mode 'harness-menu-group
     '("Review"
       ["Review"
        ("C-c C-v" "Verify (accept)" harness-ui-review-verify)
        ("C-c C-R" "Send back with feedback" harness-ui-review-reject)]))

(defun harness-ui-review--keys (on)
  "Turn this buffer's review keys on when ON, else off."
  (if on
      (unless harness-ui-review-mode (harness-ui-review-mode 1))
    (when harness-ui-review-mode (harness-ui-review-mode -1))))

;;;; Where the banner shows

(defun harness-ui-review--panel ()
  "Return the review banner when this session's task waits for review.
On `harness-chat-panel-functions': nil for a session that is no task's,
one that is not in review, or before the task is known.  While it
shows, the compose box takes feedback (`harness-chat-send-function')
and the review keys are on."
  (let* ((sid harness-ui-session-id)
         (task (harness-ui-review--task sid))
         (review (harness-ui-review--reviewing-p task)))
    (harness-ui-review--keys review)
    (if review
        (progn
          (setq-local harness-chat-send-function #'harness-ui-review--send)
          (harness-ui-review--face (harness-ui-review--banner task)))
      ;; Not in review: the box is the session's own again.
      (when (eq harness-chat-send-function #'harness-ui-review--send)
        (setq-local harness-chat-send-function nil))
      (when (equal harness-chat-placeholder harness-ui-review--feedback-hint)
        (kill-local-variable 'harness-chat-placeholder))
      nil)))

(defun harness-ui-review--report-panel (task)
  "Return the review banner for the end of TASK's report, when it waits for review.
On `harness-ui-report-panel-functions': the banner of TASK's session,
less its [Report] button.  While it shows, the review keys are on, and
the box under it sends TASK back (`harness-ui-review--report-compose')."
  (let ((review (harness-ui-review--reviewing-p task)))
    (harness-ui-review--keys review)
    (and review (harness-ui-review--face (harness-ui-review--banner task)))))

(defun harness-ui-review--report-compose (task)
  "Give TASK's report popout a box that sends it back, while it waits for review.
On `harness-ui-report-compose-functions'."
  (and (harness-ui-review--reviewing-p task)
       (cons #'harness-ui-review--send harness-ui-review--feedback-hint)))

;;;; Events and setup

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

(defun harness-ui-review--drop-chat-keys ()
  "Drop the review keys bound in every chat buffer before they had a mode.
They are `harness-ui-review-mode''s now, on while the banner shows; a
chat that is not in review has its own C-c C-v again.  Only a session
that ran the older code across `harness-reload' has them."
  (dolist (key '("C-c C-v" "C-c C-R"))
    (when (memq (lookup-key harness-chat-mode-map (kbd key))
                '(harness-ui-review-verify harness-ui-review-reject))
      (define-key harness-chat-mode-map (kbd key) nil t))))

(defun harness-ui-review--init ()
  "Add the banner to every chat buffer and to report popouts; follow tasks."
  (with-eval-after-load 'harness-ui-chat
    (harness-ui-review--drop-chat-keys)
    (add-hook 'harness-chat-mode-hook #'harness-ui-review--setup))
  (add-hook 'harness-ui-report-panel-functions #'harness-ui-review--report-panel)
  (add-hook 'harness-ui-report-compose-functions #'harness-ui-review--report-compose)
  (add-hook 'harness-ui-event-functions #'harness-ui-review--on-event))

(harness-define-module 'ui-review
  :doc "Reviewing a task where it is looked at: verify it or send it back."
  :requires '(ui ui-tasks ui-report)
  :init #'harness-ui-review--init)

(provide 'harness-ui-review)
;;; harness-ui-review.el ends here
