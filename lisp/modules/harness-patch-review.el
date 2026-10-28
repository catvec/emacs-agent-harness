;;; harness-patch-review.el --- The threads of a task's review: kept, delivered, answered  -*- lexical-binding: t; -*-

;;; Commentary:

;; The harness's half of reviewing a task's changes with threads.  The
;; library change-review (lisp/vendor/change-review) knows the data of a
;; review -- change sets with versions, threads of comments, and the
;; operations that change them -- and nothing of the harness; this module
;; is the adapter that gives it a task to review and a place to keep its
;; threads.  Its UI half is `ui-patch-review', which draws them.
;;
;; A task is a CHANGE SET.  Each time its agent hands the work in -- the
;; task comes to review -- the branch's tip is a VERSION of it: the
;; first hand-in, the second after the review sent it back.  The
;; version is named by the tip commit, the source revision every comment
;; made against it records; it comes with the commit the branch was made
;; from, the report's summary as its description, and, as its author,
;; the agent, with the session and the `hand_in' call that handed it in.
;;
;; The module is the single writer of a task's threads, so the user's
;; Emacs and the agent's tools never disagree: the UI sends the
;; operations the user makes (`patch-review/apply'), the tools send the
;; agent's (`review_comment'), the module performs them on the set it
;; keeps in the state directory, one document a task
;; (patch-review/TASK.json), and announces each in `patch-review/changed'
;; for every UI to perform on its own copy.  An operation names what it
;; adds by id, so performing one twice is harmless.
;;
;; THE AUTHORS.  The user writes as themselves, by name and address.  An
;; agent's comment records the agent, the session and the tool call that
;; made it (`review_comment'), the link back to that point of the
;; conversation.
;;
;; THE DRAFTS.  What the user writes in the review is a draft until the
;; task is sent back.  Whatever sends it back -- the report's box, a
;; message typed in its session, another client -- gets the drafts with
;; it: `harness-tasks-feedback-additions-functions' asks this module for
;; the text, which quotes the diff above each comment as a reply on a
;; mailing list does and names each comment's thread, and the drafts are
;; marked sent once the task is.  The agent answers a thread with
;; `review_comment', closing it when its point is done; the user closes
;; it in turn, once they agree.
;;
;; THE CLOSES.  The agent closes a thread; the user is the one who says
;; the point is done.  A thread the agent closed is TO REVIEW until the
;; user has looked at it: the library keeps that on the close itself
;; (the operations `mark-reviewed' and `unmark-reviewed', which a UI
;; sends like any other), so a close from two rounds ago still waits
;; and nothing takes it for read.  The agent is told, with the threads
;; it answers, that the user looks at every thread it closes.
;;
;; THE EARLIER ROUNDS.  A task sent back before there were threads kept
;; its feedback as text.  The first time a task's set is made, the
;; comments quoted in those rounds become closed threads of the set, with
;; ids that follow from where they were, so that they are made once.  A
;; reply written inline, under a quote of the agent's own words (the
;; compose box's `C-u C-c >'), keeps that quote above its text: "silence"
;; says nothing without the line it answers.
;;
;; THE THREADS STARTED IN THE CHAT.  The compose box's `C-c >' starts a
;; thread on purpose: the region it replies to -- a part of a message,
;; several messages, lines of a diff -- is recorded with the reply, as
;; data (`harness-thread-block'), and nothing is guessed from the words.
;; When the message is sent, each such reply is a comment in a thread of
;; the task's review (`harness-patch-review--on-message', an
;; `agent/message' filter; `task/reject', which the report's box sends
;; the feedback with, asks for it itself before the round of feedback is
;; kept, `harness-patch-review--on-feedback-attachments', a filter on
;; `task/feedback-attachments'): a reference to a comment of the
;; agent's in a thread (`review_comment') or to an earlier reply of the
;; user's makes it a reply in that thread, which a close does not keep
;; from opening again; lines of a diff put it on those lines, at the
;; revision; any other starts a thread on the change as a whole.  The
;; block that goes on, and is recorded, has the thread's id, and its text
;; ends with the marker (`harness-thread-marker'), which is how the agent
;; knows the thread to answer in, and with which tool, and how the chat
;; draws a link to it.  A reply that is a thread is no words: the tasks
;; module leaves it out of the words a task is sent back with
;; (`harness-tasks--words'), so they are not a thread of their own too,
;; and the import of rounds and of words by hand, which reads text, skips
;; what ends with a marker.  Only a task's session has a review, and only
;; an agent that has `review_comment' can answer in it: any other
;; session's replies stay plain, answered inline.
;;
;; THE WORDS BY HAND.  Not every reply made it into a round.  One typed in
;; the session while the agent was at work -- steering, quoting what the
;; agent said and answering it -- was never feedback, so no round holds
;; it.  `patch-review/import-manual' reads such replies from the task's
;; session and makes them closed threads too, and gives the replies of the
;; rounds the quote an earlier import left out.  It is asked for, never
;; done on its own: the words of a session are not all comments.
;;
;; THE FILES VIEWED.  Which files the reviewer has looked at, and which
;; they approved, are kept with the review (patch-review-viewed/TASK.json),
;; each by its path and the blob it was seen at, so a file the branch
;; changes again is not viewed.  `patch-review/assume-viewed' takes every
;; file as viewed but those a commit changed -- the newest, by default --
;; for a review the reviewer went through before the marks were kept.  It
;; is asked for, never done on its own: what the reviewer saw is theirs
;; to say.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'harness-core)
(require 'harness-util)
(require 'harness-links)

;; change-review is in lisp/vendor/change-review, which the harness puts
;; on `load-path' (`harness--setup-load-path').  A harness older than
;; that directory, reloading after an update, first checks that this
;; file compiles with the `load-path' it has, before it loads the
;; harness.el that adds the directory.  So when the library is not found,
;; look for it beside the file being compiled or loaded.
(defvar byte-compile-current-file)
(eval-and-compile
  (unless (or (featurep 'change-review) (locate-library "change-review"))
    (when-let* ((file (or (and (boundp 'byte-compile-current-file)
                               (stringp byte-compile-current-file)
                               byte-compile-current-file)
                          load-file-name
                          buffer-file-name))
                (dir (expand-file-name "../vendor/change-review/" (file-name-directory file)))
                ((file-directory-p dir)))
      (add-to-list 'load-path dir))))
(require 'change-review)
(require 'change-review-mail)

(defvar harness-tasks-feedback-additions-functions)

;;;; The set of a task

(cl-defstruct (harness-patch-review--set
               (:include change-review-set)
               (:constructor harness-patch-review--make-set
                             (&key id title description versions threads meta))
               (:copier nil))
  "The threads of one task's review, kept in the state directory.")

(defvar harness-patch-review--sets (make-hash-table :test 'equal)
  "Task id -> the `harness-patch-review--set' of its review, once read.")

(defun harness-patch-review--store-name (id)
  "Return the name of the document that keeps the set of task ID."
  (format "patch-review/%s.json" (replace-regexp-in-string "[^A-Za-z0-9._-]" "_" id)))

