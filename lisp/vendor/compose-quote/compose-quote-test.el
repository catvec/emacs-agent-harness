;;; compose-quote-test.el --- Tests for compose-quote  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The tests of compose-quote.el.  They need nothing but the library:
;; `make test' runs them in an Emacs with only this directory on its
;; load path.  Texts are written with marks: "|" is point, "«"
;; and "»" are the region's start and end.  Some tests compose in the
;; whole buffer, as a mail body would; the others in a box, as a chat
;; would: a read-only transcript, then a prompt, then the composition,
;; on the prompt's line, between markers.  Keys go through the command
;; loop, as typed.

;;; Code:

(require 'ert)
(require 'bytecomp)
(require 'cl-lib)
(require 'compose-quote)

(defconst compose-quote-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "The directory of the library and its tests.")

;;;; Helpers

(defun compose-quote-test--insert (text)
  "Insert TEXT at point without its marks, and return where they were.
\"|\" marks point, \"«\" and \"»\" the region's start and end.  The
result is (POINT BEG END), nil for a mark TEXT lacks."
  (let ((pt nil) (beg nil) (end nil))
    (dolist (char (string-to-list text))
      (pcase char
        (?| (setq pt (point)))
        (?« (setq beg (point)))
        (?» (setq end (point)))
        (_ (insert char))))
    (list pt beg end)))

(defun compose-quote-test--show (&optional from to)
  "Return the text from FROM to TO, with \"|\" where point is.
FROM and TO are the buffer's start and end by default."
  (let ((from (or from (point-min)))
        (to (or to (point-max))))
    (if (<= from (point) to)
        (concat (buffer-substring-no-properties from (point)) "|"
                (buffer-substring-no-properties (point) to))
      (buffer-substring-no-properties from to))))

(defun compose-quote-test--undo ()
  "Undo the last change, as the undo key would right after a command."
  (undo-boundary)
  (let ((last-command nil)
        (inhibit-message t))
    (undo)))

(defun compose-quote-test--edit (text command)
  "Run COMMAND in a buffer holding TEXT, marks and all; return the result.
The whole buffer is the composition.  COMMAND is called with the
region's ends, or nil.  The result is the buffer's text, \"|\" where
point is.  One undo must bring TEXT back: that is checked too."
  (with-temp-buffer
    (buffer-enable-undo)
    (pcase-let ((`(,pt ,beg ,end) (compose-quote-test--insert text)))
      (goto-char (or pt (point-max)))
      (let ((before (buffer-string)))
        (undo-boundary)
        (funcall command beg end)
        (prog1 (compose-quote-test--show)
          (compose-quote-test--undo)
          (should (equal before (buffer-string))))))))

(defun compose-quote-test--split (text)
  "Split the quote in TEXT where its \"|\" is; return the result, marked."
  (compose-quote-test--edit text (lambda (_beg _end) (compose-quote-split))))

(defun compose-quote-test--elide (text &optional whole)
  "Elide in TEXT, with its region if it marks one; return the result, marked.
WHOLE is the prefix argument."
  (compose-quote-test--edit text (lambda (beg end) (compose-quote-elide beg end whole))))

(defmacro compose-quote-test-with (&rest body)
  "Run BODY in a buffer of its own, shown in the selected window.
Keys typed go to it.  `transient-mark-mode' is on, and the inline hint
off."
  (declare (indent 0) (debug t))
  `(let ((buffer (generate-new-buffer "*compose-quote test*"))
         (compose-quote-inline-hint nil))
     (unwind-protect
         (save-window-excursion
           (set-window-buffer (selected-window) buffer)
           (with-current-buffer buffer
             (setq-local transient-mark-mode t)
             ,@body))
       (kill-buffer buffer))))

(defun compose-quote-test--keys (keys)
  "Type KEYS, as `kbd' reads them, through the command loop.
Messages are not shown: in batch they would go to the output."
  (let ((inhibit-message t))
    (execute-kbd-macro (kbd keys))))

(defun compose-quote-test--region (beg end)
  "Make the region from BEG to END active, point at END."
  (goto-char end)
  (push-mark beg t t))

;;;; A host composing in a box

(defvar-local compose-quote-test--box nil
  "The test box, as (START END FRONT) markers, or nil when it is gone.")

(defvar-local compose-quote-test--read nil
  "The (BEG . END) the test box's source function read, newest first.")

(defun compose-quote-test--box-area ()
  "Return the test box: its `compose-quote-area-function'."
  compose-quote-test--box)

