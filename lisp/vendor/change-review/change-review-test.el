;;; change-review-test.el --- Tests for the data of change-review  -*- lexical-binding: t; -*-

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

;; The tests of change-review.el: sets, versions, threads and comments,
;; the operations that change them, the data they turn into and the
;; file that keeps them.  They need nothing but the library: `make
;; test' runs them in an Emacs with only this directory on its load
;; path.

;;; Code:

(require 'ert)
(require 'bytecomp)
(require 'cl-lib)
(require 'json)
(require 'change-review)

(defconst change-review-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "The directory of the library and its tests.")

(defun change-review-test--alice ()
  "Return a user author, Alice."
  (change-review-user "Alice" "alice@example.org"))

(defun change-review-test--bot ()
  "Return an agent author with a session and a tool call."
  (change-review-agent "Claude" :session "sess-1" :tool-call "toolu_9"))

(defun change-review-test--file (path &optional status)
  "Return a changed file at PATH, with STATUS (M by default)."
  (change-review-make-file :path path :status (or status "M") :added 2 :deleted 1
                           :patch (format "diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n" path path path path)))

(defun change-review-test--set ()
  "Return a set with two versions and no thread."
  (let ((set (change-review-make-set :id "change-1" :title "Fix the flaky test")))
    (change-review-add-version
     set (change-review-make-version :id "aaa1111aaa1111aaa1111aaa1111aaa1111aaaa" :time 100
                                     :files (list (change-review-test--file "b.el")
                                                  (change-review-test--file "a.el"))))
    (change-review-add-version
     set (change-review-make-version :id "bbb2222bbb2222bbb2222bbb2222bbb2222bbbb" :time 200
                                     :label "second try"
                                     :files (list (change-review-test--file "b.el")
                                                  (change-review-test--file "a.el"))))
    set))

(defun change-review-test--says (set thread-id)
  "Return the bodies of the comments of the thread THREAD-ID of SET."
  (mapcar #'change-review-comment-body
          (change-review-thread-comments (change-review-find-thread set thread-id))))

;;;; Ids

(ert-deftest change-review-ids-are-new-and-stable ()
  "A new id starts with its prefix and is not made twice; a stable id is a
function of its parts."
  (let ((ids (cl-loop repeat 200 collect (change-review-new-id "c"))))
    (should (cl-every (lambda (id) (string-match-p "\\`c-[0-9a-f]\\{8\\}\\'" id)) ids))
    (should (= 200 (length (delete-dups (copy-sequence ids))))))
  (should (equal (change-review-stable-id "c" "task" 2 0) (change-review-stable-id "c" "task" 2 0)))
  (should-not (equal (change-review-stable-id "c" "task" 2 0) (change-review-stable-id "c" "task" 2 1)))
  (should (string-prefix-p "t-" (change-review-stable-id "t" "x"))))

(ert-deftest change-review-short-revision ()
  "A long hash is shortened to seven characters, anything else is kept."
  (should (equal "abcdef0" (change-review-short-revision "abcdef0123456789abcdef0123456789abcdef01")))
  (should (equal "<m1@example.org>" (change-review-short-revision "<m1@example.org>")))
  (should (equal "v2" (change-review-short-revision "v2")))
  (should (equal "" (change-review-short-revision nil))))

(cl-defstruct (change-review-test--looking-set (:include change-review-set)) looking)

(cl-defmethod change-review-default-revision ((set change-review-test--looking-set))
  (change-review-test--looking-set-looking set))

(ert-deftest change-review-a-kind-of-set-decides-what-a-comment-is-written-against ()
  "A comment, a reply and a change of status are against the newest version
unless the kind of set says the user looks at another."
  (let ((plain (change-review-make-set :id "p")))
    (change-review-add-version plain (change-review-make-version :id "aaaaaaa1"))
    (change-review-add-version plain (change-review-make-version :id "bbbbbbb2"))
    (let ((comment (change-review-comment plain "Plain")))
      (should (equal "bbbbbbb2" (change-review-comment-revision comment)))
      (should (equal "bbbbbbb2" (change-review-comment-revision (change-review-reply plain comment "Again"))))))
  (let ((set (make-change-review-test--looking-set :id "l" :looking "ccccccc3")))
    (change-review-add-version set (change-review-make-version :id "bbbbbbb2"))
    (let* ((comment (change-review-comment set "Looking"))
           (reply (change-review-reply set comment "Again"))
           (thread (change-review-find-thread set (change-review-comment-thread comment))))
      (should (equal "ccccccc3" (change-review-comment-revision comment)))
      (should (equal "ccccccc3" (change-review-comment-revision reply)))
      ;; A revision given wins; the status change names the revision too.
      (should (equal "ddddddd4" (change-review-comment-revision
                                 (change-review-comment set "Said" :revision "ddddddd4"))))
      (change-review-close set thread)
      (should (equal "ccccccc3" (plist-get (car (change-review-thread-history thread)) :revision))))))

(ert-deftest change-review-same-revision-p ()
  "A hash is the same commit written in full or abbreviated; anything else
is only the same as itself."
  (let ((full "abcdef0123456789abcdef0123456789abcdef01"))
    (should (change-review-same-revision-p full full))
    (should (change-review-same-revision-p full "abcdef0"))
    (should (change-review-same-revision-p "abcdef0123" full))
    (should-not (change-review-same-revision-p full "abcdef1"))
    ;; Too short to say, and not a hash.
    (should-not (change-review-same-revision-p full "abcde"))
    (should-not (change-review-same-revision-p full "v2"))
    (should (change-review-same-revision-p "<m1@example.org>" "<m1@example.org>"))
    (should-not (change-review-same-revision-p "<m1@example.org>" "<m1@"))
    (should-not (change-review-same-revision-p full nil))
    (should-not (change-review-same-revision-p nil nil))
    (should-not (change-review-same-revision-p "" ""))))

;;;; Authors and locations

