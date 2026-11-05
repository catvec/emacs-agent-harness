;;; image-viewer.el --- View images with easy zoom and pan  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

;; Author: catvec
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: multimedia, convenience

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; View an image with the zoom that image viewers tend to make hard: it
;; fits the window at first, and then
;;
;;   + and = (or the wheel)   zoom in
;;   - (or the wheel)         zoom out
;;   0 or f                   fit it to the window again
;;   1                        show it at its own size (100%)
;;   w and h                  fit its width or height
;;   arrows, SPC and DEL      pan while it is larger than the window
;;   r and R                  turn it a quarter turn either way
;;   H and V                  flip it
;;   n and p                  the next or previous image in the directory
;;
;; The header line names the image, its size, how large it shows and
;; the keys.  `image-viewer-open' (or visiting a file with
;; `image-viewer-mode') opens one in a buffer of its own:
;;
;;   M-x image-viewer-open
;;
;; The same zoom works on an image shown in another buffer.  An image
;; made with `image-viewer-image-string' or `image-viewer-insert-image'
;; carries `image-viewer-image-map' on its text, so +, -, 0 and 1 act
;; on the image at point; `image-viewer-wheel-map' adds the wheel to
;; that, for a window where the wheel has nothing else to scroll.
;; `image-viewer-image-keymap' composes either with the keys of the
;; buffer that shows the image.
;;
;; The size of an image is read from its file header, not from a
;; display: an image can be measured, fitted and zoomed in a batch
;; Emacs, and before it is drawn.  PNG, JPEG, GIF, BMP, WebP, SVG and
;; ICO are read; another type falls back to `image-size', where a
;; display can answer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'image)

(defgroup image-viewer nil
  "View images with easy zoom and pan."
  :group 'image
  :prefix "image-viewer-")

