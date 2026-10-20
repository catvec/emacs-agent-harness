;;; change-review-diff-test.el --- Tests for the diffs of change-review  -*- lexical-binding: t; -*-

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

;; The tests of change-review-diff.el.  The diffs are written out, most
;; of them as git wrote them for a branch that changes a file in two
;; places, deletes one, renames one, adds two and changes a binary one;
;; so nothing here needs git, or anything but the library: `make test'
;; runs them in an Emacs with only this directory on its load path.

;;; Code:

(require 'ert)
(require 'bytecomp)
(require 'cl-lib)
(require 'change-review)
(require 'change-review-diff)

(defconst change-review-diff-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "The directory of the library and its tests.")

;;;; Fixtures

(defun change-review-diff-test--text (&rest lines)
  "Return LINES as a text, each line ended by a newline."
  (mapconcat (lambda (line) (concat line "\n")) lines ""))

(defconst change-review-diff-test--a-diff
  (change-review-diff-test--text
   "diff --git a/a.el b/a.el"
   "index 9ae12be..b9609bf 100644"
   "--- a/a.el"
   "+++ b/a.el"
   "@@ -1,5 +1,5 @@"
   " (setq a1 1)"
   "-(setq a2 2)"
   "+(setq a2 'two)"
   " (setq a3 3)"
   " (setq a4 4)"
   " (setq a5 5)"
   "@@ -15,6 +15,6 @@"
   " (setq a15 15)"
   " (setq a16 16)"
   " (setq a17 17)"
   "-(setq a18 18)"
   "+(setq a18 'eighteen)"
   " (setq a19 19)"
   " (setq a20 20)")
  "The diff of a file changed in two places, line 2 and line 18 of 20.")

(defconst change-review-diff-test--rest-of-git-diff
  (change-review-diff-test--text
   "diff --git a/b.el b/b.el"
   "deleted file mode 100644"
   "index 64aa4f6..0000000"
   "--- a/b.el"
   "+++ /dev/null"
   "@@ -1,5 +0,0 @@"
   "-(setq b1 1)"
   "-(setq b2 2)"
   "-(setq b3 3)"
   "-(setq b4 4)"
   "-(setq b5 5)"
   "diff --git a/c.el b/d.el"
   "similarity index 90%"
   "rename from c.el"
   "rename to d.el"
   "index e2d58f2..0ce53ae 100644"
   "--- a/c.el"
   "+++ b/d.el"
   "@@ -3,7 +3,7 @@"
   " (setq c3 3)"
   " (setq c4 4)"
   " (setq c5 5)"
   "-(setq c6 6)"
   "+(setq c6 'six)"
   " (setq c7 7)"
   " (setq c8 8)"
   " (setq c9 9)"
   "diff --git \"a/docs/\\303\\251.txt\" \"b/docs/\\303\\251.txt\""
   "new file mode 100644"
   "index 0000000..5fb50d3"
   "--- /dev/null"
   "+++ \"b/docs/\\303\\251.txt\""
   "@@ -0,0 +1 @@"
   "+héllo"
   "diff --git a/img.bin b/img.bin"
   "index 67c1c7c..01c631b 100644"
   "Binary files a/img.bin and b/img.bin differ"
   "diff --git a/new.el b/new.el"
   "new file mode 100644"
   "index 0000000..137c8a5"
   "--- /dev/null"
   "+++ b/new.el"
   "@@ -0,0 +1,3 @@"
   "+(setq new1 1)"
   "+(setq new2 2)"
   "+(setq new3 3)")
  "The rest of the diff git wrote for the branch.")

(defconst change-review-diff-test--git-diff
  (concat change-review-diff-test--a-diff change-review-diff-test--rest-of-git-diff)
  "The diff git wrote for the branch: six files.")

(defconst change-review-diff-test--a-v2-diff
  (change-review-diff-test--text
   "diff --git a/a.el b/a.el"
   "index 9ae12be..72c44b0 100644"
   "--- a/a.el"
   "+++ b/a.el"
   "@@ -1,5 +1,8 @@"
   "+(setq top1 1)"
   "+(setq top2 2)"
   "+(setq top3 3)"
   " (setq a1 1)"
   "-(setq a2 2)"
   "+(setq a2 'three)"
   " (setq a3 3)"
   " (setq a4 4)"
   " (setq a5 5)"
   "@@ -15,6 +18,6 @@"
   " (setq a15 15)"
   " (setq a16 16)"
   " (setq a17 17)"
   "-(setq a18 18)"
   "+(setq a18 'eighteen)"
   " (setq a19 19)"
   " (setq a20 20)")
  "The diff of the file again: three lines on top and line 2 changed.")

(defconst change-review-diff-test--a-v3-diff
  (change-review-diff-test--text
   "diff --git a/a.el b/a.el"
   "index 9ae12be..c7a31cd 100644"
   "--- a/a.el"
   "+++ b/a.el"
   "@@ -1,5 +1,6 @@"
   "+(setq top1 1)"
   " (setq a1 1)"
   "-(setq a2 2)"
   "+(setq a2 'three)"
   " (setq a3 3)"
   " (setq a4 4)"
   " (setq a5 5)")
  "The diff of the file once more: line 18 is not changed any more.")

(defconst change-review-diff-test--format-patch
  (change-review-diff-test--text
   "From d1f5fd7d47d7b9b75311c5abeb94e831c6ea712a Mon Sep 17 00:00:00 2001"
   "From: Alice <alice@example.org>"
   "Date: Mon, 19 Oct 2026 22:33:12 -0400"
   "Subject: [PATCH] keep: add a line"
   ""
   "With a body paragraph."
   "---"
   " keep.el | 1 +"
   " 1 file changed, 1 insertion(+)"
   ""
   "diff --git a/keep.el b/keep.el"
   "index a5ca0a5..dcac85d 100644"
   "--- a/keep.el"
   "+++ b/keep.el"
   "@@ -1,3 +1,4 @@"
   " (setq keep1 1)"
   " (setq keep2 2)"
   " (setq keep3 3)"
   "+extra"
   "-- "
   "2.55.0"
   "")
  "A patch email as git format-patch writes it.")

(defun change-review-diff-test--files (text)
  "Return the files of the diff TEXT, by path."
  (mapcar (lambda (file) (cons (change-review-file-path file) file))
          (change-review-diff-parse text)))

(defun change-review-diff-test--file (text &optional path)
  "Return the file of the diff TEXT at PATH, the first by default."
  (if path
      (cdr (assoc path (change-review-diff-test--files text)))
    (car (change-review-diff-parse text))))

(defun change-review-diff-test--a ()
  "Return the file a.el of the two-change diff."
  (change-review-diff-test--file change-review-diff-test--a-diff))

(defun change-review-diff-test--numbered (name count &optional changes)
  "Return COUNT numbered lines setting NAME's variables.
CHANGES is an alist of LINE -> its text instead."
  (mapconcat (lambda (i) (concat (or (cdr (assq i changes)) (format "(setq %s%d %d)" name i i)) "\n"))
             (number-sequence 1 count) ""))

;;;; Reading what git writes

(ert-deftest change-review-diff-parses-what-git-writes ()
  "A branch's diff is cut into its files, each with what git says of it,
and the parts of the files make the diff again."
  (let* ((files (change-review-diff-parse change-review-diff-test--git-diff))
         (by-path (lambda (path) (cl-find path files :key #'change-review-file-path :test #'equal))))
    (should (equal '("a.el" "b.el" "d.el" "docs/é.txt" "img.bin" "new.el")
                   (mapcar #'change-review-file-path files)))
    (pcase-dolist (`(,path ,status ,old-path ,added ,deleted ,binary ,old-blob ,new-blob)
                   '(("a.el" "M" nil 2 2 nil "9ae12be" "b9609bf")
                     ("b.el" "D" nil 0 5 nil "64aa4f6" nil)
                     ("d.el" "R" "c.el" 1 1 nil "e2d58f2" "0ce53ae")
                     ("docs/é.txt" "A" nil 1 0 nil nil "5fb50d3")
                     ("img.bin" "M" nil 0 0 t "67c1c7c" "01c631b")
                     ("new.el" "A" nil 3 0 nil nil "137c8a5")))
      (ert-info ((format "%s" path))
        (let ((file (funcall by-path path)))
          (should (equal status (change-review-file-status file)))
          (should (equal old-path (change-review-file-old-path file)))
          (should (= added (change-review-file-added file)))
          (should (= deleted (change-review-file-deleted file)))
          (should (eq binary (change-review-file-binary file)))
          (should (equal old-blob (change-review-file-old-blob file)))
          (should (equal new-blob (change-review-file-new-blob file)))
          (should (string-suffix-p "\n" (change-review-file-patch file))))))
    ;; Modes: none for the side a file is not on.
    (should (equal '("100644" "100644") (list (change-review-file-old-mode (funcall by-path "a.el"))
                                              (change-review-file-new-mode (funcall by-path "a.el")))))
    (should (equal '("100644" nil) (list (change-review-file-old-mode (funcall by-path "b.el"))
                                         (change-review-file-new-mode (funcall by-path "b.el")))))
    (should (equal '(nil "100644") (list (change-review-file-old-mode (funcall by-path "new.el"))
                                         (change-review-file-new-mode (funcall by-path "new.el")))))
    ;; Each file has its own part, from its own first line.
    (should (string-prefix-p "diff --git a/c.el b/d.el\nsimilarity index 90%\n"
                             (change-review-file-patch (funcall by-path "d.el"))))
    (should (string-prefix-p "diff --git \"a/docs/\\303\\251.txt\""
                             (change-review-file-patch (funcall by-path "docs/é.txt"))))
    ;; Nothing lost, nothing added: the parts are the diff.
    (should (equal change-review-diff-test--git-diff
                   (mapconcat #'change-review-file-patch files "")))
    (should (equal (mapcar #'change-review-file-patch files)
                   (change-review-diff-split change-review-diff-test--git-diff)))))

(ert-deftest change-review-diff-parses-modes-renames-and-copies ()
  "A change of mode, a rename with no change, a copy, a file replaced by a
link and a change of kind are told by the head of the file."
  (let ((files (change-review-diff-test--files
                (change-review-diff-test--text
                 "diff --git a/keep.el b/keep.el"
                 "old mode 100644"
                 "new mode 100755"
                 "diff --git a/a.el b/moved.el"
                 "similarity index 100%"
                 "rename from a.el"
                 "rename to moved.el"
                 "diff --git a/keep.el b/keep-copy.el"
                 "similarity index 88%"
                 "copy from keep.el"
                 "copy to keep-copy.el"
                 "index a5ca0a5..1e2388e 100644"
                 "--- a/keep.el"
                 "+++ b/keep-copy.el"
                 "@@ -1,3 +1,4 @@"
                 " (setq keep1 1)"
                 " (setq keep2 2)"
                 " (setq keep3 3)"
                 "+tweak"
                 "diff --git a/link b/link"
                 "old mode 100644"
                 "new mode 120000"
                 "diff --git a/b.el b/b.el"
                 "new file mode 120000"
                 "index 0000000..21f1bfa"
                 "--- /dev/null"
                 "+++ b/b.el"
                 "@@ -0,0 +1 @@"
                 "+a.el"
                 "\\ No newline at end of file"))))
    (should (equal '("keep.el" "moved.el" "keep-copy.el" "link" "b.el") (mapcar #'car files)))
    (let ((mode (cdr (assoc "keep.el" files))))
      (should (equal "M" (change-review-file-status mode)))
      (should (equal '("100644" "100755") (list (change-review-file-old-mode mode)
                                                (change-review-file-new-mode mode))))
      (should (= 0 (change-review-file-added mode)))
      (should-not (change-review-file-binary mode)))
    (let ((rename (cdr (assoc "moved.el" files))))
      (should (equal "R" (change-review-file-status rename)))
      (should (equal "a.el" (change-review-file-old-path rename)))
      (should-not (change-review-file-old-blob rename))
      (should (equal "diff --git a/a.el b/moved.el\nsimilarity index 100%\nrename from a.el\nrename to moved.el\n"
                     (change-review-file-patch rename))))
    (let ((copy (cdr (assoc "keep-copy.el" files))))
      (should (equal "C" (change-review-file-status copy)))
      (should (equal "keep.el" (change-review-file-old-path copy)))
      (should (= 1 (change-review-file-added copy))))
    (should (equal "T" (change-review-file-status (cdr (assoc "link" files)))))
    ;; The marker after the last line is not a line.
    (let ((link (cdr (assoc "b.el" files))))
      (should (equal "A" (change-review-file-status link)))
      (should (equal "120000" (change-review-file-new-mode link)))
      (should (= 1 (change-review-file-added link)))
      (should (string-suffix-p "+a.el\n\\ No newline at end of file\n" (change-review-file-patch link))))))

