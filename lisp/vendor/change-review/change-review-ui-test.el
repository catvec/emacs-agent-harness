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
  "A closed thread says closed, by whom and when, and can be one line.
All of that takes 92 columns; in less it says less (see the tests of fitting)."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (nth 1 (change-review-ui-test--populate set)))
           (lines (change-review-ui-test--lines (change-review-ui-thread-string set thread :width 100))))
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
  (change-review-ui-test--drawing
    (cl-letf (((symbol-function 'float-time) (lambda (&rest _) change-review-ui-test--now))
              (change-review-ui-relative-times t))
      (let* ((set (change-review-ui-test--set))
             (thread (nth 1 (change-review-ui-test--populate set)))
             (header (lambda (width)
                       (car (change-review-ui-test--lines
                             (change-review-ui-thread-string set thread :view 'diff :width width))))))
        ;; The thread was closed by an agent, so it says so as long as it can.
        (should (string-suffix-p "· closed by Claude, 2026-10-14 17:16 (30m ago)   [Reply] [Reopen]"
                                 (funcall header 120)))
        (should (string-suffix-p "· closed by Claude, 30m ago   [Reply] [Reopen]" (funcall header 70)))
        (should (string-suffix-p "· 1 comment · closed by Claude   [Reply] [Reopen]" (funcall header 60)))
        (should (string-suffix-p "· 1 comment · closed   [Reply] [Reopen]" (funcall header 50)))
        (should (string-match-p "\\`✓ [^ ]+ · closed   \\[Reply\\] \\[Reopen\\]\\'" (funcall header 45)))
        (should (string-match-p "\\`✓ [^ ]+ · closed\\'" (funcall header 25)))))))

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
      (should (eq 'collapsed (change-review-ui-thread-fold set (nth 1 threads))))
      (let ((change-review-ui-collapse-closed-in-diff nil))
        (should (eq 'expanded (change-review-ui-thread-fold set (nth 1 threads))))))))

(ert-deftest change-review-ui-remembers-how-a-thread-was-folded ()
  "What was chosen stays, for the set, while the thread keeps its status;
a thread whose status changed is drawn as one of that status again."
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
      (should-error (change-review-ui-set-fold set open 'folded) :type 'change-review-error))))

(ert-deftest change-review-ui-goes-through-the-folds-in-turn ()
  "One line, then the conversation, then all of it -- where something was
left out of the conversation -- then one line; several threads follow the first."
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
        (should-not (change-review-ui-cycle-folds set nil))))))

(ert-deftest change-review-ui-draws-a-folded-thread-with-a-triangle-that-opens-it ()
  "A thread that can be folded starts with a triangle, which is a button:
pointing right on a thread of one line, down on one that is open to its
conversation.  Clicking it, or the words of a thread of one line, folds it."
  (change-review-ui-test--drawing
    (let* ((set (change-review-ui-test--set))
           (thread (nth 1 (change-review-ui-test--populate set)))
           (line (lambda (fold &rest keys)
                   (apply #'change-review-ui-thread-string set thread :view 'diff :width 90 :indent "  "
                          :fold fold keys))))
      ;; One line: the triangle takes the place of the indent.
      (let ((one (funcall line 'collapsed)))
        (should (= 1 (length (change-review-ui-test--lines one))))
        (should (string-match-p "\\`▸ ✓ [^ ]+ · 1 comment · closed by Claude, 2026-10-14 17:16   \\[Reply\\] \\[Reopen\\]  “Fine\\.”\n\\'"
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
        (should-not (change-review-ui-test--button plain "“Fine.”"))))))

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

(ert-deftest change-review-ui-lines-mode-folds-the-thread-under-the-line ()
  "TAB on a line with a thread folds it: one line, its conversation; on a
line with none it is what it was without the library's keys."
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
          (should (eq 'global-tab other)))))))

(ert-deftest change-review-ui-lines-mode-folds-all-the-threads-under-a-line-together ()
  "Two threads under one line are folded as the first, the chosen one, goes."
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
        (should (eq 'expanded (change-review-ui-thread-fold set open)))))))

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

(ert-deftest change-review-ui-diff-view-folds-threads ()
  "A closed thread is one line in the diff view, its triangle pointing right;
TAB on its line opens it to its conversation and again folds it; with no
thread on the line TAB is what it is without the library's keys."
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
      (should (string-match-p "\n  ▸ ✓ [^ ]+ · 1 comment · closed .*“Fine\\.”\\'" (funcall drawn "^\\+(setq b2 'two)")))
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
          (should ran))))))

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
