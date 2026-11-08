;;; harness-ui-images-test.el --- Tests for images in the harness  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; The images the UI shows are drawn by the image-viewer library: they
;; fit the space they are given, their keys zoom them where they are,
;; and a click opens one larger.  These tests drive the harness's side
;; of that: the string a view inserts, the keys on it, the status a
;; popout header reads, and the two ways an image opens.

;;; Code:

(require 'harness-test-helpers)
(require 'image-viewer)

(defvar harness-acp--server-enabled)
(defvar harness-ui-image-open-function)

(declare-function harness-ui-image-string "harness-ui")
(declare-function harness-ui-image-insert "harness-ui")
(declare-function harness-ui-image-open "harness-ui")
(declare-function harness-ui-image-view "harness-ui")
(declare-function harness-ui-image-status "harness-ui")
(declare-function harness-ui-action-push "harness-ui")

(defvar harness-ui-images-test-directory nil
  "The directory this suite writes its test images in.")

(defmacro harness-ui-images-test-with (&rest body)
  "Load the UI and the image library; run BODY in a temporary state."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(acp ui)) (harness-test-load-module m)))
     (let ((harness-ui-images-test-directory (harness-test-temp-dir)))
       (unwind-protect (progn ,@body)
         (dolist (buffer (buffer-list))
           (when (eq (buffer-local-value 'major-mode buffer) 'image-viewer-mode)
             (kill-buffer buffer)))
         (delete-directory harness-ui-images-test-directory t)))))

(defun harness-ui-images-test--file (&optional name)
  "Write the test PNG as NAME in the suite's directory, and return its path."
  (let ((file (expand-file-name (or name "picture.png")
                                harness-ui-images-test-directory)))
    (let ((coding-system-for-write 'no-conversion))
      (write-region harness-test-png nil file nil 'silent))
    file))

(ert-deftest harness-ui-images-string-zooms-where-it-is ()
  "An inline image carries the viewer's keys and state, and opens larger."
  (harness-ui-images-test-with
    (let ((file (harness-ui-images-test--file))
          (opened nil))
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
        (let ((string (harness-ui-image-string file "image/png")))
          (should (stringp string))
          (should (string-match-p "mouse-1 or RET: open"
                                  (get-text-property 0 'help-echo string)))
          (with-temp-buffer
            (insert string)
            (goto-char (point-min))
            (let ((keymap (get-text-property (point) 'keymap)))
              (should (eq (lookup-key keymap (kbd "+")) #'image-viewer-zoom-in))
              (should (eq (lookup-key keymap (kbd "-")) #'image-viewer-zoom-out))
              (should (eq (lookup-key keymap (kbd "0")) #'image-viewer-fit))
              (should (eq (lookup-key keymap (kbd "1")) #'image-viewer-actual-size))
              (should (commandp (lookup-key keymap (kbd "RET")))))
            (should (string-search "2×2" (harness-ui-image-status)))
            (let ((image (get-text-property (point) 'display)))
              (image-viewer-zoom-in)
              (should (> (image-property image :scale) 1.0)))
            (let ((harness-ui-image-open-function (lambda (path) (setq opened path))))
              (call-interactively (lookup-key (get-text-property (point) 'keymap)
                                              (kbd "RET"))))
            (should (equal opened file))))))))

(ert-deftest harness-ui-images-insert-draws-in-the-harness-colours ()
  "An inserted image has the viewer's wheel, its colours and its box."
  (harness-ui-images-test-with
    (let ((file (harness-ui-images-test--file "inserted.png")))
      (with-temp-buffer
        (let ((image (harness-ui-image-insert
                      file :label "[image inserted]" :max-width 4 :max-height 4
                      :max-scale 2 :wheel t)))
          (should image)
          (should (equal "white" (image-property image :background)))
          (should (equal "black" (image-property image :foreground)))
          (should (= 4 (image-property image :max-width)))
          (goto-char (point-min))
          (let ((keymap (get-text-property (point) 'keymap)))
            (should (eq (lookup-key keymap (kbd "<wheel-up>"))
                        #'image-viewer-wheel-zoom-in))
            (should (eq (lookup-key keymap (kbd "C-<wheel-down>"))
                        #'image-viewer-wheel-zoom-out)))
          (should (equal "200% fit · 2×2" (harness-ui-image-status))))
        (erase-buffer)
        (harness-ui-image-insert file :max-width 4 :max-height 4)
        (goto-char (point-min))
        ;; Without :wheel the plain wheel still scrolls the view.
        (should-not (lookup-key (get-text-property (point) 'keymap)
                                (kbd "<wheel-up>")))))))

(ert-deftest harness-ui-images-open-larger-in-a-popout-or-a-viewer ()
  "An image opens in the popout when there is one, else in the viewer."
  (harness-ui-images-test-with
    (let ((file (harness-ui-images-test--file "open.png"))
          (popped nil)
          (viewed nil))
      (cl-letf (((symbol-function 'harness-ui-popout-image)
                 (lambda (path &rest props) (setq popped (cons path props)) 'popout)))
        (harness-ui-image-open file)
        (should (equal (car popped) file))
        (let ((harness-ui-image-open-function (lambda (path) (setq viewed path))))
          (harness-ui-image-open file)
          (should (equal viewed file))))
      (cl-letf (((symbol-function 'harness-ui-popout-image) nil)
                ((symbol-function 'image-viewer-open)
                 (lambda (path &optional _other) (setq viewed path) 'viewer)))
        (harness-ui-image-open file)
        (should (equal viewed file)))
      (let ((harness-ui-image-open-function nil))
        (cl-letf (((symbol-function 'image-viewer-open)
                   (lambda (path &optional _other) (setq viewed path) 'viewer)))
          (harness-ui-image-open file)
          (should (equal viewed file))))
      ;; The command of the popout's [View in a window].
      (let ((buffer (harness-ui-image-view file)))
        (with-current-buffer buffer
          (should (derived-mode-p 'image-viewer-mode))
          (should (equal image-viewer--file file)))))))

(provide 'harness-ui-images-test)
;;; harness-ui-images-test.el ends here
