;;; harness-compaction.el --- Summarise a transcript that outgrows its window  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation cannot grow past the model's context window, and it
;; must stop well before that: the summary that replaces it has to be
;; generated with room to spare (`harness-compaction--context-reserve').  This
;; module asks the session's own model for a thorough handoff summary,
;; appends it as a `compaction' node and lets `session/messages' restart
;; the transcript from there.  The earlier nodes stay in the DAG (the
;; node's `:meta' points at the compacted head) so nothing is lost for
;; the tree view or for search.
;;
;; Automatic compaction hangs on the `agent/before-turn' filter: when
;; the last request's context exceeds window minus reserve, the turn
;; waits for the summary and then proceeds.  Providers that report
;; `:compaction hosted' compact on their own side and are left alone.
;;
;; The summarisation request has no tools.  An API provider gets the
;; transcript as ordinary messages.  A hosted-loop provider keeps the
;; conversation itself and is only sent the newest user messages, so it
;; summarises on a fork of the session's provider state (as naming
;; does): the fork starts from the real conversation, and the session's
;; own one stays untouched.  Such providers declare hosted compaction
;; and are never compacted automatically; they get here when asked to,
;; as a handoff to another provider does (see harness-handoff.el).
;;
;; A hosted-loop provider with no state to fork -- the target of a
;; switch, which owns none for this session yet -- cannot be given the
;; conversation as messages either.  It is sent it as structured text
;; inside one user message instead: all of it, or with OPTS `:context'
;; `sample' only its first and last few messages and a note of what was
;; left out, so a summary can be made on the new provider without that
;; provider's context taking the whole conversation at once.
;;
;; `compaction/status' grades how full the window is so a UI can colour
;; the token count progressively.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defconst harness-compaction--system-prompt
  "You are writing a handoff summary so that a fresh agent can continue this work without access to the conversation above.

Write a thorough, factual summary in Markdown with these sections:

1. Goals: what the user is trying to achieve, in their words where possible.
2. Decisions: choices made and the reasons behind them.
3. Files touched: every file read, created or edited, with its full path and what changed in it.
4. Current state: what works, what is unfinished, and what was being done last.
5. Open items: remaining tasks, unanswered questions, known problems.
6. Pending user request: the most recent user message(s) verbatim if they have not been answered yet.

Keep exact identifiers: file paths, function and variable names, commands, error messages, URLs, ids and numbers.  Prefer precise statements over prose.  Do not add commentary about the summary itself."
  "System prompt for the compaction summariser.")

(defconst harness-compaction--request-text
  "Summarize the conversation above for a fresh agent that will take over from here.  Follow the section list from your instructions and keep every exact identifier."
  "Final user message that asks the model for the summary.")

(defconst harness-compaction--max-tokens 4000
  "Output budget for a compaction summary, in tokens.")

(defconst harness-compaction--context-reserve 20000
  "Tokens kept free below the context window before compaction.
The room the summary request and the summary itself need, with some to
spare: `harness-compaction--max-tokens' of output plus the prompt.")

