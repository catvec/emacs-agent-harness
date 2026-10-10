;;; harness-ui-popout.el --- A popout of one item of a session or task  -*- lexical-binding: t; -*-

;;; Commentary:

;; A popout shows one thing a session or a task holds -- the request a
;; blocked session waits on, the report a task handed in -- in a small
;; window of its own, so it can be read and acted on without opening the
;; session or leaving the view it was opened from.  Whoever owns the item
;; draws it; this file gives every popout the same frame:
;;
;;   header line   the title and a [close] button
;;   content       what the owner's RENDER function inserts, buttons,
;;                 images and text-property keymaps included
;;   compose box   optional: the shared box, for a typed answer or feedback
;;
;; The window is a side window at the bottom of the frame
;; (`harness-ui-popout-window-parameters'), selected, and fitted to its
;; content up to `harness-ui-popout-max-height', or the popout's own
;; :max-height (a report with images grows taller).  An image is not
;; drawn with the content: decoding one takes long enough that the
;; popout would open frozen, so a line where it goes says it is loading
;; and the image comes a moment later, growing the window
;; (`harness-ui-image-load').  Each item has one popout, named by a
;; KEY the owner picks, such as (pending SESSION-ID) or (report
;; TASK-ID): showing the KEY again reuses its buffer, so state the
;; owner keeps buffer-locally there survives.  The owner calls
;; `harness-ui-popout-refresh' when the item changes and
;; `harness-ui-popout-close' once there is nothing left to show.
;;
;; A popout can be opened from another, its :parent: an image of a
;; report, shown larger.  It takes the parent's window, its header says
;; [back], and closing it shows the parent there again, where it was.
;; `harness-ui-popout-image' is that image popout: one image as large as
;; the frame allows, which Emacs's image keys zoom.
;;
;; On the content, `q' closes the popout and `g' draws it again; in the
;; box, the keys are the box's, and C-c C-c sends it.  C-g closes the
;; popout once it has nothing else to quit.  Text typed in the box of a
;; popout that closes is kept for the next time its KEY shows.
;;
;; Views offer one key to pop out the item at point (`harness-ui-popout-at-point',
;; SPC on the task board): the functions on
;; `harness-ui-popout-at-point-functions' each know one kind of item.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'image)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-drag)
(require 'harness-ui-compose)

(declare-function harness-ui-media-open "harness-ui-media" (path))

(defgroup harness-ui-popout nil
  "Popouts of one item of a session or task." :group 'harness-ui)

(defcustom harness-ui-popout-window-parameters
  '((side . bottom) (slot . 2) (preserve-size . (nil . t)))
  "Where popouts appear: `display-buffer-in-side-window' parameters.
The height is fitted to the content (`harness-ui-popout-max-height')."
  :type '(alist :key-type symbol :value-type sexp) :group 'harness-ui-popout)

(defcustom harness-ui-popout-max-height 0.5
  "Height a popout grows to at most, as a fraction of its frame's."
  :type 'number :group 'harness-ui-popout)

(defcustom harness-ui-popout-min-height 4
  "Height in lines of a popout with little content."
  :type 'integer :group 'harness-ui-popout)

(defcustom harness-ui-popout-image-max-height 0.9
  "Height an image popout grows to at most, as a fraction of its frame's.
The image shows as large as that and the frame's width allow
\(`harness-ui-popout-image')."
  :type 'number :group 'harness-ui-popout)

(defcustom harness-ui-popout-image-max-scale 4
  "How many times larger than elsewhere an image popout shows an image at most.
An image smaller than the popout is scaled up to fill it, by this much
at most, so a small one shows larger without being blown up past
recognition; a larger one is scaled down to fit."
  :type 'number :group 'harness-ui-popout)

;;;; State

(defvar harness-ui-popout--buffers (make-hash-table :test 'equal)
  "KEY -> the popout buffer showing that item.")

(defvar harness-ui-popout--drafts (make-hash-table :test 'equal)
  "KEY -> (TEXT . ATTACHMENTS) left in the box of its popout when it closed.")

(defvar-local harness-ui-popout-key nil
  "The KEY of the item this popout buffer shows.")

(defvar-local harness-ui-popout--title nil "The title: a string or a function returning one.")
(defvar-local harness-ui-popout--render nil "The function drawing the content.")
(defvar-local harness-ui-popout--compose nil "Function returning the box's SUBMIT, or nil for no box.")
(defvar-local harness-ui-popout--submit nil "What the box sends with, as drawn last; nil without a box.")
(defvar-local harness-ui-popout--placeholder nil "The empty box's hint: a string or a function.")
(defvar-local harness-ui-popout--dir nil "The project directory of the box.")
(defvar-local harness-ui-popout--on-close nil "Function called once the popout closes.")
(defvar-local harness-ui-popout--parent nil "KEY of the popout this one was opened from, or nil.")
(defvar-local harness-ui-popout--max-height nil
  "Height this popout grows to at most, as a fraction of its frame's.
Nil for `harness-ui-popout-max-height'; a function of no arguments
returns either, asked each time.")
(defvar-local harness-ui-popout--content-end nil "Marker: the end of the content, the start of the box.")
(defvar-local harness-ui-popout--discard nil "Non-nil when closing drops what the box holds.")

;;;; Keys

(defvar harness-ui-popout-content-map (make-sparse-keymap)
  "Keys on a popout's content, outside its compose box.
They sit under the keymaps the content brings, which win.")

(defvar harness-ui-popout-mode-map
  ;; No `special-mode-map' parent: its letters would eat typing in the box.
  (let ((map (make-sparse-keymap))) (set-keymap-parent map (make-sparse-keymap)) map)
  "Keymap of `harness-ui-popout-mode'.")

;; Filled at top level, not in the `defvar's, so a reload updates them.
(let ((map harness-ui-popout-content-map))
  (define-key map (kbd "q") #'harness-ui-popout-quit)
  (define-key map (kbd "g") #'harness-ui-popout-redraw))

(let ((map harness-ui-popout-mode-map))
  ;; The box's keys (RET newline, C-c C-a, C-y pasting images).
  (set-keymap-parent map harness-compose-map)
  (define-key map (kbd "C-c C-c") #'harness-ui-popout-submit)
  ;; C-g, as a remapping: completion popups (corfu, company) keep their
  ;; C-g, and the global one runs when there is nothing to close.
  (define-key map [remap keyboard-quit] #'harness-ui-popout-quit))

;;;; Mode

(define-derived-mode harness-ui-popout-mode special-mode "Popout"
  "Major mode of a popout: one item of a session or task, and maybe a box.
\\<harness-ui-popout-content-map>On the content \\[harness-ui-popout-quit] closes it and \\[harness-ui-popout-redraw] draws it again; with a
box, other typing there goes into the box.
\\<harness-ui-popout-mode-map>In the box \\[harness-ui-popout-submit] sends what it holds.

\\{harness-ui-popout-mode-map}"
  (setq buffer-read-only nil)
  (setq-local header-line-format '(:eval (harness-ui-popout--header)))
  (harness-compose-setup :project (lambda () (or harness-ui-popout--dir default-directory))
                         :placeholder #'harness-ui-popout--placeholder-text
                         :redraw #'harness-ui-popout--redraw-tail)
  (add-hook 'kill-buffer-hook #'harness-ui-popout--on-kill nil t))

;; The popout's keys in the harness menu.
(put 'harness-ui-popout-mode 'harness-menu-group
     '("Popout"
       ["Popout"
        (". q" "Close" harness-ui-popout-quit)
        (". g" "Draw again" harness-ui-popout-redraw)
        ("C-c C-c" "Send the box" harness-ui-popout-submit)
        ("C-c >" "Quote reply: region or message" harness-compose-quote-reply)]))

(defun harness-ui-popout--header ()
  "Return the header line: the title, then a [close] button.
A popout opened from another one, which closing shows again, has a
[back] button instead."
  (let ((parent (harness-ui-popout--parent-buffer (current-buffer))))
    (concat " " (propertize (harness-ui-popout--title-text) 'face 'harness-label-face)
            "   "
            (propertize (if parent "[back]" "[close]")
                        'face 'harness-dim-face 'mouse-face 'mode-line-highlight
                        'help-echo (if parent
                                       (format "Back to %s (q)"
                                               (with-current-buffer parent (harness-ui-popout--title-text)))
                                     "Close this popout (q)")
                        'keymap (harness-ui-mouse-keymap #'harness-ui-popout-quit)))))

(defun harness-ui-popout--title-text ()
  "Return the title as text."
  (let ((title harness-ui-popout--title))
    (or (if (functionp title)
            (with-demoted-errors "harness-ui-popout title: %S" (funcall title))
          title)
        "")))

(defun harness-ui-popout--placeholder-text ()
  "Return the hint of the empty box."
  (let ((hint harness-ui-popout--placeholder))
    (or (if (functionp hint) (funcall hint) hint) "Message…")))

;;;; Drawing

(defun harness-ui-popout--add-keymap (start end map)
  "Give START..END the keymap MAP, under the keymaps the text has already."
  (let ((pos start))
    (while (< pos end)
      (let* ((next (min end (or (next-single-property-change pos 'keymap nil end) end)))
             (existing (get-text-property pos 'keymap)))
        (put-text-property pos next 'keymap (if existing (make-composed-keymap (list existing map)) map))
        (setq pos next)))))

(defun harness-ui-popout--insert-content ()
  "Insert the content at point: what the render function draws, keys added."
  (let ((start (point)))
    (condition-case err
        (when harness-ui-popout--render (funcall harness-ui-popout--render))
      (error (insert (propertize (format "Could not draw this: %s\n" (harness-error-message err))
                                 'face 'harness-tool-error-face))))
    (unless (bolp) (insert "\n"))
    (harness-ui-popout--add-keymap start (point) harness-ui-popout-content-map)
    (put-text-property start (point) 'read-only t)
    ;; Typing just after the content goes to the box, not into the content.
    (put-text-property (max start (1- (point))) (point) 'rear-nonsticky t)))

(defun harness-ui-popout--insert-tail ()
  "Insert the attachments and the box at point when there is a box."
  (when harness-ui-popout--submit
    (let ((start (point)))
      (harness-compose-insert-attachments)
      (put-text-property start (point) 'read-only t))
    (harness-compose-insert nil "C-c C-c sends, RET newline, C-c C-a attaches")))

(defun harness-ui-popout--forget-box ()
  "Drop the box's overlays and markers: this draw has no box."
  (dolist (ov (list harness-compose-overlay harness-compose--placeholder harness-compose--indent))
    (when ov (delete-overlay ov)))
  (setq harness-compose-overlay nil harness-compose--placeholder nil harness-compose--indent nil
        harness-compose-start nil harness-compose-end nil))

(defun harness-ui-popout--place ()
  "Return where point is, as a redraw keeps it: (box . OFFSET) or (LINE . COLUMN)."
  (if (harness-compose-in-p)
      (cons 'box (- (point) harness-compose-start))
    (cons (line-number-at-pos) (current-column))))

(defun harness-ui-popout--goto (place)
  "Put point back at PLACE, from `harness-ui-popout--place'."
  (pcase place
    (`(box . ,offset)
     (if (harness-compose-live-p)
         (goto-char (min (+ harness-compose-start offset) harness-compose-end))
       (goto-char (point-min))))
    (`(,line . ,column)
     (goto-char (point-min))
     (forward-line (1- line))
     ;; A line past the content goes to the content's last line.
     (when (and harness-ui-popout--content-end (>= (point) harness-ui-popout--content-end))
       (goto-char (max (point-min) (1- harness-ui-popout--content-end)))
       (forward-line 0))
     (move-to-column column))))

(defun harness-ui-popout--render ()
  "Draw this popout again: the content, then the box when there is one.
Point stays on the same line, or at the same place in the box, whose
text is kept; every window showing the popout is fitted again.  An
image the draw before waited on goes with the text this erases: the
loading lines go, and the new draw puts one where each image goes."
  (when (derived-mode-p 'harness-ui-popout-mode)
    (harness-ui-image-load-cancel)
    (harness-compose-capture)
    (let ((place (harness-ui-popout--place))
          (starts (mapcar (lambda (w) (cons w (with-current-buffer (window-buffer w)
                                                (line-number-at-pos (window-start w)))))
                          (get-buffer-window-list nil nil t)))
          (inhibit-read-only t)
          (buffer-undo-list t))
      (setq harness-ui-popout--submit
            (and harness-ui-popout--compose
                 (with-demoted-errors "harness-ui-popout compose: %S" (funcall harness-ui-popout--compose))))
      (harness-ui-popout--forget-box)
      (erase-buffer)
      (harness-ui-popout--insert-content)
      (setq harness-ui-popout--content-end (copy-marker (point)))
      (harness-ui-popout--insert-tail)
      (harness-ui-popout--goto place)
      (set-buffer-modified-p nil)
      (pcase-dolist (`(,w . ,line) starts)
        (when (window-live-p w)
          (set-window-start w (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point)) t)
          (harness-ui-popout--fit w)))
      (force-mode-line-update))))

(defun harness-ui-popout--redraw-tail ()
  "Draw the attachments and the box again, leaving the content alone.
The box calls this when its attachments change."
  (when (and (derived-mode-p 'harness-ui-popout-mode) harness-ui-popout--content-end)
    (harness-compose-capture)
    (let ((offset (and (harness-compose-in-p) (- (point) harness-compose-start)))
          (inhibit-read-only t)
          (buffer-undo-list t))
      (harness-ui-popout--forget-box)
      (delete-region harness-ui-popout--content-end (point-max))
      (save-excursion
        (goto-char harness-ui-popout--content-end)
        (harness-ui-popout--insert-tail))
      (when (and offset (harness-compose-live-p))
        (goto-char (min (+ harness-compose-start offset) harness-compose-end)))
      (set-buffer-modified-p nil)
      (dolist (w (get-buffer-window-list nil nil t)) (harness-ui-popout--fit w)))))

(defun harness-ui-popout--max-lines (frame)
  "Return how many lines this popout's window takes at most in FRAME.
That is its :max-height of the frame, or `harness-ui-popout-max-height'."
  (let ((fraction (if (functionp harness-ui-popout--max-height)
                      (funcall harness-ui-popout--max-height)
                    harness-ui-popout--max-height)))
    (max harness-ui-popout-min-height
         (floor (* (or fraction harness-ui-popout-max-height) (frame-height frame))))))

(defun harness-ui-popout--fit (window)
  "Fit WINDOW, showing a popout, to its content within the height limits."
  (when (and (window-live-p window) (window-parameter window 'window-side))
    (let ((max (with-current-buffer (window-buffer window)
                 (harness-ui-popout--max-lines (window-frame window)))))
      (ignore-errors (fit-window-to-buffer window max harness-ui-popout-min-height)))))

(defun harness-ui-popout--refit ()
  "Fit every window showing this popout to its content.
For `harness-ui-image-load-reflow': an image drawn after the popout
opened takes more room than the line that said it was loading."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (harness-ui-popout--fit window)))

(defun harness-ui-popout--frame ()
  "Return the frame this popout shows in, or will show in: the selected one."
  (if-let* ((window (car (get-buffer-window-list nil nil t))))
      (window-frame window)
    (selected-frame)))

(defun harness-ui-popout-pixel-width (&optional window)
  "Return how many pixels wide this popout's content may be.
That is its window's body width while it shows; before it shows, as
when its content is drawn the first time, the width of a window across
the bottom of the selected frame, where it will show.  With WINDOW, a
live window, its body width: for content drawn to be shown there."
  (if-let* ((windows (if (window-live-p window) (list window) (get-buffer-window-list nil nil t))))
      (apply #'max (mapcar (lambda (w) (window-body-width w t)) windows))
    (max 1 (- (frame-inner-width) (frame-fringe-width) (frame-scroll-bar-width)))))

(defun harness-ui-popout-pixel-height (&optional lines)
  "Return how many pixels high this popout's content may be, less LINES lines.
That is the height its window grows to at most (its :max-height, or
`harness-ui-popout-max-height') less its header and mode lines, and
less LINES lines of text: an image that high shows whole, with LINES
lines of text beside it."
  (let ((frame (harness-ui-popout--frame)))
    (* (frame-char-height frame)
       (max 1 (- (harness-ui-popout--max-lines frame) 2 (or lines 0))))))

;;;; Showing and closing

(defun harness-ui-popout-buffer (key)
  "Return the live popout buffer of KEY, or nil."
  (let ((buffer (gethash key harness-ui-popout--buffers)))
    (if (buffer-live-p buffer)
        buffer
      (remhash key harness-ui-popout--buffers)
      nil)))

(defun harness-ui-popout--parent-buffer (buffer)
  "Return the live popout buffer the popout BUFFER was opened from, or nil."
  (when-let* ((parent (buffer-local-value 'harness-ui-popout--parent buffer)))
    (harness-ui-popout-buffer parent)))

(defun harness-ui-popout--buffer-name (title)
  "Return the name of a new popout buffer titled TITLE."
  (generate-new-buffer-name (format "*harness popout: %s*" (harness-first-line (or title "") 60))))

(defun harness-ui-popout--display (buffer &optional select)
  "Show the popout BUFFER in its side window, fitted to it; return the window.
The side window of popouts is reused: the popout showing there gives
way.  With SELECT the window is selected, point where the buffer has it."
  (let ((window (or (get-buffer-window buffer)
                    (display-buffer-in-side-window buffer harness-ui-popout-window-parameters))))
    (when (window-live-p window)
      (harness-ui-popout--fit window)
      (when select
        (select-window window)
        (with-current-buffer buffer (set-window-point window (point)))))
    window))

(defun harness-ui-popout-show (key title render &rest props)
  "Show the popout of KEY, drawn by RENDER, and select its window.
Return its buffer.  KEY is any value naming the item, compared with
`equal': (pending SESSION-ID), (report TASK-ID).  An item has one
popout: showing its KEY again reuses the buffer, without running its
mode again, so what the owner keeps buffer-locally there survives; it
takes the new TITLE, RENDER and PROPS and draws again.

TITLE is a string, or a function of no arguments returning one, for the
header line.  RENDER is a function of no arguments, called with the
popout buffer current and point at the start of the emptied, writable
content; it inserts the item.  It is called again on every redraw
\(`harness-ui-popout-refresh', g).  Text-property keymaps it puts in
win over the popout's own keys.

PROPS:\\<harness-ui-popout-mode-map>
  :compose FN       FN, of no arguments, is called on every draw.
                    It returns SUBMIT, a function of TEXT and
                    ATTACHMENTS, to show the shared compose box under
                    the content, or nil for no box.
                    \\[harness-ui-popout-submit] empties the box and calls
                    SUBMIT with what it held, the popout buffer current.
  :placeholder HINT the empty box's hint, a string or a function.
  :dir DIR          the project directory of the box (@ completion).
  :max-height FRACTION
                    the height its window grows to at most, as a
                    fraction of its frame's, instead of
                    `harness-ui-popout-max-height': an item with large
                    images takes more.  RENDER sizes them with
                    `harness-ui-popout-pixel-width' and
                    `harness-ui-popout-pixel-height'.  A function of no
                    arguments returning FRACTION, or nil, is asked on
                    every draw: for an item that comes to show images
                    after it opened.
  :parent KEY       the popout this one is opened from, such as the
                    report an image is shown larger from.  It shows in
                    that one's window, its header says [back], and
                    closing it shows that one there again.  Closing the
                    parent while this one is hidden closes this one too.
  :on-close FN      called with no arguments, the popout buffer current,
                    once the popout closes."
  (let* ((existing (harness-ui-popout-buffer key))
         (buffer (or existing
                     (get-buffer-create (harness-ui-popout--buffer-name
                                         (if (functionp title) "" title)))))
         (parent (plist-get props :parent)))
    (with-current-buffer buffer
      (unless existing
        (harness-ui-popout-mode)
        (setq harness-ui-popout-key key)
        (puthash key buffer harness-ui-popout--buffers)
        (when-let* ((draft (gethash key harness-ui-popout--drafts)))
          (remhash key harness-ui-popout--drafts)
          (setq harness-compose--text (car draft)
                harness-compose-attachments (cdr draft))))
      (setq harness-ui-popout--title title
            harness-ui-popout--render render
            harness-ui-popout--compose (plist-get props :compose)
            harness-ui-popout--placeholder (plist-get props :placeholder)
            harness-ui-popout--dir (plist-get props :dir)
            harness-ui-popout--max-height (plist-get props :max-height)
            harness-ui-popout--parent (and (not (equal parent key)) parent)
            harness-ui-popout--on-close (plist-get props :on-close)
            ;; An image drawn after the popout opened grows it.
            harness-ui-image-load-reflow #'harness-ui-popout--refit)
      (when harness-ui-popout--dir
        (setq default-directory (file-name-as-directory harness-ui-popout--dir)))
      (harness-ui-popout--render)
      (unless existing (goto-char (point-min))))
    (harness-ui-popout--display buffer t)
    buffer))

(defun harness-ui-popout-refresh (key)
  "Draw the popout of KEY again, if it is open; return non-nil when it was.
Point stays where it was and the window is fitted again."
  (when-let* ((buffer (harness-ui-popout-buffer key)))
    (with-current-buffer buffer (harness-ui-popout--render))
    t))

(defun harness-ui-popout--save-draft ()
  "Keep what the box holds for the next time this popout's KEY shows."
  (when (and (harness-compose-live-p) (not harness-ui-popout--discard))
    (let ((text (harness-compose-text)))
      (when (or (not (string-blank-p text)) harness-compose-attachments)
        (puthash harness-ui-popout-key (cons text harness-compose-attachments) harness-ui-popout--drafts)))))

(defun harness-ui-popout--on-kill ()
  "Forget this popout, and tell its owner it closed.
The popouts opened from it that no window shows close with it."
  (harness-ui-popout--save-draft)
  (when (eq (gethash harness-ui-popout-key harness-ui-popout--buffers) (current-buffer))
    (remhash harness-ui-popout-key harness-ui-popout--buffers))
  (let ((key harness-ui-popout-key))
    (maphash (lambda (child buffer)
               (when (and (buffer-live-p buffer)
                          (equal key (buffer-local-value 'harness-ui-popout--parent buffer))
                          (not (get-buffer-window buffer t)))
                 (harness-ui-popout-close child)))
             (copy-hash-table harness-ui-popout--buffers)))
  (when harness-ui-popout--on-close
    (with-demoted-errors "harness-ui-popout on-close: %S"
      (funcall harness-ui-popout--on-close))))

(defun harness-ui-popout-close (key &optional discard)
  "Close the popout of KEY, if it is open: its window goes and its buffer.
Return non-nil when it was open.  A popout opened from another one (its
:parent) gives its window back instead: the parent shows there again,
where it was, selected when this one was.  What its box holds is kept
for the next time KEY shows, unless DISCARD: an owner closing a popout
whose item is settled (a question answered) drops it."
  (when discard (remhash key harness-ui-popout--drafts))
  (when-let* ((buffer (harness-ui-popout-buffer key)))
    (let* ((parent (harness-ui-popout--parent-buffer buffer))
           (windows (get-buffer-window-list buffer nil t))
           (selected (memq (selected-window) windows)))
      (with-current-buffer buffer (setq harness-ui-popout--discard discard))
      ;; The parent takes the side window back; the windows still showing
      ;; this popout after that go.
      (when (and parent windows (not (get-buffer-window parent t)))
        (harness-ui-popout--display parent selected))
      (dolist (window (get-buffer-window-list buffer nil t))
        (if (window-parameter window 'window-side)
            (ignore-errors (delete-window window))
          (quit-restore-window window)))
      (kill-buffer buffer)
      t)))

(defun harness-ui-popout--refresh-all ()
  "Draw every open popout again, after a reload or reconnect."
  (maphash (lambda (key _) (harness-ui-popout-refresh key))
           (copy-hash-table harness-ui-popout--buffers)))

;;;; Commands

(defun harness-ui-popout-quit ()
  "Close this popout.
With a region, completion or minibuffer to quit, quit that instead, as
`keyboard-quit' would."
  (interactive)
  (if (or (region-active-p) (bound-and-true-p completion-in-region-mode) (active-minibuffer-window))
      (let ((command (or (command-remapping 'keyboard-quit nil (current-global-map)) #'keyboard-quit)))
        (setq this-command command)
        (call-interactively command))
    (unless harness-ui-popout-key (user-error "Not in a popout"))
    (harness-ui-popout-close harness-ui-popout-key)))

(defun harness-ui-popout-redraw ()
  "Draw this popout again."
  (interactive)
  (unless (derived-mode-p 'harness-ui-popout-mode) (user-error "Not in a popout"))
  (harness-ui-popout--render))

(defun harness-ui-popout-submit ()
  "Send what this popout's box holds to the popout's owner."
  (interactive)
  (let ((submit harness-ui-popout--submit))
    (unless (and submit (harness-compose-live-p)) (user-error "This popout takes no message"))
    (pcase-let ((`(,text . ,atts) (harness-compose-take)))
      (harness-compose-clear)
      (funcall submit text atts))))

;;;; An image, larger

(defun harness-ui-popout-open-file (file)
  "Open FILE with the desktop's opener, or visit it when there is none.
The opener is ui-media's (`harness-ui-media-open'): xdg-open, mpv or open."
  (if (and (fboundp 'harness-ui-media-open)
           (cl-find-if #'executable-find '("xdg-open" "mpv" "open")))
      (harness-ui-media-open file)
    (find-file-other-window file)))

(defun harness-ui-popout-image (file &rest props)
  "Show the image FILE in a popout of its own, as large as it fits.
Return the popout's buffer.  The image fills the frame's width or up to
`harness-ui-popout-image-max-height' of its height: a larger one is
scaled down, a smaller one up, by `harness-ui-popout-image-max-scale'
at most.  Emacs's image keys work on it: i + and i - (or C-wheel) zoom
it and i r turns it; g fits it again.  Under it, its name, its size and
how large it shows, and [Open externally] for the desktop's viewer.
Dragging the image drops FILE into another application
\(`harness-ui-drag-region').

PROPS:
  :title TITLE  the header's title, by default the file's name.
  :parent KEY   the popout it is shown from, such as a task's report:
                it takes that one's window, and closing it (q, [back])
                shows that one again (`harness-ui-popout-show')."
  (let ((file (expand-file-name file)))
    (harness-ui-popout-show (list 'image file)
                            (or (plist-get props :title) (file-name-nondirectory file))
                            (lambda () (harness-ui-popout--insert-image file))
                            :parent (plist-get props :parent)
                            :max-height harness-ui-popout-image-max-height)))

(defun harness-ui-popout--image-size (file)
  "Return (WIDTH . HEIGHT) of the image FILE, in its own pixels, or nil."
  (when-let* ((probe (ignore-errors (create-image file nil nil :scale 1))))
    (prog1 (ignore-errors (image-size probe t))
      ;; Only measured: it shows scaled, which is another image.
      (ignore-errors (image-flush probe t)))))

(defun harness-ui-popout--insert-image (file)
  "Insert the image FILE as large as this popout shows it, and a line on it.
Drawing it takes a moment, which a full-size screenshot does, so a line
where it goes says it is loading and the image comes as soon as the
popout has shown (`harness-ui-image-load'); `harness-ui-popout--draw-image'
is what draws it.  A file that cannot be read, or that Emacs cannot
draw, reads as it does there: a line saying so."
  (let* ((frame (harness-ui-popout--frame))
         (readable (and (not (file-remote-p file)) (file-readable-p file))))
    (if (and readable (display-images-p frame)
             (not (harness-ui-image-too-large file frame)))
        (harness-ui-image-load
         (propertize (format "[image %s] loading…\n" (abbreviate-file-name file))
                     'face 'harness-dim-face)
         (lambda () (harness-ui-popout--draw-image file)))
      (harness-ui-popout--draw-image file))))

(defun harness-ui-popout--draw-image (file)
  "Insert the image FILE as large as this popout shows it, and a line on it.
A remote file is never read, which would block: it can be opened."
  (let* ((local (not (file-remote-p file)))
         (frame (harness-ui-popout--frame))
         (readable (and local (file-readable-p file)))
         (graphic (display-images-p frame))
         ;; Measured from its header: loading it to measure it would fail.
         (too-large (and readable graphic (harness-ui-image-too-large file frame)))
         (natural (and readable graphic (not too-large) (harness-ui-popout--image-size file)))
         (image (and natural
                     (ignore-errors
                       ;; Scaled up by the most it may be, then down to
                       ;; the box, the max sizes being hard limits: it
                       ;; fills the box either way.  A column to spare:
                       ;; an image as wide as the window would wrap.
                       (apply #'create-image file nil nil
                              :scale (* harness-ui-popout-image-max-scale
                                        (image-compute-scaling-factor image-scaling-factor))
                              :max-width (max 1 (- (harness-ui-popout-pixel-width) (frame-char-width)))
                              :max-height (harness-ui-popout-pixel-height 2)
                              (harness-ui-image-color-props)))))
         (shown (and image (ignore-errors (image-size image t))))
         (bytes (and readable (harness-file-size file))))
    (cond
     (image
      ;; `insert-image' gives it Emacs's image keys (`image-map'), and
      ;; it drags into another application as the file it shows.
      (let ((start (point)))
        (insert-image image (format "[image %s]" (abbreviate-file-name file)))
        (harness-ui-drag-region start (point) file))
      (insert "\n"))
     ((not local)
      (insert (propertize "A remote image is not read here: open it to see it.\n" 'face 'harness-dim-face)))
     ((not readable)
      (insert (propertize (format "%s cannot be read.\n" (abbreviate-file-name file))
                          'face 'harness-tool-error-face)))
     (too-large
      (insert (propertize "This image is too large for Emacs to draw (`max-image-size'): open it to see it.\n"
                          'face 'harness-dim-face)))
     (t (insert (propertize (if graphic "This image cannot be shown here: open it to see it.\n"
                              "Images do not show here: open it to see it.\n")
                            'face 'harness-dim-face))))
    (setq natural (or natural too-large))
    (insert " " (propertize (file-name-nondirectory file) 'face 'bold)
            (propertize (concat (if natural (format "  %d×%d" (car natural) (cdr natural)) "")
                                (if (and natural shown (/= (car shown) (car natural)))
                                    (format ", shown at %d%%" (round (* 100.0 (car shown)) (car natural)))
                                  "")
                                (if bytes (concat "  ·  " (harness-format-bytes bytes)) ""))
                        'face 'harness-dim-face)
            "   ")
    (harness-ui-button "[Open externally]" (lambda () (harness-ui-popout-open-file file))
                       :help "Open it in the desktop's image viewer")
    (insert "\n")
    (when image
      (insert (propertize (concat " i + and i - zoom (or C-wheel), g fits it again"
                                  (if (harness-ui-drag-available-p) ", drag it into another application" ""))
                          'face 'harness-hint-face)
              "\n"))))

;;;; The item at point

(defvar harness-ui-popout-at-point-functions nil
  "Functions popping out the item at point of a harness view.
Each is called with no arguments in the view's buffer, point where it
is, and returns non-nil once it popped something out; the first that
does wins.  Add to it globally, checking the buffer, or buffer-locally.
The task board pops out the report a task handed in this way, and the
board and the session list what a session waits on.")

(defun harness-ui-popout-try-at-point ()
  "Pop out the item at point; return non-nil when something popped out."
  (run-hook-with-args-until-success 'harness-ui-popout-at-point-functions))

(defun harness-ui-popout-at-point ()
  "Pop out the item at point: what its session waits on, its report.
The functions on `harness-ui-popout-at-point-functions' know the items."
  (interactive)
  (unless (harness-ui-popout-try-at-point)
    (user-error "Nothing to pop out here")))

;;;; Module

(defun harness-ui-popout--init ()
  "Draw the open popouts again after a reload or reconnect."
  (add-hook 'harness-ui-redraw-hook #'harness-ui-popout--refresh-all))

(harness-define-module 'ui-popout
  :doc "Popouts: one item of a session or task in a small window of its own."
  :requires '(ui ui-compose)
  :init #'harness-ui-popout--init)

(provide 'harness-ui-popout)
;;; harness-ui-popout.el ends here
