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

;;;; Views share positions with sessions

(defvar harness-ui--position-buffers)
(defvar harness-ui-open-session-function)

(defmacro harness-ui-test-with-views (&rest body)
  "Run BODY with buffers `session', `other-session' and `view' and a fresh layout."
  (declare (indent 0))
  `(let ((session (get-buffer-create "*harness: view test*"))
         (other-session (get-buffer-create "*harness: view test 2*"))
         (view (get-buffer-create "*harness view test*"))
         (harness-ui-default-position 'right))
     (unwind-protect
         (progn
           (clrhash harness-ui--position-buffers)
           (delete-other-windows)
           (switch-to-buffer (get-buffer-create "*scratch*"))
           ,@body)
       (mapc #'kill-buffer (list session other-session view))
       (clrhash harness-ui--position-buffers)
       (ignore-errors (delete-other-windows)))))

(ert-deftest harness-ui-view-and-session-replace-each-other ()
  (harness-ui-test-with-views
    (harness-ui-display-buffer session 'right)
    (let ((window (get-buffer-window session)))
      (harness-ui-display-view view)
      (should (eq view (window-buffer window)))
      (should-not (get-buffer-window session))
      (harness-ui-display-buffer session 'right)
      (should (eq session (window-buffer window)))
      (should-not (get-buffer-window view)))))

(ert-deftest harness-ui-view-returns-to-its-last-position ()
  (harness-ui-test-with-views
    (harness-ui-display-view view 'left)
    (should (eq 'left (buffer-local-value 'harness-ui-position view)))
    (harness-ui-display-buffer session 'left)
    (should-not (get-buffer-window view))
    (harness-ui-display-view view)
    (should (eq 'left (buffer-local-value 'harness-ui-position view)))
    (should (eq (get-buffer-window view) (window-in-direction 'left (get-buffer-window "*scratch*"))))))

(ert-deftest harness-ui-session-opener-replaces-the-view ()
  (harness-ui-test-with-views
    (let ((harness-ui-open-session-function (lambda (_id) other-session)))
      (harness-ui-display-view view 'left)
      (let ((window (get-buffer-window view))
            (open (with-current-buffer view (harness-ui-session-opener))))
        ;; Called later from somewhere else, it still opens in the view's place.
        (select-window (get-buffer-window "*scratch*"))
        (funcall open "sid")
        (should (eq other-session (window-buffer window)))
        (should (eq window (selected-window)))
        (should-not (get-buffer-window view))))))

(provide 'harness-ui-test)
;;; harness-ui-test.el ends here
