;;; harness-ui-popout-test.el --- Tests for popouts  -*- lexical-binding: t; -*-

;;; Commentary:

;; The popout frame on its own, with stand-in owners: drawing and
;; redrawing, reusing a KEY's buffer, its keys, the optional compose
;; box, closing, drafts and the item-at-point hook.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
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
(declare-function harness-ui-popout-image "harness-ui-popout")
(declare-function harness-ui-image-load-flush "harness-ui")
(declare-function harness-ui-popout-pixel-height "harness-ui-popout")
(declare-function harness-ui-popout-pixel-width "harness-ui-popout")
(declare-function harness-compose-live-p "harness-ui-compose")
(declare-function harness-compose-text "harness-ui-compose")
(declare-function harness-compose-in-p "harness-ui-compose")
(declare-function harness-ui-popout--follow "harness-ui-popout")
(defvar harness-ui-popout-max-height)
(defvar harness-ui-popout-image-max-height)
(defvar harness-ui-popout--parent)
(defvar harness-ui-popout--max-height)

(defmacro harness-ui-popout-test-with (&rest body)
  "Load the UI and the popout module, run BODY, close every popout after."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
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

(ert-deftest harness-ui-popout-typing-on-the-content-goes-into-the-box ()
  "Typing on the content of a popout with a box goes into the box.
q and g stay the content's keys."
  (harness-ui-popout-test-with
    (let ((buffer (harness-ui-popout-show
                   '(test typing) "Typing"
                   (lambda () (insert "Question?\n"))
                   :compose (lambda () #'ignore)
                   :placeholder "Your answer...")))
      (with-selected-window (get-buffer-window buffer)
        (goto-char (point-min))
        (execute-kbd-macro "yes")
        (should (equal "yes" (harness-compose-text)))
        (should (= (point) harness-compose-end))
        (should (equal "Question?\n" (buffer-substring-no-properties (point-min) (+ (point-min) 10))))
        (goto-char (point-min))
        (should (eq 'harness-ui-popout-quit (key-binding "q")))
        (should (eq 'harness-ui-popout-redraw (key-binding "g")))))))

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

(ert-deftest harness-ui-popout-max-height-is-the-popouts-own ()
  "A popout's :max-height lets it grow past the popouts' common limit, and
sizes what it draws: `harness-ui-popout-pixel-height' follows it."
  (harness-ui-popout-test-with
    (let* ((lines (lambda () (dotimes (i 40) (insert (format "line %d\n" i)))))
           (plain (harness-ui-popout-show '(test plain) "Plain" lines))
           (plain-height (window-total-height (get-buffer-window plain)))
           (plain-room (with-current-buffer plain (harness-ui-popout-pixel-height))))
      (should (<= plain-height (floor (* harness-ui-popout-max-height (frame-height)))))
      (harness-ui-popout-close '(test plain))
      (let* ((tall (harness-ui-popout-show '(test tall) "Tall" lines :max-height 0.8))
             (window (get-buffer-window tall)))
        (should (> (window-total-height window) plain-height))
        (should (<= (window-total-height window) (floor (* 0.8 (frame-height)))))
        (with-current-buffer tall
          (should (> (harness-ui-popout-pixel-height) plain-room))
          ;; LINES of text beside it take their room off.
          (should (= (- (harness-ui-popout-pixel-height) (* 2 (frame-char-height)))
                     (harness-ui-popout-pixel-height 2)))
          ;; Showing, its width is its window's; or another window's,
          ;; for what is drawn to show there.
          (should (= (window-body-width window t) (harness-ui-popout-pixel-width)))
          (let ((main (window-main-window)))
            (should (= (window-body-width main t) (harness-ui-popout-pixel-width main)))))))))

(ert-deftest harness-ui-popout-box-stays-in-sight ()
  "Content taller than its popout keeps the box on the window's last line while
point is in the box, with no gap under it; content that fits shows from
its start again.  Point on the content leaves the window where it is."
  (harness-ui-popout-test-with
    (let* ((lines 3)
           (buffer (harness-ui-popout-show
                    '(test tall-box) "Tall"
                    (lambda () (dotimes (i lines) (insert (format "line %d\n" i))))
                    :compose (lambda () #'ignore)))
           (window (get-buffer-window buffer)))
      (with-selected-window window (goto-char harness-compose-end))
      ;; The content grows past what the window may show.
      (setq lines 80)
      (harness-ui-popout-refresh '(test tall-box))
      (with-current-buffer buffer
        (should (harness-compose-in-p (window-point window)))
        (should (> (window-start window) (point-min)))
        ;; The box's line is the window's last: nothing under it.  (A
        ;; batch Emacs never says a position is visible: lines are
        ;; counted instead.)
        (should (= (window-body-height window)
                   (count-screen-lines (window-start window) harness-compose-end nil window))))
      ;; It shrinks: it shows from its start, not from where it had
      ;; scrolled to.
      (setq lines 3)
      (harness-ui-popout-refresh '(test tall-box))
      (with-current-buffer buffer
        (should (= (point-min) (window-start window)))
        (should (harness-compose-in-p (window-point window))))
      ;; Point on the content: a refresh leaves the window at its start.
      (with-selected-window window (goto-char (point-min)))
      (setq lines 80)
      (harness-ui-popout-refresh '(test tall-box))
      (with-current-buffer buffer
        (should (= (point-min) (window-start window)))
        (should (= (point-min) (window-point window)))))))

(ert-deftest harness-ui-popout-box-follows-a-resize ()
  "A popout's window shrunk after it was drawn -- the echo area grew, say --
is scrolled again before it is redisplayed, the box on its last line.
Nothing changed since, nothing is done again."
  (harness-ui-popout-test-with
    (let* ((buffer (harness-ui-popout-show
                    '(test resized) "Resized"
                    (lambda () (dotimes (i 80) (insert (format "line %d\n" i))))
                    :compose (lambda () #'ignore)))
           (window (get-buffer-window buffer))
           (scroll (symbol-function 'harness-ui-popout--scroll))
           (scrolls 0)
           (box-last-p (lambda ()
                         (with-current-buffer buffer
                           (= (window-body-height window)
                              (count-screen-lines (window-start window) harness-compose-end nil window))))))
      (with-selected-window window
        (goto-char harness-compose-end)
        (harness-ui-popout-redraw)
        (should (funcall box-last-p))
        ;; Two lines fewer, the start where it was: the box is below the
        ;; window's bottom.
        (window-resize window -2 nil t)
        (should-not (funcall box-last-p))
        (cl-letf (((symbol-function 'harness-ui-popout--scroll)
                   (lambda (w) (cl-incf scrolls) (funcall scroll w))))
          (harness-ui-popout--follow window)
          (should (funcall box-last-p))
          (harness-ui-popout--follow window)
          (should (= 1 scrolls)))))))

(ert-deftest harness-ui-popout-parent-gets-its-window-back ()
  "A popout opened from another takes its window and says [back]; closing it
shows the other one there again, where it was."
  (harness-ui-popout-test-with
    (let* ((parent (harness-ui-popout-show '(test parent) "The report"
                                           (lambda () (dotimes (i 6) (insert (format "report line %d\n" i))))))
           (window (get-buffer-window parent)))
      (with-current-buffer parent
        (goto-char (point-min))
        (forward-line 3))
      (let ((child (harness-ui-popout-show '(test child) "An image" (lambda () (insert "big image\n"))
                                           :parent '(test parent))))
        ;; The same window, the parent hidden but alive.
        (should (eq child (window-buffer window)))
        (should (eq window (selected-window)))
        (should (buffer-live-p parent))
        (should-not (get-buffer-window parent))
        (let ((header (with-current-buffer child (harness-ui-popout--header))))
          (should (string-search "[back]" header))
          (should-not (string-search "[close]" header)))
        ;; q goes back: the parent shows in that window again, selected,
        ;; point where it was.
        (with-current-buffer child
          (goto-char (point-min))
          (call-interactively (key-binding (kbd "q"))))
        (should-not (buffer-live-p child))
        (should (window-live-p window))
        (should (eq parent (window-buffer window)))
        (should (eq window (selected-window)))
        (should (= 4 (with-current-buffer parent (line-number-at-pos (window-point window)))))
        (should (string-search "[close]" (with-current-buffer parent (harness-ui-popout--header))))
        ;; Closing that one closes the window: nothing to go back to.
        (harness-ui-popout-close '(test parent))
        (should-not (cl-some (lambda (w) (window-parameter w 'window-side)) (window-list)))))))

(ert-deftest harness-ui-popout-hidden-children-close-with-their-parent ()
  "A popout opened from another that no window shows any more closes with it."
  (harness-ui-popout-test-with
    (harness-ui-popout-show '(test parent) "Parent" (lambda () (insert "parent\n")))
    (let ((child (harness-ui-popout-show '(test child) "Child" (lambda () (insert "child\n"))
                                         :parent '(test parent))))
      ;; The parent is shown again from elsewhere, over the child.
      (harness-ui-popout-show '(test parent) "Parent" (lambda () (insert "parent\n")))
      (should-not (get-buffer-window child))
      (harness-ui-popout-close '(test parent))
      (should-not (buffer-live-p child))
      (should-not (harness-ui-popout-buffer '(test child))))))

(ert-deftest harness-ui-popout-image-shows-an-image-of-its-own ()
  "An image popout shows one image file, named in its header, as tall as
`harness-ui-popout-image-max-height' lets it; its parent gets it back."
  (harness-ui-popout-test-with
    (let ((file (make-temp-file "harness-popout-" nil ".svg"
                                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"/>")))
      (unwind-protect
          (progn
            (harness-ui-popout-show '(test report) "Report" (lambda () (insert "report\n")))
            (let ((buffer (harness-ui-popout-image file :parent '(test report) :title "Task: shot.svg")))
              (should (eq buffer (harness-ui-popout-buffer (list 'image file))))
              (with-current-buffer buffer
                (should (equal '(test report) harness-ui-popout--parent))
                (should (= harness-ui-popout-image-max-height harness-ui-popout--max-height))
                (should (string-search "Task: shot.svg" (harness-ui-popout--header)))
                (should (string-search "[back]" (harness-ui-popout--header)))
                (let ((text (buffer-string)))
                  (should (string-search (file-name-nondirectory file) text))
                  (should (string-search "[Open externally]" text))
                  ;; A batch Emacs shows no images: it says so.
                  (should (string-search "open it to see it" text))))
              (harness-ui-popout-close (list 'image file))
              (should (harness-ui-popout-buffer '(test report)))
              (should (get-buffer-window (harness-ui-popout-buffer '(test report)))))
            ;; With images, one that cannot be decoded says so, and is
            ;; never read when it is remote.  An image is drawn after the
            ;; popout shows, so the buffer is drawn out to see it.
            (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
              (with-current-buffer (harness-ui-popout-image file)
                (should (string-search "loading…" (buffer-string)))
                (harness-ui-image-load-flush)
                (should (string-search "cannot be shown here" (buffer-string))))
              (let ((text (with-current-buffer (harness-ui-popout-image "/ssh:nowhere.invalid:/tmp/x.png")
                            (buffer-string))))
                (should (string-search "remote image is not read here" text))))
            (let ((text (with-current-buffer (harness-ui-popout-image "/no/such/image.png") (buffer-string))))
              (should (string-search "cannot be read" text))))
        (delete-file file)))))

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

(ert-deftest harness-ui-popout-box-presses-a-key-of-the-content ()
  "C-c . in a popout's box presses q or g on its content, and says so.
The content is a panel of the box (`harness-compose-panel-key') but for
the panels its owner drew and named: its text keeps those names.  The
popout's keys type in the box otherwise.  The box's tooltip names the key."
  (harness-ui-popout-test-with
    (let* ((draws 0)
           (closed 0)
           (buffer (harness-ui-popout-show
                    '(test panel) "Panel"
                    (lambda ()
                      (cl-incf draws)
                      (insert "Before\n"
                              (propertize "Owner's panel\n" 'harness-compose-panel "request-1")
                              "After\n"))
                    :compose (lambda () #'ignore)
                    :on-close (lambda () (cl-incf closed)))))
      (with-selected-window (get-buffer-window buffer)
        (with-current-buffer buffer
          ;; What the owner named is its own; the rest of the content is the popout's.
          (should (eq 'popout (get-text-property (point-min) 'harness-compose-panel)))
          (should (equal "request-1" (get-text-property (+ (point-min) (length "Before\n")) 'harness-compose-panel)))
          (should (eq 'popout (get-text-property (- harness-compose-start 3) 'harness-compose-panel)))
          (should-not (get-text-property (1- harness-compose-start) 'harness-compose-panel))
          (should (eq 'harness-compose-panel-key (key-binding (kbd "C-c ."))))
          ;; The tooltip of the box's prompt names the key.
          (should (string-match-p "C-c \\. KEY: a key of the panel above"
                                  (get-text-property (1- harness-compose-start) 'help-echo)))
          (goto-char harness-compose-end)
          (insert "draft")
          (goto-char (+ harness-compose-start 2))
          ;; Typing q and g in the box types them.
          (execute-kbd-macro "qg")
          (should (equal "drqgaft" (harness-compose-text)))
          ;; g draws the content again, and point is back in the box.
          (execute-kbd-macro (kbd "C-c . g"))
          (should (= 2 draws))
          (should (equal "drqgaft" (harness-compose-text)))
          (should (= (point) (+ harness-compose-start 4)))
          ;; q closes the popout, which keeps the draft.
          (execute-kbd-macro (kbd "C-c . q"))))
      (should-not (buffer-live-p buffer))
      (should (= 1 closed))
      (should (equal "drqgaft" (with-current-buffer (harness-ui-popout-show
                                                     '(test panel) "Panel" (lambda () (insert "Item\n"))
                                                     :compose (lambda () #'ignore))
                                 (harness-compose-text)))))))

(ert-deftest harness-ui-popout-menu-lists-the-panel-key ()
  "The popout's entry in the menu lists the key to press a key of its content."
  (harness-ui-popout-test-with
    (let* ((entries (cl-loop for column in (cdr (get 'harness-ui-popout-mode 'harness-menu-group))
                             append (cl-loop for item across column
                                             when (and (consp item) (stringp (car item))) collect item)))
           (item (cl-find "C-c ." entries :key #'car :test #'equal)))
      (should item)
      (should (eq 'harness-compose-panel-key (nth 2 item))))))

(provide 'harness-ui-popout-test)
;;; harness-ui-popout-test.el ends here