(ert-deftest change-review-diff-parses-paths-with-spaces-and-quotes ()
  "A path with spaces, with a tab or a quote in it, with another prefix or
none is the path it is."
  (let ((files (change-review-diff-parse
                (change-review-diff-test--text
                 "diff --git a/my file.txt b/my file.txt"
                 "new file mode 100644"
                 "index 0000000..396fd61"
                 "--- /dev/null"
                 "+++ b/my file.txt\t"
                 "@@ -0,0 +1 @@"
                 "+one"
                 "diff --git a/empty file b/empty file"
                 "new file mode 100644"
                 "index 0000000..e69de29"
                 "diff --git a/old name.txt b/new name.txt"
                 "similarity index 100%"
                 "rename from old name.txt"
                 "rename to new name.txt"
                 "diff --git \"a/tab\\there.txt\" \"b/tab\\there.txt\""
                 "index 1111111..2222222 100644"
                 "--- \"a/tab\\there.txt\""
                 "+++ \"b/tab\\there.txt\""
                 "@@ -1 +1 @@"
                 "-x"
                 "+y"
                 "diff --git \"a/q\\\"uote\\\\.txt\" \"b/q\\\"uote\\\\.txt\""
                 "deleted file mode 100644"
                 "index 1111111..0000000"
                 "diff --git i/x.el w/x.el"
                 "index 1111111..2222222 100644"
                 "--- i/x.el"
                 "+++ w/x.el"
                 "@@ -1 +1 @@"
                 "-1"
                 "+2"
                 "diff --git x.el x.el"
                 "index 3333333..4444444 100644"
                 "--- x.el"
                 "+++ x.el"
                 "@@ -1 +1 @@"
                 "-1"
                 "+2"
                 "diff --git a/a/b.el b/a/b.el"
                 "index 3333333..4444444 100644"
                 "--- a/a/b.el"
                 "+++ b/a/b.el"
                 "@@ -1 +1 @@"
                 "-1"
                 "+2"))))
    (should (equal '("my file.txt" "empty file" "new name.txt" "tab\there.txt" "q\"uote\\.txt"
                     "x.el" "x.el" "a/b.el")
                   (mapcar #'change-review-file-path files)))
    (should (equal '("A" "A" "R" "M" "D" "M" "M" "M") (mapcar #'change-review-file-status files)))
    (should (equal "old name.txt" (change-review-file-old-path (nth 2 files))))
    (should (equal '(1 0 0 1 0 1 1 1) (mapcar #'change-review-file-added files)))))

