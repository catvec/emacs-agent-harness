;;; harness-ui-sticky-compose.el --- The compose box, docked in the mode line of a window scrolled away from it  -*- lexical-binding: t; -*-

;;; Commentary:

;; Scroll up through a session's history while you write, and the
;; compose box, the last thing in the chat's buffer, goes out of sight
;; with the rest of the tail.  With this module a chat window that is
;; scrolled away from its box and has something to say of it -- you were
;; in it when you scrolled, or it holds unsent text or attachments --
;; draws a compact copy of it in its mode line, after the chat's own
;; status, which stays:
;;
;;   ● idle   ❯ Refactor the parser so… the docs for the changed API.   2 lines   ↓ Compose box
;;
;; The prompt, the start and the end of the draft with an ellipsis
;; between where it is longer than the room, how many lines and
;; attachments it has, and a button.  A click on any of it, or C-c C-e
;; (`harness-chat-scroll-to-bottom'), shows the newest messages and puts
;; point in the real box.  The tooltip holds the draft.  Typing outside
;; the box already types into it, so the dock is what tells you there is
;; a box to type into, and what you wrote.
;;
;; WHY THE MODE LINE.  The chat draws its tail -- the activity line, the
;; queue, the requests it waits on, the todo list, the panels of
;; `harness-chat-panel-functions', the attachments and the box -- as
;; buffer text after the transcript, and draws all of it again, deleted
;; and inserted, at every change (`harness-chat--render-tail').  A panel
;; therefore stands in the tail and scrolls away with it: a panel
;; function cannot dock anything.  The box cannot be pinned either, being
;; text at the end of the buffer.  A copy drawn in the text of the window
;; -- an overlay that moves with the scrolling, say -- would have to be
;; put again at every scroll and every draw of the tail, and would sit in
;; the arithmetic the chat's scrolling does with the window's last line
;; (`harness-chat--bottom-line', `harness-chat--bottom-windows').  The
;; mode line is the row Emacs keeps at the bottom of every window, drawn
;; from state, not from text, so a draw of the tail leaves it alone.  It
;; is one row, which is why the copy is compact.
;;
;; WHEN.  A window shows the dock when the module is on, its buffer is a
;; chat with a box, the box is out of view, and the chat is composing
;; (`harness-sticky-compose-when'): `focus', the default, is while the
;; box has focus or holds a draft, `draft' while it holds one.  Focus is
;; point in the box when a command ends (`harness-ui-sticky-compose--post-command');
;; scrolling, by the wheel, a scroll bar or the keys, leaves it as it
;; was, though the chat's scrolling moves point out of the box, and any
;; other command that leaves the box -- a click in the transcript, a
;; search -- takes it.  The box counts as in view when the window starts
;; inside it, or shows the first line of it whole, or is the selected
;; window with point in it.
;;
;; HOW.  The dock is a window parameter, `mode-line-format', put on a
;; window while it shows the dock and taken off, with what it had, when
;; it does not: nothing else is changed, so what Emacs draws without the
;; module is what it draws once the module is off.  The decision is made
;; before every redisplay (`pre-redisplay-functions'), per window, and
;; after every command (`post-command-hook'): a window whose buffer is no
;; chat any more, or whose chat is composing no more, gets its mode line
;; back.  Both hooks are buffer-local in a chat, because the compose box
;; makes them so; the functions therefore go into the chat buffers
;; themselves: the ones open when the module starts, and every one opened
;; later.  Measuring a window formats its mode line, so the mode line
;; never measures: it
;; draws what the decision left (`harness-ui-sticky-compose--line').  A
;; chat that is not composing costs a few comparisons; one that is costs a
;; measure of one line of text, as the chat's own newer-messages notice
;; does (`harness-chat--update-notice').  `harness-sticky-compose-mode'
;; turns it all on and off in a running Emacs; the module turns it on when
;; it starts, once, and a reload leaves it as you have it.  Without the
;; module nothing here is loaded.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat--transcript-end)
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-compose-attachments)
(defvar harness-compose-placeholder-function)
(defvar harness-sticky-compose-mode)

(declare-function harness-compose-live-p "harness-ui-compose" ())
(declare-function harness-compose-in-p "harness-ui-compose" (&optional pos))
(declare-function harness-chat-scroll-to-bottom "harness-ui-chat" ())

(defgroup harness-ui-sticky-compose nil
  "The compose box, docked in the mode line of a chat window scrolled away from it."
  :group 'harness-ui)

(defcustom harness-sticky-compose-when 'focus
  "When a chat window scrolled away from its compose box shows the dock.
`focus' is while the box has focus or holds a draft; `draft' is while it
holds one.  The box has focus when point was in it as the window
scrolled away, and no command but a scroll has taken it out since.  A
draft is text, or attachments, not sent yet."
  :type '(choice (const :tag "Focus or draft" focus)
                 (const :tag "Draft" draft))
  :group 'harness-ui-sticky-compose)

(defface harness-sticky-compose-face '((t :inherit harness-compose-face))
  "Background of the dock, the compose box's own by default.
Only the background is set: the dock's text keeps the mode line's
height, so a window never changes size as its dock comes and goes."
  :group 'harness-ui-sticky-compose)

(defconst harness-ui-sticky-compose--parameter 'harness-ui-sticky-compose
  "The window parameter that says a window shows the dock.
Its value is (FORMAT), the `mode-line-format' parameter the window had
before, which `harness-ui-sticky-compose--undock' puts back.")

(defconst harness-ui-sticky-compose--format '((:eval (harness-ui-sticky-compose--line)))
  "The `mode-line-format' parameter of a window that shows the dock.")

(defvar-local harness-ui-sticky-compose--focus t
  "Non-nil while this chat's compose box has focus.
Set after a command that ends with point in the box, kept through a
scroll, cleared after any other command that leaves point outside it
\(`harness-ui-sticky-compose--post-command').  A chat starts with it:
the box is where it puts point.")

(defconst harness-ui-sticky-compose--scroll-commands
  '(scroll-bar-toolkit-scroll scroll-bar-drag scroll-bar-scroll-up scroll-bar-scroll-down
    scroll-bar-set-window-start)
  "Scroll commands that carry no `scroll-command' property, by their names.
The wheel, the keys and the pixel scrolling carry one.")

;;;; When

(defun harness-ui-sticky-compose--chat-p ()
  "Non-nil in a chat buffer that has a transcript and a compose box.
Another view of a session -- its access view, which draws tool calls as
the chat does -- has neither."
  (and (derived-mode-p 'harness-chat-mode)
       (not harness-ui-session-view)
       harness-chat--transcript-end
       (marker-buffer harness-chat--transcript-end)
       (harness-compose-live-p)))

(defun harness-ui-sticky-compose--draft-p ()
  "Non-nil when this chat's compose box holds unsent text or attachments."
  (or harness-compose-attachments
      (save-excursion
        (goto-char harness-compose-start)
        (skip-chars-forward " \t\n" harness-compose-end)
        (< (point) harness-compose-end))))

(defun harness-ui-sticky-compose--composing-p ()
  "Non-nil when this chat is composing: its box has a draft, or has focus.
`harness-sticky-compose-when' says whether focus counts."
  (or (harness-ui-sticky-compose--draft-p)
      (and (eq harness-sticky-compose-when 'focus)
           harness-ui-sticky-compose--focus)))

(defun harness-ui-sticky-compose--front ()
  "Return where this chat's compose box starts, its prompt included."
  (save-excursion
    (goto-char harness-compose-start)
    ;; The prompt is a field of its own, which the line's start stops after.
    (let ((inhibit-field-text-motion t))
      (line-beginning-position))))

(defun harness-ui-sticky-compose--visible-p (window)
  "Non-nil when WINDOW shows the first line of the compose box, whole."
  (pos-visible-in-window-p harness-compose-start window))

(defun harness-ui-sticky-compose--shown-p (window)
  "Non-nil when WINDOW shows the compose box, or is about to.
It does when WINDOW starts in the box, or shows its first line whole.
The selected window with point in the box is about to: redisplay shows
point, and asking costs nothing, where measuring a window that is being
typed in costs a line of text at every key."
  (or (and (eq window (selected-window)) (harness-compose-in-p))
      (>= (window-start window) (harness-ui-sticky-compose--front))
      (harness-ui-sticky-compose--visible-p window)))

(defun harness-ui-sticky-compose--wanted-p (window)
  "Non-nil when WINDOW, which shows the current buffer, is to show the dock."
  (and harness-sticky-compose-mode
       (harness-ui-sticky-compose--chat-p)
       (harness-ui-sticky-compose--composing-p)
       (not (harness-ui-sticky-compose--shown-p window))))

;;;; What is shown

(defconst harness-ui-sticky-compose--read-limit 2000
  "How many characters of a long draft are read from each end of the box.")

(defun harness-ui-sticky-compose--box-text ()
  "Return the text of this chat's compose box, from both ends when it is long."
  (let ((start harness-compose-start)
        (end harness-compose-end)
        (limit harness-ui-sticky-compose--read-limit))
    (if (<= (- end start) (* 2 limit))
        (buffer-substring-no-properties start end)
      (concat (buffer-substring-no-properties start (+ start limit))
              "\n"
              (buffer-substring-no-properties (- end limit) end)))))

(defun harness-ui-sticky-compose--collapse (text)
  "Return TEXT as one line, each run of white space or control characters a space."
  (string-trim (replace-regexp-in-string "[[:space:][:cntrl:]]+" " " text)))

(defun harness-ui-sticky-compose--placeholder ()
  "Return what the empty box says, its placeholder, as a line."
  (harness-ui-sticky-compose--collapse
   (or (ignore-errors (funcall harness-compose-placeholder-function))
       "Message…")))

(defun harness-ui-sticky-compose--info ()
  "Return what this chat's compose box holds, as a plist for the dock.
:text is the draft as one line, or the box's placeholder when there is
none and :placeholder is non-nil; :lines how many lines the box has and
:attachments how many files, images and tasks are attached (a reply in
a thread is a card in the text, no line of its own)."
  (let ((text (harness-ui-sticky-compose--collapse (harness-ui-sticky-compose--box-text))))
    (list :text (if (string-empty-p text) (harness-ui-sticky-compose--placeholder) text)
          :placeholder (string-empty-p text)
          :lines (count-lines harness-compose-start harness-compose-end)
          :attachments (cl-count-if-not (lambda (att) (and (consp att) (plist-get att :thread)))
                                        harness-compose-attachments))))

(defun harness-ui-sticky-compose--counts (info)
  "Return how many lines and attachments INFO says the box has, as text, or nil.
\"2 lines · 1 attachment\": a count of one line is left out, and so is none."
  (let ((lines (plist-get info :lines))
        (attachments (plist-get info :attachments)))
    (when-let* ((parts (delq nil
                             (list (and (> lines 1) (format "%d lines" lines))
                                   (and (> attachments 0)
                                        (format "%d attachment%s" attachments
                                                (if (= attachments 1) "" "s")))))))
      (string-join parts " · "))))

(defun harness-ui-sticky-compose--last-columns (string width)
  "Return the longest end of STRING that takes at most WIDTH columns."
  (let ((start (length string)) (used 0))
    (while (and (> start 0) (<= (+ used (char-width (aref string (1- start)))) width))
      (setq start (1- start)
            used (+ used (char-width (aref string start)))))
    (substring string start)))

(defun harness-ui-sticky-compose--excerpt (text room)
  "Return TEXT in at most ROOM columns.
A text that does not fit keeps its start and its end, a little more of
the start, with an ellipsis between: what a draft began with says which
it is, and where it ends is where you were."
  (if (<= (string-width text) room)
      text
    (let* ((keep (max 0 (1- room)))
           (head (ceiling (* 0.6 keep))))
      (concat (truncate-string-to-width text head)
              "…"
              (harness-ui-sticky-compose--last-columns text (- keep head))))))

(defconst harness-ui-sticky-compose--buttons '(" ↓ Compose box " " ↓ ")
  "The button of the dock, in the forms it takes as the room narrows.")

(defun harness-ui-sticky-compose--fit (cols info)
  "Fit the dock for INFO in COLS columns.
Return (TEXT COUNTS BUTTON): the text of the draft cut to the room left
by the rest, COUNTS the line and attachment counts with the space before
them, or nil when the text would be left with less than 16 columns, and
BUTTON, the long form or the arrow alone, or nil when even that leaves
the text less than 10.  Nil when there is no room for 10 columns of
text."
  (let ((lead 4)                        ; a space, the prompt and its space
        (least 10)
        (counts (harness-ui-sticky-compose--counts info))
        (text (plist-get info :text)))
    (cl-dolist (button (append harness-ui-sticky-compose--buttons '(nil)))
      (let ((room (- cols lead (if button (string-width button) 0))))
        (when (>= room least)
          (let* ((counts (and counts (concat "  " counts)))
                 (left (and counts (- room (string-width counts)))))
            (cl-return
             (if (and left (>= left 16))
                 (list (harness-ui-sticky-compose--excerpt text left) counts button)
               (list (harness-ui-sticky-compose--excerpt text room) nil button)))))))))

(defun harness-ui-sticky-compose--escape (string)
  "Return STRING with its percent signs doubled, which a mode line reads as itself."
  (replace-regexp-in-string "%" "%%" string t t))

(defun harness-ui-sticky-compose--preview ()
  "Return the first lines of this chat's compose box, for the tooltip, or nil."
  (let ((text (string-trim (substring (harness-ui-sticky-compose--box-text) 0
                                      (min 800 (- harness-compose-end harness-compose-start))))))
    (unless (string-empty-p text)
      (string-join (seq-take (split-string text "\n") 12) "\n"))))

(defun harness-ui-sticky-compose--help (window _object _pos)
  "Return the tooltip of the dock in WINDOW: what it is, how to use it, the draft.
A `help-echo' function, so the key is looked up on hover, not whenever
the mode line is drawn."
  (with-current-buffer (if (window-live-p window) (window-buffer window) (current-buffer))
    (concat (substitute-command-keys
             "Compose box (mouse-1: jump to it, \\[harness-chat-scroll-to-bottom])" t)
            (and (harness-ui-sticky-compose--chat-p)
                 (when-let* ((preview (harness-ui-sticky-compose--preview)))
                   (concat "\n\n" preview))))))

(defvar harness-ui-sticky-compose--map nil
  "Keymap of the dock, made once: a click runs `harness-chat-scroll-to-bottom'.")

(defun harness-ui-sticky-compose--keymap ()
  "Return the keymap of the dock."
  (or harness-ui-sticky-compose--map
      (setq harness-ui-sticky-compose--map
            (harness-ui-mouse-keymap #'harness-chat-scroll-to-bottom))))

(defun harness-ui-sticky-compose--render (fit info button-width)
  "Return the dock for FIT, as `harness-ui-sticky-compose--fit' made it.
INFO says what it is of.  BUTTON-WIDTH is the width in pixels of FIT's
button, which is put at the window's right edge.  The string is a mode
line construct: its percent signs are doubled."
  (pcase-let* ((`(,text ,counts ,button) fit)
               (face 'harness-sticky-compose-face)
               (dim (list 'harness-dim-face face)))
    (concat
     " "
     (propertize
      (concat
       (propertize " ❯ " 'face dim)
       (propertize (harness-ui-sticky-compose--escape text)
                   'face (if (plist-get info :placeholder) dim face))
       (and counts (propertize (harness-ui-sticky-compose--escape counts) 'face dim))
       ;; The button stands at the right edge; the space before it opens
       ;; to what the text leaves.  Past the edge, the last space paints
       ;; the rest of the row: the scroll bar's width, say.
       (and button
            (concat (propertize " " 'face face
                                'display `(space :align-to (- right (,button-width))))
                    (propertize button 'face dim 'mouse-face 'mode-line-highlight)))
       (propertize " " 'face face 'display '(space :align-to 9999)))
      'help-echo #'harness-ui-sticky-compose--help
      'local-map (harness-ui-sticky-compose--keymap)))))

(defun harness-ui-sticky-compose--pixels (string)
  "Return how wide STRING shows in a mode line, in pixels."
  (string-pixel-width string))

(defun harness-ui-sticky-compose--right (window)
  "Return the x of WINDOW's right edge, in pixels: where `:align-to right' goes.
That is the window less its scroll bar, as the header line's width is
\(`harness-ui-header-width')."
  (- (window-pixel-width window)
     (or (window-scroll-bar-width window) 0)
     (or (window-right-divider-width window) 0)))

(defun harness-ui-sticky-compose--dock (base &optional window)
  "Return the dock for WINDOW, or nil when it does not fit.
BASE is the mode line the window has otherwise, which the dock follows:
what is left of the window's width after it is the dock's.  WINDOW
defaults to the selected window, the one being drawn."
  (let* ((window (or window (selected-window)))
         (right (harness-ui-sticky-compose--right window))
         (used (harness-ui-sticky-compose--pixels (format-mode-line base 'mode-line window)))
         (char (max 1 (frame-char-width (window-frame window))))
         (info (harness-ui-sticky-compose--info))
         ;; Two columns short of the room: the fonts of a mode line may
         ;; not be the default's, and a row wider than its window is cut.
         (fit (harness-ui-sticky-compose--fit (- (/ (- right used) char) 2) info)))
    (when fit
      (harness-ui-sticky-compose--render
       fit info (if (nth 2 fit) (harness-ui-sticky-compose--pixels (nth 2 fit)) 0)))))

(defun harness-ui-sticky-compose--line ()
  "Return the mode line of the window being drawn while it shows the dock.
That is the line the window has otherwise -- its own window parameter,
or the buffer's, when it had none -- and the dock after it.  It is
called from the mode line, where the selected window is the one being
drawn, and must not measure the window (`pos-visible-in-window-p'
formats the mode line, which would call this again):
`harness-ui-sticky-compose--redisplay' decides whether the dock shows,
and this draws it.  A window that shows another buffer than a chat, as
the decision has yet to notice, gets the mode line of the buffer."
  (let* ((window (selected-window))
         (saved (window-parameter window harness-ui-sticky-compose--parameter))
         (base (or (car saved) mode-line-format)))
    (or (and (harness-ui-sticky-compose--chat-p)
             (condition-case err
                 (when-let* ((dock (harness-ui-sticky-compose--dock base window)))
                   (list "" base dock))
               (error (harness-log 'debug "sticky compose: drawing the dock failed: %s"
                                   (error-message-string err))
                      nil)))
        base)))

;;;; Showing and taking it away

(defun harness-ui-sticky-compose--dock-window (window)
  "Put the dock on WINDOW, keeping the mode line format it had.
A window whose mode line is suppressed keeps it so: there is no row to
dock in."
  (unless (or (window-parameter window harness-ui-sticky-compose--parameter)
              (eq (window-parameter window 'mode-line-format) 'none))
    (set-window-parameter window harness-ui-sticky-compose--parameter
                          (list (window-parameter window 'mode-line-format)))
    (set-window-parameter window 'mode-line-format harness-ui-sticky-compose--format)
    (force-mode-line-update)))

(defun harness-ui-sticky-compose--undock (window)
  "Take the dock off WINDOW, giving it the mode line format it had before.
The format is given back only while it is still the dock's: another
module may have put one of its own there meanwhile, which stays."
  (when-let* ((saved (window-parameter window harness-ui-sticky-compose--parameter)))
    (when (equal (window-parameter window 'mode-line-format)
                 harness-ui-sticky-compose--format)
      (set-window-parameter window 'mode-line-format (car saved)))
    (set-window-parameter window harness-ui-sticky-compose--parameter nil)
    (force-mode-line-update)))

(defun harness-ui-sticky-compose--redisplay (&optional window)
  "Show the dock on WINDOW, or take it off, as its chat stands.
On `pre-redisplay-functions', which runs it for each window to be drawn,
with the window's buffer current.  A window with the dock whose buffer
is no chat, or is not composing any more, gets its mode line back.  A
failure here would stop the other functions of the hook, and the
padding of the compose box with them: it is logged instead."
  (condition-case err
      (let ((window (or window (selected-window))))
        (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
          (cond ((harness-ui-sticky-compose--wanted-p window)
                 (harness-ui-sticky-compose--dock-window window))
                ((window-parameter window harness-ui-sticky-compose--parameter)
                 (harness-ui-sticky-compose--undock window)))))
    (error (harness-log 'warn "sticky compose: deciding on a window failed: %s"
                        (error-message-string err)))))

(defun harness-ui-sticky-compose--scrolling-p ()
  "Non-nil when the command that just ran scrolled: wheel, scroll bar or keys."
  (and (symbolp this-command)
       (or (get this-command 'scroll-command)
           (memq this-command harness-ui-sticky-compose--scroll-commands))))

(defun harness-ui-sticky-compose--post-command ()
  "Note whether this chat's compose box has focus.
On `post-command-hook', where it must stay cheap: the box has focus
after a command that leaves point in it, and keeps it through a scroll,
which the chat's own scrolling answers by moving point out of the box.
Any other command that leaves point outside it takes the focus."
  (condition-case err
      (when (and (derived-mode-p 'harness-chat-mode) (harness-compose-live-p))
        (cond ((harness-compose-in-p) (setq harness-ui-sticky-compose--focus t))
              ((harness-ui-sticky-compose--scrolling-p))
              (t (setq harness-ui-sticky-compose--focus nil))))
    (error (harness-log 'warn "sticky compose: noting the focus failed: %s"
                        (error-message-string err)))))

(defun harness-ui-sticky-compose--update-all ()
  "Decide on every window of every frame now, as the next redisplay would."
  (walk-windows (lambda (window)
                  (with-current-buffer (window-buffer window)
                    (harness-ui-sticky-compose--redisplay window)))
                'nomini t))

(defun harness-ui-sticky-compose--clear ()
  "Take the dock off every window of every frame."
  (walk-windows #'harness-ui-sticky-compose--undock 'nomini t)
  (force-mode-line-update t))

(defun harness-ui-sticky-compose--sync-focus ()
  "Give every open chat the focus its point says it has, as the mode starts.
A chat whose box is where point is, in the buffer or in a window, has it."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'harness-chat-mode) (harness-compose-live-p))
        (setq harness-ui-sticky-compose--focus
              (and (or (harness-compose-in-p)
                       (cl-some (lambda (window) (harness-compose-in-p (window-point window)))
                                (get-buffer-window-list buffer nil t)))
                   t))))))

(defun harness-ui-sticky-compose--each-chat (function)
  "Call FUNCTION in every live chat buffer."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'harness-chat-mode)
          (funcall function))))))

(defun harness-ui-sticky-compose--wire-buffer ()
  "Put the dock's functions on the hooks of this chat buffer.
Both hooks are buffer-local in a chat: the compose box makes them so
\(`harness-compose-setup'), and a global function would not reach a
buffer whose value is of its own."
  (add-hook 'pre-redisplay-functions #'harness-ui-sticky-compose--redisplay nil t)
  (add-hook 'post-command-hook #'harness-ui-sticky-compose--post-command nil t))

(defun harness-ui-sticky-compose--unwire-buffer ()
  "Take the dock's functions off the hooks of this chat buffer."
  (remove-hook 'pre-redisplay-functions #'harness-ui-sticky-compose--redisplay t)
  (remove-hook 'post-command-hook #'harness-ui-sticky-compose--post-command t))

(defun harness-ui-sticky-compose--wire ()
  "Put the dock's functions where they run from.
The chats open now get them at once, in their own hooks, and the ones
opened later from `harness-chat-mode-hook'."
  (add-hook 'harness-chat-mode-hook #'harness-ui-sticky-compose--wire-buffer)
  (harness-ui-sticky-compose--each-chat #'harness-ui-sticky-compose--wire-buffer))

(defun harness-ui-sticky-compose--unwire ()
  "Take the dock's functions off their hooks."
  (remove-hook 'harness-chat-mode-hook #'harness-ui-sticky-compose--wire-buffer)
  (harness-ui-sticky-compose--each-chat #'harness-ui-sticky-compose--unwire-buffer))

;;;; The mode and the module

(define-minor-mode harness-sticky-compose-mode
  "Dock the compose box in the mode line of a chat window scrolled away from it.
While you compose -- the box has focus, or holds a draft
\(`harness-sticky-compose-when') -- and scroll a chat's window so its
box is out of view, the window's mode line holds a compact copy of the
box after the chat's status: the start and the end of the draft, how
many lines and attachments it has, and [Compose box], which a click, or
\\[harness-chat-scroll-to-bottom], shows and puts point in.  Turned off,
every window has the mode line it had."
  :global t :group 'harness-ui-sticky-compose
  (if harness-sticky-compose-mode
      (progn
        (harness-ui-sticky-compose--sync-focus)
        (harness-ui-sticky-compose--wire)
        (harness-ui-sticky-compose--update-all)
        (force-mode-line-update t))
    (harness-ui-sticky-compose--unwire)
    (harness-ui-sticky-compose--clear)))

(defun harness-ui-sticky-compose--init ()
  "Turn the dock on, when the module starts.
A reload, which initialises the module again, leaves the mode as the
user has it, wiring the hooks again and deciding on the windows, as the
code may have changed.  A first start turns it on; a mode already on,
from a load whose shutdown did not run, is turned off and on again so
that its hooks are wired afresh."
  (if (harness-module-ready-p 'ui-sticky-compose)
      (when harness-sticky-compose-mode
        (harness-ui-sticky-compose--wire)
        (harness-ui-sticky-compose--update-all))
    (when harness-sticky-compose-mode
      (harness-sticky-compose-mode -1))
    (harness-sticky-compose-mode 1)))

(defun harness-ui-sticky-compose--shutdown ()
  "Turn the dock off: every window has its own mode line again."
  (harness-sticky-compose-mode -1))

(harness-define-module 'ui-sticky-compose
  :doc "The compose box, docked in the mode line of a chat window scrolled away from it, while you compose."
  :requires '(ui ui-chat ui-compose)
  :init #'harness-ui-sticky-compose--init
  :shutdown #'harness-ui-sticky-compose--shutdown)

(provide 'harness-ui-sticky-compose)
;;; harness-ui-sticky-compose.el ends here