(defcustom image-viewer-zoom-step 1.25
  "Factor each zoom step multiplies the size of an image by.
`image-viewer-zoom-in' and `image-viewer-zoom-out' take a number of
steps from their prefix argument, one by default."
  :type 'number
  :group 'image-viewer)

(defcustom image-viewer-min-zoom 0.05
  "Smallest scale an image may zoom to, as a fraction of its own pixels."
  :type 'number
  :group 'image-viewer)

(defcustom image-viewer-max-zoom 16.0
  "Largest scale an image may zoom to, as a multiple of its own pixels."
  :type 'number
  :group 'image-viewer)

(defcustom image-viewer-fit-max-scale 1.0
  "How far a small image may be enlarged to fit its box.
One shows it at its own size: fitting only shrinks a large image.  A
host that shows thumbnails sets the `:max-scale' of an image itself."
  :type 'number
  :group 'image-viewer)

(defcustom image-viewer-fit-margin 2
  "Pixels kept free around an image fitted to a window."
  :type 'natnum
  :group 'image-viewer)

(defcustom image-viewer-default-fit 'window
  "How `image-viewer-open' first shows an image.
`window' fits it to the window; `actual' shows it at its own size."
  :type '(choice (const :tag "Fit the window" window)
                 (const :tag "Its own size" actual))
  :group 'image-viewer)

(defcustom image-viewer-header-hint t
  "Non-nil to show the key hints in the header line of `image-viewer-mode'."
  :type 'boolean
  :group 'image-viewer)

(defface image-viewer-title-face '((t :inherit bold))
  "Face of the image's name in the header line."
  :group 'image-viewer)

(defface image-viewer-dim-face '((t :inherit shadow))
  "Face of the size and the zoom in the header line."
  :group 'image-viewer)

(defface image-viewer-key-face '((t :inherit help-key-binding))
  "Face of a key in the header line's hints."
  :group 'image-viewer)

(defface image-viewer-error-face '((t :inherit error))
  "Face of a line that says why an image does not show."
  :group 'image-viewer)

;;;; State
;;
;; An image's state travels with the text that displays it, in the
;; `image-viewer-state' property: a vector shared by every character
;; of the image, so that a copy of the string and the buffer it is
;; inserted in see the same scale.  Its fields are
;;
;;   0 width   1 height   2 scale   3 box width   4 box height
;;   5 the most it fits up to   6 fit (`fit', `width', `height' or nil)
;;   7 rotation in degrees
;;
;; The scale is the size it shows at over the size of its own pixels.

(defsubst image-viewer--state-width (state) (aref state 0))
(defsubst image-viewer--state-height (state) (aref state 1))
(defsubst image-viewer--state-scale (state) (aref state 2))
(defsubst image-viewer--state-fit (state) (aref state 6))
(defsubst image-viewer--state-rotation (state) (aref state 7))

(defun image-viewer--oriented-size (width height rotation)
  "Return the WIDTH and HEIGHT of an image turned by ROTATION degrees."
  (if (= 90 (mod (round (or rotation 0)) 180))
      (cons height width)
    (cons width height)))

(defun image-viewer--display-size (state)
  "Return the (WIDTH . HEIGHT) in pixels that STATE's image shows at."
  (let ((size (image-viewer--oriented-size
               (image-viewer--state-width state)
               (image-viewer--state-height state)
               (image-viewer--state-rotation state))))
    (cons (round (* (car size) (image-viewer--state-scale state)))
          (round (* (cdr size) (image-viewer--state-scale state))))))

(defun image-viewer--clamp-scale (scale)
  "Return SCALE within `image-viewer-min-zoom' and `image-viewer-max-zoom'."
  (max image-viewer-min-zoom
       (min image-viewer-max-zoom (float scale))))

;;;; Measuring an image

(defun image-viewer--u16be (bytes pos)
  "Return the unsigned 16-bit big-endian number at POS in BYTES."
  (+ (ash (aref bytes pos) 8) (aref bytes (1+ pos))))

(defun image-viewer--u16le (bytes pos)
  "Return the unsigned 16-bit little-endian number at POS in BYTES."
  (+ (aref bytes pos) (ash (aref bytes (1+ pos)) 8)))

(defun image-viewer--u24le (bytes pos)
  "Return the unsigned 24-bit little-endian number at POS in BYTES."
  (+ (aref bytes pos) (ash (aref bytes (1+ pos)) 8)
     (ash (aref bytes (+ pos 2)) 16)))

(defun image-viewer--u32be (bytes pos)
  "Return the unsigned 32-bit big-endian number at POS in BYTES."
  (+ (ash (aref bytes pos) 24) (ash (aref bytes (1+ pos)) 16)
     (ash (aref bytes (+ pos 2)) 8) (aref bytes (+ pos 3))))

(defun image-viewer--u32le (bytes pos)
  "Return the unsigned 32-bit little-endian number at POS in BYTES."
  (+ (aref bytes pos) (ash (aref bytes (1+ pos)) 8)
     (ash (aref bytes (+ pos 2)) 16) (ash (aref bytes (+ pos 3)) 24)))

(defun image-viewer--jpeg-size (bytes)
  "Return the (WIDTH . HEIGHT) in JPEG BYTES, or nil."
  (let ((length (length bytes))
        (pos 2)
        size)
    (when (and (>= length 4) (= (aref bytes 0) #xff) (= (aref bytes 1) #xd8))
      (while (and (< pos (1- length)) (not size))
        ;; Find the next marker, past any fill bytes.
        (while (and (< pos length) (/= (aref bytes pos) #xff)) (cl-incf pos))
        (while (and (< pos length) (= (aref bytes pos) #xff)) (cl-incf pos))
        (when (< pos length)
          (let ((marker (aref bytes pos)))
            (cl-incf pos)
            (cond
             ((= marker #xd8))          ; start of image, no length
             ((or (= marker #xd9) (= marker #xda) (= marker #x01)
                  (and (>= marker #xd0) (<= marker #xd7)))
              (setq pos length))        ; the scan or the end: stop
             ((< (+ pos 2) length)
              (let ((len (image-viewer--u16be bytes pos)))
                (when (and (memq marker '(#xc0 #xc1 #xc2 #xc3 #xc5 #xc6 #xc7
                                          #xc9 #xca #xcb #xcd #xce #xcf))
                           (< (+ pos 7) length))
                  (setq size (cons (image-viewer--u16be bytes (+ pos 5))
                                   (image-viewer--u16be bytes (+ pos 3)))))
                (setq pos (+ pos len)))))))))
    size))

(defun image-viewer--svg-size (bytes)
  "Return the (WIDTH . HEIGHT) declared in the SVG BYTES, or nil."
  (let* ((head (substring bytes 0 (min (length bytes) 65536)))
         (start (string-match-p "<svg\\b" head)))
    (when start
      (let* ((end (or (string-match ">" head start) (length head)))
             (tag (substring head start end))
             (width (and (string-match "\\bwidth=\"[ \t]*\\([0-9.]+\\)" tag)
                         (string-to-number (match-string 1 tag))))
             (height (and (string-match "\\bheight=\"[ \t]*\\([0-9.]+\\)" tag)
                          (string-to-number (match-string 1 tag)))))
        (cond
         ((and width height (> width 0) (> height 0)) (cons width height))
         ((string-match "\\bviewBox=\"[ \t]*\\([-0-9.]+\\),\?[ \t]+\\([-0-9.]+\\),?[ \t]+\\([0-9.]+\\)[ \t,]+\\([0-9.]+\\)" tag)
          (cons (string-to-number (match-string 3 tag))
                (string-to-number (match-string 4 tag)))))))))

(defun image-viewer--size-from-bytes (bytes)
  "Return the (WIDTH . HEIGHT) an image in BYTES declares, or nil."
  (let ((length (length bytes)))
    (cond
     ;; PNG: signature, IHDR at 12, width and height at 16 and 20.
     ((and (>= length 24)
           (string= (substring bytes 0 8) "\211PNG\r\n\032\n")
           (string= (substring bytes 12 16) "IHDR"))
      (cons (image-viewer--u32be bytes 16) (image-viewer--u32be bytes 20)))
     ;; GIF: width and height at 6 and 8, little-endian.
     ((and (>= length 10)
           (or (string= (substring bytes 0 6) "GIF87a")
               (string= (substring bytes 0 6) "GIF89a")))
      (cons (image-viewer--u16le bytes 6) (image-viewer--u16le bytes 8)))
     ;; BMP: width and height at 18 and 22, little-endian.
     ((and (>= length 26) (string= (substring bytes 0 2) "BM"))
      (cons (abs (if (> (image-viewer--u32le bytes 18) #x7fffffff)
                     (- (image-viewer--u32le bytes 18) #x100000000)
                   (image-viewer--u32le bytes 18)))
            (abs (if (> (image-viewer--u32le bytes 22) #x7fffffff)
                     (- (image-viewer--u32le bytes 22) #x100000000)
                   (image-viewer--u32le bytes 22)))))
     ;; ICO and CUR: the first entry's width and height, 0 meaning 256.
     ((and (>= length 8) (= (aref bytes 0) 0) (= (aref bytes 1) 0)
           (memq (aref bytes 2) '(1 2)))
      (cons (let ((w (aref bytes 6))) (if (zerop w) 256 w))
            (let ((h (aref bytes 7))) (if (zerop h) 256 h))))
     ;; WebP: a RIFF whose four bytes at 12 say how the image is stored.
     ((and (>= length 30)
           (string= (substring bytes 0 4) "RIFF")
           (string= (substring bytes 8 12) "WEBP"))
      (pcase (substring bytes 12 16)
        ("VP8X" (cons (1+ (image-viewer--u24le bytes 24))
                      (1+ (image-viewer--u24le bytes 27))))
        ("VP8L"
         (let ((b1 (aref bytes 21)) (b2 (aref bytes 22))
               (b3 (aref bytes 23)) (b4 (aref bytes 24)))
           (cons (1+ (logior b1 (ash (logand b2 #x3f) 8)))
                 (1+ (logior (ash b2 -6) (ash b3 2)
                             (ash (logand b4 #x0f) 10))))))
        ("VP8 "
         (let ((at (string-match "\235\001\052" bytes 20)))
           (when (and at (< (+ at 9) length))
             (cons (logand (image-viewer--u16le bytes (+ at 3)) #x3fff)
                   (logand (image-viewer--u16le bytes (+ at 5)) #x3fff)))))))
     ((and (>= length 4) (= (aref bytes 0) #xff) (= (aref bytes 1) #xd8))
      (image-viewer--jpeg-size bytes))
     ((string-match-p "<\\?xml\\|<!DOCTYPE svg\\|<svg\\b" bytes)
      (image-viewer--svg-size bytes))
     (t nil))))

(defun image-viewer--bytes (source &optional limit)
  "Return the first LIMIT bytes of the image SOURCE, or nil.
SOURCE is a file name or a plist with :data in base64.  A file on
another host is never read: that would block."
  (let ((limit (or limit 262144)))
    (cond
     ((stringp source)
      (when (and (not (file-remote-p source)) (file-readable-p source))
        (condition-case nil
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally source nil 0 limit)
              (buffer-string))
          (error nil))))
     ((consp source)
      (let ((data (plist-get source :data)))
        (when (stringp data)
          (condition-case nil
              (base64-decode-string
               (substring data 0 (min (length data)
                                      (* 4 (/ limit 3)))))
            (error nil))))))))

(defun image-viewer--mime-type (mime)
  "Return the image type MIME names, or nil.
MIME is a media type such as \"image/png\"; a subtype whose symbol is
not the type `create-image' takes, such as \"image/svg+xml\", is
mapped to it."
  (when (and (stringp mime) (string-prefix-p "image/" mime))
    (pcase (downcase (string-remove-prefix "image/" mime))
      ((or "png" "apng") 'png)
      ((or "jpeg" "pjpeg") 'jpeg)
      ("gif" 'gif)
      ("webp" 'webp)
      ("bmp" 'bmp)
      ("tiff" 'tiff)
      ((or "svg" "svg+xml") 'svg)
      ((or "ico" "x-icon" "vnd.microsoft.icon") 'ico))))

(defun image-viewer--image-type (source)
  "Return the image type of SOURCE, a file name or a (:data BASE64) plist."
  (cond
   ((stringp source) (ignore-errors (image-supported-file-p source)))
   ((consp source)
    (or (plist-get source :type)
        (image-viewer--mime-type (plist-get source :mime))
        (let ((data (ignore-errors
                      (base64-decode-string
                       (substring (or (plist-get source :data) "")
                                  0 (min (length (or (plist-get source :data) ""))
                                         (* 4 (/ 4096 3))))))))
          (and data (ignore-errors (image-type-from-data data))))))))

(defun image-viewer-pixel-size (source)
  "Return the (WIDTH . HEIGHT) in pixels of the image SOURCE, or nil.
SOURCE is a file name or a plist (:data BASE64).  The size is read
from the image's header, so no display is needed.  A type whose
header is not known is measured with `image-size' instead, when a
display can."
  (or (image-viewer--size-from-bytes (image-viewer--bytes source))
      (when-let* ((type (image-viewer--image-type source))
                  (data (and (consp source) (plist-get source :data)))
                  (spec (ignore-errors
                          (apply #'create-image
                                 (if data (base64-decode-string data) source)
                                 type (and data t) nil))))
        (let ((size (ignore-errors (image-size spec t))))
          (ignore-errors (image-flush spec))
          size))))

(defun image-viewer--target-frame ()
  "Return the frame showing this buffer, or the selected frame."
  (let ((window (get-buffer-window (current-buffer))))
    (if (window-live-p window) (window-frame window) (selected-frame))))

(defun image-viewer--too-large-p (size &optional frame)
  "Return non-nil when Emacs refuses to draw an image of SIZE.
SIZE is (WIDTH . HEIGHT), and FRAME is the one it would be drawn in.
Emacs loads no image larger than `max-image-size' allows there."
  (when (and size (> (car size) 0) (> (cdr size) 0)
             (boundp 'max-image-size) max-image-size)
    (let ((limit max-image-size)
          (frame (or frame (selected-frame))))
      (cond ((integerp limit)
             (or (> (car size) limit) (> (cdr size) limit)))
            ((floatp limit)
             (or (> (car size) (* limit (frame-pixel-width frame)))
                 (> (cdr size) (* limit (frame-pixel-height frame)))))))))

;;;; Fitting and zooming

(defun image-viewer--fit-scale (width height box-width box-height
                                      &optional max-scale rotation)
  "Return the scale fitting an image of WIDTH by HEIGHT into its box.
BOX-WIDTH and BOX-HEIGHT are the pixels it has.  MAX-SCALE limits how
far a small image is enlarged; ROTATION turns it first."
  (let* ((dims (image-viewer--oriented-size width height rotation))
         (by-width (and box-width (> (car dims) 0)
                        (/ (float box-width) (car dims))))
         (by-height (and box-height (> (cdr dims) 0)
                         (/ (float box-height) (cdr dims))))
         (scale (cond ((and by-width by-height) (min by-width by-height))
                      (by-width by-width)
                      (by-height by-height)
                      (t 1.0))))
    (when max-scale
      (setq scale (min scale max-scale)))
    (image-viewer--clamp-scale scale)))

(defun image-viewer--image-properties (image)
  "Return the properties of IMAGE without those that scale it."
  (let ((rest (cdr image))
        (props nil))
    (while (and rest (cdr rest))
      (let ((key (car rest))
            (value (cadr rest)))
        (unless (memq key '(:scale :width :height :max-width :max-height))
          (push key props)
          (push value props)))
      (setq rest (cddr rest)))
    (nreverse props)))

(defun image-viewer--apply-scale (image scale)
  "Make IMAGE show at SCALE of its own pixels, and redraw it."
  (ignore-errors (image-flush image))
  (setcdr image (append (image-viewer--image-properties image)
                        (list :scale scale)))
  (ignore-errors (image-flush image))
  (force-window-update))

(defun image-viewer--set-scale (image state scale fit)
  "Set IMAGE and STATE to SCALE, and record that FIT shows it.
FIT is nil when the scale is the reader's own, or `fit', `width' or
`height' when the image is fitted to its box."
  (let ((scale (image-viewer--clamp-scale scale)))
    (image-viewer--apply-scale image scale)
    (aset state 2 scale)
    (aset state 6 fit)
    scale))

(defun image-viewer--set-fit (image state mode)
  "Fit IMAGE to STATE's box for MODE, one of `fit', `width' or `height'.
Return the scale it takes."
  (let* ((rotation (or (image-property image :rotation)
                       (image-viewer--state-rotation state)))
         (dims (image-viewer--oriented-size
                (image-viewer--state-width state)
                (image-viewer--state-height state)
                rotation))
         (box-width (aref state 3))
         (box-height (aref state 4))
         (scale (pcase mode
                  ('width
                   (if (and box-width (> (car dims) 0))
                       (image-viewer--clamp-scale (/ (float box-width) (car dims)))
                     1.0))
                  ('height
                   (if (and box-height (> (cdr dims) 0))
                       (image-viewer--clamp-scale (/ (float box-height) (cdr dims)))
                     1.0))
                  (_ (image-viewer--fit-scale
                      (image-viewer--state-width state)
                      (image-viewer--state-height state)
                      box-width box-height (aref state 5) rotation)))))
    (aset state 7 (float (or rotation 0)))
    (image-viewer--set-scale image state scale mode)))

;;;; Images at point

(defun image-viewer--image-at (&optional pos)
  "Return the image displayed at POS, or nil."
  (let ((display (get-text-property (or pos (point)) 'display)))
    (cond ((eq (car-safe display) 'image) display)
          ((and (consp display) (consp (car display))
                (eq (car-safe (cadr display)) 'image))
           (cadr display)))))

(defun image-viewer--state-for-image (image)
  "Return a state for IMAGE, which carries none of its own."
  (let* ((file (image-property image :file))
         (data (image-property image :data))
         (size (cond (file (image-viewer-pixel-size file))
                     (data (image-viewer--size-from-bytes data))
                     (t nil)))
         (rotation (or (image-property image :rotation) 0)))
    (vector (or (car-safe size) 0)
            (or (cdr-safe size) 0)
            (float (or (image-property image :scale) 1.0))
            nil nil
            image-viewer-max-zoom
            nil
            (float rotation))))

(defun image-viewer--current ()
  "Return the image at point and its state, as a cons.
In `image-viewer-mode' the image of the buffer answers when point is
beside it.  Signal a `user-error' when there is no image."
  (let* ((pos (point))
         (image (or (image-viewer--image-at pos)
                    (and (eq major-mode 'image-viewer-mode)
                         (bound-and-true-p image-viewer--image))))
         (state (and image
                     (or (get-text-property pos 'image-viewer-state)
                         (and (eq major-mode 'image-viewer-mode)
                              (bound-and-true-p image-viewer--state))
                         (image-viewer--state-for-image image)))))
    (unless image
      (user-error "No image at point"))
    (cons image state)))

(defun image-viewer--window-box (&optional window)
  "Return the (WIDTH . HEIGHT) in pixels WINDOW has for an image."
  (let* ((window (or window (get-buffer-window (current-buffer))
                     (selected-window)))
         (width (max 1 (- (window-body-width window t) image-viewer-fit-margin)))
         (height (max 1 (- (window-body-height window t) image-viewer-fit-margin))))
    (cons width height)))

(defun image-viewer--clamp-scroll (state)
  "Keep the window showing this buffer scrolled within STATE's image."
  (when-let* ((window (get-buffer-window (current-buffer)))
              (dims (ignore-errors (image-viewer--display-size state)))
              ((> (car dims) 0)))
    (let* ((char-width (max 1 (frame-char-width (window-frame window))))
           (image-columns (ceiling (car dims) char-width))
           (max-hscroll (max 0 (- image-columns (window-body-width window))))
           (max-vscroll (max 0 (- (cdr dims) (window-body-height window t)))))
      (when (> (window-hscroll window) max-hscroll)
        (set-window-hscroll window max-hscroll))
      (when (> (window-vscroll window t) max-vscroll)
        (set-window-vscroll window max-vscroll t)))))

(defun image-viewer--after-change (state &optional note)
  "Redraw STATE's image, keep its window in bounds, and say how it shows."
  (image-viewer--clamp-scroll state)
  (force-mode-line-update t)
  (force-window-update (current-buffer))
  (message "%s%s" (if note (concat note "  ") "")
           (image-viewer--status-for-state state)))

(defun image-viewer--status-for-state (state)
  "Return a line saying how STATE's image shows: its zoom, fit and size."
  (let* ((percent (round (* 100 (image-viewer--state-scale state))))
         (fit (pcase (image-viewer--state-fit state)
                ('fit "fit")
                ('width "fit width")
                ('height "fit height")
                (_ nil)))
         (dims (and (> (image-viewer--state-width state) 0)
                    (> (image-viewer--state-height state) 0)
                    (format "%d×%d"
                            (image-viewer--state-width state)
                            (image-viewer--state-height state)))))
    (let ((head (string-join (delq nil (list (format "%d%%" percent) fit)) " ")))
      (if dims (concat head " · " dims) head))))

(defun image-viewer-status (&optional pos)
  "Return how the image at POS shows, as a plist, or nil.
The plist has :width and :height, its own pixels, :scale, the
multiple of them it shows at, :percent, :rotation and :fit, one of
`fit', `width', `height' or nil."
  (when-let* ((pair (if pos
                        (save-excursion (goto-char pos)
                                        (ignore-errors (image-viewer--current)))
                      (ignore-errors (image-viewer--current)))))
    (let ((state (cdr pair)))
      (list :width (image-viewer--state-width state)
            :height (image-viewer--state-height state)
            :scale (image-viewer--state-scale state)
            :percent (round (* 100 (image-viewer--state-scale state)))
            :rotation (image-viewer--state-rotation state)
            :fit (image-viewer--state-fit state)))))

(defun image-viewer-status-string (&optional pos)
  "Return a line saying how the image at POS shows, or nil.
It reads like \"62% fit · 1200×800\"."
  (when-let* ((status (image-viewer-status pos)))
    (image-viewer--status-for-state
     (vector (plist-get status :width) (plist-get status :height)
             (plist-get status :scale) nil nil image-viewer-max-zoom
             (plist-get status :fit) (plist-get status :rotation)))))

(defun image-viewer--mode-line-escape (string)
  "Return STRING with every % doubled, for a mode or header line.
Those lines read % as the start of a construct such as %b, so a literal
one -- the \"62%\" of a zoom -- would vanish with the character after it."
  (replace-regexp-in-string "%" (lambda (match) (concat match match)) string t t))

(defun image-viewer-mode-line-status ()
  "Return the zoom of the image at point for a mode line, or \"\".
Use it as a `mode-line-process' value, as a host that shows an image
in a buffer of its own does:
  (setq-local mode-line-process \='(:eval (image-viewer-mode-line-status)))"
  (if-let* ((status (image-viewer-status-string)))
      (concat " " (propertize (image-viewer--mode-line-escape status)
                              'face 'mode-line-emphasis))
    ""))

;;;; Zooming commands

(defun image-viewer--zoom (steps)
  "Zoom the image at point by STEPS of `image-viewer-zoom-step'."
  (let* ((pair (image-viewer--current))
         (image (car pair))
         (state (cdr pair))
         (factor (expt image-viewer-zoom-step steps))
         (scale (image-viewer--set-scale
                 image state (* (image-viewer--state-scale state) factor) nil)))
    (image-viewer--after-change state)
    scale))

;;;###autoload
(defun image-viewer-zoom-in (&optional n)
  "Zoom the image at point in N steps, one by default.
With a negative prefix argument, zoom it out instead."
  (interactive "p")
  (image-viewer--zoom (or n 1)))

;;;###autoload
(defun image-viewer-zoom-out (&optional n)
  "Zoom the image at point out N steps, one by default.
With a negative prefix argument, zoom it in instead."
  (interactive "p")
  (image-viewer--zoom (- (or n 1))))

(defun image-viewer--wheel-command (event command)
  "Run COMMAND at the image under the mouse EVENT."
  (interactive "e")
  (let* ((start (event-start event))
         (window (posn-window start))
         (pos (posn-point start)))
    (when (window-live-p window) (select-window window))
    (when (integer-or-marker-p pos) (goto-char pos))
    (funcall command 1)))

(defun image-viewer-wheel-zoom-in (event)
  "Zoom in the image under the mouse EVENT."
  (interactive "e")
  (image-viewer--wheel-command event #'image-viewer-zoom-in))

(defun image-viewer-wheel-zoom-out (event)
  "Zoom out the image under the mouse EVENT."
  (interactive "e")
  (image-viewer--wheel-command event #'image-viewer-zoom-out))

;;;###autoload
(defun image-viewer-fit (&optional pos)
  "Fit the image at POS, or at point, to the box it was shown in.
That is the window for `image-viewer-mode', and the space a view gave
it for an image it inserted."
  (interactive)
  (let* ((pair (if pos
                   (save-excursion (goto-char pos) (image-viewer--current))
                 (image-viewer--current)))
         (image (car pair))
         (state (cdr pair)))
    (image-viewer--set-fit image state 'fit)
    (image-viewer--after-change state)))

;;;###autoload
(defun image-viewer-fit-width ()
  "Fit the image at point to the width of its box."
  (interactive)
  (let* ((pair (image-viewer--current))
         (image (car pair))
         (state (cdr pair)))
    (image-viewer--set-fit image state 'width)
    (image-viewer--after-change state)))

;;;###autoload
(defun image-viewer-fit-height ()
  "Fit the image at point to the height of its box."
  (interactive)
  (let* ((pair (image-viewer--current))
         (image (car pair))
         (state (cdr pair)))
    (image-viewer--set-fit image state 'height)
    (image-viewer--after-change state)))

;;;###autoload
(defun image-viewer-fit-window ()
  "Fit the image at point to the window showing it, and keep it fitted.
The box a host inserted the image for is replaced by the window's."
  (interactive)
  (let* ((pair (image-viewer--current))
         (image (car pair))
         (state (cdr pair))
         (box (image-viewer--window-box (get-buffer-window (current-buffer)))))
    (aset state 3 (car box))
    (aset state 4 (cdr box))
    (image-viewer--set-fit image state 'fit)
    (image-viewer--after-change state)))

;;;###autoload
(defun image-viewer-actual-size ()
  "Show the image at point at its own size: 100%."
  (interactive)
  (let* ((pair (image-viewer--current))
         (image (car pair))
         (state (cdr pair)))
    (image-viewer--set-scale image state 1.0 nil)
    (image-viewer--after-change state)))

;;;; Turning it

(defun image-viewer--rotate (angle)
  "Turn the image at point by ANGLE degrees."
  (let* ((pair (image-viewer--current))
         (image (car pair))
         (state (cdr pair))
         (rotation (float (mod (+ (or (image-property image :rotation)
                                     (image-viewer--state-rotation state))
                                  angle)
                               360))))
    (ignore-errors (image-flush image))
    (setf (image-property image :rotation) rotation)
    (aset state 7 rotation)
    (if (memq (image-viewer--state-fit state) '(fit width height))
        (image-viewer--set-fit image state (image-viewer--state-fit state))
      (image-viewer--apply-scale image (image-viewer--state-scale state)))
    (image-viewer--after-change state (format "turned %d°" rotation))))

(defun image-viewer-rotate (&optional angle)
  "Turn the image at point clockwise by ANGLE degrees, 90 by default.
With a prefix argument, turn it counter-clockwise."
  (interactive (list (if current-prefix-arg -90 90)))
  (image-viewer--rotate (or angle 90)))

(defun image-viewer-rotate-backward ()
  "Turn the image at point counter-clockwise by 90 degrees."
  (interactive)
  (image-viewer--rotate -90))

(defun image-viewer-flip-horizontal ()
  "Flip the image at point horizontally."
  (interactive)
  (let* ((pair (image-viewer--current))
         (image (car pair))
         (state (cdr pair)))
    (ignore-errors (image-flush image))
    (setf (image-property image :flip) (not (image-property image :flip)))
    (image-viewer--apply-scale image (image-viewer--state-scale state))
    (image-viewer--after-change state "flipped horizontally")))

(defun image-viewer-flip-vertical ()
  "Flip the image at point vertically."
  (interactive)
  (let* ((pair (image-viewer--current))
         (image (car pair))
         (state (cdr pair))
         (rotation (float (mod (+ (or (image-property image :rotation) 0) 180) 360))))
    (ignore-errors (image-flush image))
    (setf (image-property image :rotation) rotation)
    (setf (image-property image :flip) (not (image-property image :flip)))
    (aset state 7 rotation)
    (if (memq (image-viewer--state-fit state) '(fit width height))
        (image-viewer--set-fit image state (image-viewer--state-fit state))
      (image-viewer--apply-scale image (image-viewer--state-scale state)))
    (image-viewer--after-change state "flipped vertically")))

;;;; Panning

(defun image-viewer--pan-h (steps)
  "Scroll the image at point STEPS tenths of the window to the right."
  (let* ((pair (image-viewer--current))
         (state (cdr pair))
         (window (selected-window))
         (char-width (max 1 (frame-char-width (window-frame window))))
         (step (max 1 (round (* (or steps 1) (max 1 (/ (window-body-width window t) 10)))
                             char-width)))
         (dims (image-viewer--display-size state))
         (max-scroll (max 0 (- (ceiling (car dims) char-width)
                               (window-body-width window)))))
    (set-window-hscroll window (max 0 (min max-scroll (+ (window-hscroll window) step))))))

(defun image-viewer--pan-v (steps)
  "Scroll the image at point STEPS tenths of the window down."
  (let* ((pair (image-viewer--current))
         (state (cdr pair))
         (window (selected-window))
         (step (max 1 (round (* (or steps 1) (max 1 (/ (window-body-height window t) 10))))))
         (dims (image-viewer--display-size state))
         (max-scroll (max 0 (- (cdr dims) (window-body-height window t)))))
    (set-window-vscroll window
                        (max 0 (min max-scroll (+ (window-vscroll window t) step)))
                        t)))

(defun image-viewer-pan-left (&optional n)
  "Scroll the image at point left N tenths of the window."
  (interactive "p")
  (image-viewer--pan-h (- (or n 1))))

(defun image-viewer-pan-right (&optional n)
  "Scroll the image at point right N tenths of the window."
  (interactive "p")
  (image-viewer--pan-h (or n 1)))

(defun image-viewer-pan-up (&optional n)
  "Scroll the image at point up N tenths of the window."
  (interactive "p")
  (image-viewer--pan-v (- (or n 1))))

(defun image-viewer-pan-down (&optional n)
  "Scroll the image at point down N tenths of the window."
  (interactive "p")
  (image-viewer--pan-v (or n 1)))

(defun image-viewer-pan-page-down ()
  "Scroll the image at point down most of the window."
  (interactive)
  (image-viewer--pan-v 8))

(defun image-viewer-pan-page-up ()
  "Scroll the image at point up most of the window."
  (interactive)
  (image-viewer--pan-v -8))

;;;; Showing an image in another buffer

(defun image-viewer--make-image (source box max-scale &rest props)
  "Return (IMAGE . STATE) showing SOURCE fitted to BOX.
BOX is (WIDTH . HEIGHT) in pixels, and MAX-SCALE the most a small
image is enlarged.  PROPS go to `create-image'."
  (when (and (not (and (stringp source) (file-remote-p source)))
             (or (not (stringp source)) (file-readable-p source)))
    (let* ((size (image-viewer-pixel-size source))
           (width (or (car-safe size) 0))
           (height (or (cdr-safe size) 0))
           (rotation (float (or (plist-get props :rotation) 0)))
           (scale (image-viewer--fit-scale
                   width height (car box) (cdr box) max-scale rotation))
           (data (and (consp source) (plist-get source :data)))
           (type (image-viewer--image-type source))
           (props (cl-loop for (key value) on props by #'cddr
                           when value append (list key value)))
           (image (condition-case nil
                      (apply #'create-image
                             (if data (base64-decode-string data) source)
                             type (and data t)
                             :scale scale
                             (append
                              (and (> width 0) (> height 0)
                                   (list :max-width (car box) :max-height (cdr box)))
                              (and (/= rotation 0) (list :rotation rotation))
                              props))
                    (error nil))))
      (when image
        (cons image
              (vector width height scale (car box) (cdr box)
                      (or max-scale image-viewer-max-zoom)
                      'fit rotation))))))

(defvar image-viewer-image-map)
(defvar image-viewer-wheel-map)

(defun image-viewer--compose-keymap (map extra)
  "Return MAP with EXTRA under it, or whichever of the two there is."
  (cond ((and map extra) (make-composed-keymap (list map extra)))
        (extra extra)
        (t map)))

(defun image-viewer-image-keymap (&optional extra wheel)
  "Return the keymap for the text of an image.
EXTRA is put under the image's own keys.  WHEEL non-nil adds the
plain wheel, for a window where nothing else uses it."
  (image-viewer--compose-keymap (if wheel image-viewer-wheel-map
                                  image-viewer-image-map)
                                extra))

(defun image-viewer--label (source)
  "Return the text behind an image shown from SOURCE."
  (let ((name (cond ((stringp source) (file-name-nondirectory source))
                    (t "image"))))
    (format "[image %s]" name)))

(defun image-viewer-image-string (source &rest props)
  "Return a string showing SOURCE, which the image keys zoom.
SOURCE is a file name or a plist (:data BASE64 [:type TYPE :mime MIME]).

PROPS:
  :label       the text behind the image, by default \"[image NAME]\"
  :max-width   pixels of the box it fits
  :max-height  pixels of the box it fits
  :max-scale   the most a small image is enlarged, 1 by default
  :keymap      a keymap under the image's own keys
  :wheel       non-nil to let the plain wheel zoom, where it is free
  :help-echo   its hover text
  :frame       the frame it is shown in, for `max-image-size'
  :foreground  the colour of what the image leaves unpainted
  :background  the colour behind its transparent parts
  :rotation    degrees to turn it by
  :properties  other text properties to put on the string

Return nil when SOURCE cannot be read or drawn, or is too large for
Emacs to draw."
  (let* ((box (cons (or (plist-get props :max-width)
                        (max 1 (- (window-body-width nil t)
                                  image-viewer-fit-margin)))
                    (or (plist-get props :max-height)
                        (max 1 (- (window-body-height nil t)
                                  image-viewer-fit-margin)))))
         (max-scale (or (plist-get props :max-scale) image-viewer-fit-max-scale))
         (pair (image-viewer--make-image
                source box max-scale
                :foreground (plist-get props :foreground)
                :background (plist-get props :background)
                :rotation (plist-get props :rotation)))
         (size (and pair (image-viewer-pixel-size source)))
         (frame (or (plist-get props :frame) (image-viewer--target-frame))))
    (when (and pair (not (image-viewer--too-large-p size frame)))
      (let* ((label (or (plist-get props :label) (image-viewer--label source)))
             (label (if (string-empty-p label) " " label))
             (string (propertize
                      label
                      'display (car pair)
                      'image-viewer-state (cdr pair)
                      'pointer 'hand
                      'help-echo (or (plist-get props :help-echo)
                                     "+ and - zoom, 0 fits, 1 shows it at 100%")
                      'keymap (image-viewer-image-keymap
                               (plist-get props :keymap)
                               (plist-get props :wheel)))))
        (when-let* ((extra (plist-get props :properties)))
          (add-text-properties 0 (length string) extra string))
        string))))

(defun image-viewer-insert-image (source &rest props)
  "Insert SOURCE at point, with the keys that zoom it, and return its image.
PROPS are those of `image-viewer-image-string', except :properties;
:text-properties are added to the text.  Return nil, inserting
nothing, when SOURCE cannot be read or drawn."
  (let* ((box (cons (or (plist-get props :max-width)
                        (max 1 (- (window-body-width nil t)
                                  image-viewer-fit-margin)))
                    (or (plist-get props :max-height)
                        (max 1 (- (window-body-height nil t)
                                  image-viewer-fit-margin)))))
         (max-scale (or (plist-get props :max-scale) image-viewer-fit-max-scale))
         (pair (image-viewer--make-image
                source box max-scale
                :foreground (plist-get props :foreground)
                :background (plist-get props :background)
                :rotation (plist-get props :rotation)))
         (size (and pair (image-viewer-pixel-size source)))
         (frame (or (plist-get props :frame) (image-viewer--target-frame))))
    (when (and pair (not (image-viewer--too-large-p size frame)))
      (let* ((label (or (plist-get props :label) (image-viewer--label source)))
             (label (if (string-empty-p label) " " label))
             (start (point)))
        (insert label)
        (add-text-properties
         start (point)
         (append
          (list 'display (car pair)
                'image-viewer-state (cdr pair)
                'rear-nonsticky t
                'pointer 'hand
                'help-echo (or (plist-get props :help-echo)
                               "+ and - zoom, 0 fits, 1 shows it at 100%")
                'keymap (image-viewer-image-keymap
                         (plist-get props :keymap)
                         (plist-get props :wheel)))
          (plist-get props :text-properties)))
        (car pair)))))

;;;; Keys

(defvar-keymap image-viewer-image-map
  :doc "Keys on an image shown in a buffer: zoom it where it is."
  :parent image-map
  "+" #'image-viewer-zoom-in
  "=" #'image-viewer-zoom-in
  "-" #'image-viewer-zoom-out
  "0" #'image-viewer-fit
  "f" #'image-viewer-fit
  "1" #'image-viewer-actual-size
  "w" #'image-viewer-fit-width
  "h" #'image-viewer-fit-height
  "F" #'image-viewer-fit-window
  "r" #'image-viewer-rotate
  "R" #'image-viewer-rotate-backward
  "H" #'image-viewer-flip-horizontal
  "V" #'image-viewer-flip-vertical
  "C-<wheel-up>" #'image-viewer-wheel-zoom-in
  "C-<wheel-down>" #'image-viewer-wheel-zoom-out
  "<mouse-4>" #'image-viewer-wheel-zoom-in
  "<mouse-5>" #'image-viewer-wheel-zoom-out)

(defvar-keymap image-viewer-wheel-map
  :doc "Keys on an image where the plain wheel has nothing else to do."
  :parent image-viewer-image-map
  "<wheel-up>" #'image-viewer-wheel-zoom-in
  "<wheel-down>" #'image-viewer-wheel-zoom-out)

(defvar-keymap image-viewer-mode-map
  :doc "Keymap of `image-viewer-mode'."
  :parent special-mode-map
  "+" #'image-viewer-zoom-in
  "=" #'image-viewer-zoom-in
  "-" #'image-viewer-zoom-out
  "0" #'image-viewer-fit
  "f" #'image-viewer-fit
  "1" #'image-viewer-actual-size
  "w" #'image-viewer-fit-width
  "h" #'image-viewer-fit-height
  "F" #'image-viewer-fit-window
  "r" #'image-viewer-rotate
  "R" #'image-viewer-rotate-backward
  "H" #'image-viewer-flip-horizontal
  "V" #'image-viewer-flip-vertical
  "n" #'image-viewer-next
  "p" #'image-viewer-previous
  "y" #'image-viewer-copy-file-name
  "<left>" #'image-viewer-pan-left
  "<right>" #'image-viewer-pan-right
  "<up>" #'image-viewer-pan-up
  "<down>" #'image-viewer-pan-down
  "SPC" #'image-viewer-pan-page-down
  "S-SPC" #'image-viewer-pan-page-up
  "DEL" #'image-viewer-pan-page-up
  "<wheel-up>" #'image-viewer-wheel-zoom-in
  "<wheel-down>" #'image-viewer-wheel-zoom-out
  "C-<wheel-up>" #'image-viewer-wheel-zoom-in
  "C-<wheel-down>" #'image-viewer-wheel-zoom-out
  "<mouse-4>" #'image-viewer-wheel-zoom-in
  "<mouse-5>" #'image-viewer-wheel-zoom-out)

;;;; The viewer buffer

(defvar-local image-viewer--file nil
  "The file this viewer shows.")

(defvar-local image-viewer--image nil
  "The image object this viewer shows.")

(defvar-local image-viewer--state nil
  "The state vector of the image this viewer shows.")

(defvar-local image-viewer--last-box nil
  "The box in pixels this viewer last fitted its image to.")

(defun image-viewer--key-hint ()
  "Return the header line's list of keys."
  (let ((key (lambda (text) (propertize text 'face 'image-viewer-key-face))))
    (string-join
     (list (concat (funcall key "+") " " (funcall key "-") " zoom")
           (concat (funcall key "0") " fit")
           (concat (funcall key "1") " 100%")
           (concat (funcall key "w") " " (funcall key "h") " width/height")
           (concat (funcall key "n") " " (funcall key "p") " next/previous")
           "arrows pan")
     "   ")))

(defun image-viewer--header ()
  "Return the header line of `image-viewer-mode'."
  (let ((name (if image-viewer--file
                  (file-name-nondirectory image-viewer--file)
                ""))
        (status (and image-viewer--state
                     (image-viewer--status-for-state image-viewer--state))))
    (image-viewer--mode-line-escape
     (concat " " (propertize name 'face 'image-viewer-title-face)
             (if status (concat "   " (propertize status 'face 'image-viewer-dim-face)) "")
             (if image-viewer-header-hint
                 (concat "   " (image-viewer--key-hint))
               "")))))

(defun image-viewer--message-line (text)
  "Insert TEXT as a line saying why an image does not show."
  (insert (propertize text 'face 'image-viewer-error-face) "\n"))

(defun image-viewer--load ()
  "Draw the file this viewer shows again, fitted to its window."
  (let* ((file image-viewer--file)
         (box (image-viewer--window-box (get-buffer-window (current-buffer))))
         (inhibit-read-only t)
         (buffer-undo-list t)
         image state)
    (setq image-viewer--last-box box
          image-viewer--image nil
          image-viewer--state nil)
    (erase-buffer)
    (cond
     ((null file)
      (image-viewer--message-line "No image to show."))
     ((file-remote-p file)
      (image-viewer--message-line "An image on another host is not read here."))
     ((not (file-readable-p file))
      (image-viewer--message-line (format "%s cannot be read." file)))
     (t
      (let* ((size (image-viewer-pixel-size file))
             (too-large (image-viewer--too-large-p
                         size (image-viewer--target-frame))))
        (cond
         (too-large
          (image-viewer--message-line
           (format "%s is %d×%d pixels, too large for Emacs to draw here (`max-image-size')."
                   (file-name-nondirectory file) (car size) (cdr size))))
         (t
          (let ((start (point)))
            (setq image (image-viewer-insert-image
                         file
                         :label " "
                         :max-width (car box)
                         :max-height (cdr box)
                         :max-scale image-viewer-fit-max-scale
                         :wheel t
                         :keymap nil
                         :help-echo nil))
            (if image
                (setq state (get-text-property start 'image-viewer-state))
              (image-viewer--message-line
               (format "%s cannot be shown here." (file-name-nondirectory file))))))))))
    (setq image-viewer--image image
          image-viewer--state state)
    (when state
      (when (eq image-viewer-default-fit 'actual)
        ;; The image was made fitted; show it at its own size instead.
        (image-viewer--set-scale image state 1.0 nil))
      (image-viewer--clamp-scroll state))
    (goto-char (point-min))
    (force-mode-line-update t)
    (force-window-update (current-buffer))))

(defun image-viewer--revert (_ignore-auto _noconfirm)
  "Draw the file this viewer shows again."
  (image-viewer--load))

(defun image-viewer--window-changed (window)
  "Fit this viewer's image to WINDOW again when the window changed size.
The hook is buffer-local; before Emacs 31 it may run with another
buffer current, so the buffer showing WINDOW is made current here."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (and (derived-mode-p 'image-viewer-mode)
                 image-viewer--image image-viewer--state)
        (let ((box (image-viewer--window-box window)))
          (unless (equal box image-viewer--last-box)
            (setq image-viewer--last-box box)
            (aset image-viewer--state 3 (car box))
            (aset image-viewer--state 4 (cdr box))
            (when (memq (image-viewer--state-fit image-viewer--state)
                        '(fit width height))
              (image-viewer--set-fit image-viewer--image image-viewer--state
                                     (image-viewer--state-fit image-viewer--state))
              (image-viewer--clamp-scroll image-viewer--state)
              (force-mode-line-update t))))))))

;;;###autoload
(define-derived-mode image-viewer-mode special-mode "Image"
  "Major mode for viewing one image, with easy zoom and pan.
\\<image-viewer-mode-map>\
The image fills the window and is fitted to it as it changes size.
\\[image-viewer-zoom-in] and \\[image-viewer-zoom-out] zoom it where it is, `0' or
\\[image-viewer-fit] fits it again, [1] shows it at its own size, and `w' and `h'
fit its width and height.  Arrow keys pan a large image, `r' and `R'
turn it, `H' and `V' flip it, `n' and `p' go to the next and previous
image of the directory, and `y' copies its file name.

The header line names it, its size and how large it shows."
  (setq-local header-line-format '(:eval (image-viewer--header)))
  (setq-local revert-buffer-function #'image-viewer--revert)
  (setq-local truncate-lines t)
  (add-hook 'window-state-change-functions #'image-viewer--window-changed nil t))

(defun image-viewer--buffer-name (file)
  "Return the name of the buffer that views FILE."
  (format "*image-viewer: %s*" (abbreviate-file-name file)))

(defun image-viewer--buffer (file)
  "Return a buffer showing FILE, new or one that already shows it."
  (or (cl-find-if (lambda (buffer)
                    (with-current-buffer buffer
                      (and (derived-mode-p 'image-viewer-mode)
                           (equal image-viewer--file file))))
                  (buffer-list))
      (generate-new-buffer (image-viewer--buffer-name file))))

;;;###autoload
(defun image-viewer-open (file &optional other-window)
  "View the image FILE in a buffer of its own.
With OTHER-WINDOW, show it in another window rather than the selected
one.  The image fits the window at first; the keys of
`image-viewer-mode' zoom it from there."
  (interactive (list (read-file-name "Image file: ") current-prefix-arg))
  (let* ((file (expand-file-name file))
         (buffer (image-viewer--buffer file)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'image-viewer-mode)
        (image-viewer-mode))
      (setq image-viewer--file file)
      (image-viewer--load))
    (if other-window
        (switch-to-buffer-other-window buffer)
      (pop-to-buffer buffer))
    buffer))

(defun image-viewer--siblings (file)
  "Return the image files beside FILE, sorted, or nil."
  (when (and file (not (file-remote-p file)))
    (let ((dir (file-name-directory file)))
      (when (file-directory-p dir)
        (sort (cl-loop for name in (directory-files dir t "\\`[^.]")
                       when (and (file-regular-p name)
                                 (ignore-errors (image-supported-file-p name)))
                       collect name)
              #'string<)))))

(defun image-viewer--visit (file)
  "Show FILE in this viewer buffer."
  (setq image-viewer--file (expand-file-name file))
  (rename-buffer (image-viewer--buffer-name image-viewer--file) t)
  (image-viewer--load))

;;;###autoload
(defun image-viewer-next (&optional n)
  "Show the next image of this one's directory, N images on."
  (interactive "p")
  (let* ((files (or (image-viewer--siblings image-viewer--file)
                    (user-error "No directory to look in")))
         (count (length files))
         (current (cl-position image-viewer--file files :test #'equal))
         (target (nth (mod (+ (or current -1) (or n 1)) count) files)))
    (unless target (user-error "No other image in this directory"))
    (image-viewer--visit target)))

;;;###autoload
(defun image-viewer-previous (&optional n)
  "Show the previous image of this one's directory, N images back."
  (interactive "p")
  (image-viewer-next (- (or n 1))))

;;;###autoload
(defun image-viewer-copy-file-name ()
  "Put this viewer's file name on the kill ring."
  (interactive)
  (unless image-viewer--file (user-error "This viewer shows no file"))
  (kill-new image-viewer--file)
  (message "Copied %s" image-viewer--file))

(provide 'image-viewer)
;;; image-viewer.el ends here