(ert-deftest change-review-diff-reads-hunks-by-their-numbers ()
  "The lines of a hunk are as many as its header says: a deleted line that
reads like the head of a file is a line, and what follows the last line,
a signature, is not."
  (let* ((text (change-review-diff-test--text
                "diff --git a/q.sql b/q.sql"
                "index 1111111..2222222 100644"
                "--- a/q.sql"
                "+++ b/q.sql"
                "@@ -1,3 +1,3 @@"
                " select 1;"
                "--- note"
                "+++ other note"
                " select 2;"
                "diff --git a/r.sql b/r.sql"
                "index 3333333..4444444 100644"
                "--- a/r.sql"
                "+++ b/r.sql"
                "@@ -1 +1 @@"
                "-old"
                "+new"
                "-- "
                "2.55.0"))
         (files (change-review-diff-parse text)))
    (should (equal '("q.sql" "r.sql") (mapcar #'change-review-file-path files)))
    (should (equal '((1 1) (1 1))
                   (mapcar (lambda (f) (list (change-review-file-added f) (change-review-file-deleted f)))
                           files)))
    (should (equal '((?\s " select 1;" 1 1) (?- "-- note" 2 2) (?+ "++ other note" 3 2) (?\s " select 2;" 3 3))
                   (mapcar (lambda (l) (list (car l) (if (eq (car l) ?\s) (concat " " (nth 1 l)) (nth 1 l))
                                             (nth 2 l) (nth 3 l)))
                           (plist-get (car (change-review-diff-hunks (car files))) :lines))))
    (should (string-suffix-p "+new\n" (change-review-file-patch (cadr files))))
    ;; An empty line where a mailer cut the space off a blank context line.
    (let ((lines (plist-get (car (change-review-diff-hunks
                                  (change-review-diff-test--file
                                   (change-review-diff-test--text
                                    "diff --git a/b b/b" "--- a/b" "+++ b/b" "@@ -1,3 +1,3 @@"
                                    " one" "" "-three" "+four"))))
                            :lines)))
      (should (equal '((?\s "one" 1 1) (?\s "" 2 2) (?- "three" 3 3) (?+ "four" 4 3))
                     lines)))))

(ert-deftest change-review-diff-parses-an-email ()
  "The words of an email before its diff and the signature after are left
out, whether it is one patch or several."
  (let* ((files (change-review-diff-parse change-review-diff-test--format-patch)))
    (should (equal '("keep.el") (mapcar #'change-review-file-path files)))
    (should (equal "M" (change-review-file-status (car files))))
    (should (equal (change-review-diff-test--text
                    "diff --git a/keep.el b/keep.el"
                    "index a5ca0a5..dcac85d 100644"
                    "--- a/keep.el"
                    "+++ b/keep.el"
                    "@@ -1,3 +1,4 @@"
                    " (setq keep1 1)"
                    " (setq keep2 2)"
                    " (setq keep3 3)"
                    "+extra")
                   (change-review-file-patch (car files)))))
  (let ((files (change-review-diff-parse
                (concat change-review-diff-test--format-patch "\n"
                        "From 1111111111111111111111111111111111111111 Mon Sep 17 00:00:00 2001\n"
                        "Subject: [PATCH 2/2] another\n\n---\n"
                        change-review-diff-test--a-v3-diff "-- \n2.55.0\n\n"))))
    (should (equal '("keep.el" "a.el") (mapcar #'change-review-file-path files)))
    (should (string-suffix-p " (setq a5 5)\n" (change-review-file-patch (cadr files))))))

(ert-deftest change-review-diff-parses-a-binary-patch ()
  "A binary patch is one file; the blank line after its data is not part of it."
  (let* ((files (change-review-diff-parse
                 (change-review-diff-test--text
                  "diff --git a/img.bin b/img.bin"
                  "index 67c1c7c1783d7da6bdab0148caff749f8be51a10..01c631b01b7b4ed852c27b512bd9ed545c791742 100644"
                  "GIT binary patch"
                  "literal 10"
                  "RcmeAS@N;KiWMX0X2LKJM0(1ZX"
                  ""
                  "literal 10"
                  "RcmeAS@N;KiWMXFc4*(6S0(1ZX"
                  ""
                  "-- "
                  "2.55.0"
                  ""))))
    (should (equal '("img.bin") (mapcar #'change-review-file-path files)))
    (let ((file (car files)))
      (should (change-review-file-binary file))
      (should (= 0 (change-review-file-added file)))
      (should (equal "67c1c7c1783d7da6bdab0148caff749f8be51a10" (change-review-file-old-blob file)))
      (should (string-suffix-p "RcmeAS@N;KiWMXFc4*(6S0(1ZX\n" (change-review-file-patch file)))
      (should (string-search "literal 10\nRcmeAS@N;KiWMX0X2LKJM0(1ZX\n\nliteral 10\n"
                             (change-review-file-patch file))))))

