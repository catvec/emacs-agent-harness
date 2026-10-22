;;; change-review-ui-test.el --- Tests for the user interface of change-review  -*- lexical-binding: t; -*-

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

;; The tests of change-review-ui.el: the one drawing of a thread, the
;; threads view with its filter and its keys, the diff view with the
;; threads under its lines, and the commands that act on a comment or a
;; thread.  They need nothing but the library: `make test' runs them in
;; an Emacs with only this directory on its load path.  Times are fixed,
;; in UTC, and the text a comment is read from is given, not asked for.

;;; Code:

(require 'ert)
(require 'bytecomp)
(require 'cl-lib)
(require 'change-review)
(require 'change-review-ui)

(defconst change-review-ui-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "The directory of the library and its tests.")

(defconst change-review-ui-test--now 1792000000.0
  "The time the tests draw at: 2026-10-14 17:46:40 UTC.")

(defconst change-review-ui-test--patch
  (concat "diff --git a/a.el b/a.el\n"
          "index 1111111..2222222 100644\n"
          "--- a/a.el\n"
          "+++ b/a.el\n"
          "@@ -1,6 +1,6 @@\n"
          " (setq a1 1)\n"
          "-(setq a2 2)\n"
          "+(setq a2 'two)\n"
          " (setq a3 3)\n"
          " (setq a4 4)\n"
          " (setq a5 5)\n"
          " (setq a6 6)\n"
          "diff --git a/b.el b/b.el\n"
          "index 3333333..4444444 100644\n"
          "--- a/b.el\n"
          "+++ b/b.el\n"
          "@@ -1,3 +1,3 @@\n"
          " (setq b1 1)\n"
          "-(setq b2 2)\n"
          "+(setq b2 'two)\n"
          " (setq b3 3)\n")
  "A diff of two files, one hunk each.")

(defconst change-review-ui-test--patch-answered
  (concat "diff --git a/a.el b/a.el\n"
          "index 1111111..5555555 100644\n"
          "--- a/a.el\n"
          "+++ b/a.el\n"
          "@@ -1,6 +1,8 @@\n"
          "+(setq top1 1)\n"
          "+(setq top2 2)\n"
          " (setq a1 1)\n"
          "-(setq a2 2)\n"
          "+(setq a2 'three)\n"
          " (setq a3 3)\n"
          " (setq a4 4)\n"
          " (setq a5 5)\n"
          " (setq a6 6)\n")
  "The diff of a.el once the answer to a comment changed it: two lines at
the top, so a3 is on line 5 now, and a2 is edited again.")

(defmacro change-review-ui-test--drawing (&rest body)
  "Run BODY with times fixed: UTC, and the present `change-review-ui-test--now'.
Relative times are off, so a drawing does not change with the clock."
  (declare (indent 0))
  `(let ((change-review-ui-relative-times nil)
         (change-review-ui-width 80)
         (change-review-ui-time-format "%Y-%m-%d %H:%M")
         (zone (current-time-zone)))
     (ignore zone)
     (set-time-zone-rule "UTC")
     (unwind-protect (progn ,@body)
       (set-time-zone-rule nil))))

(defun change-review-ui-test--author ()
  "Return the user of the tests."
  (change-review-user "Noah" "noah@example.org"))

(cl-defstruct (change-review-ui-test--set (:include change-review-set)) followed)

(cl-defmethod change-review-current-author ((_set change-review-ui-test--set))
  (change-review-ui-test--author))

(cl-defmethod change-review-follow-author ((set change-review-ui-test--set) author)
  (push author (change-review-ui-test--set-followed set)))

(cl-defstruct (change-review-ui-test--spy-set (:include change-review-ui-test--set))
  visited)

(cl-defmethod change-review-visit ((set change-review-ui-test--spy-set) target &optional version)
  (push (list target version) (change-review-ui-test--spy-set-visited set)))

(defun change-review-ui-test--set ()
  "Return a set with two versions of two files and no thread."
  (let ((set (make-change-review-ui-test--set :id "change-1" :title "Fix the flaky test")))
    (dolist (spec '(("1111111111111111111111111111111111111111" "first")
                    ("2222222222222222222222222222222222222222" "second")))
      (change-review-add-version
       set (change-review-diff-version change-review-ui-test--patch
                                       :id (car spec) :label (cadr spec)
                                       :time change-review-ui-test--now)))
    set))

(defvar change-review-ui-test--reviewed nil
  "Non-nil: `change-review-ui-test--populate' marks the agent's close reviewed.
It is a thread that waits for the user's review otherwise, drawn whole.")