(defun compose-quote-test--box-source (beg end)
  "Return the text from BEG to END in capitals, and note it was read.
The test box's `compose-quote-source-function': the capitals show the
text went through it."
  (push (cons beg end) compose-quote-test--read)
  (upcase (buffer-substring-no-properties beg end)))

(defun compose-quote-test--draw-box (text &optional transcript)
  "Make the current buffer a host composing in a box that holds TEXT.
First comes TRANSCRIPT, \"The transcript.\\n\" by default, read-only,
then the prompt, a read-only field of its own, then TEXT, between the
box's markers, on the prompt's line, then a read-only newline.  The
end's marker advances with text inserted there.  The prompt starts the
box, as its FRONT.  TEXT's marks (`compose-quote-test--insert') set
point, at the box's end by default; return (BEG END), the region's."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (or transcript "The transcript.\n") 'read-only t))
    (let ((front (point-marker)))
      (insert (propertize "❯ " 'read-only t 'rear-nonsticky t 'field 'prompt))
      (let* ((start (point-marker))
             (marks (compose-quote-test--insert text))
             (end (prog1 (copy-marker (point) t)
                    (insert (propertize "\n" 'read-only t)))))
        (set-marker end (1- (point)))
        (setq compose-quote-test--box (list start end front)
              compose-quote-area-function #'compose-quote-test--box-area
              compose-quote-source-function #'compose-quote-test--box-source
              compose-quote-test--read nil)
        (goto-char (or (car marks) end))
        (cdr marks)))))

(defun compose-quote-test--box-start ()
  "Return where the test box's text starts."
  (marker-position (nth 0 compose-quote-test--box)))

(defun compose-quote-test--box-end ()
  "Return where the test box's text ends."
  (marker-position (nth 1 compose-quote-test--box)))

(defun compose-quote-test--box-text ()
  "Return the test box's text, with \"|\" where point is when in it."
  (compose-quote-test--show (compose-quote-test--box-start) (compose-quote-test--box-end)))

(defun compose-quote-test--transcript ()
  "Return the test box's host's text before the box's prompt."
  (buffer-substring-no-properties (point-min) (nth 2 compose-quote-test--box)))

;;;; Quoting

(ert-deftest compose-quote-string ()
  "Every line of a quote follows \"> \".
Blank lines around the text go, and blanks ending a line; a blank line
within it is a bare \">\", so the quote stays one block.  Indentation
stays, as code needs."
  (should (equal "> one\n>\n>   two" (compose-quote-string "\n \none  \n\t\n  two\n\n")))
  (should (equal "> one" (compose-quote-string "one")))
  (should (equal "> > nested" (compose-quote-string "> nested")))
  (should-not (text-properties-at 2 (compose-quote-string (propertize "one" 'read-only t)))))

(defun compose-quote-test--quoted (text quote &optional start)
  "Insert QUOTE quoted where the \"|\" of TEXT is; return the result, marked.
START is `compose-quote-insert''s, as an offset into TEXT.  The result
is (TEXT BOUNDS), BOUNDS what `compose-quote-insert' returned, as the
text it bounds."
  (with-temp-buffer
    (goto-char (or (car (compose-quote-test--insert text)) (point-max)))
    (let ((bounds (compose-quote-insert quote (and start (+ (point-min) start)))))
      (list (compose-quote-test--show)
            (buffer-substring-no-properties (car bounds) (cdr bounds))))))

(ert-deftest compose-quote-insert-a-blank-line-apart ()
  "A quote goes in a blank line apart from the text before it.
A blank line follows it, point after that, where the reply goes.  Text
before START, the composition's start, does not count."
  (should (equal '("> one\n\n|" "> one") (compose-quote-test--quoted "" "one")))
  (should (equal '("a\n\n> one\n\n|" "> one") (compose-quote-test--quoted "a\n\n|" "one")))
  (should (equal '("a\n\n> one\n\n|" "> one") (compose-quote-test--quoted "a\n|" "one")))
  (should (equal '("a\n\n> one\n\n|" "> one") (compose-quote-test--quoted "a|" "one")))
  (should (equal '("a\n\n> one\n> two\n\n|b" "> one\n> two") (compose-quote-test--quoted "a|b" "one\ntwo")))
  ;; From START on: a prompt before the composition, on its line.
  (should (equal '("Prompt: > one\n\n|" "> one") (compose-quote-test--quoted "Prompt: |" "one" 8)))
  (should (equal '("a\n> one\n\n|" "> one") (compose-quote-test--quoted "a\n|" "one" 2)))
  (should (equal '("a\n\n\n> one\n\n|" "> one") (compose-quote-test--quoted "a\n\n|" "one" 2))))

(ert-deftest compose-quote-insert-refuses-blank-text ()
  "Blank text is not quoted: nothing changes."
  (with-temp-buffer
    (insert "a")
    (should-error (compose-quote-insert " \n\t") :type 'user-error)
    (should (equal "a" (buffer-string)))))

(ert-deftest compose-quote-insert-runs-the-hook ()
  "The hook runs once the quote is in, point where the reply goes.
The mark is no longer active."
  (compose-quote-test-with
    (let ((seen nil))
      (add-hook 'compose-quote-insert-hook (lambda () (push (compose-quote-test--show) seen)) nil t)
      (insert "a")
      (push-mark (point-min) t t)
      (compose-quote-insert "one")
      (should (equal '("a\n\n> one\n\n|") seen))
      (should-not (region-active-p)))))

(ert-deftest compose-quote-at-point ()
  "The text at point names the message to quote, else the function does.
The text names it with a `compose-quote' property, the buffer with
`compose-quote-function'; a blank answer is none."
  (with-temp-buffer
    (insert "Message")
    (goto-char 2)
    (should-not (compose-quote-at-point))
    (setq-local compose-quote-function (lambda () "From the function"))
    (should (equal "From the function" (compose-quote-at-point)))
    (put-text-property 1 4 'compose-quote "From the property")
    (should (equal "From the property" (compose-quote-at-point)))
    (put-text-property 1 4 'compose-quote " \n")
    (should (equal "From the function" (compose-quote-at-point)))
    (setq-local compose-quote-function (lambda () ""))
    (should-not (compose-quote-at-point))))

(ert-deftest compose-quote-reply-in-a-whole-buffer ()
  "With no area function, the whole buffer is the composition.
A region turns into a quote in place; without one, the message at
point is quoted at point."
  (compose-quote-test-with
    (compose-quote-mode 1)
    (should (eq 'compose-quote-reply (key-binding (kbd "C-c >"))))
    (insert "Look:\nHello\nworld")
    (compose-quote-test--region 7 (point-max))
    (compose-quote-test--keys "C-c >")
    (should (equal "Look:\n\n> Hello\n> world\n\n|" (compose-quote-test--show)))
    (should-not (region-active-p))
    ;; Without a region: nothing names a message here.
    (erase-buffer)
    (insert "Before\nAfter")
    (goto-char 8)
    (should-error (compose-quote-reply) :type 'user-error)
    (should (equal "Before\n|After" (compose-quote-test--show)))
    ;; The function names one.
    (setq-local compose-quote-function (lambda () "Quoted"))
    (compose-quote-test--keys "C-c >")
    (should (equal "Before\n\n> Quoted\n\n|After" (compose-quote-test--show)))
    ;; The property wins.
    (put-text-property 1 3 'compose-quote "*Marked*")
    (goto-char 2)
    (compose-quote-test--keys "C-c >")
    (should (equal "B\n\n> *Marked*\n\n|efore\n\n> Quoted\n\nAfter" (compose-quote-test--show)))
    ;; A blank region is nothing to quote.
    (erase-buffer)
    (insert "a\n  \nb")
    (compose-quote-test--region 3 5)
    (should-error (compose-quote-reply 3 5) :type 'user-error)
    (should (equal "a\n  \nb" (buffer-string)))))

(ert-deftest compose-quote-reply-quotes-the-region-in-a-box ()
  "A region above the box is quoted at the box's end, point following.
The source function reads its text back.  A region reaching into the
box quotes only its part above the box's prompt; one in the box becomes
a quote in place.  What the box follows stays as it was."
  (compose-quote-test-with
    (compose-quote-mode 1)
    (compose-quote-test--draw-box "")
    ;; "transcript", of "The transcript.\n".
    (compose-quote-test--region (+ (point-min) 4) (+ (point-min) 14))
    (compose-quote-test--keys "C-c >")
    (should (equal "> TRANSCRIPT\n\n|" (compose-quote-test--box-text)))
    (should (equal (list (cons (+ (point-min) 4) (+ (point-min) 14))) compose-quote-test--read))
    (should-not (region-active-p))
    (compose-quote-test--keys "Why?")
    (should (equal "> TRANSCRIPT\n\nWhy?|" (compose-quote-test--box-text)))
    ;; From above the box into it: the part above, after the reply.
    (compose-quote-test--region (point-min) (+ (compose-quote-test--box-start) 3))
    (compose-quote-test--keys "C-c >")
    (should (equal "> TRANSCRIPT\n\nWhy?\n\n> THE TRANSCRIPT.\n\n|" (compose-quote-test--box-text)))
    (should (equal (cons (point-min) (marker-position (nth 2 compose-quote-test--box)))
                   (car compose-quote-test--read)))
    ;; In the box, in place.
    (apply #'compose-quote-test--region (compose-quote-test--draw-box "Look:\n«Hello\nworld»"))
    (compose-quote-test--keys "C-c >")
    (should (equal "Look:\n\n> Hello\n> world\n\n|" (compose-quote-test--box-text)))
    (should-not compose-quote-test--read)
    ;; From the prompt into the box: the part in the box.
    (compose-quote-test--draw-box "Hello")
    (compose-quote-test--region (nth 2 compose-quote-test--box) (compose-quote-test--box-end))
    (compose-quote-test--keys "C-c >")
    (should (equal "> Hello\n\n|" (compose-quote-test--box-text)))
    (should (equal "The transcript.\n" (compose-quote-test--transcript)))))

(ert-deftest compose-quote-reply-without-a-region-in-a-box ()
  "Without a region the message at point is quoted whole.
It goes at point in the box, else at the box's end.  With no message
there, nothing is quoted."
  (compose-quote-test-with
    (compose-quote-mode 1)
    (compose-quote-test--draw-box "")
    (goto-char (point-min))
    (should-error (compose-quote-reply) :type 'user-error)
    (should (equal "" (compose-quote-test--box-text)))
    (setq-local compose-quote-function
                (lambda () (and (< (point) (compose-quote-test--box-start)) "The **transcript**.")))
    (compose-quote-test--keys "C-c >")
    (should (equal "> The **transcript**.\n\n|" (compose-quote-test--box-text)))
    ;; The function says nothing in the box.
    (should-error (compose-quote-reply) :type 'user-error)
    ;; Marked text wins.
    (compose-quote-test--draw-box "")
    (let ((inhibit-read-only t))
      (put-text-property (point-min) (+ (point-min) 3) 'compose-quote "*The*"))
    (goto-char (1+ (point-min)))
    (compose-quote-test--keys "C-c >")
    (should (equal "> *The*\n\n|" (compose-quote-test--box-text)))
    ;; In the box, at point.
    (compose-quote-test--draw-box "Before\n|After")
    (setq-local compose-quote-function (lambda () "Quoted"))
    (compose-quote-test--keys "C-c >")
    (should (equal "Before\n\n> Quoted\n\n|After" (compose-quote-test--box-text)))))

(ert-deftest compose-quote-reply-needs-a-composition ()
  "With no composition right now, nothing is quoted, split or elided."
  (compose-quote-test-with
    (compose-quote-test--draw-box "> one |two")
    (setq-local compose-quote-function (lambda () "Quoted"))
    (setq compose-quote-test--box nil)
    (should-error (compose-quote-reply) :type 'user-error)
    (should-error (compose-quote-reply (point-min) (+ (point-min) 3)) :type 'user-error)
    (should-error (compose-quote-split) :type 'user-error)
    (should-error (compose-quote-elide) :type 'user-error)
    (should-not (compose-quote-bounds))
    (should (string-suffix-p "❯ > one two\n" (buffer-string)))))

(ert-deftest compose-quote-reply-runs-the-hook-in-a-box ()
  "The host hears of each quote, point in its box where the reply goes."
  (compose-quote-test-with
    (compose-quote-test--draw-box "")
    (let ((seen nil))
      (add-hook 'compose-quote-insert-hook (lambda () (push (compose-quote-test--box-text) seen)) nil t)
      (compose-quote-reply (point-min) (+ (point-min) 3))
      (should (equal '("> THE\n\n|") seen)))))

;;;; Quotes

(ert-deftest compose-quote-bounds ()
  "A quote is a run of lines of the composition starting with \">\".
Bare lines are included; it goes from its first line's start to its
last line's end.  The composition's first line starts after the prompt;
lines outside it never count, whatever they start with."
  (compose-quote-test-with
    (compose-quote-test--draw-box "> ours\n>\n> too\n\nreply\n> another" "> Not ours.\n")
    (let ((start (compose-quote-test--box-start)))
      (should (equal (cons start (+ start (length "> ours\n>\n> too")))
                     (compose-quote-bounds start)))
      (should (equal (compose-quote-bounds start) (compose-quote-bounds (+ start 8))))
      (should-not (compose-quote-bounds (point-min)))
      (should-not (compose-quote-bounds (+ start (length "> ours\n>\n> too\n")))))
    (should (equal (cons (- (compose-quote-test--box-end) (length "> another"))
                         (compose-quote-test--box-end))
                   (compose-quote-bounds (compose-quote-test--box-end)))))
  ;; In a whole buffer.
  (with-temp-buffer
    (insert "Hi\n> a\n> b\nc")
    (should (equal '(4 . 11) (compose-quote-bounds 5)))
    (should-not (compose-quote-bounds 2))
    (should-not (compose-quote-bounds 13))))

;;;; Splitting

(ert-deftest compose-quote-split ()
  "Splitting a quote leaves an empty line for the answer between its parts.
The line is a blank line apart from each part.  The quote splits before
point's line at its start or in its prefix, after it at its end, else
within it, the second part behind the same prefix.  Blanks and bare
lines where the parts meet go.  One undo brings the quote back."
  (should (equal "> one\n\n|\n\n> two\n> three" (compose-quote-test--split "> one |two\n> three")))
  (should (equal "> one\n\n|\n\n> two" (compose-quote-test--split "> one\n> |two")))
  (should (equal "> one\n\n|\n\n> two" (compose-quote-test--split "> one\n|> two")))
  (should (equal "> one\n\n|\n\n> two" (compose-quote-test--split "> one|\n> two")))
  (should (equal "> one\n> two\n\n|\n\nreply" (compose-quote-test--split "> one\n> two|\n\nreply")))
  (should (equal "Look:\n\n|\n\n> one\n> two" (compose-quote-test--split "Look:\n\n> |one\n> two")))
  (should (equal "> a\n\n|\n\n> b" (compose-quote-test--split "> a\n>|\n> b")))
  (should (equal "> a\n\n|\n\n> b" (compose-quote-test--split "> a\n>\n> |b")))
  (should (equal "> > deep\n\n|\n\n> > text" (compose-quote-test--split "> > deep |text")))
  (should (equal "> one\n\n|\n\n> two" (compose-quote-test--split "> one   |   two"))))

(ert-deftest compose-quote-split-more ()
  "Only blanks before point split before its line, indentation kept.
Trailing blanks of the first part go; a quote ending the composition
leaves the empty line at its end."
  (should (equal "> one\n\n|\n\n>     code" (compose-quote-test--split "> one  \n>  |   code")))
  (should (equal "> one\n\n|" (compose-quote-test--split "> one|")))
  (should (equal "|\n\n> one" (compose-quote-test--split "|> one")))
  (should (equal ">one\n\n|\n\n>two" (compose-quote-test--split ">one |two")))
  (should (equal "> a\n>\n> b\n\n|\n\n> c" (compose-quote-test--split "> a\n>\n> b\n>\n|> c"))))

(ert-deftest compose-quote-split-needs-a-quote ()
  "Out of a quote, nothing is split."
  (with-temp-buffer
    (insert "> one\n\nreply")
    (should-error (compose-quote-split) :type 'user-error)
    (goto-char 7)
    (should-error (compose-quote-split) :type 'user-error)
    (should (equal "> one\n\nreply" (buffer-string)))))

(ert-deftest compose-quote-split-in-a-box ()
  "A quote on the prompt's line splits like any other.
In a box the composition's first line starts after the prompt; the
answer goes in the box."
  (compose-quote-test-with
    (compose-quote-test--draw-box "> one |two")
    (compose-quote-split)
    (should (equal "> one\n\n|\n\n> two" (compose-quote-test--box-text)))
    (compose-quote-test--draw-box "|> one")
    (compose-quote-split)
    (should (equal "|\n\n> one" (compose-quote-test--box-text)))
    (compose-quote-test--draw-box "> a\n> b|")
    (compose-quote-split)
    (insert "Answer")
    (should (equal "> a\n> b\n\nAnswer|" (compose-quote-test--box-text)))
    (should (equal "The transcript.\n" (compose-quote-test--transcript)))))

;;;; Eliding

(ert-deftest compose-quote-elide ()
  "Eliding replaces part of a quote with [...].
That is the region, else the rest of the paragraph from point or, with
a prefix argument, of the quote.  The text left joins on one line
around it, a space apart; whole lines leave one line of it.  Next to
one already there, it merges.  Point ends after it.  One undo brings
the quote back."
  (should (equal "> The quick [...] |jumps."
                 (compose-quote-test--elide "> The quick «brown fox »jumps.")))
  (should (equal "> The quick [...]|"
                 (compose-quote-test--elide "> The quick «brown fox jumps.»")))
  (should (equal "> The quick [...]|\n>\n> Second."
                 (compose-quote-test--elide "> The quick |brown\n> fox jumps.\n>\n> Second.")))
  (should (equal "> The quick [...]|"
                 (compose-quote-test--elide "> The quick |brown\n> fox jumps.\n>\n> Second." t)))
  (should (equal "> a\n> [...]|\n> c" (compose-quote-test--elide "> a\n«> b\n»> c")))
  (should (equal "> one [...] |four" (compose-quote-test--elide "> one «two\n> three »four")))
  (should (equal "> a [...] |c" (compose-quote-test--elide "> a [...] «b »c")))
  (should (equal "> foo [...]|" (compose-quote-test--elide "> foo«bar»"))))

(ert-deftest compose-quote-elide-more ()
  "A region starting in a prefix starts after it.
One reaching past the quote stops at its end.  Elisions on both sides
merge into one.  Point in a prefix elides from after it."
  (should (equal "> [...]|\n\nreply" (compose-quote-test--elide "«> one\n> two\n»\nreply")))
  (should (equal "> a\n> [...]|\n\nreply" (compose-quote-test--elide "> a\n«> b\n\nre»ply")))
  (should (equal "> [...] |c" (compose-quote-test--elide "> [...] «b »[...] c")))
  (should (equal "> a [...] |c" (compose-quote-test--elide "> a «b »[...] c")))
  (should (equal "> [...]|\n>\n> Second." (compose-quote-test--elide "|> First\n> line.\n>\n> Second.")))
  (should (equal "> a\n>\n> [...]|" (compose-quote-test--elide "> a\n>\n|> b" t)))
  (should (equal "> > deep [...]|" (compose-quote-test--elide "> > deep «text»")))
  (should (equal ">one [...]|" (compose-quote-test--elide ">one «two»")))
  (should (equal "> [...]|" (compose-quote-test--elide ">«two»"))))

(ert-deftest compose-quote-elide-merges-with-its-elision ()
  "The elision is `compose-quote-elision'."
  (let ((compose-quote-elision "…"))
    (should (equal "> a … |c" (compose-quote-test--elide "> a «b »c")))
    (should (equal "> a … |c" (compose-quote-test--elide "> a … «b »c")))))

(ert-deftest compose-quote-elide-needs-text ()
  "Nothing is elided out of a quote, nor only blanks and prefixes."
  (with-temp-buffer
    (insert "> one  two\n>\n> three\n\nreply")
    (should-error (compose-quote-elide (point-max) (point-max)) :type 'user-error)
    (goto-char (point-max))
    (should-error (compose-quote-elide) :type 'user-error)
    ;; At the end of a paragraph.
    (goto-char 11)
    (should-error (compose-quote-elide) :type 'user-error)
    ;; Blanks.
    (should-error (compose-quote-elide 6 8) :type 'user-error)
    ;; A bare line, or from a line's end to the next line's start.
    (goto-char 13)
    (should-error (compose-quote-elide) :type 'user-error)
    (should-error (compose-quote-elide 11 14) :type 'user-error)
    (should (equal "> one  two\n>\n> three\n\nreply" (buffer-string)))))

(ert-deftest compose-quote-elide-in-a-box ()
  "In a box the composition's first line starts after the prompt."
  (compose-quote-test-with
    (apply #'compose-quote-elide (compose-quote-test--draw-box "> The quick «brown »fox"))
    (should (equal "> The quick [...] |fox" (compose-quote-test--box-text)))
    (compose-quote-test--draw-box "|> The\n> fox")
    (compose-quote-elide)
    (should (equal "> [...]|" (compose-quote-test--box-text)))
    (should (compose-quote-bounds (compose-quote-test--box-start)))))

;;;; The modes

(ert-deftest compose-quote-mode-tracks-quotes ()
  "The inline mode is on while point is in a quote of the composition.
It is off elsewhere: out of the quote, in the transcript -- even on a
line starting with \">\" -- and out of the box.  `compose-quote-mode'
turns it on and off."
  (compose-quote-test-with
    (compose-quote-test--draw-box "Look:\n> one\n> two\n\n" "> Not ours.\n")
    (compose-quote-mode 1)
    (should (memq #'compose-quote--track post-command-hook))
    (should-not compose-quote-inline-mode)
    (goto-char (+ (compose-quote-test--box-start) (length "Look:\n")))
    (compose-quote-test--keys "C-f")
    (should compose-quote-inline-mode)
    (should (eq 'compose-quote-split (key-binding (kbd "M-RET"))))
    (should (eq 'compose-quote-split (key-binding (kbd "M-<return>"))))
    (should (eq 'compose-quote-elide (key-binding (kbd "C-c ["))))
    (should (eq 'compose-quote-reply (key-binding (kbd "C-c >"))))
    ;; The end of the quote's last line is in it; the line after is not.
    (goto-char (+ (compose-quote-test--box-start) (length "Look:\n> one\n> tw")))
    (compose-quote-test--keys "C-f")
    (should compose-quote-inline-mode)
    (compose-quote-test--keys "C-f")
    (should-not compose-quote-inline-mode)
    (should-not (key-binding (kbd "C-c [")))
    ;; The transcript's ">" line is not the composition's.
    (goto-char (1+ (point-min)))
    (compose-quote-test--keys "C-f")
    (should-not compose-quote-inline-mode)
    ;; Turning the mode off takes the inline mode with it.
    (goto-char (+ (compose-quote-test--box-start) (length "Look:\n")))
    (compose-quote-test--keys "C-f")
    (should compose-quote-inline-mode)
    (compose-quote-mode -1)
    (should-not compose-quote-inline-mode)
    (should-not (memq #'compose-quote--track post-command-hook))
    (compose-quote-test--keys "C-f")
    (should-not compose-quote-inline-mode)
    ;; Turned on in a quote, it is on at once.
    (compose-quote-mode 1)
    (should compose-quote-inline-mode)))

(ert-deftest compose-quote-inline-mode-binds-only-its-keys ()
  "The inline mode binds its two commands and nothing else.
Its map outranks the buffer's own keys while point is in a quote, so any
other key it took would stop working there: \\`C-c .' say, which a host
may well bind."
  (let ((keys nil))
    (map-keymap (lambda (event binding)
                  (if (keymapp binding)
                      (map-keymap (lambda (next _)
                                    (push (key-description (vector event next)) keys))
                                  binding)
                    (push (key-description (vector event)) keys)))
                compose-quote-inline-mode-map)
    (should (equal '("C-c [" "M-<return>" "M-RET") (sort keys #'string<))))
  (should (eq 'compose-quote-elide (keymap-lookup compose-quote-inline-mode-map "C-c [")))
  (should (eq 'compose-quote-split (keymap-lookup compose-quote-inline-mode-map "M-RET")))
  (should-not (keymap-lookup compose-quote-inline-mode-map "C-c .")))

(ert-deftest compose-quote-keys-answer-inline ()
  "The keys answer a quote inline, typed through the command loop.
In `compose-quote-mode', \\<compose-quote-mode-map>\\[compose-quote-reply] quotes the region.
In a quote, \\<compose-quote-inline-mode-map>\\[compose-quote-split] splits it to answer a part, and
\\[compose-quote-elide] elides the region, else the paragraph from point, or
with a prefix argument the rest of the quote.  The undo key undoes each."
  (compose-quote-test-with
    (compose-quote-mode 1)
    (compose-quote-test--draw-box "" (concat "One. Two three four five.\n"
                                             "Six seven.\n"
                                             "\n"
                                             "Eight.\n"))
    (compose-quote-test--region (point-min) (nth 2 compose-quote-test--box))
    (compose-quote-test--keys "C-c >")
    (should (equal "> ONE. TWO THREE FOUR FIVE.\n> SIX SEVEN.\n>\n> EIGHT.\n\n|"
                   (compose-quote-test--box-text)))
    (should-not compose-quote-inline-mode)
    ;; Into the quote, after "ONE.": split it there.
    (goto-char (+ (compose-quote-test--box-start) (length "> ONE.")))
    (compose-quote-test--keys "C-b C-f")
    (should compose-quote-inline-mode)
    (compose-quote-test--keys "M-RET")
    (should (equal "> ONE.\n\n|\n\n> TWO THREE FOUR FIVE.\n> SIX SEVEN.\n>\n> EIGHT.\n\n"
                   (compose-quote-test--box-text)))
    (should-not compose-quote-inline-mode)
    (compose-quote-test--keys "Yes.")
    ;; Elide "THREE FOUR " with the region.
    (let ((three (+ (compose-quote-test--box-start)
                    (length "> ONE.\n\nYes.\n\n> TWO "))))
      (compose-quote-test--region three (+ three (length "THREE FOUR "))))
    (compose-quote-test--keys "C-c [")
    (should (equal "> ONE.\n\nYes.\n\n> TWO [...] |FIVE.\n> SIX SEVEN.\n>\n> EIGHT.\n\n"
                   (compose-quote-test--box-text)))
    (should-not (region-active-p))
    ;; Without a region, the rest of the paragraph.
    (compose-quote-test--keys "C-c [")
    (should (equal "> ONE.\n\nYes.\n\n> TWO [...]|\n>\n> EIGHT.\n\n"
                   (compose-quote-test--box-text)))
    ;; Undo, then the rest of the quote instead.
    (compose-quote-test--keys "C-/")
    (should (equal "> ONE.\n\nYes.\n\n> TWO [...] FIVE.\n> SIX SEVEN.\n>\n> EIGHT.\n\n"
                   (buffer-substring-no-properties (compose-quote-test--box-start)
                                                   (compose-quote-test--box-end))))
    (goto-char (+ (compose-quote-test--box-start) (length "> ONE.\n\nYes.\n\n> TWO [...] ")))
    (compose-quote-test--keys "C-f C-b C-u C-c [")
    (should (equal "> ONE.\n\nYes.\n\n> TWO [...]|\n\n" (compose-quote-test--box-text)))
    (should (equal "One. Two three four five.\nSix seven.\n\nEight.\n" (compose-quote-test--transcript)))))

(ert-deftest compose-quote-mode-hints-at-the-keys ()
  "Entering a quote names the inline keys in the echo area, unlogged.
Not when the echo area is busy or the hint is off; moving within the
quote does not repeat it."
  (compose-quote-test-with
    (compose-quote-test--draw-box "Look:\n> one\n")
    (compose-quote-mode 1)
    (let ((shown nil)
          (busy nil)
          (compose-quote-inline-hint t))
      (cl-letf (((symbol-function 'message)
                 ;; Not the empty messages clearing the echo area, as
                 ;; `tooltip-hide' does on a text terminal.
                 (lambda (format &rest args)
                   (let ((text (apply #'format-message format args)))
                     (unless (string-empty-p text)
                       (push (list text message-log-max) shown)))))
                ((symbol-function 'current-message) (lambda () busy)))
        (goto-char (+ (compose-quote-test--box-start) (length "Look:\n")))
        (compose-quote-test--keys "C-f")
        (should (equal '(("In a quote: M-RET splits it to answer here, C-c [ elides [...]" nil)) shown))
        (compose-quote-test--keys "C-f")
        (should (= 1 (length shown)))
        ;; Busy.
        (compose-quote-test--keys "C-a C-b")
        (should-not compose-quote-inline-mode)
        (setq busy "Something else")
        (compose-quote-test--keys "C-f")
        (should compose-quote-inline-mode)
        (should (= 1 (length shown)))
        ;; Off.
        (compose-quote-test--keys "C-a C-b")
        (setq busy nil compose-quote-inline-hint nil)
        (compose-quote-test--keys "C-f")
        (should compose-quote-inline-mode)
        (should (= 1 (length shown)))))))

(ert-deftest compose-quote-mode-never-signals-after-a-command ()
  "A failing area function changes nothing, and the tracking stays on.
It stays on `post-command-hook', where an error would have taken it
off."
  (compose-quote-test-with
    (insert "> one")
    (compose-quote-mode 1)
    (should compose-quote-inline-mode)
    (setq-local compose-quote-area-function (lambda () (error "Broken")))
    (compose-quote-test--keys "C-b")
    (should (memq #'compose-quote--track post-command-hook))
    (should compose-quote-inline-mode)
    (setq-local compose-quote-area-function nil)
    (compose-quote-test--keys "C-a")
    (should compose-quote-inline-mode)
    (insert "x\n")
    (compose-quote-test--keys "C-p")
    (should-not compose-quote-inline-mode)))

;;;; The library

(ert-deftest compose-quote-compiles-cleanly ()
  "The library byte-compiles without a warning."
  (let* ((dir (make-temp-file "compose-quote-" t))
         (byte-compile-dest-file-function (lambda (_) (expand-file-name "compose-quote.elc" dir)))
         (byte-compile-error-on-warn t)
         (inhibit-message t))
    (unwind-protect
        (should (byte-compile-file (expand-file-name "compose-quote.el" compose-quote-test--directory)))
      (delete-directory dir t))
    (should-not (file-exists-p (expand-file-name "compose-quote.elc" compose-quote-test--directory)))))

(provide 'compose-quote-test)

;;; compose-quote-test.el ends here
