;;; harness-ui-btw-test.el --- Tests for BTW side conversations  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives BTW side windows against the real state layer, the demo
;; provider and the in-process ACP connection.  A BTW opens blank,
;; without reading anything in the minibuffer, with point in the
;; compose box of its chat buffer; the question is sent from that box
;; and names the BTW.  A BTW over the task board is a new conversation
;; about the tasks, one over a session forks it, one from the tree
;; forks at the node.  Closing goes back to where it was opened and
;; deletes a BTW nothing was asked in; keeping makes it a normal
;; session window.

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
(defvar harness-ui-tree--data)
(defvar harness-ui-tree--loading)
(defvar harness-chat--buffers)
(defvar harness-chat--loading)
(defvar harness-compose-end)
(defvar harness-compose--placeholder)
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks-btw "harness-ui-tasks")
(declare-function harness-tree "harness-ui-tree")
(declare-function harness-btw "harness-ui-btw")
(declare-function harness-ui-btw-close "harness-ui-btw")
(declare-function harness-ui-btw-promote "harness-ui-btw")
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-compose-in-p "harness-ui-compose")
(declare-function harness-compose-text "harness-ui-compose")
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
  "Load the state layer, tasks, ACP, the chat, BTW, the board and the tree; run BODY."
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
       (dolist (m '(ui ui-chat ui-btw ui-tasks ui-tree)) (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (clrhash harness-ui-btw--open)
       (harness-ui-btw-test--reset-windows)
       (unwind-protect
           (progn ,@body)
         (harness-ui-btw-test--reset-windows)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (b (buffer-list))
           (when (string-match-p "\\`\\*harness \\(?:tasks\\|tree\\)" (buffer-name b)) (kill-buffer b)))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defmacro harness-ui-btw-test-recording-reads (var &rest body)
  "Run BODY with minibuffer reads pushed onto VAR instead of reading.
A BTW never asks anything in the minibuffer: VAR stays empty."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'read-from-minibuffer) (lambda (prompt &rest _) (push prompt ,var) ""))
             ((symbol-function 'read-string) (lambda (prompt &rest _) (push prompt ,var) "")))
     ,@body))

(defun harness-ui-btw-test--window ()
  "Return the window showing a BTW, waiting for one to open."
  (harness-test-wait (lambda () (cl-find-if (lambda (w) (buffer-local-value 'harness-ui-btw-minor-mode (window-buffer w)))
                                            (window-list nil 'nomini)))
                     5 "a BTW window"))

(defun harness-ui-btw-test--open-btw (window command)
  "Run COMMAND interactively in WINDOW and return the BTW window it opens.
Nothing may be read from the minibuffer meanwhile."
  (let ((reads nil) (btw nil))
    (harness-ui-btw-test-recording-reads reads
      ;; Waited for outside: leaving `with-selected-window' selects WINDOW
      ;; again, while the BTW selects its own.
      (with-selected-window window (call-interactively command))
      (setq btw (harness-ui-btw-test--window)))
    (should-not reads)
    btw))

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

(defun harness-ui-btw-test--placeholder (buffer)
  "The hint BUFFER's empty compose box shows, as plain text, or nil."
  (with-current-buffer buffer
    (when-let* ((hint (and harness-compose--placeholder
                           (overlay-get harness-compose--placeholder 'before-string))))
      (substring-no-properties hint))))

(defun harness-ui-btw-test--wait-loaded (buffer)
  "Wait until the chat BUFFER a BTW shows has loaded its session."
  (harness-test-wait (lambda () (with-current-buffer buffer (and (not harness-chat--loading) harness-compose-end)))
                     5 "the BTW's chat buffer"))

(defun harness-ui-btw-test--ready-p (window)
  "Non-nil when WINDOW shows a loaded BTW with point in its compose box."
  (let ((buffer (window-buffer window)))
    (harness-ui-btw-test--wait-loaded buffer)
    (and (eq window (selected-window))
         (with-current-buffer buffer
           (and (derived-mode-p 'harness-chat-mode) (harness-compose-in-p (window-point window)))))))

(defun harness-ui-btw-test--ask (window text)
  "Write TEXT at point in WINDOW and send it with the key C-c C-c."
  (with-selected-window window
    (insert text)
    (call-interactively (key-binding (kbd "C-c C-c")))))

(defun harness-ui-btw-test--wait-reply (sid)
  "Wait until session SID answered and its turn is over."
  (harness-test-wait (lambda () (and (cl-find 'assistant (harness-call 'session/nodes sid)
                                              :key (lambda (n) (plist-get n :kind)))
                                     (eq 'idle (plist-get (harness-call 'session/get sid) :status))
                                     (equal "idle" (format "%s" (plist-get (harness-ui-session sid) :status)))))
                     5 "the BTW's answer"))

(defun harness-ui-btw-test--wait-name (sid name)
  "Wait until session SID is called NAME."
  (harness-test-wait (lambda () (equal name (plist-get (harness-call 'session/get sid) :name)))
                     5 (format "the BTW to be named %S" name)))

(defun harness-ui-btw-test--wait-gone (sid buffer)
  "Wait until session SID is deleted, its BUFFER killed and the UI forgot it."
  (harness-test-wait (lambda () (and (not (harness-call 'session/exists-p sid))
                                     (not (buffer-live-p buffer))
                                     (null (harness-ui-session sid))))
                     5 "the unused BTW to be deleted"))

(defun harness-ui-btw-test--board ()
  "Show the board of `default-directory' and return it once loaded."
  (let ((board (harness-tasks default-directory)))
    (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board))) 5 "the board")
    board))

(ert-deftest harness-ui-btw-over-the-board-asks-about-the-tasks ()
  "b on the board opens a blank BTW over it: a new conversation about the tasks.
The question goes in the BTW's compose box, C-c C-c asks it, and it
names the conversation."
  (harness-ui-btw-test-with
    (harness-call 'task/submit default-directory "Fix the flaky test")
    (let* ((board (harness-ui-btw-test--board))
           (board-window (get-buffer-window board)))
      (with-selected-window board-window
        (goto-char (point-min))
        (search-forward "Fix the flaky")
        (should (eq 'harness-ui-tasks-btw (key-binding (kbd "b"))))
        (should (string-match-p "\\[BTW\\]" (harness-ui-btw-test--header board))))
      (let* ((window (harness-ui-btw-test--open-btw board-window (with-selected-window board-window
                                                                 (key-binding (kbd "b")))))
             (buffer (window-buffer window))
             (sid (buffer-local-value 'harness-ui-session-id buffer))
             (session (harness-call 'session/get sid)))
        ;; A side window under the board, which stays where it was.
        (should (eq 'bottom (window-parameter window 'window-side)))
        (should (eq board (window-buffer board-window)))
        ;; A new conversation about the board, not a fork of anything, still blank.
        (should (eq 'btw (plist-get session :kind)))
        (should-not (plist-get session :parent-id))
        (should (equal default-directory (plist-get session :cwd)))
        (should (equal "btw" (plist-get session :name)))
        (should-not (harness-call 'session/nodes sid))
        (should (string-match-p "BTW about the tasks" (harness-ui-btw-test--header buffer)))
        ;; Point waits in the chat's compose box, which says what to ask.
        (should (harness-ui-btw-test--ready-p window))
        (should (equal "Ask about the tasks\N{U+2026}" (harness-ui-btw-test--placeholder buffer)))
        (harness-ui-btw-test--ask window "how are the tasks going?")
        (harness-ui-btw-test--wait-reply sid)
        (should (equal '("how are the tasks going?" "Two tasks are in progress.")
                       (mapcar (lambda (n) (plist-get n :content))
                               (cl-remove-if-not (lambda (n) (memq (plist-get n :kind) '(user assistant)))
                                                 (harness-call 'session/nodes sid)))))
        ;; The question names it, without a hint in the transcript.
        (harness-ui-btw-test--wait-name sid "btw: how are the tasks going?")
        (should-not (cl-find-if (lambda (n) (string-match-p "renamed" (format "%s" (plist-get n :content))))
                                (harness-call 'session/nodes sid)))
        ;; Closing goes back to the board and closes the finished conversation.
        (with-selected-window window (harness-ui-btw-close))
        (should-not (window-live-p window))
        (should (eq board-window (selected-window)))
        (harness-test-wait (lambda () (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
                           5 "the BTW to be closed")
        (should (buffer-live-p buffer))))))

(ert-deftest harness-ui-btw-board-failure-shows-on-the-board ()
  "When the conversation cannot start, the board says so."
  (harness-ui-btw-test-with
    (let ((board (harness-ui-btw-test--board)))
      (cl-letf (((symbol-function 'harness-method/task/btw) (lambda (&rest _) (error "No room for a BTW"))))
        (with-current-buffer board (harness-btw))
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
  "Over a session a BTW is a blank fork of it, asked from its compose box.
Closing returns to the session."
  (harness-ui-btw-test-with
    (pcase-let ((`(,parent . ,parent-window) (harness-ui-btw-test--open-session)))
      (let* ((window (harness-ui-btw-test--open-btw parent-window #'harness-btw))
             (buffer (window-buffer window))
             (sid (buffer-local-value 'harness-ui-session-id buffer)))
        (should (eq 'btw (plist-get (harness-call 'session/get sid) :kind)))
        (should (equal parent (plist-get (harness-call 'session/get sid) :parent-id)))
        (should (equal "btw" (plist-get (harness-call 'session/get sid) :name)))
        (should (string-match-p "BTW side conversation" (harness-ui-btw-test--header buffer)))
        (should (harness-ui-btw-test--ready-p window))
        (should (equal "Ask a side question\N{U+2026}" (harness-ui-btw-test--placeholder buffer)))
        (harness-ui-btw-test--ask window "what was that?")
        (harness-ui-btw-test--wait-reply sid)
        (harness-ui-btw-test--wait-name sid "btw: what was that?")
        (with-selected-window window (harness-ui-btw-close))
        (should (eq parent-window (selected-window)))
        (harness-test-wait (lambda () (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
                           5 "the BTW to be closed")
        (should (eq 'idle (plist-get (harness-call 'session/get parent) :status)))
        ;; Its buffer stays, back to a session's own header: opened again
        ;; from the session list, it is a session like any.
        (with-current-buffer buffer
          (should-not harness-ui-btw-minor-mode)
          (should-not (string-match-p "\\[keep\\]" (harness-ui-btw-test--header buffer))))
        (with-current-buffer (window-buffer parent-window)
          (should-not harness-ui-btw-minor-mode))))))

(ert-deftest harness-ui-btw-first-message-names-it-unless-named ()
  "Only the first message with text names a BTW, and never over a name given by hand."
  (harness-ui-btw-test-with
    (pcase-let ((`(,_parent . ,parent-window) (harness-ui-btw-test--open-session)))
      ;; Named by hand before anything was asked: the name stays.
      (let* ((window (harness-ui-btw-test--open-btw parent-window #'harness-btw))
             (sid (buffer-local-value 'harness-ui-session-id (window-buffer window))))
        (harness-call 'session/update sid :name "my side thing")
        (harness-test-wait (lambda () (equal "my side thing" (plist-get (harness-ui-session sid) :name)))
                           5 "the UI to see the name")
        (should (harness-ui-btw-test--ready-p window))
        (harness-ui-btw-test--ask window "a question")
        (harness-ui-btw-test--wait-reply sid)
        (should (equal "my side thing" (plist-get (harness-call 'session/get sid) :name)))
        (with-selected-window window (harness-ui-btw-close)))
      ;; Queued rather than sent, the first message names it all the same.
      (let* ((window (harness-ui-btw-test--open-btw parent-window #'harness-btw))
             (sid (buffer-local-value 'harness-ui-session-id (window-buffer window))))
        (should (harness-ui-btw-test--ready-p window))
        (with-selected-window window
          (insert "later, please")
          (call-interactively (key-binding (kbd "C-c C-q"))))
        (harness-ui-btw-test--wait-name sid "btw: later, please")
        (harness-test-wait (lambda () (plist-get (harness-call 'session/get sid) :queue)) 5 "the queued message")
        ;; Something was asked: closing keeps it.
        (with-selected-window window (harness-ui-btw-close))
        (harness-test-wait (lambda () (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
                           5 "the BTW to be closed")))))

(ert-deftest harness-ui-btw-closing-an-unused-btw-deletes-it ()
  "A BTW closed before anything was asked in it is deleted with its buffer.
One holding a draft is kept, closed, with the draft."
  (harness-ui-btw-test-with
    (pcase-let ((`(,parent . ,parent-window) (harness-ui-btw-test--open-session)))
      (let ((sessions (length (harness-call 'session/list))))
        ;; Opened and closed at once: nothing is left behind.
        (let* ((window (harness-ui-btw-test--open-btw parent-window #'harness-btw))
               (buffer (window-buffer window))
               (sid (buffer-local-value 'harness-ui-session-id buffer)))
          (should (harness-call 'session/exists-p sid))
          (with-selected-window window (harness-ui-btw-close))
          (should-not (window-live-p window))
          (should (eq parent-window (selected-window)))
          (harness-ui-btw-test--wait-gone sid buffer)
          (should (= sessions (length (harness-call 'session/list))))
          (should (eq 'idle (plist-get (harness-call 'session/get parent) :status))))
        ;; A draft in the box keeps it.
        (let* ((window (harness-ui-btw-test--open-btw parent-window #'harness-btw))
               (buffer (window-buffer window))
               (sid (buffer-local-value 'harness-ui-session-id buffer)))
          (should (harness-ui-btw-test--ready-p window))
          (with-selected-window window (insert "half a thought"))
          (with-selected-window window (harness-ui-btw-close))
          (harness-test-wait (lambda () (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
                             5 "the BTW to be closed")
          (should (buffer-live-p buffer))
          (should (equal "half a thought" (with-current-buffer buffer (harness-compose-text)))))))))

(ert-deftest harness-ui-btw-unused-board-btw-is-deleted ()
  "An unused BTW over the board, a fresh session, is deleted on close too."
  (harness-ui-btw-test-with
    (let* ((board (harness-ui-btw-test--board))
           (board-window (get-buffer-window board))
           (window (harness-ui-btw-test--open-btw board-window #'harness-ui-tasks-btw))
           (buffer (window-buffer window))
           (sid (buffer-local-value 'harness-ui-session-id buffer)))
      (should (harness-ui-btw-test--ready-p window))
      (with-selected-window window (harness-ui-btw-close))
      (should (eq board-window (selected-window)))
      (harness-ui-btw-test--wait-gone sid buffer))))

(ert-deftest harness-ui-btw-keep-makes-a-normal-session-window ()
  "Keeping a BTW shows it where it was opened, with the session's own header.
From Lisp a question can be asked at once; it names the BTW."
  (harness-ui-btw-test-with
    (pcase-let ((`(,_parent . ,parent-window) (harness-ui-btw-test--open-session)))
      (with-selected-window parent-window
        (harness-btw nil "keep this one"))
      (let* ((window (harness-ui-btw-test--window))
             (buffer (window-buffer window))
             (sid (buffer-local-value 'harness-ui-session-id buffer)))
        (should (equal "btw: keep this one" (plist-get (harness-call 'session/get sid) :name)))
        (harness-ui-btw-test--wait-reply sid)
        (with-selected-window window (harness-ui-btw-promote))
        (should-not (window-live-p window))
        ;; It took the parent's place on the right, once, as a session.
        (should (eq buffer (window-buffer parent-window)))
        (should (equal (list parent-window) (get-buffer-window-list buffer nil t)))
        (with-current-buffer buffer
          (should-not harness-ui-btw-minor-mode)
          (should-not (string-match-p "\\[keep\\]" (harness-ui-btw-test--header buffer))))
        ;; With the session's own hint in its box.
        (should (equal "Message\N{U+2026}" (harness-ui-btw-test--placeholder buffer)))
        ;; A kept BTW is open: it stays active.
        (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))))))

(defun harness-ui-btw-test--goto-tree-node (id)
  "Move point to the tree row of node ID."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal id (plist-get (get-text-property (point) 'harness-ui-tree-node) :id))))
    (forward-line 1))
  (should-not (eobp)))

(ert-deftest harness-ui-btw-from-the-tree-forks-at-the-node ()
  "b on a node of the tree opens a blank BTW forked there, over the tree.
The session's head moves back once the fork is made."
  (harness-ui-btw-test-with
    (let* ((sid (plist-get (harness-call 'session/create :cwd default-directory :model "demo:scripted" :name "Main")
                           :id))
           (n1 (plist-get (harness-call 'session/append sid (list :kind 'user :content "first question")) :id))
           (n2 (plist-get (harness-call 'session/append sid (list :kind 'assistant :content "first answer")) :id)))
      (harness-ui-refresh-sessions)
      (harness-test-wait (lambda () (harness-ui-session sid)) 5 "the session cache")
      (let ((harness-ui-default-position 'full))
        (harness-tree sid))
      (let ((tree (current-buffer))
            (tree-window (selected-window)))
        (harness-test-wait (lambda () (with-current-buffer tree (and harness-ui-tree--data (not harness-ui-tree--loading))))
                           5 "the tree")
        (harness-ui-btw-test--goto-tree-node n1)
        (should (eq 'harness-ui-tree-btw (key-binding (kbd "b"))))
        (let* ((window (harness-ui-btw-test--open-btw tree-window (key-binding (kbd "b"))))
               (buffer (window-buffer window))
               (btw (buffer-local-value 'harness-ui-session-id buffer))
               (session (harness-call 'session/get btw)))
          (should (eq 'btw (plist-get session :kind)))
          (should (equal sid (plist-get session :parent-id)))
          (should (equal n1 (plist-get session :fork-node)))
          (should (harness-ui-btw-test--ready-p window))
          (harness-test-wait (lambda () (equal n2 (plist-get (harness-call 'session/get sid) :head)))
                             5 "the head to move back")
          ;; Closed unused, back to the tree.
          (with-selected-window window (harness-ui-btw-close))
          (should (eq tree-window (selected-window)))
          (harness-ui-btw-test--wait-gone btw buffer))))))

(provide 'harness-ui-btw-test)
;;; harness-ui-btw-test.el ends here
