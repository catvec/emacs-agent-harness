;;; harness-ui-test.el --- Tests for the UI foundation  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)

(defmacro harness-ui-test-with-layout (&rest body)
  "Run BODY with \"other\" in the main window and a session in a right side window.
The side window is selected and not dedicated, as Doom leaves it."
  (declare (indent 0))
  `(let ((other (get-buffer-create "other"))
         (chat (get-buffer-create "*harness: test*"))
         (menu (get-buffer-create " *harness-test-menu*"))
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

(ert-deftest harness-ui-menu-from-main-window-follows-transient-action ()
  (harness-ui-test-with-layout
    (select-window (get-buffer-window other))
    (let ((window (harness-ui--display-menu menu '((inhibit-same-window . t)))))
      (should-not (window-parameter window 'window-side))
      (should (eq window (window-in-direction 'below (get-buffer-window other)))))))

(ert-deftest harness-ui-icon-face-background ()
  ;; An SVG keeps the background it was rendered on, so an icon on a
  ;; coloured line is rendered on that line's background.
  (cl-letf (((symbol-function 'icon-string)
             ;; solaire-mode adds its own background to every image.
             (lambda (_) (propertize " " 'display '(image :type svg :file "send.svg" :background "#000000")))))
    (should (equal "#000000" (plist-get (cdr (get-text-property 0 'display (harness-ui-icon 'harness-icon-send)))
                                        :background)))
    (let ((spec (cdr (get-text-property 0 'display (harness-ui-icon 'harness-icon-send 'harness-compose-face)))))
      (should (equal (face-background 'harness-compose-face nil t) (plist-get spec :background)))
      (should (= 1 (cl-count :background spec))))))

(provide 'harness-ui-test)
;;; harness-ui-test.el ends here
