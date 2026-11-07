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
;; Emacs and the agent's messages never disagree: the UI sends the
;; operations the user makes (`patch-review/apply'), the agent's
;; <thread> blocks its answers (`patch-review/comment'), the module
;; performs them on the set it keeps in the state directory, one
;; document a task (patch-review/TASK.json), and announces each in
;; `patch-review/changed' for every UI to perform on its own copy.  An
;; operation names what it adds by id, so performing one twice is
;; harmless.
;;
;; THE AUTHORS.  The user writes as themselves, by name and address.  An
;; agent's comment records the agent and the session; a comment made by
;; the reply tool before it was removed also records the call, the link
;; back to that point of the conversation.
;;
;; THE DRAFTS.  What the user writes in a thread is a draft until it is
;; sent, and a blank one is no comment at all.  A task waiting for review
;; sends its drafts when it is sent back: whatever sends it back -- the
;; report's box, a message typed in its session, another client -- gets
;; them, `harness-tasks-feedback-additions-functions' asking this module
;; for the text, which quotes the diff above each comment as a reply on a
;; mailing list does and names each comment's thread.  The agent answers a
;; thread in a <thread> block of its message, closing it with
;; status="closed" when its point is done; the user closes it in turn,
;; once they agree.
;;
;; THE WORKING PHASE.  A task at work is in the working phase: its review
;; is a conversation with the user, and there is no feedback that could
;; carry a draft until the work is handed in.  What the user writes in
;; its threads waits there as drafts, all of them, until they send the
;; drafts together (`patch-review/send-replies',
;; `harness-patch-review--send-working-replies'): one message to the
;; agent, a thread block each, which the agent answers in their threads
;; as one turn.  The message of the last close waits in the same drafts
;; (see THE LAST CLOSE), and goes with them.  A reply that quotes a
;; comment, as C-c > writes it, has its quote in the <quote> of the
;; block -- the line that names the comment answered and links to it,
;; then its words -- not as the Markdown ">" lines the review keeps
;; for a person to read; a reply that quotes nothing has no <quote>
;; tag.  Closing a thread is the
;; user's question answered, not a way past the hand-in check: hand_in
;; refuses while one is open (`harness-patch-review--hand-in-blocker').
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
;; reply written inline, under a quote of the agent's own words (what a
;; compose box's C-c > made before every reply was a thread), keeps that
;; quote above its text: "silence" says nothing without the line it
;; answers.
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
;; agent's in a thread (the call that made it) or to an earlier reply of
;; the user's makes it a reply in that thread, which a close does not
;; keep from opening again; lines of a diff put it on those lines, at the
;; revision; any other starts a thread on the change as a whole.  The
;; block that goes on, and is recorded, has the thread's id, and its text
;; is one <thread> block (`harness-thread-marker'), which is how the agent
;; knows the thread to answer in and how the chat
;; draws a link to it.  A reply that is a thread is no words: the tasks
;; module leaves it out of the words a task is sent back with
;; (`harness-tasks--words'), so they are not a thread of their own too,
;; and the import of rounds and of words by hand, which reads text, skips
;; what names a thread.  Only a task's session has a review: any other session's
;; replies stay plain, answered inline.
;;
;; THE <thread> FORM IN MESSAGES.  A reply in a thread can be written in
;; the message itself, by the user and the agent alike
;; (`harness-thread-parse-blocks'): <thread id="..."><quote>what it
;; answers</quote>the reply</thread>, status="closed" to close it.  The
;; chat draws it as the card a reply in a thread is, and the transcript
;; keeps it as it was written.  The thread-reply module reads that form
;; (`harness-thread-reply--on-message',
;; `harness-thread-reply--take-tagged-words', and, for the agent,
;; `harness-thread-reply--on-assistant-message') and hands each reply
;; here (`patch-review/user-reply', `patch-review/comment'): the user's
;; is a comment of the review -- a draft, sent with the feedback that
;; sends the task back, or with the other replies of a task at work --
;; and the agent's is its answer in the thread.  This is the way an agent
;; answers without the tool, and the format its prompt names; a block
;; that names no thread the review has stays as the user wrote it, for
;; the agent to read.  The reply form is the thread-reply module's; the
;; threads it is kept in are this one's.
;;
;; THE OPEN THREADS.  A thread with a sent comment that is still open is
;; a question the work has not answered, and the working phase is for
;; working through it with the user until they are satisfied -- not for
;; getting to hand_in.  While this module is loaded, and
;; `harness-tools-handin-require-closed-threads' is on, `hand_in' refuses
;; until every such thread is closed
;; (`harness-patch-review--hand-in-blocker', on
;; `harness-tools-handin-block-functions'): the working phase goes on
;; until the agent has answered what the user asked, and closing a
;; thread is a statement that its point is done, never a way around the
;; check.  Without the module there is no such check, and the hook is
;; empty.
;;
;; THE LAST CLOSE.  The user closing the last thread that has a sent
;; comment and is open leaves the review with nothing to answer.  In the
;; working phase the agent has to know: it may be waiting for the user,
;; and nothing the user typed would tell it.  So the harness keeps a
;; message of its own -- that no thread is left to answer
;; (`harness-patch-review-last-close-message') -- as a draft of the
;; task's session, from "review".  It is one of the drafts the user
;; sends (`patch-review/send-replies'): with the replies, one send; by
;; itself, when nothing else waits, the same.  The agent then takes a
;; turn as it would for a message the user typed: it sees that no thread
;; is left open, and hands the work in when nothing is outstanding.
;; Nothing is sent by itself: the draft waits for the user, who may send
;; it with the rest or drop it (`patch-review/discard-last-close').  The
;; message does not say to hand in -- the task's prompt does.  Only the
;; user's close offers it: the agent's own close is in a turn of its
;; own, a close in a task waiting for review needs no turn, and a thread
;; of drafts was never a question the work had to answer
;; (`harness-patch-review-draft-on-last-close').
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
(require 'mailcap)
(require 'harness-core)
(require 'harness-util)
(require 'harness-links)
(require 'harness-thread-reply)

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

(defun harness-patch-review--agent (session-id &optional call-id message block-start)
  "Return the agent of SESSION-ID as an author.
CALL-ID is the tool call that made the comment, if a call did.  MESSAGE
and BLOCK-START say which message, and which of its <thread> blocks,
made it, so that a reply to that block in the chat follows the comment."
  (let ((session (and (stringp session-id) (harness-method-exists-p 'session/get)
                      (ignore-errors (harness-call 'session/get session-id)))))
    (change-review-agent (harness-patch-review--model-name (plist-get session :model))
                         :session session-id :tool-call call-id
                         :meta (and message (list :message message :block-start block-start)))))

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
text is a <thread> block with its thread's id (`harness-thread-marker'),
which the text of a round or of a message keeps."
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
;; reference to a comment of the agent's in a thread (the tool call that
;; made it) or to an earlier reply of the user's in one makes the reply a
;; comment in that thread, which is how the replies of a conversation stay
;; together, and a close does not keep it from opening again: the user is
;; the one to say a point is done.  A reference to lines of a diff puts the
;; thread on those lines, at the revision, as a comment made in the review
;; is.  Any other starts a thread on the change as a whole, and keeps the
;; references in its comment's meta.
;;
;; The block that goes on, and is recorded, has the thread's id
;; (`:thread'), and its text is the <thread> block of the reply
;; (`harness-thread-marker'), which tells the agent the thread to answer in,
;; and the code that turns typed words into threads that this one is made.

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

(defun harness-patch-review--split-quote (body)
  "Return (QUOTE . RESPONSE) for BODY, the text of a comment of a review.
BODY is Markdown.  When it opens with a block quote -- the lines that
start with \">\", which `harness-thread-quote' makes of the part of a
comment a reply answers -- QUOTE is its text, each line with the \">\"
and the space after it left off, and RESPONSE the words written under
it, as they are.  With no quote at the start QUOTE is nil and RESPONSE
is BODY.  A body that is only a quote has no response."
  (let* ((text (string-trim-left (or body "")))
         (lines (split-string text "\n"))
         (quoted nil) (going t))
    (while (and going lines)
      (let ((line (car lines)))
        (cond
         ((harness-patch-review--quote-line-p line)
          (let ((bare (string-remove-prefix ">" (string-trim-left line))))
            (push (string-remove-prefix " " bare) quoted))
          (setq lines (cdr lines)))
         ((and quoted (string-blank-p line))
          ;; A blank line between the parts of one quote is the quote's.
          (push "" quoted)
          (setq lines (cdr lines)))
         (t (setq going nil)))))
    (setq quoted (string-trim (string-join (nreverse quoted) "\n")))
    (if (string-empty-p quoted)
        (cons nil (string-trim (or body "")))
      (cons quoted (string-trim (string-join lines "\n"))))))

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

(defun harness-patch-review--block-comment (set session-id node-id block-start)
  "Return (THREAD . COMMENT) that the block of message NODE-ID made in SET.
BLOCK-START is where the block starts in the message.  The comment is
the agent's, in SESSION-ID, the message and the block in its author's
meta; nil when no comment of the set is that one."
  (when (and (stringp node-id) (numberp block-start))
    (cl-loop for thread in (change-review-set-threads set)
             for comment = (cl-find-if
                            (lambda (comment)
                              (let ((author (change-review-comment-author comment)))
                                (and author
                                     (equal (change-review-author-kind author) 'agent)
                                     (equal (change-review-author-session author) session-id)
                                     (equal (plist-get (change-review-author-meta author)
                                                       :message)
                                            node-id)
                                     (equal (plist-get (change-review-author-meta author)
                                                       :block-start)
                                            block-start))))
                            (change-review-thread-comments thread))
             when comment return (cons thread comment))))

(defun harness-patch-review--ref-parent (set session-id ref)
  "Return (THREAD . COMMENT) of SET that the chat reference REF is, or nil.
REF is a region of a node of SESSION-ID's transcript: when that node is a
<thread> block of the agent's message, a tool call that made a comment
before the reply tool was removed, or an earlier reply of the user's
that is a comment in a thread, the comment is what the reply follows."
  (when (and (equal (harness-thread-ref-kind ref) "chat") (stringp (plist-get ref :node)))
    (when-let* ((node (condition-case nil
                          (harness-call 'session/node session-id (plist-get ref :node))
                        (error nil))))
      (pcase (harness-patch-review--kind node)
        ("tool-call" (harness-patch-review--call-comment set (plist-get node :call-id)))
        ("assistant"
         (let* ((content (or (plist-get node :content) ""))
                (from (plist-get ref :from))
                (part (plist-get ref :part))
                (text (plist-get ref :text))
                (blocks (harness-thread-parse-blocks content))
                (matching
                 (when (and (stringp text) (not (string-empty-p text)))
                   (cl-remove-if-not
                    (lambda (block)
                      (string-search text (or (plist-get block :body) "")))
                    blocks))))
           (or
            ;; The words of a block, drawn as a card: PART says so.
            (when (and (equal part "body") (= 1 (length matching)))
              (harness-patch-review--block-comment
               set session-id (plist-get node :id)
               (plist-get (car matching) :start)))
            ;; A reference into the raw message: the block it lands in.
            (cl-loop for block in blocks
                     when (and (numberp from)
                               (<= (plist-get block :start) from)
                               (< from (plist-get block :end)))
                     return (harness-patch-review--block-comment
                             set session-id (plist-get node :id)
                             (plist-get block :start)))
            ;; A reference that names no offset: the one block there is.
            (when (and (null from) (= 1 (length blocks)))
              (harness-patch-review--block-comment
               set session-id (plist-get node :id)
               (plist-get (car blocks) :start))))))
        ("user" (cl-some (lambda (block)
                           (when-let* (((harness-thread-block-p block))
                                       (id (plist-get (plist-get block :thread) :comment)))
                             (change-review-find-comment set id)))
                         (plist-get node :blocks)))))))

(defun harness-patch-review--thread-body (data)
  "Return what the comment of the thread DATA says: the quotes, then the response.
The lines of a diff the thread is on are its location, which the review
shows with the thread: only the words a person would not find there are
quoted.  A person reads the comment, so the quotes have no links to the
messages they are of: the agent reads those in the reply itself."
  (let ((quoted (cl-remove-if (lambda (ref) (equal (harness-thread-ref-kind ref) "diff"))
                              (harness-thread-refs data))))
    (harness-thread-text (list :refs quoted :response (plist-get data :response)) t)))

(defun harness-patch-review--thread-location (data)
  "Return the location in the diff the thread DATA is on, or nil.
That is where its first reference to lines of a diff or to lines of a
buffer -- a section of a design document, say -- is."
  (when-let* ((ref (cl-find-if (lambda (ref)
                                 (member (harness-thread-ref-kind ref) '("diff" "buffer")))
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
             ;; The pictures and videos the words name stay with the
             ;; comment, which draws them under them in the thread.
             :meta (append (list :chat t :session session-id :refs (harness-thread-refs data))
                           (and (plist-get data :attachments)
                                (list :attachments (plist-get data :attachments)))))))
         (thread (car (change-review-find-comment set (change-review-comment-id comment)))))
    (when (and thread (not (change-review-thread-open-p thread)))
      (change-review-update-status set thread 'open :author author :time (+ now 0.001)))
    (harness-thread-normalize
     (append (cl-loop for (key value) on data by #'cddr
                      unless (memq key '(:id :comment)) append (list key value))
             (list :id (change-review-thread-id thread) :comment (change-review-comment-id comment))))))

(defun harness-patch-review--answerable-p (session-id)
  "Non-nil when SESSION-ID can answer in the threads of its task's review.
That is when this module keeps threads, which every task's session has:
with no reply tool, the agent answers in the <thread> blocks of its
message.  The callers look the task up themselves."
  (harness-thread-reply--answerable-p session-id))

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

(defun harness-patch-review--attachment-mime (attachment)
  "Return the MIME type of ATTACHMENT, a block or a compose attachment.
It is ATTACHMENT's own `:mime', else what its file name makes it."
  (or (plist-get attachment :mime)
      (when-let* ((path (plist-get attachment :path)))
        (condition-case nil
            (mailcap-extension-to-mime (or (file-name-extension path t) ""))
          (error nil)))
      "application/octet-stream"))

(defun harness-patch-review--media-of-reply (attachments response)
  "Return the pictures and videos among ATTACHMENTS that RESPONSE names.
ATTACHMENTS are the blocks of a message, or the attachments of the
feedback that sends a task back: plists with `:path', `:mime', `:name',
`:size' and, for an image, the `:label' its token, [image 1], names it
by.  RESPONSE is the words written under the reply's card.  A picture or
video shows in the thread of the reply only when those words name it, as
the compose box writes a token, so an attachment of the message's own
text is not taken for the reply's."
  (when (stringp response)
    (let (media)
      (dolist (attachment attachments)
        (let* ((path (plist-get attachment :path))
               (mime (harness-patch-review--attachment-mime attachment))
               (label (plist-get attachment :label))
               (name (or (plist-get attachment :name)
                         (and path (file-name-nondirectory path))))
               (named (or (and (stringp label) (not (string-empty-p label))
                               (string-search (format "[%s]" label) response))
                          (and (stringp name) (harness-names-file-p response name))
                          (and (stringp path)
                               (string-search (format "@%s" path) response)))))
          (when (and path named
                     (or (string-prefix-p "image/" mime)
                         (string-prefix-p "video/" mime)))
            (push (list :path path :mime mime :name name
                        :size (plist-get attachment :size))
                  media))))
      (nreverse media))))

(defun harness-patch-review--register-blocks (set session-id blocks)
  "Return BLOCKS with each reply in a new thread made a comment of SET.
SESSION-ID is the session the message is sent in.  A block that goes on
has its thread's id in the tag of its <thread> block.  The pictures and
videos of the message that a reply's words name go with its comment,
which the review draws in the thread."
  (mapcar (lambda (block)
            (if (harness-patch-review--new-thread-p block)
                (let* ((data (plist-get block :thread))
                       (media (harness-patch-review--media-of-reply
                               blocks (plist-get data :response)))
                       (data (if media
                                 (plist-put (copy-sequence data) :attachments media)
                               data)))
                  (harness-thread-block
                   (harness-patch-review--register-thread set session-id data)))
              block))
          blocks))

(defun harness-patch-review--user-tagged-comment (set session-id block &optional draft attachments)
  "Make BLOCK, a parsed <thread> reply of the user's, a comment of SET.
SESSION-ID is the session the message is sent in.  DRAFT non-nil keeps
it unsent, as a reply in a thread of the review is until the feedback
that sends the task back.  ATTACHMENTS are the message's blocks: only
media named in the reply's body go with its comment.  Return the id of
the thread it is in.  Signal when the block names a thread this review
does not have."
  (let* ((named (plist-get block :id))
         (thread (and named (change-review-find-thread set named))))
    (when (and named (not thread))
      (signal 'harness-error
              (list (format "No thread %s in this review" named))))
    (let* ((body (harness-thread-render-text block))
           (media (harness-patch-review--media-of-reply attachments (plist-get block :body)))
           (status (let ((value (plist-get block :status)))
                     (and (member value '("open" "closed")) (intern value))))
           (time (float-time))
           (comment (unless (string-blank-p body)
                      (change-review-comment
                       set body :thread thread
                       :author (harness-patch-review--user)
                       :time time :sent (unless draft time)
                       :meta (append (list :tag t :session session-id)
                                     (and media (list :attachments media)))))))
      (when (and status (or thread comment))
        (change-review-update-status
         set (or thread (change-review-comment-thread comment)) status
         :author (harness-patch-review--user) :time (+ time 0.001)))
      (or (and thread (change-review-thread-id thread))
          (and comment (change-review-comment-thread comment))))))

(harness-defmethod patch-review/user-reply (task-id session-id block &optional draft attachments)
  "Make BLOCK, a parsed <thread> reply of the user's, a comment of a review.
The review is TASK-ID's; SESSION-ID is the session the message is sent
in.  DRAFT non-nil keeps it unsent, as a reply in a thread of the review
is until the feedback that sends the task back.  ATTACHMENTS are the
message's blocks; media named in the reply's body stay with the comment.
Return the id of the thread it is in.  Signal when the block names a
thread this review does not have.  The thread-reply module reads the
block out of the words; this keeps it."
  (prog1 (harness-patch-review--user-tagged-comment
          (harness-patch-review--set-for task-id t) session-id block draft attachments)
    ;; The review may have something to answer again: the message of its
    ;; last close is read, and goes when a sent thread is open now.
    (harness-patch-review--last-close-here task-id)))

(defun harness-patch-review--on-message (blocks session-id info)
  "Make the replies in threads of the user's message BLOCKS comments of a review.
An `agent/message' filter, INFO being (:from FROM ...): only the user's
own messages count, in the session of a task's review.  The harness's own
messages and another session's agent's are no replies.  Each block with
thread data (`harness-thread-block') and no thread yet becomes a comment
\(`harness-patch-review--register-thread'), and the block that goes on
has the thread's id in its tag.  It runs before the tasks
module reads a message to a task in review as the feedback that sends it
back, which then carries the markers.  A message the review cannot take
is left as it was, and so is one that fails.  The <thread> replies typed
in a text block are the thread-reply module's, which runs first and
leaves each as a thread block with its thread's id."
  (if (or (harness-sender-kind (plist-get info :from))
          (not (cl-some #'harness-patch-review--new-thread-p blocks)))
      blocks
    (condition-case err
        (let ((task (and (harness-method-exists-p 'task/for-session)
                         (harness-call 'task/for-session session-id))))
          (if (not (and task (harness-patch-review--answerable-p session-id)))
              blocks
            (prog1 (harness-patch-review--register-blocks
                    (harness-patch-review--set-for (plist-get task :id) t)
                    session-id blocks)
              (harness-patch-review--last-close-here (plist-get task :id)))))
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
the threads it made.  Replies that have their thread already are left
alone."
  (let ((session-id (plist-get task :session)))
    (if (not (and (stringp session-id)
                  (cl-some #'harness-patch-review--new-thread-attachment-p attachments)))
        attachments
      (let ((set (harness-patch-review--set-for (plist-get task :id) t)))
        (mapcar (lambda (attachment)
                  (if (harness-patch-review--new-thread-attachment-p attachment)
                      (let* ((response (plist-get attachment :response))
                             (data (plist-put (copy-sequence (plist-get attachment :thread))
                                              :response response))
                             (media (harness-patch-review--media-of-reply
                                     attachments response))
                             (data (if media
                                       (plist-put data :attachments media)
                                     data)))
                        (plist-put (copy-sequence attachment) :thread
                                   (harness-patch-review--register-thread
                                    set session-id data)))
                    attachment))
                attachments)))))

(defun harness-patch-review--unregistered (text)
  "Return TEXT, trimmed, without the replies the review keeps already.
Those are the <thread> blocks of the chat -- and the quotes and answers
that end with a marker line, as replies were written before the block
\(`harness-thread-marker') -- threads started in the chat.  What is left,
the words that made none, has the blank lines they leave collapsed.  A
TEXT with no such reply is returned as it is, trimmed."
  (let ((text (or text "")) (cut nil))
    ;; A reply whose tag names its thread is the review's; one that names
    ;; none started a thread the review never made, and stays.
    (let ((pos 0))
      (while (string-match harness-thread-marker-regexp text pos)
        (let ((start (match-beginning 0))
              (attributes (match-string 1 text)))
          (setq pos (match-end 0))
          (when (and attributes
                     (string-match "\\bid=\"[A-Za-z0-9][A-Za-z0-9_.-]*\"" attributes)
                     (not (harness-thread--fenced-p text start))
                     (string-match "</thread>" text pos))
            (let ((end (match-end 0)))
              (setq cut t
                    pos start
                    text (concat (substring text 0 start) (substring text end))))))))
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

(defun harness-patch-review--decode (bytes)
  "Return BYTES, as git wrote them, decoded as UTF-8."
  (decode-coding-string
   (if (multibyte-string-p bytes)
       (condition-case nil (string-to-unibyte bytes)
         (error (encode-coding-string bytes 'utf-8)))
     bytes)
   'utf-8))

(defun harness-patch-review--git-text (dir &rest args)
  "Return a promise of what git, run in DIR with ARGS, writes, as text.
The output is not trimmed, so a patch keeps its last newline.  It
rejects with git's message when git fails."
  (harness-then
   (harness-run-command (append '("git" "--no-pager" "-c" "core.quotePath=false") args)
                        :cwd dir :timeout 60 :name "harness-patch-review"
                        :env '(("GIT_OPTIONAL_LOCKS" . "0")))
   (lambda (result)
     (if (eql (plist-get result :exit) 0)
         (harness-patch-review--decode (or (plist-get result :stdout) ""))
       (harness-rejected
        (list 'error (format "git %s failed: %s" (car args)
                             (harness-first-line
                              (harness-patch-review--decode (or (plist-get result :stderr) "")) 120))))))))

(defun harness-patch-review--find-version (set ref)
  "Return the version REF names in SET, or nil.
REF is a version, an id, a number or a label; a string may also be the
start of one id, three characters or more, when it names no version as
it is and exactly one version starts with it."
  (when set
    (or (change-review-find-version set ref)
        (and (stringp ref) (>= (length ref) 3)
             (let ((matches (cl-remove-if-not
                             (lambda (version)
                               (string-prefix-p ref (or (change-review-version-id version) "")))
                             (change-review-set-versions set))))
               (and (= 1 (length matches)) (car matches)))))))

(cl-defun harness-patch-review--review-revisions (task &optional version-ref)
  "Return a promise of where TASK's review reads the version VERSION-REF.
VERSION-REF names a version of the review (`change-review-find-version'
takes an id, a number or a label), or is nil for the newest.  The value
is a plist:

  :dir         the repository directory the version is read in
  :base        the commit the version is a change from
  :tip         the commit the version ends at, the revision of its files
  :revision    :tip, what a comment made there records
  :version     the version, nil for a task whose work was never handed in
  :version-id  its id, nil when there is none
  :label       what to call it, such as \"v2\"

It rejects when the task has no repository here, no branch of its own,
or no commit in common with its base."
  (let* ((id (plist-get task :id))
         (dir (harness-patch-review--repository task))
         (set (and (stringp id) (harness-patch-review--set-for id)))
         (version (and set
                       (if (null version-ref)
                           (change-review-latest-version set)
                         (harness-patch-review--find-version set version-ref))))
         (branch (plist-get task :branch))
         (base-name (plist-get task :base)))
    (cond
     ((and version-ref (null version))
      (harness-rejected
       (list 'error (format "The review has no version %s" version-ref))))
     ((null dir)
      (harness-rejected
       (list 'error "The repository of this task is not on this machine")))
     ((and (null version) (harness-string-blank-p branch))
      (harness-rejected
       (list 'error "The task has no branch of its own: it worked in the main checkout")))
     (t
      (harness-then
       (if version
           (harness-resolved (change-review-version-tip version))
         (harness-patch-review--git dir "rev-parse" "--verify" "--quiet"
                                    (concat branch "^{commit}")))
       (lambda (tip)
         (when (harness-string-blank-p tip)
           (harness-rejected (list 'error "The branch of this task names no commit")))
         (harness-then
          (let ((recorded (and version (change-review-version-base version))))
            (if (and (stringp recorded) (not (string-blank-p recorded)))
                (harness-resolved recorded)
              (harness-patch-review--merge-base dir base-name tip)))
          (lambda (base)
            (when (harness-string-blank-p base)
              (harness-rejected
               (list 'error "The branch has no commit in common with its base")))
            (list :dir dir
                  :base base
                  :tip tip
                  :revision tip
                  :version version
                  :version-id (and version (change-review-version-id version))
                  :label (and version (change-review-version-name version))
                  :branch branch)))))))))

(defun harness-patch-review--diff-files (raw)
  "Return the files RAW, what `git diff --raw -z' wrote, in its order.
Each is a plist of `:path', `:old-path' (for a rename or a copy),
`:status' (git's letter), `:old-mode', `:new-mode', `:old-blob' and
`:new-blob' (nil for a side the change has no blob on)."
  (let ((fields (split-string raw "\0" t))
        files)
    (while fields
      (let ((head (pop fields)))
        (when (string-match
               "\\`:\\([0-7]+\\) \\([0-7]+\\) \\([0-9a-f]+\\) \\([0-9a-f]+\\) \\([A-Z]\\)" head)
          (let* ((old-mode (match-string 1 head))
                 (new-mode (match-string 2 head))
                 (old-sha (match-string 3 head))
                 (new-sha (match-string 4 head))
                 (status (match-string 5 head))
                 (two (member status '("R" "C")))
                 (first (pop fields))
                 (second (and two (pop fields))))
            (push (list :path (or second first)
                        :old-path (and two first)
                        :status status
                        :old-mode old-mode
                        :new-mode new-mode
                        :old-blob (and (not (string-match-p "\\`0+\\'" old-sha)) old-sha)
                        :new-blob (and (not (string-match-p "\\`0+\\'" new-sha)) new-sha))
                  files)))))
    (nreverse files)))

(defun harness-patch-review--numstat-files (raw)
  "Return the counts RAW, what `git diff --numstat -z' wrote, in its order.
Each is a plist of `:path', `:old-path' for a rename or a copy,
`:added', `:deleted' (numbers, nil for a binary file) and `:binary'."
  (let ((fields (split-string raw "\0" t))
        files)
    (while fields
      (let ((head (pop fields)))
        (when (string-match "\\`\\([0-9-]+\\)\t\\([0-9-]+\\)\t\\(.*\\)\\'" head)
          (let* ((added (match-string 1 head))
                 (deleted (match-string 2 head))
                 (path (match-string 3 head))
                 (binary (or (equal added "-") (equal deleted "-")))
                 (old (and (string-empty-p path) (pop fields)))
                 (new (and old (pop fields))))
            (push (list :path (or new path)
                        :old-path (and new old)
                        :added (and (not binary) (string-to-number added))
                        :deleted (and (not binary) (string-to-number deleted))
                        :binary binary)
                  files)))))
    (nreverse files)))

(defun harness-patch-review--file-counts (file stat)
  "Return FILE with the counts of STAT, the `--numstat' record of it.
The counts are those of STAT when it names the same file, else FILE
keeps none; a binary file is marked either way."
  (cond
   ((null stat) file)
   ((or (not (equal (plist-get stat :path) (plist-get file :path)))
        (and (plist-get file :old-path)
             (not (equal (plist-get stat :old-path) (plist-get file :old-path)))))
    file)
   (t (append file (list :added (plist-get stat :added)
                         :deleted (plist-get stat :deleted)
                         :binary (plist-get stat :binary))))))

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
  "Record the version of TASK, which comes to review: the work handed in.
Its last-close message, if one still waited for the user to send, goes:
the task has left the working phase."
  (when (plist-get task :id)
    (harness-patch-review--drop-last-close (plist-get task :id)))
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

(defun harness-patch-review--pair-counts (files stats)
  "Return FILES, the `git diff --raw' records, with the counts of STATS.
STATS are the `git diff --numstat' records of the same change, in the
same order; a file whose record cannot be told apart by position is
looked for by its path."
  (let ((in-order (= (length files) (length stats))))
    (mapcar (lambda (file)
              (harness-patch-review--file-counts
               file
               (if in-order
                   (pop stats)
                 (cl-find (or (plist-get file :path) "")
                          stats :key (lambda (stat) (or (plist-get stat :path) ""))
                          :test #'equal))))
            files)))

(defun harness-patch-review--change-file (path files)
  "Return the file of FILES that PATH names, after the change or before it."
  (cl-find-if (lambda (file)
                (or (equal path (plist-get file :path))
                    (equal path (plist-get file :old-path))))
              files))

(harness-defmethod patch-review/changes (task-id &optional version)
  "Return the files task TASK-ID's review changes at VERSION, as plain data.
VERSION names a version of the review (`change-review-find-version'
takes an id, a number or a label), or is nil for the newest.  The work
of a task that was not handed in yet is read from its branch, against
the branch it was made from.

The answer is a plist:

  :task-id    TASK-ID
  :revision   the commit the files are read at, the revision a comment
              made on them records
  :base       the commit they are a change from
  :version    the version's id, nil for a task with no hand-in yet
  :label      what to call the version, such as \"v2\", when it has one
  :branch     the task's branch
  :files      a list of (:path PATH [:old-path PATH] :status LETTER
              :added N :deleted M :binary BOOL [:old-blob BLOB]
              [:new-blob BLOB] [:old-mode MODE] [:new-mode MODE])

STATUS is git's letter: A, D, M, R, C or T.  ADDED and DELETED count the
lines the change touches, nil for a binary file, which BINARY marks.
This is what a client that cannot read the task's repository shows its
reviewer: the list and counts, then one file's diff at a time with
`patch-review/diff'."
  (let ((task (harness-patch-review--task task-id)))
    (harness-then
     (harness-patch-review--review-revisions task version)
     (lambda (revisions)
       (let ((dir (plist-get revisions :dir))
             (base (plist-get revisions :base))
             (tip (plist-get revisions :tip)))
         (harness-then
          (harness-all
           (list (harness-patch-review--git-text
                  dir "diff" "--raw" "-z" "-M" "--no-abbrev" base tip)
                 (harness-patch-review--git-text
                  dir "diff" "--numstat" "-z" "-M" base tip)))
          (lambda (outputs)
            (list :task-id task-id
                  :revision (plist-get revisions :revision)
                  :base base
                  :version (plist-get revisions :version-id)
                  :label (plist-get revisions :label)
                  :branch (plist-get revisions :branch)
                  :files (harness-patch-review--pair-counts
                          (harness-patch-review--diff-files (nth 0 outputs))
                          (harness-patch-review--numstat-files (nth 1 outputs)))))))))))

(harness-defmethod patch-review/diff (task-id path &optional version)
  "Return the diff of PATH in task TASK-ID's review at VERSION.
VERSION names a version as `patch-review/changes' takes it; nil is the
newest.  PATH is the file's path after the change, or the one it had
before it: a renamed file is read as the rename it is, with both paths.

The answer is a plist:

  :task-id    TASK-ID
  :path       the path after the change
  :old-path   the path before it, for a rename or a copy
  :status     git's letter for the change
  :added      lines added, nil for a binary file
  :deleted    lines deleted, nil for a binary file
  :binary     non-nil for a file with no text diff
  :patch      its part of the unified diff, or nil for a binary file
  :revision   the commit it is read at, the revision a comment records
  :base       the commit it is a change from
  :version    the version's id, when the review has one
  :label      what to call it, such as \"v2\"

The patch is what `git diff' writes, with its `diff --git' line, its
hunk headers and its lines of context, additions and deletions.  Signal
an error when the change has no such file."
  (unless (and (stringp path)
               (not (string-empty-p path))
               (not (string-prefix-p "/" path))
               (not (string-match-p "\0" path)))
    (signal 'harness-error (list "A file of the change needs a relative path")))
  (let ((task (harness-patch-review--task task-id)))
    (harness-then
     (harness-patch-review--review-revisions task version)
     (lambda (revisions)
       (let ((dir (plist-get revisions :dir))
             (base (plist-get revisions :base))
             (tip (plist-get revisions :tip)))
         (harness-then
          (harness-all
           (list (harness-patch-review--git-text
                  dir "diff" "--raw" "-z" "-M" "--no-abbrev" base tip)
                 (harness-patch-review--git-text
                  dir "diff" "--numstat" "-z" "-M" base tip)))
          (lambda (outputs)
            (let* ((files (harness-patch-review--diff-files (nth 0 outputs)))
                   (file (harness-patch-review--change-file path files)))
              (unless file
                (signal 'harness-error
                        (list (format "The change has no file %s" path))))
              (let ((paths (cl-remove-duplicates
                            (delq nil (list path
                                            (plist-get file :path)
                                            (plist-get file :old-path)))
                            :test #'equal)))
                (harness-then
                 (apply #'harness-patch-review--git-text dir
                        "diff" "-M" "--no-color" "--no-ext-diff" "--no-textconv"
                        "--src-prefix=a/" "--dst-prefix=b/" base tip "--" paths)
                 (lambda (patch)
                   (let* ((stat (harness-patch-review--file-counts
                                 file
                                 (cl-find (plist-get file :path)
                                          (harness-patch-review--numstat-files (nth 1 outputs))
                                          :key (lambda (record) (plist-get record :path))
                                          :test #'equal))))
                     (list :task-id task-id
                           :path (plist-get file :path)
                           :old-path (plist-get file :old-path)
                           :status (plist-get file :status)
                           :added (plist-get stat :added)
                           :deleted (plist-get stat :deleted)
                           :binary (plist-get stat :binary)
                           :patch (and (not (plist-get stat :binary)) patch)
                           :revision (plist-get revisions :revision)
                           :base base
                           :version (plist-get revisions :version-id)
                           :label (plist-get revisions :label))))))))))))))

(defun harness-patch-review--ui-op (task-id op)
  "Return OP, an operation a UI sends, with what the harness fills for its user.
A comment the user adds is theirs: the author is
`harness-patch-review--user', the time is now, the revision is the
newest version's, and a comment or a thread id left out is made.
Closing, opening and marking a thread reviewed record the user as the
one who did it, at the time it was done.  An operation the harness
cannot complete alone is left as it is for `change-review-apply' to
refuse."
  (let* ((kind (let ((value (plist-get op :op)))
                 (cond ((symbolp value) value)
                       ((stringp value) (intern value)))))
         (set (harness-patch-review--set-for task-id t))
         (user (change-review-author-to-data (harness-patch-review--user)))
         (now (float-time))
         (op (copy-sequence op)))
    (cond
     ((eq kind 'add-comment)
      (let* ((comment (copy-sequence (or (plist-get op :comment) (list))))
             (reply (plist-get comment :reply-to))
             (parent (and reply (change-review-find-comment set reply)))
             (thread (or (plist-get comment :thread)
                         (plist-get op :thread)
                         (and parent (change-review-comment-thread (cdr parent))))))
        (when (and parent thread
                   (not (equal thread (change-review-comment-thread (cdr parent)))))
          (signal 'harness-error
                  (list "A reply is in the thread of the comment it answers")))
        (unless thread (setq thread (change-review-new-thread-id set)))
        (unless (plist-get comment :id)
          (setq comment (plist-put comment :id (change-review-new-id "c"))))
        (unless (plist-get comment :thread)
          (setq comment (plist-put comment :thread thread)))
        (unless (plist-get comment :author)
          (setq comment (plist-put comment :author user)))
        (unless (plist-get comment :time)
          (setq comment (plist-put comment :time now)))
        (unless (plist-get comment :revision)
          (when-let* ((version (change-review-latest-version set)))
            (setq comment (plist-put comment :revision
                                     (change-review-version-id version)))))
        (setq op (plist-put op :comment comment))
        (setq op (plist-put op :thread thread))))
     ((eq kind 'set-status)
      (unless (plist-get op :id)
        (setq op (plist-put op :id (change-review-new-id "s"))))
      (unless (plist-get op :time)
        (setq op (plist-put op :time now)))
      (unless (plist-get op :author)
        (setq op (plist-put op :author user))))
     ((memq kind '(mark-reviewed unmark-reviewed))
      (unless (plist-get op :time)
        (setq op (plist-put op :time now)))))
    op))

(harness-defmethod patch-review/apply (task-id op)
  "Perform OP, an operation of change-review, on the review of task TASK-ID.
The UI sends the operations the user makes: `add-comment', `set-status',
`edit-comment', `delete-comment', `add-version', and `mark-reviewed' and
`unmark-reviewed' for a close by the agent the user has looked at, or
no longer has.  Return (:changed BOOL).  `patch-review/changed' announces
what changed to every UI, so that each performs it on its own copy.  The
user closing the last open thread of a task at work also leaves the
harness's message that no thread is left, for the user to send with the
drafts (`harness-patch-review-draft-on-last-close',
`patch-review/send-replies')."
  (let ((kind (let ((value (plist-get op :op)))
                (cond ((symbolp value) value)
                      ((stringp value) (intern value))))))
    (unless (memq kind '(add-comment set-status edit-comment delete-comment add-version
                                     mark-reviewed unmark-reviewed))
      (signal 'harness-error (list (format "The review does not take %S operations from a UI" kind))))
    (let ((set (harness-patch-review--set-for task-id t))
          changed)
      (setq op (harness-patch-review--ui-op task-id op))
      (setq changed (and (change-review-dispatch set op) t))
      (when changed
        (if (harness-patch-review--last-close-p set op)
            (harness-patch-review--offer-last-close task-id)
          ;; Any other change may leave the message untrue -- a thread
          ;; opened again, a sent comment added.  Reading it drops it
          ;; then; one that still holds stays.
          (harness-patch-review--last-close-here task-id)))
      (list :changed changed))))

(harness-defmethod patch-review/send-replies (task-id)
  "Send the drafts waiting in task TASK-ID's review to its agent.
It is for a task at work, which has no feedback to carry them.  The
user's replies go as one message, a thread block each, and are marked
sent.  The harness's message that the last thread is closed
\(`patch-review/last-close') goes after them, as a message of its own,
from \"review\".  Return (:sent N :last-close BOOL), N how many replies
there were and BOOL whether the harness's message went with them.  A
task waiting for review signals `harness-error': its drafts go with the
feedback that sends it back."
  (harness-patch-review--send-working-replies task-id))

(defun harness-patch-review--sent-open-threads (set)
  "Return the threads of SET that are open and have a sent comment.
These are the threads a hand-in waits on (`patch-review/open-threads',
`harness-patch-review--hand-in-blocker'): a draft the user has not sent is
no question the work has to answer yet."
  (cl-remove-if-not
   (lambda (thread)
     (and (change-review-thread-open-p thread)
          (cl-some (lambda (comment) (not (change-review-comment-draft-p comment)))
                   (change-review-thread-comments thread))))
   (change-review-set-threads set)))

(harness-defmethod patch-review/open-threads (task-id)
  "Return the open threads of task TASK-ID's review, as a list of plists.
Each is (:id ID :where WHERE), WHERE being the file and line the thread
is on, or \"the change as a whole\".  Only threads with a sent comment
count: a draft the user has not sent is no thread yet.  A task with no
review has none, and nothing is made."
  (when-let* ((set (harness-patch-review--set-for task-id)))
    (mapcar (lambda (thread)
              (list :id (change-review-thread-id thread)
                    :where (harness-patch-review--where thread)))
            (harness-patch-review--sent-open-threads set))))

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
the thread afterwards; `:session' and `:call-id' say which session and,
when a tool call made it, which call wrote it; `:message' and
`:block-start' say which message, and which of its <thread> blocks,
wrote it; `:file', `:line' and `:side' say where in the change a new
thread is; `:revision' the commit the agent was at.  With no BODY
`:status' alone changes the thread's status.  Every comment is kept: an
agent that wants to say two things in one thread makes two comments,
and both are there.  Signal an error naming the threads there are when
`:thread' names none."
  (let* ((set (harness-patch-review--set-for task-id t))
         (named (plist-get opts :thread))
         (thread (and named
                      (or (change-review-find-thread set named)
                          (signal 'harness-error
                                  (list (format "No thread %s in this review; threads: %s"
                                                named
                                                (mapconcat (lambda (th) (change-review-thread-id th))
                                                           (change-review-set-threads set) ", ")))))))
         (author (harness-patch-review--agent (plist-get opts :session)
                                              (plist-get opts :call-id)
                                              (plist-get opts :message)
                                              (plist-get opts :block-start)))
         (status (let ((value (plist-get opts :status)))
                   (and value (intern (format "%s" value)))))
         (time (float-time))
         ;; The comment a new one follows: the newest of the thread there is.
         (parent-before (and thread (change-review-thread-last-comment thread))))
    (when (and status (not (memq status '(open closed))))
      (signal 'harness-error (list "A thread's status is open or closed")))
    (when (and (harness-string-blank-p body) (not (and thread status)))
      (signal 'harness-error (list "A comment needs text; to only open or close a thread, name the thread and a status")))
    (let* ((comment
            (unless (harness-string-blank-p body)
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
           (reply-thread (or thread
                             (and comment (change-review-find-thread
                                           set (change-review-comment-thread comment)))))
           (parent (harness-patch-review--parent-data parent-before)))
      (when (and status (or reply-thread comment))
        (change-review-update-status
         set (or reply-thread (change-review-comment-thread comment)) status
         :author author :time (+ time 0.001)))
      ;; The review has something new: the message of its last close, if
      ;; one waits for the user to send, is read: it goes when the
      ;; review has a thread to answer again, and stays when it does not.
      (harness-patch-review--last-close-here task-id)
      (list :thread (and reply-thread (change-review-thread-id reply-thread))
            :status (and reply-thread
                         (symbol-name (change-review-thread-status reply-thread)))
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
    (format "My review comments on your branch %s%s%s. Each is quoted from the diff, with my comment under the lines it is about; the <thread id=\"...\"> line names the thread it belongs to. These threads are what I want worked on with you, not a check to get to hand_in. Answer a thread in your message with a <thread id=\"THREAD_ID\"><quote>what you answer</quote>your answer</thread> block, giving its id, and close it (status=\"closed\") only once what it raises is done: a thread left open is not done, and neither is one closed unanswered or in a batch. I look at every thread you close, so say in your answer what you changed and where."
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
               :markers (lambda (comment) (harness-thread-marker (change-review-comment-thread comment))))))
    (if (string-search attribution text)
        text
      (concat attribution "\n\n" text))))

(defun harness-patch-review--additions (task words)
  "Return the drafts of TASK's review as text to add to its feedback, or nil.
On `harness-tasks-feedback-additions-functions'.  WORDS are what the user
sends the task back with.  The text is the marker of the thread WORDS
become, before the drafts, if there are any, quoted from the diff; a
draft whose text is blank is no feedback and is left out.  The function
marks the drafts it sent once the task is sent back, and keeps WORDS, if
there are any, as that thread on the change as a whole, sent: the review
has a record of what each round said, and the agent reads the id of the
thread its words are in."
  (let* ((id (plist-get task :id))
         ;; The replies in threads started in the chat are threads already:
         ;; the tasks module leaves them out of WORDS (`harness-tasks--words').
         (words (and (stringp words) (not (string-blank-p words)) (string-trim words)))
         (set (harness-patch-review--set-for id (and words t)))
         ;; A <thread> reply written in the feedback is a comment too, as
         ;; one typed in the box is; its words are no plain feedback.
         (words (and words set
                     (harness-thread-reply--take-tagged-words
                      id (plist-get task :session) words)))
         (drafts (and set
                      (cl-remove-if (lambda (draft)
                                      (harness-string-blank-p (change-review-comment-body draft)))
                                    (change-review-drafts set))))
         ;; The words become a thread of their own when the task is sent
         ;; back; its id goes in the feedback, before the drafts, so the
         ;; agent reads which thread the words above the marker are.  The
         ;; thread is made once the task is sent back: a message that is
         ;; refused names a thread that is never made, and nothing is lost.
         (thread (and words (change-review-new-thread-id set))))
    (when (or drafts words)
      (let ((round (length (plist-get task :feedback))))
        (cons (string-join
               (delq nil (list (and thread (harness-thread-marker thread))
                               (and drafts (harness-patch-review--render task set drafts))))
               "\n\n")
              (lambda ()
                (let ((time (float-time)))
                  (when drafts
                    (change-review-mark-sent set drafts :time time :meta (list :round round)))
                  (when words
                    (change-review-comment set words :thread thread
                                           :author (harness-patch-review--user)
                                           :time time :sent time
                                           :meta (list :round round :words t))))))))))

;;;; The working phase: the replies go together

(defun harness-patch-review--working-task-p (task)
  "Non-nil when TASK is at work, in the working phase.
Its review is then a conversation with the user: what the user writes in
its threads is sent to the agent together, when they send it
\(`patch-review/send-replies'), not with a round of feedback."
  (and task
       (eq (plist-get task :state) 'active)
       (fboundp 'harness-tasks--working-phase-p)
       (harness-tasks--working-phase-p task)))

(defun harness-patch-review--working-replies (set)
  "Return the replies of the user in SET that are not sent yet, as comments.
They are the drafts that are the user's, not blank, in the order they
were written."
  (cl-remove-if-not
   (lambda (comment)
     (and (not (harness-string-blank-p (change-review-comment-body comment)))
          (let ((author (change-review-comment-author comment)))
            (eq (change-review-author-kind author) 'user))))
   (change-review-drafts set)))

(defun harness-patch-review--comment-ref (task-id thread comment &optional text)
  "Return the reference to COMMENT of THREAD in task TASK-ID's review.
TEXT is what is quoted of it, COMMENT's body by default.  The reference
names the task and the thread, so the header of the quote links to the
review, and where COMMENT was made, so the header says that too."
  (let* ((location (or (change-review-comment-location comment)
                       (change-review-thread-location thread)))
         (author (ignore-errors
                   (change-review-author-label (change-review-comment-author comment)))))
    (append (list :kind "comment" :who "comment" :author author
                  :thread (change-review-thread-id thread)
                  :task task-id
                  :text (or text (change-review-comment-body comment)))
            (and location
                 (append (list :file (change-review-location-file location)
                               :side (format "%s" (change-review-location-side location))
                               :line (change-review-location-line location))
                         (and (change-review-location-end-line location)
                              (list :end (change-review-location-end-line location))))))))

(defun harness-patch-review--reply-block (task-id thread comment)
  "Return the thread block of COMMENT, a reply in THREAD of TASK-ID's review.
The block's text is the <thread> XML the agent reads: the reply's quote
in a <quote> tag, and the answer under it.  The quote is the Markdown
block quote the review keeps, with its \">\"s left off; the line it
opens with, which names the comment answered and links to its thread,
is the header the thread data makes of that comment, so the block draws
as any reply with a quote does.  A comment that opens with no quote has
no <quote> tag, as it quotes nothing."
  (let* ((split (harness-patch-review--split-quote (change-review-comment-body comment)))
         (quoted (car split))
         (response (cdr split))
         (parent (change-review-comment-parent thread comment))
         (ref (and quoted parent (harness-patch-review--comment-ref task-id thread parent)))
         (header (and ref (harness-thread-ref-header ref))))
    (when ref
      (if (and header (string-prefix-p (concat header "\n") (concat quoted "\n")))
          ;; The body opens with the header the reference makes: the tag
          ;; makes it again, above the words alone.
          (progn (setq quoted (string-trim (substring quoted (length header))))
                 (setf (plist-get ref :text) quoted))
        ;; Words the user wrote, not the quote of the comment: left whole.
        (setq ref nil)))
    (harness-thread-block
     (append (list :id (change-review-thread-id thread))
             (and quoted
                  (list :refs (list (or ref
                                        (list :kind "quote" :label "the quoted text"
                                              :text quoted)))))
             (list :response response))
     response)))

(defun harness-patch-review--send-working-replies (task-id)
  "Send the drafts written in the threads of TASK-ID's review to its agent.
The user's replies go as one message, each a thread block, so the agent
answers them in their threads as one turn; each is marked sent.  The
harness's message that the last thread is closed, when it waits
\(`patch-review/last-close'), goes after them as a message of its own,
from \"review\".  Return (:sent N :last-close BOOL), N how many replies
there were.  Only a task in the working phase sends them so: a task
waiting for review sends its drafts with the feedback that sends it
back."
  (let ((task (harness-patch-review--task task-id))
        (set (harness-patch-review--set-for task-id t)))
    (unless (harness-patch-review--working-task-p task)
      (signal 'harness-error
              (list "The task waits for review: its drafts go with the feedback that sends it back")))
    (let* ((replies (harness-patch-review--working-replies set))
           (close (harness-patch-review--last-close-here task-id))
           (session (plist-get task :session)))
      (unless (or replies close)
        (signal 'harness-error (list "No draft to send")))
      (when replies
        (unless (and (stringp session) (not (string-blank-p session)))
          (signal 'harness-error (list "The task has no session to send its replies to")))
        (unless (harness-method-exists-p 'agent/prompt)
          (signal 'harness-error (list "The harness cannot prompt a session")))
        (let* ((time (float-time))
               (blocks
                (cons (list :type "text"
                            :text "I wrote replies in the threads of the review of your work. Answer each in its thread with a <thread id=\"THREAD_ID\"> block in your message.")
                      (mapcar (lambda (comment)
                                (let ((thread (car (change-review-find-comment
                                                    set (change-review-comment-id comment)))))
                                  (harness-patch-review--reply-block task-id thread comment)))
                              replies)))
               (promise (harness-call-async 'agent/prompt session blocks)))
          (when (eq (harness-promise-state promise) 'rejected)
            (signal 'harness-error (list "The replies did not reach the agent")))
          (harness-catch
           promise
           (lambda (e)
             (harness-log 'warn "patch-review: the replies of %s did not reach the agent: %s"
                          task-id (harness-error-message e))))
          (change-review-mark-sent set replies :time time :meta (list :working t))))
      ;; Sending a draft in a new, open thread makes it a sent open
      ;; thread: the last-close message is no longer true.  Revalidate
      ;; after marking the replies, not against the earlier snapshot.
      (setq close (harness-patch-review--last-close-here task-id))
      ;; After the replies, so the agent reads them before it hears there
      ;; is nothing left to answer: the message starts the turn when no
      ;; reply does, and steers one already running.
      (when close
        (harness-patch-review--prompt-review task (plist-get close :text))
        (harness-patch-review--drop-last-close task-id))
      (list :sent (length replies) :last-close (and close t)))))

;;;; The last close

;; Declared before `harness-patch-review-draft-on-last-close', so a value
;; set under the old name is kept.
(define-obsolete-variable-alias 'harness-patch-review-wake-on-last-close
  'harness-patch-review-draft-on-last-close "3.1.0")

(defcustom harness-patch-review-draft-on-last-close t
  "When non-nil, closing the last open thread of a task at work offers a message.
The user closing the last thread of a task's review that has a sent
comment and is open leaves nothing of the review to answer.  The close
then keeps a message of the harness's own, from \"review\", as a draft of
the task's session: the UI shows it with the other drafts, and the user
sends it with them (`patch-review/send-replies'), or by itself when no
reply waits.  The message starts a turn then, as a message the user
typed would: the agent sees that no thread is left open, and hands the
work in when nothing is outstanding.  It does not say to hand in -- the
task's prompt does.  Only the working phase offers it: a task waiting
for review needs no turn when its threads are closed, and the agent
closing a thread itself offers none.  Off, closing a thread leaves no
message."
  :type 'boolean :group 'harness)

(defconst harness-patch-review-last-close-message
  "The user closed the last open thread of this task's review; no thread is left to answer."
  "What the agent reads when the user closes the last open thread of its review.
It says what changed, not what to do: the task's prompt says to hand the
work in when nothing is outstanding.")

(defvar harness-patch-review--last-close-drafts (make-hash-table :test #'equal)
  "Task id -> the message the user has yet to send that its last thread is closed.
A draft is a plist: `:task', `:session', `:text', `:from' and `:time'.
The draft waits for the user, who sends it with their other drafts
\(`patch-review/send-replies'); it never goes out by itself.
`patch-review/last-close' gives it to a UI to show.")

(defun harness-patch-review--last-close-p (set op)
  "Non-nil when OP is the user closing the last sent open thread of SET.
The thread OP closes has a sent comment, and no other thread with a sent
comment is open now.  A close of a thread of drafts is not one: no
question was waiting on it.  A close the agent makes is not either: it is
in a turn of its own, and it knows."
  (and (eq 'set-status (intern (format "%s" (plist-get op :op))))
       (equal "closed" (format "%s" (plist-get op :status)))
       (equal "user" (format "%s" (plist-get (plist-get op :author) :kind)))
       (when-let* ((thread (change-review-find-thread set (plist-get op :thread))))
         (and (cl-some (lambda (comment) (not (change-review-comment-draft-p comment)))
                       (change-review-thread-comments thread))
              (null (harness-patch-review--sent-open-threads set))))))

(defun harness-patch-review--last-close-valid-p (task-id)
  "Non-nil when a last-close draft of TASK-ID is still the review's.
The task is at work, in the working phase, and no thread with a sent
comment is open.  A task that left the phase, or one whose thread was
opened again, has no such message to send."
  (condition-case nil
      (let ((task (harness-call 'task/get task-id))
            (set (harness-patch-review--set-for task-id)))
        (and task set
             (harness-patch-review--working-task-p task)
             (null (harness-patch-review--sent-open-threads set))))
    (error nil)))

(defun harness-patch-review--last-close-draft (task)
  "Return the draft of the harness's message for TASK, or nil.
TASK has to have a session: without one the message has nowhere to go."
  (let ((session (plist-get task :session)))
    (when (and (stringp session) (not (harness-string-blank-p session)))
      (list :task (plist-get task :id)
            :session session
            :text harness-patch-review-last-close-message
            :from (harness-sender-system "review")
            :time (float-time)))))

(defun harness-patch-review--last-close-store-name (task-id)
  "Return the store document of TASK-ID's last-close draft."
  (format "patch-review-last-close/%s.json"
          (replace-regexp-in-string "[^A-Za-z0-9._-]" "_" task-id)))

(defun harness-patch-review--last-close-save (task-id draft)
  "Keep DRAFT, TASK-ID's last-close message, in the state directory.
With DRAFT nil the document goes.  A failure is logged: the message is
the user's, and must not make the close fail."
  (when (harness-method-exists-p 'store/save)
    (condition-case err
        (if draft
            (harness-call 'store/save
                          (harness-patch-review--last-close-store-name task-id) draft)
          (harness-call 'store/delete
                        (harness-patch-review--last-close-store-name task-id)))
      (error (harness-log 'warn "patch-review: the last close of %s was not kept: %s"
                          task-id (harness-error-message err))))))

(defun harness-patch-review--last-close-read (task-id)
  "Return the last-close draft of TASK-ID kept in the state directory, or nil.
It is there when the harness reloaded, or started again, while the user
had not yet sent it."
  (when (harness-method-exists-p 'store/load)
    (let ((data (ignore-errors
                  (harness-call 'store/load
                                (harness-patch-review--last-close-store-name task-id)))))
      (when (and (consp data)
                 (stringp (plist-get data :text))
                 (stringp (plist-get data :session)))
        ;; The sender's kind comes back as the string JSON kept.
        (let ((from (plist-get data :from)))
          (when (and (consp from) (plist-get from :kind))
            (setq data (plist-put data :from
                                  (plist-put from :kind (harness-sender-kind from))))))
        data))))

(defun harness-patch-review--set-last-close (task-id draft)
  "Keep DRAFT as TASK-ID's last-close draft, or forget it when nil.
Announce what changed to every UI: `patch-review/last-close' with the
draft, or with nil when it is gone.  The draft is kept in the state
directory too, for a harness that reloads while the user has not sent
it."
  (if draft
      (puthash task-id draft harness-patch-review--last-close-drafts)
    (remhash task-id harness-patch-review--last-close-drafts))
  (harness-patch-review--last-close-save task-id draft)
  (harness-emit 'patch-review/last-close task-id draft))

(defun harness-patch-review--offer-last-close (task-id)
  "Keep the message TASK-ID's last close leaves for the user to send.
Only in the working phase, and only with
`harness-patch-review-draft-on-last-close' on.  Nothing is sent: the
message waits as a draft until the user sends the drafts
\(`patch-review/send-replies') or drops it
\(`patch-review/discard-last-close')."
  (when harness-patch-review-draft-on-last-close
    (condition-case err
        (when (harness-patch-review--last-close-valid-p task-id)
          (when-let* ((draft (harness-patch-review--last-close-draft
                              (harness-call 'task/get task-id))))
            (harness-patch-review--set-last-close task-id draft)))
      (error (harness-log 'warn "patch-review: the message of %s's last close was not offered: %s"
                          task-id (harness-error-message err))))))

(defun harness-patch-review--drop-last-close (task-id)
  "Forget TASK-ID's last-close draft, telling UIs when there was one."
  (let ((had (or (gethash task-id harness-patch-review--last-close-drafts)
                 (harness-patch-review--last-close-read task-id))))
    (remhash task-id harness-patch-review--last-close-drafts)
    (harness-patch-review--last-close-save task-id nil)
    (when had
      (harness-emit 'patch-review/last-close task-id nil))))

(defun harness-patch-review--last-close-here (task-id)
  "Return TASK-ID's last-close draft while it still is the review's.
A draft that is no longer the review's -- a thread was opened again, or
the task left the working phase -- is forgotten, and nil is returned.
One the harness kept in the state directory is read when the table has
none: a reload loses the table, not the message."
  (let ((draft (or (gethash task-id harness-patch-review--last-close-drafts)
                   (harness-patch-review--last-close-read task-id))))
    (cond ((null draft) nil)
          ((harness-patch-review--last-close-valid-p task-id)
           (puthash task-id draft harness-patch-review--last-close-drafts)
           draft)
          (t (harness-patch-review--drop-last-close task-id)
             nil))))

(defun harness-patch-review--prompt-review (task text)
  "Send TASK's agent TEXT as a message of the harness's own, from \"review\".
It starts a turn as a message the user typed would, and steers one
already running (`agent/prompt').  The message says only what changed:
whether to hand the work in is the agent's and its task prompt's.  A task
with no session, or a harness that cannot prompt one, signals; a failure
to reach the agent is logged."
  (let ((session (plist-get task :session)))
    (unless (and (stringp session) (not (harness-string-blank-p session)))
      (signal 'harness-error (list "The task has no session to send its message to")))
    (unless (harness-method-exists-p 'agent/prompt)
      (signal 'harness-error (list "The harness cannot prompt a session")))
    (unless (harness-call 'session/exists-p session)
      (signal 'harness-error (list "The task's session is gone")))
    (let ((promise (harness-call-async 'agent/prompt session
                                       (list (list :type "text" :text text))
                                       (list :from (harness-sender-system "review")))))
      (when (eq (harness-promise-state promise) 'rejected)
        (signal 'harness-error (list "The message of the last close did not reach the agent")))
      (harness-catch
       promise
       (lambda (err)
         (harness-log 'warn "patch-review: the message of %s's last close was not sent: %s"
                      (plist-get task :id) (harness-error-message err)))))
    t))

(harness-defmethod patch-review/last-close (task-id)
  "Return the message TASK-ID's last close waits for the user to send, or nil.
The message is the harness's own, from \"review\": it says that the user
closed the last open thread, and no thread is left to answer.  It is a
plist of `:task', `:session', `:text', `:from' and `:time'.  A UI shows
it as a draft, which the user sends with the other drafts
\(`patch-review/send-replies') or drops with
`patch-review/discard-last-close'.  Only a task at work has one.  A
draft the review has outgrown -- a thread opened again, or the task
handed its work in -- is forgotten, and nil returned."
  (harness-patch-review--last-close-here task-id))

(harness-defmethod patch-review/discard-last-close (task-id)
  "Forget the message that TASK-ID's last thread is closed, unsent.
Return (:discarded t) when there was one, (:discarded nil) when none
waited."
  (if (harness-patch-review--last-close-here task-id)
      (progn
        (harness-patch-review--drop-last-close task-id)
        (list :discarded t))
    (list :discarded nil)))

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

(harness-declare-event 'patch-review/last-close
                       "(TASK-ID DRAFT) when the message that a task's last review thread is closed waits for the user to send it, or when it no longer does: DRAFT is (:task :session :text :from :time), or nil.")

(defvar harness-tools-handin-require-closed-threads)

(defun harness-patch-review--hand-in-blocker (task)
  "Refuse a hand-in of TASK while its review has open threads.
On `harness-tools-handin-block-functions'.  It is added only when this
module is loaded, so a harness without threads gates nothing; with
`harness-tools-handin-require-closed-threads' nil it gates nothing
either.  Return the text for the agent, naming the threads to answer."
  (when (bound-and-true-p harness-tools-handin-require-closed-threads)
    (when-let* ((open (harness-call 'patch-review/open-threads (plist-get task :id))))
      (format "hand_in: %d thread%s of this task's review %s still open: %s. They are the user's questions: answer each in its thread with a <thread id=\"THREAD_ID\"> block and close it (status=\"closed\") only when what it raises is done -- never in a batch just to hand in. Then call hand_in."
              (length open) (if (= 1 (length open)) "" "s")
              (if (= 1 (length open)) "is" "are")
              (string-join
               (mapcar (lambda (thread)
                         (format "%s (%s)"
                                 (harness-links-markdown
                                  (plist-get thread :id)
                                  (harness-links-thread-url nil (plist-get thread :id)))
                                 (or (plist-get thread :where) "the change")))
                       open)
               ", ")))))

(defun harness-patch-review--changed (set op)
  "Announce operation OP, which changed SET, if SET is a task's review.
On `change-review-changed-functions'."
  (when (harness-patch-review--set-p set)
    (harness-emit 'patch-review/changed (change-review-set-id set) op)))

(defun harness-patch-review--on-deleted (id)
  "Forget the review of task ID, which was deleted, and its last-close message."
  (remhash id harness-patch-review--sets)
  (harness-patch-review--drop-last-close id))

(defun harness-patch-review--on-done (task &optional _how)
  "Forget the last-close message of TASK, which is done."
  (when-let* ((id (plist-get task :id)))
    (harness-patch-review--drop-last-close id)))

(defun harness-patch-review--init ()
  "Follow the tasks, and put the drafts in the feedback that sends one back.
The replies the user quotes the agent's words to make are comments of
the review (`harness-patch-review--on-message'), before the tasks module
reads a message to a task as the feedback that sends it back.  The
<thread> replies typed in the words are the thread-reply module's, which
runs first."
  (add-hook 'change-review-changed-functions #'harness-patch-review--changed)
  (harness-add-filter 'agent/message #'harness-patch-review--on-message 40)
  (add-hook 'harness-tools-handin-block-functions #'harness-patch-review--hand-in-blocker)
  (harness-add-filter 'task/feedback-attachments #'harness-patch-review--on-feedback-attachments 40)
  (harness-on 'task/review #'harness-patch-review--on-review)
  (harness-on 'task/done #'harness-patch-review--on-done)
  (harness-on 'task/deleted #'harness-patch-review--on-deleted)
  (add-hook 'harness-tasks-feedback-additions-functions #'harness-patch-review--additions))

(defun harness-patch-review--shutdown ()
  "Stop following the tasks."
  (harness-remove-filter 'agent/message #'harness-patch-review--on-message)
  (remove-hook 'harness-tools-handin-block-functions #'harness-patch-review--hand-in-blocker)
  (harness-remove-filter 'task/feedback-attachments #'harness-patch-review--on-feedback-attachments)
  (remove-hook 'change-review-changed-functions #'harness-patch-review--changed)
  (remove-hook 'harness-tasks-feedback-additions-functions #'harness-patch-review--additions)
  (harness-off (cons 'task/review #'harness-patch-review--on-review))
  (harness-off (cons 'task/done #'harness-patch-review--on-done))
  (harness-off (cons 'task/deleted #'harness-patch-review--on-deleted))
  ;; The messages that waited go with the tasks' state, UIs hearing of it.
  ;; They stay in the state directory, for the harness that loads next:
  ;; the user may not have sent them.
  (clrhash harness-patch-review--last-close-drafts)
  (clrhash harness-patch-review--sets))

(harness-define-module 'patch-review
  :doc "The threads of a task's review: kept in the state directory, delivered with the feedback, answered by the agent."
  :requires '(store tasks tools-review thread-reply)
  :init #'harness-patch-review--init
  :shutdown #'harness-patch-review--shutdown)

(provide 'harness-patch-review)
;;; harness-patch-review.el ends here
