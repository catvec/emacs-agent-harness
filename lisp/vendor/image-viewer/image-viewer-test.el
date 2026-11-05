;;; image-viewer-test.el --- Tests for image-viewer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

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

;; The tests of image-viewer.el.  They need nothing but the library:
;; `make test' runs them in an Emacs with only this directory on its
;; load path.  The images are written from bytes in the tests, and the
;; sizes are read from their headers, so no display is needed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'image-viewer)

(defconst image-viewer-test--png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAIAAAA8r+mnAAAAEklEQVR4nGP4z8CAFWEXJUsCAFpeH+EeQoQoAAAAAElFTkSuQmCC")
  "The bytes of an 8x4 PNG.")

(defconst image-viewer-test--gif
  (concat "GIF89a" (unibyte-string 8 0 4 0 0 0 0))
  "The first bytes of an 8x4 GIF.")

(defconst image-viewer-test--jpeg
  (concat (unibyte-string #xff #xd8 #xff #xc0 0 11 8 0 4 0 8 3 1 34 0 2 0)
          (unibyte-string #xff #xd9))
  "The header of an 8x4 JPEG, with its start and end markers.")

(defconst image-viewer-test--svg
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"4\"></svg>"
  "An SVG 8x4 pixels large.")

(defmacro image-viewer-test-with-dir (&rest body)
  "Run BODY with `dir' bound to an empty temporary directory."
  (declare (indent 0))
  `(let ((dir (make-temp-file "image-viewer-test-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(defun image-viewer-test--write (dir name bytes)
  "Write BYTES into NAME in DIR, and return the file's name."
  (let ((file (expand-file-name name dir)))
    (let ((coding-system-for-write 'no-conversion))
      (with-temp-file file
        (set-buffer-multibyte nil)
        (insert bytes)))
    file))

(defun image-viewer-test--show (dir &optional props)
  "Insert the PNG in DIR into a temporary buffer, and return image and state.
PROPS are those of `image-viewer-image-string'."
  (let* ((file (image-viewer-test--write dir "test.png" image-viewer-test--png))
         (image nil)
         (state nil))
    (with-temp-buffer
      (setq image (apply #'image-viewer-insert-image
                         file (append '(:max-width 8 :max-height 8) props)))
      (setq state (get-text-property (point-min) 'image-viewer-state)))
    (list image state)))

(ert-deftest image-viewer-reads-the-size-from-headers ()
  "PNG, GIF, JPEG and SVG sizes are read without a display."
  (image-viewer-test-with-dir
    (should (equal (image-viewer-pixel-size
                    (image-viewer-test--write dir "a.png" image-viewer-test--png))
                   '(8 . 4)))
    (should (equal (image-viewer-pixel-size
                    (image-viewer-test--write dir "a.gif" image-viewer-test--gif))
                   '(8 . 4)))
    (should (equal (image-viewer-pixel-size
                    (image-viewer-test--write dir "a.jpg" image-viewer-test--jpeg))
                   '(8 . 4)))
    (should (equal (image-viewer-pixel-size
                    (image-viewer-test--write dir "a.svg"
                                              (string-to-unibyte image-viewer-test--svg)))
                   '(8 . 4)))
    (should (equal (image-viewer-pixel-size
                    (list :data (base64-encode-string image-viewer-test--png t)))
                   '(8 . 4)))))

(ert-deftest image-viewer-knows-the-type-a-mime-names ()
  "A data image's media type names its type, even where the subtype is not one."
  (should (eq 'png (image-viewer--mime-type "image/png")))
  (should (eq 'jpeg (image-viewer--mime-type "image/jpeg")))
  (should (eq 'svg (image-viewer--mime-type "image/svg+xml")))
  (should (eq 'ico (image-viewer--mime-type "image/x-icon")))
  (should-not (image-viewer--mime-type "text/plain"))
  (should (eq 'svg
              (image-viewer--image-type
               (list :data (base64-encode-string image-viewer-test--svg t)
                     :mime "image/svg+xml")))))

(ert-deftest image-viewer-fits-only-as-large-as-it-may ()
  "Fitting shrinks a large image, and never enlarges past its limit."
  (should (= 0.5 (image-viewer--fit-scale 8 4 4 4 1)))
  (should (= 1.0 (image-viewer--fit-scale 8 4 8 8 1)))
  (should (= 2.0 (image-viewer--fit-scale 8 4 16 16 2)))
  ;; A quarter turn swaps the sides the box has to hold.
  (should (= 1.0 (image-viewer--fit-scale 8 4 4 16 2 90)))
  (should (= 0.5 (image-viewer--fit-scale 8 4 4 4 2 90))))

(ert-deftest image-viewer-inserts-an-image-with-its-keys ()
  "An inserted image carries its state, its keys and its help."
  (image-viewer-test-with-dir
    (pcase-let ((`(,image ,state) (image-viewer-test--show dir)))
      (should image)
      (should (equal (aref state 0) 8))
      (should (equal (aref state 1) 4))
      (should (= (aref state 2) 1.0))
      (with-temp-buffer
        (image-viewer-insert-image
         (image-viewer-test--write dir "other.png" image-viewer-test--png)
         :max-width 8 :max-height 8)
        (goto-char (point-min))
        (let ((keymap (get-text-property (point) 'keymap)))
          (should (eq (lookup-key keymap (kbd "+")) #'image-viewer-zoom-in))
          (should (eq (lookup-key keymap (kbd "-")) #'image-viewer-zoom-out))
          (should (eq (lookup-key keymap (kbd "0")) #'image-viewer-fit))
          (should (eq (lookup-key keymap (kbd "1")) #'image-viewer-actual-size))
          ;; Emacs's own image keys stay under them.
          (should (eq (lookup-key keymap (kbd "i +")) #'image-increase-size)))
        (should (string-search "+ and - zoom"
                               (get-text-property (point) 'help-echo)))
        (should (equal (image-viewer-status-string)
                       "100% fit · 8×4"))))))

(ert-deftest image-viewer-zooms-at-point ()
  "Zooming changes the image in place, and 0 fits it again."
  (image-viewer-test-with-dir
    (let (image)
      (with-temp-buffer
        (setq image (image-viewer-insert-image
                     (image-viewer-test--write dir "test.png" image-viewer-test--png)
                     :max-width 8 :max-height 8))
        (goto-char (point-min))
        (image-viewer-zoom-in)
        (should (= 1.25 (image-property image :scale)))
        (image-viewer-zoom-in 2)
        (should (= (* 1.25 1.25 1.25) (image-property image :scale)))
        (image-viewer-zoom-out)
        (should (= (* 1.25 1.25) (image-property image :scale)))
        (image-viewer-fit)
        (should (= 1.0 (image-property image :scale)))
        (should (equal (image-viewer-status-string) "100% fit · 8×4"))
        (image-viewer-zoom-in 100)
        (should (= image-viewer-max-zoom (image-property image :scale)))
        (image-viewer-zoom-out 100)
        (should (= image-viewer-min-zoom (image-property image :scale)))
        (image-viewer-actual-size)
        (should (= 1.0 (image-property image :scale)))
        (should (equal (image-viewer-status-string) "100% · 8×4"))))))

(ert-deftest image-viewer-turns-and-fits-again ()
  "A quarter turn refits the image, and shows in its state."
  (image-viewer-test-with-dir
    (let (image state)
      (with-temp-buffer
        (setq image (image-viewer-insert-image
                     (image-viewer-test--write dir "test.png" image-viewer-test--png)
                     :max-width 8 :max-height 8)
              state (get-text-property (point-min) 'image-viewer-state))
        (goto-char (point-min))
        (image-viewer-fit-width)
        (should (= 1.0 (image-property image :scale)))
        (image-viewer-rotate)
        (should (= 90.0 (image-property image :rotation)))
        (should (= 90.0 (aref state 7)))
        ;; Fitted to the width again: the sides have swapped, so 4 pixels
        ;; of width now fill the 8 the box has.
        (should (= 2.0 (image-property image :scale)))
        (should (equal (image-viewer-status-string) "200% fit width · 8×4"))))))

(ert-deftest image-viewer-opens-a-buffer-of-its-own ()
  "Opening a file shows it in `image-viewer-mode', fitted to the window."
  (image-viewer-test-with-dir
    (let ((file (image-viewer-test--write dir "test.png" image-viewer-test--png)))
      (let ((buffer (image-viewer-open file)))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'image-viewer-mode))
              (should (equal image-viewer--file file))
              (should image-viewer--image)
              (should image-viewer--state)
              (should (= (aref image-viewer--state 2) 1.0))
              (should (string-search "test.png" (image-viewer--header)))
              ;; A header line reads % as a construct: the zoom's is doubled.
              (should (string-search "100%% fit" (image-viewer--header)))
              (should (string-search "100%%" (image-viewer-mode-line-status)))
              (goto-char (point-min))
              (execute-kbd-macro (kbd "+"))
              (should (= 1.25 (aref image-viewer--state 2)))
              (execute-kbd-macro (kbd "1"))
              (should (= 1.0 (aref image-viewer--state 2)))
              (execute-kbd-macro (kbd "0"))
              (should (= 1.0 (aref image-viewer--state 2))))
          (kill-buffer buffer))))))

(ert-deftest image-viewer-browses-the-images-beside-one ()
  "n and p visit the next and previous image of the directory."
  (image-viewer-test-with-dir
    (let ((alpha (image-viewer-test--write dir "alpha.png" image-viewer-test--png))
          (beta (image-viewer-test--write dir "beta.png" image-viewer-test--png)))
      (let ((buffer (image-viewer-open alpha)))
        (unwind-protect
            (with-current-buffer buffer
              (execute-kbd-macro (kbd "n"))
              (should (equal image-viewer--file beta))
              (execute-kbd-macro (kbd "p"))
              (should (equal image-viewer--file alpha))
              (execute-kbd-macro (kbd "p"))
              (should (equal image-viewer--file beta)))
          (kill-buffer buffer))))))

(ert-deftest image-viewer-keymaps-have-the-wheel-where-it-is-free ()
  "The inline map leaves the plain wheel alone; the other one zooms."
  (should-not (lookup-key image-viewer-image-map (kbd "<wheel-up>")))
  (should (eq (lookup-key image-viewer-wheel-map (kbd "<wheel-up>"))
              #'image-viewer-wheel-zoom-in))
  (should (eq (lookup-key image-viewer-image-map (kbd "C-<wheel-up>"))
              #'image-viewer-wheel-zoom-in))
  (should (eq (lookup-key image-viewer-mode-map (kbd "<wheel-down>"))
              #'image-viewer-wheel-zoom-out)))

(provide 'image-viewer-test)
;;; image-viewer-test.el ends here