(defun harness-patch-review--save (set)
  "Write SET to the store."
  (when (harness-method-exists-p 'store/save)
    (condition-case err
        (harness-call 'store/save (harness-patch-review--store-name (change-review-set-id set))
                      (change-review-set-to-data set nil))
      (error (harness-log 'warn "patch-review: saving the threads of %s failed: %s"
                          (change-review-set-id set) (harness-error-message err))))))

(cl-defmethod change-review-save ((set harness-patch-review--set))
  (harness-patch-review--save set))

(cl-defmethod change-review-current-author ((_set harness-patch-review--set))
  (harness-patch-review--user))

(defun harness-patch-review--user ()
  "Return the user, as the author of what the user writes."
  (change-review-user (if (and (stringp user-full-name) (not (string-empty-p user-full-name)))
                          user-full-name
                        (user-login-name))
                      (and (stringp user-mail-address) (not (string-empty-p user-mail-address))
                           user-mail-address)))

(defun harness-patch-review--model-name (model)
  "Return how to call the agent that runs MODEL, such as \"claude:sonnet\"."
  (cond ((not (and (stringp model) (not (string-empty-p model)))) "Agent")
        ((string-match "\\`\\([^:]+\\):\\(.+\\)\\'" model)
         (format "%s (%s)" (capitalize (match-string 1 model)) (match-string 2 model)))
        (t model)))

(defun harness-patch-review--agent (session-id &optional call-id)
  "Return the agent of SESSION-ID as an author.
CALL-ID is the tool call that made the comment, if any."
  (let ((session (and (stringp session-id) (harness-method-exists-p 'session/get)
                      (ignore-errors (harness-call 'session/get session-id)))))
    (change-review-agent (harness-patch-review--model-name (plist-get session :model))
                         :session session-id :tool-call call-id)))

(defun harness-patch-review--task (id)
  "Return the task ID, or signal an error when there is none."
  (or (and (harness-method-exists-p 'task/get) (harness-call 'task/get id))
      (signal 'harness-error (list (format "No task %s" id)))))

(defun harness-patch-review--task-title (task)
  "Return what to call TASK."
  (or (let ((name (plist-get task :name))) (and (stringp name) (not (string-blank-p name)) name))
      (harness-first-line (or (plist-get task :prompt) "task") 72)))

;;;; The earlier rounds

(defvar harness-tasks--reject-message)
(defvar harness-tasks--sent-back-message)
(defvar harness-tasks--aside-message)

(defun harness-patch-review--rule-p (text)
  "Return non-nil when TEXT is only a rule: three or more of \"-\", \"*\", \"_\" or \"=\".
Typed between two comments to part them, it is none of the two."
  (and (stringp text)
       (string-match-p "\\`\\(?:-\\{3,\\}\\|\\*\\{3,\\}\\|_\\{3,\\}\\|=\\{3,\\}\\)\\'"
                       (string-trim text))))

(defun harness-patch-review--quoted (lines)
  "Return LINES, the text of a quote, as a block quote: each line after \"> \"."
  (mapconcat (lambda (line) (if (string-blank-p line) ">" (concat "> " line))) lines "\n"))

(defun harness-patch-review--trim-blank (lines)
  "Return LINES without the blank lines at either end."
  (while (and lines (string-blank-p (car lines))) (setq lines (cdr lines)))
  (setq lines (reverse lines))
  (while (and lines (string-blank-p (car lines))) (setq lines (cdr lines)))
  (nreverse lines))

(defun harness-patch-review--reply-text (block)
  "Return what BLOCK, a comment read from a reply, says, with the quote it answers.
BLOCK is one of `change-review-mail-parse-reply''s.  Its quoted lines
that are no diff -- the agent's words the reply answers inline -- go
above the text as a block quote; a comment under a quoted diff has the
diff in its location instead."
  (let ((prose (harness-patch-review--trim-blank (plist-get block :prose)))
        (body (plist-get block :body)))
    (if prose
        (concat (harness-patch-review--quoted prose) "\n\n" body)
      body)))

(cl-defun harness-patch-review--reply-ops (set key text at &key split meta quoted-only)
  "Return the operations that make the comments of the reply TEXT threads of SET.
They are closed threads.  KEY says where TEXT is from, a round's index
or a message's name: the ids follow from SET, KEY and the place of the
comment in TEXT, so what SET has already is not made again.  The
comments were written by the user at AT, against the commit TEXT names
when it does.  SPLIT makes a paragraph of a reply a comment of its own,
as the rounds did; META is the plist each comment keeps; with
QUOTED-ONLY only a comment that answers a quote of the agent's words
counts, the others are no comments.

A comment SET has already from an earlier import, still with the plain text
it was imported with and never edited, comes back as an `edit-comment'
operation when the reply puts a quote above it: the quote an earlier
import left out.  A reply that is a comment already, made in the chat
\(`harness-patch-review--register-thread'), is no comment to make: its
answer ends with its thread's marker (`harness-thread-marker'), which
the text of a round or of a message keeps."
  (let* ((id (change-review-set-id set))
         (author (harness-patch-review--user))
         ;; A reply the chat made a thread of was never feedback to import.
         (text (if (harness-thread-marker-ids text) (harness-patch-review--unregistered text) text))
         (tip (change-review-mail-parse-tip text))
         ops)
    (cl-loop
     for block in (change-review-mail-parse-reply text :split split)
     for k from 0
     for plain = (plist-get block :body)
     for thread = (change-review-stable-id "t" id key k)
     for comment-id = (change-review-stable-id "c" id key k)
     for body = (harness-patch-review--reply-text block)
     for path = (plist-get block :path)
     for have = (cdr (change-review-find-comment set comment-id))
     unless (or (harness-patch-review--rule-p plain)
                (and quoted-only (equal body plain)))
     do (cond
         ((null have)
          (push (list :op 'add-comment :thread thread
                      :comment (change-review-comment-to-data
                                (change-review-make-comment
                                 :id comment-id :thread thread :author author
                                 :body body :time at :sent at :revision tip
                                 :location (and path
                                                (change-review-make-location
                                                 :file path :old-file (plist-get block :old-path)
                                                 :side (or (plist-get block :side) 'new)
                                                 :line (plist-get block :line)
                                                 :end-line (plist-get block :end-line)
                                                 :excerpt (plist-get block :excerpt)))
                                 :meta (copy-sequence meta))))
                ops)
          (push (list :op 'set-status :thread thread :status "closed"
                      :id (change-review-stable-id "s" id key k) :time at
                      :author (change-review-author-to-data author) :revision tip)
                ops))
         ((and (not (equal body plain))
               (equal (change-review-comment-body have) plain)
               (plist-get (change-review-comment-meta have) :imported)
               (null (change-review-comment-edited have)))
          (push (list :op 'edit-comment :comment comment-id :body body :time (float-time))
                ops))))
    (nreverse ops)))

(defun harness-patch-review--round-ops (set task)
  "Return the operations that make TASK's rounds of feedback threads of SET.
See `harness-patch-review--reply-ops'."
  (cl-loop
   for round in (plist-get task :feedback)
   for index from 0
   append (harness-patch-review--reply-ops
           set index (let ((text (plist-get round :text))) (if (stringp text) text ""))
           (plist-get round :at)
           :split t :meta (list :round index :imported t))))

(defun harness-patch-review--import-rounds (set task)
  "Make the comments quoted in TASK's rounds of feedback closed threads of SET.
The rounds were kept as text before threads existed.  Each comment the
reply format finds in one is a thread of its own, written by the user at
the time the round was sent, closed, against the commit the round names
when it does.  A comment that answers a quote of the agent's words keeps
the quote above its text.  The ids follow from the task, the round and the
place of the comment in it, so a round imported twice adds nothing."
  (dolist (op (harness-patch-review--round-ops set task))
    (change-review-apply set op t)))

;;;; The words by hand

(defun harness-patch-review--typed-nodes (task)
  "Return the messages the user typed in the session of TASK that are no round.
Nodes of the session's transcript, oldest first: the user's own, not the
harness's or another session's agent's, and not the task's prompt.  What
a round of feedback opens with (`harness-tasks--reject-message') marks the
rounds, which the task keeps by themselves."
  (let ((session (plist-get task :session))
        (prompt (string-trim (let ((prompt (plist-get task :prompt))) (if (stringp prompt) prompt ""))))
        (headers (delq nil (list (and (boundp 'harness-tasks--reject-message) harness-tasks--reject-message)
                                 (and (boundp 'harness-tasks--sent-back-message) harness-tasks--sent-back-message)
                                 (and (boundp 'harness-tasks--aside-message) harness-tasks--aside-message)))))
    (when (and (stringp session) (harness-method-exists-p 'session/nodes))
      (cl-remove-if-not
       (lambda (node)
         (let ((text (plist-get node :content)))
           (and (member (plist-get node :kind) '(user "user"))
                (null (harness-node-sender node))
                (stringp text)
                (not (string-blank-p text))
                (not (equal (string-trim text) prompt))
                (not (cl-some (lambda (header) (string-prefix-p header text)) headers)))))
       (condition-case nil (harness-call 'session/nodes session) (error nil))))))

(defun harness-patch-review--manual-ops (set task)
  "Return the operations that make TASK's words by hand closed threads of SET.
Two kinds of words: the replies under a quote of the agent's own words in
a round of feedback, whole -- an import that left the quote out gets it
now -- and the replies of that kind in the messages the user typed in the
session that were no round (`harness-patch-review--typed-nodes'), which
no round holds.  Each is a closed thread; what SET has is not made again."
  (append
   (harness-patch-review--round-ops set task)
   (cl-loop
    for node in (harness-patch-review--typed-nodes task)
    append (harness-patch-review--reply-ops
            set (format "message %s" (plist-get node :id)) (plist-get node :content)
            (plist-get node :ts)
            :quoted-only t
            :meta (list :imported t :manual t :node (plist-get node :id))))))

(defun harness-patch-review--perform (set ops)
  "Perform OPS on SET as the operations of a UI are; return those that changed it.
Each is kept and announced (`patch-review/changed')."
  (let (done)
    (dolist (op ops)
      (when (change-review-dispatch set op)
        (push op done)))
    (nreverse done)))

(defun harness-patch-review--set-for (id &optional create)
  "Return the set of task ID, read from the store; with CREATE, made if none.
A set made for a task that was sent back before threads existed starts
with the comments of its rounds of feedback."
  (or (gethash id harness-patch-review--sets)
      (let ((set (or (when-let* ((data (and (harness-method-exists-p 'store/load)
                                            (harness-call 'store/load
                                                          (harness-patch-review--store-name id)))))
                       (change-review-set-from-data data (harness-patch-review--make-set :id id)))
                     (when create
                       (let* ((task (harness-patch-review--task id))
                              (set (harness-patch-review--make-set
                                    :id id :title (harness-patch-review--task-title task))))
                         (harness-patch-review--import-rounds set task)
                         (harness-patch-review--save set)
                         set)))))
        (when set (puthash id set harness-patch-review--sets))
        set)))

;;;; Threads started in the chat

;; The compose box's C-c > starts a thread on purpose: it records where the
;; region the reply answers is from -- a part of a message, several
;; messages, lines of a diff -- and the reply goes out as a text block with
;; that thread's data (`harness-thread-block').  In a task's session that
;; is a comment in a thread of the task's review, made when the message is
;; sent: the `agent/message' filter below makes one of each block that has
;; the data and no thread yet, and nothing is read out of the words.  A
;; reference to a comment of the agent's in a thread (a `review_comment'
;; call) or to an earlier reply of the user's in one makes the reply a
;; comment in that thread, which is how the replies of a conversation stay
;; together, and a close does not keep it from opening again: the user is
;; the one to say a point is done.  A reference to lines of a diff puts the
;; thread on those lines, at the revision, as a comment made in the review
;; is.  Any other starts a thread on the change as a whole, and keeps the
;; references in its comment's meta.
;;
;; The block that goes on, and is recorded, has the thread's id
;; (`:thread'), and its text ends with the marker line
;; (`harness-thread-marker'), which tells the agent the thread to answer in,
;; with the tool that answers it, and the code that turns typed words into
;; threads that this one is made.

(defun harness-patch-review--kind (node)
  "Return the kind of NODE, a transcript node, as a string."
  (let ((kind (plist-get node :kind)))
    (if (symbolp kind) (symbol-name kind) kind)))

(defun harness-patch-review--lines (text)
  "Return the lines of TEXT, each as (FROM TO LINE).
FROM and TO are where it starts and ends in TEXT, LINE what it says."
  (let ((pos 0) lines)
    (dolist (line (split-string text "\n"))
      (let ((to (+ pos (length line))))
        (push (list pos to line) lines)
        (setq pos (1+ to))))
    (nreverse lines)))

(defun harness-patch-review--quote-line-p (line)
  "Non-nil when LINE is a line of a Markdown quote: it starts with \">\"."
  (string-match-p "\\`[ \t]*>" line))

(defun harness-patch-review--segments (text)
  "Return the quotes of TEXT with the answers under them, in order.
A quote is the lines that start with \">\" -- several parts of one, with
only blank lines between, are one -- and its answer the lines after it
that are no quote, up to the next quote.  Text before the first quote
answers nothing, and a quote with nothing under it is no reply.  Each
segment is a plist: `:from' where its first line starts, `:to' where its
answer ends, `:quote' the lines of the quote as written, `:answer' the
answer's text, trimmed."
  (let ((segments nil) (quote nil) (from nil) (answer-from nil) (answer-to nil))
    (cl-flet ((finish ()
                (when (and quote answer-from)
                  (push (list :from from :to answer-to :quote (nreverse quote)
                              :answer (string-trim (substring text answer-from answer-to)))
                        segments))
                (setq quote nil from nil answer-from nil answer-to nil)))
      (dolist (entry (harness-patch-review--lines text))
        (pcase-let ((`(,start ,end ,line) entry))
          (cond
           ((harness-patch-review--quote-line-p line)
            (when answer-from (finish))
            (unless quote (setq from start))
            (push line quote))
           ((and quote (not (string-blank-p line)))
            (unless answer-from (setq answer-from start))
            (setq answer-to end)))))
      (finish))
    (nreverse segments)))

(defun harness-patch-review--call-comment (set call-id)
  "Return (THREAD . COMMENT) for the comment of SET that CALL-ID made, or nil.
CALL-ID is the id of a tool call: the author of its comment records it."
  (when (stringp call-id)
    (cl-loop for thread in (change-review-set-threads set)
             for comment = (cl-find-if
                            (lambda (comment)
                              (when-let* ((author (change-review-comment-author comment)))
                                (equal (change-review-author-tool-call author) call-id)))
                            (change-review-thread-comments thread))
             when comment return (cons thread comment))))

(defun harness-patch-review--ref-parent (set session-id ref)
  "Return (THREAD . COMMENT) of SET that the chat reference REF is, or nil.
REF is a region of a node of SESSION-ID's transcript: when that node is a
`review_comment' call of the agent's, or an earlier reply of the user's
that is a comment in a thread, the comment is what the reply follows."
  (when (and (equal (harness-thread-ref-kind ref) "chat") (stringp (plist-get ref :node)))
    (when-let* ((node (condition-case nil
                          (harness-call 'session/node session-id (plist-get ref :node))
                        (error nil))))
      (pcase (harness-patch-review--kind node)
        ("tool-call" (and (equal (plist-get node :tool) "review_comment")
                          (harness-patch-review--call-comment set (plist-get node :call-id))))
        ("user" (cl-some (lambda (block)
                           (when-let* (((harness-thread-block-p block))
                                       (id (plist-get (plist-get block :thread) :comment)))
                             (change-review-find-comment set id)))
                         (plist-get node :blocks)))))))

(defun harness-patch-review--thread-body (data)
  "Return what the comment of the thread DATA says: the quotes, then the response.
The lines of a diff the thread is on are its location, which the review
shows with the thread: only the words a person would not find there are
quoted."
  (let ((quoted (cl-remove-if (lambda (ref) (equal (harness-thread-ref-kind ref) "diff"))
                              (harness-thread-refs data))))
    (harness-thread-text (list :refs quoted :response (plist-get data :response)))))

(defun harness-patch-review--thread-location (data)
  "Return the location in the diff the thread DATA is on, or nil.
That is where its first reference to lines of a diff is."
  (when-let* ((ref (cl-find-if (lambda (ref) (equal (harness-thread-ref-kind ref) "diff"))
                               (harness-thread-refs data)))
              (file (plist-get ref :file)))
    (change-review-make-location
     :file file
     :side (if (equal (format "%s" (plist-get ref :side)) "old") 'old 'new)
     :line (plist-get ref :line) :end-line (plist-get ref :end)
     :excerpt (plist-get ref :text))))

(defun harness-patch-review--register-thread (set session-id data)
  "Make the reply in the thread DATA a comment of SET; return DATA with its ids.
SESSION-ID is the session the reply is sent in.  The comment is the
user's, sent, and has the quotes of the references above the response
\(`harness-patch-review--thread-body').  A reference to a comment in a
thread makes it a reply in that thread, which a close does not keep
from opening again, and a reference to lines of a diff puts a new thread
on them, at the revision the reference names; the references stay in the
comment's meta.  A reply that is a comment already, put back into the
box and sent again, edits the comment instead of making another."
  (let* ((now (float-time))
         (author (harness-patch-review--user))
         (body (harness-patch-review--thread-body data))
         (have (and (plist-get data :comment) (cdr (change-review-find-comment set (plist-get data :comment)))))
         (parent (cl-some (lambda (ref) (harness-patch-review--ref-parent set session-id ref))
                          (harness-thread-refs data)))
         (comment
          (if have
              (progn
                (unless (equal (change-review-comment-body have) body)
                  (change-review-dispatch set (list :op 'edit-comment :comment (change-review-comment-id have)
                                                    :body body :time now)))
                have)
            (change-review-comment
             set body
             :thread (car parent) :reply-to (cdr parent)
             :author author :time now :sent now
             :revision (cl-some (lambda (ref) (plist-get ref :revision)) (harness-thread-refs data))
             :location (and (null parent) (harness-patch-review--thread-location data))
             :meta (list :chat t :session session-id :refs (harness-thread-refs data)))))
         (thread (car (change-review-find-comment set (change-review-comment-id comment)))))
    (when (and thread (not (change-review-thread-open-p thread)))
      (change-review-update-status set thread 'open :author author :time (+ now 0.001)))
    (harness-thread-normalize
     (append (cl-loop for (key value) on data by #'cddr
                      unless (memq key '(:id :comment)) append (list key value))
             (list :id (change-review-thread-id thread) :comment (change-review-comment-id comment))))))

(defun harness-patch-review--answerable-p (session-id)
  "Non-nil when the agent of SESSION-ID has the tool that answers a thread."
  (and (harness-method-exists-p 'tools/list)
       (cl-some (lambda (spec) (equal (plist-get spec :name) "review_comment"))
                (ignore-errors (harness-call 'tools/list session-id)))))

(defun harness-patch-review--new-thread-p (block)
  "Non-nil when BLOCK is a reply in a thread the review has not made yet."
  (and (harness-thread-block-p block)
       (null (plist-get (plist-get block :thread) :id))))

(defun harness-patch-review--new-thread-attachment-p (attachment)
  "Non-nil when ATTACHMENT is a reply in a thread the review has not made yet.
An attachment of the feedback that sends a task back: `:thread' is the
thread's data and `:response' the words under it."
  (and (consp attachment) (plist-get attachment :thread)
       (null (plist-get (plist-get attachment :thread) :id))))

(defun harness-patch-review--register-blocks (set session-id blocks)
  "Return BLOCKS with each reply in a new thread made a comment of SET.
SESSION-ID is the session the message is sent in.  A block that goes on
has its thread's id and ends with the marker of the thread."
  (mapcar (lambda (block)
            (if (harness-patch-review--new-thread-p block)
                (harness-thread-block
                 (harness-patch-review--register-thread set session-id (plist-get block :thread)))
              block))
          blocks))

(defun harness-patch-review--on-message (blocks session-id info)
  "Make the replies in threads of the user's message BLOCKS comments of a review.
An `agent/message' filter, INFO being (:from FROM ...): only the user's
own messages count, in the session of a task whose agent has
`review_comment', the tool that answers a thread.  The harness's own
messages and another session's agent's are no replies.  Each block with
thread data (`harness-thread-block') and no thread yet becomes a comment
\(`harness-patch-review--register-thread'), and the block that goes on
has the thread's id and ends with its marker.  It runs before the tasks
module reads a message to a task in review as the feedback that sends it
back, which then carries the markers.  A message the review cannot take
is left as it was, and so is one that fails."
  (if (or (harness-sender-kind (plist-get info :from))
          (not (cl-some #'harness-patch-review--new-thread-p blocks)))
      blocks
    (condition-case err
        (let ((task-id (and (harness-method-exists-p 'task/for-session)
                            (plist-get (harness-call 'task/for-session session-id) :id))))
          (if (not (and task-id (harness-patch-review--answerable-p session-id)))
              blocks
            (harness-patch-review--register-blocks
             (harness-patch-review--set-for task-id t) session-id blocks)))
      (error (harness-log 'warn "patch-review: the threads of a message in %s were not made: %s"
                          session-id (harness-error-message err))
             blocks))))

(defun harness-patch-review--on-feedback-attachments (attachments task)
  "Make the replies in threads among ATTACHMENTS comments of TASK's review.
A `task/feedback-attachments' filter: ATTACHMENTS are those of the
feedback that sends the task back (`task/reject'), an attachment with
`:thread', the thread's data (`harness-thread-block'), and `:response',
the words written under it.  Return ATTACHMENTS, each such reply with the
thread's data now carrying its thread's id and its comment's: the round of
feedback is kept after that, and a message kept for a slot goes out with
the threads it made.  They come back as they were when the task's agent
cannot answer a thread (it has no `review_comment'), and replies that
have their thread already are left alone."
  (let ((session-id (plist-get task :session)))
    (if (not (and (stringp session-id)
                  (cl-some #'harness-patch-review--new-thread-attachment-p attachments)
                  (harness-patch-review--answerable-p session-id)))
        attachments
      (let ((set (harness-patch-review--set-for (plist-get task :id) t)))
        (mapcar (lambda (attachment)
                  (if (harness-patch-review--new-thread-attachment-p attachment)
                      (plist-put (copy-sequence attachment) :thread
                                 (harness-patch-review--register-thread
                                  set session-id
                                  (plist-put (copy-sequence (plist-get attachment :thread))
                                             :response (plist-get attachment :response))))
                    attachment))
                attachments)))))

(defun harness-patch-review--unregistered (text)
  "Return TEXT, trimmed, without the replies the review keeps already.
Those are the quotes and answers that end with a marker line
\(`harness-thread-marker'), threads started in the chat.  What is left,
the words that made none, has the blank lines they leave collapsed.  A
TEXT with no such reply is returned as it is, trimmed."
  (let ((text (or text "")) (cut nil))
    (dolist (segment (reverse (harness-patch-review--segments text)))
      (when (harness-thread-marker-ids (plist-get segment :answer))
        (setq cut t
              text (concat (substring text 0 (plist-get segment :from))
                           (substring text (plist-get segment :to))))))
    (string-trim (if cut
                     (replace-regexp-in-string "\n\\(?:[ \t]*\n\\)\\{2,\\}" "\n\n" text)
                   text))))

;;;; The versions

(defun harness-patch-review--git (dir &rest args)
  "Return a promise of what git, run in DIR with ARGS, writes, trimmed.
It rejects when git fails."
  (harness-then
   (harness-run-command (append '("git" "--no-pager") args) :cwd dir :timeout 60
                        :name "harness-patch-review"
                        :env '(("GIT_OPTIONAL_LOCKS" . "0")))
   (lambda (result)
     (if (eql (plist-get result :exit) 0)
         (string-trim (or (plist-get result :stdout) ""))
       (harness-rejected (list 'error (format "git %s failed: %s" (car args)
                                              (harness-first-line (or (plist-get result :stderr) "") 120))))))))

(defun harness-patch-review--repository (task)
  "Return the directory TASK's branch can be read in, or nil."
  (cl-loop for dir in (list (plist-get task :project) (plist-get task :worktree))
           when (and (stringp dir) (not (string-empty-p dir))
                     (not (file-remote-p dir)) (file-directory-p dir))
           return dir))

(defun harness-patch-review--merge-base (dir base tip)
  "Return a promise of the commit TIP and BASE, a branch, have in common in DIR.
BASE that is blank or no longer there is what DIR has checked out."
  (harness-catch
   (if (and (stringp base) (not (string-empty-p base)))
       (harness-catch (harness-patch-review--git dir "merge-base" base tip)
                      (lambda (_) (harness-patch-review--git dir "merge-base" "HEAD" tip)))
     (harness-patch-review--git dir "merge-base" "HEAD" tip))
   (lambda (_) (harness-resolved nil))))

(defun harness-patch-review--version-op (task tip merge-base)
  "Return the operation that adds the version of TASK that ends at TIP.
MERGE-BASE is the commit its branch was made from, or nil."
  (let* ((report (plist-get task :report))
         (summary (plist-get report :summary))
         (round (length (plist-get task :feedback))))
    (list :op 'add-version
          :version (change-review-version-to-data
                    (change-review-make-version
                     :id tip :tip tip :base merge-base
                     :time (or (plist-get task :report-at) (plist-get report :at) (float-time))
                     :title (harness-patch-review--task-title task)
                     :description (and (stringp summary) (not (string-blank-p summary))
                                       (harness-truncate-end summary 4000))
                     :author (harness-patch-review--agent (plist-get task :session)
                                                          (plist-get report :call-id))
                     :meta (list :round round :branch (plist-get task :branch)
                                 :base-branch (plist-get task :base)))))))

(defun harness-patch-review--record-version (task)
  "Record the version TASK handed in: where its branch ends now.
Read in the task's repository.  Return a promise of the set, or nil
when the task has no branch of its own or its repository is not here."
  (let ((dir (harness-patch-review--repository task))
        (branch (plist-get task :branch)))
    (when (and dir (stringp branch) (not (string-blank-p branch)))
      (harness-catch
       (harness-then
        (harness-patch-review--git dir "rev-parse" "--verify" "--quiet" (concat branch "^{commit}"))
        (lambda (tip)
          (harness-then
           (harness-patch-review--merge-base dir (plist-get task :base) tip)
           (lambda (merge-base)
             (let ((set (harness-patch-review--set-for (plist-get task :id) t)))
               (change-review-dispatch set (harness-patch-review--version-op task tip merge-base))
               set)))))
       (lambda (err)
         (harness-log 'info "patch-review: no version recorded for %s: %s"
                      (plist-get task :id) (harness-error-message err))
         (harness-resolved nil))))))

(defun harness-patch-review--on-review (task)
  "Record the version of TASK, which comes to review: the work handed in."
  (when (and (plist-get task :id) (harness-patch-review--repository task))
    (harness-patch-review--record-version task)))

;;;; The files viewed

(defun harness-patch-review--viewed-name (id)
  "Return the name of the document that keeps the files viewed in task ID's review."
  (format "patch-review-viewed/%s.json" (replace-regexp-in-string "[^A-Za-z0-9._-]" "_" id)))

(defun harness-patch-review--viewed-entries (value)
  "Return VALUE, files as the store keeps them, as (:path PATH [:blob BLOB]).
What is no file, or has no path, is left out; a file the branch deletes
has no blob."
  (cl-loop for entry in (append value nil)
           for path = (and (consp entry) (plist-get entry :path))
           for blob = (and (consp entry) (plist-get entry :blob))
           when (and (stringp path) (not (string-empty-p path)))
           collect (if (and (stringp blob) (not (string-empty-p blob)))
                       (list :path path :blob blob)
                     (list :path path))))

(defun harness-patch-review--viewed-key (entry)
  "Return what names the file ENTRY stands for: its path and its blob."
  (cons (plist-get entry :path) (plist-get entry :blob)))

(defun harness-patch-review--viewed-change (entries files on)
  "Return ENTRIES with FILES added, or taken away when ON is nil.
Each of them is (:path PATH [:blob BLOB]); the order of ENTRIES is kept,
the files added come after."
  (let ((keys (make-hash-table :test 'equal))
        (files (harness-patch-review--viewed-entries files)))
    (if on
        (progn (dolist (entry entries) (puthash (harness-patch-review--viewed-key entry) t keys))
               (append entries
                       (cl-remove-if (lambda (entry)
                                       (let ((key (harness-patch-review--viewed-key entry)))
                                         (prog1 (gethash key keys) (puthash key t keys))))
                                     files)))
      (dolist (entry files) (puthash (harness-patch-review--viewed-key entry) t keys))
      (cl-remove-if (lambda (entry) (gethash (harness-patch-review--viewed-key entry) keys)) entries))))

(defun harness-patch-review--viewed-data (id)
  "Return the files viewed in task ID's review, as kept: nil when none were.
A plist of :seen and :approved, lists of (:path PATH [:blob BLOB]), and
:assumed, what `harness-patch-review--assume' recorded, if it did."
  (when-let* ((data (and (harness-method-exists-p 'store/load)
                         (harness-call 'store/load (harness-patch-review--viewed-name id)))))
    (list :seen (harness-patch-review--viewed-entries (plist-get data :seen))
          :approved (harness-patch-review--viewed-entries (plist-get data :approved))
          :assumed (plist-get data :assumed))))

(defun harness-patch-review--viewed-save (id data)
  "Keep DATA for task ID's review, as `harness-patch-review--viewed-data' has it."
  (when (harness-method-exists-p 'store/save)
    (harness-call 'store/save (harness-patch-review--viewed-name id)
                  (append (list :format 1 :task id
                                :seen (harness-json-array (plist-get data :seen))
                                :approved (harness-json-array (plist-get data :approved)))
                          (and (plist-get data :assumed) (list :assumed (plist-get data :assumed)))))))

(defun harness-patch-review--raw-files (raw)
  "Return the files RAW, what `git diff --raw -z' wrote, names, in order.
Each is (:path PATH :blob BLOB): the path the file has after the change
\(a renamed file's new one) and its blob there, nil for a deleted file."
  (let ((fields (split-string raw "\0" t))
        files)
    (while fields
      (let ((head (pop fields)))
        (when (string-match "\\`:[0-7]+ [0-7]+ [0-9a-f]+ \\([0-9a-f]+\\) \\([A-Z]\\)" head)
          (let* ((blob (match-string 1 head))
                 (status (match-string 2 head))
                 (first (pop fields))
                 (second (and (member status '("R" "C")) (pop fields))))
            (push (list :path (or second first)
                        :blob (and (not (string-match-p "\\`0+\\'" blob)) blob))
                  files)))))
    (nreverse files)))

(defun harness-patch-review--assume (task-id revision)
  "Return a promise of the files task TASK-ID's review takes as viewed.
They are all of its newest version's but those changed from REVISION on.
REVISION is a commit of the task's branch, by default the one before its
newest version's tip: every file of the version is viewed but those the
branch changed since, that is, from REVISION on.  The files already
viewed are replaced by these, and the files approved stay.  The promise
resolves to (:seen N :unviewed M :revision COMMIT :tip COMMIT)."
  (let* ((task (harness-patch-review--task task-id))
         (dir (harness-patch-review--repository task))
         (set (and dir (harness-patch-review--set-for task-id t)))
         (version (and set (change-review-latest-version set)))
         (branch (plist-get task :branch)))
    (harness-then
     (cond
      ((null dir)
       (harness-rejected (list 'error "The repository of this task is not on this machine")))
      ((and version (change-review-version-tip version))
       (harness-resolved (change-review-version-tip version)))
      ((harness-string-blank-p branch)
       (harness-rejected (list 'error "The task has no branch of its own")))
      (t (harness-patch-review--git dir "rev-parse" "--verify" "--quiet" (concat branch "^{commit}"))))
     (lambda (tip)
       (harness-then
        (harness-all (list (harness-patch-review--merge-base dir (plist-get task :base) tip)
                           (let ((name (or revision (concat tip "^"))))
                             (harness-catch
                              (harness-patch-review--git dir "rev-parse" "--verify" "--quiet"
                                                         (concat name "^{commit}"))
                              (lambda (_)
                                (harness-rejected
                                 (list 'error (format "There is no commit %s in the repository of the task" name))))))))
        (lambda (found)
          (let ((merge-base (nth 0 found))
                (since (nth 1 found)))
            (cond
             ((null merge-base)
              (harness-rejected (list 'error "The branch has no commit in common with its base")))
             (t
              (harness-then
               (harness-all
                (list (harness-patch-review--git dir "diff" "--raw" "-z" "-M" "--no-abbrev" merge-base tip)
                      (harness-patch-review--git dir "diff" "--raw" "-z" "--no-abbrev" "--no-renames" since tip)))
               (lambda (outputs)
                 (let* ((files (harness-patch-review--raw-files (nth 0 outputs)))
                        (changed (make-hash-table :test 'equal))
                        (viewed (progn
                                  (dolist (file (harness-patch-review--raw-files (nth 1 outputs)))
                                    (puthash (plist-get file :path) t changed))
                                  (harness-patch-review--viewed-entries
                                   (cl-remove-if (lambda (file) (gethash (plist-get file :path) changed))
                                                 files)))))
                   (harness-patch-review--viewed-save
                    task-id
                    (list :seen viewed
                          :approved (plist-get (harness-patch-review--viewed-data task-id) :approved)
                          :assumed (list :revision since :tip tip :time (float-time))))
                   (list :seen (length viewed) :unviewed (- (length files) (length viewed))
                         :revision since :tip tip)))))))))))))

(defun harness-patch-review--viewed (task-id)
  "Return the files viewed in task TASK-ID's review: what was kept, else none.
A plist of :seen and :approved, lists of (:path PATH [:blob BLOB]), and
:assumed when files were taken as viewed and not looked at."
  (or (harness-patch-review--viewed-data task-id)
      (list :seen nil :approved nil)))

;;;; Methods

(harness-defmethod patch-review/get (task-id)
  "Return the review of task TASK-ID as plain data: its versions and threads.
The data is that of `change-review-set-to-data', without the versions'
files: the UI reads those from the repository.  The set is made when
the task has none yet, with the comments of the task's earlier rounds
of feedback as closed threads."
  (let ((set (harness-patch-review--set-for task-id t)))
    (change-review-set-to-data set nil)))

(harness-defmethod patch-review/apply (task-id op)
  "Perform OP, an operation of change-review, on the review of task TASK-ID.
The UI sends the operations the user makes: `add-comment', `set-status',
`edit-comment', `delete-comment', `add-version', and `mark-reviewed' and
`unmark-reviewed' for a close by the agent the user has looked at, or
no longer has.  Return (:changed BOOL).  `patch-review/changed' announces
what changed to every UI, so that each performs it on its own copy."
  (let ((kind (let ((value (plist-get op :op)))
                (cond ((symbolp value) value)
                      ((stringp value) (intern value))))))
    (unless (memq kind '(add-comment set-status edit-comment delete-comment add-version
                                     mark-reviewed unmark-reviewed))
      (signal 'harness-error (list (format "The review does not take %S operations from a UI" kind))))
    (let ((set (harness-patch-review--set-for task-id t)))
      (list :changed (and (change-review-dispatch set op) t)))))

(harness-defmethod patch-review/threads-text (task-id &optional status)
  "Return the threads of task TASK-ID's review as text for its agent.
STATUS is \"open\", \"closed\" or nil for all.  Only the comments sent are
in it: the drafts are the user's until they send the task back."
  (harness-patch-review-threads-text
   (harness-patch-review--set-for task-id t)
   (and (stringp status) (member status '("open" "closed")) (intern status))))

(harness-defmethod review/find-thread (task-id ref)
  "Return the thread of task TASK-ID's review that REF names, or nil.
REF is a thread's id, or the start of one, three characters or more, that
no other thread's id starts with.  A plist: `:id', the thread's id,
`:status', \"open\" or \"closed\", `:where', the file and line it is on or
\"the change as a whole\", and `:comments', how many it holds.  The linking
module finds what a link to a thread names with it.  Nothing is made: a
task with no review has no thread.  Signal an error naming the threads
when REF starts the ids of several."
  (when-let* (((stringp ref))
              (set (harness-patch-review--set-for task-id)))
    (let* ((ref (string-trim ref))
           (threads (change-review-set-threads set))
           (exact (cl-find ref threads :key #'change-review-thread-id :test #'equal))
           (starts (and (not exact) (>= (length ref) 3)
                        (cl-remove-if-not (lambda (thread) (string-prefix-p ref (change-review-thread-id thread)))
                                          threads)))
           (thread (or exact (car starts))))
      (when (cdr starts)
        (signal 'harness-error
                (list (format "%s starts the ids of %d threads (%s); give more of it" ref (length starts)
                              (mapconcat #'change-review-thread-id starts ", ")))))
      (when thread
        (list :id (change-review-thread-id thread)
              :status (if (change-review-thread-open-p thread) "open" "closed")
              :where (harness-patch-review--where thread)
              :comments (length (change-review-thread-comments thread)))))))

(harness-defmethod patch-review/drafts (task-id)
  "Return the draft comments of task TASK-ID's review, those not sent yet, as data."
  (when-let* ((set (harness-patch-review--set-for task-id)))
    (mapcar #'change-review-comment-to-data (change-review-drafts set))))

(defun harness-patch-review--excerpt (body)
  "Return the start of what BODY, a comment's text, says, as one line.
A reply made in the chat has the quote it answers above its answer: the
line is the answer's first, else the quote's with its \">\" left off."
  (let* ((lines (split-string (string-trim body) "\n"))
         (answer (cl-find-if (lambda (line)
                               (and (not (string-blank-p line))
                                    (not (harness-patch-review--quote-line-p line))))
                             lines)))
    (harness-first-line (string-trim (or answer
                                         (replace-regexp-in-string "\\`[ \t>]+" "" (or (car lines) ""))))
                        100)))

(defun harness-patch-review--parent-data (comment)
  "Return what a UI says of COMMENT, the one an answer follows, as plain data.
\(:id ID :author NAME :kind KIND :excerpt LINE): who wrote it, the
kind of author (\"user\", \"agent\") and the start of what it says
\(`harness-patch-review--excerpt').  Nil for no comment."
  (when comment
    (let ((author (change-review-comment-author comment)))
      (list :id (change-review-comment-id comment)
            :author (change-review-author-label author)
            :kind (and author (symbol-name (change-review-author-kind author)))
            :excerpt (harness-patch-review--excerpt (change-review-comment-body comment))))))

(harness-defmethod patch-review/comment (task-id body &rest opts)
  "Add the agent's comment BODY to the review of task TASK-ID.
Return (:thread ID :status STATUS :comment DATA :parent PARENT), DATA
being the comment as plain data, or nil when only the status changed;
PARENT says which comment it follows in its thread, the one before it
\(`harness-patch-review--parent-data'), nil when it starts the thread.
OPTS: `:thread' answers that thread (an id, or a prefix of one that is
unique), else the comment starts a thread; `:status' closes or opens
the thread afterwards; `:session' and `:call-id' say which session and
tool call wrote it; `:file', `:line' and `:side' say where in the change
a new thread is; `:revision' the commit the agent was at.  With no BODY
`:status' alone changes the thread's status.  Signal an error naming
the threads there are when `:thread' names none."
  (let* ((set (harness-patch-review--set-for task-id t))
         (thread (and (plist-get opts :thread)
                      (or (change-review-find-thread set (plist-get opts :thread))
                          (signal 'harness-error
                                  (list (format "No thread %s in this review; threads: %s"
                                                (plist-get opts :thread)
                                                (mapconcat (lambda (th) (change-review-thread-id th))
                                                           (change-review-set-threads set) ", ")))))))
         (author (harness-patch-review--agent (plist-get opts :session) (plist-get opts :call-id)))
         (status (let ((value (plist-get opts :status)))
                   (and value (intern (format "%s" value)))))
         (time (float-time))
         ;; The comment the new one follows: the newest of the thread there is.
         (parent (and thread (harness-patch-review--parent-data
                              (change-review-thread-last-comment thread))))
         comment)
    (when (and status (not (memq status '(open closed))))
      (signal 'harness-error (list "A thread's status is open or closed")))
    (when (and (harness-string-blank-p body) (not (and thread status)))
      (signal 'harness-error (list "A comment needs text; to only open or close a thread, name the thread and a status")))
    (unless (harness-string-blank-p body)
      (setq comment
            (change-review-comment
             set (string-trim body)
             :thread thread :author author :time time :sent time
             :revision (or (plist-get opts :revision)
                           (when-let* ((version (change-review-latest-version set)))
                             (change-review-version-id version)))
             :location (and (not thread) (plist-get opts :file)
                            (change-review-make-location
                             :file (plist-get opts :file)
                             :side (if (member (format "%s" (plist-get opts :side)) '("old" "before")) 'old 'new)
                             :line (plist-get opts :line))))))
    (when (and status (or thread comment))
      (change-review-update-status
       set (or thread (change-review-comment-thread comment)) status
       :author author :time (+ time 0.001)))
    (let ((thread (or thread (change-review-find-thread set (change-review-comment-thread comment)))))
      (list :thread (change-review-thread-id thread)
            :status (symbol-name (change-review-thread-status thread))
            :comment (and comment (change-review-comment-to-data comment))
            :parent parent))))

(harness-defmethod patch-review/import-manual (task-id)
  "Make the user's words by hand in task TASK-ID's session threads of its review.
Replies written inline, under a quote of the agent's own words, that no
thread holds yet: the ones in the task's rounds of feedback, whole -- a
quote an earlier import left out is put back -- and the ones the user
typed in its session that were no round, such as an answer to the agent
while it worked.  They are closed threads, written by the user when they
were typed; what the review has is not made again, so this can be asked
for twice.  Return (:added N :edited M :threads IDS): the comments
added, the comments given their quote, the threads made."
  (let* ((task (harness-patch-review--task task-id))
         (set (harness-patch-review--set-for task-id t))
         (done (harness-patch-review--perform set (harness-patch-review--manual-ops set task)))
         (added (cl-remove-if-not (lambda (op) (eq (plist-get op :op) 'add-comment)) done)))
    (list :added (length added)
          :edited (length (cl-remove-if-not (lambda (op) (eq (plist-get op :op) 'edit-comment)) done))
          :threads (mapcar (lambda (op) (plist-get op :thread)) added))))

(harness-defmethod patch-review/viewed (task-id)
  "Return the files viewed, and approved, in task TASK-ID's review.
\(:seen FILES :approved FILES :assumed WHY).  FILES are (:path PATH :blob
BLOB), the blob the file has on the branch, none for a file it deletes: a
file the branch changes again is a file not viewed.  WHY, when there is
one, says the files were taken as viewed and not looked at
\(`patch-review/assume-viewed'): (:revision COMMIT :tip COMMIT :time TIME)."
  (harness-patch-review--task task-id)
  (harness-patch-review--viewed task-id))

(harness-defmethod patch-review/set-viewed (task-id kind files on)
  "Mark FILES viewed in task TASK-ID's review, or approved, or take the mark off.
KIND is \"seen\" or \"approved\"; FILES are (:path PATH :blob BLOB), as
`patch-review/viewed' gives them; ON is true to mark them, false to
take the mark off.  Approving a file views it too, and a file no longer
viewed is no longer approved.  Return (:seen N :approved M), how many
files each mark holds."
  (harness-patch-review--task task-id)
  (let* ((kind (pcase (format "%s" kind)
                 ("seen" 'seen)
                 ("approved" 'approved)
                 (_ (signal 'harness-error (list "A mark is \"seen\" or \"approved\"")))))
         (on (harness-json-true-p on))
         (data (harness-patch-review--viewed task-id))
         (seen (plist-get data :seen))
         (approved (plist-get data :approved)))
    (pcase kind
      ('seen (setq seen (harness-patch-review--viewed-change seen files on))
             (unless on (setq approved (harness-patch-review--viewed-change approved files nil))))
      ('approved (setq approved (harness-patch-review--viewed-change approved files on))
                 (when on (setq seen (harness-patch-review--viewed-change seen files t)))))
    (harness-patch-review--viewed-save
     task-id (list :seen seen :approved approved :assumed (plist-get data :assumed)))
    (list :seen (length seen) :approved (length approved))))

(harness-defmethod patch-review/assume-viewed (task-id &optional revision)
  "Take every file of task TASK-ID's review as viewed, but those changed lately.
Those changed from REVISION on stay to view.  REVISION is a commit of the
branch, by default the one before the newest version's tip: only the files
the newest commit changed are left to view.  For a review the reviewer
went through before the marks were kept.  The files viewed so far are
replaced; the files approved stay.
Return a promise of (:seen N :unviewed M :revision COMMIT :tip COMMIT)."
  (harness-patch-review--task task-id)
  (harness-patch-review--assume task-id
                                (and (stringp revision) (not (string-blank-p revision)) revision)))

;;;; The drafts go with the feedback

(defun harness-patch-review--attribution (task set)
  "Return the line before the first quote of the drafts of TASK's review in SET."
  (let ((version (change-review-latest-version set)))
    (format "My review comments on your branch %s%s%s. Each is quoted from the diff, with my comment under the lines it is about; [thread ...] names the thread it belongs to. Answer a thread with the review_comment tool, giving its id, and close it (status \"closed\") once what it raises is done: a thread left open is not done. I look at every thread you close, so say in your answer what you changed and where."
            (or (plist-get task :branch) "")
            (if version (format " (at %s)" (change-review-short-revision (change-review-version-tip version))) "")
            (if (and version (change-review-version-base version))
                (format " against %s (merge base %s)"
                        (or (plist-get task :base) "its base")
                        (change-review-short-revision (change-review-version-base version)))
              ""))))

(defun harness-patch-review--render (task set drafts)
  "Return the text of DRAFTS, comments of TASK's review in SET, as feedback.
It opens with the line that says what the quotes are and how to answer
the threads, also when no comment is on a file and so quotes nothing."
  (let ((attribution (harness-patch-review--attribution task set))
        (text (change-review-mail-render-comments
               set drafts
               :attribution (harness-patch-review--attribution task set)
               :history t
               :markers (lambda (comment) (format "[thread %s]" (change-review-comment-thread comment))))))
    (if (string-search attribution text)
        text
      (concat attribution "\n\n" text))))

(defun harness-patch-review--additions (task words)
  "Return the drafts of TASK's review as text to add to its feedback, or nil.
On `harness-tasks-feedback-additions-functions'.  WORDS are what the user
sends the task back with.  The text is the drafts, if there are any,
quoted from the diff; a draft whose text is blank is no feedback and is
left out.  The function marks the drafts it sent once the task is sent
back, and keeps WORDS, if there are any, as a thread on the change as a
whole, sent: the review has a record of what each round said."
  (let* ((id (plist-get task :id))
         ;; The replies in threads started in the chat are threads already:
         ;; the tasks module leaves them out of WORDS (`harness-tasks--words').
         (words (and (stringp words) (not (string-blank-p words)) (string-trim words)))
         (set (harness-patch-review--set-for id (and words t)))
         (drafts (and set
                      (cl-remove-if (lambda (draft)
                                      (harness-string-blank-p (change-review-comment-body draft)))
                                    (change-review-drafts set)))))
    (when (or drafts words)
      (let ((round (length (plist-get task :feedback))))
        (cons (and drafts (harness-patch-review--render task set drafts))
              (lambda ()
                (let ((time (float-time)))
                  (when drafts
                    (change-review-mark-sent set drafts :time time :meta (list :round round)))
                  (when words
                    (change-review-comment set words :author (harness-patch-review--user)
                                           :time time :sent time
                                           :meta (list :round round :words t))))))))))

;;;; What the agent reads

(defun harness-patch-review--where (thread)
  "Return where THREAD is, for the agent to read."
  (let ((location (change-review-thread-location thread)))
    (if location (change-review-location-label location t) "the change as a whole")))

(defun harness-patch-review-threads-text (set &optional status)
  "Return the sent comments of SET's threads as text for the agent.
STATUS is `open', `closed' or nil for all.  A comment that is still a
draft is not shown: the user has not sent it."
  (let* ((seen (cl-remove-if-not
                (lambda (thread)
                  (cl-some (lambda (c) (not (change-review-comment-draft-p c)))
                           (change-review-thread-comments thread)))
                (change-review-set-threads set)))
         (threads (if status
                      (cl-remove-if-not (lambda (thread) (eq (change-review-thread-status thread) status)) seen)
                    seen)))
    (if (null threads)
        (format "No %sthreads in this review." (if status (format "%s " status) ""))
      (concat
       (format "%d open, %d closed.\n\n"
               (cl-count-if #'change-review-thread-open-p seen)
               (cl-count-if-not #'change-review-thread-open-p seen))
       (mapconcat
        (lambda (thread)
          (concat
           ;; The link is what the agent puts in a message to point at the thread.
           (format "[%s] %s · %s · %s\n" (change-review-thread-id thread)
                   (if (change-review-thread-open-p thread) "open" "closed")
                   (harness-patch-review--where thread)
                   (harness-links-thread-url (change-review-set-id set) (change-review-thread-id thread)))
           (mapconcat
            (lambda (comment)
              (let ((author (change-review-comment-author comment)))
                (format "  %s %s (%s): %s\n"
                        (change-review-comment-id comment)
                        (change-review-author-label author)
                        (change-review-author-kind author)
                        (string-replace "\n" "\n      " (change-review-comment-body comment)))))
            (cl-remove-if #'change-review-comment-draft-p (change-review-thread-comments thread))
            "")))
        threads "\n")))))

;;;; Events and the module

(harness-declare-event 'patch-review/changed
                       "(TASK-ID OP) after an operation changed the threads of a task's review: OP, to perform on a copy.")

(defun harness-patch-review--changed (set op)
  "Announce operation OP, which changed SET, if SET is a task's review.
On `change-review-changed-functions'."
  (when (harness-patch-review--set-p set)
    (harness-emit 'patch-review/changed (change-review-set-id set) op)))

(defun harness-patch-review--on-deleted (id)
  "Forget the review of task ID, which was deleted."
  (remhash id harness-patch-review--sets))

(defun harness-patch-review--init ()
  "Follow the tasks, and put the drafts in the feedback that sends one back.
The replies the user quotes the agent's words to make are comments of
the review (`harness-patch-review--on-message'), before the tasks module
reads a message to a task as the feedback that sends it back."
  (add-hook 'change-review-changed-functions #'harness-patch-review--changed)
  (harness-add-filter 'agent/message #'harness-patch-review--on-message 40)
  (harness-add-filter 'task/feedback-attachments #'harness-patch-review--on-feedback-attachments 40)
  (harness-on 'task/review #'harness-patch-review--on-review)
  (harness-on 'task/deleted #'harness-patch-review--on-deleted)
  (add-hook 'harness-tasks-feedback-additions-functions #'harness-patch-review--additions))

(defun harness-patch-review--shutdown ()
  "Stop following the tasks."
  (harness-remove-filter 'agent/message #'harness-patch-review--on-message)
  (harness-remove-filter 'task/feedback-attachments #'harness-patch-review--on-feedback-attachments)
  (remove-hook 'change-review-changed-functions #'harness-patch-review--changed)
  (remove-hook 'harness-tasks-feedback-additions-functions #'harness-patch-review--additions)
  (harness-off (cons 'task/review #'harness-patch-review--on-review))
  (harness-off (cons 'task/deleted #'harness-patch-review--on-deleted))
  (clrhash harness-patch-review--sets))

(harness-define-module 'patch-review
  :doc "The threads of a task's review: kept in the state directory, delivered with the feedback, answered by the agent."
  :requires '(store tasks tools-review)
  :init #'harness-patch-review--init
  :shutdown #'harness-patch-review--shutdown)

(provide 'harness-patch-review)
;;; harness-patch-review.el ends here
