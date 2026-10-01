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

(provide 'harness-ui-markdown-test)
;;; harness-ui-markdown-test.el ends here
