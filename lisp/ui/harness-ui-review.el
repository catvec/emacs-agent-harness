;;; harness-ui-review.el --- Reviewing a task: the banner of its session and of its report  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task waiting for review shows a banner wherever its work is looked
;; at: that the work is done and waits for the user, and the buttons that
;; act on it -- [Verify], which accepts the work and merges its branch,
;; and [Send back].  It is the board's Ready for review: the same mark
;; and the same wording, so accepting work is one action wherever the
;; user is.  One banner, one set of commands and keys, in two places:
;;
;;   the session  above its compose box, a chat panel
;;                (`harness-chat-panel-functions'), with [Review] too,
;;                which pops the report out;
;;                in the session's own window, in a BTW over it, and in
;;                a task's session opened from the board -- the width is
;;                the window's;
;;   the report   at the end of its report popout, after the evidence
;;                (`harness-ui-report-panel-functions'), so the work is
;;                accepted or sent back where it is read.
;;
;; Inside the session the report is not behind a button either: it is
;; shown in full and always expanded, between the heading and the
;; buttons (`harness-ui-review--report', `harness-ui-report-string').
;; A round whose turn ended without `hand_in' has no report, only what
;; the harness recorded for it (`harness-tasks--missing-report'): the
;; banner says in a line that nothing was handed in, its last message
;; being right above, and has no [Review].
;;
;; Under the banner the compose box writes the feedback that sends the
;; task back: C-c C-c takes what the box holds to the task's session,
;; which works on it again and comes back for review.  The session's box
;; needs nothing of its own: the harness takes any message to the
;; session of a task in review for the feedback that sends it back,
;; whoever wrote it (`harness-tasks--on-message').  The report's box
;; sends it back itself (`harness-ui-review--send' through
;; `harness-ui-report-compose-functions').  Its keys,
;; C-c C-v to verify and C-c C-x to send back, are those of
;; `harness-ui-review-minor-mode', on only while the banner shows: the
;; rest of the time the buffer's own keys stand, C-c C-v attaching the
;; clipboard.  The banner disappears when the task leaves review, whoever
;; moved it, and its keys with it.

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
(declare-function harness-ui-report-string "harness-ui-report" (task &optional window))
(declare-function harness-ui-report-task "harness-ui-report" ())

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
                (equal (buffer-local-value 'harness-ui-session-id buffer) sid))
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
  (let* ((report (and (fboundp 'harness-ui-report-task) (harness-ui-report-task)))
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
Point goes to the compose box, whose \\<harness-chat-mode-map>\\[harness-chat-send] sends what you write there
back to the task.  In a task's session or in its report popout, while
it waits for review.  Any message sent to the session while its task
waits for review sends the task back with it as the feedback; this
takes you to the box."
  (interactive)
  (harness-ui-review--current-task)
  ;; A report's box asks for the feedback already; a session's says so now.
  (when (derived-mode-p 'harness-chat-mode)
    (setq-local harness-chat-placeholder harness-ui-review--feedback-hint)
    (with-no-warnings
      (when (fboundp 'harness-compose-update-placeholder)
        (harness-compose-update-placeholder))))
  (when-let* ((window (get-buffer-window (current-buffer))))
    (select-window window)
    (goto-char (or harness-compose-end (point-max))))
  (message "Write what should change in the box; C-c C-c sends it back"))

(defun harness-ui-review--send (text attachments)
  "Send the task this buffer shows back, TEXT and ATTACHMENTS its feedback.
The report popout's box under the banner sends this way
\(`harness-ui-report-compose-functions'); a session's box is the
session's own, the harness taking any message to the task's session for
the feedback that sends it back (`harness-tasks--on-message')."
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
  (propertize (buttonize label (lambda (_) (funcall command)) nil help)
              "mouse-face" 'highlight))

(defconst harness-ui-review--indentation "   "
  "What the banner's lines start with, under its heading.")

(defun harness-ui-review--indent (string)
  "Return STRING indented as the banner's text, on the review background.
Every line of it, wrapped ones too, starts with the banner's
indentation; the line and wrap prefixes STRING has already follow,
on the same background, so no stretch of a line goes without it."
  (let* ((s (copy-sequence string))
         (on-review (lambda (prefix)
                      (let ((p (copy-sequence prefix)))
                        (add-face-text-property 0 (length p) 'harness-chat-review-face t p)
                        p)))
         (margin (funcall on-review harness-ui-review--indentation))
         (pos 0)
         (len (length s)))
    (while (< pos len)
      (let ((next (or (next-property-change pos s) len))
            (line (get-text-property pos 'line-prefix s))
            (wrap (get-text-property pos 'wrap-prefix s)))
        (put-text-property pos next 'line-prefix
                           (concat margin (if (stringp line) (funcall on-review line) "")) s)
        (put-text-property pos next 'wrap-prefix
                           (concat margin (if (stringp wrap) (funcall on-review wrap) "")) s)
        (setq pos next)))
    s))

(defun harness-ui-review--missing-p (task)
  "Non-nil when TASK's report says its round of work handed none in.
The harness records one such when the turn ends without `hand_in'
\(`harness-tasks--missing-report')."
  (harness-json-true-p (plist-get (plist-get task :report) :missing)))

(defconst harness-ui-review--missing-text
  "It handed no report in: its turn ended without hand_in, so there is no summary and no evidence.  Its last message is above; check the work before you verify it."
  "What the banner says of a task whose round handed no report in.")

(defun harness-ui-review--report (task)
  "Return the report TASK handed in, drawn in full for the banner, or nil.
Inside the session the report is always expanded -- the summary and
every piece of evidence, each referenced call with its whole output --
and indented as the banner's text.  It is the drawing of the report
popout [Review] opens (`harness-ui-report-string'), sized for this
buffer's window.
A round that handed no report in says so instead, in a line: the
session's last message, all the harness has for it, is right above.
A report that cannot be drawn says so rather than take the compose box
down with it."
  (when (and (plist-get task :report) (fboundp 'harness-ui-report-string))
    (harness-ui-review--indent
     (if (harness-ui-review--missing-p task)
         (propertize (concat harness-ui-review--missing-text "\n") 'face 'warning)
       (condition-case err
           (or (harness-ui-report-string task (car (get-buffer-window-list nil nil t))) "")
         (error (propertize (format "The report could not be drawn: %s\n" (error-message-string err))
                            'face 'harness-dim-face)))))))

(defun harness-ui-review--banner (task &optional report in-report)
  "Return the banner string for TASK, waiting for review.
It reads as the board's Ready for review card: the mark, the heading,
what verifying does, and the buttons, with the keys beside them.
REPORT, what TASK handed in drawn in full (`harness-ui-review--report'),
goes between what verifying does and the buttons: the work is read
before it is verified or sent back.  IN-REPORT is non-nil when the banner
is drawn at the end of TASK's report popout
\\(`harness-ui-report-panel-functions'): it speaks of the task then, and
leaves [Review] out, the report being the window it is drawn in."
  (let* ((in-report (or in-report (and (fboundp 'harness-ui-report-task)
                                       (harness-ui-report-task))))
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
     "\n"
     (if (harness-string-blank-p report) "" (concat "\n" report "\n"))
     "   "
     (harness-ui-review--button "[Verify]" #'harness-ui-review-verify verify-help)
     (harness-ui-review--key #'harness-ui-review-verify)
     "   "
     (harness-ui-review--button "[Send back]" #'harness-ui-review-reject
                                "Type the feedback in the box below, then C-c C-c")
     (harness-ui-review--key #'harness-ui-review-reject)
     ;; A round that handed none in has nothing for [Review] to pop out
     ;; that the session does not show already.  [Review] as on the
     ;; board's card (`harness-ui-tasks--card-buttons'), not [Report].
     (when (and (not in-report) (plist-get task :report) (not (harness-ui-review--missing-p task))
                (fboundp 'harness-ui-report-popout))
       (concat "   " (harness-ui-review--button "[Review]" (lambda () (harness-ui-report-popout task))
                                                "Review the final message and evidence in a window of their own")))
     "\n"
     "   " (propertize "C-c C-c in the box sends what you write back to this task."
                    'face 'harness-hint-face)
     "\n ")))

;;;; Keys

(defvar harness-ui-review-minor-mode-map (make-sparse-keymap)
  "Keys of a buffer showing a task that waits for your review.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-ui-review-minor-mode-map))
  (define-key map (kbd "C-c C-v") #'harness-ui-review-verify)
  ;; No Shift to hold: x sits next to c and two keys from v, so a slip
  ;; does not verify (which merges) instead.
  (define-key map (kbd "C-c C-x") #'harness-ui-review-reject))

(define-minor-mode harness-ui-review-minor-mode
  "Keys to review the task this buffer shows, on while its banner shows.
In a task's session and in its report popout, while the task waits for
your review: \\<harness-ui-review-minor-mode-map>\\[harness-ui-review-verify] verifies it and \\[harness-ui-review-reject] sends it back, with what the
compose box holds as the feedback.  Elsewhere, and once the task has
left review, the keys are the buffer's own (C-c C-v attaches the
clipboard to the box).

\\{harness-ui-review-minor-mode-map}"
  :lighter nil :keymap harness-ui-review-minor-mode-map :group 'harness-ui-review)

;; Its keys in the harness menu.  They beat the chat's own `C-c C-v'
;; there, in the menu as in the buffer.
(put 'harness-ui-review-minor-mode 'harness-menu-group
     '("Review"
       ["Task in review"
        ("C-c C-v" "Verify (accept)" harness-ui-review-verify)
        ("C-c C-x" "Send back with feedback" harness-ui-review-reject)]))

;; The banner's keys once sat in the chat's own map, so they acted in
;; every session: C-c C-v hid the box's attach-the-clipboard, and C-c C-R,
;; which Emacs reads as C-c C-r, the chat's redraw.  A reload takes them out.
(when (boundp 'harness-chat-mode-map)
  (dolist (key (list (kbd "C-c C-v") (kbd "C-c C-r")))
    (when (memq (lookup-key harness-chat-mode-map key)
                '(harness-ui-review-verify harness-ui-review-reject))
      (define-key harness-chat-mode-map key nil t))))

(defun harness-ui-review--key (command)
  "Return \"  KEY\" for COMMAND's key in the banner, or \"\" when it has none.
Read from `harness-ui-review-minor-mode-map': the banner shows the key
that runs it."
  (if-let* ((key (where-is-internal command (list harness-ui-review-minor-mode-map) t)))
      (concat "  " (propertize (key-description key) 'face 'harness-chat-key-face))
    ""))

(defun harness-ui-review--shown (task)
  "Return what the banner shows of TASK: nil unless TASK waits for review.
Two records whose banners read the same give `equal' values, so a
change the banner does not show -- a task at work moving on, say --
does not draw the session's tail again under a reader of the report."
  (when (harness-ui-review--reviewing-p task)
    (list (plist-get task :id) (plist-get task :prompt) (plist-get task :worktree)
          (plist-get task :merged) (plist-get task :report))))

(defun harness-ui-review--keys (on)
  "Turn this buffer's review keys on when ON, else off."
  (if on
      (unless harness-ui-review-minor-mode (harness-ui-review-minor-mode 1))
    (when harness-ui-review-minor-mode (harness-ui-review-minor-mode -1))))

;;;; Where the banner shows

(defun harness-ui-review--face (banner)
  "Return BANNER on the review background, under its own faces.
The board's Ready for review has it: a panel's own background stays out."
  (if (fboundp 'harness-chat--face)
      (harness-chat--face banner 'harness-chat-review-face)
    (let ((s (copy-sequence banner)))
      (add-face-text-property 0 (length s) 'harness-chat-review-face t s)
      s)))

(defun harness-ui-review--panel ()
  "Return the review banner when this session's task waits for review.
On `harness-chat-panel-functions': nil for a session that is no task's,
one that is not in review, or before the task is known.  While it
shows, the banner's keys are on (`harness-ui-review-minor-mode'); the
box is the session's own, since the harness takes any message to the
task's session for the feedback that sends it back
\(`harness-tasks--on-message')."
  (let* ((sid harness-ui-session-id)
         (task (harness-ui-review--task sid))
         (review (harness-ui-review--reviewing-p task)))
    (harness-ui-review--keys review)
    ;; A buffer drawn by an earlier version may still have its box routed
    ;; to `harness-ui-review--send'; the harness takes the message now.
    (when (eq harness-chat-send-function #'harness-ui-review--send)
      (kill-local-variable 'harness-chat-send-function))
    (if review
        (harness-ui-review--face (harness-ui-review--banner task (harness-ui-review--report task)))
      ;; Not in review: the box asks for a message again, not feedback.
      (when (equal harness-chat-placeholder harness-ui-review--feedback-hint)
        (kill-local-variable 'harness-chat-placeholder))
      nil)))

(defun harness-ui-review--report-panel (task)
  "Return the review banner for the end of TASK's report, when it waits for review.
On `harness-ui-report-panel-functions': the banner of TASK's session,
less its [Review] button.  While it shows, the review keys are on, and
the box under it sends TASK back (`harness-ui-review--report-compose')."
  (let ((review (harness-ui-review--reviewing-p task)))
    (harness-ui-review--keys review)
    (and review (harness-ui-review--face (harness-ui-review--banner task nil t)))))

(defun harness-ui-review--report-compose (task)
  "Give TASK's report popout a box that sends it back, while it waits for review.
On `harness-ui-report-compose-functions'."
  (and (harness-ui-review--reviewing-p task)
       (cons #'harness-ui-review--send harness-ui-review--feedback-hint)))

;;;; Events and setup

(defun harness-ui-review--on-event (event args)
  "Follow EVENT with ARGS: keep the review banners in step with the tasks.
The banner of an open session follows its task, and a session that
becomes a task's, or stops being one, is looked up again.  Only a
change the banner shows draws the session's tail again: the report it
holds is long, and its reader keeps their place."
  (pcase event
    ((or "task/changed" "task/review" "task/done")
     (let ((task (car args)))
       (when-let* ((sid (plist-get task :session)))
         (let ((before (harness-ui-review--shown (gethash sid harness-ui-review--tasks))))
           (puthash sid task harness-ui-review--tasks)
           (unless (equal before (harness-ui-review--shown task))
             (harness-ui-review--redraw sid))))))
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
  "Add the banner to every chat buffer and to report popouts; follow tasks."
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-review--setup))
  (with-eval-after-load 'harness-ui-report
    (add-hook 'harness-ui-report-panel-functions #'harness-ui-review--report-panel)
    (add-hook 'harness-ui-report-compose-functions #'harness-ui-review--report-compose))
  (add-hook 'harness-ui-event-functions #'harness-ui-review--on-event))

(harness-define-module 'ui-review
  :doc "Reviewing a task where it is looked at: its report in full in its session; verify it or send it back."
  :requires '(ui ui-tasks ui-report)
  :init #'harness-ui-review--init)

(provide 'harness-ui-review)
;;; harness-ui-review.el ends here
