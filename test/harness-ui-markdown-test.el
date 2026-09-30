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

(provide 'harness-ui-markdown-test)
;;; harness-ui-markdown-test.el ends here
