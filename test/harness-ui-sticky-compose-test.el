;;; harness-ui-sticky-compose-test.el --- The compose box docked in the mode line  -*- lexical-binding: t; -*-

;;; Commentary:

;; A chat window scrolled away from its compose box draws a compact copy
;; of the box in its mode line while the module is on and the chat is
;; composing.  The tests build a chat buffer without a session: the dock
;; reads the box, the window and the mode line, and nothing of a model.
;; Batch Emacs has no displayed window, so the tests say what is in view
;; (`harness-ui-sticky-compose--visible-p') and what the command did.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-chat--buffers)
(defvar harness-chat--transcript-end)
(defvar harness-ui--sessions)

(defmacro harness-ui-sticky-compose-test-with (&rest body)
  "Load the UI and the sticky compose module, then run BODY.
Every chat buffer the tests make is killed, every dock is taken off and
the window configuration is put back."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(acp ui ui-compose ui-chat))
         (harness-test-load-module m)))
     (clrhash harness-ui--sessions)
     (clrhash harness-chat--buffers)
     (let ((config (current-window-configuration)))
       (unwind-protect
           (progn
             (harness-test-load-module 'ui-sticky-compose)
             (unwind-protect
                 (progn ,@body)
               (when (bound-and-true-p harness-sticky-compose-mode)
                 (harness-sticky-compose-mode -1))
               (dolist (buffer (buffer-list))
                 (with-current-buffer buffer
                   (when (derived-mode-p 'harness-chat-mode)
                     (let ((kill-buffer-query-functions nil))
                       (kill-buffer buffer)))))))
         (set-window-configuration config)))))

(defun harness-ui-sticky-compose-test-chat (&optional text)
  "Make a chat buffer holding TEXT in its compose box, and return it.
The transcript is one agent message before the box."
  (let ((buffer (generate-new-buffer "*sticky chat*")))
    (with-current-buffer buffer
      (harness-chat-mode)
      (let ((inhibit-read-only t))
        (insert "A message from the agent.\n"))
      (setq harness-chat--transcript-end (copy-marker (point-max) t))
      (harness-compose-insert text)
      (goto-char harness-compose-end))
    buffer))

(defun harness-ui-sticky-compose-test-away (buffer)
  "Put point outside BUFFER's box, as a scroll away from it would."
  (with-current-buffer buffer
    (goto-char (point-min))))

(defun harness-ui-sticky-compose-test-dock (buffer &optional window)
  "Scroll BUFFER away from its box and decide on WINDOW, its window."
  (let ((window (or window (selected-window))))
    (with-current-buffer buffer
      (harness-ui-sticky-compose-test-away buffer)
      (setq harness-ui-sticky-compose--focus nil)
      (harness-ui-sticky-compose--redisplay window))
    window))

(defun harness-ui-sticky-compose-test-dock-text (buffer)
  "Return the dock text of BUFFER, without properties."
  (with-current-buffer buffer
    (substring-no-properties
     (nth 2 (harness-ui-sticky-compose--line)))))

;;;; What the dock says

(ert-deftest harness-ui-sticky-compose-fit-keeps-the-draft-and-gives-way ()
  "The draft has the room the mode line leaves, the button and counts what is left.
A narrow window drops the counts, then shortens the button, then leaves
the text alone; with less than ten columns of text there is no dock."
  (let ((info '(:text "Refactor the parser so that it reads the syntax of the new files"
                :placeholder nil :lines 3 :attachments 2)))
    (let ((fit (harness-ui-sticky-compose--fit 80 info)))
      (should (equal " ↓ Compose box " (nth 2 fit)))
      (should (equal "  3 lines · 2 attachments" (nth 1 fit)))
      (should (string-match-p "Refactor the parser" (nth 0 fit))))
    (let ((fit (harness-ui-sticky-compose--fit 60 info)))
      (should (equal " ↓ Compose box " (nth 2 fit)))
      (should (equal "  3 lines · 2 attachments" (nth 1 fit)))
      (should (string-match-p "…" (nth 0 fit)))
      (should (= 16 (string-width (nth 0 fit)))))
    ;; The counts go where they leave the text less than sixteen columns.
    (let ((fit (harness-ui-sticky-compose--fit 59 info)))
      (should-not (nth 1 fit))
      (should (equal " ↓ Compose box " (nth 2 fit))))
    (let ((fit (harness-ui-sticky-compose--fit 30 info)))
      (should (equal " ↓ Compose box " (nth 2 fit)))
      (should-not (nth 1 fit))
      (should (= 11 (string-width (nth 0 fit)))))
    ;; Then the button shortens, then goes.
    (let ((fit (harness-ui-sticky-compose--fit 28 info)))
      (should (equal " ↓ " (nth 2 fit)))
      (should-not (nth 1 fit))
      (should (= 21 (string-width (nth 0 fit)))))
    (let ((fit (harness-ui-sticky-compose--fit 16 info)))
      (should-not (nth 2 fit))
      (should (= 12 (string-width (nth 0 fit)))))
    (should-not (harness-ui-sticky-compose--fit 13 info))))

(ert-deftest harness-ui-sticky-compose-excerpt-keeps-the-start-and-the-end ()
  "A draft too long for the dock keeps its start, more of it, and its end."
  (let ((text "Start of the message and then a great many words in between, and the end."))
    (dolist (room '(12 20 40))
      (let ((excerpt (harness-ui-sticky-compose--excerpt text room)))
        (should (<= (string-width excerpt) room))
        (should (string-prefix-p "Start" excerpt))
        (should (string-suffix-p "end." excerpt))
        (should (string-match-p "…" excerpt)))))
  (should (equal "short" (harness-ui-sticky-compose--excerpt "short" 10))))

(ert-deftest harness-ui-sticky-compose-counts-and-text-read-as-one-line ()
  "The counts name lines only past one and attachments only past none.
The draft is one line of text, white space runs collapsed, and an empty
box says what its placeholder says."
  (should-not (harness-ui-sticky-compose--counts '(:lines 1 :attachments 0)))
  (should (equal "2 lines" (harness-ui-sticky-compose--counts '(:lines 2 :attachments 0))))
  (should (equal "1 attachment"
                 (harness-ui-sticky-compose--counts '(:lines 1 :attachments 1))))
  (should (equal "3 lines · 2 attachments"
                 (harness-ui-sticky-compose--counts '(:lines 3 :attachments 2))))
  (should (equal "a b c" (harness-ui-sticky-compose--collapse "  a\n\tb  c ")))
  (should (equal "50%% done" (harness-ui-sticky-compose--escape "50% done")))
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat)))
      (with-current-buffer chat
        (let ((info (harness-ui-sticky-compose--info)))
          (should (equal "Message…" (plist-get info :text)))
          (should (plist-get info :placeholder))
          (should (equal 0 (plist-get info :lines)))
          (should (equal 0 (plist-get info :attachments))))
        (harness-compose-set "first line\nsecond line")
        (let ((info (harness-ui-sticky-compose--info)))
          (should (equal "first line second line" (plist-get info :text)))
          (should-not (plist-get info :placeholder))
          (should (equal 2 (plist-get info :lines))))
        (harness-compose-set "x")
        (setq harness-compose-attachments '((:path "a") (:path "b") (:thread t :reply 1)))
        (should (equal 2 (plist-get (harness-ui-sticky-compose--info) :attachments)))))))

(ert-deftest harness-ui-sticky-compose-composes-on-focus-or-draft ()
  "A chat composes while its box has focus or a draft, as the option says.
Only white space, and a reply card, make no draft; with the option on
draft, focus alone is not composing."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat)))
      (with-current-buffer chat
        (setq harness-ui-sticky-compose--focus nil)
        (should-not (harness-ui-sticky-compose--composing-p))
        (setq harness-ui-sticky-compose--focus t)
        (should (harness-ui-sticky-compose--composing-p))
        (setq harness-ui-sticky-compose--focus nil)
        (harness-compose-set "  \n\t ")
        (should-not (harness-ui-sticky-compose--composing-p))
        (harness-compose-set "something")
        (should (harness-ui-sticky-compose--composing-p))
        (harness-compose-set "")
        (setq harness-compose-attachments '((:path "notes.txt")))
        (should (harness-ui-sticky-compose--composing-p))
        (setq harness-compose-attachments nil
              harness-sticky-compose-when 'draft
              harness-ui-sticky-compose--focus t)
        (should-not (harness-ui-sticky-compose--composing-p))
        (harness-compose-set "a draft")
        (setq harness-ui-sticky-compose--focus nil)
        (should (harness-ui-sticky-compose--composing-p))))))

(ert-deftest harness-ui-sticky-compose-wants-a-window-scrolled-away-while-composing ()
  "A window wants the dock when the module and the chat compose, and the box is away.
A chat that is not composing, a buffer that is no chat and the module
turned off all leave the window as it was."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "a draft")))
      (set-window-buffer (selected-window) chat)
      (with-current-buffer chat
        (harness-ui-sticky-compose-test-away chat)
        (setq harness-ui-sticky-compose--focus nil)
        (cl-letf (((symbol-function 'harness-ui-sticky-compose--shown-p)
                   (lambda (_window) nil)))
          (should (harness-ui-sticky-compose--wanted-p (selected-window)))
          (let ((harness-sticky-compose-mode nil))
            (should-not (harness-ui-sticky-compose--wanted-p (selected-window))))
          (harness-compose-set "")
          (should-not (harness-ui-sticky-compose--wanted-p (selected-window)))
          (harness-compose-set "a draft")
          (harness-ui-sticky-compose--draft-p)
          (cl-letf (((symbol-function 'harness-ui-sticky-compose--shown-p)
                     (lambda (_window) t)))
            (should-not (harness-ui-sticky-compose--wanted-p (selected-window))))))
      (with-current-buffer (get-buffer-create "*not a chat*")
        (should-not (harness-ui-sticky-compose--wanted-p (selected-window)))))))

(ert-deftest harness-ui-sticky-compose-shows-when-the-box-is-away ()
  "A window shows the box when it starts inside it, shows its first line, or is the selected one at point.
A window scrolled above all of that does not."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "a draft")))
      (set-window-buffer (selected-window) chat)
      (with-current-buffer chat
        (goto-char (point-min))
        (should-not (harness-ui-sticky-compose--shown-p (selected-window)))
        (cl-letf (((symbol-function 'pos-visible-in-window-p)
                   (lambda (&rest _) t)))
          (should (harness-ui-sticky-compose--shown-p (selected-window))))
        (cl-letf (((symbol-function 'pos-visible-in-window-p)
                   (lambda (&rest _) nil)))
          (should-not (harness-ui-sticky-compose--shown-p (selected-window)))
          (set-window-start (selected-window) (harness-ui-sticky-compose--front))
          (should (harness-ui-sticky-compose--shown-p (selected-window))))
        (set-window-start (selected-window) (point-min))
        (goto-char harness-compose-end)
        (should (harness-ui-sticky-compose--shown-p (selected-window)))))))

;;;; The dock on a window

(ert-deftest harness-ui-sticky-compose-docks-a-chat-scrolled-away-from-its-box ()
  "The window gets the dock's mode line, and the mode line it had is kept.
The dock after the chat's own status names the prompt, the draft and
the button."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "a draft")))
      (set-window-buffer (selected-window) chat)
      (harness-ui-sticky-compose-test-dock chat)
      (should (equal harness-ui-sticky-compose--format
                     (window-parameter (selected-window) 'mode-line-format)))
      (should (equal (list nil)
                     (window-parameter (selected-window) 'harness-ui-sticky-compose)))
      (with-current-buffer chat
        (let ((line (harness-ui-sticky-compose--line)))
          (should (equal mode-line-format (nth 1 line)))
          (should (string-search "❯ a draft" (substring-no-properties (nth 2 line))))
          (should (string-search "Compose box" (substring-no-properties (nth 2 line)))))))))

(ert-deftest harness-ui-sticky-compose-gives-a-window-its-mode-line-back ()
  "A window whose chat stops composing, or whose buffer leaves it, gets its line back.
A mode line format the window had of its own comes back too, and a
window with no mode line is left alone."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "a draft"))
          (other (get-buffer-create "*elsewhere*")))
      (set-window-buffer (selected-window) chat)
      (set-window-parameter (selected-window) 'mode-line-format "Previous")
      (harness-ui-sticky-compose-test-dock chat)
      (should (equal harness-ui-sticky-compose--format
                     (window-parameter (selected-window) 'mode-line-format)))
      (should (equal '("Previous")
                     (window-parameter (selected-window) 'harness-ui-sticky-compose)))
      (with-current-buffer chat
        (harness-compose-set "")
        (harness-ui-sticky-compose--redisplay (selected-window)))
      (should (equal "Previous"
                     (window-parameter (selected-window) 'mode-line-format)))
      (should-not (window-parameter (selected-window) 'harness-ui-sticky-compose))
      ;; A window that shows another buffer is no chat any more.
      (set-window-parameter (selected-window) 'mode-line-format nil)
      (harness-ui-sticky-compose-test-dock chat)
      (set-window-buffer (selected-window) other)
      (with-current-buffer other
        (harness-ui-sticky-compose--redisplay (selected-window)))
      (should-not (window-parameter (selected-window) 'mode-line-format))
      (should-not (window-parameter (selected-window) 'harness-ui-sticky-compose))
      ;; A window whose mode line is suppressed keeps it so.
      (set-window-buffer (selected-window) chat)
      (set-window-parameter (selected-window) 'mode-line-format 'none)
      (harness-ui-sticky-compose-test-dock chat)
      (should (eq 'none (window-parameter (selected-window) 'mode-line-format)))
      (should-not (window-parameter (selected-window) 'harness-ui-sticky-compose))
      (set-window-buffer (selected-window) other)
      (set-window-parameter (selected-window) 'mode-line-format nil))))

(ert-deftest harness-ui-sticky-compose-docks-only-the-windows-that-need-it ()
  "One chat window gets the dock, and the window beside it, another buffer, does not."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "a draft"))
          (other (get-buffer-create "*elsewhere*")))
      (set-window-buffer (selected-window) chat)
      (let ((second (split-window (selected-window))))
        (set-window-buffer second other)
        (select-window (selected-window))
        (harness-ui-sticky-compose-test-dock chat)
        (should (equal harness-ui-sticky-compose--format
                       (window-parameter (selected-window) 'mode-line-format)))
        (should-not (window-parameter second 'mode-line-format))
        (should (equal "*elsewhere*" (buffer-name (window-buffer second))))
        (delete-window second)))))

;;;; The line it draws

(ert-deftest harness-ui-sticky-compose-line-shows-the-draft-and-its-counts ()
  "The dock shows the draft, the counts and the button after the chat's own line.
An empty box shows the placeholder instead, dimmed as it is in the box."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "first line\nsecond line")))
      (set-window-buffer (selected-window) chat)
      (with-current-buffer chat
        (setq harness-ui-sticky-compose--focus t)
        (setq harness-compose-attachments '((:path "a") (:path "b")))
        (let ((line (harness-ui-sticky-compose--line)))
          (should (equal mode-line-format (nth 1 line)))
          (let ((dock (substring-no-properties (nth 2 line))))
            (should (string-search "first line second line" dock))
            (should (string-search "2 lines · 2 attachments" dock))
            (should (string-search "↓ Compose box" dock))))
        (harness-compose-set "")
        (setq harness-compose-attachments nil)
        (should (string-search "Message…"
                               (substring-no-properties
                                (nth 2 (harness-ui-sticky-compose--line)))))
        (should (equal (harness-ui-sticky-compose--placeholder)
                       (plist-get (harness-ui-sticky-compose--info) :text)))))))

(ert-deftest harness-ui-sticky-compose-line-escapes-percent-signs ()
  "A draft's percent signs are doubled in the mode line construct.
Emacs reads them as one, so what shows is what was typed."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "50% of 100%")))
      (set-window-buffer (selected-window) chat)
      (with-current-buffer chat
        (setq harness-ui-sticky-compose--focus t)
        (let ((dock (substring-no-properties
                     (nth 2 (harness-ui-sticky-compose--line)))))
          (should (string-search "50%% of 100%%" dock))
          (should-not (string-search "50% of" dock)))))))

(ert-deftest harness-ui-sticky-compose-a-click-jumps-to-the-box ()
  "A left click on the dock, or RET, runs `harness-chat-scroll-to-bottom'."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "a draft")))
      (set-window-buffer (selected-window) chat)
      (with-current-buffer chat
        (setq harness-ui-sticky-compose--focus t)
        (let* ((dock (harness-ui-sticky-compose--dock mode-line-format (selected-window)))
               (pos (string-match "Compose box" dock))
               (map (get-text-property pos 'local-map dock))
               (called nil))
          (should (eq (lookup-key map [mode-line mouse-1])
                      (lookup-key map [mode-line mouse-1])))
          (should (lookup-key map [mode-line mouse-1]))
          (should (lookup-key map [mode-line mouse-2]))
          (should (lookup-key map (kbd "RET")))
          (cl-letf (((symbol-function 'harness-chat-scroll-to-bottom)
                     (lambda () (interactive) (setq called t))))
            (call-interactively (lookup-key map [mode-line mouse-1]))
            (should called)))))))

(ert-deftest harness-ui-sticky-compose-the-tooltip-holds-the-draft ()
  "The dock's tooltip says what it is, how it is used, and shows the draft."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "first line\nsecond line")))
      (set-window-buffer (selected-window) chat)
      (with-current-buffer chat
        (setq harness-ui-sticky-compose--focus t)
        (let* ((dock (harness-ui-sticky-compose--dock mode-line-format (selected-window)))
               (help (funcall (get-text-property 1 'help-echo dock)
                              (selected-window) nil 1)))
          (should (string-search "Compose box (mouse-1: jump to it" help))
          (should (string-search "first line\nsecond line" help)))))))

