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

(defun harness-md-test-faced-parts (string)
  "Return the parts of STRING that have a face, as plain text, in order."
  (let ((parts nil) (pos 0))
    (while (< pos (length string))
      (let ((next (or (next-single-property-change pos 'face string) (length string))))
        (when (get-text-property pos 'face string)
          (push (substring-no-properties string pos next) parts))
        (setq pos next)))
    (nreverse parts)))

(ert-deftest harness-md-emphasis-needs-text-against-its-markers ()
  "Stars and underscores with a blank against them, in arithmetic, C, Python,
globs and names, stay as they are: none of the text between two of them turns
into emphasis, and no marker vanishes."
  (dolist (text '("2 * 3 * 4" "char *p and char *q" "pass *args and **kwargs through"
                  "all *.el and *.py files" "src/**/*.py is a glob" "a ** b ** c" "a _ b _ c"
                  "call _private_method here" "see _foo_bar" "x_ y_ z" "snake_case_name"
                  "*" "**" "_" "__"))
    (ert-info ((format "%S" text))
      (let ((s (harness-ui-markdown-inline text)))
        (should (equal text (substring-no-properties s)))
        (should-not (harness-md-test-faced-parts s)))))
  ;; Emphasis with its text against its markers is emphasis.
  (dolist (case '(("*it* and **bold** and _it_ and __bold__" "it" "bold" "it" "bold")
                  ("*a* and **a**" "a" "a")
                  ("a *b c* d, **e f g** and _h i_" "b c" "e f g" "h i")
                  ("**Fixed:** done, (_it_), _it_." "Fixed:" "it" "it")
                  ("**bold *and italic* inside**" "bold " "and italic" " inside")
                  ;; A marker that opens none is the text before the one that does.
                  ("**a **b**" "b")
                  ("2 * 3 and *x*" "x")
                  ;; The character before the marker stays what it was.
                  ("_*a*" "a")
                  ("*_a_*" "a")))
    (ert-info ((format "%S" (car case)))
      (should (equal (cdr case) (harness-md-test-faced-parts (harness-ui-markdown-inline (car case)))))))
  (should (equal "_a" (substring-no-properties (harness-ui-markdown-inline "_*a*"))))
  (should (equal "**a b" (substring-no-properties (harness-ui-markdown-inline "**a **b**")))))

(ert-deftest harness-md-angle-brackets-make-a-link-only-around-a-url ()
  "Text in angle brackets that is no URL, a type or a placeholder, keeps its brackets."
  (dolist (text '("List<Foo> and Vec<String>" "a <b> c" "<file.txt> and <x/y>" "1 < 2 > 0" "<>"))
    (ert-info ((format "%S" text))
      (let ((s (harness-ui-markdown-inline text)))
        (should (equal text (substring-no-properties s)))
        (should-not (cl-some (lambda (i) (get-text-property i 'harness-url s))
                             (number-sequence 0 (max 0 (1- (length s)))))))))
  (let ((s (harness-ui-markdown-inline "see <https://x.org/a?b=1> and <mailto:me@x.org>.")))
    (should (equal "see https://x.org/a?b=1 and mailto:me@x.org." (substring-no-properties s)))
    (should (equal "https://x.org/a?b=1" (get-text-property (string-search "x.org/a" s) 'harness-url s)))
    (should (equal "mailto:me@x.org" (get-text-property (string-search "me@" s) 'harness-url s)))))

(ert-deftest harness-md-emphasis-markers-take-time-linear-in-the-text ()
  "A text full of markers that open nothing is read in time that grows with it.
Asking the regexp itself for text against the markers searched to the
end of the text from each marker -- minutes for this one -- where
asking after it finds the marker's end next to it."
  (let ((start (float-time)))
    (dolist (text (list (apply #'concat (make-list 30000 "**a "))
                        (apply #'concat (make-list 30000 "*a "))
                        (apply #'concat (make-list 30000 "_a "))))
      (should (stringp (harness-ui-markdown-render text))))
    (should (< (- (float-time) start) 20))))

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

(ert-deftest harness-md-code-block-fontified-once ()
  "A code block rendered again, as a message streaming in is, is not fontified again.
Fontifying runs the language's major mode in a buffer of its own, and a
long message was rendered whole, each of its blocks fontified, every
few tenths of a second as it streamed in."
  (let ((harness-ui-markdown--fontified (make-hash-table :test 'equal))
        (harness-ui-markdown--fontified-size 0)
        (calls 0)
        (fontify-in (symbol-function 'harness-ui-markdown--fontify-in)))
    (cl-letf (((symbol-function 'harness-ui-markdown--fontify-in)
               (lambda (&rest args) (cl-incf calls) (apply fontify-in args))))
      (dotimes (_ 3)
        (let* ((s (harness-ui-markdown-render "Some code:\n\n```emacs-lisp\n(defun x () 1)\n```\n"))
               (pos (string-match "(defun" s)))
          (should (memq 'harness-md-code-block (harness-md-test-face-at s pos)))
          (should (memq 'font-lock-keyword-face (harness-md-test-face-at s (1+ pos))))))
      (should (= 1 calls))
      ;; Other code is fontified anew.
      (harness-ui-markdown-render "```emacs-lisp\n(defvar y 2)\n```\n")
      (should (= 2 calls))
      (should (= 2 (hash-table-count harness-ui-markdown--fontified)))
      ;; Past its size the cache starts over.
      (let ((harness-ui-markdown--fontified-max 20))
        (harness-ui-markdown-render "```emacs-lisp\n(defvar a-longer-name 3)\n```\n"))
      (should (= 3 calls))
      (should (= 1 (hash-table-count harness-ui-markdown--fontified))))))

(ert-deftest harness-md-unclosed-fence-and-empty ()
  (should (equal "" (harness-ui-markdown-render "")))
  (should (string-match-p "still code" (substring-no-properties (harness-ui-markdown-render "```\nstill code"))))
  (should (equal "plain" (substring-no-properties (harness-ui-markdown-render "plain")))))

(ert-deftest harness-md-horizontal-rule-checked-without-regexp ()
  "A horizontal rule renders as one, and an enormous line of one character does not overflow.
The regexp that recognized a rule backtracked through a line of a
hundred thousand characters until the regexp engine gave up with
\"Stack overflow in regexp matcher\", taking the whole rendering of a
message with it (2026-10-09)."
  (dolist (rule '("---" "- - -" "***" "___" "  * * *  "))
    (should (eq 'harness-md-rule (get-text-property 0 'face (harness-ui-markdown-render rule)))))
  (dolist (text '("-" "*-*" "a - - -" "    ---" "--*"))
    (should-not (eq 'harness-md-rule (get-text-property 0 'face (harness-ui-markdown-render text)))))
  ;; The line that overflowed: rendered as the text it is.
  (should (stringp (harness-ui-markdown-render (make-string 200000 ?-))))
  (should (stringp (harness-ui-markdown-render (make-string 200000 ?x)))))

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

;;;; Reading rendered text back

(defun harness-md-test-source (markdown &optional from to)
  "Render MARKDOWN in a buffer and read it back from FROM to TO.
FROM and TO are texts of the rendering: the read starts at FROM and
ends after TO, the whole rendering by default."
  (with-temp-buffer
    (insert (harness-ui-markdown-render markdown))
    (let ((beg (if from (progn (goto-char (point-min)) (search-forward from) (match-beginning 0)) (point-min)))
          (end (if to (progn (goto-char (point-min)) (search-forward to) (point)) (point-max))))
      (harness-ui-markdown-source beg end))))

(ert-deftest harness-md-source-reads-the-rendering-back ()
  "What the renderer drew of its own reads back as the Markdown it was:
a code block's fences and language, inline code, a link's target, the
bullets and the quote bars.  Emphasis and headings, faces alone, read
as plain text, and a link that is its own URL as the URL."
  (should (equal (concat "Title\n\nSee `x` in [the docs](https://x.org) or https://y.org\n\n"
                         "- one\n  - two\n\n1. first\n\n```elisp\n(defun x () 1)\n```\n\n"
                         "> quoted text\n\nbold end")
                 (harness-md-test-source
                  (concat "# Title\n\nSee `x` in [the docs](https://x.org) or https://y.org\n\n"
                          "- one\n  - two\n\n1. first\n\n```elisp\n(defun x () 1)\n```\n\n"
                          "> quoted\n> *text*\n\n**bold** end"))))
  ;; A block with no language has bare fences.
  (should (equal "```\nno lang\n```\nafter" (harness-md-test-source "```\nno lang\n```\nafter"))))

(ert-deftest harness-md-source-of-part-of-a-code-block ()
  "Part of a code block reads back fenced, under the whole block's language.
The part may start in the code or in the language's label line; the
fence closes on a line of its own, wherever the part ends."
  (let ((md "```elisp\n(defun foo ()\n  (bar))\n```"))
    (should (equal "```elisp\n  (bar))\n```\n" (harness-md-test-source md "  (bar)")))
    (should (equal "```elisp\n(defun foo ()\n```\n" (harness-md-test-source md "isp" "foo ()")))))

(ert-deftest harness-md-source-leaves-out-what-does-not-show ()
  "Invisible text, by a property or an overlay as a folded block's, is left out."
  (with-temp-buffer
    (insert "one two three four")
    (put-text-property 5 9 'invisible t)
    (add-to-invisibility-spec 'folded)
    (overlay-put (make-overlay 9 15) 'invisible 'folded)
    (should (equal "one four" (harness-ui-markdown-source (point-min) (point-max))))
    ;; Unfolded, it shows, and reads back.
    (remove-from-invisibility-spec 'folded)
    (should (equal "one three four" (harness-ui-markdown-source (point-min) (point-max))))))

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

;;;; Code is meant literally

(ert-deftest harness-md-code-at-p-says-where-the-renderer-drew-code ()
  "Inline code and a fenced block are code; the text around them, a heading,
a link label and a list item are not."
  (let* ((s (harness-ui-markdown-render
             "# Head\n\nplain `inline` and [a link](https://e.org).\n\n- an item\n\n```sh\nfenced line\n```\n"))
         (at (lambda (text) (string-search text s))))
    (dolist (text '("inline" "fenced line"))
      (ert-info (text)
        (should (harness-ui-markdown-code-at-p s (funcall at text)))
        (should (harness-ui-markdown-code-at-p s (+ (funcall at text) (1- (length text)))))))
    (dolist (text '("Head" "plain" "and" "a link" "an item"))
      (ert-info (text)
        (should-not (harness-ui-markdown-code-at-p s (funcall at text)))))
    ;; The language a block names is part of the block.
    (should (harness-ui-markdown-code-at-p s (funcall at "sh")))))

;;;; Links to the harness

(defun harness-md-test-url-at (string text)
  "Return the `harness-url' of the first TEXT in STRING."
  (get-text-property (string-search text string) 'harness-url string))

(ert-deftest harness-md-harness-links-are-links ()
  "A link to a session, a message, a call or a thread renders as the label it was given."
  (let ((s (harness-ui-markdown-inline
            (concat "See [the run](harness:call/bash#2), [the plan](harness:session/abc/message/n-1) "
                    "and [that thread](harness:task/t-4/thread/t-3)."))))
    (should (equal "See the run, the plan and that thread." (substring-no-properties s)))
    (should (equal "harness:call/bash#2" (harness-md-test-url-at s "the run")))
    (should (equal "harness:session/abc/message/n-1" (harness-md-test-url-at s "the plan")))
    (should (equal "harness:task/t-4/thread/t-3" (harness-md-test-url-at s "that thread")))
    (dolist (label '("the run" "the plan" "that thread"))
      (let ((pos (string-search label s)))
        (should (memq 'link (harness-md-test-face-at s pos)))
        (should (get-text-property pos 'keymap s))
        (should (get-text-property pos 'follow-link s))))
    ;; The tooltip says what the click opens, not the URL.
    (should (string-match-p "tool call bash#2"
                            (get-text-property (string-search "the run" s) 'help-echo s)))
    (should (string-match-p "message n-1"
                            (get-text-property (string-search "the plan" s) 'help-echo s)))))

(ert-deftest harness-md-harness-autolinks-and-bare-links-read-as-what-they-name ()
  "A link with no words of its own shows words made from what it names."
  (let ((s (harness-ui-markdown-inline "Ask <harness:session/abc>, see harness:thread/t-3. Or harness:call/last, then.")))
    (should (equal "Ask session abc, see thread t-3. Or tool call last, then."
                   (substring-no-properties s)))
    (should (equal "harness:session/abc" (harness-md-test-url-at s "session abc")))
    ;; The full stop that ends the sentence is the sentence's.
    (should (equal "harness:thread/t-3" (harness-md-test-url-at s "thread t-3")))
    (should-not (get-text-property (+ (string-search "thread t-3" s) (length "thread t-3")) 'harness-url s))
    (should (equal "harness:call/last" (harness-md-test-url-at s "tool call last")))
    (should-not (get-text-property (+ (string-search "tool call last" s) (length "tool call last")) 'harness-url s))))

(ert-deftest harness-md-harness-links-leave-alone-what-is-not-one ()
  (dolist (text '("The harness: it runs." "harness:foo/bar" "the harness:8080 port" "xharness:session/abc"
                  "see https://example.org/harness:session/abc"
                  "`[x](harness:call/last)` and `harness:call/last`"
                  "<harness> and harness:"))
    (ert-info ((format "%S" text))
      (let ((s (harness-ui-markdown-inline text)))
        ;; Only the web address of the one case is a link, and not to the harness.
        (should-not (cl-some (lambda (i)
                               (let ((url (get-text-property i 'harness-url s)))
                                 (and url (harness-links-p url))))
                             (number-sequence 0 (max 0 (1- (length s))))))))))

(ert-deftest harness-md-harness-links-nest-in-markup ()
  "A link in a list, a heading, a table, a quote or bold is a link."
  (let ((s (harness-ui-markdown-render
            (concat "# Report [on it](harness:session/abc)

"
                    "- the run: [bash](harness:call/last)

"
                    "> said [here](harness:message/n-9)

"
                    "**see [this](harness:thread/t-1)**

"
                    "| what | where |
|---|---|
| run | [call](harness:call/bash#1) |
"))))
    (dolist (case '(("on it" . "harness:session/abc") ("bash" . "harness:call/last")
                    ("here" . "harness:message/n-9") ("this" . "harness:thread/t-1")
                    ("call" . "harness:call/bash#1")))
      (ert-info ((car case))
        (should (equal (cdr case) (harness-md-test-url-at s (car case))))))))

(ert-deftest harness-md-harness-links-are-described-by-the-ui ()
  "`harness-ui-markdown-link-describe-function' names what a link goes to."
  (let ((harness-ui-markdown-link-describe-function
         (lambda (url)
           (pcase (plist-get (harness-links-parse url) :kind)
             ('session (list :label "Fix the build" :help "open Fix the build, idle"))
             (_ nil)))))
    (let ((s (harness-ui-markdown-inline "[words](harness:session/abc) <harness:session/abc> [call](harness:call/last)")))
      (should (equal "words Fix the build call" (substring-no-properties s)))
      ;; Words given are kept, and the description is the tooltip.
      (should (equal "open Fix the build, idle" (get-text-property (string-search "words" s) 'help-echo s)))
      (should (equal "open Fix the build, idle" (get-text-property (string-search "Fix" s) 'help-echo s)))
      (should (string-match-p "tool call last" (get-text-property (string-search "call" s) 'help-echo s)))))
  ;; A describer that fails is as good as none.
  (let ((harness-ui-markdown-link-describe-function (lambda (_) (error "Boom"))))
    (should (equal "session abc" (substring-no-properties (harness-ui-markdown-inline "<harness:session/abc>"))))))

(ert-deftest harness-md-a-link-that-names-nothing-says-so ()
  (let ((s (harness-ui-markdown-inline "[x](harness:nothing/here) and [y](harness:session)")))
    (should (equal "x and y" (substring-no-properties s)))
    (should (string-match-p "not a link to anything"
                            (get-text-property (string-search "x" s) 'help-echo s)))))

(ert-deftest harness-md-harness-links-follow-the-ui-function ()
  "Opening a harness link calls the UI's function with its URL, and browses nothing."
  (harness-md-test-with-links "Run [it](harness:call/last), <harness:session/abc> and [web](https://e.org/)."
    (let* ((followed nil)
           (harness-ui-markdown-harness-link-function (lambda (url) (push (cons url (current-buffer)) followed))))
      (goto-char (+ (point-min) (string-search "it" (buffer-string))))
      (harness-ui-markdown-follow-link)
      (goto-char (+ (point-min) (string-search "session abc" (buffer-string))))
      (execute-kbd-macro (kbd "RET"))
      (should (equal (list (cons "harness:session/abc" buffer) (cons "harness:call/last" buffer)) followed))
      (should-not opened)
      ;; A web link still goes to the browser.
      (goto-char (+ (point-min) (string-search "web" (buffer-string))))
      (harness-ui-markdown-follow-link)
      (should (equal '("https://e.org/") opened))
      (should (= 2 (length followed))))))

(ert-deftest harness-md-harness-links-need-the-ui-function ()
  (harness-md-test-with-links "Run [it](harness:call/last)."
    (let ((harness-ui-markdown-harness-link-function nil))
      (goto-char (+ (point-min) (string-search "it" (buffer-string))))
      (should-error (harness-ui-markdown-follow-link) :type 'user-error)
      (should-not opened))))

(ert-deftest harness-md-harness-links-read-back-as-markdown ()
  "Quoting a rendered message gives the link back, its URL whole."
  (with-temp-buffer
    (insert (harness-ui-markdown-render "Run [it](harness:call/last) and <harness:session/abc>."))
    (should (equal "Run [it](harness:call/last) and [session abc](harness:session/abc)."
                   (harness-ui-markdown-source (point-min) (point-max))))))

(ert-deftest harness-md-table-fits-a-bound-width ()
  "A table wider than its bound wraps inside its columns, still aligned."
  (let* ((md "| name | description |\n|---|---|\n| alpha | a very long description that would not fit in a chat window at all, over and over and over again |\n")
         (harness-ui-markdown-table-width 40)
         (s (harness-ui-markdown-render md))
         (plain (substring-no-properties s))
         (lines (split-string plain "\n" t)))
    (should (eq 'table (get-text-property 0 'harness-md-block s)))
    (dolist (line lines)
      (should (<= (string-width line) 40))
      (should (string-match-p "│" line)))
    (should (memq 'harness-md-table-header (harness-md-test-face-at s 0)))
    ;; No word of the header or the long cell is lost to the wrapping.
    (dolist (word '("name" "description" "alpha" "a" "very" "long" "description"
                    "that" "would" "not" "fit" "in" "a" "chat" "window" "at" "all"
                    "over" "and" "over" "and" "over" "again"))
      (should (string-match-p word plain)))))

(ert-deftest harness-md-table-breaks-a-long-word ()
  "One long word breaks across the column instead of overflowing it."
  (let* ((word (make-string 200 ?w))
         (md (format "| a |\n|---|\n| %s |\n" word))
         (harness-ui-markdown-table-width 30)
         (s (harness-ui-markdown-render md))
         (plain (substring-no-properties s)))
    (dolist (line (split-string plain "\n" t))
      (should (<= (string-width line) 30)))
    (should (eq 'table (get-text-property 0 'harness-md-block s)))
    ;; The whole word is still there, just broken across the lines.
    (should (= 200 (cl-count ?w plain)))))

(ert-deftest harness-md-table-unchanged-when-it-fits ()
  "A table that already fits its bound renders exactly as without one."
  (let ((md "| a | b |\n|---|---|\n| 1 | 2 |\n")
        (natural (harness-ui-markdown-render "| a | b |\n|---|---|\n| 1 | 2 |\n")))
    (let ((harness-ui-markdown-table-width 40))
      (should (equal natural (harness-ui-markdown-render md))))))

(ert-deftest harness-md-hard-breaks-keep-a-paragraph-s-lines ()
  "`harness-ui-markdown-hard-breaks' keeps the line breaks inside a paragraph.
Markdown joins a paragraph's lines with spaces; bound, as for what a
person typed, each line break stays one.  Paragraphs apart, lists and
code blocks render the same either way."
  (should (equal "one two" (substring-no-properties (harness-ui-markdown-render "one\ntwo"))))
  (let ((harness-ui-markdown-hard-breaks t))
    (should (equal "one\ntwo" (substring-no-properties (harness-ui-markdown-render "one\ntwo"))))
    ;; Inline markup still renders on each line.
    (let ((s (harness-ui-markdown-render "a **bold** line\nand `code`")))
      (should (equal "a bold line\nand code" (substring-no-properties s)))
      (should (memq 'bold (harness-md-test-face-at s 2)))
      (should (memq 'harness-md-code (harness-md-test-face-at s 16)))))
  (dolist (md '("one\n\ntwo"
                "- item one\n  wrapped\n- item two"
                "```\nline one\nline two\n```"))
    (let ((soft (harness-ui-markdown-render md))
          (hard (let ((harness-ui-markdown-hard-breaks t)) (harness-ui-markdown-render md))))
      (should (equal-including-properties soft hard)))))

;;;; In lines

(defun harness-md-test-lines (markdown width)
  "Return the lines `harness-ui-markdown-render-lines' makes of MARKDOWN, as plain text."
  (mapcar #'substring-no-properties (harness-ui-markdown-render-lines markdown width)))

(ert-deftest harness-md-lines-end-in-newlines-within-the-width ()
  "Every line ends in a newline and none is wider than the width, whatever the block."
  (let ((md (concat "A paragraph long enough that it has to be wrapped into several lines of text.\n\n"
                    "- an item long enough that it has to be wrapped too, under its bullet\n"
                    "  - a nested one, which is also long enough to be wrapped under its bullet\n"
                    "1. numbered, and long enough to be wrapped under its number as well\n\n"
                    "> a quote long enough that it has to be wrapped under its bar as well\n\n"
                    "# A heading long enough that it has to be wrapped like the rest of the text\n\n"
                    "```sh\nsome-command --with-a-long-option --and-another-long-option --and-more\n```\n\n"
                    "| a | b |\n|---|---|\n| one | a cell long enough that it has to be wrapped in its column |\n")))
    (dolist (width '(20 30 40 80))
      (let ((lines (harness-ui-markdown-render-lines md width)))
        (should lines)
        (dolist (line lines)
          (should (string-suffix-p "\n" line))
          (should (<= (string-width (string-remove-suffix "\n" line)) width)))))))

(ert-deftest harness-md-lines-indent-what-the-window-would-have ()
  "A list item wraps under its text, a quote under its bar, code under its margin.
The properties the renderer leaves for the window to draw them by are
text in the lines, and no longer properties, which would draw a second
margin."
  (let ((lines (harness-md-test-lines
                (concat "- one item that is long enough to wrap at thirty columns\n"
                        "  - nested one that is long enough to wrap at thirty columns\n"
                        "1. numbered item that is long enough to wrap at thirty columns\n\n"
                        "> quoted words that are long enough to wrap at thirty columns\n\n"
                        "```\ncode that is longer than thirty columns, so it is cut\n```\n")
                30)))
    (should (equal '("• one item that is long enough\n"
                     "  to wrap at thirty columns\n"
                     "  • nested one that is long\n"
                     "    enough to wrap at thirty\n"
                     "    columns\n"
                     "1. numbered item that is long\n"
                     "   enough to wrap at thirty\n"
                     "   columns\n"
                     "\n"
                     "┃ quoted words that are long\n"
                     "┃ enough to wrap at thirty\n"
                     "┃ columns\n"
                     "\n"
                     ;; The code is cut where its room ends, inside a word,
                     ;; and both pieces have the block's margin.
                     "  code that is longer than thi\n"
                     "  rty columns, so it is cut\n")
                   lines))))

(ert-deftest harness-md-lines-leave-no-margin-property ()
  "No line of the rendering holds a `line-prefix' or a `wrap-prefix' any more."
  (dolist (line (harness-ui-markdown-render-lines
                 "- item\n  - nested item\n\n> quote\n\n```\ncode\n```\n\ntext" 40))
    (let ((pos 0))
      (while (< pos (length line))
        (should-not (get-text-property pos 'line-prefix line))
        (should-not (get-text-property pos 'wrap-prefix line))
        (setq pos (1+ pos))))))

(ert-deftest harness-md-lines-keep-the-faces-and-links ()
  "Emphasis, inline code and links of the text are in the lines, wrapped or not."
  (let* ((lines (harness-ui-markdown-render-lines
                 "A **bold word**, `code`, *italics* and [a link label](https://x.org/a) on a line to wrap" 24))
         (text (apply #'concat lines)))
    (should (> (length lines) 2))
    (should-not (string-match-p "[*`]\\|](" (substring-no-properties text)))
    (let ((pos (string-search "bold" text)))
      (should (memq 'bold (harness-md-test-face-at text pos))))
    (should (memq 'harness-md-code (harness-md-test-face-at text (string-search "code" text))))
    (should (memq 'italic (harness-md-test-face-at text (string-search "italics" text))))
    ;; A link broken over two lines is a link in both.
    (let ((label (string-search "link" text)))
      (should (equal "https://x.org/a" (get-text-property label 'harness-url text)))
      (should (equal "https://x.org/a" (get-text-property (string-search "label" text) 'harness-url text))))))

(ert-deftest harness-md-lines-keep-a-code-block-s-background-to-the-edge ()
  "A code block's newlines keep the face that extends its background, the last one too.
The renderer trims the newline that ends its text; the last line of
a block that ends it gets one."
  (dolist (md '("```\none\ntwo\n```\n\nafter" "```\none\ntwo\n```"))
    (let* ((lines (harness-ui-markdown-render-lines md 30))
           (code (cl-remove-if-not (lambda (line) (string-match-p "one\\|two" line)) lines)))
      (should (= 2 (length code)))
      (dolist (line code)
        (let ((newline (1- (length line))))
          (should (equal "\n" (substring-no-properties line newline)))
          (should (memq 'harness-md-code-block (harness-md-test-face-at line newline))))))))

(ert-deftest harness-md-lines-cut-code-where-the-room-ends ()
  "Code keeps its blanks where a line is cut; the rest of the text gives them up."
  ;; The margin of two columns, then eight of the ten.
  (should (equal '("  aaaa    \n" "  bbbb\n")
                 (harness-md-test-lines "```\naaaa    bbbb\n```" 10)))
  (should (equal '("aaaa\n" "bbbb\n")
                 (harness-md-test-lines "aaaa      bbbb" 6))))

(ert-deftest harness-md-lines-cut-a-word-wider-than-the-room ()
  "A word too long for the room is cut inside it, and none of it is lost."
  (let* ((url "https://example.org/a/very/long/path/that/goes/on/and/on")
         (lines (harness-md-test-lines url 20)))
    (should (> (length lines) 2))
    (dolist (line lines) (should (<= (string-width (string-remove-suffix "\n" line)) 20)))
    (should (equal url (mapconcat (lambda (line) (string-remove-suffix "\n" line)) lines "")))))

(ert-deftest harness-md-lines-fit-a-table-to-the-width ()
  "A table is fitted to the width, its columns aligned."
  (let ((lines (harness-md-test-lines
                "| name | description |\n|---|---|\n| alpha | a very long description that does not fit in thirty columns |\n" 30)))
    (should (> (length lines) 3))
    (dolist (line lines)
      (should (<= (string-width (string-remove-suffix "\n" line)) 30))
      (should (string-match-p "│" line)))))

(ert-deftest harness-md-lines-keep-or-join-the-lines-of-a-paragraph ()
  "The lines of a paragraph join as Markdown says, and stay when the caller says so."
  (should (equal '("one two\n") (harness-md-test-lines "one\ntwo" 40)))
  (let ((harness-ui-markdown-hard-breaks t))
    (should (equal '("one\n" "two\n") (harness-md-test-lines "one\ntwo" 40)))))

(ert-deftest harness-md-lines-of-nothing-are-one-empty-line ()
  "Empty text, or none, is a line that is empty; a rule is blank, not wider than the width."
  (should (equal '("\n") (harness-md-test-lines "" 40)))
  (should (equal '("\n") (harness-md-test-lines nil 40)))
  (let ((lines (harness-md-test-lines "above\n\n---\n\nbelow" 12)))
    (should (equal '("above\n" "\n" "            \n" "\n" "below\n") lines))))

(ert-deftest harness-md-lines-of-a-long-text-take-time-linear-in-it ()
  "A very long word, line of code, or run of words is cut in time that grows with it.
Cutting each piece off a copy of what was left, instead of walking
along the text, took the square of its length."
  (let ((start (float-time)))
    (dolist (md (list (make-string 500000 ?w)
                      (concat "```\n" (make-string 300000 ?x) "\n```")
                      (mapconcat #'identity (make-list 60000 "word") " ")))
      (let ((lines (harness-ui-markdown-render-lines md 80)))
        (should (> (length lines) 1000))
        (dolist (line lines)
          (should (<= (string-width (string-remove-suffix "\n" line)) 80)))))
    (should (< (- (float-time) start) 20))))

(ert-deftest harness-md-lines-survive-odd-text ()
  "Wide characters, tabs, blank-only and very narrow widths all end."
  (dolist (md '("日本語のコメントはここにあります、とても長い文章です" "a\tb\tc" "   " "\n\n\n"
                "- \n- x" "> " "```" "| |\n|-|\n| |" "**" "[](" "*" "_"))
    (dolist (width '(1 5 20))
      (let ((lines (harness-ui-markdown-render-lines md width)))
        (should (consp lines))
        (dolist (line lines) (should (string-suffix-p "\n" line)))))))

;;;; The first words

(ert-deftest harness-md-summary-is-one-line-without-the-markers ()
  "A summary has the text's faces and none of its markers, in one line."
  (let ((s (harness-ui-markdown-summary
            "## A **bold** start\n\n- one\n- two with `code`\n\n```elisp\n(defun x () 1)\n```\n\n> quoted")))
    (should (not (string-match-p "[\n*`#]" (substring-no-properties s))))
    (should (string-prefix-p "A bold start • one • two with code (defun x () 1) ┃ quoted"
                             (substring-no-properties s)))
    ;; The language a block names is left out.
    (should-not (string-match-p "elisp" s))
    (should (memq 'bold (harness-md-test-face-at s (string-search "bold" s))))
    (should (memq 'harness-md-code (harness-md-test-face-at s (string-search "code" s))))))

(ert-deftest harness-md-summary-draws-a-heading-as-bold ()
  "A heading's height would make one line of a list taller than the others."
  (let ((s (harness-ui-markdown-summary "# Big heading\n\ntext")))
    (should (equal "Big heading text" (substring-no-properties s)))
    (should (memq 'bold (harness-md-test-face-at s 0)))
    (dolist (face '(harness-md-heading-1 harness-md-heading-2 harness-md-heading-3 harness-md-heading-4))
      (should-not (memq face (harness-md-test-face-at s 0))))))

(ert-deftest harness-md-summary-draws-a-link-as-its-label ()
  "A link in a summary is its label: it does nothing, so it is not drawn as one."
  (let ((s (harness-ui-markdown-summary "see [the docs](https://x.org/a) and https://y.org now")))
    (should (equal "see the docs and https://y.org now" (substring-no-properties s)))
    (dolist (pos (list (string-search "docs" s) (string-search "y.org" s)))
      (should-not (get-text-property pos 'harness-url s))
      (should-not (get-text-property pos 'keymap s))
      (should-not (get-text-property pos 'mouse-face s))
      (should-not (memq 'link (harness-md-test-face-at s pos))))))

(ert-deftest harness-md-summary-reads-the-start-of-a-long-text ()
  "A text far longer than any line is read at its start only."
  (let* ((text (concat "**first** " (make-string 100000 ?x)))
         (s (harness-ui-markdown-summary text)))
    (should (string-prefix-p "first xxx" s))
    (should (<= (length s) (+ 20 harness-ui-markdown--summary-limit)))
    (should (equal "" (harness-ui-markdown-summary nil)))
    (should (equal "" (harness-ui-markdown-summary "")))))

(provide 'harness-ui-markdown-test)
;;; harness-ui-markdown-test.el ends here
