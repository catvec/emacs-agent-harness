;;; harness-ui-drag.el --- Drag images out of Emacs into other applications  -*- lexical-binding: t; -*-

;;; Commentary:

;; The images the harness shows can be dragged out of Emacs into another
;; application -- a file manager, a browser, a chat app -- as a file:
;; those of the transcript, the attachments of the compose box, and
;; those of reports and their popouts.  `harness-ui-drag-source' makes a
;; string draggable and `harness-ui-drag-region' a stretch of buffer
;; text.  Each lays `harness-ui-drag-map' over the keymap the text
;; already has, so that down-mouse-1 there runs `harness-ui-drag-start',
;; and adds a word about it to the hover text.
;;
;; That command follows the mouse while the button is down.  A release
;; before the mouse moved `harness-ui-drag-threshold' pixels is a click:
;; the release is put back and does what mouse-1 does there (opens the
;; image, shows it larger...).  Moved further, it is a drag:
;; `dnd-begin-file-drag' hands the file to the window system, which
;; gives it to the application the button is released over.  A drop
;; back on the frame the drag started from does nothing, so letting go
;; over Emacs again cancels it.
;;
;; A file on disk is dragged as it is.  An image held only in memory,
;; such as one pasted into a message (it travels as base64 data), is
;; first written to the temporary directory of the buffer's session
;; (session/tmp-dir), as image-SHA.EXT where SHA starts the SHA-1 of its
;; bytes, so dragging it again writes nothing.  The UI asks the harness
;; for that directory ahead of time, when it draws such an image, and
;; never waits for the answer: until it is in, and in a buffer of no
;; session, the image goes to a private directory of this Emacs, which
;; is deleted when Emacs exits.
;;
;; Emacs starts drags on X, macOS and Haiku (`x-begin-drag').  Elsewhere
;; nothing is made draggable, nor is a file on another host: dragging it
;; would copy it here while the UI waits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dnd)
(require 'image)

(defvar harness-ui-session-id)
(defvar harness-ui-connection)
(declare-function harness-ui-call "harness-ui")
(declare-function harness-acp-open-p "harness-acp")

(defcustom harness-ui-drag-threshold 6
  "Pixels the mouse moves with the button down before a press is a drag.
A press on a draggable image that is released before the mouse moved
that far is a click."
  :type 'natnum :group 'harness-ui)

(defconst harness-ui-drag-hint "drag: drop it into another application"
  "What the hover text of something draggable adds about dragging it.")

(defvar-keymap harness-ui-drag-map
  :doc "Keymap laid over draggable text: pressing mouse-1 there starts a drag."
  "<down-mouse-1>" #'harness-ui-drag-start)

(defun harness-ui-drag-available-p ()
  "Non-nil when this Emacs can drag files out to other applications."
  (fboundp 'x-begin-drag))

(defun harness-ui-drag--frame-p (frame)
  "Non-nil when a drag can start from FRAME: a graphical frame that can drag."
  (and (harness-ui-drag-available-p) (frame-live-p frame) (display-graphic-p frame)))

(defun harness-ui-drag--local-p (file)
  "Non-nil unless FILE names a file on another host."
  (not (and (stringp file) (file-remote-p file))))

;;;; Making text draggable

(defun harness-ui-drag--layered-p (map)
  "Non-nil when keymap MAP is `harness-ui-drag-map' or has it laid over."
  (or (eq map harness-ui-drag-map)
      (and (keymapp map) (memq harness-ui-drag-map (cdr-safe map)) t)))

