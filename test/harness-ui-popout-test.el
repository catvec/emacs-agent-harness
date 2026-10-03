;;; harness-ui-popout-test.el --- Tests for popouts  -*- lexical-binding: t; -*-

;;; Commentary:

;; The popout frame on its own, with stand-in owners: drawing and
;; redrawing, reusing a KEY's buffer, its keys, the optional compose
;; box, closing, drafts and the item-at-point hook.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp-server-enabled)
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-ui-popout-key)
(defvar harness-ui-popout-at-point-functions)
(declare-function harness-ui-popout-show "harness-ui-popout")
(declare-function harness-ui-popout-refresh "harness-ui-popout")
(declare-function harness-ui-popout-close "harness-ui-popout")
(declare-function harness-ui-popout-buffer "harness-ui-popout")
(declare-function harness-ui-popout-quit "harness-ui-popout")
(declare-function harness-ui-popout-redraw "harness-ui-popout")
(declare-function harness-ui-popout-submit "harness-ui-popout")
(declare-function harness-ui-popout-at-point "harness-ui-popout")
(declare-function harness-ui-popout-try-at-point "harness-ui-popout")
(declare-function harness-ui-popout--header "harness-ui-popout")
(declare-function harness-compose-live-p "harness-ui-compose")
(declare-function harness-compose-text "harness-ui-compose")

(defmacro harness-ui-popout-test-with (&rest body)
  "Load the UI and the popout module, run BODY, close every popout after."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(acp ui ui-compose ui-popout))
         (harness-test-load-module m)))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           ,@body)
       (dolist (b (buffer-list))
         (when (eq (buffer-local-value 'major-mode b) 'harness-ui-popout-mode)
           (kill-buffer b))))))

(defun harness-ui-popout-test--text (buffer)
  "BUFFER's text, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defvar-local harness-ui-popout-test--kept nil
  "State an owner keeps in its popout buffer.")

