;;; change-review-diff.el --- Unified diffs for change-review  -*- lexical-binding: t; -*-

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

;; What change-review knows of a diff, with no git and no process: it
;; all works from the text of a unified diff.
;;
;; READING A DIFF.  `change-review-diff-parse' cuts a diff into the files
;; it changes, as `change-review-file's: what `git diff' and `git
;; format-patch' write, with their renames, copies, modes and binary
;; files, and what `diff -u' and `diff -ru' write.  Anything before the
;; first file, such as the text of an email, is left out, and so is the
;; signature format-patch ends with.  A hunk is read by the numbers of
;; its header, as git reads it, so a deleted line that reads "--- x"
;; is a line, not a file.  `change-review-diff-hunks' gives the hunks of
;; a file, each line with its number before the change and after it.
;;
;; THE LINES A COMMENT IS ABOUT.  A comment on a line keeps the part of
;; the diff around the line, its EXCERPT: a hunk header, then the lines,
;; each starting with " ", "+" or "-", the last one the line commented
;; on.  `change-review-diff-excerpt' cuts it from a file, the change the
;; line is in with a few lines before it (`change-review-diff-context-lines'),
;; and `change-review-diff-location' makes the `change-review-location'
;; that holds it.  The excerpt is what the comment was about when the
;; version it was made on is gone, and what lets the line be found in
;; another.  It reads back as lines with their numbers
;; (`change-review-diff-excerpt-lines') and quotes as a mail reply
;; does (`change-review-diff-quote').
;;
;; FINDING A LINE IN ANOTHER VERSION.  A line commented on in one
;; version is somewhere in the next.  `change-review-diff-relocate' looks
;; for it in the diff of a file of another version, by the lines of its
;; excerpt, and says whether it is where it was (`same'), elsewhere
;; (`moved'), edited (`changed'), gone or not to be told.  Where the full
;; text of the file is at hand, `change-review-diff-place' does it with
;; the lines of the file and how the file changed since: a line is
;; carried through the ranges of a diff (`change-review-diff-ranges',
;; `change-review-diff-map-line') or found by what it says
;; (`change-review-diff-find-line').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'change-review)

(defgroup change-review-diff nil
  "Unified diffs in change-review."
  :group 'change-review :prefix "change-review-diff-")

(defcustom change-review-diff-context-lines 3
  "How many lines before a change the excerpt of a comment on it starts.
The excerpt of a line holds the change the line is in, up to the line,
after this many lines at most.  It never starts in the middle of another
change."
  :type 'natnum)

(defcustom change-review-diff-excerpt-limit 60
  "The most lines an excerpt holds, header apart.
A longer one keeps its end, where the line commented on is."
  :type 'natnum)

;;;; Lines and hunk headers

(defconst change-review-diff--hunk-regexp
  "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@\\(.*\\)"
  "A hunk's header, with its line numbers and its heading.
Its groups: where the hunk starts before the change and how many lines
it has there, the same after the change, and the heading git gives it,
its leading space included.")

(defun change-review-diff--side (side)
  "Return SIDE, `old' or `new' or one of the keywords of those, as a symbol."
  (if (memq side '(old :old)) 'old 'new))

(defun change-review-diff--chomp (line)
  "Return LINE without a carriage return at its end."
  (if (string-suffix-p "\r" line) (substring line 0 -1) line))

(defun change-review-diff--text-lines (text)
  "Return the lines of TEXT as a vector; a last newline starts no line."
  (let ((lines (split-string text "\n")))
    (when (equal (car (last lines)) "")
      (setq lines (butlast lines)))
    (vconcat lines)))

(defun change-review-diff--join (lines first last)
  "Return the lines FIRST to LAST of the vector LINES as text, each ended."
  (let ((out nil))
    (cl-loop for i from first to last
             do (push (aref lines i) out) (push "\n" out))
    (apply #'concat (nreverse out))))

(defun change-review-diff--hunk-header-p (line)
  "Return non-nil when LINE is the header of a hunk."
  (string-match-p change-review-diff--hunk-regexp line))

(defun change-review-diff--read-hunk (lines i)
  "Read the hunk whose header is line I of LINES, a vector of lines.
Return (HUNK . NEXT): the hunk as `change-review-diff-hunks' describes
it and the index of the line after it, or nil when line I is no header.
The lines of the hunk are as many as the numbers of its header say; the
\"\\ No newline\" marker belongs to the line it follows."
  (let ((header (aref lines i)))
    (when (string-match change-review-diff--hunk-regexp header)
      (let* ((old-start (string-to-number (match-string 1 header)))
             (old-count (if (match-string 2 header) (string-to-number (match-string 2 header)) 1))
             (new-start (string-to-number (match-string 3 header)))
             (new-count (if (match-string 4 header) (string-to-number (match-string 4 header)) 1))
             (heading (match-string 5 header))
             ;; A side with no lines counts from the line before: git's
             ;; "-0,0" for a file that is new.
             (old (+ old-start (if (equal (match-string 2 header) "0") 1 0)))
             (new (+ new-start (if (equal (match-string 4 header) "0") 1 0)))
             (old-left old-count)
             (new-left new-count)
             (n (length lines))
             (j (1+ i))
             (out nil)
             (done nil))
        (while (and (not done) (< j n))
          (let* ((text (aref lines j))
                 (kind (if (string-empty-p text) nil (aref text 0))))
            (cond
             ((eq kind ?\\)
              (push (list ?\\ (substring text 1) old new) out)
              (cl-incf j))
             ((and (<= old-left 0) (<= new-left 0)) (setq done t))
             ((and (or (null kind) (eq kind ?\s)) (> old-left 0) (> new-left 0))
              ;; A context line a mailer stripped the space of is empty.
              (push (list ?\s (if kind (substring text 1) "") old new) out)
              (cl-incf old) (cl-incf new) (cl-decf old-left) (cl-decf new-left) (cl-incf j))
             ((and (eq kind ?-) (> old-left 0))
              (push (list ?- (substring text 1) old new) out)
              (cl-incf old) (cl-decf old-left) (cl-incf j))
             ((and (eq kind ?+) (> new-left 0))
              (push (list ?+ (substring text 1) old new) out)
              (cl-incf new) (cl-decf new-left) (cl-incf j))
             (t (setq done t)))))
        (cons (list :header header :heading heading
                    :old-start old-start :old-count old-count
                    :new-start new-start :new-count new-count
                    :lines (nreverse out))
              j)))))

;;;; Cutting a diff into files

(defconst change-review-diff--git-header-regexp
  (concat "\\`\\(?:index \\|old mode \\|new mode \\|deleted file mode \\|new file mode \\|"
          "similarity index \\|dissimilarity index \\|rename from \\|rename to \\|"
          "copy from \\|copy to \\|--- \\|\\+\\+\\+ \\|Binary files \\)")
  "The lines that follow a `diff --git' line, before the first hunk.")

(defconst change-review-diff--plain-header-regexp
  "\\`\\(?:====\\|--- \\|\\+\\+\\+ \\|Binary files \\)"
  "The lines after the first of the head of a file of a plain diff.
The first, a `diff' or `Index:' line, a `---' line or the line that
says the files differ, starts the file; a `diff' line after it starts
the next.")

(defconst change-review-diff--binary-payload-regexp
  "\\`\\(?:\\|literal [0-9]+\\|delta [0-9]+\\|[A-Za-z][0-9A-Za-z!#$%&()*+;<=>?@^_`{|}~-]*\\)\\'"
  "A line of the data of a `GIT binary patch'.")

(defun change-review-diff--part-kind (lines i)
  "Return how a file of a diff starts at line I of LINES, or nil.
It is `git' for a `diff --git' line and `plain' for the head of a file
of a diff that git did not write: its `---' and `+++' lines, with the
`diff' or `Index:' line before them if there is one."
  (let ((line (aref lines i))
        (n (length lines)))
    (cl-flet ((heads-hunk-p (k)
                (and (< (+ k 2) n)
                     (string-prefix-p "--- " (aref lines k))
                     (string-prefix-p "+++ " (aref lines (1+ k)))
                     (change-review-diff--hunk-header-p (aref lines (+ k 2))))))
      (cond
       ((string-prefix-p "diff --git " line) 'git)
       ((heads-hunk-p i) 'plain)
       ((or (string-prefix-p "diff " line) (string-prefix-p "Index: " line))
        (let ((k (1+ i)) (found nil) (looking t))
          (while (and looking (< k n) (<= k (+ i 3)))
            (let ((next (aref lines k)))
              (cond ((string-prefix-p "====" next) (cl-incf k))
                    ((heads-hunk-p k) (setq found 'plain looking nil))
                    ((string-prefix-p "Binary files " next) (setq found 'plain looking nil))
                    (t (setq looking nil)))))
          found))
       ((and (string-prefix-p "Binary files " line)
             (string-suffix-p " differ" (change-review-diff--chomp line)))
        'plain)))))

(defun change-review-diff--read-part (lines i kind)
  "Read the file of KIND whose first line is line I of LINES.
Return (PART . NEXT): PART is a plist, :text the lines of the file from
its first to its last, :added and :deleted the lines of its hunks that
are, :binary non-nil for a file with no text diff, and NEXT the index of
the line to go on from."
  (let* ((n (length lines))
         (j (1+ i))
         (last i)
         (binary (and (string-prefix-p "Binary files " (aref lines i)) t))
         (added 0)
         (deleted 0)
         (regexp (if (eq kind 'git)
                     change-review-diff--git-header-regexp
                   change-review-diff--plain-header-regexp)))
    (while (and (< j n) (string-match-p regexp (aref lines j)))
      (when (string-prefix-p "Binary files " (aref lines j)) (setq binary t))
      (setq last j j (1+ j)))
    (when (and (< j n) (equal (change-review-diff--chomp (aref lines j)) "GIT binary patch"))
      (setq binary t last j j (1+ j))
      (while (and (< j n) (string-match-p change-review-diff--binary-payload-regexp
                                          (change-review-diff--chomp (aref lines j))))
        ;; Blank lines between the data are part of it, those after it not.
        (unless (string-empty-p (change-review-diff--chomp (aref lines j))) (setq last j))
        (cl-incf j)))
    (while (and (< j n) (change-review-diff--hunk-header-p (aref lines j)))
      (let ((read (change-review-diff--read-hunk lines j)))
        (dolist (line (plist-get (car read) :lines))
          (pcase (car line)
            (?+ (cl-incf added))
            (?- (cl-incf deleted))))
        (setq j (cdr read) last (1- j))))
    (cons (list :text (change-review-diff--join lines i last)
                :added added :deleted deleted :binary binary)
          j)))

(defun change-review-diff--scan (text)
  "Return the files of TEXT, a unified diff, as a list of (KIND . PART).
KIND and PART are as `change-review-diff--read-part' gives them."
  (let* ((lines (change-review-diff--text-lines text))
         (n (length lines))
         (i 0)
         (parts nil))
    (while (< i n)
      (if-let* ((kind (change-review-diff--part-kind lines i)))
          (let ((read (change-review-diff--read-part lines i kind)))
            (push (cons kind (car read)) parts)
            (setq i (max (cdr read) (1+ i))))
        (cl-incf i)))
    (nreverse parts)))

(defun change-review-diff-split (text)
  "Return the files of the diff TEXT as a list of strings, in order.
Each string is one file's part of the diff, from its first line on
\(its `diff --git' line, for a diff git wrote) and ended by a newline.
What lies between two files, or before the first, is not in any."
  (mapcar (lambda (part) (plist-get (cdr part) :text))
          (change-review-diff--scan text)))

;;;; Reading the head of a file

(defun change-review-diff--quote-end (text)
  "Return the index after the closing quote of the string TEXT starts with."
  (let ((i 1) (n (length text)) (end nil))
    (while (and (not end) (< i n))
      (pcase (aref text i)
        (?\\ (cl-incf i 2))
        (?\" (setq end (1+ i)))
        (_ (cl-incf i))))
    end))

(defun change-review-diff--unquote (text)
  "Return the path TEXT as git wrote it, with the quoting taken off.
Git quotes a path with characters it will not write as they are --
\"a/\\303\\251.txt\" for a/é.txt -- in double quotes, with C escapes and
the bytes of UTF-8 in octal.  A path that is not quoted is returned as
it is."
  (if (not (and (> (length text) 1) (eq (aref text 0) ?\")
                (eq (aref text (1- (length text))) ?\")))
      text
    (let ((bytes nil) (i 1) (end (1- (length text))))
      (while (< i end)
        (let ((c (aref text i)))
          (cond
           ((and (eq c ?\\) (< (1+ i) end))
            (let ((next (aref text (1+ i))))
              (if (<= ?0 next ?7)
                  (let ((j (1+ i)) (value 0) (digits 0))
                    (while (and (< j end) (< digits 3) (<= ?0 (aref text j) ?7))
                      (setq value (+ (* value 8) (- (aref text j) ?0))
                            j (1+ j) digits (1+ digits)))
                    (push (logand value 255) bytes)
                    (setq i j))
                (push (pcase next (?t 9) (?n 10) (?r 13) (?a 7) (?b 8) (?f 12) (?v 11) (_ next))
                      bytes)
                (setq i (+ i 2)))))
           ((< c 128) (push c bytes) (setq i (1+ i)))
           (t (dolist (byte (append (encode-coding-char c 'utf-8) nil))
                (push byte bytes))
              (setq i (1+ i))))))
      (decode-coding-string (apply #'unibyte-string (nreverse bytes)) 'utf-8))))

(defun change-review-diff--git-line-paths (rest)
  "Return (A . B), the two paths of a `diff --git' line, REST being its end.
REST is the text after \"diff --git \".  The paths are told apart where
git leaves it to be worked out: by quotes, or, when neither is quoted,
because a path that was not renamed is twice the same.  Nil when REST
does not give two."
  (let ((rest (change-review-diff--chomp rest)))
    (cond
     ((string-prefix-p "\"" rest)
      (when-let* ((end (change-review-diff--quote-end rest)))
        (cons (change-review-diff--unquote (substring rest 0 end))
              (change-review-diff--unquote (string-trim-left (substring rest end))))))
     ((string-suffix-p "\"" rest)
      (when-let* ((pos (string-search " \"" rest)))
        (cons (substring rest 0 pos)
              (change-review-diff--unquote (substring rest (1+ pos))))))
     (t
      (let ((len (length rest)) (result nil))
        ;; With a prefix of two characters on each path ("a/", "b/"), then
        ;; with none: the halves around the middle space are the same path.
        (dolist (k '(2 0))
          (unless result
            (let ((half (- len 1 (* 2 k))))
              (when (and (> half 0) (cl-evenp half))
                (let ((cut (+ k (/ half 2))))
                  (when (eq (aref rest cut) ?\s)
                    (let ((a (substring rest 0 cut)) (b (substring rest (1+ cut))))
                      (when (equal (substring a k) (substring b k))
                        (setq result (cons a b))))))))))
        (or result
            (when (string-match "\\`\\(.+?\\) \\([a-z]/.*\\)\\'" rest)
              (cons (match-string 1 rest) (match-string 2 rest)))))))))

(defun change-review-diff--prefixes (pair)
  "Return the prefixes (A . B) the paths of PAIR start with, or nil.
Git writes \"a/\" before the path before the change and \"b/\" before the
one after it; with `diff.mnemonicPrefix' they are other letters.  Paths
that start with the same letter have no prefix."
  (when (and pair (car pair) (cdr pair)
             (string-match "\\`\\([a-z]\\)/" (car pair)))
    (let ((a (match-string 1 (car pair))))
      (when (and (string-match "\\`\\([a-z]\\)/" (cdr pair))
                 (not (equal a (match-string 1 (cdr pair)))))
        (cons (concat a "/") (concat (match-string 1 (cdr pair)) "/"))))))

(defun change-review-diff--strip (path prefix)
  "Return PATH without PREFIX at its start, if it has it."
  (if (and path prefix (string-prefix-p prefix path))
      (substring path (length prefix))
    path))

(defun change-review-diff--header-path (text prefix)
  "Return the path the `---' or `+++' line with TEXT after it names.
PREFIX is taken off its start.  Nil for no line and for /dev/null."
  (when text
    (let ((path (change-review-diff--unquote
                 (car (split-string (change-review-diff--chomp text) "\t")))))
      (unless (member path '("/dev/null" ""))
        (change-review-diff--strip path prefix)))))

(defun change-review-diff--plain-paths (old new)
  "Return (PATH . OLD-PATH) for a plain diff of the file OLD against NEW.
The path is what the two names have at their ends in common, so that
`diff -ru a b' gives the path in a and b; two names with nothing in
common are a file renamed, and OLD-PATH is OLD."
  (let ((old-parts (split-string old "/" t))
        (new-parts (split-string new "/" t))
        (common nil))
    (while (and old-parts new-parts (equal (car (last old-parts)) (car (last new-parts))))
      (push (car (last old-parts)) common)
      (setq old-parts (butlast old-parts) new-parts (butlast new-parts)))
    (if common
        (cons (string-join common "/") nil)
      (cons new old))))

(defun change-review-diff--head-info (lines)
  "Return a plist of what the head of a file in LINES says.
The head is the lines before the first hunk."
  (let ((n (length lines)) (i 0) (info nil))
    (while (and (< i n)
                (not (change-review-diff--hunk-header-p (aref lines i)))
                (not (equal (change-review-diff--chomp (aref lines i)) "GIT binary patch")))
      (let ((line (change-review-diff--chomp (aref lines i))))
        (cond
         ((string-prefix-p "diff --git " line) (setq info (plist-put info :git (substring line 11))))
         ((string-prefix-p "old mode " line) (setq info (plist-put info :old-mode (substring line 9))))
         ((string-prefix-p "new mode " line) (setq info (plist-put info :new-mode (substring line 9))))
         ((string-prefix-p "new file mode " line) (setq info (plist-put info :new-file (substring line 14))))
         ((string-prefix-p "deleted file mode " line)
          (setq info (plist-put info :deleted-file (substring line 18))))
         ((string-prefix-p "rename from " line)
          (setq info (plist-put info :rename-from (change-review-diff--unquote (substring line 12)))))
         ((string-prefix-p "rename to " line)
          (setq info (plist-put info :rename-to (change-review-diff--unquote (substring line 10)))))
         ((string-prefix-p "copy from " line)
          (setq info (plist-put info :copy-from (change-review-diff--unquote (substring line 10)))))
         ((string-prefix-p "copy to " line)
          (setq info (plist-put info :copy-to (change-review-diff--unquote (substring line 8)))))
         ((string-match "\\`index \\([0-9a-f]+\\)\\.\\.\\([0-9a-f]+\\)\\(?: \\([0-7]+\\)\\)?" line)
          (setq info (plist-put (plist-put (plist-put info :old-blob (match-string 1 line))
                                           :new-blob (match-string 2 line))
                                :index-mode (match-string 3 line))))
         ((and (string-prefix-p "--- " line) (null (plist-member info :minus)))
          (setq info (plist-put info :minus (substring line 4))))
         ((and (string-prefix-p "+++ " line) (null (plist-member info :plus)))
          (setq info (plist-put info :plus (substring line 4))))
         ((string-match "\\`Binary files \\(.+?\\) and \\(.+\\) differ\\'" line)
          (setq info (plist-put (plist-put info :binary-old (match-string 1 line))
                                :binary-new (match-string 2 line))))))
      (cl-incf i))
    (if (and (< i n) (change-review-diff--hunk-header-p (aref lines i)))
        (plist-put info :first-hunk (aref lines i))
      info)))

(defun change-review-diff--blob (id)
  "Return the object id ID, nil when it is all zeros (no object there)."
  (and id (not (string-match-p "\\`0+\\'" id)) id))

(defun change-review-diff--type-changed-p (old-mode new-mode)
  "Return non-nil when the modes OLD-MODE and NEW-MODE are of two file kinds."
  (and old-mode new-mode (>= (length old-mode) 3) (>= (length new-mode) 3)
       (not (equal (substring old-mode 0 3) (substring new-mode 0 3)))))

(defun change-review-diff--file-from-part (part kind)
  "Return the `change-review-file' of PART, a file of KIND; nil with no path."
  (let* ((text (plist-get part :text))
         (info (change-review-diff--head-info (change-review-diff--text-lines text)))
         path old-path status old-mode new-mode)
    (if (eq kind 'git)
        (let* ((pair (change-review-diff--git-line-paths (plist-get info :git)))
               (prefixes (change-review-diff--prefixes pair))
               (a (change-review-diff--strip (car pair) (car prefixes)))
               (b (change-review-diff--strip (cdr pair) (cdr prefixes)))
               (minus (change-review-diff--header-path (plist-get info :minus) (car prefixes)))
               (plus (change-review-diff--header-path (plist-get info :plus) (cdr prefixes)))
               (rename-from (plist-get info :rename-from))
               (rename-to (plist-get info :rename-to))
               (copy-from (plist-get info :copy-from))
               (copy-to (plist-get info :copy-to)))
          (setq old-mode (or (plist-get info :old-mode) (plist-get info :deleted-file)
                             (and (not (plist-get info :new-file)) (plist-get info :index-mode)))
                new-mode (or (plist-get info :new-mode) (plist-get info :new-file)
                             (and (not (plist-get info :deleted-file)) (plist-get info :index-mode)))
                status (cond ((and rename-from rename-to) "R")
                             ((and copy-from copy-to) "C")
                             ((plist-get info :new-file) "A")
                             ((plist-get info :deleted-file) "D")
                             ((change-review-diff--type-changed-p (plist-get info :old-mode)
                                                                  (plist-get info :new-mode))
                              "T")
                             (t "M"))
                path (pcase status
                       ((or "R" "C") (or rename-to copy-to))
                       ("D" (or minus a b))
                       ("A" (or plus b a))
                       (_ (or plus b minus a)))
                old-path (pcase status
                           ("R" rename-from)
                           ("C" copy-from))))
      (let* ((old (change-review-diff--header-path (plist-get info :minus) nil))
             (new (change-review-diff--header-path (plist-get info :plus) nil))
             (binary-old (change-review-diff--header-path (plist-get info :binary-old) nil))
             (binary-new (change-review-diff--header-path (plist-get info :binary-new) nil))
             (old (or old binary-old))
             (new (or new binary-new))
             (named (cond ((and old new) (change-review-diff--plain-paths old new))
                          (new (cons new nil))
                          (old (cons old nil)))))
        (setq status (cond ((and (null old) new) "A")
                           ((and (null new) old) "D")
                           ;; `diff -N' shows the file that is not there as empty.
                           ((string-match-p "\\`@@ -0,0 " (or (plist-get info :first-hunk) "")) "A")
                           ((string-match-p " \\+0,0 @@" (or (plist-get info :first-hunk) "")) "D")
                           ((cdr named) "R")
                           (t "M"))
              path (car named)
              old-path (cdr named))))
    (when (and path (not (string-empty-p path)))
      (change-review-make-file
       :path path :old-path old-path :status status :patch text
       :added (plist-get part :added) :deleted (plist-get part :deleted)
       :binary (plist-get part :binary)
       :old-blob (change-review-diff--blob (plist-get info :old-blob))
       :new-blob (change-review-diff--blob (plist-get info :new-blob))
       :old-mode old-mode :new-mode new-mode))))

(defun change-review-diff-parse (text)
  "Return the files the unified diff TEXT changes, as `change-review-file's.
TEXT is what `git diff', `git format-patch' or `diff -u' wrote, or
several of them one after the other.  What comes before the first file,
an email's words, and after the last, the signature format-patch ends
with, is left out.  The files are in the order of the diff.  Each has
its path (where the file is after the change; where it was, for a file
deleted), its old path for a rename or a copy, its status letter (A, D,
M, R, C or T), its part of the diff in `patch', the lines the diff adds
and deletes, whether it is binary, and the modes and the object ids that
git writes in the head of a file."
  (delq nil (mapcar (lambda (part) (change-review-diff--file-from-part (cdr part) (car part)))
                    (change-review-diff--scan text))))

(defun change-review-diff-count (file)
  "Count the lines FILE's patch adds and deletes; see whether it is binary.
Set `added', `deleted' and `binary' of FILE, a `change-review-file',
from its `patch', and return FILE."
  (let* ((lines (change-review-diff--text-lines (or (change-review-file-patch file) "")))
         (n (length lines))
         (i 0) (added 0) (deleted 0) (binary nil))
    (while (< i n)
      (let ((line (aref lines i)))
        (if (change-review-diff--hunk-header-p line)
            (let ((read (change-review-diff--read-hunk lines i)))
              (dolist (hunk-line (plist-get (car read) :lines))
                (pcase (car hunk-line)
                  (?+ (cl-incf added))
                  (?- (cl-incf deleted))))
              (setq i (max (cdr read) (1+ i))))
          (when (or (string-prefix-p "Binary files " line)
                    (string-prefix-p "GIT binary patch" line))
            (setq binary t))
          (cl-incf i))))
    (setf (change-review-file-added file) added
          (change-review-file-deleted file) deleted
          (change-review-file-binary file) binary)
    file))

(defun change-review-diff-version (text &rest keys)
  "Return a `change-review-version' of the files the diff TEXT changes.
KEYS are those of `change-review-make-version'; the files are
`change-review-diff-parse' of TEXT, whatever KEYS say of them."
  (apply #'change-review-make-version
         :files (change-review-diff-parse text) keys))

;;;; Hunks and the lines in them

(defvar change-review-diff--hunks-cache (make-hash-table :test 'eq :weakness 'key)
  "The hunks read from each patch, by the patch's string itself.")

(defun change-review-diff--read-hunks (patch)
  "Return the hunks of PATCH, a string, as `change-review-diff-hunks' gives them."
  (let* ((lines (change-review-diff--text-lines patch))
         (n (length lines))
         (i 0)
         (hunks nil))
    (while (< i n)
      (if (change-review-diff--hunk-header-p (aref lines i))
          (let ((read (change-review-diff--read-hunk lines i)))
            (push (car read) hunks)
            (setq i (max (cdr read) (1+ i))))
        (cl-incf i)))
    (nreverse hunks)))

(defun change-review-diff-hunks (file)
  "Return the hunks of the patch of FILE, in order, each a plist.
:header is the line that opens it, :heading what follows the line
numbers on it (with its space), :old-start, :old-count, :new-start and
:new-count the numbers as the header gives them.  :lines are its lines,
each (KIND TEXT OLD NEW): KIND the character the line starts with, a
space, + or - (or \\ for the \"No newline at end of file\" marker), TEXT
the rest, OLD and NEW the number of the line before the change and
after it -- on a side the line is not on, the number of the line that
follows it there.

The hunks of a patch are read once, and the list is shared by whoever
asks for them again: do not change it."
  (let* ((patch (or (change-review-file-patch file) ""))
         (hit (gethash patch change-review-diff--hunks-cache 'miss)))
    (if (eq hit 'miss)
        (puthash patch (change-review-diff--read-hunks patch) change-review-diff--hunks-cache)
      hit)))

(defun change-review-diff-line-number (line side)
  "Return the number of LINE, a line of a hunk, on SIDE, `old' or `new'.
Nil when the line is not on that side."
  (pcase-let ((`(,kind ,_ ,old ,new) line))
    (pcase kind
      (?\s (if (eq (change-review-diff--side side) 'old) old new))
      (?- (and (eq (change-review-diff--side side) 'old) old))
      (?+ (and (eq (change-review-diff--side side) 'new) new)))))

(defun change-review-diff-locate (hunks side number)
  "Return (HUNK INDEX EXACT) for line NUMBER of SIDE in HUNKS, or nil.
INDEX is that of the line in HUNK's lines: the line NUMBER, EXACT
non-nil, else the nearest the diff has on SIDE."
  (let (best distance)
    (cl-loop for hunk in hunks
             until (and distance (zerop distance))
             do (cl-loop for line in (plist-get hunk :lines) for index from 0
                         for own = (change-review-diff-line-number line side)
                         when (and own (or (null distance) (< (abs (- own number)) distance)))
                         do (setq best (list hunk index (= own number))
                                  distance (abs (- own number)))))
    best))

;;;; Excerpts

(defun change-review-diff--excerpt-header (hunk lines)
  "Return the header of an excerpt of the LINES of HUNK that count just them."
  (pcase-let ((`(,_ ,_ ,old ,new) (car lines))
              (old-count (cl-count-if (lambda (l) (memq (car l) '(?\s ?-))) lines))
              (new-count (cl-count-if (lambda (l) (memq (car l) '(?\s ?+))) lines)))
    ;; A side with no line names the line before, as git does.
    (format "@@ -%d,%d +%d,%d @@%s"
            (if (zerop old-count) (1- old) old) old-count
            (if (zerop new-count) (1- new) new) new-count
            (plist-get hunk :heading))))

(defun change-review-diff-excerpt (file side number &optional end-number)
  "Return the part of FILE's diff that a comment on line NUMBER of SIDE keeps.
FILE is a `change-review-file', SIDE `new' for a line of the file after
the change and `old' for one of the file before it.  With END-NUMBER the
comment is on the lines from NUMBER to it.  The part ends on the line, or
on the nearest one the diff has, and starts where the change it ends
starts, after at most `change-review-diff-context-lines' lines before it
that are not in another change; it has no more than
`change-review-diff-excerpt-limit' lines, and keeps their end.  A range
whose ends are in two hunks is the part for its end.

Return nil when the diff has no hunk, else a plist.  :text is the part:
a hunk header counting just its lines, with git's heading, then the
lines, each starting with a space, + or -, with newlines between them and
none at the end.  :exact is non-nil when the part ends on the line asked
for, :first-line and :last-line say where it starts and ends on SIDE
\(:first-line is the number of the line that follows a first line SIDE
does not have) and :side is SIDE."
  (let* ((side (change-review-diff--side side))
         (hunks (change-review-diff-hunks file))
         (end-number (and end-number (not (eql end-number number)) end-number))
         (low (if end-number (min number end-number) number))
         (high (if end-number (max number end-number) number))
         (found (change-review-diff-locate hunks side high))
         (found-low (and end-number (change-review-diff-locate hunks side low))))
    (when found
      (pcase-let* ((`(,hunk ,index ,exact) found)
                   (lines (vconcat (plist-get hunk :lines)))
                   (start (if (and found-low (eq (car found-low) hunk))
                              (min index (nth 1 found-low))
                            index))
                   (change-p (lambda (i) (memq (car (aref lines i)) '(?+ ?- ?\\))))
                   (end (if (and (< (1+ index) (length lines))
                                 (eq (car (aref lines (1+ index))) ?\\))
                            (1+ index)
                          index))
                   ;; Nothing before this is kept, so nothing needs looking at.
                   (floor (max 0 (- end change-review-diff-excerpt-limit)))
                   (back (lambda (i)
                           ;; To the start of the change I is in, if any.
                           (when (funcall change-p i)
                             (while (and (> i floor) (funcall change-p (1- i))) (cl-decf i)))
                           i))
                   ;; The context before the change, not cutting into one.
                   (first (funcall back (max 0 (- (funcall back start)
                                                  change-review-diff-context-lines))))
                   (first (if (> (- end first -1) change-review-diff-excerpt-limit)
                              (max 0 (- end change-review-diff-excerpt-limit -1))
                            first))
                   (part (append (cl-subseq lines first (1+ end)) nil)))
        (list :text (mapconcat #'identity
                               (cons (change-review-diff--excerpt-header hunk part)
                                     (mapcar (lambda (l) (concat (char-to-string (car l)) (nth 1 l)))
                                             part))
                               "\n")
              :exact exact
              :first-line (nth (if (eq side 'old) 2 3) (aref lines first))
              :last-line (change-review-diff-line-number (aref lines index) side)
              :side side)))))

(defun change-review-diff-location (file side number &optional end-number)
  "Return the `change-review-location' of line NUMBER of SIDE in FILE.
FILE is a `change-review-file'.  The location names the file (and the
file it was renamed from), the side, the line as asked -- also when the
diff does not hold it -- and, with END-NUMBER, the last line of a range.
Its excerpt is `change-review-diff-excerpt' of the line, nil when the
diff has no hunk; its patch is the file's."
  (let* ((side (change-review-diff--side side))
         (end-number (and end-number (not (eql end-number number)) end-number))
         (low (if end-number (min number end-number) number))
         (high (and end-number (max number end-number))))
    (change-review-make-location
     :file (change-review-file-path file)
     :old-file (change-review-file-old-path file)
     :side side :line low :end-line high
     :excerpt (plist-get (change-review-diff-excerpt file side low high) :text)
     :patch (change-review-file-patch-id file))))

(defun change-review-diff-excerpt-lines (excerpt)
  "Return the lines of EXCERPT, an excerpt, each (KIND TEXT OLD NEW).
They are as the lines of a hunk (`change-review-diff-hunks'), numbered
from the header of the excerpt; a text with no header has no numbers."
  (let* ((lines (split-string (or excerpt "") "\n"))
         (header (car lines))
         (old nil) (new nil) (out nil))
    (when (and header (string-match change-review-diff--hunk-regexp header))
      (setq old (+ (string-to-number (match-string 1 header))
                   (if (equal (match-string 2 header) "0") 1 0))
            new (+ (string-to-number (match-string 3 header))
                   (if (equal (match-string 4 header) "0") 1 0)))
      (setq lines (cdr lines)))
    (dolist (text lines)
      (unless (string-empty-p text)
        (let ((kind (aref text 0)))
          (push (list kind (substring text 1) old new) out)
          (when (and old new)
            (pcase kind
              (?\s (cl-incf old) (cl-incf new))
              (?- (cl-incf old))
              (?+ (cl-incf new)))))))
    (nreverse out)))

(defun change-review-diff-excerpt-target (excerpt)
  "Return the line EXCERPT is about: its last line that is not a marker.
It is a list (KIND TEXT OLD NEW), nil for an excerpt with no line."
  (car (last (cl-remove ?\\ (change-review-diff-excerpt-lines excerpt) :key #'car))))

(defun change-review-diff-quote (excerpt &optional prefix)
  "Return EXCERPT with PREFIX, \"> \" by default, at the start of each line.
It is how a mail reply quotes the diff it answers."
  (let* ((prefix (or prefix "> "))
         (text (or excerpt ""))
         (ended (string-suffix-p "\n" text))
         (body (if ended (substring text 0 -1) text)))
    (if (string-empty-p text)
        ""
      (concat (mapconcat (lambda (line) (concat prefix line)) (split-string body "\n") "\n")
              (if ended "\n" "")))))

;;;; Finding a line again

(defun change-review-diff-lines-of (text)
  "Return the lines of TEXT as a vector, without their newlines."
  (if (string-empty-p text)
      (vector)
    (vconcat (split-string (if (string-suffix-p "\n" text) (substring text 0 -1) text) "\n"))))

(defun change-review-diff-find-line (lines quote hint)
  "Return (LINE . SCORE) for where QUOTE is in LINES, or nil.
LINES is a vector of the lines of a file, QUOTE the lines (KIND . TEXT)
of it that were quoted, the last being the one that matters.  LINE is
the number of the line, from 1, that is that last line; where several
are, the one with most of the quoted lines above it just above it too
\(SCORE of them), then the one nearest the line HINT, where it was.
Blanks at the end of a line count for nothing."
  (let* ((target (string-trim-right (cdr (car (last quote)))))
         (before (mapcar (lambda (entry) (string-trim-right (cdr entry)))
                         (reverse (butlast quote))))
         best best-score best-distance)
    (dotimes (i (length lines))
      (when (equal target (string-trim-right (aref lines i)))
        (let ((score 0))
          (while (and (< score (length before)) (>= (- i score 1) 0)
                      (equal (nth score before)
                             (string-trim-right (aref lines (- i score 1)))))
            (cl-incf score))
          (let ((distance (abs (- (1+ i) hint))))
            (when (or (null best) (> score best-score)
                      (and (= score best-score) (< distance best-distance)))
              (setq best (1+ i) best-score score best-distance distance))))))
    (and best (cons best best-score))))

(defun change-review-diff-ranges (diff)
  "Return the ranges the hunks of DIFF change, as `git diff -U0' writes it.
Each is (OLD-START OLD-COUNT NEW-START NEW-COUNT), in order."
  (let (ranges)
    (dolist (line (split-string diff "\n"))
      (when (string-match change-review-diff--hunk-regexp line)
        (push (list (string-to-number (match-string 1 line))
                    (if (match-string 2 line) (string-to-number (match-string 2 line)) 1)
                    (string-to-number (match-string 3 line))
                    (if (match-string 4 line) (string-to-number (match-string 4 line)) 1))
              ranges)))
    (nreverse ranges)))

(defun change-review-diff-map-line (ranges line)
  "Return (NEW . STATUS) for old LINE, once RANGES have changed the file.
RANGES are as `change-review-diff-ranges' gives them.  NEW is the
line's number in the new file, STATUS `same' where nothing before it
changed the numbering, `moved' where lines were added or deleted before
it, and `changed' for a line in a range, whose NEW is the line in the
same place among the lines that replaced it, the last of them at most."
  (let ((offset 0) inside)
    (cl-loop for (start count new-start new-count) in ranges
             do (let ((first (if (zerop count) (1+ start) start))
                      (last (if (zerop count) start (+ start count -1))))
                  (cond
                   ((< line first) (cl-return))
                   ((and (> count 0) (<= line last))
                    ;; The same place in what replaced the lines, the last
                    ;; of them when there are fewer.
                    (setq inside (if (> new-count 0)
                                     (+ new-start (min (- line start) (1- new-count)))
                                   (max 1 new-start)))
                    (cl-return))
                   ;; Past the range: its lines come to the new ones that follow.
                   (t (setq offset (- (if (zerop new-count) (1+ new-start) (+ new-start new-count))
                                      (if (zerop count) (1+ start) (+ start count))))))))
    (cond (inside (cons inside 'changed))
          ((zerop offset) (cons line 'same))
          (t (cons (+ line offset) 'moved)))))

(defun change-review-diff-side-quote (location side)
  "Return the lines of the file on SIDE that LOCATION's excerpt shows, or nil.
SIDE is `new' for the file after the change, `old' for the file before
it.  The lines are (KIND . TEXT), KIND `context', `added' or `removed',
the last the line the location is on.  Nil when the excerpt does not
end on a line of SIDE, or on a line other than the one the location
names (a line the diff does not have gets the nearest one)."
  (let* ((side (change-review-diff--side side))
         (lines (change-review-diff-excerpt-lines (change-review-location-excerpt location)))
         (target (car (last (cl-remove ?\\ lines :key #'car))))
         (kinds (if (eq side 'old) '(?\s ?-) '(?\s ?+)))
         (named (or (change-review-location-end-line location)
                    (change-review-location-line location))))
    (when (and target (memq (car target) kinds)
               (or (null named) (eql named (change-review-diff-line-number target side))))
      (cl-loop for line in lines
               when (memq (car line) kinds)
               collect (cons (pcase (car line) (?\s 'context) (?+ 'added) (?- 'removed))
                             (nth 1 line))))))

(defun change-review-diff-place (location old-lines new-lines unchanged &optional ranges)
  "Return where LOCATION, a location with a line, is in the newest version.
OLD-LINES and NEW-LINES are vectors of the lines of its file before the
change and after it, nil for a side that was not read.  UNCHANGED is
non-nil when the file after the change is as it was when the location
was made.  RANGES says how that file changed since: `same', or the
ranges (`change-review-diff-ranges') of the change.  For a range of
lines the answer is about its last line.  The answer is a plist: :side,
:line where it is now (nil when the file has no such line any more) and
:was where it was, and :status:
  same     the line is where it was
  moved    the line the location is on is now at :line
  changed  the line was edited, or is gone: :line is where the lines that
           replaced it start, or where it was, as near as the file allows
  unknown  there is no telling: the file was not read, or the location
           has no excerpt to find the line by"
  (let* ((side (change-review-diff--side (change-review-location-side location)))
         (was (or (change-review-location-end-line location)
                  (change-review-location-line location)))
         (lines (if (eq side 'old) old-lines new-lines))
         ;; What the ranges make of the line, on the new side.
         (mapped (and was (eq side 'new) (consp ranges)
                      (change-review-diff-map-line ranges was)))
         (clamped (lambda ()
                    (if mapped
                        (car mapped)
                      (and (> (length lines) 0) (max 1 (min was (length lines))))))))
    (cond
     ((null was) (list :side side :line nil :was nil :status 'same))
     ((and (eq side 'new) (or unchanged (eq ranges 'same)))
      (list :side side :line was :was was :status 'same))
     ((and mapped (memq (cdr mapped) '(same moved)))
      (list :side side :line (car mapped) :was was :status (cdr mapped)))
     ((null lines)
      (list :side side :line (if mapped (car mapped) was) :was was
            :status (if mapped 'changed 'unknown)))
     ((zerop (length lines)) (list :side side :line nil :was was :status 'changed))
     (t
      (let* ((quote (change-review-diff-side-quote location side))
             (found (and quote (change-review-diff-find-line
                                lines quote (if mapped (car mapped) was)))))
        (cond
         ;; Edited, yet the same line is somewhere: moved there.
         (found (list :side side :line (car found) :was was
                      :status (if (= (car found) was) 'same 'moved)))
         ((or quote mapped)
          (list :side side :line (funcall clamped) :was was :status 'changed))
         (t (list :side side :line (funcall clamped) :was was :status 'unknown))))))))

(defun change-review-diff--side-sequence (hunks side)
  "Return (LINES . NUMBERS), the lines of HUNKS on SIDE and their numbers.
Both are vectors.  A line that cannot be told from the first of the next
hunk stands between two hunks, so a line is never taken for the one that
follows it in another hunk."
  (let (lines numbers)
    (dolist (hunk hunks)
      (when lines
        (push "\0" lines)
        (push nil numbers))
      (dolist (line (plist-get hunk :lines))
        (when-let* ((own (change-review-diff-line-number line side)))
          (push (nth 1 line) lines)
          (push own numbers))))
    (cons (vconcat (nreverse lines)) (vconcat (nreverse numbers)))))

(defun change-review-diff--nearest-index (numbers number)
  "Return the index, from 1, of the entry of NUMBERS nearest to NUMBER."
  (let (best distance)
    (dotimes (i (length numbers))
      (when-let* ((entry (aref numbers i)))
        (when (or (null distance) (< (abs (- entry number)) distance))
          (setq best (1+ i) distance (abs (- entry number))))))
    (or best 1)))

(defun change-review-diff-relocate (location file)
  "Return where LOCATION, made against another version, is in FILE.
FILE is a `change-review-file' of the version being shown; only its
diff is read, not the text of the file.  The answer is a plist: :side,
:line where the line is in FILE's diff (nil when it is not), :was where
the location had it, and :status:
  same     the line is where it was, and says what it said
  moved    the same line, with the lines quoted above it, is elsewhere
  changed  the lines around it are there and it is not as it was:
           :line is the nearest line of the diff
  gone     nothing like it is in the diff of FILE
  unknown  there is no telling: the location has no excerpt to find
           the line by
A location with no line is on the file as a whole, and `same'.  For a
range of lines the answer is about its last line."
  (let* ((side (change-review-diff--side (change-review-location-side location)))
         (line (change-review-location-line location))
         (was (and line (or (change-review-location-end-line location) line)))
         (quote (and was (change-review-diff-side-quote location side))))
    (cond
     ((null was) (list :side side :line nil :was nil :status 'same))
     ((null quote) (list :side side :line was :was was :status 'unknown))
     (t
      (pcase-let* ((`(,lines . ,numbers)
                    (change-review-diff--side-sequence (change-review-diff-hunks file) side))
                   (target (string-trim-right (cdr (car (last quote)))))
                   (at (cl-position was numbers))
                   (hint (change-review-diff--nearest-index numbers was))
                   (found (change-review-diff-find-line lines quote hint))
                   (above (butlast quote))
                   (near (and above (change-review-diff-find-line lines above hint)))
                   ;; One quoted line above is not much to go by.
                   (near (and near (or (>= (cdr near) 1) (null (cdr above))) near)))
        (cond
         ((and at (equal target (string-trim-right (aref lines at))))
          (list :side side :line was :was was :status 'same))
         (found
          (let ((number (aref numbers (1- (car found)))))
            (list :side side :line number :was was :status (if (= number was) 'same 'moved))))
         (near
          ;; The line above is there: the line is what follows it, if
          ;; the diff has anything there, else the line above.
          (let* ((index (car near))
                 (next (and (< index (length numbers)) (aref numbers index))))
            (list :side side :line (or next (aref numbers (1- index))) :was was
                  :status 'changed)))
         (t (list :side side :line nil :was was :status 'gone))))))))

(provide 'change-review-diff)
;;; change-review-diff.el ends here
