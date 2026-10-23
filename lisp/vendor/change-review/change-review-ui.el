;;; change-review-ui.el --- Threads of a change review, in Emacs buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

;; Author: catvec
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, vc, convenience

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

;; The user interface of change-review: a thread of comments is drawn by
;; one function, `change-review-ui-thread-string', wherever it shows,
;; and two views use it.
;;
;; THE THREAD.  A thread reads as a header, then its comments:
;;
;;   ● t-3f9a · line 18 · 3 comments · open          [Reply] [Close] [Diff]
;;   ┃ 1/3  Noah Huppert (you) · 2026-10-19 21:57 (2h ago) · v1  ▸ where
;;   ┃      Why eighteen?  The tests only ever use 17.
;;   ┃ 2/3  Claude (agent) · 2026-10-19 22:10 (1h ago) · v2  ↗ conversation
;;   ┃      Because the retry loop needs one more.
;;   ┃ 3/3  Noah Huppert (you) · draft · ↳ re 1/3  [Edit] [Delete]
;;   ┃      Then say so in a comment.
;;
;; Each comment says who wrote it (and what kind of author that is),
;; when, against which revision, whether it is a draft, and where it
;; sits in the thread: its number out of the thread's comments, and the
;; one it answers when that is not the one before.  The header says
;; whether the thread is open or closed, who closed it and when.  A
;; closed thread can be drawn as one line.  One that someone else closed
;; says `to review' until the user has looked at it and said so, or
;; answered it (see below), and is then drawn whole.
;;
;; A DRAFT can be changed, or taken back: it has an [Edit] button and a
;; [Delete] button, which act on that draft whatever point is on -- point
;; cannot be on a thread drawn under a line of another buffer, so the
;; buttons are how one of several drafts there is named -- and
;; `change-review-ui-edit-draft' (e) edits the comment at point, or, on
;; a thread's header or under a line that has threads, a draft of those
;; threads, asking which when there are several.  k deletes a draft the
;; same way, after asking.  A thread that is nothing but drafts can be
;; taken back whole: its header has a [Delete thread] button, and K
;; (`change-review-ui-delete-draft-thread') deletes the thread at point,
;; or the one of those under the line that is.  The first draft of a
;; thread that has more cannot go alone -- the thread has its place from
;; it -- so what asks about it asks about the thread.  What was sent is
;; not a draft any more, and is not changed or deleted.
;;
;; THE TEXT.  What a comment says is drawn as its author typed it, its
;; lines wrapped to the width under the bar.  A kind of set whose
;; comments are written in a markup -- Markdown, say -- draws them as
;; that markup does by answering `change-review-ui-body-lines' (the
;; lines of a comment) and `change-review-ui-body-summary' (the first
;; words of it, where a thread is one line); every view draws the text
;; through them.
;;
;; FITTING.  A line of the drawing is never wider than the width it is
;; drawn to: a header that does not fit says less -- how long ago instead
;; of the date, the revision left out, the buttons shortened -- until it
;; does, so a thread in a narrow window does not wrap.
;;
;; FOLDING.  A thread under a line of a diff, where the room is the
;; window's, folds.  A closed thread is one line, with the first words of
;; what it says, and TAB on its line, a click on its triangle or on the
;; words opens it to its conversation.  One that is longer than the window
;; has room for is cut after the lines it has, and TAB again, or a click
;; on "… more lines", shows all of it; one more TAB folds any thread to a
;; line.  What was folded is kept with the set, so it stays so when the
;; view is drawn again.
;;
;; THE THREADS VIEW (`change-review-open-threads').  All the threads of a
;; change set, grouped by file, with a filter on their status: open,
;; closed, all, or to review.  Point is on a comment, and the keys act
;; on it: RET shows where it was made (the file and line, the revision,
;; and the lines of the diff it was made on), r replies to it, x closes
;; its thread or opens it again, m marks its thread reviewed, d shows
;; it in the diff view, o follows an agent's comment to the
;; conversation it came from, e edits a draft, k deletes it (K a thread
;; of drafts), c comments on the change as a whole.  n and p move between
;; comments, N and P between threads, f changes the filter.
;;
;; WHAT WAITS FOR THE USER.  An agent answers a thread and closes it; the
;; user is the one who says it is done.  A thread closed by someone other
;; than the user is TO REVIEW (`change-review-thread-unreviewed-p'), and
;; the filter of that name lists those, so that after a round of work the
;; user sees what was closed and reads the answers.  A thread leaves the
;; filter only when the user acts on it: m (or [Mark reviewed]) says
;; they looked at it, M says so for all that wait, a reply to it does
;; too, and opening it again takes it out of the closed ones.  Nothing
;; marks a thread by itself, so a close missed for two rounds still
;; waits.  m on a thread already reviewed makes it wait again.
;;
;; WHERE A COMMENT WAS MADE.  The lines under a comment are the diff of
;; the revision it was written against, as it was then: the answer to a
;; comment changes the code it is about, and the newest version's diff
;; would make the comment read as if it asked for what is there already
;; (`change-review-origin').  A reply, whose thread started on another
;; revision, has the lines of its own.  The details also lead to the
;; code: [Source @ v1] shows it as it was when the comment was written
;; (D does), [Source @ v2] in the newest version (d does), and RET on a
;; line of the diff shows that line of the source (`change-review-visit'
;; with a version).
;;
;; THE DIFF VIEW (`change-review-open-diff').  The files of a version as the
;; unified diff, with the threads under the lines they are about, drawn
;; by the same function.  c comments on the line at point, or on the
;; region; r, x, o and RET do what they do in the threads view for the
;; thread under point.  `change-review-visit' shows a thread in it.
;;
;; THE THREADS AMONG OTHER TEXT.  The body of the threads view is a string
;; of its own, `change-review-ui-threads-string', and the line that heads
;; it, with the buttons of the status filter, another,
;; `change-review-ui-threads-heading': a buffer that shows the threads as
;; a section of its text, a report or a side panel, draws them with those
;; and binds the keys of the threads view where they are.
;;
;; The views follow the set: whatever changes it, they draw again
;; (`change-review-changed-functions').  Other views of a diff, such as a
;; side-by-side comparison, draw the threads under their lines with
;; `change-review-ui-add-thread-overlay' and bind the same commands, in
;; `change-review-ui-lines-mode' or in a map of their own.
;;
;; QUOTE REPLY (`change-review-ui-quote-reply', C-c > in every view).
;; Select part of a comment and it starts a reply to the comment with that
;; part quoted, as a mail's does -- "> " before each line, point under the
;; quote -- or, with nothing selected, with all of the comment quoted.  The
;; threads view is text, so its selection is the region.  A thread drawn
;; under a line is a string an overlay shows, no text of the buffer, so
;; the region cannot hold any of it: the mouse selects its text instead
;; (`change-review-ui-mouse-select').  Either way what is selected is read
;; back as the text of the comment it is of, as it was written, not as it is
;; drawn, wrapped and under a bar (`change-review-ui--offset-at').  Where
;; compose-quote is installed, the buffer the reply is read in answers a
;; quote inline with it: M-RET splits it, C-c [ elides part of it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'button)
(require 'diff-mode)
(require 'pulse)
(require 'change-review)
(require 'change-review-diff)
(require 'change-review-mail)

(defgroup change-review-ui nil
  "Threads of a change review, in Emacs buffers."
  :group 'change-review :prefix "change-review-ui-")

(defcustom change-review-ui-time-format "%Y-%m-%d %H:%M"
  "How `format-time-string' writes the time of a comment."
  :type 'string)

(defcustom change-review-ui-relative-times t
  "Whether a time is followed by how long ago it was, as \"(2h ago)\"."
  :type 'boolean)

(defcustom change-review-ui-width nil
  "The width threads are drawn to, in columns; nil for the window's.
Long lines of a comment are wrapped to it, under the comment's bar."
  :type '(choice (const :tag "The window's" nil) natnum))

(defcustom change-review-ui-default-filter 'open
  "Which threads the threads view shows at first.
`open', `closed', `all', or `unreviewed': the closed threads that wait
for the user to review them."
  :type '(choice (const open) (const closed) (const all)
                 (const :tag "to review" unreviewed)))

(defcustom change-review-ui-collapse-closed-in-diff t
  "Whether a closed thread is drawn as one line, until it is opened.
In the diff view, and in any other view of the lines of a file, a
comparison in Ediff say.  \\`TAB' on the line opens it to its conversation,
and folds any thread to one line.  A closed thread that waits for the
user to review it is drawn whole all the same, so that what was
answered is in sight."
  :type 'boolean)

(defcustom change-review-ui-max-thread-lines 'window
  "The most lines a thread takes under a line of a diff.
A number; `window' for what the window shows, its height less a few
lines, so the line the thread is under stays in sight; nil for no limit.
A thread that is longer is cut after the lines it has room for, with how
many more there are in a line of its own: \\`TAB' on the thread, or a
click on that line, shows all of it.  The threads view has no limit."
  :type '(choice (const :tag "What the window shows" window)
                 (const :tag "No limit" nil)
                 natnum))

(defcustom change-review-ui-tail-replies 3
  "How many of the last comments of a long thread are drawn in full.
A thread with many comments keeps its first, folds away the ones after
it, and draws the last this many: where the folded comments were there
is one line, \"▸ 6 earlier replies\", and a click on it (or the
\\`TAB' that shows all of the thread) draws them.  A comment that is a
draft, or whose details are shown, is never folded away, and neither
is any comment after it.  Fewer than two comments are not worth a line
of their own, so a thread folds only when that many would go.  nil
never folds comments away.  The chat folds the replies of its threads
by this number too."
  :type '(choice (const :tag "Never fold comments away" nil) natnum))

(defcustom change-review-ui-max-comment-lines 15
  "The most lines of a comment's text drawn before \"Show more\".
A comment longer than that is cut after this many lines (as drawn: the
text wrapped to the room it has, or rendered, in a set that renders
it), with how many there are more and a button, [Show more], that draws
all of it; a comment drawn so ends with [Show less], which cuts it
again.  A comment only a line over is not cut: that line is no
shorter than the button.  nil never cuts a comment.  The chat cuts the
replies of its threads by this number too."
  :type '(choice (const :tag "Never cut a comment" nil) natnum))

(defcustom change-review-ui-read-function #'change-review-ui-read-with-string-edit
  "The function that reads the text of a comment.
It is called with a prompt, the text to start from and a function to
call with the text read, which it calls when the user is done and not
at all when they give up.  The default edits the text in a buffer of
its own, where \\`C-c C-c' finishes and \\`C-c C-k' gives up.

A function that takes a fourth argument is given where point starts in
the text, `end' when that is after it, as it is for a reply that starts
with a quote, else nil."
  :type 'function)

(defcustom change-review-ui-directory (locate-user-emacs-file "change-review/")
  "The directory that keeps the reviews of emailed patches.
`change-review-open-patches' keeps the threads of a set of patches in a
file here, named after the set, so that they are there when the same
patches are opened again."
  :type 'directory)

(defvar change-review-set-function nil
  "A function that returns the change set of the current buffer, or nil.
A buffer that is none of the views of this library, a side-by-side
comparison say, has its set through this, or in `change-review-ui--set'.")

;;;; Faces

(defface change-review-ui-open-face '((t :inherit warning :weight bold))
  "The mark and the word of an open thread.")
(defface change-review-ui-closed-face '((t :inherit success))
  "The mark and the word of a closed thread.")
(defface change-review-ui-review-face '((t :inherit warning))
  "The words \"to review\", on a thread someone else closed that waits for the user.")
(defface change-review-ui-user-face '((t :inherit font-lock-keyword-face :weight bold))
  "The name of a comment's author, for a user.")
(defface change-review-ui-agent-face '((t :inherit font-lock-type-face :weight bold))
  "The name of a comment's author, for an agent.")
(defface change-review-ui-other-face '((t :inherit font-lock-constant-face :weight bold))
  "The name of a comment's author, for any other kind.")
(defface change-review-ui-meta-face '((t :inherit shadow))
  "Times, revisions and ids.")
(defface change-review-ui-draft-face '((t :inherit (warning italic)))
  "The mark of a draft, a comment not sent yet.")
(defface change-review-ui-position-face '((t :inherit (shadow bold)))
  "The place of a comment in its thread.")
(defface change-review-ui-header-face '((t :inherit bold))
  "The headings of the views.")
(defface change-review-ui-file-face '((t :inherit (bold font-lock-function-name-face)))
  "The name of a file in the threads view.")
(defface change-review-ui-button-face '((t :inherit button))
  "The buttons of a thread.")
(defface change-review-ui-fold-face '((t :inherit (shadow bold)))
  "The triangle that folds a thread, and the words that show the rest of it.")
(defface change-review-ui-filter-face '((t :inherit (bold highlight)))
  "The status filter in force.")
(defface change-review-ui-target-face '((t :inherit bold :extend t))
  "The line a comment was made on, in the lines it quotes.")
(defface change-review-ui-quote-face '((t :inherit font-lock-comment-face))
  "The lines of a comment that quote another, those that start with \">\".")
(defface change-review-ui-selection-face '((t :inherit region))
  "The text of a comment selected with the mouse in a thread under a line.")

;;;; State of a view

(defvar-local change-review-ui--set nil
  "In a view of this library, the change set it shows.")

(defvar-local change-review-ui--filter nil
  "In a view, which threads it shows: `open', `closed' or `all'.")

(defvar-local change-review-ui--details nil
  "In a view, the ids of the comments that show where they were made.")

(defvar-local change-review-ui--version nil
  "In the diff view, the version it shows.")

(defvar-local change-review-ui--redraw-function nil
  "In a view, the function that draws it again.")

(defvar-local change-review-ui--timer nil
  "In a view, the timer that draws it again, while one is waiting.")

(defvar change-review-ui--source-map)

;;;; Time and width

(defun change-review-ui-ago (time &optional now)
  "Return how long before NOW (default the present) TIME was, as \"2h ago\"."
  (let ((seconds (- (or now (float-time)) time)))
    (cond ((< seconds -60) "in the future")
          ((< seconds 45) "just now")
          ((< seconds 3600) (format "%dm ago" (max 1 (round (/ seconds 60)))))
          ((< seconds 86400) (format "%dh ago" (round (/ seconds 3600))))
          ((< seconds (* 86400 60)) (format "%dd ago" (round (/ seconds 86400))))
          ((< seconds (* 86400 700)) (format "%dmo ago" (round (/ seconds 86400 30))))
          (t (format "%dy ago" (round (/ seconds 86400 365)))))))

(defun change-review-ui--time (time)
  "Return TIME for a comment's header: the date, and how long ago it was."
  (cond ((not (numberp time)) "")
        (change-review-ui-relative-times
         (format "%s (%s)" (format-time-string change-review-ui-time-format time)
                 (change-review-ui-ago time)))
        (t (format-time-string change-review-ui-time-format time))))

(defun change-review-ui--window ()
  "Return a window that shows the current buffer, in any frame, or nil."
  (get-buffer-window (current-buffer) t))

(defun change-review-ui-current-width ()
  "Return the width to draw a thread to.
That is `change-review-ui-width' when it is set, else the columns a line
of the window that shows the buffer has -- less the one a continuation
takes in a terminal -- else 80; never under 40 or over 160."
  (let ((window (change-review-ui--window)))
    (max 40 (min 160 (or change-review-ui-width
                         (and window (window-max-chars-per-line window))
                         80)))))

(defun change-review-ui-current-max-lines ()
  "Return the most lines a thread takes in this buffer, or nil for no limit.
That is `change-review-ui-max-thread-lines': a number, or for `window'
the height of the window that shows the buffer less four lines (20 when
none does), never under six."
  (let ((limit change-review-ui-max-thread-lines))
    (cond ((natnump limit) (max 3 limit))
          ((eq limit 'window)
           (let ((window (change-review-ui--window)))
             (if window (max 6 (- (window-body-height window) 4)) 20))))))

(defun change-review-ui-current-size ()
  "Return what a thread is drawn to here, as (WIDTH . MAX-LINES).
A view that follows its window compares it with the size it drew at."
  (cons (change-review-ui-current-width) (change-review-ui-current-max-lines)))

(defun change-review-ui--cut-point (line width)
  "Return where to cut LINE, longer than WIDTH columns, to fit WIDTH.
At the last space the first WIDTH columns hold, or inside a word when
there is none; the character at the cut is a space or the next one."
  (let ((i 0) (w 0) (length (length line)))
    (while (and (< i length) (<= (+ w (char-width (aref line i))) width))
      (cl-incf w (char-width (aref line i)))
      (cl-incf i))
    (cond ((and (< i length) (eq (aref line i) ?\s)) i)
          ((let ((space (cl-position ?\s line :end i :from-end t)))
             (and space (> space 0) space)))
          (t (max i 1)))))

(defun change-review-ui--wrap-offsets (line width)
  "Return LINE cut into pieces of WIDTH columns at most, at spaces if it can.
Each piece comes with where it starts in LINE, as (PIECE . INDEX): what
the cut leaves out, the spaces it was at, is in none.  A line that fits,
and the empty one, is a piece of its own."
  (if (<= (string-width line) width)
      (list (cons line 0))
    (let ((pieces nil) (base 0))
      (while (> (string-width line) width)
        (let* ((cut (change-review-ui--cut-point line width))
               (rest (substring line cut))
               (next (string-trim-left rest)))
          (push (cons (string-trim-right (substring line 0 cut)) base) pieces)
          (setq base (+ base cut (- (length rest) (length next)))
                line next)))
      (push (cons line base) pieces)
      (nreverse pieces))))

(defun change-review-ui--wrap (line width)
  "Return LINE cut into pieces of WIDTH columns at most, at spaces if it can.
A line that fits, and the empty one, is a piece of its own."
  (mapcar #'car (change-review-ui--wrap-offsets line width)))

;;;; Authors

(defun change-review-ui--author-face (author)
  "Return the face of AUTHOR's name, by the kind of author."
  (pcase (and author (change-review-author-kind author))
    ('user 'change-review-ui-user-face)
    ('agent 'change-review-ui-agent-face)
    (_ 'change-review-ui-other-face)))

(defun change-review-ui--you-p (set author)
  "Return non-nil when AUTHOR is the user of SET."
  (and author (eq (change-review-author-kind author) 'user)
       (change-review-own-author-p set author)))

(defun change-review-ui--author-string (set author)
  "Return AUTHOR's name for a header: the name, then what kind they are.
\"(you)\" for the user of SET, \"(agent)\" for an agent."
  (concat (propertize (change-review-author-label author)
                      'face (change-review-ui--author-face author))
          (cond ((change-review-ui--you-p set author)
                 (propertize " (you)" 'face 'change-review-ui-meta-face))
                ((eq (and author (change-review-author-kind author)) 'agent)
                 (propertize " (agent)" 'face 'change-review-ui-meta-face))
                (t ""))))

;;;; Buttons

(defun change-review-ui--link (label help function face)
  "Return LABEL in FACE as a button that calls FUNCTION, with HELP as its tooltip."
  (propertize (buttonize label (lambda (_) (funcall function)) nil help)
              'face face
              'mouse-face 'highlight))

(defun change-review-ui--button (label help function)
  "Return LABEL as a button that calls FUNCTION, with HELP as its tooltip."
  (change-review-ui--link label help function 'change-review-ui-button-face))

;;;; Fitting a line to its width

(defun change-review-ui--opt (options key default)
  "Return the value of KEY in the plist OPTIONS, DEFAULT when it has none."
  (if (plist-member options key) (plist-get options key) default))

(defun change-review-ui--fit (width build steps &optional keep)
  "Return the first line BUILD draws that is at most WIDTH columns wide.
BUILD is called with a plist of options, nil at first; each of STEPS, a
plist of one option, is added to it in turn, the newest winning, while the
line is too wide.  So the steps say what to give up, the first the least
missed.  A line that is wider still when they are all taken is cut,
unless KEEP is non-nil: the caller sees that it did not fit."
  (let* ((options nil)
         (line (funcall build options)))
    (while (and (> (string-width line) width) steps)
      (setq options (append (pop steps) options)
            line (funcall build options)))
    (if (and (not keep) (> (string-width line) width))
        (truncate-string-to-width line (max 1 width) nil nil "…")
      line)))

(defun change-review-ui--edit-button (set comment)
  "Return the [Edit] button of COMMENT of SET, a draft.
It edits that draft, whichever view it is drawn in and whatever point is
on: the one way to name a draft among several under one line, where
point cannot be on it.  It finds the comment by its id when pressed, so
a set that was read again since the view was drawn does no harm."
  (let ((id (change-review-comment-id comment)))
    (change-review-ui--button
     "[Edit]" "Edit this draft"
     (lambda ()
       (if-let* ((found (change-review-find-comment set id)))
           (change-review-ui-edit-comment set (car found) (cdr found))
         (user-error "That draft is gone"))))))

(defun change-review-ui--delete-button (set thread comment)
  "Return the [Delete] button of COMMENT of THREAD in SET, a draft.
As [Edit] does it names the draft, by its id, whatever point is on, and
finds it again when pressed.  The question it asks says what goes: the
draft, or, for the draft that starts a thread with more comments in it,
all of the thread (`change-review-ui-delete-comment')."
  (let ((id (change-review-comment-id comment)))
    (change-review-ui--button
     "[Delete]"
     (if (change-review-ui--starts-thread-p thread comment)
         "Delete this draft and the drafts after it: it starts the thread, which goes with it"
       "Delete this draft")
     (lambda ()
       (if-let* ((found (change-review-find-comment set id)))
           (change-review-ui-delete-comment set (car found) (cdr found))
         (user-error "That draft is gone"))))))

(defun change-review-ui--delete-thread-button (set thread)
  "Return the [Delete thread] button of THREAD of SET, a thread of drafts.
It finds the thread by its id when pressed, as [Edit] does a comment."
  (let ((id (change-review-thread-id thread)))
    (change-review-ui--button
     "[Delete thread]"
     "Delete this thread: nothing in it was sent, so it goes with its drafts"
     (lambda ()
       (if-let* ((found (change-review-find-thread set id)))
           (change-review-ui-delete-thread set found)
         (user-error "That thread is gone"))))))

(defun change-review-ui--starts-thread-p (thread comment)
  "Return non-nil when COMMENT is the root of THREAD and the thread has more."
  (and (eq comment (change-review-thread-root thread))
       (cdr (change-review-thread-comments thread))
       t))

;;;; Placement

(cl-defgeneric change-review-placement (set thread &optional version)
  "Return where THREAD of SET is in VERSION, by default the newest, or nil.
A plist (:side :line :was :status): :line is the line of VERSION the
thread is about now (nil when the line is gone), :was the line it was
made on, and :status is `same', `moved', `changed' (the line was
edited), `gone' or `unknown', as `change-review-diff-relocate' gives it.
The method for a plain `change-review-set' relocates the thread's
location in the diff of VERSION; a kind of set that can read the files
themselves answers better.  Nil for a thread with no line.")

(cl-defmethod change-review-placement ((set change-review-set) thread &optional version)
  (let* ((location (change-review-thread-location thread))
         (version (or (change-review-find-version set version) (change-review-latest-version set)))
         (path (and location (change-review-location-file location)))
         (revision (change-review-thread-revision thread)))
    (when (and location path version (change-review-location-line location))
      (let ((file (cl-find-if (lambda (f) (or (equal (change-review-file-path f) path)
                                              (equal (change-review-file-old-path f) path)))
                              (change-review-version-files version))))
        (cond
         ;; Made against this very version: it is where it was made.
         ((and revision (equal revision (change-review-version-id version)))
          (list :side (change-review-location-side location)
                :line (change-review-location-line location)
                :was (change-review-location-line location) :status 'same))
         (file (change-review-diff-relocate location file))
         (t (list :side (change-review-location-side location) :line nil
                  :was (change-review-location-line location) :status 'gone)))))))

(defun change-review-ui--where-text (location placement)
  "Return where a thread with LOCATION is, for a list: \"line 44 (was 42)\".
PLACEMENT says where the thread is now.  A thread on a file as a whole
is \"the file\", one on the change \"the change\"."
  (cond ((null location) "the change")
        ((null (change-review-location-line location)) "the file")
        (t (let ((was (change-review-location-line location))
                 (line (plist-get placement :line)))
             (pcase (plist-get placement :status)
               ('moved (format "line %d (was %d)" line was))
               ('changed (if line (format "line %d (changed since)" line)
                           (format "line %d (changed since)" was)))
               ('gone (format "line %d (gone)" was))
               (_ (format "line %d" (or line was))))))))

(defun change-review-ui--placement-note (placement &optional was)
  "Return what PLACEMENT, a thread's place now, says beyond the line, or nil.
WAS is the line a comment was made on, when that is not the line the
thread started on, which PLACEMENT remembers."
  (when placement
    (let ((line (plist-get placement :line)) (was (or was (plist-get placement :was))))
      (pcase (plist-get placement :status)
        ('moved (format "now line %s (was %s)" line was))
        ('changed (if line (format "line %s changed since" line) "its line changed since"))
        ('gone "its line is gone")))))

;;;; The text of a comment

(cl-defgeneric change-review-ui-body-lines (set comment width)
  "Return the text of COMMENT of SET as the lines to draw, WIDTH columns at most.
A list of strings, which the drawing of a thread puts one by one under
the comment's header, after its bar.  WIDTH is what the bar leaves.  A
line may end in a newline of its own, whose face then reaches the edge
of the window if it says so, a code block's background say; a line
that does not gets the one the drawing ends it with.  The lines keep
their text properties, faces and the like.

The method for a plain `change-review-set' draws the text as its author
typed it: its lines, wrapped at spaces to WIDTH.  A kind of set whose
comments are written in a markup draws them as that does, and wraps
what it draws itself.")

(cl-defmethod change-review-ui-body-lines ((_set change-review-set) comment width)
  (cl-loop for text in (split-string (change-review-comment-body comment) "\n")
           ;; A line that starts with ">" quotes: every piece it wraps to has the face.
           append (mapcar (lambda (piece)
                            (if (string-prefix-p ">" text)
                                (propertize piece 'face 'change-review-ui-quote-face)
                              piece))
                          (change-review-ui--wrap text width))))

(cl-defgeneric change-review-ui-body-summary (set comment)
  "Return the text of COMMENT of SET as one line, a string without newline.
It names a thread in a list, or one drawn collapsed, by the first
words of its first comment: the drawing cuts the line to the room it
has, and draws what has no face of its own in the face of the words
around it.

The method for a plain `change-review-set' joins the lines of the text
with spaces.")

(cl-defmethod change-review-ui-body-summary ((_set change-review-set) comment)
  (change-review-ui--summary (change-review-comment-body comment)))

(defun change-review-ui--preview (set comment room)
  "Return the first words of COMMENT of SET, quoted, in ROOM columns at most.
The quotes, and the words with no face of their own, are in
`change-review-ui-meta-face'; a face the words have, bold say, stays
and adds to it."
  (let ((meta 'change-review-ui-meta-face)
        (words (copy-sequence
                (truncate-string-to-width (change-review-ui-body-summary set comment)
                                          room nil nil "…"))))
    (add-face-text-property 0 (length words) meta t words)
    (concat (propertize "“" 'face meta) words (propertize "”" 'face meta))))

;;;; Origin

;; Where a comment was made is not where its thread is now.  The code a
;; comment is about is changed by the answer to it, so the lines the
;; reader sees under a comment have to be those of the revision the
;; comment was written against: its diff, as it was.  A comment made on
;; a line keeps the diff around the line (the excerpt of its location);
;; a reply has no location of its own, and its thread's is of the
;; revision the thread started on, not of the reply's.

(defun change-review-ui--location-in-version (set thread location version)
  "Return LOCATION of THREAD in SET as VERSION's diff has it, or nil.
The thread is placed in VERSION (`change-review-placement') and the
location made again at that place, with the lines of VERSION's diff
around it.  Nil when VERSION has no files, or none that LOCATION names,
or no line of the thread."
  (let* ((path (change-review-location-file location))
         (file (and path (cl-find-if (lambda (f) (or (equal (change-review-file-path f) path)
                                                     (equal (change-review-file-old-path f) path)))
                                     (change-review-version-files version))))
         (placement (and file (change-review-placement set thread version))))
    (when (and placement (plist-get placement :line))
      (change-review-diff-location file (or (plist-get placement :side)
                                            (change-review-location-side location))
                                   (plist-get placement :line)))))

(defun change-review-ui--stale-origin (set thread comment location)
  "Return the origin of COMMENT of THREAD in SET when only LOCATION is known.
LOCATION was made on another revision than COMMENT: when it holds an
excerpt, a note says whose lines they are."
  (let ((basis (let ((root (change-review-thread-root thread)))
                 (and root (change-review-comment-revision root)))))
    (list :location location
          :note (and (change-review-location-excerpt location) basis
                     (not (eq comment (change-review-thread-root thread)))
                     (format "the lines are those of %s, where the thread started"
                             (change-review-revision-name set basis))))))

(cl-defgeneric change-review-origin (set thread comment)
  "Return where COMMENT of THREAD in SET was made, as it was made.
A plist (:location LOCATION :note NOTE).  LOCATION is a
`change-review-location' with the line and the excerpt of the revision
COMMENT was written against -- not the newest version's, which the
answer to the comment may have changed, nor its thread's when the
thread started on another revision -- or nil for a comment on the
change as a whole.  NOTE, a string or nil, says what is not as it
should be: the lines are being read, or cannot be.

The method for a plain `change-review-set' keeps what the comment has:
its own location, its thread's when made on the same revision; for a
comment on another revision it places the thread in the diff of the
version it was written against, when the set holds that version's
files, and else says whose lines it shows.  A kind of set that reads
its files from somewhere else answers better.")

(cl-defmethod change-review-origin ((set change-review-set) thread comment)
  (pcase-let ((`(,location . ,exact) (change-review-kept-location thread comment)))
    (cond
     ((or (null location) exact) (list :location location))
     ((let* ((revision (change-review-comment-revision comment))
             (version (and revision (change-review-find-version set revision)))
             (found (and version (change-review-ui--location-in-version set thread location version))))
        (and found (list :location found))))
     (t (change-review-ui--stale-origin set thread comment location)))))

;;;; Long threads and long comments

;; A thread with many comments, or a comment with many lines, is hard to
;; read in the room a view has, and in a window of Ediff it takes the
;; room of the code.  So a thread keeps its first comment and the last
;; few and folds away the ones between, and a long comment is cut after a
;; number of lines.  Both are one line with a button that shows the rest,
;; and what was shown stays so, for the set, like the fold of a thread
;; (`change-review-ui-set-fold').  The two functions below are the whole
;; of the counting, for the chat's threads as for these views: they know
;; nothing of what is drawn.

(defconst change-review-ui--min-folded 2
  "The fewest comments a line \"N earlier replies\" stands for.
One comment would be as long as its line.")

(defconst change-review-ui--min-cut 2
  "The fewest lines of a comment a line \"N more lines\" stands for.
One line left out would be no shorter than the line that says so.")

(defun change-review-ui-folded-replies (count &optional tail keep)
  "Return the comments a thread of COUNT comments folds away, as (FROM . TO).
The comments are counted from 0, the range is FROM up to, not with, TO:
the first comment stays, then come the folded ones, then the last TAIL
\(by default `change-review-ui-tail-replies', and at least 1).  KEEP is a
list of indexes that stay in sight whatever, a draft's say: the range
ends before the first of them, so does not take any comment after it.
Nil when fewer than `change-review-ui--min-folded' comments would be
folded, or TAIL is nil."
  (let ((tail (if tail (max 1 tail) (and change-review-ui-tail-replies
                                         (max 1 change-review-ui-tail-replies)))))
    (when (and tail (> count 1))
      (let ((to (apply #'min (- count tail) (or (cl-remove-if (lambda (i) (< i 1)) keep) (list count)))))
        (when (>= (- to 1) change-review-ui--min-folded)
          (cons 1 to))))))

(defun change-review-ui-cut-lines (lines &optional limit)
  "Return the first LIMIT of LINES and how many are left out, as (SHOWN . HIDDEN).
LIMIT is by default `change-review-ui-max-comment-lines'.  Nothing is left
out of a list that is not `change-review-ui--min-cut' lines longer than
LIMIT, or when LIMIT is nil; blank lines at the end of what is shown do
not count as shown, so that it does not end on a gap."
  (let ((limit (if limit (max 1 limit)
                 (and change-review-ui-max-comment-lines (max 1 change-review-ui-max-comment-lines)))))
    (if (or (null limit) (< (- (length lines) limit) change-review-ui--min-cut))
        (cons lines 0)
      (let ((shown (seq-take lines limit)))
        (while (and (cdr shown) (string-blank-p (car (last shown))))
          (setq shown (butlast shown)))
        (cons shown (- (length lines) (length shown)))))))

(defvar change-review-ui--earlier (make-hash-table :test 'eq :weakness 'key)
  "Change set -> a table of the ids of the threads whose earlier replies show.")

(defvar change-review-ui--shown (make-hash-table :test 'eq :weakness 'key)
  "Change set -> a table of the ids of the comments drawn in full though long.")

(defun change-review-ui--flag (table set id)
  "Return whether ID is flagged in the table of SET in TABLE, a hash table."
  (let ((ids (gethash set table)))
    (and ids (gethash id ids))))

(defun change-review-ui--set-flag (table set id on)
  "Flag ID in the table of SET in TABLE if ON, else clear it."
  (let ((ids (or (gethash set table)
                 (puthash set (make-hash-table :test 'equal) table))))
    (if on (puthash id t ids) (remhash id ids))))

(defun change-review-ui-earlier-shown-p (set thread)
  "Return non-nil when THREAD of SET draws the comments it would fold away."
  (change-review-ui--flag change-review-ui--earlier set (change-review-thread-id thread)))

(defun change-review-ui-show-earlier (set thread &optional show)
  "Draw the earlier replies of THREAD of SET; with SHOW nil, fold them away again.
The views of SET are drawn again."
  (change-review-ui--set-flag change-review-ui--earlier set (change-review-thread-id thread) show)
  (change-review-ui-refresh set))

(defun change-review-ui-comment-shown-p (set comment)
  "Return non-nil when COMMENT of SET is drawn in full though it is long."
  (change-review-ui--flag change-review-ui--shown set (change-review-comment-id comment)))

(defun change-review-ui-show-comment (set comment &optional show)
  "Draw all of COMMENT of SET, or cut it again if SHOW is nil.
The views of SET are drawn again."
  (change-review-ui--set-flag change-review-ui--shown set (change-review-comment-id comment) show)
  (change-review-ui-refresh set))

(defun change-review-ui--opened-p (set thread)
  "Return non-nil when the user asked THREAD of SET for more than it draws first.
Its earlier replies are shown, or a comment of it is drawn in full."
  (or (change-review-ui-earlier-shown-p set thread)
      (cl-some (lambda (comment) (change-review-ui-comment-shown-p set comment))
               (change-review-thread-comments thread))))

(defun change-review-ui--folded-range (thread details)
  "Return the range of comments THREAD folds away, or nil.
As `change-review-ui-folded-replies' says; the comments that stay in
sight are the drafts and those DETAILS, a list of ids or t, shows."
  (let ((comments (change-review-thread-comments thread)))
    (change-review-ui-folded-replies
     (length comments) nil
     (cl-loop for comment in comments for i from 0
              when (or (change-review-comment-draft-p comment)
                       (eq details t)
                       (member (change-review-comment-id comment) details))
              collect i))))

;;;; Drawing a thread

(defun change-review-ui--status-text (set thread &optional brief)
  "Return the status of THREAD in SET for its header: open, or closed and by whom.
BRIEF says less of a closed thread, for a header short of room: `short'
gives how long ago it was closed for the date, and says who closed it
only when it was not the user; `who' leaves out when; `bare' says
closed and no more."
  (if (change-review-thread-open-p thread)
      (propertize "open" 'face 'change-review-ui-open-face)
    (let* ((entry (car (last (cl-remove-if-not (lambda (e) (eq (plist-get e :status) 'closed))
                                               (change-review-thread-history thread)))))
           (closer (and entry (plist-get entry :author)))
           (you (and closer (change-review-ui--you-p set closer)))
           (by (and closer (or (null brief) (and (memq brief '(short who)) (not you))) closer))
           (time (and entry (memq brief '(nil short)) (plist-get entry :time)))
           (who (and by (concat " by " (change-review-author-label by) (if you " (you)" ""))))
           (since (and time (if (and brief change-review-ui-relative-times)
                                (change-review-ui-ago time)
                              (change-review-ui--time time)))))
      (apply #'propertize
             (concat "closed" who
                     (and (stringp since) (not (string-empty-p since))
                          (concat (if who ", " " ") since)))
             'face 'change-review-ui-closed-face
             (and time (list 'help-echo (change-review-ui--time time)))))))

(defun change-review-ui--review-text (set thread)
  "Return what THREAD of SET says of the user's review of its close, or nil.
Only a thread closed by someone else says anything: `to review' while
the user has not looked at it, `reviewed' once they did."
  (when-let* ((entry (change-review-thread-closing thread))
              (author (plist-get entry :author))
              ((not (change-review-own-author-p set author))))
    (if-let* ((time (plist-get entry :reviewed)))
        (propertize "reviewed" 'face 'change-review-ui-meta-face
                    'help-echo (format "You reviewed this close, %s; m makes it wait for you again"
                                       (change-review-ui--time time)))
      (propertize "to review" 'face 'change-review-ui-review-face
                  'help-echo "Closed by someone else, and you have not reviewed it: m marks it reviewed"))))

(defun change-review-ui-thread-short-id (set thread)
  "Return the id of THREAD as short as it can be and still be its own in SET."
  (let* ((id (change-review-thread-id thread))
         (others (delq thread (copy-sequence (change-review-set-threads set)))))
    (cl-loop for n from (min 6 (length id)) to (length id)
             for prefix = (substring id 0 n)
             unless (cl-some (lambda (o) (string-prefix-p prefix (change-review-thread-id o))) others)
             return prefix
             finally return id)))

(defconst change-review-ui--comment-header-steps
  '((:time ago) (:revision nil) (:links short) (:time none) (:marks nil) (:links none)
    (:answer nil))
  "What the header of a comment gives up, the first the least missed.
Each step is added to the options `change-review-ui--comment-header'
draws with, while the line is wider than the room it has: the date goes
for how long ago, then the revision, the words of the links, the time,
the \"(you)\" and \"(agent)\", the links, and last the comment it answers,
which a draft's buttons would otherwise be cut for.")

(defun change-review-ui--comment-header (set thread comment prefix bar details options)
  "Return the first line of COMMENT of THREAD in SET, without its newline.
PREFIX and BAR start it; DETAILS non-nil says where the comment was made
is shown.  OPTIONS are those of `change-review-ui--comment-header-steps':
`:time' is `full', `ago' or `none', `:revision', `:marks' and `:answer'
are nil to leave out the revision, the marks of who wrote it and the
comment it answers, `:links' is `full', `short' or `none'."
  (let* ((position (change-review-comment-position thread comment))
         (total (cdr position))
         (author (change-review-comment-author comment))
         (digits (length (number-to-string total)))
         (index (propertize (format (format "%%%dd/%%d" digits) (car position) total)
                            'face 'change-review-ui-position-face))
         (parent (change-review-comment-parent thread comment))
         (parent-position (and parent (change-review-comment-position thread parent)))
         (previous (and (> (car position) 1)
                        (nth (- (car position) 2) (change-review-thread-comments thread))))
         (answer (and parent (not (eq parent previous))
                      (change-review-ui--opt options :answer t)
                      (propertize (format "↳ re %d/%d" (car parent-position) total)
                                  'face 'change-review-ui-meta-face)))
         (revision (and (change-review-ui--opt options :revision t)
                        (change-review-comment-revision comment)))
         (agent (eq (and author (change-review-author-kind author)) 'agent))
         (time (change-review-comment-time comment))
         (time-mode (change-review-ui--opt options :time 'full))
         (links-mode (change-review-ui--opt options :links 'full))
         (full-time (and (numberp time) (change-review-ui--time time)))
         (header
          (mapconcat
           #'identity
           (delq nil
                 (list (concat index "  "
                               (if (change-review-ui--opt options :marks t)
                                   (change-review-ui--author-string set author)
                                 (propertize (change-review-author-label author)
                                             'face (change-review-ui--author-face author))))
                       (and full-time (not (eq time-mode 'none))
                            (if (and (eq time-mode 'ago) change-review-ui-relative-times)
                                (propertize (change-review-ui-ago time)
                                            'face 'change-review-ui-meta-face
                                            'help-echo full-time)
                              (propertize full-time 'face 'change-review-ui-meta-face)))
                       (and revision
                            (propertize (change-review-revision-name set revision)
                                        'face 'change-review-ui-meta-face
                                        'help-echo (format "Written against revision %s" revision)))
                       (and (change-review-comment-draft-p comment)
                            (propertize "draft" 'face 'change-review-ui-draft-face
                                        'help-echo "Not sent yet"))
                       (and (change-review-comment-edited comment)
                            (propertize "edited" 'face 'change-review-ui-meta-face))
                       answer))
           (propertize " · " 'face 'change-review-ui-meta-face)))
         (short (eq links-mode 'short))
         (links (concat
                 ;; A draft is the one comment that can be changed or taken
                 ;; back; its buttons are kept when the other links are given up.
                 (if (change-review-comment-draft-p comment)
                     (concat "  " (change-review-ui--edit-button set comment)
                             " " (change-review-ui--delete-button set thread comment))
                   "")
                 (if (eq links-mode 'none)
                    ""
                  (concat
                   (if (and agent (or (change-review-author-session author)
                                      (change-review-author-tool-call author)))
                       (concat "  " (change-review-ui--button
                                     (if short "↗" "↗ conversation")
                                     "Show the point of the conversation this comment came from"
                                     (lambda () (change-review-follow-author set author))))
                     "")
                   "  " (change-review-ui--button
                         (concat (if details "▾" "▸") (if short "" " where"))
                         "Show where this comment was made"
                         (lambda () (change-review-ui-toggle-details comment))))))))
    (propertize (concat prefix bar " " header links) 'change-review-comment-start t)))

(defun change-review-ui--cut-row (set comment body-prefix cut hidden)
  "Return the line that stands for the HIDDEN lines COMMENT of SET is cut by.
BODY-PREFIX starts it.  CUT is `cut' for a comment drawn cut short: the
line says how many more there are, and its [Show more] draws all of the
comment; `shown' for one drawn in full though it is long: the line is
its [Show less], which cuts it again.  The line carries
`change-review-cut', for the drawing to tell that something was left out."
  (let ((meta 'change-review-ui-meta-face))
    (propertize
     (concat body-prefix
             (if (eq cut 'cut)
                 (concat (propertize (format "… %d more %s" hidden (if (= hidden 1) "line" "lines"))
                                     'face meta)
                         "  "
                         (change-review-ui--button
                          "[Show more]" (format "Draw the other %d %s of this comment"
                                                hidden (if (= hidden 1) "line" "lines"))
                          (lambda () (change-review-ui-show-comment set comment t))))
               (change-review-ui--button
                "[Show less]" "Cut this comment short again"
                (lambda () (change-review-ui-show-comment set comment nil)))))
     'change-review-cut (eq cut 'cut))))

(defun change-review-ui--comment-lines (set thread comment prefix width details &optional cut limit)
  "Return the lines that draw COMMENT of THREAD in SET, a string each.
PREFIX starts every line, WIDTH is the width to wrap the text to and the
header to fit, and DETAILS non-nil adds where the comment was made.  Each
line ends in a newline, which carries the comment's properties as the
line does.  The lines that hold the comment's text, from after their bar
to their newline, also say where that is in it: their `change-review-body'
is the index in the comment's text of the first character they draw,
which is how a selection of the drawing is read back as the text it is of
\(`change-review-ui--offset-at').  A line that cannot be placed in the
text (a markup changed it) has none.

CUT says what to do with a text longer than LIMIT, by default
`change-review-ui-max-comment-lines' (`change-review-ui-cut-lines'): nil
draws all of it, `cut' draws the first lines and a line with a button
that draws the rest, `shown' draws all of it and ends with a button that
cuts it again (`change-review-ui--cut-row')."
  (let* ((position (change-review-comment-position thread comment))
         (author (change-review-comment-author comment))
         (bar (propertize "┃" 'face (change-review-ui--author-face author)))
         (digits (length (number-to-string (cdr position))))
         (header (change-review-ui--fit
                  width
                  (lambda (options)
                    (change-review-ui--comment-header set thread comment prefix bar details options))
                  change-review-ui--comment-header-steps))
         (body-prefix (concat prefix bar (make-string (+ digits 3 2) ?\s)))
         (lines (list header))
         (start 0)
         (pieces (change-review-ui-body-lines
                  set comment (max 20 (- width (string-width body-prefix)))))
         (split (and cut (change-review-ui-cut-lines pieces limit)))
         (hidden (if split (cdr split) 0)))
    (dolist (piece (if (and (eq cut 'cut) split) (car split) pieces))
      ;; A line of the text is (STRING . WHERE IT STARTS IN THE TEXT), when
      ;; the drawing can say: the markup a set draws the text with may
      ;; change what it reads, so a line that is not found in the text,
      ;; from where the one before ended, has no place in it.
      (let* ((body (change-review-comment-body comment))
             (plain (string-trim-right (substring-no-properties piece)))
             (at (if (string-empty-p (string-trim plain))
                     ;; A blank line starts after the newline that ends the one before.
                     (if (and (= start 0) (null (cdr lines)))
                         (and (or (string-empty-p body) (eq (aref body 0) ?\n)) 0)
                       (when-let* ((newline (string-search "\n" body start)))
                         (1+ newline)))
                   (when-let* ((found (string-search (string-trim-left plain) body start)))
                     (- found (- (length plain) (length (string-trim-left plain))))))))
        (when at
          (setq at (max at 0)
                start (+ at (length plain))))
        (push (if at (cons (concat body-prefix piece) at) (concat body-prefix piece)) lines)))
    (when (> hidden 0)
      (push (change-review-ui--cut-row set comment body-prefix cut hidden) lines))
    (when details
      (dolist (line (change-review-ui-origin-lines set thread comment))
        ;; A line of the diff is a way to its source all along the line.
        (push (concat (if-let* ((source (get-text-property 0 'change-review-source line)))
                          (propertize body-prefix 'change-review-source source
                                      'keymap change-review-ui--source-map)
                        body-prefix)
                      line)
              lines)))
    (mapcar (lambda (line)
              ;; A line of the text may end in a newline of its own.
              (let* ((text (if (consp line) (car line) line))
                     (string (propertize (if (string-suffix-p "\n" text) text (concat text "\n"))
                                         'change-review-comment (change-review-comment-id comment))))
                (when (consp line)
                  (put-text-property (length body-prefix) (length string)
                                     'change-review-body (cdr line) string))
                string))
            (nreverse lines))))

(defconst change-review-ui--header-steps
  '((:delete nil) (:status short) (:note nil) (:status who) (:status bare) (:count nil) (:buttons nil))
  "What the header of a thread gives up, the first the least missed.
Each step is added to the options `change-review-ui--thread-header' draws
with, while the line is wider than the room it has: the button that
deletes a thread of drafts goes first (each of its drafts has the button
that deletes it); when a closed thread was closed gives the date for how
long ago, the place the thread moved to goes, then when it was closed,
then who closed it, the count of comments and last the buttons.")

(defconst change-review-ui--collapsed-header-steps
  '((:delete nil) (:status short) (:buttons nil) (:note nil) (:count nil) (:status who) (:status bare))
  "What the header of a thread drawn as one line gives up.
As `change-review-ui--header-steps', but the buttons go as soon as the
status is short, and the count of comments before when it was closed: the
words of the thread are worth more there.")

(defconst change-review-ui--quote-room 30
  "How many columns a thread drawn as one line wants for its first words.")

(defconst change-review-ui--collapsed-width 100
  "The widest a thread drawn as one line is, in a window that has more room.
It is a summary to run an eye down, not to read across a whole screen.")

(defun change-review-ui--fold-gutter (prefix marker)
  "Return PREFIX with MARKER, a string one column wide, in its last two columns.
A space follows it, so the line goes on where it did without the marker.
PREFIX is spaces; one that is shorter than two columns is followed by
the marker and the space."
  (if (string-suffix-p "  " prefix)
      (concat (substring prefix 0 -2) marker " ")
    (concat prefix marker " ")))

(defun change-review-ui--fold-marker (set thread fold)
  "Return the triangle that folds THREAD of SET, drawn with FOLD, a button."
  (let ((collapsed (eq fold 'collapsed)))
    (change-review-ui--link
     (if collapsed "▸" "▾")
     (if collapsed "Show the conversation of this thread (TAB)" "Fold this thread to one line (TAB)")
     (lambda () (change-review-ui-set-fold set thread (if collapsed 'expanded 'collapsed)))
     'change-review-ui-fold-face)))

(defun change-review-ui--build-thread-header (set thread view placement prefix fold options)
  "Return the first line of THREAD in SET, drawn for VIEW, after PREFIX.
VIEW is `threads' or `diff'; PLACEMENT says where the thread is now.
FOLD, non-nil when the thread can be folded, puts the triangle that does
it where the last two columns of PREFIX are.  OPTIONS are those of
`change-review-ui--header-steps': `:status' is nil for all of it, `short',
`who' or `bare'; `:note', `:count', `:delete' and `:buttons' are nil to
leave out where the thread is, how many comments it has, the button
that deletes a thread of drafts and the buttons."
  (let* ((open (change-review-thread-open-p thread))
         (location (change-review-thread-location thread))
         (placed (change-review-ui--opt options :note t))
         (where (and placed (not (eq view 'diff)) (change-review-ui--where-text location placement)))
         (note (and placed (eq view 'diff) (change-review-ui--placement-note placement)))
         (count (length (change-review-thread-comments thread)))
         (parts (delq nil
                      (list (propertize (change-review-ui-thread-short-id set thread)
                                        'face 'change-review-ui-meta-face
                                        'help-echo (format "Thread %s" (change-review-thread-id thread)))
                            where
                            (and note (propertize note 'face 'change-review-ui-meta-face))
                            (and (change-review-ui--opt options :count t)
                                 (format "%d %s" count (if (= count 1) "comment" "comments")))
                            (change-review-ui--status-text set thread (plist-get options :status))
                            (change-review-ui--review-text set thread))))
         (buttons (and (change-review-ui--opt options :buttons t)
                       (concat
                        (change-review-ui--button "[Reply]" "Reply to this thread"
                                                  (lambda () (change-review-ui-reply-to-thread set thread)))
                        " "
                        (change-review-ui--button (if open "[Close]" "[Reopen]")
                                                  (if open "Close this thread: it is done"
                                                    "Open this thread again")
                                                  (lambda () (change-review-ui-toggle-thread set thread)))
                        (if (change-review-thread-unreviewed-p set thread)
                            (concat " " (change-review-ui--button
                                         "[Mark reviewed]"
                                         "You looked at how this thread was closed: it no longer waits for you"
                                         (lambda () (change-review-ui-mark-thread-reviewed set thread))))
                          "")
                        (if (eq view 'diff)
                            ""
                          (concat " " (change-review-ui--button
                                       "[Diff]" "Show this thread in the diff view"
                                       (lambda () (change-review-visit set thread)))))
                        ;; A thread of drafts is the author's alone: it can be taken back.
                        (if (and (change-review-ui--opt options :delete t)
                                 (change-review-thread-draft-p thread))
                            (concat " " (change-review-ui--delete-thread-button set thread))
                          "")))))
    (propertize (concat (if fold
                            (change-review-ui--fold-gutter prefix (change-review-ui--fold-marker set thread fold))
                          prefix)
                        (propertize (if open "●" "✓")
                                    'face (if open 'change-review-ui-open-face
                                            'change-review-ui-closed-face))
                        " " (mapconcat #'identity parts
                                       (propertize " · " 'face 'change-review-ui-meta-face))
                        (if buttons (concat "   " buttons) ""))
                'change-review-thread-start t
                ;; A long header wraps under its mark, not at the margin.
                'wrap-prefix (concat prefix "  "))))

(defun change-review-ui--thread-header (set thread view placement prefix width &optional fold keep)
  "Return the first line of THREAD in SET, drawn for VIEW, after PREFIX.
It is at most WIDTH columns wide: when it would not be, it says less
\(`change-review-ui--header-steps').  VIEW is `threads' or `diff';
PLACEMENT says where the thread is now.  FOLD is how the thread is
folded when it can be folded (`change-review-ui-thread-fold'), nil when
not.  With KEEP a line that does not fit when it says the least is
returned as it is, not cut."
  (change-review-ui--fit
   width
   (lambda (options)
     (change-review-ui--build-thread-header set thread view placement prefix fold options))
   (if (eq fold 'collapsed) change-review-ui--collapsed-header-steps change-review-ui--header-steps)
   keep))

(defun change-review-ui--summary (body)
  "Return the words of BODY, a comment's text, that stand for it in one line.
Its lines that are not a quote (`> ', as a reply to patches quotes) joined
by spaces; a text that is all quote, all of it.  A comment imported from
a reply to patches opens with what it answers, which says less of it than
the answer does."
  (let* ((lines (split-string body "\n" t "[ \t]+"))
         (own (cl-remove-if (lambda (line) (string-match-p "\\`>+\\(?:[ \t]\\|\\'\\)" line)) lines)))
    (string-join (or own lines) " ")))

(defun change-review-ui--collapsed-line (set thread view placement indent width fold)
  "Return THREAD of SET as one line: the header, then the first words of its root.
The line is at most WIDTH columns wide, and no wider than
`change-review-ui--collapsed-width'.  The header gives up what it can
\(`change-review-ui--collapsed-header-steps') to leave the words
`change-review-ui--quote-room' columns, or what they need if that is
less; when it has given up all it can, the words are the room that is
left.  FOLD, INDENT, VIEW and PLACEMENT are those of
`change-review-ui-thread-string'; the words are a button that opens the
thread when the thread can be folded."
  (let* ((width (min width change-review-ui--collapsed-width))
         (rich (change-review-ui-body-summary set (change-review-thread-root thread)))
         (text (substring-no-properties rich))
         (wanted (min (+ 2 (string-width text)) change-review-ui--quote-room))
         (header (change-review-ui--thread-header set thread view placement indent
                                                  (- width 2 wanted) fold t))
         (room (- width (string-width header) 2 2))
         (words (and (>= room 3) (truncate-string-to-width text room nil nil "…"))))
    (concat (if (> (string-width header) (- width 2 3))
                ;; Not even the least of a header leaves room for words.
                (truncate-string-to-width header width nil nil "…")
              header)
            (if words
                (concat "  "
                        (if fold
                            (change-review-ui--link
                             (concat "“" words "”")
                             "Show the conversation of this thread (TAB)"
                             (lambda () (change-review-ui-set-fold set thread 'expanded))
                             'change-review-ui-meta-face)
                          ;; The faces the set gave the words stay, over the meta face.
                          (let ((shown (copy-sequence (truncate-string-to-width rich room nil nil "…")))
                                (meta 'change-review-ui-meta-face))
                            (add-face-text-property 0 (length shown) meta t shown)
                            (concat (propertize "“" 'face meta) shown (propertize "”" 'face meta)))))
              "")
            "\n")))

(defun change-review-ui--more-row (set thread indent count)
  "Return the line that says COUNT more lines of THREAD of SET are not drawn.
INDENT starts it; its words are a button that draws all of the thread."
  (concat indent (propertize "┃" 'face 'change-review-ui-meta-face) "      "
          (change-review-ui--link
           (format "… %d more %s" count (if (= count 1) "line" "lines"))
           "Show all of this thread (TAB)"
           (lambda () (change-review-ui-set-fold set thread 'full))
           'change-review-ui-fold-face)
          "\n"))

(defun change-review-ui--earlier-row (set thread indent range shown)
  "Return the line that stands for the replies THREAD of SET folds away.
RANGE is the comments, as `change-review-ui-folded-replies' gives it;
INDENT starts the line, which is under the bars of the comments.  SHOWN
says the replies are drawn under it: the line is then the button that
folds them away again, the triangle pointing down.  The line carries
`change-review-cut' when it folds, for the drawing to tell that
something was left out."
  (let* ((comments (change-review-thread-comments thread))
         (count (- (cdr range) (car range)))
         (digits (length (number-to-string (length comments))))
         (label (format "%s %d earlier %s" (if shown "▾" "▸") count (if (= count 1) "reply" "replies"))))
    (propertize
     (concat indent (propertize "┃" 'face 'change-review-ui-meta-face)
             (make-string (+ digits 3 2) ?\s)
             (change-review-ui--link
              label
              (if shown
                  (format "Fold the %d earlier replies away" count)
                (format "Draw the %d replies between 1/%d and %d/%d"
                        count (length comments) (1+ (cdr range)) (length comments)))
              (lambda () (change-review-ui-show-earlier set thread (not shown)))
              'change-review-ui-fold-face)
             "\n")
     'change-review-cut (not shown))))

(defun change-review-ui--comment-rows (set thread indent width details fold &optional limit)
  "Return the lines of the comments of THREAD of SET, drawn, as (LINES . LEFT-OUT).
INDENT, WIDTH and DETAILS are those of `change-review-ui-thread-string'.
A thread with many comments draws the first, a line standing for the
replies it folds away (`change-review-ui-folded-replies'), and the last;
a long comment is cut after LIMIT lines, by default
`change-review-ui-max-comment-lines' (`change-review-ui--comment-lines');
what the user asked to see stays shown (`change-review-ui-show-earlier',
`change-review-ui-show-comment').  FOLD `full' leaves nothing out.
LEFT-OUT is non-nil when something was: comments or lines of one."
  (let* ((full (eq fold 'full))
         (range (and (not full) (change-review-ui--folded-range thread details)))
         (earlier (and range (change-review-ui-earlier-shown-p set thread)))
         (i 0)
         lines)
    (dolist (comment (change-review-thread-comments thread))
      (when (and range (= i (car range)))
        (push (list (change-review-ui--earlier-row set thread indent range earlier)) lines))
      ;; Folded away, a comment has no line of its own.
      (unless (and range (not earlier) (>= i (car range)) (< i (cdr range)))
        (push (change-review-ui--comment-lines
               set thread comment indent width
               (or (eq details t) (member (change-review-comment-id comment) details))
               (cond (full nil)
                     ((change-review-ui-comment-shown-p set comment) 'shown)
                     (t 'cut))
               limit)
              lines))
      (cl-incf i))
    (let ((lines (apply #'append (nreverse lines))))
      (cons lines (and (cl-some (lambda (line) (get-text-property 0 'change-review-cut line)) lines)
                       t)))))

(defconst change-review-ui--min-room 3
  "The fewest lines of a comment a thread short of room still draws.
A comment is cut to fewer than `change-review-ui-max-comment-lines' to
make a thread fit its window, but not to fewer than this.")

(defun change-review-ui--fit-rows (set thread indent width details fold rooms)
  "Return the comments of THREAD of SET, drawn to take ROOMS lines if they can.
As `change-review-ui--comment-rows', which says what they are, but a thread
the window has less room for than the comments take is not cut off at the
line it comes to: the long comments in it are cut shorter, as far as
`change-review-ui--min-room' lines of each, so that the line that shows
the rest of each stays in sight.  ROOMS is the lines the comments may take,
the thread's header not counted.  The longest cut that fits is the one
drawn; when the shortest does not, it is, and the thread is cut off
where its room ends."
  (let* ((draw (lambda (limit)
                 (change-review-ui--comment-rows set thread indent width details fold limit)))
         (most change-review-ui-max-comment-lines)
         (least (and most (min most change-review-ui--min-room)))
         (rows (funcall draw nil)))
    (if (or (not most) (<= (length (car rows)) rooms))
        rows
      ;; The most lines a cut can leave that still fit: more lines leave
      ;; more rows, so the search halves what is left between them.
      (let ((low least) (high most) (fits nil))
        (setq fits (funcall draw low))
        (if (> (length (car fits)) rooms)
            fits
          (while (> (- high low) 1)
            (let* ((middle (/ (+ low high) 2))
                   (try (funcall draw middle)))
              (if (<= (length (car try)) rooms)
                  (setq low middle fits try)
                (setq high middle))))
          fits)))))

(cl-defun change-review-ui-thread-string (set thread &key (view 'threads) placement
                                              collapsed details width (indent "") fold max-lines)
  "Return THREAD of SET drawn as text, each line ending in a newline.
This is the one drawing of a thread, in the threads view and in the
diff view.  It has a header line -- the thread's mark and short id,
where it is, how many comments it has, whether it is open or closed,
and for a thread someone else closed whether it is still to review --
and buttons, then each comment: the bar, the comment's place in the
thread (\"2/3\", and \"↳ re 1/3\" when it answers another than the one
before), who wrote it, when, against which revision, whether it is a
draft, and the text (`change-review-ui-body-lines': as it was typed,
unless the kind of set says its comments are a markup).  A comment
whose author is an agent has a button to the conversation it came from.

No line is wider than WIDTH, by default the room the buffer's window
has: a line that would be says less -- how long ago for a date, the
revision left out, shorter buttons -- until it fits.  INDENT starts
every line.

VIEW is `threads' or `diff': the diff view leaves out the line the
thread is about, since it is under it.  PLACEMENT is where the thread is
now (`change-review-placement'); a thread that moved says so.  COLLAPSED
draws only the header and the first words of the root.  DETAILS is a
list of comment ids, or t for all, that also show where they were made.

FOLD, for a view that lets the thread be folded (`change-review-ui-thread-fold'
says how it is), is `collapsed', `expanded' or `full': the header then
starts with a triangle, a button that folds it, and the first words of a
collapsed thread open it when clicked.  MAX-LINES, with FOLD `expanded',
is the most lines the thread takes, the header and the comments: the long
comments are cut shorter to fit, to three lines at the least, so that the
[Show more] of each stays in sight (`change-review-ui--fit-rows'), and
what still does not fit is cut off, a line saying how many lines the
thread has more, a button that draws all of it.  A thread whose DETAILS
show, or that the user asked to show more of
\(`change-review-ui-show-earlier', `change-review-ui-show-comment'), is
not cut.

A thread with many comments draws the first and the last few, and one
line, \"▸ 6 earlier replies\", for the ones between; a comment longer than
`change-review-ui-max-comment-lines' is cut, with a [Show more] button.
Both, in every view, whether or not it can be folded.  FOLD `full' leaves
nothing out.  What a view left out, a cut thread or one of these, is what
the next `change-review-ui-next-fold' shows."
  (let* ((width (or width (change-review-ui-current-width)))
         (collapsed (or collapsed (eq fold 'collapsed)))
         (fold (and fold (if collapsed 'collapsed fold)))
         (comments (change-review-thread-comments thread))
         (limit (and max-lines (eq fold 'expanded)
                     (not (or (eq details t)
                              (cl-some (lambda (comment) (member (change-review-comment-id comment) details))
                                       comments)
                              (change-review-ui--opened-p set thread)))
                     (max 3 max-lines)))
         (lines
          (if collapsed
              (list (change-review-ui--collapsed-line set thread view placement indent width fold))
            (pcase-let* ((`(,rows . ,left-out)
                          (if limit
                              (change-review-ui--fit-rows set thread indent width details fold (1- limit))
                            (change-review-ui--comment-rows set thread indent width details fold)))
                         (all (cons (concat (change-review-ui--thread-header set thread view placement indent
                                                                              width fold)
                                            "\n")
                                    rows))
                         (cut (and limit (> (length all) limit))))
              ;; A drawing that cannot be folded -- the threads view's -- says nothing of it.
              (when fold
                (change-review-ui--note-trimmed set thread (or cut left-out)))
              (if cut
                  ;; The button draws all of it: that is what the count is of.
                  (append (seq-take all (1- limit))
                          (list (change-review-ui--more-row
                                 set thread indent
                                 (- (1+ (length (car (change-review-ui--comment-rows
                                                      set thread indent width details 'full))))
                                    (1- limit)))))
                all)))))
    (propertize (apply #'concat lines)
                'change-review-thread (change-review-thread-id thread))))

(cl-defun change-review-ui-thread-line (set thread &key placement (width 80) (indent ""))
  "Return THREAD of SET as one line, for a list of threads.
Its mark, short id, line, the author and first words of its root, and
how many comments it has; each part drawn as the thread's header and
comments draw it, and \"to review\" for a thread someone else closed that
waits for the user.  PLACEMENT says where the thread is now.  The line
ends in a newline and carries the thread's id."
  (let* ((root (change-review-thread-root thread))
         (open (change-review-thread-open-p thread))
         (location (change-review-thread-location thread))
         (count (length (change-review-thread-comments thread)))
         (head (concat indent
                       (propertize (if open "●" "✓")
                                   'face (if open 'change-review-ui-open-face
                                           'change-review-ui-closed-face))
                       " "
                       (propertize (change-review-ui-thread-short-id set thread)
                                   'face 'change-review-ui-meta-face)
                       " · " (change-review-ui--where-text location placement) " · "
                       (propertize (change-review-author-label (change-review-comment-author root))
                                   'face (change-review-ui--author-face (change-review-comment-author root)))
                       ": "))
         (room (max 12 (- width (string-width head) 14))))
    (propertize (concat head (change-review-ui--preview set root room)
                        (if (> count 1)
                            (propertize (format " · %d comments" count) 'face 'change-review-ui-meta-face)
                          "")
                        (if (change-review-thread-drafts thread)
                            (propertize " · draft" 'face 'change-review-ui-draft-face) "")
                        (if (change-review-thread-unreviewed-p set thread)
                            (propertize " · to review" 'face 'change-review-ui-review-face) "")
                        "\n")
                'change-review-thread (change-review-thread-id thread))))

;;;; Where a comment was made

(defun change-review-ui--excerpt-line (text target)
  "Return TEXT, a line of a quoted diff, with the face of its kind.
TARGET non-nil marks the line the comment was made on."
  (let ((face (pcase (and (> (length text) 0) (aref text 0))
                (?+ 'diff-added) (?- 'diff-removed) (?@ 'diff-hunk-header) (_ nil))))
    (concat (propertize text 'face (cond ((and target face) (list face 'change-review-ui-target-face))
                                         (target 'change-review-ui-target-face)
                                         (t face)))
            (if target (propertize "  ◀" 'face 'change-review-ui-meta-face) ""))))

(defvar change-review-ui--source-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'change-review-ui-follow-source)
    (define-key map [mouse-1] #'change-review-ui-follow-source)
    map)
  "Keys on a line of the diff a comment was made on.
RET or a click shows the line of the source.")

(defun change-review-ui--source-buttons (set thread comment)
  "Return the buttons that show the source COMMENT of THREAD was written on.
Two spaces and one button when COMMENT was written against the newest
version, two when it was written against an earlier one: the code as it
was then, and as it is now."
  (let* ((revision (change-review-comment-revision comment))
         (latest (change-review-latest-version set))
         (newest (or (null revision) (null latest)
                     (change-review-same-revision-p revision (change-review-version-id latest)))))
    (concat
     "  "
     (if newest
         (change-review-ui--button "[Source]" "Show the code this comment is about"
                                   (lambda () (change-review-visit set comment)))
       (concat
        (change-review-ui--button
         (format "[Source @ %s]" (change-review-revision-name set revision))
         (format "Show the code this comment was written on: %s (%s), as it was"
                 (change-review-revision-name set revision)
                 (change-review-short-revision revision))
         (lambda () (change-review-visit set comment revision)))
        " "
        (change-review-ui--button
         (format "[Source @ %s]" (change-review-version-name latest))
         (format "Show the thread in the newest version, %s" (change-review-version-name latest))
         (lambda () (change-review-visit set thread))))))))

(defun change-review-ui--source-of (line)
  "Return (SIDE . NUMBER) for LINE, a line of an excerpt, or nil.
LINE is (KIND TEXT OLD NEW) as `change-review-diff-excerpt-lines' gives
it: a line of the file after the change, or a removed line, which is the
file's before it."
  (pcase (car line)
    ((or ?\s ?+) (and (nth 3 line) (cons 'new (nth 3 line))))
    (?- (and (nth 2 line) (cons 'old (nth 2 line))))))

(defun change-review-ui--excerpt-rows (location)
  "Return the lines that draw the excerpt of LOCATION, a string each.
Each line of the diff -- not the hunk header -- carries the file, the
side and the number of the line of the source it is, for
`change-review-ui-follow-source'."
  (let* ((excerpt (change-review-location-excerpt location))
         (path (change-review-location-file location))
         (rows (split-string excerpt "\n"))
         (lines (change-review-diff-excerpt-lines excerpt))
         (first t)
         out)
    (while rows
      (let* ((row (pop rows))
             (header (and first (change-review-diff--hunk-header-p row)))
             (line (and (not header) (not (string-empty-p row)) (pop lines)))
             (source (and line (change-review-ui--source-of line)))
             (text (concat (propertize "│ " 'face 'change-review-ui-meta-face)
                           (change-review-ui--excerpt-line row (null rows)))))
        (setq first nil)
        (push (if (and source path)
                  (propertize text
                              'change-review-source (list path (car source) (cdr source))
                              'keymap change-review-ui--source-map
                              'mouse-face 'highlight
                              'help-echo "RET or a click: show this line of the source")
                text)
              out)))
    (nreverse out)))

(defun change-review-ui--now-note (set comment location placement)
  "Return what to say of where the thread of COMMENT is now, or nil.
LOCATION is where COMMENT was made, PLACEMENT where its thread is now.
A comment written against the newest version has nothing to say: its
lines are as they are; and a thread that has not moved since the comment
was made has not moved."
  (let ((revision (change-review-comment-revision comment))
        (latest (change-review-latest-version set))
        (was (and location (change-review-location-line location))))
    (unless (and revision latest (change-review-same-revision-p revision (change-review-version-id latest)))
      (unless (and (eq (plist-get placement :status) 'moved) was
                   (eql was (plist-get placement :line)))
        (change-review-ui--placement-note placement was)))))

(defun change-review-ui-origin-lines (set thread comment)
  "Return the lines that say where COMMENT of THREAD in SET was made.
They give its place -- file, line and side -- and the revision, with
buttons to the source there (`change-review-origin'); where the thread
is now when the comment was written against an earlier version; the
lines of the diff of that revision the comment was made on, the last of
them the line it is about, each a way to its source line
\(`change-review-ui-follow-source'); and for an agent's comment the
session and the tool call."
  (let* ((origin (change-review-origin set thread comment))
         (location (plist-get origin :location))
         (revision (change-review-comment-revision comment))
         (author (change-review-comment-author comment))
         (placement (change-review-placement set thread))
         (meta 'change-review-ui-meta-face)
         lines)
    (push (concat
           (propertize
            (concat "made at "
                    (if location (change-review-location-label location t) "the change as a whole")
                    (if revision (format " · revision %s" (change-review-revision-name set revision)) "")
                    (if (and revision (not (equal (change-review-short-revision revision)
                                                  (change-review-revision-name set revision))))
                        (format " (%s)" (change-review-short-revision revision))
                      ""))
            'face meta)
           (if location (change-review-ui--source-buttons set thread comment) ""))
          lines)
    (when-let* ((note (plist-get origin :note)))
      (push (propertize note 'face meta) lines))
    (when-let* ((note (change-review-ui--now-note set comment location placement)))
      (push (propertize (concat "now: " (string-remove-prefix "now " note)) 'face meta) lines))
    (when (and location (change-review-location-excerpt location))
      (dolist (row (change-review-ui--excerpt-rows location))
        (push row lines)))
    (when (and author (eq (change-review-author-kind author) 'agent)
               (or (change-review-author-session author) (change-review-author-tool-call author)))
      (push (propertize (concat "from the conversation"
                                (if (change-review-author-session author)
                                    (format " · session %s" (change-review-author-session author)) "")
                                (if (change-review-author-tool-call author)
                                    (format " · call %s" (change-review-author-tool-call author)) ""))
                        'face meta)
            lines))
    (nreverse lines)))

;;;; Overlays: threads under the lines of another buffer

;; A thread drawn under a line is the `after-string' of an overlay at the
;; end of the line (its `before-string' at the start of the buffer, for a
;; thread about no line): rows of text that belong to no line of the
;; buffer, and one position, the end of the line.  Emacs cannot start a
;; window in the middle of such a string, and what it does when a scroll
;; would is to start the window at the position the string hangs on, from
;; which the next scroll leads to the same position: a window scrolled
;; line by line -- by the wheel, by `scroll-up' with a number of lines,
;; by Ediff's v and V -- cannot get past a thread, even one of five
;; rows; one that is taller than the window cannot be seen to its end.
;; So a window whose start is such a position is moved past the thread
;; (forwards) or back to the line it is under (backwards).  Point is
;; moved with it, and C-n and C-p go by lines of the buffer, so that the
;; rows of a thread are no stop of their own.

(defvar-local change-review-ui--keeps-scrolling nil
  "Non-nil in a buffer whose windows are kept from starting in a thread.
Set by the first thread drawn under a line of the buffer.")

(defun change-review-ui--thread-string-at-p (pos)
  "Return non-nil when a thread drawn under a line hangs on POS."
  (cl-some (lambda (overlay)
             (and (overlay-get overlay 'change-review-overlay)
                  (or (overlay-get overlay 'after-string)
                      (overlay-get overlay 'before-string))
                  t))
           (overlays-in pos pos)))

(defun change-review-ui--unstick (window old forward)
  "Start WINDOW past the thread it was scrolled into, or back before it.
OLD is where the window started before it was scrolled, FORWARD says the
scroll was towards the end of the buffer.  A window that now starts on
the position a thread hangs on starts at the next line, or, scrolled
back, at the line the thread is under.  The same goes for one scrolled
forwards that did not move at all, as one that starts on the thread
before the first line cannot, and as one that starts on the line a thread
is under cannot, when the thread has as many rows as the window: the
line is the first row, and every row after it the thread's, so there is
none to start at.  The empty line a thread is under is a place to start
in the first time.  Point is moved to where the window starts if that is
past it.  Return non-nil when the window was moved."
  (with-current-buffer (window-buffer window)
    (let* ((start (window-start window))
           (new (save-excursion
                  (goto-char start)
                  (cond
                   ((change-review-ui--thread-string-at-p start)
                    (cond
                     (forward
                      (unless (and (/= start old) (bolp) (eolp))
                        (forward-line 1)
                        (point)))
                     ((/= start old)
                      (beginning-of-line)
                      (point))))
                   ((and forward (= start old)
                         (progn (end-of-line) (change-review-ui--thread-string-at-p (point))))
                    (forward-line 1)
                    (point))))))
      ;; Not to the end of the buffer: there is nothing to see there.
      (when (and new (if forward (and (> new start) (< new (point-max))) (< new start)))
        (set-window-start window new)
        (when (and forward
                   (< (if (eq window (selected-window)) (point) (window-point window)) new))
          (if (eq window (selected-window))
              (goto-char new)
            (set-window-point window new)))
        t))))

(defun change-review-ui--scroll-advice (forward function &rest args)
  "Call FUNCTION, `scroll-up' or `scroll-down', with ARGS; keep it from sticking.
FORWARD says it scrolls towards the end of the buffer, as it does when
its argument is not negative.  In a buffer with threads drawn under its
lines the window it scrolled does not stay started in one
\(`change-review-ui--unstick'); anywhere else this is FUNCTION."
  (if (not change-review-ui--keeps-scrolling)
      (apply function args)
    (let* ((window (selected-window))
           (old (window-start window))
           (arg (car args))
           (forward (if (or (eq arg '-) (and (numberp arg) (< arg 0))) (not forward) forward)))
      (prog1 (apply function args)
        ;; No scrolling at all, by 0 lines, leaves the window where it is.
        (when (and (window-live-p window) (eq (window-buffer window) (current-buffer))
                   (not (eql arg 0)))
          (change-review-ui--unstick window old forward))))))

(defun change-review-ui--scroll-up-advice (function &rest args)
  "Advice around `scroll-up': see `change-review-ui--scroll-advice'."
  (apply #'change-review-ui--scroll-advice t function args))

(defun change-review-ui--scroll-down-advice (function &rest args)
  "Advice around `scroll-down': see `change-review-ui--scroll-advice'."
  (apply #'change-review-ui--scroll-advice nil function args))

(advice-add 'scroll-up :around #'change-review-ui--scroll-up-advice)
(advice-add 'scroll-down :around #'change-review-ui--scroll-down-advice)

(defun change-review-ui--pre-redisplay (window)
  "Keep WINDOW from starting in a thread drawn under a line, whatever scrolled it.
On `pre-redisplay-functions' in the buffer WINDOW shows: the start the
window had at the last redisplay says which way it moved
\(`change-review-ui--unstick')."
  (let ((old (window-parameter window 'change-review-ui-start))
        (start (window-start window)))
    (set-window-parameter window 'change-review-ui-start start)
    (when (and old (/= old start)
               (change-review-ui--unstick window old (> start old)))
      (set-window-parameter window 'change-review-ui-start (window-start window)))))

(defun change-review-ui--keep-scrolling ()
  "Keep this buffer's windows from sticking on the threads under its lines."
  (unless change-review-ui--keeps-scrolling
    (setq change-review-ui--keeps-scrolling t)
    (add-hook 'pre-redisplay-functions #'change-review-ui--pre-redisplay nil t)
    ;; C-n and C-p go from line to line, not through the rows of a thread.
    (setq-local line-move-visual nil)))

(defun change-review-ui-add-thread-overlay (set thread position &rest args)
  "Draw THREAD of SET under the line that ends at POSITION; return the overlay.
ARGS are those of `change-review-ui-thread-string', which draws it.  The
overlay carries the thread's id, so that the commands of this library
find the thread at point.  With the key :before non-nil in ARGS the
text goes before POSITION instead, on lines of its own.  A view of a
diff other than the ones here draws its threads with this.

The text of the comments is the mouse's to select, which a region
cannot, the thread being no text of the buffer: see
`change-review-ui-mouse-select'."
  (let* ((before (plist-get args :before))
         (args (cl-loop for (key value) on args by #'cddr
                        unless (eq key :before) append (list key value)))
         (text (apply #'change-review-ui-thread-string set thread args))
         (overlay (make-overlay position position nil t nil)))
    (change-review-ui--keep-scrolling)
    (overlay-put overlay 'change-review-overlay t)
    (overlay-put overlay 'change-review-thread (change-review-thread-id thread))
    (overlay-put overlay 'change-review-before before)
    (overlay-put overlay 'change-review-text (change-review-ui--selectable text))
    (change-review-ui--show-text overlay)
    overlay))

(defun change-review-ui-clear-overlays (&optional buffer)
  "Remove the thread overlays of BUFFER, by default the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (remove-overlays (point-min) (point-max) 'change-review-overlay t)))

(defun change-review-ui--overlay-thread-ids ()
  "Return the ids of the threads drawn under the line at point."
  (delete-dups
   (cl-loop for overlay in (overlays-in (line-beginning-position)
                                        (min (point-max) (1+ (line-end-position))))
            for id = (overlay-get overlay 'change-review-thread)
            when id collect id)))

;;;; What point is on

(defun change-review-ui--current-set ()
  "Return the change set of the current buffer, or signal an error."
  (or change-review-ui--set
      (and (functionp change-review-set-function) (funcall change-review-set-function))
      (user-error "No change review here")))

(defvar-local change-review-ui--chosen-thread nil
  "In a view, the id of the thread the user moved to last.
When several threads are drawn under one line, the commands act on it.")

(defun change-review-ui--thread-at-point ()
  "Return the thread at point: of the text it is on, else drawn under its line."
  (let* ((set (change-review-ui--current-set))
         (id (or (get-text-property (point) 'change-review-thread)
                 (let ((ids (change-review-ui--overlay-thread-ids)))
                   (if (and change-review-ui--chosen-thread
                            (member change-review-ui--chosen-thread ids))
                       change-review-ui--chosen-thread
                       (car ids))))))
    (and id (change-review-find-thread set id))))

(defun change-review-ui--threads-at-point (set)
  "Return the threads of SET point is on, or under: all those drawn under its line.
Point on the text of a thread is on that thread alone.  Those under a
line are in the order the set has them, which is the order the views
draw them in; the overlays themselves come in no order to count on."
  (let ((id (get-text-property (point) 'change-review-thread)))
    (if id
        (delq nil (list (change-review-find-thread set id)))
      (let ((ids (change-review-ui--overlay-thread-ids)))
        (cl-remove-if-not (lambda (thread) (member (change-review-thread-id thread) ids))
                          (change-review-set-threads set))))))

(defun change-review-ui--comment-at-point ()
  "Return the comment at point, or nil."
  (when-let* ((id (get-text-property (point) 'change-review-comment))
              (found (change-review-find-comment (change-review-ui--current-set) id)))
    (cdr found)))

(defun change-review-ui--target (&optional need-comment)
  "Return (SET THREAD COMMENT) for what point is on, or signal an error.
COMMENT is the comment point is on, else the last of the thread under
the line; with NEED-COMMENT a thread's last comment will not do."
  (let* ((set (change-review-ui--current-set))
         (thread (or (change-review-ui--thread-at-point)
                     (user-error "No thread here")))
         (comment (or (change-review-ui--comment-at-point)
                      (and (not need-comment) (change-review-thread-last-comment thread)))))
    (when (and need-comment (null comment)) (user-error "No comment here"))
    (list set thread comment)))

;;;; What of a comment's text a selection of the drawing is of

;; A comment is drawn wrapped, under a bar, between the lines of its
;; header and those that say where it was made, so what is selected of the
;; drawing -- the region of the threads view, what the mouse dragged over
;; in a thread under a line of a diff -- is not the text it is of.  The
;; lines that hold the text know: `change-review-body', from their first
;; character to their newline, is where in the comment's text that
;; character is (`change-review-ui--comment-lines').  A place in the
;; drawing is so a place in the text, and a selection a piece of it as it
;; was written, with its newlines and the spaces the wrapping left out.
;; The drawing is a string (a thread under a line is an overlay's) or the
;; buffer's text (the threads view): OBJECT, nil for the buffer, says which.

(defun change-review-ui--start (object)
  "Return the first position of OBJECT, a string, or else the current buffer."
  (if (stringp object) 0 (point-min)))

(defun change-review-ui--end (object)
  "Return the end of OBJECT, a string, or else the current buffer."
  (if (stringp object) (length object) (point-max)))

(defun change-review-ui--char (pos &optional object)
  "Return the character at POS of OBJECT, a string, or else the current buffer."
  (if (stringp object) (aref object pos) (char-after pos)))

(defun change-review-ui--body-line (pos &optional object)
  "Return (START FROM TO LENGTH) for the line of a comment's text that POS is on.
FROM and TO are where, in OBJECT, the characters of the text on that line
and the newline that ends it are: from FROM up to TO.  START is where in
the comment's text the first of them is, and LENGTH how many the text has
on the line.  Nil for a position that is not on such a line: in its bar,
in the comment's header, or elsewhere."
  (when-let* ((start (get-text-property pos 'change-review-body object)))
    (let* ((from (previous-single-property-change (1+ pos) 'change-review-body object
                                                  (change-review-ui--start object)))
           (to (next-single-property-change pos 'change-review-body object
                                            (change-review-ui--end object))))
      (list start from to
            (- to from (if (eq (change-review-ui--char (1- to) object) ?\n) 1 0))))))

(defun change-review-ui--clamped-offset (pos &optional object)
  "Return the offset in a comment's text that the place POS stands for.
POS is in OBJECT, in the drawing of a comment, and is none of its text.
A place before the text, the header's, stands for the start of the
text; one in the bar of a line of the text, for where that line starts;
one after the text, in the lines that say where it was made, for the end
of the text."
  (let* ((comment-start (previous-single-property-change (1+ pos) 'change-review-comment object
                                                         (change-review-ui--start object)))
         (comment-end (next-single-property-change pos 'change-review-comment object
                                                   (change-review-ui--end object)))
         (first (text-property-not-all comment-start comment-end 'change-review-body nil object))
         (next (and first (>= pos first)
                    (text-property-not-all pos comment-end 'change-review-body nil object))))
    (cond ((or (null first) (< pos first)) 0)
          ;; In the bar of a line of the text: the line is the next with some.
          ((and next (cl-loop for i from pos below next
                              never (eq (change-review-ui--char i object) ?\n)))
           (car (change-review-ui--body-line next object)))
          ;; After the text.
          (t (let ((last pos))
               (while (and (> last comment-start)
                           (not (get-text-property last 'change-review-body object)))
                 (cl-decf last))
               (pcase-let ((`(,start ,_from ,_to ,length) (change-review-ui--body-line last object)))
                 (+ start length)))))))

(defun change-review-ui--offset-at (pos &optional object)
  "Return (COMMENT-ID . OFFSET) for POS of OBJECT, or nil outside a comment.
OFFSET is where in the comment's text the character at POS is, as the
drawing says; for a place that is none of its text, the nearest of
its start and its end (`change-review-ui--clamped-offset').  OBJECT is a
string, or nil for the current buffer."
  (when-let* ((id (get-text-property pos 'change-review-comment object)))
    (cons id (if-let* ((line (change-review-ui--body-line pos object)))
                 (+ (nth 0 line) (min (- pos (nth 1 line)) (nth 3 line)))
               (change-review-ui--clamped-offset pos object)))))

(defun change-review-ui--region-parts (beg end)
  "Return the parts of comments' text that BEG to END of the buffer draws.
A list of (COMMENT-ID START END) in the order they are drawn, one for each
comment that has some in it: the text from START to END, offsets in
the comment's text.  Nothing of a comment's header or of where it was made
counts, only its text."
  (let ((pos beg) (parts nil))
    (while (and (< pos end)
                (setq pos (text-property-not-all pos end 'change-review-body nil)))
      (pcase-let* ((`(,start ,from ,to ,length) (change-review-ui--body-line pos))
                   (id (get-text-property pos 'change-review-comment))
                   (low (+ start (max 0 (- pos from))))
                   (high (+ start (min length (- (min end to) from)))))
        (if (equal id (car (car parts)))
            (setf (nth 2 (car parts)) high)
          (push (list id low high) parts))
        (setq pos to)))
    (nreverse (cl-remove-if-not (lambda (part) (< (nth 1 part) (nth 2 part))) parts))))

;;;; Quoting

(defun change-review-ui-quote-string (text)
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

(defun change-review-ui--quote-only-p (text)
  "Return non-nil when TEXT is nothing but quotes and blanks.
Every line of it that is not blank starts with \">\"."
  (cl-every (lambda (line) (or (string-blank-p line) (string-match-p "\\`[ \t]*>" line)))
            (split-string text "\n")))

;;;; Selecting the text of a thread drawn under a line

;; A thread under a line of a diff is no text of the buffer, only a string
;; an overlay shows, so no region holds any of it and a drag of the mouse
;; over it selects nothing.  The text of its comments has keys of its own
;; for that (`change-review-ui-text-map'): a drag over it selects a part of
;; a comment's text, a double click a word and a triple click a line.  The
;; selection is marked (`change-review-ui-selection-face') and is the
;; overlay's, its `change-review-selection': (COMMENT-ID START END), offsets
;; in the comment's text, which `change-review-ui-quote-reply' quotes and
;; `change-review-ui-copy-selection' copies.  It goes with the next command
;; that is not the mouse's.

(defvar change-review-ui-text-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'change-review-ui-mouse-select)
    (define-key map [double-down-mouse-1] #'change-review-ui-mouse-select)
    (define-key map [triple-down-mouse-1] #'change-review-ui-mouse-select)
    map)
  "Keys of the text of a comment in a thread drawn under a line.
The mouse selects it.")

(defun change-review-ui--selectable (text)
  "Return TEXT, a thread drawn, with the mouse's keys on its comments' text.
They are those of `change-review-ui-text-map'."
  (let ((text (copy-sequence text)) (pos 0))
    (while (and (< pos (length text))
                (setq pos (text-property-not-all pos (length text) 'change-review-body nil text)))
      (let ((to (next-single-property-change pos 'change-review-body text (length text))))
        (add-text-properties pos to (list 'keymap change-review-ui-text-map 'pointer 'text) text)
        (setq pos to)))
    text))

(defun change-review-ui--mark-selection (text selection)
  "Return TEXT, a thread drawn, with SELECTION of a comment's text marked.
SELECTION is (COMMENT-ID START END), as an overlay keeps it."
  (pcase-let ((`(,id ,low ,high) selection)
              (text (copy-sequence text)))
    (let ((pos 0))
      (while (and (< pos (length text))
                  (setq pos (text-property-not-all pos (length text) 'change-review-body nil text)))
        (pcase-let ((`(,start ,from ,to ,length) (change-review-ui--body-line pos text)))
          (when (equal id (get-text-property pos 'change-review-comment text))
            (let ((a (max low start)) (b (min high (+ start length))))
              (when (< a b)
                (add-face-text-property (+ from (- a start)) (+ from (- b start))
                                        'change-review-ui-selection-face nil text))))
          (setq pos to))))
    text))

(defun change-review-ui--show-text (overlay)
  "Put the text of OVERLAY, a thread under a line, in it, a selection marked.
It is the overlay's `after-string', or its `before-string' for a thread
that goes before its position.  Every character of the string knows
the overlay, as `change-review-view': what a mouse position is over is a
string, and the overlay is how the thread it draws is found."
  (let* ((text (overlay-get overlay 'change-review-text))
         (selection (overlay-get overlay 'change-review-selection))
         (text (if selection
                   (change-review-ui--mark-selection text selection)
                 (copy-sequence text))))
    (put-text-property 0 (length text) 'change-review-view overlay text)
    (if (overlay-get overlay 'change-review-before)
        (overlay-put overlay 'before-string text)
      ;; The buffer's own newline ends the last line.  A face the text's
      ;; last newline has, to reach the edge of the window as the
      ;; background of a code block does, would be lost with it: a stretch
      ;; to the edge has it instead.
      (let* ((face (and (> (length text) 0) (get-text-property (1- (length text)) 'face text)))
             (string (concat "\n" (substring text 0 -1)
                             (if face
                                 (propertize " " 'face face 'display '(space :align-to right))
                               ""))))
        ;; Point at the end of the line, where the thread hangs, is shown
        ;; after the string, on the last of its rows: one that is not in
        ;; sight with a thread taller than the window, which then scrolls
        ;; to the thread's end, out of the way of what it showed.  The
        ;; cursor is on the thread's first row instead.
        (when (> (length string) 1)
          (put-text-property 1 2 'cursor t string))
        (overlay-put overlay 'after-string string)))))

(defun change-review-ui--overlay-selection ()
  "Return what is selected of a thread drawn under a line in this buffer, or nil.
That is (COMMENT-ID START END): the text from START to END of the comment's."
  (cl-loop for overlay in (overlays-in (point-min) (point-max))
           for selection = (overlay-get overlay 'change-review-selection)
           when selection return selection))

(defun change-review-ui-clear-selection (&optional buffer)
  "Select nothing of the threads drawn under the lines of BUFFER.
BUFFER is by default the current one."
  (with-current-buffer (or buffer (current-buffer))
    (remove-hook 'post-command-hook #'change-review-ui--drop-selection t)
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (overlay-get overlay 'change-review-selection)
        (overlay-put overlay 'change-review-selection nil)
        (change-review-ui--show-text overlay)))))

(defconst change-review-ui--keeping-commands
  '(change-review-ui-mouse-select ignore handle-switch-frame
    scroll-up-command scroll-down-command scroll-other-window
    scroll-left scroll-right recenter-top-bottom
    mwheel-scroll pixel-scroll-precision)
  "The commands that leave a selection of a thread under a line as it is.
Those that only scroll, the mouse's wheel included.")

(defun change-review-ui--drop-selection ()
  "Select nothing again, once a command that is not the selection's has run.
On `post-command-hook' in a buffer that has a selection."
  (unless (memq this-command change-review-ui--keeping-commands)
    (change-review-ui-clear-selection)))

(defun change-review-ui--select (overlay id low high)
  "Select LOW to HIGH of the text of comment ID, in the thread OVERLAY draws.
Nothing else is selected in the buffer; LOW and HIGH the same select
nothing."
  (with-current-buffer (overlay-buffer overlay)
    (let ((selection (and (< low high) (list id low high))))
      (dolist (other (overlays-in (point-min) (point-max)))
        (when (and (not (eq other overlay)) (overlay-get other 'change-review-selection))
          (overlay-put other 'change-review-selection nil)
          (change-review-ui--show-text other)))
      ;; The mouse moves a pixel at a time, a character is many: draw
      ;; again only for a change.
      (unless (equal selection (overlay-get overlay 'change-review-selection))
        (overlay-put overlay 'change-review-selection selection)
        (change-review-ui--show-text overlay))
      (if selection
          (add-hook 'post-command-hook #'change-review-ui--drop-selection nil t)
        (remove-hook 'post-command-hook #'change-review-ui--drop-selection t)))))

(defun change-review-ui--posn-hit (posn)
  "Return (OVERLAY COMMENT-ID OFFSET TEXT-P) for what mouse position POSN is over.
Nil when it is not over a comment.  That is a thread drawn under a line,
in the text of one of its comments or in what is drawn of the comment
around it, which stands for the start or the end of the text
\(`change-review-ui--offset-at'); TEXT-P is non-nil for the text itself."
  (let ((string (posn-string posn)))
    (when (and (consp string) (stringp (car string))
               (<= 0 (cdr string)) (< (cdr string) (length (car string))))
      (when-let* ((overlay (get-text-property (cdr string) 'change-review-view (car string)))
                  ((overlayp overlay))
                  ((overlay-buffer overlay))
                  (hit (change-review-ui--offset-at (cdr string) (car string))))
        (list overlay (car hit) (cdr hit)
              (and (change-review-ui--body-line (cdr string) (car string)) t))))))

(defun change-review-ui--comment-body (overlay id)
  "Return the text of comment ID, in the set of the buffer OVERLAY is in, or nil."
  (with-current-buffer (overlay-buffer overlay)
    (when-let* ((found (change-review-find-comment (change-review-ui--current-set) id)))
      (change-review-comment-body (cdr found)))))

(defun change-review-ui--row-hit (posn overlay id)
  "Return the hit of the last character of comment ID on the row of POSN, or nil.
For a mouse position POSN to the right of the end of a row of the thread
OVERLAY draws, where it is over nothing: the hit
\(`change-review-ui--posn-hit') of the last character of the row."
  (let* ((window (posn-window posn))
         (xy (posn-x-y posn))
         (y (cdr xy))
         (lo 0)
         (hi (car xy))
         (same (lambda (hit) (and hit (eq (car hit) overlay) (equal (nth 1 hit) id))))
         (found (and (window-live-p window) (> hi 0)
                     (change-review-ui--posn-hit (posn-at-x-y 0 y window)))))
    (when (and found (funcall same found))
      ;; The characters of the row go from the left as far as its text
      ;; does, and nothing after: look for the last, by halves.
      (while (> (- hi lo) 1)
        (let* ((mid (/ (+ lo hi) 2))
               (hit (change-review-ui--posn-hit (posn-at-x-y mid y window))))
          (if (funcall same hit)
              (setq lo mid found hit)
            (setq hi mid))))
      found)))

(defun change-review-ui--drag-offset (posn overlay id window y)
  "Return the offset in the text of comment ID that a drag to POSN reaches.
The drag is in the thread OVERLAY draws, in WINDOW, and began at pixel
row Y.  Over the text it is the place there; to the right of it, the end of
its row; above it or under it, the start or the end of the text.  Nil
when POSN is not in WINDOW."
  (when (eq (posn-window posn) window)
    (let ((hit (change-review-ui--posn-hit posn)))
      (cond
       ((and hit (eq (car hit) overlay) (equal (nth 1 hit) id)) (nth 2 hit))
       ((when-let* ((row (change-review-ui--row-hit posn overlay id)))
          ;; After the last character of the row, not before it.
          (+ (nth 2 row) (if (nth 3 row) 1 0))))
       ((and (posn-x-y posn) (< (cdr (posn-x-y posn)) y)) 0)
       (t (length (or (change-review-ui--comment-body overlay id) "")))))))

(defun change-review-ui--unit (offset count body)
  "Return (LOW . HIGH), what a click of COUNT at OFFSET of BODY selects.
Nothing for one click, the word for two and the line for more."
  (let ((length (length body)))
    (if (or (= count 1) (>= offset length) (eq (aref body offset) ?\n))
        (cons offset offset)
      (if (= count 2)
          (let* ((char (aref body offset))
                 (regexp (cond ((string-match-p "[[:alnum:]_]" (string char)) "[[:alnum:]_]")
                               ((memq char '(?\s ?\t)) "[ \t]")
                               (t "[^[:alnum:]_ \t\n]")))
                 (low offset)
                 (high offset))
            (while (and (> low 0) (string-match-p regexp (string (aref body (1- low)))))
              (cl-decf low))
            (while (and (< high length) (string-match-p regexp (string (aref body high))))
              (cl-incf high))
            (cons low high))
        (cons (let ((newline (cl-position ?\n body :end offset :from-end t)))
                (if newline (1+ newline) 0))
              (or (cl-position ?\n body :start offset) length))))))

(defun change-review-ui--set-primary (text)
  "Make TEXT the primary selection, as an active region is, where there is one."
  (when (and select-active-regions (fboundp 'gui-set-selection) (display-graphic-p))
    (ignore-errors (gui-set-selection 'PRIMARY text))))

(defun change-review-ui-mouse-select (event)
  "Select, with the mouse, text of a comment in a thread drawn under a line.
Drag over it to select a part, double click for a word, triple click
for a line.  \\<change-review-ui-lines-mode-map>\\[change-review-ui-quote-reply] then quotes what is selected in a reply to the
comment.  A click without a drag selects nothing, and makes the thread
the one the commands of the buffer act on.  The selection goes with the
next command that is not this one's."
  (interactive "e")
  (let* ((start (event-start event))
         (window (posn-window start))
         (hit (change-review-ui--posn-hit start)))
    (if (not (and hit (window-live-p window)))
        (mouse-drag-region event)
      (pcase-let* ((`(,overlay ,id ,anchor ,_) hit)
                   (body (or (change-review-ui--comment-body overlay id) ""))
                   (unit (change-review-ui--unit anchor (max 1 (event-click-count event)) body))
                   (y (cdr (posn-x-y start)))
                   (last nil))
        (select-window window)
        (change-review-ui--select overlay id (car unit) (cdr unit))
        (track-mouse
          (while (progn (setq last (read-event))
                        (or (mouse-movement-p last)
                            (memq (car-safe last) '(switch-frame select-window))))
            (when (and (mouse-movement-p last) (overlay-buffer overlay))
              (when-let* ((offset (change-review-ui--drag-offset (event-end last) overlay id window y)))
                (change-review-ui--select overlay id (min (car unit) offset) (max (cdr unit) offset))))))
        ;; The release ends it; anything else, a key say, is for the
        ;; command loop once this command is over.
        (let ((modifiers (event-modifiers last)))
          (unless (and (mouse-event-p last) (not (memq 'down modifiers)))
            (push last unread-command-events)))
        (when (overlay-buffer overlay)
          (with-current-buffer (overlay-buffer overlay)
            (if-let* ((selection (overlay-get overlay 'change-review-selection)))
                (change-review-ui--set-primary
                 (substring body (min (nth 1 selection) (length body))
                            (min (nth 2 selection) (length body))))
              ;; A click: point where the thread is, and the thread the one
              ;; the commands act on.
              (when (eq (current-buffer) (window-buffer window))
                (goto-char (posn-point start)))
              (setq change-review-ui--chosen-thread (overlay-get overlay 'change-review-thread)))))))))

(defun change-review-ui-copy-selection ()
  "Copy what is selected of a comment's text, else do what `kill-ring-save' does.
The text a thread drawn under a line holds, selected with the mouse
\(`change-review-ui-mouse-select'), is held by no region."
  (interactive)
  (if-let* ((selection (change-review-ui--overlay-selection))
            (found (change-review-find-comment (change-review-ui--current-set) (car selection))))
      (let ((body (change-review-comment-body (cdr found))))
        (kill-new (substring body (min (nth 1 selection) (length body))
                             (min (nth 2 selection) (length body))))
        (change-review-ui-clear-selection)
        (message "Copied what was selected"))
    (call-interactively #'kill-ring-save)))
(defun change-review-ui-draft-candidates (threads)
  "Return the drafts of THREADS as (THREAD . COMMENT) each, in the order drawn."
  (cl-loop for thread in threads
           append (mapcar (lambda (comment) (cons thread comment))
                          (change-review-thread-drafts thread))))

(defun change-review-ui--draft-label (set thread comment)
  "Return COMMENT of THREAD in SET, a draft, as a line to choose it by."
  (let ((position (change-review-comment-position thread comment)))
    (format "%s %d/%d  %s" (change-review-ui-thread-short-id set thread)
            (car position) (cdr position)
            (truncate-string-to-width
             (string-replace "\n" " " (change-review-comment-body comment)) 60 nil nil "…"))))

(defun change-review-ui--choose (labels noun verb)
  "Return the value of the one of LABELS, (LABEL . VALUE) each, the user chooses.
The prompt starts with VERB and asks which NOUN; the last of LABELS is the
default, so RET takes the newest, and they keep their order in the list."
  (let* ((table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action (mapcar #'car labels) string predicate))))
         (default (car (car (last labels))))
         (choice (completing-read (format-prompt "%s which %s" default verb noun)
                                  table nil t nil nil default)))
    ;; A completion that takes any input can answer with what is none of them.
    (or (cdr (assoc choice labels))
        (user-error "No such %s: %s" noun choice))))

(defun change-review-ui-choose-draft (set candidates &optional verb)
  "Return the one of CANDIDATES, (THREAD . COMMENT) drafts of SET, to act on.
It is the only one, or the one chosen when there are several: the
prompt, which starts with VERB (\"Edit\" by default), lists each by its
thread, its place in it and its first words; the last is the default,
so RET takes the newest.  CANDIDATES keep their order in the list."
  (if (null (cdr candidates))
      (car candidates)
    (change-review-ui--choose
     (mapcar (lambda (candidate)
               (cons (change-review-ui--draft-label set (car candidate) (cdr candidate))
                     candidate))
             candidates)
     "draft" (or verb "Edit"))))

(defun change-review-ui--thread-label (set thread)
  "Return THREAD of SET, a thread of drafts, as a line to choose it by.
That is its short id, where it is, how many drafts it holds and the
first words of the first."
  (let ((count (length (change-review-thread-comments thread)))
        (location (change-review-thread-location thread)))
    (format "%s  %s  %d %s  %s" (change-review-ui-thread-short-id set thread)
            (if location (change-review-location-label location) "the change")
            count (if (= count 1) "draft" "drafts")
            (truncate-string-to-width
             (string-replace "\n" " " (change-review-comment-body (change-review-thread-root thread)))
             50 nil nil "…"))))

(defun change-review-ui-choose-thread (set threads &optional verb)
  "Return the one of THREADS, threads of drafts of SET, to act on.
It is the only one, or the one chosen when there are several: the
prompt, which starts with VERB (\"Delete\" by default), lists each by its
short id, where it is, how many drafts it holds and the first words of
the first; the last is the default, so RET takes the newest."
  (if (null (cdr threads))
      (car threads)
    (change-review-ui--choose
     (mapcar (lambda (thread) (cons (change-review-ui--thread-label set thread) thread))
             threads)
     "thread" (or verb "Delete"))))

(defun change-review-ui--draft-target (&optional verb)
  "Return (SET THREAD COMMENT) for the draft point is on, or signal an error.
That is the comment point is on, which has to be a draft; on a thread's
header, or under a line that has threads drawn under it, the draft of
those threads, asking which when there are several (VERB, \"Edit\" by
default, is what the question says to do with it)."
  (let* ((set (change-review-ui--current-set))
         (comment (change-review-ui--comment-at-point)))
    (if comment
        (progn
          (unless (change-review-comment-draft-p comment)
            (user-error "That comment was sent already"))
          (list set (car (change-review-find-comment set (change-review-comment-id comment))) comment))
      (let* ((threads (or (change-review-ui--threads-at-point set)
                          (user-error "No thread here")))
             (candidates (or (change-review-ui-draft-candidates threads)
                             (user-error "No draft in %s" (if (cdr threads) "these threads" "this thread"))))
             (choice (change-review-ui-choose-draft set candidates verb)))
        (list set (car choice) (cdr choice))))))

(defun change-review-ui--draft-thread-target (&optional verb)
  "Return (SET THREAD) for the thread of drafts point is on, or signal an error.
That is the thread point is on, else, under a line that has threads
drawn under it, the one of those that is nothing but drafts
\(`change-review-thread-draft-p'), asking which when there are several
\(VERB, \"Delete\" by default, is what the question says to do with it)."
  (let* ((set (change-review-ui--current-set))
         (threads (or (change-review-ui--threads-at-point set)
                      (user-error "No thread here")))
         (drafts (cl-remove-if-not #'change-review-thread-draft-p threads)))
    (cond
     (drafts (list set (change-review-ui-choose-thread set drafts verb)))
     ((cdr threads)
      (user-error "No thread of drafts here: every one of these has a comment that was sent"))
     (t
      (user-error "Thread %s has a comment that was sent: only a thread of drafts is deleted whole"
                  (change-review-ui-thread-short-id set (car threads)))))))

;;;; Reading a comment

(defvar string-edit-mode-hook)

(declare-function compose-quote-mode "compose-quote" (&optional arg))
(defvar compose-quote-area-function)

(defun change-review-ui--reading-area ()
  "Return where the text of a comment is in the buffer it is read in.
That is after the prompt.  The `compose-quote-area-function' of the
buffer `string-edit' makes."
  (list (if (get-text-property (point-min) 'string-edit--prompt)
            (or (next-single-property-change (point-min) 'string-edit--prompt) (point-max))
          (point-min))
        (point-max)))

(defun change-review-ui--prepare-reading (point)
  "Set up the buffer a comment is being read in, which is current.
POINT, `end' or nil, says where point starts, after the text to start
from or before it.  Where the compose-quote library is, the buffer
answers a quote inline with it: \\`M-RET' splits it, \\`C-c [' elides part of it."
  (when (eq point 'end)
    (goto-char (point-max))
    (dolist (window (get-buffer-window-list nil nil t))
      (set-window-point window (point))))
  (when (require 'compose-quote nil t)
    (setq-local compose-quote-area-function #'change-review-ui--reading-area)
    (compose-quote-mode 1)))

(defun change-review-ui-read-with-string-edit (prompt initial callback &optional point)
  "Read a comment in a buffer of its own: `change-review-ui-read-function'.
PROMPT says what for, INITIAL is the text to start from and CALLBACK
gets the text when the user finishes it with \\`C-c C-c'.  POINT, `end'
or nil, says whether point starts after INITIAL or before it."
  (require 'string-edit)
  (let ((string-edit-mode-hook (cons (lambda () (change-review-ui--prepare-reading point))
                                     string-edit-mode-hook)))
    (string-edit (concat prompt "  C-c C-c saves it as a draft, C-c C-k cancels")
                 (or initial "") callback :abort-callback #'ignore)))

(defun change-review-ui-read (prompt initial callback &optional point)
  "Read a comment as `change-review-ui-read-function' does; see there.
POINT is `end' to start with point after INITIAL, to answer a quote
that is its text; the function is given it when it takes a fourth
argument."
  (let ((arity (func-arity change-review-ui-read-function)))
    (if (and point (or (eq (cdr arity) 'many) (>= (cdr arity) 4)))
        (funcall change-review-ui-read-function prompt initial callback point)
      (funcall change-review-ui-read-function prompt initial callback))))

(defun change-review-ui--comment-label (set thread comment)
  "Return how to call COMMENT of THREAD in SET in a prompt."
  (let ((position (change-review-comment-position thread comment)))
    (format "%s's comment %d/%d%s"
            (change-review-author-label (change-review-comment-author comment))
            (car position) (cdr position)
            (if-let* ((location (change-review-thread-location thread)))
                (concat " on " (change-review-location-label location))
              (ignore set) ""))))

;;;; Commands on a thread

(defun change-review-ui-reply-to-comment (set thread comment &optional quote)
  "Read a reply to COMMENT of THREAD in SET and add it as a draft.
QUOTE, a string, is a block quote (`change-review-ui-quote-string') the
reply starts with: the text it answers, as it is in a mail.  Point starts
under it, and a reply that is nothing but the quote is no reply.
Answering a thread that waits for the user's review is looking at it:
the thread is reviewed then."
  (change-review-ui-read
   (format "Reply to %s:" (change-review-ui--comment-label set thread comment))
   (if quote (concat quote "\n\n") "")
   (lambda (text)
     (if (or (string-blank-p text) (and quote (change-review-ui--quote-only-p text)))
         (message "No reply")
       (change-review-reply set comment (string-trim text))
       (when (change-review-thread-unreviewed-p set thread)
         (change-review-mark-reviewed set thread))))
   (and quote 'end)))

(defun change-review-ui-reply-to-thread (set thread &optional quote)
  "Read a reply to the last comment of THREAD in SET and add it as a draft.
QUOTE is as for `change-review-ui-reply-to-comment'."
  (change-review-ui-reply-to-comment set thread (change-review-thread-last-comment thread) quote))

(defun change-review-ui-reply ()
  "Reply to the comment at point, as a draft.
In the diff view, where a thread is drawn under its line and has no
comment to point at, to the thread's last comment."
  (interactive)
  (pcase-let ((`(,set ,thread ,comment) (change-review-ui--target)))
    (change-review-ui-reply-to-comment set thread comment)))

(defun change-review-ui--selected-parts ()
  "Return what is selected of comments' text in this buffer, or nil.
A list of (COMMENT-ID START END), offsets in the comment's text.  That is
what the mouse selected of a thread drawn under a line
\(`change-review-ui-mouse-select'), else what the region holds of the
text drawn in the buffer.  An active region that holds none is an error."
  (or (when-let* ((selection (change-review-ui--overlay-selection)))
        (list selection))
      (when (use-region-p)
        (or (change-review-ui--region-parts (region-beginning) (region-end))
            (user-error (substitute-command-keys
                         "The region holds no text of a comment: \\[keyboard-quit] quotes the comment at point"))))))

(defun change-review-ui--quotation ()
  "Return (SET THREAD COMMENT QUOTE) for `change-review-ui-quote-reply'.
It is what that quotes: what is selected of comments' text
\(`change-review-ui--selected-parts'), else the whole text of the comment
at point, or of the last comment of the thread there.  COMMENT is the
comment to reply to, the last one quoted; QUOTE is the quote,
`change-review-ui-quote-string' of the text, and of each comment's when
there are several, each under a line that says who wrote it."
  (let* ((set (change-review-ui--current-set))
         (parts (change-review-ui--selected-parts))
         (entries
          (if parts
              (cl-loop for (id start end) in parts
                       for found = (change-review-find-comment set id)
                       when found
                       collect (let ((body (change-review-comment-body (cdr found))))
                                 (list (car found) (cdr found)
                                       (substring body (min start (length body)) (min end (length body))))))
            (pcase-let ((`(,_ ,thread ,comment) (change-review-ui--target)))
              (list (list thread comment (change-review-comment-body comment)))))))
    (setq entries (cl-remove-if (lambda (entry) (string-blank-p (nth 2 entry))) entries))
    (unless entries (user-error "Nothing to quote"))
    (when (cdr (cl-remove-duplicates (mapcar #'car entries) :test #'eq))
      (user-error "The selection is of more than one thread: select in one, to reply in it"))
    (let ((last (car (last entries))))
      (list set (nth 0 last) (nth 1 last)
            (if (cdr entries)
                (mapconcat (lambda (entry)
                             (concat (change-review-author-label (change-review-comment-author (nth 1 entry)))
                                     " wrote:\n" (change-review-ui-quote-string (nth 2 entry))))
                           entries "\n\n")
              (change-review-ui-quote-string (nth 2 (car entries))))))))

(defun change-review-ui-quote-reply ()
  "Reply to a comment, quoting what is selected of it.
Select part of a comment's text -- with the region in the threads view,
with the mouse in a thread drawn under a line of a diff, in Ediff say --
and this starts a reply to the comment with that part quoted, as a mail
does: a block quote, \"> \" before each line, and point under it, to answer
it.  Select text of several comments of a thread and each is quoted,
under a line that says who wrote it, in a reply to the last.  With
nothing selected the whole comment is quoted: the one at point, or the
last of the thread drawn under the line at point.  The reply is a draft,
as one that \\[change-review-ui-reply] makes is."
  (interactive)
  (pcase-let ((`(,set ,thread ,comment ,quote) (change-review-ui--quotation)))
    (deactivate-mark)
    (change-review-ui-clear-selection)
    (change-review-ui-reply-to-comment set thread comment quote)))

(defun change-review-ui-toggle-thread (set thread)
  "Close THREAD of SET if it is open, else open it again."
  (if (change-review-thread-open-p thread)
      (change-review-close set thread)
    (change-review-reopen set thread))
  (message "Thread %s is %s" (change-review-ui-thread-short-id set thread)
           (if (change-review-thread-open-p thread) "open" "closed")))

(defun change-review-ui-toggle-status ()
  "Close the thread at point if it is open, else open it again."
  (interactive)
  (pcase-let ((`(,set ,thread ,_) (change-review-ui--target)))
    (change-review-ui-toggle-thread set thread)))

(defun change-review-ui-set-status (status)
  "Set the status of the thread at point to STATUS, `open' or `closed'."
  (interactive (list (intern (completing-read "Status: " '("open" "closed") nil t))))
  (pcase-let ((`(,set ,thread ,_) (change-review-ui--target)))
    (change-review-update-status set thread status)
    (message "Thread %s is %s" (change-review-ui-thread-short-id set thread) status)))

(defun change-review-ui-mark-thread-reviewed (set thread)
  "Say the user looked at how THREAD of SET was closed: it no longer waits."
  (when (change-review-mark-reviewed set thread)
    (message "Thread %s is reviewed" (change-review-ui-thread-short-id set thread))))

(defun change-review-ui-toggle-thread-reviewed (set thread)
  "Mark how THREAD of SET was closed reviewed, or make it wait for the user again.
Only a close by someone else is the user's to review: for a thread that
is open, or that the user closed, it signals."
  (let* ((entry (change-review-thread-closing thread))
         (author (and entry (plist-get entry :author)))
         (short (change-review-ui-thread-short-id set thread)))
    (cond ((change-review-thread-open-p thread)
           (user-error "Thread %s is open: only a closed thread is reviewed" short))
          ((null author)
           (user-error "Thread %s has no record of who closed it: nothing to review" short))
          ((change-review-own-author-p set author)
           (user-error "You closed thread %s yourself: nothing to review" short))
          ((plist-get entry :reviewed)
           (change-review-unmark-reviewed set thread)
           (message "Thread %s waits for your review again" short))
          (t
           (change-review-mark-reviewed set thread)
           (message "Thread %s is reviewed" short)))))

(defun change-review-ui-toggle-reviewed ()
  "Mark the thread at point reviewed, or make it wait for you again.
A thread someone else closed is to review until you say you looked at
it.  Marking it takes it out of the `to review' filter, and a second
press puts it back, so a slip is undone."
  (interactive)
  (pcase-let ((`(,set ,thread ,_) (change-review-ui--target)))
    (change-review-ui-toggle-thread-reviewed set thread)))

(defun change-review-ui-mark-all-reviewed ()
  "Mark every thread that waits for your review reviewed, after asking.
It is the answer for an agent you trust: you read what it said, and
leave it at that."
  (interactive)
  (let* ((set (change-review-ui--current-set))
         (threads (change-review-threads set 'unreviewed))
         (count (length threads)))
    (cond ((null threads) (message "Nothing to review"))
          ((y-or-n-p (if (= count 1)
                         "Mark the thread that waits for your review reviewed? "
                       (format "Mark all %d threads that wait for your review reviewed? " count)))
           (dolist (thread threads) (change-review-mark-reviewed set thread))
           (message "%d %s reviewed" count (if (= count 1) "thread" "threads"))))))

(defun change-review-ui-show-in-diff ()
  "Show the thread at point in the diff view, at the line it is about."
  (interactive)
  (pcase-let ((`(,set ,thread ,_) (change-review-ui--target)))
    (change-review-visit set thread)))

(defun change-review-ui-follow-author ()
  "Go to the conversation the comment at point came from, when an agent wrote it."
  (interactive)
  (pcase-let ((`(,set ,thread ,comment) (change-review-ui--target)))
    (let ((author (change-review-comment-author
                   (or (and (eq (and comment (change-review-author-kind
                                              (change-review-comment-author comment)))
                                'agent)
                            comment)
                       (cl-find-if (lambda (c) (eq (and (change-review-comment-author c)
                                                        (change-review-author-kind
                                                         (change-review-comment-author c)))
                                                   'agent))
                                   (reverse (change-review-thread-comments thread)))
                       (user-error "No agent wrote in this thread")))))
      (change-review-follow-author set author))))

(defun change-review-ui-edit-comment (set thread comment)
  "Read a new text for COMMENT of THREAD in SET, a draft, and keep it.
The text to start from is the draft's own.  A blank text, or the
same one, changes nothing.  What was delivered was read, so a comment
that was sent while the text was written, from the feedback box say, is
left as it was: the new text goes to the kill ring instead, not lost."
  (unless (change-review-comment-draft-p comment)
    (user-error "That comment was sent already"))
  (let ((id (change-review-comment-id comment)))
    (change-review-ui-read
     (format "Edit %s:" (change-review-ui--comment-label set thread comment))
     (change-review-comment-body comment)
     (lambda (text)
       (let ((found (change-review-find-comment set id)))
         (cond ((string-blank-p text) (message "No change"))
               ((null found) (message "That draft is gone: nothing to change"))
               ((not (change-review-comment-draft-p (cdr found)))
                (kill-new text)
                (message "That comment was sent meanwhile, so it stays as it was; your text is in the kill ring"))
               ((equal (string-trim text) (change-review-comment-body (cdr found)))
                (message "No change"))
               (t (change-review-edit set (cdr found) (string-trim text)))))))))

(defun change-review-ui-edit-draft ()
  "Edit a draft: the comment at point, else a draft of the thread there.
Point on a comment edits it, which has to be a draft.  Point on a thread's
header, or on a line with threads drawn under it, edits the draft of
those threads, asking which when they have several.  The [Edit] button
of a draft edits that draft, whatever point is on."
  (interactive)
  (pcase-let ((`(,set ,thread ,comment) (change-review-ui--draft-target "Edit")))
    (change-review-ui-edit-comment set thread comment)))

(defun change-review-ui-delete-comment (set thread comment)
  "Delete COMMENT of THREAD in SET, a draft, after asking.
Only a draft can go: what was delivered was read, so a comment that was
sent -- also while the question was open, from the feedback box say --
stays.  The first comment of a thread that has more cannot go alone, for
the thread has its place from it: the question is then whether to delete
the whole thread, which is nothing but drafts when its first is one
\(`change-review-ui-delete-thread').  A thread left with no comment goes
with the last."
  (unless (change-review-comment-draft-p comment)
    (user-error "That comment was sent already: only a draft is deleted"))
  (if (change-review-ui--starts-thread-p thread comment)
      (change-review-ui--delete-thread
       set thread
       (format "This draft starts thread %s: delete the thread, with the %s after it? "
               (change-review-ui-thread-short-id set thread)
               (change-review-ui--drafts-phrase (1- (length (change-review-thread-comments thread))))))
    (let ((id (change-review-comment-id comment)))
      (when (y-or-n-p "Delete this draft? ")
        (let ((found (change-review-find-comment set id)))
          (cond ((null found) (message "That draft is gone already"))
                ((not (change-review-comment-draft-p (cdr found)))
                 (user-error "That comment was sent meanwhile, so it stays"))
                (t (change-review-delete set (cdr found))
                   (message "Draft deleted"))))))))

(defun change-review-ui--drafts-phrase (count)
  "Return COUNT drafts as words: \"draft\" for 1, \"3 drafts\" otherwise."
  (if (= count 1) "draft" (format "%d drafts" count)))

(defun change-review-ui-delete-thread (set thread)
  "Delete THREAD of SET, a thread of drafts, after asking.
A thread with a comment that was sent is not deleted, nor any draft in
it: what was delivered was read.  Then `change-review-ui-delete-comment'
takes back a draft of it.  The question says how many drafts go."
  (change-review-ui--delete-thread set thread nil))

(defun change-review-ui--delete-thread (set thread question)
  "Delete THREAD of SET, a thread of drafts, when the user says yes to QUESTION.
QUESTION is a string, by default one that counts the drafts.  What is
checked before the question is checked again after it: the thread may
have been sent meanwhile, or deleted."
  (let ((id (change-review-thread-id thread))
        (short (change-review-ui-thread-short-id set thread)))
    (unless (change-review-thread-draft-p thread)
      (user-error "Thread %s has a comment that was sent: only a thread of drafts is deleted whole"
                  short))
    (when (y-or-n-p (or question
                        (format "Delete thread %s with its %s? " short
                                (change-review-ui--drafts-phrase
                                 (length (change-review-thread-comments thread))))))
      (let ((live (change-review-find-thread set id)))
        (cond ((null live) (message "That thread is gone already"))
              ((not (change-review-thread-draft-p live))
               (user-error "Thread %s was sent meanwhile, so it stays" short))
              (t (change-review-delete-thread set live)
                 (message "Thread %s deleted" short)))))))

(defun change-review-ui-delete-draft ()
  "Delete a draft: the comment at point, else a draft of the thread there.
It is found as `change-review-ui-edit-draft' finds it, and the question
is asked as `change-review-ui-delete-comment' asks it.  The [Delete]
button of a draft deletes that draft, whatever point is on."
  (interactive)
  (pcase-let ((`(,set ,thread ,comment) (change-review-ui--draft-target "Delete")))
    (change-review-ui-delete-comment set thread comment)))

(defun change-review-ui-delete-draft-thread ()
  "Delete a thread that is nothing but drafts: the thread at point.
Point on a thread's text is on that thread.  Under a line with threads
drawn under it, in a view of a diff, the one of them that is nothing but
drafts, asking which when there are several.  A thread with a comment
that was sent is not deleted.  The [Delete thread] button in the header
of a thread of drafts deletes that thread, whatever point is on."
  (interactive)
  (pcase-let ((`(,set ,thread) (change-review-ui--draft-thread-target "Delete")))
    (change-review-ui-delete-thread set thread)))

(defun change-review-ui-comment-on-change ()
  "Add a comment on the change as a whole, as a draft: a thread of its own."
  (interactive)
  (let ((set (change-review-ui--current-set)))
    (change-review-ui-read
     "Comment on the change:" ""
     (lambda (text)
       (if (string-blank-p text)
           (message "No comment")
         (change-review-comment set (string-trim text)))))))

;;;; Folding a thread

(defvar change-review-ui--folds (make-hash-table :test 'eq :weakness 'key)
  "How threads were folded: change set -> a table of thread id -> (STATUS . FOLD).
FOLD is `collapsed', `expanded' or `full'.  STATUS is the thread's when
it was folded: a thread whose status changed since is drawn as a thread
of that status is, again.")

(defvar change-review-ui--trimmed (make-hash-table :test 'eq :weakness 'key)
  "Change set -> a table of the ids of the threads the last drawing cut short.")

(defun change-review-ui--note-trimmed (set thread trimmed)
  "Note that the last drawing of THREAD of SET was TRIMMED, cut short, or was not."
  (let ((table (or (gethash set change-review-ui--trimmed)
                   (puthash set (make-hash-table :test 'equal) change-review-ui--trimmed))))
    (if trimmed
        (puthash (change-review-thread-id thread) t table)
      (remhash (change-review-thread-id thread) table))))

(defun change-review-ui--trimmed-p (set thread)
  "Return non-nil when the last drawing of THREAD of SET cut it short."
  (let ((table (gethash set change-review-ui--trimmed)))
    (and table (gethash (change-review-thread-id thread) table))))

(defun change-review-ui-default-fold (thread &optional set)
  "Return how THREAD is folded before anyone folded it.
A closed thread is `collapsed', one line, unless
`change-review-ui-collapse-closed-in-diff' says not, or it waits for the
user's review in SET; any other is `expanded'."
  (if (and change-review-ui-collapse-closed-in-diff
           (not (change-review-thread-open-p thread))
           (not (and set (change-review-thread-unreviewed-p set thread))))
      'collapsed
    'expanded))

(defun change-review-ui-thread-fold (set thread)
  "Return how THREAD of SET is folded: `collapsed', `expanded' or `full'.
A collapsed thread is drawn as one line, an expanded one in full but
for what does not fit the window (`change-review-ui-max-thread-lines'),
a full one in full.  What the user chose
\(`change-review-ui-set-fold') holds while the thread keeps its status."
  (let* ((table (gethash set change-review-ui--folds))
         (entry (and table (gethash (change-review-thread-id thread) table))))
    (if (and entry (eq (car entry) (change-review-thread-status thread)))
        (cdr entry)
      (change-review-ui-default-fold thread set))))

(defun change-review-ui-set-fold (set thread fold)
  "Fold THREAD of SET to FOLD, `collapsed', `expanded' or `full'.
One line takes back what was shown of it: the earlier replies and the
long comments drawn in full (`change-review-ui-show-earlier',
`change-review-ui-show-comment'), so that its conversation, drawn
again, is as short as it was.  The views of SET are drawn again."
  (unless (memq fold '(collapsed expanded full))
    (signal 'change-review-error (list (format "Not a way to fold a thread: %S" fold))))
  (let ((table (or (gethash set change-review-ui--folds)
                   (puthash set (make-hash-table :test 'equal) change-review-ui--folds))))
    (puthash (change-review-thread-id thread) (cons (change-review-thread-status thread) fold) table))
  (when (eq fold 'collapsed)
    (change-review-ui--set-flag change-review-ui--earlier set (change-review-thread-id thread) nil)
    (dolist (comment (change-review-thread-comments thread))
      (change-review-ui--set-flag change-review-ui--shown set (change-review-comment-id comment) nil)))
  (change-review-ui-refresh set))

(defun change-review-ui-next-fold (set thread)
  "Return the fold THREAD of SET goes to next.
One line, then its conversation, then all of it when the drawing of the
conversation left something out, then one line again."
  (pcase (change-review-ui-thread-fold set thread)
    ('collapsed 'expanded)
    ('expanded (if (change-review-ui--trimmed-p set thread) 'full 'collapsed))
    (_ 'collapsed)))

(defun change-review-ui-cycle-folds (set threads)
  "Fold THREADS of SET, all as the first goes next (`change-review-ui-next-fold').
Say what they are now, and return that."
  (when threads
    (let ((next (change-review-ui-next-fold set (car threads))))
      (dolist (thread threads) (change-review-ui-set-fold set thread next))
      (message "%s: %s"
               (if (cdr threads)
                   (format "%d threads" (length threads))
                 (format "Thread %s" (change-review-ui-thread-short-id set (car threads))))
               (pcase next
                 ('collapsed "one line")
                 ('expanded "the conversation")
                 (_ "all of it")))
      next)))

(defun change-review-ui--threads-here (set)
  "Return the threads of SET drawn under the line at point, the chosen one first."
  (let ((chosen (change-review-ui--thread-at-point))
        (threads (cl-loop for id in (change-review-ui--overlay-thread-ids)
                          for thread = (change-review-find-thread set id)
                          when thread collect thread)))
    (if chosen (cons chosen (remq chosen threads)) threads)))

(defun change-review-ui--other-command (keys self)
  "Return the command KEYS run in this buffer but for SELF, or nil.
The first of the active keymaps, in the order the keys are looked up in,
that binds KEYS to a command that is not SELF: the other minor modes',
the major mode's, the global one."
  (cl-loop for map in (current-active-maps t)
           for binding = (lookup-key map keys)
           when (and (commandp binding) (not (eq binding self)))
           return binding))

(defun change-review-ui--reveal-line ()
  "Scroll the window of this buffer, if need be, to show what is under this line.
The threads drawn under the line at point, that is: when the next line is
not in sight, the window shows the line at point second from its top."
  (when-let* ((window (get-buffer-window (current-buffer))))
    (let ((next (save-excursion (forward-line 1) (point))))
      (unless (eq t (pos-visible-in-window-p next window))
        (with-selected-window window (recenter 1))))))

(defun change-review-ui-cycle-fold ()
  "Fold the thread under the line at point: one line, its conversation, all of it.
A closed thread is one line at first, and so can any thread be: this
shows its conversation, and, when there was more than the window has room
for (`change-review-ui-max-thread-lines'), all of it, and then makes it
one line again.  The window scrolls if what grew is out of sight.
Several threads under a line follow the first.  On a line with none this
is what TAB is without this library's keys."
  (interactive)
  (let* ((set (change-review-ui--current-set))
         (threads (change-review-ui--threads-here set)))
    (if threads
        (progn (change-review-ui-cycle-folds set threads)
               (change-review-ui-flush)
               (change-review-ui--reveal-line))
      (if-let* ((command (change-review-ui--other-command (kbd "TAB") #'change-review-ui-cycle-fold)))
          (call-interactively command)
        (user-error "No thread under this line")))))

;;;; Showing where a comment was made

(defun change-review-ui-toggle-details (comment)
  "Show where COMMENT was made under it, or hide that again, in this view."
  (let ((id (change-review-comment-id comment)))
    (setq change-review-ui--details
          (if (member id change-review-ui--details)
              (delete id change-review-ui--details)
            (cons id change-review-ui--details)))
    (change-review-ui-redraw)))

(defun change-review-ui-show-origin ()
  "Show where the comment at point was made, or hide that again.
That is the file and line, the revision, and the lines of the diff of
that revision it was made on, with a way to the source.  In the diff
view it is the comments of the thread under point."
  (interactive)
  (pcase-let ((`(,_ ,thread ,comment) (change-review-ui--target)))
    (if (get-text-property (point) 'change-review-comment)
        (change-review-ui-toggle-details comment)
      (let ((ids (mapcar #'change-review-comment-id (change-review-thread-comments thread))))
        (setq change-review-ui--details
              (if (cl-every (lambda (id) (member id change-review-ui--details)) ids)
                  (cl-set-difference change-review-ui--details ids :test #'equal)
                (cl-union change-review-ui--details ids :test #'equal)))
        (change-review-ui-redraw)))))

(defun change-review-ui-show-source ()
  "Show the code the comment at point was written on, as it was then.
That is the version the comment was written against: its diff, the code
the comment is about before the answer to it changed it.  \\`d' shows the
thread in the newest version instead.  On a thread, not a comment, the
thread's first."
  (interactive)
  (pcase-let ((`(,set ,thread ,_) (change-review-ui--target)))
    (let ((comment (or (change-review-ui--comment-at-point) (change-review-thread-root thread))))
      (change-review-visit set comment (change-review-comment-revision comment)))))

(defun change-review-ui-follow-source (&optional event)
  "Show the line of the source that the diff line at point, or clicked, is.
It is the line as the version the comment was written against has it
\(`change-review-visit').  The diff lines are those a comment's details
show (`change-review-ui-show-origin'); EVENT is the click."
  (interactive (list (and (mouse-event-p last-nonmenu-event) last-nonmenu-event)))
  (let* ((posn (and event (event-start event)))
         (clicked (and posn (posn-string posn)))
         (buffer (if posn (window-buffer (posn-window posn)) (current-buffer))))
    (with-current-buffer buffer
      (let* ((get (lambda (property)
                    (cond (clicked (get-text-property (cdr clicked) property (car clicked)))
                          ((and posn (integerp (posn-point posn)))
                           (get-text-property (posn-point posn) property))
                          (t (get-text-property (point) property)))))
             (source (funcall get 'change-review-source))
             (set (change-review-ui--current-set))
             (found (change-review-find-comment set (funcall get 'change-review-comment))))
        (unless (and source found) (user-error "No source line here"))
        (pcase-let ((`(,path ,side ,line) source))
          (change-review-visit set (change-review-make-location :file path :side side :line line)
                               (change-review-comment-revision (cdr found))))))))

;;;; Drawing a view again

(defun change-review-ui-redraw ()
  "Draw this view again."
  (interactive)
  (when (functionp change-review-ui--redraw-function)
    (funcall change-review-ui--redraw-function)))

(defun change-review-ui--buffers (set)
  "Return the live buffers that are views of SET."
  (cl-remove-if-not (lambda (buffer)
                      (and (buffer-live-p buffer)
                           (eq set (buffer-local-value 'change-review-ui--set buffer))
                           (buffer-local-value 'change-review-ui--redraw-function buffer)))
                    (buffer-list)))

(defun change-review-ui--redraw-buffer (buffer)
  "Draw the view BUFFER again, after the timer that waited for it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq change-review-ui--timer nil)
      (change-review-ui-redraw))))

(defun change-review-ui-refresh (set)
  "Draw the views of SET again soon.
A burst of changes draws each view once.  The views follow
operations by themselves; a program that changes what they show
otherwise -- where it places the threads, say -- calls this."
  (dolist (buffer (change-review-ui--buffers set))
    (with-current-buffer buffer
      (unless change-review-ui--timer
        (setq change-review-ui--timer
              (run-with-timer 0.02 nil #'change-review-ui--redraw-buffer buffer))))))

(defun change-review-ui--changed (set _op)
  "Draw the views of SET again soon, once an operation changed it.
On `change-review-changed-functions'."
  (change-review-ui-refresh set))

(add-hook 'change-review-changed-functions #'change-review-ui--changed)

(defun change-review-ui-flush ()
  "Draw every view that waits to be drawn again, now."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer) (buffer-local-value 'change-review-ui--timer buffer))
      (with-current-buffer buffer
        (cancel-timer change-review-ui--timer))
      (change-review-ui--redraw-buffer buffer))))

(defun change-review-ui--anchor ()
  "Return where point is in a view, to put it back after drawing it again.
The comment or the thread under it, and the line within that, then the
line of the buffer: where the thread was, when it is no longer shown."
  (let ((comment (get-text-property (point) 'change-review-comment))
        (thread (get-text-property (point) 'change-review-thread))
        (file (get-text-property (point) 'change-review-file)))
    (list comment thread file
          (- (line-number-at-pos) (line-number-at-pos
                                   (or (and comment (change-review-ui--property-start 'change-review-comment))
                                       (and thread (change-review-ui--property-start 'change-review-thread))
                                       (and file (change-review-ui--property-start 'change-review-file))
                                       (point-min))))
          (current-column)
          (line-number-at-pos))))

(defun change-review-ui--property-start (property)
  "Return where the run of text at point with the same PROPERTY starts."
  (let ((value (get-text-property (point) property)))
    (save-excursion
      (while (and (> (point) (point-min))
                  (equal value (get-text-property (1- (point)) property)))
        (goto-char (previous-single-property-change (point) property nil (point-min))))
      (point))))

(defun change-review-ui--goto-anchor (anchor)
  "Put point where ANCHOR, from `change-review-ui--anchor', says.
When what point was on is gone -- a thread marked reviewed in the filter
that lists those waiting, say -- it goes to where that was, which is the
next thread now, so that the keys can go on.  A comment that is shorter
now, one cut again, has point on its last line, not past it."
  (pcase-let ((`(,comment ,thread ,file ,offset ,column ,line) anchor))
    (let ((found (or (and comment (change-review-ui--find-property 'change-review-comment comment))
                     (and thread (change-review-ui--find-property 'change-review-thread thread))
                     (and file (change-review-ui--find-property 'change-review-file file)))))
      (cond
       (found
        (goto-char found)
        (forward-line (or offset 0))
        (when (and comment (not (equal comment (get-text-property (point) 'change-review-comment))))
          ;; The comment ends before the line it was on.
          (goto-char found)
          (while (and (not (eobp))
                      (equal comment (get-text-property (line-beginning-position 2) 'change-review-comment)))
            (forward-line 1)))
        (move-to-column (or column 0)))
       ((and (or comment thread file) line)
        (goto-char (point-min))
        (forward-line (1- line))
        ;; Off the end, or in a gap: back to the last thread before it.
        (while (and (not (bobp)) (not (get-text-property (point) 'change-review-thread)))
          (forward-line -1)))))))

(defun change-review-ui--find-property (property value)
  "Return where the first text with PROPERTY equal to VALUE starts, or nil."
  (let ((pos (point-min)) found)
    (while (and (not found) pos (< pos (point-max)))
      (if (equal (get-text-property pos property) value)
          (setq found pos)
        (setq pos (next-single-property-change pos property nil (point-max)))))
    found))

;;;; The threads view

(defvar change-review-threads-mode-map (make-sparse-keymap)
  "Keys of the threads view.")

;; Filled at top level, not in the `defvar', so that loading this file
;; again, as a reload does, gives a keymap that exists already its new keys.
(let ((map change-review-threads-mode-map))
  (set-keymap-parent map special-mode-map)
  (define-key map (kbd "n") #'change-review-ui-next-comment)
  (define-key map (kbd "p") #'change-review-ui-previous-comment)
  (define-key map (kbd "N") #'change-review-ui-next-thread)
  (define-key map (kbd "P") #'change-review-ui-previous-thread)
  (define-key map (kbd "RET") #'change-review-ui-show-origin)
  (define-key map (kbd "TAB") #'change-review-ui-show-origin)
  (define-key map (kbd "r") #'change-review-ui-reply)
  (define-key map (kbd "x") #'change-review-ui-toggle-status)
  (define-key map (kbd "m") #'change-review-ui-toggle-reviewed)
  (define-key map (kbd "M") #'change-review-ui-mark-all-reviewed)
  (define-key map (kbd "s") #'change-review-ui-set-status)
  (define-key map (kbd "d") #'change-review-ui-show-in-diff)
  (define-key map (kbd "D") #'change-review-ui-show-source)
  (define-key map (kbd "o") #'change-review-ui-follow-author)
  (define-key map (kbd "e") #'change-review-ui-edit-draft)
  (define-key map (kbd "k") #'change-review-ui-delete-draft)
  (define-key map (kbd "K") #'change-review-ui-delete-draft-thread)
  (define-key map (kbd "c") #'change-review-ui-comment-on-change)
  (define-key map (kbd "f") #'change-review-ui-cycle-filter)
  (define-key map (kbd "F") #'change-review-ui-set-filter)
  (define-key map (kbd "g") #'change-review-ui-redraw)
  (define-key map (kbd "I") #'change-review-ui-import-reply)
  (define-key map (kbd "C-c C-c") #'change-review-ui-send))

(define-derived-mode change-review-threads-mode special-mode "Review-Threads"
  "The threads of a change set, grouped by file.

Point is on a comment; the keys act on it:
\\<change-review-threads-mode-map>
\\[change-review-ui-next-comment] and \\[change-review-ui-previous-comment] move between comments,
\\[change-review-ui-next-thread] and \\[change-review-ui-previous-thread] between threads.
\\[change-review-ui-show-origin] shows where the comment was made, hides it again.
\\[change-review-ui-reply] replies to it, as a draft.
\\[change-review-ui-quote-reply] replies to it with the text you selected of it quoted, or all of it.
\\[change-review-ui-toggle-status] closes its thread or opens it again.
\\[change-review-ui-toggle-reviewed] marks a thread someone else closed reviewed, or makes it wait again;
\\[change-review-ui-mark-all-reviewed] marks every one that waits.
\\[change-review-ui-set-status] sets the status by name.
\\[change-review-ui-show-in-diff] shows it in the diff view, in the newest version.
\\[change-review-ui-show-source] shows the code the comment was written on, as it was then.
\\[change-review-ui-follow-author] follows an agent's comment to its conversation.
\\[change-review-ui-edit-draft] edits a draft, \\[change-review-ui-delete-draft] deletes it: the
comment at point, or on a thread's header one of the thread's drafts.
\\[change-review-ui-delete-draft-thread] deletes the thread at point when it is nothing but drafts.
\\[change-review-ui-comment-on-change] comments on the change as a whole.
\\[change-review-ui-send] sends the drafts, \\[change-review-ui-import-reply] adds the comments of a reply.
\\[change-review-ui-cycle-filter] changes which threads show.
\\[change-review-ui-redraw] draws the view again.

\\{change-review-threads-mode-map}"
  (setq-local truncate-lines nil)
  (setq change-review-ui--redraw-function #'change-review-ui--draw-threads))

(defconst change-review-ui--filters
  '((open . "open") (unreviewed . "to review") (closed . "closed") (all . "all"))
  "The filters of the views, in the order f goes through them, and their names.
`unreviewed' shows the closed threads that wait for the user's review: it
comes after `open', the other threads that want the user's attention.")

(defun change-review-ui--filter-phrase (filter)
  "Return what the threads of FILTER are called: \"open threads\", say."
  (if (eq filter 'unreviewed)
      "threads to review"
    (format "%s threads" filter)))

(defun change-review-ui--filter-button (set label filter current)
  "Return a button that shows the threads of FILTER, labelled LABEL, of SET.
The one for CURRENT, the filter in force, is marked instead."
  (let* ((counts (change-review-thread-counts set))
         (number (pcase filter
                   ('open (plist-get counts :open))
                   ('closed (plist-get counts :closed))
                   ('unreviewed (plist-get counts :unreviewed))
                   (_ (+ (plist-get counts :open) (plist-get counts :closed)))))
         (text (format "%s %d" label number)))
    (if (eq filter current)
        (propertize (format "[%s]" text) 'face 'change-review-ui-filter-face)
      (change-review-ui--button
       (format " %s " text) (format "Show the %s threads" label)
       (lambda ()
         (setq change-review-ui--filter filter)
         (change-review-ui-redraw))))))

(defun change-review-ui--set-title (set)
  "Return what to call SET in a heading."
  (or (change-review--string (change-review-set-title set))
      (change-review--string (change-review-set-id set))
      "change"))

(defun change-review-ui-threads-heading (set &optional filter)
  "Return the line that heads the threads of SET, ending in a newline.
It is \"Threads\" and a button for each status filter -- open, closed and
all, with how many threads each lets through -- the one for FILTER, by
default `change-review-ui--filter', marked as in force; and how many
drafts are not sent.  A button sets `change-review-ui--filter' in the
buffer it is pressed in and draws that view again
\(`change-review-ui-redraw'), so a buffer that embeds the threads
\(`change-review-ui-threads-string') keeps both."
  (let ((counts (change-review-thread-counts set))
        (filter (or filter change-review-ui--filter)))
    (concat
     (propertize "Threads  " 'face 'change-review-ui-header-face)
     (mapconcat (lambda (spec)
                  (change-review-ui--filter-button set (cdr spec) (car spec) filter))
                change-review-ui--filters " ")
     (if (> (plist-get counts :drafts) 0)
         (propertize (format "     %d %s not sent" (plist-get counts :drafts)
                             (if (= 1 (plist-get counts :drafts)) "draft" "drafts"))
                     'face 'change-review-ui-draft-face)
       "")
     "\n")))

(defun change-review-ui--heading (set)
  "Return the first lines of the threads view of SET."
  (let* ((version (change-review-latest-version set)))
    (concat
     (propertize "Review of " 'face 'change-review-ui-header-face)
     (propertize (change-review-ui--set-title set) 'face 'change-review-ui-header-face)
     (if version
         (propertize (format "   %s of %d" (change-review-version-name version)
                             (length (change-review-set-versions set)))
                     'face 'change-review-ui-meta-face)
       "")
     "\n"
     (change-review-ui-threads-heading set change-review-ui--filter)
     (propertize (substitute-command-keys
                  "\\<change-review-threads-mode-map>\
\\[change-review-ui-next-comment]/\\[change-review-ui-previous-comment] comments  \
\\[change-review-ui-next-thread]/\\[change-review-ui-previous-thread] threads  \
\\[change-review-ui-show-origin] where  \\[change-review-ui-reply] reply  \
\\[change-review-ui-edit-draft] edit draft  \\[change-review-ui-delete-draft] delete draft  \\[change-review-ui-toggle-status] close/open  \\[change-review-ui-toggle-reviewed] reviewed  \\[change-review-ui-show-in-diff] diff now  \\[change-review-ui-show-source] diff then  \\[change-review-ui-cycle-filter] filter  \\[quit-window] quit")
                 'face 'change-review-ui-meta-face)
     "\n\n")))

(cl-defun change-review-ui-threads-string (set &key (filter 'open) details width (indent "") empty)
  "Return the threads of SET that FILTER lets through, grouped by file, as text.
This is the body of the threads view, for a buffer that shows it among
its own text.  The change as a whole comes first, then the files in the
order of the newest version; under the name of a file, each of its
threads drawn as `change-review-ui-thread-string' draws it in the
threads view, a blank line after each.  The text carries the ids of its
threads and comments, so the commands of this library, such as
`change-review-ui-reply' and `change-review-ui-toggle-status', find
the thread or the comment at point in the buffer that shows it.

FILTER is `open', `closed' or `all'.  DETAILS is the list of the ids of
the comments that also show where they were made.  WIDTH is the width to
wrap to, by default that of the window showing the current buffer, and
INDENT starts every line.  EMPTY is the line to say when the filter
lets no thread through, by default one that says so.  The head of the
threads, their filter buttons, is `change-review-ui-threads-heading'."
  (let ((groups (change-review-threads-by-file set filter))
        (width (or width (change-review-ui-current-width))))
    (if (null groups)
        (propertize (concat indent
                            (or empty (pcase filter
                                        ('open "No open threads.")
                                        ('closed "No closed threads.")
                                        ('unreviewed "Nothing to review.")
                                        (_ "No threads yet.")))
                            "\n")
                    'face 'change-review-ui-meta-face)
      (mapconcat
       (lambda (group)
         (let* ((file (car group)) (threads (cdr group))
                (open (cl-count-if #'change-review-thread-open-p threads)))
           (concat
            (propertize
             (concat indent
                     (propertize (if file (concat "▾ " file) "▾ The change as a whole")
                                 'face 'change-review-ui-file-face)
                     (propertize (format "   %d %s%s" (length threads)
                                         (if (= 1 (length threads)) "thread" "threads")
                                         (if (eq filter 'all) (format " · %d open" open) ""))
                                 'face 'change-review-ui-meta-face)
                     "\n")
             'change-review-file (or file :change))
            (mapconcat
             (lambda (thread)
               (concat (change-review-ui-thread-string
                        set thread :view 'threads
                        :placement (change-review-placement set thread)
                        :details details :width width :indent (concat indent "  "))
                       "\n"))
             threads ""))))
       groups ""))))

(defun change-review-ui--screen-row ()
  "Return the row of the selected window point is on, 0 being its top row.
Nil when this buffer is not the one the selected window shows."
  (let ((window (selected-window)))
    (when (eq (window-buffer window) (current-buffer))
      (let ((lines (count-screen-lines (window-start window) (point) nil window)))
        (if (bolp) lines (max 0 (1- lines)))))))

(defun change-review-ui--draw-threads ()
  "Draw the threads view in the current buffer.
Point stays on what it was on, on the row of the window it was on: a
button that draws more or less of a thread leaves the reader where they
were."
  (let* ((inhibit-read-only t)
         (set change-review-ui--set)
         (anchor (change-review-ui--anchor))
         (row (change-review-ui--screen-row)))
    (erase-buffer)
    (insert (change-review-ui--heading set)
            (change-review-ui-threads-string
             set :filter change-review-ui--filter :details change-review-ui--details
             :width (change-review-ui-current-width)
             :empty (pcase change-review-ui--filter
                      ('open "No open threads.  f shows the closed ones.")
                      ('closed "No closed threads.  f shows the open ones.")
                      ('unreviewed "Nothing to review: no thread closed by someone else waits for you.  f shows the others.")
                      (_ "No threads yet.  c comments on the change; in the diff view, c comments on a line."))))
    (goto-char (point-min))
    (change-review-ui--goto-anchor anchor)
    (when (and row (eq (window-buffer (selected-window)) (current-buffer)))
      (recenter row))
    (set-buffer-modified-p nil)
    (force-mode-line-update)))

(defun change-review-ui--buffer-name (kind set &optional suffix)
  "Return the name of the buffer of KIND, a string, for SET.
SUFFIX, a string, ends the name."
  (format "*Review %s: %s%s*" kind (change-review-ui--set-title set) (or suffix "")))

(defun change-review-ui--view-buffer (kind set mode &optional version suffix)
  "Return the buffer of KIND, a string, in MODE that shows SET.
That is the live one that shows it already -- of VERSION, for a view of
one -- else a new one, named for SET and ending in SUFFIX.  Two sets
with one title each have a buffer of their own."
  (or (cl-find-if (lambda (buffer)
                    (and (eq mode (buffer-local-value 'major-mode buffer))
                         (eq set (buffer-local-value 'change-review-ui--set buffer))
                         (or (null version)
                             (eq version (buffer-local-value 'change-review-ui--version buffer)))))
                  (buffer-list))
      (generate-new-buffer (change-review-ui--buffer-name kind set suffix))))

(defvar change-review-ui-sets nil
  "The change sets the views were opened for, newest first.")

(defun change-review-ui--read-set ()
  "Return the change set to open a view of: the buffer's, else one asked for."
  (or change-review-ui--set
      (and (functionp change-review-set-function) (funcall change-review-set-function))
      (pcase (length change-review-ui-sets)
        (0 (user-error "No change review open"))
        (1 (car change-review-ui-sets))
        (_ (let ((names (mapcar (lambda (set) (cons (change-review-ui--set-title set) set))
                                change-review-ui-sets)))
             (cdr (assoc (completing-read "Change review: " names nil t) names)))))))

;;;###autoload
(defun change-review-open-threads (set &optional filter)
  "Show the threads of change set SET, grouped by file.
FILTER is `open', `closed' or `all'; by default what the view showed
last, else `change-review-ui-default-filter'.  Return the buffer."
  (interactive (list (change-review-ui--read-set)))
  (setq change-review-ui-sets (cons set (delq set change-review-ui-sets)))
  (let ((buffer (change-review-ui--view-buffer "threads" set 'change-review-threads-mode)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'change-review-threads-mode)
        (change-review-threads-mode))
      (setq change-review-ui--set set
            change-review-ui--filter (or filter change-review-ui--filter
                                         change-review-ui-default-filter)))
    ;; Shown before it is drawn: the threads are drawn to the width of
    ;; their window, not to eighty columns for want of one.
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (change-review-ui--draw-threads))
    buffer))

(defun change-review-ui--read-filter ()
  "Ask which threads to show, and return the filter that is."
  (let ((name (completing-read "Show threads: " (mapcar #'cdr change-review-ui--filters) nil t)))
    (car (rassoc name change-review-ui--filters))))

(defun change-review-ui-set-filter (filter)
  "Show the threads of FILTER: `open', `closed', `all', or `unreviewed'.
The last is the closed threads someone else closed and the user has not
reviewed yet: what an agent answered and closed since they looked."
  (interactive (list (change-review-ui--read-filter)))
  (setq change-review-ui--filter filter)
  (change-review-ui-redraw))

(defun change-review-ui-cycle-filter ()
  "Change which threads show: open, those to review, closed, and all."
  (interactive)
  (let ((order (mapcar #'car change-review-ui--filters)))
    (change-review-ui-set-filter (or (cadr (memq change-review-ui--filter order)) (car order)))))

;;;; Moving between comments and threads

(defun change-review-ui--move-to-start (property direction)
  "Move to the next start of text with PROPERTY, in DIRECTION 1 or -1.
Return non-nil when there was one."
  (let ((pos (point)) found)
    (while (and (not found)
                (setq pos (if (> direction 0)
                              (next-single-property-change pos property)
                            (previous-single-property-change pos property))))
      (when (get-text-property pos property)
        (setq found pos)))
    ;; A run that starts at the beginning of the buffer is not a change.
    (when (and (not found) (< direction 0) (get-text-property (point-min) property)
               (> (point) (point-min)))
      (setq found (point-min)))
    (when found (goto-char found))
    found))

(defun change-review-ui-next-comment ()
  "Move to the next comment of the threads view."
  (interactive)
  (end-of-line)
  (or (change-review-ui--move-to-start 'change-review-comment-start 1)
      (user-error "No more comments")))

(defun change-review-ui-previous-comment ()
  "Move to the previous comment of the threads view."
  (interactive)
  (beginning-of-line)
  (or (change-review-ui--move-to-start 'change-review-comment-start -1)
      (user-error "No earlier comment")))

(defun change-review-ui-next-thread ()
  "Move to the next thread: in the threads view, or the diff view."
  (interactive)
  (if (derived-mode-p 'change-review-diff-view-mode)
      (change-review-ui--next-thread-overlay 1)
    (end-of-line)
    (or (change-review-ui--move-to-start 'change-review-thread-start 1)
        (user-error "No more threads"))))

(defun change-review-ui-previous-thread ()
  "Move to the previous thread: in the threads view, or the diff view."
  (interactive)
  (if (derived-mode-p 'change-review-diff-view-mode)
      (change-review-ui--next-thread-overlay -1)
    (beginning-of-line)
    (or (change-review-ui--move-to-start 'change-review-thread-start -1)
        (user-error "No earlier thread"))))

;;;; The diff view

(defvar-local change-review-ui--index nil
  "In the diff view, where each file is: a list of (FILE START END LINES).
LINES maps (SIDE . NUMBER) to the end of the line that has it.")

(defvar change-review-diff-view-mode-map (make-sparse-keymap)
  "Keys of the diff view, beside those of `diff-mode'.")

;; Filled at top level, not in the `defvar', so that loading the file
;; again, as an Emacs that runs on does after an update, gives the map
;; the keys the new version has.
(let ((map change-review-diff-view-mode-map))
  (define-key map (kbd "c") #'change-review-ui-comment-at-point)
  (define-key map (kbd "r") #'change-review-ui-reply)
  (define-key map (kbd "x") #'change-review-ui-toggle-status)
  (define-key map (kbd "m") #'change-review-ui-toggle-reviewed)
  (define-key map (kbd "M") #'change-review-ui-mark-all-reviewed)
  (define-key map (kbd "o") #'change-review-ui-follow-author)
  (define-key map (kbd "e") #'change-review-ui-edit-draft)
  (define-key map (kbd "k") #'change-review-ui-delete-draft)
  (define-key map (kbd "K") #'change-review-ui-delete-draft-thread)
  (define-key map (kbd "RET") #'change-review-ui-return)
  (define-key map (kbd "TAB") #'change-review-ui-cycle-fold)
  (define-key map (kbd "T") #'change-review-ui-show-threads)
  (define-key map (kbd "C-c C-n") #'change-review-ui-next-thread)
  (define-key map (kbd "C-c C-p") #'change-review-ui-previous-thread)
  (define-key map (kbd "C-c C-t") #'change-review-ui-show-threads)
  (define-key map (kbd "C-c C-f") #'change-review-ui-cycle-filter)
  (define-key map (kbd "C-c C-c") #'change-review-ui-send)
  (define-key map (kbd "C-c C-i") #'change-review-ui-import-reply))

(define-derived-mode change-review-diff-view-mode diff-mode "Review-Diff"
  "A version of a change as the unified diff, with its threads under the lines.

\\<change-review-diff-view-mode-map>
\\[change-review-ui-comment-at-point] comments on the line at point, or on the region.
Under a thread:
\\[change-review-ui-reply] replies to it.
\\[change-review-ui-quote-reply] replies to it with what you selected of a comment (drag the
mouse over its text) quoted, or all of the last comment.
\\[change-review-ui-edit-draft] edits a draft of it (the [Edit] button of a draft does too).
\\[change-review-ui-delete-draft] deletes a draft of it (so does the [Delete] button of a draft).
\\[change-review-ui-delete-draft-thread] deletes the thread when it is nothing but drafts
\(its [Delete thread] button does too).
\\[change-review-ui-toggle-status] closes it or opens it again.
\\[change-review-ui-toggle-reviewed] marks it reviewed when someone else closed it, or makes it wait again;
\\[change-review-ui-mark-all-reviewed] marks every thread that waits.
\\[change-review-ui-return] opens it if it is one line, else shows where its comments were made.
\\[change-review-ui-cycle-fold] folds it: one line, its conversation, all of it.
\\[change-review-ui-follow-author] follows an agent's comment to its conversation.
\\[change-review-ui-next-thread] and \\[change-review-ui-previous-thread] move between threads.
\\[change-review-ui-show-threads] lists them by file.
\\[change-review-ui-send] sends the drafts, \\[change-review-ui-import-reply] adds the comments of a reply.

The keys of `diff-mode' stay: n and p between hunks.  Its k and K, which
kill hunks and files of the view, are the ones that delete drafts here.

\\{change-review-diff-view-mode-map}"
  (setq buffer-read-only t)
  (setq change-review-ui--redraw-function #'change-review-ui--draw-diff))

(defun change-review-ui--index-file (file start end)
  "Return where the lines of FILE's diff are, between START and END of the buffer.
A hash table of (SIDE . NUMBER) to the end of the line."
  (let ((table (make-hash-table :test 'equal)))
    (save-excursion
      (goto-char start)
      (dolist (hunk (change-review-diff-hunks file))
        (when (re-search-forward (concat "^" (regexp-quote (plist-get hunk :header)) "$") end t)
          (dolist (line (plist-get hunk :lines))
            (forward-line 1)
            (let ((eol (line-end-position)))
              (pcase (nth 0 line)
                (?\s (puthash (cons 'old (nth 2 line)) eol table)
                     (puthash (cons 'new (nth 3 line)) eol table))
                (?- (puthash (cons 'old (nth 2 line)) eol table))
                (?+ (puthash (cons 'new (nth 3 line)) eol table))))))))
    table))

(defun change-review-ui--file-entry (path)
  "Return the entry of the file at PATH in the index of the diff view, or nil."
  (cl-find-if (lambda (entry)
                (let ((file (nth 0 entry)))
                  (or (equal path (change-review-file-path file))
                      (equal path (change-review-file-old-path file)))))
              change-review-ui--index))

(defun change-review-ui--decorate-diff ()
  "Draw the threads that have a place in the diff view, under their lines.
Those about the change as a whole go before the first file; those about
a file with no line, or whose line is not in this version's diff, under
the first line of the file; those whose file is not in it at all, before
the first file too, saying so."
  (let* ((set change-review-ui--set)
         (version change-review-ui--version)
         (width (change-review-ui-current-width))
         (max-lines (change-review-ui-current-max-lines))
         (loose nil))
    (change-review-ui-clear-overlays)
    (change-review-ui--keep-scrolling)
    (dolist (thread (change-review-threads set (if (eq change-review-ui--filter 'all) nil
                                                 change-review-ui--filter)))
      (let* ((location (change-review-thread-location thread))
             (path (and location (change-review-location-file location)))
             (entry (and path (change-review-ui--file-entry path)))
             (placement (and location (change-review-location-line location)
                             (change-review-placement set thread version)))
             (args (list :view 'diff :placement placement :width width
                         :details change-review-ui--details
                         :fold (change-review-ui-thread-fold set thread)
                         :max-lines max-lines
                         :indent "    ")))
        (cond
         ((null location) (push (cons thread args) loose))
         ((null entry) (push (cons thread (plist-put (copy-sequence args) :unplaced t)) loose))
         (t
          (let* ((line (plist-get placement :line))
                 (side (or (plist-get placement :side) (change-review-location-side location)))
                 (pos (and line (gethash (cons side line) (nth 3 entry))))
                 (start-eol (save-excursion (goto-char (nth 1 entry)) (line-end-position))))
            (apply #'change-review-ui-add-thread-overlay set thread (or pos start-eol) args))))))
    (when loose
      (let ((overlay (make-overlay (point-min) (point-min))))
        (overlay-put overlay 'change-review-overlay t)
        (overlay-put overlay 'before-string
                     (concat (propertize "Threads about the change as a whole, or about files this version\
 does not have\n" 'face 'change-review-ui-header-face)
                             (mapconcat (lambda (entry)
                                          (apply #'change-review-ui-thread-string set (car entry)
                                                 (cl-loop for (k v) on (cdr entry) by #'cddr
                                                          unless (eq k :unplaced) append (list k v))))
                                        (nreverse loose) "\n")
                             "\n"))))))

(defun change-review-ui--draw-diff ()
  "Draw the diff view in the current buffer."
  (let* ((inhibit-read-only t)
         (set change-review-ui--set)
         (version change-review-ui--version)
         (line (line-number-at-pos))
         (column (current-column)))
    (erase-buffer)
    (setq change-review-ui--index nil)
    (let ((files (change-review-version-files version)))
      (if (null files)
          (insert (propertize (format "%s changes no file, or its files are not read.\n"
                                      (change-review-version-name version))
                              'face 'change-review-ui-meta-face))
        (dolist (file files)
          (let ((start (point)))
            (insert (or (change-review-file-patch file) ""))
            (unless (bolp) (insert "\n"))
            (push (list file start (point) (change-review-ui--index-file file start (point)))
                  change-review-ui--index)))))
    (setq change-review-ui--index (nreverse change-review-ui--index))
    (change-review-ui--decorate-diff)
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)
    (set-buffer-modified-p nil)
    (setq header-line-format
          (list " " (propertize "Review diff" 'face 'change-review-ui-header-face)
                " · " (change-review-ui--set-title set)
                " · " (change-review-version-name version)
                (let ((counts (change-review-thread-counts set)))
                  (format " · %d open, %d closed%s%s" (plist-get counts :open) (plist-get counts :closed)
                          (if (> (plist-get counts :unreviewed) 0)
                              (format ", %d to review" (plist-get counts :unreviewed)) "")
                          (if (> (plist-get counts :drafts) 0)
                              (format ", %d not sent" (plist-get counts :drafts)) "")))
                (if (eq change-review-ui--filter 'all) ""
                  (format " · showing %s" (change-review-ui--filter-phrase change-review-ui--filter)))))
    (force-mode-line-update)))

;;;###autoload
(defun change-review-open-diff (set &optional version)
  "Show VERSION of change set SET as a diff with its threads under the lines.
VERSION is a version, an id, a number or a label; by default the newest.
Return the buffer."
  (interactive (list (change-review-ui--read-set)))
  (let ((version (or (change-review-find-version set version) (change-review-latest-version set))))
    (unless version (user-error "This change has no version to show"))
    (setq change-review-ui-sets (cons set (delq set change-review-ui-sets)))
    (let ((buffer (change-review-ui--view-buffer
                   "diff" set 'change-review-diff-view-mode version
                   (format " (%s)" (change-review-version-name version)))))
      (with-current-buffer buffer
        (unless (derived-mode-p 'change-review-diff-view-mode)
          (change-review-diff-view-mode))
        (setq change-review-ui--set set
              change-review-ui--version version
              change-review-ui--filter (or change-review-ui--filter 'all)))
      ;; Shown before it is drawn, as the threads view is.
      (pop-to-buffer buffer)
      (with-current-buffer buffer
        (change-review-ui--draw-diff))
      buffer)))

(defun change-review-ui-show-threads ()
  "Show the threads view of the change set of this buffer."
  (interactive)
  (change-review-open-threads (change-review-ui--current-set)))

(defun change-review-ui-return ()
  "Under a thread, open it if it is one line, else show where it was made.
Where its comments were made, that is.  Elsewhere RET is what it is in
`diff-mode'."
  (interactive)
  (if (change-review-ui--overlay-thread-ids)
      (let ((set (change-review-ui--current-set))
            (thread (change-review-ui--thread-at-point)))
        (if (and thread (eq (change-review-ui-thread-fold set thread) 'collapsed))
            (change-review-ui-set-fold set thread 'expanded)
          (change-review-ui-show-origin)))
    (call-interactively (lookup-key diff-mode-map (kbd "RET")))))

(defun change-review-ui--next-thread-overlay (direction)
  "Move to the line with the next thread drawn under it, in DIRECTION 1 or -1."
  (let* ((positions (sort (delete-dups
                           (cl-loop for overlay in (overlays-in (point-min) (point-max))
                                    when (overlay-get overlay 'change-review-thread)
                                    collect (save-excursion (goto-char (overlay-start overlay))
                                                            (line-beginning-position))))
                          #'<))
         (here (line-beginning-position))
         (target (if (> direction 0)
                     (cl-find-if (lambda (pos) (> pos here)) positions)
                   (cl-find-if (lambda (pos) (< pos here)) (reverse positions)))))
    (unless target (user-error (if (> direction 0) "No more threads" "No earlier thread")))
    (goto-char target)
    (end-of-line)
    (let ((ids (change-review-ui--overlay-thread-ids)))
      (setq change-review-ui--chosen-thread (car ids)))))

;;;; Commenting on a line of the diff view

(defun change-review-ui--diff-position ()
  "Return (FILE SIDE LINE) for the line of the diff at point, or nil.
FILE is the `change-review-file'; the line is a line of its new version,
or of its old one for a removed line."
  (let* ((entry (cl-find-if (lambda (e) (and (>= (point) (nth 1 e)) (< (point) (nth 2 e))))
                            change-review-ui--index))
         (target (line-end-position))
         found)
    (when entry
      (maphash (lambda (key eol)
                 (when (= eol target)
                   ;; A context line is on both sides: the new one.
                   (when (or (null found) (eq (car key) 'new))
                     (setq found key))))
               (nth 3 entry))
      (when found
        (list (nth 0 entry) (car found) (cdr found))))))

(defun change-review-ui-comment-at-point ()
  "Comment on the line at point of the diff view, or on the region's lines.
The comment is a draft in a thread of its own, made against the version
shown, with the lines of the diff around it kept."
  (interactive)
  (let* ((set (change-review-ui--current-set))
         (version change-review-ui--version)
         (start (if (use-region-p) (region-beginning) (point)))
         (end (if (use-region-p) (region-end) (point)))
         (first (save-excursion (goto-char start) (change-review-ui--diff-position)))
         (last (save-excursion (goto-char end) (when (use-region-p) (skip-chars-backward "\n"))
                               (change-review-ui--diff-position))))
    (unless first (user-error "Point is not on a line of the diff"))
    (let* ((file (nth 0 first))
           (same (and last (eq file (nth 0 last)) (eq (nth 1 first) (nth 1 last))
                      (> (nth 2 last) (nth 2 first))))
           (location (change-review-diff-location file (nth 1 first) (nth 2 first)
                                                  (and same (nth 2 last)))))
      (deactivate-mark)
      (change-review-ui-read
       (format "Comment on %s:" (change-review-location-label location t)) ""
       (lambda (text)
         (if (string-blank-p text)
             (message "No comment")
           (change-review-comment set (string-trim text) :location location
                                  :revision (change-review-version-id version))))))))

;;;; Showing a thread

(defun change-review-ui--goto-thread (thread)
  "Move point to THREAD, drawn in this diff view, and highlight it."
  (when-let* ((overlay (cl-find-if (lambda (o) (equal (overlay-get o 'change-review-thread)
                                                      (change-review-thread-id thread)))
                                   (overlays-in (point-min) (point-max)))))
    (goto-char (overlay-start overlay))
    (setq change-review-ui--chosen-thread (change-review-thread-id thread))
    (recenter)
    (pulse-momentary-highlight-one-line (point))))

(defun change-review-ui--goto-location (location)
  "Move point to the line LOCATION names in this diff view, and highlight it."
  (when-let* ((entry (and (change-review-location-file location)
                          (change-review-ui--file-entry (change-review-location-file location))))
              (line (change-review-location-line location))
              (pos (gethash (cons (or (change-review-location-side location) 'new) line)
                            (nth 3 entry))))
    (goto-char pos)
    (recenter)
    (pulse-momentary-highlight-one-line (point))))

(cl-defmethod change-review-visit ((set change-review-set) target &optional version)
  (let* ((thread (cond ((change-review-thread-p target) target)
                       ((change-review-comment-p target)
                        (car (change-review-find-comment set (change-review-comment-id target))))
                       (t nil)))
         (buffer (change-review-open-diff set version)))
    (with-current-buffer buffer
      (cond (thread (change-review-ui--goto-thread thread))
            ((change-review-location-p target) (change-review-ui--goto-location target))))
    buffer))

;;;; Sending, and emailed patches

(cl-defmethod change-review-send ((set change-review-set))
  (if (cl-some (lambda (version) (plist-get (change-review-version-meta version) :series))
               (change-review-set-versions set))
      (change-review-mail-compose set)
    (user-error "These comments were not made on emailed patches: there is no mail to send")))

(defun change-review-ui-send ()
  "Send the drafts of the change set of this view.
For emailed patches that opens the replies, a mail for each patch with
comments, in `message-mode'; sending one marks its comments sent."
  (interactive)
  (change-review-send (change-review-ui--current-set)))

(defun change-review-ui--store-file (set)
  "Return the file that keeps the review SET, a set of emailed patches."
  (expand-file-name (concat (replace-regexp-in-string "[^A-Za-z0-9._-]" "_" (change-review-set-id set))
                            ".eld")
                    change-review-ui-directory))

;;;###autoload
(defun change-review-open-patches (file)
  "Review the patches in FILE: emailed, a mailbox of them, or a plain diff.
FILE may hold a series sent with `git send-email' and saved from a mail
program, `git format-patch' files put one after the other, a single
patch, or the output of `git diff' or `diff -u'.  The patches show as
a diff with a thread of comments under each line a comment is on
\(`change-review-open-diff'); c comments on a line, \\`C-c C-c' writes the
comments as the replies to send.  The threads are kept in a file of
`change-review-ui-directory', so opening the same patches again finds
them; a later version of the series, sent again, is a version of the
same change set."
  (interactive "fPatches (an mbox, a patch mail or a diff): ")
  (let* ((text (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert-file-contents-literally file)
                 (buffer-string)))
         (fresh (change-review-mail-make-set text))
         (store (change-review-ui--store-file fresh))
         (set (if (file-exists-p store)
                  (let ((kept (change-review-read-file store)))
                    (change-review-mail-import-patches kept text)
                    kept)
                (setf (change-review-set-file fresh) store)
                fresh)))
    (change-review-save set)
    (prog1 (change-review-open-diff set)
      (message "%s: %d %s; c comments on a line, T lists the threads, C-c C-c writes the replies"
               (change-review-ui--set-title set) (length (change-review-set-versions set))
               (if (= 1 (length (change-review-set-versions set))) "version" "versions")))))

(defun change-review-ui-import-reply (text)
  "Add the comments of a reply to the patches, TEXT, to the set of this view.
Interactively TEXT is the region, else a mail saved in a file.  A reply
mail -- headers and all -- is read as one: its sender is the author of
the comments, its date their time; a text that is only the reply, the
diff quoted with `> ' and the comments under it, is the user's.  Each
comment is a thread of its own, on the line it was under, or a reply in
the thread it answers; importing it again adds nothing."
  (interactive (list (if (use-region-p)
                         (buffer-substring-no-properties (region-beginning) (region-end))
                       (with-temp-buffer
                         (insert-file-contents (read-file-name "Reply mail: " nil nil t))
                         (buffer-string)))))
  (let* ((set (change-review-ui--current-set))
         (comments (if (plist-get (change-review-mail-parse-message text) :headers)
                       (change-review-mail-import-reply-message set text)
                     (change-review-mail-import-reply set text))))
    (message "%d %s from the reply" (length comments) (if (= 1 (length comments)) "comment" "comments"))
    comments))

;;;; Other views of a diff

(defvar change-review-ui-lines-mode-map (make-sparse-keymap)
  "Keys of a buffer that shows threads under its lines.")

;; Filled at top level, as the diff view's is.
(let ((map change-review-ui-lines-mode-map))
  (define-key map (kbd "r") #'change-review-ui-reply)
  (define-key map (kbd "x") #'change-review-ui-toggle-status)
  (define-key map (kbd "m") #'change-review-ui-toggle-reviewed)
  (define-key map (kbd "o") #'change-review-ui-follow-author)
  (define-key map (kbd "e") #'change-review-ui-edit-draft)
  (define-key map (kbd "k") #'change-review-ui-delete-draft)
  (define-key map (kbd "K") #'change-review-ui-delete-draft-thread)
  (define-key map (kbd "RET") #'change-review-ui-return)
  (define-key map (kbd "TAB") #'change-review-ui-cycle-fold))
(define-key change-review-ui-lines-mode-map (kbd "D") #'change-review-ui-show-source)

(define-minor-mode change-review-ui-lines-mode
  "Keys for the threads drawn under the lines of this buffer.
The buffer draws them with `change-review-ui-add-thread-overlay' and
has its change set in `change-review-ui--set' or through
`change-review-set-function'.

The mouse selects the text of the comments (`change-review-ui-mouse-select'):
\\<change-review-ui-lines-mode-map>\\[change-review-ui-quote-reply] replies to the comment with what is selected quoted, and
\\[kill-ring-save] copies it.

\\{change-review-ui-lines-mode-map}"
  :lighter nil :keymap change-review-ui-lines-mode-map :group 'change-review-ui)

;;;; The quote reply's key, and the key that copies

;; Bound here, not in the maps' `defvar's, so that a library loaded again
;; in a running Emacs gives the maps it has the key as well: a `defvar'
;; leaves the value a map already has as it is.
(define-key change-review-threads-mode-map (kbd "C-c >") #'change-review-ui-quote-reply)
(define-key change-review-diff-view-mode-map (kbd "C-c >") #'change-review-ui-quote-reply)
(define-key change-review-ui-lines-mode-map (kbd "C-c >") #'change-review-ui-quote-reply)
;; And what is selected with the mouse is copied by the key that copies.
(define-key change-review-diff-view-mode-map [remap kill-ring-save] #'change-review-ui-copy-selection)
(define-key change-review-ui-lines-mode-map [remap kill-ring-save] #'change-review-ui-copy-selection)

(provide 'change-review-ui)
;;; change-review-ui.el ends here