(ert-deftest change-review-authors ()
  "A user and an agent are told apart and named; the same author is the same."
  (let ((alice (change-review-test--alice))
        (bot (change-review-test--bot)))
    (should (eq 'user (change-review-author-kind alice)))
    (should (eq 'agent (change-review-author-kind bot)))
    (should (equal "sess-1" (change-review-author-session bot)))
    (should (equal "toolu_9" (change-review-author-tool-call bot)))
    (should (equal "Alice" (change-review-author-label alice)))
    (should (equal "a@b.c" (change-review-author-label (change-review-user nil "a@b.c"))))
    (should (equal "agent" (change-review-author-label (change-review-make-author :kind 'agent))))
    (should (equal "unknown" (change-review-author-label nil)))
    (should (change-review-author-same-p alice (change-review-user "Alice B." "alice@example.org")))
    (should-not (change-review-author-same-p alice (change-review-user "Alice" "other@example.org")))
    (should (change-review-author-same-p (change-review-user "Bob") (change-review-user "Bob")))
    (should-not (change-review-author-same-p alice bot))
    ;; Agents of one session are one author, whatever they are called.
    (should (change-review-author-same-p bot (change-review-agent "Opus" :session "sess-1")))
    (should-not (change-review-author-same-p bot (change-review-agent "Claude" :session "sess-2")))
    (should-not (change-review-author-same-p nil alice))))

(ert-deftest change-review-author-data ()
  "An author turns into plain data and back."
  (let ((bot (change-review-agent "Claude" :session "s" :tool-call "t" :meta '(:model "x"))))
    (should (equal '(:kind "agent" :name "Claude" :session "s" :tool-call "t" :meta (:model "x"))
                   (change-review-author-to-data bot)))
    (let ((back (change-review-author-from-data (change-review-author-to-data bot))))
      (should (eq 'agent (change-review-author-kind back)))
      (should (equal "t" (change-review-author-tool-call back)))
      (should (equal '(:model "x") (change-review-author-meta back))))
    (should-not (change-review-author-to-data nil))
    (should-not (change-review-author-from-data nil))
    (should-not (change-review-author-from-data :null))))

(ert-deftest change-review-location-labels-and-data ()
  "A location reads as file:line, and keeps its excerpt through its data."
  (let ((one (change-review-make-location :file "a.el" :line 18))
        (range (change-review-make-location :file "a.el" :line 12 :end-line 18))
        (old (change-review-make-location :file "b.el" :side 'old :line 3))
        (file (change-review-make-location :file "c.el"))
        (excerpt (change-review-make-location :file "a.el" :line 2 :patch 1
                                              :excerpt "@@ -1,2 +1,2 @@\n a\n-b\n+c")))
    (should (equal "a.el:18" (change-review-location-label one)))
    (should (equal "a.el:12-18" (change-review-location-label range)))
    (should (equal "b.el:3" (change-review-location-label old)))
    (should (equal "b.el:3 (before)" (change-review-location-label old t)))
    (should (equal "c.el" (change-review-location-label file)))
    (should (equal "the change" (change-review-location-label nil)))
    (should (equal '(:file "a.el" :line 18) (change-review-location-to-data one)))
    (let ((back (change-review-location-from-data (change-review-location-to-data excerpt))))
      (should (equal "@@ -1,2 +1,2 @@\n a\n-b\n+c" (change-review-location-excerpt back)))
      (should (eql 1 (change-review-location-patch back)))
      (should (eq 'new (change-review-location-side back))))
    (should (eq 'old (change-review-location-side
                      (change-review-location-from-data (change-review-location-to-data old)))))
    (should-not (change-review-location-to-data nil))
    (should-not (change-review-location-from-data nil))))

;;;; Versions

(ert-deftest change-review-versions-are-numbered-and-found ()
  "Versions get the next number, are found by id, number and label, and
one id is one version."
  (let ((set (change-review-test--set)))
    (should (equal '(1 2) (mapcar #'change-review-version-number (change-review-set-versions set))))
    (let ((first (change-review-find-version set 1))
          (second (change-review-latest-version set)))
      (should (equal "v1" (change-review-version-name first)))
      (should (equal "second try" (change-review-version-name second)))
      (should (eq first (change-review-find-version set "aaa1111aaa1111aaa1111aaa1111aaa1111aaaa")))
      (should (eq second (change-review-find-version set "second try")))
      (should (eq second (change-review-find-version set second)))
      (should-not (change-review-find-version set 3))
      (should-not (change-review-find-version set "nope"))
      ;; Adding one again adds nothing and returns the one there is.
      (let ((again (change-review-add-version
                    set (change-review-make-version :id (change-review-version-id first)))))
        (should (eq first again))
        (should (= 2 (length (change-review-set-versions set)))))
      (should (equal "v1" (change-review-revision-name set (change-review-version-id first))))
      (should (equal "1234567" (change-review-revision-name set "1234567890abcdef1234567890abcdef12345678")))
      (should (equal "<m@x>" (change-review-revision-name set "<m@x>"))))))

(ert-deftest change-review-a-version-keeps-the-files-it-was-added-with ()
  "The files stay in memory with the version, though operations carry none."
  (let ((set (change-review-test--set)))
    (should (equal '("b.el" "a.el")
                   (mapcar #'change-review-file-path
                           (change-review-version-files (change-review-latest-version set)))))
    (should-not (plist-get (car (plist-get (change-review-set-to-data set) :versions)) :files))
    (should (plist-get (car (plist-get (change-review-set-to-data set t) :versions)) :files))))

;;;; Comments and threads

(ert-deftest change-review-a-comment-starts-a-thread ()
  "A comment with no thread starts an open one, recording what the data
structure is for: thread, author, location and revision."
  (let* ((set (change-review-test--set))
         (alice (change-review-test--alice))
         (where (change-review-make-location :file "a.el" :line 18 :excerpt "@@ -17 +17 @@\n+x"))
         (comment (change-review-comment set "Why eighteen?" :author alice :location where
                                         :time 1000)))
    (should (change-review-comment-p comment))
    (should (string-prefix-p "c-" (change-review-comment-id comment)))
    (should (= 1 (length (change-review-set-threads set))))
    (let ((thread (car (change-review-set-threads set))))
      (should (equal (change-review-thread-id thread) (change-review-comment-thread comment)))
      (should (eq 'open (change-review-thread-status thread)))
      (should (change-review-thread-open-p thread))
      (should (eq comment (change-review-thread-root thread)))
      ;; The set holds what the operation said, not the objects given.
      (should (equal (change-review-location-to-data where)
                     (change-review-location-to-data (change-review-thread-location thread))))
      (should (equal "a.el" (change-review-thread-file thread)))
      (should (eql 18 (change-review-thread-line thread)))
      (should (= 1000 (change-review-thread-time thread))))
    (should (change-review-author-same-p alice (change-review-comment-author comment)))
    ;; Against the newest version, as a revision, unless it says another.
    (should (equal "bbb2222bbb2222bbb2222bbb2222bbb2222bbbb" (change-review-comment-revision comment)))
    (should (change-review-comment-draft-p comment))
    (should-not (change-review-comment-reply-to comment))))

(ert-deftest change-review-replies-make-a-thread ()
  "A reply joins the thread of the comment it answers; the position of a
comment and its depth tell how it sits in the thread."
  (let* ((set (change-review-test--set))
         (alice (change-review-test--alice))
         (bot (change-review-test--bot))
         (root (change-review-comment set "Why?" :author alice :time 10
                                      :location (change-review-make-location :file "a.el" :line 3)))
         (answer (change-review-reply set root "Because." :author bot :time 20 :sent 20
                                      :revision "bbb2222bbb2222bbb2222bbb2222bbb2222bbbb"))
         (second (change-review-reply set root "Also this." :author bot :time 30))
         (third (change-review-reply set answer "Ok." :author alice :time 40))
         (thread (change-review-find-thread set (change-review-comment-thread root))))
    (should (= 1 (length (change-review-set-threads set))))
    (should (equal '("Why?" "Because." "Also this." "Ok.") (change-review-test--says set (change-review-thread-id thread))))
    (should (equal '(1 . 4) (change-review-comment-position thread root)))
    (should (equal '(3 . 4) (change-review-comment-position thread second)))
    (should (equal '(4 . 4) (change-review-comment-position thread third)))
    (should-not (change-review-comment-position thread (change-review-make-comment :id "x")))
    (should (eq root (change-review-comment-parent thread answer)))
    (should (eq answer (change-review-comment-parent thread third)))
    (should-not (change-review-comment-parent thread root))
    (should (equal '(0 1 1 2) (mapcar (lambda (c) (change-review-comment-depth thread c))
                                      (change-review-thread-comments thread))))
    (should (eq third (change-review-thread-last-comment thread)))
    (should (equal '("Alice" "Claude") (mapcar #'change-review-author-label
                                               (change-review-thread-participants thread))))
    (should (equal (list root second third) (change-review-thread-drafts thread)))
    ;; The comment of another thread, by id, with the thread its own.
    (should (equal (cons thread answer) (change-review-find-comment set (change-review-comment-id answer))))
    ;; An answer to a comment that is not there is an error.
    (should-error (change-review-reply set "c-nope" "Hm") :type 'change-review-error)
    ;; A reply says the thread of the comment it answers.
    (should-error (change-review-comment set "x" :reply-to root :thread "t-other")
                  :type 'change-review-error)))

(ert-deftest change-review-comments-keep-the-order-of-time ()
  "A comment that arrives late goes where its time puts it."
  (let* ((set (change-review-make-set))
         (root (change-review-comment set "one" :time 10 :author (change-review-test--alice)))
         (thread-id (change-review-comment-thread root)))
    (change-review-comment set "three" :thread thread-id :time 30 :author (change-review-test--alice))
    (change-review-comment set "two" :thread thread-id :time 20 :author (change-review-test--alice))
    (change-review-comment set "two again" :thread thread-id :time 20 :author (change-review-test--alice))
    (should (equal '("one" "two" "two again" "three") (change-review-test--says set thread-id)))))

(ert-deftest change-review-a-thread-is-found-by-a-prefix-of-its-id ()
  "A unique prefix of three characters or more names a thread."
  (let* ((set (change-review-make-set))
         (a (change-review-comment set "a"))
         (thread (change-review-find-thread set (change-review-comment-thread a)))
         (id (change-review-thread-id thread)))
    (should (eq thread (change-review-find-thread set id)))
    (should (eq thread (change-review-find-thread set (substring id 0 4))))
    (should-not (change-review-find-thread set "t-"))
    (should-not (change-review-find-thread set "x-123"))
    (should-not (change-review-find-thread set nil))))

;;;; Status

(ert-deftest change-review-threads-close-and-open ()
  "A thread is closed and opened again by whoever says so, and says who and
when in its history; closing a closed thread changes nothing."
  (let* ((set (change-review-test--set))
         (alice (change-review-test--alice))
         (bot (change-review-test--bot))
         (comment (change-review-comment set "Fix this" :author alice))
         (thread (change-review-find-thread set (change-review-comment-thread comment)))
         (calls nil))
    (add-hook 'change-review-changed-functions (lambda (_set op) (push (plist-get op :op) calls)))
    (unwind-protect
        (progn
          (should (change-review-close set thread :author bot :time 50))
          (should (eq 'closed (change-review-thread-status thread)))
          (should-not (change-review-thread-open-p thread))
          (should-not (change-review-close set thread :author bot :time 51))
          (should (change-review-reopen set (change-review-thread-id thread) :author alice :time 60))
          (should (eq 'open (change-review-thread-status thread)))
          (should (change-review-update-status set thread 'closed :author alice :time 70))
          (let ((history (change-review-thread-history thread)))
            (should (equal '(closed open closed) (mapcar (lambda (e) (plist-get e :status)) history)))
            (should (equal '(50 60 70) (mapcar (lambda (e) (plist-get e :time)) history)))
            (should (eq 'agent (change-review-author-kind (plist-get (car history) :author))))
            (should (equal "Alice" (change-review-author-label (plist-get (nth 1 history) :author))))
            (should (equal "bbb2222bbb2222bbb2222bbb2222bbb2222bbbb" (plist-get (car history) :revision))))
          ;; Three changes, none for the one that changed nothing.
          (should (= 3 (cl-count 'set-status calls))))
      (setq change-review-changed-functions nil))
    (should-error (change-review-update-status set thread 'resolved) :type 'change-review-error)
    (should-error (change-review-update-status set "t-none" 'closed) :type 'change-review-error)))

(ert-deftest change-review-a-status-change-heard-twice-is-made-once ()
  "A status operation carries an id; performing it again changes nothing,
even when the thread was moved on meanwhile."
  (let* ((set (change-review-make-set))
         (comment (change-review-comment set "x"))
         (thread (change-review-find-thread set (change-review-comment-thread comment)))
         (op (list :op 'set-status :thread (change-review-thread-id thread)
                   :status "closed" :id "s-1" :time 5)))
    (should (change-review-apply set op))
    (should (change-review-apply set (list :op 'set-status :thread (change-review-thread-id thread)
                                           :status "open" :id "s-2" :time 6)))
    (should-not (change-review-apply set op))
    (should (eq 'open (change-review-thread-status thread)))
    (should (= 2 (length (change-review-thread-history thread))))))

;;;; Reviewing a close

(defun change-review-test--closed-by-bot (set &optional time)
  "Return a thread of SET that the bot closed at TIME, started by the user."
  (let* ((comment (change-review-comment set "Fix this" :author (change-review-test--alice) :time 1))
         (thread (change-review-find-thread set (change-review-comment-thread comment))))
    (change-review-close set thread :author (change-review-test--bot) :time (or time 50))
    thread))

(ert-deftest change-review-a-close-by-someone-else-waits-for-review ()
  "A thread closed by someone other than the user is to review, until the
user marks that close reviewed; the user's own closes never wait."
  (let* ((set (change-review-test--set))
         (thread (change-review-test--closed-by-bot set)))
    (should (change-review-thread-unreviewed-p set thread))
    (should (eq 'closed (plist-get (change-review-thread-closing thread) :status)))
    (should (equal (list thread) (change-review-threads set 'unreviewed)))
    (should (= 1 (plist-get (change-review-thread-counts set) :unreviewed)))
    ;; Closed by the user: nothing of someone else's to look at.
    (let* ((mine (change-review-comment set "Mine" :time 2))
           (mine-thread (change-review-find-thread set (change-review-comment-thread mine))))
      (change-review-close set mine-thread :time 60)
      (should-not (change-review-thread-unreviewed-p set mine-thread))
      (should (= 1 (length (change-review-threads set 'unreviewed))))
      (should (= 2 (plist-get (change-review-thread-counts set) :closed))))
    ;; An open thread, and a closed one with no record of who closed it.
    (let ((open (change-review-find-thread set (change-review-comment-thread
                                                (change-review-comment set "Open" :time 3)))))
      (should-not (change-review-thread-closing open))
      (should-not (change-review-thread-unreviewed-p set open)))
    (let ((bare (change-review-thread-from-data
                 (list :id "t-bare" :status "closed"
                       :comments (list (list :id "c-bare" :body "x" :time 4))))))
      (should-not (change-review-thread-closing bare))
      (should-not (change-review-thread-unreviewed-p set bare)))))

(ert-deftest change-review-a-comment-in-a-closed-thread-leaves-it-closed ()
  "Adding a comment to a thread is no change of its status: a closed thread
stays closed, with nothing added to its history and still to review, whoever
the comment is by.  The user's own reply opens it again where it is read
\(`change-review-ui-reply-to-comment'), a change of status of its own."
  (let* ((set (change-review-test--set))
         (thread (change-review-test--closed-by-bot set))
         (root (change-review-thread-root thread))
         (calls nil))
    (add-hook 'change-review-changed-functions (lambda (_set op) (push (plist-get op :op) calls)))
    (unwind-protect
        (progn
          ;; The agent answers again in the thread it closed, and replies of
          ;; the user's, as a mail's are, are added by the library as they are.
          (change-review-reply set root "More on that." :author (change-review-test--bot) :time 60)
          (change-review-reply set root "Thanks, but why?" :author (change-review-test--alice) :time 61)
          (change-review-comment set "Also this." :thread thread
                                 :author (change-review-test--alice) :time 62)
          (should (equal '(add-comment add-comment add-comment) calls))
          (should (= 4 (length (change-review-thread-comments thread))))
          (should-not (change-review-thread-open-p thread))
          (should (equal '(closed) (mapcar (lambda (e) (plist-get e :status))
                                           (change-review-thread-history thread))))
          (should (change-review-thread-unreviewed-p set thread)))
      (setq change-review-changed-functions nil))))

(ert-deftest change-review-reviewing-a-close-is-kept-in-its-history ()
  "Marking a close reviewed puts the time on the change of status that closed
the thread, once; unmarking takes it off; an open thread has nothing to mark."
  (let* ((set (change-review-test--set))
         (thread (change-review-test--closed-by-bot set))
         (calls nil))
    (add-hook 'change-review-changed-functions (lambda (_set op) (push (plist-get op :op) calls)))
    (unwind-protect
        (progn
          (should (change-review-mark-reviewed set thread :time 90))
          (should (= 90 (plist-get (change-review-thread-closing thread) :reviewed)))
          (should-not (change-review-thread-unreviewed-p set thread))
          (should (= 0 (plist-get (change-review-thread-counts set) :unreviewed)))
          (should (equal '(closed) (mapcar (lambda (e) (plist-get e :status))
                                           (change-review-thread-history thread))))
          ;; Marked once: again, nothing happens and nothing is sent.
          (should-not (change-review-mark-reviewed set (change-review-thread-id thread) :time 91))
          (should (= 90 (plist-get (change-review-thread-closing thread) :reviewed)))
          (should (change-review-unmark-reviewed set thread))
          (should-not (plist-member (change-review-thread-closing thread) :reviewed))
          (should (change-review-thread-unreviewed-p set thread))
          (should-not (change-review-unmark-reviewed set thread))
          ;; Marking it again after that is as good as the first time.
          (should (change-review-mark-reviewed set thread :time 92))
          (should (= 92 (plist-get (change-review-thread-closing thread) :reviewed)))
          (should (equal '(mark-reviewed unmark-reviewed mark-reviewed) calls))
          ;; An open thread has no close to review.
          (change-review-reopen set thread :time 100)
          (should-not (change-review-mark-reviewed set thread))
          (should-not (change-review-unmark-reviewed set thread))
          (should (equal '(set-status mark-reviewed unmark-reviewed mark-reviewed) calls)))
      (setq change-review-changed-functions nil))
    (should-error (change-review-mark-reviewed set "t-none") :type 'change-review-error)
    (should-error (change-review-unmark-reviewed set "t-none") :type 'change-review-error)))

(ert-deftest change-review-a-close-reviewed-is-not-the-next-close ()
  "A thread the user reviewed, opened and closed again by someone else is to
review again, and a mark meant for the earlier close never reaches the later."
  (let* ((set (change-review-test--set))
         (bot (change-review-test--bot))
         (alice (change-review-test--alice))
         (find-entry (lambda (thread id)
                       (cl-find id (change-review-thread-history thread)
                                :key (lambda (e) (plist-get e :id)) :test #'equal)))
         (reviewed (change-review-test--closed-by-bot set 50))
         (first (plist-get (change-review-thread-closing reviewed) :id)))
    (change-review-mark-reviewed set reviewed :time 60)
    (change-review-reopen set reviewed :author alice :time 70)
    (should-not (change-review-thread-unreviewed-p set reviewed))
    (change-review-close set reviewed :author bot :time 80)
    (should (change-review-thread-unreviewed-p set reviewed))
    (should-not (equal first (plist-get (change-review-thread-closing reviewed) :id)))
    ;; The earlier close stays reviewed.
    (should (= 60 (plist-get (funcall find-entry reviewed first) :reviewed)))
    ;; Two closes, neither reviewed: a mark that names the earlier one, heard
    ;; late, marks that one and leaves the later waiting.
    (let* ((thread (change-review-test--closed-by-bot set 50))
           (id (change-review-thread-id thread))
           (early (plist-get (change-review-thread-closing thread) :id)))
      (change-review-reopen set thread :author alice :time 70)
      (change-review-close set thread :author bot :time 80)
      (let ((late (plist-get (change-review-thread-closing thread) :id)))
        (should (change-review-apply set (list :op 'mark-reviewed :thread id :status-id early :time 85)))
        (should (= 85 (plist-get (funcall find-entry thread early) :reviewed)))
        (should-not (plist-member (funcall find-entry thread late) :reviewed))
        (should (change-review-thread-unreviewed-p set thread))
        (should (change-review-apply set (list :op 'mark-reviewed :thread id :status-id late :time 86)))
        (should-not (change-review-thread-unreviewed-p set thread))))))

(ert-deftest change-review-review-operations-come-over-a-wire ()
  "The review operations are plain data: names as strings, the history's mark
as a number; they signal for a thread that is not there and leave an entry
that is not there or no close alone."
  (let* ((set (change-review-test--set))
         (thread (change-review-test--closed-by-bot set))
         (id (change-review-thread-id thread))
         (status-id (plist-get (change-review-thread-closing thread) :id)))
    (should (change-review-apply set (list :op "mark-reviewed" :thread id :status-id status-id :time 7)))
    (should-not (change-review-apply set (list :op "mark-reviewed" :thread id :status-id status-id :time 8)))
    (should (= 7 (plist-get (change-review-thread-closing thread) :reviewed)))
    (should (change-review-apply set (list :op "unmark-reviewed" :thread id :status-id status-id)))
    (should-not (change-review-apply set (list :op "unmark-reviewed" :thread id :status-id status-id)))
    ;; With no :status-id, the close that is there; without a :time, now.
    (should (change-review-apply set (list :op "mark-reviewed" :thread id)))
    (should (numberp (plist-get (change-review-thread-closing thread) :reviewed)))
    (should-not (change-review-apply set (list :op "mark-reviewed" :thread id :status-id "s-nothing")))
    (should-error (change-review-apply set (list :op "mark-reviewed" :thread "t-none"))
                  :type 'change-review-error)
    (should-error (change-review-apply set (list :op "unmark-reviewed" :thread "t-none"))
                  :type 'change-review-error)
    ;; A thread that was opened again has no close to mark.
    (change-review-reopen set thread :time 99)
    (should-not (change-review-apply set (list :op "mark-reviewed" :thread id)))))

(ert-deftest change-review-the-mark-of-a-review-survives-data-and-json ()
  "A close marked reviewed comes back marked from the plain data of its set,
also after JSON; one not marked comes back to review."
  (let* ((set (change-review-test--set))
         (marked (change-review-test--closed-by-bot set))
         (waiting (change-review-test--closed-by-bot set)))
    (change-review-mark-reviewed set marked :time 90)
    (let* ((data (change-review-set-to-data set))
           (back (change-review-set-from-data (change-review-test--through-json data)))
           (back-marked (change-review-find-thread back (change-review-thread-id marked)))
           (back-waiting (change-review-find-thread back (change-review-thread-id waiting))))
      (should (= 90 (plist-get (change-review-thread-closing back-marked) :reviewed)))
      (should (equal data (change-review-set-to-data back)))
      (should-not (plist-member (change-review-thread-closing back-waiting) :reviewed))
      (should (equal (list back-waiting) (change-review-threads back 'unreviewed))))))

;;;; Operations

(ert-deftest change-review-operations-are-idempotent ()
  "Performing an operation again changes nothing and calls no hook."
  (let* ((set (change-review-test--set))
         (calls 0)
         (hook (lambda (_set _op) (cl-incf calls)))
         (op (list :op 'add-comment :thread "t-1"
                   :comment (list :id "c-1" :thread "t-1" :body "hello" :time 5
                                  :author (list :kind "user" :name "Alice")))))
    (add-hook 'change-review-changed-functions hook)
    (unwind-protect
        (progn
          (should (change-review-apply set op))
          (should-not (change-review-apply set op))
          (should (= 1 calls))
          (should (= 1 (length (change-review-set-threads set))))
          (should (= 1 (length (change-review-thread-comments (car (change-review-set-threads set))))))
          ;; Silent: no hook.
          (should (change-review-apply set (list :op 'add-comment :thread "t-1"
                                                 :comment (list :id "c-2" :thread "t-1" :body "again" :time 6))
                                       t))
          (should (= 1 calls))
          ;; Operations as strings, the way they come over a wire.
          (should (change-review-apply set (list :op "add-comment" :thread "t-2"
                                                 :comment (list :id "c-3" :body "other" :time 7))))
          (should (equal '("t-1" "t-2") (mapcar #'change-review-thread-id (change-review-set-threads set))))
          (should (equal "t-2" (change-review-comment-thread
                                (cdr (change-review-find-comment set "c-3"))))))
      (remove-hook 'change-review-changed-functions hook))
    (should-error (change-review-apply set (list :op 'nonsense)) :type 'change-review-error)
    (should-error (change-review-apply set (list :op 'add-comment :comment '(:body "no id")))
                  :type 'change-review-error)
    (should-error (change-review-apply set (list :op 'add-version :version '(:label "no id")))
                  :type 'change-review-error)))

(ert-deftest change-review-drafts-are-sent-edited-and-deleted ()
  "A draft is marked sent once, can be edited, and can be deleted until it
is sent; a thread with no comment left goes."
  (let* ((set (change-review-test--set))
         (a (change-review-comment set "first" :time 1))
         (b (change-review-comment set "second" :time 2))
         (thread (change-review-find-thread set (change-review-comment-thread a))))
    (should (equal (list a b) (change-review-drafts set)))
    (should (equal 2 (plist-get (change-review-thread-counts set) :drafts)))
    (should (change-review-mark-sent set (list a) :time 99 :meta '(:round 3)))
    (should (eql 99 (change-review-comment-sent a)))
    (should (equal '(:round 3) (change-review-comment-meta a)))
    (should-not (change-review-comment-draft-p a))
    ;; Marked again: nothing, the time stays.
    (should-not (change-review-mark-sent set (list (change-review-comment-id a)) :time 100))
    (should (eql 99 (change-review-comment-sent a)))
    (should (equal (list b) (change-review-drafts set)))
    (should (change-review-edit set b "second, better" :time 150))
    (should (equal "second, better" (change-review-comment-body b)))
    (should (eql 150 (change-review-comment-edited b)))
    (should-not (change-review-edit set b "second, better"))
    (should-error (change-review-delete set a) :type 'change-review-error)
    (should (change-review-delete set b))
    (should-not (change-review-delete set b))
    (should (equal "first" (change-review-comment-body (car (change-review-thread-comments thread)))))
    ;; The only comment of a thread, a draft: the thread goes with it.
    (let ((lonely (change-review-comment set "lonely")))
      (should (= 2 (length (change-review-set-threads set))))
      (change-review-delete set lonely)
      (should (= 1 (length (change-review-set-threads set)))))))

(ert-deftest change-review-a-thread-is-a-draft-when-nothing-in-it-was-sent ()
  "A thread is a draft when it has comments and every one is: one sent
comment, however many drafts follow it, makes it a thread to keep."
  (let* ((set (change-review-test--set))
         (root (change-review-comment set "root" :time 1))
         (thread (change-review-find-thread set (change-review-comment-thread root))))
    (should (change-review-thread-draft-p thread))
    (change-review-reply set root "and more" :time 2)
    (should (change-review-thread-draft-p thread))
    ;; The first sent, the second not: it is not a draft thread any more.
    (change-review-mark-sent set (list root) :time 3)
    (should (= 1 (length (change-review-thread-drafts thread))))
    (should-not (change-review-thread-draft-p thread))
    ;; A thread with no comment at all is no draft either.
    (should-not (change-review-thread-draft-p (change-review-make-thread :id "t-empty")))))

(ert-deftest change-review-a-thread-of-drafts-is-deleted-whole ()
  "A thread that is nothing but drafts goes with all its comments, one
`delete-comment' operation each, the newest first so that the root, which
gives the thread its place, is the last to go.  The other threads stay."
  (let* ((set (change-review-test--set))
         (where (change-review-make-location :file "a.el" :line 7))
         (root (change-review-comment set "root" :time 1 :location where))
         (second (change-review-reply set root "second" :time 2))
         (third (change-review-reply set second "third" :time 3))
         (other (change-review-comment set "other thread" :time 4))
         (thread (change-review-find-thread set (change-review-comment-thread root)))
         (ops nil)
         (hook (lambda (_set op) (push op ops))))
    (add-hook 'change-review-changed-functions hook)
    (unwind-protect
        (progn
          (should (= 2 (length (change-review-set-threads set))))
          (should (change-review-delete-thread set thread))
          ;; One operation each, the newest first, the root last.
          (should (equal (mapcar (lambda (comment) (list 'delete-comment (change-review-comment-id comment)))
                                 (list third second root))
                         (mapcar (lambda (op) (list (plist-get op :op) (plist-get op :comment)))
                                 (reverse ops))))
          ;; Only the other thread is left, with its comment.
          (should (equal (list (change-review-comment-thread other))
                         (mapcar #'change-review-thread-id (change-review-set-threads set))))
          (should-not (change-review-find-comment set (change-review-comment-id root)))
          (should (change-review-find-comment set (change-review-comment-id other)))
          ;; Deleted again, by the thread or by its id: nothing happens, and no
          ;; operation is performed for it.
          (setq ops nil)
          (should-not (change-review-delete-thread set thread))
          (should-not (change-review-delete-thread set (change-review-comment-thread root)))
          (should-not ops))
      (remove-hook 'change-review-changed-functions hook))))

(ert-deftest change-review-a-thread-with-a-comment-that-was-sent-is-not-deleted ()
  "What was delivered was read: a thread with one sent comment is kept whole,
its drafts too, and nothing of it is performed before the error."
  (let* ((set (change-review-test--set))
         (root (change-review-comment set "sent" :time 1))
         (draft (change-review-reply set root "not sent" :time 2))
         (thread (change-review-find-thread set (change-review-comment-thread root)))
         (calls 0)
         (hook (lambda (_set _op) (cl-incf calls))))
    (change-review-mark-sent set (list root) :time 3)
    (add-hook 'change-review-changed-functions hook)
    (unwind-protect
        (progn
          (should-error (change-review-delete-thread set thread) :type 'change-review-error)
          (should-error (change-review-delete-thread set (change-review-thread-id thread))
                        :type 'change-review-error)
          (should (= 0 calls))
          (should (equal (list root draft) (change-review-thread-comments thread)))
          ;; The draft alone can go; then the thread is what was sent.
          (should (change-review-delete set draft))
          (should (equal (list root) (change-review-thread-comments thread)))
          (should-error (change-review-delete-thread set thread) :type 'change-review-error))
      (remove-hook 'change-review-changed-functions hook))))


;;;; Queries

(defun change-review-test--populate (set)
  "Put threads in SET: two on a.el, one on b.el, one on the change; return them."
  (let* ((alice (change-review-test--alice))
         (at (lambda (file line)
               (change-review-make-location :file file :line line)))
         (a30 (change-review-comment set "a30" :author alice :time 1 :location (funcall at "a.el" 30)))
         (b5 (change-review-comment set "b5" :author alice :time 2 :location (funcall at "b.el" 5)))
         (a10 (change-review-comment set "a10" :author alice :time 3 :location (funcall at "a.el" 10)))
         (all (change-review-comment set "all" :author alice :time 4))
         (gone (change-review-comment set "c.el" :author alice :time 5 :location (funcall at "c.el" 1))))
    (change-review-close set (change-review-comment-thread b5) :time 6)
    (list a30 b5 a10 all gone)))

(ert-deftest change-review-threads-by-status-and-file ()
  "Threads list by status; grouped by file the change comes first, then the
files in the order of the newest version, then any other, and a file's
threads in the order of their lines."
  (let ((set (change-review-test--set)))
    (change-review-test--populate set)
    (should (= 5 (length (change-review-threads set))))
    (should (= 5 (length (change-review-threads set 'all))))
    (should (equal '("a30" "a10" "all" "c.el")
                   (mapcar (lambda (th) (change-review-comment-body (change-review-thread-root th)))
                           (change-review-threads set 'open))))
    (should (equal '("b5") (mapcar (lambda (th) (change-review-comment-body (change-review-thread-root th)))
                                   (change-review-threads set 'closed))))
    (let ((groups (change-review-threads-by-file set)))
      (should (equal '(nil "b.el" "a.el" "c.el") (mapcar #'car groups)))
      (should (equal '("a10" "a30")
                     (mapcar (lambda (th) (change-review-comment-body (change-review-thread-root th)))
                             (cdr (assoc "a.el" groups))))))
    (should (equal '(nil "a.el" "c.el") (mapcar #'car (change-review-threads-by-file set 'open))))
    (should (equal '("b.el") (mapcar #'car (change-review-threads-by-file set 'closed))))
    (should (equal '(:open 4 :closed 1 :unreviewed 0 :drafts 5 :comments 5)
                   (change-review-thread-counts set)))))

(ert-deftest change-review-threads-on-one-line-come-in-the-order-they-were-started ()
  "A thread added late with an early time -- one imported from before --
is listed where its time puts it, not last; the lines still come first."
  (let* ((set (change-review-test--set))
         (alice (change-review-user "Alice"))
         (at (lambda (line) (change-review-make-location :file "a.el" :line line))))
    (dolist (spec '(("whole, 5" 5 nil) ("whole, 9" 9 nil) ("line 3, 8" 8 3) ("line 3, 2" 2 3) ("whole, 7" 7 nil)))
      (pcase-let ((`(,body ,time ,line) spec))
        (change-review-comment set body :author alice :time time
                               :location (and line (funcall at line)))))
    (let ((groups (change-review-threads-by-file set))
          (bodies (lambda (threads)
                    (mapcar (lambda (th) (change-review-comment-body (change-review-thread-root th))) threads))))
      (should (equal '("whole, 5" "whole, 7" "whole, 9") (funcall bodies (cdr (assoc nil groups)))))
      (should (equal '("line 3, 2" "line 3, 8") (funcall bodies (cdr (assoc "a.el" groups))))))))

(ert-deftest change-review-a-set-with-no-version-groups-by-name ()
  "Without a version to order the files by, they come in the order of their names."
  (let ((set (change-review-make-set)))
    (dolist (file '("z.el" "b.el"))
      (change-review-comment set "x" :location (change-review-make-location :file file :line 1)))
    (should (equal '("b.el" "z.el") (mapcar #'car (change-review-threads-by-file set))))))

;;;; Plain data and files

(defun change-review-test--jsonify (value)
  "Return VALUE, change-review data, as `json-serialize' takes it.
A list that is not a plist is an array there."
  (cond ((null value) :null)
        ((and (consp value) (keywordp (car value)))
         (cl-loop for (key val) on value by #'cddr
                  append (list key (change-review-test--jsonify val))))
        ((consp value) (apply #'vector (mapcar #'change-review-test--jsonify value)))
        (t value)))

(defun change-review-test--through-json (data)
  "Return DATA after JSON: encoded and parsed back, as a wire would."
  (let ((json (json-serialize (change-review-test--jsonify data) :null-object :null)))
    (json-parse-string json :object-type 'plist :array-type 'list
                       :null-object nil :false-object :false)))

(ert-deftest change-review-sets-turn-into-data-and-back ()
  "A set with versions, threads, comments, authors, locations and a history
comes back equal from its data, also after JSON."
  (let ((set (change-review-test--set)))
    (change-review-test--populate set)
    (let ((root (change-review-comment set "root" :author (change-review-test--bot) :time 7
                                       :meta '(:round 2 :source "mail")
                                       :location (change-review-make-location
                                                  :file "a.el" :line 4 :end-line 6 :side 'old
                                                  :excerpt "@@ -3,4 +3,3 @@\n a\n-b\n c"))))
      (change-review-reply set root "reply\nwith lines" :author (change-review-test--alice) :time 8 :sent 9)
      (change-review-close set (change-review-comment-thread root) :author (change-review-test--alice) :time 10))
    (setf (change-review-set-description set) "A description" (change-review-set-meta set) '(:kind "task"))
    (let ((data (change-review-set-to-data set t)))
      (should (equal data (change-review-set-to-data (change-review-set-from-data data) t)))
      (should (equal data (change-review-set-to-data
                           (change-review-set-from-data (change-review-test--through-json data)) t)))
      (let ((back (change-review-set-from-data (change-review-test--through-json data))))
        (should (equal "Fix the flaky test" (change-review-set-title back)))
        (should (equal '(:kind "task") (change-review-set-meta back)))
        (should (= 6 (length (change-review-set-threads back))))
        (should (equal '("b.el" "a.el")
                       (mapcar #'change-review-file-path
                               (change-review-version-files (change-review-latest-version back)))))
        (let* ((found (change-review-find-comment back (change-review-comment-id
                                                        (change-review-thread-root
                                                         (car (last (change-review-set-threads set))))))))
          (should (eq 'old (change-review-location-side (change-review-comment-location (cdr found)))))
          (should (eq 'closed (change-review-thread-status (car found))))
          (should (equal "sess-1" (change-review-author-session (change-review-comment-author (cdr found)))))
          (should (equal '(:round 2 :source "mail") (change-review-comment-meta (cdr found))))
          (should (equal 9 (change-review-comment-sent
                            (cadr (change-review-thread-comments (car found))))))
          (should (eq 'user (change-review-author-kind
                             (plist-get (car (change-review-thread-history (car found))) :author)))))))))

(cl-defstruct (change-review-test--kind (:include change-review-set)))

(ert-deftest change-review-data-replaces-the-contents-of-a-set ()
  "Data read into a set replaces what it holds and keeps the files its
versions had, its file and its kind."
  (let* ((set (make-change-review-test--kind :id "x" :file "/tmp/never"))
         (version (change-review-make-version :id "r1" :files (list (change-review-test--file "a.el")))))
    (change-review-add-version set version)
    (let* ((other (change-review-make-set :id "x" :title "New title"))
           (_ (change-review-add-version other (change-review-make-version :id "r1" :label "one")))
           (_ (change-review-add-version other (change-review-make-version :id "r2")))
           (_ (change-review-comment other "hello")))
      (should (eq set (change-review-set-from-data (change-review-set-to-data other) set)))
      (should (change-review-test--kind-p set))
      (should (equal "/tmp/never" (change-review-set-file set)))
      (should (equal "New title" (change-review-set-title set)))
      (should (equal '("one" "v2") (mapcar #'change-review-version-name (change-review-set-versions set))))
      (should (equal '("a.el") (mapcar #'change-review-file-path
                                       (change-review-version-files (change-review-find-version set "r1")))))
      (should (= 1 (length (change-review-set-threads set)))))))

(ert-deftest change-review-a-set-is-kept-in-a-file ()
  "A set written to a file is read back whole, text with newlines and
characters outside ASCII included; a set with a file keeps itself there."
  (let* ((dir (make-temp-file "change-review-test" t))
         (file (expand-file-name "sub/change.eld" dir))
         (set (change-review-test--set)))
    (unwind-protect
        (progn
          (setf (change-review-set-file set) file)
          (change-review-comment set "Naïve — “quotes”\nsecond line\n\"q\" \\ back"
                                 :author (change-review-test--alice) :time 3
                                 :location (change-review-make-location :file "é.el" :line 2))
          ;; The dispatch of a plain set saved it.
          (should (file-exists-p file))
          (should (equal '() (directory-files (file-name-directory file) nil "\\`\\.change-review-")))
          (let ((back (change-review-read-file file)))
            (should (equal file (change-review-set-file back)))
            (should (equal (change-review-set-to-data set t) (change-review-set-to-data back t)))
            (should (equal "Naïve — “quotes”\nsecond line\n\"q\" \\ back"
                           (change-review-comment-body
                            (change-review-thread-root (car (change-review-set-threads back)))))))
          (write-region "(not a review)" nil file)
          (should-error (change-review-read-file file) :type 'change-review-error))
      (delete-directory dir t))))

;;;; What a kind of set decides

(cl-defstruct (change-review-test--remote (:include change-review-set)) sent)

(cl-defmethod change-review-dispatch ((set change-review-test--remote) op)
  (push op (change-review-test--remote-sent set))
  (change-review-apply set op))

(cl-defmethod change-review-current-author ((_set change-review-test--remote))
  (change-review-user "Remote Reviewer"))

(ert-deftest change-review-a-kind-of-set-decides-where-operations-go ()
  "A struct that includes a set can send the operations elsewhere and name
its own user; a plain set does neither."
  (let ((set (make-change-review-test--remote :id "r")))
    (let ((comment (change-review-comment set "hi")))
      (should (equal "Remote Reviewer" (change-review-author-label (change-review-comment-author comment))))
      (change-review-close set (change-review-comment-thread comment)))
    (should (equal '(set-status add-comment) (mapcar (lambda (op) (plist-get op :op))
                                                     (change-review-test--remote-sent set))))
    (should (eq 'user (change-review-author-kind (change-review-current-author (change-review-make-set))))))
  ;; Who is the user: the current author, unless the kind of set knows better.
  (let ((set (change-review-make-set)))
    (should (change-review-own-author-p set (change-review-current-author set)))
    (should-not (change-review-own-author-p set (change-review-test--bot)))
    (should-not (change-review-own-author-p set nil)))
  (should-error (change-review-follow-author (change-review-make-set) (change-review-test--bot))
                :type 'user-error)
  (should-not (change-review-file-text (change-review-make-set) nil "a.el" 'new)))

(ert-deftest change-review-deleting-a-thread-sends-the-set-that-keeps-it-one-operation-each ()
  "A set that keeps its threads elsewhere is sent the `delete-comment' of each
comment of a thread of drafts, as it is for any deletion: it has nothing new
to know, and no operation is lost on the way."
  (let* ((set (make-change-review-test--remote :id "r"))
         (root (change-review-comment set "root" :time 1))
         (reply (change-review-reply set root "reply" :time 2))
         (thread (change-review-find-thread set (change-review-comment-thread root))))
    (setf (change-review-test--remote-sent set) nil)
    (should (change-review-delete-thread set thread))
    (should (equal (list (list 'delete-comment (change-review-comment-id reply))
                         (list 'delete-comment (change-review-comment-id root)))
                   (mapcar (lambda (op) (list (plist-get op :op) (plist-get op :comment)))
                           (reverse (change-review-test--remote-sent set)))))
    (should-not (change-review-set-threads set))))

;;;; The library compiles

(ert-deftest change-review-compiles-without-a-warning ()
  "The library byte-compiles without a warning."
  (let* ((dir (make-temp-file "change-review-elc" t))
         (byte-compile-dest-file-function (lambda (_) (expand-file-name "change-review.elc" dir)))
         (byte-compile-error-on-warn t)
         (load-path (cons change-review-test--directory load-path)))
    (unwind-protect
        (should (byte-compile-file (expand-file-name "change-review.el" change-review-test--directory)))
      (delete-directory dir t))))

(provide 'change-review-test)
;;; change-review-test.el ends here
