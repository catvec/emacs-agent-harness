;;; compose-quote.el --- Quote text to reply to it, and answer it inline  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

;; Author: catvec
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: mail, convenience

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

;; Compose a reply against the text it answers: quote what you answer,
;; then answer it inline, a part at a time.
;;
;; A buffer composes its reply in its composition: the whole buffer (a
;; mail body, a scratch buffer), or a part of it (a box under a
;; read-only transcript).  `compose-quote-reply' quotes the text the
;; reply answers into the composition as a Markdown block quote, its
;; lines after "> ": the region, read back as it shows, or else the
;; message at point, whole.  Point ends under the quote, after a blank
;; line, where the reply goes.
;;
;; Inside a quote, `compose-quote-inline-mode' answers it inline:
;; `compose-quote-split' (M-RET) splits the quote where point is,
;; leaving an empty line between its parts for an answer, and
;; `compose-quote-elide' (C-c [) replaces part of it with "[...]",
;; keeping the rest -- typically the front matter -- for context.
;;
;; `compose-quote-mode' turns it all on in a buffer: it binds C-c > to
;; `compose-quote-reply', and turns the inline mode on while point is
;; in a quote of the composition and off elsewhere:
;;
;;   (add-hook 'message-mode-hook #'compose-quote-mode)
;;
;; A buffer that composes in only a part of itself, or shows text
;; otherwise than as it was written, says so with buffer-local
;; variables:
;;
;; - `compose-quote-area-function': where the composition is, as
;;   (START END [FRONT]); the whole buffer by default.
;; - `compose-quote-source-function': reads text outside the
;;   composition back for quoting, say Markdown drawn with faces back
;;   into its markup.
;; - `compose-quote-function', and the `compose-quote' text property:
;;   the message at point, quoted when there is no region.
;; - `compose-quote-insert-hook': runs after a quote went in.
;;
;; Quotes are found from their lines alone, those starting with ">", so
;; a quote typed or yanked in counts as much as one this library put
;; there.

;;; Code:

(require 'subr-x)

(defgroup compose-quote nil
  "Quote text to reply to it, and answer it inline."
  :group 'mail
  :prefix "compose-quote-")

(defcustom compose-quote-elision "[...]"
  "The text `compose-quote-elide' leaves where it removes part of a quote."
  :type 'string
  :group 'compose-quote)