(ert-deftest change-review-diff-parses-plain-diffs ()
  "What diff -u and diff -ru write: the path is what the names have in
common, a file that is not there on one side is added or deleted, and
files with other names are renamed."
  (let ((files (change-review-diff-test--files
                (change-review-diff-test--text
                 "Only in new: skipped.txt"
                 "diff -ruN old/added.txt new/added.txt"
                 "--- old/added.txt\t1970-01-01 00:00:00.000000000 +0000"
                 "+++ new/added.txt\t2026-10-19 22:33:12.545775319 -0400"
                 "@@ -0,0 +1 @@"
                 "+only new"
                 "diff -ruN old/gone.txt new/gone.txt"
                 "--- old/gone.txt\t2026-10-19 22:33:12.545775319 -0400"
                 "+++ new/gone.txt\t1970-01-01 00:00:00.000000000 +0000"
                 "@@ -1 +0,0 @@"
                 "-only old"
                 "diff -ru old/x.txt new/x.txt"
                 "--- old/x.txt\t2026-10-19 22:33:12.545775319 -0400"
                 "+++ new/x.txt\t2026-10-19 22:33:12.545775319 -0400"
                 "@@ -1,3 +1,3 @@"
                 " a"
                 "-b"
                 "+B"
                 " c"
                 "--- /dev/null"
                 "+++ fresh.txt"
                 "@@ -0,0 +1 @@"
                 "+fresh"
                 "--- fruit.txt"
                 "+++ /dev/null"
                 "@@ -1 +0,0 @@"
                 "-apple"
                 "--- one.txt"
                 "+++ two.txt"
                 "@@ -1 +1 @@"
                 "-1"
                 "+2"
                 "Binary files old/img.bin and new/img.bin differ"))))
    (should (equal '("added.txt" "gone.txt" "x.txt" "fresh.txt" "fruit.txt" "two.txt" "img.bin")
                   (mapcar #'car files)))
    (should (equal '("A" "D" "M" "A" "D" "R" "M")
                   (mapcar (lambda (entry) (change-review-file-status (cdr entry))) files)))
    (should (equal "one.txt" (change-review-file-old-path (cdr (assoc "two.txt" files)))))
    (should-not (change-review-file-old-path (cdr (assoc "x.txt" files))))
    (should (string-prefix-p "diff -ru old/x.txt new/x.txt\n--- old/x.txt\t"
                             (change-review-file-patch (cdr (assoc "x.txt" files)))))
    (should (= 1 (change-review-file-added (cdr (assoc "x.txt" files)))))
    (should (change-review-file-binary (cdr (assoc "img.bin" files))))
    ;; Files with no text diff, one after the other, stay apart.
    (let ((two (change-review-diff-parse
                (change-review-diff-test--text
                 "diff -ru old/a.bin new/a.bin"
                 "Binary files old/a.bin and new/a.bin differ"
                 "diff -ru old/b.bin new/b.bin"
                 "Binary files old/b.bin and /dev/null differ"
                 "diff -ru old/x.txt new/x.txt"
                 "--- old/x.txt" "+++ new/x.txt" "@@ -1 +1 @@" "-a" "+b"))))
      ;; A file on one side only has the name its side gives it.
      (should (equal '("a.bin" "old/b.bin" "x.txt") (mapcar #'change-review-file-path two)))
      (should (equal '("M" "D" "M") (mapcar #'change-review-file-status two)))
      (should (equal '(t t nil) (mapcar #'change-review-file-binary two)))
      (should (equal '(1 1) (list (change-review-file-added (nth 2 two))
                                  (change-review-file-deleted (nth 2 two))))))
    ;; Anything before the first file is words.
    (should (string-prefix-p "--- old/x.txt"
                             (change-review-file-patch
                              (change-review-diff-test--file
                               (change-review-diff-test--text
                                "Hello,"
                                "--- old/x.txt" "+++ new/x.txt" "@@ -1 +1 @@" "-b" "+B")))))
    ;; Version control comments in front of the lines.
    (let ((svn (change-review-diff-test--file
                (change-review-diff-test--text
                 "Index: src/foo.c"
                 "==================================================================="
                 "--- src/foo.c\t(revision 12)"
                 "+++ src/foo.c\t(working copy)"
                 "@@ -1 +1 @@" "-a" "+b"))))
      (should (equal "src/foo.c" (change-review-file-path svn)))
      (should (string-prefix-p "Index: src/foo.c\n=====" (change-review-file-patch svn))))))

(ert-deftest change-review-diff-parses-diffs-that-are-not-quite-right ()
  "A diff with carriage returns, one cut short, one with no newline at its
end, words between its files or an empty file is read as far as it goes."
  ;; Mail that went through a DOS machine.
  (let* ((files (change-review-diff-parse
                 (replace-regexp-in-string
                  "\n" "\r\n"
                  (change-review-diff-test--text
                   "diff --git a/x.el b/x.el" "index 1111111..2222222 100644"
                   "--- a/x.el" "+++ b/x.el" "@@ -1,2 +1,2 @@" " one" "-two" "+TWO"))))
         (file (car files)))
    (should (equal '("x.el" "M" 1 1) (list (change-review-file-path file) (change-review-file-status file)
                                           (change-review-file-added file) (change-review-file-deleted file))))
    (should (equal "2222222" (change-review-file-new-blob file)))
    (should (string-suffix-p "+TWO\r\n" (change-review-file-patch file))))
  ;; A hunk that says five lines and has two: the next file is the next file.
  (let ((files (change-review-diff-parse
                (change-review-diff-test--text
                 "diff --git a/x b/x" "--- a/x" "+++ b/x" "@@ -1,5 +1,5 @@" " one" "-two"
                 "diff --git a/y b/y" "--- a/y" "+++ b/y" "@@ -1 +1 @@" "-a" "+b"))))
    (should (equal '("x" "y") (mapcar #'change-review-file-path files)))
    (should (equal '((0 1) (1 1)) (mapcar (lambda (f) (list (change-review-file-added f)
                                                            (change-review-file-deleted f)))
                                          files))))
  ;; No newline at the end of the text.
  (let ((file (change-review-diff-test--file "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b")))
    (should (string-suffix-p "+b\n" (change-review-file-patch file))))
  ;; Words between files are in neither, an empty file has a head and nothing else.
  (let ((files (change-review-diff-test--files
                (change-review-diff-test--text
                 "diff --git a/x b/x" "--- a/x" "+++ b/x" "@@ -1 +1 @@" "-a" "+b"
                 "" "some words" ""
                 "diff --git a/e b/e" "new file mode 100644" "index 0000000..e69de29"))))
    (should (equal '("x" "e") (mapcar #'car files)))
    (should (equal "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
                   (change-review-file-patch (cdr (assoc "x" files)))))
    (let ((empty (cdr (assoc "e" files))))
      (should (equal '("A" 0 0) (list (change-review-file-status empty) (change-review-file-added empty)
                                      (change-review-file-deleted empty))))
      ;; The empty file is an object of its own.
      (should (equal "e69de29" (change-review-file-new-blob empty)))
      (should-not (change-review-file-old-blob empty))
      (should-not (change-review-diff-hunks empty)))))

(ert-deftest change-review-diff-parses-nothing-from-text-that-is-no-diff ()
  "Text with no file in it has no files."
  (should-not (change-review-diff-parse ""))
  (should-not (change-review-diff-parse "Hello,\n\nthere is no patch here.\n"))
  (should-not (change-review-diff-parse "--- a\n+++ b\nno hunk follows\n"))
  (should-not (change-review-diff-parse "@@ -1 +1 @@\n-a\n+b\n"))
  (should-not (change-review-diff-split "")))

(ert-deftest change-review-diff-counts-the-lines-of-a-patch ()
  "Counting reads the added and deleted lines of a file's patch and sees
whether it is binary, also for a file made by hand."
  (let ((file (change-review-make-file :path "a.el" :patch change-review-diff-test--a-diff)))
    (should (eq file (change-review-diff-count file)))
    (should (equal '(2 2 nil) (list (change-review-file-added file) (change-review-file-deleted file)
                                    (change-review-file-binary file)))))
  (let ((file (change-review-make-file
               :path "img" :added 9
               :patch "diff --git a/img b/img\nBinary files a/img and b/img differ\n")))
    (change-review-diff-count file)
    (should (equal '(0 0 t) (list (change-review-file-added file) (change-review-file-deleted file)
                                  (change-review-file-binary file)))))
  (let ((file (change-review-make-file :path "none")))
    (change-review-diff-count file)
    (should (equal '(0 0 nil) (list (change-review-file-added file) (change-review-file-deleted file)
                                    (change-review-file-binary file))))))

