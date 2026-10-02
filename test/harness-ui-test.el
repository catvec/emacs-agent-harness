;;; harness-ui-test.el --- Tests for the UI foundation  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)

(defmacro harness-ui-test-with-layout (&rest body)
  "Run BODY with \"other\" in the main window and a session in a right side window.
The side window is selected and not dedicated, as Doom leaves it."
  (declare (indent 0))
  `(let ((other (get-buffer-create "other"))
         (chat (get-buffer-create "*harness: test*"))
         (menu (get-buffer-create " *harness-test-menu*"))
         (split-width-threshold 160)
         (split-height-threshold nil)
         (transient-display-buffer-action
          '(display-buffer-below-selected (dedicated . t) (inhibit-same-window . t))))
     (unwind-protect
         (progn
           (delete-other-windows)
           (switch-to-buffer other)
           (select-window (display-buffer-in-side-window chat '((side . right) (window-width . 0.45))))
           (set-window-dedicated-p nil nil)
           ,@body)
       (mapc #'kill-buffer (list other chat menu))
       (ignore-errors (delete-other-windows)))))

(ert-deftest harness-ui-menu-from-side-window-leaves-other-windows-alone ()
  (harness-ui-test-with-layout
    (let* ((other-window (get-buffer-window other))
           (width (window-total-width other-window))
           (window (harness-ui--display-menu menu '((inhibit-same-window . t)))))
      (should (eq 'bottom (window-parameter window 'window-side)))
      (should (eq other (window-buffer other-window)))
      (should (= width (window-total-width other-window)))
      (delete-window window)
      (should (eq other (window-buffer other-window))))))

(ert-deftest harness-ui-menu-from-main-window-follows-transient-action ()
  (harness-ui-test-with-layout
    (select-window (get-buffer-window other))
    (let ((window (harness-ui--display-menu menu '((inhibit-same-window . t)))))
      (should-not (window-parameter window 'window-side))
      (should (eq window (window-in-direction 'below (get-buffer-window other)))))))

;;;; The menu lists the commands of the buffer it is opened from

(require 'harness-ui-chat)
(require 'harness-ui-tasks)
(require 'harness-ui-sessions)
(require 'harness-ui-tree)
(require 'harness-ui-worktree)
(require 'harness-ui-usage)
(require 'harness-ui-dirs)
(require 'harness-ui-btw)
(require 'harness-ui-media)

(defvar harness-ui-test-ran nil "Commands the menu ran, newest first: (COMMAND BUFFER POINT).")

(define-derived-mode harness-ui-test-board-mode special-mode "Test board"
  "A board for the menu tests.")

(define-minor-mode harness-ui-test-minor-mode
  "A minor mode for the menu tests."
  :lighter nil)

(defun harness-ui-test-start ()
  "Record that the menu ran this here."
  (interactive)
  (push (list 'start (current-buffer) (point)) harness-ui-test-ran))

(defun harness-ui-test-submit ()
  "Record that the menu ran this here."
  (interactive)
  (push (list 'submit (current-buffer) (point)) harness-ui-test-ran))

(defun harness-ui-test-close ()
  "Record that the menu ran this here."
  (interactive)
  (push (list 'close (current-buffer) (point)) harness-ui-test-ran))

(defconst harness-ui-test-menu-modes
  '(harness-ui-test-board-mode harness-ui-test-minor-mode fundamental-mode)
  "Modes whose `harness-menu-group' the menu tests set.")

(defmacro harness-ui-test-with-menu-groups (&rest body)
  "Run BODY, then put back the `harness-menu-group' of the test modes."
  (declare (indent 0))
  `(let ((harness-ui-test--saved-groups
          (mapcar (lambda (mode) (cons mode (get mode 'harness-menu-group))) harness-ui-test-menu-modes)))
     (unwind-protect (progn ,@body)
       (pcase-dolist (`(,mode . ,group) harness-ui-test--saved-groups)
         (put mode 'harness-menu-group group)))))

(defmacro harness-ui-test-with-menu-buffer (mode &rest body)
  "Run BODY in a new buffer in MODE (a function) shown in the selected window.
The menu groups BODY gives the test modes are taken back afterwards."
  (declare (indent 1))
  `(harness-ui-test-with-menu-groups
     (let ((buffer (generate-new-buffer "*harness menu test*"))
           (harness-ui-test-ran nil))
       (unwind-protect
           (progn (delete-other-windows)
                  (switch-to-buffer buffer)
                  (funcall ,mode)
                  ,@body)
         (kill-buffer buffer)))))

(defun harness-ui-test-menu-groups ()
  "Return every (MODE TITLE . COLUMNS) the UI modules give `harness-menu'."
  (let (groups)
    (mapatoms (lambda (mode)
                (when-let* ((group (get mode 'harness-menu-group)))
                  (push (cons mode group) groups))))
    groups))

(defun harness-ui-test-menu (&optional keys)
  "Open `harness-menu' here and return its text, then type KEYS in it.
KEYS default to C-g, which closes the menu."
  (call-interactively #'harness-menu)
  (prog1 (with-current-buffer transient--buffer-name
           (buffer-substring-no-properties (point-min) (point-max)))
    (execute-kbd-macro (kbd (or keys "C-g")))))

(ert-deftest harness-ui-menu-elsewhere-shows-only-its-own-groups ()
  (harness-ui-test-with-menu-buffer #'fundamental-mode
    (let ((text (harness-ui-test-menu)))
      (should (string-match-p "Sessions" text))
      (should (string-match-p "Session settings" text))
      (should (string-match-p "Tools" text))
      (should-not (string-match-p "^ *\\. \\|C-c C-" text))
      (pcase-dolist (`(,_mode ,title . ,_columns) (harness-ui-test-menu-groups))
        (should-not (string-match-p (concat "^" (regexp-quote title) "$") text))))
    (should-not transient--prefix)))

(ert-deftest harness-ui-menu-shows-the-chat-commands-in-a-chat ()
  (harness-ui-test-with-menu-buffer #'harness-chat-mode
    (let ((text (harness-ui-test-menu)))
      (should (string-match-p "^Chat$" text))
      (should (string-match-p "C-c C-c +Send" text))
      (should (string-match-p "C-c C-q +Queue for next turn" text))
      (should (string-match-p "C-c C-k +Cancel turn" text))
      (should (string-match-p "C-c C-a +Attach file" text))
      (should-not (string-match-p "Task board" text)))))

(ert-deftest harness-ui-menu-in-a-btw-shows-its-keys-over-the-chats ()
  "In a BTW, C-c C-k closes it, in the buffer and so in the menu."
  (harness-ui-test-with-menu-buffer (lambda () (harness-chat-mode) (harness-ui-btw-minor-mode 1))
    (let ((text (harness-ui-test-menu)))
      (should (string-match-p "^Chat .* BTW$" text))
      (should (string-match-p "C-c C-k +Close" text))
      (should-not (string-match-p "C-c C-k +Cancel turn" text))
      (should (string-match-p "C-c C-c +Send" text)))))

(ert-deftest harness-ui-menu-shows-the-board-commands-on-the-task-board ()
  (harness-ui-test-with-menu-buffer #'harness-ui-tasks-mode
    (let ((text (harness-ui-test-menu)))
      (should (string-match-p "^Task board$" text))
      (should (string-match-p "\\. s +Start now" text))
      (should (string-match-p "\\. RET +Open its session" text))
      (should (string-match-p "C-c C-c +Submit" text))
      (should-not (string-match-p "^Chat$" text)))))

(ert-deftest harness-ui-menu-runs-buffer-commands-in-the-buffer ()
  "A buffer command chosen in the menu runs there, with point where it was."
  (harness-ui-test-with-menu-buffer #'harness-ui-test-board-mode
    (put 'harness-ui-test-board-mode 'harness-menu-group
         '("Test board"
           ["At point" (". s" "Start" harness-ui-test-start)]
           ["Box" ("C-c C-c" "Submit" harness-ui-test-submit)]))
    (let ((inhibit-read-only t)) (insert "one\ntwo\nthree\n"))
    (goto-char 6)
    (let ((text (harness-ui-test-menu ". s")))
      (should (string-match-p "^Test board$" text))
      (should (string-match-p "^At point +Box *$" text)))
    (harness-ui-test-menu "C-c C-c")
    (should (equal (list (list 'start buffer 6) (list 'submit buffer 6)) (reverse harness-ui-test-ran)))
    (should-not transient--prefix)))

(ert-deftest harness-ui-menu-leaves-out-buffer-commands-it-cannot-offer ()
  "Keys of the menu's own groups, undefined commands and keys shadowed
by a minor mode are left out; a mode left with nothing is not named."
  (harness-ui-test-with-menu-buffer (lambda () (harness-ui-test-board-mode) (harness-ui-test-minor-mode 1))
    (put 'harness-ui-test-board-mode 'harness-menu-group
         '("Test board"
           ["At point"
            (". s" "Start" harness-ui-test-start)
            ("s" "Taken by Switch session" harness-ui-test-start)
            ("C-c C-k" "Shadowed by the minor mode" harness-ui-test-submit)
            (". u" "Undefined" harness-ui-test-no-such-command)]))
    (put 'harness-ui-test-minor-mode 'harness-menu-group
         '("Test minor" ["Minor" ("C-c C-k" "Close" harness-ui-test-close)]))
    (put 'fundamental-mode 'harness-menu-group
         '("Not this buffer" ["Elsewhere" ("C-c C-e" "Elsewhere" harness-ui-test-start)]))
    (let ((text (harness-ui-test-menu "C-c C-k")))
      (should (string-match-p "^Test board .* Test minor$" text))
      (should (string-match-p "\\. s +Start" text))
      (should (string-match-p "C-c C-k +Close" text))
      (should-not (string-match-p "Taken by\\|Shadowed\\|Undefined\\|Elsewhere\\|Not this buffer" text)))
    (should (equal (list (list 'close buffer (point))) harness-ui-test-ran))
    ;; With every command left out, the mode is not named either.
    (harness-ui-test-minor-mode -1)
    (put 'harness-ui-test-board-mode 'harness-menu-group
         '("Test board" ["At point" ("s" "Taken by Switch session" harness-ui-test-start)]))
    (should-not (string-match-p "Test board\\|At point" (harness-ui-test-menu)))))

(ert-deftest harness-ui-menu-registrations-teach-the-buffers-keys ()
  "Every registered command is offered under the key it has in its buffer:
a chord as it is, a plain key behind `.', which the menu's own groups
leave free.  None is left out by the menu."
  (should-not (harness-ui--menu-key-taken-p "."))
  (pcase-dolist (`(,mode ,_title . ,columns) (harness-ui-test-menu-groups))
    (let ((maps (delq nil (list (let ((map (intern (format "%s-map" mode)))) (and (boundp map) (symbol-value map)))
                                (and (eq mode 'harness-ui-tasks-mode) harness-ui-tasks-board-map))))
          (keys nil))
      (dolist (column columns)
        (dolist (item (append column nil))
          (when (and (consp item) (stringp (car item)))
            (let* ((key (key-description (kbd (car item))))
                   (command (nth 2 item))
                   (events (kbd key))
                   (dotted (equal "." (key-description (substring events 0 1))))
                   (own (if dotted (substring events 1) events)))
              (ert-info ((format "%s: %s %s" mode key command))
                (should (commandp command))
                (should-not (member key keys))
                (push key keys)
                (should-not (harness-ui--menu-key-taken-p key))
                ;; Behind `.' one plain key; otherwise a chord, never a plain key.
                (if dotted
                    (should (= 2 (length events)))
                  (should (memq 'control (event-modifiers (aref events 0)))))
                (should (cl-some (lambda (map) (eq command (lookup-key map own))) maps)))))))))
  ;; What every harness buffer offers is checked above; here, that each mode is there.
  (dolist (mode '(harness-chat-mode harness-ui-tasks-mode harness-ui-sessions-mode harness-ui-tree-mode
                  harness-ui-worktree-mode harness-ui-usage-mode harness-ui-dirs-mode
                  harness-ui-btw-minor-mode harness-ui-media-recording-mode))
    (should (get mode 'harness-menu-group))))

(ert-deftest harness-ui-menu-with-buffer-commands-from-a-side-window ()
  "From a session's side window the menu, buffer commands included, gets a
bottom side window and leaves the other windows alone."
  (harness-ui-test-with-layout
    (harness-ui-test-with-menu-groups
      (with-current-buffer chat
        (harness-ui-test-board-mode)
        (put 'harness-ui-test-board-mode 'harness-menu-group
             '("Test board" ["At point" (". s" "Start" harness-ui-test-start)])))
      (let* ((other-window (get-buffer-window other))
             (width (window-total-width other-window)))
        (call-interactively #'harness-menu)
        (unwind-protect
            (let ((window (get-buffer-window transient--buffer-name)))
              (should (eq 'bottom (window-parameter window 'window-side)))
              (should (eq other (window-buffer other-window)))
              (should (= width (window-total-width other-window)))
              (with-current-buffer transient--buffer-name
                (should (string-match-p "^Test board$" (buffer-string)))
                (should (string-match-p "\\. s +Start" (buffer-string)))))
          (execute-kbd-macro (kbd "C-g")))
        (should (eq other (window-buffer other-window)))
        (should-not (get-buffer-window transient--buffer-name))))))

;;;; Views share positions with sessions

(defvar harness-ui--position-buffers)
(defvar harness-ui-open-session-function)

(defmacro harness-ui-test-with-views (&rest body)
  "Run BODY with buffers `session', `other-session' and `view' and a fresh layout."
  (declare (indent 0))
  `(let ((session (get-buffer-create "*harness: view test*"))
         (other-session (get-buffer-create "*harness: view test 2*"))
         (view (get-buffer-create "*harness view test*"))
         (harness-ui-default-position 'right))
     (unwind-protect
         (progn
           (clrhash harness-ui--position-buffers)
           (delete-other-windows)
           (switch-to-buffer (get-buffer-create "*scratch*"))
           ,@body)
       (mapc #'kill-buffer (list session other-session view))
       (clrhash harness-ui--position-buffers)
       (ignore-errors (delete-other-windows)))))

(ert-deftest harness-ui-view-and-session-replace-each-other ()
  (harness-ui-test-with-views
    (harness-ui-display-buffer session 'right)
    (let ((window (get-buffer-window session)))
      (harness-ui-display-view view)
      (should (eq view (window-buffer window)))
      (should-not (get-buffer-window session))
      (harness-ui-display-buffer session 'right)
      (should (eq session (window-buffer window)))
      (should-not (get-buffer-window view)))))

(ert-deftest harness-ui-view-returns-to-its-last-position ()
  (harness-ui-test-with-views
    (harness-ui-display-view view 'left)
    (should (eq 'left (buffer-local-value 'harness-ui-position view)))
    (harness-ui-display-buffer session 'left)
    (should-not (get-buffer-window view))
    (harness-ui-display-view view)
    (should (eq 'left (buffer-local-value 'harness-ui-position view)))
    (should (eq (get-buffer-window view) (window-in-direction 'left (get-buffer-window "*scratch*"))))))

(ert-deftest harness-ui-session-opener-replaces-the-view ()
  (harness-ui-test-with-views
    (let ((harness-ui-open-session-function (lambda (_id) other-session)))
      (harness-ui-display-view view 'left)
      (let ((window (get-buffer-window view))
            (open (with-current-buffer view (harness-ui-session-opener))))
        ;; Called later from somewhere else, it still opens in the view's place.
        (select-window (get-buffer-window "*scratch*"))
        (funcall open "sid")
        (should (eq other-session (window-buffer window)))
        (should (eq window (selected-window)))
        (should-not (get-buffer-window view))))))

(ert-deftest harness-ui-unowned-requests-stay-pending-without-prompting ()
  "A question or permission no buffer owns is declined, never prompted for."
  (let (responses (harness-ui-question-functions nil) (harness-ui-permission-functions nil))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (error "Prompted")))
              ((symbol-function 'read-string) (lambda (&rest _) (error "Prompted")))
              ((symbol-function 'read-multiple-choice) (lambda (&rest _) (error "Prompted"))))
      (harness-ui--dispatch "_harness/ask_user" '(:sessionId "s1" :requestId "q1" :question "Which?" :options ["a" "b"])
                            (lambda (r) (push r responses)))
      (harness-ui--dispatch "session/request_permission" '(:sessionId "s1" :toolCall (:title "bash"))
                            (lambda (r) (push r responses))))
    (should (= 2 (length responses)))
    (should-not (cl-some (lambda (r) (plist-get r :answer)) responses))
    (should-not (cl-some (lambda (r) (plist-get r :outcome)) responses))))

(ert-deftest harness-ui-permission-mode-labels-and-picker-order ()
  (should (equal "Ask" (harness-ui-permission-mode-label nil)))
  (should (equal "Accept Edits" (harness-ui-permission-mode-label 'accept-edits)))
  (should (equal "YOLO" (harness-ui-permission-mode-label "yolo")))
  (let (offered sent)
    (cl-letf (((symbol-function 'harness-ui-current-session-id) (lambda () "s1"))
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (setq offered (list (all-completions "" table)
                                     (completion-metadata-get (completion-metadata "" table nil)
                                                              'display-sort-function)))
                 "Accept Edits"))
              ((symbol-function 'harness-ui-call) (lambda (_method params &rest _) (setq sent params))))
      (harness-set-permission-mode))
    (should (equal '("Ask" "Accept Edits" "Auto" "YOLO") (car offered)))
    (should (eq 'identity (cadr offered)))
    (should (equal "accept-edits" (plist-get sent :modeId)))))

;;;; Connecting to another harness

(defmacro harness-ui-test-with-connect-stub (var &rest body)
  "Run BODY with `harness-ui-connect' recording each address into VAR, oldest first."
  (declare (indent 1))
  `(let ((,var nil) (harness-ui-redraw-hook nil))
     (cl-letf (((symbol-function 'harness-ui-connect)
                (lambda (&optional address) (setq ,var (append ,var (list address))) nil)))
       ,@body)))

(ert-deftest harness-ui-connect-remote-prompt-takes-only-an-address ()
  "The prompt starts from the remote address in use, never from the
`process' or nil that stand for a local harness."
  (harness-ui-test-with-connect-stub connected
    (dolist (case '((process . nil) (nil . nil) ("example.org:9000" . "example.org:9000")))
      (let ((harness-ui-connection-address (car case))
            (initial 'unset))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (_prompt &optional init &rest _)
                     ;; What the real `read-string' accepts as INITIAL-INPUT.
                     (unless (or (null init) (stringp init) (consp init))
                       (signal 'wrong-type-argument (list 'stringp init)))
                     (setq initial init)
                     "127.0.0.1:9000")))
          (call-interactively #'harness-connect-remote))
        (should (equal (cdr case) initial))))
    (should (equal '("127.0.0.1:9000" "127.0.0.1:9000" "127.0.0.1:9000") connected))))

(ert-deftest harness-ui-connect-remote-empty-is-the-local-harness ()
  "No address goes back to this Emacs's own harness, wherever it runs."
  (harness-ui-test-with-connect-stub connected
    (let ((harness-process t)) (harness-connect-remote ""))
    (let ((harness-process nil)) (harness-connect-remote "  "))
    (let ((harness-process nil)) (harness-connect-remote nil))
    (harness-connect-remote " 127.0.0.1:9000 ")
    (should (equal '(process nil nil "127.0.0.1:9000") connected))))

(provide 'harness-ui-test)
;;; harness-ui-test.el ends here