(ert-deftest harness-ui-popout-show-draws-and-reuses ()
  "A popout draws its item in a bottom side window; its KEY's buffer is reused."
  (harness-ui-popout-test-with
    (let* ((draws 0)
           (buffer (harness-ui-popout-show '(test 1) "A thing"
                                           (lambda () (cl-incf draws) (insert "Hello\nWorld\n"))))
           (window (get-buffer-window buffer)))
      (should (eq 'harness-ui-popout-mode (buffer-local-value 'major-mode buffer)))
      (should (equal '(test 1) (buffer-local-value 'harness-ui-popout-key buffer)))
      (should (eq buffer (harness-ui-popout-buffer '(test 1))))
      (should (= 1 draws))
      (should (equal "Hello\nWorld\n" (harness-ui-popout-test--text buffer)))
      ;; A selected side window at the bottom, the title in its header.
      (should (eq 'bottom (window-parameter window 'window-side)))
      (should (eq window (selected-window)))
      (let ((header (with-current-buffer buffer (harness-ui-popout--header))))
        (should (string-search "A thing" header))
        (should (string-search "[close]" header)))
      ;; Shown again: the same buffer, its mode not run again, drawn anew.
      (with-current-buffer buffer (setq harness-ui-popout-test--kept 'kept))
      (should (eq buffer (harness-ui-popout-show '(test 1) (lambda () "Renamed")
                                                 (lambda () (insert "Changed\n")))))
      (should (eq 'kept (buffer-local-value 'harness-ui-popout-test--kept buffer)))
      (should (equal "Changed\n" (harness-ui-popout-test--text buffer)))
      (should (string-search "Renamed" (with-current-buffer buffer (harness-ui-popout--header))))
      ;; Another KEY is another popout.
      (should-not (eq buffer (harness-ui-popout-show '(test 2) "Other" (lambda () (insert "x\n"))))))))

(ert-deftest harness-ui-popout-refresh-keeps-point-and-fits ()
  "A refresh draws the item again, point on its line, the window fitted to it."
  (harness-ui-popout-test-with
    (let* ((lines 3)
           (buffer (harness-ui-popout-show
                    '(test fit) "Lines"
                    (lambda () (dotimes (i lines) (insert (format "line %d\n" i)))))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (forward-line 2)
        (move-to-column 3))
      (setq lines 12)
      (should (harness-ui-popout-refresh '(test fit)))
      (with-current-buffer buffer
        (should (= 3 (line-number-at-pos)))
        (should (= 3 (current-column))))
      ;; Taller content, a taller window, within half the frame.
      (let ((window (get-buffer-window buffer)))
        (should (>= (window-body-height window) 8))
        (should (<= (window-total-height window) (floor (* 0.5 (frame-height))))))
      ;; Nothing to refresh once it is closed.
      (harness-ui-popout-close '(test fit))
      (should-not (harness-ui-popout-refresh '(test fit))))))

(ert-deftest harness-ui-popout-keys-under-the-content-keymaps ()
  "q and g work on the content, under the keys and buttons the owner puts there."
  (harness-ui-popout-test-with
    (let* ((owner (make-sparse-keymap))
           (pushed nil)
           (buffer (harness-ui-popout-show
                    '(test keys) "Keys"
                    (lambda ()
                      (define-key owner (kbd "q") #'ignore)
                      (define-key owner (kbd "y") #'ignore)
                      (insert "plain line\n"
                              (propertize "owner's line\n" 'keymap owner)
                              (buttonize "[Push]" (lambda (_) (setq pushed t)))
                              "\n")))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (should (eq 'harness-ui-popout-quit (key-binding (kbd "q"))))
        (should (eq 'harness-ui-popout-redraw (key-binding (kbd "g"))))
        ;; The owner's keys win where it put them.
        (forward-line 1)
        (should (eq 'ignore (key-binding (kbd "q"))))
        (should (eq 'ignore (key-binding (kbd "y"))))
        (should (eq 'harness-ui-popout-redraw (key-binding (kbd "g"))))
        ;; Buttons push.
        (forward-line 1)
        (push-button (point))
        (should pushed)
        ;; The content is read-only.
        (goto-char (+ (point-min) 2))
        (should-error (insert "x") :type 'text-read-only)))))

(ert-deftest harness-ui-popout-compose-box-sends-and-comes-and-goes ()
  "The box shows while :compose returns a SUBMIT; C-c C-c hands it the text."
  (harness-ui-popout-test-with
    (let* ((open t)
           (sent nil)
           (buffer (harness-ui-popout-show
                    '(test box) "Box"
                    (lambda () (insert "Question?\n"))
                    :compose (lambda () (and open (lambda (text atts) (push (cons text atts) sent))))
                    :placeholder "Your answer...")))
      (with-current-buffer buffer
        (should (harness-compose-live-p))
        (should (eq 'harness-ui-popout-submit (key-binding (kbd "C-c C-c"))))
        (goto-char harness-compose-end)
        (insert "half")
        ;; A redraw keeps the text and point in the box.
        (harness-ui-popout-redraw)
        (should (equal "half" (harness-compose-text)))
        (should (= (point) harness-compose-end))
        (insert " typed")
        ;; Typing q in the box is typing, not closing.
        (should-not (eq 'harness-ui-popout-quit (key-binding (kbd "q"))))
        (harness-ui-popout-submit)
        (should (equal '(("half typed")) sent))
        (should (equal "" (harness-compose-text)))
        (should-error (harness-ui-popout-submit) :type 'user-error))
      ;; Without a SUBMIT there is no box, and nothing to send.
      (setq open nil)
      (harness-ui-popout-refresh '(test box))
      (with-current-buffer buffer
        (should-not (harness-compose-live-p))
        (should (equal "Question?\n" (harness-ui-popout-test--text buffer)))
        (should-error (harness-ui-popout-submit) :type 'user-error))
      ;; And back.
      (setq open t)
      (harness-ui-popout-refresh '(test box))
      (with-current-buffer buffer (should (harness-compose-live-p))))))

(ert-deftest harness-ui-popout-close-keeps-the-draft ()
  "Closed by the user, a popout keeps the box's text for next time; its owner hears of it."
  (harness-ui-popout-test-with
    (let* ((closed 0)
           (show (lambda ()
                   (harness-ui-popout-show '(test draft) "Draft" (lambda () (insert "Item\n"))
                                           :compose (lambda () #'ignore)
                                           :on-close (lambda () (cl-incf closed)))))
           (buffer (funcall show)))
      (with-current-buffer buffer
        (goto-char harness-compose-end)
        (insert "not sent yet")
        (goto-char (point-min))
        ;; q on the content closes it.
        (call-interactively (key-binding (kbd "q"))))
      (should-not (buffer-live-p buffer))
      (should-not (harness-ui-popout-buffer '(test draft)))
      (should (= 1 closed))
      (should-not (cl-some (lambda (w) (window-parameter w 'window-side)) (window-list)))
      ;; Shown again, the box holds the text.
      (setq buffer (funcall show))
      (with-current-buffer buffer (should (equal "not sent yet" (harness-compose-text))))
      ;; An owner closing a settled item drops it.
      (harness-ui-popout-close '(test draft) t)
      (should (= 2 closed))
      (setq buffer (funcall show))
      (with-current-buffer buffer (should (equal "" (harness-compose-text)))))))

(ert-deftest harness-ui-popout-at-point-asks-the-views ()
  "The item at point pops out through the functions that know it."
  (harness-ui-popout-test-with
    (with-temp-buffer
      (should-error (harness-ui-popout-at-point) :type 'user-error)
      (should-not (harness-ui-popout-try-at-point))
      (let ((asked nil))
        (add-hook 'harness-ui-popout-at-point-functions (lambda () (push 'first asked) nil) nil t)
        (add-hook 'harness-ui-popout-at-point-functions (lambda () (push 'second asked) t) t t)
        (harness-ui-popout-at-point)
        (should (equal '(second first) asked))))))

(provide 'harness-ui-popout-test)
;;; harness-ui-popout-test.el ends here
