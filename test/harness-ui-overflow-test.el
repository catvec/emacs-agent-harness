;;; harness-ui-overflow-test.el --- Tests for what a bar cut off  -*- lexical-binding: t; -*-

;;; Commentary:

;; A bar that fits is unchanged.  One that has to cut something ends in
;; a clickable …, whose popup shows every hidden part in full and keeps
;; the action of a button the cut took away.  The header fitting, the
;; marks a fitted line carries, and the task board's own fitting -- the
;; lines above its compose box -- are checked here; the chat header and
;; the board header themselves are checked in their own suites.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)
(require 'harness-ui-tasks)

(defun harness-ui-overflow-test--item (label items)
  "Return the item of ITEMS whose label is LABEL."
  (cl-find label items :key (lambda (item) (plist-get item :label)) :test #'equal))

(ert-deftest harness-ui-overflow-fitting-bar-is-unchanged ()
  "A header that fits is exactly as it was, with no overflow control."
  (cl-letf (((symbol-function 'display-graphic-p) #'ignore))
    (with-temp-buffer
      (should (equal " One Two" (harness-ui-fit-header '(" One" (" Two" 5)) 100 t)))
      (should-not harness-ui--header-overflow)
      ;; And a fitted line that fits gets no mark at all.
      (should (equal "short line" (harness-ui-tasks--fit "short line" 20)))
      (should-not (get-text-property 0 'harness-ui-overflow-full
                                     (harness-ui-tasks--fit "short line" 20))))))

(ert-deftest harness-ui-overflow-header-keeps-what-it-cut ()
  "A header that cuts a segment ends in … and remembers its full text and action.
The segments that were dropped and those shortened to their MIN are
both there, in display order; a header that fits has none."
  (cl-letf (((symbol-function 'display-graphic-p) #'ignore))
    (with-temp-buffer
      (let* ((ran nil)
             (segments (list " One"
                             (list " Two" 5 nil (lambda () (interactive) (setq ran t)))
                             " Three"))
             (header (harness-ui-fit-header segments 12 t))
             (ellipsis (1- (length header))))
        (should (equal " One Three …" (substring-no-properties header)))
        (should (equal harness-ui-overflow-map
                       (get-text-property ellipsis 'keymap header)))
        (should (string-match-p "Overflow"
                                (get-text-property ellipsis 'help-echo header)))
        (should (eq 'harness-ui-overflow-face
                    (get-text-property ellipsis 'face header)))
        (let* ((report (harness-ui-overflow-report))
               (items (cdr report)))
          (should (equal "Header" (car report)))
          (should (equal '("Two") (mapcar (lambda (item) (plist-get item :label)) items)))
          (should (equal "Two" (plist-get (car items) :text)))
          (funcall (plist-get (car items) :action))
          (should ran))))
    ;; A MIN is enough: the segment stays, shortened, and is still whole
    ;; in the overflow popup.
    (with-temp-buffer
      (let* ((header (harness-ui-fit-header '(" One" (" Wide Name" t " W…")) 10 t))
             (items harness-ui--header-overflow))
        (should (equal " One W… …" (substring-no-properties header)))
        (should (equal '("Wide Name")
                       (mapcar (lambda (item) (plist-get item :label)) items)))
        (should (equal "Wide Name" (plist-get (car items) :text)))))))

(ert-deftest harness-ui-overflow-mark-covers-line-and-buttons ()
  "A fitted line's … knows the whole line and every button the cut took.
It works from a point on the line as well as from the … itself."
  (with-temp-buffer
    (let* ((ran nil)
           (button (buttonize "[Refresh]" (lambda (_) (setq ran t)) nil "Reload the board"))
           (full (concat "  Settings "
                         (make-string 24 ?x)
                         "   " button))
           (line (harness-ui-overflow-mark
                  (concat (substring full 0 14) "…")
                  full
                  "Task bar")))
      (insert line)
      (dolist (pos (list (1- (length line)) 2))
        (let* ((report (harness-ui-overflow-report pos))
               (items (cdr report))
               (button-item (harness-ui-overflow-test--item "[Refresh]" items)))
          (should (equal "Task bar" (car report)))
          (should (equal (string-trim (substring-no-properties full))
                         (plist-get (car items) :text)))
          (should button-item)
          (should (equal "Reload the board" (plist-get button-item :help)))
          (funcall (plist-get button-item :action))
          (should ran)
          (setq ran nil))))))

(ert-deftest harness-ui-overflow-report-finds-the-bar-above ()
  "From a line below, the report is the nearest fitted bar's, not the header's.
A reader in a compose box, under the line that bars it, gets that line."
  (with-temp-buffer
    (let ((line (harness-ui-overflow-mark
                 (concat (make-string 20 ?x) "…")
                 (concat (make-string 40 ?x) " hidden words")
                 "Task bar")))
      (insert line "\n")
      (setq-local harness-ui--header-overflow
                  (list (list :label "header" :text "header")))
      (insert "the compose box\n")
      (goto-char (point-max))
      (let ((report (harness-ui-overflow-report)))
        (should (equal "Task bar" (car report)))
        (should (string-match-p "hidden words"
                                (plist-get (car (cdr report)) :text)))))))

(ert-deftest harness-ui-overflow-report-finds-a-cut-in-the-middle ()
  "A bar can cut mid-line: settings shortened, the note after them whole.
The … and the report are found from anywhere on the line, and from
the compose box below, whose own line carries no mark."
  (with-temp-buffer
    (let* ((note (propertize "  note stays" 'face 'bold))
           (settings (concat "settings " (make-string 60 ?y)))
           (line (harness-ui-tasks--fit-settings settings note t 40)))
      (should (equal 40 (string-width line)))
      (should (string-match-p "…" line))
      (should-not (string-suffix-p "…" (substring-no-properties line)))
      (insert line "\n" "the compose box\n")
      (dolist (place (list (point-min)
                           (1+ (string-match-p "…" line))
                           (1- (line-end-position))))
        (let* ((report (harness-ui-overflow-report place))
               (item (car (cdr report))))
          (should (equal "Task bar" (car report)))
          (should (string-match-p "settings yyy" (plist-get item :text)))))
      ;; From the box below, with no mark of its own, the bar above is meant.
      (goto-char (point-max))
      (let ((report (harness-ui-overflow-report)))
        (should (equal "Task bar" (car report)))
        (should (string-match-p "settings yyy"
                                (plist-get (car (cdr report)) :text)))))))

(ert-deftest harness-ui-overflow-popup-shows-everything-in-full ()
  "The popup shows each hidden part whole, wrapped, with its action.
Labels are short: the part's text and a word for what a click does, no
sentence.  A click or RET runs the action in the buffer the bar belongs
to."
  (let* ((origin (get-buffer-create " *overflow origin*"))
         (ran nil)
         (item (list :label "Model"
                     :text "Model (a long demo model) that the bar cut"
                     :help "Model (mouse-1: change)"
                     :command 'harness-set-model
                     :action (lambda () (setq ran t)))))
    (unwind-protect
        (with-temp-buffer
          (setq-local harness-ui-overflow--origin origin)
          (harness-ui-overflow--fill "Header" (list item))
          (should (equal " Header " header-line-format))
          (should (string-match-p
                   "Model (a long demo model) that the bar cut" (buffer-string)))
          (should (string-match-p "\\[change\\]" (buffer-string)))
          (should-not (string-match-p "mouse-1" (buffer-string)))
          (should (string-match-p "q close" (buffer-string)))
          ;; The text carries the action, and running it uses the origin.
          (goto-char (point-min))
          (search-forward "Model (a long demo model)")
          (should (get-text-property (point) 'button))
          (should (functionp (lookup-key (get-text-property (point) 'keymap)
                                         (kbd "RET"))))
          (harness-ui-overflow--run item)
          (should ran))
      (kill-buffer origin))))

(ert-deftest harness-ui-overflow-task-bar-keeps-hidden-buttons ()
  "A task board bar that is cut keeps its whole text and clipped buttons.
`harness-ui-tasks--fit' is what the settings, notice and compose-label
lines use; a line that fits is left alone."
  (with-temp-buffer
    (let* ((ran nil)
           (button (harness-ui-tasks--button "[Archive]"
                                             (lambda () (setq ran t))
                                             "Archive the task"))
           (full (concat "  " (make-string 40 ?x) "   " button))
           (line (harness-ui-tasks--fit full 20 t)))
      (insert line)
      (should (string-suffix-p "…" (substring-no-properties line)))
      ;; A card's title, which is fitted without OVERFLOW, has no control.
      (let ((plain (harness-ui-tasks--fit full 20)))
        (should-not (get-text-property (1- (length plain))
                                       'harness-ui-overflow-items plain)))
      (should (keymapp (get-text-property (1- (length line)) 'keymap line)))
      (should (harness-ui-overflow-test--item
               "[Archive]" (get-text-property (1- (length line))
                                              'harness-ui-overflow-items line)))
      ;; Clicking the … opens the popup with the same hidden button.
      (let ((popup nil))
        (cl-letf (((symbol-function 'harness-ui--display-menu)
                   (lambda (buffer _alist) (setq popup buffer))))
          (funcall (lookup-key (get-text-property (1- (length line)) 'keymap line)
                               [mouse-1])
                   nil)
          (should popup)
          (with-current-buffer popup
            (should (string-match-p "\\[Archive\\]" (buffer-string))))
          (kill-buffer popup)))
      (let* ((items (cdr (harness-ui-overflow-report (1- (length line)))))
             (item (harness-ui-overflow-test--item "[Archive]" items)))
        (should (equal (string-trim (substring-no-properties full))
                       (plist-get (car items) :text)))
        (should item)
        (funcall (plist-get item :action))
        (should ran)))))

(provide 'harness-ui-overflow-test)
;;; harness-ui-overflow-test.el ends here
