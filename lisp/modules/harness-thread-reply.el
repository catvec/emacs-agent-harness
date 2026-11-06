;;; harness-thread-reply.el --- The <thread> form of a reply, and its repair  -*- lexical-binding: t; -*-

;;; Commentary:

;; A reply in a thread of a task's review can be written in the message
;; itself, by the user and the agent alike (`harness-thread-parse-blocks'):
;; <thread id="..."><quote>what it answers</quote>the reply</thread>,
;; status="closed" to close it.  The chat draws it as the card a reply in
;; a thread is, and the transcript keeps it as it was written.  This
;; module reads that form and hands what it says to the review, which
;; keeps the threads (harness-patch-review.el): the user's block in a
;; message, the words that send a task back, and the agent's block in its
;; final message, which is its answer in the thread
;; (`agent/assistant-message').  A block that names no thread the review
;; has is left as the user wrote it, for the agent to read.
;;
;; The form is strict (`harness-thread-format-example'): lowercase exact
;; tags, id and status in double quotes and nothing else in the opening
;; tag, and no <reply> wrapper.  The user's writing is never corrected:
;; it is theirs, and a block that does not parse stays prose.  A model
;; that writes it malformed is sent back over it
;; (`harness-thread-reply--repair-stop', on `agent/stop'): a message of
;; the harness's says what is wrong and, when a judge -- a cheap model --
;; can read it, shows a corrected block.  A reply that does not parse is
;; no comment, and each correction gives the model one step more to write
;; it again; a turn is corrected at most
;; `harness-thread-reply-attempts' times (2 by default), and so gets at
;; most that many extra steps.  A model that cannot get the syntax right
;; is not sent round forever: after the last correction the turn ends,
;; and a hint says the reply was left as written.
;;
;; The module is the thread reply's, not the review's: patch-review
;; requires it, and it keeps what it reads through
;; `patch-review/user-reply' and `patch-review/comment'.  Its own state
;; is only the corrections of the turn that runs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(declare-function harness-judge-ask "harness-judge" (&rest args))
(declare-function harness-patch-review--set-for "harness-patch-review" (task-id &optional create))
(declare-function harness-patch-review--block-comment "harness-patch-review" (set session-id node-id block-start))

;;;; Reading the form in a message

(defun harness-thread-reply--answerable-p (_session-id)
  "Non-nil when a message in SESSION-ID can be kept as a reply in a thread.
That is when the review module keeps threads: a task's agent answers in
the <thread> blocks of its message, and needs no tool to do it.  The
callers look the task up themselves."
  (and (harness-method-exists-p 'patch-review/comment) t))

(defun harness-thread-reply--blocks (task-id session-id blocks draft)
  "Return BLOCKS with each <thread> reply in a text block made a comment.
The comment is of TASK-ID's review: the reply becomes a thread block, as
the compose box's reply is, and the prose around it stays text, in order.
SESSION-ID is the session the message is sent in, and DRAFT says the
comments are drafts, as the replies of feedback that sends a task back
are.  A block that names no thread the review has is left as it is, with
a line in the log: the agent still reads what the user wrote."
  (mapcan
   (lambda (block)
     (if (or (harness-thread-block-p block)
             (not (equal (plist-get block :type) "text"))
             (null (harness-thread-parse-blocks (plist-get block :text))))
         (list block)
       (let ((text (plist-get block :text)) (pos 0) out)
         (dolist (tag (harness-thread-parse-blocks text))
           (let ((before (string-trim (substring text pos (plist-get tag :start)))))
             (unless (string-blank-p before)
               (push (list :type "text" :text before) out)))
           (condition-case err
               (let* ((id (harness-call 'patch-review/user-reply
                                        task-id session-id tag draft blocks))
                      (quote (plist-get tag :quote))
                      (body (plist-get tag :body))
                      (data (append (list
                                     :refs (and quote
                                                (list (list :kind "chat" :who "agent"
                                                            :label "agent's message"
                                                            :text quote)))
                                     :response body
                                     :id id)
                                    (and (member (plist-get tag :status) '("open" "closed"))
                                         (list :status (plist-get tag :status))))))
                 (push (harness-thread-block data body) out))
             (error
              (harness-log 'warn "thread-reply: a <thread> block in a message of %s was not made a comment: %s"
                           session-id (harness-error-message err))
              ;; Left as the user wrote it, for the agent to read.
              (push (list :type "text" :text (plist-get tag :raw)) out)))
           (setq pos (plist-get tag :end)))
         (let ((after (string-trim (substring text pos))))
           (unless (string-blank-p after)
             (push (list :type "text" :text after) out)))
         (nreverse out))))
   blocks))

(defun harness-thread-reply--on-message (blocks session-id info)
  "Make the <thread> replies of the user's message BLOCKS comments of a review.
An `agent/message' filter, INFO being (:from FROM ...): only the user's
own messages count, in the session of a task whose review keeps
threads.  The harness's own
messages and another session's agent's are no replies.  Each block that
names a thread is a comment in it, a draft while the task waits for
review, and the block that goes on is the thread block the chat draws,
with the thread's id.  The review keeps it, the filter's
`harness-patch-review--on-message' leaving a block that has its thread
alone.  A message the review cannot take is left as it was, and so is
one that fails."
  (let ((tagged (cl-some (lambda (block)
                           (and (equal (plist-get block :type) "text")
                                (harness-thread-parse-blocks (plist-get block :text))))
                         blocks)))
    (if (or (harness-sender-kind (plist-get info :from))
            (not tagged)
            (not (harness-method-exists-p 'patch-review/user-reply)))
        blocks
      (condition-case err
          (let ((task (and (harness-method-exists-p 'task/for-session)
                           (harness-call 'task/for-session session-id))))
            (if (not (and task (harness-thread-reply--answerable-p session-id)))
                blocks
              (harness-thread-reply--blocks
               (plist-get task :id) session-id blocks
               (equal (format "%s" (plist-get task :state)) "review"))))
        (error (harness-log 'warn "thread-reply: the <thread> replies of a message in %s were not made: %s"
                            session-id (harness-error-message err))
               blocks)))))

(defun harness-thread-reply--take-tagged-words (task-id session-id words)
  "Make the <thread> replies in WORDS drafts of the review; return the rest.
WORDS are what the user sends TASK-ID's task back with.  The comment of
each reply is a draft, as a reply in the review's box is until the
feedback that sends the task back.  A block the review cannot take stays
in the words, for the agent to read."
  (let ((blocks (harness-thread-parse-blocks words))
        (cut nil))
    (dolist (block blocks)
      (condition-case err
          (progn
            (harness-call 'patch-review/user-reply task-id session-id block t)
            (push (cons (plist-get block :start) (plist-get block :end)) cut))
        (error
         (harness-log 'warn "thread-reply: a <thread> block in feedback for %s was not made a comment: %s"
                      session-id (harness-error-message err)))))
    (let ((text words))
      (dolist (span (sort cut (lambda (a b) (> (car a) (car b)))))
        (setq text (concat (substring text 0 (car span)) (substring text (cdr span)))))
      (let ((text (string-trim (replace-regexp-in-string "\n\\(?:[ \t]*\n\\)\\{2,\\}" "\n\n" text))))
        (unless (string-blank-p text) text)))))

(defun harness-thread-reply--on-assistant-message (text session-id node-id)
  "Make the <thread> reply blocks in TEXT comments of SESSION-ID's task review.
An `agent/assistant-message' filter: TEXT is the final words of the
agent's message, NODE-ID its node.  Each block that names a thread
answers that thread, and one without an id starts a thread; status
closes or opens it.  The text is left as
the agent wrote it: the chat draws its blocks, and the transcript keeps
what the agent said for the turns after.  A block the review cannot take
is logged, and the message goes on."
  (when (and (stringp text) (string-search "<thread" text))
    (condition-case err
        (when-let* ((task (and (harness-method-exists-p 'task/for-session)
                               (harness-call 'task/for-session session-id)))
                    (id (plist-get task :id))
                    ((harness-method-exists-p 'patch-review/comment))
                    ((harness-thread-reply--answerable-p session-id)))
          (let ((set (harness-patch-review--set-for id t)))
            (dolist (block (harness-thread-parse-blocks text))
              (condition-case block-err
                  (let ((thread (plist-get block :id))
                        (status (plist-get block :status))
                        (body (harness-thread-render-text block))
                        (start (plist-get block :start)))
                    (when (or thread (not (string-blank-p body)))
                      ;; The same block of the same message, read again -- a
                      ;; node finalized twice -- is the comment it made, not
                      ;; another.
                      (unless (harness-patch-review--block-comment
                               set session-id node-id start)
                        (harness-call 'patch-review/comment id body
                                      :thread thread
                                      :status (and (member status '("open" "closed")) status)
                                      :session session-id
                                      :message node-id
                                      :block-start start))))
                (error
                 (harness-log 'warn "thread-reply: thread block in message %s of %s not recorded: %s"
                              node-id session-id (harness-error-message block-err)))))))
      (error (harness-log 'warn "thread-reply: the thread blocks of a message in %s were not recorded: %s"
                          session-id (harness-error-message err)))))
  text)

;;;; Sending a malformed reply in a thread back

(defcustom harness-thread-reply-attempts 2
  "Most corrections one turn gets for its malformed <thread> replies.
An agent that answers a thread in its message must write the strict
form (`harness-thread-format-example').  A reply that does not parse is
no comment, so the harness tells the agent what is wrong and gives it a
step more to write the reply again.  Each correction is one such step,
and a turn is corrected at most this many times, so it gets at most
this many extra steps.  After that the turn ends, and a hint says the
reply was left as written: a model that cannot get the syntax right is
not sent round forever.  Nil or 0 turns the correction off."
  :type '(choice (const :tag "No correction" nil)
                 (integer :tag "Corrections a turn gets"))
  :group 'harness)

(defconst harness-thread-reply--repair-judge-max 2
  "Most malformed blocks a judge is asked to correct in one message.")

(defconst harness-thread-reply--repair-judge-system
  (concat "You repair the markup of replies in review threads written by an AI agent. "
          "Change the syntax only, never the meaning or the words. "
          "Answer with the corrected block between <fixed> and </fixed> and nothing else.")
  "The system prompt of the judge that suggests a corrected thread block.")

(defvar harness-thread-reply--repairs (make-hash-table :test 'equal)
  "Session id -> the malformed thread replies of its running turn.
A plist: `:node' is the last assistant node sent back, `:count' how
many times the turn was, and `:exhausted' says its attempts ran out.
`agent/turn-ended' clears it.")

(defun harness-thread-reply--last-reply (session-id)
  "Return (NODE-ID . TEXT) of the last assistant message of SESSION-ID, or nil.
That is the last one after the last message the user sent; steering
messages within the turn, the harness's own included, do not end the
search."
  (catch 'found
    (dolist (node (reverse (harness-call 'session/nodes session-id)))
      (pcase (plist-get node :kind)
        ('assistant (throw 'found (cons (plist-get node :id)
                                        (or (plist-get node :content) ""))))
        ('user (unless (harness-json-true-p (plist-get (plist-get node :meta) :steering))
                 (throw 'found nil)))))
    nil))

(defun harness-thread-reply--repair-prompt (problem)
  "Return the judge's question about PROBLEM, a malformed thread block."
  (format (concat "The harness reads a reply in a review thread in one strict form:\n\n%s\n\n"
                  "Rules:\n"
                  "- Tag names are lowercase: <thread>, <quote>, </quote>, </thread>.\n"
                  "- The opening tag has only id and status attributes, in double quotes; "
                  "id is optional, and status is \"open\" or \"closed\".\n"
                  "- The quote is optional and comes first; the answer follows </quote> "
                  "with no <reply> or other wrapper.\n"
                  "- Keep the id the agent wrote, or leave it out when it wrote none; "
                  "never write THREAD_ID.\n"
                  "- Do not change the agent's words: fix only the markup.\n\n"
                  "The agent wrote:\n\n```\n%s\n```\n\n"
                  "It was rejected because:\n%s\n\n"
                  "Return the corrected block between <fixed> and </fixed>, and nothing else.")
          harness-thread-format-example
          (harness-truncate-end (plist-get problem :raw) 6000)
          (mapconcat (lambda (finding) (concat "- " finding))
                     (plist-get problem :problems) "\n")))

(defun harness-thread-reply--repair-block-p (text)
  "Non-nil when TEXT is exactly one strict reply in a thread."
  (when-let* ((blocks (and (stringp text) (harness-thread-parse-blocks text))))
    (and (= 1 (length blocks))
         (equal (string-trim text)
                (string-trim (plist-get (car blocks) :raw))))))

(defun harness-thread-reply--repair-id (text)
  "Return the thread id TEXT names in its opening tag, tolerantly, or nil."
  (when (string-match "\\bid[ \t]*=[ \t]*['\"]?\\([A-Za-z0-9][A-Za-z0-9_.-]*\\)" text)
    (match-string 1 text)))

(defun harness-thread-reply--repair-parse (text)
  "Return the corrected block between <fixed> and </fixed> in TEXT, or nil.
Only a whole, strict reply in a thread is a corrected block."
  (when (and (stringp text)
             (string-match "<fixed>\\(\\(?:.\\|\n\\)*?\\)</fixed>" text))
    (let ((fixed (string-trim (match-string 1 text))))
      (when (harness-thread-reply--repair-block-p fixed)
        fixed))))

(defun harness-thread-reply--repair-suggest (session-id problem)
  "Return a promise of a corrected block for PROBLEM, or nil.
PROBLEM is one that `harness-thread-find-malformed' returned.  A judge
\(`harness-judge-ask'), a cheap model, reads it and the strict form; no
judge, or an answer that is no strict block, gives nil."
  (condition-case err
      (progn
        (require 'harness-judge)
        (harness-then
         (harness-judge-ask
          :session session-id
          :system harness-thread-reply--repair-judge-system
          :prompt (harness-thread-reply--repair-prompt problem)
          :parse #'harness-thread-reply--repair-parse
          :label "thread reply repair"
          :job "thread reply repair"
          :max-tokens 1000
          :retry-max-tokens 1500
          :timeout 20)
         (lambda (answer)
           (let* ((value (plist-get answer :value))
                  (id (and value (harness-thread-reply--repair-id value))))
             ;; It corrects the syntax, not the thread: the id stays the
             ;; one the agent named, or absent for a new thread, and is
             ;; never the format's placeholder.
             (when (and (harness-thread-reply--repair-block-p value)
                        (not (equal (downcase (or id "")) "thread_id"))
                        (equal (or (harness-thread-reply--repair-id
                                    (plist-get problem :raw))
                                   "")
                               (or id "")))
               value)))))
    (error
     (harness-log 'warn "thread-reply: the thread reply repair judge failed: %s"
                  (harness-error-message err))
     (harness-resolved nil))))

(defun harness-thread-reply--repair-suggestions (session-id malformed)
  "Return a promise of corrected blocks for MALFORMED, or nil for each.
At most `harness-thread-reply--repair-judge-max' blocks are put to the
judge.  A block that is not closed is left to the message: its words are
not all there for a judge to correct.  So is one that copied the
placeholder id, which no judge can know: the message tells the agent to
name the thread it answers."
  (let* ((fixable (cl-remove-if
                   (lambda (problem)
                     (or (plist-get problem :unclosed)
                         (equal (downcase (or (harness-thread-reply--repair-id
                                               (plist-get problem :raw))
                                              ""))
                                "thread_id")))
                   malformed))
         (asked (cl-subseq fixable 0 (min (length fixable)
                                          harness-thread-reply--repair-judge-max))))
    (harness-then
     (harness-all (mapcar (lambda (problem)
                            (harness-thread-reply--repair-suggest session-id problem))
                          asked))
     (lambda (fixed) (delq nil fixed)))))

(defun harness-thread-reply--repair-message (malformed suggestions)
  "Return what a model that wrote MALFORMED thread blocks is told.
SUGGESTIONS are corrected blocks from a judge, or nil."
  (let* ((fixed (cl-remove-if-not #'stringp suggestions))
         (problems (cl-remove-duplicates
                    (apply #'append
                           (mapcar (lambda (problem) (plist-get problem :problems)) malformed))
                    :test #'equal)))
    (string-join
     (delq nil
           (list
            "Your reply in a thread was not written in the strict <thread> form, so the harness did not record it as a comment in the thread."
            (format (concat "A reply in a thread is exactly this, changing only THREAD_ID "
                            "and the words:\n\n```\n%s\n```")
                    harness-thread-format-example)
            (concat "Use status=\"closed\" in the opening tag to close the thread. The tags are "
                    "lowercase; id and status are the only attributes, each with a double-quoted "
                    "value. The answer goes between </quote> and </thread>: do not wrap it in "
                    "<reply>, and do not use an <id> tag. If you are starting a new thread, "
                    "leave id out.")
            (concat "What is wrong:\n"
                    (mapconcat (lambda (problem) (concat "- " problem)) problems "\n"))
            (when fixed
              (concat (if (= 1 (length fixed))
                          "A model suggests this corrected block (keep your own words):"
                        "A model suggests these corrected blocks (keep your own words):")
                      "\n\n"
                      (mapconcat (lambda (block) (format "```\n%s\n```" block)) fixed "\n\n")))
            "Write the reply again in this form; review_threads lists the threads and their ids, and there is no tool to answer with."))
     "\n\n")))

(defun harness-thread-reply--repair-answer (session)
  "Return a promise of what follows SESSION's stop, for a malformed thread reply.
That is nil when there is nothing to correct, when the turn has had
`harness-thread-reply-attempts' corrections, or when the last assistant
node was already answered; else the answer of `agent/stop':
\(:stop nil :message TEXT :from SENDER).  The message names what is
wrong and, when a judge answers in time, the block it suggests."
  (let* ((sid (plist-get session :id))
         (limit (let ((attempts harness-thread-reply-attempts))
                  (and (natnump attempts) (> attempts 0) attempts)))
         (task (and sid limit (harness-method-exists-p 'task/for-session)
                    (ignore-errors (harness-call 'task/for-session sid))))
         (reply (and task (harness-thread-reply--answerable-p sid)
                     (harness-thread-reply--last-reply sid)))
         (text (cdr reply))
         (malformed (and (stringp text)
                         (let ((case-fold-search t))
                           (string-match-p "<\\/?thread" text))
                         (harness-thread-find-malformed text)))
         (state (gethash sid harness-thread-reply--repairs))
         (count (or (plist-get state :count) 0)))
    (cond
     ((or (null malformed) (null reply)) (harness-resolved nil))
     ;; The same message is not sent back over twice.
     ((equal (plist-get state :node) (car reply)) (harness-resolved nil))
     ((>= count limit)
      (unless (plist-get state :exhausted)
        (harness-log 'warn "thread-reply: %s wrote malformed thread replies %d time(s); leaving the turn to end"
                     sid count)
        (ignore-errors
          (harness-call 'session/hint
                        sid
                        (format (concat "A reply in a thread was malformed, and the harness did not "
                                        "ask for another correction after %d attempt%s; it is left as written.")
                                count (if (= count 1) "" "s"))))
        (puthash sid (plist-put (copy-sequence (or state '())) :exhausted t)
                 harness-thread-reply--repairs))
      (harness-resolved nil))
     (t
      (harness-then
       (harness-thread-reply--repair-suggestions sid malformed)
       (lambda (suggestions)
         (harness-log 'info "thread-reply: sending %s back over %d malformed thread reply block(s)"
                      sid (length malformed))
         (puthash sid (list :node (car reply) :count (1+ count))
                  harness-thread-reply--repairs)
         (list :stop nil
               :message (harness-thread-reply--repair-message malformed suggestions)
               :from (harness-sender-system "thread replies"))))))))

(defun harness-thread-reply--repair-stop (value next session)
  "Send a model that wrote malformed thread replies back (`agent/stop').
VALUE is what the chain has so far; only a model that stopped on its
own is checked, and its message is the harness's own, from \"thread
replies\".  NEXT goes on with the answer, or with VALUE when there is
nothing to correct; a failure here lets the model stop."
  (if (not (harness-json-true-p (plist-get value :stop)))
      (funcall next value)
    (harness-then
     (harness-thread-reply--repair-answer session)
     (lambda (answer) (funcall next (or answer value)))
     (lambda (err)
       (harness-log 'error "thread-reply: the malformed thread reply check failed: %s"
                    (harness-error-message err))
       (funcall next value)))))

(defun harness-thread-reply--on-turn-ended (session-id &optional _reason)
  "Forget the malformed thread replies of SESSION-ID's finished turn."
  (remhash session-id harness-thread-reply--repairs))

;;;; The module

(defun harness-thread-reply--init ()
  "Read the <thread> form in messages, and send a malformed agent reply back.
The user's replies are made comments before the review's own filter
registers the thread blocks of the compose box
\(`harness-patch-review--on-message', at priority 40); the agent's final
message is answered in its threads as it is written."
  (harness-add-filter 'agent/message #'harness-thread-reply--on-message 35)
  (harness-add-filter 'agent/assistant-message #'harness-thread-reply--on-assistant-message 20)
  (harness-add-filter 'agent/stop #'harness-thread-reply--repair-stop 60)
  (harness-on 'agent/turn-ended #'harness-thread-reply--on-turn-ended))

(defun harness-thread-reply--shutdown ()
  "Stop reading the <thread> form in messages and correcting it."
  (harness-remove-filter 'agent/message #'harness-thread-reply--on-message)
  (harness-remove-filter 'agent/assistant-message #'harness-thread-reply--on-assistant-message)
  (harness-remove-filter 'agent/stop #'harness-thread-reply--repair-stop)
  (harness-off (cons 'agent/turn-ended #'harness-thread-reply--on-turn-ended))
  (clrhash harness-thread-reply--repairs))

(harness-define-module 'thread-reply
  :doc "Replies in a thread written in a message: the strict <thread> form, read for the review, and a malformed reply sent back until it is right."
  :requires '(agent session tools)
  :init #'harness-thread-reply--init
  :shutdown #'harness-thread-reply--shutdown)

(provide 'harness-thread-reply)
;;; harness-thread-reply.el ends here
