;;; harness-ui-btw-test.el --- Tests for BTW side conversations  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives BTW side windows against the real state layer, the demo
;; provider and the in-process ACP connection.  A BTW opens blank,
;; without reading anything in the minibuffer, with point in the
;; compose box of its chat buffer; the question is sent from that box
;; and names the BTW.  It is the full chat: the session's own header
;; line with the BTW segment in front, whose permission mode changes
;; from the header, the key and the menu like any session's.  Every BTW
;; is a new session sharing nothing with any other: one over the task
;; board is a conversation about the tasks; one over a session, or from
;; a node of the tree, is listed under that session but has none of its
;; transcript or provider state, nor anything of an earlier BTW.
;; Closing goes back to where it was opened and deletes a BTW nothing
;; was asked in; keeping makes it a normal session window, header
;; included.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
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
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-tasks--error)
(defvar harness-ui-btw--open)
(defvar harness-ui-btw-minor-mode)
(defvar harness-ui-tree--data)
(defvar harness-ui-tree--loading)
(defvar harness-ui-tree--family)
(defvar harness-ui-tree--rows)
(defvar harness-chat--buffers)
(defvar harness-chat--loading)
(defvar harness-chat-header-functions)
(defvar harness-compose-end)
(defvar harness-compose--placeholder)
(defvar harness-ui-sessions--buffer-name)
(defvar transient--buffer-name)
(declare-function harness-sessions "harness-ui-sessions")
(declare-function harness-ui-sessions--ordered "harness-ui-sessions")
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks-btw "harness-ui-tasks")
(declare-function harness-tree "harness-ui-tree")
(declare-function harness-btw "harness-ui-btw")
(declare-function harness-ui-btw-close "harness-ui-btw")
(declare-function harness-ui-btw-promote "harness-ui-btw")
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat--header "harness-ui-chat")
(declare-function harness-compose-in-p "harness-ui-compose")
(declare-function harness-compose-text "harness-ui-compose")
(declare-function harness-ui-display-session "harness-ui")
(declare-function harness-ui-session "harness-ui")
(declare-function harness-ui-refresh-sessions "harness-ui")
(declare-function harness-ui-thinking-label "harness-ui")
(declare-function harness-acp--drop-client "harness-acp")

