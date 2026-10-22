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
;;   ┃ 3/3  Noah Huppert (you) · draft · ↳ re 1/3
;;   ┃      Then say so in a comment.
;;
;; Each comment says who wrote it (and what kind of author that is),
;; when, against which revision, whether it is a draft, and where it
;; sits in the thread: its number out of the thread's comments, and the
;; one it answers when that is not the one before.  The header says
;; whether the thread is open or closed, who closed it and when.  A
;; closed thread can be drawn as one line.
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
;; closed or all.  Point is on a comment, and the keys act on it: RET
;; shows where it was made (the file and line, the revision, and the
;; lines of the diff it was made on), r replies to it, x closes its
;; thread or opens it again, d shows it in the diff view, o follows an
;; agent's comment to the conversation it came from, e edits a draft, c
;; comments on the change as a whole.  n and p move between comments, N
;; and P between threads, f changes the filter.
;;
;; THE DIFF VIEW (`change-review-open-diff').  The files of a version as the
;; unified diff, with the threads under the lines they are about, drawn
;; by the same function.  c comments on the line at point, or on the
;; region; r, x, o and RET do what they do in the threads view for the
;; thread under point.  `change-review-visit' shows a thread in it.
;;
;; The views follow the set: whatever changes it, they draw again
;; (`change-review-changed-functions').  Other views of a diff, such as a
;; side-by-side comparison, draw the threads under their lines with
;; `change-review-ui-add-thread-overlay' and bind the same commands, in
;; `change-review-ui-lines-mode' or in a map of their own.

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
`open', `closed' or `all'."
  :type '(choice (const open) (const closed) (const all)))

(defcustom change-review-ui-collapse-closed-in-diff t
  "Whether a closed thread is drawn as one line, until it is opened.
In the diff view, and in any other view of the lines of a file, a
comparison in Ediff say.  \\`TAB' on the line opens it to its conversation,
and folds any thread to one line."
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

(defcustom change-review-ui-read-function #'change-review-ui-read-with-string-edit
  "The function that reads the text of a comment.
It is called with a prompt, the text to start from and a function to
call with the text read, which it calls when the user is done and not
at all when they give up.  The default edits the text in a buffer of
its own, where \\`C-c C-c' finishes and \\`C-c C-k' gives up."
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

(defun change-review-ui--wrap (line width)
  "Return LINE cut into pieces of WIDTH columns at most, at spaces if it can.
A line that fits, and the empty one, is a piece of its own."
  (if (<= (string-width line) width)
      (list line)
    (let (pieces)
      (while (> (string-width line) width)
        (let ((cut (change-review-ui--cut-point line width)))
          (push (string-trim-right (substring line 0 cut)) pieces)
          (setq line (string-trim-left (substring line cut)))))
      (push line pieces)
      (nreverse pieces))))

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

(defun change-review-ui--placement-note (placement)
  "Return what PLACEMENT, a thread's place now, says beyond the line, or nil."
  (when placement
    (let ((line (plist-get placement :line)) (was (plist-get placement :was)))
      (pcase (plist-get placement :status)
        ('moved (format "now line %s (was %s)" line was))
        ('changed (if line (format "line %s changed since" line) "its line changed since"))
        ('gone "its line is gone")))))

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
  '((:time ago) (:revision nil) (:links short) (:time none) (:marks nil) (:links none))
  "What the header of a comment gives up, the first the least missed.
Each step is added to the options `change-review-ui--comment-header'
draws with, while the line is wider than the room it has: the date goes
for how long ago, then the revision, the words of the links, the time,
the \"(you)\" and \"(agent)\", and last the links.")

(defun change-review-ui--comment-header (set thread comment prefix bar details options)
  "Return the first line of COMMENT of THREAD in SET, without its newline.
PREFIX and BAR start it; DETAILS non-nil says where the comment was made
is shown.  OPTIONS are those of `change-review-ui--comment-header-steps':
`:time' is `full', `ago' or `none', `:revision' and `:marks' are nil to
leave out the revision and the marks of who wrote it, `:links' is `full',
`short' or `none'."
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
         (links (if (eq links-mode 'none)
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
                         (lambda () (change-review-ui-toggle-details comment)))))))
    (propertize (concat prefix bar " " header links) 'change-review-comment-start t)))

(defun change-review-ui--comment-lines (set thread comment prefix width details)
  "Return the lines that draw COMMENT of THREAD in SET, a string each.
PREFIX starts every line, WIDTH is the width to wrap the text to and the
header to fit, and DETAILS non-nil adds where the comment was made.  Each
line ends in a newline, which carries the comment's properties as the
line does."
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
         (lines (list header)))
    (dolist (text (split-string (change-review-comment-body comment) "\n"))
      (dolist (piece (change-review-ui--wrap text (max 20 (- width (string-width body-prefix)))))
        (push (concat body-prefix piece) lines)))
    (when details
      (dolist (line (change-review-ui-origin-lines set thread comment))
        (push (concat body-prefix line) lines)))
    (mapcar (lambda (line)
              (propertize (concat line "\n") 'change-review-comment (change-review-comment-id comment)))
            (nreverse lines))))

(defconst change-review-ui--header-steps
  '((:status short) (:note nil) (:status who) (:status bare) (:count nil) (:buttons nil))
  "What the header of a thread gives up, the first the least missed.
Each step is added to the options `change-review-ui--thread-header' draws
with, while the line is wider than the room it has: when a closed thread
was closed gives the date for how long ago, the place the thread moved to
goes, then when it was closed, then who closed it, the count of comments
and last the buttons.")

(defconst change-review-ui--collapsed-header-steps
  '((:status short) (:buttons nil) (:note nil) (:count nil) (:status who) (:status bare))
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
`who' or `bare'; `:note', `:count' and `:buttons' are nil to leave out
where the thread is, how many comments it has and the buttons."
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
                            (change-review-ui--status-text set thread (plist-get options :status)))))
         (buttons (and (change-review-ui--opt options :buttons t)
                       (concat
                        (change-review-ui--button "[Reply]" "Reply to this thread"
                                                  (lambda () (change-review-ui-reply-to-thread set thread)))
                        " "
                        (change-review-ui--button (if open "[Close]" "[Reopen]")
                                                  (if open "Close this thread: it is done"
                                                    "Open this thread again")
                                                  (lambda () (change-review-ui-toggle-thread set thread)))
                        (if (eq view 'diff)
                            ""
                          (concat " " (change-review-ui--button
                                       "[Diff]" "Show this thread in the diff view"
                                       (lambda () (change-review-visit set thread)))))))))
    (propertize (concat (if fold
                            (change-review-ui--fold-gutter prefix (change-review-ui--fold-marker set thread fold))
                          prefix)
                        (propertize (if open "●" "✓")
                                    'face (if open 'change-review-ui-open-face
                                            'change-review-ui-closed-face))
                        " " (mapconcat #'identity parts
                                       (propertize " · " 'face 'change-review-ui-meta-face))
                        (if buttons (concat "   " buttons) ""))
                'change-review-thread-start t)))

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
         (text (change-review-ui--summary (change-review-comment-body (change-review-thread-root thread))))
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
                          (propertize (concat "“" words "”") 'face 'change-review-ui-meta-face)))
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

(cl-defun change-review-ui-thread-string (set thread &key (view 'threads) placement
                                              collapsed details width (indent "") fold max-lines)
  "Return THREAD of SET drawn as text, each line ending in a newline.
This is the one drawing of a thread, in the threads view and in the
diff view.  It has a header line -- the thread's mark and short id,
where it is, how many comments it has, whether it is open or closed --
and buttons, then each comment: the bar, the comment's place in the
thread (\"2/3\", and \"↳ re 1/3\" when it answers another than the one
before), who wrote it, when, against which revision, whether it is a
draft, and the text.  A comment whose author is an agent has a button
to the conversation it came from.

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
is the most lines the thread takes, the header and the comments: the
rest is cut, and a line says how many there are, a button that draws all
of it.  A thread whose DETAILS show is not cut."
  (let* ((width (or width (change-review-ui-current-width)))
         (collapsed (or collapsed (eq fold 'collapsed)))
         (fold (and fold (if collapsed 'collapsed fold)))
         (comments (change-review-thread-comments thread))
         (limit (and max-lines (eq fold 'expanded)
                     (not (or (eq details t)
                              (cl-some (lambda (comment) (member (change-review-comment-id comment) details))
                                       comments)))
                     (max 3 max-lines)))
         (lines
          (if collapsed
              (list (change-review-ui--collapsed-line set thread view placement indent width fold))
            (let ((all (cons (concat (change-review-ui--thread-header set thread view placement indent
                                                                       width fold)
                                     "\n")
                             (cl-loop for comment in comments
                                      append (change-review-ui--comment-lines
                                              set thread comment indent width
                                              (or (eq details t)
                                                  (member (change-review-comment-id comment) details)))))))
              ;; A drawing that cannot be folded -- the threads view's -- says nothing of it.
              (when fold
                (change-review-ui--note-trimmed set thread (and limit (> (length all) limit))))
              (if (and limit (> (length all) limit))
                  (append (seq-take all (1- limit))
                          (list (change-review-ui--more-row set thread indent
                                                            (- (length all) (1- limit)))))
                all)))))
    (propertize (apply #'concat lines)
                'change-review-thread (change-review-thread-id thread))))

(cl-defun change-review-ui-thread-line (set thread &key placement (width 80) (indent ""))
  "Return THREAD of SET as one line, for a list of threads.
Its mark, short id, line, the author and first words of its root, and
how many comments it has; each part drawn as the thread's header and
comments draw it.  PLACEMENT says where the thread is now.  The line
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
         (room (max 12 (- width (string-width head) 14)))
         (text (truncate-string-to-width
                (change-review-ui--summary (change-review-comment-body root)) room nil nil "…")))
    (propertize (concat head (propertize (concat "“" text "”") 'face 'change-review-ui-meta-face)
                        (if (> count 1)
                            (propertize (format " · %d comments" count) 'face 'change-review-ui-meta-face)
                          "")
                        (if (change-review-thread-drafts thread)
                            (propertize " · draft" 'face 'change-review-ui-draft-face) "")
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

(defun change-review-ui-origin-lines (set thread comment)
  "Return the lines that say where COMMENT of THREAD in SET was made.
They give its place -- file, line and side -- the revision, where the
thread is now when that is not where it was made, the lines of the diff
the comment was made on, the last of them the line it is about, and for
an agent's comment the session and the tool call."
  (let* ((location (or (change-review-comment-location comment)
                       (change-review-thread-location thread)))
         (revision (change-review-comment-revision comment))
         (author (change-review-comment-author comment))
         (placement (change-review-placement set thread))
         (meta 'change-review-ui-meta-face)
         lines)
    (push (propertize
           (concat "made at "
                   (if location (change-review-location-label location t) "the change as a whole")
                   (if revision (format " · revision %s" (change-review-revision-name set revision)) "")
                   (if (and revision (not (equal (change-review-short-revision revision)
                                                 (change-review-revision-name set revision))))
                       (format " (%s)" (change-review-short-revision revision))
                     ""))
           'face meta)
          lines)
    (when-let* ((note (change-review-ui--placement-note placement)))
      (push (propertize (concat "now: " note) 'face meta) lines))
    (when-let* ((excerpt (and location (change-review-location-excerpt location))))
      (let ((rows (split-string excerpt "\n")))
        (while rows
          (let ((row (pop rows)))
            (push (concat (propertize "│ " 'face meta) (change-review-ui--excerpt-line row (null rows)))
                  lines)))))
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

(defun change-review-ui-add-thread-overlay (set thread position &rest args)
  "Draw THREAD of SET under the line that ends at POSITION; return the overlay.
ARGS are those of `change-review-ui-thread-string', which draws it.  The
overlay carries the thread's id, so that the commands of this library
find the thread at point.  With the key :before non-nil in ARGS the
text goes before POSITION instead, on lines of its own.  A view of a
diff other than the ones here draws its threads with this."
  (let* ((before (plist-get args :before))
         (args (cl-loop for (key value) on args by #'cddr
                        unless (eq key :before) append (list key value)))
         (text (apply #'change-review-ui-thread-string set thread args))
         (overlay (make-overlay position position nil t nil)))
    (overlay-put overlay 'change-review-overlay t)
    (overlay-put overlay 'change-review-thread (change-review-thread-id thread))
    (if before
        (overlay-put overlay 'before-string text)
      ;; The buffer's own newline ends the last line.
      (overlay-put overlay 'after-string (concat "\n" (substring text 0 -1))))
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

;;;; Reading a comment

(defun change-review-ui-read-with-string-edit (prompt initial callback)
  "Read a comment in a buffer of its own: `change-review-ui-read-function'.
PROMPT says what for, INITIAL is the text to start from and CALLBACK
gets the text when the user finishes it with \\`C-c C-c'."
  (require 'string-edit)
  (string-edit (concat prompt "  C-c C-c saves it as a draft, C-c C-k cancels")
               (or initial "") callback :abort-callback #'ignore))

(defun change-review-ui-read (prompt initial callback)
  "Read a comment as `change-review-ui-read-function' does; see there."
  (funcall change-review-ui-read-function prompt initial callback))

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

(defun change-review-ui-reply-to-comment (set thread comment)
  "Read a reply to COMMENT of THREAD in SET and add it as a draft."
  (change-review-ui-read
   (format "Reply to %s:" (change-review-ui--comment-label set thread comment)) ""
   (lambda (text)
     (if (string-blank-p text)
         (message "No reply")
       (change-review-reply set comment (string-trim text))))))

(defun change-review-ui-reply-to-thread (set thread)
  "Read a reply to the last comment of THREAD in SET and add it as a draft."
  (change-review-ui-reply-to-comment set thread (change-review-thread-last-comment thread)))

(defun change-review-ui-reply ()
  "Reply to the comment at point, as a draft.
In the diff view, where a thread is drawn under its line and has no
comment to point at, to the thread's last comment."
  (interactive)
  (pcase-let ((`(,set ,thread ,comment) (change-review-ui--target)))
    (change-review-ui-reply-to-comment set thread comment)))

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

(defun change-review-ui-edit-draft ()
  "Edit the comment at point, which has to be a draft."
  (interactive)
  (pcase-let ((`(,set ,thread ,comment) (change-review-ui--target t)))
    (unless (change-review-comment-draft-p comment)
      (user-error "That comment was sent already"))
    (change-review-ui-read
     (format "Edit %s:" (change-review-ui--comment-label set thread comment))
     (change-review-comment-body comment)
     (lambda (text)
       (if (string-blank-p text)
           (message "No change")
         (change-review-edit set comment (string-trim text)))))))

(defun change-review-ui-delete-draft ()
  "Delete the comment at point, which has to be a draft."
  (interactive)
  (pcase-let ((`(,set ,_ ,comment) (change-review-ui--target t)))
    (unless (change-review-comment-draft-p comment)
      (user-error "That comment was sent already"))
    (when (y-or-n-p "Delete this draft? ")
      (change-review-delete set comment))))

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

(defun change-review-ui-default-fold (thread)
  "Return how THREAD is folded before anyone folded it.
A closed thread is `collapsed', one line, unless
`change-review-ui-collapse-closed-in-diff' says not; any other is `expanded'."
  (if (and change-review-ui-collapse-closed-in-diff (not (change-review-thread-open-p thread)))
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
      (change-review-ui-default-fold thread))))

(defun change-review-ui-set-fold (set thread fold)
  "Fold THREAD of SET to FOLD, `collapsed', `expanded' or `full'.
The views of SET are drawn again."
  (unless (memq fold '(collapsed expanded full))
    (signal 'change-review-error (list (format "Not a way to fold a thread: %S" fold))))
  (let ((table (or (gethash set change-review-ui--folds)
                   (puthash set (make-hash-table :test 'equal) change-review-ui--folds))))
    (puthash (change-review-thread-id thread) (cons (change-review-thread-status thread) fold) table))
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
That is the file and line, the revision, and the lines of the diff it
was made on.  In the diff view it is the comments of the thread under
point."
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
The comment or the thread under it, and the line within that."
  (let ((comment (get-text-property (point) 'change-review-comment))
        (thread (get-text-property (point) 'change-review-thread))
        (file (get-text-property (point) 'change-review-file)))
    (list comment thread file
          (- (line-number-at-pos) (line-number-at-pos
                                   (or (and comment (change-review-ui--property-start 'change-review-comment))
                                       (and thread (change-review-ui--property-start 'change-review-thread))
                                       (and file (change-review-ui--property-start 'change-review-file))
                                       (point-min))))
          (current-column))))

(defun change-review-ui--property-start (property)
  "Return where the run of text at point with the same PROPERTY starts."
  (let ((value (get-text-property (point) property)))
    (save-excursion
      (while (and (> (point) (point-min))
                  (equal value (get-text-property (1- (point)) property)))
        (goto-char (previous-single-property-change (point) property nil (point-min))))
      (point))))

(defun change-review-ui--goto-anchor (anchor)
  "Put point where ANCHOR, from `change-review-ui--anchor', says."
  (pcase-let ((`(,comment ,thread ,file ,offset ,column) anchor))
    (let ((found (or (and comment (change-review-ui--find-property 'change-review-comment comment))
                     (and thread (change-review-ui--find-property 'change-review-thread thread))
                     (and file (change-review-ui--find-property 'change-review-file file)))))
      (when found
        (goto-char found)
        (forward-line (or offset 0))
        (move-to-column (or column 0))))))

(defun change-review-ui--find-property (property value)
  "Return where the first text with PROPERTY equal to VALUE starts, or nil."
  (let ((pos (point-min)) found)
    (while (and (not found) pos (< pos (point-max)))
      (if (equal (get-text-property pos property) value)
          (setq found pos)
        (setq pos (next-single-property-change pos property nil (point-max)))))
    found))

;;;; The threads view

(defvar change-review-threads-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "n") #'change-review-ui-next-comment)
    (define-key map (kbd "p") #'change-review-ui-previous-comment)
    (define-key map (kbd "N") #'change-review-ui-next-thread)
    (define-key map (kbd "P") #'change-review-ui-previous-thread)
    (define-key map (kbd "RET") #'change-review-ui-show-origin)
    (define-key map (kbd "TAB") #'change-review-ui-show-origin)
    (define-key map (kbd "r") #'change-review-ui-reply)
    (define-key map (kbd "x") #'change-review-ui-toggle-status)
    (define-key map (kbd "s") #'change-review-ui-set-status)
    (define-key map (kbd "d") #'change-review-ui-show-in-diff)
    (define-key map (kbd "o") #'change-review-ui-follow-author)
    (define-key map (kbd "e") #'change-review-ui-edit-draft)
    (define-key map (kbd "k") #'change-review-ui-delete-draft)
    (define-key map (kbd "c") #'change-review-ui-comment-on-change)
    (define-key map (kbd "f") #'change-review-ui-cycle-filter)
    (define-key map (kbd "F") #'change-review-ui-set-filter)
    (define-key map (kbd "g") #'change-review-ui-redraw)
    (define-key map (kbd "I") #'change-review-ui-import-reply)
    (define-key map (kbd "C-c C-c") #'change-review-ui-send)
    map)
  "Keys of the threads view.")

(define-derived-mode change-review-threads-mode special-mode "Review-Threads"
  "The threads of a change set, grouped by file.

Point is on a comment; the keys act on it:
\\<change-review-threads-mode-map>
\\[change-review-ui-next-comment] and \\[change-review-ui-previous-comment] move between comments,
\\[change-review-ui-next-thread] and \\[change-review-ui-previous-thread] between threads.
\\[change-review-ui-show-origin] shows where the comment was made, hides it again.
\\[change-review-ui-reply] replies to it, as a draft.
\\[change-review-ui-toggle-status] closes its thread or opens it again.
\\[change-review-ui-set-status] sets the status by name.
\\[change-review-ui-show-in-diff] shows it in the diff view.
\\[change-review-ui-follow-author] follows an agent's comment to its conversation.
\\[change-review-ui-edit-draft] edits a draft, \\[change-review-ui-delete-draft] deletes it.
\\[change-review-ui-comment-on-change] comments on the change as a whole.
\\[change-review-ui-send] sends the drafts, \\[change-review-ui-import-reply] adds the comments of a reply.
\\[change-review-ui-cycle-filter] changes which threads show.
\\[change-review-ui-redraw] draws the view again.

\\{change-review-threads-mode-map}"
  (setq-local truncate-lines nil)
  (setq change-review-ui--redraw-function #'change-review-ui--draw-threads))

(defun change-review-ui--filter-button (set label filter current)
  "Return a button that shows the threads of FILTER, labelled LABEL, of SET.
The one for CURRENT, the filter in force, is marked instead."
  (let* ((counts (change-review-thread-counts set))
         (number (pcase filter
                   ('open (plist-get counts :open))
                   ('closed (plist-get counts :closed))
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

(defun change-review-ui--heading (set)
  "Return the first lines of the threads view of SET."
  (let* ((counts (change-review-thread-counts set))
         (version (change-review-latest-version set))
         (filter change-review-ui--filter))
    (concat
     (propertize "Review of " 'face 'change-review-ui-header-face)
     (propertize (change-review-ui--set-title set) 'face 'change-review-ui-header-face)
     (if version
         (propertize (format "   %s of %d" (change-review-version-name version)
                             (length (change-review-set-versions set)))
                     'face 'change-review-ui-meta-face)
       "")
     "\n"
     (propertize "Threads  " 'face 'change-review-ui-header-face)
     (mapconcat (lambda (spec)
                  (change-review-ui--filter-button set (car spec) (cdr spec) filter))
                '(("open" . open) ("closed" . closed) ("all" . all)) " ")
     (if (> (plist-get counts :drafts) 0)
         (propertize (format "     %d %s not sent" (plist-get counts :drafts)
                             (if (= 1 (plist-get counts :drafts)) "draft" "drafts"))
                     'face 'change-review-ui-draft-face)
       "")
     "\n"
     (propertize (substitute-command-keys
                  "\\<change-review-threads-mode-map>\
\\[change-review-ui-next-comment]/\\[change-review-ui-previous-comment] comments  \
\\[change-review-ui-next-thread]/\\[change-review-ui-previous-thread] threads  \
\\[change-review-ui-show-origin] where  \\[change-review-ui-reply] reply  \
\\[change-review-ui-toggle-status] close/open  \\[change-review-ui-show-in-diff] diff  \
\\[change-review-ui-cycle-filter] filter  \\[quit-window] quit")
                 'face 'change-review-ui-meta-face)
     "\n\n")))

(defun change-review-ui--draw-threads ()
  "Draw the threads view in the current buffer."
  (let* ((inhibit-read-only t)
         (set change-review-ui--set)
         (anchor (change-review-ui--anchor))
         (groups (change-review-threads-by-file set change-review-ui--filter))
         (width (change-review-ui-current-width)))
    (erase-buffer)
    (insert (change-review-ui--heading set))
    (if (null groups)
        (insert (propertize
                 (pcase change-review-ui--filter
                   ('open "No open threads.  f shows the closed ones.\n")
                   ('closed "No closed threads.  f shows the open ones.\n")
                   (_ "No threads yet.  c comments on the change; in the diff view, c comments on a line.\n"))
                 'face 'change-review-ui-meta-face))
      (dolist (group groups)
        (let* ((file (car group)) (threads (cdr group))
               (open (cl-count-if #'change-review-thread-open-p threads)))
          (insert (propertize
                   (concat (propertize (if file (concat "▾ " file) "▾ The change as a whole")
                                       'face 'change-review-ui-file-face)
                           (propertize (format "   %d %s%s" (length threads)
                                               (if (= 1 (length threads)) "thread" "threads")
                                               (if (eq change-review-ui--filter 'all)
                                                   (format " · %d open" open) ""))
                                       'face 'change-review-ui-meta-face)
                           "\n")
                   'change-review-file (or file :change)))
          (dolist (thread threads)
            (insert (change-review-ui-thread-string
                     set thread :view 'threads
                     :placement (change-review-placement set thread)
                     :details change-review-ui--details :width width :indent "  ")
                    "\n")))))
    (goto-char (point-min))
    (change-review-ui--goto-anchor anchor)
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
                                         change-review-ui-default-filter))
      (change-review-ui--draw-threads))
    (pop-to-buffer buffer)
    buffer))

(defun change-review-ui-set-filter (filter)
  "Show the threads of FILTER: `open', `closed' or `all'."
  (interactive (list (intern (completing-read "Show threads: " '("open" "closed" "all") nil t))))
  (setq change-review-ui--filter filter)
  (change-review-ui-redraw))

(defun change-review-ui-cycle-filter ()
  "Change which threads show: open, then closed, then all."
  (interactive)
  (change-review-ui-set-filter (pcase change-review-ui--filter
                                 ('open 'closed) ('closed 'all) (_ 'open))))

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
  (define-key map (kbd "o") #'change-review-ui-follow-author)
  (define-key map (kbd "e") #'change-review-ui-edit-draft)
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
\\[change-review-ui-toggle-status] closes it or opens it again.
\\[change-review-ui-return] opens it if it is one line, else shows where its comments were made.
\\[change-review-ui-cycle-fold] folds it: one line, its conversation, all of it.
\\[change-review-ui-follow-author] follows an agent's comment to its conversation.
\\[change-review-ui-next-thread] and \\[change-review-ui-previous-thread] move between threads.
\\[change-review-ui-show-threads] lists them by file.
\\[change-review-ui-send] sends the drafts, \\[change-review-ui-import-reply] adds the comments of a reply.

The keys of `diff-mode' stay: n and p between hunks.

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
                  (format " · %d open, %d closed%s" (plist-get counts :open) (plist-get counts :closed)
                          (if (> (plist-get counts :drafts) 0)
                              (format ", %d not sent" (plist-get counts :drafts)) "")))
                (if (eq change-review-ui--filter 'all) ""
                  (format " · showing %s threads" change-review-ui--filter))))
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
              change-review-ui--filter (or change-review-ui--filter 'all))
        (change-review-ui--draw-diff))
      (pop-to-buffer buffer)
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

(cl-defmethod change-review-visit ((set change-review-set) target &optional version)
  (let* ((thread (cond ((change-review-thread-p target) target)
                       ((change-review-comment-p target)
                        (car (change-review-find-comment set (change-review-comment-id target))))
                       (t nil)))
         (buffer (change-review-open-diff set version)))
    (with-current-buffer buffer
      (when thread
        (change-review-ui--goto-thread thread)))
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
  (define-key map (kbd "o") #'change-review-ui-follow-author)
  (define-key map (kbd "e") #'change-review-ui-edit-draft)
  (define-key map (kbd "RET") #'change-review-ui-return)
  (define-key map (kbd "TAB") #'change-review-ui-cycle-fold))

(define-minor-mode change-review-ui-lines-mode
  "Keys for the threads drawn under the lines of this buffer.
The buffer draws them with `change-review-ui-add-thread-overlay' and
has its change set in `change-review-ui--set' or through
`change-review-set-function'.

\\{change-review-ui-lines-mode-map}"
  :lighter nil :keymap change-review-ui-lines-mode-map :group 'change-review-ui)

(provide 'change-review-ui)
;;; change-review-ui.el ends here
