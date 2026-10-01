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

(ert-deftest harness-ui-unowned-requests-stay-pending-without-prompting ()
  "A question or permission no buffer owns is declined, never prompted for."
  (let (responses (harness-ui-question-functions nil) (harness-ui-permission-functions nil))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (error "Prompted")))
              ((symbol-function 'read-string) (lambda (&rest _) (error "Prompted")))
              ((symbol-function 'read-multiple-choice) (lambda (&rest _) (error "Prompted"))))
      (harness-ui--dispatch "_harness/ask_user" '(:sessionId "s1" :requestId "q1" :question "Which?" :options ["a" "b"])
                            (lambda (r) (push r responses)))
      (harness-ui--dispatch "session/request_permission" '(:sessionId "s1" :toolCall (:title "bash"))
                            (lambda (r) (push r responses))))
    (should (= 2 (length responses)))
    (should-not (cl-some (lambda (r) (plist-get r :answer)) responses))
    (should-not (cl-some (lambda (r) (plist-get r :outcome)) responses))))

(provide 'harness-ui-test)
;;; harness-ui-test.el ends here
