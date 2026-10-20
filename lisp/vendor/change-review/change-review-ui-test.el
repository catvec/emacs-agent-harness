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
    (mapcar (lambda (comment)
              (change-review-find-thread set (change-review-comment-thread comment)))
            (list a1 b1 c1 d1))))

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
                   (change-review-ui-thread-string set thread :view 'threads :width 80))))
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
      (should (equal "┃ 3/3  Noah (you) · 2026-10-14 17:45 · second · draft · ↳ re 1/3  ▸ where"
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
  "A closed thread says closed, by whom and when, and can be one line."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (nth 1 (change-review-ui-test--populate set)))
           (lines (change-review-ui-test--lines (change-review-ui-thread-string set thread :width 90))))
      (should (string-match-p "\\`✓ [^ ]+ · line 2 · 1 comment · closed by Claude, 2026-10-14 17:16 +\\[Reply\\] \\[Reopen\\] \\[Diff\\]\\'"
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
      (should (member "┃      made at a.el:3 · revision second (2222222)" lines))
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
      (should (string-match-p "\\`✓ [^ ]+ · line 2 · Noah: “Fine\\.”\\'"
                              (car (change-review-ui-test--lines closed))))
      (should (equal (change-review-thread-id (car threads))
                     (get-text-property 0 'change-review-thread one)))
      ;; Too narrow for the words: they are cut.
      (should (string-match-p "…”" (change-review-ui-thread-line set (car threads) :width 40)))
      ;; Where it is now.
      (should (string-match-p "line 9 (was 3)"
                              (change-review-ui-thread-line
                               set (car threads) :width 100
                               :placement '(:side new :line 9 :was 3 :status moved)))))))

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
      (should (string-match-p "^Threads  +open 3 +closed 1 +\\[all 4\\]" text))
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
  "f changes which threads show: open, closed, all; the buttons say how many."
  (change-review-ui-test--threads-view
    (change-review-ui-set-filter 'open)
    (let ((text (change-review-ui-test--text)))
      (should (string-match-p "^Threads  \\[open 3\\]" text))
      (should (string-match-p "What about a4\\?" text))
      (should-not (string-match-p "▾ b\\.el" text))
      (should-not (string-match-p "Fine\\." text)))
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
    (change-review-ui-flush)
    (should (string-match-p "closed by Noah (you)" (change-review-ui-test--text)))
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
        (call-interactively #'change-review-ui-reply)
        (should (equal "From a line" (change-review-comment-body (change-review-thread-last-comment thread))))
        (call-interactively #'change-review-ui-toggle-status)
        (should-not (change-review-thread-open-p thread))
        (forward-line 1)
        (should-error (call-interactively #'change-review-ui-reply) :type 'user-error)))))

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
    (should (string-match-p "3 open, 1 closed, 2 not sent"
                            (apply #'concat (cl-remove-if-not #'stringp header-line-format))))))

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
      ;; RET opens its comments' details, and the thread is no longer one line.
      (change-review-ui-test--goto "^ (setq a4 4)")
      (end-of-line)
      (call-interactively #'change-review-ui-return)
      (change-review-ui-flush)
      (should (string-match-p "made at a\\.el:4"
                              (overlay-get (cl-find-if (lambda (o) (overlay-get o 'after-string))
                                                       (overlays-in (line-beginning-position) (1+ (line-end-position))))
                                           'after-string))))))

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