(defconst harness-compaction--levels '((0.7 . ok) (0.85 . warning) (0.95 . urgent))
  "Fractions of the usable window below which each level applies.
Anything at or above the last fraction is `critical'.")

(defconst harness-compaction--sample-head 4
  "Messages kept from the start of a `sample' compaction context.
The first turn's prompt and answer, enough to say what the work is.")

(defconst harness-compaction--sample-tail 12
  "Messages kept from the end of a `sample' compaction context.
The latest exchange is what a summary of a long session needs most.")

(defvar harness-compaction--running (make-hash-table :test 'equal)
  "Session id -> promise of the compaction in flight.")

;;;; Status

(defun harness-compaction--reserve (_session)
  "Return the context reserve that applies to SESSION."
  harness-compaction--context-reserve)

(defun harness-compaction--window (session)
  "Return the context window of SESSION's model."
  (or (plist-get session :context-window)
      (and (harness-method-exists-p 'provider/model)
           (plist-get (harness-call 'provider/model (plist-get session :model)) :context-window))
      128000))

(defun harness-compaction--usable (window reserve)
  "Return the tokens usable before compaction given WINDOW and RESERVE.
The reserve is capped at half the window so tiny models still work."
  (max 1 (- window (min reserve (/ window 2)))))

(defun harness-compaction--level (fraction)
  "Return the warning level for FRACTION of the usable window."
  (or (cdr (cl-find-if (lambda (cell) (< fraction (car cell))) harness-compaction--levels))
      'critical))

(harness-defmethod compaction/status (session-id)
  "Describe how full the context of SESSION-ID is.
Return (:context N :window N :reserve N :usable N :fraction F :level L)
where L is one of `ok', `warning', `urgent' and `critical'."
  (let* ((session (harness-call 'session/get session-id))
         (context (or (plist-get (plist-get session :usage) :context) 0))
         (window (harness-compaction--window session))
         (reserve (harness-compaction--reserve session))
         (usable (harness-compaction--usable window reserve))
         (fraction (/ (float context) usable)))
    (list :context context :window window :reserve reserve :usable usable
          :fraction fraction :level (harness-compaction--level fraction))))

(defun harness-compaction-needed-p (session)
  "Non-nil when SESSION's last context exceeded its window minus the reserve."
  (let ((context (or (plist-get (plist-get session :usage) :context) 0)))
    (> context (harness-compaction--usable (harness-compaction--window session)
                                           (harness-compaction--reserve session)))))

(defun harness-compaction-hosted-p (session)
  "Non-nil when SESSION's provider compacts on its own side."
  (let ((v (plist-get (harness-call 'provider/capabilities (plist-get session :model)) :compaction)))
    (or (eq v 'hosted) (equal v "hosted"))))

;;;; Compacting

(defun harness-compaction--trailing-user-nodes (path)
  "Return the unanswered user nodes at the end of PATH, oldest first."
  (let (out)
    (cl-loop for n in (reverse path)
             while (memq (plist-get n :kind) '(user hint))
             when (eq (plist-get n :kind) 'user) do (push n out))
    out))

(defun harness-compaction--context (context)
  "Return CONTEXT, nil or its name, as `full' or `sample'."
  (cond ((member context '(nil full "full")) 'full)
        ((member context '(sample "sample")) 'sample)
        (t (signal 'harness-error
                   (list (format "Unknown compaction context %s (use full or sample)" context))))))

(defun harness-compaction--hosted-model-p (model)
  "Non-nil when MODEL's provider keeps the conversation itself."
  (and (harness-method-exists-p 'provider/capabilities)
       (harness-json-true-p (plist-get (harness-call 'provider/capabilities model) :hosted-loop))))

(defun harness-compaction--sample-messages (messages)
  "Keep the first and last few of MESSAGES, naming what is left out.
Return (LIMITED . OMITTED): LIMITED is `harness-compaction--sample-head'
messages from the start of MESSAGES, a user message saying how many
were left out, then `harness-compaction--sample-tail' from its end.
OMITTED is that number, 0 when nothing was dropped."
  (let* ((n (length messages))
         (head harness-compaction--sample-head)
         (tail harness-compaction--sample-tail))
    (if (<= n (+ head tail))
        (cons messages 0)
      (let* ((omitted (- n head tail))
             (elision (list :role 'user
                            :content (list (list :type "text"
                                                 :text (format (concat "[The harness left out the %d messages between here"
                                                                       " and the next one, so this context is only the start"
                                                                       " and the most recent part of the conversation.]")
                                                                 omitted))))))
        (cons (append (cl-subseq messages 0 head)
                      (list elision)
                      (cl-subseq messages (- n tail)))
              omitted)))))

(defun harness-compaction--block-text (block)
  "Return BLOCK as text for a summariser sent the conversation in one message."
  (pcase (plist-get block :type)
    ("text" (or (plist-get block :text) ""))
    ("thinking" (format "[thinking] %s" (or (plist-get block :text) "")))
    ("tool_use" (format "[called %s with %s]" (plist-get block :name)
                        (condition-case nil
                            (harness-json-encode (or (plist-get block :input) :empty))
                          (error ""))))
    ("tool_result" (format "[result] %s" (or (plist-get block :content) "")))
    (_ "")))

(defun harness-compaction--messages-text (messages)
  "Return MESSAGES as structured Markdown.
A hosted loop keeps the conversation itself and is sent only the newest
user messages, so one without this session's provider state cannot be
given the transcript as ordinary messages: it goes inside one."
  (string-join
   (cl-loop for m in messages
            collect (format "### %s\n\n%s"
                            (pcase (plist-get m :role)
                              ('user "user") ('assistant "assistant")
                              (r (format "%s" r)))
                            (mapconcat #'harness-compaction--block-text
                                       (plist-get m :content) "\n\n")))
   "\n\n"))

(defun harness-compaction--with-ask (messages)
  "Return MESSAGES with the summarisation request in its final user message."
  (let ((ask (list :type "text" :text harness-compaction--request-text))
        (last (car (last messages))))
    (if (and last (eq (plist-get last :role) 'user))
        (append (butlast messages)
                (list (list :role 'user :content (append (plist-get last :content) (list ask)))))
      (append messages (list (list :role 'user :content (list ask)))))))

(defun harness-compaction--context-messages (session-id model state context)
  "Return the messages MODEL is sent to summarise SESSION-ID.
STATE is the provider state MODEL gets -- a fork of the session's own
conversation, or nil -- and CONTEXT `full' or `sample' (see
`compaction/compact').  With STATE the provider already has the
conversation; without it, `sample' keeps only the first and last few
messages.  A hosted loop without STATE is sent the context as one
message of text, since only the newest user messages ever reach it."
  (let* ((messages (harness-call 'session/messages session-id))
         (contextual (if (eq context 'sample)
                         (car (harness-compaction--sample-messages messages))
                       messages)))
    (harness-compaction--with-ask
     (if (and (not state) (harness-compaction--hosted-model-p model))
         (list (list :role 'user
                     :content (list (list :type "text"
                                          :text (harness-compaction--messages-text contextual)))))
       contextual))))

(defun harness-compaction--messages-tokens (messages)
  "Cheap token estimate for MESSAGES."
  (let ((n 0))
    (dolist (m messages n)
      (dolist (b (plist-get m :content))
        (cl-incf n (harness-estimate-tokens
                    (or (plist-get b :text)
                        (and (stringp (plist-get b :content)) (plist-get b :content))
                        "")))))))

(defun harness-compaction--finish (session-id summary old-head model usage input-tokens trailing context)
  "Record SUMMARY for SESSION-ID and return the compaction node.
OLD-HEAD is the head that was compacted, MODEL the summariser, USAGE
its usage event, INPUT-TOKENS the size of what was compacted, TRAILING
the unanswered user nodes to carry over, and CONTEXT what the
summariser was given (see `compaction/compact')."
  (let ((node (harness-call 'session/append session-id
                            (list :kind 'compaction :content summary
                                  :meta (list :compacted-head old-head :model model
                                              :context context
                                              :input-tokens input-tokens
                                              :summary-tokens (harness-estimate-tokens summary))))))
    (harness-call 'session/hint session-id
                  (format "Compacted: %s tokens → summary" (harness-format-tokens input-tokens)))
    (dolist (u trailing)
      (harness-call 'session/append session-id
                    (list :kind 'user :content (plist-get u :content) :blocks (plist-get u :blocks)
                          :meta (plist-put (copy-sequence (plist-get u :meta)) :carried-from (plist-get u :id)))))
    (harness-call 'session/usage-add session-id
                  (list :input (plist-get usage :input) :output (plist-get usage :output)
                        :cache-read (plist-get usage :cache-read) :cache-write (plist-get usage :cache-write)
                        :cost (plist-get usage :cost)
                        :context (harness-estimate-tokens summary)))
    (harness-emit 'compaction/done session-id node)
    node))

(defun harness-compaction--forked-state (session-id model)
  "Return a promise of the provider state to summarise SESSION-ID with on MODEL.
That is a fork of the session's state when MODEL's provider can continue
it and fork it (a hosted loop: Claude Code, Copilot), so the summary
comes from the real conversation without writing into it; else nil, and
MODEL gets the transcript as messages."
  (let ((state (and (harness-method-exists-p 'session/provider-state)
                    (harness-call 'session/provider-state session-id model))))
    (if (and state
             (harness-method-exists-p 'provider/fork)
             (plist-get (harness-call 'provider/capabilities model) :fork))
        (harness-catch (harness-call-async 'provider/fork model state)
                       (lambda (e)
                         (harness-log 'warn "compaction: provider fork failed, sending the transcript: %s"
                                      (harness-error-message e))
                         nil))
      (harness-resolved nil))))

(defun harness-compaction--request (session-id session model state promise context)
  "Ask MODEL for the summary of SESSION-ID, whose record is SESSION.
STATE is the provider state to send it with, CONTEXT what it is given
(`full' or `sample'), and PROMISE settles with the compaction node."
  (let* ((old-head (plist-get session :head))
         (path (harness-call 'session/nodes session-id))
         (trailing (harness-compaction--trailing-user-nodes path))
         (messages (harness-compaction--context-messages session-id model state context))
         (estimate (or (let ((c (plist-get (plist-get session :usage) :context)))
                         (and (numberp c) (> c 0) c))
                       (harness-compaction--messages-tokens messages)))
         (text "") (usage nil))
    (harness-log 'info "compaction: summarising %s with %s (%s context, %s tokens)"
                 session-id model context estimate)
    (harness-call
     'provider/complete
     (list :model model :session session
           :system harness-compaction--system-prompt
           :messages messages :tools nil :provider-state state
           :max-tokens harness-compaction--max-tokens
           :on-event
           (lambda (ev)
             (pcase (plist-get ev :type)
               ('text (setq text (concat text (plist-get ev :delta))))
               ('usage (setq usage ev))
               ('done
                (let* ((reason (plist-get ev :stop-reason))
                       (summary (string-trim text))
                       (problem (cond ((memq reason '(error cancelled))
                                       (or (plist-get ev :error) (format "%s" reason)))
                                      ((string-empty-p summary)
                                       "the model returned an empty summary"))))
                  (if problem
                      (harness-compaction--fail session-id promise problem)
                    (condition-case err
                        (harness-resolve
                         promise
                         (harness-compaction--finish
                          session-id summary old-head model usage
                          (or (plist-get usage :context)
                              (and (plist-get usage :input)
                                   (+ (plist-get usage :input) (or (plist-get usage :cache-read) 0)))
                              estimate)
                          trailing context))
                      (error (harness-compaction--fail session-id promise err))))))
               (_ nil)))))))

(harness-defmethod compaction/compact (session-id &optional opts)
  "Summarise the transcript of SESSION-ID; return a promise of the compaction node.
OPTS `:model' picks a summariser other than the session's model.  OPTS
`:context' is `full' (the default), which lets the summariser see the
whole conversation (on a fork of the session's provider state when its
provider can), or `sample', which sends it only the first and last few
messages with a note of what was left out, never the whole
conversation: a bound on what a summariser that has to be sent the
conversation as text costs.  The summary replaces the transcript for
the provider (`session/messages' restarts at the compaction node, as a
user message); unanswered user messages at the end of the transcript
are carried over after it.  A summariser that keeps the conversation
itself (a hosted loop) works on a fork of the session's provider state
when it can; one with no state of this session gets the context as one
message of text, since that is all such a provider is ever sent.  A
second call while one is running returns the running promise."
  (or (gethash session-id harness-compaction--running)
      (let* ((session (harness-call 'session/get session-id))
             (model (or (plist-get opts :model) (plist-get session :model)))
             (context (harness-compaction--context (plist-get opts :context)))
             (promise (harness-make-promise)))
        (puthash session-id promise harness-compaction--running)
        (harness-finally promise (lambda () (remhash session-id harness-compaction--running)))
        (harness-call 'session/hint session-id "Compacting context…")
        (harness-then (if (eq context 'sample)
                          ;; A sample is the point: do not hand the
                          ;; summariser the whole conversation on a fork.
                          (harness-resolved nil)
                        (harness-compaction--forked-state session-id model))
                      (lambda (state)
                        (condition-case err
                            ;; The record from before the hint: its head is
                            ;; the one compacted.
                            (harness-compaction--request session-id session model state promise context)
                          (error (harness-compaction--fail session-id promise err))))
                      (lambda (err) (harness-compaction--fail session-id promise err)))
        promise)))

(defun harness-compaction--fail (session-id promise err)
  "Reject PROMISE with ERR and tell SESSION-ID about it."
  (let ((msg (harness-error-message err)))
    (harness-log 'warn "compaction of %s failed: %s" session-id msg)
    (ignore-errors (harness-call 'session/hint session-id (format "Compaction failed: %s" msg)))
    (harness-emit 'compaction/failed session-id msg)
    (harness-reject promise err)))

;;;; Automatic compaction

(defun harness-compaction--before-turn (value next session)
  "Compact SESSION before its turn when the context is nearly full.
VALUE and NEXT are the `agent/before-turn' filter arguments.  SESSION
is read again first: a handler earlier in the chain (the fallback) may
have moved it to another model, whose window and compaction decide."
  (let ((session (or (ignore-errors (harness-call 'session/get (plist-get session :id))) session)))
    (if (or (not (plist-get value :proceed))
            (not (harness-compaction-needed-p session))
            (harness-compaction-hosted-p session))
        (funcall next value)
      (harness-then (harness-call 'compaction/compact (plist-get session :id))
                    (lambda (_node) (funcall next value))
                    (lambda (_err) (funcall next value)))))
  nil)

(defun harness-compaction--init ()
  "Hook automatic compaction into the turn loop."
  (harness-add-filter 'agent/before-turn #'harness-compaction--before-turn 20))

(harness-compaction--init)

(harness-declare-event 'compaction/done "(SESSION-ID NODE) after a compaction node is appended.")
(harness-declare-event 'compaction/failed "(SESSION-ID MESSAGE) when a compaction fails.")

(harness-define-module 'compaction
  :doc "Summarise the transcript when it nears the context window."
  :requires '(session provider agent)
  :init #'harness-compaction--init)

(provide 'harness-compaction)
;;; harness-compaction.el ends here
