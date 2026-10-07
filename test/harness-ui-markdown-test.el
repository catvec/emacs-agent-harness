;;; harness-ui-markdown-test.el --- Tests for the markdown renderer  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui-markdown)

(defun harness-md-test-face-at (string index)
  (let ((f (get-text-property index 'face string)))
    (if (listp f) f (list f))))

(ert-deftest harness-md-inline ()
  (let ((s (harness-ui-markdown-inline "a **bold** and *it* and `code` and [l](http://x) ~~no~~")))
    (should (equal "a bold and it and code and l no" (substring-no-properties s)))
    (should (memq 'bold (harness-md-test-face-at s 2)))
    (should (memq 'italic (harness-md-test-face-at s 11)))
    (should (memq 'harness-md-code (harness-md-test-face-at s 18)))
    (should (equal "http://x" (get-text-property 27 'harness-url s)))
    (should (memq 'harness-md-strike (harness-md-test-face-at s 29)))))

(ert-deftest harness-md-blocks ()
  (let* ((md "# Title\n\nPara one\ncontinues.\n\n- item one\n  wrapped\n- item **two**\n\n1. first\n2. second\n\n> quoted\n> text\n\n```emacs-lisp\n(defun x () 1)\n```\n\n---\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
         (s (harness-ui-markdown-render md))
         (plain (substring-no-properties s)))
    (should (string-prefix-p "Title\n" plain))
    (should (memq 'harness-md-heading-1 (harness-md-test-face-at s 0)))
    (should (string-match-p "Para one continues\\." plain))
    (should (string-match-p "• item one wrapped\n• item two" plain))
    (should (string-match-p "1\\. first\n2\\. second" plain))
    (should (string-match-p "┃ quoted text" plain))
    (should (string-match-p "(defun x () 1)" plain))
    (let ((pos (string-match "(defun" plain)))
      (should (memq 'harness-md-code-block (harness-md-test-face-at s pos)))
      (should (memq 'font-lock-keyword-face (harness-md-test-face-at s (1+ pos)))))
    (should (string-match-p " a +│ b" plain))
    (should (string-match-p " 1 +│ 2" plain))
    ;; List continuation lines wrap under the text.
    (let ((pos (string-match "item one" plain)))
      (should (equal "  " (get-text-property pos 'wrap-prefix s))))))

(ert-deftest harness-md-unclosed-fence-and-empty ()
  (should (equal "" (harness-ui-markdown-render "")))
  (should (string-match-p "still code" (substring-no-properties (harness-ui-markdown-render "```\nstill code"))))
  (should (equal "plain" (substring-no-properties (harness-ui-markdown-render "plain")))))

;; Regression tests for agent answers follow.

(ert-deftest harness-md-list-with-icon-glyphs ()
  ;; A nested list item starting with a nerd-font glyph once signalled
  ;; (wrong-type-argument stringp nil) and left a chat buffer without
  ;; its compose box.
  (let ((plain (substring-no-properties
                (harness-ui-markdown-render
                 "- a pin icon:\n  - \U000F0931 (`nf-md-pin_outline`): weak.\n  - \U000F0403 (`nf-md-pin`): strong."))))
    (should (string-match-p "\U000F0931 (nf-md-pin_outline): weak" plain))
    (should (string-match-p "\U000F0403 (nf-md-pin): strong" plain))))

(ert-deftest harness-md-list-right-after-styled-paragraph ()
  ;; Rendering the paragraph before a block must keep the block's match
  ;; data: "**Title**" then "- item" signalled (stringp nil).
  (let ((plain (substring-no-properties
                (harness-ui-markdown-render "**What it is**\n- It's the `window-state` segment.\n  - nested `code`"))))
    (should (equal "What it is\n\N{U+2022} It's the window-state segment.\n  \N{U+2022} nested code" plain))))

(ert-deftest harness-md-blocks-right-after-styled-paragraph ()
  (should (equal "see x here\nHeading two"
                 (substring-no-properties (harness-ui-markdown-render "see `x` here\n## Heading two"))))
  (should (string-match-p "\\`run ls:\nsh\nls -la"
                          (substring-no-properties (harness-ui-markdown-render "run `ls`:\n```sh\nls -la\n```"))))
  (should (string-match-p "quoted q\\'"
                          (substring-no-properties (harness-ui-markdown-render "a **b** c\n> quoted `q`")))))

(ert-deftest harness-md-link-label-and-url ()
  (let ((s (harness-ui-markdown-inline "see [the docs](https://x.org/a_(b)) now")))
    (should (string-prefix-p "see the docs" (substring-no-properties s)))
    (should (equal "https://x.org/a_(b" (get-text-property 5 'harness-url s)))))

;;;; Following links

(defconst harness-md-test-primary "Open private configuration C-c f P"
  "The primary selection while a test clicks.
The text the bug report saw a click on a link paste into a response.")

(defmacro harness-md-test-with-links (markdown &rest body)
  "Run BODY with MARKDOWN rendered in BUFFER, shown in the selected window.
The text is read-only and rear-nonsticky, as a chat transcript block
is, so an insertion inside it gets through.  BUFFER's directory, DIR,
holds notes.md, five lines long.  OPENED lists the URLs `browse-url'
was given, newest first, and no browser starts.  The primary selection
holds `harness-md-test-primary'."
  (declare (indent 1))
  `(let ((dir (harness-test-temp-dir))
         (buffer (generate-new-buffer "*harness-md-links*"))
         (opened nil))
     (with-temp-file (expand-file-name "notes.md" dir) (insert "one\ntwo\nthree\nfour\nfive\n"))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buffer)
           (delete-other-windows)
           (setq default-directory dir)
           (let ((inhibit-read-only t))
             (insert (propertize (harness-ui-markdown-render ,markdown) 'read-only t 'rear-nonsticky t)))
           (set-buffer-modified-p nil)
           (goto-char (point-min))
           (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (push url opened)))
                     ((symbol-function 'gui-get-primary-selection) (lambda () harness-md-test-primary)))
             ,@body))
       (kill-buffer buffer)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (file-in-directory-p (buffer-file-name b) dir))
           (kill-buffer b)))
       (delete-directory dir t))))

(ert-deftest harness-md-link-click-opens-it-and-nothing-else ()
  "A click on a link opens it and leaves the buffer as it was.
The `follow-link' property makes a quick `mouse-1' on a link `mouse-2',
which the link did not bind: the global `mouse-yank-primary' pasted the
primary selection where the click landed, and nothing opened."
  (harness-md-test-with-links
      "Read [the manual](https://www.gnu.org/software/emacs/manual/) and [the notes](notes.md#L3)."
    (let ((text (buffer-string))
          (url (+ (point-min) (string-search "manual" (buffer-string))))
          (file (+ (point-min) (string-search "notes" (buffer-string)))))
      ;; A quick click arrives as `mouse-2'; a slow one stays `mouse-1'.
      (harness-test-click url)
      (should (equal '("https://www.gnu.org/software/emacs/manual/") opened))
      (let ((mouse-1-click-follows-link nil))
        (harness-test-click url))
      ;; The middle button, and RET.
      (harness-test-click url 2)
      (with-current-buffer buffer
        (goto-char url)
        (execute-kbd-macro (kbd "RET")))
      (should (equal (make-list 4 "https://www.gnu.org/software/emacs/manual/") opened))
      ;; A double or a triple click opens it once, also where only a
      ;; double click follows a link.
      (dolist (follows '(450 double))
        (let ((mouse-1-click-follows-link follows))
          (pcase-dolist (`(,button ,count) '((1 2) (1 3) (2 2)))
            (setq opened nil)
            (harness-test-click url button count)
            (should (equal (list follows button count 1) (list follows button count (length opened)))))))
      ;; A file opens in another window, at the line the link names.
      (harness-test-click file)
      (let ((notes (window-buffer (selected-window))))
        (should (equal (expand-file-name "notes.md" dir) (buffer-file-name notes)))
        (should (= 3 (with-current-buffer notes (line-number-at-pos)))))
      (should (eq buffer (window-buffer (next-window))))
      (with-current-buffer buffer
        (should (equal text (buffer-string)))
        (should-not (buffer-modified-p))))))

(ert-deftest harness-md-link-targets ()
  "A URL goes to `browse-url'; any other target is a file, opened at its line.
A file name is taken in `default-directory'; a file: URL is a file too."
  (harness-md-test-with-links ""
    (with-temp-file (expand-file-name "my notes.md" dir) (insert "a\nb\n"))
    (let ((visited nil))
      (cl-letf (((symbol-function 'find-file-other-window)
                 (lambda (file &rest _) (push file visited) (set-buffer (find-file-noselect file)))))
        (dolist (url '("https://x.org/a?b=c#d" "http://x.org" "mailto:me@x.org"))
          (harness-ui-markdown-open-link url))
        (should (equal '("mailto:me@x.org" "http://x.org" "https://x.org/a?b=c#d") opened))
        (pcase-dolist (`(,target ,file ,line)
                       `(("notes.md" "notes.md" nil)
                         ("./notes.md#L4" "notes.md" 4)
                         ("notes.md#L2-L3" "notes.md" 2)
                         ("notes.md:5" "notes.md" 5)
                         ("notes.md:3:7" "notes.md" 3)
                         ("notes.md#usage" "notes.md" nil)
                         (,(expand-file-name "notes.md" dir) "notes.md" nil)
                         (,(concat "file://" dir "my%20notes.md#L2") "my notes.md" 2)))
          (with-current-buffer buffer
            (harness-ui-markdown-open-link target)
            (should (equal (expand-file-name file dir) (car visited)))
            (when line (should (= line (line-number-at-pos))))))
        ;; None of the files went to the browser.
        (should (= 3 (length opened)))
        (with-current-buffer buffer
          (should-error (harness-ui-markdown-open-link "missing.md") :type 'user-error)
          (should-error (harness-ui-markdown-open-link "#usage") :type 'user-error)
          ;; Not on a link.
          (should-error (harness-ui-markdown-follow-link) :type 'user-error))
        (should (= 8 (length visited)))))))

(provide 'harness-ui-markdown-test)
;;; harness-ui-markdown-test.el ends here
