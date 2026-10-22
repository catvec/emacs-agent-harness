;;; change-review.el --- Threaded review of change sets and patch sets  -*- lexical-binding: t; -*-

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

;; The data of a code review, and nothing that draws it: a change set
;; with its versions, and the threads of comments on them.
;;
;; A CHANGE SET (`change-review-set') is the thing under review: a
;; branch's work, a series of emailed patches, any patch set.  It has
;; VERSIONS (`change-review-version'), each one proposal of the change:
;; the first hand-in of an agent's branch, the second one after the
;; review, `[PATCH v2]' of a series.  A version is named by its source
;; REVISION, a string: the commit it ends at, the message id of its
;; first mail, whatever names that version of the code among the
;; others.  It lists the FILES it changes (`change-review-file'), each
;; with its part of the unified diff.
;;
;; A THREAD (`change-review-thread') is a conversation, open or closed:
;; "closed" is the good ending, the point made, the change made.  It
;; holds COMMENTS (`change-review-comment'), the first being the root.
;; Each comment records
;;
;;   thread      the thread it belongs to,
;;   id          its own id, and `reply-to' the comment it answers,
;;   author      who wrote it (`change-review-author'): a user, by name
;;               and email, or an agent, by name, session and the tool
;;               call that produced the comment, which is a link to the
;;               point in the conversation it came from,
;;   body, time  what it says and when,
;;   location    optional: the file, the line and the lines of the diff
;;               around it (`change-review-location'); a comment with
;;               none is on the change as a whole,
;;   revision    the source revision it was written against,
;;   sent        nil while it is a draft, else when it was delivered.
;;
;; The status of a thread changes by an operation that records who made
;; it and when (`change-review-thread-history').
;;
;; Everything that changes a set is an OPERATION, a plist of plain
;; data: `add-comment', `set-status', `add-version', `mark-sent',
;; `edit-comment', `delete-comment'.  `change-review-apply' performs
;; one, and performing the same operation twice changes nothing the
;; second time (the ids see to that), so a set can be kept by writing
;; down operations, copied to another Emacs by sending them, and made
;; to agree by sending them again.  The commands call
;; `change-review-comment', `change-review-reply',
;; `change-review-update-status' and the like, which build the
;; operation and hand it to `change-review-dispatch'.  By default that
;; applies it to the set in this Emacs and saves the set to its file;
;; a set of a kind of your own (a struct that includes
;; `change-review-set') decides otherwise with a method of its own: the
;; set it belongs to lives somewhere else, say.  The same holds for who
;; the user is (`change-review-current-author'), what following an
;; agent to its conversation does (`change-review-follow-author'), how
;; a location is shown (`change-review-visit'), where the drafts go
;; (`change-review-send'), the text of a file the diff does not hold
;; (`change-review-file-text') and the revision a comment is written
;; against (`change-review-default-revision').
;;
;; The data is plain: `change-review-set-to-data' turns a set into
;; lists, strings and numbers, `change-review-set-from-data' back, and
;; `change-review-write-file' and `change-review-read-file' keep a set
;; in a file.  Other libraries of this package read patches
;; (change-review-diff.el), emailed patches and replies
;; (change-review-mail.el), and draw the review (change-review-ui.el).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(define-error 'change-review-error "Change review error")

;; Emacs 31 has no `read-eval' to bind; older ones read "#." with it.
(defvar read-eval)

(defgroup change-review nil
  "Threaded review of change sets and patch sets."
  :group 'tools :prefix "change-review-")

(defvar change-review-changed-functions nil
  "Functions called with (SET OP) after operation OP changed SET.
OP is the plist `change-review-apply' performed.  An operation that
changed nothing, performed again, does not call them.")

;;;; Ids

(defvar change-review--id-counter 0
  "Counts the ids made in this Emacs, so two made at once differ.")

(defun change-review-new-id (prefix)
  "Return a new id, PREFIX then \"-\" then eight hexadecimal digits.
PREFIX is \"t\" for a thread, \"c\" for a comment, and so on.  The
digits come from the time, the process, a counter and a random number;
an id is unique in practice, not by construction, so code that makes
many checks the set (`change-review-new-thread-id')."
  (format "%s-%s" prefix
          (substring (secure-hash
                      'sha1 (format "%s/%s/%s/%s/%s" (float-time) (emacs-pid) (random)
                                    (cl-incf change-review--id-counter) (random)))
                     0 8)))

(defun change-review-stable-id (prefix &rest parts)
  "Return an id for PREFIX and PARTS: the same for the same PARTS.
It is how data imported again (a mail, a round of feedback) gets the
ids it got before, so importing it twice adds nothing."
  (format "%s-%s" prefix
          (substring (secure-hash 'sha1 (mapconcat (lambda (p) (format "%s" p)) parts "\0"))
                     0 8)))

(defun change-review-short-revision (revision)
  "Return REVISION shortened to seven characters when it is a long hash.
Any other revision, a message id or a version name, is returned as is;
nil gives \"\"."
  (cond ((not (stringp revision)) "")
        ((string-match-p "\\`[0-9a-f]\\{12,64\\}\\'" revision) (substring revision 0 7))
        (t revision)))

(defun change-review-same-revision-p (a b)
  "Return non-nil when revisions A and B name the same commit.
Both are strings.  A hash may be written in full or abbreviated (seven
characters or more, as git and `change-review-short-revision' do), so
two that start the same way are one; any other revision, a message id
or a version name, is the same as itself only."
  (and (stringp a) (stringp b)
       (not (string-empty-p a)) (not (string-empty-p b))
       (or (equal a b)
           (let ((short (if (<= (length a) (length b)) a b))
                 (long (if (<= (length a) (length b)) b a)))
             (and (string-match-p "\\`[0-9a-f]\\{7,64\\}\\'" short)
                  (string-match-p "\\`[0-9a-f]+\\'" long)
                  (string-prefix-p short long))))))

;;;; Plain data helpers

(defun change-review--plist (&rest pairs)
  "Return the plist of PAIRS, a key and a value each, without nil values."
  (let (out)
    (while pairs
      (let ((key (pop pairs)) (value (pop pairs)))
        (when value (push key out) (push value out))))
    (nreverse out)))

(defun change-review--list (value)
  "Return VALUE, a list, a vector or nil, as a list.
Data that went through JSON has vectors and null where the data of a
set has lists and nil."
  (cond ((vectorp value) (append value nil))
        ((memq value '(:null :false)) nil)
        ((listp value) value)))

(defun change-review--blank (value)
  "Return VALUE, or nil when it is nil, a JSON null or false."
  (unless (memq value '(nil :null :false)) value))

(defun change-review--symbol (value)
  "Return VALUE, a symbol or its name, as a symbol; nil for none."
  (setq value (change-review--blank value))
  (cond ((stringp value) (and (not (string-empty-p value)) (intern value)))
        ((symbolp value) value)))

(defun change-review--string (value)
  "Return VALUE when it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun change-review--number (value)
  "Return VALUE when it is a number, else nil."
  (and (numberp value) value))

(defun change-review--meta (value)
  "Return VALUE, a metadata plist, or nil; null and false are none."
  (and (consp (change-review--blank value)) value))

;;;; Authors

(cl-defstruct (change-review-author
               (:constructor change-review-make-author
                             (&key (kind 'user) name email session tool-call meta))
               (:copier nil))
  "Who wrote a comment or made a change.
KIND is a symbol: `user' for a person, `agent' for an AI agent, `other'
for any other source.  NAME is how the author is called, EMAIL their
address.  For an agent, SESSION is the id of the conversation it was in
and TOOL-CALL the id of the call in it that made the comment or the
change, which is how to get back to the point of the conversation it
came from.  META is a plist for anything else."
  kind name email session tool-call meta)

(defun change-review-user (name &optional email)
  "Return a user author called NAME, with EMAIL if given."
  (change-review-make-author :kind 'user :name name :email email))

(cl-defun change-review-agent (name &key session tool-call meta)
  "Return an agent author called NAME.
SESSION is the conversation it was in and TOOL-CALL the call of that
conversation that made the comment; META is a plist."
  (change-review-make-author :kind 'agent :name name :session session
                             :tool-call tool-call :meta meta))

(defun change-review-author-label (author)
  "Return how AUTHOR is named: the name, else the address, else the kind."
  (cond ((null author) "unknown")
        ((change-review--string (change-review-author-name author)))
        ((change-review--string (change-review-author-email author)))
        (t (symbol-name (or (change-review-author-kind author) 'unknown)))))

(defun change-review-author-same-p (a b)
  "Return non-nil when authors A and B are the same author.
Two authors are the same when they are of one kind and, if both have a
session, share it; else if both have an address, share it; else share
the name."
  (and a b
       (eq (change-review-author-kind a) (change-review-author-kind b))
       (let ((session-a (change-review-author-session a))
             (session-b (change-review-author-session b))
             (email-a (change-review-author-email a))
             (email-b (change-review-author-email b)))
         (cond ((and session-a session-b) (equal session-a session-b))
               ((and email-a email-b) (equal email-a email-b))
               (t (equal (change-review-author-name a) (change-review-author-name b)))))))

(defun change-review-author-to-data (author)
  "Return AUTHOR as plain data, or nil for no author."
  (when author
    (change-review--plist :kind (and (change-review-author-kind author)
                                     (symbol-name (change-review-author-kind author)))
                          :name (change-review-author-name author)
                          :email (change-review-author-email author)
                          :session (change-review-author-session author)
                          :tool-call (change-review-author-tool-call author)
                          :meta (change-review-author-meta author))))

(defun change-review-author-from-data (data)
  "Return the author DATA, from `change-review-author-to-data', holds."
  (when (consp (change-review--blank data))
    (change-review-make-author
     :kind (or (change-review--symbol (plist-get data :kind)) 'user)
     :name (change-review--string (plist-get data :name))
     :email (change-review--string (plist-get data :email))
     :session (change-review--string (plist-get data :session))
     :tool-call (change-review--string (plist-get data :tool-call))
     :meta (change-review--meta (plist-get data :meta)))))

;;;; Locations

(cl-defstruct (change-review-location
               (:constructor change-review-make-location
                             (&key file old-file (side 'new) line end-line excerpt patch))
               (:copier nil))
  "Where in a change a comment was made.
FILE is the path of the file in the version, OLD-FILE the path it had
before when the change renamed it.  SIDE is `new' for a line of the
file after the change, `old' for one of the file before it, and LINE
the line's number there, from 1, nil for a comment on the file as a
whole.  END-LINE is the last line of a range, nil for one line.
EXCERPT is the part of the file's diff around the line, as unified diff
lines: a hunk header, then the lines of the hunk, each starting with
\" \", \"+\" or \"-\"; the line commented on, or the last of the range, is
the last line of it.  It is what the comment was about when the
version is no longer at hand.  PATCH names the patch of a series the
file is in, nil when the version is not a series."
  file old-file side line end-line excerpt patch)

(defun change-review-location-label (location &optional with-side)
  "Return LOCATION as \"file:line\", \"file:from-to\" or \"file\".
With WITH-SIDE a line of the file before the change says so, as
\"file:3 (before)\".  Nil for no location: \"the change\"."
  (if (null location)
      "the change"
    (let ((file (or (change-review-location-file location) "the change"))
          (line (change-review-location-line location))
          (end (change-review-location-end-line location)))
      (concat file
              (cond ((null line) "")
                    ((and end (/= end line)) (format ":%d-%d" line end))
                    (t (format ":%d" line)))
              (if (and with-side line (eq (change-review-location-side location) 'old))
                  " (before)"
                "")))))

(defun change-review-location-to-data (location)
  "Return LOCATION as plain data, or nil for none."
  (when location
    (change-review--plist
     :file (change-review-location-file location)
     :old-file (change-review-location-old-file location)
     :side (let ((side (change-review-location-side location)))
             (and side (not (eq side 'new)) (symbol-name side)))
     :line (change-review-location-line location)
     :end-line (change-review-location-end-line location)
     :excerpt (change-review-location-excerpt location)
     :patch (change-review-location-patch location))))

(defun change-review-location-from-data (data)
  "Return the location DATA, from `change-review-location-to-data', holds."
  (when (consp (change-review--blank data))
    (change-review-make-location
     :file (change-review--string (plist-get data :file))
     :old-file (change-review--string (plist-get data :old-file))
     :side (or (change-review--symbol (plist-get data :side)) 'new)
     :line (change-review--number (plist-get data :line))
     :end-line (change-review--number (plist-get data :end-line))
     :excerpt (change-review--string (plist-get data :excerpt))
     :patch (let ((patch (change-review--blank (plist-get data :patch))))
              (and patch (if (numberp patch) patch (change-review--string patch)))))))

;;;; Comments, threads, files, versions, sets

(cl-defstruct (change-review-comment
               (:constructor change-review-make-comment
                             (&key id thread reply-to author body time location revision
                                   sent edited meta))
               (:copier nil))
  "One message of a thread.
ID names it and THREAD (an id) the thread it is in; REPLY-TO is the id
of the comment it answers, nil for the first of a thread.  AUTHOR is a
`change-review-author', BODY the text, TIME when it was written, as
`float-time' gives it.  LOCATION is where in the change it was made, a
`change-review-location' or nil, and REVISION the source revision it
was written against, the id of a version.  SENT is nil while the
comment is a draft, only its author's to see, and the time it was
delivered after.  EDITED is the time of its last edit.  META is a
plist for what the program using the library keeps with it."
  id thread reply-to author body time location revision sent edited meta)

(defun change-review-comment-draft-p (comment)
  "Return non-nil when COMMENT is a draft: not delivered yet."
  (null (change-review-comment-sent comment)))

(cl-defstruct (change-review-thread
               (:constructor change-review-make-thread
                             (&key id (status 'open) comments history meta))
               (:copier nil))
  "A conversation about the change, or about one place in it.
ID names it.  STATUS is `open' or `closed'; a thread is closed when
what it raised is done.  COMMENTS are its comments in the order they
were written, the first being the root.  HISTORY lists the changes of
status, oldest first, each a plist :status, :time, :author (a
`change-review-author'), :revision and :id.  META is a plist."
  id status comments history meta)

(cl-defstruct (change-review-file
               (:constructor change-review-make-file
                             (&key path old-path status patch (added 0) (deleted 0) binary
                                   old-blob new-blob old-mode new-mode patch-id meta))
               (:copier nil))
  "A file a version changes.
PATH is where the file is after the change (where it was, for a file
deleted), OLD-PATH where it was before when it was renamed or copied.
STATUS is the letter git gives: A added, D deleted, M modified, R
renamed, C copied, T type changed.  PATCH is the file's part of the
unified diff, from its \"diff --git\" line on.  ADDED and DELETED count
the lines the diff adds and deletes, BINARY is non-nil for a file with
no text diff.  OLD-BLOB and NEW-BLOB name the contents before and after
\(a git object id, or whatever the source calls them), OLD-MODE and
NEW-MODE the file modes.  PATCH-ID names the patch of a series the file
is in.  META is a plist."
  path old-path status patch (added 0) (deleted 0) binary
  old-blob new-blob old-mode new-mode patch-id meta)

(cl-defstruct (change-review-version
               (:constructor change-review-make-version
                             (&key id number label time author title description base tip files meta))
               (:copier nil))
  "One proposal of a change: a patch set.
ID is the source revision that names the version among the others of
its set, such as the commit it ends at.  NUMBER counts the versions of
the set from 1; LABEL is what to call it, \"v2\" by default.  TIME is
when it was proposed and AUTHOR (a `change-review-author') who
proposed it; for an agent that is the session and the tool call that
handed the change in.  TITLE and DESCRIPTION are the subject and the
description it came with, a cover letter or a report.  BASE is the
revision the change is made against, TIP the last revision of it.
FILES are the `change-review-file's it changes, nil when they are not
read or it changes none.  META is a plist."
  id number label time author title description base tip files meta)

(cl-defstruct (change-review-set
               (:constructor change-review-make-set
                             (&key id title description versions threads file meta))
               (:copier nil))
  "A change under review: its versions and the threads about them.
ID names the set, TITLE and DESCRIPTION say what it is.  VERSIONS are
the `change-review-version's, oldest first, THREADS the
`change-review-thread's in the order they were started.  FILE is where
`change-review-save' keeps the set, nil to keep it nowhere.  META is a
plist.  A struct that includes this one is a kind of set of its own,
whose behavior the generic functions below decide."
  id title description versions threads file meta)

;;;; Finding things

(defun change-review-find-thread (set id)
  "Return the thread of SET named ID, or nil.
An ID that names none but starts the id of exactly one thread, of
three characters at least, names that one."
  (when (stringp id)
    (or (cl-find id (change-review-set-threads set) :key #'change-review-thread-id :test #'equal)
        (and (>= (length id) 3)
             (let ((matches (cl-remove-if-not
                             (lambda (thread) (string-prefix-p id (change-review-thread-id thread)))
                             (change-review-set-threads set))))
               (and matches (null (cdr matches)) (car matches)))))))

(defun change-review-find-comment (set id)
  "Return (THREAD . COMMENT) for the comment of SET named ID, or nil."
  (when (stringp id)
    (cl-loop for thread in (change-review-set-threads set)
             for comment = (cl-find id (change-review-thread-comments thread)
                                    :key #'change-review-comment-id :test #'equal)
             when comment return (cons thread comment))))

(defun change-review-find-version (set key)
  "Return the version of SET that KEY names, or nil.
KEY is a version, an id (a source revision), a number or a label."
  (cond ((change-review-version-p key) key)
        ((numberp key) (cl-find key (change-review-set-versions set)
                                :key #'change-review-version-number))
        ((stringp key)
         (or (cl-find key (change-review-set-versions set)
                      :key #'change-review-version-id :test #'equal)
             (cl-find key (change-review-set-versions set)
                      :key #'change-review-version-label :test #'equal)))))

(defun change-review-latest-version (set)
  "Return the newest version of SET, or nil when it has none."
  (car (last (change-review-set-versions set))))

(defun change-review-version-name (version)
  "Return the name of VERSION: its label, else \"v\" and its number."
  (or (change-review--string (change-review-version-label version))
      (format "v%s" (or (change-review-version-number version) "?"))))

(defun change-review-revision-name (set revision)
  "Return what to call REVISION in SET: its version's name, else it shortened."
  (if-let* ((version (and revision (change-review-find-version set revision))))
      (change-review-version-name version)
    (change-review-short-revision revision)))

(defun change-review-new-thread-id (set)
  "Return a thread id SET does not have."
  (let (id)
    (while (or (null id) (cl-find id (change-review-set-threads set)
                                  :key #'change-review-thread-id :test #'equal))
      (setq id (change-review-new-id "t")))
    id))

;;;; Threads

(defun change-review-thread-root (thread)
  "Return the first comment of THREAD, or nil."
  (car (change-review-thread-comments thread)))

(defun change-review-thread-location (thread)
  "Return where THREAD is: its root's location, else a later comment's."
  (or (and (change-review-thread-root thread)
           (change-review-comment-location (change-review-thread-root thread)))
      (cl-some #'change-review-comment-location (change-review-thread-comments thread))))

(defun change-review-thread-file (thread)
  "Return the path of the file THREAD is about; nil for the change as a whole."
  (when-let* ((location (change-review-thread-location thread)))
    (change-review-location-file location)))

(defun change-review-thread-line (thread)
  "Return the line THREAD is about, or nil."
  (when-let* ((location (change-review-thread-location thread)))
    (change-review-location-line location)))

(defun change-review-kept-location (thread comment)
  "Return (LOCATION . EXACT) for the place kept with COMMENT of THREAD.
LOCATION is the comment's own, else its thread's: nil for a comment on
the change as a whole.  EXACT is non-nil when its lines are those of the
revision COMMENT was written against: it has an excerpt and is the
comment's own or was made on the same revision, or it names no line, so
there is no diff to show.  A reply, or a comment an agent made on a
line, has no excerpt of the revision it was written against: that is
found where the files of the revision are (`change-review-origin')."
  (let* ((own (change-review-comment-location comment))
         (location (or own (change-review-thread-location thread)))
         (root (change-review-thread-root thread))
         (revision (change-review-comment-revision comment))
         (basis (and root (change-review-comment-revision root))))
    (cons location
          (and location
               (or (null (change-review-location-line location))
                   (and (change-review-location-excerpt location)
                        (or own (null revision) (null basis)
                            (change-review-same-revision-p revision basis))))
               t))))

(defun change-review-thread-revision (thread)
  "Return the source revision THREAD was started against."
  (when-let* ((root (change-review-thread-root thread)))
    (change-review-comment-revision root)))

(defun change-review-thread-open-p (thread)
  "Return non-nil when THREAD is open."
  (eq (change-review-thread-status thread) 'open))

(defun change-review-thread-drafts (thread)
  "Return the comments of THREAD that are drafts, in order."
  (cl-remove-if-not #'change-review-comment-draft-p (change-review-thread-comments thread)))

(defun change-review-thread-last-comment (thread)
  "Return the newest comment of THREAD."
  (car (last (change-review-thread-comments thread))))

(defun change-review-thread-time (thread)
  "Return when THREAD was started: the time of its root."
  (when-let* ((root (change-review-thread-root thread)))
    (change-review-comment-time root)))

(defun change-review-comment-position (thread comment)
  "Return (INDEX . TOTAL) of COMMENT among the comments of THREAD.
INDEX counts from 1; nil when THREAD does not hold COMMENT."
  (let ((comments (change-review-thread-comments thread)))
    (when-let* ((tail (memq comment comments)))
      (cons (- (length comments) (length tail) -1) (length comments)))))

(defun change-review-comment-parent (thread comment)
  "Return the comment of THREAD that COMMENT answers, or nil."
  (when-let* ((id (change-review-comment-reply-to comment)))
    (cl-find id (change-review-thread-comments thread)
             :key #'change-review-comment-id :test #'equal)))

(defun change-review-comment-depth (thread comment)
  "Return how many answers deep COMMENT is in THREAD: 0 for a root."
  (let ((depth 0) (seen nil))
    (while-let ((parent (and (not (memq comment seen))
                             (change-review-comment-parent thread comment))))
      (push comment seen)
      (setq comment parent depth (1+ depth)))
    depth))

(defun change-review-thread-participants (thread)
  "Return the distinct authors of THREAD's comments, in order of appearance."
  (let (authors)
    (dolist (comment (change-review-thread-comments thread))
      (let ((author (change-review-comment-author comment)))
        (when (and author (not (cl-find author authors :test #'change-review-author-same-p)))
          (push author authors))))
    (nreverse authors)))

;;;; Queries

(defun change-review-threads (set &optional status)
  "Return the threads of SET, in the order they were started.
STATUS limits them to the `open' or the `closed' ones; nil or `all'
returns every one."
  (if (memq status '(nil all))
      (copy-sequence (change-review-set-threads set))
    (cl-remove-if-not (lambda (thread) (eq (change-review-thread-status thread) status))
                      (change-review-set-threads set))))

(defun change-review-thread-counts (set)
  "Return the counts of SET's threads as a plist.
:open and :closed count the threads of each status, :drafts the draft
comments, :comments all the comments."
  (let ((open 0) (closed 0) (drafts 0) (comments 0))
    (dolist (thread (change-review-set-threads set))
      (if (change-review-thread-open-p thread) (cl-incf open) (cl-incf closed))
      (cl-incf comments (length (change-review-thread-comments thread)))
      (cl-incf drafts (length (change-review-thread-drafts thread))))
    (list :open open :closed closed :drafts drafts :comments comments)))

(defun change-review-drafts (set)
  "Return the draft comments of SET, in the order they were written."
  (sort (cl-loop for thread in (change-review-set-threads set)
                 append (change-review-thread-drafts thread))
        (lambda (a b) (< (or (change-review-comment-time a) 0)
                         (or (change-review-comment-time b) 0)))))

(defun change-review-threads-by-file (set &optional status)
  "Return the threads of SET grouped by the file they are about.
The result is an alist of (FILE . THREADS).  FILE is a path, or nil for
the threads about the change as a whole, which come first; the paths
follow the order of the files of the newest version, those it does not
have after them by name.  THREADS are in the order of their lines, then
of the time they were started (`change-review-thread-time'), a thread
added later of an earlier time -- one imported -- where it belongs.
STATUS limits the threads as for `change-review-threads'."
  (let* ((threads (change-review-threads set status))
         (order (when-let* ((version (change-review-latest-version set)))
                  (mapcar #'change-review-file-path (change-review-version-files version))))
         (groups nil))
    (dolist (thread threads)
      (let* ((file (change-review-thread-file thread))
             (cell (assoc file groups)))
        (if cell
            (setcdr cell (append (cdr cell) (list thread)))
          (push (cons file (list thread)) groups))))
    (setq groups (nreverse groups))
    (dolist (group groups)
      (setcdr group (cl-stable-sort (cdr group)
                                    (lambda (a b)
                                      (let ((line-a (or (change-review-thread-line a) 0))
                                            (line-b (or (change-review-thread-line b) 0)))
                                        (if (/= line-a line-b)
                                            (< line-a line-b)
                                          (< (or (change-review-thread-time a) 0)
                                             (or (change-review-thread-time b) 0))))))))
    (let ((rank (lambda (file)
                  (cond ((null file) -1)
                        ((cl-position file order :test #'equal))
                        (t most-positive-fixnum)))))
      (cl-stable-sort groups (lambda (a b)
                               (let ((ra (funcall rank (car a))) (rb (funcall rank (car b))))
                                 (cond ((/= ra rb) (< ra rb))
                                       ((and (car a) (car b)) (string< (car a) (car b))))))))))

;;;; Operations

(defun change-review--status (value)
  "Return VALUE as a thread status, `open' or `closed'; signal for any other."
  (let ((status (change-review--symbol value)))
    (if (memq status '(open closed))
        status
      (signal 'change-review-error (list (format "Not a thread status: %S" value))))))

(defun change-review--insert-comment (thread comment)
  "Put COMMENT in THREAD, in the order of time, after those of the same time."
  (let ((time (or (change-review-comment-time comment) 0))
        (comments (change-review-thread-comments thread))
        (before nil))
    (while (and comments (<= (or (change-review-comment-time (car comments)) 0) time))
      (push (pop comments) before))
    (setf (change-review-thread-comments thread)
          (append (nreverse before) (list comment) comments))))

(defun change-review-comment-from-data (data)
  "Return the comment DATA, from `change-review-comment-to-data', holds."
  (change-review-make-comment
   :id (change-review--string (plist-get data :id))
   :thread (change-review--string (plist-get data :thread))
   :reply-to (change-review--string (plist-get data :reply-to))
   :author (change-review-author-from-data (plist-get data :author))
   :body (or (change-review--string (plist-get data :body)) "")
   :time (change-review--number (plist-get data :time))
   :location (change-review-location-from-data (plist-get data :location))
   :revision (change-review--string (plist-get data :revision))
   :sent (change-review--number (plist-get data :sent))
   :edited (change-review--number (plist-get data :edited))
   :meta (change-review--meta (plist-get data :meta))))

(defun change-review-comment-to-data (comment)
  "Return COMMENT as plain data."
  (change-review--plist
   :id (change-review-comment-id comment)
   :thread (change-review-comment-thread comment)
   :reply-to (change-review-comment-reply-to comment)
   :author (change-review-author-to-data (change-review-comment-author comment))
   :body (change-review-comment-body comment)
   :time (change-review-comment-time comment)
   :location (change-review-location-to-data (change-review-comment-location comment))
   :revision (change-review-comment-revision comment)
   :sent (change-review-comment-sent comment)
   :edited (change-review-comment-edited comment)
   :meta (change-review-comment-meta comment)))

(defun change-review-version-from-data (data)
  "Return the version DATA, from `change-review-version-to-data', holds."
  (change-review-make-version
   :id (change-review--string (plist-get data :id))
   :number (change-review--number (plist-get data :number))
   :label (change-review--string (plist-get data :label))
   :time (change-review--number (plist-get data :time))
   :author (change-review-author-from-data (plist-get data :author))
   :title (change-review--string (plist-get data :title))
   :description (change-review--string (plist-get data :description))
   :base (change-review--string (plist-get data :base))
   :tip (change-review--string (plist-get data :tip))
   :files (mapcar #'change-review-file-from-data (change-review--list (plist-get data :files)))
   :meta (change-review--meta (plist-get data :meta))))

(defun change-review-version-to-data (version &optional files)
  "Return VERSION as plain data, with its files when FILES is non-nil."
  (change-review--plist
   :id (change-review-version-id version)
   :number (change-review-version-number version)
   :label (change-review-version-label version)
   :time (change-review-version-time version)
   :author (change-review-author-to-data (change-review-version-author version))
   :title (change-review-version-title version)
   :description (change-review-version-description version)
   :base (change-review-version-base version)
   :tip (change-review-version-tip version)
   :files (and files (mapcar #'change-review-file-to-data (change-review-version-files version)))
   :meta (change-review-version-meta version)))

(defun change-review-file-from-data (data)
  "Return the file DATA, from `change-review-file-to-data', holds."
  (change-review-make-file
   :path (change-review--string (plist-get data :path))
   :old-path (change-review--string (plist-get data :old-path))
   :status (change-review--string (plist-get data :status))
   :patch (change-review--string (plist-get data :patch))
   :added (or (change-review--number (plist-get data :added)) 0)
   :deleted (or (change-review--number (plist-get data :deleted)) 0)
   :binary (and (change-review--blank (plist-get data :binary)) t)
   :old-blob (change-review--string (plist-get data :old-blob))
   :new-blob (change-review--string (plist-get data :new-blob))
   :old-mode (change-review--string (plist-get data :old-mode))
   :new-mode (change-review--string (plist-get data :new-mode))
   :patch-id (let ((id (change-review--blank (plist-get data :patch-id))))
               (and id (if (numberp id) id (change-review--string id))))
   :meta (change-review--meta (plist-get data :meta))))

(defun change-review-file-to-data (file)
  "Return FILE as plain data."
  (change-review--plist
   :path (change-review-file-path file)
   :old-path (change-review-file-old-path file)
   :status (change-review-file-status file)
   :patch (change-review-file-patch file)
   :added (let ((n (change-review-file-added file))) (and n (> n 0) n))
   :deleted (let ((n (change-review-file-deleted file))) (and n (> n 0) n))
   :binary (and (change-review-file-binary file) t)
   :old-blob (change-review-file-old-blob file)
   :new-blob (change-review-file-new-blob file)
   :old-mode (change-review-file-old-mode file)
   :new-mode (change-review-file-new-mode file)
   :patch-id (change-review-file-patch-id file)
   :meta (change-review-file-meta file)))

(defun change-review--history-from-data (data)
  "Return the history entry DATA describes: a plist with an author struct."
  (change-review--plist
   :id (change-review--string (plist-get data :id))
   :status (change-review--symbol (plist-get data :status))
   :time (change-review--number (plist-get data :time))
   :author (change-review-author-from-data (plist-get data :author))
   :revision (change-review--string (plist-get data :revision))))

(defun change-review--history-to-data (entry)
  "Return the history ENTRY, a plist with an author struct, as plain data."
  (change-review--plist
   :id (plist-get entry :id)
   :status (and (plist-get entry :status) (symbol-name (plist-get entry :status)))
   :time (plist-get entry :time)
   :author (change-review-author-to-data (plist-get entry :author))
   :revision (plist-get entry :revision)))

(defun change-review--apply-add-comment (set op)
  "Perform the `add-comment' operation OP on SET; non-nil if SET changed."
  (let* ((comment (change-review-comment-from-data (plist-get op :comment)))
         (thread-id (or (change-review--string (plist-get op :thread))
                        (change-review-comment-thread comment))))
    (unless (and (change-review-comment-id comment) thread-id)
      (signal 'change-review-error (list "A comment needs an id and a thread")))
    (setf (change-review-comment-thread comment) thread-id)
    (unless (change-review-find-comment set (change-review-comment-id comment))
      (let ((thread (cl-find thread-id (change-review-set-threads set)
                             :key #'change-review-thread-id :test #'equal)))
        (unless thread
          (setq thread (change-review-make-thread
                        :id thread-id
                        :meta (change-review--meta (plist-get op :thread-meta))))
          (setf (change-review-set-threads set)
                (append (change-review-set-threads set) (list thread))))
        (change-review--insert-comment thread comment)
        t))))

(defun change-review--apply-set-status (set op)
  "Perform the `set-status' operation OP on SET; non-nil if SET changed."
  (let* ((thread (or (change-review-find-thread set (plist-get op :thread))
                     (signal 'change-review-error
                             (list (format "No thread %s" (plist-get op :thread))))))
         (status (change-review--status (plist-get op :status)))
         (id (change-review--string (plist-get op :id))))
    (unless (or (eq status (change-review-thread-status thread))
                (and id (cl-find id (change-review-thread-history thread)
                                 :key (lambda (entry) (plist-get entry :id)) :test #'equal)))
      (setf (change-review-thread-status thread) status
            (change-review-thread-history thread)
            (append (change-review-thread-history thread)
                    (list (change-review--plist
                           :id id :status status
                           :time (change-review--number (plist-get op :time))
                           :author (change-review-author-from-data (plist-get op :author))
                           :revision (change-review--string (plist-get op :revision))))))
      t)))

(defun change-review--apply-add-version (set op)
  "Perform the `add-version' operation OP on SET; non-nil if SET changed."
  (let ((version (change-review-version-from-data (plist-get op :version))))
    (unless (change-review-version-id version)
      (signal 'change-review-error (list "A version needs an id")))
    (unless (cl-find (change-review-version-id version) (change-review-set-versions set)
                     :key #'change-review-version-id :test #'equal)
      (unless (change-review-version-number version)
        (setf (change-review-version-number version)
              (1+ (apply #'max 0 (mapcar (lambda (v) (or (change-review-version-number v) 0))
                                         (change-review-set-versions set))))))
      (setf (change-review-set-versions set)
            (append (change-review-set-versions set) (list version)))
      t)))

(defun change-review--apply-mark-sent (set op)
  "Perform the `mark-sent' operation OP on SET; non-nil if SET changed."
  (let ((time (or (change-review--number (plist-get op :time)) (float-time)))
        (meta (change-review--meta (plist-get op :meta)))
        (changed nil))
    (dolist (id (change-review--list (plist-get op :comments)))
      (when-let* ((found (change-review-find-comment set id))
                  (comment (cdr found)))
        (when (change-review-comment-draft-p comment)
          (setf (change-review-comment-sent comment) time)
          (let ((merged (change-review-comment-meta comment)))
            (cl-loop for (key value) on meta by #'cddr
                     do (setq merged (plist-put (copy-sequence merged) key value)))
            (setf (change-review-comment-meta comment) merged))
          (setq changed t))))
    changed))

(defun change-review--apply-edit-comment (set op)
  "Perform the `edit-comment' operation OP on SET; non-nil if SET changed."
  (let* ((found (or (change-review-find-comment set (plist-get op :comment))
                    (signal 'change-review-error
                            (list (format "No comment %s" (plist-get op :comment))))))
         (comment (cdr found))
         (body (plist-get op :body)))
    (unless (stringp body)
      (signal 'change-review-error (list "An edit needs the new text")))
    (unless (equal body (change-review-comment-body comment))
      (setf (change-review-comment-body comment) body
            (change-review-comment-edited comment)
            (or (change-review--number (plist-get op :time)) (float-time)))
      t)))

(defun change-review--apply-delete-comment (set op)
  "Perform the `delete-comment' operation OP on SET; non-nil if SET changed.
Only a draft can be deleted: what was delivered was read."
  (when-let* ((found (change-review-find-comment set (plist-get op :comment))))
    (let ((thread (car found)) (comment (cdr found)))
      (unless (change-review-comment-draft-p comment)
        (signal 'change-review-error (list "A comment that was sent cannot be deleted")))
      (setf (change-review-thread-comments thread)
            (delq comment (change-review-thread-comments thread)))
      (unless (change-review-thread-comments thread)
        (setf (change-review-set-threads set) (delq thread (change-review-set-threads set))))
      t)))

(defun change-review-apply (set op &optional silent)
  "Perform operation OP on SET; return non-nil when it changed SET.
OP is a plist whose :op is one of
  add-comment     :comment, the data of a comment (:id, :thread, ...);
                  starts the thread named by :thread when SET has none;
  set-status      :thread, :status (open or closed), :id, :time,
                  :author (data) and :revision;
  add-version     :version, the data of a version;
  mark-sent       :comments, ids, :time, :meta (merged into theirs);
  edit-comment    :comment, an id, :body and :time;
  delete-comment  :comment, an id (of a draft).
An operation that finds its change made already -- a comment, a version
or a status change of that id is there -- does nothing and returns nil,
so an operation can be performed again without harm.  Unless SILENT,
`change-review-changed-functions' are called when SET changed.  An
operation that cannot be performed signals `change-review-error'."
  (let ((changed (pcase (change-review--symbol (plist-get op :op))
                   ('add-comment (change-review--apply-add-comment set op))
                   ('set-status (change-review--apply-set-status set op))
                   ('add-version (change-review--apply-add-version set op))
                   ('mark-sent (change-review--apply-mark-sent set op))
                   ('edit-comment (change-review--apply-edit-comment set op))
                   ('delete-comment (change-review--apply-delete-comment set op))
                   (kind (signal 'change-review-error
                                 (list (format "Unknown operation %S" kind)))))))
    (when (and changed (not silent))
      (run-hook-with-args 'change-review-changed-functions set op))
    (and changed t)))

;;;; Generic functions: what a kind of set decides

(cl-defgeneric change-review-dispatch (set op)
  "Perform operation OP on SET, the way SET's kind of set does.
The commands of the library change a set only through this.  The
method for a plain `change-review-set' performs OP on the set in this
Emacs and saves it (`change-review-save').  A kind of set that lives
elsewhere sends OP there, and performs it here too, in the same way,
so that what the user did shows at once.  Return what
`change-review-apply' returns.")

(cl-defmethod change-review-dispatch ((set change-review-set) op)
  (prog1 (change-review-apply set op)
    (change-review-save set)))

(cl-defgeneric change-review-save (set)
  "Keep SET, after an operation changed it.
The method for a plain `change-review-set' writes it to its file, if it
has one (`change-review-write-file').")

(cl-defmethod change-review-save ((set change-review-set))
  (when-let* ((file (change-review-set-file set)))
    (change-review-write-file set file)))

(cl-defgeneric change-review-current-author (set)
  "Return the author of what the user does in SET.")

(cl-defmethod change-review-current-author ((_set change-review-set))
  (change-review-user (or (change-review--string user-full-name) (user-login-name))
                      (change-review--string user-mail-address)))

(cl-defgeneric change-review-own-author-p (set author)
  "Return non-nil when AUTHOR is the user of SET, who sees \"(you)\" by it.
The method for a plain `change-review-set' compares AUTHOR with
`change-review-current-author'; a kind of set whose user is known by
other means -- the only one who reviews, say -- answers for itself.")

(cl-defmethod change-review-own-author-p ((set change-review-set) author)
  (and author (change-review-author-same-p author (change-review-current-author set))))

(cl-defgeneric change-review-send (set)
  "Send the drafts of SET to whom they are for.
The user interface calls it for \\`C-c C-c'.  The method of the user
interface for a plain `change-review-set' writes the drafts as mail
replies to the patches (`change-review-mail-compose'); a kind of set
that reviews work somewhere else sends them there, marking them sent
\(`change-review-mark-sent').  Without a method of its own, a set has no
place to send to."
  (ignore set)
  (user-error "This review has nowhere to send its drafts"))

(cl-defgeneric change-review-follow-author (set author)
  "Show the point of the conversation AUTHOR's comment came from.
That is the session and tool call of an agent author.  The method for a
plain `change-review-set' knows nothing of conversations.")

(cl-defmethod change-review-follow-author ((_set change-review-set) author)
  (user-error "No conversation to show for %s" (change-review-author-label author)))

(cl-defgeneric change-review-file-text (set version file side)
  "Return the text of FILE of VERSION on SIDE, `old' or `new', or nil.
It is how the review reads a file the diff holds only a part of.  The
method for a plain `change-review-set' has none.")

(cl-defmethod change-review-file-text ((_set change-review-set) _version _file _side)
  nil)

(cl-defgeneric change-review-visit (set target &optional version)
  "Show TARGET, a thread, a comment or a location, in the diff view of SET.
VERSION names the version to show it in; by default the newest.  The
user interface of the library (change-review-ui.el) gives the method for
a plain `change-review-set'; a kind of set with a diff view of its own
gives one that shows that.")

;;;; Changing a set

(cl-defgeneric change-review-default-revision (set)
  "Return the revision a comment made now in SET is written against.
The method for a plain `change-review-set' is the newest version's.  A
kind of set whose user can look at the code of another version answers
that one: what a comment is written against is what its author saw.")

(cl-defmethod change-review-default-revision ((set change-review-set))
  (when-let* ((version (change-review-latest-version set)))
    (change-review-version-id version)))

(defun change-review--default-revision (set)
  "Return the revision a comment made now in SET is against."
  (change-review-default-revision set))

(cl-defun change-review-comment (set body &key thread reply-to author location revision
                                     time sent meta)
  "Add a comment with text BODY to SET; return the comment.
It starts a new thread, open, unless it is in THREAD (an id or a
thread) or answers REPLY-TO (a comment or an id), which puts it in the
thread of that comment.  AUTHOR defaults to `change-review-current-author',
REVISION to the newest version's, TIME to now.  LOCATION is a
`change-review-location' or nil.  SENT is the time the comment was
delivered, nil for a draft.  META is the comment's plist.
Operations go through `change-review-dispatch'."
  (let* ((parent (and reply-to
                      (let ((found (change-review-find-comment
                                    set (if (change-review-comment-p reply-to)
                                            (change-review-comment-id reply-to)
                                          reply-to))))
                        (or found (signal 'change-review-error
                                          (list (format "No comment %s to answer" reply-to)))))))
         (thread-id (cond ((change-review-thread-p thread) (change-review-thread-id thread))
                          (thread (or (and (change-review-find-thread set thread)
                                           (change-review-thread-id (change-review-find-thread set thread)))
                                      thread))
                          (parent (change-review-thread-id (car parent)))
                          (t (change-review-new-thread-id set))))
         (id (change-review-new-id "c"))
         (comment (change-review-make-comment
                   :id id :thread thread-id
                   :reply-to (and parent (change-review-comment-id (cdr parent)))
                   :author (or author (change-review-current-author set))
                   :body body :time (or time (float-time))
                   :location location
                   :revision (or revision (change-review--default-revision set))
                   :sent sent :meta meta)))
    (when (and parent thread (not (equal thread-id (change-review-thread-id (car parent)))))
      (signal 'change-review-error (list "A reply is in the thread of the comment it answers")))
    (change-review-dispatch set (list :op 'add-comment :thread thread-id
                                      :comment (change-review-comment-to-data comment)))
    (cdr (change-review-find-comment set id))))

(cl-defun change-review-reply (set comment body &key author revision time sent location meta)
  "Add a comment with text BODY to SET that answers COMMENT; return it.
COMMENT is a comment or its id.  The other arguments are those of
`change-review-comment'."
  (change-review-comment set body :reply-to comment :author author :revision revision
                         :time time :sent sent :location location :meta meta))

(cl-defun change-review-update-status (set thread status &key author time revision)
  "Make THREAD, a thread of SET or its id, STATUS: `open' or `closed'.
The change is recorded in the thread's history with AUTHOR (by default
`change-review-current-author'), TIME (now) and REVISION (the newest
version's).  Return non-nil when the status changed."
  (let ((thread (if (change-review-thread-p thread) thread (change-review-find-thread set thread))))
    (unless thread (signal 'change-review-error (list "No such thread")))
    (change-review-dispatch
     set (list :op 'set-status :thread (change-review-thread-id thread)
               :status (symbol-name (change-review--status status))
               :id (change-review-new-id "s")
               :time (or time (float-time))
               :author (change-review-author-to-data (or author (change-review-current-author set)))
               :revision (or revision (change-review--default-revision set))))))

(defun change-review-close (set thread &rest keys)
  "Close THREAD of SET.  KEYS are those of `change-review-update-status'."
  (apply #'change-review-update-status set thread 'closed keys))

(defun change-review-reopen (set thread &rest keys)
  "Open THREAD of SET again.  KEYS are those of `change-review-update-status'."
  (apply #'change-review-update-status set thread 'open keys))

(defun change-review-add-version (set version)
  "Add VERSION, a `change-review-version', to SET; return the version SET has.
A version with the id of one SET has is not added again.  Its number is
the next free one unless it has one.  The version is added through
`change-review-dispatch' without its files, which are read where they
are: a version has them in its struct, in memory."
  (change-review-dispatch set (list :op 'add-version
                                    :version (change-review-version-to-data version)))
  (let ((have (change-review-find-version set (change-review-version-id version))))
    (when (and have version (null (change-review-version-files have))
               (change-review-version-files version))
      (setf (change-review-version-files have) (change-review-version-files version)))
    have))

(cl-defun change-review-mark-sent (set comments &key time meta)
  "Mark COMMENTS, comments of SET or their ids, as delivered at TIME.
META, a plist, is merged into the metadata of each.  Return non-nil
when one was a draft."
  (change-review-dispatch
   set (list :op 'mark-sent
             :comments (mapcar (lambda (c) (if (change-review-comment-p c) (change-review-comment-id c) c))
                               comments)
             :time (or time (float-time)) :meta meta)))

(cl-defun change-review-edit (set comment body &key time)
  "Replace the text of COMMENT of SET, a comment or an id, with BODY."
  (change-review-dispatch
   set (list :op 'edit-comment
             :comment (if (change-review-comment-p comment) (change-review-comment-id comment) comment)
             :body body :time (or time (float-time)))))

(defun change-review-delete (set comment)
  "Delete COMMENT of SET, a comment or an id; only a draft can be.
A thread left with no comment goes too."
  (change-review-dispatch
   set (list :op 'delete-comment
             :comment (if (change-review-comment-p comment) (change-review-comment-id comment) comment))))

;;;; Plain data and files

(defun change-review-thread-to-data (thread)
  "Return THREAD as plain data."
  (change-review--plist
   :id (change-review-thread-id thread)
   :status (symbol-name (change-review-thread-status thread))
   :comments (mapcar #'change-review-comment-to-data (change-review-thread-comments thread))
   :history (mapcar #'change-review--history-to-data (change-review-thread-history thread))
   :meta (change-review-thread-meta thread)))

(defun change-review-thread-from-data (data)
  "Return the thread DATA, from `change-review-thread-to-data', holds."
  (let* ((id (change-review--string (plist-get data :id)))
         (thread (change-review-make-thread
                  :id id
                  :status (or (change-review--symbol (plist-get data :status)) 'open)
                  :history (mapcar #'change-review--history-from-data
                                   (change-review--list (plist-get data :history)))
                  :meta (change-review--meta (plist-get data :meta)))))
    (dolist (comment-data (change-review--list (plist-get data :comments)))
      (let ((comment (change-review-comment-from-data comment-data)))
        (setf (change-review-comment-thread comment) id)
        (change-review--insert-comment thread comment)))
    thread))

(defun change-review-set-to-data (set &optional files)
  "Return SET as plain data: plists, lists, strings and numbers.
The versions carry their files when FILES is non-nil."
  (change-review--plist
   :format 1
   :id (change-review-set-id set)
   :title (change-review-set-title set)
   :description (change-review-set-description set)
   :versions (mapcar (lambda (v) (change-review-version-to-data v files))
                     (change-review-set-versions set))
   :threads (mapcar #'change-review-thread-to-data (change-review-set-threads set))
   :meta (change-review-set-meta set)))

(defun change-review-set-from-data (data &optional set)
  "Return the set DATA, as `change-review-set-to-data' gives it, describes.
With SET, a set that exists, its contents are replaced by DATA's and
SET is returned; the file, the identity and the kind of SET stay."
  (let ((versions (mapcar #'change-review-version-from-data
                          (change-review--list (plist-get data :versions))))
        (threads (mapcar #'change-review-thread-from-data
                         (change-review--list (plist-get data :threads)))))
    (if set
        (progn
          ;; Files read for a version stay with it when the data has none.
          (dolist (version versions)
            (let ((have (change-review-find-version set (change-review-version-id version))))
              (when (and have (null (change-review-version-files version)))
                (setf (change-review-version-files version) (change-review-version-files have)))))
          (setf (change-review-set-title set) (change-review--string (plist-get data :title))
                (change-review-set-description set) (change-review--string (plist-get data :description))
                (change-review-set-versions set) versions
                (change-review-set-threads set) threads
                (change-review-set-meta set) (change-review--meta (plist-get data :meta)))
          set)
      (change-review-make-set
       :id (change-review--string (plist-get data :id))
       :title (change-review--string (plist-get data :title))
       :description (change-review--string (plist-get data :description))
       :versions versions :threads threads
       :meta (change-review--meta (plist-get data :meta))))))

(defun change-review-write-file (set file)
  "Write SET to FILE as Lisp data, atomically; return FILE.
The versions are written with their files."
  (let ((dir (file-name-directory (expand-file-name file))))
    (make-directory dir t)
    (let ((temp (make-temp-file (expand-file-name ".change-review-" dir)))
          (coding-system-for-write 'utf-8-unix))
      (unwind-protect
          (progn
            (with-temp-file temp
              (let ((print-length nil) (print-level nil) (print-circle nil)
                    (print-escape-newlines t))
                (insert ";; -*- mode: lisp-data; coding: utf-8 -*-\n"
                        ";; A change review: its versions, threads and comments.\n")
                (prin1 (change-review-set-to-data set t) (current-buffer))
                (insert "\n")))
            (rename-file temp file t)
            (setq temp nil))
        (when (and temp (file-exists-p temp)) (delete-file temp)))))
  file)

(defun change-review-read-file (file)
  "Return the set kept in FILE by `change-review-write-file'.
The set's FILE is FILE, so that it keeps itself there."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (goto-char (point-min))
    (let ((data (let ((read-circle nil) (read-eval nil)) (read (current-buffer)))))
      (unless (and (consp data) (keywordp (car data)))
        (signal 'change-review-error (list (format "%s is no change review" file))))
      (let ((set (change-review-set-from-data data)))
        (setf (change-review-set-file set) file)
        set))))

(provide 'change-review)
;;; change-review.el ends here