(ert-deftest change-review-diff-makes-a-version-of-a-diff ()
  "A version of a diff has its files, and what else it is given."
  (let ((version (change-review-diff-version change-review-diff-test--git-diff
                                             :id "tip" :label "second try" :time 5)))
    (should (equal "tip" (change-review-version-id version)))
    (should (equal "second try" (change-review-version-name version)))
    (should (= 6 (length (change-review-version-files version))))
    (should (equal "a.el" (change-review-file-path (car (change-review-version-files version)))))
    (should-not (change-review-version-files (change-review-diff-version "no diff" :id "x")))))

;;;; Hunks and lines

(ert-deftest change-review-diff-reads-the-hunks ()
  "A hunk's lines have their numbers on both sides."
  (let* ((a (change-review-diff-test--a))
         (hunks (change-review-diff-hunks a))
         (locate (lambda (side number)
                   (let ((found (change-review-diff-locate hunks side number)))
                     (list (cl-position (car found) hunks) (nth 1 found) (nth 2 found))))))
    (should (= 2 (length hunks)))
    (should (equal '((?\s "(setq a1 1)" 1 1) (?- "(setq a2 2)" 2 2) (?+ "(setq a2 'two)" 3 2)
                     (?\s "(setq a3 3)" 3 3) (?\s "(setq a4 4)" 4 4) (?\s "(setq a5 5)" 5 5))
                   (plist-get (car hunks) :lines)))
    (should (equal '("@@ -1,5 +1,5 @@" "" 1 5 1 5)
                   (mapcar (lambda (key) (plist-get (car hunks) key))
                           '(:header :heading :old-start :old-count :new-start :new-count))))
    (should (equal '(15 6 15 6)
                   (mapcar (lambda (key) (plist-get (cadr hunks) key))
                           '(:old-start :old-count :new-start :new-count))))
    ;; The line, or the nearest the diff has on that side.
    (should (equal '(1 4 t) (funcall locate 'new 18)))
    (should (equal '(1 3 t) (funcall locate 'old 18)))
    (should (equal '(1 0 nil) (funcall locate 'new 12)))
    (should (equal '(0 5 nil) (funcall locate 'new 7)))
    ;; The keywords of the older code do as well.
    (should (equal '(1 4 t) (funcall locate :new 18)))
    (should-not (change-review-diff-locate nil 'new 1))
    ;; Read once: the same hunks again, for the same patch.
    (should (eq hunks (change-review-diff-hunks a)))
    (should-not (change-review-diff-hunks (change-review-diff-test--file
                                           change-review-diff-test--rest-of-git-diff "img.bin")))
    ;; The number of a line on each side.
    (should (equal '(2 nil) (list (change-review-diff-line-number '(?- "x" 2 2) 'old)
                                  (change-review-diff-line-number '(?- "x" 2 2) 'new))))
    (should (equal '(nil 2) (list (change-review-diff-line-number '(?+ "x" 3 2) 'old)
                                  (change-review-diff-line-number '(?+ "x" 3 2) 'new))))
    (should (equal '(3 4) (list (change-review-diff-line-number '(?\s "x" 3 4) 'old)
                                (change-review-diff-line-number '(?\s "x" 3 4) 'new))))))

(ert-deftest change-review-diff-numbers-a-side-with-no-lines-from-the-line-before ()
  "Git names the line before a side that has no lines; the lines of the
other side are numbered from the line that follows it."
  (let* ((new (change-review-diff-test--file
               (change-review-diff-test--text
                "diff --git a/n b/n" "new file mode 100644" "--- /dev/null" "+++ b/n"
                "@@ -0,0 +1,2 @@" "+one" "+two")))
         (gone (change-review-diff-test--file
                (change-review-diff-test--text
                 "diff --git a/g b/g" "deleted file mode 100644" "--- a/g" "+++ /dev/null"
                 "@@ -1,2 +0,0 @@" "-one" "-two")))
         (insert (change-review-diff-test--file
                  (change-review-diff-test--text
                   "diff --git a/i b/i" "--- a/i" "+++ b/i"
                   "@@ -5,0 +6,2 @@ (defun f ()" "+x" "+y"
                   "@@ -9 +11 @@" "-z" "+w"))))
    (should (equal '((?+ "one" 1 1) (?+ "two" 1 2))
                   (plist-get (car (change-review-diff-hunks new)) :lines)))
    (should (equal '((?- "one" 1 1) (?- "two" 2 1))
                   (plist-get (car (change-review-diff-hunks gone)) :lines)))
    (let ((hunks (change-review-diff-hunks insert)))
      ;; Inserted after old line 5: old line 6 follows the lines.
      (should (equal '((?+ "x" 6 6) (?+ "y" 6 7)) (plist-get (car hunks) :lines)))
      (should (equal " (defun f ()" (plist-get (car hunks) :heading)))
      (should (equal '((?- "z" 9 11) (?+ "w" 10 11)) (plist-get (cadr hunks) :lines))))))

;;;; Excerpts

(ert-deftest change-review-diff-excerpts-the-change-a-line-is-in ()
  "The excerpt of a line is the change it ends, a few lines before it, under
a header that counts just those lines."
  (let* ((a (change-review-diff-test--a))
         (new (change-review-diff-test--file change-review-diff-test--rest-of-git-diff "new.el"))
         (excerpt (change-review-diff-excerpt a 'new 18)))
    (should (equal (mapconcat #'identity
                              '("@@ -15,4 +15,4 @@"
                                " (setq a15 15)" " (setq a16 16)" " (setq a17 17)"
                                "-(setq a18 18)" "+(setq a18 'eighteen)")
                              "\n")
                   (plist-get excerpt :text)))
    (should (equal '(t 15 18 new) (list (plist-get excerpt :exact) (plist-get excerpt :first-line)
                                        (plist-get excerpt :last-line) (plist-get excerpt :side))))
    ;; The same line before the change, the last line is the removed one.
    (let ((old (change-review-diff-excerpt a 'old 18)))
      (should (equal (mapconcat #'identity
                                '("@@ -15,4 +15,3 @@"
                                  " (setq a15 15)" " (setq a16 16)" " (setq a17 17)" "-(setq a18 18)")
                                "\n")
                     (plist-get old :text)))
      (should (equal '(15 18) (list (plist-get old :first-line) (plist-get old :last-line)))))
    ;; Three lines before the line, but not into the middle of a change.
    (let ((near (change-review-diff-excerpt a 'new 7)))
      (should (equal (mapconcat #'identity
                                '("@@ -2,4 +2,4 @@"
                                  "-(setq a2 2)" "+(setq a2 'two)" " (setq a3 3)" " (setq a4 4)" " (setq a5 5)")
                                "\n")
                     (plist-get near :text)))
      (should-not (plist-get near :exact))
      (should (eql 5 (plist-get near :last-line))))
    ;; A side with no line names the line before, as git does.
    (should (equal "@@ -0,0 +1,2 @@\n+(setq new1 1)\n+(setq new2 2)"
                   (plist-get (change-review-diff-excerpt new 'new 2) :text)))
    (should (equal "@@ -0,0 +1 @@\n+(setq new1 1)"
                   (let ((text (plist-get (change-review-diff-excerpt new 'new 1) :text)))
                     (replace-regexp-in-string "\\`@@ -0,0 \\+1,1 @@" "@@ -0,0 +1 @@" text))))
    (should-not (change-review-diff-excerpt
                 (change-review-diff-test--file change-review-diff-test--rest-of-git-diff "img.bin")
                 'new 1))
    (should-not (change-review-diff-excerpt (change-review-make-file :path "x") 'new 1))))

(ert-deftest change-review-diff-excerpt-keeps-the-heading-and-the-marker ()
  "The heading git gave the hunk is kept, and the \"No newline\" marker stays
with the line it follows."
  (let* ((file (change-review-diff-test--file
                (change-review-diff-test--text
                 "diff --git a/f.el b/f.el" "--- a/f.el" "+++ b/f.el"
                 "@@ -10,6 +10,6 @@ (defun f ()"
                 " (one)" " (two)" " (three)" "-(four)" "+(FOUR)" " (five)"
                 "-last"
                 "\\ No newline at end of file"
                 "+LAST"
                 "\\ No newline at end of file"))))
    (should (equal (mapconcat #'identity '("@@ -10,4 +10,4 @@ (defun f ()"
                                           " (one)" " (two)" " (three)" "-(four)" "+(FOUR)")
                              "\n")
                   (plist-get (change-review-diff-excerpt file 'new 13) :text)))
    ;; Three lines before would cut into the change above: it is kept whole.
    (let ((last (change-review-diff-excerpt file 'new 15)))
      (should (equal (mapconcat #'identity '("@@ -13,3 +13,3 @@ (defun f ()"
                                             "-(four)" "+(FOUR)" " (five)"
                                             "-last" "\\ No newline at end of file"
                                             "+LAST" "\\ No newline at end of file")
                                "\n")
                     (plist-get last :text)))
      (should (eql 15 (plist-get last :last-line))))))

(ert-deftest change-review-diff-excerpts-a-range-and-keeps-it-short ()
  "A range of lines is an excerpt to its last line; one too long keeps the
end of it; the context before is an option."
  (let ((a (change-review-diff-test--a)))
    ;; A range in one hunk starts where its first line asks the context to.
    (should (equal "@@ -1,4 +1,4 @@\n (setq a1 1)\n-(setq a2 2)\n+(setq a2 'two)\n (setq a3 3)\n (setq a4 4)"
                   (plist-get (change-review-diff-excerpt a 'new 1 4) :text)))
    ;; Two hunks: the part for its end.
    (should (equal (plist-get (change-review-diff-excerpt a 'new 18) :text)
                   (plist-get (change-review-diff-excerpt a 'new 2 18) :text)))
    ;; The same range the other way round.
    (should (equal (plist-get (change-review-diff-excerpt a 'new 1 4) :text)
                   (plist-get (change-review-diff-excerpt a 'new 4 1) :text)))
    ;; Fewer lines before.
    (let ((change-review-diff-context-lines 1))
      (should (equal "@@ -17,2 +17,2 @@\n (setq a17 17)\n-(setq a18 18)\n+(setq a18 'eighteen)"
                     (plist-get (change-review-diff-excerpt a 'new 18) :text))))
    ;; No lines before: the change alone, its header counting it.
    (let ((change-review-diff-context-lines 0))
      (should (equal "@@ -18,1 +18,1 @@\n-(setq a18 18)\n+(setq a18 'eighteen)"
                     (plist-get (change-review-diff-excerpt a 'new 18) :text)))))
  ;; A long run of added lines is cut to its end.
  (let* ((big (change-review-diff-test--file
               (concat (change-review-diff-test--text "diff --git a/big b/big" "new file mode 100644"
                                                      "--- /dev/null" "+++ b/big" "@@ -0,0 +1,100 @@")
                       (mapconcat (lambda (i) (format "+line %d\n" i)) (number-sequence 1 100) ""))))
         (excerpt (change-review-diff-excerpt big 'new 100)))
    (should (string-prefix-p "@@ -0,0 +41,60 @@\n+line 41\n" (plist-get excerpt :text)))
    (should (string-suffix-p "\n+line 100" (plist-get excerpt :text)))
    (should (= 61 (length (split-string (plist-get excerpt :text) "\n"))))
    (should (eql 41 (plist-get excerpt :first-line)))
    (let ((change-review-diff-excerpt-limit 5))
      (should (= 6 (length (split-string (plist-get (change-review-diff-excerpt big 'new 100 90) :text) "\n")))))))

(ert-deftest change-review-diff-makes-a-location ()
  "A location names the file and the line as asked and keeps the excerpt;
it comes back from its data."
  (let* ((files (change-review-diff-test--files change-review-diff-test--git-diff))
         (a (cdr (assoc "a.el" files)))
         (renamed (cdr (assoc "d.el" files)))
         (location (change-review-diff-location a 'new 18)))
    (should (equal "a.el" (change-review-location-file location)))
    (should (eq 'new (change-review-location-side location)))
    (should (eql 18 (change-review-location-line location)))
    (should-not (change-review-location-end-line location))
    (should (equal (plist-get (change-review-diff-excerpt a 'new 18) :text)
                   (change-review-location-excerpt location)))
    (should (equal "a.el:18" (change-review-location-label location)))
    (let ((back (change-review-location-from-data (change-review-location-to-data location))))
      (should (equal (change-review-location-excerpt location) (change-review-location-excerpt back)))
      (should (eql 18 (change-review-location-line back))))
    ;; A line the diff does not have stays the line asked for.
    (let ((far (change-review-diff-location a 'new 12)))
      (should (eql 12 (change-review-location-line far)))
      (should (string-suffix-p "\n (setq a15 15)" (change-review-location-excerpt far))))
    ;; The other side, a range, a rename, a file with no text.
    (let ((range (change-review-diff-location a 'old 17 18)))
      (should (eq 'old (change-review-location-side range)))
      (should (equal '(17 18) (list (change-review-location-line range)
                                    (change-review-location-end-line range)))))
    (should-not (change-review-location-end-line (change-review-diff-location a 'new 18 18)))
    (should (equal '(5 17) (let ((swapped (change-review-diff-location a 'new 17 5)))
                             (list (change-review-location-line swapped)
                                   (change-review-location-end-line swapped)))))
    (should (equal "c.el" (change-review-location-old-file (change-review-diff-location renamed 'new 6))))
    (should-not (change-review-location-excerpt
                 (change-review-diff-location (cdr (assoc "img.bin" files)) 'new 1)))
    (let ((series (change-review-make-file :path "p" :patch-id 2 :patch change-review-diff-test--a-diff)))
      (should (eql 2 (change-review-location-patch (change-review-diff-location series 'new 2)))))))

(ert-deftest change-review-diff-reads-an-excerpt-back ()
  "An excerpt has lines with their numbers, a target, and a quote."
  (let* ((excerpt (plist-get (change-review-diff-excerpt (change-review-diff-test--a) 'new 18) :text))
         (lines (change-review-diff-excerpt-lines excerpt)))
    (should (equal '((?\s "(setq a15 15)" 15 15) (?\s "(setq a16 16)" 16 16) (?\s "(setq a17 17)" 17 17)
                     (?- "(setq a18 18)" 18 18) (?+ "(setq a18 'eighteen)" 19 18))
                   lines))
    (should (equal '(?+ "(setq a18 'eighteen)" 19 18) (change-review-diff-excerpt-target excerpt)))
    ;; A marker is no target.
    (should (equal '(?+ "z" 6 5)
                   (change-review-diff-excerpt-target "@@ -5,0 +5 @@\n+z\n\\ No newline at end of file")))
    ;; A side with no lines counts from the line before, as in a hunk.
    (should (equal '((?+ "one" 1 1) (?+ "two" 1 2))
                   (change-review-diff-excerpt-lines "@@ -0,0 +1,2 @@\n+one\n+two")))
    (should (equal '((?+ "one" nil nil)) (change-review-diff-excerpt-lines "+one")))
    (should-not (change-review-diff-excerpt-lines nil))
    (should-not (change-review-diff-excerpt-target nil))
    (should (equal "> @@ -1 +1 @@\n> -a\n> +b" (change-review-diff-quote "@@ -1 +1 @@\n-a\n+b")))
    (should (equal "| -a\n| +b\n" (change-review-diff-quote "-a\n+b\n" "| ")))
    (should (equal "> \n" (change-review-diff-quote "\n")))
    (should (equal "" (change-review-diff-quote "")))
    (should (equal "" (change-review-diff-quote nil)))))

;;;; Finding a line again

(ert-deftest change-review-diff-finds-a-quoted-line ()
  "A quoted line is found by what it says; among lines that say the same, by
the lines quoted above it, then by how near it is to the line it was on."
  (let ((lines (vector "x" "a" "x" "b" "x")))
    ;; The x with an a above it, wherever the comment was.
    (should (equal '(3 . 1) (change-review-diff-find-line
                             lines '((context . "a") (added . "x")) 5)))
    ;; Nothing tells them apart: the nearest to where it was.
    (should (equal '(5 . 0) (change-review-diff-find-line lines '((added . "x")) 5)))
    (should (equal '(1 . 0) (change-review-diff-find-line lines '((added . "x")) 1)))
    ;; Blanks at the end of a line count for nothing.
    (should (equal '(2 . 0) (change-review-diff-find-line (vector "q" "a  ") '((added . "a")) 9)))
    (should-not (change-review-diff-find-line lines '((added . "gone")) 1))
    (should (equal ["a" "b"] (change-review-diff-lines-of "a\nb\n")))
    (should (equal ["a" "" "b"] (change-review-diff-lines-of "a\n\nb")))
    (should (equal [] (change-review-diff-lines-of "")))))

(ert-deftest change-review-diff-maps-a-line-through-a-diff ()
  "A line of the old file is where the ranges of the diff put it: moved by
lines added or deleted before it, changed where a range edited it."
  (let ((ranges (change-review-diff-ranges
                 (concat "diff --git a/x b/x\n--- a/x\n+++ b/x\n"
                         "@@ -0,0 +1,3 @@\n+a\n+b\n+c\n"
                         "@@ -5 +8 @@\n-e\n+E\n"
                         "@@ -9,2 +11,0 @@\n-i\n-j\n"))))
    (should (equal '((0 0 1 3) (5 1 8 1) (9 2 11 0)) ranges))
    (should (equal '(4 . moved) (change-review-diff-map-line ranges 1)))
    (should (equal '(7 . moved) (change-review-diff-map-line ranges 4)))
    (should (equal '(8 . changed) (change-review-diff-map-line ranges 5)))
    (should (equal '(9 . moved) (change-review-diff-map-line ranges 6)))
    ;; Deleted: where the lines were.
    (should (equal '(11 . changed) (change-review-diff-map-line ranges 9)))
    (should (equal '(11 . changed) (change-review-diff-map-line ranges 10)))
    (should (equal '(12 . moved) (change-review-diff-map-line ranges 11)))
    (should (equal '(7 . same) (change-review-diff-map-line nil 7)))
    ;; In a range that replaced three lines with two: the same place, then the last.
    (let ((ranges '((10 3 10 2))))
      (should (equal '(10 . changed) (change-review-diff-map-line ranges 10)))
      (should (equal '(11 . changed) (change-review-diff-map-line ranges 11)))
      (should (equal '(11 . changed) (change-review-diff-map-line ranges 12)))
      (should (equal '(12 . moved) (change-review-diff-map-line ranges 13)))))
  (should-not (change-review-diff-ranges "")))

(ert-deftest change-review-diff-quotes-the-lines-of-a-side ()
  "The quote of a location on a side is the lines of its excerpt that the
side has, the last being the line; none when the excerpt ends elsewhere."
  (let* ((a (change-review-diff-test--a))
         (new (change-review-diff-location a 'new 18))
         (old (change-review-diff-location a 'old 18)))
    (should (equal '((context . "(setq a15 15)") (context . "(setq a16 16)") (context . "(setq a17 17)")
                     (added . "(setq a18 'eighteen)"))
                   (change-review-diff-side-quote new 'new)))
    (should (equal '((context . "(setq a15 15)") (context . "(setq a16 16)") (context . "(setq a17 17)")
                     (removed . "(setq a18 18)"))
                   (change-review-diff-side-quote old 'old)))
    ;; The excerpt of the new line does not end on a line of the old side.
    (should-not (change-review-diff-side-quote new 'old))
    ;; A line the diff does not have gets the excerpt of the nearest, not its own.
    (should-not (change-review-diff-side-quote (change-review-diff-location a 'new 12) 'new))
    (should-not (change-review-diff-side-quote (change-review-make-location :file "a.el" :line 3) 'new))
    ;; A range ends on its last line.
    (should (equal '(added . "(setq a18 'eighteen)")
                   (car (last (change-review-diff-side-quote
                               (change-review-diff-location a 'new 16 18) 'new)))))))

(defun change-review-diff-test--v1 ()
  "Return the file a.el before and after the change, as vectors of lines."
  (cons (change-review-diff-lines-of (change-review-diff-test--numbered "a" 20))
        (change-review-diff-lines-of
         (change-review-diff-test--numbered "a" 20 '((2 . "(setq a2 'two)") (18 . "(setq a18 'eighteen)"))))))

(ert-deftest change-review-diff-places-a-location ()
  "A location is on the line it is on now: the same where nothing happened,
moved by lines added above it, changed when its line was edited."
  (let* ((a (change-review-diff-test--a))
         (two (change-review-diff-location a 'new 2))
         (eighteen (change-review-diff-location a 'new 18))
         (eleven (change-review-diff-location a 'new 11))
         (b3 (change-review-make-location :file "b.el" :side 'old :line 3))
         (v1 (change-review-diff-test--v1))
         (ranges (change-review-diff-ranges
                  (concat "@@ -0,0 +1,3 @@\n+(setq top1 1)\n+(setq top2 2)\n+(setq top3 3)\n"
                          "@@ -2 +5 @@\n-(setq a2 'two)\n+(setq a2 'three)\n"))))
    ;; The file is as it was.
    (should (equal '(:side new :line 18 :was 18 :status same)
                   (change-review-diff-place eighteen (car v1) (cdr v1) t)))
    (should (equal '(:side new :line 18 :was 18 :status same)
                   (change-review-diff-place eighteen (car v1) (cdr v1) nil 'same)))
    ;; Three lines on top and the second edited: carried through the ranges.
    (should (equal '(:side new :line 5 :was 2 :status changed)
                   (change-review-diff-place two nil nil nil ranges)))
    (should (equal '(:side new :line 21 :was 18 :status moved)
                   (change-review-diff-place eighteen nil nil nil ranges)))
    ;; Not a line of the diff: nothing to find it by but the ranges.
    (should (equal '(:side new :line 14 :was 11 :status moved)
                   (change-review-diff-place eleven nil nil nil ranges)))
    ;; The merge base did not change, whatever the ranges.
    (should (equal '(:side old :line 3 :was 3 :status unknown)
                   (change-review-diff-place b3 nil nil nil ranges)))
    ;; Without the ranges, by what they quote: line 19 once a line went on top.
    (let ((later (change-review-diff-lines-of
                  (concat "(setq top 1)\n"
                          (change-review-diff-test--numbered
                           "a" 20 '((2 . "(setq a2 'three)") (18 . "(setq a18 'eighteen)")))))))
      (should (equal '(:side new :line 19 :was 18 :status moved)
                     (change-review-diff-place eighteen (car v1) later nil)))
      ;; Edited: not found, so where it was.
      (should (equal '(:side new :line 2 :was 2 :status changed)
                     (change-review-diff-place two (car v1) later nil)))
      ;; A line the diff did not have is not found by the lines of the nearest.
      (should (equal '(:side new :line 11 :was 11 :status unknown)
                     (change-review-diff-place eleven (car v1) later nil))))
    ;; The file went: no line to be on.
    (should (equal '(:side new :line nil :was 18 :status changed)
                   (change-review-diff-place eighteen nil (vector) nil)))
    ;; Not read, no ranges, nothing to go by.
    (should (equal '(:side new :line 18 :was 18 :status unknown)
                   (change-review-diff-place eighteen nil nil nil)))
    ;; On the file as a whole there is no line to place.
    (should (equal '(:side new :line nil :was nil :status same)
                   (change-review-diff-place (change-review-make-location :file "a.el") nil nil nil)))
    ;; The old side is found by what it quotes too.
    (let ((old-18 (change-review-diff-location a 'old 18)))
      (should (equal '(:side old :line 18 :was 18 :status same)
                     (change-review-diff-place old-18 (car v1) nil nil)))
      (should (equal '(:side old :line 19 :was 18 :status moved)
                     (change-review-diff-place old-18 (change-review-diff-lines-of
                                                      (concat "(setq top 1)\n"
                                                              (change-review-diff-test--numbered "a" 20)))
                                               nil nil))))))

;;;; Finding a line in another version

(ert-deftest change-review-diff-relocates-a-location-in-another-diff ()
  "A location made against one version is found in the diff of another by
the lines it quotes: where it was, elsewhere, changed, or gone."
  (let* ((a (change-review-diff-test--a))
         (v2 (change-review-diff-test--file change-review-diff-test--a-v2-diff))
         (v3 (change-review-diff-test--file change-review-diff-test--a-v3-diff))
         (eighteen (change-review-diff-location a 'new 18))
         (two (change-review-diff-location a 'new 2))
         (old-two (change-review-diff-location a 'old 2)))
    ;; The version again: every location is where it was.
    (should (equal '(:side new :line 18 :was 18 :status same) (change-review-diff-relocate eighteen a)))
    (should (equal '(:side new :line 2 :was 2 :status same) (change-review-diff-relocate two a)))
    (should (equal '(:side old :line 2 :was 2 :status same) (change-review-diff-relocate old-two a)))
    ;; Three lines went on top: the line moved down with them.
    (should (equal '(:side new :line 21 :was 18 :status moved) (change-review-diff-relocate eighteen v2)))
    ;; The line was edited: what is there now, the nearest the diff has.
    (should (equal '(:side new :line 5 :was 2 :status changed) (change-review-diff-relocate two v2)))
    ;; The merge base's side is where it was.
    (should (equal '(:side old :line 2 :was 2 :status same) (change-review-diff-relocate old-two v2)))
    ;; The change of the line is no more: nothing like it in the diff.
    (should (equal '(:side new :line nil :was 18 :status gone) (change-review-diff-relocate eighteen v3)))
    (should (equal '(:side new :line 3 :was 2 :status changed) (change-review-diff-relocate two v3)))
    ;; A range is about its end.
    (should (equal '(:side new :line 21 :was 18 :status moved)
                   (change-review-diff-relocate (change-review-diff-location a 'new 16 18) v2)))
    ;; No excerpt, no telling; no line, nothing to find.
    (should (equal '(:side new :line 18 :was 18 :status unknown)
                   (change-review-diff-relocate (change-review-make-location :file "a.el" :line 18) v2)))
    (should (equal '(:side new :line nil :was nil :status same)
                   (change-review-diff-relocate (change-review-make-location :file "a.el") v2)))
    ;; A line the diff did not have, and so its nearest quoted: no telling.
    (should (equal '(:side new :line 12 :was 12 :status unknown)
                   (change-review-diff-relocate (change-review-diff-location a 'new 12) v2)))))

(ert-deftest change-review-diff-relocates-an-edited-line-to-its-neighbours ()
  "A line edited in the next version is found by the lines above it; when
the lines after those are gone, the nearest line there is."
  (let* ((a (change-review-diff-test--a))
         (eighteen (change-review-diff-location a 'new 18))
         (edited (change-review-diff-test--file
                  (change-review-diff-test--text
                   "diff --git a/a.el b/a.el" "--- a/a.el" "+++ b/a.el" "@@ -15,6 +15,6 @@"
                   " (setq a15 15)" " (setq a16 16)" " (setq a17 17)"
                   "-(setq a18 18)" "+(setq a18 'changed again)"
                   " (setq a19 19)" " (setq a20 20)")))
         (cut (change-review-diff-test--file
               (change-review-diff-test--text
                "diff --git a/a.el b/a.el" "--- a/a.el" "+++ b/a.el" "@@ -15,3 +15,3 @@"
                " (setq a15 15)" " (setq a16 16)" "-(setq a17 17)" "+(setq a17 'edited)"))))
    (should (equal '(:side new :line 18 :was 18 :status changed)
                   (change-review-diff-relocate eighteen edited)))
    ;; The hunk stops after a17: the line itself is not there, a17's is the nearest.
    (should (equal '(:side new :line 17 :was 18 :status changed)
                   (change-review-diff-relocate
                    eighteen
                    (change-review-diff-test--file
                     (change-review-diff-test--text
                      "diff --git a/a.el b/a.el" "--- a/a.el" "+++ b/a.el" "@@ -15,3 +15,3 @@"
                      " (setq a15 15)" " (setq a16 16)" " (setq a17 17)")))))
    ;; One quoted line above is too little when it is not there as it was.
    (should (equal '(:side new :line nil :was 18 :status gone)
                   (change-review-diff-relocate eighteen cut)))))

;;;; The library compiles

(ert-deftest change-review-diff-compiles-without-a-warning ()
  "The library byte-compiles without a warning."
  (let* ((dir (make-temp-file "change-review-diff-elc" t))
         (byte-compile-dest-file-function (lambda (_) (expand-file-name "change-review-diff.elc" dir)))
         (byte-compile-error-on-warn t)
         (load-path (cons change-review-diff-test--directory load-path)))
    (unwind-protect
        (should (byte-compile-file (expand-file-name "change-review-diff.el"
                                                     change-review-diff-test--directory)))
      (delete-directory dir t))))

(provide 'change-review-diff-test)
;;; change-review-diff-test.el ends here