(defun harness-ui-btw-test--reset-windows ()
  "Leave the frame with one ordinary window, side windows deleted."
  (dolist (w (window-list nil 'nomini))
    (when (and (window-live-p w) (window-parameter w 'window-side))
      (delete-window w)))
  (delete-other-windows))

(defmacro harness-ui-btw-test-with (&rest body)
  "Load the state layer, tasks, ACP, the chat, BTW, the board, the tree and
the session list; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (setq harness-tasks--loaded t harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
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
       (dolist (m '(ui ui-chat ui-btw ui-tasks ui-tree ui-sessions)) (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (clrhash harness-ui-btw--open)
       (harness-ui-btw-test--reset-windows)
       (unwind-protect
           (progn ,@body)
         (harness-ui-btw-test--reset-windows)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (b (buffer-list))
           (when (string-match-p "\\`\\*harness \\(?:tasks\\|tree\\|sessions\\)" (buffer-name b)) (kill-buffer b)))
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

(defun harness-ui-btw-test--own-header (buffer)
  "BUFFER's header line as plain text, without what modes put in front of it.
That is the header line any chat buffer of its session has."
  (with-current-buffer buffer
    (let ((harness-chat-header-functions nil))
      (harness-ui-btw-test--header buffer))))

(defun harness-ui-btw-test--full-header (buffer)
  "BUFFER's header line as plain text, with room for all of it.
A header is fitted to its window, and a BTW's is the chat's own with
the BTW segment in front: in a narrow window the chat drops what does
not fit.  This asks the view for the whole line, so a test can say what
a header holds without depending on the batch frame's width."
  (with-current-buffer buffer (harness-chat--header most-positive-fixnum)))

(defun harness-ui-btw-test--own-full-header (buffer)
  "BUFFER's header as `harness-ui-btw-test--full-header', without a mode's own."
  (with-current-buffer buffer
    (let ((harness-chat-header-functions nil))
      (harness-chat--header most-positive-fixnum))))

(defun harness-ui-btw-test--normal-header-p (buffer)
  "Non-nil when BUFFER's header line is the chat's, with nothing of a BTW's."
  (with-current-buffer buffer
    (and (equal '(:eval (harness-chat--header)) header-line-format)
         (not (local-variable-p 'harness-chat-header-functions))
         (equal (harness-ui-btw-test--own-header buffer) (harness-ui-btw-test--header buffer))
         ;; The session may well be called "btw".
         (let ((case-fold-search nil))
           (not (string-match-p "BTW\\|\\[close\\]\\|\\[keep\\]" (harness-ui-btw-test--header buffer)))))))

(defun harness-ui-btw-test--click-header (window text)
  "Click mouse-1 on TEXT in the header line of WINDOW, as a user would."
  (let* ((header (with-current-buffer (window-buffer window) (harness-chat--header)))
         (pos (or (string-search text header) (error "No %S in the header line" text)))
         (command (lookup-key (get-text-property pos 'local-map header) [header-line mouse-1])))
    (should (commandp command))
    (funcall command (list 'mouse-1 (list window 'header-line '(0 . 0) 0)))))

(defmacro harness-ui-btw-test-choosing (choice &rest body)
  "Run BODY answering CHOICE when the permission mode is read.
Any other read fails: the session to change is never asked for."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (prompt &rest _)
                (if (string-prefix-p "Permission mode" prompt) ,choice (error "Unexpected read: %s" prompt)))))
     ,@body))

(defun harness-ui-btw-test--wait-mode (sid mode)
  "Wait until session SID is in permission MODE, a symbol, in the UI too."
  (harness-test-wait (lambda () (and (eq mode (plist-get (harness-call 'session/get sid) :permission-mode))
                                     (equal (symbol-name mode)
                                            (format "%s" (plist-get (harness-ui-session sid) :permission-mode)))))
                     5 (format "permission mode %s" mode)))

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
        ;; The board's header is fitted to its window, and this board
        ;; window is narrow: ask the view for the whole line.
        (should (string-match-p "\\[BTW\\]" (with-current-buffer board
                                             (harness-ui-tasks--header most-positive-fixnum)))))
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

(defun harness-ui-btw-test--converse (sid)
  "Give session SID a conversation: a question, an answer and a provider state.
Return (NODES . PROVIDER-STATE), SID's transcript and provider state then."
  (harness-call 'session/append sid (list :kind 'user :content "the main question"))
  (harness-call 'session/append sid (list :kind 'assistant :content "the main answer"))
  (harness-call 'session/set-provider-state sid '(:cli-session-id "main-cli" :model "m"))
  (cons (harness-call 'session/nodes sid) (plist-get (harness-call 'session/get sid) :provider-state)))

(defun harness-ui-btw-test--user-texts (sid)
  "Return the texts of the user messages of session SID."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq 'user (plist-get n :kind))) (harness-call 'session/nodes sid))))

(defun harness-ui-btw-test--buffer-text (buffer)
  "BUFFER's text, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-btw-test--session-list ()
  "Show the session list of `default-directory''s project; return its rows.
Each row is (DEPTH . ID), top to bottom, children right under their parent."
  (let ((done nil))
    (harness-ui-refresh-sessions (lambda (_) (setq done t)))
    (harness-test-wait (lambda () done) 5 "the session cache"))
  (cl-letf (((symbol-function 'harness-ui-display-view) #'ignore))
    (harness-sessions))
  (with-current-buffer harness-ui-sessions--buffer-name
    (mapcar (lambda (cell) (cons (car cell) (plist-get (cdr cell) :id))) (harness-ui-sessions--ordered))))

(ert-deftest harness-ui-btw-over-a-session-is-a-new-session ()
  "Over a session a BTW is a new, blank session listed under it, asked from its box.
It has nothing of the session's: no transcript, no provider state, and
the session keeps both as they were.  Closing returns to the session."
  (harness-ui-btw-test-with
    (pcase-let* ((`(,parent . ,parent-window) (harness-ui-btw-test--open-session))
                 (`(,nodes . ,state) (harness-ui-btw-test--converse parent)))
      (let* ((window (harness-ui-btw-test--open-btw parent-window #'harness-btw))
             (buffer (window-buffer window))
             (sid (buffer-local-value 'harness-ui-session-id buffer))
             (session (harness-call 'session/get sid)))
        (should-not (equal parent sid))
        (should (eq 'btw (plist-get session :kind)))
        (should (equal parent (plist-get session :parent-id)))
        (should (equal "btw" (plist-get session :name)))
        ;; Blank: nothing of the session's conversation, here or with the provider.
        (should-not (harness-call 'session/nodes sid))
        (should-not (plist-get session :fork-node))
        (should-not (plist-get session :provider-state))
        (should (string-match-p "BTW side conversation" (harness-ui-btw-test--header buffer)))
        (should (harness-ui-btw-test--ready-p window))
        (should-not (string-match-p "the main \\(?:question\\|answer\\)" (harness-ui-btw-test--buffer-text buffer)))
        (should (equal "Ask a side question\N{U+2026}" (harness-ui-btw-test--placeholder buffer)))
        (harness-ui-btw-test--ask window "what was that?")
        (harness-ui-btw-test--wait-reply sid)
        (harness-ui-btw-test--wait-name sid "btw: what was that?")
        (should (equal '("what was that?") (harness-ui-btw-test--user-texts sid)))
        (with-selected-window window (harness-ui-btw-close))
        (should (eq parent-window (selected-window)))
        (harness-test-wait (lambda () (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
                           5 "the BTW to be closed")
        (should (eq 'idle (plist-get (harness-call 'session/get parent) :status)))
        ;; The session is as it was.
        (should (equal nodes (harness-call 'session/nodes parent)))
        (should (equal state (plist-get (harness-call 'session/get parent) :provider-state)))
        ;; Its buffer stays, back to a session's own header: opened again
        ;; from the session list, it is a session like any.
        (with-current-buffer buffer
          (should-not harness-ui-btw-minor-mode)
          (should (harness-ui-btw-test--normal-header-p buffer)))
        (with-current-buffer (window-buffer parent-window)
          (should-not harness-ui-btw-minor-mode))))))

(ert-deftest harness-ui-btw-each-one-starts-fresh ()
  "Two BTWs in a row over one session are two new sessions, sharing nothing.
The second has nothing of the first: not its question, answer or
provider state, nor anything of the session's.  The session list shows
both under the session, which keeps its transcript and provider state."
  (harness-ui-btw-test-with
    (pcase-let* ((`(,parent . ,parent-window) (harness-ui-btw-test--open-session))
                 (`(,nodes . ,state) (harness-ui-btw-test--converse parent)))
      (let* ((window (harness-ui-btw-test--open-btw parent-window #'harness-btw))
             (first (buffer-local-value 'harness-ui-session-id (window-buffer window))))
        (should (harness-ui-btw-test--ready-p window))
        (harness-ui-btw-test--ask window "the first side question")
        (harness-ui-btw-test--wait-reply first)
        ;; As a provider keeping the conversation would have it.
        (harness-call 'session/set-provider-state first '(:cli-session-id "first-btw-cli"))
        (with-selected-window window (harness-ui-btw-close))
        (let* ((window (harness-ui-btw-test--open-btw parent-window #'harness-btw))
               (buffer (window-buffer window))
               (second (buffer-local-value 'harness-ui-session-id buffer))
               (session (harness-call 'session/get second)))
          (should-not (member second (list first parent)))
          (should (eq 'btw (plist-get session :kind)))
          (should (equal parent (plist-get session :parent-id)))
          (should-not (harness-call 'session/nodes second))
          (should-not (plist-get session :fork-node))
          (should-not (plist-get session :provider-state))
          (should (harness-ui-btw-test--ready-p window))
          (should-not (string-match-p "the first side question\\|the main question"
                                      (harness-ui-btw-test--buffer-text buffer)))
          (harness-ui-btw-test--ask window "the second side question")
          (harness-ui-btw-test--wait-reply second)
          ;; Each kept its own exchange, and the first its provider state.
          (should (equal '("the first side question") (harness-ui-btw-test--user-texts first)))
          (should (equal '("the second side question") (harness-ui-btw-test--user-texts second)))
          (should (equal '(:cli-session-id "first-btw-cli")
                         (plist-get (harness-call 'session/get first) :provider-state)))
          (should-not (plist-get (harness-call 'session/get second) :provider-state))
          (with-selected-window window (harness-ui-btw-close))
          (harness-test-wait (lambda () (eq 'inactive (plist-get (harness-call 'session/get second) :status)))
                             5 "the BTW to be closed")
          ;; Both are listed under the session, oldest first.
          (let* ((rows (harness-ui-btw-test--session-list))
                 (at (cl-position (cons 0 parent) rows :test #'equal)))
            (should at)
            (should (equal (list (cons 0 parent) (cons 1 first) (cons 1 second))
                           (seq-subseq rows at (min (length rows) (+ at 3))))))
          ;; And the session is as it was.
          (should (equal nodes (harness-call 'session/nodes parent)))
          (should (equal state (plist-get (harness-call 'session/get parent) :provider-state))))))))

(ert-deftest harness-ui-btw-has-the-full-chat-header ()
  "A BTW's header line is its session's own, the BTW segment in front.
The permission mode shows there, its parent's to begin with, and the
header, the key and the harness menu change it for the BTW alone, the
menu in a window of its own.  The thinking level is the BTW level, low,
whatever the parent's.  Closed, the BTW has the session's header and
nothing else."
  (harness-ui-btw-test-with
    (pcase-let ((`(,parent . ,parent-window) (harness-ui-btw-test--open-session)))
      (harness-call 'session/update parent :permission-mode 'accept-edits :thinking "high")
      (let* ((window (harness-ui-btw-test--open-btw parent-window #'harness-btw))
             (buffer (window-buffer window))
             (sid (buffer-local-value 'harness-ui-session-id buffer)))
        (should (harness-ui-btw-test--ready-p window))
        (harness-ui-btw-test--wait-mode sid 'accept-edits)
        (should (equal "low" (plist-get (harness-call 'session/get sid) :thinking)))
        ;; The chat's own header line, after the BTW segment.
        (should (equal '(:eval (harness-chat--header)) (buffer-local-value 'header-line-format buffer)))
        (let ((own (harness-ui-btw-test--own-full-header buffer)))
          (should (equal (concat " BTW side conversation  [close] [keep] " own)
                         (harness-ui-btw-test--full-header buffer)))
          (dolist (segment (list "btw" "scripted (Demo)" "Accept Edits"
                                 (substring-no-properties (harness-ui-thinking-label "low")) "[menu]"))
            (should (string-search segment own))))
        ;; mouse-1 on the permission mode, from the parent's window.
        (select-window parent-window)
        (harness-ui-btw-test-choosing "Auto"
          (harness-ui-btw-test--click-header window "Accept Edits"))
        (harness-ui-btw-test--wait-mode sid 'auto)
        (should (string-search "  Auto  " (harness-ui-btw-test--full-header buffer)))
        ;; The key that sets it, as in any session.
        (with-selected-window window
          (let ((key (where-is-internal #'harness-set-permission-mode nil t)))
            (should key)
            (harness-ui-btw-test-choosing "YOLO"
              (call-interactively (key-binding key)))))
        (harness-ui-btw-test--wait-mode sid 'yolo)
        ;; The harness menu opens in a window of its own, below the BTW,
        ;; whose height and buffer stay as they were.
        (let ((edges (mapcar #'window-pixel-edges (window-list nil 'nomini (frame-first-window))))
              (height (window-pixel-height window)))
          (with-selected-window window
            (call-interactively #'harness-menu)
            (let ((menu (get-buffer-window transient--buffer-name)))
              (should (window-live-p menu))
              (should-not (eq window menu))
              (should (eq 'bottom (window-parameter menu 'window-side)))
              (should (eq menu (window-in-direction 'below window t)))
              (should (= height (window-pixel-height window)))
              (should (eq buffer (window-buffer window))))
            (harness-ui-btw-test-choosing "Ask"
              (execute-kbd-macro (kbd "p"))))
          (harness-ui-btw-test--wait-mode sid 'ask)
          (should-not (get-buffer-window transient--buffer-name))
          ;; Closed, it leaves every window where it was.
          (should (equal edges (mapcar #'window-pixel-edges (window-list nil 'nomini (frame-first-window))))))
        (should (eq buffer (window-buffer window)))
        (should (eq 'accept-edits (plist-get (harness-call 'session/get parent) :permission-mode)))
        ;; [close]: changed, the BTW is not blank any more; it is closed and
        ;; its buffer shows the session's own header.
        (select-window parent-window)
        (harness-ui-btw-test--click-header window "[close]")
        (should-not (window-live-p window))
        (harness-test-wait (lambda () (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
                           5 "the BTW to be closed")
        (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-btw-minor-mode buffer)))
                           5 "the BTW mode to be off")
        (should (harness-ui-btw-test--normal-header-p buffer))))))

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

(ert-deftest harness-ui-btw-each-board-btw-is-a-new-conversation ()
  "Every BTW over the board starts a new conversation, never an earlier one."
  (harness-ui-btw-test-with
    (let* ((board (harness-ui-btw-test--board))
           (board-window (get-buffer-window board))
           (window (harness-ui-btw-test--open-btw board-window #'harness-ui-tasks-btw))
           (first (buffer-local-value 'harness-ui-session-id (window-buffer window))))
      (should (harness-ui-btw-test--ready-p window))
      (harness-ui-btw-test--ask window "how are the tasks going?")
      (harness-ui-btw-test--wait-reply first)
      (with-selected-window window (harness-ui-btw-close))
      (let* ((window (harness-ui-btw-test--open-btw board-window #'harness-ui-tasks-btw))
             (buffer (window-buffer window))
             (second (buffer-local-value 'harness-ui-session-id buffer))
             (session (harness-call 'session/get second)))
        (should-not (equal first second))
        (should (eq 'btw (plist-get session :kind)))
        (should-not (plist-get session :parent-id))
        (should-not (harness-call 'session/nodes second))
        (should-not (plist-get session :provider-state))
        (should (harness-ui-btw-test--ready-p window))
        (should-not (string-match-p "how are the tasks going" (harness-ui-btw-test--buffer-text buffer)))
        (should (equal '("how are the tasks going?") (harness-ui-btw-test--user-texts first)))
        (with-selected-window window (harness-ui-btw-close))
        (harness-ui-btw-test--wait-gone second buffer)))))

(ert-deftest harness-ui-btw-keep-makes-a-normal-session-window ()
  "Keeping a BTW, with its [keep] button, shows it where it was opened.
It has the session's own header there, with nothing of the BTW left.
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
        ;; Clicked from the parent's window, it keeps the BTW all the same.
        (select-window parent-window)
        (harness-ui-btw-test--click-header window "[keep]")
        (should-not (window-live-p window))
        ;; It took the parent's place on the right, once, as a session.
        (should (eq buffer (window-buffer parent-window)))
        (should (equal (list parent-window) (get-buffer-window-list buffer nil t)))
        (with-current-buffer buffer
          (should-not harness-ui-btw-minor-mode)
          (should (harness-ui-btw-test--normal-header-p buffer)))
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

(ert-deftest harness-ui-btw-from-the-tree-is-a-new-session-under-the-node-s ()
  "b on a node of the tree opens a blank BTW over the node's session, over the tree.
Like any BTW it is a new session listed under that session, sharing
nothing with it: the node only says which session, whose head never
moves.  The tree shows the BTW, still empty, at the top."
  (harness-ui-btw-test-with
    (let* ((sid (plist-get (harness-call 'session/create :cwd default-directory :model "demo:scripted" :name "Main")
                           :id))
           (n1 (plist-get (harness-call 'session/append sid (list :kind 'user :content "first question")) :id))
           (n2 (plist-get (harness-call 'session/append sid (list :kind 'assistant :content "first answer")) :id))
           (moves nil))
      (harness-on 'session/head-moved (lambda (id node) (push (cons id node) moves)))
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
          (should-not (equal sid btw))
          (should (eq 'btw (plist-get session :kind)))
          (should (equal sid (plist-get session :parent-id)))
          (should-not (plist-get session :fork-node))
          (should-not (harness-call 'session/nodes btw))
          (should (harness-ui-btw-test--ready-p window))
          (should-not (string-match-p "first \\(?:question\\|answer\\)" (harness-ui-btw-test--buffer-text buffer)))
          ;; The session's head stayed put.
          (should (equal n2 (plist-get (harness-call 'session/get sid) :head)))
          (should-not moves)
          ;; The tree shows the BTW in its family, blank, as its newest row.
          (harness-test-wait (lambda () (with-current-buffer tree
                                          (and (member btw harness-ui-tree--family) (not harness-ui-tree--loading))))
                             5 "the tree to show the BTW")
          (should (equal (concat "session:" btw)
                         (plist-get (plist-get (car (buffer-local-value 'harness-ui-tree--rows tree)) :node) :id)))
          ;; Closed unused, back to the tree.
          (with-selected-window window (harness-ui-btw-close))
          (should (eq tree-window (selected-window)))
          (harness-ui-btw-test--wait-gone btw buffer))))))

(provide 'harness-ui-btw-test)
;;; harness-ui-btw-test.el ends here
