;;; harness-ui-compose.el --- The compose box shared by harness buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; The editable box at the bottom of a chat buffer and of the task
;; board.  A host buffer calls `harness-compose-setup' once from its
;; major mode, then `harness-compose-insert' wherever it draws the box
;; (after making everything before it read-only).  The box gives:
;;
;;   - multi-line editing: RET and C-j insert a newline, typing outside
;;     the box jumps into it, a placeholder shows while it is empty;
;;   - a prompt that is a field of its own: C-a stops after it, as in
;;     the minibuffer, so C-a C-k clears the box's first line;
;;   - @file completion over the project's files, or over the file
;;     system for a path (/, ~/, ./, ../); each completed file becomes
;;     an attachment, and so does the file an @ reference typed out in
;;     full names, once the message is sent; /skill completion at its
;;     start; a popup that shows as you type (corfu, company) shows for
;;     them even while the host redraws around the box;
;;   - attachments: C-c C-a finds a file the same way, by part of a
;;     project file's name or by path (C-u C-c C-a: browse the file
;;     system), C-y pastes what the clipboard holds (an
;;     image or copied files go on the media ring; M-x
;;     harness-compose-attach-clipboard for other MIME types), files
;;     dropped on the window attach;
;;   - the text and attachments, kept across redraws of the host;
;;   - long lines that wrap under the text, never scrolling sideways;
;;   - optionally, the box at the bottom of the window: a buffer shorter
;;     than its window is padded at the top so it ends on the last line;
;;   - optionally, colours of its own: a host passes `:face' for the
;;     background and `:accent' for the prompt and a bar down the left
;;     edge, to mark a box that does something else than compose -- the
;;     task board's, which sends a message to a session.  It carries the
;;     bar onto its own lines around the box with `harness-compose-bar'.
;;
;; Hosts read the box with `harness-compose-text' and
;; `harness-compose-take', expand /skill references with
;; `harness-compose-with-expanded-text' and turn attachments into ACP
;; prompt blocks with `harness-compose-attachment-block'.
;;   - attachments: C-c C-a finds a project file by part of its name
;;   - links dropped from a web page download in the background, curl
;;   - yanking media: with `harness-compose-yank-media', C-y attaches

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'mailcap)
(require 'dnd)
(require 'harness-core)
(require 'harness-util)
(require 'image)
(require 'harness-http)
(require 'harness-ui-media-ring)
(require 'harness-ui)

;;;; State

(defvar-local harness-compose-start nil "Marker: first character of the compose box.")
(defvar-local harness-compose-end nil "Marker: after the last character of the compose box.")
(defvar-local harness-compose-overlay nil "Overlay over the prompt and the box.")
(defvar-local harness-compose-attachments nil "Attachments for the next message.")
(defvar-local harness-compose--placeholder nil "Overlay showing the placeholder.")
(defvar-local harness-compose--indent nil "Overlay lining the box's lines up after the prompt.")
(defvar-local harness-compose--text "" "The box's text, kept across redraws.")
(defvar-local harness-compose--files nil "Project files for @ completion.")
(defvar-local harness-compose--skills nil "Skill names for / completion.")
(defvar-local harness-compose--pads nil "Window -> overlay padding the buffer so the box sits at the bottom.")
(defvar-local harness-compose--pad-at nil "Function returning where the padding goes, or nil for the top.")
(defvar-local harness-compose--files-at nil "Start of the @ token whose completion last refreshed the files.")
(defvar-local harness-compose--last-token nil "The @file or /skill token at point after the last command.")
(defvar-local harness-compose--popup-timer nil "Timer asking the completion UI to show the token's completions.")
(defvar-local harness-compose--face 'harness-compose-face
  "Face the box's background is drawn in, set by `harness-compose-insert'.")
(defvar-local harness-compose--accent nil
  "Face of the box's prompt and bar, or nil for an ordinary box.
A host sets it through `harness-compose-insert' to mark a box that does
something else than compose: sending a message to an existing session,
say.")

(defvar-local harness-compose-project-function (lambda () default-directory)
  "Function returning the project root files are completed and attached from.")
(defvar-local harness-compose-placeholder-function (lambda () "Message…")
  "Function returning the hint shown while the box is empty.")
(defvar-local harness-compose-redraw-function #'ignore
  "Function the host redraws the box with, after the attachments change.")

(defun harness-compose--project ()
  (funcall harness-compose-project-function))

;;;; Setup and drawing

(defvar harness-compose-map (make-sparse-keymap)
  "Keys of the compose box.  Host major modes use it as their keymap's parent.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-compose-map))
  (define-key map (kbd "RET") #'harness-compose-newline)
  (define-key map (kbd "S-<return>") #'harness-compose-newline)
  (define-key map (kbd "C-j") #'harness-compose-newline)
  (define-key map (kbd "C-c C-a") #'harness-compose-add-attachment)
  ;; C-c C-v, the clipboard's key once, is the review banner's [Verify]
  ;; in a chat; unbound here so a reload frees it there too.  Other
  ;; MIME types are chosen from with M-x harness-compose-attach-clipboard.
  (define-key map (kbd "C-c C-v") nil t)
  ;; Bound here, not remapped: a minor mode's remap (Doom's
  ;; `consult-yank-pop' for M-y, say) outranks a major mode's.  The
  ;; filter makes the key fall through to its usual command when yanking
  ;; media is off, remapping included.
  (define-key map (kbd "C-y") '(menu-item "" harness-compose-yank :filter harness-compose--yank-binding))
  (define-key map (kbd "M-y") '(menu-item "" harness-compose-yank-pop :filter harness-compose--yank-binding)))

(cl-defun harness-compose-setup (&key project placeholder redraw bottom)
  "Make this buffer host a compose box.
PROJECT returns the project root, PLACEHOLDER the hint for the empty
box, REDRAW redraws the box (it must call `harness-compose-insert').
With BOTTOM the box sits at the bottom of every window showing the
buffer, the way a chat app keeps its input there: t pads the top of a
short buffer, a function returning a position pads there instead (a
board above the box stays at the top, the gap opens below it).

The box wraps long lines and never scrolls sideways.  Emacs wraps whole
buffers, not regions, so the host's own lines wrap too: it fits to the
window the ones that must stay on one line."
  (when bottom
    (setq harness-compose--pad-at (and (functionp bottom) bottom))
    (add-hook 'pre-redisplay-functions #'harness-compose-pad-window nil t))
  (when project (setq harness-compose-project-function project))
  (when placeholder (setq harness-compose-placeholder-function placeholder))
  (when redraw (setq harness-compose-redraw-function redraw))
  ;; The last one keeps windows narrower than the frame (side windows)
  ;; from truncating anyway.
  (setq-local truncate-lines nil
              word-wrap t
              truncate-partial-width-windows nil)
  (add-hook 'pre-redisplay-functions #'harness-compose-unscroll nil t)
  (setq-local hl-line-range-function #'harness-compose-hl-line-range)
  (harness-compose--setup-drops)
  (when (fboundp 'yank-media-handler)
    (yank-media-handler "image/.*" #'harness-compose--yank-media-image))
  (add-hook 'kill-buffer-hook #'harness-compose--drop-pending nil t)
  (add-hook 'completion-at-point-functions #'harness-compose-completion-at-point nil t)
  (add-hook 'pre-command-hook #'harness-compose--pre-command nil t)
  (add-hook 'post-command-hook #'harness-compose-update-placeholder nil t)
  (add-hook 'post-command-hook #'harness-compose--after-command nil t))

(defun harness-compose-live-p ()
  "Non-nil when the compose markers point into this buffer."
  (and harness-compose-start harness-compose-end
       (eq (marker-buffer harness-compose-start) (current-buffer))
       (<= harness-compose-start harness-compose-end)))

(defun harness-compose-capture ()
  "Remember the box's text, before the host deletes it to redraw."
  (when (harness-compose-live-p)
    (setq harness-compose--text
          (buffer-substring-no-properties harness-compose-start harness-compose-end))))

(defun harness-compose-text ()
  "Return the text in the box."
  (harness-compose-capture)
  harness-compose--text)

(defun harness-compose-in-p (&optional pos)
  "Non-nil when POS (default point) is inside the box."
  (let ((p (or pos (point))))
    (and (harness-compose-live-p) (>= p harness-compose-start) (<= p harness-compose-end))))

(defun harness-compose-insert-attachments ()
  "Insert the attachment chips at point (nothing without attachments).
An image shows its thumbnail, and so does a video once one is made; a
link still downloading shows its progress, which an overlay redraws, so
the text is left alone while it ticks."
  (dolist (p harness-compose--progress) (delete-overlay (cdr p)))
  (setq harness-compose--progress nil)
  (when harness-compose-attachments
    (insert " " (propertize (harness-ui-icon 'harness-icon-attach) 'face 'harness-dim-face) " ")
    (dolist (att harness-compose-attachments)
      (if (plist-get att :pending)
          (harness-compose--insert-pending-chip att)
        (insert (harness-compose--chip att)))
      (insert "  "))
    (insert "\n")
    (harness-compose--start-progress)))

(defun harness-compose-bar (&optional accent face)
  "Return the bar of a compose box in ACCENT on background FACE, and a space.
ACCENT and FACE default to the ones the box was last drawn with
\(`harness-compose--accent', `harness-compose--face'), so a host can carry
the bar onto the lines it draws around the box, such as the label saying
what the box does.  Two columns wide, the bar and a space; empty when
the box has no accent, since an ordinary box has no bar."
  (let ((accent (or accent harness-compose--accent))
        (face (or face harness-compose--face)))
    (if (null accent)
        ""
      (propertize "▌ " 'face (delq nil (list accent face))))))

(cl-defun harness-compose-insert (&optional text help &key face accent)
  "Insert the prompt and the box at point, holding TEXT or the kept text.
HELP is the prompt's tooltip.  FACE is the background to draw the box
in, `harness-compose-face' by default.  ACCENT, when given, is the face
of the box's prompt and the bar down its left edge, which marks a box
that does something else than compose -- sending a message to a session,
say.  Point ends after the box's final newline."
  (dolist (ov (list harness-compose-overlay harness-compose--placeholder harness-compose--indent))
    (when ov (delete-overlay ov)))
  (when text (setq harness-compose--text text))
  (let* ((background (or face 'harness-compose-face))
         (accent (and accent (list accent background)))
         (prompt (if accent (concat (harness-compose-bar (car accent) background) "❯ ") "❯ "))
         (label-start (point)))
    (setq harness-compose--face background
          harness-compose--accent (car accent))
    ;; The prompt is a field of its own, like the minibuffer's: C-a, and
    ;; whatever finds the line's start with `line-beginning-position',
    ;; stops after it, so C-a C-k clears the line rather than running
    ;; into the read-only prompt.  Rear-nonsticky, so text typed after
    ;; the prompt takes neither its field nor its read-only.
    (insert (propertize prompt 'face (or accent (list 'harness-dim-face background))
                        'help-echo help
                        'read-only t 'rear-nonsticky t 'field 'harness-compose-prompt))
    (setq harness-compose-start (copy-marker (point)))
    (insert harness-compose--text)
    (let ((end (point)))
      (insert (propertize "\n" 'read-only t))
      (setq harness-compose-end (copy-marker end t)))
    ;; FRONT-ADVANCE: text the host inserts just before the box stays outside.
    (setq harness-compose-overlay (make-overlay label-start (point) nil t t))
    (overlay-put harness-compose-overlay 'face background)
    ;; Wrapped lines, and lines after a newline, start under the text
    ;; rather than under the prompt.  The overlay starts after the prompt,
    ;; so the prompt's line gets no prefix, and ends after the final
    ;; newline, so an empty last line already has one.  A prefix is drawn
    ;; in the default face unless it brings its own.
    (let* ((width (string-width (buffer-substring label-start harness-compose-start)))
           (indent (if (car accent)
                       (concat (harness-compose-bar (car accent) background)
                               (propertize (make-string (- width 2) ?\s) 'face background))
                     (propertize (make-string width ?\s) 'face background))))
      (setq harness-compose--indent (make-overlay harness-compose-start (point)))
      (overlay-put harness-compose--indent 'line-prefix indent)
      (overlay-put harness-compose--indent 'wrap-prefix indent))
    (setq harness-compose--placeholder (make-overlay (1- (point)) (point)))
    (harness-compose-update-placeholder)))

(defun harness-compose-update-placeholder ()
  "Show the placeholder while the box is empty."
  (when (and harness-compose--placeholder (overlay-buffer harness-compose--placeholder)
             (harness-compose-live-p))
    (overlay-put harness-compose--placeholder 'before-string
                 (and (= harness-compose-start harness-compose-end)
                      ;; Overlay strings miss the compose overlay's face.
                      (propertize (funcall harness-compose-placeholder-function)
                                  'face (list 'harness-dim-face harness-compose--face)
                                  'cursor t)))))

(defun harness-compose-hl-line-range ()
  "Return the `hl-line-mode' range, empty inside the box.
The line highlight would cover the compose background, and outranking it
would hide the region too.  Never nil: `global-hl-line-mode' needs a range."
  (if (and harness-compose-overlay (overlay-buffer harness-compose-overlay)
           (>= (point) (overlay-start harness-compose-overlay)))
      (cons (point) (point))
    (cons (line-beginning-position) (line-beginning-position 2))))

(defun harness-compose--pre-command ()
  "Send typing that lands outside the box into it."
  (when (and (memq this-command '(self-insert-command yank harness-compose-yank))
             (harness-compose-live-p)
             (not (harness-compose-in-p)))
    (goto-char harness-compose-end)))

(defun harness-compose-pad-window (window)
  "Keep the box at the bottom of WINDOW.
A buffer shorter than WINDOW is padded so it ends at its bottom, each
window with its own overlay; a taller one scrolls to keep the box there
while the window's point is in it (`harness-compose--follow').  Runs
from `pre-redisplay-functions'."
  (when (and (window-live-p window) (eq (window-buffer window) (current-buffer))
             (harness-compose-live-p))
    ;; A dropped overlay is deleted too: kept, it would pad its window
    ;; again, twice over, once the window shows the buffer again.
    (setq harness-compose--pads
          (cl-remove-if-not (lambda (p) (or (and (window-live-p (car p)) (overlay-buffer (cdr p))
                                                 (eq (window-buffer (car p)) (current-buffer)))
                                            (progn (delete-overlay (cdr p)) nil)))
                            harness-compose--pads))
    (harness-compose--follow window)
    (let* ((ov (or (alist-get window harness-compose--pads)
                   (let ((o (make-overlay (point-min) (point-min) nil t)))
                     (overlay-put o 'window window)
                     (push (cons window o) harness-compose--pads)
                     o)))
           (at (if harness-compose--pad-at (funcall harness-compose--pad-at) (point-min)))
           (body (window-body-height window t))
           (key (list (buffer-modified-tick) body (window-body-width window t) (window-start window) at)))
      (unless (equal key (overlay-get ov 'harness-compose-key))
        (overlay-put ov 'harness-compose-key key)
        (move-overlay ov at at)
        (overlay-put ov 'before-string nil)
        ;; Padding at the top leaves a line for the empty one after the
        ;; box, where a host following the end (chat) puts the bottom of
        ;; the window; padding inside the buffer puts the box on the last line.
        (let* ((line (frame-char-height (window-frame window)))
               ;; More than BODY for a buffer taller than the window: no padding.
               (used (harness-ui-text-height window (point-min) harness-compose-end body))
               (lines (/ (- body used (if harness-compose--pad-at 0 line)) line)))
          (when (and (= (window-start window) (point-min)) (> lines 0))
            ;; An explicit face: bare newlines would take the height of the
            ;; text they precede (a smaller label face) and fall short.
            (overlay-put ov 'before-string (propertize (make-string lines ?\n) 'face 'default))))))))

(defun harness-compose-repad (window)
  "Drop WINDOW's padding so the next redisplay sizes it again.
A host about to scroll WINDOW calls this first: `recenter' would count
the padding as lines to keep in view."
  (when-let* ((pad (alist-get window harness-compose--pads)))
    (overlay-put pad 'before-string nil)
    (overlay-put pad 'harness-compose-key nil)))

(defun harness-compose-unscroll (window)
  "Scroll WINDOW back to its left edge.
The box wraps rather than scrolling sideways, yet \\[scroll-left] or a
shifted mouse wheel would still scroll the window, and a window scrolled
sideways truncates every line, the box's too.  Runs from
`pre-redisplay-functions'.  A buffer whose lines were made to truncate
again by hand is left to `auto-hscroll-mode'."
  (when (and (window-live-p window) (eq (window-buffer window) (current-buffer))
             (not truncate-lines) (/= (window-hscroll window) 0))
    (set-window-hscroll window 0)))

(defun harness-compose--follow (window)
  "Keep the box on WINDOW's last line while the window's point is in it.
The box's lines wrap, so it grows and shrinks as it is typed in, and
the host redraws around it.  Emacs would recenter once the box falls
off the bottom and leave a gap under it once it shrinks; instead WINDOW
scrolls just enough to keep the box's last line on its last line (above
the spare line of a host padding its top), the way a chat app's input
grows upwards.  A buffer that fits shows from its start, for the
padding.  Only after the text or the window's size changed: scrolling
is left to the user.

The window's start is never forced: were point's line to fall outside
the window from there, redisplay would move point, out of the box, to
the window's last whole line or its middle, where a host's keys may be
commands, rather than scroll."
  (let ((key (list (current-buffer) (buffer-chars-modified-tick)
                   (window-body-width window t) (window-body-height window t))))
    (unless (equal key (window-parameter window 'harness-compose-follow))
      (set-window-parameter window 'harness-compose-follow key)
      (when (harness-compose-in-p (window-point window))
        ;; Measured without the padding, which is sized again after this.
        (harness-compose-repad window)
        (let* ((body (window-body-height window t))
               (line (frame-char-height (window-frame window)))
               (room (- body (if harness-compose--pad-at 0 line)))
               ;; Exact up to ROOM and more than ROOM beyond, so a buffer
               ;; taller than the window never reads as one that fits:
               ;; showing it from its start would push point, and the
               ;; box with it, out of the window on every redraw.
               (height (lambda (from) (harness-ui-text-height window from harness-compose-end room)))
               (start (window-start window))
               (pt (window-point window))
               (anchor (if harness-compose--pad-at harness-compose-end (point-max))))
          (cond
           ((<= (funcall height (point-min)) room)
            (unless (= start (point-min)) (set-window-start window (point-min) t)))
           ;; Grown past the bottom.  Point's line goes there instead when
           ;; the box from point on is taller than the window.
           ((not (pos-visible-in-window-p pt window))
            (harness-compose--bottom-at
             window (if (<= (funcall height (save-excursion (goto-char pt) (vertical-motion 0 window) (point)))
                            room)
                        anchor
                      pt)))
           ;; Shrunk, leaving a gap under the box.
           ((and (> start (point-min)) (<= line (- room (funcall height start))))
            (harness-compose--bottom-at window anchor))))))))

(defun harness-compose--bottom-at (window pos)
  "Scroll WINDOW so the screen line of POS is its last."
  (with-selected-window window
    (save-excursion (goto-char pos) (recenter -1))))

;;;; Editing and reading

(defun harness-compose-set (text)
  "Replace the box's contents with TEXT."
  (setq harness-compose--text text)
  (when (harness-compose-live-p)
    (let ((inhibit-read-only t))
      (delete-region harness-compose-start harness-compose-end)
      (save-excursion (goto-char harness-compose-start) (insert text)))
    (harness-compose-update-placeholder)))

(defun harness-compose-clear ()
  "Empty the box and drop the attachments, then redraw."
  (harness-compose-set "")
  (harness-compose--drop-pending)
  (setq harness-compose-attachments nil)
  (funcall harness-compose-redraw-function))

(defun harness-compose-take ()
  "Return (TEXT . ATTACHMENTS) from the box, or signal when both are empty.
The files that @ references typed out in TEXT name are attached too,
after the box's own attachments (`harness-compose--references'); the
references stay in TEXT.  A link still downloading signals too: the
message waits for it."
  (let ((text (string-trim (harness-compose-text)))
        (atts harness-compose-attachments))
    (when (and (string-empty-p text) (null atts)) (user-error "Nothing to send"))
    (when-let* ((pending (cl-find-if (lambda (a) (plist-get a :pending)) atts)))
      (user-error "%s is still downloading: wait for it, or remove it (×)"
                  (or (plist-get pending :name) "An attachment")))
    (cons text (append atts (cl-remove-if (lambda (a) (harness-compose--attached-p (plist-get a :path)))
                                          (harness-compose--references text))))))

(defun harness-compose-newline ()
  "Insert a newline in the box, or jump there from elsewhere."
  (interactive)
  (if (harness-compose-in-p)
      (insert "\n")
    (goto-char harness-compose-end)))

(defun harness-compose-skill-reference-p (text)
  "Non-nil when TEXT references a skill by /name or @skill:name."
  (or (string-match-p "\\(?:\\`\\|[ \t\n]\\)@skill:[A-Za-z0-9_.-]+" text)
      (let ((case-fold-search nil) (found nil))
        (dolist (name harness-compose--skills found)
          (when (string-match-p (concat "\\(?:\\`\\|[ \t\n]\\)/" (regexp-quote name) "\\_>") text)
            (setq found t))))))

(defun harness-compose-with-expanded-text (text callback)
  "Call CALLBACK with TEXT after expanding the skill references in it."
  (if (harness-compose-skill-reference-p text)
      (harness-ui-call "_harness/skills/expand" (list :text text :cwd (harness-compose--project))
                       (lambda (r) (funcall callback (or (plist-get r :text) text)))
                       (lambda (_) (funcall callback text)))
    (funcall callback text)))

(defun harness-compose-attachment-block (att)
  "Return the ACP prompt block for attachment ATT."
  (let* ((path (plist-get att :path))
         (mime (or (plist-get att :mime) "application/octet-stream")))
    (if (and (string-prefix-p "image/" mime) (file-readable-p path))
        (list :type "image" :mimeType mime
              :data (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally path)
                      (base64-encode-string (buffer-string) t)))
      (list :type "resource_link" :uri (concat "file://" path)
            :name (or (plist-get att :name) (file-name-nondirectory path))
            :size (plist-get att :size) :mimeType mime))))

;;;; Finding files

;; @ references and the attach command find a file the same way.  Part
;; of a name finds a project file in any subdirectory, among the files
;; listed from the projectile cache (`harness-compose--files').  A path
;; finds any file of this machine: one starting with / or ~ (absolute,
;; or in a home directory), or with ./ or ../, relative to the root the
;; project's files are named from, so ../other-repo/README.md is the
;; README next door.  Paths complete directory by directory, the way
;; `read-file-name' does, but only on this machine: completing as you
;; type must never open a connection to a remote host.

(defun harness-compose--root ()
  "Return the directory the box's file names are relative to.
That is the project's root (`harness-compose-project-function'), as a
directory name."
  (file-name-as-directory (expand-file-name (or (harness-compose--project) default-directory))))

(defun harness-compose--path-p (name)
  "Non-nil when NAME is a path rather than part of a project file's name.
A path starts with / or ~, or with ./ or ../, or is just \"..\"."
  (string-match-p "\\`\\(?:[/~]\\|\\.\\.?/\\|\\.\\.\\'\\)" name))

(defun harness-compose--complete-path (root string pred action)
  "Complete the path STRING, relative to ROOT, for completion ACTION with PRED.
Only files of this machine complete: file name handlers are off, so a
remote name, which TRAMP would connect for, completes to nothing.  A
directory's ./ and ../ are offered only once a name starting with a dot
is typed, so a popup lists what the directory holds."
  (let* ((default-directory root)
         (file-name-handler-alist nil)
         (non-essential t)
         (found (completion-file-name-table string pred action)))
    (if (and (eq action t) (not (string-prefix-p "." (file-name-nondirectory string))))
        (cl-remove-if (lambda (name) (member name '("./" "../"))) found)
      found)))

(defun harness-compose--file-table ()
  "Return the completion table @ references and the attach command find files in.
Part of a name completes over the project's files, in the
`harness-compose-file' category, which matches with `flex' unless
configured otherwise.  A path (`harness-compose--path-p') completes
over the file system, relative to the box's root, directory by
directory, in the `file' category: the styles and the UI (vertico,
marginalia) of file names apply to it."
  (let ((files (harness-compose--table 'harness-compose--files 'harness-compose-file))
        (root (harness-compose--root)))
    (lambda (string pred action)
      (if (harness-compose--path-p string)
          (harness-compose--complete-path root string pred action)
        (funcall files string pred action)))))

(defun harness-compose--attach-table ()
  "Return the table the attach command reads a file with.
That of @ references (`harness-compose--file-table'), but a leading @,
typed out of the habit of the box, is ignored: \"@notes\" finds what
\"notes\" does."
  (let ((table (harness-compose--file-table)))
    (lambda (string pred action)
      (if (not (string-prefix-p "@" string))
          (funcall table string pred action)
        (let ((name (substring string 1)))
          (pcase action
            ;; The @ is out of the field being completed.
            (`(boundaries . ,_)
             (let ((inner (funcall table name pred action)))
               `(boundaries ,(1+ (or (cadr inner) 0)) . ,(cddr inner))))
            ('nil (let ((found (funcall table name pred nil)))
                    (if (stringp found) (concat "@" found) found)))
            (_ (funcall table name pred action))))))))

(defun harness-compose--local-file (name root)
  "Return NAME, relative to ROOT, absolute when it is a regular file here, or nil.
A remote name is never looked at, as completing it never is."
  (let* ((file-name-handler-alist nil)
         (path (expand-file-name name root)))
    (and (file-regular-p path) path)))

;; An @ reference typed out in full, or pasted, rather than completed
;; names its file all the same: sending the message attaches it
;; (`harness-compose-take'), and the reference stays in the text, where
;; it says what the file is for.

(defconst harness-compose--reference-regexp "\\(?:\\`\\|[ \t\n]\\)@\\([^ \t\n]+\\)"
  "An @ reference: an @ starting a word, then the name up to a space.
That is the token @ completes in the box (`harness-compose--capf-bounds').")

(defun harness-compose--reference-file (name root)
  "Return the absolute name of the file the @ reference NAME means, or nil.
NAME is what follows the @: a file the project lists, or a path
relative to ROOT, absolute or under ~, of a regular file of this
machine.  Punctuation ending a sentence or a bracket after it is no
part of it (\"see @notes.txt.\"), and an @skill: reference names a
skill, not a file."
  (unless (string-prefix-p "skill:" name)
    (cl-some (lambda (candidate)
               (cond ((string-empty-p candidate) nil)
                     ((member candidate harness-compose--files) (expand-file-name candidate root))
                     (t (harness-compose--local-file candidate root))))
             (delete-dups (list name (replace-regexp-in-string "[]),.;:!?'\"`>}]+\\'" "" name))))))

(defun harness-compose--references (text)
  "Return the attachments of the files the @ references in TEXT name.
In the order of TEXT, each file once; see
`harness-compose--reference-file' for what a reference may name."
  (let ((root (harness-compose--root)) (start 0) (paths nil))
    (while (string-match harness-compose--reference-regexp text start)
      (setq start (match-end 0))
      (when-let* ((path (harness-compose--reference-file (match-string 1 text) root)))
        (cl-pushnew path paths :test #'equal)))
    (mapcar #'harness-compose--file-attachment (nreverse paths))))

(defun harness-compose-without-references (atts text)
  "Return ATTS without the files the @ references in TEXT name.
ATTS are the attachments `harness-compose-take' returned with TEXT.
For what can only be text, an answer to a question say: a file the text
names goes as its reference, while any other attachment cannot go."
  (let ((named (mapcar (lambda (att) (plist-get att :path)) (harness-compose--references text))))
    (cl-remove-if (lambda (att) (member (plist-get att :path) named)) atts)))

;;;; Attachments

(defun harness-compose--mime-of (path)
  "Return the MIME type of PATH."
  (or (mailcap-extension-to-mime (file-name-extension path t)) "application/octet-stream"))

(defun harness-compose-read-file (&optional any)
  "Read a file to attach and return its absolute name.
Part of a name finds a project file in any subdirectory, and a path any
file: absolute, under ~, or relative to the project with ./ or ../,
completing directory by directory.  It is what @ completes in the box
\(`harness-compose--file-table'), so the project's files match with
`flex' unless configured otherwise, and a leading @ is ignored.  A
directory is no file to attach: choosing one reads again, from inside
it, and so does an empty answer.  With ANY, or when the project lists
no files, browse the file system instead.  The project is never listed
while you wait: a listing still running fills the candidates in when it
returns."
  (let ((root (harness-compose--root))
        (listing (harness-compose-fetch-files)))
    (expand-file-name
     (if (or any (and (harness-promise-settled-p listing) (null harness-compose--files)))
         (read-file-name "Attach file: " root nil t)
       (let ((table (harness-compose--attach-table)) (initial nil) (name nil))
         (while (progn
                  (setq name (string-remove-prefix
                              "@" (completing-read "Attach a project file, or a path (/ ~/ ../): "
                                                   table nil t initial)))
                  (let ((file-name-handler-alist nil))
                    (file-directory-p (expand-file-name name root))))
           (setq initial (and (not (string-empty-p name)) (file-name-as-directory name))))
         name))
     root)))

(defun harness-compose-add-attachment (path &optional mime)
  "Attach the file PATH (with MIME) to the next message.
Interactively, part of its name finds a project file in any
subdirectory, and a path (/, ~/, ./, ../) any file; with a prefix
argument, the file system is browsed instead (see
`harness-compose-read-file')."
  (interactive (list (harness-compose-read-file current-prefix-arg)))
  (let ((path (expand-file-name path)))
    (harness-compose--attach (harness-compose--file-attachment path mime))
    (funcall harness-compose-redraw-function)
    (message "Attached %s" (abbreviate-file-name path))))

(defun harness-compose-remove-attachment (path)
  "Remove the attachment PATH."
  (interactive (list (completing-read "Remove attachment: "
                                      (delq nil (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments))
                                      nil t)))
  (setq harness-compose-attachments
        (cl-remove path harness-compose-attachments :key (lambda (a) (plist-get a :path)) :test #'equal))
  (funcall harness-compose-redraw-function))

;;;; Downloads

;; A link dropped on the box downloads with curl as a subprocess
;; (`harness-http-download'), never blocking Emacs.  Until it arrived
;; its place among the attachments holds a pending entry, (:pending t
;; :id :url :name :download ...), whose chip shows the progress; then
;; the attachment of the file takes its place, in the downloads
;; directory under the name the server or the link gave.

(defun harness-compose-attach-clipboard (&optional from-ring)
  "Attach what the clipboard holds.
An image is attached and goes on the media ring, files copied in a
file manager are attached, data of other MIME types is offered to
choose from and attached, and plain text goes into the box.  With a
prefix argument FROM-RING, attach an earlier capture of the media ring
instead (`harness-compose-attach-from-ring')."
  (interactive "P")
  (if from-ring
      (call-interactively #'harness-compose-attach-from-ring)
    (unless (display-graphic-p) (user-error "The clipboard needs a graphical display"))
    (let* ((targets (harness-media-ring-clipboard-targets))
           (image (harness-media-ring-capture-image targets))
           (files (and (not image) (harness-media-ring-clipboard-files targets)))
           (mimes (cl-remove-if-not (lambda (s) (string-match-p "\\`[a-z]+/" (symbol-name s))) targets)))
      (cond
       (image (harness-compose--attach-captures (list image)))
       (files (harness-compose--attach-captures (mapcar #'harness-compose--file-attachment files)))
       (mimes
        (let* ((choice (intern (completing-read "Clipboard type: " (mapcar #'symbol-name mimes) nil t)))
               (att (harness-media-ring-capture choice)))
          (unless att (user-error "The clipboard gave nothing as %s" choice))
          (harness-compose--attach-captures (list att))))
       (t
        (let ((text (ignore-errors (gui-get-selection 'CLIPBOARD 'UTF8_STRING))))
          (unless (and (stringp text) (not (string-empty-p text)))
            (user-error "Nothing usable in the clipboard"))
          (unless (harness-compose-in-p) (goto-char harness-compose-end))
          (insert (substring-no-properties text))))))))

(defun harness-compose-dnd-open (uri action)
  "Attach the file dropped as URI; ACTION is returned unchanged."
  (when-let* ((path (dnd-get-local-file-name uri t)))
    (harness-compose-add-attachment path))
  action)

(defun harness-compose-fetch-files ()
  "Refresh the files @ completes from the project's file list.
Listed here, not by the harness process, so it is this Emacs's
projectile cache (cleared by `projectile-invalidate-cache') that answers;
a miss lists asynchronously.  On failure the previous list is kept.
Return a promise settled once the list is in place."
  (let ((buf (current-buffer)))
    (harness-then (harness-files-list-limited (harness-compose--project) nil 20000)
                  (lambda (files)
                    (when (buffer-live-p buf)
                      (with-current-buffer buf (harness-compose--arrived 'harness-compose--files files))))
                  (lambda (err) (harness-log 'warn "compose: listing project files failed: %s" (harness-error-message err))))))

(defun harness-compose-fetch-completions ()
  "Prefetch project files and skill names for completion."
  (let ((buf (current-buffer)))
    (harness-compose-fetch-files)
    (harness-ui-call "_harness/skills/list" (list :cwd (harness-compose--project))
                     (lambda (skills)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (harness-compose--arrived 'harness-compose--skills
                                                     (mapcar (lambda (s) (plist-get s :name)) skills)))))
                     #'ignore)))

(defun harness-compose--arrived (var value)
  "Set VAR, a completion source of the box, to VALUE.
A token typed before the source arrived was offered nothing: when VAR
was empty, the completion UI is asked again."
  (let ((was (symbol-value var)))
    (set var value)
    (when (and value (null was))
      (harness-compose--popup-later 0))))

(defun harness-compose--capf-bounds (char)
  "Return (START . END) of the token after CHAR before point in the box."
  (when (harness-compose-in-p)
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward "^ \t\n" harness-compose-start)
        (when (and (< (point) end) (eq (char-after) char)
                   (or (= (point) harness-compose-start)
                       (memq (char-before) '(?\s ?\t ?\n))))
          (cons (1+ (point)) end))))))

(defun harness-compose--table (var category)
  "Return a completion table over the strings in VAR, with CATEGORY metadata.
VAR, a variable of the current buffer, is read each time the table is
asked: the box's sources arrive asynchronously, and a table made before
one did offers it once it has."
  (let ((buf (current-buffer)))
    (lambda (string pred action)
      (if (eq action 'metadata)
          (list 'metadata (cons 'category category))
        (complete-with-action action (and (buffer-live-p buf) (buffer-local-value var buf))
                              string pred)))))

(defun harness-compose--attach-token (name root)
  "Attach the file the @ token NAME, just completed before point, names.
The token goes, its file taking its place among the attachments.  A
project file's name attaches its file; a path (relative to ROOT) only a
regular file of this machine: a directory stays in the box, for its
files to complete next."
  (when-let* ((path (if (harness-compose--path-p name)
                        (harness-compose--local-file name root)
                      (expand-file-name name root))))
    (let* ((end (point))
           (start (- end (length name) 1)))
      (when (and (harness-compose-in-p start)
                 (equal (buffer-substring-no-properties start end) (concat "@" name)))
        (delete-region start end)))
    (harness-compose-add-attachment path)))

(defun harness-compose-completion-at-point ()
  "Complete @files and /skills in the box.
An @ completes a project file by part of its name, or any file by its
path (see `harness-compose--file-table'); a completed file becomes an
attachment.  The sigil is what starts completion, the way an LSP
trigger character does: popups that wait for a few characters show
right after it."
  (let ((file (harness-compose--capf-bounds ?@))
        (skill (harness-compose--capf-bounds ?/))
        (root (harness-compose--root)))
    (cond
     (file
      ;; A new @ token refreshes the list, so files created since the
      ;; buffer opened show up once the listing returns.
      (unless (eql (car file) harness-compose--files-at)
        (setq harness-compose--files-at (car file))
        (harness-compose-fetch-files))
      (list (car file) (cdr file)
            (harness-compose--file-table)
            :exclusive 'no
            :company-prefix-length t
            :company-kind (lambda (name) (if (string-suffix-p "/" name) 'folder 'file))
            :exit-function
            (lambda (str status)
              (when (memq status '(finished sole))
                (harness-compose--attach-token str root)))))
     ((and skill (= (1- (car skill)) harness-compose-start))
      (list (car skill) (cdr skill)
            (harness-compose--table 'harness-compose--skills 'harness-compose-skill)
            :exclusive 'no
            :company-prefix-length t
            :exit-function (lambda (_str status) (when (memq status '(finished sole)) (insert " "))))))))

(defvar harness-state-directory)
(defvar x-dnd-types-alist)
(defvar x-dnd-known-types)
(defvar x-dnd-direct-save-function)
(defcustom harness-compose-thumbnail-lines 4
  "Height of the thumbnail an attached image or video shows, in lines.
0 shows none.  Videos need the media module and ffmpeg."
  :type 'number :group 'harness-compose)

(defcustom harness-compose-download-max-size (* 200 1024 1024)
  "Largest file, in bytes, that a link dropped on a compose box downloads."
  :type 'integer :group 'harness-compose)

(defcustom harness-compose-yank-media t
  "Non-nil: yanking in a compose box attaches the media on the clipboard.
When the clipboard holds an image (copied in a browser, or by a
screenshot tool) or files copied in a file manager, and this Emacs did
not put it there, \\[yank] attaches them instead of yanking text.  The
image goes on the media ring, a kill ring of its own that only compose
boxes read, and \\[yank-pop] right after swaps it for an earlier one.
`kill-ring' never sees an image, so other modes are not affected.
\\[universal-argument] \\[yank] yanks text whatever the clipboard holds,
and so does \\[yank] once the image is attached."
  :type 'boolean :group 'harness-compose)

(defface harness-compose-progress-face '((t :inherit success))
  "The filled part of a download's progress bar." :group 'harness-compose)

;;;; State

(defvar-local harness-compose--progress nil "Alist: id of a pending download -> overlay showing its progress.")
(defvar-local harness-compose--progress-timer nil "Timer animating the chips of pending downloads.")
(defvar-local harness-compose--yanked nil
  "What the last media yank attached: (:paths PATHS :index I).
I is the media ring entry it was, or -1 for files of a file manager.")
(defun harness-compose--yank-binding (command)
  "Return COMMAND, the box's own yank, unless yanking media is off."
  (and harness-compose-yank-media command))

(defun harness-compose--chip-name (att)
  "Return the name the chip of attachment ATT shows.
A file of the project goes by its path in the project, a capture or a
download of the harness by its name, any other file by its path."
  (let ((path (plist-get att :path)))
    (cond ((null path) (or (plist-get att :name) "attachment"))
          ((and (boundp 'harness-state-directory)
                (string-prefix-p (expand-file-name harness-state-directory) path))
           (or (plist-get att :name) (file-name-nondirectory path)))
          (t (harness-relative-path (harness-compose--project) path)))))

(defun harness-compose--chip (att)
  "Return the chip of attachment ATT: its thumbnail, name and size, and ×."
  (let* ((path (plist-get att :path))
         (help (harness-ui-one-line
                (concat (abbreviate-file-name path) "\n"
                        (harness-format-bytes (plist-get att :size)) ", " (or (plist-get att :mime) "")
                        (if (plist-get att :url) (concat "\nfrom " (plist-get att :url)) "")
                        "\nmouse-1: open")))
         (open (lambda (&rest _) (interactive) (harness-compose-open-attachment att)))
         (thumb (harness-compose--thumbnail att)))
    (concat
     (if thumb
         (concat (propertize thumb 'help-echo help 'pointer 'hand
                             'keymap (harness-ui-mouse-keymap open))
                 " ")
       "")
     (buttonize (format "%s (%s)" (harness-truncate-middle (harness-compose--chip-name att) 40)
                        (harness-format-bytes (plist-get att :size)))
                open nil help)
     (propertize (buttonize "×" (lambda (_) (harness-compose-remove-attachment path)) nil
                            "Remove this attachment")
                 'face 'harness-dim-face))))

(defun harness-compose-open-attachment (att)
  "Open attachment ATT: a video or a sound in the player, anything else in Emacs."
  (let ((path (plist-get att :path)))
    (cond ((not (file-exists-p path)) (user-error "%s is gone" (abbreviate-file-name path)))
          ((and (string-match-p "\\`\\(?:video\\|audio\\)/" (or (plist-get att :mime) ""))
                (fboundp 'harness-ui-media-open))
           (harness-ui-media-open path))
          (t (find-file-other-window path)))))

(defun harness-compose--thumbnail-height ()
  "Return the height of thumbnails in pixels, or nil when none are shown."
  (and (display-images-p) (> harness-compose-thumbnail-lines 0)
       (round (* harness-compose-thumbnail-lines (frame-char-height)))))

(defun harness-compose--image (file height)
  "Return a string showing the image FILE at most HEIGHT pixels high, or nil."
  (when (and file (file-readable-p file) (ignore-errors (image-supported-file-p file)))
    (when-let* ((image (ignore-errors (create-image file nil nil :max-height height :max-width (* 3 height)
                                                    :ascent 'center))))
      (propertize " " 'display image))))

(defun harness-compose--thumbnail (att)
  "Return a string showing a thumbnail of attachment ATT, or nil.
A video's is made by the media module, in the background: the box is
redrawn once it is there."
  (when-let* ((height (harness-compose--thumbnail-height))
              (path (plist-get att :path)))
    (let ((mime (or (plist-get att :mime) "")))
      (cond ((string-prefix-p "image/" mime) (harness-compose--image path height))
            ((and (string-prefix-p "video/" mime) (fboundp 'harness-ui-media-video-thumbnail))
             (let ((buf (current-buffer)))
               (harness-compose--image
                (harness-ui-media-video-thumbnail
                 path (lambda () (when (buffer-live-p buf)
                                   (with-current-buffer buf (harness-compose-redraw)))))
                height)))))))

(defconst harness-compose--spinner ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames of the spinner of a pending download.")

(defun harness-compose--insert-pending-chip (att)
  "Insert the chip of ATT, a download under way, and the overlay drawing it."
  (let ((id (plist-get att :id))
        (start (point)))
    (insert (propertize " " 'harness-compose-pending id))
    (let ((ov (make-overlay start (point) nil t nil)))
      (overlay-put ov 'display (harness-compose--progress-string att))
      (overlay-put ov 'help-echo (concat "Downloading " (plist-get att :url)))
      (push (cons id ov) harness-compose--progress))
    (insert (propertize (buttonize "×" (lambda (_) (harness-compose-cancel-download id)) nil
                                   "Stop this download")
                        'face 'harness-dim-face))))

(defun harness-compose--progress-string (att)
  "Return what the chip of ATT, a download under way, shows now."
  (let* ((dl (plist-get att :download))
         (received (if dl (harness-http-download-received dl) 0))
         (total (and dl (harness-download-total dl)))
         (fraction (and total (> total 0) (min 1.0 (/ (float received) total))))
         (frame (aref harness-compose--spinner
                      (mod (truncate (* 8 (float-time))) (length harness-compose--spinner)))))
    (concat
     (propertize frame 'face 'harness-dim-face) " "
     (harness-truncate-middle (or (plist-get att :name) "download") 40) " "
     (if fraction
         (let ((filled (round (* 10 fraction))))
           (concat (propertize (make-string filled ?━) 'face 'harness-compose-progress-face)
                   (propertize (make-string (- 10 filled) ?─) 'face 'harness-dim-face)
                   (propertize (format " %d%% of %s" (floor (* 100 fraction)) (harness-format-bytes total))
                               'face 'harness-dim-face)))
       (propertize (if (> received 0) (format "%s so far" (harness-format-bytes received)) "connecting…")
                   'face 'harness-dim-face))
     " ")))

(defun harness-compose--start-progress ()
  "Animate the chips of pending downloads until there are none."
  (when (and harness-compose--progress (not harness-compose--progress-timer))
    (let ((buf (current-buffer)) (timer nil))
      (setq timer (run-at-time 0.15 0.15
                               (lambda ()
                                 (if (not (buffer-live-p buf))
                                     (cancel-timer timer)
                                   (with-current-buffer buf (harness-compose--tick-progress timer)))))
            harness-compose--progress-timer timer))))

(defun harness-compose--tick-progress (timer)
  "Redraw the chips of pending downloads; stop TIMER once there are none."
  (let ((live nil))
    (dolist (p harness-compose--progress)
      (let ((att (harness-compose--pending (car p))))
        (when (and att (overlay-buffer (cdr p)))
          (setq live t)
          (overlay-put (cdr p) 'display (harness-compose--progress-string att)))))
    (unless live
      (cancel-timer timer)
      (when (eq timer harness-compose--progress-timer)
        (setq harness-compose--progress-timer nil)))))

(defun harness-compose-redraw ()
  "Redraw the box, through its host."
  (funcall harness-compose-redraw-function))

(defun harness-compose--attached-p (path)
  "Non-nil when the file PATH is attached."
  (and path (cl-find (expand-file-name path) harness-compose-attachments
                     :key (lambda (a) (plist-get a :path)) :test #'equal)))

(defun harness-compose--file-attachment (path &optional mime)
  "Return the attachment of the file PATH, of the MIME type MIME."
  (let ((path (expand-file-name path)))
    (list :path path :size (or (harness-file-size path) 0)
          :mime (or mime (harness-compose--mime-of path))
          :name (file-name-nondirectory path))))

(defun harness-compose--attach (att)
  "Add the attachment ATT, unless its file is attached already; no redraw.
Return non-nil when it was added."
  (unless (harness-compose--attached-p (plist-get att :path))
    (setq harness-compose-attachments (append harness-compose-attachments (list att)))
    t))

(defun harness-compose--downloads-directory ()
  "Return the directory links dropped on a compose box download into."
  (harness-ensure-directory
   (expand-file-name "downloads/" (if (boundp 'harness-state-directory) harness-state-directory
                                    (locate-user-emacs-file "harness/")))))

(defun harness-compose--pending (id)
  "Return the pending download ID of this box, or nil."
  (cl-find-if (lambda (a) (and (plist-get a :pending) (equal (plist-get a :id) id)))
              harness-compose-attachments))

(defun harness-compose--clean-partials ()
  "Remove downloads left half-written by an Emacs that died mid-download.
A fresh one is never touched: only files older than a day go."
  (dolist (file (ignore-errors (directory-files (harness-compose--downloads-directory) t "\\`\\.partial-")))
    (let ((age (ignore-errors (float-time (file-attribute-modification-time (file-attributes file))))))
      (when (and age (< age (- (float-time) 86400)))
        (ignore-errors (delete-file file))))))

(defun harness-compose--settle-pending (id &optional att)
  "Put the attachment ATT where the pending download ID was, or drop it; redraw."
  (setq harness-compose-attachments
        (delq nil (mapcar (lambda (a) (if (and (plist-get a :pending) (equal (plist-get a :id) id)) att a))
                          harness-compose-attachments)))
  (harness-compose-redraw))

(defun harness-compose--drop-pending ()
  "Stop every download of this box and forget their chips, without a redraw."
  (let ((pending (cl-remove-if-not (lambda (a) (plist-get a :pending)) harness-compose-attachments)))
    (when pending
      (setq harness-compose-attachments
            (cl-remove-if (lambda (a) (plist-get a :pending)) harness-compose-attachments))
      (dolist (a pending) (harness-http-download-cancel (plist-get a :download))))))

(defun harness-compose-cancel-download (id)
  "Stop the download ID and remove its chip."
  (when-let* ((att (harness-compose--pending id)))
    (harness-compose--settle-pending id nil)
    (harness-http-download-cancel (plist-get att :download))
    (message "Stopped downloading %s" (plist-get att :name))))

(defun harness-compose-download (url &optional name)
  "Download URL in the background, then attach the file.
NAME is the name to give the file, else the server's or the link's.
Meanwhile the chip of the download shows its progress, and its ×
stops it; the message waits for it.  A link to a web page (HTML) is
not downloaded: it goes into the box as text.  A link that arrives
with junk around it (a NUL, a newline, a byte order mark, a zero width
space) is cleaned first; one that is no http, https or ftp link with a
host to fetch is refused, shown with %S so that what was wrong with it
shows."
  (interactive (list (read-string "Download and attach the link: ")))
  (let ((raw url))
    (when (and (stringp raw) (> (length raw) 0) (text-properties-at 0 raw))
      ;; A link off a selection carries `foreign-selection'; worth a line,
      ;; since it is what used to make curl read a whole address as a
      ;; fragment.
      (harness-log 'info "compose: link arrived with text properties %S" (text-properties-at 0 raw)))
    (setq url (harness-http-clean-url url))
    (unless (equal raw url)
      ;; The junk a drop hides: it is what makes curl disagree with what
      ;; the box shows.
      (harness-log 'info "compose: link arrived as %S, cleaned to %S" raw url)))
  (harness-log 'debug "compose: link to download: %S" url)
  (unless (and (string-match-p "\\`\\(?:https?\\|ftps?\\)://" url) (harness-http-link-p url))
    (user-error "That is not a link I can fetch: %S" url))
  (unless harness-http--curl-program
    (user-error "Downloading a link needs curl"))
  (harness-compose--clean-partials)
  (if (cl-find url harness-compose-attachments :key (lambda (a) (plist-get a :url)) :test #'equal)
      (message "%s is attached already" url)
    (let* ((id (harness-short-id))
           (buf (current-buffer))
           (att (list :pending t :id id :url url :page nil :download nil :named (and name t)
                      :name (harness-compose--clean-name (or name (harness-http-url-file-name url) "download")))))
      (setq harness-compose-attachments (append harness-compose-attachments (list att)))
      (plist-put att :download
                 (harness-http-download
                  url (expand-file-name (concat ".partial-" id) (harness-compose--downloads-directory))
                  :max-size harness-compose-download-max-size
                  :on-headers (lambda (dl) (harness-compose--download-headers buf id dl))
                  :callback (lambda (dl err) (harness-compose--download-done buf id dl err))))
      (harness-compose-redraw)
      (message "Downloading %s…" (plist-get att :name)))))

(defun harness-compose--download-headers (buf id dl)
  "Take what the server said of DL, the download ID of BUF.
A web page is not downloaded: the link goes into the box instead."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when-let* ((att (harness-compose--pending id)))
        (cond ((member (harness-download-mime dl) '("text/html" "application/xhtml+xml"))
               (plist-put att :page t)
               (harness-http-download-cancel dl))
              ((and (harness-download-name dl) (not (plist-get att :named)))
               (plist-put att :name (harness-compose--clean-name (harness-download-name dl)))))))))

(defun harness-compose--download-done (buf id dl err)
  "Settle DL, the download ID of BUF, which ended with the error ERR or nil."
  (let ((att (and (buffer-live-p buf) (with-current-buffer buf (harness-compose--pending id)))))
    (cond
     ((null att)
      (unless err (ignore-errors (delete-file (harness-download-file dl)))))
     ((plist-get att :page)
      (with-current-buffer buf
        (harness-compose--settle-pending id nil)
        (harness-compose--append-text (plist-get att :url))
        (message "%s is a web page: its address went into the message" (plist-get att :url))))
     (err
      (with-current-buffer buf
        (harness-compose--settle-pending id nil)
        (harness-log 'warn "compose: download failed for %S: %s" (plist-get att :url) err)
        (message "Could not download %s: %s" (plist-get att :url) err)))
     (t
      (with-current-buffer buf
        (let* ((file (harness-download-file dl))
               (mime (harness-compose--download-mime dl file (plist-get att :name)))
               (path (harness-compose--unique-file (harness-compose--downloads-directory)
                                                   (harness-compose--name-for-mime (plist-get att :name) mime))))
          (rename-file file path)
          (harness-compose--settle-pending
           id (list :path path :size (or (harness-file-size path) 0) :mime mime
                    :name (file-name-nondirectory path) :url (plist-get att :url)))
          (message "Attached %s (%s)" (file-name-nondirectory path)
                   (harness-format-bytes (harness-file-size path)))))))))

(defun harness-compose--append-text (text)
  "Add TEXT at the end of the box, after a space, leaving point where it is."
  (when (harness-compose-live-p)
    (save-excursion
      (goto-char harness-compose-end)
      (when (and (> (point) harness-compose-start) (not (memq (char-before) '(?\s ?\t ?\n))))
        (insert " "))
      (insert text))
    (harness-compose-update-placeholder)))

(defconst harness-compose--vague-mimes
  '("application/octet-stream" "binary/octet-stream" "application/binary" "application/unknown"
    "application/download" "application/force-download" "application/x-download")
  "Content types that say nothing of what a download is.")

(defun harness-compose--download-mime (dl file name)
  "Return the MIME type of FILE, downloaded by DL under the name NAME.
The server's, unless it says nothing; then the file's first bytes or
its name tell."
  (let ((mime (harness-download-mime dl)))
    (if (and mime (not (string-empty-p mime)) (not (member mime harness-compose--vague-mimes)))
        mime
      (or (harness-compose--sniff-mime file)
          (let ((guess (harness-media-ring-mime (or name ""))))
            (and (not (equal guess "application/octet-stream")) guess))
          "application/octet-stream"))))

(defun harness-compose--sniff-mime (file)
  "Return the MIME type the first bytes of FILE say, or nil."
  (let* ((head (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (ignore-errors (insert-file-contents-literally file nil 0 64))
                 (buffer-string)))
         (at (lambda (from tag) (and (>= (length head) (+ from (length tag)))
                                     (string= (substring head from (+ from (length tag))) tag)))))
    (cond ((funcall at 0 "\211PNG") "image/png")
          ((funcall at 0 "\377\330\377") "image/jpeg")
          ((funcall at 0 "GIF8") "image/gif")
          ((and (funcall at 0 "RIFF") (funcall at 8 "WEBP")) "image/webp")
          ((and (funcall at 0 "RIFF") (funcall at 8 "WAVE")) "audio/wav")
          ((or (funcall at 4 "ftypavif") (funcall at 4 "ftypavis")) "image/avif")
          ((funcall at 4 "ftypqt") "video/quicktime")
          ((funcall at 4 "ftyp") "video/mp4")
          ((funcall at 0 "\032\105\337\243") "video/webm")
          ((funcall at 0 "%PDF-") "application/pdf")
          ((funcall at 0 "OggS") "audio/ogg")
          ((funcall at 0 "ID3") "audio/mpeg")
          ((string-match-p "\\`\\(?:<\\?xml[^>]*>[ \t\r\n]*\\)?<svg" head) "image/svg+xml"))))

(defun harness-compose--clean-name (name)
  "Return NAME fit to name a file: no slashes or control characters, not hidden."
  (let* ((clean (replace-regexp-in-string "\\`[. ]+" ""
                                          (replace-regexp-in-string "[/\\\\[:cntrl:]]+" "_" (string-trim name))))
         (ext (file-name-extension clean t)))
    (when (> (length clean) 100)
      (setq clean (concat (substring (file-name-sans-extension clean) 0 (max 1 (- 100 (length ext)))) ext)))
    (if (string-empty-p clean) "download" clean)))

(defun harness-compose--name-for-mime (name mime)
  "Return NAME with an extension saying MIME, unless its own says so."
  (let ((ext (file-name-extension name)))
    (cond ((member mime harness-compose--vague-mimes) name)
          ((null ext) (concat name "." (harness-media-ring-extension mime)))
          ((equal (harness-media-ring-mime name) mime) name)
          ;; An extension saying something else (photo.php) gives way.
          ((mailcap-extension-to-mime (concat "." ext))
           (concat (file-name-sans-extension name) "." (harness-media-ring-extension mime)))
          (t (concat name "." (harness-media-ring-extension mime))))))

(defun harness-compose--unique-file (dir name)
  "Return a file named NAME in DIR that does not exist yet, numbered if need be."
  (let* ((ext (or (file-name-extension name t) ""))
         (base (file-name-sans-extension name))
         (path (expand-file-name name dir))
         (n 1))
    (while (file-exists-p path)
      (setq path (expand-file-name (format "%s-%d%s" base n ext) dir)
            n (1+ n)))
    path))

(defun harness-compose--attach-bytes (bytes mime name)
  "Save BYTES, of the MIME type MIME, among the downloads as NAME; attach them."
  (let ((path (harness-compose--unique-file (harness-compose--downloads-directory)
                                            (harness-compose--name-for-mime (harness-compose--clean-name name) mime)))
        (coding-system-for-write 'binary))
    (with-temp-file path
      (set-buffer-multibyte nil)
      (insert (if (multibyte-string-p bytes) (encode-coding-string bytes 'utf-8 t) bytes)))
    (harness-compose-add-attachment path mime)))

;;;; Dropping

;; What is dropped on a buffer with a box goes to the box, whatever the
;; window it lands on: files attach, links download and attach (or go
;; in as text when they lead to a web page), data: links are decoded,
;; and text is typed into the box rather than into the read-only text
;; around it.  The handlers are buffer-local, so other buffers drop as
;; they always did.  On X a drop also says which types it offers: an
;; image dragged out of a browser offers the image's own address (the
;; link around it is what it drops), and an image with no link at all
;; is taken as its bytes.

(defconst harness-compose--drop-image-types
  '("image/png" "image/jpeg" "image/webp" "image/gif" "image/svg+xml" "image/avif" "image/bmp" "image/tiff")
  "Image types of an X drop taken as the image itself, best first.")

(defconst harness-compose--drop-text-types
  '(("UTF8_STRING" . harness-compose--drop-utf8)
    ("text/plain;charset=UTF-8" . harness-compose--drop-utf8)
    ("text/plain;charset=utf-8" . harness-compose--drop-utf8)
    ("text/unicode" . harness-compose--drop-utf16)
    ("text/plain" . harness-compose--drop-plain)
    ("COMPOUND_TEXT" . harness-compose--drop-ctext)
    ("STRING" . harness-compose--drop-latin-1)
    ("TEXT" . harness-compose--drop-plain)
    ("DndTypeText" . harness-compose--drop-plain))
  "Text types of an X drop, and the functions putting them in the box.")

(defun harness-compose--setup-drops ()
  "Send what is dropped on this buffer to the box (see the Dropping section)."
  (setq-local dnd-protocol-alist
              (append '(("^file:" . harness-compose-dnd-open)
                        ("^\\(?:https?\\|ftps?\\)://" . harness-compose-dnd-download)
                        ("^data:" . harness-compose-dnd-data)
                        ("^blob:" . harness-compose-dnd-blob))
                      (default-value 'dnd-protocol-alist)))
  (when (boundp 'x-dnd-types-alist)
    (setq-local x-dnd-types-alist
                (append (mapcar (lambda (type) (cons type #'harness-compose--drop-image))
                                harness-compose--drop-image-types)
                        harness-compose--drop-text-types
                        (default-value 'x-dnd-types-alist)))
    ;; Images come after links, which name the file, and before text.
    (setq-local x-dnd-known-types
                (let* ((known (default-value 'x-dnd-known-types))
                       (at (or (cl-position-if (lambda (type) (assoc type harness-compose--drop-text-types)) known)
                               (length known))))
                  (append (seq-take known at) harness-compose--drop-image-types (seq-drop known at))))
    (setq-local x-dnd-direct-save-function #'harness-compose--drop-direct-save)))

(defun harness-compose-dnd-download (url action)
  "Download what the link URL dropped on the window leads to, and attach it.
See `harness-compose-download'; a browser's drop of an image inside a
link gets the image (`harness-compose--dropped-media').  Return ACTION."
  (pcase-let ((`(,media . ,name) (harness-compose--dropped-media url)))
    (if (string-prefix-p "data:" media)
        (harness-compose--attach-data-url media)
      (harness-compose-download media name)))
  action)

(defun harness-compose-dnd-data (url action)
  "Attach the data that the data: URL dropped on the window holds; return ACTION."
  (harness-compose--attach-data-url url)
  action)

(defun harness-compose-dnd-blob (_url action)
  "Attach the image a drop of a blob: link offers as data; return ACTION.
The link itself only means something inside the browser."
  (unless (harness-compose--attach-drop-image)
    (message "%s" (substitute-command-keys
                   "A blob: link works only inside the browser: copy the image there, then \\[yank] it here")))
  action)

(defun harness-compose--media-name-p (name)
  "Non-nil when the file NAME names an image, a video or a sound."
  (and name (string-match-p "\\`\\(?:image\\|video\\|audio\\)/" (harness-media-ring-mime name))))

(defun harness-compose--dropped-media (url)
  "Return (ADDRESS . NAME): the media a drop of the link URL is about.
URL itself when it names a media file.  Else what the X drop says the
dragged image is: Firefox's file promise, or the only image of the
drop's HTML (a browser dragging an image inside a link drops the
link).  Else URL.  NAME is the file name the drop suggests, or nil."
  (or (and (harness-compose--media-name-p (harness-http-url-file-name url)) (list url))
      (let ((promise (harness-compose--drop-text "application/x-moz-file-promise-url")))
        (and promise (string-match-p "\\`\\(?:https?\\|ftps?\\|data\\):" promise)
             (cons promise (harness-compose--drop-text "application/x-moz-file-promise-dest-filename"))))
      (let ((src (harness-compose--single-image (harness-compose--drop-text "text/html") url)))
        (and src (list src)))
      (list url)))

(defun harness-compose--drop-types ()
  "Return the types the X drop being handled offers, as strings, or nil."
  (when (and (eq (window-system) 'x) (fboundp 'x-dnd-get-state-for-frame))
    (ignore-errors
      (let ((types (aref (x-dnd-get-state-for-frame (selected-frame)) 2)))
        (and (vectorp types)
             (mapcar (lambda (type) (if (symbolp type) (symbol-name type) type)) types))))))

(defun harness-compose--drop-data (type)
  "Return the data of TYPE that the X drop being handled offers, or nil."
  (when (member type (harness-compose--drop-types))
    (let ((data (ignore-errors (x-get-selection-internal 'XdndSelection (intern type)))))
      (and (stringp data) (> (length data) 0) data))))

(defun harness-compose--drop-text (type)
  "Return the text of TYPE that the X drop being handled offers, or nil."
  (when-let* ((text (harness-media-ring-selection-text (harness-compose--drop-data type))))
    (let ((text (string-trim (car (split-string text "\0")))))
      (and (not (string-empty-p text)) text))))

(defun harness-compose--html-unescape (string)
  "Decode the character references HTML attributes use in STRING."
  (let ((case-fold-search nil))
    (replace-regexp-in-string
     "&\\(amp\\|lt\\|gt\\|quot\\|apos\\|#[0-9]+\\|#x[0-9a-fA-F]+\\);"
     (lambda (m)
       (let ((ref (substring m 1 -1)))
         (pcase ref
           ("amp" "&") ("lt" "<") ("gt" ">") ("quot" "\"") ("apos" "'")
           (_ (string (if (string-prefix-p "#x" ref) (string-to-number (substring ref 2) 16)
                        (string-to-number (substring ref 1))))))))
     string t t)))

(defun harness-compose--single-image (html base)
  "Return the address of the only image in HTML, against BASE, or nil."
  (when html
    (let ((case-fold-search t) (srcs nil) (start 0))
      (while (string-match "<img\\b[^>]*?[ \t\r\n]src[ \t\r\n]*=[ \t\r\n]*\\(?:\"\\([^\"]*\\)\"\\|'\\([^']*\\)'\\|\\([^ \t\r\n>]+\\)\\)"
                           html start)
        (push (or (match-string 1 html) (match-string 2 html) (match-string 3 html)) srcs)
        (setq start (match-end 0)))
      (setq srcs (delete-dups srcs))
      (when (= 1 (length srcs))
        (let ((src (harness-compose--html-unescape (string-trim (car srcs)))))
          (cond ((string-match-p "\\`\\(?:https?\\|ftps?\\|data\\):" src) src)
                ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" src) nil)
                ((string-empty-p src) nil)
                (t (require 'url-expand)
                   (ignore-errors (url-expand-file-name src base)))))))))

(defun harness-compose--attach-data-url (url)
  "Attach the data that the data: link URL holds."
  (if (not (string-match "\\`data:\\([^,;]*\\)\\(?:;[^,;]*\\)*?\\(;base64\\)?," url))
      (message "Not a data: link")
    (let* ((mime (downcase (string-trim (match-string 1 url))))
           (base64 (match-beginning 2))
           (payload (harness-http-unhex-bytes (substring url (match-end 0))))
           (bytes (if base64
                      (ignore-errors (base64-decode-string (replace-regexp-in-string "[ \t\r\n]+" "" payload)))
                    payload)))
      (if (not bytes)
          (message "The data: link holds no valid data")
        (harness-compose--attach-bytes bytes (if (string-empty-p mime) "text/plain" mime) "dropped")))))

(defun harness-compose--attach-drop-image ()
  "Attach the image the X drop being handled offers as data; non-nil if it did."
  (when-let* ((type (cl-find-if (lambda (type) (member type (harness-compose--drop-types)))
                                harness-compose--drop-image-types))
              (data (harness-compose--drop-data type)))
    (harness-compose--attach-bytes data type "dropped")
    t))

(defun harness-compose--drop-image (window action data)
  "Attach the image DATA dropped on WINDOW, of the drop's type; return ACTION."
  (when (and (windowp window) (stringp data) (> (length data) 0))
    (with-current-buffer (window-buffer window)
      (harness-compose--attach-bytes data (or (ignore-errors (x-dnd-current-type window)) "image/png") "dropped")))
  action)

(defun harness-compose--drop-insert (window action text)
  "Put TEXT dropped on WINDOW in the box; return ACTION.
Where it was dropped when that is in the box, else at its end."
  (when (and (windowp window) (stringp text))
    (with-selected-window window
      (when (harness-compose-live-p)
        (unless (harness-compose-in-p) (goto-char harness-compose-end))
        (insert (string-replace "\r\n" "\n" text)))))
  action)

(defun harness-compose--drop-utf8 (window action data)
  "Put the UTF-8 text DATA dropped on WINDOW in the box; return ACTION."
  (harness-compose--drop-insert window action (decode-coding-string data 'utf-8)))

(defun harness-compose--drop-utf16 (window action data)
  "Put the UTF-16 text DATA dropped on WINDOW in the box; return ACTION."
  (harness-compose--drop-insert window action
                                (decode-coding-string data (if (eq (byteorder) ?B) 'utf-16be 'utf-16le))))

(defun harness-compose--drop-ctext (window action data)
  "Put the compound text DATA dropped on WINDOW in the box; return ACTION."
  (harness-compose--drop-insert window action (decode-coding-string data 'compound-text-with-extensions)))

(defun harness-compose--drop-latin-1 (window action data)
  "Put the Latin-1 text DATA dropped on WINDOW in the box; return ACTION."
  (harness-compose--drop-insert window action
                                (if (multibyte-string-p data) data (decode-coding-string data 'latin-1))))

(defun harness-compose--drop-plain (window action data)
  "Put the text DATA dropped on WINDOW in the box; return ACTION."
  (harness-compose--drop-insert window action (harness-media-ring-selection-text data)))

(defun harness-compose--drop-direct-save (need-name filename)
  "Save a file dropped by X direct save among the downloads, then attach it.
NEED-NAME non-nil asks where to save FILENAME; nil says it is saved
there, which is when it is attached."
  (if need-name
      (harness-compose--unique-file (harness-compose--downloads-directory) (harness-compose--clean-name filename))
    (harness-compose-add-attachment filename)))

;;;; The clipboard and the media ring

(defun harness-compose--attach-captures (atts &optional quiet)
  "Attach ATTS, captures or copied files, and redraw.
Return the paths of those that were not attached before.  QUIET keeps
the message to the caller."
  (let ((added (delq nil (mapcar (lambda (a) (and (harness-compose--attach a) (plist-get a :path))) atts))))
    (harness-compose-redraw)
    (unless quiet
      (message "Attached %s" (mapconcat (lambda (a) (plist-get a :name)) atts ", ")))
    added))

(defun harness-compose--yank-media-image (type data)
  "Attach the image DATA, of TYPE, that `yank-media' took off the clipboard."
  (harness-compose--attach-captures (list (harness-media-ring-save data (symbol-name type)))))

(defun harness-compose-attach-from-ring ()
  "Attach an earlier capture of the media ring, chosen by name."
  (interactive)
  (let ((entries (harness-media-ring-entries)))
    (unless entries
      (user-error "%s" (substitute-command-keys "The media ring is empty: copy an image, then \\[yank] it here")))
    (let* ((choices (mapcar (lambda (e) (cons (harness-media-ring-describe e) e)) entries))
           (table (lambda (string pred action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity) (cycle-sort-function . identity))
                      (complete-with-action action choices string pred))))
           (choice (completing-read "Attach from the media ring: " table nil t)))
      (harness-compose--attach-captures (list (cdr (assoc choice choices)))))))

(defun harness-compose--underlying (command)
  "Return what runs for COMMAND in this buffer, but for the box's remapping."
  (or (command-remapping command) command))

(defun harness-compose--yank-text (command)
  "Run COMMAND, `yank' or `yank-pop', as it runs without the box's remapping.
A region in the box goes first in `delete-selection-mode', as a yank
of text replaces it."
  (let ((cmd (harness-compose--underlying command)))
    (when (eq command 'yank)
      (if (and (bound-and-true-p delete-selection-mode) (use-region-p)
               (harness-compose-in-p (region-beginning)) (harness-compose-in-p (region-end)))
          (delete-region (region-beginning) (region-end))
        (when (and (harness-compose-live-p) (not (harness-compose-in-p)))
          (goto-char harness-compose-end))))
    (setq this-command cmd)
    (call-interactively cmd)))

(defun harness-compose--clipboard-media ()
  "Return the attachments a yank should add from the clipboard, or nil.
The image on the clipboard, captured on the media ring, else the files
a file manager copied.  Those attached already do not count, so
yanking again yanks text."
  (when-let* ((targets (and harness-compose-yank-media (harness-compose-live-p)
                            (harness-media-ring-clipboard-targets))))
    (let ((image (harness-media-ring-capture-image targets)))
      (if image
          (unless (harness-compose--attached-p (plist-get image :path)) (list image))
        (mapcar #'harness-compose--file-attachment
                (cl-remove-if #'harness-compose--attached-p (harness-media-ring-clipboard-files targets)))))))

(defun harness-compose-yank (&optional arg)
  "Attach the image or the files on the clipboard, else yank text.
See `harness-compose-yank-media'.  The image goes on the media ring,
which \\[yank-pop] right after goes back through.  With ARG, yank as
`yank' does, whatever the clipboard holds."
  (interactive "*P")
  (let ((media (and (not arg) (harness-compose--clipboard-media))))
    (if (not media)
        (harness-compose--yank-text 'yank)
      (let ((added (harness-compose--attach-captures media))
            (head (car (harness-media-ring-entries))))
        (setq harness-compose--yanked
              (list :paths added
                    :index (if (and head (equal (plist-get head :path) (plist-get (car media) :path))) 0 -1))
              this-command 'harness-compose-yank)))))

(defun harness-compose-yank-pop (&optional n)
  "Swap the media just yanked for an earlier capture of the media ring.
Each press goes one further back (N further with a numeric prefix
argument), its thumbnail showing in the box.  Right after anything but
a yank of media, run `yank-pop' as it runs without the box."
  (interactive "p")
  (if (not (and (eq last-command 'harness-compose-yank) harness-compose--yanked))
      (harness-compose--yank-text 'yank-pop)
    (let ((entries (harness-media-ring-entries)))
      (unless entries (user-error "The media ring is empty"))
      (let* ((index (mod (+ (plist-get harness-compose--yanked :index) (or n 1)) (length entries)))
             (entry (nth index entries))
             (gone (plist-get harness-compose--yanked :paths)))
        (setq harness-compose-attachments
              (cl-remove-if (lambda (a) (member (plist-get a :path) gone)) harness-compose-attachments))
        (setq harness-compose--yanked (list :paths (harness-compose--attach-captures (list entry) t) :index index)
              this-command 'harness-compose-yank)
        (message "Media ring %d/%d: %s%s" (1+ index) (length entries) (plist-get entry :name)
                 (if (= 1 (length entries)) " (the only capture)" ""))))))

;;;; Completion

;;;; Completing as you type

;; Completion UIs that pop up as you type (corfu with `corfu-auto',
;; company) wait a moment after a key, then give up when the buffer
;; changed meanwhile.  Hosts change all the time -- a chat streams its
;; reply, a task board follows its tasks -- so the popup for an @file or
;; /skill token rarely showed.  Once the token stops changing, the box
;; asks them again, ignoring changes outside it.

(defvar corfu-auto)
(defvar corfu-auto-delay)
(defvar company-idle-delay)
(defvar company-candidates)
(declare-function corfu-auto--complete-deferred "corfu-auto")
(declare-function corfu--auto-complete-deferred "corfu")
(declare-function company-idle-begin "company")

(defun harness-compose--token ()
  "Return the @file or /skill token before point as (OFFSET . TEXT), or nil.
TEXT starts with the sigil.  OFFSET is point's distance from the start
of the box, which a host's redraws move."
  (when-let* ((bounds (or (harness-compose--capf-bounds ?@)
                          (let ((skill (harness-compose--capf-bounds ?/)))
                            (and skill (= (1- (car skill)) harness-compose-start) skill)))))
    (cons (- (point) harness-compose-start)
          (buffer-substring-no-properties (1- (car bounds)) (cdr bounds)))))

(defun harness-compose--corfu-delay ()
  "Seconds corfu waits before popping up in this buffer, or nil if it does not."
  (and (bound-and-true-p corfu-mode) (bound-and-true-p corfu-auto)
       (let ((delay (bound-and-true-p corfu-auto-delay))) (if (numberp delay) delay 0))))

(defun harness-compose--company-delay ()
  "Seconds company waits before popping up in this buffer, or nil if it does not."
  (and (bound-and-true-p company-mode) (boundp 'company-idle-delay)
       (let ((delay (if (functionp company-idle-delay) (funcall company-idle-delay) company-idle-delay)))
         (cond ((numberp delay) delay) (delay 0)))))

(defun harness-compose--popup ()
  "Ask the completion UIs that pop up by themselves to complete at point.
Only a UI that is not showing already is asked."
  (when (and (harness-compose--corfu-delay) (not completion-in-region-mode))
    (cond ((fboundp 'corfu-auto--complete-deferred) (corfu-auto--complete-deferred))
          ((fboundp 'corfu--auto-complete-deferred) (corfu--auto-complete-deferred))))
  (when (and (harness-compose--company-delay) (not (bound-and-true-p company-candidates))
             (fboundp 'company-idle-begin))
    ;; The tick and position it checks are the ones of now.
    (company-idle-begin (current-buffer) (selected-window) (buffer-chars-modified-tick) (point))))

(defun harness-compose--popup-later (&optional delay)
  "Ask the completion UIs for the token at point after DELAY seconds.
DELAY defaults to just after the UIs' own wait, so that they show the
popup themselves when nothing changed the buffer.  Nothing happens
without a token at point or a UI that pops up by itself."
  (when-let* ((wait (let ((delays (delq nil (list (harness-compose--corfu-delay)
                                                  (harness-compose--company-delay)))))
                      (and delays (apply #'max delays))))
              (token (and (harness-compose-live-p) (harness-compose--token))))
    (when harness-compose--popup-timer (cancel-timer harness-compose--popup-timer))
    (setq harness-compose--popup-timer
          (run-at-time (or delay (+ wait 0.05)) nil #'harness-compose--popup-if-unchanged
                       (current-buffer) token))))

(defun harness-compose--popup-if-unchanged (buffer token)
  "Ask the completion UIs to complete TOKEN, if it is still at point in BUFFER.
BUFFER must be the selected window's, with no input waiting."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq harness-compose--popup-timer nil)
      (when (and (eq (window-buffer (selected-window)) buffer)
                 (not (input-pending-p))
                 (harness-compose-live-p)
                 (equal token (harness-compose--token)))
        (condition-case err
            (harness-compose--popup)
          (error (harness-log 'warn "compose: completion popup failed: %S" err)))))))

(defun harness-compose--after-command ()
  "Ask the completion UIs again once the token at point stops changing.
Runs from `post-command-hook'."
  (when harness-compose--popup-timer
    (cancel-timer harness-compose--popup-timer)
    (setq harness-compose--popup-timer nil))
  (condition-case err
      (let ((token (and (harness-compose-live-p) (harness-compose--token))))
        (when (and token (not (equal token harness-compose--last-token)))
          (harness-compose--popup-later))
        (setq harness-compose--last-token token))
    (error (harness-log 'warn "compose: following the token failed: %S" err))))

;; Boxes set up before a reload follow their tokens too.
(dolist (buf (buffer-list))
  (with-current-buffer buf
    (when (memq #'harness-compose-completion-at-point completion-at-point-functions)
      (add-hook 'post-command-hook #'harness-compose--after-command nil t))))

(add-to-list 'completion-category-defaults '(harness-compose-file (styles flex)))
(add-to-list 'completion-category-defaults '(harness-compose-skill (styles basic flex)))

(harness-define-module 'ui-compose
  :doc "The compose box shared by chat buffers and the task board."
  :requires '(ui))

(provide 'harness-ui-compose)
;;; harness-ui-compose.el ends here
