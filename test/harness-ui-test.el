;;; harness-ui-test.el --- Tests for the UI foundation  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)

;; The tasks module's cap: declared here so that the context limit test
;; can bind it, the way a task's session is capped.
(defvar harness-tasks-context-limit 256000)

(defmacro harness-ui-test-with-layout (&rest body)
  "Run BODY with \"other\" in the main window and a session in a right side window.
The side window is selected and not dedicated, as Doom leaves it.  The
echo area keeps its height while BODY runs: on a graphic frame, a long
message from an earlier test can leave it two lines high, and emptied
in BODY, it would give the windows above its second line."
  (declare (indent 0))
  `(let ((other (get-buffer-create "other"))
         (chat (get-buffer-create "*harness: test*"))
         (menu (get-buffer-create " *harness-test-menu*"))
         (resize-mini-windows nil)
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

(defun harness-ui-test--layout ()
  "Return each window of the frame with its buffer, pixel edges and kept size."
  (mapcar (lambda (window)
            (list window (window-buffer window) (window-pixel-edges window)
                  (window-parameter window 'window-preserved-size)))
          (window-list nil 'nomini (frame-first-window))))

(defun harness-ui-test--btw-window (btw)
  "Show BTW at the bottom as `harness-btw' shows a BTW and return its window."
  (display-buffer-in-side-window
   btw '((side . bottom) (slot . 1) (window-height . 0.2) (preserve-size . (nil . t)))))

(ert-deftest harness-ui-menu-with-a-window-at-the-bottom-goes-below-it ()
  "With a window at the bottom, as a BTW's, the menu from a side window
goes below it, as wide as the frame, in a window of its own: at the
bottom, where it opens without a BTW, never above everything.  The BTW
keeps its height, the menu's lines coming from the windows above, and
closed, the menu leaves every window as it was.  In the BTW's slot it
would show in its place, and transient would delete the window as the
menu closes; beside it, it would get its height only."
  (harness-ui-test-with-layout
    (let* ((btw (get-buffer-create " *harness-test-btw*"))
           (btw-window (harness-ui-test--btw-window btw)))
      (with-current-buffer menu
        (insert "Sessions\n n New session\n s Switch session\n f Fork session\n"))
      (unwind-protect
          ;; From the BTW, and from the session it was opened over.
          (dolist (from (list btw-window (get-buffer-window chat)))
            (select-window from)
            (let* ((before (harness-ui-test--layout))
                   (height (window-pixel-height btw-window))
                   (main-height (window-pixel-height (get-buffer-window other)))
                   (window (harness-ui--display-menu menu '((inhibit-same-window . t)))))
              (should (eq 'bottom (window-parameter window 'window-side)))
              (should (eq window (window-in-direction 'below btw-window t)))
              (should (= (window-total-width (frame-root-window)) (window-total-width window)))
              (should (= (nth 3 (window-pixel-edges (frame-root-window)))
                         (nth 3 (window-pixel-edges window))))
              (should (eq menu (window-buffer window)))
              (should (eq from (selected-window)))
              ;; Four lines and the mode line, from the windows above.
              (should (= 5 (window-total-height window)))
              (should (eq btw (window-buffer btw-window)))
              (should (= height (window-pixel-height btw-window)))
              (should (= (window-pixel-height window)
                         (- main-height (window-pixel-height (get-buffer-window other)))))
              (delete-window window)
              (should-not (window-live-p window))
              (should (equal before (harness-ui-test--layout)))))
        (kill-buffer btw)))))

(ert-deftest harness-ui-menu-below-a-btw-puts-every-window-back ()
  "Opened over a BTW from a side window, the menu fits its window below
the BTW to its text with the lines of the windows above, and closed
with C-g, it leaves every window as it was.  Closed by one of its
commands, it does too: `harness-ui-btw-has-the-full-chat-header'."
  (harness-ui-test-with-layout
    (let* ((btw (get-buffer-create " *harness-test-btw*"))
           (btw-window (harness-ui-test--btw-window btw))
           (height (window-pixel-height btw-window)))
      (unwind-protect
          (dolist (from (list (get-buffer-window chat) btw-window))
            (select-window from)
            (let ((before (harness-ui-test--layout)))
              (call-interactively #'harness-menu)
              (unwind-protect
                  (let ((window (get-buffer-window transient--buffer-name)))
                    (should (eq window (window-in-direction 'below btw-window t)))
                    (should (= (window-total-width (frame-root-window)) (window-total-width window)))
                    (should (= height (window-pixel-height btw-window)))
                    ;; Tall enough for all of the menu.  In pixels: on a
                    ;; graphic frame transient draws the line under the
                    ;; menu a pixel high, so the last line of the window
                    ;; is a pixel high too.  On a text terminal a pixel is
                    ;; a line, and the lines are the menu's own, as
                    ;; `harness-ui--menu-height' counts them there: a batch
                    ;; frame is 80 columns wide, and the menu's longest
                    ;; lines wrap in it.
                    (should (<= (if (display-graphic-p)
                                    (cdr (window-text-pixel-size window))
                                  (with-current-buffer transient--buffer-name
                                    (count-lines (point-min) (point-max))))
                                (window-body-height window t))))
                (execute-kbd-macro (kbd "C-g")))
              (should-not (get-buffer-window transient--buffer-name))
              (should (equal before (harness-ui-test--layout)))
              (should (eq from (selected-window)))))
        (kill-buffer btw)))))