(defun change-review-ui-test--populate (set)
  "Put threads in SET and return them as (A B C D).
A is on a.el with three comments, the third a draft answering the first;
B is on b.el and closed; C is on the change as a whole; D on a.el, open."
  (let* ((noah (change-review-ui-test--author))
         (bot (change-review-agent "Claude" :session "sess-1" :tool-call "toolu_9"))
         (where (lambda (file line side)
                  (change-review-diff-location
                   (cl-find file (change-review-version-files (change-review-latest-version set))
                            :key #'change-review-file-path :test #'equal)
                   side line)))
         (rev (change-review-version-id (change-review-latest-version set)))
         (a1 (change-review-comment set "Why 'two?\nSecond line of the question."
                                    :author noah :time (- change-review-ui-test--now 7200)
                                    :revision rev :sent (- change-review-ui-test--now 7000)
                                    :location (funcall where "a.el" 3 'new)))
         (a2 (change-review-reply set a1 "Because the retry loop needs it."
                                  :author bot :time (- change-review-ui-test--now 3600)
                                  :revision rev :sent (- change-review-ui-test--now 3600)))
         (_a3 (change-review-reply set a1 "Then say so in a comment." :author noah
                                   :time (- change-review-ui-test--now 60) :revision rev))
         (b1 (change-review-comment set "Fine." :author noah :time (- change-review-ui-test--now 5000)
                                    :revision rev :sent (- change-review-ui-test--now 5000)
                                    :location (funcall where "b.el" 2 'new)))
         (c1 (change-review-comment set "Overall: good." :author noah
                                    :time (- change-review-ui-test--now 4000)
                                    :revision rev :sent (- change-review-ui-test--now 4000)))
         (d1 (change-review-comment set "What about a4?" :author noah
                                    :time (- change-review-ui-test--now 100) :revision rev
                                    :location (funcall where "a.el" 4 'new))))
    (ignore a2)
    (change-review-close set (change-review-comment-thread b1) :author bot
                         :time (- change-review-ui-test--now 1800))
    (when change-review-ui-test--reviewed
      (change-review-mark-reviewed set (change-review-comment-thread b1)
                                   :time change-review-ui-test--now))
    (mapcar (lambda (comment)
              (change-review-find-thread set (change-review-comment-thread comment)))
            (list a1 b1 c1 d1))))

(defun change-review-ui-test--answered-set (&optional spy no-files)
  "Return (SET THREAD ROOT REPLY): a comment on a3, answered once a3 moved.
The set has the versions `first' and `second', whose diffs of a.el
differ.  The user's comment is on line 3 of the first; the agent's answer
was written against the second, where that line is line 5.  With SPY the
set records what `change-review-visit' is asked; with NO-FILES the second
version has no files, as a version a program has not read yet."
  (let ((set (funcall (if spy #'make-change-review-ui-test--spy-set #'make-change-review-ui-test--set)
                      :id "change-1" :title "Fix the flaky test")))
    (change-review-add-version
     set (change-review-diff-version change-review-ui-test--patch
                                     :id "1111111111111111111111111111111111111111" :label "first"
                                     :time change-review-ui-test--now))
    (change-review-add-version
     set (if no-files
             (change-review-make-version :id "2222222222222222222222222222222222222222" :label "second"
                                         :time change-review-ui-test--now)
           (change-review-diff-version change-review-ui-test--patch-answered
                                       :id "2222222222222222222222222222222222222222" :label "second"
                                       :time change-review-ui-test--now)))
    (let* ((file (car (change-review-version-files (change-review-find-version set "first"))))
           (root (change-review-comment
                  set "Why 'two?" :author (change-review-ui-test--author)
                  :time (- change-review-ui-test--now 7200)
                  :revision "1111111111111111111111111111111111111111" :sent (- change-review-ui-test--now 7000)
                  :location (change-review-diff-location file 'new 3)))
           (reply (change-review-reply
                   set root "Done: it is 'three now."
                   :author (change-review-agent "Claude" :session "sess-1" :tool-call "toolu_9")
                   :time (- change-review-ui-test--now 3600)
                   :revision "2222222222222222222222222222222222222222"
                   :sent (- change-review-ui-test--now 3600))))
      (list set (change-review-find-thread set (change-review-comment-thread root)) root reply))))

(defun change-review-ui-test--lines (string)
  "Return the lines of STRING without properties."
  (split-string (substring-no-properties string) "\n" t))

(defun change-review-ui-test--button (string label)
  "Return where the button labelled LABEL starts in STRING, or nil."
  (let ((pos 0) found)
    (while (and (not found) (setq pos (next-single-property-change pos 'button string)))
      (when (and (get-text-property pos 'button string)
                 (string-prefix-p label (substring-no-properties string pos)))
        (setq found pos)))
    (or found
        (and (get-text-property 0 'button string)
             (string-prefix-p label (substring-no-properties string 0)) 0))))

(defun change-review-ui-test--press-nth (string label n)
  "Press the Nth (from 0) button labelled LABEL in STRING, as a click would."
  (let (starts (pos 0))
    (while (setq pos (next-single-property-change pos 'button string))
      (when (and (get-text-property pos 'button string)
                 (string-prefix-p label (substring-no-properties string pos)))
        (push pos starts)))
    (when (and (get-text-property 0 'button string)
               (string-prefix-p label (substring-no-properties string 0)))
      (push 0 starts))
    (setq starts (sort starts #'<))
    (with-temp-buffer
      (insert string)
      (push-button (1+ (or (nth n starts) (error "No button %d %s in %S" n label (substring-no-properties string))))))))

(defun change-review-ui-test--press (string label)
  "Press the button labelled LABEL in STRING, as a click would."
  (let ((pos (or (change-review-ui-test--button string label)
                 (error "No button %s in %S" label (substring-no-properties string)))))
    (with-temp-buffer
      (insert string)
      (push-button (1+ pos)))))

;;;; Time and width

(ert-deftest change-review-ui-says-how-long-ago ()
  "A time reads as minutes, hours, days, months or years ago."
  (let ((now 1000000000.0))
    (should (equal "just now" (change-review-ui-ago (- now 10) now)))
    (should (equal "5m ago" (change-review-ui-ago (- now 300) now)))
    (should (equal "2h ago" (change-review-ui-ago (- now 7200) now)))
    (should (equal "3d ago" (change-review-ui-ago (- now (* 3 86400)) now)))
    (should (equal "2mo ago" (change-review-ui-ago (- now (* 70 86400)) now)))
    (should (equal "3y ago" (change-review-ui-ago (- now (* 3 365 86400)) now)))
    (should (equal "in the future" (change-review-ui-ago (+ now 3600) now)))))

(ert-deftest change-review-ui-wraps-long-lines-at-spaces ()
  "A line is cut at a space within the width; a word longer than the width
is cut inside; a short line and the empty one stay whole."
  (should (equal '("short") (change-review-ui--wrap "short" 20)))
  (should (equal '("") (change-review-ui--wrap "" 20)))
  (should (equal '("the quick brown" "fox jumps over" "the lazy dog")
                 (change-review-ui--wrap "the quick brown fox jumps over the lazy dog" 16)))
  (should (equal '("abcdefghij" "klmnopqrst" "uv") (change-review-ui--wrap "abcdefghijklmnopqrstuv" 10)))
  (should (equal '("see" "abcdefghij" "klm") (change-review-ui--wrap "see abcdefghijklm" 10)))
  (dolist (piece (change-review-ui--wrap (string-join (make-list 30 "word") " ") 30))
    (should (<= (string-width piece) 30))))

;;;; Drawing a thread

(ert-deftest change-review-ui-draws-a-thread ()
  "The thread says who wrote each comment, when, against which revision,
whether it is a draft, and where it is in the thread."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (car (change-review-ui-test--populate set)))
           (lines (change-review-ui-test--lines
                   (change-review-ui-thread-string set thread :view 'threads :width 90))))
      (should (string-match-p
               (format "\\`● %s · line 3 · 3 comments · open +\\[Reply\\] \\[Close\\] \\[Diff\\]\\'"
                       (change-review-ui-thread-short-id set thread))
               (nth 0 lines)))
      (should (equal "┃ 1/3  Noah (you) · 2026-10-14 15:46 · second  ▸ where" (nth 1 lines)))
      (should (equal "┃      Why 'two?" (nth 2 lines)))
      (should (equal "┃      Second line of the question." (nth 3 lines)))
      (should (equal "┃ 2/3  Claude (agent) · 2026-10-14 16:46 · second  ↗ conversation  ▸ where"
                     (nth 4 lines)))
      (should (equal "┃      Because the retry loop needs it." (nth 5 lines)))
      ;; The third answers the first, not the one before it, and is a draft.
      ;; (and the one comment that can still be changed has its button.)
      (should (equal "┃ 3/3  Noah (you) · 2026-10-14 17:45 · second · draft · ↳ re 1/3  [Edit]  ▸ where"
                     (nth 6 lines)))
      (should (equal "┃      Then say so in a comment." (nth 7 lines)))
      (should (= 8 (length lines))))))

(ert-deftest change-review-ui-marks-what-the-text-is-about ()
  "The text carries the ids of its thread and its comments, and where each starts."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (car (change-review-ui-test--populate set)))
           (string (change-review-ui-thread-string set thread :width 80))
           (ids (mapcar #'change-review-comment-id (change-review-thread-comments thread))))
      (should (string-suffix-p "\n" string))
      (should (equal (change-review-thread-id thread) (get-text-property 0 'change-review-thread string)))
      (should (equal (change-review-thread-id thread)
                     (get-text-property (1- (length string)) 'change-review-thread string)))
      (should (get-text-property 0 'change-review-thread-start string))
      ;; The comments, in order, each beginning at its header line.
      (let (seen (pos 0))
        (while (setq pos (next-single-property-change pos 'change-review-comment-start string))
          (when (get-text-property pos 'change-review-comment-start string)
            (push (get-text-property pos 'change-review-comment string) seen)))
        (when (get-text-property 0 'change-review-comment-start string)
          (push (get-text-property 0 'change-review-comment string) seen))
        (should (equal ids (reverse seen)))))))

(ert-deftest change-review-ui-draws-a-closed-thread-and-who-closed-it ()
  "A closed thread says closed, by whom and when, and can be one line.
This one the agent closed, so it waits for the user's review as well."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (nth 1 (change-review-ui-test--populate set)))
           (lines (change-review-ui-test--lines (change-review-ui-thread-string set thread :width 120))))
      (should (string-match-p "\\`✓ [^ ]+ · line 2 · 1 comment · closed by Claude, 2026-10-14 17:16 · to review +\\[Reply\\] \\[Reopen\\] \\[Mark reviewed\\] \\[Diff\\]\\'"
                              (car lines)))
      (should (= 3 (length lines)))
      (let ((one (change-review-ui-test--lines
                  (change-review-ui-thread-string set thread :width 90 :collapsed t :view 'diff))))
        (should (= 1 (length one)))
        (should (string-match-p "“Fine\\.”\\'" (car one)))
        (should-not (string-match-p "line 2" (car one)))))))

(ert-deftest change-review-ui-draws-where-a-comment-was-made ()
  "Details add the file, the line, the revision and the diff lines quoted."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (car (change-review-ui-test--populate set)))
           (root (change-review-thread-root thread))
           (plain (change-review-ui-test--lines (change-review-ui-thread-string set thread :width 90)))
           (lines (change-review-ui-test--lines
                   (change-review-ui-thread-string set thread :width 90
                                                   :details (list (change-review-comment-id root))))))
      (should (> (length lines) (length plain)))
      ;; Written against the newest version: one button to the source.
      (should (member "┃      made at a.el:3 · revision second (2222222)  [Source]" lines))
      (should (cl-some (lambda (line) (string-match-p "│ @@ " line)) lines))
      (should (member "┃      │  (setq a3 3)  ◀" lines))
      (should (member "┃      │ +(setq a2 'two)" lines))
      ;; The line the comment is on is the last, and marked.
      (should (equal "┃      │  (setq a3 3)  ◀"
                     (car (last (seq-take-while (lambda (line) (string-prefix-p "┃      │" line))
                                                (member "┃      │ @@ -1,3 +1,3 @@" lines))))))
      ;; Everything at once.
      (should (> (length (change-review-ui-test--lines
                          (change-review-ui-thread-string set thread :width 90 :details t)))
                 (length lines))))))

(ert-deftest change-review-ui-says-what-an-agent-came-from ()
  "The details of an agent's comment name its session and tool call."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (car (change-review-ui-test--populate set)))
           (bot-comment (nth 1 (change-review-thread-comments thread)))
           (lines (change-review-ui-test--lines
                   (change-review-ui-thread-string set thread :width 90
                                                   :details (list (change-review-comment-id bot-comment))))))
      (should (member "┃      from the conversation · session sess-1 · call toolu_9" lines)))))

(ert-deftest change-review-ui-wraps-comments-under-their-bar ()
  "A long line of a comment wraps to the width, under the bar."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (comment (change-review-comment set (string-join (make-list 40 "wordy") " ")
                                           :author (change-review-ui-test--author) :time change-review-ui-test--now))
           (thread (change-review-find-thread set (change-review-comment-thread comment)))
           (lines (change-review-ui-test--lines (change-review-ui-thread-string set thread :width 50))))
      (should (> (length lines) 4))
      ;; The text wraps; the header lines are as long as they are.
      (dolist (line (cddr lines))
        (should (<= (string-width line) 50))
        (should (string-prefix-p "┃      wordy" line))))))

(ert-deftest change-review-ui-names-a-thread-by-the-shortest-unique-id ()
  "The short id of a thread is a prefix of its id no other thread shares."
  (let* ((set (change-review-make-set))
         (a (change-review-apply set (list :op 'add-comment :thread "t-abcdef01" :comment '(:id "c-1" :body "a"))))
         (b (change-review-apply set (list :op 'add-comment :thread "t-abcdef99" :comment '(:id "c-2" :body "b"))))
         (c (change-review-apply set (list :op 'add-comment :thread "t-123456ff" :comment '(:id "c-3" :body "c")))))
    (ignore a b c)
    (let ((threads (change-review-set-threads set)))
      (should (equal "t-abcdef0" (change-review-ui-thread-short-id set (nth 0 threads))))
      (should (equal "t-abcdef9" (change-review-ui-thread-short-id set (nth 1 threads))))
      (should (equal "t-1234" (change-review-ui-thread-short-id set (nth 2 threads)))))))

(ert-deftest change-review-ui-buttons-act-on-the-thread ()
  "[Reply], [Close] and [Reopen] do what they say."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (car (change-review-ui-test--populate set)))
           (change-review-ui-read-function (lambda (_prompt _initial callback) (funcall callback "A reply"))))
      (change-review-ui-test--press (change-review-ui-thread-string set thread :width 90) "[Close]")
      (should-not (change-review-thread-open-p thread))
      (change-review-ui-test--press (change-review-ui-thread-string set thread :width 90) "[Reopen]")
      (should (change-review-thread-open-p thread))
      (should (equal '(closed open) (mapcar (lambda (e) (plist-get e :status))
                                            (change-review-thread-history thread))))
      (change-review-ui-test--press (change-review-ui-thread-string set thread :width 90) "[Reply]")
      (let ((last (change-review-thread-last-comment thread)))
        (should (equal "A reply" (change-review-comment-body last)))
        (should (change-review-comment-draft-p last))
        (should (equal (change-review-comment-id (nth 2 (change-review-thread-comments thread)))
                       (change-review-comment-reply-to last))))
      (change-review-ui-test--press (change-review-ui-thread-string set thread :width 90) "↗ conversation")
      (should (equal "sess-1" (change-review-author-session
                                (car (change-review-ui-test--set-followed set))))))))

;; The comment that can still be changed has a button of its own.

(ert-deftest change-review-ui-draws-an-edit-button-on-a-draft-only ()
  "A draft has [Edit] in its header, a comment that was sent has none."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (car (change-review-ui-test--populate set)))
           (string (change-review-ui-thread-string set thread :width 90))
           (headers (cl-remove-if-not (lambda (line) (string-match-p "\\`┃ [0-9]/" line))
                                      (change-review-ui-test--lines string))))
      (should (= 3 (length headers)))
      (should-not (string-search "[Edit]" (nth 0 headers)))
      (should-not (string-search "[Edit]" (nth 1 headers)))
      (should (string-match-p "· draft · ↳ re 1/3  \\[Edit\\]  ▸ where\\'" (nth 2 headers)))
      ;; One button, on the line of the draft, which says what it does.
      (let ((pos (change-review-ui-test--button string "[Edit]")))
        (should pos)
        (should (equal "Edit this draft" (get-text-property pos 'help-echo string)))
        (should (equal (change-review-comment-id (change-review-thread-last-comment thread))
                       (get-text-property pos 'change-review-comment string)))
        (should-not (change-review-ui-test--button (substring string (1+ pos)) "[Edit]")))
      ;; Closed, and one line: no button, the thread is read, not changed.
      (should-not (string-search "[Edit]" (change-review-ui-thread-string
                                           set thread :width 90 :collapsed t))))))

(ert-deftest change-review-ui-edit-button-edits-that-draft ()
  "[Edit] edits the draft it is on, the first of two as well as the last:
the text to start from is that draft's, and what is read replaces it."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (car (change-review-ui-test--populate set)))
           (first (change-review-thread-last-comment thread))
           (second (change-review-reply set first "And name the test."
                                        :author (change-review-ui-test--author)
                                        :time (- change-review-ui-test--now 30)))
           (asked nil)
           (change-review-ui-read-function
            (lambda (prompt initial callback)
              (push (cons prompt initial) asked)
              (funcall callback (concat initial " (better)")))))
      (should (= 2 (length (change-review-thread-drafts thread))))
      (change-review-ui-test--press-nth (change-review-ui-thread-string set thread :width 90) "[Edit]" 0)
      (should (equal "Then say so in a comment. (better)" (change-review-comment-body first)))
      (should (equal "And name the test." (change-review-comment-body second)))
      (should (string-match-p "\\`Edit Noah's comment 3/4 on a\\.el:3:" (car (car asked))))
      (should (equal "Then say so in a comment." (cdr (car asked))))
      (should (change-review-comment-edited first))
      ;; The second, the other button of the same drawing.
      (change-review-ui-test--press-nth (change-review-ui-thread-string set thread :width 90) "[Edit]" 1)
      (should (equal "And name the test. (better)" (change-review-comment-body second)))
      (should (string-match-p "\\`Edit Noah's comment 4/4" (car (car asked))))
      ;; Both are still drafts, and the thread has the same comments.
      (should (= 2 (length (change-review-thread-drafts thread))))
      (should (= 4 (length (change-review-thread-comments thread)))))))

(ert-deftest change-review-ui-edit-keeps-what-was-sent-meanwhile ()
  "A draft sent while its new text was written is not changed -- it was read
as it was -- and the text is not lost: it is in the kill ring.  A blank text
changes nothing either, and neither does one for a draft that is gone."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (car (change-review-ui-test--populate set)))
           (draft (change-review-thread-last-comment thread))
           (kill-ring nil)
           (said nil))
      (cl-letf (((symbol-function 'message) (lambda (&rest args) (setq said (apply #'format args)))))
        ;; Sent while the text is written.
        (let ((change-review-ui-read-function
               (lambda (_prompt _initial callback)
                 (change-review-mark-sent set (list draft))
                 (funcall callback "Too late."))))
          (change-review-ui-edit-comment set thread draft))
        (should (equal "Then say so in a comment." (change-review-comment-body draft)))
        (should (equal '("Too late.") kill-ring))
        (should (string-match-p "sent meanwhile" said))
        ;; What is sent cannot be edited at all.
        (should-error (change-review-ui-edit-comment set thread draft) :type 'user-error)
        ;; A blank text is no change, nor is the same one.
        (let ((other (change-review-reply set draft "Another." :author (change-review-ui-test--author)))
              (change-review-ui-read-function (lambda (_prompt _initial callback) (funcall callback " \n "))))
          (change-review-ui-edit-comment set thread other)
          (should (equal "Another." (change-review-comment-body other)))
          (should (equal "No change" said))
          (should-not (change-review-comment-edited other))
          (setq said nil)
          (let ((change-review-ui-read-function (lambda (_prompt initial callback) (funcall callback (concat initial "\n")))))
            (change-review-ui-edit-comment set thread other))
          (should (equal "No change" said))
          (should-not (change-review-comment-edited other))
          ;; Deleted meanwhile: nothing to change.
          (let ((change-review-ui-read-function
                 (lambda (_prompt _initial callback)
                   (change-review-delete set other)
                   (funcall callback "Gone."))))
            (change-review-ui-edit-comment set thread other))
          (should (string-match-p "gone" said))
          (should (equal '("Too late.") kill-ring)))))))

(ert-deftest change-review-ui-chooses-a-draft-among-several ()
  "The only draft is the one to act on, without a question; of several, the
prompt lists them in order by thread, place and first words, the newest being
the default, and what is chosen is the draft."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (a (nth 0 threads)) (d (nth 3 threads))
           (a3 (change-review-thread-last-comment a))
           (d1 (change-review-thread-root d))
           (asked nil))
      (should (equal (list (cons a a3) (cons d d1))
                     (change-review-ui-draft-candidates (list a (nth 1 threads) (nth 2 threads) d))))
      ;; One draft: no question.
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "asked which of one"))))
        (should (equal (cons a a3) (change-review-ui-choose-draft set (list (cons a a3)))))
        (should-not (change-review-ui-choose-draft set nil)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table _predicate _require _initial _hist default &rest _)
                   (setq asked (list prompt (all-completions "" table)
                                     (completion-metadata "" table nil) default))
                   (car (all-completions "" table)))))
        (let ((choice (change-review-ui-choose-draft set (list (cons a a3) (cons d d1)) "Delete")))
          (should (equal (cons a a3) choice)))
        ;; The prompt says what RET takes: the newest.
        (should (equal (format "Delete which draft (default %s): " (nth 3 asked)) (nth 0 asked)))
        (should (equal (list (format "%s 3/3  Then say so in a comment." (change-review-ui-thread-short-id set a))
                             (format "%s 1/1  What about a4?" (change-review-ui-thread-short-id set d)))
                       (nth 1 asked)))
        ;; In the order given, not sorted by the completion UI.
        (should (eq 'identity (alist-get 'display-sort-function (cdr (nth 2 asked)))))
        (should (equal (nth 1 (nth 1 asked)) (nth 3 asked))))
      ;; An answer that is none of the drafts is no draft.
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "something else")))
        (should-error (change-review-ui-choose-draft set (list (cons a a3) (cons d d1)))
                      :type 'user-error)))))

(ert-deftest change-review-ui-draws-a-thread-as-a-line ()
  "A thread in a list is a line: mark, id, line, who wrote it and the first
words, how many comments, and whether one is a draft."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (a (change-review-thread-id (car threads)))
           (one (change-review-ui-thread-line set (car threads) :width 100))
           (closed (change-review-ui-thread-line set (nth 1 threads) :width 100)))
      (ignore a)
      (should (string-suffix-p "\n" one))
      (should (= 1 (length (change-review-ui-test--lines one))))
      (should (string-match-p "\\`● [^ ]+ · line 3 · Noah: “Why 'two\\? Second line of the question\\.” · 3 comments · draft\\'"
                              (car (change-review-ui-test--lines one))))
      ;; The agent closed this one: it waits for the user's review.
      (should (string-match-p "\\`✓ [^ ]+ · line 2 · Noah: “Fine\\.” · to review\\'"
                              (car (change-review-ui-test--lines closed))))
      (change-review-mark-reviewed set (nth 1 threads))
      (should (string-match-p "\\`✓ [^ ]+ · line 2 · Noah: “Fine\\.”\\'"
                              (car (change-review-ui-test--lines
                                    (change-review-ui-thread-line set (nth 1 threads) :width 100)))))
      (should (equal (change-review-thread-id (car threads))
                     (get-text-property 0 'change-review-thread one)))
      ;; Too narrow for the words: they are cut.
      (should (string-match-p "…”" (change-review-ui-thread-line set (car threads) :width 40)))
      ;; Where it is now.
      (should (string-match-p "line 9 (was 3)"
                              (change-review-ui-thread-line
                               set (car threads) :width 100
                               :placement '(:side new :line 9 :was 3 :status moved)))))))

;;;; The text of a comment

;; A kind of set whose comments are a markup: a line that starts with
;; "!" is drawn bold without it, one that starts with "~" ends in a
;; newline of its own whose face reaches the window's edge, and the
;; width the drawing gave is remembered.
(cl-defstruct (change-review-ui-test--markup-set (:include change-review-set)) widths)

(cl-defmethod change-review-ui-body-lines ((set change-review-ui-test--markup-set) comment width)
  (push width (change-review-ui-test--markup-set-widths set))
  (mapcar (lambda (line)
            (cond ((string-prefix-p "!" line)
                   (propertize (substring line 1) 'face 'bold))
                  ((string-prefix-p "~" line)
                   (concat (substring line 1) (propertize "\n" 'face 'highlight)))
                  (t line)))
          (split-string (change-review-comment-body comment) "\n")))

(cl-defmethod change-review-ui-body-summary ((_set change-review-ui-test--markup-set) comment)
  (let ((text (string-replace "\n" " " (change-review-comment-body comment))))
    (if (string-prefix-p "!" text) (propertize (substring text 1) 'face 'bold) text)))

(defun change-review-ui-test--markup-thread (body)
  "Return (SET . THREAD): a markup set with one thread whose only comment says BODY."
  (let* ((set (make-change-review-ui-test--markup-set :id "markup" :title "Markup"))
         (comment (change-review-comment set body :author (change-review-ui-test--author)
                                         :time change-review-ui-test--now)))
    (cons set (change-review-find-thread set (change-review-comment-thread comment)))))

(ert-deftest change-review-ui-asks-the-set-for-the-text-of-a-comment ()
  "A kind of set draws the text of its comments itself: each line it gives is
put after the bar, keeps its faces and carries its comment; one that
ends in a newline of its own is not given another; the width it is
given is what the bar leaves."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set . ,thread) (change-review-ui-test--markup-thread "plain\n!bold\n~extends\nlast"))
                 (string (change-review-ui-thread-string set thread :width 80 :indent "  "))
                 (lines (change-review-ui-test--lines string))
                 (id (change-review-comment-id (change-review-thread-root thread))))
      ;; The indent, the bar, and the six columns the comment's place in
      ;; the thread takes: nine columns of the eighty.
      (should (equal '(71) (change-review-ui-test--markup-set-widths set)))
      ;; The thread's header, the comment's, then its four lines.
      (should (= 6 (length lines)))
      (should (equal '("  ┃      plain" "  ┃      bold" "  ┃      extends" "  ┃      last")
                     (nthcdr 2 lines)))
      (let ((pos (string-search "bold" string)))
        (should (eq 'bold (get-text-property pos 'face string)))
        (should (eq 'bold (get-text-property (+ pos 3) 'face string)))
        (should-not (get-text-property (+ pos 4) 'face string)))
      ;; The newline it brought is the line's end, in its face.
      (let ((pos (+ (string-search "extends" string) (length "extends"))))
        (should (equal "\n" (substring-no-properties string pos (1+ pos))))
        (should (eq 'highlight (get-text-property pos 'face string))))
      (should-not (string-search "\n\n" (substring-no-properties string)))
      ;; Every line of the text is its comment's.
      (dolist (word '("plain" "bold" "extends" "last"))
        (should (equal id (get-text-property (string-search word string) 'change-review-comment string)))))))

(ert-deftest change-review-ui-asks-the-set-for-the-first-words ()
  "A thread drawn as a line, or collapsed, is named by what the set says
its first comment starts with: cut to the room there is, in the meta face
under the faces it brings."
  (change-review-ui-test--drawing
    (pcase-let ((`(,set . ,thread) (change-review-ui-test--markup-thread "!bold words and more")))
      (dolist (string (list (change-review-ui-thread-line set thread :width 100)
                            (change-review-ui-thread-string set thread :width 100 :collapsed t :view 'diff)))
        (should (string-match-p "“bold words and more”" (substring-no-properties string)))
        ;; Its own face, and the meta face beneath.
        (should (equal '(bold change-review-ui-meta-face)
                       (get-text-property (string-search "bold words" string) 'face string)))
        ;; The quotes are in the meta face alone.
        (should (eq 'change-review-ui-meta-face
                    (get-text-property (string-search "“" string) 'face string))))
      ;; Too little room: cut, with the ellipsis.
      (let ((narrow (substring-no-properties (change-review-ui-thread-line set thread :width 40))))
        (should (string-match-p "bold words …”" narrow))
        (should-not (string-search "and more" narrow))))))

(ert-deftest change-review-ui-draws-the-text-as-typed-for-a-plain-set ()
  "A plain set draws the lines its author typed, each wrapped, with no markup."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (comment (change-review-comment set "**not bold**\n`not code`\n- not a list"
                                           :author (change-review-ui-test--author)
                                           :time change-review-ui-test--now))
           (thread (change-review-find-thread set (change-review-comment-thread comment))))
      (should (equal '("**not bold**" "`not code`" "- not a list")
                     (change-review-ui-body-lines set comment 40)))
      (should (equal "**not bold** `not code` - not a list" (change-review-ui-body-summary set comment)))
      (should (member "┃      **not bold**"
                      (change-review-ui-test--lines (change-review-ui-thread-string set thread :width 80)))))))

;;;; Fitting a thread to its room

(defun change-review-ui-test--widest (string)
  "Return the width of the widest line of STRING."
  (apply #'max 0 (mapcar #'string-width (change-review-ui-test--lines string))))

(defun change-review-ui-test--thread-kinds (set threads)
  "Return threads of SET to draw, as (NAME . THREAD): every kind there is.
THREADS are those `change-review-ui-test--populate' made.  Added: one a
user of another name closed, one an agent answered, and one whose place moved."
  (let* ((agent (change-review-agent "A Claude with a long name (Fable 5.1)" :session "s-1" :tool-call "t-1"))
         (stranger (change-review-make-author :kind 'other :name "Bob Reviewer" :email "bob@example.org"))
         (long (change-review-comment
                set (concat "Is this right? "
                            (string-join (make-list 30 "A long question that goes on and on") " "))
                :author (change-review-ui-test--author) :time change-review-ui-test--now
                :revision "2222222222222222222222222222222222222222"))
         (by-bob (change-review-comment
                  set "Looks wrong to me." :author stranger :time change-review-ui-test--now
                  :revision "2222222222222222222222222222222222222222")))
    (change-review-reply set long "Yes: the retry loop needs one more." :author agent
                         :time change-review-ui-test--now :sent change-review-ui-test--now)
    (change-review-close set (change-review-comment-thread by-bob) :author stranger
                         :time (- change-review-ui-test--now 90000))
    (list (cons 'open (nth 0 threads)) (cons 'closed-by-agent (nth 1 threads))
          (cons 'change (nth 2 threads)) (cons 'draft (nth 3 threads))
          (cons 'long (change-review-find-thread set (change-review-comment-thread long)))
          (cons 'closed-by-stranger (change-review-find-thread set (change-review-comment-thread by-bob))))))

(ert-deftest change-review-ui-never-draws-a-line-wider-than-its-width ()
  "However little room it has, a thread is drawn to it: no line of any
kind of thread, in any view or fold, is wider than the width, down to the
least there is, 40 columns."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (kinds (change-review-ui-test--thread-kinds set (change-review-ui-test--populate set))))
      (dolist (relative '(nil t))
        (let ((change-review-ui-relative-times relative))
          (dolist (width '(40 45 53 60 80 100 120 160))
            (dolist (kind kinds)
              (dolist (view '(threads diff))
                (dolist (fold '(nil collapsed expanded full))
                  (dolist (indent '("" "  " "    "))
                    (let ((string (change-review-ui-thread-string
                                   set (cdr kind) :view view :width width :indent indent
                                   :fold fold :max-lines 12
                                   :placement '(:side new :line 9 :was 3 :status moved))))
                      (ert-info ((format "%s %s %s fold %s indent %S relative %s" (car kind) view width fold
                                         indent relative))
                        (should (<= (change-review-ui-test--widest string) width))))))))))))))

(ert-deftest change-review-ui-says-less-of-a-closed-thread-in-less-room ()
  "What a closed thread was closed by and when goes from all of it, to how
long ago, to who, to nothing; the count of comments and the buttons go last."
  (let ((change-review-ui-test--reviewed t))
  (change-review-ui-test--drawing
    (cl-letf (((symbol-function 'float-time) (lambda (&rest _) change-review-ui-test--now))
              (change-review-ui-relative-times t))
      (let* ((set (change-review-ui-test--set))
             (thread (nth 1 (change-review-ui-test--populate set)))
             (header (lambda (width)
                       (car (change-review-ui-test--lines
                             (change-review-ui-thread-string set thread :view 'diff :width width))))))
        ;; The thread was closed by an agent, so it says so as long as it can.
        (should (string-suffix-p "· closed by Claude, 2026-10-14 17:16 (30m ago) · reviewed   [Reply] [Reopen]"
                                 (funcall header 120)))
        (should (string-suffix-p "· closed by Claude · reviewed   [Reply] [Reopen]" (funcall header 70)))
        (should (string-suffix-p "· 1 comment · closed · reviewed   [Reply] [Reopen]" (funcall header 60)))
        (should (string-suffix-p "· closed · reviewed   [Reply] [Reopen]" (funcall header 50)))
        (should (string-match-p "\\`✓ [^ ]+ · closed · reviewed\\'" (funcall header 45)))
        (should (string-match-p "\\`✓ [^ ]+ · closed · revi…\\'" (funcall header 25))))))))

(ert-deftest change-review-ui-says-who-closed-a-thread-unless-it-was-you ()
  "A shortened status leaves out that the user closed the thread, not that
someone else did."
  (change-review-ui-test--drawing
    (cl-letf (((symbol-function 'float-time) (lambda (&rest _) change-review-ui-test--now))
              (change-review-ui-relative-times t))
      (let* ((set (change-review-ui-test--set))
             (threads (change-review-ui-test--populate set))
             (mine (nth 3 threads))
             (theirs (nth 1 threads))
             (status (lambda (thread &optional brief)
                       (substring-no-properties (change-review-ui--status-text set thread brief)))))
        (change-review-close set mine :author (change-review-ui-test--author)
                             :time (- change-review-ui-test--now 7200))
        (should (equal "closed by Noah (you), 2026-10-14 15:46 (2h ago)" (funcall status mine)))
        (should (equal "closed 2h ago" (funcall status mine 'short)))
        (should (equal "closed" (funcall status mine 'who)))
        (should (equal "closed" (funcall status mine 'bare)))
        (should (equal "closed by Claude, 2026-10-14 17:16 (30m ago)" (funcall status theirs)))
        (should (equal "closed by Claude, 30m ago" (funcall status theirs 'short)))
        (should (equal "closed by Claude" (funcall status theirs 'who)))
        (should (equal "closed" (funcall status theirs 'bare)))
        ;; Where times are not relative, a shortened status keeps the date.
        (let ((change-review-ui-relative-times nil))
          (should (equal "closed by Claude, 2026-10-14 17:16" (funcall status theirs 'short))))))))

(ert-deftest change-review-ui-shortens-the-header-of-a-comment-in-less-room ()
  "A comment's header leaves out the date for how long ago, the revision,
the words of its links, the time and the marks, in that order."
  (change-review-ui-test--drawing
    (cl-letf (((symbol-function 'float-time) (lambda (&rest _) change-review-ui-test--now))
              (change-review-ui-relative-times t))
      (let* ((set (change-review-ui-test--set))
             (thread (car (change-review-ui-test--populate set)))
             (header (lambda (width)
                       (cl-find-if (lambda (line) (string-prefix-p "┃ 2/3" line))
                                   (change-review-ui-test--lines
                                    (change-review-ui-thread-string set thread :width width))))))
        (should (equal "┃ 2/3  Claude (agent) · 2026-10-14 16:46 (1h ago) · second  ↗ conversation  ▸ where"
                       (funcall header 100)))
        (should (equal "┃ 2/3  Claude (agent) · 1h ago · second  ↗ conversation  ▸ where" (funcall header 70)))
        (should (equal "┃ 2/3  Claude (agent) · 1h ago  ↗ conversation  ▸ where" (funcall header 55)))
        (should (equal "┃ 2/3  Claude (agent) · 1h ago  ↗  ▸" (funcall header 50)))
        (should (equal "┃ 2/3  Claude (agent)  ↗  ▸" (funcall header 30)))
        (should (equal "┃ 2/3  Claude  ↗  ▸" (funcall header 20)))
        ;; The words of a comment's answer, and its draft mark, stay.
        (let ((third (cl-find-if (lambda (line) (string-prefix-p "┃ 3/3" line))
                                 (change-review-ui-test--lines
                                  (change-review-ui-thread-string set thread :width 50)))))
          (should (string-match-p "draft · ↳ re 1/3" third)))))))

(ert-deftest change-review-ui-draws-a-thread-at-the-width-of-the-window ()
  "A thread is drawn to the columns of the window its buffer is in, and
to 80 where no window shows it; the width is never under 40 or over 160."
  (let ((change-review-ui-width nil)
        (buffer (generate-new-buffer " *change-review-width*")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer buffer
            (should (= 80 (change-review-ui-current-width))))
          (delete-other-windows)
          (let ((window (split-window nil 30 'right)))
            (set-window-buffer window buffer)
            (with-current-buffer buffer
              (should (= (max 40 (min 160 (window-max-chars-per-line window)))
                         (change-review-ui-current-width)))
              (should (< (change-review-ui-current-width) 80))
              (should (= (change-review-ui-current-width) (car (change-review-ui-current-size))))
              ;; A window of fewer columns than a thread can be drawn to.
              (should (= 40 (let ((change-review-ui-width 20)) (change-review-ui-current-width))))
              (should (= 160 (let ((change-review-ui-width 300)) (change-review-ui-current-width)))))))
      (kill-buffer buffer))))

(ert-deftest change-review-ui-limits-a-thread-to-what-the-window-shows ()
  "The most lines a thread takes is a number, the window's less four, or nothing."
  (let ((change-review-ui-width 80)
        (buffer (generate-new-buffer " *change-review-lines*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buffer)
          (with-current-buffer buffer
            (let ((change-review-ui-max-thread-lines 15))
              (should (= 15 (change-review-ui-current-max-lines)))
              (should (equal '(80 . 15) (change-review-ui-current-size))))
            (let ((change-review-ui-max-thread-lines 1))
              (should (= 3 (change-review-ui-current-max-lines))))
            (let ((change-review-ui-max-thread-lines nil))
              (should-not (change-review-ui-current-max-lines)))
            (let ((change-review-ui-max-thread-lines 'window))
              (should (= (max 6 (- (window-body-height) 4)) (change-review-ui-current-max-lines))))))
      (kill-buffer buffer))
    ;; Where no window shows the buffer, a thread may take twenty.
    (with-temp-buffer
      (let ((change-review-ui-max-thread-lines 'window))
        (should (= 20 (change-review-ui-current-max-lines)))))))

;;;; Folding a thread

(ert-deftest change-review-ui-folds-closed-threads-at-first ()
  "A closed thread is one line before anyone folds it, any other is in full:
unless the option says a closed one is too."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set)))
      (should (eq 'expanded (change-review-ui-thread-fold set (nth 0 threads))))
      ;; The agent's close waits for the user's review: it is in full, until reviewed.
      (should (eq 'expanded (change-review-ui-thread-fold set (nth 1 threads))))
      (change-review-mark-reviewed set (nth 1 threads))
      (should (eq 'collapsed (change-review-ui-thread-fold set (nth 1 threads))))
      (let ((change-review-ui-collapse-closed-in-diff nil))
        (should (eq 'expanded (change-review-ui-thread-fold set (nth 1 threads))))))))

(ert-deftest change-review-ui-remembers-how-a-thread-was-folded ()
  "What was chosen stays, for the set, while the thread keeps its status;
a thread whose status changed is drawn as one of that status again."
  (let ((change-review-ui-test--reviewed t))
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (other (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (open (nth 0 threads))
           (closed (nth 1 threads)))
      (change-review-ui-set-fold set closed 'expanded)
      (change-review-ui-set-fold set open 'collapsed)
      (should (eq 'expanded (change-review-ui-thread-fold set closed)))
      (should (eq 'collapsed (change-review-ui-thread-fold set open)))
      ;; Another set has its own.
      (should (eq 'collapsed (change-review-ui-thread-fold other closed)))
      (should (eq 'expanded (change-review-ui-thread-fold other open)))
      ;; Reopened, the closed thread is a thread of an open one's kind again; closed,
      ;; the open one is one line.
      (change-review-reopen set closed)
      (should (eq 'expanded (change-review-ui-thread-fold set closed)))
      (change-review-close set open)
      (should (eq 'collapsed (change-review-ui-thread-fold set open)))
      (should-error (change-review-ui-set-fold set open 'folded) :type 'change-review-error)))))

(ert-deftest change-review-ui-goes-through-the-folds-in-turn ()
  "One line, then the conversation, then all of it -- where something was
left out of the conversation -- then one line; several threads follow the first."
  (let ((change-review-ui-test--reviewed t))
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (closed (nth 1 threads))
           (open (nth 0 threads))
           (message-log nil))
      (cl-letf (((symbol-function 'message) (lambda (&rest args) (push (apply #'format args) message-log))))
        (should (eq 'collapsed (change-review-ui-thread-fold set closed)))
        (should (eq 'expanded (change-review-ui-cycle-folds set (list closed))))
        (should (equal (format "Thread %s: the conversation" (change-review-ui-thread-short-id set closed))
                       (car message-log)))
        ;; Nothing was left out: the next is one line.
        (change-review-ui-thread-string set closed :width 80 :fold 'expanded :max-lines 10)
        (should (eq 'collapsed (change-review-ui-cycle-folds set (list closed))))
        (should (equal (format "Thread %s: one line" (change-review-ui-thread-short-id set closed))
                       (car message-log)))
        ;; Something was: all of it comes before one line.
        (should (= 8 (length (change-review-ui-test--lines
                              (change-review-ui-thread-string set open :width 80)))))
        (change-review-ui-thread-string set open :width 80 :fold 'expanded :max-lines 5)
        (should (eq 'full (change-review-ui-cycle-folds set (list open))))
        (should (string-suffix-p ": all of it" (car message-log)))
        (should (eq 'collapsed (change-review-ui-cycle-folds set (list open))))
        (should (eq 'expanded (change-review-ui-cycle-folds set (list open))))
        ;; Two threads follow the first: an open one in its conversation
        ;; goes to one line, and takes the closed one with it, one line already.
        (change-review-ui-thread-string set open :width 80 :fold 'expanded :max-lines 20)
        (should (eq 'collapsed (change-review-ui-cycle-folds set (list open closed))))
        (should (eq 'collapsed (change-review-ui-thread-fold set open)))
        (should (eq 'collapsed (change-review-ui-thread-fold set closed)))
        (should (string-suffix-p "2 threads: one line" (car message-log)))
        (should (eq 'expanded (change-review-ui-cycle-folds set (list closed open))))
        (should (eq 'expanded (change-review-ui-thread-fold set open)))
        (should-not (change-review-ui-cycle-folds set nil)))))))

(ert-deftest change-review-ui-draws-a-folded-thread-with-a-triangle-that-opens-it ()
  "A thread that can be folded starts with a triangle, which is a button:
pointing right on a thread of one line, down on one that is open to its
conversation.  Clicking it, or the words of a thread of one line, folds it."
  (let ((change-review-ui-test--reviewed t))
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (nth 1 (change-review-ui-test--populate set)))
           (line (lambda (fold &rest keys)
                   (apply #'change-review-ui-thread-string set thread :view 'diff :width 90 :indent "  "
                          :fold fold keys))))
      ;; One line: the triangle takes the place of the indent.
      (let ((one (funcall line 'collapsed)))
        (should (= 1 (length (change-review-ui-test--lines one))))
        (should (string-match-p "\\`▸ ✓ [^ ]+ · 1 comment · closed by Claude[^\n]*· reviewed  “Fine\\.”\n\\'"
                                (substring-no-properties one)))
        (change-review-ui-test--press one "▸")
        (should (eq 'expanded (change-review-ui-thread-fold set thread)))
        (change-review-ui-set-fold set thread 'collapsed)
        ;; The words are a button too.
        (change-review-ui-test--press one "“Fine.”")
        (should (eq 'expanded (change-review-ui-thread-fold set thread))))
      ;; Open to its conversation: the triangle points down, the rest as ever.
      (let ((open (funcall line 'expanded)))
        (should (string-prefix-p "▾ ✓ " (substring-no-properties open)))
        (should (equal "  ┃ 1/1  Noah" (substring (nth 1 (change-review-ui-test--lines open)) 0 13)))
        (change-review-ui-test--press open "▾")
        (should (eq 'collapsed (change-review-ui-thread-fold set thread))))
      ;; A thread that cannot be folded has no triangle, and its words no button.
      (should (string-prefix-p "  ✓ " (substring-no-properties (funcall line nil))))
      (let ((plain (funcall line nil :collapsed t)))
        (should (string-match-p "“Fine\\.”\n\\'" (substring-no-properties plain)))
        (should-not (change-review-ui-test--button plain "“Fine.”")))))))

(ert-deftest change-review-ui-cuts-a-thread-that-is-longer-than-the-room-it-has ()
  "A thread longer than MAX-LINES is cut, and says how many lines more there
are, in a button that shows them all: the fold `full'.  Where the thread
shows where its comments were made, it is not cut."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (comment (change-review-comment
                     set (mapconcat (lambda (n) (format "Line %d of a long comment." n))
                                    (number-sequence 1 20) "\n")
                     :author (change-review-ui-test--author) :time change-review-ui-test--now))
           (thread (change-review-find-thread set (change-review-comment-thread comment)))
           (draw (lambda (fold &rest keys)
                   (apply #'change-review-ui-thread-string set thread :view 'diff :width 80
                          :fold fold :max-lines 8 keys))))
      ;; Eight lines: the header, the comment's, five of its text, and the one that says more.
      (let ((lines (change-review-ui-test--lines (funcall draw 'expanded))))
        (should (= 8 (length lines)))
        (should (equal "┃      Line 5 of a long comment." (nth 6 lines)))
        (should (equal "┃      … 15 more lines" (nth 7 lines))))
      (should (change-review-ui--trimmed-p set thread))
      (change-review-ui-test--press (funcall draw 'expanded) "… 15 more lines")
      (should (eq 'full (change-review-ui-thread-fold set thread)))
      ;; All of it, and nothing says more.
      (let ((lines (change-review-ui-test--lines (funcall draw 'full))))
        (should (= 22 (length lines)))
        (should-not (cl-some (lambda (line) (string-search "more line" line)) lines)))
      (should-not (change-review-ui--trimmed-p set thread))
      ;; The threads view's drawing, which cannot be folded, leaves that note alone.
      (funcall draw 'expanded)
      (should (change-review-ui--trimmed-p set thread))
      (change-review-ui-thread-string set thread :width 80)
      (should (change-review-ui--trimmed-p set thread))
      ;; Not cut where there is room, or where no limit is given, or when
      ;; the comment's details show: it was asked for.
      (should (= 22 (length (change-review-ui-test--lines
                             (change-review-ui-thread-string set thread :view 'diff :width 80
                                                             :fold 'expanded :max-lines 30)))))
      (should (= 22 (length (change-review-ui-test--lines
                             (change-review-ui-thread-string set thread :view 'diff :width 80 :fold 'expanded)))))
      (should (> (length (change-review-ui-test--lines
                          (funcall draw 'expanded :details (list (change-review-comment-id comment)))))
                 22))
      ;; The threads view, with no fold, has no limit either.
      (should (= 22 (length (change-review-ui-test--lines
                             (change-review-ui-thread-string set thread :width 80 :max-lines 8))))))))

(ert-deftest change-review-ui-quotes-what-was-said-not-what-it-answered ()
  "The words that stand for a comment in one line are its own, not the
lines it quotes: a comment imported from a reply opens with the quote."
  (should (equal "Why that?" (change-review-ui--summary "> What the agent said.\n\nWhy that?")))
  (should (equal "One two three" (change-review-ui--summary "One\ntwo\n\n  three")))
  (should (equal "> all quote > of it" (change-review-ui--summary "> all quote\n> of it")))
  (should (equal "Yes. Sure." (change-review-ui--summary "> quote\nYes.\n> more\nSure.")))
  ;; Only `> ' quotes, as a reply to patches has them; `>=' is not one.
  (should (equal ">= 5 is wrong See above" (change-review-ui--summary ">= 5 is wrong\nSee above")))
  (should (equal "Reply" (change-review-ui--summary ">> older\n> old\n>\nReply"))))

(ert-deftest change-review-ui-draws-a-thread-of-quotes-as-one-line-with-its-answer ()
  "A thread one line long says what was answered, not only what it quoted,
and a thread in a list does too."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (comment (change-review-comment
                     set "> I changed the middleware so every request is timed.\n\nWhy the 401s too?"
                     :author (change-review-ui-test--author) :time change-review-ui-test--now))
           (thread (change-review-find-thread set (change-review-comment-thread comment))))
      (should (string-suffix-p "“Why the 401s too?”"
                               (car (change-review-ui-test--lines
                                     (change-review-ui-thread-string set thread :view 'diff :width 90
                                                                     :collapsed t)))))
      (should (string-match-p "“Why the 401s too\\?”"
                              (change-review-ui-thread-line set thread :width 90))))))

(ert-deftest change-review-ui-gives-a-thread-of-one-line-the-room-it-wants-for-its-words ()
  "The header of a thread of one line leaves out what it can to leave its
words thirty columns, or the room they need; no line is wider than a hundred."
  (change-review-ui-test--drawing
    (cl-letf (((symbol-function 'float-time) (lambda (&rest _) change-review-ui-test--now))
              (change-review-ui-relative-times t))
      (let* ((set (change-review-ui-test--set))
             (comment (change-review-comment
                       set (string-join (make-list 20 "These are the words of the root") " ")
                       :author (change-review-ui-test--author) :time change-review-ui-test--now))
             (thread (change-review-find-thread set (change-review-comment-thread comment)))
             (one (lambda (width)
                    (car (change-review-ui-test--lines
                          (change-review-ui-thread-string set thread :view 'diff :width width
                                                          :fold 'collapsed))))))
        (change-review-close set thread :author (change-review-ui-test--author)
                             :time (- change-review-ui-test--now 120))
        ;; Room for the buttons as well as the words.
        (should (string-match-p "\\`▸ ✓ [^ ]+ · 1 comment · closed 2m ago   \\[Reply\\] \\[Reopen\\]  “These are the words of the r…”\\'"
                                (funcall one 90)))
        ;; Not for the buttons: the words have what they want.
        (should (string-match-p "\\`▸ ✓ [^ ]+ · 1 comment · closed 2m ago  “These are the words of the …”\\'"
                                (funcall one 70)))
        ;; Not for the count of comments either.
        (should (string-match-p "\\`▸ ✓ [^ ]+ · closed 2m ago  “These are the words of the ro…”\\'"
                                (funcall one 60)))
        ;; The least a header says, and the words what is left.
        (should (string-match-p "\\`▸ ✓ [^ ]+ · closed  “These are the words of the…”\\'" (funcall one 50)))
        (should (string-match-p "\\`▸ ✓ [^ ]+ · closed  “These are the wo…”\\'" (funcall one 40)))
        ;; In a wide window the line is a hundred columns at most.
        (should (= 100 (string-width (funcall one 160))))
        (dolist (width '(40 50 60 70 90 100 160))
          (should (<= (string-width (funcall one width)) (min width 100))))
        ;; Words that need less than they want leave the rest of the line empty.
        (let* ((short (change-review-comment
                       set "Fine." :author (change-review-ui-test--author) :time change-review-ui-test--now))
               (thread (change-review-find-thread set (change-review-comment-thread short))))
          (should (string-match-p "· 1 comment · open   \\[Reply\\] \\[Close\\]  “Fine\\.”\\'"
                                  (car (change-review-ui-test--lines
                                        (change-review-ui-thread-string set thread :view 'diff :width 80
                                                                        :fold 'collapsed))))))))))

;;;; The threads view

(defmacro change-review-ui-test--threads-view (&rest body)
  "Run BODY in the threads view of a set with threads; bind `set' and `threads'."
  (declare (indent 0))
  `(change-review-ui-test--drawing
     (let* ((set (change-review-ui-test--set))
            (threads (change-review-ui-test--populate set))
            (change-review-ui-sets nil)
            (buffer (save-window-excursion (change-review-open-threads set 'all))))
       (ignore threads)
       (unwind-protect
           (with-current-buffer buffer ,@body)
         (kill-buffer buffer)))))

(defun change-review-ui-test--text ()
  "Return the text of the current buffer without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(ert-deftest change-review-ui-threads-view-groups-by-file ()
  "The view lists the threads by file, the change as a whole first, then
the files in the order of the newest version."
  (change-review-ui-test--threads-view
    (let ((text (change-review-ui-test--text)))
      (should (string-prefix-p "Review of Fix the flaky test   second of 2\n" text))
      (should (string-match-p "^Threads  +open 3 +to review 1 +closed 1 +\\[all 4\\]" text))
      (should (string-match-p "2 drafts not sent" text))
      (let ((whole (string-match "^▾ The change as a whole" text))
            (a (string-match "^▾ a\\.el" text))
            (b (string-match "^▾ b\\.el" text)))
        (should (and whole a b (< whole a b))))
      (should (string-match-p "^▾ a\\.el +2 threads · 2 open$" text))
      (should (string-match-p "^▾ b\\.el +1 thread · 0 open$" text))
      (should (string-match-p "Overall: good\\." text))
      (should (string-match-p "What about a4\\?" text)))))

(ert-deftest change-review-ui-threads-view-filters-by-status ()
  "f changes which threads show: open, closed, all, those to review; the
buttons say how many."
  (change-review-ui-test--threads-view
    (change-review-ui-set-filter 'open)
    (let ((text (change-review-ui-test--text)))
      (should (string-match-p "^Threads  \\[open 3\\]" text))
      (should (string-match-p "What about a4\\?" text))
      (should-not (string-match-p "▾ b\\.el" text))
      (should-not (string-match-p "Fine\\." text)))
    (change-review-ui-cycle-filter)
    (should (eq 'unreviewed change-review-ui--filter))
    (change-review-ui-cycle-filter)
    (let ((text (change-review-ui-test--text)))
      (should (string-match-p "\\[closed 1\\]" text))
      (should (string-match-p "Fine\\." text))
      (should-not (string-match-p "What about a4\\?" text))
      (should-not (string-match-p "▾ a\\.el" text)))
    (change-review-ui-cycle-filter)
    (should (eq 'all change-review-ui--filter))
    (change-review-ui-cycle-filter)
    (should (eq 'open change-review-ui--filter))
    (change-review-ui-set-filter 'closed)
    (change-review-ui-set-filter 'open)
    (should (eq 'open change-review-ui--filter))))

(ert-deftest change-review-ui-threads-view-is-drawn-to-the-width-of-its-window ()
  "The view is shown before it is drawn, so even its first drawing wraps the
text to the width of the window it is shown in, not to eighty columns
for want of one."
  (let* ((change-review-ui-width nil)
         (change-review-ui-sets nil)
         (set (change-review-ui-test--set)))
    (change-review-comment set (string-join (make-list 30 "wordy") " ")
                           :author (change-review-ui-test--author) :time change-review-ui-test--now)
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 50)))
      (let ((buffer (save-window-excursion (change-review-open-threads set 'all))))
        (unwind-protect
            (with-current-buffer buffer
              (let ((words (cl-remove-if-not (lambda (line) (string-search "wordy" line))
                                             (split-string (change-review-ui-test--text) "\n"))))
                (should (> (length words) 3))
                (dolist (line words)
                  (should (<= (string-width line) 50)))))
          (kill-buffer buffer))))))

(ert-deftest change-review-ui-threads-view-says-when-there-is-nothing ()
  "A filter that shows nothing says so, and how to see more."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (change-review-ui-sets nil)
           (buffer (save-window-excursion (change-review-open-threads set 'open))))
      (unwind-protect
          (with-current-buffer buffer
            (should (string-match-p "No open threads\\." (change-review-ui-test--text)))
            (change-review-ui-set-filter 'closed)
            (should (string-match-p "No closed threads\\." (change-review-ui-test--text)))
            (change-review-ui-set-filter 'all)
            (should (string-match-p "No threads yet\\." (change-review-ui-test--text))))
        (kill-buffer buffer)))))

(ert-deftest change-review-ui-threads-string-is-the-body-of-the-view ()
  "A buffer that shows the threads among its own text gets them as a string:
grouped by file as the view groups them, filtered by status, every line
starting with the indent, the ids of the threads and comments on the
text so the commands find them, and a line of its own saying that none
passes the filter."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (open (change-review-ui-threads-string set :filter 'open :width 80))
           (closed (change-review-ui-threads-string set :filter 'closed :width 80))
           (all (change-review-ui-threads-string set :filter 'all :width 80 :indent "  ")))
      ;; Open: the change as a whole and a.el, the closed b.el behind the filter.
      (should (string-match-p "^▾ The change as a whole +1 thread$" (substring-no-properties open)))
      (should (string-match-p "^▾ a\\.el +2 threads$" (substring-no-properties open)))
      (should-not (string-search "b.el" (substring-no-properties open)))
      (should (string-search "What about a4?" open))
      (should-not (string-search "Fine." open))
      (should (string-search "Fine." closed))
      (should-not (string-search "What about a4?" closed))
      ;; All: the closed ones count in the header of their file.
      (should (string-match-p "^  ▾ b\\.el +1 thread · 0 open$" (substring-no-properties all)))
      (dolist (line (change-review-ui-test--lines all))
        (should (string-prefix-p "  " line)))
      ;; The ids, for the commands to find.
      (let ((pos (string-search "What about a4?" open)))
        (should (equal (change-review-thread-id (nth 3 threads))
                       (get-text-property pos 'change-review-thread open)))
        (should (equal (change-review-comment-id (change-review-thread-root (nth 3 threads)))
                       (get-text-property pos 'change-review-comment open))))
      (should (equal "a.el" (get-text-property (string-search "▾ a.el" open) 'change-review-file open)))
      ;; It is what the view draws: the view only adds its heading.
      (let ((buffer (save-window-excursion (change-review-open-threads set 'open))))
        (unwind-protect
            (should (string-suffix-p (substring-no-properties
                                      (change-review-ui-threads-string
                                       set :filter 'open :width (with-current-buffer buffer
                                                                  (change-review-ui-current-width))))
                                     (with-current-buffer buffer (change-review-ui-test--text))))
          (kill-buffer buffer))))
    ;; No thread passes: a line says so, EMPTY instead when given.
    (let ((set (change-review-ui-test--set)))
      (should (equal "No open threads.\n" (substring-no-properties (change-review-ui-threads-string set))))
      (should (equal "  No threads yet.\n"
                     (substring-no-properties (change-review-ui-threads-string set :filter 'all :indent "  "))))
      (should (equal "Nothing.\n"
                     (substring-no-properties (change-review-ui-threads-string set :empty "Nothing.")))))))

(ert-deftest change-review-ui-threads-heading-has-the-filter-buttons ()
  "The head of the threads has a button for each filter, the one in force
marked, how many drafts wait, and its buttons set the filter of the buffer
they are pressed in and draw it again."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (_ (change-review-ui-test--populate set))
           (heading (change-review-ui-threads-heading set 'open)))
      (should (string-suffix-p "\n" heading))
      (should (string-match-p "\\`Threads  \\[open 3\\] +to review 1 +closed 1 +all 4 +2 drafts not sent\n\\'"
                              (substring-no-properties heading)))
      (should (string-match-p "\\`Threads  +open 3 +to review 1 +closed 1 +\\[all 4\\]"
                              (substring-no-properties (change-review-ui-threads-heading set 'all))))
      (let (redrawn)
        (with-temp-buffer
          (setq change-review-ui--filter 'open
                change-review-ui--redraw-function (lambda () (setq redrawn change-review-ui--filter)))
          (insert heading)
          (push-button (1+ (change-review-ui-test--button heading " closed 1 ")))
          (should (eq 'closed change-review-ui--filter))
          (should (eq 'closed redrawn)))))))

(ert-deftest change-review-ui-threads-view-moves-between-comments-and-threads ()
  "n and p move between comments, N and P between threads."
  (change-review-ui-test--threads-view
    (goto-char (point-min))
    (let ((starts nil))
      (while (condition-case nil (progn (change-review-ui-next-comment) t) (user-error nil))
        (push (get-text-property (point) 'change-review-comment) starts))
      ;; Six comments: three of A, one each of B, C and D.
      (should (= 6 (length starts))))
    (goto-char (point-min))
    (change-review-ui-next-thread)
    (should (get-text-property (point) 'change-review-thread-start))
    (should (string-match-p "Overall: good" (buffer-substring (point) (point-max))))
    (let ((first (point)))
      (change-review-ui-next-thread)
      (should (> (point) first))
      (change-review-ui-previous-thread)
      (should (= (point) first)))
    (goto-char (point-max))
    (change-review-ui-previous-comment)
    (should (string-match-p "\\`.*Noah (you).*\n.*Fine\\." (buffer-substring (point) (point-max))))
    (change-review-ui-previous-comment)
    (should (string-match-p "What about a4" (buffer-substring (point) (point-max))))
    (goto-char (point-min))
    (should-error (change-review-ui-previous-comment) :type 'user-error)))

(ert-deftest change-review-ui-threads-view-shows-where-a-comment-was-made ()
  "RET on a comment shows where it was made under it; RET again hides it."
  (change-review-ui-test--threads-view
    (goto-char (point-min))
    (search-forward "Why 'two?")
    (should-not (string-match-p "made at a\\.el:3" (change-review-ui-test--text)))
    (change-review-ui-show-origin)
    (should (string-match-p "made at a\\.el:3 · revision second" (change-review-ui-test--text)))
    (should (string-match-p "│ +\\(?:@@\\|(setq a3 3)\\)" (change-review-ui-test--text)))
    ;; Point stays on the comment.
    (should (equal (change-review-comment-id (change-review-thread-root (car threads)))
                   (get-text-property (point) 'change-review-comment)))
    (change-review-ui-show-origin)
    (should-not (string-match-p "made at a\\.el:3" (change-review-ui-test--text)))))

(ert-deftest change-review-ui-threads-view-replies-and-closes ()
  "r replies to the comment at point, x closes the thread and opens it
again, s sets the status by name; the view follows the set."
  (change-review-ui-test--threads-view
    (let ((change-review-ui-read-function
           (lambda (prompt _initial callback)
             (should (string-match-p "\\`Reply to Claude's comment 2/3 on a\\.el:3" prompt))
             (funcall callback " Thanks, done.\n"))))
      (goto-char (point-min))
      (search-forward "Because the retry loop")
      (change-review-ui-reply)
      (let ((last (change-review-thread-last-comment (car threads))))
        (should (equal "Thanks, done." (change-review-comment-body last)))
        (should (equal (change-review-comment-id (nth 1 (change-review-thread-comments (car threads))))
                       (change-review-comment-reply-to last)))
        (should (equal "Noah" (change-review-author-label (change-review-comment-author last)))))
      (change-review-ui-flush)
      (should (string-match-p "4/4" (change-review-ui-test--text)))
      (should (string-match-p "Thanks, done\\." (change-review-ui-test--text))))
    (goto-char (point-min))
    (search-forward "Because the retry loop")
    (change-review-ui-toggle-status)
    (should-not (change-review-thread-open-p (car threads)))
    (let ((change-review-ui-width 120))
      (change-review-ui-flush)
      (should (string-match-p "closed by Noah (you)" (change-review-ui-test--text))))
    ;; The thread is still where it was: point is on the same comment.
    (should (string-match-p "Because the retry loop" (buffer-substring (line-beginning-position) (line-end-position))))
    (change-review-ui-toggle-status)
    (should (change-review-thread-open-p (car threads)))
    (change-review-ui-set-status 'closed)
    (should-not (change-review-thread-open-p (car threads)))
    (should-error (change-review-ui-set-status 'resolved) :type 'change-review-error)))

(ert-deftest change-review-ui-threads-view-comments-on-the-change ()
  "c adds a draft comment on the change as a whole, a thread of its own."
  (change-review-ui-test--threads-view
    (let ((count (length (change-review-set-threads set)))
          (change-review-ui-read-function (lambda (_prompt _initial callback) (funcall callback "Please add a changelog."))))
      (change-review-ui-comment-on-change)
      (should (= (1+ count) (length (change-review-set-threads set))))
      (let ((thread (car (last (change-review-set-threads set)))))
        (should-not (change-review-thread-location thread))
        (should (change-review-comment-draft-p (change-review-thread-root thread))))
      (change-review-ui-flush)
      (should (string-match-p "Please add a changelog\\." (change-review-ui-test--text))))
    (let ((count (length (change-review-set-threads set)))
          (change-review-ui-read-function (lambda (_prompt _initial callback) (funcall callback "   "))))
      (change-review-ui-comment-on-change)
      (should (= count (length (change-review-set-threads set)))))))

(ert-deftest change-review-ui-threads-view-edits-and-deletes-drafts ()
  "e edits a draft, k deletes it; a comment that was sent is neither."
  (change-review-ui-test--threads-view
    (goto-char (point-min))
    (search-forward "Then say so")
    (let ((change-review-ui-read-function
           (lambda (prompt initial callback)
             (should (string-match-p "\\`Edit Noah's comment 3/3" prompt))
             (should (equal "Then say so in a comment." initial))
             (funcall callback "Then explain it in a comment."))))
      (change-review-ui-edit-draft))
    (should (equal "Then explain it in a comment."
                   (change-review-comment-body (change-review-thread-last-comment (car threads)))))
    (change-review-ui-flush)
    (goto-char (point-min))
    (search-forward "Because the retry loop")
    (should-error (change-review-ui-edit-draft) :type 'user-error)
    (should-error (change-review-ui-delete-draft) :type 'user-error)
    (goto-char (point-min))
    (search-forward "Then explain it")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (change-review-ui-delete-draft))
    (should (= 2 (length (change-review-thread-comments (car threads)))))
    (change-review-ui-flush)
    (should-not (string-match-p "Then explain it" (change-review-ui-test--text)))))

(ert-deftest change-review-ui-threads-view-edits-the-draft-of-the-thread-at-point ()
  "e on a thread's header, where N and P stop, edits a draft of the thread:
the only one, or the one chosen of several; a thread with none says so, and
what is no thread is none.  k finds a draft the same way."
  (change-review-ui-test--threads-view
    (let* ((a (nth 0 threads)) (b (nth 1 threads)) (d (nth 3 threads))
           (header (lambda (thread)
                     (goto-char (point-min))
                     (search-forward (change-review-ui-thread-short-id set thread))
                     (beginning-of-line)
                     (should (get-text-property (point) 'change-review-thread-start))
                     (should-not (get-text-property (point) 'change-review-comment))))
           asked)
      ;; The only draft of the thread: no question.
      (funcall header d)
      (let ((change-review-ui-read-function
             (lambda (prompt initial callback)
               (should (string-match-p "\\`Edit Noah's comment 1/1 on a\\.el:4" prompt))
               (should (equal "What about a4?" initial))
               (funcall callback "What about a4, then?"))))
        (change-review-ui-edit-draft))
      (should (equal "What about a4, then?" (change-review-comment-body (change-review-thread-root d))))
      ;; Two drafts in thread A: asked which, the newest by default.
      (let* ((first (change-review-thread-last-comment a))
             (second (change-review-reply set (change-review-thread-root a) "And the test's name."
                                          :author (change-review-ui-test--author))))
        (change-review-ui-flush)
        (funcall header a)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt table _predicate _require _initial _hist default &rest _)
                     (setq asked (list prompt (all-completions "" table) default))
                     (car (all-completions "" table)))))
          (let ((change-review-ui-read-function
                 (lambda (_prompt initial callback) (funcall callback (concat initial "!")))))
            (change-review-ui-edit-draft)))
        (should (equal (format "Edit which draft (default %s): " (nth 2 asked)) (nth 0 asked)))
        (should (= 2 (length (nth 1 asked))))
        (should (string-match-p " 3/4  Then say so in a comment\\.\\'" (car (nth 1 asked))))
        (should (equal (nth 2 asked) (cadr (nth 1 asked))))
        (should (string-match-p " 4/4  And the test's name\\.\\'" (nth 2 asked)))
        ;; The first of the list was chosen, not the default (the newest).
        (should (equal "Then say so in a comment.!" (change-review-comment-body first)))
        (should (equal "And the test's name." (change-review-comment-body second))))
      ;; A thread whose comments were all sent has no draft to edit.
      (funcall header b)
      (let ((error (should-error (change-review-ui-edit-draft) :type 'user-error)))
        (should (equal "No draft in this thread" (cadr error))))
      ;; On the text that is not a thread: none.
      (goto-char (point-min))
      (should-error (change-review-ui-edit-draft) :type 'user-error)
      (should-error (change-review-ui-delete-draft) :type 'user-error)
      ;; k: the draft of thread D, which goes with its thread.
      (funcall header d)
      (let ((count (length (change-review-set-threads set))))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (change-review-ui-delete-draft))
        (should (= (1- count) (length (change-review-set-threads set))))
        (should-not (memq d (change-review-set-threads set)))))))

(ert-deftest change-review-ui-threads-view-follows-an-agent ()
  "o on a comment of an agent follows it to its conversation; on the thread
of a user alone, it says there is none."
  (change-review-ui-test--threads-view
    (goto-char (point-min))
    (search-forward "Because the retry loop")
    (change-review-ui-follow-author)
    (should (equal "toolu_9" (change-review-author-tool-call
                              (car (change-review-ui-test--set-followed set)))))
    (goto-char (point-min))
    (search-forward "Overall: good")
    (should-error (change-review-ui-follow-author) :type 'user-error)
    ;; On a comment of the user's in a thread an agent wrote in, the agent's.
    (setf (change-review-ui-test--set-followed set) nil)
    (goto-char (point-min))
    (search-forward "Why 'two?")
    (change-review-ui-follow-author)
    (should (= 1 (length (change-review-ui-test--set-followed set))))))

(ert-deftest change-review-ui-views-follow-the-set ()
  "Whatever changes the set draws its views again; other sets' views stay."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (other (change-review-ui-test--set))
           (change-review-ui-sets nil)
           (buffer (save-window-excursion (change-review-open-threads set 'all)))
           (other-buffer (save-window-excursion (change-review-open-threads other 'all))))
      (unwind-protect
          (progn
            (change-review-comment set "A new thread" :author (change-review-ui-test--author))
            (with-current-buffer other-buffer
              (should-not change-review-ui--timer))
            (with-current-buffer buffer
              (should change-review-ui--timer)
              (should-not (string-match-p "A new thread" (change-review-ui-test--text))))
            ;; Waiting is enough: the timer draws it.
            (with-current-buffer buffer
              (let ((deadline (+ (float-time) 3)))
                (while (and change-review-ui--timer (< (float-time) deadline))
                  (accept-process-output nil 0.05)))
              (should (string-match-p "A new thread" (change-review-ui-test--text)))))
        (kill-buffer buffer)
        (kill-buffer other-buffer)))))

;;;; Overlays under the lines of another buffer

(ert-deftest change-review-ui-draws-a-thread-under-a-line ()
  "A thread is an overlay's text at the end of a line, and the commands find
it by the line point is on."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (thread (car threads)))
      (with-temp-buffer
        (insert "one\ntwo\nthree\n")
        (setq change-review-ui--set set)
        (goto-char (point-min))
        (forward-line 1)
        (let ((overlay (change-review-ui-add-thread-overlay set thread (line-end-position)
                                                            :view 'diff :width 70 :indent "  ")))
          (should (equal (change-review-thread-id thread) (overlay-get overlay 'change-review-thread)))
          (should (string-prefix-p "\n  " (overlay-get overlay 'after-string)))
          (should-not (string-suffix-p "\n" (overlay-get overlay 'after-string)))
          (should (equal (list (change-review-thread-id thread)) (change-review-ui--overlay-thread-ids)))
          (should (eq thread (change-review-ui--thread-at-point)))
          (forward-line -1)
          (should-not (change-review-ui--thread-at-point))
          (forward-line 2)
          (should-not (change-review-ui--thread-at-point))
          (change-review-ui-clear-overlays)
          (forward-line -1)
          (should-not (change-review-ui--overlay-thread-ids)))))))

(ert-deftest change-review-ui-lines-mode-edits-the-drafts-under-the-line ()
  "Where two threads are drawn under one line, e asks which of their drafts to
edit -- point cannot be on either -- and edits it; a line with none says so.
The [Edit] buttons of the drawing name one directly."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (a (nth 0 threads)) (d (nth 3 threads)) (b (nth 1 threads))
           (a3 (change-review-thread-last-comment a))
           (d1 (change-review-thread-root d)))
      (with-temp-buffer
        (insert "one\ntwo\nthree\n")
        (setq change-review-ui--set set)
        (change-review-ui-lines-mode 1)
        (goto-char (point-min))
        (forward-line 1)
        (dolist (thread (list a b d))
          (change-review-ui-add-thread-overlay set thread (line-end-position) :view 'diff :width 70))
        (should (eq #'change-review-ui-edit-draft (key-binding "e")))
        (should (equal (list a b d) (change-review-ui--threads-at-point set)))
        (should (equal (list (cons a a3) (cons d d1))
                       (change-review-ui-draft-candidates (change-review-ui--threads-at-point set))))
        (let (asked)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt table &rest _)
                       (setq asked (all-completions "" table))
                       ;; The second: thread D's.
                       (cadr (all-completions "" table)))))
            (let ((change-review-ui-read-function
                   (lambda (_prompt initial callback)
                     (should (equal "What about a4?" initial))
                     (funcall callback "Which a4?"))))
              (call-interactively #'change-review-ui-edit-draft)))
          (should (= 2 (length asked)))
          (should (equal "Which a4?" (change-review-comment-body d1)))
          (should (equal "Then say so in a comment." (change-review-comment-body a3))))
        ;; The button of a draft in the drawing goes straight to it.
        (let ((change-review-ui-read-function
               (lambda (_prompt _initial callback) (funcall callback "By the button"))))
          (change-review-ui-test--press (change-review-ui-thread-string set a :width 70) "[Edit]"))
        (should (equal "By the button" (change-review-comment-body a3)))
        ;; A line with no thread under it.
        (forward-line 1)
        (should-error (call-interactively #'change-review-ui-edit-draft) :type 'user-error)
        ;; A line with only threads that were sent.
        (forward-line -2)
        (change-review-ui-clear-overlays)
        (change-review-ui-add-thread-overlay set b (line-end-position) :view 'diff :width 70)
        (let ((error (should-error (call-interactively #'change-review-ui-edit-draft) :type 'user-error)))
          (should (equal "No draft in this thread" (cadr error))))))))

(ert-deftest change-review-ui-keeps-the-face-of-the-last-newline-under-a-line ()
  "The buffer's own newline ends the last line of a thread under a line, so a
face that reaches the edge of the window from the newline of that line is
a stretch there instead; text whose last newline has no face ends as it did."
  (change-review-ui-test--drawing
    (pcase-let ((`(,set . ,thread) (change-review-ui-test--markup-thread "first\n~extends"))
                (plain (change-review-ui-test--set)))
      (with-temp-buffer
        (insert "one\ntwo\n")
        (setq change-review-ui--set set)
        (goto-char (point-min))
        (let* ((text (overlay-get (change-review-ui-add-thread-overlay
                                   set thread (line-end-position) :view 'diff :width 70)
                                  'after-string))
               (last (1- (length text))))
          (should-not (string-suffix-p "\n" text))
          (should (string-suffix-p "extends " (substring-no-properties text)))
          (should (eq 'highlight (get-text-property last 'face text)))
          (should (equal '(space :align-to right) (get-text-property last 'display text))))
        (let* ((thread (car (change-review-ui-test--populate plain)))
               (text (overlay-get (change-review-ui-add-thread-overlay
                                   plain thread (line-end-position) :view 'diff :width 70)
                                  'after-string)))
          (should-not (string-suffix-p "\n" text))
          (should-not (get-text-property (1- (length text)) 'display text)))))))

(ert-deftest change-review-ui-lines-mode-acts-on-the-thread-under-the-line ()
  "In a buffer that shows threads under its lines, r, x and RET act on the thread there."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (car (change-review-ui-test--populate set)))
           (change-review-ui-read-function (lambda (_prompt _initial callback) (funcall callback "From a line"))))
      (with-temp-buffer
        (insert "one\ntwo\n")
        (setq change-review-ui--set set)
        (change-review-ui-lines-mode 1)
        (goto-char (point-min))
        (change-review-ui-add-thread-overlay set thread (line-end-position) :view 'diff :width 70)
        (should (eq #'change-review-ui-reply (key-binding "r")))
        (should (eq #'change-review-ui-toggle-status (key-binding "x")))
        (should (eq #'change-review-ui-show-source (key-binding "D")))
        (call-interactively #'change-review-ui-reply)
        (should (equal "From a line" (change-review-comment-body (change-review-thread-last-comment thread))))
        (call-interactively #'change-review-ui-toggle-status)
        (should-not (change-review-thread-open-p thread))
        (forward-line 1)
        (should-error (call-interactively #'change-review-ui-reply) :type 'user-error)))))

;;;; What waits for the user's review

(ert-deftest change-review-ui-says-when-a-close-waits-for-review ()
  "A thread someone else closed says `to review' and offers [Mark reviewed]
until the user marks it; then it says `reviewed'.  What the user closed, and
what is open, say nothing of the kind."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (open (car threads))
           (waiting (nth 1 threads)))
      (let ((string (change-review-ui-thread-string set waiting :width 100)))
        (should (string-match-p " · closed by Claude\\(?:, 2026-10-14 17:16\\)? · to review +\\[Reply\\]"
                                (substring-no-properties string)))
        (should (change-review-ui-test--button string "[Mark reviewed]"))
        (should (eq 'change-review-ui-review-face
                    (get-text-property (string-match "to review" string) 'face string)))
        (change-review-ui-test--press string "[Mark reviewed]"))
      (should-not (change-review-thread-unreviewed-p set waiting))
      (let ((string (change-review-ui-thread-string set waiting :width 100)))
        (should (string-match-p "closed by Claude\\(?:, 2026-10-14 17:16\\)? · reviewed +\\[Reply\\] \\[Reopen\\] \\[Diff\\]"
                                (substring-no-properties string)))
        (should-not (change-review-ui-test--button string "[Mark reviewed]"))
        (should-not (string-match-p "to review" string)))
      ;; Closed by the user: nothing of someone else's to review.
      (should-not (string-match-p "to review\\|\\breviewed\\b"
                                  (substring-no-properties
                                   (change-review-ui-thread-string set open :width 100))))
      (change-review-close set open)
      (let ((string (change-review-ui-thread-string set open :width 100)))
        (should (string-match-p "closed by Noah (you)" (substring-no-properties string)))
        (should-not (string-match-p "to review\\|\\breviewed\\b" (substring-no-properties string)))
        (should-not (change-review-ui-test--button string "[Mark reviewed]"))))))

(ert-deftest change-review-ui-threads-view-lists-what-waits-for-review ()
  "The `to review' filter lists the closed threads the user has not reviewed;
m marks one reviewed and takes it out, and a second m brings it back."
  (change-review-ui-test--threads-view
    (should (string-match-p "to review 1" (change-review-ui-test--text)))
    (change-review-ui-set-filter 'unreviewed)
    (let ((text (change-review-ui-test--text)))
      (should (string-match-p "\\[to review 1\\]" text))
      (should (string-match-p "^▾ b\\.el +1 thread$" text))
      (should (string-match-p "Fine\\." text))
      (should-not (string-match-p "What about a4" text))
      (should-not (string-match-p "Overall: good" text)))
    (goto-char (point-min))
    (search-forward "Fine.")
    (call-interactively #'change-review-ui-toggle-reviewed)
    (should-not (change-review-thread-unreviewed-p set (nth 1 threads)))
    (change-review-ui-flush)
    (let ((text (change-review-ui-test--text)))
      (should (string-match-p "Nothing to review" text))
      (should (string-match-p "\\[to review 0\\]" text)))
    ;; In the closed threads it says it was reviewed; m makes it wait again.
    (change-review-ui-set-filter 'closed)
    (should (string-match-p "closed[^\n]* · reviewed" (change-review-ui-test--text)))
    (goto-char (point-min))
    (search-forward "Fine.")
    (call-interactively #'change-review-ui-toggle-reviewed)
    (should (change-review-thread-unreviewed-p set (nth 1 threads)))
    (change-review-ui-flush)
    (should (string-match-p "closed[^\n]* · to review" (change-review-ui-test--text)))
    (should (eq #'change-review-ui-toggle-reviewed (key-binding "m")))
    (should (eq #'change-review-ui-mark-all-reviewed (key-binding "M")))))

(ert-deftest change-review-ui-point-goes-on-to-the-next-thread-when-one-leaves-the-view ()
  "A thread marked reviewed leaves the filter of those that wait: point goes to
the thread that took its place, so the keys can go on from one to the next."
  (change-review-ui-test--threads-view
    ;; A second thread the agent closed, on the change as a whole: listed first.
    (let ((second (change-review-find-thread
                   set (change-review-comment-thread
                        (change-review-comment set "One more" :time change-review-ui-test--now)))))
      (change-review-close set second :author (change-review-agent "Claude" :session "sess-1")))
    (change-review-ui-set-filter 'unreviewed)
    (goto-char (point-min))
    (search-forward "One more")
    (call-interactively #'change-review-ui-toggle-reviewed)
    (change-review-ui-flush)
    (should (equal (change-review-thread-id (nth 1 threads))
                   (get-text-property (point) 'change-review-thread)))
    (should-not (string-search "One more" (change-review-ui-test--text)))
    ;; The last one: nothing waits, and nothing is left to be on.
    (call-interactively #'change-review-ui-toggle-reviewed)
    (change-review-ui-flush)
    (should (string-match-p "Nothing to review" (change-review-ui-test--text)))
    (should-error (call-interactively #'change-review-ui-toggle-reviewed) :type 'user-error)))

(ert-deftest change-review-ui-a-long-header-wraps-under-its-mark ()
  "A header too long for the window continues under its mark, indented as the
thread is."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (nth 1 (change-review-ui-test--populate set)))
           (string (change-review-ui-thread-string set thread :width 90 :indent "  ")))
      (should (equal "    " (get-text-property 0 'wrap-prefix string))))))

(ert-deftest change-review-ui-only-a-close-by-someone-else-is-reviewed ()
  "m on an open thread, or one the user closed, says why there is nothing
to mark, and changes nothing."
  (change-review-ui-test--threads-view
    (change-review-close set (nth 3 threads))
    (change-review-ui-flush)
    (goto-char (point-min))
    (search-forward "Overall: good.")
    (let ((error (should-error (call-interactively #'change-review-ui-toggle-reviewed) :type 'user-error)))
      (should (string-match-p "is open" (cadr error))))
    (goto-char (point-min))
    (search-forward "What about a4?")
    (let ((error (should-error (call-interactively #'change-review-ui-toggle-reviewed) :type 'user-error)))
      (should (string-match-p "You closed thread .* yourself" (cadr error))))
    (should (equal (list (nth 1 threads)) (change-review-threads set 'unreviewed)))
    (should-not (plist-get (change-review-thread-closing (nth 3 threads)) :reviewed))))

(ert-deftest change-review-ui-marks-everything-that-waits-reviewed ()
  "M marks every thread that waits for the user, after asking; declining
changes nothing, and with nothing waiting it says so."
  (change-review-ui-test--threads-view
    (let ((second (change-review-find-thread
                   set (change-review-comment-thread
                        (change-review-comment set "One more" :time change-review-ui-test--now)))))
      (change-review-close set second :author (change-review-agent "Claude" :session "sess-1")))
    (should (= 2 (length (change-review-threads set 'unreviewed))))
    (let (asked)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) nil)))
        (call-interactively #'change-review-ui-mark-all-reviewed))
      (should (string-match-p "all 2 threads" (car asked)))
      (should (= 2 (length (change-review-threads set 'unreviewed))))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) t)))
        (call-interactively #'change-review-ui-mark-all-reviewed))
      (should-not (change-review-threads set 'unreviewed))
      (should (= 2 (length asked)))
      ;; Nothing waits now: it does not even ask.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) t)))
        (call-interactively #'change-review-ui-mark-all-reviewed))
      (should (= 2 (length asked))))))

(ert-deftest change-review-ui-answering-a-close-is-reviewing-it ()
  "A reply to a thread that waits for the user's review marks it reviewed; an
empty reply is no reply and marks nothing."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (waiting (nth 1 (change-review-ui-test--populate set))))
      (let ((change-review-ui-read-function (lambda (_prompt _initial callback) (funcall callback "  "))))
        (change-review-ui-reply-to-thread set waiting))
      (should (change-review-thread-unreviewed-p set waiting))
      (let ((change-review-ui-read-function
             (lambda (_prompt _initial callback) (funcall callback "Thanks, but why not b3?"))))
        (change-review-ui-reply-to-thread set waiting))
      (should-not (change-review-thread-unreviewed-p set waiting))
      (should (equal "Thanks, but why not b3?"
                     (change-review-comment-body (change-review-thread-last-comment waiting)))))))

(ert-deftest change-review-ui-lines-mode-marks-the-thread-under-the-line-reviewed ()
  "In a buffer that shows threads under its lines, m marks the thread there."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (waiting (nth 1 (change-review-ui-test--populate set))))
      (with-temp-buffer
        (insert "one\ntwo\n")
        (setq change-review-ui--set set)
        (change-review-ui-lines-mode 1)
        (goto-char (point-min))
        (change-review-ui-add-thread-overlay set waiting (line-end-position) :view 'diff :width 70)
        (should (eq #'change-review-ui-toggle-reviewed (key-binding "m")))
        (call-interactively #'change-review-ui-toggle-reviewed)
        (should-not (change-review-thread-unreviewed-p set waiting))
        (call-interactively #'change-review-ui-toggle-reviewed)
        (should (change-review-thread-unreviewed-p set waiting))))))

(ert-deftest change-review-ui-lines-mode-folds-the-thread-under-the-line ()
  "TAB on a line with a thread folds it: one line, its conversation; on a
line with none it is what it was without the library's keys."
  (let ((change-review-ui-test--reviewed t))
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (closed (nth 1 threads))
           (open (nth 3 threads))
           (change-review-ui-read-function (lambda (_prompt _initial callback) (funcall callback "x")))
           (other nil))
      (with-temp-buffer
        (insert "one\ntwo\nthree\n")
        (setq change-review-ui--set set)
        (change-review-ui-lines-mode 1)
        (let ((draw (lambda ()
                      (change-review-ui-clear-overlays)
                      (goto-char (point-min))
                      (change-review-ui-add-thread-overlay
                       set closed (line-end-position) :view 'diff :width 70 :indent "  "
                       :fold (change-review-ui-thread-fold set closed))
                      (forward-line 1)
                      (change-review-ui-add-thread-overlay
                       set open (line-end-position) :view 'diff :width 70 :indent "  "
                       :fold (change-review-ui-thread-fold set open)
                       :max-lines (change-review-ui-current-max-lines))))
              (drawn (lambda (line)
                       (save-excursion
                         (goto-char (point-min))
                         (forward-line (1- line))
                         (substring-no-properties
                          (overlay-get (car (cl-remove-if-not (lambda (o) (overlay-get o 'after-string))
                                                              (overlays-in (line-beginning-position)
                                                                           (1+ (line-end-position)))))
                                       'after-string))))))
          (should (eq #'change-review-ui-cycle-fold (key-binding (kbd "TAB"))))
          (funcall draw)
          (should (= 1 (length (change-review-ui-test--lines (funcall drawn 1)))))
          (goto-char (point-min))
          (let ((inhibit-message t))
            (call-interactively #'change-review-ui-cycle-fold))
          (should (eq 'expanded (change-review-ui-thread-fold set closed)))
          (funcall draw)
          (should (string-match-p "1/1  Noah" (funcall drawn 1)))
          (goto-char (point-min))
          (let ((inhibit-message t))
            (call-interactively #'change-review-ui-cycle-fold))
          (should (eq 'collapsed (change-review-ui-thread-fold set closed)))
          ;; The open thread on the second line is its own.
          (goto-char (point-min))
          (forward-line 1)
          (should (eq 'expanded (change-review-ui-thread-fold set open)))
          (let ((inhibit-message t))
            (call-interactively #'change-review-ui-cycle-fold))
          (should (eq 'collapsed (change-review-ui-thread-fold set open)))
          ;; On the third line, with no thread: the key of the major mode, if any.
          (forward-line 1)
          (cl-letf (((symbol-function 'change-review-ui--other-command) (lambda (&rest _) nil)))
            (should-error (call-interactively #'change-review-ui-cycle-fold) :type 'user-error))
          (use-local-map (let ((map (make-sparse-keymap)))
                           (define-key map (kbd "TAB") (lambda () (interactive) (setq other 'major-mode-tab)))
                           map))
          (call-interactively #'change-review-ui-cycle-fold)
          (should (eq 'major-mode-tab other))
          ;; The global key too, when the major mode has none.
          (use-local-map nil)
          (setq other nil)
          (cl-letf (((symbol-function 'indent-for-tab-command) (lambda (&rest _) (interactive) (setq other 'global-tab))))
            (call-interactively #'change-review-ui-cycle-fold))
          (should (eq 'global-tab other))))))))

(ert-deftest change-review-ui-lines-mode-folds-all-the-threads-under-a-line-together ()
  "Two threads under one line are folded as the first, the chosen one, goes."
  (let ((change-review-ui-test--reviewed t))
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (open (nth 3 threads))
           (closed (nth 1 threads)))
      (with-temp-buffer
        (insert "one\n")
        (setq change-review-ui--set set)
        (goto-char (point-min))
        (dolist (thread (list open closed))
          (change-review-ui-add-thread-overlay set thread (line-end-position) :view 'diff :width 70
                                               :fold (change-review-ui-thread-fold set thread)))
        (should (= 2 (length (change-review-ui--threads-here set))))
        (should (memq open (change-review-ui--threads-here set)))
        (should (memq closed (change-review-ui--threads-here set)))
        (setq change-review-ui--chosen-thread (change-review-thread-id closed))
        (should (eq closed (car (change-review-ui--threads-here set))))
        (setq change-review-ui--chosen-thread (change-review-thread-id open))
        (should (eq open (car (change-review-ui--threads-here set))))
        (setq change-review-ui--chosen-thread (change-review-thread-id closed))
        ;; The closed one is the first: its next fold, the conversation, is both's.
        (let ((inhibit-message t))
          (call-interactively #'change-review-ui-cycle-fold))
        (should (eq 'expanded (change-review-ui-thread-fold set closed)))
        (should (eq 'expanded (change-review-ui-thread-fold set open))))))))

(ert-deftest change-review-ui-scrolls-to-show-what-a-fold-grew ()
  "TAB shows the line second from the top of its window when the thread
that grew under it is not in sight, and leaves the window alone when it is."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (closed (nth 1 (change-review-ui-test--populate set)))
           (recentered nil)
           (visible nil)
           (buffer (generate-new-buffer " *change-review-reveal*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer buffer)
            (with-current-buffer buffer
              (insert "one\ntwo\nthree\n")
              (setq change-review-ui--set set)
              (change-review-ui-lines-mode 1)
              (goto-char (point-min))
              (change-review-ui-add-thread-overlay set closed (line-end-position) :view 'diff :width 70
                                                   :fold 'collapsed)
              (cl-letf (((symbol-function 'pos-visible-in-window-p) (lambda (&rest _) visible))
                        ((symbol-function 'recenter) (lambda (&rest args) (setq recentered args)))
                        ((symbol-function 'message) #'ignore))
                (setq visible nil)
                (call-interactively #'change-review-ui-cycle-fold)
                (should (equal '(1) recentered))
                (setq recentered nil visible t)
                (call-interactively #'change-review-ui-cycle-fold)
                (should-not recentered))))
        (kill-buffer buffer)))))

;;;; The diff view

(defmacro change-review-ui-test--diff-view (&rest body)
  "Run BODY in the diff view of the newest version of a set with threads."
  (declare (indent 0))
  `(change-review-ui-test--drawing
     (let* ((set (change-review-ui-test--set))
            (threads (change-review-ui-test--populate set))
            (change-review-ui-sets nil)
            (buffer (save-window-excursion (change-review-open-diff set))))
       (ignore threads)
       (unwind-protect
           (with-current-buffer buffer ,@body)
         (kill-buffer buffer)))))

(defun change-review-ui-test--goto (regexp)
  "Move point to the line that matches REGEXP, in the diff view's text."
  (goto-char (point-min))
  (re-search-forward regexp)
  (beginning-of-line))

(ert-deftest change-review-ui-diff-view-shows-the-diff-with-threads-under-lines ()
  "The files' diffs are the text; each thread is drawn under the line it is
about, the change's own at the top."
  ;; The window a batch Emacs shows the view in is a few lines high.
  (let ((change-review-ui-max-thread-lines nil))
  (change-review-ui-test--diff-view
    (should (derived-mode-p 'change-review-diff-view-mode))
    (should (derived-mode-p 'diff-mode))
    (should buffer-read-only)
    (should (string-prefix-p "diff --git a/a.el b/a.el\n" (change-review-ui-test--text)))
    (let ((overlays (cl-remove-if-not (lambda (o) (overlay-get o 'change-review-thread))
                                      (overlays-in (point-min) (point-max)))))
      ;; The thread on b.el is closed: one line, under its line.  A and D are on a.el.
      (should (= 3 (length overlays)))
      (let ((positions (mapcar (lambda (o)
                                 (save-excursion
                                   (goto-char (overlay-start o))
                                   (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
                               overlays)))
        (should (member " (setq a3 3)" positions))
        (should (member " (setq a4 4)" positions))
        (should (member "+(setq b2 'two)" positions))))
    (let ((whole (cl-find-if (lambda (o) (overlay-get o 'before-string))
                             (overlays-in (point-min) (point-min)))))
      (should whole)
      (should (string-match-p "Overall: good\\." (overlay-get whole 'before-string))))
    (let ((string (overlay-get (cl-find-if (lambda (o)
                                              (and (overlay-get o 'after-string)
                                                   (string-match-p "Why 'two"
                                                                   (overlay-get o 'after-string))))
                                            (overlays-in (point-min) (point-max)))
                               'after-string)))
      (should (string-match-p "1/3  Noah (you)" string))
      (should (string-match-p "↳ re 1/3" string))
      ;; In the diff view the line is implied: no "line 3" in the header.
      (should-not (string-match-p "· line 3 ·" string)))
    ;; (`format-mode-line' draws nothing in a batch Emacs.)
    (should (string-match-p "3 open, 1 closed, 1 to review, 2 not sent"
                            (apply #'concat (cl-remove-if-not #'stringp header-line-format)))))))

(ert-deftest change-review-ui-diff-view-comments-on-a-line ()
  "c on a line of the diff makes a draft thread there, with the lines around it."
  (change-review-ui-test--diff-view
    (let ((change-review-ui-read-function
           (lambda (prompt _initial callback)
             (should (string-match-p "\\`Comment on b\\.el:3:" prompt))
             (funcall callback "Why b3?"))))
      (change-review-ui-test--goto "^ (setq b3 3)")
      (call-interactively #'change-review-ui-comment-at-point))
    (let* ((thread (car (last (change-review-set-threads set))))
           (root (change-review-thread-root thread))
           (location (change-review-comment-location root)))
      (should (equal "Why b3?" (change-review-comment-body root)))
      (should (change-review-comment-draft-p root))
      (should (equal "b.el" (change-review-location-file location)))
      (should (eql 3 (change-review-location-line location)))
      (should (eq 'new (change-review-location-side location)))
      (should (string-suffix-p " (setq b3 3)" (change-review-location-excerpt location)))
      (should (equal "2222222222222222222222222222222222222222" (change-review-comment-revision root))))
    ;; A removed line is a line of the old version.
    (let ((change-review-ui-read-function (lambda (_prompt _initial callback) (funcall callback "Why drop b2?"))))
      (change-review-ui-test--goto "^-(setq b2 2)")
      (call-interactively #'change-review-ui-comment-at-point))
    (let ((location (change-review-comment-location (change-review-thread-root (car (last (change-review-set-threads set)))))))
      (should (eq 'old (change-review-location-side location)))
      (should (eql 2 (change-review-location-line location))))
    (change-review-ui-flush)
    (should (cl-some (lambda (o) (and (overlay-get o 'after-string)
                                      (string-match-p "Why drop b2\\?" (overlay-get o 'after-string))))
                     (overlays-in (point-min) (point-max))))
    ;; Off a line of the diff there is nothing to comment on.
    (goto-char (point-min))
    (should-error (call-interactively #'change-review-ui-comment-at-point) :type 'user-error)))

(ert-deftest change-review-ui-diff-view-comments-on-a-region ()
  "c with a region comments on its lines: a range."
  (change-review-ui-test--diff-view
    (let ((change-review-ui-read-function (lambda (_prompt _initial callback) (funcall callback "This whole block"))))
      (change-review-ui-test--goto "^ (setq a3 3)")
      (set-mark (point))
      (change-review-ui-test--goto "^ (setq a5 5)")
      (end-of-line)
      (activate-mark)
      (call-interactively #'change-review-ui-comment-at-point))
    (let ((location (change-review-comment-location (change-review-thread-root (car (last (change-review-set-threads set)))))))
      (should (eql 3 (change-review-location-line location)))
      (should (eql 5 (change-review-location-end-line location)))
      (should (string-suffix-p " (setq a5 5)" (change-review-location-excerpt location))))))

(ert-deftest change-review-ui-diff-view-acts-on-the-thread-under-the-line ()
  "r, x and RET act on the thread drawn under the line point is on."
  (change-review-ui-test--diff-view
    (change-review-ui-test--goto "^ (setq a4 4)")
    (end-of-line)
    (let ((thread (change-review-ui--thread-at-point)))
      (should (equal "What about a4?" (change-review-comment-body (change-review-thread-root thread))))
      (let ((change-review-ui-read-function (lambda (_p _i callback) (funcall callback "Good point"))))
        (call-interactively #'change-review-ui-reply))
      (should (equal "Good point" (change-review-comment-body (change-review-thread-last-comment thread))))
      (call-interactively #'change-review-ui-toggle-status)
      (should-not (change-review-thread-open-p thread))
      (change-review-ui-flush)
      ;; Closed, it is a line now.
      (should (string-match-p "“What about a4\\?”"
                              (overlay-get (cl-find-if (lambda (o) (and (overlay-get o 'after-string)
                                                                        (string-match-p "a4" (overlay-get o 'after-string))))
                                                       (overlays-in (point-min) (point-max)))
                                           'after-string)))
      ;; RET opens it to its conversation, and once it is open, RET opens
      ;; its comments' details.
      (let ((drawn (lambda ()
                     (overlay-get (cl-find-if (lambda (o) (overlay-get o 'after-string))
                                              (overlays-in (line-beginning-position)
                                                           (1+ (line-end-position))))
                                  'after-string))))
        (change-review-ui-test--goto "^ (setq a4 4)")
        (end-of-line)
        (call-interactively #'change-review-ui-return)
        (change-review-ui-flush)
        (should (string-match-p "1/2  Noah (you)" (funcall drawn)))
        (should (string-match-p "2/2  Noah (you)" (funcall drawn)))
        (should-not (string-match-p "made at a\\.el:4" (funcall drawn)))
        (call-interactively #'change-review-ui-return)
        (change-review-ui-flush)
        (should (string-match-p "made at a\\.el:4" (funcall drawn)))))))

(ert-deftest change-review-ui-diff-view-edits-the-draft-under-the-line ()
  "e on the line a draft's thread is drawn under edits the draft; under a
line with a thread that was sent only, it says there is no draft."
  (change-review-ui-test--diff-view
    (should (eq #'change-review-ui-edit-draft (key-binding "e")))
    (change-review-ui-test--goto "^ (setq a4 4)")
    (end-of-line)
    (let ((thread (change-review-ui--thread-at-point)))
      (should (equal "What about a4?" (change-review-comment-body (change-review-thread-root thread))))
      (let ((change-review-ui-read-function
             (lambda (prompt initial callback)
               (should (string-match-p "\\`Edit Noah's comment 1/1 on a\\.el:4" prompt))
               (should (equal "What about a4?" initial))
               (funcall callback "What does a4 do?"))))
        (call-interactively #'change-review-ui-edit-draft))
      (should (equal "What does a4 do?" (change-review-comment-body (change-review-thread-root thread))))
      (change-review-ui-flush)
      ;; Drawn again, with the new text and the button on it.
      (let ((drawn (overlay-get (cl-find-if (lambda (o) (and (overlay-get o 'after-string)
                                                               (string-match-p "a4 do" (overlay-get o 'after-string))))
                                             (overlays-in (point-min) (point-max)))
                                'after-string)))
        (should (string-match-p "draft · edited  \\[Edit\\]" drawn))))
    ;; The thread under (setq a3 3) has a draft too: the third comment.
    (change-review-ui-test--goto "^ (setq a3 3)")
    (end-of-line)
    (let ((change-review-ui-read-function (lambda (_prompt _initial callback) (funcall callback "Say why."))))
      (call-interactively #'change-review-ui-edit-draft))
    (should (equal "Say why." (change-review-comment-body
                               (change-review-thread-last-comment (change-review-ui--thread-at-point)))))
    ;; The thread of b.el was sent: no draft to edit under its line.
    (change-review-ui-test--goto "^\\+(setq b2 'two)")
    (end-of-line)
    (let ((error (should-error (call-interactively #'change-review-ui-edit-draft) :type 'user-error)))
      (should (equal "No draft in this thread" (cadr error))))))

(ert-deftest change-review-ui-diff-view-moves-between-threads ()
  "C-c C-n and C-c C-p move between the lines that have a thread."
  (change-review-ui-test--diff-view
    (goto-char (point-min))
    (change-review-ui-next-thread)
    (should (string-match-p "setq a3 3" (buffer-substring (line-beginning-position) (line-end-position))))
    (change-review-ui-next-thread)
    (should (string-match-p "setq a4 4" (buffer-substring (line-beginning-position) (line-end-position))))
    (change-review-ui-next-thread)
    (should (string-match-p "setq b2 'two" (buffer-substring (line-beginning-position) (line-end-position))))
    (should-error (change-review-ui-next-thread) :type 'user-error)
    (change-review-ui-previous-thread)
    (should (string-match-p "setq a4 4" (buffer-substring (line-beginning-position) (line-end-position))))
    (should (eq #'change-review-ui-next-thread (key-binding (kbd "C-c C-n"))))
    ;; Both keys list the threads.
    (should (eq #'change-review-ui-show-threads (key-binding "T")))
    (should (eq #'change-review-ui-show-threads (key-binding (kbd "C-c C-t"))))
    (should (eq #'change-review-ui-comment-at-point (key-binding "c")))))

(ert-deftest change-review-ui-diff-view-follows-the-filter ()
  "Only the threads of the filter in force are drawn; C-c C-f changes it."
  (change-review-ui-test--diff-view
    (setq change-review-ui--filter 'open)
    (change-review-ui-redraw)
    (should (= 2 (length (cl-remove-if-not (lambda (o) (and (overlay-get o 'change-review-thread)
                                                            (overlay-get o 'after-string)))
                                           (overlays-in (point-min) (point-max))))))
    (change-review-ui-set-filter 'closed)
    (should (= 1 (length (cl-remove-if-not (lambda (o) (and (overlay-get o 'change-review-thread)
                                                            (overlay-get o 'after-string)))
                                           (overlays-in (point-min) (point-max))))))))

(ert-deftest change-review-ui-diff-view-draws-a-close-that-waits-whole ()
  "A closed thread is one line in the diff view, unless it waits for the
user's review: then what was answered is in sight, until it is reviewed."
  (change-review-ui-test--diff-view
    (let ((drawn (lambda ()
                   (overlay-get (cl-find-if (lambda (o) (and (overlay-get o 'after-string)
                                                             (string-match-p "Fine\\."
                                                                             (overlay-get o 'after-string))))
                                            (overlays-in (point-min) (point-max)))
                                'after-string))))
      (should (string-match-p "┃ 1/1  Noah" (funcall drawn)))
      (change-review-ui-test--goto "^\\+(setq b2 'two)")
      (end-of-line)
      (call-interactively #'change-review-ui-toggle-reviewed)
      (change-review-ui-flush)
      (should (string-match-p "“Fine\\.”" (funcall drawn)))
      (should-not (string-match-p "┃" (funcall drawn)))
      (should (string-match-p "3 open, 1 closed, 2 not sent"
                              (apply #'concat (cl-remove-if-not #'stringp header-line-format))))
      (should (eq #'change-review-ui-toggle-reviewed (key-binding "m")))
      (should (eq #'change-review-ui-mark-all-reviewed (key-binding "M")))
      ;; Made to wait again, it is whole again, though closed threads collapse.
      (call-interactively #'change-review-ui-toggle-reviewed)
      (should change-review-ui-collapse-closed-in-diff)
      (change-review-ui-flush)
      (should (string-match-p "┃ 1/1  Noah" (funcall drawn))))))

(ert-deftest change-review-ui-diff-view-shows-only-what-waits-for-review ()
  "The `to review' filter draws only the closed threads that wait, and the
header line says which are shown."
  (change-review-ui-test--diff-view
    (change-review-ui-set-filter 'unreviewed)
    (should (= 1 (length (cl-remove-if-not (lambda (o) (and (overlay-get o 'change-review-thread)
                                                            (overlay-get o 'after-string)))
                                           (overlays-in (point-min) (point-max))))))
    (should (string-match-p "showing threads to review"
                            (apply #'concat (cl-remove-if-not #'stringp header-line-format))))
    (change-review-ui-set-filter 'open)
    (should (string-match-p "showing open threads"
                            (apply #'concat (cl-remove-if-not #'stringp header-line-format))))))

(ert-deftest change-review-ui-diff-view-places-threads-of-another-version ()
  "A thread made against an earlier version is drawn where its line is now;
one whose line is gone, under the first line of its file."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (first (change-review-find-version set 1))
           (file (car (change-review-version-files first)))
           (moved (change-review-comment
                   set "Moved?" :author (change-review-ui-test--author) :time change-review-ui-test--now
                   :revision (change-review-version-id first)
                   :location (change-review-diff-location file 'new 4)))
           (gone (change-review-comment
                  set "Gone?" :author (change-review-ui-test--author) :time change-review-ui-test--now
                  :revision (change-review-version-id first)
                  :location (change-review-make-location
                             :file "a.el" :line 4
                             :excerpt (concat "@@ -3,2 +3,2 @@\n (setq x 1)\n+(setq nothing like it 9)"))))
           (change-review-ui-sets nil)
           (buffer (save-window-excursion (change-review-open-diff set))))
      (ignore moved gone)
      (unwind-protect
          (with-current-buffer buffer
            (let ((strings (mapcar (lambda (o) (cons (save-excursion (goto-char (overlay-start o))
                                                                     (buffer-substring-no-properties
                                                                      (line-beginning-position) (line-end-position)))
                                                     (overlay-get o 'after-string)))
                                   (cl-remove-if-not (lambda (o) (overlay-get o 'after-string))
                                                     (overlays-in (point-min) (point-max))))))
              (should (cl-some (lambda (s) (and (equal " (setq a4 4)" (car s)) (string-match-p "Moved\\?" (cdr s)))) strings))
              (should (cl-some (lambda (s) (and (equal "diff --git a/a.el b/a.el" (car s))
                                                (string-match-p "Gone\\?" (cdr s))
                                                (string-match-p "its line is gone" (cdr s))))
                               strings))))
        (kill-buffer buffer)))))

(ert-deftest change-review-ui-visit-shows-a-thread-in-the-diff-view ()
  "`change-review-visit' opens the diff view with point on the thread's line."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (threads (change-review-ui-test--populate set))
           (change-review-ui-sets nil)
           buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (change-review-visit set (nth 3 threads)))
            (with-current-buffer buffer
              (should (derived-mode-p 'change-review-diff-view-mode))
              (should (string-match-p "setq a4 4" (buffer-substring (line-beginning-position) (line-end-position))))
              (should (eq (nth 3 threads) (change-review-ui--thread-at-point))))
            ;; By comment, and the other kinds of threads view's [Diff] button.
            (change-review-visit set (change-review-thread-root (nth 1 threads)))
            (with-current-buffer buffer
              (should (string-match-p "setq b2 'two" (buffer-substring (line-beginning-position) (line-end-position))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest change-review-ui-d-in-the-threads-view-opens-the-diff-view ()
  "d on a comment shows its thread in the diff view."
  (change-review-ui-test--threads-view
    (goto-char (point-min))
    (search-forward "Fine.")
    (let (diff)
      (save-window-excursion
        (change-review-ui-show-in-diff)
        (setq diff (current-buffer))
        (should (derived-mode-p 'change-review-diff-view-mode))
        (should (string-match-p "setq b2 'two" (buffer-substring (line-beginning-position) (line-end-position)))))
      (when (buffer-live-p diff) (kill-buffer diff)))))

(ert-deftest change-review-ui-where-of-a-reply-is-the-diff-of-its-own-revision ()
  "A comment's details show the diff of the revision it was written against:
the reply that answers a thread, once the code changed, shows the code as the
answer found it, on the line it is on there, not the lines the thread started on."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set ,thread ,root ,reply) (change-review-ui-test--answered-set))
                 (origin (change-review-origin set thread reply)))
      ;; The root keeps the diff it was made on, line 3 of the first version.
      (let ((location (plist-get (change-review-origin set thread root) :location)))
        (should (eql 3 (change-review-location-line location)))
        (should (string-search "+(setq a2 'two)" (change-review-location-excerpt location))))
      ;; The reply: the second version's diff, where the thread is line 5.
      (let ((location (plist-get origin :location)))
        (should (eql 5 (change-review-location-line location)))
        (should (equal "a.el" (change-review-location-file location)))
        (should (string-search "+(setq a2 'three)" (change-review-location-excerpt location)))
        (should-not (string-search "'two" (change-review-location-excerpt location)))
        (should (string-suffix-p " (setq a3 3)" (change-review-location-excerpt location))))
      (should-not (plist-get origin :note))
      (let ((lines (change-review-ui-test--lines
                    (change-review-ui-thread-string set thread :width 90 :details t))))
        (should (member "┃      made at a.el:3 · revision first (1111111)  [Source @ first] [Source @ second]" lines))
        (should (member "┃      made at a.el:5 · revision second (2222222)  [Source]" lines))
        (should (member "┃      │ +(setq a2 'three)" lines))
        (should (member "┃      │ +(setq a2 'two)" lines))
        ;; Where the thread is now is said of the comment written on an
        ;; earlier version, not of the one written on the newest.
        (should (member "┃      now: line 5 (was 3)" lines))
        (should (= 1 (cl-count-if (lambda (line) (string-prefix-p "┃      now:" line)) lines)))))))

(ert-deftest change-review-ui-where-says-whose-lines-it-shows-when-it-has-no-others ()
  "When the set has not the diff of the version a reply was written against, the
details show what the thread kept and say whose lines they are."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set ,thread ,_root ,reply) (change-review-ui-test--answered-set nil t))
                 (origin (change-review-origin set thread reply)))
      (should (equal "the lines are those of first, where the thread started" (plist-get origin :note)))
      (should (eql 3 (change-review-location-line (plist-get origin :location))))
      (should (member "┃      the lines are those of first, where the thread started"
                      (change-review-ui-test--lines
                       (change-review-ui-thread-string set thread :width 90 :details t)))))))

(ert-deftest change-review-ui-where-has-the-lines-of-an-agents-thread ()
  "A thread an agent started on a line of the second version has no excerpt of
its own; the diff of that version gives it one."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (second (change-review-find-version set 2))
           (comment (change-review-comment
                     set "This one is odd." :author (change-review-agent "Claude")
                     :time change-review-ui-test--now :revision (change-review-version-id second)
                     :location (change-review-make-location :file "a.el" :line 3 :side 'new)))
           (thread (change-review-find-thread set (change-review-comment-thread comment)))
           (location (plist-get (change-review-origin set thread comment) :location)))
      ;; The set's two versions have the one diff, so the line is as it was.
      (should (eql 3 (change-review-location-line location)))
      (should (string-suffix-p " (setq a3 3)" (change-review-location-excerpt location)))
      (should (member "┃      │ +(setq a2 'two)"
                      (change-review-ui-test--lines
                       (change-review-ui-thread-string set thread :width 90 :details t)))))))

(ert-deftest change-review-ui-where-leads-to-the-source ()
  "The details of a comment written against an earlier version have a button
for the code as it was then and one for the newest version's; the details of
one written against the newest have the one."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set ,thread ,root ,reply) (change-review-ui-test--answered-set t))
                 (string (change-review-ui-thread-string set thread :width 90 :details t)))
      (change-review-ui-test--press string "[Source @ first]")
      (change-review-ui-test--press string "[Source @ second]")
      (change-review-ui-test--press string "[Source]")
      (should (equal (list (list reply nil)
                           (list thread nil)
                           (list root "1111111111111111111111111111111111111111"))
                     (change-review-ui-test--spy-set-visited set))))))

(ert-deftest change-review-ui-d-and-D-show-the-thread-now-and-the-comment-then ()
  "d shows the thread in the newest version; D shows the code the comment at
point was written on, in the version it was written against."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set ,thread ,root ,reply) (change-review-ui-test--answered-set t))
                 (change-review-ui-sets nil)
                 (buffer (save-window-excursion (change-review-open-threads set 'all))))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq #'change-review-ui-show-source (key-binding "D")))
            (goto-char (point-min))
            (search-forward "Why 'two?")
            (call-interactively #'change-review-ui-show-source)
            (goto-char (point-min))
            (search-forward "Done: it is 'three now.")
            (call-interactively #'change-review-ui-show-source)
            (call-interactively #'change-review-ui-show-in-diff)
            (should (equal (list (list thread nil)
                                 (list reply "2222222222222222222222222222222222222222")
                                 (list root "1111111111111111111111111111111111111111"))
                           (change-review-ui-test--spy-set-visited set))))
        (kill-buffer buffer)))))

(ert-deftest change-review-ui-follows-a-line-of-the-diff-to-the-source ()
  "RET on a line of the diff the details show visits that line of the source,
in the version the comment was written against: a removed line is the old
file's."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set ,_thread ,root ,reply) (change-review-ui-test--answered-set t))
                 (change-review-ui-sets nil)
                 (buffer (save-window-excursion (change-review-open-threads set 'all))))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Why 'two?")
            (change-review-ui-show-origin)
            (change-review-ui-test--goto "│ \\+(setq a2 'two)")
            (should (eq #'change-review-ui-follow-source (key-binding (kbd "RET"))))
            (call-interactively #'change-review-ui-follow-source)
            (change-review-ui-test--goto "│ -(setq a2 2)")
            (call-interactively (key-binding (kbd "RET")))
            ;; The hunk header is no line of the source.
            (change-review-ui-test--goto "│ @@ -1,3 \\+1,3 @@")
            (should-error (call-interactively #'change-review-ui-follow-source) :type 'user-error)
            ;; The reply's lines are the second version's.
            (goto-char (point-min))
            (search-forward "Done: it is 'three now.")
            (change-review-ui-show-origin)
            (change-review-ui-test--goto "│ \\+(setq a2 'three)")
            (call-interactively #'change-review-ui-follow-source)
            (let ((visits (reverse (change-review-ui-test--spy-set-visited set))))
              (pcase-let ((`((,a ,a-version) (,b ,b-version) (,c ,c-version)) visits))
                (should (equal '("a.el" new 2) (list (change-review-location-file a)
                                                     (change-review-location-side a)
                                                     (change-review-location-line a))))
                (should (equal '("a.el" old 2) (list (change-review-location-file b)
                                                     (change-review-location-side b)
                                                     (change-review-location-line b))))
                ;; Line 4 of the second version, where the answer changed a2.
                (should (equal '("a.el" new 4) (list (change-review-location-file c)
                                                     (change-review-location-side c)
                                                     (change-review-location-line c))))
                (should (equal (change-review-comment-revision root) a-version))
                (should (equal (change-review-comment-revision root) b-version))
                (should (equal (change-review-comment-revision reply) c-version))
                (should (= 3 (length visits))))))
        (kill-buffer buffer)))))

(ert-deftest change-review-ui-follows-a-click-on-a-line-of-the-diff ()
  "A click on a line of the diff the details show visits its source line, as RET
does, wherever point is; a click elsewhere does nothing."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set ,_thread ,root ,_reply) (change-review-ui-test--answered-set t))
                 (change-review-ui-sets nil)
                 (buffer (save-window-excursion (change-review-open-threads set 'all))))
      (unwind-protect
          (with-current-buffer buffer
            (save-window-excursion
              (set-window-buffer (selected-window) buffer)
              (goto-char (point-min))
              (search-forward "Why 'two?")
              (change-review-ui-show-origin)
              (goto-char (point-min))
              (re-search-forward "│ \\+(setq a2 'two)")
              (let* ((on (match-beginning 0))
                     (click (lambda (position)
                              (list 'mouse-1 (list (selected-window) position '(0 . 0) 0)))))
                ;; Point is elsewhere: the click says which line.
                (goto-char (point-min))
                (change-review-ui-follow-source (funcall click on))
                (should (equal (list (list (change-review-make-location :file "a.el" :side 'new :line 2)
                                           (change-review-comment-revision root)))
                               (mapcar (lambda (visit)
                                         (list (change-review-make-location
                                                :file (change-review-location-file (car visit))
                                                :side (change-review-location-side (car visit))
                                                :line (change-review-location-line (car visit)))
                                               (cadr visit)))
                                       (change-review-ui-test--spy-set-visited set))))
                ;; Not a line of the diff.
                (should-error (change-review-ui-follow-source (funcall click (point-min)))
                              :type 'user-error))))
        (kill-buffer buffer)))))

(ert-deftest change-review-ui-visit-takes-a-version-and-a-location ()
  "The diff view shows the version asked for, with point on the line of a
location, or at a thread: the thread's place in that version."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set ,thread ,_root ,_reply) (change-review-ui-test--answered-set))
                 (change-review-ui-sets nil)
                 (buffers nil))
      (unwind-protect
          (save-window-excursion
            (let ((buffer (change-review-visit set (change-review-make-location :file "a.el" :side 'new :line 4)
                                               "first")))
              (push buffer buffers)
              (with-current-buffer buffer
                (should (equal "first" (change-review-version-label change-review-ui--version)))
                (should (equal " (setq a4 4)" (buffer-substring (line-beginning-position) (line-end-position))))))
            ;; A removed line is a line of the old file.
            (let ((buffer (change-review-visit set (change-review-make-location :file "a.el" :side 'old :line 2)
                                               "first")))
              (with-current-buffer buffer
                (should (equal "-(setq a2 2)" (buffer-substring (line-beginning-position) (line-end-position))))))
            ;; The thread, in the second version: line 5 there.
            (let ((buffer (change-review-visit set thread "second")))
              (push buffer buffers)
              (with-current-buffer buffer
                (should (equal "second" (change-review-version-label change-review-ui--version)))
                (should (eq thread (change-review-ui--thread-at-point)))
                (should (equal " (setq a3 3)" (buffer-substring (line-beginning-position) (line-end-position)))))))
        (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest change-review-ui-diff-view-folds-threads ()
  "A closed thread is one line in the diff view, its triangle pointing right;
TAB on its line opens it to its conversation and again folds it; with no
thread on the line TAB is what it is without the library's keys."
  (let ((change-review-ui-test--reviewed t))
  (change-review-ui-test--diff-view
    (let ((drawn (lambda (regexp)
                   (change-review-ui-test--goto regexp)
                   (substring-no-properties
                    (or (overlay-get (cl-find-if (lambda (o) (overlay-get o 'after-string))
                                                 (overlays-in (line-beginning-position)
                                                              (1+ (line-end-position))))
                                     'after-string)
                        "")))))
      (should (eq #'change-review-ui-cycle-fold (key-binding (kbd "TAB"))))
      (should (string-match-p "\n  ▸ ✓ [^ ]+ · closed .*“Fine\\.”\\'" (funcall drawn "^\\+(setq b2 'two)")))
      (should (string-match-p "\n  ▾ ● [^ ]+ · 1 comment · open " (funcall drawn "^ (setq a4 4)")))
      (let ((inhibit-message t))
        (change-review-ui-test--goto "^\\+(setq b2 'two)")
        (end-of-line)
        (call-interactively #'change-review-ui-cycle-fold)
        (change-review-ui-flush)
        (should (string-match-p "\n  ▾ ✓ [^ ]+ · 1 comment · closed by Claude.*\n    ┃ 1/1  Noah (you)"
                                (funcall drawn "^\\+(setq b2 'two)")))
        (end-of-line)
        (call-interactively #'change-review-ui-cycle-fold)
        (change-review-ui-flush)
        (should (string-match-p "\n  ▸ ✓ " (funcall drawn "^\\+(setq b2 'two)")))
        ;; On a line with no thread: what TAB does without the library's keys.
        (goto-char (point-min))
        (let (ran)
          (cl-letf (((symbol-function 'indent-for-tab-command)
                     (lambda (&rest _) (interactive) (setq ran t))))
            (call-interactively #'change-review-ui-cycle-fold))
          (should ran)))))))

(ert-deftest change-review-ui-diff-view-draws-closed-threads-in-full-when-asked ()
  "The option that says closed threads are not one line makes them as open ones."
  (let ((change-review-ui-collapse-closed-in-diff nil))
    (change-review-ui-test--diff-view
      (let ((text (overlay-get (cl-find-if (lambda (o) (and (overlay-get o 'after-string)
                                                            (string-match-p "Fine\\." (overlay-get o 'after-string))))
                                           (overlays-in (point-min) (point-max)))
                               'after-string)))
        (should (string-match-p "▾ ✓ " (substring-no-properties text)))
        (should (string-match-p "1/1  Noah" (substring-no-properties text)))))))

(ert-deftest change-review-ui-diff-view-keeps-the-folds-when-it-draws-again ()
  "What was folded stays so when the view is drawn again: after another
thread was answered, say."
  (change-review-ui-test--diff-view
    (change-review-ui-set-fold set (nth 1 threads) 'expanded)
    (change-review-ui-set-fold set (nth 3 threads) 'collapsed)
    (change-review-ui-flush)
    (let ((texts (mapcar (lambda (o) (substring-no-properties (overlay-get o 'after-string)))
                         (cl-remove-if-not (lambda (o) (overlay-get o 'after-string))
                                           (overlays-in (point-min) (point-max))))))
      (should (cl-some (lambda (text) (string-match-p "▾ ✓ .*\n.*1/1  Noah" text)) texts))
      (should (cl-some (lambda (text) (string-match-p "▸ ● .*“What about a4\\?”" text)) texts)))
    (change-review-comment set "Another thread" :author (change-review-ui-test--author)
                           :location (change-review-diff-location
                                      (car (change-review-version-files (change-review-latest-version set)))
                                      'new 5))
    (change-review-ui-flush)
    (should (cl-some (lambda (o) (string-match-p "▸ ● .*“What about a4\\?”"
                                                 (substring-no-properties (or (overlay-get o 'after-string) ""))))
                     (overlays-in (point-min) (point-max))))))

(ert-deftest change-review-ui-diff-view-cuts-a-thread-longer-than-the-window ()
  "A thread longer than the room the option gives is cut, with a line that
says how much, and TAB shows all of it."
  (let ((change-review-ui-max-thread-lines 7))
    (change-review-ui-test--diff-view
      (let ((comment (change-review-comment
                      set (mapconcat (lambda (n) (format "Line %d of a long comment." n))
                                     (number-sequence 1 12) "\n")
                      :author (change-review-ui-test--author) :time change-review-ui-test--now
                      :location (change-review-diff-location
                                 (car (change-review-version-files (change-review-latest-version set)))
                                 'new 6))))
        (change-review-ui-flush)
        (let ((drawn (lambda ()
                       (substring-no-properties
                        (overlay-get (cl-find-if (lambda (o) (string-match-p "long comment"
                                                                              (or (overlay-get o 'after-string) "")))
                                                 (overlays-in (point-min) (point-max)))
                                     'after-string)))))
          ;; The header, the comment's, four of its lines and the one that says more.
          (should (string-match-p "Line 4 of a long comment\\.\n    ┃      … 8 more lines\\'" (funcall drawn)))
          (should-not (string-match-p "Line 5 of" (funcall drawn)))
          (change-review-ui-test--goto "^ (setq a6 6)")
          (end-of-line)
          (should (equal (list (change-review-comment-thread comment))
                         (mapcar #'change-review-thread-id (change-review-ui--threads-here set))))
          (let ((inhibit-message t))
            (call-interactively #'change-review-ui-cycle-fold))
          (change-review-ui-flush)
          (should (string-match-p "Line 12 of a long comment\\.\\'" (funcall drawn)))
          (should-not (string-match-p "more lines" (funcall drawn))))))))

;;;; Emailed patches

(defconst change-review-ui-test--mbox
  (concat "From 1111111111111111111111111111111111111111 Mon Sep 17 00:00:00 2001\n"
          "From: Ann Author <ann@example.org>\n"
          "Date: Mon, 19 Oct 2026 10:00:00 +0000\n"
          "Subject: [PATCH] a: shout two\n"
          "Message-Id: <patch-1@example.org>\n"
          "\n"
          "Louder.\n"
          "---\n"
          " a.el | 2 +-\n"
          " 1 file changed, 1 insertion(+), 1 deletion(-)\n"
          "\n"
          "diff --git a/a.el b/a.el\n"
          "index 1111111..2222222 100644\n"
          "--- a/a.el\n"
          "+++ b/a.el\n"
          "@@ -1,3 +1,3 @@\n"
          " (setq a1 1)\n"
          "-(setq a2 2)\n"
          "+(setq a2 'two)\n"
          " (setq a3 3)\n"
          "-- \n"
          "2.43.0\n"
          "\n")
  "One emailed patch, as `git format-patch' writes it.")

(defmacro change-review-ui-test--with-patches (&rest body)
  "Run BODY with `file', the mbox of one patch, and a directory that keeps reviews."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "change-review-ui" t))
          (file (expand-file-name "patch.mbox" dir))
          (change-review-ui-directory (expand-file-name "reviews/" dir))
          (change-review-ui-sets nil))
     (unwind-protect
         (progn
           (with-temp-file file (insert change-review-ui-test--mbox))
           ,@body)
       (dolist (buffer (buffer-list))
         (when (string-match-p "\\`\\*\\(?:Review \\|change review reply\\)" (buffer-name buffer))
           (kill-buffer buffer)))
       (delete-directory dir t))))

(ert-deftest change-review-ui-opens-emailed-patches ()
  "A mailbox of patches shows as a diff to comment on; the comments are
kept in a file, and found again when the same patches are opened."
  (change-review-ui-test--with-patches
    (let ((buffer (save-window-excursion (change-review-open-patches file))))
      (with-current-buffer buffer
        (should (derived-mode-p 'change-review-diff-view-mode))
        (should (string-prefix-p "diff --git a/a.el b/a.el\n" (change-review-ui-test--text)))
        (let ((set change-review-ui--set))
          (should (equal "a: shout two" (change-review-set-title set)))
          (should (= 1 (length (change-review-set-versions set))))
          (should (equal "Ann Author" (change-review-author-label
                                        (change-review-version-author (car (change-review-set-versions set))))))
          (should (equal '("a.el") (mapcar #'change-review-file-path
                                            (change-review-version-files (car (change-review-set-versions set))))))
          ;; A comment on a line of the patch is kept in the file.
          (let ((change-review-ui-read-function (lambda (_p _i callback) (funcall callback "Why two?"))))
            (change-review-ui-test--goto "^+(setq a2 'two)")
            (call-interactively #'change-review-ui-comment-at-point))
          (should (file-exists-p (change-review-set-file set)))))
      ;; Opened again: the same set, its comment there, no second version.
      (let ((again (save-window-excursion (change-review-open-patches file))))
        (with-current-buffer again
          (let ((set change-review-ui--set))
            (should (= 1 (length (change-review-set-versions set))))
            (should (equal '("Why two?")
                           (mapcar (lambda (th) (change-review-comment-body (change-review-thread-root th)))
                                   (change-review-set-threads set))))
            (should (equal "a.el" (change-review-thread-file (car (change-review-set-threads set)))))))))))

(ert-deftest change-review-ui-writes-the-drafts-as-replies-to-the-patches ()
  "C-c C-c opens a reply mail to the patch with the drafts: the diff quoted,
the comment under it; sending the mail marks the comments sent."
  (change-review-ui-test--with-patches
    (let ((buffer (save-window-excursion (change-review-open-patches file))))
      (with-current-buffer buffer
        (let ((set change-review-ui--set)
              (change-review-ui-read-function (lambda (_p _i callback) (funcall callback "Why two?"))))
          (should (eq #'change-review-ui-send (key-binding (kbd "C-c C-c"))))
          (should-error (call-interactively #'change-review-ui-send) :type 'user-error)
          (change-review-ui-test--goto "^+(setq a2 'two)")
          (call-interactively #'change-review-ui-comment-at-point)
          (should (= 1 (length (change-review-drafts set))))
          (let* ((mail (car (save-window-excursion (call-interactively #'change-review-ui-send))))
                 (text (with-current-buffer mail (buffer-string))))
            (should (string-match-p "^To: Ann Author <ann@example.org>$" text))
            (should (string-match-p "^Subject: Re: \\[PATCH\\] a: shout two$" text))
            (should (string-match-p "^In-Reply-To: <patch-1@example.org>$" text))
            (should (string-search "> diff --git a/a.el b/a.el\n" text))
            (should (string-search "> +(setq a2 'two)\n\nWhy two?\n" text))
            ;; Sent: the drafts are no more.
            (with-current-buffer mail (run-hooks 'message-sent-hook))
            (should-not (change-review-drafts set))
            (should (change-review-comment-sent (change-review-thread-root (car (change-review-set-threads set)))))))))))

(ert-deftest change-review-ui-imports-the-reply-of-a-reviewer ()
  "The comments of a reply mail -- the diff quoted, the comment under it --
are threads of the change set, on the lines they were under, by whoever
wrote the mail; importing the mail again adds nothing."
  (change-review-ui-test--with-patches
    (let ((buffer (save-window-excursion (change-review-open-patches file)))
          (reply (concat "From: Bob Reviewer <bob@example.org>\n"
                         "Date: Mon, 19 Oct 2026 12:00:00 +0000\n"
                         "Subject: Re: [PATCH] a: shout two\n"
                         "Message-Id: <reply-1@example.org>\n"
                         "In-Reply-To: <patch-1@example.org>\n"
                         "\n"
                         "On Mon, 19 Oct 2026, Ann Author <ann@example.org> wrote:\n"
                         "> diff --git a/a.el b/a.el\n"
                         "> @@ -1,3 +1,3 @@\n"
                         ">  (setq a1 1)\n"
                         "> -(setq a2 2)\n"
                         "> +(setq a2 'two)\n"
                         "\n"
                         "Why quote it?\n"
                         "\n"
                         "-- \nBob\n")))
      (with-current-buffer buffer
        (let ((set change-review-ui--set))
          (should (= 1 (length (change-review-ui-import-reply reply))))
          (should (= 1 (length (change-review-set-threads set))))
          (let* ((thread (car (change-review-set-threads set)))
                 (root (change-review-thread-root thread)))
            (should (equal "Why quote it?" (change-review-comment-body root)))
            (should (equal "Bob Reviewer" (change-review-author-label (change-review-comment-author root))))
            (should (equal "a.el" (change-review-thread-file thread)))
            (should (eql 2 (change-review-thread-line thread)))
            (should-not (change-review-comment-draft-p root)))
          ;; Again: the same comment, once.
          (change-review-ui-import-reply reply)
          (should (= 1 (length (change-review-set-threads set))))
          ;; And under its line in the diff view.
          (change-review-ui-flush)
          (should (cl-some (lambda (o) (string-search "Why quote it?" (or (overlay-get o 'after-string) "")))
                           (overlays-in (point-min) (point-max)))))))))


;;;; The README

(ert-deftest change-review-ui-readme-example-builds-a-set-and-opens-it ()
  "The example of the README: a set from a diff, a comment on a line, a view."
  (change-review-ui-test--drawing
    (let ((buffer nil))
      (unwind-protect
          (let ((set (change-review-make-set :id "demo" :title "A demo")))
            (change-review-add-version
             set (change-review-diff-version change-review-ui-test--patch
                                             :id "3f9a1c2" :label "v1"))
            (change-review-comment
             set "Why 'two?"
             :location (change-review-diff-location
                        (car (change-review-version-files (change-review-latest-version set)))
                        'new 2)
             :revision "3f9a1c2")
            (setq buffer (save-window-excursion (change-review-open-threads set)))
            (with-current-buffer buffer
              (should (derived-mode-p 'change-review-threads-mode))
              (should (string-search "▾ a.el" (change-review-ui-test--text)))
              (should (string-search "Why 'two?" (change-review-ui-test--text)))
              (should (string-search "draft" (change-review-ui-test--text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;;;; Where a comment's text is

(defconst change-review-ui-test--question
  (concat "Why does the retry loop wait eighteen seconds? The tests only ever use "
          "seventeen, and nothing in the docs says why that is.\n\nSecond paragraph of the question.")
  "A comment whose text wraps, has a blank line and a second paragraph.")

(defun change-review-ui-test--wrapped-set ()
  "Return (SET THREAD FIRST SECOND): a thread of two comments, the first one's text long.
The first is the user's, the second the agent's, an answer to it."
  (let* ((set (change-review-ui-test--set))
         (rev (change-review-version-id (change-review-latest-version set)))
         (first (change-review-comment
                 set change-review-ui-test--question
                 :author (change-review-ui-test--author) :time (- change-review-ui-test--now 7200)
                 :revision rev :sent (- change-review-ui-test--now 7000)
                 :location (change-review-diff-location
                            (cl-find "a.el" (change-review-version-files (change-review-latest-version set))
                                     :key #'change-review-file-path :test #'equal)
                            'new 3)))
         (second (change-review-reply
                  set first "Because the loop needs one more than that: it counts the first try as well."
                  :author (change-review-agent "Claude" :session "sess-1" :tool-call "toolu_9")
                  :time (- change-review-ui-test--now 3600) :revision rev
                  :sent (- change-review-ui-test--now 3600))))
    (list set (change-review-find-thread set (change-review-comment-thread first)) first second)))

(defmacro change-review-ui-test--wrapped-view (&rest body)
  "Run BODY in the threads view of the set of `change-review-ui-test--wrapped-set'.
Bind `set', `thread', `first' and `second'."
  (declare (indent 0))
  `(change-review-ui-test--drawing
     (pcase-let* ((`(,set ,thread ,first ,second) (change-review-ui-test--wrapped-set))
                  (change-review-ui-sets nil)
                  (buffer (save-window-excursion (change-review-open-threads set 'all))))
       (ignore set thread first second)
       (unwind-protect
           (with-current-buffer buffer ,@body)
         (kill-buffer buffer)))))

(ert-deftest change-review-ui-wrap-says-where-each-piece-starts ()
  "A piece comes with where it starts in the line: what the cuts left out,
the spaces, is in none, and a piece that was cut inside a word follows the
one before."
  (should (equal '(("short" . 0)) (change-review-ui--wrap-offsets "short" 20)))
  (should (equal '(("" . 0)) (change-review-ui--wrap-offsets "" 20)))
  (should (equal '(("the quick brown" . 0) ("fox jumps over" . 16) ("the lazy dog" . 31))
                 (change-review-ui--wrap-offsets "the quick brown fox jumps over the lazy dog" 16)))
  (should (equal '(("abcdefghij" . 0) ("klmnopqrst" . 10) ("uv" . 20))
                 (change-review-ui--wrap-offsets "abcdefghijklmnopqrstuv" 10)))
  ;; Spaces at a cut are all left out; the first piece keeps its indentation.
  (should (equal '(("  indented line" . 0) ("goes on" . 20))
                 (change-review-ui--wrap-offsets "  indented line     goes on" 16)))
  (let ((line (string-join (make-list 12 "words") " ")))
    (dolist (piece (change-review-ui--wrap-offsets line 20))
      (should (equal (car piece) (substring line (cdr piece) (+ (cdr piece) (length (car piece)))))))))

(ert-deftest change-review-ui-draws-where-the-text-of-a-comment-is ()
  "The lines that hold a comment's text say where in the text they are, from
their first character to their newline: nothing else of the drawing does."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set ,thread ,first ,_) (change-review-ui-test--wrapped-set))
                 (string (change-review-ui-thread-string set thread :width 80 :indent "  "))
                 (body (change-review-comment-body first))
                 (pos 0)
                 (lines nil))
      (while (setq pos (text-property-not-all pos (length string) 'change-review-body nil string))
        (pcase-let ((`(,start ,from ,to ,length) (change-review-ui--body-line pos string)))
          (when (equal (change-review-comment-id first)
                       (get-text-property pos 'change-review-comment string))
            (push (list start (substring-no-properties string from (+ from length))) lines))
          ;; The newline is part of it, the bar before is not.
          (should (eq ?\n (aref string (1- to))))
          (should-not (get-text-property (1- from) 'change-review-body string))
          (setq pos to)))
      (setq lines (nreverse lines))
      ;; The text wraps, a blank line and a second paragraph follow.
      (should (>= (length lines) 4))
      (should (equal '("" "Second paragraph of the question.") (last (mapcar #'cadr lines) 2)))
      (dolist (line lines)
        (should (equal (cadr line) (substring body (car line) (+ (car line) (length (cadr line)))))))
      ;; What was left out of the drawing is only the spaces at the cuts.
      (should (equal body (concat (mapconcat (lambda (line) (cadr line)) (cl-subseq lines 0 2) " ")
                                  "\n\n" (cadr (car (last lines)))))))))

(defun change-review-ui-test--odd-text (seed)
  "Return a comment's text made at random from SEED: words of every width, blanks and lines."
  (random (format "change-review-%d" seed))
  (let ((words '("a" "bb" "ccc" "dddd" "eeeee" "ffffff" "ggggggg" "hhhhhhhh"
                 "supercalifragilisticexpialidocious-and-more-and-more-and-more-and-more"
                 "ünïcödé" "日本語のテキスト" "x" "'quoted'" "> q" ">" "\t" "tab\tbed"))
        (blanks '(" " " " " " "  " "   " "\n" "\n\n" " \n" "\n "))
        (text ""))
    (dotimes (_ (+ 1 (random 40)))
      (setq text (concat text (nth (random (length words)) words) (nth (random (length blanks)) blanks))))
    text))

(ert-deftest change-review-ui-every-character-drawn-maps-back-to-the-text ()
  "Whatever a comment says -- indented, with long words, tabs, blank lines, wide
characters -- and however wide the drawing, each character of its text on the
drawing is the very character of the text that its place says, and a region over
all the drawing holds all of the text, bar the blanks."
  (change-review-ui-test--drawing
    (let ((checked 0))
      (dotimes (seed 60)
        (let* ((body (change-review-ui-test--odd-text seed))
               (width (+ 30 (random 60)))
               (set (change-review-ui-test--set))
               (comment (change-review-comment set body :author (change-review-ui-test--author)
                                               :time change-review-ui-test--now))
               (thread (change-review-find-thread set (change-review-comment-thread comment)))
               (string (change-review-ui-thread-string set thread :width width :indent "  "))
               (pos 0))
          (ert-info ((format "seed %d, width %d, text %S" seed width body))
            (while (and (< pos (length string))
                        (setq pos (text-property-not-all pos (length string) 'change-review-body nil string)))
              (pcase-let ((`(,start ,from ,to ,length) (change-review-ui--body-line pos string)))
                (dotimes (i length)
                  (cl-incf checked)
                  (let ((offset (cdr (change-review-ui--offset-at (+ from i) string))))
                    (should (= offset (+ start i)))
                    (should (eq (aref string (+ from i)) (aref body offset)))))
                (setq pos to)))
            (unless (string-blank-p body)
              (with-temp-buffer
                (insert string)
                (let* ((part (car (change-review-ui--region-parts (point-min) (point-max))))
                       (squeeze (lambda (text) (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))))
                  (should (equal (change-review-comment-id comment) (car part)))
                  (should (equal (funcall squeeze body)
                                 (funcall squeeze (substring body (nth 1 part) (nth 2 part)))))))))))
      ;; A real run, not an empty one.
      (should (> checked 1000)))))

(ert-deftest change-review-ui-reads-a-place-in-the-drawing-as-a-place-in-the-text ()
  "A place in the text is the offset of that character; the header and the
bar stand for the start of the text or of the line, the lines that say where
the comment was made for its end."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set ,thread ,first ,second) (change-review-ui-test--wrapped-set))
                 (string (change-review-ui-thread-string
                          set thread :width 80 :indent "  "
                          :details (list (change-review-comment-id first))))
                 (body (change-review-comment-body first))
                 (id (change-review-comment-id first))
                 (index (lambda (text) (string-search text string)))
                 (at (lambda (pos) (change-review-ui--offset-at pos string))))
      ;; The text itself.
      (should (equal (cons id (string-search "only ever" body)) (funcall at (funcall index "only ever"))))
      (should (equal (cons id (string-search "seventeen," body)) (funcall at (funcall index "seventeen,"))))
      ;; Before the text: the thread's header, the comment's, the bar.
      (should-not (funcall at 0))
      (should (equal (cons id 0) (funcall at (funcall index "1/2"))))
      (should (equal (cons id 0) (funcall at (1- (funcall index "Why does")))))
      ;; The bar of the second line is where that line starts.
      (should (equal (cons id (string-search "seventeen," body))
                     (funcall at (- (funcall index "seventeen,") 3))))
      ;; Where the comment was made, under the text: its end.
      (should (equal (cons id (length body)) (funcall at (funcall index "made at"))))
      ;; The next comment is another's.
      (should (equal (cons (change-review-comment-id second) 0) (funcall at (funcall index "2/2"))))
      ;; The newline that ends a line of text is where the line ends.
      (should (equal (cons id (length "Why does the retry loop wait eighteen seconds? The tests only ever use"))
                     (funcall at (+ (funcall index "only ever use") (length "only ever use"))))))))

(ert-deftest change-review-ui-faces-the-lines-that-quote ()
  "A line of a comment that starts with \">\" quotes: it has the quote's face,
every piece it wraps to, and no other line has it."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (quoted (string-join (make-list 20 "quoted") " "))
           (comment (change-review-comment set (concat "> " quoted "\n>\nAn answer.")
                                           :author (change-review-ui-test--author)
                                           :time change-review-ui-test--now))
           (thread (change-review-find-thread set (change-review-comment-thread comment)))
           (string (change-review-ui-thread-string set thread :width 60))
           (pos 0)
           (rows nil))
      (while (setq pos (text-property-not-all pos (length string) 'change-review-body nil string))
        (pcase-let ((`(,_ ,from ,to ,length) (change-review-ui--body-line pos string)))
          (push (list (substring-no-properties string from (+ from length))
                      ;; Whether every character of it has the face.
                      (null (text-property-not-all from (+ from length) 'face
                                                   'change-review-ui-quote-face string)))
                rows)
          (setq pos to)))
      (setq rows (nreverse rows))
      ;; The long line wraps, then the bare ">" and the answer.
      (should (> (length rows) 3))
      (should (equal '("An answer." nil) (car (last rows))))
      (should (equal '(">" t) (car (last (butlast rows)))))
      (should (cl-every #'cadr (butlast rows)))
      (should (string-prefix-p "> quoted" (car (car rows)))))))

(ert-deftest change-review-ui-quotes-text-as-markdown ()
  "Every line is after \"> \", a blank one reads \">\", the blanks around go."
  (should (equal "> one" (change-review-ui-quote-string "one")))
  (should (equal "> one\n>\n> two" (change-review-ui-quote-string "\n\none  \n\ntwo\n\n")))
  (should (equal ">     code\n> more" (change-review-ui-quote-string "    code\nmore")))
  (should (equal "> > a quote already" (change-review-ui-quote-string "> a quote already")))
  (should-not (get-text-property 0 'face (change-review-ui-quote-string (propertize "one" 'face 'bold)))))

;;;; Quote reply

(defun change-review-ui-test--region (start-text end-text)
  "Select, in this buffer, from where START-TEXT starts to where END-TEXT ends."
  (goto-char (point-min))
  (search-forward start-text)
  (set-mark (match-beginning 0))
  (search-forward end-text)
  (activate-mark))

(defun change-review-ui-test--reading (&optional answer)
  "Return a reader function and what it was asked, a cons: (FUNCTION . CALLS).
FUNCTION answers every call with ANSWER, added to the text it starts from.
CALLS is a symbol's value, the list (PROMPT INITIAL POINT) of each."
  (let* ((calls (make-symbol "calls")))
    (set calls nil)
    (cons (lambda (prompt initial callback &optional point)
            (set calls (append (symbol-value calls) (list (list prompt initial point))))
            (funcall callback (concat initial (or answer ""))))
          calls)))

(ert-deftest change-review-ui-quote-reply-quotes-what-the-region-holds ()
  "In the threads view C-c > replies to the comment with what is selected of
it quoted: its text as it was written, wrapped though it is drawn, with
nothing of the bar; point starts under the quote."
  (change-review-ui-test--wrapped-view
    (let* ((transient-mark-mode t)
           (reading (change-review-ui-test--reading "Seventeen is a guess."))
           (body (change-review-comment-body first))
           (quoted (substring body (string-search "only ever use" body)
                              (+ (string-search "says why" body) (length "says why")))))
      (should (eq #'change-review-ui-quote-reply (key-binding (kbd "C-c >"))))
      (change-review-ui-test--region "only ever use" "says why")
      (let ((change-review-ui-read-function (car reading)))
        (call-interactively #'change-review-ui-quote-reply))
      ;; Asked once, for a reply to the first comment, starting with the quote.
      (should (= 1 (length (symbol-value (cdr reading)))))
      (pcase-let ((`(,prompt ,initial ,point) (car (symbol-value (cdr reading)))))
        (should (string-match-p "\\`Reply to Noah's comment 1/2 on a\\.el:3" prompt))
        (should (equal (concat "> " quoted "\n\n") initial))
        (should-not (string-match-p "┃" initial))
        (should (eq 'end point)))
      (let ((reply (change-review-thread-last-comment thread)))
        (should (equal (concat "> " quoted "\n\nSeventeen is a guess.") (change-review-comment-body reply)))
        (should (equal (change-review-comment-id first) (change-review-comment-reply-to reply)))
        (should (change-review-comment-draft-p reply)))
      ;; The region is no longer.
      (should-not mark-active))))

(ert-deftest change-review-ui-quote-reply-keeps-the-paragraphs-of-a-selection ()
  "A selection over a blank line is a quote of two paragraphs, one block."
  (change-review-ui-test--wrapped-view
    (let ((transient-mark-mode t)
          (reading (change-review-ui-test--reading "Fine.")))
      (change-review-ui-test--region "docs says why that is." "Second paragraph")
      (let ((change-review-ui-read-function (car reading)))
        (call-interactively #'change-review-ui-quote-reply))
      (should (equal (cadr (car (symbol-value (cdr reading))))
                     (concat "> " (substring (change-review-comment-body first)
                                             (string-search "docs says why" (change-review-comment-body first))
                                             (string-search "\n\n" (change-review-comment-body first)))
                             "\n>\n> Second paragraph\n\n"))))))

(ert-deftest change-review-ui-quote-reply-quotes-the-whole-comment-without-a-region ()
  "Without a selection it quotes all of the comment at point; on the thread's
header, the last comment of the thread."
  (change-review-ui-test--wrapped-view
    ;; Nothing is answered, so the thread stays as it is.
    (let ((reading (change-review-ui-test--reading)))
      (let ((change-review-ui-read-function (car reading)))
        (goto-char (point-min))
        (search-forward "Because the loop")
        (call-interactively #'change-review-ui-quote-reply)
        ;; On the first comment: the whole of its text, both paragraphs.
        (goto-char (point-min))
        (search-forward "Why does the retry")
        (call-interactively #'change-review-ui-quote-reply)
        ;; On the thread's header: the last comment, the agent's.
        (goto-char (point-min))
        (re-search-forward "^  ● ")
        (call-interactively #'change-review-ui-quote-reply))
      (should (= 3 (length (symbol-value (cdr reading)))))
      (should (equal (list (concat (change-review-ui-quote-string (change-review-comment-body second)) "\n\n")
                           (concat (change-review-ui-quote-string (change-review-comment-body first)) "\n\n")
                           (concat (change-review-ui-quote-string (change-review-comment-body second)) "\n\n"))
                     (mapcar #'cadr (symbol-value (cdr reading)))))
      (should (equal '("Reply to Claude's comment 2/2" "Reply to Noah's comment 1/2"
                       "Reply to Claude's comment 2/2")
                     (mapcar (lambda (call) (substring (car call) 0 (string-search " on " (car call))))
                             (symbol-value (cdr reading)))))
      (should (= 2 (length (change-review-thread-comments thread)))))))

(ert-deftest change-review-ui-quote-reply-quotes-comments-under-who-wrote-them ()
  "A selection of the text of several comments quotes each, under a line that
says who wrote it, in a reply to the last."
  (change-review-ui-test--wrapped-view
    (let ((transient-mark-mode t)
          (reading (change-review-ui-test--reading "Both.")))
      (change-review-ui-test--region "Second paragraph" "needs one more")
      (let ((change-review-ui-read-function (car reading)))
        (call-interactively #'change-review-ui-quote-reply))
      (should (equal (concat "Noah wrote:\n> Second paragraph of the question.\n\n"
                             "Claude wrote:\n> Because the loop needs one more\n\n")
                     (cadr (car (symbol-value (cdr reading))))))
      (should (string-match-p "\\`Reply to Claude's comment 2/2" (car (car (symbol-value (cdr reading)))))))))

(ert-deftest change-review-ui-quote-reply-replies-in-one-thread-only ()
  "A selection of the text of two threads quotes in neither: it says so."
  (change-review-ui-test--drawing
    (pcase-let* ((`(,set ,thread ,_first ,_second) (change-review-ui-test--wrapped-set))
                 (other (change-review-comment set "Another thread altogether, further down."
                                               :author (change-review-ui-test--author)
                                               :time change-review-ui-test--now))
                 (change-review-ui-sets nil)
                 (buffer (save-window-excursion (change-review-open-threads set 'all)))
                 (reading (change-review-ui-test--reading "No.")))
      (ignore thread other)
      (unwind-protect
          (with-current-buffer buffer
            (let ((transient-mark-mode t)
                  (change-review-ui-read-function (car reading)))
              ;; The change's own thread comes first in the view, then the file's.
              (change-review-ui-test--region "Another thread" "Why does the retry")
              (should-error (call-interactively #'change-review-ui-quote-reply) :type 'user-error)
              (should-not (symbol-value (cdr reading)))))
        (kill-buffer buffer)))))

(ert-deftest change-review-ui-quote-reply-needs-some-text-of-a-comment ()
  "A region that holds no text of a comment says so, and no reply starts; so does
a place that is no comment's."
  (change-review-ui-test--wrapped-view
    (let ((transient-mark-mode t)
          (reading (change-review-ui-test--reading "No.")))
      (let ((change-review-ui-read-function (car reading)))
        ;; Only a header.
        (change-review-ui-test--region "1/2  Noah" "(you)")
        (should-error (call-interactively #'change-review-ui-quote-reply) :type 'user-error)
        ;; The words are blank.
        (deactivate-mark)
        (goto-char (point-min))
        (should-error (call-interactively #'change-review-ui-quote-reply) :type 'user-error))
      (should-not (symbol-value (cdr reading)))
      (should (= 2 (length (change-review-thread-comments thread)))))))

(ert-deftest change-review-ui-a-quote-alone-is-no-reply ()
  "A reply that is only the quote it started with answers nothing: no draft."
  (change-review-ui-test--wrapped-view
    (let ((count (length (change-review-thread-comments thread)))
          (reading (change-review-ui-test--reading)))
      (goto-char (point-min))
      (search-forward "Because the loop")
      (let ((change-review-ui-read-function (car reading)))
        (call-interactively #'change-review-ui-quote-reply)
        ;; The quote, and an answer under it that is blank.
        (should (= count (length (change-review-thread-comments thread))))
        ;; An answer above it is an answer.
        (setq change-review-ui-read-function
              (lambda (_prompt initial callback &optional _point)
                (funcall callback (concat "Agreed.\n\n" initial))))
        (call-interactively #'change-review-ui-quote-reply))
      (should (= (1+ count) (length (change-review-thread-comments thread))))
      (should (string-prefix-p "Agreed.\n\n> Because" (change-review-comment-body
                                                       (change-review-thread-last-comment thread)))))))

(ert-deftest change-review-ui-reading-a-comment-says-where-point-starts-only-to-readers-that-ask ()
  "A reader that takes a fourth argument is told where point starts; one that
takes three is called as before, and the reply that quotes nothing does not
say where."
  (change-review-ui-test--wrapped-view
    (let (told)
      (goto-char (point-min))
      (search-forward "Because the loop")
      (let ((change-review-ui-read-function
             (lambda (_prompt _initial callback) (push 'three told) (funcall callback ""))))
        (call-interactively #'change-review-ui-quote-reply))
      (let ((change-review-ui-read-function
             (lambda (_prompt _initial callback &optional point)
               (push (list 'four point) told) (funcall callback ""))))
        (call-interactively #'change-review-ui-quote-reply)
        (call-interactively #'change-review-ui-reply))
      (let ((change-review-ui-read-function
             (lambda (_prompt _initial callback &rest more)
               (push (cons 'rest more) told) (funcall callback ""))))
        (call-interactively #'change-review-ui-quote-reply))
      (should (equal '(three (four end) (four nil) (rest end)) (nreverse told))))))

(ert-deftest change-review-ui-the-reply-is-read-with-point-under-the-quote ()
  "The default reader opens the buffer with point after the quote it starts
with; before the text it starts from when no point is asked for."
  (change-review-ui-test--drawing
    (let ((read nil))
      (unwind-protect
          (save-window-excursion
            (change-review-ui-read "Reply:" "> a quote\n\n" #'ignore 'end)
            (setq read (window-buffer (selected-window)))
            (with-current-buffer read
              (should (string-prefix-p "*edit string*" (buffer-name)))
              (should (= (point) (point-max)))
              (should (string-suffix-p "> a quote\n\n" (buffer-string)))
              (should (get-text-property (point-min) 'read-only)))
            (kill-buffer read)
            (change-review-ui-read "Reply:" "text\n\n" #'ignore)
            (setq read (window-buffer (selected-window)))
            (with-current-buffer read
              (should (looking-at "text\n\n"))))
        (when (buffer-live-p read) (kill-buffer read))))))

(ert-deftest change-review-ui-the-reply-answers-a-quote-inline-where-compose-quote-is ()
  "Where the compose-quote library is on the load path, the buffer a comment is
read in answers a quote inline: M-RET splits it, C-c [ elides part of it, and
the prompt above the text is no part of what it works on."
  (skip-unless (locate-library "compose-quote"))
  (require 'compose-quote)
  (change-review-ui-test--drawing
    (let ((read nil)
          (compose-quote-inline-hint nil))
      (unwind-protect
          (save-window-excursion
            (change-review-ui-read "Reply:" "> one two three\n>\n> four five six\n\n" #'ignore 'end)
            (setq read (window-buffer (selected-window)))
            (with-current-buffer read
              (should (bound-and-true-p compose-quote-mode))
              ;; The composition starts under the prompt.
              (let ((area (funcall compose-quote-area-function)))
                (should (equal "> one two" (buffer-substring (car area) (+ (car area) 9))))
                (should (= (cadr area) (point-max))))
              ;; Point at the end is no quote's, and so has none of its keys.
              (run-hooks 'post-command-hook)
              (should-not (key-binding (kbd "M-RET")))
              ;; In the quote, the keys are there: split it to answer the first part.
              (goto-char (point-min))
              (search-forward "one two")
              (run-hooks 'post-command-hook)
              (should (eq 'compose-quote-split (key-binding (kbd "M-RET"))))
              (should (eq 'compose-quote-elide (key-binding (kbd "C-c ["))))
              (call-interactively #'compose-quote-split)
              ;; An empty line for the answer, a blank line from each part.
              (should (string-search "> one two\n\n\n\n> three\n>\n> four" (buffer-string)))))
        (when (buffer-live-p read) (kill-buffer read))))))

(ert-deftest change-review-ui-offers-quote-reply-in-every-view ()
  "C-c > is the quote reply in the threads view, the diff view and the buffers
that show threads under their lines."
  (should (eq #'change-review-ui-quote-reply (lookup-key change-review-threads-mode-map (kbd "C-c >"))))
  (should (eq #'change-review-ui-quote-reply (lookup-key change-review-diff-view-mode-map (kbd "C-c >"))))
  (should (eq #'change-review-ui-quote-reply (lookup-key change-review-ui-lines-mode-map (kbd "C-c >"))))
  (change-review-ui-test--diff-view
    (should (eq #'change-review-ui-quote-reply (key-binding (kbd "C-c >"))))))

;;;; Selecting the text of a thread under a line

(defun change-review-ui-test--posn (overlay x y)
  "Return the mouse position at pixel X, Y over the text of OVERLAY, drawn in a window.
There is no display here, so the window is laid out in the mind: a column is
a pixel wide and a row ten pixels high, the first row the one that ends the
line the thread is under, and the thread's text after it."
  (let* ((string (overlay-get overlay 'after-string))
         (rows (let ((start 0) (rows nil))
                 (while (<= start (length string))
                   (let ((end (or (string-search "\n" string start) (length string))))
                     (push (cons start end) rows)
                     (setq start (1+ end))))
                 (nreverse rows)))
         (row (nth (/ y 10) rows))
         (index (and row (< x (- (cdr row) (car row))) (+ (car row) x)))
         (pos (overlay-start overlay)))
    (list (selected-window) pos (cons x y) 0 (and index (cons string index)) pos
          (cons x (/ y 10)) nil (cons 0 0) (cons 1 10))))

(defun change-review-ui-test--where (overlay text &optional after)
  "Return (X . Y), the pixel where TEXT starts in what OVERLAY shows; AFTER, how far into it.
Y is the middle of the row."
  (let* ((string (overlay-get overlay 'after-string))
         (index (+ (or (string-search text string) (error "No %S" text)) (or after 0)))
         (row (cl-count ?\n (substring string 0 index)))
         (start (let ((newline (cl-position ?\n string :end index :from-end t))) (if newline (1+ newline) 0))))
    (cons (- index start) (+ (* 10 row) 5))))

(defun change-review-ui-test--drag (overlay from to &optional click-count)
  "Press the mouse at FROM, (X . Y), move it to TO and release it, over OVERLAY's text.
Run `change-review-ui-mouse-select' as the command loop would, its events
read from what the mouse does after the press.  With CLICK-COUNT, a double or
triple click."
  (cl-letf (((symbol-function 'posn-at-x-y)
             (lambda (x y &optional _window _whole) (change-review-ui-test--posn overlay x y))))
    (let* ((start (change-review-ui-test--posn overlay (car from) (cdr from)))
           (end (change-review-ui-test--posn overlay (car to) (cdr to)))
           (count (or click-count 1))
           (down (append (list (pcase count (1 'down-mouse-1) (2 'double-down-mouse-1) (_ 'triple-down-mouse-1)) start)
                         (and (> count 1) (list count))))
           (up (cond ((equal from to) (append (list (pcase count (1 'mouse-1) (2 'double-mouse-1) (_ 'triple-mouse-1)) start)
                                              (and (> count 1) (list count))))
                     (t (list 'drag-mouse-1 start end)))))
      (setq unread-command-events
            (append (unless (equal from to) (list (list 'mouse-movement end))) (list up)))
      (let ((this-command 'change-review-ui-mouse-select))
        (change-review-ui-mouse-select down))
      (should-not unread-command-events))))

(defun change-review-ui-test--selected (overlay)
  "Return the text selected of the thread OVERLAY draws, or nil."
  (when-let* ((selection (overlay-get overlay 'change-review-selection))
              (found (change-review-find-comment change-review-ui--set (car selection))))
    (substring (change-review-comment-body (cdr found)) (nth 1 selection) (nth 2 selection))))

(defun change-review-ui-test--marked (overlay)
  "Return the characters of what OVERLAY shows that have the face of a selection."
  (let ((string (overlay-get overlay 'after-string)) (marked nil))
    (dotimes (i (length string))
      (when (memq 'change-review-ui-selection-face
                  (ensure-list (get-text-property i 'face string)))
        (push (aref string i) marked)))
    (concat (nreverse marked))))

(defmacro change-review-ui-test--under-a-line (&rest body)
  "Run BODY in a buffer, shown in the selected window, with a thread drawn under a line.
The thread is that of `change-review-ui-test--wrapped-set'; bind `set',
`thread', `first', `second' and `overlay'."
  (declare (indent 0))
  `(change-review-ui-test--drawing
     (pcase-let ((`(,set ,thread ,first ,second) (change-review-ui-test--wrapped-set)))
       (with-temp-buffer
         (save-window-excursion
           (set-window-buffer (selected-window) (current-buffer))
           (insert "one\ntwo\nthree\n")
           (setq change-review-ui--set set)
           (change-review-ui-lines-mode 1)
           (goto-char (point-min))
           (forward-line 1)
           (let ((overlay (change-review-ui-add-thread-overlay
                           set thread (line-end-position) :view 'diff :width 80 :indent "  "))
                 (transient-mark-mode t))
             (ignore set thread first second overlay)
             ,@body))))))

(ert-deftest change-review-ui-the-text-under-a-line-has-the-mouse-to-select-it ()
  "A thread under a line is a string, and the mouse selects the text of its
comments: only that text has the keys, and every character of the string
knows its overlay."
  (change-review-ui-test--under-a-line
    (let ((string (overlay-get overlay 'after-string)))
      (should (eq overlay (get-text-property (1- (length string)) 'change-review-view string)))
      (should (eq overlay (get-text-property 3 'change-review-view string)))
      (dolist (text '("only ever" "Because the loop"))
        (let ((index (string-search text string)))
          (should (eq change-review-ui-text-map (get-text-property index 'keymap string)))
          (should (eq #'change-review-ui-mouse-select
                      (key-binding [down-mouse-1] t nil
                                   (change-review-ui-test--posn
                                    overlay (car (change-review-ui-test--where overlay text))
                                    (cdr (change-review-ui-test--where overlay text))))))))
      ;; Not the header, nor the bar.
      (should-not (eq change-review-ui-text-map (get-text-property (string-search "Noah" string) 'keymap string)))
      (should-not (eq change-review-ui-text-map (get-text-property (string-search "┃" string) 'keymap string)))
      (should (eq #'mouse-drag-region
                  (key-binding [down-mouse-1] t nil
                               (change-review-ui-test--posn
                                overlay (car (change-review-ui-test--where overlay "Noah"))
                                (cdr (change-review-ui-test--where overlay "Noah"))))))
      ;; The buttons still press.
      (should (eq #'push-button (key-binding [mouse-2] t nil
                                             (change-review-ui-test--posn
                                              overlay (car (change-review-ui-test--where overlay "[Reply]"))
                                              (cdr (change-review-ui-test--where overlay "[Reply]")))))))))

(ert-deftest change-review-ui-a-drag-selects-the-text-of-a-comment ()
  "Dragging from one place of a comment's text to another selects what is
between, which is marked in what the overlay shows, across the rows the text
wraps to, and nothing else is."
  (change-review-ui-test--under-a-line
    ;; Within a row: up to the place the mouse is over.
    (change-review-ui-test--drag overlay (change-review-ui-test--where overlay "only ever")
                                 (change-review-ui-test--where overlay "only ever" 9))
    (should (equal "only ever" (change-review-ui-test--selected overlay)))
    (should (equal "only ever" (change-review-ui-test--marked overlay)))
    ;; The same backwards.
    (change-review-ui-test--drag overlay (change-review-ui-test--where overlay "only ever" 9)
                                 (change-review-ui-test--where overlay "only ever"))
    (should (equal "only ever" (change-review-ui-test--selected overlay)))
    ;; Over the wrapped lines, with the space the wrap left out.
    (change-review-ui-test--drag overlay (change-review-ui-test--where overlay "only ever")
                                 (change-review-ui-test--where overlay "and nothing" 3))
    (should (equal "only ever use seventeen, and" (change-review-ui-test--selected overlay)))
    (should (equal "only ever useseventeen, and" (change-review-ui-test--marked overlay)))
    ;; Only the comment it began in: the next one's text is no part of it.
    (change-review-ui-test--drag overlay (change-review-ui-test--where overlay "Second paragraph")
                                 (change-review-ui-test--where overlay "Because the loop" 7))
    (should (equal "Second paragraph of the question." (change-review-ui-test--selected overlay)))
    (should (equal "Second paragraph of the question." (change-review-ui-test--marked overlay)))
    ;; The text of the string is what it was.
    (should (equal (substring-no-properties (overlay-get overlay 'change-review-text) 0 -1)
                   (substring-no-properties (overlay-get overlay 'after-string) 1)))))

(ert-deftest change-review-ui-a-drag-past-the-text-goes-to-where-it-ends ()
  "To the right of a row of text the selection reaches its end; above the text
it reaches the start, under it the end."
  (change-review-ui-test--under-a-line
    (let ((from (change-review-ui-test--where overlay "only ever")))
      ;; Far to the right of the row "...only ever use": to its end.
      (change-review-ui-test--drag overlay from (cons 300 (cdr from)))
      (should (equal "only ever use" (change-review-ui-test--selected overlay)))
      ;; Over the header of the comment above, and over the thread's header.
      (change-review-ui-test--drag overlay from (cons 20 15))
      (should (equal "Why does the retry loop wait eighteen seconds? The tests " (change-review-ui-test--selected overlay)))
      (change-review-ui-test--drag overlay from (cons 20 5))
      (should (equal "Why does the retry loop wait eighteen seconds? The tests " (change-review-ui-test--selected overlay)))
      ;; Under the text of the comment, among the next comment's.
      (change-review-ui-test--drag overlay from (change-review-ui-test--where overlay "Because the loop"))
      (should (equal (substring (change-review-comment-body first) (string-search "only ever" (change-review-comment-body first)))
                     (change-review-ui-test--selected overlay)))
      ;; And past the end of the whole string: the same.
      (change-review-ui-test--drag overlay from (cons 20 1000))
      (should (equal (substring (change-review-comment-body first) (string-search "only ever" (change-review-comment-body first)))
                     (change-review-ui-test--selected overlay))))))

(ert-deftest change-review-ui-a-click-selects-nothing-and-chooses-the-thread ()
  "A click without a drag selects nothing: it puts point on the line the thread
is under, and makes the thread the one the commands act on."
  (change-review-ui-test--under-a-line
    (let ((where (change-review-ui-test--where overlay "only ever")))
      (change-review-ui-test--drag overlay where (change-review-ui-test--where overlay "Because the loop" 2))
      (should (change-review-ui-test--selected overlay))
      (goto-char (point-max))
      (setq change-review-ui--chosen-thread nil)
      (change-review-ui-test--drag overlay where where)
      (should-not (change-review-ui-test--selected overlay))
      (should-not (overlay-get overlay 'change-review-selection))
      (should (equal "" (change-review-ui-test--marked overlay)))
      (should (= (point) (overlay-start overlay)))
      (should (equal (change-review-thread-id thread) change-review-ui--chosen-thread)))))

(ert-deftest change-review-ui-a-double-click-selects-a-word-and-a-triple-click-a-line ()
  "A double click selects the word under the mouse, a triple click the line of
the text; a drag from there goes on from what they selected."
  (change-review-ui-test--under-a-line
    (let ((where (change-review-ui-test--where overlay "seventeen," 3)))
      (change-review-ui-test--drag overlay where where 2)
      (should (equal "seventeen" (change-review-ui-test--selected overlay)))
      (should (equal "seventeen" (change-review-ui-test--marked overlay)))
      ;; Punctuation is a word of its own; a space too.
      (change-review-ui-test--drag overlay (change-review-ui-test--where overlay "seventeen," 9)
                                   (change-review-ui-test--where overlay "seventeen," 9) 2)
      (should (equal "," (change-review-ui-test--selected overlay)))
      (change-review-ui-test--drag overlay where where 3)
      (should (equal (car (split-string (change-review-comment-body first) "\n"))
                     (change-review-ui-test--selected overlay)))
      (should (equal (concat "Why does the retry loop wait eighteen seconds? The tests only ever use"
                             "seventeen, and nothing in the docs says why that is.")
                     (change-review-ui-test--marked overlay)))
      ;; A drag after a double click goes on by the characters, from the word.
      (change-review-ui-test--drag overlay where (change-review-ui-test--where overlay "and nothing" 3) 2)
      (should (equal "seventeen, and" (change-review-ui-test--selected overlay))))))

(ert-deftest change-review-ui-a-selection-goes-with-the-next-command ()
  "The selection stays through the mouse's own command and scrolling, and goes
with any other command, its marks with it."
  (change-review-ui-test--under-a-line
    (let ((from (change-review-ui-test--where overlay "only ever")))
      (change-review-ui-test--drag overlay from (change-review-ui-test--where overlay "only ever" 9))
      (should (memq #'change-review-ui--drop-selection post-command-hook))
      (dolist (command '(change-review-ui-mouse-select scroll-up-command recenter-top-bottom))
        (let ((this-command command))
          (run-hooks 'post-command-hook))
        (should (equal "only ever" (change-review-ui-test--selected overlay)))
        (should (equal "only ever" (change-review-ui-test--marked overlay))))
      (let ((this-command 'next-line))
        (run-hooks 'post-command-hook))
      (should-not (change-review-ui-test--selected overlay))
      (should (equal "" (change-review-ui-test--marked overlay)))
      (should-not (memq #'change-review-ui--drop-selection post-command-hook)))))

(ert-deftest change-review-ui-one-selection-at-a-time ()
  "Selecting in one thread selects nothing in another of the buffer."
  (change-review-ui-test--drawing
    (pcase-let ((`(,set ,thread ,first ,_) (change-review-ui-test--wrapped-set)))
      (let ((other (change-review-comment set "Another thread, in the same buffer."
                                          :author (change-review-ui-test--author) :time change-review-ui-test--now)))
        (with-temp-buffer
          (save-window-excursion
            (set-window-buffer (selected-window) (current-buffer))
            (insert "one\ntwo\nthree\n")
            (setq change-review-ui--set set)
            (let ((one (progn (goto-char (point-min)) (end-of-line)
                              (change-review-ui-add-thread-overlay set thread (point) :view 'diff :width 80)))
                  (two (progn (goto-char (point-max))
                              (change-review-ui-add-thread-overlay
                               set (change-review-find-thread set (change-review-comment-thread other))
                               (point) :view 'diff :width 80))))
              (ignore first)
              (change-review-ui-test--drag one (change-review-ui-test--where one "only ever")
                                           (change-review-ui-test--where one "only ever" 4))
              (should (equal "only" (change-review-ui-test--selected one)))
              (change-review-ui-test--drag two (change-review-ui-test--where two "Another")
                                           (change-review-ui-test--where two "Another" 7))
              (should (equal "Another" (change-review-ui-test--selected two)))
              (should-not (change-review-ui-test--selected one))
              (should (equal "" (change-review-ui-test--marked one)))
              (should (equal '("c" "Another") (list (substring (car (overlay-get two 'change-review-selection)) 0 1)
                                                    (change-review-ui-test--selected two)))))))))))

(ert-deftest change-review-ui-quote-reply-quotes-what-the-mouse-selected ()
  "C-c > in a buffer that shows threads under its lines replies to the comment
with what was selected of it quoted; without a selection, to the last comment of
the thread under point's line, all of it quoted."
  (change-review-ui-test--under-a-line
    (let ((reading (change-review-ui-test--reading)))
      (let ((change-review-ui-read-function (car reading)))
        (change-review-ui-test--drag overlay (change-review-ui-test--where overlay "only ever")
                                     (change-review-ui-test--where overlay "and nothing" 11))
        (should (eq #'change-review-ui-quote-reply (key-binding (kbd "C-c >"))))
        (call-interactively #'change-review-ui-quote-reply)
        ;; It is used up.
        (should-not (change-review-ui-test--selected overlay))
        (should (equal "" (change-review-ui-test--marked overlay)))
        (goto-char (overlay-start overlay))
        (call-interactively #'change-review-ui-quote-reply)
        ;; Where no thread is, there is no comment to quote.
        (forward-line 1)
        (should-error (call-interactively #'change-review-ui-quote-reply) :type 'user-error))
      (should (equal (list (concat "> only ever use seventeen, and nothing\n\n")
                           (concat "> " (change-review-comment-body second) "\n\n"))
                     (mapcar #'cadr (symbol-value (cdr reading)))))
      (should (string-match-p "\\`Reply to Noah's comment 1/2" (car (nth 0 (symbol-value (cdr reading))))))
      (should (string-match-p "\\`Reply to Claude's comment 2/2" (car (nth 1 (symbol-value (cdr reading))))))
      (should (equal '(end end) (mapcar #'caddr (symbol-value (cdr reading))))))))

(ert-deftest change-review-ui-copies-what-the-mouse-selected ()
  "The key that copies a region copies the selection of a comment's text, which no
region holds, and ends it; without one it is what it was."
  (change-review-ui-test--under-a-line
    (should (eq #'change-review-ui-copy-selection (key-binding (kbd "M-w"))))
    (let ((kill-ring nil) (kill-ring-yank-pointer nil))
      (change-review-ui-test--drag overlay (change-review-ui-test--where overlay "only ever")
                                   (change-review-ui-test--where overlay "and nothing" 11))
      (call-interactively (key-binding (kbd "M-w")))
      (should (equal '("only ever use seventeen, and nothing") kill-ring))
      (should-not (change-review-ui-test--selected overlay))
      (should (equal "" (change-review-ui-test--marked overlay)))
      ;; Nothing selected, no region: the usual complaint, and nothing copied.
      (should-error (call-interactively (key-binding (kbd "M-w"))))
      (should (= 1 (length kill-ring)))
      ;; A region of the buffer's own text is copied as always.
      (goto-char (point-min))
      (set-mark (point))
      (end-of-line)
      (activate-mark)
      (call-interactively (key-binding (kbd "M-w")))
      (should (equal "one" (car kill-ring))))))

(ert-deftest change-review-ui-draws-a-selection-again-only-when-it-changes ()
  "The mouse moves a pixel at a time, which is a fraction of a character: the
text is drawn again only when what is selected is not what was."
  (change-review-ui-test--under-a-line
    (let ((from (change-review-ui-test--where overlay "only ever")))
      (change-review-ui-test--drag overlay from (change-review-ui-test--where overlay "only ever" 4))
      (let ((shown (overlay-get overlay 'after-string))
            (id (car (overlay-get overlay 'change-review-selection))))
        (change-review-ui--select overlay id 0 0)
        (should-not (eq shown (overlay-get overlay 'after-string)))
        (let ((shown (overlay-get overlay 'after-string)))
          (change-review-ui--select overlay id 0 0)
          (should (eq shown (overlay-get overlay 'after-string))))
        (change-review-ui--select overlay id 5 9)
        (let ((shown (overlay-get overlay 'after-string)))
          (change-review-ui--select overlay id 5 9)
          (should (eq shown (overlay-get overlay 'after-string)))
          (change-review-ui--select overlay id 5 10)
          (should-not (eq shown (overlay-get overlay 'after-string))))))))

(ert-deftest change-review-ui-a-selection-nothing-is-under-goes-to-the-default ()
  "A press that is over nothing of a comment's text is the default press's."
  (change-review-ui-test--under-a-line
    (let ((called nil))
      (cl-letf (((symbol-function 'mouse-drag-region) (lambda (event) (setq called event))))
        (change-review-ui-mouse-select
         (list 'down-mouse-1 (change-review-ui-test--posn overlay 500 5))))
      (should called)
      (should-not (overlay-get overlay 'change-review-selection)))))

(ert-deftest change-review-ui-the-diff-view-quotes-a-selection ()
  "In the diff view the threads are under their lines, and C-c > quotes what
the mouse selected, as it does in any buffer that draws them so."
  (change-review-ui-test--diff-view
    (let* ((reading (change-review-ui-test--reading))
           (overlay (cl-find-if (lambda (o) (and (overlay-get o 'change-review-thread)
                                                 (string-search "Why 'two?" (or (overlay-get o 'after-string) ""))))
                                (overlays-in (point-min) (point-max))))
           (window-buffer (window-buffer (selected-window))))
      (should overlay)
      (save-window-excursion
        (set-window-buffer (selected-window) (current-buffer))
        (change-review-ui-test--drag overlay (change-review-ui-test--where overlay "Why 'two?")
                                     (change-review-ui-test--where overlay "Why 'two?" 9))
        (let ((change-review-ui-read-function (car reading)))
          (should (eq #'change-review-ui-quote-reply (key-binding (kbd "C-c >"))))
          (call-interactively #'change-review-ui-quote-reply)))
      (ignore window-buffer)
      (should (equal '("> Why 'two?\n\n") (mapcar #'cadr (symbol-value (cdr reading)))))
      (should (string-match-p "\\`Reply to Noah's comment 1/3" (car (car (symbol-value (cdr reading)))))))))

;;;; The library compiles

(ert-deftest change-review-ui-compiles-without-a-warning ()
  "The library byte-compiles without a warning."
  (let* ((dir (make-temp-file "change-review-elc" t))
         (byte-compile-dest-file-function (lambda (file) (expand-file-name (concat (file-name-nondirectory file) "c") dir)))
         (byte-compile-error-on-warn t)
         (load-path (cons change-review-ui-test--directory load-path)))
    (unwind-protect
        (should (byte-compile-file (expand-file-name "change-review-ui.el" change-review-ui-test--directory)))
      (delete-directory dir t))))

(provide 'change-review-ui-test)
;;; change-review-ui-test.el ends here