(defun harness-ui-drag--apply (start end object file)
  "Make START..END of OBJECT draggable as FILE (nil: the image shown there).
OBJECT is a string, or nil for the current buffer."
  (put-text-property start end 'harness-ui-drag (or file t) object)
  (let ((pos start))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'keymap object end))
            (map (get-text-property pos 'keymap object)))
        (unless (harness-ui-drag--layered-p map)
          (put-text-property pos next 'keymap
                             (if map (make-composed-keymap (list harness-ui-drag-map map)) harness-ui-drag-map)
                             object))
        (setq pos next))))
  (let ((pos start))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'help-echo object end))
            (help (get-text-property pos 'help-echo object)))
        (cond ((null help) (put-text-property pos next 'help-echo harness-ui-drag-hint object))
              ((and (stringp help) (not (string-suffix-p harness-ui-drag-hint help)))
               (put-text-property pos next 'help-echo (concat help "; " harness-ui-drag-hint) object)))
        (setq pos next)))))

(defun harness-ui-drag-source (string &optional file)
  "Return STRING made draggable out of Emacs, as FILE or as the image it shows.
FILE is what a drag hands over: a local file name, or a function
returning one when the drag starts.  Without FILE it is the image
STRING displays, its file or, for an image held in memory, a file its
bytes are written to (`harness-ui-drag-image-file').  STRING gets
`harness-ui-drag-map' over the keymaps it has, so pressing mouse-1 on it
and moving the mouse drags it while a click does what it did, and its
hover text says so.  STRING comes back unchanged when this Emacs cannot
drag, or FILE is on another host."
  (if (not (and (harness-ui-drag-available-p) (harness-ui-drag--local-p file)
                (stringp string) (> (length string) 0)))
      string
    (let ((s (copy-sequence string)))
      (harness-ui-drag--apply 0 (length s) s file)
      (unless file (harness-ui-drag-prefetch))
      s)))

(defun harness-ui-drag-region (start end &optional file)
  "Make START..END of the current buffer draggable, as FILE or the image there.
The same as `harness-ui-drag-source' does to a string."
  (when (and (harness-ui-drag-available-p) (harness-ui-drag--local-p file) (< start end))
    (let ((inhibit-read-only t))
      (harness-ui-drag--apply start end nil file))
    (unless file (harness-ui-drag-prefetch))))

;;;; Pressing and dragging

(defun harness-ui-drag--property (posn prop)
  "Return the PROP of what the mouse position POSN is on, string or buffer text."
  (let ((str (posn-string posn))
        (window (posn-window posn))
        (pos (posn-point posn)))
    (or (and (stringp (car-safe str)) (natnump (cdr str)) (< (cdr str) (length (car str)))
             (get-text-property (cdr str) prop (car str)))
        (and (windowp window) (window-live-p window) (integer-or-marker-p pos)
             (with-current-buffer (window-buffer window)
               (get-char-property pos prop window))))))

(defun harness-ui-drag--session (window)
  "Return the session id of the buffer WINDOW shows, or nil."
  (and (windowp window) (window-live-p window)
       (with-current-buffer (window-buffer window)
         (and (boundp 'harness-ui-session-id) harness-ui-session-id))))

(defun harness-ui-drag--moved-p (start now)
  "Non-nil when the mouse at NOW is far enough from where it was pressed, START.
That is `harness-ui-drag-threshold' pixels away, or in another window
or another part of it."
  (let ((a (posn-x-y start))
        (b (posn-x-y now)))
    (or (not (eq (posn-window start) (posn-window now)))
        (not (eq (posn-area start) (posn-area now)))
        (not (and (consp a) (consp b) (numberp (car a)) (numberp (car b))))
        (>= (max (abs (- (car b) (car a))) (abs (- (cdr b) (cdr a))))
            harness-ui-drag-threshold))))

(defun harness-ui-drag--as-click (event start)
  "Return EVENT, which ended a press at START short of a drag, to read again.
A release after the mouse moved a little is a `drag-mouse-1': it comes
back as the click it was meant as, at START."
  (if (eq (car-safe event) 'drag-mouse-1)
      (list 'mouse-1 start 1)
    event))

(defun harness-ui-drag--track (start)
  "Follow the mouse pressed at START until it is dragged or released.
Return non-nil when it moved far enough with the button still down
\(`harness-ui-drag--moved-p').  Otherwise put the event that ended the
press back to be read again, as a click when it was a release, and
return nil."
  (let ((mouse-fine-grained-tracking t)
        (state nil))
    (track-mouse
      ;; Keep the pointer's shape, and report motion relative to this frame.
      (setq track-mouse 'dragging)
      (while (not state)
        (let ((event (read-event)))
          (cond
           ((mouse-movement-p event)
            (when (harness-ui-drag--moved-p start (event-start event))
              (setq state 'drag)))
           ((memq (car-safe event) '(select-window switch-frame help-echo)))
           (t (push (harness-ui-drag--as-click event start) unread-command-events)
              (setq state 'click))))))
    (eq state 'drag)))

(defun harness-ui-drag--file (source posn)
  "Return the local file to drag for SOURCE, pressed at POSN, or nil.
SOURCE is a file name, a function returning one, or t for the image
displayed at POSN."
  (let ((file (cond ((stringp source) source)
                    ((functionp source) (funcall source))
                    (t (when-let* ((image (harness-ui-drag--image-at posn)))
                         (harness-ui-drag-image-file image (harness-ui-drag--session (posn-window posn))))))))
    (and (stringp file) (not (file-remote-p file)) (file-exists-p file)
         (expand-file-name file))))

(defun harness-ui-drag-start (event)
  "Drag the image under the mouse out of Emacs, or click it.
EVENT is the press of mouse-1 on something `harness-ui-drag-source' or
`harness-ui-drag-region' made draggable.  Moving the mouse
`harness-ui-drag-threshold' pixels with the button down drags its file
into the application it is released over; a drop back on this frame
does nothing.  Released sooner, it is a click, and does what mouse-1
does there."
  (interactive "e")
  (let* ((start (event-start event))
         (window (posn-window start))
         (frame (if (windowp window) (window-frame window) (selected-frame)))
         (source (harness-ui-drag--property start 'harness-ui-drag)))
    ;; What pressing mouse-1 does anywhere else (`mouse-drag-region'):
    ;; select the window and put point where it was pressed.
    (run-hooks 'mouse-leave-buffer-hook)
    (deactivate-mark)
    (ignore-errors (mouse-set-point event))
    (when (and source (harness-ui-drag--frame-p frame))
      (unless (stringp source)
        (harness-ui-drag-prefetch (harness-ui-drag--session window)))
      (when (harness-ui-drag--track start)
        (condition-case err
            (if-let* ((file (harness-ui-drag--file source start)))
                (dnd-begin-file-drag file frame 'copy nil)
              (message "Harness: there is no file to drag here"))
          (error (message "Harness: could not drag the image: %s" (error-message-string err))))))))

;;;; Images and their files

(defun harness-ui-drag--image-in (display)
  "Return the image descriptor in the display spec DISPLAY, or nil."
  (cond ((eq (car-safe display) 'image) display)
        ((vectorp display) (cl-some #'harness-ui-drag--image-in display))
        ((consp display)
         (let ((found nil))
           (while (and (consp display) (not found))
             (setq found (harness-ui-drag--image-in (car display))
                   display (cdr display)))
           found))))

(defun harness-ui-drag--image-at (posn)
  "Return the image descriptor shown at the mouse position POSN, or nil."
  (or (harness-ui-drag--image-in (posn-image posn))
      (harness-ui-drag--image-in (harness-ui-drag--property posn 'display))))

(defun harness-ui-drag--extension (image)
  "Return the file name extension for the image descriptor IMAGE."
  (let* ((data (image-property image :data))
         (type (image-property image :type))
         (type (if (and (memq type '(nil imagemagick)) (stringp data))
                   (ignore-errors (image-type-from-data data))
                 type)))
    (pcase type
      ('jpeg "jpg")
      ('nil "img")
      (_ (symbol-name type)))))

(defun harness-ui-drag-image-file (image &optional session)
  "Return a local file holding IMAGE, an image descriptor, or nil.
An image made from a file is that file.  One made from data in memory
is written to a file first, in the temporary directory of SESSION (a
session id) or, while that is not known, in one of this Emacs's own
\(`harness-ui-drag-directory'); see `harness-ui-drag-write'."
  (let ((file (image-property image :file))
        (data (image-property image :data)))
    (cond
     ((stringp file)
      (let ((f (if (file-name-absolute-p file) file
                 (or (image-search-load-path file) (expand-file-name file)))))
        (and (not (file-remote-p f)) f)))
     ((stringp data)
      (harness-ui-drag-write data (harness-ui-drag--extension image) (harness-ui-drag-directory session))))))

(defun harness-ui-drag-write (bytes extension dir)
  "Write BYTES to DIR as image-SHA.EXTENSION and return the file's name.
SHA starts the SHA-1 of BYTES: when that file is there already, it is
the same image, and nothing is written."
  (let* ((bytes (if (multibyte-string-p bytes) (encode-coding-string bytes 'utf-8) bytes))
         (file (expand-file-name (format "image-%s.%s" (substring (secure-hash 'sha1 bytes) 0 12) extension)
                                 dir)))
    (unless (eql (file-attribute-size (file-attributes file)) (length bytes))
      (let ((tmp (make-temp-file (expand-file-name ".image-" dir)))
            (coding-system-for-write 'no-conversion)
            (create-lockfiles nil))
        (unwind-protect
            (progn (write-region bytes nil tmp nil 'silent)
                   (rename-file tmp file t))
          (when (file-exists-p tmp) (ignore-errors (delete-file tmp))))))
    file))

;;;; Where images held in memory go

(defvar harness-ui-drag--session-dirs (make-hash-table :test #'equal)
  "Session id -> its temporary directory, `pending' while asked, or `none'.")

(defvar harness-ui-drag--own-dir nil
  "The private directory of this Emacs for images of no known session.")

(defun harness-ui-drag--own-dir-p (dir)
  "Non-nil when DIR is a local directory of the user's own, not a link."
  (and (stringp dir) (not (file-remote-p dir))
       (let ((attrs (file-attributes (directory-file-name dir) 'integer)))
         (and attrs (eq t (file-attribute-type attrs))
              (eql (file-attribute-user-id attrs) (user-uid))))))

(defun harness-ui-drag--connected-p ()
  "Non-nil when the UI is connected to a harness it can ask."
  (and (fboundp 'harness-ui-call) (fboundp 'harness-acp-open-p) (boundp 'harness-ui-connection)
       (harness-acp-open-p harness-ui-connection)))

(defun harness-ui-drag-prefetch (&optional session)
  "Ask the harness for the temporary directory of SESSION, unless known or asked.
SESSION is a session id, by default the current buffer's.  The answer is
kept for `harness-ui-drag-directory'; nothing waits for it."
  (let ((sid (or session (and (boundp 'harness-ui-session-id) harness-ui-session-id))))
    (when (and sid (not (gethash sid harness-ui-drag--session-dirs)) (harness-ui-drag--connected-p))
      (puthash sid 'pending harness-ui-drag--session-dirs)
      (harness-ui-call "_harness/session/tmp-dir" (list :id sid)
                       (lambda (dir)
                         (puthash sid (if (stringp dir) (file-name-as-directory dir) 'none)
                                  harness-ui-drag--session-dirs))
                       (lambda (_err) (remhash sid harness-ui-drag--session-dirs) nil)))))

(defun harness-ui-drag--delete-own-dir ()
  "Delete the private directory of this Emacs, with the images in it."
  (when (harness-ui-drag--own-dir-p harness-ui-drag--own-dir)
    (ignore-errors (delete-directory harness-ui-drag--own-dir t)))
  (setq harness-ui-drag--own-dir nil))

(defun harness-ui-drag-directory (&optional session)
  "Return the directory an image held in memory is written to, to drag it.
That is the temporary directory of SESSION when the harness has said
which it is (`harness-ui-drag-prefetch') and it is still there.
Otherwise it is asked for, for next time, and the image goes to a
private directory of this Emacs, made on first use and deleted when
Emacs exits."
  (let ((dir (and session (gethash session harness-ui-drag--session-dirs))))
    (if (and (stringp dir) (harness-ui-drag--own-dir-p dir))
        dir
      (when (stringp dir)
        ;; Gone (the system emptied /tmp?): the harness makes it again.
        (remhash session harness-ui-drag--session-dirs))
      (when session (harness-ui-drag-prefetch session))
      (unless (harness-ui-drag--own-dir-p harness-ui-drag--own-dir)
        (setq harness-ui-drag--own-dir
              (file-name-as-directory (with-file-modes #o700 (make-temp-file "harness-drag-" t))))
        (add-hook 'kill-emacs-hook #'harness-ui-drag--delete-own-dir))
      harness-ui-drag--own-dir)))

(provide 'harness-ui-drag)
;;; harness-ui-drag.el ends here
