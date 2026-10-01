;;; harness-ui-btw-test.el --- Tests for BTW side conversations  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives BTW side windows against the real state layer, the demo
;; provider and the in-process ACP connection: a BTW over the task board
;; asks a new conversation about the tasks, a BTW over a session forks
;; it, closing goes back to where it was opened, keeping makes it a
;; normal session window.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo-delay)
(defvar harness-naming-auto)
(defvar harness-model)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-model)
(defvar harness-tasks-worktrees)
(defvar harness-ui-default-position)
(defvar harness-acp-server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-tasks--error)
(defvar harness-ui-btw--open)
(defvar harness-ui-btw-minor-mode)
(defvar harness-chat--buffers)
(defvar harness-chat--loading)
(defvar harness-compose-end)
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks-btw "harness-ui-tasks")
(declare-function harness-btw "harness-ui-btw")
(declare-function harness-ui-btw-close "harness-ui-btw")
(declare-function harness-ui-btw-promote "harness-ui-btw")
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-ui-display-session "harness-ui")
(declare-function harness-ui-session "harness-ui")
(declare-function harness-ui-refresh-sessions "harness-ui")
(declare-function harness-acp--drop-client "harness-acp")

(defun harness-ui-btw-test--reset-windows ()
  "Leave the frame with one ordinary window, side windows deleted."
  (dolist (w (window-list nil 'nomini))
    (when (and (window-live-p w) (window-parameter w 'window-side))
      (delete-window w)))
  (delete-other-windows))

(defmacro harness-ui-btw-test-with (&rest body)
  "Load the state layer, tasks, ACP, the chat, BTW and the board; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (setq harness-tasks--loaded t harness-acp--clients nil)
     (let ((harness-provider-demo-delay 0.005)
           (harness-provider-demo-script-override
            '((:type text :delta "Two tasks are in progress.") (:type done :stop-reason end-turn)))
           (harness-naming-auto nil)
           (harness-model "demo:scripted")
           (harness-tasks-model "demo:scripted")
           (harness-tasks-worktrees nil)
           (harness-ui-default-position 'right)
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (dolist (m '(ui ui-chat ui-btw ui-tasks)) (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (clrhash harness-ui-btw--open)
       (harness-ui-btw-test--reset-windows)
       (unwind-protect
           (progn ,@body)
         (harness-ui-btw-test--reset-windows)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (b (buffer-list))
           (when (string-prefix-p "*harness tasks" (buffer-name b)) (kill-buffer b)))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-btw-test--window ()
  "Return the window showing a BTW, waiting for one to open."
  (harness-test-wait (lambda () (cl-find-if (lambda (w) (buffer-local-value 'harness-ui-btw-minor-mode (window-buffer w)))
                                            (window-list nil 'nomini)))
                     5 "a BTW window"))

(defun harness-ui-btw-test--format (spec)
  "SPEC, a header line made of strings, lists and :eval forms, as plain text.
`format-mode-line' draws nothing in batch."
  (cond ((stringp spec) (substring-no-properties spec))
        ((eq (car-safe spec) :eval) (harness-ui-btw-test--format (eval (cadr spec) t)))
        ((consp spec) (mapconcat #'harness-ui-btw-test--format spec ""))
        (t "")))

(defun harness-ui-btw-test--header (buffer)
  "BUFFER's header line as plain text."
  (with-current-buffer buffer (harness-ui-btw-test--format header-line-format)))

(defun harness-ui-btw-test--wait-reply (sid)
  "Wait until session SID answered and its turn is over."
  (harness-test-wait (lambda () (and (cl-find 'assistant (harness-call 'session/nodes sid)
                                              :key (lambda (n) (plist-get n :kind)))
                                     (eq 'idle (plist-get (harness-call 'session/get sid) :status))
                                     (equal "idle" (format "%s" (plist-get (harness-ui-session sid) :status)))))
                     5 "the BTW's answer"))

(ert-deftest harness-ui-btw-over-the-board-asks-about-the-tasks ()
  "b on the board opens a BTW over it: a new conversation about the tasks."
  (harness-ui-btw-test-with
    (harness-call 'task/submit default-directory "Fix the flaky test")
    (let* ((board (harness-tasks default-directory))
           (board-window (get-buffer-window board))
           (prompts nil))
      (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board))) 5 "the board")
      (with-selected-window board-window
        (goto-char (point-min))
        (search-forward "Fix the flaky")
        (should (eq 'harness-ui-tasks-btw (key-binding (kbd "b"))))
        (should (string-match-p "\\[BTW\\]" (harness-ui-btw-test--header board)))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (prompt &rest _) (push prompt prompts) "how are the tasks going?")))
          (call-interactively (key-binding (kbd "b")))))
      (should (equal '("BTW about the tasks: ") prompts))
      (let* ((window (harness-ui-btw-test--window))
             (buffer (window-buffer window))
             (sid (buffer-local-value 'harness-ui-session-id buffer))
             (session (harness-call 'session/get sid)))
        ;; A side window under the board, which stays where it was.
        (should (eq 'bottom (window-parameter window 'window-side)))
        (should (eq window (selected-window)))
        (should (eq board (window-buffer board-window)))
        ;; A new conversation about the board, not a fork of anything.
        (should (eq 'btw (plist-get session :kind)))
        (should-not (plist-get session :parent-id))
        (should (equal default-directory (plist-get session :cwd)))
        (should (string-match-p "BTW about the tasks" (harness-ui-btw-test--header buffer)))
        (harness-ui-btw-test--wait-reply sid)
        (should (equal '("how are the tasks going?" "Two tasks are in progress.")
                       (mapcar (lambda (n) (plist-get n :content))
                               (cl-remove-if-not (lambda (n) (memq (plist-get n :kind) '(user assistant)))
                                                 (harness-call 'session/nodes sid)))))
        ;; Closing goes back to the board and closes the finished conversation.
        (with-selected-window window (harness-ui-btw-close))
        (should-not (window-live-p window))
        (should (eq board-window (selected-window)))
        (harness-test-wait (lambda () (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
                           5 "the BTW to be closed")))))

(ert-deftest harness-ui-btw-board-failure-shows-on-the-board ()
  "When the conversation cannot start, the board says so."
  (harness-ui-btw-test-with
    (let ((board (harness-tasks default-directory)))
      (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board))) 5 "the board")
      (cl-letf (((symbol-function 'harness-method/task/btw) (lambda (&rest _) (error "No room for a BTW"))))
        (with-current-buffer board (harness-btw nil "anything?"))
        (harness-test-wait (lambda () (buffer-local-value 'harness-ui-tasks--error board)) 5 "the failure")
        (should (string-match-p "\\`Starting a BTW failed: .*No room for a BTW"
                                (buffer-local-value 'harness-ui-tasks--error board)))
        (should-not (cl-some (lambda (w) (buffer-local-value 'harness-ui-btw-minor-mode (window-buffer w)))
                             (window-list nil 'nomini)))))))

(defun harness-ui-btw-test--open-session ()
  "Create a demo session, show it on the right and return (ID . WINDOW)."
  (let ((sid (plist-get (harness-call 'session/create :cwd default-directory :model "demo:scripted" :name "Main")
                        :id)))
    (harness-ui-refresh-sessions)
    (harness-test-wait (lambda () (harness-ui-session sid)) 5 "the session cache")
    (let ((buf (harness-ui-display-session sid 'right)))
      (harness-test-wait (lambda () (with-current-buffer buf (and (not harness-chat--loading) harness-compose-end)))
                         5 "the chat buffer")
      (cons sid (get-buffer-window buf)))))

(ert-deftest harness-ui-btw-over-a-session-forks-it ()
  "Over a session a BTW is still a fork of it, and closing returns to it."
  (harness-ui-btw-test-with
    (pcase-let ((`(,parent . ,parent-window) (harness-ui-btw-test--open-session)))
      (with-selected-window parent-window
        (harness-btw nil "what was that?"))
      (let* ((window (harness-ui-btw-test--window))
             (buffer (window-buffer window))
             (sid (buffer-local-value 'harness-ui-session-id buffer)))
        (should (eq 'btw (plist-get (harness-call 'session/get sid) :kind)))
        (should (equal parent (plist-get (harness-call 'session/get sid) :parent-id)))
        (should (string-match-p "BTW side conversation" (harness-ui-btw-test--header buffer)))
        (harness-ui-btw-test--wait-reply sid)
        (with-selected-window window (harness-ui-btw-close))
        (should (eq parent-window (selected-window)))
        (harness-test-wait (lambda () (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
                           5 "the BTW to be closed")
        (should (eq 'idle (plist-get (harness-call 'session/get parent) :status)))))))

(ert-deftest harness-ui-btw-keep-makes-a-normal-session-window ()
  "Keeping a BTW shows it where it was opened, with the session's own header."
  (harness-ui-btw-test-with
    (pcase-let ((`(,_parent . ,parent-window) (harness-ui-btw-test--open-session)))
      (with-selected-window parent-window
        (harness-btw nil "keep this one"))
      (let* ((window (harness-ui-btw-test--window))
             (buffer (window-buffer window))
             (sid (buffer-local-value 'harness-ui-session-id buffer)))
        (harness-ui-btw-test--wait-reply sid)
        (with-selected-window window (harness-ui-btw-promote))
        (should-not (window-live-p window))
        ;; It took the parent's place on the right, once, as a session.
        (should (eq buffer (window-buffer parent-window)))
        (should (equal (list parent-window) (get-buffer-window-list buffer nil t)))
        (with-current-buffer buffer
          (should-not harness-ui-btw-minor-mode)
          (should-not (string-match-p "\\[keep\\]" (harness-ui-btw-test--header buffer))))
        ;; A kept BTW is open: it stays active.
        (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))))))

(provide 'harness-ui-btw-test)
;;; harness-ui-btw-test.el ends here