(defcustom compose-quote-inline-hint t
  "Non-nil to name the inline keys in the echo area as point enters a quote.
The hint shows when `compose-quote-mode' turns `compose-quote-inline-mode'
on, unless the echo area already shows something, and it is not logged
in the *Messages* buffer."
  :type 'boolean
  :group 'compose-quote)

;;;; The composition

(defvar-local compose-quote-area-function nil
  "Function returning where this buffer composes its reply, or nil.
Nil means the whole accessible buffer is the composition.  Otherwise a
function of no arguments, returning nil when there is no composition
right now, or a list (START END [FRONT]): START and END, positions or
markers, bound the composition's text.  FRONT, START by default, is
where the composition shows to start when something precedes START on
its line, such as a prompt: text before FRONT is outside it, and text
from FRONT to START belongs to neither.")

(defvar-local compose-quote-source-function #'buffer-substring-no-properties
  "Function reading text outside the composition back, to quote it.
It is called with BEG and END and returns the text between them.  A
buffer whose text is rendered, say Markdown drawn with faces, sets a
function that restores the markup.")

(defvar-local compose-quote-function nil
  "Function returning the text of the message at point to quote, or nil.
It is called with no arguments, point where `compose-quote-reply' was
run, when there is no region and no `compose-quote' text property at
point.  A buffer that shows messages sets it: a chat's might return the
message at point, or else the one above it.")

(defvar compose-quote-insert-hook nil
  "Normal hook run after a quote is inserted.
Point is under the quote, after the blank line following it, where the
reply goes.  Add to it buffer-locally.")

(defun compose-quote--position (pos)
  "Return POS, a position or a marker, as a number, or nil."
  (if (markerp pos) (marker-position pos) (and (integerp pos) pos)))

(defun compose-quote--area ()
  "Return the composition as (START END FRONT), numbers, or nil.
See `compose-quote-area-function'."
  (if (null compose-quote-area-function)
      (list (point-min) (point-max) (point-min))
    (when-let* ((area (funcall compose-quote-area-function))
                ((consp area))
                (start (compose-quote--position (nth 0 area)))
                (end (compose-quote--position (nth 1 area))))
      (let ((start (max start (point-min)))
            (end (min end (point-max)))
            (front (or (compose-quote--position (nth 2 area)) start)))
        (and (<= start end)
             (list start end (max (point-min) (min front start))))))))

(defun compose-quote--line (pos area)
  "Return (BOL . EOL) of the line at POS, cut to AREA, the composition.
The line's start is never before the composition's start, nor its end
after the composition's end.  Fields are ignored: a prompt before the
composition is not part of the line."
  (save-excursion
    (goto-char pos)
    (cons (max (nth 0 area) (pos-bol)) (min (nth 1 area) (pos-eol)))))

;;;; Quoting

(defun compose-quote-string (text)
  "Return TEXT as a Markdown block quote: every line after \"> \".
Blank lines around TEXT and blanks at the ends of lines are dropped; a
blank line within TEXT reads \">\", which keeps the quote one block.
Indentation stays, as code needs."
  (mapconcat (lambda (line)
               (let ((line (string-trim-right line)))
                 (if (string-empty-p line) ">" (concat "> " line))))
             (split-string (string-trim-left (string-trim-right (substring-no-properties text))
                                             "\\(?:[ \t]*\n\\)+")
                           "\n")
             "\n"))

(defun compose-quote-insert (text &optional start)
  "Insert TEXT quoted at point, and leave point where the reply goes.
The quote is `compose-quote-string' of TEXT.  It is a blank line apart
from the text before it, from START on (by default the buffer's
start): no newline goes before it when that text is empty or already
ends in a blank line.  A blank line follows it, which Markdown needs
between a quote and what is not part of it, and point ends after that.
Deactivate the mark, run `compose-quote-insert-hook', and return
\(BEG . END), the bounds of the quote's lines."
  (when (string-blank-p text) (user-error "Nothing to quote"))
  (deactivate-mark)
  (let ((start (or start (point-min))))
    (insert (cond ((<= (point) start) "")
                  ((not (eq (char-before) ?\n)) "\n\n")
                  ((and (> (1- (point)) start) (eq (char-before (1- (point))) ?\n)) "")
                  (t "\n"))))
  (let ((beg (point-marker))
        (end nil))
    (insert (compose-quote-string text))
    (setq end (point-marker))
    (insert "\n\n")
    (run-hooks 'compose-quote-insert-hook)
    (prog1 (cons (marker-position beg) (marker-position end))
      (set-marker beg nil)
      (set-marker end nil))))

(defun compose-quote--text (value)
  "Return VALUE when it is a string that is not blank, else nil."
  (and (stringp value) (not (string-blank-p value)) value))

(defun compose-quote-at-point ()
  "Return the text of the message at point to quote, or nil.
That is the `compose-quote' property at point, else what
`compose-quote-function' returns, whichever is a string not blank."
  (or (compose-quote--text (get-char-property (point) 'compose-quote))
      (and compose-quote-function
           (compose-quote--text (funcall compose-quote-function)))))

(defun compose-quote-reply (&optional beg end)
  "Quote the region, or the message at point, to reply to it.
The quote is Markdown, its lines after \"> \", and goes in the
composition (`compose-quote-area-function'): point ends under it, after
a blank line, ready for the reply (`compose-quote-insert').
Interactively, BEG and END are the region's, while it is active.

A region quotes the text it selects.  Only its part before the
composition counts, read back with `compose-quote-source-function' and
quoted at the composition's end; a region in the composition turns into
a quote where it is.

Without a region the message at point is quoted whole, at point in the
composition or else at its end.  The buffer says which message that
is: the text at point names it with a `compose-quote' property, else
`compose-quote-function' finds it.

Return the bounds of the quote, as `compose-quote-insert' does."
  (interactive (and (use-region-p) (list (region-beginning) (region-end))))
  (pcase-let ((`(,start ,stop ,front)
               (or (compose-quote--area) (user-error "No reply is being composed here"))))
    (cond
     ((and beg end (< beg front))
      (let ((text (funcall compose-quote-source-function beg (min end front))))
        ;; Not where the region ends in the composition: it reached in
        ;; from above.
        (goto-char stop)
        (compose-quote-insert text start)))
     ((and beg end (< (max beg start) (min end stop)))
      (let* ((beg (max beg start))
             (end (min end stop))
             (text (buffer-substring-no-properties beg end)))
        (when (string-blank-p text) (user-error "Nothing to quote"))
        (delete-region beg end)
        (goto-char beg)
        (compose-quote-insert text start)))
     (t
      (let ((text (or (compose-quote-at-point)
                      (user-error "Nothing to quote here: select the text to quote"))))
        (unless (<= start (point) stop) (goto-char stop))
        (compose-quote-insert text start))))))

;;;; Quotes in the composition

(defconst compose-quote--prefix-regexp "\\(?:> ?\\)+"
  "Regexp matching the prefix of a quoted line, such as \"> \" or \"> > \".")

(defun compose-quote--quoted-p (bol eol)
  "Non-nil when the line from BOL to EOL is a quote's: it starts with \">\"."
  (and (< bol eol) (eq (char-after bol) ?>)))

(defun compose-quote--content (bol eol)
  "Return where the content of the quoted line from BOL to EOL starts.
That is after its prefix, the match of `compose-quote--prefix-regexp'."
  (save-excursion
    (goto-char bol)
    (if (looking-at compose-quote--prefix-regexp) (min eol (match-end 0)) bol)))

(defun compose-quote--bare-p (bol eol)
  "Non-nil when the quoted line from BOL to EOL holds only its prefix.
Blanks after the prefix do not count."
  (save-excursion
    (goto-char (compose-quote--content bol eol))
    (skip-chars-forward " \t" eol)
    (= (point) eol)))

(defun compose-quote--blank-p (beg end)
  "Non-nil when the text from BEG to END is only blanks, or empty."
  (or (>= beg end)
      (save-excursion
        (goto-char beg)
        (skip-chars-forward " \t" end)
        (= (point) end))))

(defun compose-quote--bounds (pos area)
  "Return (BEG . END) of the quote around POS in AREA, or nil.
AREA is the composition, as `compose-quote--area' returns it, or nil."
  (when (and area (<= (nth 0 area) pos (nth 1 area)))
    (pcase-let ((`(,bol . ,eol) (compose-quote--line pos area)))
      (when (compose-quote--quoted-p bol eol)
        (let ((beg bol)
              (end eol))
          (while (and (> beg (nth 0 area))
                      (pcase-let ((`(,b . ,e) (compose-quote--line (1- beg) area)))
                        (and (compose-quote--quoted-p b e) (setq beg b)))))
          (while (and (< end (nth 1 area))
                      (pcase-let ((`(,b . ,e) (compose-quote--line (1+ end) area)))
                        (and (compose-quote--quoted-p b e) (setq end e)))))
          (cons beg end))))))

(defun compose-quote-bounds (&optional pos)
  "Return (BEG . END) of the quote around POS, point by default, or nil.
A quote is a run of lines of the composition that start with \">\",
bare \">\" lines included: BEG is where its first line starts, END
where its last line ends, before its newline.  Lines outside the
composition never count, whatever they start with."
  (compose-quote--bounds (or pos (point)) (compose-quote--area)))

(defun compose-quote--in-quote-p ()
  "Non-nil when point is on a line of a quote of the composition.
Only point's line is looked at."
  (when-let* ((area (compose-quote--area)))
    (and (<= (nth 0 area) (point) (nth 1 area))
         (pcase-let ((`(,bol . ,eol) (compose-quote--line (point) area)))
           (compose-quote--quoted-p bol eol)))))

;;;; Splitting a quote

(defun compose-quote--first-end (qbeg pos area)
  "Return where the first part of a split quote ends, the part ending at POS.
QBEG is where the quote starts and AREA is the composition.  Blanks at
the part's end are left out, and so are bare lines, which separated
paragraphs: QBEG when nothing else is left."
  (catch 'done
    (while t
      (pcase-let* ((`(,bol . ,eol) (compose-quote--line pos area))
                   (content (compose-quote--content bol eol))
                   (end (save-excursion
                          (goto-char pos)
                          (skip-chars-backward " \t" content)
                          (point))))
        (cond ((> end content) (throw 'done end))
              ((> bol qbeg) (setq pos (1- bol)))
              (t (throw 'done qbeg)))))))

(defun compose-quote--second-start (pos qend area)
  "Return where the second part of a split quote starts, the part from POS.
POS is where a line starts, QEND where the quote ends and AREA is the
composition.  Bare lines at the part's start are left out: QEND when
nothing else is left."
  (catch 'done
    (while t
      (pcase-let ((`(,bol . ,eol) (compose-quote--line pos area)))
        (cond ((not (compose-quote--bare-p bol eol)) (throw 'done bol))
              ((< eol qend) (setq pos (1+ eol)))
              (t (throw 'done qend)))))))

(defun compose-quote-split ()
  "Split the quote at point, to answer the part above it right there.
Point ends on an empty line between the two parts, a blank line apart
from each, where the answer goes.

Point at the start of a line, in its \">\" prefix, or after only blanks
there splits the quote before that line; point followed by only blanks
splits it after the line.  Elsewhere the line itself is split: its
text after point starts a line of the second part, behind the same
prefix.  Bare \">\" lines where the parts meet go, as do the blanks."
  (interactive "*")
  (let* ((area (compose-quote--area))
         (quote (or (compose-quote--bounds (point) area) (user-error "Not in a quote")))
         (qbeg (car quote))
         (qend (cdr quote))
         (pos (point))
         (line (compose-quote--line pos area))
         (bol (car line))
         (eol (cdr line))
         (content (compose-quote--content bol eol))
         (prefix nil)
         (cut-start nil)
         (cut-end nil))
    (cond
     ;; Before the line.
     ((compose-quote--blank-p content pos)
      (setq cut-start (if (> bol qbeg) (compose-quote--first-end qbeg (1- bol) area) qbeg)
            cut-end (compose-quote--second-start bol qend area)))
     ;; After it.
     ((compose-quote--blank-p pos eol)
      (setq cut-start (compose-quote--first-end qbeg eol area)
            cut-end (if (< eol qend) (compose-quote--second-start (1+ eol) qend area) qend)))
     ;; Within it.
     (t
      (setq cut-start (save-excursion (skip-chars-backward " \t" content) (point))
            cut-end (save-excursion (skip-chars-forward " \t" eol) (point))
            prefix (buffer-substring-no-properties bol content))))
    (let ((first (> cut-start qbeg))
          (second (or prefix (< cut-end qend))))
      (delete-region cut-start cut-end)
      (goto-char cut-start)
      (insert (if first "\n\n" "") (if second "\n\n" "") (or prefix ""))
      (goto-char (+ cut-start (if first 2 0)))
      (deactivate-mark))))

;;;; Eliding part of a quote

(defun compose-quote--past-prefix (pos area)
  "Return POS, or the end of its line's prefix when POS is in that prefix.
AREA is the composition."
  (pcase-let ((`(,bol . ,eol) (compose-quote--line pos area)))
    (max pos (compose-quote--content bol eol))))

(defun compose-quote--before-prefix (from pos area)
  "Return POS, or the end of the line before when POS is in a line's prefix.
That is when POS is at the start of a line after the one of FROM, or in
its prefix.  AREA is the composition."
  (pcase-let ((`(,bol . ,eol) (compose-quote--line pos area)))
    (if (and (> bol (car (compose-quote--line from area)))
             (<= pos (compose-quote--content bol eol)))
        (1- bol)
      pos)))

(defun compose-quote--paragraph-end (pos qend area)
  "Return where the paragraph of the quote at POS ends.
That is the end of the last line of the run of lines that are not bare
from POS's line on, or of POS's line when it is bare.  QEND is where
the quote ends and AREA is the composition."
  (pcase-let ((`(,bol . ,eol) (compose-quote--line pos area)))
    (unless (compose-quote--bare-p bol eol)
      (while (and (< eol qend)
                  (pcase-let ((`(,b . ,e) (compose-quote--line (1+ eol) area)))
                    (and (not (compose-quote--bare-p b e)) (setq eol e))))))
    eol))

(defun compose-quote--text-p (from to area)
  "Non-nil when the quote holds more than blanks from FROM to TO.
The prefixes of its lines do not count.  AREA is the composition."
  (let ((pos from)
        (found nil))
    (while (and (not found) (< pos to))
      (pcase-let ((`(,bol . ,eol) (compose-quote--line pos area)))
        (setq found (not (compose-quote--blank-p (max pos (compose-quote--content bol eol))
                                                 (min to eol)))
              pos (1+ eol))))
    found))

(defun compose-quote--marker-at-p (pos limit)
  "Non-nil when `compose-quote-elision' is at POS, ending by LIMIT."
  (let ((end (+ pos (length compose-quote-elision))))
    (and (<= end limit)
         (string= compose-quote-elision (buffer-substring-no-properties pos end)))))

(defun compose-quote-elide (&optional beg end whole)
  "Elide part of the quote at point: replace it with `compose-quote-elision'.
The rest of the quote stays, typically its front matter, for context.
Interactively, BEG and END are the region's, while it is active, and
WHOLE is the prefix argument.

With BEG and END, the part from BEG to END goes, as far as the quote
reaches.  Whole lines go as one: their prefixes stay on the first of
them, which holds the elision.  Without, the part from point to the
end of its paragraph goes or, with WHOLE, to the end of the quote.

What stays of the first and the last line the part touches joins on
one line around the elision, a space apart.  An elision next to one
already there merges into it.  Point ends after the elision."
  (interactive (progn (barf-if-buffer-read-only)
                      (if (use-region-p)
                          (list (region-beginning) (region-end) nil)
                        (list nil nil current-prefix-arg))))
  (let* ((area (compose-quote--area))
         (quote (or (compose-quote--bounds (or beg (point)) area) (user-error "Not in a quote")))
         (qend (cdr quote))
         (from (compose-quote--past-prefix (or beg (point)) area))
         (to (cond (beg (compose-quote--before-prefix from (min (or end beg) qend) area))
                   (whole qend)
                   (t (compose-quote--paragraph-end from qend area)))))
    (unless (and (< from to) (compose-quote--text-p from to area))
      (user-error "Nothing to elide here"))
    (let* ((elision compose-quote-elision)
           (content (pcase-let ((`(,bol . ,eol) (compose-quote--line from area)))
                      (compose-quote--content bol eol)))
           (eol (cdr (compose-quote--line to area)))
           ;; The blanks around the part go with it: the elision puts
           ;; back one space each side.
           (from (save-excursion (goto-char from) (skip-chars-backward " \t" content) (point)))
           (to (save-excursion (goto-char to) (skip-chars-forward " \t" eol) (point)))
           (before (and (>= (- from content) (length elision))
                        (compose-quote--marker-at-p (- from (length elision)) from)))
           (after (compose-quote--marker-at-p to eol)))
      (when (and before after)
        ;; Elided on both sides already: one elision for all of it.
        (setq to (save-excursion
                   (goto-char (+ to (length elision)))
                   (skip-chars-forward " \t" eol)
                   (point))
              after nil))
      (let ((space (if (memq (char-before from) '(?\s ?\t)) "" " "))
            (rest (if (< to eol) " " "")))
        (delete-region from to)
        (goto-char from)
        (cond (before (insert rest))
              (after (insert space)
                     (forward-char (length elision))
                     (when (eq (char-after) ?\s) (forward-char 1)))
              (t (insert space elision rest)))
        (deactivate-mark)))))

;;;; The modes

(defvar-keymap compose-quote-inline-mode-map
  :doc "Keymap of `compose-quote-inline-mode', on while point is in a quote.
\\`C-c' and most punctuation characters are a minor mode's to bind:
\\`C-c [' for the \"[...]\" it leaves.  \\`M-RET' splits a quote in
`message-mode' as well.  The map binds nothing else, so that the keys
of the buffer's own modes still work in a quote."
  "M-RET" #'compose-quote-split
  "M-<return>" #'compose-quote-split
  "C-c [" #'compose-quote-elide)

(put 'compose-quote-split :advertised-binding (kbd "M-RET"))

(define-minor-mode compose-quote-inline-mode
  "Answer a quote inline: split it, and elide parts of it.
`compose-quote-mode' turns this mode on while point is in a quote of the
composition, and off elsewhere.

\\<compose-quote-inline-mode-map>\\[compose-quote-split] splits the quote where point is, leaving an empty line
between its parts for an answer to the part above.  \\[compose-quote-elide] replaces
the region, or the rest of the paragraph from point, with
`compose-quote-elision'; with a prefix argument, the rest of the quote.

\\{compose-quote-inline-mode-map}"
  :lighter " Quote")

(defun compose-quote--hint ()
  "Name the inline keys in the echo area, without logging them.
Only while `compose-quote-inline-hint' is non-nil and the echo area
shows nothing else."
  (when (and compose-quote-inline-hint (not (current-message)))
    (let ((message-log-max nil))
      (message "%s" (concat (substitute-command-keys
                             "In a quote: \\<compose-quote-inline-mode-map>\\[compose-quote-split] \
splits it to answer here, \\[compose-quote-elide] elides ")
                            compose-quote-elision)))))

(defun compose-quote--track ()
  "Turn `compose-quote-inline-mode' on while point is in a quote, off elsewhere.
On `post-command-hook' in `compose-quote-mode'.  It looks at point's
line only, and never signals: an error would take it off the hook."
  (condition-case nil
      (let ((in (compose-quote--in-quote-p)))
        (cond ((and in (not compose-quote-inline-mode))
               (compose-quote-inline-mode 1)
               (compose-quote--hint))
              ((and (not in) compose-quote-inline-mode)
               (compose-quote-inline-mode -1))))
    (error nil)))

(defvar-keymap compose-quote-mode-map
  :doc "Keymap of `compose-quote-mode'.
By convention \\`C-c >' is a major mode's to bind, not a minor mode's;
the mode binds it all the same, since quoting is what it is for.  Bind
another key here to change it."
  "C-c >" #'compose-quote-reply)

;;;###autoload
(define-minor-mode compose-quote-mode
  "Quote text to reply to it, and answer the quote inline.
\\<compose-quote-mode-map>\\[compose-quote-reply] quotes the region, or the message at point, in the composition,
ready for the reply (`compose-quote-reply').  While point is in a quote
of the composition, `compose-quote-inline-mode' is on, to split the
quote and elide parts of it.

A buffer composing its reply in only a part of itself says where with
`compose-quote-area-function'.

\\{compose-quote-mode-map}"
  :lighter nil
  (if compose-quote-mode
      (progn
        (add-hook 'post-command-hook #'compose-quote--track nil t)
        (compose-quote--track))
    (remove-hook 'post-command-hook #'compose-quote--track t)
    (when compose-quote-inline-mode (compose-quote-inline-mode -1))))

(provide 'compose-quote)

;;; compose-quote.el ends here
