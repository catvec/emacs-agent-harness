;;; harness-ui-compose.el --- The compose box shared by harness buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; The editable box at the bottom of a chat buffer and of the task
;; board.  A host buffer calls `harness-compose-setup' once from its
;; major mode, then `harness-compose-insert' wherever it draws the box
;; (after making everything before it read-only).  The box gives:
;;
;;   - multi-line editing: RET and C-j insert a newline, typing outside
;;     the box jumps into it, a placeholder shows while it is empty;
;;   - @file completion over the project's files (each completed file
;;     becomes an attachment) and /skill completion at its start;
;;   - attachments: C-c C-a picks a file, C-c C-v pastes the clipboard
;;     (images and other MIME types), files dropped on the window attach;
;;   - the text and attachments, kept across redraws of the host;
;;   - optionally, the box at the bottom of the window: a buffer shorter
;;     than its window is padded at the top so it ends on the last line.
;;
;; Hosts read the box with `harness-compose-text' and
;; `harness-compose-take', expand /skill references with
;; `harness-compose-with-expanded-text' and turn attachments into ACP
;; prompt blocks with `harness-compose-attachment-block'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'mailcap)
(require 'dnd)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

;;;; State

(defvar-local harness-compose-start nil "Marker: first character of the compose box.")
(defvar-local harness-compose-end nil "Marker: after the last character of the compose box.")
(defvar-local harness-compose-overlay nil "Overlay over the prompt and the box.")
(defvar-local harness-compose-attachments nil "Attachments for the next message.")
(defvar-local harness-compose--placeholder nil "Overlay showing the placeholder.")
(defvar-local harness-compose--text "" "The box's text, kept across redraws.")
(defvar-local harness-compose--files nil "Project files for @ completion.")
(defvar-local harness-compose--skills nil "Skill names for / completion.")
(defvar-local harness-compose--pads nil "Window -> overlay padding the buffer so the box sits at the bottom.")
(defvar-local harness-compose--pad-at nil "Function returning where the padding goes, or nil for the top.")
(defvar-local harness-compose--files-at nil "Start of the @ token whose completion last refreshed the files.")

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
  (define-key map (kbd "C-c C-v") #'harness-compose-attach-clipboard))

(cl-defun harness-compose-setup (&key project placeholder redraw bottom)
  "Make this buffer host a compose box.
PROJECT returns the project root, PLACEHOLDER the hint for the empty
box, REDRAW redraws the box (it must call `harness-compose-insert').
With BOTTOM the box sits at the bottom of every window showing the
buffer, the way a chat app keeps its input there: t pads the top of a
short buffer, a function returning a position pads there instead (a
board above the box stays at the top, the gap opens below it)."
  (when bottom
    (setq harness-compose--pad-at (and (functionp bottom) bottom))
    (add-hook 'pre-redisplay-functions #'harness-compose-pad-window nil t))
  (when project (setq harness-compose-project-function project))
  (when placeholder (setq harness-compose-placeholder-function placeholder))
  (when redraw (setq harness-compose-redraw-function redraw))
  (setq-local hl-line-range-function #'harness-compose-hl-line-range)
  (setq-local dnd-protocol-alist (cons '("^file:" . harness-compose-dnd-open) dnd-protocol-alist))
  (add-hook 'completion-at-point-functions #'harness-compose-completion-at-point nil t)
  (add-hook 'pre-command-hook #'harness-compose--pre-command nil t)
  (add-hook 'post-command-hook #'harness-compose-update-placeholder nil t))

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
  "Insert the attachment chips at point (nothing without attachments)."
  (when harness-compose-attachments
    (insert " " (propertize (harness-ui-icon 'harness-icon-attach) 'face 'harness-dim-face) " ")
    (dolist (att harness-compose-attachments)
      (let* ((path (plist-get att :path))
             (label (format "%s (%s)"
                            (harness-truncate-middle (harness-relative-path (harness-compose--project) path) 40)
                            (harness-format-bytes (plist-get att :size)))))
        (insert (buttonize label (lambda (_) (find-file-other-window path)) nil
                           (concat path "\nmouse-1: open"))
                (propertize (buttonize "×" (lambda (_) (harness-compose-remove-attachment path)) nil
                                       "Remove this attachment")
                            'face 'harness-dim-face)
                "  ")))
    (insert "\n")))

(defun harness-compose-insert (&optional text help)
  "Insert the prompt and the box at point, holding TEXT or the kept text.
HELP is the prompt's tooltip.  Point ends after the box's final newline."
  (dolist (ov (list harness-compose-overlay harness-compose--placeholder))
    (when ov (delete-overlay ov)))
  (when text (setq harness-compose--text text))
  (let ((label-start (point)))
    (insert (propertize "❯ " 'face '(harness-dim-face harness-compose-face) 'help-echo help
                        'read-only t 'rear-nonsticky t))
    (setq harness-compose-start (copy-marker (point)))
    (insert harness-compose--text)
    (let ((end (point)))
      (insert (propertize "\n" 'read-only t))
      (setq harness-compose-end (copy-marker end t)))
    ;; FRONT-ADVANCE: text the host inserts just before the box stays outside.
    (setq harness-compose-overlay (make-overlay label-start (point) nil t t))
    (overlay-put harness-compose-overlay 'face 'harness-compose-face)
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
                                  'face '(harness-dim-face harness-compose-face) 'cursor t)))))

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
  (when (and (memq this-command '(self-insert-command yank))
             (harness-compose-live-p)
             (not (harness-compose-in-p)))
    (goto-char harness-compose-end)))

(defun harness-compose-pad-window (window)
  "Pad WINDOW so a buffer shorter than it ends at its bottom.
Runs from `pre-redisplay-functions'; each window gets its own overlay."
  (when (and (window-live-p window) (eq (window-buffer window) (current-buffer))
             (harness-compose-live-p))
    (setq harness-compose--pads
          (cl-remove-if-not (lambda (p) (and (window-live-p (car p)) (overlay-buffer (cdr p))
                                             (eq (window-buffer (car p)) (current-buffer))))
                            harness-compose--pads))
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
        ;; Leave a line for the empty one after the box, where a host
        ;; following the end puts the bottom of the window.
        (let* ((line (frame-char-height (window-frame window)))
               (used (cdr (window-text-pixel-size window (point-min) harness-compose-end nil body)))
               (lines (/ (- body used line) line)))
          (when (and (= (window-start window) (point-min)) (> lines 0))
            (overlay-put ov 'before-string (make-string lines ?\n))))))))

(defun harness-compose-repad (window)
  "Drop WINDOW's padding so the next redisplay sizes it again.
A host about to scroll WINDOW calls this first: `recenter' would count
the padding as lines to keep in view."
  (when-let* ((pad (alist-get window harness-compose--pads)))
    (overlay-put pad 'before-string nil)
    (overlay-put pad 'harness-compose-key nil)))

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
  (setq harness-compose-attachments nil)
  (funcall harness-compose-redraw-function))

(defun harness-compose-take ()
  "Return (TEXT . ATTACHMENTS) from the box, or signal when both are empty."
  (let ((text (string-trim (harness-compose-text)))
        (atts harness-compose-attachments))
    (when (and (string-empty-p text) (null atts)) (user-error "Nothing to send"))
    (cons text atts)))

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

;;;; Attachments

(defun harness-compose--mime-of (path)
  "Return the MIME type of PATH."
  (or (mailcap-extension-to-mime (file-name-extension path t)) "application/octet-stream"))

(defun harness-compose-add-attachment (path &optional mime)
  "Attach the file PATH (with MIME) to the next message."
  (interactive (list (read-file-name "Attach file: " (harness-compose--project) nil t)))
  (let ((path (expand-file-name path)))
    (unless (cl-find path harness-compose-attachments :key (lambda (a) (plist-get a :path)) :test #'equal)
      (setq harness-compose-attachments
            (append harness-compose-attachments
                    (list (list :path path :size (or (harness-file-size path) 0)
                                :mime (or mime (harness-compose--mime-of path))
                                :name (file-name-nondirectory path))))))
    (funcall harness-compose-redraw-function)
    (message "Attached %s" (abbreviate-file-name path))))

(defun harness-compose-remove-attachment (path)
  "Remove the attachment PATH."
  (interactive (list (completing-read "Remove attachment: "
                                      (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments) nil t)))
  (setq harness-compose-attachments
        (cl-remove path harness-compose-attachments :key (lambda (a) (plist-get a :path)) :test #'equal))
  (funcall harness-compose-redraw-function))

(defun harness-compose--clips-directory ()
  "Return the directory where clipboard captures are saved."
  (harness-ensure-directory
   (expand-file-name "clips/" (if (boundp 'harness-state-directory) harness-state-directory
                                (locate-user-emacs-file "harness/")))))

(defun harness-compose--save-clip (data extension)
  "Write DATA (a unibyte string) to a new file with EXTENSION; return its path."
  (let ((path (expand-file-name (format "clip-%s.%s" (format-time-string "%Y%m%d-%H%M%S") extension)
                                (harness-compose--clips-directory)))
        (coding-system-for-write 'binary))
    (with-temp-file path (set-buffer-multibyte nil) (insert data))
    path))

(defun harness-compose-attach-clipboard ()
  "Attach the clipboard: an image when it holds one, else a chosen MIME target.
Plain text is inserted into the box."
  (interactive)
  (unless (display-graphic-p) (user-error "The clipboard needs a graphical display"))
  (let ((png (ignore-errors (gui-get-selection 'CLIPBOARD 'image/png))))
    (if (and png (> (length png) 0))
        (harness-compose-add-attachment (harness-compose--save-clip png "png") "image/png")
      (let* ((targets (ignore-errors (append (gui-get-selection 'CLIPBOARD 'TARGETS) nil)))
             (mimes (cl-remove-if-not (lambda (s) (string-match-p "\\`[a-z]+/" (symbol-name s))) targets)))
        (if (null mimes)
            (let ((text (ignore-errors (gui-get-selection 'CLIPBOARD 'UTF8_STRING))))
              (if (and text (not (string-empty-p text)))
                  (progn (unless (harness-compose-in-p) (goto-char harness-compose-end))
                         (insert text))
                (user-error "Nothing usable in the clipboard")))
          (let* ((choice (intern (completing-read "Clipboard type: " (mapcar #'symbol-name mimes) nil t)))
                 (data (gui-get-selection 'CLIPBOARD choice))
                 (mime (symbol-name choice))
                 (ext (string-remove-prefix
                       "." (or (car (rassoc mime mailcap-mime-extensions))
                               (cadr (split-string mime "/"))))))
            (harness-compose-add-attachment
             (harness-compose--save-clip (if (multibyte-string-p data) (encode-coding-string data 'utf-8) data) ext)
             mime)))))))

(defun harness-compose-dnd-open (uri action)
  "Attach the file dropped as URI; ACTION is returned unchanged."
  (when-let* ((path (dnd-get-local-file-name uri t)))
    (harness-compose-add-attachment path))
  action)

;;;; Completion

(defun harness-compose-fetch-files ()
  "Refresh the files @ completes from the project's file list.
Listed here, not by the harness process, so it is this Emacs's
projectile cache (cleared by `projectile-invalidate-cache') that answers;
a miss lists asynchronously.  On failure the previous list is kept."
  (let ((buf (current-buffer)))
    (harness-then (harness-files-list-limited (harness-compose--project) nil 20000)
                  (lambda (files) (when (buffer-live-p buf) (with-current-buffer buf (setq harness-compose--files files))))
                  (lambda (err) (harness-log 'warn "compose: listing project files failed: %s" (harness-error-message err))))))

(defun harness-compose-fetch-completions ()
  "Prefetch project files and skill names for completion."
  (let ((buf (current-buffer)))
    (harness-compose-fetch-files)
    (harness-ui-call "_harness/skills/list" (list :cwd (harness-compose--project))
                     (lambda (skills)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-compose--skills (mapcar (lambda (s) (plist-get s :name)) skills)))))
                     #'ignore)))

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

(defun harness-compose--table (candidates category)
  "Return a completion table over CANDIDATES with CATEGORY metadata."
  (lambda (string pred action)
    (if (eq action 'metadata)
        (list 'metadata (cons 'category category))
      (complete-with-action action candidates string pred))))

(defun harness-compose-completion-at-point ()
  "Complete @files and /skills in the box."
  (let ((file (harness-compose--capf-bounds ?@))
        (skill (harness-compose--capf-bounds ?/))
        (root (harness-compose--project)))
    (cond
     (file
      ;; A new @ token refreshes the list, so files created since the
      ;; buffer opened show up from the next keystroke on.
      (unless (eql (car file) harness-compose--files-at)
        (setq harness-compose--files-at (car file))
        (harness-compose-fetch-files))
      (list (car file) (cdr file)
            (harness-compose--table harness-compose--files 'harness-compose-file)
            :exclusive 'no
            :exit-function
            (lambda (str status)
              (when (memq status '(finished sole))
                (let ((end (point)))
                  (delete-region (- end (length str) 1) end)
                  (harness-compose-add-attachment (expand-file-name str root)))))))
     ((and skill (= (1- (car skill)) harness-compose-start))
      (list (car skill) (cdr skill)
            (harness-compose--table harness-compose--skills 'harness-compose-skill)
            :exclusive 'no
            :exit-function (lambda (_str status) (when (memq status '(finished sole)) (insert " "))))))))

(add-to-list 'completion-category-defaults '(harness-compose-file (styles flex)))
(add-to-list 'completion-category-defaults '(harness-compose-skill (styles basic flex)))

(harness-define-module 'ui-compose
  :doc "The compose box shared by chat buffers and the task board."
  :requires '(ui))

(provide 'harness-ui-compose)
;;; harness-ui-compose.el ends here