(ert-deftest harness-ui-menu-goes-below-a-popup-that-splits-another-window ()
  "A Doom popup at the bottom has a `split-window' parameter that splits
another window instead of it.  The menu goes below the popup all the
same, and leaves every window as it was."
  (harness-ui-test-with-layout
    (let* ((help (get-buffer-create " *harness-test-help*"))
           (popup (display-buffer-in-side-window help '((side . bottom) (slot . 0) (window-height . 0.2)))))
      (set-window-parameter popup 'split-window
                            (lambda (_window size side)
                              (let ((ignore-window-parameters t))
                                (split-window (get-buffer-window other) size side))))
      (unwind-protect
          (let* ((before (harness-ui-test--layout))
                 (window (harness-ui--display-menu menu '((inhibit-same-window . t)))))
            (should (eq window (window-in-direction 'below popup t)))
            (should (eq 'bottom (window-parameter window 'window-side)))
            (should (= (window-total-width (frame-root-window)) (window-total-width window)))
            (delete-window window)
            (should (equal before (harness-ui-test--layout))))
        (kill-buffer help)))))

(ert-deftest harness-ui-menu-with-windows-sharing-the-bottom-goes-to-the-top ()
  "With several windows at the bottom, below one of which a window would
not be a valid side window, the menu from a side window goes to the
top, whole, and leaves them as they were."
  (harness-ui-test-with-layout
    (let* ((btw (get-buffer-create " *harness-test-btw*"))
           (bottom (get-buffer-create " *harness-test-bottom*"))
           (windows (list (display-buffer-in-side-window bottom '((side . bottom) (slot . 0)))
                          (harness-ui-test--btw-window btw)))
           (edges (mapcar #'window-edges windows)))
      (unwind-protect
          (let ((window (harness-ui--display-menu menu '((inhibit-same-window . t)))))
            (should (eq 'top (window-parameter window 'window-side)))
            (should (= (window-total-width (frame-root-window)) (window-total-width window)))
            (should (eq menu (window-buffer window)))
            (should (equal (list bottom btw) (mapcar #'window-buffer windows)))
            (should (equal edges (mapcar #'window-edges windows)))
            (delete-window window)
            (should (equal edges (mapcar #'window-edges windows))))
        (mapc #'kill-buffer (list btw bottom))))))

(ert-deftest harness-ui-menu-from-main-window-follows-transient-action ()
  (harness-ui-test-with-layout
    (select-window (get-buffer-window other))
    (let ((window (harness-ui--display-menu menu '((inhibit-same-window . t)))))
      (should-not (window-parameter window 'window-side))
      (should (eq window (window-in-direction 'below (get-buffer-window other)))))))

;;;; The menu lists the commands of the buffer it is opened from

(require 'harness-ui-chat)
(require 'harness-ui-tasks)
(require 'harness-ui-slots)
(require 'harness-ui-sessions)
(require 'harness-ui-tree)
(require 'harness-ui-worktree)
(require 'harness-ui-usage)
(require 'harness-ui-access)
(require 'harness-ui-btw)
(require 'harness-ui-media)
(require 'harness-ui-review)
(require 'harness-ui-version)

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

(defun harness-ui-test--suffix-plist (suffix)
  "Return the properties of SUFFIX, a suffix of a transient layout.
Transient 0.8 and later write it (CLASS . PLIST), earlier ones (LEVEL
CLASS PLIST)."
  (if (keywordp (cadr suffix)) (cdr suffix) (car (last suffix))))

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

(ert-deftest harness-ui-menu-offers-deleting-a-budget ()
  "Deleting a budget is in the menu from any buffer, not only the dashboard,
whose own group says d deletes the budget at point."
  (harness-ui-test-with-menu-buffer #'fundamental-mode
    (should (string-match-p "B +Delete budget" (harness-ui-test-menu))))
  (harness-ui-test-with-menu-buffer #'harness-ui-usage-mode
    (let ((text (harness-ui-test-menu)))
      (should (string-match-p "B +Delete budget" text))
      (should (string-match-p "\\. d +Delete budget (or fallback) at point" text)))))

(ert-deftest harness-ui-menu-offers-the-supervisor-all-command-only-when-there ()
  "The menu's V turns supervisor mode on or off for every session, beside
the other for-all-sessions entries; a harness without the supervisor UI
module leaves the entry out, so the menu is unharmed."
  (harness-ui-test-with-menu-buffer #'fundamental-mode
    ;; The UI here does not load ui-supervisor, so there is nothing to offer.
    (should-not (fboundp 'harness-set-supervisor-all))
    (should-not (string-match-p "Supervisor mode for all sessions" (harness-ui-test-menu)))
    (unwind-protect
        (progn
          (require 'harness-ui-supervisor)
          (should (string-match-p "V +Supervisor mode for all sessions" (harness-ui-test-menu))))
      ;; Loaded only for this test: leave the UI as it was, unbound.
      (fmakunbound 'harness-set-supervisor-all))))

(ert-deftest harness-ui-menu-shows-the-chat-commands-in-a-chat ()
  (harness-ui-test-with-menu-buffer #'harness-chat-mode
    (let ((text (harness-ui-test-menu)))
      (should (string-match-p "^Chat$" text))
      (should (string-match-p "C-c C-c +Send" text))
      (should (string-match-p "C-c C-q +Queue for next turn" text))
      (should (string-match-p "C-c C-k +Cancel turn" text))
      (should (string-match-p "C-c C-a +Attach file or task" text))
      ;; Pasting is C-y; C-c C-v is the review banner's [Verify].
      (should (string-match-p "C-y +Paste; an image attaches" text))
      (should (string-match-p "C-c > +Reply in a thread; C-u quotes" text))
      ;; A key of a panel above the box, which types there, and the box's own M-< and M->.
      (should (string-match-p "C-c \\. +A key of the panel above, from the box" text))
      (should (string-match-p "M-< +Top of the box, then the buffer" text))
      (should (string-match-p "M-> +Bottom of the box, then the buffer" text))
      ;; Answering a quote inline: the keys of `compose-quote-inline-mode'.
      (should (string-match-p "M-RET +Split a quote to answer inline" text))
      (should (string-match-p "C-c \\[ +Elide part of a quote: \\[\\.\\.\\.\\]" text))
      (should-not (string-match-p "C-c C-v" text))
      (should-not (string-match-p "Task board" text)))))

(ert-deftest harness-ui-menu-in-a-btw-shows-its-keys-over-the-chats ()
  "In a BTW, C-c C-k closes it, in the buffer and so in the menu."
  (harness-ui-test-with-menu-buffer (lambda () (harness-chat-mode) (harness-ui-btw-minor-mode 1))
    (let ((text (harness-ui-test-menu)))
      (should (string-match-p "^Chat .* BTW$" text))
      (should (string-match-p "C-c C-k +Close" text))
      (should-not (string-match-p "C-c C-k +Cancel turn" text))
      (should (string-match-p "C-c C-c +Send" text))
      (should (string-match-p "C-c > +Reply in a thread" text)))))

(ert-deftest harness-ui-menu-in-review-shows-its-keys-over-the-chats ()
  "While a task's review banner shows, C-c C-v verifies and C-c C-x sends
it back, in the buffer and so in the menu; the chat's C-c C-r still
redraws.  With the banner gone, C-c C-v is nothing: the box pastes with C-y."
  (harness-ui-test-with-menu-buffer (lambda () (harness-chat-mode) (harness-ui-review-minor-mode 1))
    (should (eq 'harness-ui-review-verify (key-binding (kbd "C-c C-v"))))
    (should (eq 'harness-ui-review-reject (key-binding (kbd "C-c C-x"))))
    (should (eq 'harness-chat-redraw (key-binding (kbd "C-c C-r"))))
    (let ((text (harness-ui-test-menu)))
      (should (string-match-p "^Chat .* Review$" text))
      (should (string-match-p "C-c C-v +Verify (accept)" text))
      (should (string-match-p "C-c C-x +Send back with feedback" text))
      (should (string-match-p "C-c C-r +Redraw" text))
      (should-not (string-match-p "Attach clipboard" text)))
    (harness-ui-review-minor-mode -1)
    (should-not (key-binding (kbd "C-c C-v")))
    (let ((text (harness-ui-test-menu)))
      (should-not (string-match-p "C-c C-v" text))
      (should-not (string-match-p "Review\\|Send back" text)))))

(ert-deftest harness-ui-menu-shows-the-board-commands-on-the-task-board ()
  (harness-ui-test-with-menu-buffer #'harness-ui-tasks-mode
    (let ((text (harness-ui-test-menu)))
      (should (string-match-p "^Task board$" text))
      (should (string-match-p "\\. s +Start now" text))
      (should (string-match-p "\\. RET +Open its session" text))
      (should (string-match-p "C-c C-c +Submit" text))
      (should (string-match-p "C-y +Paste; an image attaches" text))
      (should-not (string-match-p "C-c C-v" text))
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
                                ;; Keys on a view's content, outside its box,
                                ;; and the session list's on the lines of a
                                ;; session waiting on a tool call.
                                (and (eq mode 'harness-ui-tasks-mode) harness-ui-tasks-board-map)
                                (and (eq mode 'harness-ui-sessions-mode) harness-ui-sessions-permission-map)
                                (and (eq mode 'harness-ui-popout-mode) harness-ui-popout-content-map)
                                ;; The keys of a queued message, on its text: the
                                ;; ones of the queue, and the ones of a message
                                ;; sent to a turn that has not taken it yet.
                                (and (eq mode 'harness-chat-mode) harness-chat-queued-map)
                                (and (eq mode 'harness-chat-mode) harness-chat-steering-map)
                                ;; Answering a quote in the compose box inline:
                                ;; the keys of the library's mode, which is on
                                ;; while point is in a quote of the box.
                                (and (memq mode '(harness-chat-mode harness-ui-popout-mode))
                                     (boundp 'compose-quote-inline-mode-map)
                                     (symbol-value 'compose-quote-inline-mode-map)))))
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
                ;; Behind `.' one plain key; otherwise a chord -- a key
                ;; with a modifier, the chat's C-c C-c or its M-n --
                ;; never a plain key, which the menu's own groups own.
                (if dotted
                    (should (= 2 (length events)))
                  (should (event-modifiers (aref events 0))))
                (should (cl-some (lambda (map)
                                   (or (eq command (lookup-key map own))
                                       ;; Or the key's global command, remapped:
                                       ;; the compose box's C-y, `yank' remapped.
                                       (let ((global (lookup-key global-map own)))
                                         (and global (symbolp global)
                                              (eq command (lookup-key map (vector 'remap global)))))
                                       ;; Or the command the map gives it, remapped
                                       ;; in the map itself: the chat's C-c >, the
                                       ;; box's `compose-quote-reply' remapped to
                                       ;; starting a thread, which the quoting
                                       ;; minor mode's own binding of the key
                                       ;; would otherwise outrank.
                                       (let ((bound (lookup-key map own)))
                                         (and bound (symbolp bound)
                                              (eq command (lookup-key map (vector 'remap bound)))))))
                                 maps)))))))))
  ;; What every harness buffer offers is checked above; here, that each mode is there.
  (dolist (mode '(harness-chat-mode harness-ui-tasks-mode harness-ui-slots-mode harness-ui-sessions-mode
                  harness-ui-tree-mode harness-ui-worktree-mode harness-ui-usage-mode harness-ui-access-mode
                  harness-ui-btw-minor-mode harness-ui-media-recording-mode harness-ui-review-minor-mode))
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

;;;; Where a window prefix says
;;
;; Emacs's window prefixes -- C-x 4 4, C-x 5 5, C-x t t -- say where the
;; next command's buffer shows.  The keys go through the command loop
;; (`execute-kbd-macro'), as typed keys do, so a prefix's action lasts
;; until the command after it is over, as it does for the user.

(declare-function harness-ui-display-override-p "harness-ui")
(declare-function harness-ui-display-later "harness-ui")
(declare-function harness-switch-session "harness-ui")
(declare-function tab-bar--current-tab-index "tab-bar")
(declare-function tab-bar-select-tab "tab-bar")
(declare-function tab-bar-close-tab "tab-bar")
(defvar tab-bar-tabs-function)

(defmacro harness-ui-test-with-keys (bindings &rest body)
  "Run BODY with BINDINGS, a list of (KEY . COMMAND), over the buffers' keys.
The global map stays below them, with its window prefixes."
  (declare (indent 1))
  `(let ((overriding-local-map (make-sparse-keymap)))
     (dolist (binding ,bindings)
       (define-key overriding-local-map (kbd (car binding)) (cdr binding)))
     ,@body))

(defun harness-ui-test--view-command (buffer)
  "Return a command showing BUFFER as a view command shows its view."
  (lambda () (interactive) (harness-ui-display-view buffer)))

(ert-deftest harness-ui-display-view-shows-in-the-frame-given ()
  "The frame argument is the frame the view shows in, and its position is set."
  (harness-ui-test-with-views
    (let ((frame (selected-frame)))
      (harness-ui-display-view view 'right frame)
      (should (eq frame (window-frame (get-buffer-window view))))
      (should (eq view (window-buffer (get-buffer-window view frame))))
      (should (eq 'right (buffer-local-value 'harness-ui-position view))))))

(ert-deftest harness-ui-window-prefix-shows-a-view-in-another-window ()
  "C-x 4 4 before a view command shows the view in another window.
Not in its position, a side window, but where the prefix says, as any
buffer would: a window of its own, selected.  The position the view had
is kept for the next time, and the prefix is spent once the command is
over, so the next buffer goes to its position again."
  (harness-ui-test-with-views
    (with-current-buffer view (setq-local harness-ui-position 'left))
    (let ((main (selected-window)))
      (harness-ui-test-with-keys (list (cons "C-c v" (harness-ui-test--view-command view)))
        (execute-kbd-macro (kbd "C-x 4 4 C-c v")))
      (let ((window (get-buffer-window view)))
        (should window)
        (should-not (eq main window))
        (should-not (window-parameter window 'window-side))
        (should (eq window (selected-window)))
        (should (eq 'left (buffer-local-value 'harness-ui-position view))))
      ;; Spent with the command, nothing left pending.
      (should-not (harness-ui-display-override-p))
      (should-not (car display-buffer-overriding-action))
      (harness-ui-display-view other-session 'right)
      (should (eq 'right (window-parameter (get-buffer-window other-session) 'window-side))))))

(ert-deftest harness-ui-window-prefix-shows-a-view-in-a-new-frame ()
  "C-x 5 5 before a view command shows the view in a new frame.
A batch Emacs makes no frame, so the frame made is the selected one, and
what counts is that one was asked for and the view shows in it."
  (harness-ui-test-with-views
    (let* ((made 0)
           (pop-up-frame-function (lambda () (cl-incf made) (selected-frame))))
      (with-current-buffer view (setq-local harness-ui-position 'right))
      (harness-ui-test-with-keys (list (cons "C-c v" (harness-ui-test--view-command view)))
        (execute-kbd-macro (kbd "C-x 5 5 C-c v")))
      (should (= 1 made))
      (should (eq view (window-buffer (selected-window))))
      (should-not (window-parameter (selected-window) 'window-side))
      (should (eq 'right (buffer-local-value 'harness-ui-position view))))))

(ert-deftest harness-ui-window-prefix-shows-a-view-in-a-new-tab ()
  "C-x t t before a view command shows the view in a new tab."
  (require 'tab-bar)
  (harness-ui-test-with-views
    (let ((tabs (length (funcall tab-bar-tabs-function)))
          (mode (bound-and-true-p tab-bar-mode)))
      (unwind-protect
          (progn
            (harness-ui-test-with-keys (list (cons "C-c v" (harness-ui-test--view-command view)))
              (execute-kbd-macro (kbd "C-x t t C-c v")))
            (should (= (1+ tabs) (length (funcall tab-bar-tabs-function))))
            (should (eq view (window-buffer (selected-window)))))
        (while (> (length (funcall tab-bar-tabs-function)) tabs)
          (tab-bar-close-tab))
        (unless mode (tab-bar-mode -1))))))

(ert-deftest harness-ui-window-prefix-holds-for-a-session-shown-later ()
  "A session shown once the harness answers goes where the prefix said.
C-c h s reads the session once the session list is fetched, when the
prefix's command is over: the prefix's action and the frame the command
ran in are taken as it runs (`harness-ui-display-later'), and the session
shows with them."
  (harness-ui-test-with-views
    (let* ((pending nil)
           (frames nil)
           (display (symbol-function 'harness-ui-display-session))
           (harness-ui-open-session-function (lambda (_id) session)))
      (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
                 (lambda (&optional callback) (setq pending callback)))
                ((symbol-function 'harness-ui-read-session)
                 (lambda (&rest _) (list :id "sid")))
                ((symbol-function 'harness-ui-display-session)
                 (lambda (id &optional position frame)
                   (push frame frames)
                   (funcall display id position frame))))
        (harness-ui-test-with-keys (list (cons "C-c s" #'harness-switch-session))
          (execute-kbd-macro (kbd "C-x 4 4 C-c s")))
        ;; The command is over and its prefix spent; the harness answers now.
        (should-not (harness-ui-display-override-p))
        (should-not (get-buffer-window session))
        (funcall pending nil))
      (should (equal (list (selected-frame)) frames))
      (let ((window (get-buffer-window session)))
        (should window)
        (should-not (window-parameter window 'window-side))
        (should (eq window (selected-window))))
      ;; Spent there too: the next session goes to its position.
      (should-not (harness-ui-display-override-p))
      (harness-ui-display-buffer other-session 'right)
      (should (eq 'right (window-parameter (get-buffer-window other-session) 'window-side))))))

(ert-deftest harness-ui-display-later-without-a-prefix ()
  "Shown later with no prefix before the command, a buffer goes to its position.
The frame the command ran in is given to the function that shows it."
  (harness-ui-test-with-views
    (let ((later (harness-ui-display-later))
          given)
      (funcall later (lambda (frame)
                       (setq given frame)
                       (harness-ui-display-buffer session 'right frame)))
      (should (eq (selected-frame) given))
      (should (eq 'right (window-parameter (get-buffer-window session) 'window-side))))))

;;;; The fullscreen layout of an overview

(defmacro harness-ui-test-with-fullscreen (&rest body)
  "Run BODY with the user's buffer `file' alone in the frame, an overview
`view' that names session \"one\", and the buffers of sessions \"one\"
and \"two\", `one' and `two'."
  (declare (indent 0))
  `(let* ((file (get-buffer-create "fullscreen test file"))
          (view (get-buffer-create "*harness fullscreen test view*"))
          (one (get-buffer-create "*harness: fullscreen one*"))
          (two (get-buffer-create "*harness: fullscreen two*"))
          (harness-ui-default-position 'right)
          (harness-ui-open-session-function
           (lambda (id) (pcase id ("one" one) ("two" two)))))
     (unwind-protect
         (progn
           (clrhash harness-ui--position-buffers)
           (clrhash harness-ui--fullscreen-layouts)
           (delete-other-windows)
           (switch-to-buffer file)
           (with-current-buffer view
             (setq-local harness-ui-overview-function (lambda () "one")))
           ,@body)
       (clrhash harness-ui--fullscreen-layouts)
       (clrhash harness-ui--position-buffers)
       (let ((ignore-window-parameters t))
         (ignore-errors (delete-other-windows (harness-ui--main-window))))
       (mapc #'kill-buffer (list file view one two)))))

(ert-deftest harness-ui-fullscreen-shows-the-overview-left-and-a-session-beside ()
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'right)
      (should (eq 'right (window-parameter (get-buffer-window view) 'window-side)))
      ;; F in the overview.
      (harness-fullscreen)
      (let ((overview (get-buffer-window view)))
        (should (harness-ui--fullscreen-layout))
        (should (eq 'left (window-parameter overview 'window-side)))
        (should (window-parameter overview 'no-delete-other-windows))
        (should (eq overview (selected-window)))
        ;; The session the overview names takes the window the frame kept;
        ;; the side window the overview was in made way.
        (should (eq one (window-buffer main)))
        (should (= 2 (length (window-list))))
        (should (eq 'fullscreen (buffer-local-value 'harness-ui-position view)))
        (should (eq 'fullscreen (buffer-local-value 'harness-ui-position one)))))))

(ert-deftest harness-ui-fullscreen-anchor-side ()
  "The anchor sits on the configured side: left by default, right when set."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window))
          (harness-ui-fullscreen-side 'right))
      (harness-ui-display-view view 'fullscreen)
      (let ((anchor (get-buffer-window view)))
        (should (eq 'right (window-parameter anchor 'window-side)))
        (should (eq one (window-buffer main)))
        (should (harness-ui--overview-window-p anchor))
        ;; q on the anchor ends the layout, whichever side it sits on.
        (harness-ui-quit-view)
        (should-not (harness-ui--fullscreen-layout))))))

(ert-deftest harness-ui-fullscreen-a-main-session-anchors ()
  "A main session with no parent is the layout's anchor, its child beside it."
  (harness-ui-test-with-fullscreen
    (let* ((main-buf (get-buffer-create "*harness: fullscreen main*"))
           (child-buf (get-buffer-create "*harness: fullscreen child*"))
           (harness-ui-open-session-function (lambda (id) (pcase id ("child" child-buf))))
           (main-window (selected-window)))
      (unwind-protect
          (progn
            (puthash "main" (list :id "main" :updated 10) harness-ui--sessions)
            (puthash "child" (list :id "child" :parent-id "main" :updated 20) harness-ui--sessions)
            (with-current-buffer main-buf
              (setq-local harness-ui-session-id "main")
              (setq-local major-mode 'harness-chat-mode))
            (with-current-buffer child-buf
              (setq-local harness-ui-session-id "child")
              (setq-local major-mode 'harness-chat-mode))
            ;; The main session is an anchor, the child is not.
            (should (harness-ui-anchor-p main-buf))
            (should (harness-ui--session-anchor-p main-buf))
            (should-not (harness-ui-overview-p main-buf))
            (should-not (harness-ui-anchor-p child-buf))
            ;; The anchor's choice is its most recent child.
            (should (equal "child" (harness-ui--anchor-session main-buf)))
            ;; F in the main session starts the layout with it as the anchor.
            (switch-to-buffer main-buf)
            (harness-fullscreen)
            (let ((anchor (get-buffer-window main-buf)))
              (should (harness-ui--fullscreen-layout))
              (should (harness-ui--overview-window-p anchor))
              (should (eq main-buf (window-buffer anchor)))
              (should (eq child-buf (window-buffer main-window)))
              ;; The anchor never shows beside itself.
              (should (eq child-buf (harness-ui--fullscreen-session main-buf (selected-frame)))))
            (harness-ui-quit-view)
            (should-not (harness-ui--fullscreen-layout))
            ;; Without the layout, shown in the `fullscreen' position (C-u
            ;; C-c h s, say), it starts the layout as its anchor too.
            (harness-ui-display-buffer main-buf 'fullscreen)
            (let ((layout (harness-ui--fullscreen-layout)))
              (should layout)
              (should (eq main-buf (window-buffer (harness-ui--fullscreen-overview layout))))
              (should (eq child-buf (window-buffer main-window))))
            (harness-ui-quit-view)
            (should-not (harness-ui--fullscreen-layout)))
        (remhash "main" harness-ui--sessions)
        (remhash "child" harness-ui--sessions)
        (kill-buffer main-buf)
        (kill-buffer child-buf)))))

(ert-deftest harness-ui-fullscreen-a-main-session-opened-takes-the-slot ()
  "A main session opened while the layout lasts takes the slot; the anchor stays.
A main session can anchor the layout, but only F makes it the anchor.
Opened from the overview -- RET or a click on the board, which go
through `harness-ui-session-opener' -- visited, as RET on the session
list, a session link or a notification do, or shown without a position,
as C-c h s does, it shows beside the anchor like any session: a task's
session is a main session, and it never takes the board's place.  An
anchor shown again keeps the anchor side."
  (harness-ui-test-with-fullscreen
    (let* ((main-buf (get-buffer-create "*harness: fullscreen main*"))
           (harness-ui-open-session-function
            (lambda (id) (pcase id ("one" one) ("two" two) ("main" main-buf))))
           (harness-ui-switch-project-function nil)
           (main (selected-window)))
      (unwind-protect
          (progn
            (puthash "main" (list :id "main" :updated 10) harness-ui--sessions)
            (with-current-buffer main-buf
              (setq-local harness-ui-session-id "main")
              (setq-local major-mode 'harness-chat-mode))
            (should (harness-ui-anchor-p main-buf))
            (harness-ui-display-view view 'fullscreen)
            (let ((anchor (get-buffer-window view)))
              (should (eq one (window-buffer main)))
              ;; Opened from the overview.
              (select-window anchor)
              (funcall (with-current-buffer view (harness-ui-session-opener)) "main")
              (should (eq main-buf (window-buffer main)))
              (should (eq main (selected-window)))
              (should (eq view (window-buffer anchor)))
              (should (eq anchor (harness-ui--fullscreen-overview (harness-ui--fullscreen-layout))))
              (should (eq 'fullscreen (buffer-local-value 'harness-ui-position main-buf)))
              ;; Visited from the overview.
              (harness-ui-display-buffer one)
              (select-window anchor)
              (with-current-buffer view (harness-ui-visit-session "main"))
              (should (eq main-buf (window-buffer main)))
              (should (eq view (window-buffer anchor)))
              ;; Shown without a position, or in the `fullscreen' one.
              (harness-ui-display-buffer two)
              (harness-ui-display-session "main")
              (should (eq main-buf (window-buffer main)))
              (harness-ui-display-buffer two)
              (harness-ui-display-session "main" 'fullscreen)
              (should (eq main-buf (window-buffer main)))
              (should (eq view (window-buffer anchor)))
              (should (= 2 (length (window-list))))
              ;; F in it makes it the anchor, and shown again it stays there.
              (select-window main)
              (with-current-buffer main-buf (harness-fullscreen))
              (should (eq main-buf (window-buffer anchor)))
              (should-not (eq main-buf (window-buffer main)))
              (harness-ui-display-session "main")
              (should (eq main-buf (window-buffer anchor)))
              (should-not (eq main-buf (window-buffer main)))
              (should (eq anchor (selected-window)))))
        (remhash "main" harness-ui--sessions)
        (kill-buffer main-buf)))))

(ert-deftest harness-ui-fullscreen-width-clamps ()
  "The anchor width is clamped so the slot keeps a usable width."
  (let ((harness-ui-fullscreen-width 0.5))
    (should (eql 0.5 (harness-ui--fullscreen-width))))
  (let ((harness-ui-fullscreen-width 0.05))
    (should (eql 0.2 (harness-ui--fullscreen-width))))
  (let ((harness-ui-fullscreen-width 0.95))
    (should (eql 0.8 (harness-ui--fullscreen-width))))
  (let ((harness-ui-fullscreen-width 200))
    (should (= (max 20 (- (frame-width) 20)) (harness-ui--fullscreen-width))))
  (let ((harness-ui-fullscreen-width 10))
    (should (= 20 (harness-ui--fullscreen-width)))))

(ert-deftest harness-ui-fullscreen-starts-with-the-overview-shown-last ()
  "Run from a buffer that is not an overview, the command picks one."
  (harness-ui-test-with-fullscreen
    (harness-ui-display-view view 'right)
    (quit-window nil (get-buffer-window view))
    (should-not (get-buffer-window view))
    (with-current-buffer file (harness-fullscreen))
    (should (harness-ui--overview-window-p (get-buffer-window view)))))

(ert-deftest harness-ui-fullscreen-sessions-take-the-slot ()
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'fullscreen)
      (let ((overview (get-buffer-window view))
            (open (with-current-buffer view (harness-ui-session-opener))))
        (should (eq one (window-buffer main)))
        ;; A session opened from the overview takes the slot, and is selected.
        (funcall open "two")
        (should (eq two (window-buffer main)))
        (should (eq main (selected-window)))
        (should (eq view (window-buffer overview)))
        ;; So does anything shown without a position, views that are no
        ;; overview included, whatever position they had.
        (harness-ui-display-buffer one)
        (should (eq one (window-buffer main)))
        (let ((log (get-buffer-create "*harness fullscreen test log*")))
          (unwind-protect
              (progn
                (with-current-buffer log (setq-local harness-ui-position 'bottom))
                (harness-ui-display-view log)
                (should (eq log (window-buffer main))))
            (kill-buffer log)))
        ;; A position of its own leaves the layout's windows alone.
        (harness-ui-display-buffer two 'bottom)
        (should (eq 'bottom (window-parameter (get-buffer-window two) 'window-side)))
        (should (eq view (window-buffer overview)))
        ;; C-x 1 beside the overview keeps it.
        (select-window main)
        (delete-other-windows)
        (should (window-live-p overview))
        (should (harness-ui--fullscreen-layout))))))

(ert-deftest harness-ui-fullscreen-bury-brings-back-the-users-buffer ()
  "Burying the session beside the overview keeps the layout."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'fullscreen)
      (funcall (with-current-buffer view (harness-ui-session-opener)) "two")
      (should (eq two (window-buffer main)))
      ;; C-c C-z: back to the file, past the sessions shown since.
      (harness-ui-bury)
      (should (eq file (window-buffer main)))
      (should (harness-ui--fullscreen-layout))
      (should (harness-ui--overview-window-p (get-buffer-window view)))
      ;; The next session opened from the overview takes the window back.
      (select-window (get-buffer-window view))
      (funcall (with-current-buffer view (harness-ui-session-opener)) "one")
      (should (eq one (window-buffer main))))))

(ert-deftest harness-ui-fullscreen-quitting-the-overview-ends-it ()
  "q on the overview buries it and puts the windows back."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'right)
      (harness-fullscreen)
      (should (eq one (window-buffer main)))
      (harness-ui-quit-view)
      (should-not (harness-ui--fullscreen-layout))
      (should (equal (list main) (window-list)))
      (should (eq file (window-buffer main)))
      (should-not (get-buffer-window view))
      ;; Opened again, it goes where it was before the layout.
      (should (eq 'right (buffer-local-value 'harness-ui-position view))))))

(ert-deftest harness-ui-fullscreen-slot-session-gets-its-position-back ()
  "Ending the layout gives a session shown in the slot its position back.
The session is marked `fullscreen' while the layout lasts, but once the
layout is gone it has the position it had before, not one that sends it
looking for a layout that is not there any more."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'fullscreen)
      (should (eq one (window-buffer main)))
      (should (eq 'fullscreen (buffer-local-value 'harness-ui-position one)))
      ;; q on the anchor, the selected window after the layout started.
      (harness-ui-quit-view)
      (should-not (harness-ui--fullscreen-layout))
      (should-not (buffer-local-value 'harness-ui-position one)))))

(ert-deftest harness-ui-fullscreen-slot-bury-gets-the-position-back ()
  "Burying a session out of the slot keeps the layout, and its position comes back."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'fullscreen)
      (should (eq one (window-buffer main)))
      ;; C-c C-z in the slot: the user's file comes back and the layout
      ;; stays, but the session is not left marked `fullscreen'.
      (select-window main)
      (harness-ui-bury)
      (should (eq file (window-buffer main)))
      (should (harness-ui--fullscreen-layout))
      (should (harness-ui--overview-window-p (get-buffer-window view)))
      (should-not (buffer-local-value 'harness-ui-position one)))))

(ert-deftest harness-ui-fullscreen-slot-view-gets-its-position-back ()
  "A view shown in the slot gets back the position it had before the layout."
  (harness-ui-test-with-fullscreen
    (let ((anchor (get-buffer-create "*harness fullscreen test anchor*")))
      (unwind-protect
          (progn
            (with-current-buffer anchor (setq-local harness-ui-overview-function #'ignore))
            (with-current-buffer view (setq-local harness-ui-position 'right))
            (harness-ui-display-view anchor 'fullscreen)
            (should (harness-ui--fullscreen-layout))
            ;; A left or right position inside a layout is the slot.
            (harness-ui-display-buffer view 'right)
            (should (eq view (window-buffer (selected-window))))
            (should-not (window-parameter (selected-window) 'window-side))
            (should (eq 'fullscreen (buffer-local-value 'harness-ui-position view)))
            ;; q on the anchor ends the layout, and the view goes back to
            ;; the position it had before it.
            (select-window (harness-ui--fullscreen-overview (harness-ui--fullscreen-layout)))
            (harness-ui-quit-view)
            (should-not (harness-ui--fullscreen-layout))
            (should (eq 'right (buffer-local-value 'harness-ui-position view))))
        (kill-buffer anchor)))))

(ert-deftest harness-ui-fullscreen-ends-keeping-a-file-visited-beside ()
  "Ended, the layout puts the windows back but the user's buffer stays in sight."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window))
          (other-file (get-buffer-create "fullscreen test other file")))
      (unwind-protect
          (progn
            (harness-ui-display-view view 'right)
            (harness-fullscreen)
            (select-window main)
            (switch-to-buffer other-file)
            ;; From a buffer that is not an overview, the command ends the layout.
            (harness-fullscreen)
            (should-not (harness-ui--fullscreen-layout))
            (should (eq 'right (window-parameter (get-buffer-window view) 'window-side)))
            (should (eq other-file (window-buffer main))))
        (kill-buffer other-file)))))

(ert-deftest harness-ui-fullscreen-another-overview-takes-the-left ()
  (harness-ui-test-with-fullscreen
    (let ((list (get-buffer-create "*harness fullscreen test list*")))
      (unwind-protect
          (progn
            (with-current-buffer list (setq-local harness-ui-overview-function #'ignore))
            (harness-ui-display-view view 'fullscreen)
            (let ((overview (get-buffer-window view)))
              (harness-ui-display-view list)
              (should (eq list (window-buffer overview)))
              (should (eq 'side (window-dedicated-p overview)))
              (should (harness-ui--overview-window-p overview))
              (should (eq overview (selected-window)))
              (harness-ui-quit-view)
              (should-not (harness-ui--fullscreen-layout))
              ;; Both had no position before the layout, and have none after.
              (should-not (buffer-local-value 'harness-ui-position list))
              (should-not (buffer-local-value 'harness-ui-position view))))
        (kill-buffer list)))))

(ert-deftest harness-ui-fullscreen-displaced-anchor-keeps-a-position ()
  "An anchor another one replaces leaves the layout with its position back,
while the layout stays on with the new anchor."
  (harness-ui-test-with-fullscreen
    (let ((list (get-buffer-create "*harness fullscreen test list*")))
      (unwind-protect
          (progn
            (with-current-buffer list (setq-local harness-ui-overview-function #'ignore))
            (harness-ui-display-view view 'right)
            (harness-fullscreen)
            (should (eq 'fullscreen (buffer-local-value 'harness-ui-position view)))
            ;; Another overview takes the anchor side.
            (harness-ui-display-view list)
            (should (harness-ui--fullscreen-layout))
            (should (eq list (window-buffer (harness-ui--fullscreen-overview
                                             (harness-ui--fullscreen-layout)))))
            ;; The anchor it replaced is out of the layout, with the
            ;; position it had before it, not `fullscreen' any more.
            (should (eq 'right (buffer-local-value 'harness-ui-position view)))
            (should (eq 'fullscreen (buffer-local-value 'harness-ui-position list)))
            ;; And the layout still ends cleanly with the new anchor.
            (harness-ui-quit-view)
            (should-not (harness-ui--fullscreen-layout))
            (should-not (buffer-local-value 'harness-ui-position list)))
        (kill-buffer list)))))

(ert-deftest harness-ui-fullscreen-ends-with-the-overviews-window ()
  (harness-ui-test-with-fullscreen
    (harness-ui-display-view view 'fullscreen)
    (delete-window (get-buffer-window view))
    (should-not (harness-ui--fullscreen-layout))
    (harness-ui-display-buffer two)
    (should (eq 'right (window-parameter (get-buffer-window two) 'window-side)))))

(ert-deftest harness-ui-fullscreen-dropped-with-its-window ()
  "A layout whose anchor window goes is dropped, and its anchor's position
before the layout comes back, so nothing looks for the layout again."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'right)
      (harness-fullscreen)
      (should (eq one (window-buffer main)))
      (should (eq 'fullscreen (buffer-local-value 'harness-ui-position view)))
      (delete-window (get-buffer-window view))
      ;; The layout is dropped, not just passed over: no stale entry, and
      ;; the anchor gets back the position it had before the layout.
      (should-not (harness-ui--fullscreen-layout))
      (should-not (gethash (selected-frame) harness-ui--fullscreen-layouts))
      (should (eq 'right (buffer-local-value 'harness-ui-position view)))
      ;; A session shown now opens where the position says, not into the
      ;; layout that is gone.
      (harness-ui-display-buffer two)
      (should (eq 'right (window-parameter (get-buffer-window two) 'window-side))))))

(ert-deftest harness-ui-fullscreen-dropped-on-a-project-switch ()
  "A project switch replaces the frame's windows, so its layout is dropped.
The session is shown in the project switched to, and the anchor the layout
showed gets back the position it had before the layout."
  (harness-ui-test-with-fullscreen
    (let* ((session (list :id "elsewhere" :project default-directory :updated 1))
           (other (get-buffer-create "*harness: fullscreen switch*"))
           (harness-ui-open-session-function
            (lambda (id) (pcase id ("elsewhere" other) ("one" one) (_ two))))
           (harness-ui-switch-project-function
            (lambda (_root)
              ;; A workspace switch puts the project's windows in the frame:
              ;; the layout's own are gone, the main window alone remains.
              (let ((ignore-window-parameters t))
                (delete-other-windows (harness-ui--main-window)))
              t)))
      (unwind-protect
          (progn
            (puthash "elsewhere" session harness-ui--sessions)
            (harness-ui-display-view view 'right)
            (harness-fullscreen)
            (should (harness-ui--fullscreen-layout))
            (harness-ui-visit-session "elsewhere")
            ;; The switch took the layout with it; no stale entry, and the
            ;; anchor is back where it was before the layout.
            (should-not (harness-ui--fullscreen-layout))
            (should-not (gethash (selected-frame) harness-ui--fullscreen-layouts))
            (should (eq 'right (buffer-local-value 'harness-ui-position view)))
            ;; The session shows, where sessions open.
            (should (eq other (window-buffer (selected-window))))
            (should (eq 'right (window-parameter (get-buffer-window other) 'window-side))))
        (remhash "elsewhere" harness-ui--sessions)
        (kill-buffer other)))))

(ert-deftest harness-ui-fullscreen-popup-is-not-the-slot ()
  "A popup window, such as transient's, is never taken for the slot."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'fullscreen)
      (should (eq one (window-buffer main)))
      (let ((popup (get-buffer-create " *harness fullscreen popup*")))
        (unwind-protect
            (progn
              (select-window main)
              (display-buffer popup '(display-buffer-below-selected))
              (let ((popup-window (get-buffer-window popup)))
                (should popup-window)
                (should (harness-ui--popup-window-p popup-window))
                ;; The slot stays the session's window, not the popup, and
                ;; the main-window search passes the popup over.
                (should-not (eq popup-window (harness-ui--fullscreen-window
                                              (harness-ui--fullscreen-layout))))
                (should-not (eq popup-window (harness-ui--main-window))))
              ;; A session shown now goes to the slot; the popup stays.
              (harness-ui-display-buffer two)
              (should (eq two (window-buffer main)))
              (should (eq popup (window-buffer (get-buffer-window popup)))))
          (kill-buffer popup))))))

(ert-deftest harness-ui-fullscreen-no-second-column ()
  "A left or right position inside the layout is the slot, not a second column."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'fullscreen)
      (should (eq one (window-buffer main)))
      (harness-ui-display-buffer two 'right)
      (should (= 2 (length (window-list))))
      (should (eq two (window-buffer main)))
      (should-not (window-parameter (get-buffer-window two) 'window-side))
      (should (eq 'fullscreen (buffer-local-value 'harness-ui-position two)))
      ;; The anchor is where it was.
      (should (eq view (window-buffer (get-buffer-window view)))))))

(ert-deftest harness-ui-fullscreen-slot-position ()
  "The slot position shows beside the anchor; without a layout, the default."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'fullscreen)
      (should (eq one (window-buffer main)))
      ;; In the layout, `slot' shows beside the anchor and leaves it alone.
      (harness-ui-display-buffer two 'slot)
      (should (eq two (window-buffer main)))
      (should (eq view (window-buffer (get-buffer-window view))))
      (should (= 2 (length (window-list))))
      ;; End the layout; `slot' then means the default position.
      (select-window (get-buffer-window view))
      (harness-ui-quit-view)
      (should-not (harness-ui--fullscreen-layout))
      (harness-ui-display-buffer one 'slot)
      (should (eq 'right (window-parameter (get-buffer-window one) 'window-side))))))

;; Window prefixes and the layout (see "Where a window prefix says").

(ert-deftest harness-ui-window-prefix-opens-a-session-elsewhere ()
  "C-x 4 4 before opening a session from a view shows it in another window.
The fullscreen layout is left as it is: the anchor keeps its side and
the slot its session, and the session opened next takes the slot again."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      (harness-ui-display-view view 'fullscreen)
      (let ((anchor (get-buffer-window view))
            (open (lambda () (interactive) (funcall (harness-ui-session-opener) "two"))))
        (should (eq one (window-buffer main)))
        (select-window anchor)
        (harness-ui-test-with-keys (list (cons "C-c o" open))
          (execute-kbd-macro (kbd "C-x 4 4 C-c o")))
        (let ((window (get-buffer-window two)))
          (should window)
          (should-not (memq window (list anchor main)))
          (should (eq window (selected-window))))
        (should (eq one (window-buffer main)))
        (should (eq view (window-buffer anchor)))
        (should (eq anchor (harness-ui--fullscreen-overview (harness-ui--fullscreen-layout))))
        ;; The prefix is spent with the command: nothing is left pending
        ;; to take the next buffer Emacs shows.
        (should-not (harness-ui-display-override-p))
        ;; Without a prefix, the slot again.
        (select-window anchor)
        (harness-ui-test-with-keys (list (cons "C-c o" open))
          (execute-kbd-macro (kbd "C-c o")))
        (should (eq two (window-buffer main)))
        (should (eq view (window-buffer anchor)))))))

(ert-deftest harness-ui-window-prefix-starts-the-layout-in-a-new-tab ()
  "C-x t t before F lays the layout out in a new tab; this tab stays as it was.
F run in a buffer that anchors nothing takes the overview shown last,
which shows in the new tab and anchors the layout there, the session it
names beside it."
  (require 'tab-bar)
  (harness-ui-test-with-fullscreen
    (let ((tabs (length (funcall tab-bar-tabs-function)))
          (here (tab-bar--current-tab-index))
          (mode (bound-and-true-p tab-bar-mode)))
      (unwind-protect
          (progn
            (harness-ui-display-view view 'right)
            (select-window (get-buffer-window file))
            (harness-ui-test-with-keys (list (cons "C-c F" #'harness-fullscreen))
              (execute-kbd-macro (kbd "C-x t t C-c F")))
            (should (= (1+ tabs) (length (funcall tab-bar-tabs-function))))
            (should-not (= here (tab-bar--current-tab-index)))
            (should-not (harness-ui-display-override-p))
            (let* ((layout (harness-ui--fullscreen-layout))
                   (anchor (and layout (harness-ui--fullscreen-overview layout))))
              (should layout)
              (should (eq view (window-buffer anchor)))
              (should (eq 'left (window-parameter anchor 'window-side)))
              (should (eq anchor (selected-window)))
              (should (eq one (window-buffer (harness-ui--fullscreen-window layout)))))
            ;; The tab F ran in shows what it showed.
            (tab-bar-select-tab (1+ here))
            (should (eq file (window-buffer (selected-window))))
            (should (eq 'right (window-parameter (get-buffer-window view) 'window-side))))
        (tab-bar-select-tab (1+ here))
        (while (> (length (funcall tab-bar-tabs-function)) tabs)
          (tab-bar-close-tab (+ 2 here)))
        (unless mode (tab-bar-mode -1))))))

(ert-deftest harness-ui-window-prefix-on-the-anchor-lays-it-out-in-a-new-tab ()
  "C-x t t before F on the anchor lays it out in a new tab, not ending it here.
F on the anchor ends the layout; after the prefix it shows the anchor
in a new tab and starts the layout there instead, the anchor's session
beside it, and the tab it ran in still shows the layout as it was."
  (require 'tab-bar)
  (harness-ui-test-with-fullscreen
    (let ((tabs (length (funcall tab-bar-tabs-function)))
          (here (tab-bar--current-tab-index))
          (mode (bound-and-true-p tab-bar-mode))
          (main (selected-window)))
      (unwind-protect
          (progn
            (harness-ui-display-view view 'fullscreen)
            (let ((anchor (get-buffer-window view)))
              (should (eq one (window-buffer main)))
              (select-window anchor)
              (harness-ui-test-with-keys (list (cons "C-c F" #'harness-fullscreen))
                (execute-kbd-macro (kbd "C-x t t C-c F")))
              (should (= (1+ tabs) (length (funcall tab-bar-tabs-function))))
              (should-not (= here (tab-bar--current-tab-index)))
              (should-not (harness-ui-display-override-p))
              (let* ((layout (harness-ui--fullscreen-layout))
                     (laid (and layout (harness-ui--fullscreen-overview layout))))
                (should layout)
                (should-not (eq anchor laid))
                (should (eq view (window-buffer laid)))
                (should (eq 'left (window-parameter laid 'window-side)))
                (should (eq laid (selected-window)))
                (should (eq one (window-buffer (harness-ui--fullscreen-window layout)))))
              ;; The tab F ran in shows the layout as it was.
              (tab-bar-select-tab (1+ here))
              (should (eq 'left (window-parameter (get-buffer-window view) 'window-side)))
              (should-not (window-parameter (get-buffer-window one) 'window-side))))
        (tab-bar-select-tab (1+ here))
        (while (> (length (funcall tab-bar-tabs-function)) tabs)
          (tab-bar-close-tab (+ 2 here)))
        (unless mode (tab-bar-mode -1))))))

(ert-deftest harness-ui-window-prefix-on-the-anchor-lays-it-out-in-a-new-frame ()
  "C-x 5 5 before F on the anchor lays it out in a new frame, not ending it here.
A batch Emacs makes no frame, so the frame made is the selected one:
what counts is that one was asked for and the anchor is laid out in it,
rather than F ending the layout."
  (harness-ui-test-with-fullscreen
    (let* ((made 0)
           (pop-up-frame-function (lambda () (cl-incf made) (selected-frame)))
           (main (selected-window)))
      (harness-ui-display-view view 'fullscreen)
      (select-window (get-buffer-window view))
      (harness-ui-test-with-keys (list (cons "C-c F" #'harness-fullscreen))
        (execute-kbd-macro (kbd "C-x 5 5 C-c F")))
      (should (= 1 made))
      (should-not (harness-ui-display-override-p))
      (let* ((layout (harness-ui--fullscreen-layout))
             (anchor (and layout (harness-ui--fullscreen-overview layout))))
        (should layout)
        (should (eq view (window-buffer anchor)))
        (should (eq 'left (window-parameter anchor 'window-side)))
        (should (eq one (window-buffer main)))))))

(ert-deftest harness-ui-bury-outside-the-fullscreen-layout ()
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window)))
      ;; In a window of the frame's own, back to the user's buffer.
      (harness-ui-display-buffer one 'full)
      (harness-ui-display-buffer two 'full)
      (should (eq two (window-buffer main)))
      (harness-ui-bury)
      (should (eq file (window-buffer main)))
      ;; A side window quits.
      (harness-ui-display-buffer one 'right)
      (let ((side (selected-window)))
        (should (window-parameter side 'window-side))
        (harness-ui-bury)
        (should-not (window-live-p side))
        (should (eq file (window-buffer main)))))))

(ert-deftest harness-ui-view-map-buries-with-q ()
  "A view mode inherits q and C-c C-z from `harness-ui-view-map'."
  (should (eq 'harness-ui-quit-view (lookup-key harness-ui-view-map (kbd "q"))))
  (should (eq 'harness-ui-bury (lookup-key harness-ui-view-map (kbd "C-c C-z"))))
  (should (eq special-mode-map (keymap-parent harness-ui-view-map))))

(ert-deftest harness-ui-view-p-tells-a-view-from-a-conversation ()
  "A harness view is what q buries; a session's chat is not one."
  (let ((chat (get-buffer-create "*harness view p chat*"))
        (plain (get-buffer-create "harness view p plain file")))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (setq-local harness-ui-session-id "s1")
            (setq-local major-mode 'harness-chat-mode))
          (should (harness-ui--session-buffer-p chat))
          (should-not (harness-ui-view-p chat))
          (should-not (harness-ui--session-buffer-p plain))
          (should-not (harness-ui-view-p plain)))
      (kill-buffer chat)
      (kill-buffer plain))))

(ert-deftest harness-ui-quit-view-buries-a-view ()
  "q on a harness view brings back the user's buffer, keeping the window."
  (harness-ui-test-with-fullscreen
    (let ((main (selected-window))
          (other (get-buffer-create "*harness quitting view*")))
      (unwind-protect
          (progn
            (with-current-buffer other (setq-local harness-ui-position 'right))
            (should (harness-ui-view-p other))
            ;; Over the user's file, in the frame's own window.
            (set-window-buffer main other)
            (select-window main)
            (harness-ui-quit-view)
            (should (window-live-p main))
            (should (eq file (window-buffer main)))
            (should (eq main (selected-window)))
            (should-not (get-buffer-window other)))
        (kill-buffer other)))))

(ert-deftest harness-ui-quit-view-buries-a-view-in-the-slot ()
  "q on a view in the slot brings back the user's buffer; the layout stays."
  (harness-ui-test-with-fullscreen
    (let ((in-slot (get-buffer-create "*harness quitting slot view*")))
      (unwind-protect
          (progn
            (with-current-buffer in-slot (setq-local harness-ui-position 'right))
            (harness-ui-display-view view 'fullscreen)
            (harness-ui-display-buffer in-slot)
            (let ((slot (harness-ui--fullscreen-window (harness-ui--fullscreen-layout))))
              (should (eq in-slot (window-buffer slot)))
              (harness-ui-quit-view)
              (should (harness-ui--fullscreen-layout))
              (should (eq file (window-buffer slot)))
              (should (eq view (window-buffer (harness-ui--fullscreen-overview
                                              (harness-ui--fullscreen-layout)))))
              ;; q on the anchor still ends the layout.
              (select-window (harness-ui--fullscreen-overview (harness-ui--fullscreen-layout)))
              (harness-ui-quit-view)
              (should-not (harness-ui--fullscreen-layout))))
        (kill-buffer in-slot)))))

(ert-deftest harness-ui-log-is-a-buryable-view ()
  "The harness log is a harness view: q buries it, and logging carries on."
  (harness-ui-test-with-fullscreen
    (when (get-buffer harness-log-buffer-name)
      (kill-buffer harness-log-buffer-name))
    (let ((main (selected-window))
          (buffer (get-buffer-create harness-log-buffer-name)))
      (unwind-protect
          (progn
            ;; Over the user's file, in the frame's own window.
            (let ((harness-ui-default-position 'full))
              (harness-show-log))
            (should (eq buffer (window-buffer main)))
            (with-current-buffer buffer
              (should (derived-mode-p 'harness-ui-log-mode))
              (should (harness-ui-view-p))
              (should (eq 'harness-ui-quit-view (key-binding (kbd "q"))))
              (should (eq 'harness-ui-bury (key-binding (kbd "C-c C-z"))))
              (should (eq 'harness-menu (key-binding (kbd "?"))))
              ;; The mode makes the buffer read-only; the harness logs to it
              ;; with `inhibit-read-only' bound, so a line still lands.
              (should buffer-read-only)
              (let ((before (buffer-size)))
                (harness-log 'info "log test %s" "line")
                (should (> (buffer-size) before))
                (should (save-excursion
                          (goto-char (point-min))
                          (search-forward "log test line" nil t)))))
            ;; q buries it: back to the user's file, the window kept.
            (select-window main)
            (harness-ui-quit-view)
            (should (window-live-p main))
            (should (eq file (window-buffer main)))
            (should (eq main (selected-window)))
            (should-not (get-buffer-window buffer)))
        (kill-buffer buffer)))))

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

(ert-deftest harness-ui-models-redraw-only-when-new ()
  "A model catalogue redraws every view only when it is new.
The harness says the catalogue was updated each time a provider
settles, mostly with nothing new, and each redraw fetched and rendered
every chat buffer again.  It is new when it changed, or when it is the
first over a connection (another harness may know other models)."
  (let ((harness-ui--models (make-hash-table :test 'equal))
        (harness-ui--models-seen nil)
        (harness-ui-connection 'first)
        (catalogue '((:id "demo:a") (:id "demo:b")))
        (redrawn 0) (got nil)
        (harness-ui-redraw-hook nil))
    (add-hook 'harness-ui-redraw-hook (lambda () (cl-incf redrawn)))
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (method _params callback &rest _)
                 (should (equal "_harness/provider/models" method))
                 (funcall callback (copy-tree catalogue)))))
      (harness-ui-refresh-models)
      (should (= 1 redrawn))
      (should (gethash "demo:b" harness-ui--models))
      ;; The same again: nothing to redraw, the callback still called.
      (harness-ui-refresh-models (lambda (models) (setq got models)))
      (should (= 1 redrawn))
      (should (equal catalogue got))
      ;; Changed.
      (setq catalogue '((:id "demo:a")))
      (harness-ui-refresh-models)
      (should (= 2 redrawn))
      (should-not (gethash "demo:b" harness-ui--models))
      ;; The same models, over another connection.
      (setq harness-ui-connection 'second)
      (harness-ui-refresh-models)
      (should (= 3 redrawn))
      (harness-ui-refresh-models)
      (should (= 3 redrawn)))))

(ert-deftest harness-ui-model-window-says-when-it-is-estimated ()
  "The model picker marks a window the catalogue estimated with a tilde."
  (should (equal "1.00M" (harness-ui-format-model-window '(:context-window 1000000))))
  (should (equal "~200k" (harness-ui-format-model-window '(:context-window 200000 :context-window-estimated t))))
  ;; JSON's false is no estimate.
  (should (equal "200k" (harness-ui-format-model-window '(:context-window 200000 :context-window-estimated :false))))
  ;; Unknown windows still get a face, against the harness's fallback window.
  (should (eq 'harness-context-ok-face (harness-ui-context-face 100000 nil)))
  (should (eq 'harness-context-critical-face (harness-ui-context-face 175000 nil))))

(ert-deftest harness-ui-thinking-menu-follows-the-model ()
  "The thinking menu offers a model's own levels, weakest first, so a
DeepSeek model (low, high, max) is not offered a medium or an xhigh that
DeepSeek would collapse onto high.  A model that names none gets the
common levels."
  (should (equal '("low" "high" "max")
                 (harness-ui--thinking-levels-for '("low" "high" "max"))))
  ;; Whatever order the model lists them in, the menu is weakest first.
  (should (equal '("low" "high" "max")
                 (harness-ui--thinking-levels-for '("max" "low" "high"))))
  (should (equal '("none" "minimal" "low" "medium" "high" "xhigh" "max")
                 (harness-ui--thinking-levels-for
                  '("max" "xhigh" "high" "medium" "low" "minimal" "none"))))
  (should (equal '("low" "medium" "high" "xhigh" "max")
                 (harness-ui--thinking-levels-for nil)))
  (let (offered sort chosen)
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (_method _params callback)
                 (funcall callback '(:id "deepseek:deepseek-flash"
                                     :thinking-levels ("low" "high" "max")))))
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (setq offered (all-completions "" table)
                       sort (completion-metadata-get (completion-metadata "" table nil)
                                                     'display-sort-function))
                 "high")))
      (harness-ui-choose-thinking
       (lambda (value label) (setq chosen (cons value label)))
       "deepseek:deepseek-flash"))
    (should (equal '("default" "low" "high" "max") offered))
    (should (eq 'identity sort))
    (should (equal '("high" . "high") chosen))))

(ert-deftest harness-ui-non-interactive-key-and-menu-label ()
  "C-c h i toggles non-interactive mode.  In the menu its entry says
whether what it toggles from the buffer is non-interactive, a session
or a board's new-task settings; from a buffer with neither it says
nothing about it and asks for nothing."
  (should (eq 'harness-toggle-non-interactive (lookup-key harness-ui-map (kbd "i"))))
  (should (eq 'harness-toggle-non-interactive (lookup-key harness-global-mode-map (kbd "C-c h i"))))
  (let ((harness-ui--sessions (make-hash-table :test 'equal))
        (harness-ui-sessions-changed-hook nil)
        (sent nil) (set nil))
    (harness-ui-cache-session '(:id "s-away" :non-interactive t))
    (harness-ui-cache-session '(:id "s-here" :non-interactive :false))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (error "Prompted")))
              ((symbol-function 'read-string) (lambda (&rest _) (error "Prompted")))
              ((symbol-function 'harness-ui-call) (lambda (_method params &rest _) (push params sent))))
      (harness-ui-test-with-menu-buffer #'fundamental-mode
        (let ((text (harness-ui-test-menu)))
          (should (string-match-p " i Non-interactive\\( \\|$\\)" text))
          (should-not (string-match-p "Non-interactive:" text))))
      (pcase-dolist (`(,sid ,label ,value) '(("s-away" "on" :false) ("s-here" "off" t)))
        (harness-ui-test-with-menu-buffer #'fundamental-mode
          (setq harness-ui-session-id sid)
          (should (string-match-p (concat " i Non-interactive: " label) (harness-ui-test-menu "i")))
          (should (equal (list :id sid :non-interactive value) (pop sent)))))
      ;; What a target function names, as the task board's new-task settings.
      (harness-ui-test-with-menu-buffer #'fundamental-mode
        (setq-local harness-ui-setting-target-function
                    (lambda () (list '(:non-interactive t) (lambda (key value) (push (list key value) set)))))
        (should (string-match-p " i Non-interactive: on" (harness-ui-test-menu "i")))
        (should (equal '((:non-interactive nil)) set))))
    (should-not sent)))

(ert-deftest harness-ui-move-session-asks-the-harness ()
  "C-c h W moves a session.  The harness gets the directory, absolute,
and the project the UI sees there; a prefix argument keeps the old
directory.  A remote session's directory goes as typed, a path on its
host, and no TRAMP connection is opened for it."
  (should (eq 'harness-move-session (lookup-key harness-ui-map (kbd "W"))))
  (should (eq 'harness-move-session (lookup-key harness-global-mode-map (kbd "C-c h W"))))
  (should (eq 'harness-move-session (symbol-function 'harness-session-move)))
  (let* ((harness-ui--sessions (make-hash-table :test 'equal))
         (harness-ui-sessions-changed-hook nil)
         (base (file-name-as-directory (file-truename (harness-test-temp-dir))))
         (repo (file-name-as-directory (expand-file-name "repo" base)))
         (sub (file-name-as-directory (expand-file-name "sub" repo)))
         (sent nil) (answer nil) (said nil))
    (unwind-protect
        (progn
          (make-directory sub t)
          (let ((default-directory repo)) (should (zerop (call-process "git" nil nil nil "init" "-q"))))
          (harness-ui-cache-session (list :id "s-here" :name "Here" :cwd base :project base))
          (harness-ui-cache-session (list :id "s-far" :name "Far" :cwd "/srv/app/" :host "/ssh:box:"))
          (cl-letf (((symbol-function 'harness-ui-call)
                     (lambda (method params callback &optional _on-error)
                       (push (cons method params) sent)
                       (funcall callback answer)))
                    ((symbol-function 'message)
                     (lambda (format &rest args) (push (apply #'format-message format args) said))))
            ;; Moved at once: the cache has the session where it is now.
            (setq answer (list :id "s-here" :name "Here" :cwd sub :project repo))
            (harness-move-session (concat repo "sub") "s-here")
            (should (equal (cons "_harness/session/move" (list :id "s-here" :dir sub :keep-old-dir :false :project repo))
                           (pop sent)))
            (should (equal sub (plist-get (harness-ui-session "s-here") :cwd)))
            (should (string-match-p "\\`Moved .*Here to .*/repo/sub/\\'" (pop said)))
            ;; Running a turn: it moves when the turn ends.
            (setq answer (list :id "s-here" :name "Here" :cwd sub :project repo :move (list :cwd base)))
            (harness-move-session base "s-here" t)
            (should (eq t (plist-get (cdr (pop sent)) :keep-old-dir)))
            (should (string-match-p "Here moves to .* when its turn ends\\'" (pop said)))
            ;; A remote session's directory is for its host to resolve.
            (setq answer (list :id "s-far" :name "Far" :cwd "/srv/other/" :host "/ssh:box:"))
            (harness-move-session "../other" "s-far")
            (should (equal (cons "_harness/session/move" (list :id "s-far" :dir "../other" :keep-old-dir :false))
                           (pop sent)))
            (should (string-match-p "Moved .*Far to /srv/other/\\'" (pop said)))))
      (delete-directory base t))))

(ert-deftest harness-ui-new-session-hands-the-buffer-to-its-callback ()
  "The harness makes a new session and the UI shows it a moment later.
The callback, when there is one, is called with the buffer shown, in
the position asked for; without one the session is just shown."
  (let ((sent nil) (shown nil) (got nil))
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (method params callback &optional _on-error)
                 (push (cons method params) sent)
                 (funcall callback (list :sessionId "s-new"))))
              ((symbol-function 'harness-ui-refresh-sessions)
               (lambda (&optional callback) (when callback (funcall callback nil))))
              ((symbol-function 'harness-ui-display-session)
               (lambda (id &optional position _frame) (push (list id position) shown) 'the-buffer)))
      (harness-new-session "/tmp/proj/" 'right (lambda (buffer) (setq got buffer)))
      (should (eq 'the-buffer got))
      (should (equal '(("s-new" right)) shown))
      (should (equal "session/new" (car (car sent))))
      (should (equal "/tmp/proj/" (plist-get (cdr (car sent)) :cwd)))
      (setq got nil shown nil)
      (harness-new-session "/tmp/proj/")
      (should-not got)
      (should (equal '(("s-new" nil)) shown)))))

(ert-deftest harness-ui-menu-offers-prompting-with-the-region ()
  "The menu has > from any buffer: prompt a session with the region."
  (harness-ui-test-with-menu-buffer #'fundamental-mode
    (should (fboundp 'harness-prompt-region))
    (should (string-match-p "> +Prompt with the region" (harness-ui-test-menu)))))

(ert-deftest harness-ui-tool-outcome-tells-denied-from-failed ()
  "A refused call is `denied' whatever else its result says; one that
ran and reported an error is `failed'.  Wire values: a call that was
not refused carries `:denied' null (nil) or false."
  (should-not (harness-ui-tool-outcome nil))
  (should (eq 'ok (harness-ui-tool-outcome '(:kind "tool-result" :output "fine" :is-error :false))))
  (should (eq 'ok (harness-ui-tool-outcome '(:output "fine" :is-error nil :meta (:denied :false)))))
  (should (eq 'failed (harness-ui-tool-outcome '(:output "exit 1" :is-error t))))
  (should (eq 'failed (harness-ui-tool-outcome '(:output "exit 1" :is-error t :meta (:denied nil :duration 0.1)))))
  (should (eq 'denied (harness-ui-tool-outcome '(:output "Denied: no" :is-error t :meta (:denied t))))))

(defvar harness-ui--sessions)

(ert-deftest harness-ui-task-title-is-the-session-name-else-the-prompt ()
  "A task's title, on the board and in the session list, is its session's
name once it has one, else its prompt's first line: a session is named
after its first turn, so a task at work has none yet."
  (let ((task '(:id "t-1" :session "s-1" :prompt "\n  Add CSV export to reports  \n\nFinance wants it.")))
    (should (equal "Add CSV export to reports" (harness-ui-task-title task '(:id "s-1" :name nil))))
    (should (equal "Add CSV export to reports" (harness-ui-task-title task '(:id "s-1" :name "  "))))
    (should (equal "Export orders as CSV" (harness-ui-task-title task '(:id "s-1" :name "Export orders as CSV"))))
    ;; Without SESSION: the task's session in the cache, if any.
    (let ((harness-ui--sessions (make-hash-table :test 'equal)))
      (should (equal "Add CSV export to reports" (harness-ui-task-title task)))
      (puthash "s-1" '(:id "s-1" :name "Export orders as CSV") harness-ui--sessions)
      (should (equal "Export orders as CSV" (harness-ui-task-title task)))
      (should (equal "Add CSV export to reports" (harness-ui-task-title (plist-put (copy-sequence task) :session nil)))))
    ;; A long first line is shortened.
    (should (= 72 (length (harness-ui-task-title (list :prompt (make-string 100 ?x))))))))

(ert-deftest harness-ui-task-title-is-the-task-name-before-the-session-has-one ()
  "A task is named as soon as it is submitted: one waiting for a slot, or
whose session has no name yet, is called by its own name.  Its
session's name, once it has one, comes first."
  (let ((task '(:id "t-1" :name "Export orders as CSV" :prompt "Add CSV export to reports\n\nFinance wants it.")))
    (should (equal "Export orders as CSV" (harness-ui-task-title task)))
    (should (equal "Export orders as CSV" (harness-ui-task-name task)))
    (should (equal "Export orders as CSV" (harness-ui-task-title task '(:id "s-1" :name nil))))
    (should (equal "CSV export for finance"
                   (harness-ui-task-title task '(:id "s-1" :name "CSV export for finance"))))
    ;; Without a name the title is the prompt, and the task has no name.
    (let ((nameless (plist-put (copy-sequence task) :name "  ")))
      (should (equal "Add CSV export to reports" (harness-ui-task-title nameless)))
      (should-not (harness-ui-task-name nameless))
      (should-not (harness-ui-task-name nameless '(:id "s-1" :name ""))))))

;;;; Internal sessions

;; The harness records each model call it makes on its own -- the
;; permission and session judges, naming a session -- as a session of
;; kind internal: one per call, many an hour.  They are in the cache,
;; for the session list to show on request, but no other view picks one,
;; counts it or reloads for it.

(defvar harness-ui--internal-ids)

(defmacro harness-ui-test-with-sessions (sessions &rest body)
  "Run BODY with the session cache holding SESSIONS, a list of plists, only.
The record of internal ids starts empty, and the hook the cache runs is off."
  (declare (indent 1))
  `(let ((harness-ui--sessions (make-hash-table :test 'equal))
         (harness-ui--internal-ids (make-hash-table :test 'equal))
         (harness-ui-sessions-changed-hook nil))
     (dolist (s ,sessions) (harness-ui-cache-session s))
     ,@body))

(defconst harness-ui-test--mixed-sessions
  '((:id "main-1" :name "Fix the parser" :kind "main" :project "/p/" :updated 10)
    (:id "int-1" :name "Permission judge" :kind "internal" :project "/p/" :updated 20)
    (:id "sub-1" :name "Worker" :kind "subagent" :project "/p/" :updated 5))
  "Sessions of the user's and an internal one, the internal one the newest.")

(ert-deftest harness-ui-read-session-does-not-offer-an-internal-session ()
  "Switching to a session offers the user's sessions, not the harness's records.
An internal session is in the cache, and the newest there, but it is no
session to switch to.  A predicate narrows the rest; the callers get the
session chosen, and a cache of nothing else reads as no sessions."
  (harness-ui-test-with-sessions harness-ui-test--mixed-sessions
    (let (offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq offered (mapcar #'car table))
                   (car (car table)))))
        (should (equal "main-1" (plist-get (harness-ui-read-session "Switch to session: ") :id)))
        (should (= 2 (length offered)))
        (should-not (cl-some (lambda (label) (string-search "Permission judge" label)) offered))
        (should (equal "sub-1" (plist-get (harness-ui-read-session
                                           "Open: " (lambda (s) (equal "subagent" (plist-get s :kind))))
                                          :id)))
        (should (= 1 (length offered)))
        ;; The predicate cannot bring one back.
        (harness-ui-read-session "Open: " (lambda (s) (equal "internal" (plist-get s :kind))))
        (should-not offered)
        ;; A session to act on, without a buffer's own: the choice.
        (should (equal "main-1" (harness-ui-current-session-id)))
        ;; Switching shows the session chosen.
        (let (shown)
          (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
                     (lambda (&optional callback) (when callback (funcall callback nil))))
                    ((symbol-function 'harness-ui-display-session)
                     (lambda (id &rest _) (setq shown id))))
            (harness-switch-session))
          (should (equal "main-1" shown)))
        (should (equal '("main-1" "sub-1")
                       (mapcar (lambda (s) (plist-get s :id)) (harness-ui-user-sessions))))
        ;; The cache holds it all the same.
        (should (= 3 (length (harness-ui-sessions))))))
    (harness-ui-test-with-sessions '((:id "int-1" :kind "internal" :updated 20))
      (should-not (harness-ui-user-sessions))
      (should-not (harness-ui-current-session-id t))
      (should-error (harness-ui-current-session-id) :type 'user-error))))

(ert-deftest harness-ui-internal-event-tells-a-session-by-its-event-the-cache-or-the-record ()
  "An event of an internal session is told by the session it carries, the cache or the record.
`session/created' carries the session and `session/status' only its id
and status; a `session/deleted' with only the id may come after the
cache forgot the session, so what was seen of it before decides.  What
nothing is known about is not taken for an internal session, and no other
event is ever one's."
  (harness-ui-test-with-sessions nil
    (let ((internal '(:id "int-1" :kind "internal" :name "Permission judge"))
          (main '(:id "main-1" :kind "main" :name "Fix the parser")))
      ;; The creation carries the session; the id is remembered from it.
      (should (harness-ui-internal-event-p "session/created" (list "int-1" internal)))
      (should-not (harness-ui-internal-event-p "session/created" (list "main-1" main)))
      (should (harness-ui-internal-event-p "session/status" (list "int-1" "running")))
      (should-not (harness-ui-internal-event-p "session/status" (list "main-1" "running")))
      (should-not (harness-ui-internal-event-p "session/status" (list "stranger" "idle")))
      ;; The cache tells a session never seen created.
      (puthash "int-2" '(:id "int-2" :kind "internal") harness-ui--sessions)
      (should (harness-ui-internal-event-p "session/status" (list "int-2" "idle")))
      ;; A deletion carries the session on the wire, or only the id, the
      ;; cache having let it go: then the record has it.
      (harness-ui--forget-session "int-1")
      (should-not (harness-ui-session "int-1"))
      (should (harness-ui-internal-event-p "session/deleted" (list "int-1")))
      (should (harness-ui-internal-event-p "session/deleted" (list "int-1" internal)))
      (should-not (harness-ui-internal-event-p "session/deleted" (list "main-1")))
      ;; Only the events views reload for are told apart.
      (should-not (harness-ui-internal-event-p "agent/turn-ended" (list "int-1")))
      (should-not (harness-ui-internal-event-p "session/ext-changed" (list "int-1" "priority" "low")))
      (should-not (harness-ui-internal-event-p "session/created" nil))
      (should-not (harness-ui-internal-event-p "session/created" '(nil)))
      (should-not (harness-ui-internal-event-p "session/created" '(:id))))))

(ert-deftest harness-ui-event-of-an-internal-session-fetches-no-session-list ()
  "The creation and deletion of an internal session do not reload the session cache.
Those of a session of the user's do, as they did.  The cache hears of an
internal session from its own updates; it comes and goes with every
model call the harness makes on its own.  Every listener of the
deletion can still tell the session was internal, and the id is
forgotten once it has been told."
  (harness-ui-test-with-sessions nil
    (let ((harness-ui-event-functions nil)
          (fetched 0)
          (heard nil))
      (add-hook 'harness-ui-event-functions
                (lambda (event args) (push (list event (harness-ui-internal-event-p event args)) heard)))
      (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
                 (lambda (&rest _) (cl-incf fetched))))
        (cl-flet ((event (name &rest args)
                    (setq heard nil)
                    (harness-ui--dispatch-ui "_harness/event" (list :event name :args args) nil)
                    (car heard)))
          ;; A session of the user's: fetched.
          (should (equal '("session/created" nil)
                         (event "session/created" "main-1" '(:id "main-1" :kind "main"))))
          (should (= 1 fetched))
          ;; An internal session's creation and status: not fetched, and
          ;; every listener can tell.
          (should (equal '("session/created" t)
                         (event "session/created" "int-1" '(:id "int-1" :kind "internal"))))
          (should (equal '("session/status" t) (event "session/status" "int-1" "running")))
          (should (= 1 fetched))
          ;; Its deletion, with the cache having forgotten it: nor fetched.
          (harness-ui--forget-session "int-1")
          (should (equal '("session/deleted" t) (event "session/deleted" "int-1")))
          (should (= 1 fetched))
          (should-not (gethash "int-1" harness-ui--internal-ids))
          ;; Forgotten: a later event of that id is an ordinary one's.
          (should (equal '("session/deleted" nil) (event "session/deleted" "int-1")))
          (should (= 2 fetched))
          (should (equal '("session/deleted" nil) (event "session/deleted" "main-1")))
          (should (= 3 fetched)))))))

(ert-deftest harness-ui-cache-remembers-which-sessions-are-internal ()
  "The record of internal ids follows the cache, and a fetch of every session sets it.
An internal session is remembered whenever it is cached; the whole list
replaces the record, so ids of sessions gone while the UI was not
listening do not pile up."
  (harness-ui-test-with-sessions '((:id "int-1" :kind "internal") (:id "main-1" :kind "main"))
    (should (gethash "int-1" harness-ui--internal-ids))
    (should-not (gethash "main-1" harness-ui--internal-ids))
    (harness-ui-cache-session '(:id "int-2" :kind "internal" :status "running"))
    (should (gethash "int-2" harness-ui--internal-ids))
    ;; The harness may write the kind as a symbol or a string.
    (harness-ui-cache-session '(:id "int-3" :kind internal))
    (should (gethash "int-3" harness-ui--internal-ids))
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (method _params callback &rest _)
                 (should (equal "_harness/session/list" method))
                 (funcall callback (list '(:id "int-2" :kind "internal") '(:id "main-1" :kind "main"))))))
      (harness-ui-refresh-sessions))
    (should-not (gethash "int-1" harness-ui--internal-ids))
    (should (gethash "int-2" harness-ui--internal-ids))
    (should-not (gethash "int-3" harness-ui--internal-ids))
    (should-not (gethash "main-1" harness-ui--internal-ids))
    (should (equal '("main-1" "int-2")
                   (sort (mapcar (lambda (s) (plist-get s :id)) (harness-ui-sessions))
                         (lambda (a b) (string> a b)))))))

;;;; The prefix key

(ert-deftest harness-ui-prefix-key-moves-the-keys ()
  "The keys are under C-c h, and setting `harness-ui-prefix-key' moves them.
C-c a, the old prefix, stays free: users bind it themselves, to Org's
agenda or Embark for instance."
  (cl-flet ((prefix-p (keys) (eq harness-ui-map (lookup-key harness-global-mode-map keys))))
    (should (equal "C-c h" (eval (car (get 'harness-ui-prefix-key 'standard-value)) t)))
    (should (prefix-p (kbd "C-c h")))
    (should-not (prefix-p (kbd "C-c a")))
    (let ((before harness-ui-prefix-key))
      (unwind-protect
          (progn
            (setopt harness-ui-prefix-key "C-c x")
            (should (prefix-p (kbd "C-c x")))
            (should-not (prefix-p (kbd "C-c h")))
            ;; A vector of events, which Customize stored before the option
            ;; took key descriptions.
            (customize-set-variable 'harness-ui-prefix-key [f12])
            (should (prefix-p [f12]))
            (should-not (prefix-p (kbd "C-c x"))))
        (setopt harness-ui-prefix-key before))
      (should (prefix-p (kbd "C-c h")))
      (should-not (prefix-p [f12])))))

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

;;;; Tools by their labels

(defmacro harness-ui-test-with-tools (specs &rest body)
  "Run BODY with the tool cache holding SPECS, as `tools/list' returns them."
  (declare (indent 1))
  `(let ((harness-ui--tools (make-hash-table :test 'equal))
         (harness-ui--tools-fetch nil)
         (harness-ui--tools-generation 0))
     (dolist (spec ,specs) (puthash (plist-get spec :name) spec harness-ui--tools))
     ,@body))

(ert-deftest harness-ui-tools-go-by-their-labels ()
  "Views name a tool by its label, the name the model calls it by when it has none."
  (harness-ui-test-with-tools '((:name "read_file" :label "Read file") (:name "bash" :label "Bash"))
    (should (equal "Read file" (harness-ui-tool-label "read_file")))
    (should (equal "t_unknown" (harness-ui-tool-label "t_unknown")))
    ;; A title is the label, then what the call is about.
    (should (equal '("Read file" . "a.el") (harness-ui-tool-title-parts "read_file" "Read file: a.el")))
    (should (equal '("Bash" . nil) (harness-ui-tool-title-parts "bash" "Bash")))
    (should (equal '("Bash" . nil) (harness-ui-tool-title-parts "bash" nil)))
    ;; One recorded before tools had labels starts with the tool's name.
    (should (equal '("Read file" . "a.el:1-9") (harness-ui-tool-title-parts "read_file" "read_file a.el:1-9")))
    (should (equal '("Bash" . nil) (harness-ui-tool-title-parts "bash" "bash")))
    (should (equal "Read file: a.el" (harness-ui-tool-title "read_file" "read_file a.el")))
    (should (equal "Read file: a.el" (harness-ui-tool-title "read_file" "Read file: a.el")))
    ;; A title of another shape, such as a directory prompt's, stays as it is.
    (should (equal '(nil . "Access ~/notes/") (harness-ui-tool-title-parts "read_file" "Access ~/notes/")))
    (should (equal "Access ~/notes/" (harness-ui-tool-title "read_file" "Access ~/notes/")))
    ;; In a header the label's face sets it apart from the rest, in place of the colon.
    (let ((s (harness-ui-tool-title-string "read_file" "Read file: a.el")))
      (should (equal "Read file a.el" s))
      (should (eq 'harness-tool-title-face (get-text-property 0 'face s)))
      (should (eq 'harness-tool-title-face (get-text-property 8 'face s)))
      (should (eq 'harness-tool-subject-face (get-text-property 10 'face s))))
    (let ((s (harness-ui-tool-title-string "read_file" "Read file: a-rather-long-file-name.el" 14)))
      (should (= 14 (length s))))
    (let ((s (harness-ui-tool-title-string "read_file" "Access ~/notes/")))
      (should (equal "Access ~/notes/" s))
      (should (eq 'harness-tool-title-face (get-text-property 0 'face s))))))

(ert-deftest harness-ui-tools-are-fetched-once-per-connection ()
  "Every tool's spec is fetched once, again after a reload or reconnect."
  (harness-ui-test-with-tools nil
    (setq harness-ui--tools nil)
    (let ((asked nil))
      (cl-letf (((symbol-function 'harness-ui-request)
                 (lambda (method params)
                   (push (list method params) asked)
                   (harness-resolved (list (list :name "bash" :label "Bash"))))))
        (should (equal "bash" (harness-ui-tool-label "bash")))
        (let ((table (harness-test-await (harness-ui-fetch-tools))))
          (should (equal "Bash" (plist-get (gethash "bash" table) :label))))
        ;; Every tool, not one session's.
        (should (equal '(("_harness/tools/list" nil)) asked))
        (should (equal "Bash" (harness-ui-tool-label "bash")))
        (harness-test-await (harness-ui-fetch-tools))
        (should (= 1 (length asked)))
        (harness-ui--forget-tools)
        (should (equal "bash" (harness-ui-tool-label "bash")))
        (harness-test-await (harness-ui-fetch-tools))
        (should (= 2 (length asked)))
        (should (equal "Bash" (harness-ui-tool-label "bash"))))
      ;; A failed fetch leaves names in place and is tried again next time.
      (harness-ui--forget-tools)
      (cl-letf (((symbol-function 'harness-ui-request) (lambda (&rest _) (harness-rejected '(error "down")))))
        (let ((table (harness-test-await (harness-ui-fetch-tools))))
          (should (hash-table-p table))
          (should (zerop (hash-table-count table))))
        (should-not harness-ui--tools)
        (should-not harness-ui--tools-fetch)))))

;;;; Corporate mode

(defconst harness-ui-test-corporate-refusal
  (format-message "Corporate mode is on: the UI connects only to this Emacs's own harness")
  "What `harness-connect-remote' says when corporate mode refuses an address.")

(ert-deftest harness-ui-connect-remote-refused-in-corporate-mode ()
  "In corporate mode the UI connects to its own harness only: an address
is refused, and an empty one still goes back to the local harness."
  (harness-ui-test-with-connect-stub connected
    (let ((harness-corporate-mode t) (harness-process t))
      (let ((err (should-error (harness-connect-remote "example.org:9000") :type 'user-error)))
        (should (equal harness-ui-test-corporate-refusal (error-message-string err))))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "127.0.0.1:9000")))
        (should-error (call-interactively #'harness-connect-remote) :type 'user-error))
      (should-not connected)
      (harness-connect-remote "")
      (harness-connect-remote nil)
      (should (equal '(process process) connected)))))

(ert-deftest harness-ui-connect-stays-local-in-corporate-mode ()
  "In corporate mode a remote address gives way to the local harness,
whoever asks for it: an address set before `harness-start', say, or a
reconnection."
  (let ((harness-ui-connection nil) (harness-ui-connection-address nil)
        (harness-ui--server-address nil) (opened nil) (started 0))
    (cl-letf (((symbol-function 'harness-ui--open) (lambda (address token) (push (cons address token) opened) nil))
              ((symbol-function 'harness-ui--ensure-server) (lambda () (cl-incf started))))
      (let ((harness-corporate-mode t))
        (let ((harness-process t))
          (harness-ui-connect "example.org:9000")
          (should (eq 'process harness-ui-connection-address))
          (should (= 1 started))
          (should-not opened))
        (let ((harness-process nil))
          (harness-ui-connect "example.org:9000")
          (should-not harness-ui-connection-address)
          (should (equal '((nil . nil)) opened))))
      (let ((harness-corporate-mode nil))
        (harness-ui-connect "example.org:9000")
        (should (equal "example.org:9000" harness-ui-connection-address))
        (should (equal '("example.org:9000" . nil) (car opened)))))))

(ert-deftest harness-ui-menu-connect-remote-is-inapt-in-corporate-mode ()
  "The menu shows Connect remote as inapt in corporate mode."
  (cl-flet ((inapt-p ()
              (harness-ui-test-with-menu-buffer #'fundamental-mode
                (call-interactively #'harness-menu)
                (unwind-protect
                    (with-current-buffer transient--buffer-name
                      (goto-char (point-min))
                      (should (search-forward "Connect remote" nil t))
                      (and (memq 'transient-inapt-suffix
                                 (ensure-list (get-text-property (match-beginning 0) 'face)))
                           t))
                  (execute-kbd-macro (kbd "C-g"))))))
    (let ((harness-corporate-mode nil)) (should-not (inapt-p)))
    (let ((harness-corporate-mode t)) (should (inapt-p)))))

(ert-deftest harness-ui-server-exit-of-a-replaced-process-is-ignored ()
  "The end of a harness process the UI no longer runs changes nothing.
A process stopped for a restart can be reported gone after its
successor started: the UI keeps the successor and starts no third one.
The end of the process it runs is news, and restarts it."
  (let ((old (make-pipe-process :name "harness-ui-test-old" :noquery t))
        (current (make-pipe-process :name "harness-ui-test-current" :noquery t))
        (scheduled nil))
    (unwind-protect
        (cl-letf (((symbol-function 'run-at-time) (lambda (&rest args) (push args scheduled) nil))
                  ((symbol-function 'message) #'ignore))
          (let ((harness-ui--server current)
                (harness-ui--server-address '("127.0.0.1:1" . "token"))
                (harness-ui--server-stopping nil)
                (harness-ui--server-restarts nil))
            (harness-ui--on-server-exit 15 old)
            (should (eq current harness-ui--server))
            (should harness-ui--server-address)
            (should-not scheduled)
            (harness-ui--on-server-exit 9 current)
            (should-not harness-ui--server)
            (should-not harness-ui--server-address)
            (should (= 1 (length scheduled)))))
      (delete-process old)
      (delete-process current))))

(defmacro harness-ui-test-with-corporate-change (&rest body)
  "Run BODY with `harness-restart' and `harness-ui-connect' recorded, not run.
RESTARTS counts the restarts, CONNECTED lists the addresses connected
to, oldest first, and REDRAWN counts the redraws.  SERVER is a live
process standing for the harness process."
  (declare (indent 0))
  `(let ((server (make-pipe-process :name "harness-ui-test-server" :noquery t))
         (restarts 0) (redrawn 0)
         (harness-ui-connection nil) (harness-process t))
     (unwind-protect
         (harness-ui-test-with-connect-stub connected
           (add-hook 'harness-ui-redraw-hook (lambda () (cl-incf redrawn)))
           (cl-letf (((symbol-function 'harness-restart) (lambda () (cl-incf restarts))))
             ,@body))
       (delete-process server))))

(ert-deftest harness-ui-corporate-mode-change-restarts-the-running-process ()
  "A change of corporate mode restarts the harness process the UI uses,
when it runs.  While Emacs initialises it has not started yet."
  (harness-ui-test-with-corporate-change
    (let ((harness-ui-connection-address 'process) (harness-ui--server server))
      (dolist (on '(t nil))
        (let ((harness-corporate-mode on))
          (harness-ui--corporate-mode-changed)))
      (should (= 2 restarts)))
    ;; Not started yet, as while Emacs initialises.
    (let ((harness-ui-connection-address 'process) (harness-ui--server nil)
          (harness-corporate-mode t))
      (harness-ui--corporate-mode-changed))
    ;; A harness in this Emacs reads the option as it goes.
    (let ((harness-ui-connection-address nil) (harness-ui--server server)
          (harness-corporate-mode t))
      (harness-ui--corporate-mode-changed))
    (should (= 2 restarts))
    (should-not connected)
    (should (= 0 redrawn))))

(ert-deftest harness-ui-corporate-mode-on-leaves-a-remote-harness ()
  "Corporate mode turned on takes the UI off a remote harness, back to
the local one, whose process restarts when it runs.  Turned off, it
leaves the UI where it is."
  (harness-ui-test-with-corporate-change
    (let ((harness-ui-connection-address "example.org:9000") (harness-ui--server server)
          (harness-corporate-mode nil))
      (harness-ui--corporate-mode-changed)
      (should (equal "example.org:9000" harness-ui-connection-address)))
    (should (= 0 restarts))
    ;; No harness process runs: the UI connects to a new one.
    (let ((harness-ui-connection-address "example.org:9000") (harness-ui--server nil)
          (harness-corporate-mode t))
      (harness-ui--corporate-mode-changed)
      (should (eq 'process harness-ui-connection-address)))
    (should (equal '(process) connected))
    (should (= 0 restarts))
    (should (= 1 redrawn))
    ;; It runs: it restarts, which connects the UI to it and redraws.
    (let ((harness-ui-connection-address "example.org:9000") (harness-ui--server server)
          (harness-corporate-mode t))
      (harness-ui--corporate-mode-changed)
      (should (eq 'process harness-ui-connection-address)))
    (should (equal '(process) connected))
    (should (= 1 restarts))
    (should (= 1 redrawn))
    ;; The harness runs in this Emacs: the UI connects to it there.
    (let ((harness-ui-connection-address "example.org:9000") (harness-ui--server nil)
          (harness-process nil) (harness-corporate-mode t))
      (harness-ui--corporate-mode-changed)
      (should-not harness-ui-connection-address))
    (should (equal '(process nil) connected))
    (should (= 2 redrawn))))

(ert-deftest harness-ui-init-hooks-corporate-mode-changes ()
  "The UI's init adds its function to `harness-corporate-mode-change-hook'
once, and a change made with `setopt' reaches it."
  (let ((harness-corporate-mode-change-hook nil)
        (kill-emacs-hook nil))
    (cl-letf (((symbol-function 'harness-global-mode) #'ignore))
      (harness-ui-test-with-corporate-change
        (harness-ui--init)
        (harness-ui--init)
        (should (equal '(harness-ui--corporate-mode-changed) harness-corporate-mode-change-hook))
        (let ((harness-ui-connection-address 'process) (harness-ui--server server))
          (unwind-protect
              (progn
                (setopt harness-corporate-mode t)
                (should (= 1 restarts))
                ;; The same value again is no change.
                (setopt harness-corporate-mode t)
                (should (= 1 restarts)))
            (setopt harness-corporate-mode nil))
          (should (= 2 restarts)))))))

(ert-deftest harness-ui-set-model-all-switches-and-sets-default ()
  "`harness-set-model-all' retargets every session and the new-session default."
  (let ((calls nil))
    (cl-letf (((symbol-function 'harness-ui-refresh-models)
               (lambda (&optional callback)
                 (funcall callback
                          (list (list :id "deepseek:deepseek-flash" :label "DeepSeek V4.1 Flash"
                                      :provider-label "DeepSeek" :context-window 1048576
                                      :pricing '(:input 0.15 :output 0.60))))))
              ((symbol-function 'harness-ui-call)
               (lambda (method params &optional callback _on-error)
                 (push (cons method params) calls)
                 (when callback
                   (funcall callback (and (equal method "_harness/session/set-all") '("s1" "s2"))))))
              ((symbol-function 'completing-read) (lambda (_prompt table &rest _) (caar table))))
      (call-interactively #'harness-set-model-all))
    (let ((config (cdr (assoc "_harness/config/set" calls)))
          (bulk (cdr (assoc "_harness/session/set-all" calls))))
      (should (equal "harness-model" (plist-get config :key)))
      (should (equal "deepseek:deepseek-flash" (plist-get config :value)))
      (should (equal "global" (plist-get config :scope)))
      (should (equal "deepseek:deepseek-flash" (plist-get (plist-get bulk :settings) :model)))
      (should (equal '(:active t :tasks t) (plist-get bulk :filter)))
      ;; The current tasks of every project: no `:cwd'.
      (should (equal '(:settings (:model "deepseek:deepseek-flash")) (cdr (assoc "_harness/task/set-all" calls))))
      (should (assoc "_harness/config/overrides" calls)))))

(ert-deftest harness-ui-set-model-all-prefix-leaves-the-default-alone ()
  "A prefix argument switches the sessions but keeps the new-session default."
  (let ((calls nil))
    (cl-letf (((symbol-function 'harness-ui-refresh-models)
               (lambda (&optional callback)
                 (funcall callback (list (list :id "deepseek:deepseek-flash" :label "DeepSeek V4.1 Flash"
                                               :provider-label "DeepSeek" :context-window 1048576)))))
              ((symbol-function 'harness-ui-call)
               (lambda (method params &optional callback _on-error)
                 (push (cons method params) calls)
                 (when callback (funcall callback nil))))
              ((symbol-function 'completing-read) (lambda (_prompt table &rest _) (caar table))))
      (harness-set-model-all t))
    (should-not (assoc "_harness/config/set" calls))
    (should (equal "deepseek:deepseek-flash"
                   (plist-get (plist-get (cdr (assoc "_harness/session/set-all" calls)) :settings) :model)))
    (should (equal '(:settings (:model "deepseek:deepseek-flash")) (cdr (assoc "_harness/task/set-all" calls))))
    ;; No new default, so nothing to say about what overrides it.
    (should-not (assoc "_harness/config/overrides" calls))))

(defmacro harness-ui-test-with-all (answers &rest body)
  "Run BODY with the harness answering every request from ANSWERS.
ANSWERS maps a method to its result.  BODY sees CALLS, the requests
made, newest first; SAID, the messages said, newest first; and SET, the
arguments of the calls of `harness-ui-set-all-functions', which stands
for two open boards, of /p/ and /q/."
  (declare (indent 1))
  `(let ((calls nil) (said nil) (set nil))
     (let ((harness-ui-set-all-functions
            (list (lambda (key value) (push (list key value) set) (list "/p/" "/q/")))))
       (cl-letf (((symbol-function 'harness-ui-call)
                  (lambda (method params &optional callback _on-error)
                    (push (cons method params) calls)
                    (when callback (funcall callback (cdr (assoc method ,answers))))))
                 ((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (when format-string (push (apply #'format format-string args) said)))))
         ,@body))))

(ert-deftest harness-ui-set-non-interactive-all-changes-everything ()
  "C-c h I, beside C-c h i for one session as M is beside m, turns
non-interactive on or off, offering on first, for every session and
current task of every project, for the open boards' next tasks and as
the default for new sessions.  It says how many sessions and tasks
changed, and what keeps the new default from new work: here a
project's .dir-locals.el and a directory's."
  (should (eq 'harness-set-non-interactive-all (lookup-key harness-ui-map (kbd "I"))))
  (should (eq 'harness-set-non-interactive-all (lookup-key harness-global-mode-map (kbd "C-c h I"))))
  (should (eq 'harness-toggle-non-interactive (lookup-key harness-global-mode-map (kbd "C-c h i"))))
  ;; Beside i in the menu's session settings, as M is beside m.
  (let* ((column (transient-get-suffix 'harness-menu '(0 1)))
         (keys (mapcar (lambda (suffix) (plist-get (harness-ui-test--suffix-plist suffix) :key))
                       (aref column (1- (length column))))))
    (should (equal "Session settings" (plist-get (aref column (- (length column) 2)) :description)))
    (should (equal '("i" "I") (seq-take (member "i" keys) 2)))
    (should (equal '("m" "M") (seq-take (member "m" keys) 2)))
    ;; The supervisor's all-command sits with them, behind I.
    (should (equal '("I" "V") (seq-take (member "I" keys) 2))))
  (harness-ui-test-with-all
      (list (cons "_harness/session/set-all" '("s1" "s2" "s3"))
            (cons "_harness/task/set-all" '("t1"))
            (cons "_harness/config/overrides"
                  '(:key "harness-non-interactive" :value "t"
                    :files ((:file "/p/.dir-locals.el" :scope "project" :dir "/p/" :project "p" :value "nil")
                            (:file "/q/sub/.dir-locals.el" :scope "directory" :dir "/q/sub/" :project "q"
                             :value "nil")))))
    (let (offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table _pred require _initial _hist def)
                   (setq offered (list (all-completions "" table)
                                       (completion-metadata-get (completion-metadata "" table nil)
                                                                'display-sort-function)
                                       require def))
                   def)))
        (call-interactively #'harness-set-non-interactive-all))
      (should (equal '(("on" "off") identity t "on") offered)))
    (should (equal '((:non-interactive t)) set))
    ;; Sessions, then tasks (whose sessions have it already), then the default.
    (should (equal '("_harness/session/set-all" "_harness/task/set-all"
                     "_harness/config/set" "_harness/config/overrides")
                   (reverse (mapcar #'car calls))))
    (should (equal '(:settings (:non-interactive t) :filter (:active t :tasks t))
                   (cdr (assoc "_harness/session/set-all" calls))))
    (should (equal '(:settings (:non-interactive t)) (cdr (assoc "_harness/task/set-all" calls))))
    (should (equal '(:key "harness-non-interactive" :value "t" :printed t :scope "global")
                   (cdr (assoc "_harness/config/set" calls))))
    (should (equal '(:key "harness-non-interactive" :value "t" :printed t :dirs ("/p/" "/q/"))
                   (cdr (assoc "_harness/config/overrides" calls))))
    (should (equal (list (concat "Non-interactive on for 3 sessions and 1 task, and for new sessions"
                                 " and the open boards' new tasks.  But new sessions in p start interactive"
                                 " (harness-non-interactive in /p/.dir-locals.el), new sessions in /q/sub/"
                                 " start interactive (harness-non-interactive in /q/sub/.dir-locals.el);"
                                 " M-x harness-settings changes them."))
                   said)))
  ;; Off, when nothing overrides it: just the counts.
  (harness-ui-test-with-all
      (list (cons "_harness/session/set-all" '("s1"))
            (cons "_harness/task/set-all" '("t1" "t2"))
            (cons "_harness/config/overrides" '(:key "harness-non-interactive" :value "nil")))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "off")))
      (harness-set-non-interactive-all))
    (should (equal '((:non-interactive nil)) set))
    (should (equal '(:settings (:non-interactive :false) :filter (:active t :tasks t))
                   (cdr (assoc "_harness/session/set-all" calls))))
    (should (equal "nil" (plist-get (cdr (assoc "_harness/config/set" calls)) :value)))
    (should (equal '("Non-interactive off for 1 session and 2 tasks, and for new sessions and the open boards' new tasks")
                   said))))

(ert-deftest harness-ui-set-non-interactive-all-prefix-leaves-the-default-alone ()
  "With a prefix argument C-c h I leaves the default for new sessions alone.
The boards' next tasks still change.  Turned on, there is no new default
to say anything about; turned off, what still turns new work on is said
all the same."
  (harness-ui-test-with-all
      (list (cons "_harness/session/set-all" '("s1"))
            (cons "_harness/task/set-all" nil))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "on")))
      (harness-set-non-interactive-all t))
    (should (equal '("_harness/session/set-all" "_harness/task/set-all") (reverse (mapcar #'car calls))))
    (should (equal '((:non-interactive t)) set))
    (should (equal '("Non-interactive on for 1 session and 0 tasks, and for the open boards' new tasks") said)))
  (harness-ui-test-with-all
      (list (cons "_harness/session/set-all" '("s1" "s2"))
            (cons "_harness/task/set-all" '("t1" "t2"))
            (cons "_harness/config/overrides"
                  '(:key "harness-non-interactive" :value "nil"
                    :tasks (:option "harness-tasks-non-interactive" :value "t"))))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "off")))
      (harness-set-non-interactive-all t))
    (should-not (assoc "_harness/config/set" calls))
    (should (equal '((:non-interactive nil)) set))
    (should (equal '(:key "harness-non-interactive" :value "nil" :printed t :dirs ("/p/" "/q/"))
                   (cdr (assoc "_harness/config/overrides" calls))))
    (should (equal (list (concat "Non-interactive off for 2 sessions and 2 tasks, and for the open boards'"
                                 " new tasks.  But new tasks start non-interactive"
                                 " (harness-tasks-non-interactive); M-x harness-settings changes them."))
                   said))))

(ert-deftest harness-ui-set-thinking-all-reaches-every-project ()
  "C-c h H sets a thinking level on every session and current task of
every project, the open boards' next tasks and new sessions, and says
what keeps the new default from new work.  With a prefix argument the
default and the boards stay as they were."
  (should (eq 'harness-set-thinking-all (lookup-key harness-ui-map (kbd "H"))))
  (harness-ui-test-with-all
      (list (cons "_harness/session/set-all" '("s1" "s2"))
            (cons "_harness/task/set-all" '("t1" "t2" "t3"))
            (cons "_harness/config/overrides"
                  '(:key "harness-thinking" :value "\"high\""
                    :tasks (:option "harness-tasks-thinking" :value "\"low\"")
                    :files ((:file "/p/.dir-locals.el" :scope "project" :dir "/p/" :project "p" :value "nil")))))
    (cl-letf (((symbol-function 'harness-ui-choose-thinking)
               (lambda (callback &rest _) (funcall callback "high" "high"))))
      (harness-set-thinking-all))
    (should (equal '((:thinking "high")) set))
    (should (equal '(:key "harness-thinking" :value "\"high\"" :printed t :scope "global")
                   (cdr (assoc "_harness/config/set" calls))))
    (should (equal '(:settings (:thinking "high") :filter (:active t :tasks t))
                   (cdr (assoc "_harness/session/set-all" calls))))
    (should (equal '(:settings (:thinking "high")) (cdr (assoc "_harness/task/set-all" calls))))
    (should (equal '(:key "harness-thinking" :value "\"high\"" :printed t :dirs ("/p/" "/q/"))
                   (cdr (assoc "_harness/config/overrides" calls))))
    (should (equal (list (concat "Thinking → high for 2 sessions and 3 tasks, and for new sessions and the open"
                                 " boards' new tasks.  But new sessions in p think at the model's default"
                                 " (harness-thinking in /p/.dir-locals.el), new tasks think at low"
                                 " (harness-tasks-thinking); M-x harness-settings changes them."))
                   said)))
  (harness-ui-test-with-all
      (list (cons "_harness/session/set-all" '("s1"))
            (cons "_harness/task/set-all" '("t1")))
    (cl-letf (((symbol-function 'harness-ui-choose-thinking)
               (lambda (callback &rest _) (funcall callback nil "default"))))
      (harness-set-thinking-all t))
    (should-not set)
    (should-not (assoc "_harness/config/set" calls))
    (should-not (assoc "_harness/config/overrides" calls))
    (should (equal '(:settings (:thinking nil)) (cdr (assoc "_harness/task/set-all" calls))))
    (should (equal '("Thinking → default for 1 session and 1 task") said))))

(ert-deftest harness-ui-set-all-empty-answer-changes-nothing ()
  "An empty answer at the model or thinking prompt, which a required
match still lets through, chooses nothing: C-c h M and C-c h H change
no session, task, board or default, where they once set the model to
nil and the level to \"\" everywhere."
  (dolist (command '(harness-set-model-all harness-set-thinking-all))
    (harness-ui-test-with-all nil
      (cl-letf (((symbol-function 'harness-ui-refresh-models)
                 (lambda (&optional callback)
                   (funcall callback (list (list :id "deepseek:deepseek-flash" :label "DeepSeek V4.1 Flash"
                                                 :provider-label "DeepSeek" :context-window 1048576)))))
                ((symbol-function 'completing-read) (lambda (&rest _) "")))
        (call-interactively command))
      (should-not calls)
      (should-not set)
      (should (equal (list (if (eq command 'harness-set-model-all) "No model chosen" "No thinking level chosen"))
                     said)))))

(ert-deftest harness-ui-set-all-without-task-mode-or-overrides ()
  "A harness without task mode, or without `config/overrides', still has
the all-sessions commands change every session and say how many."
  (let ((calls nil) (said nil))
    (let ((harness-ui-set-all-functions nil))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params &optional callback on-error)
                   (push (cons method params) calls)
                   (if (member method '("_harness/task/set-all" "_harness/config/overrides"))
                       (when on-error (funcall on-error '(:message "Method not found")))
                     (when callback (funcall callback (and (equal method "_harness/session/set-all") '("s1")))))))
                ((symbol-function 'message)
                 (lambda (format-string &rest args) (push (apply #'format format-string args) said)))
                ((symbol-function 'completing-read) (lambda (&rest _) "on")))
        (harness-set-non-interactive-all)))
    (should (assoc "_harness/config/set" calls))
    (should (equal '("Non-interactive on for 1 session and 0 tasks, and for new sessions") said))))

;;;; Switches that lose the conversation

(defun harness-ui-test--lossy-check (id name &optional running)
  "Return a `handoff/check' answer saying that switching session ID loses it.
NAME is the session's name; RUNNING says a turn runs."
  (list :id id :name name :lossy t :history t :running running
        :from "deepseek:deepseek-flash" :from-label "DeepSeek V4.1 Flash"
        :to "claude:claude-opus-5-5" :to-label "Claude Opus 5.5" :to-provider "Claude Code"
        :reason "Claude Code keeps its own conversation and is sent only the user messages after the model's last reply."
        :risks '("Cold prompt cache: written, not read."
                 "Reduced fidelity: explored again."
                 "Old provider state: a conversation it could resume, compaction it did itself and its built-in tools stay behind."
                 "Timing: takes effect at the next step, not mid-step.")
        :cache-cost "120k tokens: $0.60 to write, $0.02 to read"))

(defmacro harness-ui-test-with-switch (answers key &rest body)
  "Run BODY switching models with the harness answering from ANSWERS.
ANSWERS maps a method to its result.  The user picks the first model
and, asked about a lossy switch, KEY.  BODY sees CALLS, the requests
made, newest first, and ASKED, the arguments of each question asked."
  (declare (indent 2))
  `(let ((calls nil) (asked nil))
     (cl-letf (((symbol-function 'harness-ui-refresh-models)
                (lambda (&optional callback)
                  (funcall callback (list (list :id "claude:claude-opus-5-5" :label "Claude Opus 5.5"
                                                :provider-label "Claude Code" :context-window 1000000)))))
               ((symbol-function 'harness-ui-call)
                (lambda (method params &optional callback _on-error)
                  (push (cons method params) calls)
                  (when callback (funcall callback (cdr (assoc method ,answers))))))
               ((symbol-function 'completing-read) (lambda (_prompt table &rest _) (caar table)))
               ((symbol-function 'read-multiple-choice)
                (lambda (prompt choices &optional help show &rest _)
                  (push (list prompt choices help show) asked)
                  (assq ,key choices))))
       ,@body)))

(ert-deftest harness-ui-set-model-asks-before-losing-the-conversation ()
  "A lossy switch states its risks first and hands over as the user chooses."
  (harness-ui-test-with-switch
      (list (cons "_harness/handoff/check" (harness-ui-test--lossy-check "s1" "Fix the parser" t))
            (cons "_harness/handoff/switch" '(:mode "transcript" :file "/tmp/p/.harness/handoff/s1.md")))
      ?t
    (harness-set-model "s1")
    (should (= 1 (length asked)))
    (pcase-let ((`(,_prompt ,choices ,help ,show) (car asked)))
      ;; Shown at once: the switch, the risks, the choices -- as tables.
      (should show)
      (should (equal '(?c ?n ?t ?s ?q) (mapcar #'car choices)))
      (should (string-match-p (concat "^MODEL SWITCH → "
                                      (regexp-quote (harness-ui-model-label "claude:claude-opus-5-5")) "$")
                              help))
      (should (string-match-p "^  Session  “Fix the parser”$" help))
      (should (string-match-p (concat "^  From     " (regexp-quote (harness-ui-model-label "deepseek:deepseek-flash")) "$")
                              help))
      (should (string-match-p "sent only the user[ \n]+messages after the model's last reply" help))
      (should (string-match-p "^  Cache    120k tokens: \\$0\\.60 to write, \\$0\\.02 to read (list prices)$" help))
      (should (string-match-p "^  Turn     running; the switch takes effect at its next step$" help))
      ;; The risks table: a heading, a header row, the four labelled risks.
      (should (string-match-p "^RISKS$" help))
      (should (string-match-p "^  RISK\\( +\\)WHAT IT MEANS$" help))
      (dolist (risk '("Cold prompt cache" "Reduced fidelity" "Old provider state" "Timing"))
        (should (string-match-p (format "^  %s +." (regexp-quote risk)) help)))
      ;; Short, one line each, easy to scan: key, name, what it does.
      (should (string-match-p "^  c  current model summarises[ ]+warm cache; summary from the whole conversation$" help))
      (should (string-match-p "^  n  new model summarises[ ]+the conversation's narrative, tool calls in brief; small, but lossy$" help))
      (should (string-match-p "^  t  full transcript[ ]+whole conversation as a file the new model reads$" help))
      (should (string-match-p "^  s  no handoff[ ]+no context; the new model starts from your next message$" help))
      (should (string-match-p "^  q  cancel[ ]+keep the current model$" help))
      (should (string-match-p "^HAND OVER$" help))
      (should (string-match-p "^  lossy; the new model is told to re-investigate$" help)))
    (let ((check (cdr (assoc "_harness/handoff/check" calls)))
          (switch (cdr (assoc "_harness/handoff/switch" calls))))
      (should (equal '(:sessionId "s1" :model "claude:claude-opus-5-5") check))
      (should (equal '(:sessionId "s1" :model "claude:claude-opus-5-5" :mode "transcript") switch)))
    (should-not (assoc "session/set_model" calls))))

(ert-deftest harness-ui-handoff-choices-say-when-the-cache-is-cold ()
  "Summarising on the current model is cheap while that model's cache is
warm, so the choice says when it is not: it lapsed, or it is another
model's.  Where nothing is known, or every cache is warm, it reads as
ever; the other choices always do."
  (let* ((now 10000.0)
         (warm '(:from "a:m" :cache (:at 9900.0 :ttl 300 :expires 10200.0 :model "a:m")))
         (expired '(:from "a:m" :cache (:at 9000.0 :ttl 300 :expires 9300.0 :model "a:m")))
         (other '(:from "a:m" :cache (:at 9900.0 :ttl 300 :expires 10200.0 :model "b:m")))
         (unknown '(:from "a:m"))
         (usual (nth 3 (assq ?c harness-ui--handoff-choices)))
         (describe (lambda (&rest checks) (nth 3 (assq ?c (harness-ui--handoff-choices-for checks now))))))
    (should (equal "warm cache; summary from the whole conversation" usual))
    (should (equal usual (funcall describe warm)))
    (should (equal usual (funcall describe unknown)))
    (should (equal usual (funcall describe warm unknown)))
    (should (equal (format "cache expired at %s: re-reads it all uncached" (harness-ui-format-clock 9300.0 now))
                   (funcall describe expired)))
    (should (equal "cache cold: re-reads it all uncached" (funcall describe other)))
    (should (equal "caches expired: re-reads them all uncached" (funcall describe expired other)))
    (should (equal "re-reads it all uncached where the cache lapsed (1 of 3)"
                   (funcall describe warm expired unknown)))
    (dolist (key '(?n ?t ?s ?q))
      (should (equal (assq key harness-ui--handoff-choices)
                     (assq key (harness-ui--handoff-choices-for (list expired) now)))))
    ;; The minibuffer question says so too.
    (let ((help (harness-ui--handoff-text (list (append (list :id "s1" :name "Fix it") expired))
                                          "Hosted M" 1)))
      (should (string-match-p (format "^  c  current model summarises +cache expired at %s: re-reads it all uncached$"
                                      (regexp-quote (harness-ui-format-clock 9300.0)))
                              help))
      (should-not (string-match-p "warm cache" help)))))

(ert-deftest harness-ui-handoff-choices-do-not-call-the-cache-of-a-running-turn-expired ()
  "A session whose turn runs reads its cache with every request: it is not called lapsed.
The stamp of a hosted loop (Claude Code) is the turn before's until the
turn says its next request, and a switch made then summarises at the
turn's next step, from a cache the turn has just used.  The switch
banner would have said the cache expired at a moment before the turn
began: a false alarm.  What the stamp says of another model's cache holds
whatever the turn does, and so does a cache that is warm."
  (let* ((now 10000.0)
         (expired '(:from "a:m" :running t :cache (:at 9000.0 :ttl 300 :expires 9300.0 :model "a:m")))
         (idle (plist-put (copy-sequence expired) :running nil))
         (other '(:from "a:m" :running t :cache (:at 9900.0 :ttl 300 :expires 10200.0 :model "b:m")))
         (warm '(:from "a:m" :running t :cache (:at 9900.0 :ttl 300 :expires 10200.0 :model "a:m")))
         (usual (nth 3 (assq ?c harness-ui--handoff-choices)))
         (describe (lambda (&rest checks) (nth 3 (assq ?c (harness-ui--handoff-choices-for checks now))))))
    ;; The same stamp, said of an idle session, is a lapsed cache.
    (should (equal (format "cache expired at %s: re-reads it all uncached" (harness-ui-format-clock 9300.0 now))
                   (funcall describe idle)))
    (should (equal usual (funcall describe expired)))
    (should (equal usual (funcall describe warm)))
    (should (equal "cache cold: re-reads it all uncached" (funcall describe other)))
    ;; A batch counts the lapsed caches of the sessions that wait.
    (should (equal "re-reads it all uncached where the cache lapsed (1 of 2)"
                   (funcall describe idle expired)))
    (should (equal usual (funcall describe expired warm)))))

(ert-deftest harness-ui-handoff-choices-say-when-a-redaction-dropped-the-cache ()
  "A cache a redaction dropped (the check's `:cache' has `:dropped') is not one that lapsed.
Asked about one session, the choice says when the redaction dropped it, as
the cache panel does, and that it re-reads everything uncached.  Every
other case reads as it did: a lapsed cache, another model's cache -- the
cache a redaction dropped of a model the session left is that, first --
a batch, and a cache that still lasts."
  (let* ((now (+ 10000.0 86400.0))
         (dropped '(:from "a:m" :cache (:at 9000.0 :ttl 300 :expires 10100.0 :model "a:m" :dropped 10100.0)))
         (lapsed '(:from "a:m" :cache (:at 9000.0 :ttl 300 :expires 9300.0 :model "a:m")))
         (other '(:from "a:m" :cache (:at 9000.0 :ttl 300 :expires 10100.0 :model "b:m" :dropped 10100.0)))
         (warm (list :from "a:m" :cache (list :at (- now 10) :ttl 300 :expires (+ now 290) :model "a:m")))
         (describe (lambda (&rest checks) (harness-ui--handoff-compact-text checks now)))
         (clock (harness-ui-format-clock 10100.0 now)))
    ;; The drop is said with its moment, which is the cache's `:expires', and by whom.
    (should (equal (format "cache dropped at %s by a redaction: re-reads it all uncached" clock)
                   (funcall describe dropped)))
    (should (equal (format "cache dropped at %s by a redaction: re-reads it all uncached"
                           (harness-ui-format-clock 10100.0 10200.0))
                   (harness-ui--handoff-compact-text (list dropped) 10200.0)))
    ;; Not the words for a cache that lapsed by itself, which read as they did.
    (should (equal (format "cache expired at %s: re-reads it all uncached" (harness-ui-format-clock 9300.0 now))
                   (funcall describe lapsed)))
    (should (equal "cache cold: re-reads it all uncached" (funcall describe other)))
    ;; A batch says only how many lapsed, as ever.
    (should (equal "caches expired: re-reads them all uncached" (funcall describe dropped lapsed)))
    (should (equal "caches expired: re-reads them all uncached" (funcall describe dropped dropped)))
    (should (equal "re-reads it all uncached where the cache lapsed (1 of 2)" (funcall describe warm dropped)))
    (should-not (funcall describe warm))
    ;; The choice and the minibuffer question carry it; the other choices do not change.
    (should (equal (format "cache dropped at %s by a redaction: re-reads it all uncached" clock)
                   (nth 3 (assq ?c (harness-ui--handoff-choices-for (list dropped) now)))))
    (dolist (key '(?n ?t ?s ?q))
      (should (equal (assq key harness-ui--handoff-choices)
                     (assq key (harness-ui--handoff-choices-for (list dropped) now)))))
    (let ((help (harness-ui--handoff-text (list (append (list :id "s1" :name "Fix it") dropped))
                                          "Hosted M" 1)))
      (should (string-match-p (format "^  c  current model summarises +cache dropped at %s by a redaction: re-reads it all uncached$"
                                      (regexp-quote (harness-ui-format-clock 10100.0)))
                              help))
      (should-not (string-match-p "warm cache\\|cache expired" help)))))

(ert-deftest harness-ui-set-model-compacts-with-the-new-model ()
  "The advanced choice has the new model summarise a limited context."
  (harness-ui-test-with-switch
      (list (cons "_harness/handoff/check" (harness-ui-test--lossy-check "s1" "Fix the parser" t))
            (cons "_harness/handoff/switch"
                  '(:mode "compact-new" :summarizer "claude:claude-opus-5-5" :context "sample")))
      ?n
    (harness-set-model "s1")
    (should (equal '(:sessionId "s1" :model "claude:claude-opus-5-5" :mode "compact-new")
                   (cdr (assoc "_harness/handoff/switch" calls))))))

(ert-deftest harness-ui-set-model-cancel-or-plain ()
  "Cancelling leaves the model alone; a switch that loses nothing just happens."
  (harness-ui-test-with-switch
      (list (cons "_harness/handoff/check" (harness-ui-test--lossy-check "s1" "Fix the parser")))
      ?q
    (harness-set-model "s1")
    (should (= 1 (length asked)))
    (should-not (assoc "_harness/handoff/switch" calls))
    (should-not (assoc "session/set_model" calls)))
  (harness-ui-test-with-switch
      (list (cons "_harness/handoff/check" '(:id "s1" :lossy nil :reason "The new model is of the same provider.")))
      ?q
    (harness-set-model "s1")
    (should-not asked)
    (should (equal '(:sessionId "s1" :modelId "claude:claude-opus-5-5")
                   (cdr (assoc "session/set_model" calls))))))

(ert-deftest harness-ui-set-model-all-asks-once ()
  "Switching every session asks once, for all those that would lose their conversation."
  (harness-ui-test-with-switch
      (list (cons "_harness/handoff/check-all"
                  (list (harness-ui-test--lossy-check "s1" "Fix the parser" t)
                        (harness-ui-test--lossy-check "s2" nil)
                        '(:id "s3" :lossy nil :reason "Same provider.")))
            (cons "_harness/handoff/switch-all" '("s1" "s2" "s3")))
      ?c
    (harness-set-model-all)
    (should (= 1 (length asked)))
    (let ((help (nth 2 (car asked))))
      (should (string-match-p "^  Sessions  2 of 3 start a new conversation there$" help))
      (should (string-match-p (concat "^MODEL SWITCH → "
                                      (regexp-quote (harness-ui-model-label "claude:claude-opus-5-5")) "$")
                              help))
      (should (string-match-p "^  SESSION +\\(FROM +TURN +CACHE COST\\)$" help))
      (let ((from (regexp-quote (harness-ui-model-label "deepseek:deepseek-flash"))))
        (should (string-match-p (concat "^  “Fix the parser” +" from " +running +120k tokens: \\$0\\.60 to write, \\$0\\.02 to read$")
                                help))
        (should (string-match-p (concat "^  s2 +" from " +- +120k tokens: \\$0\\.60 to write, \\$0\\.02 to read$")
                                help)))
      (should (string-match-p "The choice applies to each session listed; the others just switch" help)))
    ;; Every project's sessions, those of the current tasks included, are
    ;; checked and switched with the handoff; then the tasks' records,
    ;; whose sessions have switched already.
    (should (equal '(:model "claude:claude-opus-5-5" :filter (:active t :tasks t))
                   (cdr (assoc "_harness/handoff/check-all" calls))))
    (should (equal '(:model "claude:claude-opus-5-5" :filter (:active t :tasks t) :mode "compact")
                   (cdr (assoc "_harness/handoff/switch-all" calls))))
    (should (equal '(:settings (:model "claude:claude-opus-5-5")) (cdr (assoc "_harness/task/set-all" calls))))
    (should (< (cl-position "_harness/task/set-all" calls :key #'car :test #'equal)
               (cl-position "_harness/handoff/switch-all" calls :key #'car :test #'equal)))
    (should-not (assoc "_harness/session/set-all" calls))
    (should (equal "claude:claude-opus-5-5" (plist-get (cdr (assoc "_harness/config/set" calls)) :value)))
    ;; Then what overrides the new default is looked up.
    (should (equal '(:key "harness-model" :value "\"claude:claude-opus-5-5\"" :printed t :dirs nil)
                   (cdr (assoc "_harness/config/overrides" calls)))))
  ;; Cancelled: nothing changes, not even the default for new sessions.
  (harness-ui-test-with-switch
      (list (cons "_harness/handoff/check-all" (list (harness-ui-test--lossy-check "s1" "Fix the parser"))))
      ?q
    (harness-set-model-all)
    (should (equal '("_harness/handoff/check-all") (mapcar #'car calls)))))

(ert-deftest harness-ui-one-line-collapses-hover-help ()
  "Hover help becomes one line: a second line grows the echo area.
With tooltips off the help shows there, where the echo area's growth
shrinks every window and moves the button under the mouse."
  (should (equal "a b c" (harness-ui-one-line "a\n\tb  c")))
  (should (equal "path mouse-1: open" (harness-ui-one-line " path\nmouse-1: open ")))
  (should (equal "" (harness-ui-one-line nil))))

;;;; Output rate

(ert-deftest harness-ui-rate-reads-short-and-dims-once-idle ()
  "A session's output rate reads as tokens per second, its details on hover.
A running session's figure is its current one; an idle one's is its
last, dimmed.  A session never measured shows nothing."
  (let ((harness-ui--rates (make-hash-table :test 'equal))
        (rate (list :rate 48.2 :output 1234 :seconds 25.6 :calls 3
                    :at (float-time) :model "demo:scripted")))
    ;; One decimal below ten, whole numbers up to a thousand, then k.
    (should (equal "4.8" (harness-ui-format-rate-number 4.83)))
    (should (equal "10" (harness-ui-format-rate-number 9.96)))
    (should (equal "48" (harness-ui-format-rate-number 48.2)))
    (should (equal "1.2k" (harness-ui-format-rate-number 1234.0)))
    (should-not (harness-ui-format-rate '(:id "s1" :status "running")))
    (puthash "s1" rate harness-ui--rates)
    (let ((live (harness-ui-format-rate '(:id "s1" :status "running")))
          (idle (harness-ui-format-rate '(:id "s1" :status "idle"))))
      (should (equal "48 tok/s" (substring-no-properties live)))
      (should (equal "48" (substring-no-properties (harness-ui-format-rate '(:id "s1") t))))
      (should-not (get-text-property 0 'face live))
      (should (eq 'harness-dim-face (get-text-property 0 'face idle)))
      (let ((help (get-text-property 0 'help-echo live)))
        (should (string-prefix-p
                 (concat "Output rate: 48 tokens per second, 1.2k output tokens in 25.6s of streaming"
                         " over the 3 latest model calls on " (harness-ui-model-label "demo:scripted")
                         ", measured at ")
                 help))
        (should (string-suffix-p "Waiting for the first token and running tools do not count." help))
        (should-not (string-match-p "\n" help)))
      (should (string-prefix-p "Last output rate: 48 " (get-text-property 0 'help-echo idle))))
    ;; One call, measured on another day.
    (puthash "s1" (append (list :calls 1 :at (- (float-time) (* 3 86400))) rate) harness-ui--rates)
    (let ((help (get-text-property 0 'help-echo (harness-ui-format-rate '(:id "s1" :status "idle")))))
      (should (string-match-p " over the latest model call on " help))
      (should (string-match-p ", measured on [0-9]+-[0-9]+-[0-9]+ [0-9]+:[0-9]+\\. " help)))))

(ert-deftest harness-ui-average-rate-reads-the-streamed-totals ()
  "A session's average output rate is its streamed output over its streaming time.
Both are totals of its usage.  It reads as tokens per second with
\"avg\" after the unit, whatever the session's status: it is no last
figure to dim.  A session without the totals, or with under a second of
streaming, has none.  The tooltip says it is the average of the whole
session and not the current rate, which follows once one is measured:
the current rate while the session runs, else the last one."
  (let ((harness-ui--rates (make-hash-table :test 'equal))
        (idle (list :id "s1" :status "idle" :usage (list :stream-output 1200 :stream-seconds 25.0)))
        (rate (list :rate 48.2 :output 1234 :seconds 25.6 :calls 3
                    :at (float-time) :model "demo:scripted")))
    (should (= 48.0 (harness-ui-session-average-rate idle)))
    (let ((cell (harness-ui-format-average-rate idle)))
      (should (equal "48 tok/s avg" (substring-no-properties cell)))
      (should-not (get-text-property 0 'face cell)))
    (should (equal "48" (substring-no-properties (harness-ui-format-average-rate idle t))))
    (should-not (get-text-property 0 'face (harness-ui-format-average-rate
                                            (append '(:status "running") idle))))
    ;; The number is written as the current rate is: one decimal below ten.
    (should (equal "6.0 tok/s avg"
                   (substring-no-properties
                    (harness-ui-format-average-rate '(:id "s2" :usage (:stream-output 600 :stream-seconds 100))))))
    ;; No totals, or under a second of streaming: none.
    (should-not (harness-ui-session-average-rate '(:id "s1")))
    (should-not (harness-ui-session-average-rate '(:id "s1" :usage (:cost 1.5 :output 900))))
    (should-not (harness-ui-format-average-rate '(:id "s1" :usage (:stream-output 30))))
    (should-not (harness-ui-format-average-rate '(:id "s1" :usage (:stream-output 30 :stream-seconds 0.9))))
    (should (equal "30 tok/s avg" (substring-no-properties
                                   (harness-ui-format-average-rate
                                    '(:id "s1" :usage (:stream-output 30 :stream-seconds 1.0))))))
    ;; The tooltip: the average of the whole session, in one line.
    (let ((help (get-text-property 0 'help-echo (harness-ui-format-average-rate idle))))
      (should (equal (concat "Average output rate over the whole session: 48 tokens per second,"
                             " 1.2k output tokens in 25.0s of streaming, not the current rate."
                             " Waiting for the first token and running tools do not count.")
                     help)))
    ;; A rate measured for the session follows, as the current one while it runs...
    (puthash "s1" rate harness-ui--rates)
    (let ((help (get-text-property 0 'help-echo
                                   (harness-ui-format-average-rate (append '(:status "running") idle)))))
      (should (string-prefix-p (concat "Average output rate over the whole session: 48 tokens per second,"
                                       " 1.2k output tokens in 25.0s of streaming, not the current rate."
                                       " Output rate: 48 tokens per second, 1.2k output tokens in 25.6s"
                                       " of streaming over the 3 latest model calls on ")
                               help))
      (should-not (string-match-p "\n" help)))
    ;; ...and else as the last one measured.
    (should (string-match-p " not the current rate\\. Last output rate: 48 tokens per second, "
                            (get-text-property 0 'help-echo (harness-ui-format-average-rate idle))))
    ;; The tooltip of the current rate is as it was.
    (should (string-prefix-p "Last output rate: 48 "
                             (get-text-property 0 'help-echo (harness-ui-format-rate idle))))))

(ert-deftest harness-ui-rate-cache-follows-the-harness ()
  "The UI's rates come from `usage/rate-updated' events and tell the views.
A fetch replaces the whole cache; a deleted session's rate goes."
  (let ((harness-ui--rates (make-hash-table :test 'equal))
        (harness-ui--sessions (make-hash-table :test 'equal))
        (harness-ui-rate-functions nil)
        (harness-ui-event-functions nil)
        (harness-ui-sessions-changed-hook nil)
        (heard nil)
        (rate '(:rate 20.0 :output 100 :seconds 5.0 :calls 1 :at 1000.0 :model "demo:scripted")))
    (add-hook 'harness-ui-rate-functions (lambda (id rate) (push (list id rate) heard)))
    (harness-ui--dispatch-ui "_harness/event" (list :event "usage/rate-updated" :args (list "s1" rate)) nil)
    (should (equal rate (harness-ui-session-rate "s1")))
    (should (equal (list (list "s1" rate)) heard))
    ;; The fetch on connecting replaces the cache, then tells the views at once.
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (method _params callback &rest _)
                 (should (equal "_harness/usage/rates" method))
                 (funcall callback (list (append '(:session "s2") rate))))))
      (harness-ui-refresh-rates))
    (should-not (harness-ui-session-rate "s1"))
    (should (equal rate (harness-ui-session-rate "s2")))
    (should (equal '(nil nil) (car heard)))
    ;; A deleted session's rate goes with it.
    (harness-ui--forget-session "s2")
    (should-not (harness-ui-session-rate "s2"))
    (should (equal '("s2" nil) (car heard)))))

;;;; Token figures

(ert-deftest harness-ui-token-figures-read-the-totals-or-the-live-count ()
  "A session's token figures are its totals, or its live count while it runs.
The context in use is the latest prompt plus what that request wrote.
While the turn streams, the harness's live count stands in, and \"~\"
marks the figures that are partly estimated."
  (let ((harness-ui--live (make-hash-table :test 'equal))
        (session (list :id "s1" :status "running" :context-window 200000
                       :usage (list :context 1000 :last-output 200 :output 300))))
    (should (equal '(:context 1200 :output 300 :estimated 0) (harness-ui-session-tokens session)))
    (should (equal "1.2k/200k" (substring-no-properties (harness-ui-format-context session))))
    (should (equal "300 out" (substring-no-properties (harness-ui-format-output session))))
    (should (equal "300" (substring-no-properties (harness-ui-format-output session t))))
    (let ((help (get-text-property 0 'help-echo (harness-ui-format-context session))))
      (should (string-prefix-p "Context tokens in use: 1.2k of a 200k window; output tokens: 300." help))
      (should (string-match-p "changes the limit" help))
      (should-not (string-match-p "\n" help)))
    ;; Nothing written: no output figure.  Totals recorded before the
    ;; output of the last request was count its prompt alone.
    (let ((old '(:id "s2" :status "idle" :context-window 200000 :usage (:context 500))))
      (should (equal '(:context 500 :output 0 :estimated 0) (harness-ui-session-tokens old)))
      (should-not (harness-ui-format-output old))
      (should (equal "500/200k" (substring-no-properties (harness-ui-format-context old)))))
    ;; Streaming: the live count, its estimate marked.
    (puthash "s1" '(:context 1700 :output 800 :estimated 500) harness-ui--live)
    (should (equal '(:context 1700 :output 800 :estimated 500) (harness-ui-session-tokens session)))
    (should (equal "~1.7k/200k" (substring-no-properties (harness-ui-format-context session))))
    (should (equal "~800 out" (substring-no-properties (harness-ui-format-output session))))
    (should (equal "~800" (substring-no-properties (harness-ui-format-output session t))))
    (let ((help (get-text-property 0 'help-echo (harness-ui-format-output session))))
      (should (string-prefix-p "Context tokens in use: 1.7k; output tokens: 800. ~500 of them estimated" help))
      (should-not (string-match-p "\n" help)))
    ;; Reported: the real numbers, unmarked.
    (puthash "s1" '(:context 1760 :output 860 :estimated 0) harness-ui--live)
    (should (equal "1.8k/200k" (substring-no-properties (harness-ui-format-context session))))
    (should (equal "860 out" (substring-no-properties (harness-ui-format-output session))))))

(ert-deftest harness-ui-context-limit-state-names-the-cap ()
  "How the token figure's window is limited, and by what.
A sub-agent's kind says a sub-agent's cap, the tasks module's own cap
value says a task's; the rest is a session limit.  A limit above the
model's window is inert, and a window set for the session itself wins
over any limit."
  (let* ((sub (harness-ui-context-limit-state
               '(:kind "subagent" :context-window 256000 :context-window-limit 256000)
               1000000))
         (task (harness-ui-context-limit-state
                (let ((harness-tasks-context-limit 256000))
                  '(:kind "main" :context-window 256000 :context-window-limit 256000))
                nil))
         (own (harness-ui-context-limit-state
               '(:kind "main" :context-window 300000 :context-window-limit 300000)
               1000000))
         (full (harness-ui-context-limit-state '(:kind "main" :context-window 200000) 200000))
         (above (harness-ui-context-limit-state
                 '(:kind "main" :context-window 200000 :context-window-limit 500000) 200000))
         (override (harness-ui-context-limit-state
                    '(:kind "main" :context-window 100000 :context-window-override 100000
                      :context-window-limit 50000)
                    200000)))
    (should (equal 1000000 (plist-get sub :model-window)))
    (should (equal 256000 (plist-get sub :limit)))
    (should (plist-get sub :limited))
    (should (plist-get sub :capped))
    (should (equal "a sub-agent's limit" (plist-get sub :cap)))
    (should (equal "a task's limit" (plist-get task :cap)))
    (should (equal "a limit set for this session" (plist-get own :cap)))
    (should-not (plist-get full :limit))
    (should-not (plist-get full :limited))
    ;; Above the model's window the limit is set but does not hold it.
    (should (equal 500000 (plist-get above :limit)))
    (should-not (plist-get above :limited))
    (should-not (plist-get above :capped))
    (should-not (plist-get override :limited))
    ;; The tooltip says what holds the window and how to change it.
    (should (string-match-p
             "The model's window is 1.00M, but this session is capped at 256k by a sub-agent's limit"
             (harness-ui-context-limit-help
              '(:kind "subagent" :context-window 256000 :context-window-limit 256000) 1000000)))
    (should (string-match-p
             "A limit of 500k is set, but the model's own window of 200k is what applies"
             (harness-ui-context-limit-help
              '(:context-window 200000 :context-window-limit 500000) 200000)))
    (should (string-match-p
             "Its window of 100k is set for the session itself and wins over any limit"
             (harness-ui-context-limit-help
              '(:context-window 100000 :context-window-override 100000
                :context-window-limit 50000)
              200000)))
    (dolist (help (list (harness-ui-context-limit-help
                         '(:kind "subagent" :context-window 256000 :context-window-limit 256000)
                         1000000)))
      (should-not (string-match-p "\n" help)))))

(ert-deftest harness-ui-context-limit-options-stay-within-the-model-window ()
  "The offer holds the current limit, round sizes under the model's
window, and no limit for the whole of it: never a size above the
model's own window."
  (let ((options (harness-ui--context-limit-options 1000000 256000)))
    (should (equal 256000 (cdr (assoc "256k (current)" options))))
    (should (equal 128000 (cdr (assoc "128k" options))))
    (should (equal 512000 (cdr (assoc "512k" options))))
    (should (assoc "no limit: the whole 1.00M the model has" options))
    (should-not (cl-some (lambda (o) (and (numberp (cdr o)) (> (cdr o) 1000000))) options)))
  (let ((options (harness-ui--context-limit-options 200000 256000)))
    ;; The limit is above the model's window: not offered again.
    (should-not (assoc "256k (current)" options))
    (should (equal 128000 (cdr (assoc "128k" options))))
    (should-not (cl-some (lambda (o) (and (numberp (cdr o)) (> (cdr o) 200000))) options)))
  (let ((options (harness-ui--context-limit-options nil nil)))
    (should (equal 128000 (cdr (assoc "128k" options))))
    (should (assoc "no limit: the model's whole window" options))))

(ert-deftest harness-ui-token-count-reads-what-the-figure-shows ()
  "A typed limit reads as the token figures do, or names none."
  (should (equal 128000 (harness-ui--token-count "128k")))
  (should (equal 1500000 (harness-ui--token-count "1.5M")))
  (should (equal 200000 (harness-ui--token-count "200K")))
  (should (equal 256000 (harness-ui--token-count "256,000")))
  (should (equal 256000 (harness-ui--token-count " 256000 ")))
  (should-not (harness-ui--token-count "0"))
  (should-not (harness-ui--token-count "k"))
  (should-not (harness-ui--token-count "twelve"))
  (should-not (harness-ui--token-count "")))

(ert-deftest harness-ui-context-figure-is-a-button ()
  "The token figure carries the keymap, session id and hover face of a
button, and a click on it changes the limit of the session it shows,
not of point."
  (let* ((session '(:id "s7" :kind "subagent" :model "demo:scripted"
                    :context-window 4000 :context-window-limit 4000
                    :usage (:context 1000)))
         (figure (harness-ui-format-context session))
         (got 'unset))
    (should (eq harness-ui-context-limit-map (get-text-property 0 'keymap figure)))
    (should (eq 'highlight (get-text-property 0 'mouse-face figure)))
    (should (equal "s7" (get-text-property 0 'harness-context-session figure)))
    (should (string-match-p "capped at 4.0k by a sub-agent's limit"
                            (get-text-property 0 'help-echo figure)))
    (cl-letf (((symbol-function 'harness-set-context-limit)
               (lambda (&optional id) (setq got id))))
      (with-temp-buffer
        (insert figure)
        (harness-ui-context-limit-click
         (list 'mouse-1 (list (selected-window) (point-min) '(0 . 0) 0 nil (point-min))))))
    (should (equal "s7" got))))

(ert-deftest harness-ui-set-context-limit-sets-clears-and-clamps ()
  "C-c h e sets the limit the offer names, clamps it to the model's own
window, clears it for the whole window, and reads a number typed
instead.  Only `session/update' is asked: the conversation is untouched."
  (let* ((session-val '(:id "s1" :name "Capped" :kind "main" :model "demo:scripted"
                        :context-window 256000 :context-window-limit 256000))
         (calls nil) (said nil) (cached nil))
    (cl-letf (((symbol-function 'harness-ui-session) (lambda (_) session-val))
              ((symbol-function 'harness-ui-model-context-window) (lambda (_) 1000000))
              ((symbol-function 'harness-ui-call)
               (lambda (method params &optional callback _on-error)
                 (push (cons method params) calls)
                 (when callback (funcall callback (append session-val (list :updated 1))))))
              ((symbol-function 'harness-ui-cache-session) (lambda (s) (push s cached)))
              ((symbol-function 'message) (lambda (format-string &rest args)
                                            (push (apply #'format format-string args) said))))
      (cl-letf (((symbol-function 'completing-read) (lambda (_p table &rest _) (caar table))))
        (harness-set-context-limit "s1"))
      (should (equal '("_harness/session/update") (mapcar #'car calls)))
      (should (equal 256000 (plist-get (cdr (car calls)) :context-window-limit)))
      (should (equal '("Context limit for Capped → 256k") said))
      (should (= 1 (length cached)))
      ;; A chosen round size.
      (setq calls nil said nil cached nil)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p table &rest _)
                   (car (cl-find "512k" table :key #'car :test #'equal)))))
        (harness-set-context-limit "s1"))
      (should (equal 512000 (plist-get (cdr (car calls)) :context-window-limit)))
      (should (equal '("Context limit for Capped → 512k") said))
      ;; A typed number, above the model's window: clamped to it.
      (setq calls nil said nil)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "2M")))
        (harness-set-context-limit "s1"))
      (should (equal 1000000 (plist-get (cdr (car calls)) :context-window-limit)))
      (should (equal '("Context limit for Capped → 1.00M (the model's window)") said))
      ;; A typed number below it.
      (setq calls nil said nil)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "300k")))
        (harness-set-context-limit "s1"))
      (should (equal 300000 (plist-get (cdr (car calls)) :context-window-limit)))
      (should (equal '("Context limit for Capped → 300k") said))
      ;; No limit: cleared, so the whole window is used.
      (setq calls nil said nil)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p table &rest _)
                   (car (cl-find-if (lambda (o) (string-prefix-p "no limit" (car o))) table)))))
        (harness-set-context-limit "s1"))
      (should (plist-member (cdr (car calls)) :context-window-limit))
      (should-not (plist-get (cdr (car calls)) :context-window-limit))
      (should (equal '("Context limit removed for Capped: the whole 1.00M window") said))
      ;; A window set for the session itself is cleared with the limit.
      (setq calls nil said nil
            session-val '(:id "s1" :name "Capped" :kind "main"
                          :context-window 100000 :context-window-override 100000))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p table &rest _)
                   (car (cl-find-if (lambda (o) (string-prefix-p "no limit" (car o))) table)))))
        (harness-set-context-limit "s1"))
      (should-not (plist-get (cdr (car calls)) :context-window-limit))
      (should (plist-member (cdr (car calls)) :context-window))
      (should-not (plist-get (cdr (car calls)) :context-window))
      (should (equal '("Context limit removed for Capped: the whole 1.00M window, its own window cleared")
                     said))
      ;; A number chosen also clears it, or it would win over the limit.
      (setq calls nil said nil)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p table &rest _)
                   (car (cl-find "512k" table :key #'car :test #'equal)))))
        (harness-set-context-limit "s1"))
      (should (equal 512000 (plist-get (cdr (car calls)) :context-window-limit)))
      (should (plist-member (cdr (car calls)) :context-window))
      (should-not (plist-get (cdr (car calls)) :context-window))
      (should (equal '("Context limit for Capped → 512k, its own window cleared") said))
      ;; Nothing typed, nothing changed; junk is refused.
      (setq calls nil said nil)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
        (harness-set-context-limit "s1"))
      (should-not calls)
      (should (equal '("Context limit unchanged") said))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "wat")))
        (should-error (harness-set-context-limit "s1") :type 'user-error))
      (should-not calls))))

(ert-deftest harness-ui-live-token-cache-follows-the-harness ()
  "Live figures come from `usage/live-updated' events and tell the views.
The event that ends a turn's count can come before the session's new
totals: the last figures stay until the cache shows the session no
longer running, so they never drop in between.  A fetch replaces the
whole cache; a deleted session's figures go."
  (let ((harness-ui--live (make-hash-table :test 'equal))
        (harness-ui--sessions (make-hash-table :test 'equal))
        (harness-ui--rates (make-hash-table :test 'equal))
        (harness-ui-live-functions nil)
        (harness-ui-rate-functions nil)
        (harness-ui-event-functions nil)
        (harness-ui-sessions-changed-hook nil)
        (heard nil)
        (live '(:context 1700 :output 800 :estimated 500))
        (event (lambda (id live)
                 (harness-ui--dispatch-ui "_harness/event"
                                          (list :event "usage/live-updated" :args (list id live)) nil))))
    (add-hook 'harness-ui-live-functions (lambda (id live) (push (list id live) heard)))
    (harness-ui-cache-session (list :id "s1" :status "running" :context-window 200000
                                    :usage (list :context 1000 :last-output 200 :output 300)))
    (funcall event "s1" live)
    (should (equal live (harness-ui-session-live "s1")))
    (should (equal (list (list "s1" live)) heard))
    ;; The count ends while the cache still shows the session running.
    (funcall event "s1" nil)
    (should-not (harness-ui-session-live "s1"))
    (should (equal '("s1" nil) (car heard)))
    (should (equal live (harness-ui-session-tokens (harness-ui-session "s1"))))
    ;; Its new totals come with it idle: they count from now on.
    (harness-ui-cache-session (list :id "s1" :status "idle" :context-window 200000
                                    :usage (list :context 1000 :last-output 820 :output 920)))
    (should-not (gethash "s1" harness-ui--live))
    (should (equal '(:context 1820 :output 920 :estimated 0)
                   (harness-ui-session-tokens (harness-ui-session "s1"))))
    ;; The count of a session already shown idle ends at once.
    (funcall event "s1" live)
    (funcall event "s1" nil)
    (should-not (gethash "s1" harness-ui--live))
    ;; Fetching every session again settles an ended count the same way.
    (harness-ui-cache-session (list :id "s3" :status "running" :usage (list :context 10)))
    (funcall event "s3" live)
    (funcall event "s3" nil)
    (should (gethash "s3" harness-ui--live))
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (method _params callback &rest _)
                 (should (equal "_harness/session/list" method))
                 (funcall callback (list (list :id "s3" :status "idle" :usage (list :context 900)))))))
      (harness-ui-refresh-sessions))
    (should-not (gethash "s3" harness-ui--live))
    ;; The fetch on connecting replaces the cache, then tells the views at once.
    (puthash "gone" live harness-ui--live)
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (method _params callback &rest _)
                 (should (equal "_harness/usage/live-all" method))
                 (funcall callback (list (append '(:session "s2") live))))))
      (harness-ui-refresh-live))
    (should-not (gethash "gone" harness-ui--live))
    (should (equal live (harness-ui-session-live "s2")))
    (should (equal '(nil nil) (car heard)))
    ;; A deleted session's figures go with it.
    (harness-ui--forget-session "s2")
    (should-not (gethash "s2" harness-ui--live))
    (should (equal '("s2" nil) (car heard)))))

;;;; Mouse targets

(ert-deftest harness-ui-mouse-keymap-runs-on-ret-too ()
  "A target of `harness-ui-mouse-keymap' runs its command on RET, an event
without a position, as it does on a click."
  (let ((ran 0)
        (buffer (generate-new-buffer " *harness mouse keymap*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert (propertize "target" 'keymap (harness-ui-mouse-keymap (lambda () (interactive) (cl-incf ran)))))
          (goto-char (point-min))
          (execute-kbd-macro (kbd "RET"))
          (should (= 1 ran)))
      (kill-buffer buffer))))

(ert-deftest harness-ui-fit-header-drops-the-least-important-first ()
  "A header too wide for its window keeps what matters and loses the rest.
Segments are given in display order; the lowest priority goes first,
the rightmost among equals, and a segment with a shortened form shrinks
to it once nothing is left to drop.  A segment whose priority is t
always stays.  The widths are columns, as on a text terminal, even
in a graphic Emacs: measuring in pixels has a test of its own."
  (cl-letf (((symbol-function 'display-graphic-p) #'ignore))
    (let ((segments '(" One" (" Two" 5) (" Three" 5 " 3") (" Four" 100))))
      (should (equal " One Two Three Four" (harness-ui-fit-header segments 200)))
      ;; Room for the rightmost of two equal priorities only after it
      ;; shortens: a shortened segment is worth keeping over dropping it.
      (should (equal " One Two 3 Four" (harness-ui-fit-header segments 16)))
      ;; Not even its shortened form fits: then it goes.
      (should (equal " One Four" (harness-ui-fit-header segments 10)))
      (should (equal " One" (harness-ui-fit-header segments 4)))
      ;; What cannot be dropped stays, however little room there is.
      (should (equal " One" (harness-ui-fit-header segments 0)))
      ;; A flexible segment shrinks only when dropping cannot help: the
      ;; name has priority t here, so it is never dropped, only shortened.
      (should (equal " One Four Wide Name" (harness-ui-fit-header
                                            '(" One" (" Four" 100) (" Wide Name" t " W…")) 40)))
      ;; Room for the name whole once the droppable segment is gone.
      (should (equal " One Wide Name" (harness-ui-fit-header
                                       '(" One" (" Four" 100) (" Wide Name" t " W…")) 16)))
      ;; Too narrow even then: the name shortens, which is all that is left.
      (should (equal " One W…" (harness-ui-fit-header
                                '(" One" (" Four" 100) (" Wide Name" t " W…")) 10)))
      ;; nil segments are left out, not turned into "nil".
      (should (equal " One" (harness-ui-fit-header (list " One" nil "" nil) 80))))))

(ert-deftest harness-ui-fit-header-measures-in-the-header-face ()
  "On a graphic frame a header is measured in pixels, icons included."
  (skip-unless (display-graphic-p))
  (should (> (harness-ui-header-string-width (harness-ui-icon 'harness-icon-blocked))
             (frame-char-width)))
  ;; The room of a named window: the default is the narrowest window
  ;; showing the buffer, which this buffer need not be shown in.
  (should (= (harness-ui-header-width (selected-window))
             (- (window-pixel-width) (or (window-scroll-bar-width) 0)))))

(ert-deftest harness-ui-icons-are-made-once ()
  "An icon is made once, then reused while it is defined the same way.
Header and mode lines are drawn on every key typed, and making an icon
reads its file and asks the fonts."
  (let ((made 0)
        (harness-ui--icons (make-hash-table :test 'equal)))
    (cl-letf* ((make (symbol-function 'icon-string))
               ((symbol-function 'icon-string) (lambda (name) (cl-incf made) (funcall make name))))
      (let ((a (harness-ui-icon 'harness-icon-idle))
            (b (harness-ui-icon 'harness-icon-idle)))
        (should (= made 1))
        (should (equal-including-properties a b))
        ;; Each is a copy: what one caller puts on it, the next one does not get.
        (put-text-property 0 (length a) 'face 'bold a)
        (should-not (get-text-property 0 'face (harness-ui-icon 'harness-icon-idle)))
        (should (= made 1))
        ;; Defined again, by a reload say, it is made again.
        (harness-ui-define-icon harness-icon-idle "idle" "●" "idle" "Idle session.")
        (harness-ui-icon 'harness-icon-idle)
        (should (= made 2))
        ;; So it is for a user who prefers another kind of icon.
        (let ((icon-preference '(text)))
          (should (equal "idle" (substring-no-properties (harness-ui-icon 'harness-icon-idle))))
          (should (= made 3)))))))

;;;; Session links and project switching

(ert-deftest harness-ui-session-link-opens-the-session-in-its-project ()
  "A session link is propertized text; a click or RET opens it in its project.
The link wears `harness-ui-session-link-face' and carries the mouse
face, the hand pointer, the tooltip and the keys every session link in
the UI shares, and its keys go through `harness-ui-visit-session',
which switches to the session's project first, as a row of the session
list does.  A label and tooltip the caller gives win over the defaults."
  (let* ((root (harness-test-temp-dir))
         (chat (get-buffer-create " *harness-ui-test link*"))
         (switched nil)
         (opened nil)
         (shown nil)
         (harness-ui--sessions (make-hash-table :test 'equal))
         (harness-ui-switch-project-function (lambda (dir) (push dir switched) t))
         (harness-ui-open-session-function (lambda (id) (push id opened) chat)))
    (unwind-protect
        (progn
          (harness-ui-cache-session (list :id "child" :name "worker" :project root :cwd root
                                          :status "running"))
          (cl-letf (((symbol-function 'harness-files-owning-checkout) (lambda (&rest _) root))
                    ((symbol-function 'harness-ui-display-buffer)
                     (lambda (buffer &optional position) (push (list buffer position) shown) buffer)))
            (let ((link (harness-ui-session-link "child")))
              (should (equal "worker" link))
              (should (eq 'harness-ui-session-link-face (get-text-property 0 'face link)))
              (should (eq 'highlight (get-text-property 0 'mouse-face link)))
              (should (eq 'hand (get-text-property 0 'pointer link)))
              (should (equal "mouse-1, RET: open the session worker"
                             (get-text-property 0 'help-echo link)))
              ;; The keys on the text open the session, from a buffer point.
              (with-temp-buffer
                (insert link)
                (goto-char (point-min))
                (let ((command (key-binding (kbd "RET"))))
                  (should (commandp command))
                  (call-interactively command)))
              ;; A label and tooltip the caller gives win over the defaults.
              (let ((mine (harness-ui-session-link "child" (propertize "w" 'face 'bold) "there")))
                (should (equal "w" mine))
                (should (eq 'bold (get-text-property 0 'face mine)))
                (should (equal "there" (get-text-property 0 'help-echo mine)))))
            (should (equal (list root) switched))
            (should (equal '("child") opened))
            ;; It shows the session: a switch leaves the position to the
            ;; caller's default (`harness-ui-visit-session').
            (should (equal (list chat) (mapcar #'car shown)))))
      (kill-buffer chat)
      (delete-directory root t))))

(ert-deftest harness-ui-resolve-session-reads-the-cache-as-the-session-tools-do ()
  "A reference names a cached session as the session tools take one: its
id, else a unique prefix of an id, else a unique name, in any case.  One
that matches no session, or several, names none, and so does anything
that is not a reference."
  (let ((harness-ui--sessions (make-hash-table :test 'equal))
        (alpha "0a1b2c3d-1111-4111-8111-111111111111")
        (alpine "0a1b2c3d-2222-4222-8222-222222222222")
        (beta "5e5e5e5e-3333-4333-8333-333333333333")
        (twin-a "7f7f7f7f-4444-4444-8444-444444444444")
        (twin-b "9d9d9d9d-5555-4555-8555-555555555555")
        (decoy "c0c0c0c0-6666-4666-8666-666666666666"))
    (dolist (s (list (list :id alpha :name "Alpha") (list :id alpine :name "Alpine")
                     (list :id beta :name "Beta Reader")
                     (list :id twin-a :name "Twin") (list :id twin-b :name "twin")
                     ;; Its name is the start of Beta's id.
                     (list :id decoy :name "5e5e")))
      (puthash (plist-get s :id) s harness-ui--sessions))
    ;; An id, whole.
    (should (equal alpha (harness-ui-resolve-session alpha)))
    (should (equal twin-b (harness-ui-resolve-session twin-b)))
    ;; A prefix of one id, with the blanks round a reference left out; a
    ;; prefix two ids share names neither of them.
    (should (equal beta (harness-ui-resolve-session "5e5e5")))
    (should (equal twin-a (harness-ui-resolve-session "  7f7f  \n")))
    (should-not (harness-ui-resolve-session "0a1b"))
    (should (equal alpha (harness-ui-resolve-session "0a1b2c3d-1")))
    ;; Ids are lowercase and a prefix is not case-folded, as with the tools.
    (should-not (harness-ui-resolve-session "5E5E5"))
    ;; A name, in any case; two sessions of one name name neither.
    (should (equal beta (harness-ui-resolve-session "Beta Reader")))
    (should (equal beta (harness-ui-resolve-session "beta READER")))
    (should (equal alpha (harness-ui-resolve-session " alpha ")))
    (should-not (harness-ui-resolve-session "Twin"))
    (should-not (harness-ui-resolve-session "TWIN"))
    ;; Prefixes come before names: "5e5e" is a prefix of Beta's id as well
    ;; as the decoy's name, and the prefix wins, as the session tools have it.
    (should (equal beta (harness-ui-resolve-session "5e5e")))
    ;; Without a prefix hit the name counts: "Alp" is not a name, "Alpine" is.
    (should (equal alpine (harness-ui-resolve-session "alpine")))
    (should-not (harness-ui-resolve-session "Alp"))
    ;; Nothing it knows.
    (should-not (harness-ui-resolve-session "no such session"))
    (should-not (harness-ui-resolve-session "ffffffff-0000-4000-8000-000000000000"))
    ;; Not a reference.
    (dolist (ref (list nil "" "   " "\n" 42 'alpha :alpha (list alpha) (vector alpha)))
      (should-not (harness-ui-resolve-session ref)))
    ;; A session without a name is reached by its id alone.
    (puthash "e1e1e1e1-7777-4777-8777-777777777777" (list :id "e1e1e1e1-7777-4777-8777-777777777777")
             harness-ui--sessions)
    (should (equal "e1e1e1e1-7777-4777-8777-777777777777" (harness-ui-resolve-session "e1e1")))
    (should-not (harness-ui-resolve-session "nil"))
    ;; Reading the cache is all it does: nothing is added or dropped.
    (should (= 7 (hash-table-count harness-ui--sessions)))
    ;; An empty cache knows no one.
    (clrhash harness-ui--sessions)
    (should-not (harness-ui-resolve-session alpha))
    (should-not (harness-ui-resolve-session "Alpha"))))

(ert-deftest harness-ui-link-session-ids-links-the-ids-the-cache-knows ()
  "A whole session id the cache knows, among other words, gets the shared
session link's look and keys in place.  The text keeps its own faces
under the link's and its words around the id stay as they are; an id
the cache does not know, a short id, and an id inside a longer word are
left alone."
  (let* ((harness-ui--sessions (make-hash-table :test 'equal))
         (known "0a1b2c3d-1111-4111-8111-111111111111")
         (other "5e5e5e5e-3333-4333-8333-333333333333")
         (unknown "7f7f7f7f-4444-4444-8444-444444444444")
         (opened nil))
    (puthash known (list :id known :name "Alpha") harness-ui--sessions)
    (puthash other (list :id other :name "Beta") harness-ui--sessions)
    (cl-letf (((symbol-function 'harness-ui-visit-session)
               (lambda (id &rest _) (push id opened))))
      (cl-flet ((faces (string pos) (ensure-list (get-text-property pos 'face string)))
                (plain-p (string start end)
                  ;; No look and no keys between START and END.
                  (cl-loop for pos from start below end
                           never (or (get-text-property pos 'keymap string)
                                     (get-text-property pos 'mouse-face string)
                                     (get-text-property pos 'help-echo string)
                                     (memq 'harness-ui-session-link-face
                                           (ensure-list (get-text-property pos 'face string)))))))
        ;; A known id inside text of another face: both faces, the link's first.
        (let* ((text (format "read %s now, %s too, and %s." known unknown (substring known 0 8)))
               (string (propertize (copy-sequence text) 'face 'harness-dim-face))
               (start (string-search known text))
               (end (+ start (length known)))
               (result (harness-ui-link-session-ids string)))
          ;; In place: the string given comes back, its text as it was.
          (should (eq string result))
          (should (equal text (substring-no-properties result)))
          (dolist (pos (list start (+ start 17) (1- end)))
            (should (equal '(harness-ui-session-link-face harness-dim-face) (faces string pos)))
            (should (eq 'highlight (get-text-property pos 'mouse-face string)))
            (should (eq 'hand (get-text-property pos 'pointer string)))
            (should (equal "mouse-1, RET: open the session Alpha" (get-text-property pos 'help-echo string)))
            (should (keymapp (get-text-property pos 'keymap string))))
          ;; The keys open that session through `harness-ui-visit-session'.
          (let ((keys (get-text-property start 'keymap string)))
            (setq opened nil)
            (call-interactively (lookup-key keys (kbd "RET")))
            (should (equal (list known) opened))
            (setq opened nil)
            (call-interactively (lookup-key keys [mouse-1]))
            (should (equal (list known) opened)))
          ;; The text around it keeps its own face and gets nothing else; an
          ;; unknown id and a short id are text.
          (should (plain-p string 0 start))
          (should (plain-p string end (length text)))
          (should (equal '(harness-dim-face) (faces string 0)))
          (should (equal '(harness-dim-face) (faces string (string-search unknown text))))
          (should-not (get-text-property (string-search unknown text) 'keymap string))
          (should-not (get-text-property (string-search (substring known 0 8) text end) 'keymap string)))
        ;; Several ids, each opening its own session: at either end of the
        ;; string, in quotes, in a path and in brackets.
        (let* ((ids (list known other known other known))
               (text (format "%s\nwith \"%s\" in /tmp/%s.json and (%s)\n%s" known other known other known))
               (string (harness-ui-link-session-ids (copy-sequence text)))
               (from 0))
          (dolist (id ids)
            (let ((at (string-search id text from)))
              (should at)
              (setq from (+ at (length id)))
              (setq opened nil)
              (call-interactively (lookup-key (get-text-property at 'keymap string) (kbd "RET")))
              (should (equal (list id) opened))
              (should (memq 'harness-ui-session-link-face (faces string at)))
              (should (memq 'harness-ui-session-link-face (faces string (1- from))))
              ;; The characters beside the id are text.
              (should (plain-p string (max 0 (1- at)) (if (zerop at) 0 at)))
              (should (plain-p string from (min (length text) (1+ from))))))
          (should (= from (length text))))
        ;; Not whole ids: part of a longer word or of a longer run of hex.
        (dolist (text (list (concat "x" known) (concat known "x") (concat known "f")
                            (concat "_" known) (concat known "_") (concat "a" known "b")
                            (substring known 0 35) (substring known 1)
                            (string-replace "-" "_" known)))
          (let ((string (harness-ui-link-session-ids (copy-sequence text))))
            (should (equal text (substring-no-properties string)))
            (should (plain-p string 0 (length text)))))
        ;; Uppercase is no session id of the harness's.
        (let ((string (harness-ui-link-session-ids (upcase known))))
          (should (plain-p string 0 (length known))))
        ;; Nothing to link: the string comes back as it was.
        (should (null (harness-ui-link-session-ids nil)))
        (should (equal "" (harness-ui-link-session-ids "")))
        (let ((string (propertize "no session in here, only a hash 0a1b2c3d" 'face 'bold)))
          (should (eq string (harness-ui-link-session-ids string)))
          (should (equal '(bold) (faces string 0)))
          (should (plain-p string 0 (length string))))))))

(ert-deftest harness-ui-link-session-ids-leaves-alone-what-skip-says ()
  "An id SKIP, a function of the string and the id's position, says to leave is
text: the others are linked, and SKIP sees where each id starts."
  (let* ((harness-ui--sessions (make-hash-table :test 'equal))
         (known "0a1b2c3d-1111-4111-8111-111111111111")
         (text (format "first %s then %s" known known))
         (second (+ (string-search known text) (length known) (length " then ")))
         (asked nil))
    (puthash known (list :id known :name "Alpha") harness-ui--sessions)
    (let ((string (harness-ui-link-session-ids
                   (copy-sequence text)
                   (lambda (string pos)
                     (should (stringp string))
                     (push pos asked)
                     (= pos second)))))
      (should (equal (list (string-search known text) second) (reverse asked)))
      (should (keymapp (get-text-property (string-search known text) 'keymap string)))
      (should-not (get-text-property second 'keymap string))
      (should-not (memq 'harness-ui-session-link-face
                        (ensure-list (get-text-property second 'face string)))))
    ;; Skipping nothing is not skipping.
    (should (get-text-property 0 'keymap (harness-ui-link-session-ids (copy-sequence known) #'ignore)))))

(ert-deftest harness-ui-switch-to-project-only-switches-to-a-local-directory ()
  "`harness-ui-switch-to-project' switches only to a local, existing root.
A remote root, a missing one or none at all switches nothing, and nor
does it without `harness-ui-switch-project-function'; the function's
own answer (nil when nothing switched) comes back, and one that fails
is logged, not signalled."
  (let* ((root (harness-test-temp-dir))
         (asked nil)
         (harness-ui-switch-project-function (lambda (dir) (push dir asked) t)))
    (unwind-protect
        (progn
          (should (eq t (harness-ui-switch-to-project root)))
          (should (equal (list root) asked))
          (setq asked nil)
          (should-not (harness-ui-switch-to-project "/ssh:nobody@example.invalid:/srv/project/"))
          (should-not (harness-ui-switch-to-project (expand-file-name "gone/" root)))
          (should-not (harness-ui-switch-to-project nil))
          (should-not (harness-ui-switch-to-project ""))
          (should-not asked)
          (let ((harness-ui-switch-project-function nil))
            (should-not (harness-ui-switch-to-project root))
            (should-not asked))
          (let ((harness-ui-switch-project-function (lambda (_dir) (error "no workspace for it"))))
            (should-not (harness-ui-switch-to-project root))))
      (delete-directory root t))))

(ert-deftest harness-ui-switch-to-session-project-uses-the-session-checkout ()
  "Switching to a session's project goes through `harness-ui-switch-to-project'.
The root switched to is the session's main checkout, a task worktree's
repository root; a remote project is not switched to."
  (let* ((root (harness-test-temp-dir))
         (worktree (file-name-as-directory (expand-file-name "wt/" root)))
         (asked nil)
         (harness-ui--sessions (make-hash-table :test 'equal))
         (harness-ui-switch-project-function (lambda (dir) (push dir asked) t)))
    (unwind-protect
        (progn
          (make-directory worktree t)
          (harness-ui-cache-session (list :id "task" :name "a task" :project worktree :cwd worktree))
          (harness-ui-cache-session (list :id "remote" :name "far" :project "/ssh:nobody@example.invalid:/srv/project/"))
          (cl-letf (((symbol-function 'harness-files-owning-checkout) (lambda (&rest _) root)))
            (should (eq t (harness-ui-switch-to-session-project "task"))))
          (should (equal (list root) asked))
          (setq asked nil)
          (should-not (harness-ui-switch-to-session-project "remote"))
          (should-not (harness-ui-switch-to-session-project "no-such-session"))
          (should-not asked))
      (delete-directory root t))))

;;;; Seeds in what the UI navigates to

(ert-deftest harness-ui-seed-session-p-reads-the-mark-in-the-record ()
  "A seed is the session whose `:ext' says so, given as a plist or an id.
A session that is not marked, one marked an explicit `:false', one the
cache does not know, and nil are not seeds; no name is consulted, so a
session that merely looks like a seed is navigable."
  (let ((harness-ui--sessions (make-hash-table :test 'equal)))
    (harness-ui-cache-session (list :id "seed" :name "Shared context for main" :ext (list :seed t)))
    (harness-ui-cache-session (list :id "off" :name "Shared context for main" :ext (list :seed :false)))
    (harness-ui-cache-session (list :id "worker" :name "Shared context for main"))
    (harness-ui-cache-session (list :id "fork" :name "fork of main" :kind "fork"))
    (harness-ui-cache-session (list :id "btw" :name "aside" :kind "btw"))
    (should (harness-ui-seed-session-p (harness-ui-session "seed")))
    (should (harness-ui-seed-session-p "seed"))
    (should-not (harness-ui-seed-session-p (harness-ui-session "off")))
    (should-not (harness-ui-seed-session-p (harness-ui-session "worker")))
    (should-not (harness-ui-seed-session-p "unknown"))
    (should-not (harness-ui-seed-session-p nil))
    (should-not (harness-ui-navigable-session-p (harness-ui-session "seed")))
    ;; Forks, BTWs and ordinary sub-agents stay navigable.
    (should (harness-ui-navigable-session-p (harness-ui-session "worker")))
    (should (harness-ui-navigable-session-p (harness-ui-session "fork")))
    (should (harness-ui-navigable-session-p (harness-ui-session "btw")))))

(ert-deftest harness-ui-read-session-can-leave-seeds-out ()
  "A caller's predicate keeps seeds out of the completion it builds.
`harness-ui-navigable-session-p' is what the commands that open a
session pass; without it every session, seeds included, is offered."
  (let ((harness-ui--sessions (make-hash-table :test 'equal))
        (seen nil))
    (harness-ui-cache-session (list :id "seed" :name "Shared context for main" :ext (list :seed t)))
    (harness-ui-cache-session (list :id "worker" :name "worker one"))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _) (setq seen collection) (caar collection))))
      (harness-ui-read-session "Session: " #'harness-ui-navigable-session-p)
      (should (= 1 (length seen)))
      (should (equal "worker" (plist-get (cdr (car seen)) :id)))
      (harness-ui-read-session "Session: ")
      (should (= 2 (length seen))))))

(ert-deftest harness-ui-switch-session-leaves-seeds-out ()
  "Switching to another session never offers a seed conversation."
  (let ((harness-ui--sessions (make-hash-table :test 'equal))
        (seen nil)
        (displayed nil))
    (harness-ui-cache-session (list :id "seed" :name "Shared context for main" :ext (list :seed t)))
    (harness-ui-cache-session (list :id "worker" :name "worker one"))
    (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
               (lambda (&optional callback) (when callback (funcall callback (harness-ui-sessions)))))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _) (setq seen collection) (caar collection)))
              ((symbol-function 'harness-ui-display-session)
               (lambda (id &rest _) (setq displayed id))))
      (harness-switch-session)
      (should (equal "worker" displayed))
      (should (= 1 (length seen))))))

;;;; Views that follow the harness only while a window shows them

(defun harness-ui-test--spin (seconds)
  "Let the timers due within SECONDS run."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.02))))

(defmacro harness-ui-test-with-view (&rest body)
  "Run BODY with `view', a live buffer shown in the selected window.
`other' is another buffer.  Both are killed after."
  (declare (indent 0))
  `(let ((view (generate-new-buffer " *harness-ui-test-view*"))
         (other (generate-new-buffer " *harness-ui-test-other*"))
         (shown (window-buffer (selected-window))))
     (unwind-protect
         (progn (set-window-buffer (selected-window) view) ,@body)
       (set-window-buffer (selected-window) shown)
       (mapc #'kill-buffer (list view other)))))

(ert-deftest harness-ui-view-follows-a-buffer-only-while-a-window-shows-it ()
  "`harness-ui-view-follow-p' says yes for a shown buffer and notes the change it skips otherwise.
A change a hidden view skipped is noted in `harness-ui-view-stale',
which only drawing the view clears (`harness-ui-view-drawn'): that a
window shows it again does not."
  (harness-ui-test-with-view
    (should (harness-ui-view-shown-p view))
    (should (harness-ui-view-follow-p view))
    (should-not (buffer-local-value 'harness-ui-view-stale view))
    ;; Hidden: no, and the change is noted, in the view and not in the others.
    (set-window-buffer (selected-window) other)
    (should-not (harness-ui-view-shown-p view))
    (should-not (harness-ui-view-follow-p view))
    (should (buffer-local-value 'harness-ui-view-stale view))
    (should-not (buffer-local-value 'harness-ui-view-stale other))
    ;; Shown again it follows, and is as stale as it was until it is drawn.
    (set-window-buffer (selected-window) view)
    (should (harness-ui-view-follow-p view))
    (should (buffer-local-value 'harness-ui-view-stale view))
    (harness-ui-view-drawn view)
    (should-not (buffer-local-value 'harness-ui-view-stale view))
    ;; The current buffer is the default, and a dead buffer follows nothing.
    (with-current-buffer view (should (harness-ui-view-shown-p)) (should (harness-ui-view-follow-p)))
    (let ((dead (generate-new-buffer " *dead*")))
      (kill-buffer dead)
      (should-not (harness-ui-view-shown-p dead))
      (should-not (harness-ui-view-follow-p dead)))))

(ert-deftest harness-ui-view-catches-up-once-when-shown-after-missing-a-change ()
  "A view that missed a change catches up, once, soon after a window shows it.
Nothing is done for a view that missed nothing, or for a hook run because
a window stopped showing it, and the catch-up runs in the view's buffer
with the view no longer stale."
  (harness-ui-test-with-view
    (let ((calls nil))
      (cl-flet ((install ()
                  (with-current-buffer view
                    (harness-ui-view-install
                     (lambda () (push (list (current-buffer) harness-ui-view-stale) calls))))))
        (install)
        (should (memq #'harness-ui-view--shown
                      (buffer-local-value 'window-buffer-change-functions view)))
        ;; Installed again, as a reload does it, the view is hooked once.
        (install)
        (should (= 1 (cl-count #'harness-ui-view--shown
                               (buffer-local-value 'window-buffer-change-functions view)))))
      ;; Not stale: showing it does nothing.
      (with-current-buffer view (harness-ui-view--shown (selected-window)))
      (harness-ui-test--spin 0.2)
      (should-not calls)
      ;; Stale and hidden: the hook runs for the window that left, and does nothing.
      (set-window-buffer (selected-window) other)
      (harness-ui-view-follow-p view)
      (with-current-buffer view (harness-ui-view--shown (selected-window)))
      (harness-ui-test--spin 0.2)
      (should-not calls)
      (should (buffer-local-value 'harness-ui-view-stale view))
      ;; Shown, however often the hook runs: one catch-up, in the view, not stale.
      (set-window-buffer (selected-window) view)
      (with-current-buffer view
        (harness-ui-view--shown (selected-window))
        (harness-ui-view--shown (selected-window)))
      (should-not calls)                ; redisplay runs the hook: the work waits
      ;; The catch-up is on its way: the mark of a suspended view does not flash.
      (should (equal "" (with-current-buffer view (harness-ui-view-indicator))))
      (harness-test-wait (lambda () calls) 5 "the view to catch up")
      (harness-ui-test--spin 0.2)
      (should (equal (list (list view nil)) calls))
      (should-not (buffer-local-value 'harness-ui-view-stale view))
      ;; Hidden again before the timer ran: nothing is drawn for nobody, and
      ;; the view, still behind, is marked once more.
      (setq calls nil)
      (set-window-buffer (selected-window) other)
      (harness-ui-view-follow-p view)
      (set-window-buffer (selected-window) view)
      (with-current-buffer view (harness-ui-view--shown (selected-window)))
      (set-window-buffer (selected-window) other)
      (harness-ui-test--spin 0.2)
      (should-not calls)
      (should (equal "[Suspended: resume]"
                     (substring-no-properties (with-current-buffer view (harness-ui-view-indicator))))))))

(ert-deftest harness-ui-view-says-it-is-suspended-and-wakes-on-a-click ()
  "A view that missed changes says so in its mode line, the same in every view, and a click wakes it.
Should a window show it without the catch-up having run, the mark
\[Suspended: resume] is drawn from `mode-line-misc-info', which every
view that `harness-ui-view-install's has, once; clicking it, or RET
with point on it, brings the view up to date and takes the mark away."
  (harness-ui-test-with-view
    (let ((woken 0) (other-view other))
      (cl-flet ((install (buffer)
                  (with-current-buffer buffer
                    (harness-ui-view-install (lambda () (cl-incf woken)))))
                (indicator (buffer) (with-current-buffer buffer (harness-ui-view-indicator))))
        (install view)
        (install other-view)
        (install view)                  ; as a reload does it
        ;; The same element, once, in each view's own mode line, and no other buffer's.
        (dolist (buffer (list view other-view))
          (should (= 1 (cl-count harness-ui-view--mode-line
                                 (buffer-local-value 'mode-line-misc-info buffer) :test #'equal)))
          (should (equal "" (indicator buffer))))
        (should-not (member harness-ui-view--mode-line (default-value 'mode-line-misc-info)))
        ;; A buffer that is no view has no mark, though a stale flag is set in it.
        (with-temp-buffer
          (setq harness-ui-view-stale t)
          (should (equal "" (harness-ui-view-indicator))))
        ;; Missed changes: the mark, whoever looks, until the view is drawn.
        (set-window-buffer (selected-window) other)
        (should-not (harness-ui-view-follow-p view))
        (set-window-buffer (selected-window) view)
        (let ((mark (indicator view)))
          (should (equal "[Suspended: resume]" (substring-no-properties mark)))
          (should (eq 'harness-ui-view-suspended-face (get-text-property 0 'face mark)))
          (should (eq 'mode-line-highlight (get-text-property 0 'mouse-face mark)))
          (should (string-match-p "Click" (get-text-property 0 'help-echo mark)))
          (should (equal "" (indicator other-view)))
          ;; A click on it wakes the view: caught up, not stale, no mark.
          (let ((event (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
            (funcall (lookup-key (get-text-property 0 'local-map mark) [mode-line mouse-1]) event))
          (should (= 1 woken))
          (should-not (buffer-local-value 'harness-ui-view-stale view))
          (should (equal "" (indicator view))))
        ;; Drawn by other means, the mark goes too.
        (set-window-buffer (selected-window) other)
        (harness-ui-view-follow-p view)
        (should (equal "[Suspended: resume]" (substring-no-properties (indicator view))))
        (harness-ui-view-drawn view)
        (should (equal "" (indicator view)))
        (should (= 1 woken))
        ;; The command is the click's, and only for a view.
        (with-current-buffer view (harness-ui-view-follow-p view) (harness-ui-view-wake))
        (should (= 2 woken))
        (with-temp-buffer (should-error (harness-ui-view-wake) :type 'user-error))))))

(ert-deftest harness-ui-session-help-function-makes-the-tooltip-when-asked-for ()
  "A tooltip made on hover reads the session as the cache has it then.
Not before it is asked for, and with the snapshot it was made from when
the cache has lost the session or the session has no id."
  (let ((harness-ui--sessions (make-hash-table :test 'equal))
        (calls 0))
    (harness-ui-cache-session (list :id "s" :name "first"))
    (let ((help (harness-ui-session-help-function
                 (harness-ui-session "s")
                 (lambda (session) (cl-incf calls) (plist-get session :name)))))
      (should (functionp help))
      (should (= 0 calls))
      (should (equal "first" (funcall help nil nil 0)))
      (harness-ui-cache-session (list :id "s" :name "second"))
      (should (equal "second" (funcall help (selected-window) (current-buffer) 7)))
      (should (= 2 calls))
      ;; The cache lost it: the session as it was.
      (remhash "s" harness-ui--sessions)
      (should (equal "first" (funcall help nil nil 0))))
    ;; A session standing for several has no id to look up.
    (let ((help (harness-ui-session-help-function (list :name "total")
                                                  (lambda (session) (plist-get session :name)))))
      (should (equal "total" (funcall help nil nil 0))))))

(ert-deftest harness-ui-formatters-make-a-tooltip-on-hover-when-lazy ()
  "With LAZY the figure is the same and its tooltip is a function making the same text.
The context, output, average rate and spend figures, which a session
list draws a thousand of at every redraw."
  (let ((harness-ui--sessions (make-hash-table :test 'equal))
        (harness-ui--live (make-hash-table :test 'equal)))
    (harness-ui-cache-session
     (list :id "s" :name "work" :model "demo:scripted" :context-window 200000 :status "idle"
           :usage (list :cost 1.5 :context 41000 :last-output 900 :output 7000
                        :stream-output 6000 :stream-seconds 100.0)))
    (let ((s (harness-ui-session "s")))
      (cl-flet ((help (string)
                  (let ((help (get-text-property 0 'help-echo string)))
                    (if (functionp help) (funcall help (selected-window) (current-buffer) 0) help))))
        (dolist (case (list (list (harness-ui-format-context s) (harness-ui-format-context s t))
                            (list (harness-ui-format-output s) (harness-ui-format-output s nil t))
                            (list (harness-ui-format-average-rate s) (harness-ui-format-average-rate s nil t))
                            (list (harness-ui-format-spend s) (harness-ui-format-spend s nil nil t))
                            (list (harness-ui-format-spend s nil "This task")
                                  (harness-ui-format-spend s nil "This task" t))))
          (let ((eager (nth 0 case)) (lazy (nth 1 case)))
            (should (stringp (get-text-property 0 'help-echo eager)))
            (should (functionp (get-text-property 0 'help-echo lazy)))
            (should (equal (substring-no-properties eager) (substring-no-properties lazy)))
            (should (equal (get-text-property 0 'face eager) (get-text-property 0 'face lazy)))
            (should (equal (help eager) (help lazy)))))
        ;; The hover reads the figures it finds then, the text what it was drawn with.
        (let ((lazy (harness-ui-format-context s t)))
          (harness-ui--store-live "s" '(:context 150000 :output 9000 :estimated 0))
          (should (equal "41.9k/200k" (substring-no-properties lazy)))
          (should (string-match-p "in use: 150k of" (help lazy))))))))

(provide 'harness-ui-test)
;;; harness-ui-test.el ends here