(ert-deftest harness-ui-sticky-compose-a-long-draft-is-cut-to-the-room ()
  "A draft longer than the mode line is cut with an ellipsis, both ends kept."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat
                 (concat "Beginning " (make-string 200 ?x) " end of a long draft"))))
      (set-window-buffer (selected-window) chat)
      (with-current-buffer chat
        (setq harness-ui-sticky-compose--focus t)
        (let ((dock (substring-no-properties
                     (nth 2 (harness-ui-sticky-compose--line)))))
          (should (string-search "…" dock))
          (should (string-search "Beginning" dock))
          (should (string-search "end of a long draft" dock))
          (should (< (string-width dock) 90)))))))

;;;; Focus after a command

(ert-deftest harness-ui-sticky-compose-focus-follows-commands-but-not-scrolling ()
  "Point in the box gives it focus; a scroll keeps it; anything else takes it."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "a draft")))
      (with-current-buffer chat
        (goto-char harness-compose-end)
        (let ((this-command 'self-insert-command))
          (harness-ui-sticky-compose--post-command))
        (should harness-ui-sticky-compose--focus)
        (goto-char (point-min))
        (dolist (command '(harness-chat-scroll-up mwheel-scroll scroll-bar-toolkit-scroll))
          (let ((this-command command))
            (harness-ui-sticky-compose--post-command))
          (should harness-ui-sticky-compose--focus))
        (let ((this-command 'ignore))
          (harness-ui-sticky-compose--post-command))
        (should-not harness-ui-sticky-compose--focus)
        (let ((this-command 'harness-chat-scroll-up))
          (harness-ui-sticky-compose--post-command))
        (should-not harness-ui-sticky-compose--focus)
        ;; Outside a chat the command leaves it alone.
        (with-temp-buffer
          (setq harness-ui-sticky-compose--focus t)
          (let ((this-command 'ignore))
            (harness-ui-sticky-compose--post-command))
          (should harness-ui-sticky-compose--focus))))))

;;;; The module and its mode

(ert-deftest harness-ui-sticky-compose-wires-a-chat-opened-before-it-starts ()
  "A chat open before the module starts gets its hooks when the module starts.
The compose box makes the hooks buffer-local, so the module adds its
functions to each chat buffer, the ones open then included."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (let ((harness-acp--server-enabled nil))
      (dolist (m '(acp ui ui-compose ui-chat))
        (harness-test-load-module m)))
    (clrhash harness-ui--sessions)
    (clrhash harness-chat--buffers)
    (let ((chat (harness-ui-sticky-compose-test-chat)))
      (unwind-protect
          (progn
            (with-current-buffer chat
              (should-not (memq #'harness-ui-sticky-compose--redisplay
                                pre-redisplay-functions)))
            (harness-test-load-module 'ui-sticky-compose)
            (with-current-buffer chat
              (should (memq #'harness-ui-sticky-compose--redisplay
                            pre-redisplay-functions))
              (should (memq #'harness-ui-sticky-compose--post-command
                            post-command-hook))))
        (when (bound-and-true-p harness-sticky-compose-mode)
          (harness-sticky-compose-mode -1))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest harness-ui-sticky-compose-the-module-starts-and-stops ()
  "The module turns the mode on, and disables it: every dock and hook goes.
Starting it again wires the chats open now and the ones opened later."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "a draft")))
      (set-window-buffer (selected-window) chat)
      (harness-ui-sticky-compose-test-dock chat)
      (should (harness-module-ready-p 'ui-sticky-compose))
      (should harness-sticky-compose-mode)
      (with-current-buffer chat
        (should (memq #'harness-ui-sticky-compose--redisplay pre-redisplay-functions))
        (should (memq #'harness-ui-sticky-compose--post-command post-command-hook)))
      (should (memq #'harness-ui-sticky-compose--wire-buffer harness-chat-mode-hook))
      (harness-module-disable 'ui-sticky-compose)
      (should-not harness-sticky-compose-mode)
      (should (eq 'disabled (harness-module-state (harness-module-get 'ui-sticky-compose))))
      (should-not (window-parameter (selected-window) 'mode-line-format))
      (should-not (window-parameter (selected-window) 'harness-ui-sticky-compose))
      (with-current-buffer chat
        (should-not (memq #'harness-ui-sticky-compose--redisplay pre-redisplay-functions))
        (should-not (memq #'harness-ui-sticky-compose--post-command post-command-hook)))
      (should-not (memq #'harness-ui-sticky-compose--wire-buffer harness-chat-mode-hook))
      (setf (harness-module-state (harness-module-get 'ui-sticky-compose)) 'registered)
      (should (harness-module-start 'ui-sticky-compose))
      (should harness-sticky-compose-mode)
      (with-current-buffer chat
        (should (memq #'harness-ui-sticky-compose--redisplay pre-redisplay-functions)))
      (let ((later (harness-ui-sticky-compose-test-chat)))
        (with-current-buffer later
          (should (memq #'harness-ui-sticky-compose--redisplay pre-redisplay-functions)))))))

(ert-deftest harness-ui-sticky-compose-turning-off-and-on-keeps-the-chats ()
  "Turning the mode off takes every dock off and on puts them back.
A chat opened while it is off gets the hooks when it comes on."
  (harness-ui-sticky-compose-test-with
    (let ((chat (harness-ui-sticky-compose-test-chat "a draft")))
      (set-window-buffer (selected-window) chat)
      (harness-ui-sticky-compose-test-dock chat)
      (should (window-parameter (selected-window) 'mode-line-format))
      (harness-sticky-compose-mode -1)
      (should-not (window-parameter (selected-window) 'mode-line-format))
      (with-current-buffer chat
        (should-not (memq #'harness-ui-sticky-compose--redisplay pre-redisplay-functions)))
      (let ((later (harness-ui-sticky-compose-test-chat)))
        (harness-sticky-compose-mode 1)
        (dolist (buffer (list chat later))
          (with-current-buffer buffer
            (should (memq #'harness-ui-sticky-compose--redisplay pre-redisplay-functions))
            (should (memq #'harness-ui-sticky-compose--post-command post-command-hook))))))))

(provide 'harness-ui-sticky-compose-test)
;;; harness-ui-sticky-compose-test.el ends here
