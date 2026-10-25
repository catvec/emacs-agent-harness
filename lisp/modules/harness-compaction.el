;;; harness-compaction.el --- Make a conversation that outgrew its window small again  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation cannot grow past the model's context window, and it
;; must stop well before that: the summary that replaces it has to be
;; generated with room to spare (`harness-compaction--context-reserve').
;; This module replaces the conversation with something much smaller,
;; appends that as a `compaction' node and lets `session/messages'
;; restart the transcript from there.  The earlier nodes stay in the DAG
;; (the node's `:meta' points at the compacted head) so nothing is lost
;; for the tree view or for search.
;;
;; What replaces it is one of `harness-compaction-kinds', the ways a
;; handoff to another provider carries a conversation over
;; (harness-handoff.el), here on the session's own provider:
;;
;; - `summary': the session's own model writes a thorough handoff
;;   summary of the whole conversation.  It reads all of it again, from
;;   the prompt cache while that lasts and uncached once it lapsed.
;; - `brief': a cheap model (`harness-compaction-brief-model', by
;;   default the simple tier of the session's provider) summarises the
;;   conversation's narrative, as a handoff's new model does
;;   (`compact-new'): every user and assistant message in order, each
;;   tool call and result in one line naming what it did or answered,
;;   never a payload.  Cheap however long the conversation, since the
;;   payloads are most of it, but the details they carried are not in
;;   it, which the summary's caveat says.
;; - `transcript': the whole transcript goes to a file in the session's
;;   directory (`session/write-transcript', the handoff's), and the node
;;   is a note telling the model where it is and to read what it needs
;;   of it.  No request at all.
;; - `fresh': nothing of the conversation is carried over, not even a
;;   summary; the node is a note saying so, and telling the model to
;;   look back at what it needs with the session_history tool.  No
;;   request either, and the smallest context of all.
;; - `truncate': the oldest nodes are dropped and the most recent are
;;   kept, verbatim, whole tool exchanges, after a note saying what was
;;   cut; for a conversation too big to summarise.  No request either.
;;
;; Whatever the kind, the conversation it replaces stays on the
;; session's path, where the session_history tool searches and reads it
;; (harness-tools-sessions.el): every note and summary ends by saying so
;; when the session has the tool (`harness-compaction--history-note').
;;
;; Automatic compaction makes `harness-compaction-kind'; by hand (the
;; UI's `harness-compact', or the panel of a session whose prompt cache
;; expired) any kind, with what each costs (`compaction/estimate').  A
;; message to a session whose prompt cache went cold makes one of them
;; first, or carries on, as the cowboy module decides (harness-cowboy.el).
;;
;; What the provider cached of the old transcript is of no use to the
;; new one, so the session's prompt cache stamp goes too (`:cache-reset'
;; to `session/usage-add'), whichever model summarised: a new
;; conversation has nothing cached to lose.  A hosted loop (Claude Code,
;; Copilot) holding the session's conversation would rather go on with
;; it, the compaction one more message of it, and so would save
;; nothing: its provider state goes (`session/set-provider-state'), and
;; its next request starts a new conversation that the compaction opens.
;;
;; Automatic compaction hangs on two filters, and in both the context
;; that counts is the last request's: when it exceeds window minus
;; reserve, the turn waits for the compaction and then proceeds.
;; `agent/before-turn' compacts before a turn starts.  `agent/step',
;; the boundary between two steps of a turn that runs, compacts in the
;; middle of one (`harness-compaction-mid-turn', on unless turned off):
;; a turn of many tool calls -- an unattended task's -- can outgrow the
;; window long before it ends, and would otherwise run on past the limit
;; until the next message.  Such a compaction ends in a note telling the
;; model its work is not finished, so it carries on from the summary.  A
;; compaction that did not bring the context under the limit, or failed,
;; is not made again at once (`harness-compaction--mid-turn-due-p'): it
;; would repeat at every step.  Providers that report
;; `:compaction hosted' compact on their own side and are left alone.
;; A compaction asked for while a turn runs (`compaction/compact' OPTS
;; `:queue' or `:interrupt') is recorded in `harness-compaction--pending'
;; and runs at the turn's next boundary, as a handoff waiting on a turn
;; does (harness-handoff.el): the `agent/step' and `agent/before-turn'
;; gates hold that boundary, and `agent/turn-ended' runs it when the
;; turn ends first.
;;
;; A message that comes to a session while a compaction of it runs goes
;; on with the compacted conversation: nothing asks about it, no queue
;; sends it later, and the model answers it right after the compaction.  A
;; turn that starts meanwhile waits at the `agent/before-turn' gate
;; (`harness-compaction--wait-gate', ahead of the cold-cache question,
;; which the compaction under way answers already -- it leaves nothing
;; cold -- and of the automatic compaction), showing the session as
;; compacting; and a message sent to a turn that waits for a compaction
;; waits with it (the sync filter `agent/hold', which
;; `harness-compaction--on-hold' answers), and is recorded after the
;; compaction, as the user's next message (harness-agent.el).  Recorded
;; meanwhile it would lie before the compaction node, where the model
;; never reads it, and a turn that ran beside the compaction would be
;; buried by it: the node comes after the whole exchange, and the
;; conversation restarts there.  Until then such a message is no part
;; of the transcript, so the session lists it with the messages that
;; wait (`agent/show-waiting', `harness-compaction-show-waiting'): a UI
;; draws it as a queued message, above its compose box, with the buttons
;; that take it back, and it leaves the list as it is recorded.
;;
;; The summarisation request has no tools.  An API provider gets the
;; transcript as ordinary messages.  A hosted-loop provider keeps the
;; conversation itself and is only sent the newest user messages, so it
;; summarises on a fork of the session's provider state (as naming
;; does): the fork starts from the real conversation, and the session's
;; own one stays untouched until the summary replaces it.  Such
;; providers declare hosted compaction and are never compacted
;; automatically; they get here when asked to, as a handoff to another
;; provider does (see harness-handoff.el).
;;
;; A hosted-loop provider with no state to fork -- the target of a
;; switch, which owns none for this session yet -- cannot be given the
;; conversation as messages either.  It is sent it as structured text
;; inside one user message instead: all of it, or with OPTS `:context'
;; `sample' the conversation's narrative -- every user and assistant
;; message, each tool call and result in one line -- so a summary can be
;; made on the new provider without that provider's context taking the
;; whole conversation, payloads and all, at once.
;;
;; `compaction/status' grades how full the window is so a UI can colour
;; the token count progressively.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-provider-fallback-context-window)

(declare-function harness-agent-strip-result-images "harness-agent" (messages))
(declare-function harness-agent-waiting-text "harness-agent" (texts))

(defconst harness-compaction-kinds '(summary brief transcript fresh truncate)
  "The kinds of compaction: what stands in for the conversation from then on.
`summary' is a summary the session's model writes from the whole
conversation; `brief' one `harness-compaction-brief-model' writes from
the conversation's narrative -- every user and assistant message, each
tool call and result in one line -- cheap however long the
conversation, since the payloads are left out, but without the details
they carried; `transcript' is the whole
conversation written to a file in the session's directory, with a note
telling the model to read what it needs of it, which takes no request;
`fresh' carries nothing over but a note saying so, which takes no
request either; `truncate' drops the oldest nodes and keeps the most
recent ones as they were, which takes no request either.  The first
three are the handoff's `compact', `compact-new' and `transcript' (see
harness-handoff.el), on the session's own provider.  After any of them
the model can still search and read the conversation it replaced with
the session_history tool.")

(defcustom harness-compaction-kind 'summary
  "How a conversation that nears its model's context window is compacted.
`summary' (the default) has the session's model summarise the whole
conversation, which reads all of it again; `brief' has a cheap model
\(`harness-compaction-brief-model') summarise the conversation's
narrative -- every user and assistant message, tool calls and results
each in a line -- which costs little however long the conversation but
leaves the payloads they carried out; `transcript' writes the whole
conversation to a
file in the session's directory and leaves the model a note to read
what it needs of it, which costs no request at all; `fresh' carries
nothing over, and the model looks back at what it needs of the
conversation with the session_history tool; `truncate' drops the oldest
messages and keeps the most recent ones as they were, for a conversation
too big to summarise.  Automatic compaction makes
this kind; compacting by hand (`harness-compact', or the panel above
the message box of a session whose prompt cache expired) offers every
kind, with what each costs."
  :type '(choice (const :tag "Summary: the session's model summarises the whole conversation" summary)
                 (const :tag "Brief summary: a cheap model summarises the narrative, tool calls in brief" brief)
                 (const :tag "Transcript: a file the model reads what it needs of" transcript)
                 (const :tag "Fresh start: nothing carried over; the model looks back when it needs to" fresh)
                 (const :tag "Cut old context: drop the oldest messages and keep the newest as they are" truncate))
  :safe (lambda (v) (memq v '(summary brief transcript fresh truncate)))
  :group 'harness)

(defcustom harness-compaction-brief-model 'auto
  "Model that writes a brief summary, as PROVIDER:NAME, or `auto'.
A brief summary is made from the conversation's narrative -- every
user and assistant message, each tool call and result in a line -- a
job a cheap model does about as well as any.  `auto'
\(the default) asks the session's provider for its `simple' tier (see
`harness-provider-tier-model'), falling back to the session's own model
when the provider names none.  A PROVIDER:NAME forces that model, and
nil uses the session's own model."
  :type '(choice (const :tag "The session provider's simple model" auto)
                 (const :tag "The session's own model" nil)
                 (string :tag "Model" :names model))
  :safe (lambda (v) (or (memq v '(auto nil)) (stringp v)))
  :group 'harness)

(defcustom harness-compaction-mid-turn t
  "Non-nil to compact in the middle of a turn that outgrew its context limit.
A turn that makes many tool calls -- an unattended task's -- can grow its
context past the limit (the window less the reserve; a task's window is
capped by `harness-tasks-context-limit') long before it ends.  With this
on, the default, the conversation is compacted as `harness-compaction-kind'
says at the first step boundary after the context went over the limit, no
matter what the turn is in the middle of: the turn waits for the
compaction and carries on from it, its model told that its work is not
finished.  With nil the conversation is compacted only before the next
turn, so a turn runs on past the limit until it is over.  A provider that
compacts on its own side (Claude Code, Copilot) is left alone either way."
  :type 'boolean :safe #'booleanp :group 'harness)

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

(defconst harness-compaction--narrative-line-max 200
  "Longest a tool call or result line runs in a narrative summary.
The narrative names what each call asked and what it answered in a line
\(`harness-compaction--narrative-messages'): a payload would be the
conversation again.")

(defconst harness-compaction--narrative-param-keys
  '(:file_path :path :file :dir :directory :command :cmd :query :pattern
    :url :question :prompt :message :name :tool :id)
  "Tool input keys a narrative names first, in the order it tries them.
The first one a call holds says what the call was about: the file it
read or wrote, the command it ran, the question it asked.")

(defconst harness-compaction--verbatim-max-chars 4000
  "Longest a verbatim first or last message is kept in a compaction.
The point is that a short message survives a summary intact; a
pathological one is truncated rather than carried whole.")

(defconst harness-compaction--summary-output 2000
  "Tokens a summary is taken to come to when its cost is estimated.
A thorough one runs to one or two thousand, short of
`harness-compaction--max-tokens', which bounds it.")

(defconst harness-compaction--truncate-keep 0.7
  "Fraction of the usable window a `truncate' compaction keeps, at most.
The most recent nodes are kept until their tokens would pass this much
of the window; the rest, oldest first, are dropped.")

(defvar harness-compaction--running (make-hash-table :test 'equal)
  "Session id -> promise of the compaction in flight.")

(defvar harness-compaction--pending (make-hash-table :test 'equal)
  "Session id -> the compaction waiting for that session's next boundary.
A plist (:opts OPTS :interrupt BOOL :running PROMISE), `:running' set
once it is under way.")

(defconst harness-compaction--mid-turn-note
  "Harness note: this compaction was made in the middle of your turn, because the conversation reached its context limit while you were working, so the work it describes is not finished.  Carry on with it from where it stood, without waiting for the user; check the files and the state first if you are unsure where you were."
  "Ends a compaction made in the middle of a turn (`harness-compaction-mid-turn').
Nothing follows it in what the model is sent next, a message of the
user's being what ends a compaction before a turn, so it is told to go
on rather than to wait to be asked.")

(defconst harness-compaction--mid-turn-cooldown 3
  "Step boundaries a turn lets pass after a mid-turn compaction that did not help.
A compaction in the middle of a turn that left the context over the
limit, or failed, is not tried again at the very next boundary: a
conversation that stays over a small limit would be compacted at every
step, and a summariser that keeps failing asked every time.  It is
tried again at the third boundary over the limit after it, the sixth
after a second try that did not help, and so on, up to the twenty-fourth;
a boundary that finds the context under the limit starts it over
\(`harness-compaction--mid-turn-due-p').")

(defvar harness-compaction--mid-turn (make-hash-table :test 'equal)
  "Session id -> how the running turn's compactions in its middle went.
A plist (:tries N :since N): how many tries in a row left the context
over the limit or failed, and how many step boundaries over the limit
have passed since the latest.  Gone once a boundary finds the context
under the limit, and when the turn ends.  Kept beside the other tables
of this module.")

(defun harness-compaction-busy-p (session-id)
  "Non-nil while a compaction of SESSION-ID is under way."
  (and (gethash session-id harness-compaction--running) t))

;;;; Kinds

(defun harness-compaction--kind (kind &optional context)
  "Return KIND, a symbol or its name, as one of `harness-compaction-kinds'.
Without KIND, CONTEXT (see `compaction/compact') decides: a summary of
a `sample' is a `brief' one, of anything else a `summary'."
  (let ((k (cond ((or (null kind) (equal kind ""))
                  (if (eq (harness-compaction--context context) 'sample) 'brief 'summary))
                 ((stringp kind) (intern kind))
                 (t kind))))
    (unless (memq k harness-compaction-kinds)
      (signal 'harness-error
              (list (format "Unknown compaction kind %s (use summary, brief, transcript, fresh or truncate)" kind))))
    k))

(defun harness-compaction--model-label (model)
  "Return the label people read for MODEL."
  (or (and model (harness-method-exists-p 'provider/model)
           (plist-get (ignore-errors (harness-call 'provider/model model)) :label))
      model))

(defun harness-compaction--brief-model (session)
  "Return the model that writes SESSION's brief summary.
See `harness-compaction-brief-model'."
  (let ((model (plist-get session :model))
        (choice harness-compaction-brief-model))
    (cond ((or (eq choice 'auto) (equal choice "auto"))
           (or (and model (harness-method-exists-p 'provider/tier-model)
                    (ignore-errors (harness-call 'provider/tier-model model 'simple)))
               model))
          ((and (stringp choice) (not (string-empty-p choice))) choice)
          (t model))))

(defun harness-compaction--brief-caveat (model)
  "Return the note that ends a brief summary MODEL wrote.
The summary had the conversation's narrative to go by, with tool calls
and results named in a line rather than in full, so the model that goes
on from it is told what it lacks, and to look again rather than trust
it, as after a handoff (harness-handoff.el)."
  (format (concat "Harness note: %s wrote this summary from the conversation's user and assistant"
                  " messages, with each tool call and result named in a line rather than in full, so what"
                  " tools read and wrote is not in it.  Treat it as possibly incomplete: re-investigate"
                  " anything you are unsure of -- read the files, check the state -- before you act on it.")
          (harness-compaction--model-label model)))

(defun harness-compaction--transcript-note (file lines)
  "Return the note that stands for a conversation written to FILE, of LINES lines.
It opens the conversation from then on, so it says what the model
starts without and how to get it back: the end of the file first,
where the work stands, the start for the task, then the rest as needed
rather than all of it, which would bring the whole conversation back."
  (format (concat "The conversation so far was compacted into a file, to keep the context small: %s (%d lines,"
                  " the whole conversation, oldest first).  You start without it, so before you answer, read its"
                  " end, to see where the work stands, and its start, for the task; then read or search the rest"
                  " as you need it, rather than all of it at once.")
          (if (file-remote-p file) (file-local-name file) file)
          lines))

(defconst harness-compaction-history-tool "session_history"
  "The tool that searches and reads a conversation from before a compaction.
See harness-tools-sessions.el.")

(defun harness-compaction-history-p (session-id)
  "Non-nil when SESSION-ID's model has the session_history tool.
The notes a compaction leaves point at it only then."
  (and session-id
       (harness-method-exists-p 'tools/list)
       (condition-case nil
           (cl-some (lambda (spec) (equal (plist-get spec :name) harness-compaction-history-tool))
                    (harness-call 'tools/list session-id))
         (error nil))
       t))

(defun harness-compaction--history-note ()
  "Return the line that ends a compaction: what it replaced is still on record."
  (format (concat "Harness note: the conversation this stands in for is still on record.  When you need"
                  " something it left out -- what was asked, decided, tried or found -- search and read it"
                  " with the %s tool rather than guessing.")
          harness-compaction-history-tool))

(defun harness-compaction--fresh-note (count tokens history)
  "Return the note that opens a conversation started afresh.
COUNT messages of about TOKENS tokens came before it and are not
carried over.  HISTORY non-nil says the model has the session_history
tool to look back at them with; without it, the user is the one to ask."
  (concat
   (format (concat "This conversation starts afresh, to keep the context small: the %d message%s before"
                   " this point (about %s tokens) are not carried over, not even as a summary.")
           count (if (= count 1) "" "s") (harness-format-tokens tokens))
   "  "
   (if history
       (format (concat "You start without them, so before you answer, look back at what you need of them"
                       " with the %s tool -- the task, what was decided and done, where the work stood --"
                       " rather than guessing, and check the files and the state before you act.")
               harness-compaction-history-tool)
     (concat "You start without them: check the files and the state before you act, and ask the user"
             " for what you need of the earlier conversation rather than guessing."))))

;;;; Status

(defun harness-compaction--reserve (_session)
  "Return the context reserve that applies to SESSION."
  harness-compaction--context-reserve)

(defun harness-compaction--window (session)
  "Return the context window of SESSION's model.
The catalogue gives every model one (see `provider/model'); without a
catalogue it is `harness-provider-fallback-context-window'."
  (or (plist-get session :context-window)
      (and (harness-method-exists-p 'provider/model)
           (plist-get (harness-call 'provider/model (plist-get session :model)) :context-window))
      (bound-and-true-p harness-provider-fallback-context-window)
      200000))

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

;;;; Estimates

(defun harness-compaction--catalogue (model)
  "Return MODEL's catalogue entry, or nil."
  (and model (harness-method-exists-p 'provider/model)
       (ignore-errors (harness-call 'provider/model model))))

(defun harness-compaction--cost (model usage)
  "Return what USAGE costs on MODEL at list prices, in US dollars, or nil.
USAGE has `:input' `:output' `:cache-read' `:cache-write' token counts.
Nil when the catalogue does not price MODEL.  A model whose rates
change with the clock is priced at the current ones (`usage/price')."
  (let ((entry (harness-compaction--catalogue model)))
    (cond ((not (or (plist-get entry :pricing) (plist-get entry :pricing-fn))) nil)
          ((harness-method-exists-p 'usage/price)
           (ignore-errors (harness-call 'usage/price model usage)))
          (t (let ((pricing (plist-get entry :pricing)))
               (/ (cl-loop for k in '(:input :output :cache-read :cache-write)
                           sum (* (or (plist-get usage k) 0) (or (plist-get pricing k) 0)))
                  1e6))))))

(defun harness-compaction--uncached-key (model)
  "Return the price key MODEL's input is billed at when nothing is cached.
A request that misses the cache writes it again where the provider
charges for that (Anthropic's cache writes cost more than plain input),
and pays the plain input price where it does not (DeepSeek's cost
nothing extra): `:cache-write' when that price is the higher, else
`:input'."
  (let* ((pricing (plist-get (harness-compaction--catalogue model) :pricing))
         (write (plist-get pricing :cache-write))
         (input (plist-get pricing :input)))
    (if (and (numberp write) (or (not (numberp input)) (> write input))) :cache-write :input)))

(defun harness-compaction--resend (model tokens cached)
  "Return what sending TOKENS of context to MODEL costs, or nil.
CACHED non-nil reads them from MODEL's prompt cache, else they go
uncached (`harness-compaction--uncached-key')."
  (harness-compaction--cost model (list (if cached :cache-read (harness-compaction--uncached-key model))
                                        tokens)))

(harness-defmethod compaction/resend-cost (session-id)
  "Say what sending SESSION-ID's context costs, read from the cache and not.
The answer is (:context N :model MODEL :cached USD :uncached USD), at
list prices (`usage/price', so a time-of-day price applies): what the
next request costs to send N tokens of context from the model's prompt
cache, and what it costs when nothing is cached -- the higher of the
cache-write and the input price, as `compaction/estimate' prices a
summary that reads it all.  A price is nil where the catalogue has none.
N is the last request's context, else an estimate of the transcript's.
Keeping a cache warm (harness-cache-warm.el) weighs the one against the
other."
  (let* ((session (harness-call 'session/get session-id))
         (model (plist-get session :model))
         (context (let ((c (plist-get (plist-get session :usage) :context)))
                    (if (and (numberp c) (> c 0)) c
                      (harness-compaction--messages-tokens (harness-call 'session/messages session-id))))))
    (list :context context :model model
          :cached (harness-compaction--resend model context t)
          :uncached (harness-compaction--resend model context nil))))

(defun harness-compaction--warm-p (session)
  "Non-nil while SESSION's prompt cache lasts for its own model.
See `session/get''s `:cache'."
  (let ((cache (plist-get session :cache)))
    (and (numberp (plist-get cache :expires))
         (> (plist-get cache :expires) (float-time))
         (equal (plist-get cache :model) (plist-get session :model)))))

(defun harness-compaction--fork-p (session-id model)
  "Non-nil when a summary of SESSION-ID on MODEL would work on a fork of its state.
That is what `harness-compaction--forked-state' forks: the session's own
conversation, held by MODEL's provider, which can fork it."
  (and (harness-method-exists-p 'session/provider-state)
       (harness-method-exists-p 'provider/fork)
       (harness-call 'session/provider-state session-id model)
       (harness-json-true-p (plist-get (harness-call 'provider/capabilities model) :fork))))

(defun harness-compaction--estimate-summary (session-id session context warm ends)
  "Estimate a `summary' of SESSION-ID, whose record is SESSION, of CONTEXT tokens.
WARM says the session's prompt cache lasts: a summary on a fork of the
session's own conversation reads it back from there; any other is sent
a prompt of its own, which nothing cached starts, so it pays for all of
it uncached.  ENDS is `harness-compaction--verbatim-tokens': what the
first and last messages kept verbatim add to the result."
  (let* ((model (plist-get session :model))
         (cached (and warm (harness-compaction--fork-p session-id model)))
         (ask (harness-estimate-tokens harness-compaction--request-text))
         (output harness-compaction--summary-output))
    (list :kind 'summary :model model :model-label (harness-compaction--model-label model)
          :input (+ context ask) :output output :cached (and cached t)
          :cost (harness-compaction--cost
                 model (if cached
                           (list :cache-read context :input ask :output output)
                         (list (harness-compaction--uncached-key model) (+ context ask) :output output)))
          ;; What it costs once the cache lapsed: a client that keeps the
          ;; estimate for a while says so when the cache lapses meanwhile.
          :cost-uncached (harness-compaction--cost
                          model (list (harness-compaction--uncached-key model) (+ context ask)
                                      :output output))
          :after (+ output ends))))

(defun harness-compaction--estimate-brief (session messages ends &optional model)
  "Estimate a `brief' summary of SESSION, whose provider messages are MESSAGES.
Its model is sent the system prompt and the conversation's narrative
\(`harness-compaction--narrative-messages'), all of it uncached.  ENDS
is `harness-compaction--verbatim-tokens': what the first and last
messages kept verbatim add to the result.  MODEL, when given, writes it
in place of `harness-compaction--brief-model': a handoff has the new
model write it."
  (let* ((model (or model (harness-compaction--brief-model session)))
         (input (+ (harness-estimate-tokens harness-compaction--system-prompt)
                   (harness-compaction--messages-tokens
                    (harness-compaction--narrative-messages messages))
                   (harness-estimate-tokens harness-compaction--request-text)))
         (output harness-compaction--summary-output))
    (list :kind 'brief :model model :model-label (harness-compaction--model-label model)
          :input input :output output :cached nil
          :cost (harness-compaction--cost
                 model (list (harness-compaction--uncached-key model) input :output output))
          :after (+ output ends))))

(defun harness-compaction--estimate-transcript (context)
  "Estimate a `transcript' of a conversation of CONTEXT tokens.
No model is asked anything; the note left in its place is about as
long as an example of it."
  (list :kind 'transcript :model nil :model-label nil :input 0 :output 0 :cached nil :cost 0.0
        :after (harness-estimate-tokens (harness-compaction--transcript-note "/a/file.md" 1000))
        :file-tokens context))

(defun harness-compaction--estimate-fresh (count context)
  "Estimate a `fresh' start after COUNT messages of CONTEXT tokens.
No model is asked anything, and only the note saying so stands for
the conversation."
  (list :kind 'fresh :model nil :model-label nil :input 0 :output 0 :cached nil :cost 0.0
        :after (harness-estimate-tokens (harness-compaction--fresh-note count context t))))

(defun harness-compaction--estimate-truncate (session-id context)
  "Estimate a `truncate' of a conversation of CONTEXT tokens.
No model is asked anything: the oldest nodes go and the most recent are
kept as they were, with only the note added.  `:kept' and `:dropped'
are how many nodes each holds; when nothing can be cut, `:after' is
CONTEXT and `:dropped' is 0."
  (condition-case nil
      (let* ((plan (harness-compaction--truncate-plan session-id))
             (kept (plist-get plan :kept))
             (dropped (plist-get plan :dropped))
             (kept-tokens (plist-get plan :kept-tokens))
             (dropped-tokens (plist-get plan :dropped-tokens))
             (note (harness-compaction--truncate-note (length dropped) dropped-tokens
                                                      (length kept) kept-tokens t)))
        (list :kind 'truncate :model nil :model-label nil :input 0 :output 0 :cached nil :cost 0.0
              :after (+ (harness-estimate-tokens note) kept-tokens)
              :kept (length kept) :dropped (length dropped)
              :kept-tokens kept-tokens :dropped-tokens dropped-tokens))
    (harness-error
     (list :kind 'truncate :model nil :model-label nil :input 0 :output 0 :cached nil :cost 0.0
           :after context :kept (length (harness-call 'session/messages session-id)) :dropped 0))))

(harness-defmethod compaction/estimate (session-id &optional opts)
  "Say what compacting SESSION-ID costs, kind by kind, and what carrying on does.
Return (:context N :model MODEL :model-label LABEL :cached BOOL
:carry-on USD :carry-on-cached USD :compacting BOOL :kind KIND :kinds
ESTIMATES).  N is the context the next message sends, the last
request's or else an estimate of the transcript's; `:cached' says the
session's prompt cache still lasts for MODEL, `:carry-on' what the next
message costs to send N as things are, `:carry-on-cached' what it would
cost read from the cache.  `:compacting' says a compaction is under way
and `:kind' is `harness-compaction-kind'.  ESTIMATES has one plist per
kind of `harness-compaction-kinds', (:kind KIND :model MODEL
:model-label LABEL :input N :output N :cached BOOL :cost USD :after N):
the model that would write it, the tokens it would read and write
\(`:cached' when it would read them from the cache), what that costs,
and the context that stands for the conversation after it -- a
model-written one keeps the conversation's first and last messages
verbatim, which that number includes.  Costs are
at list prices, nil where the catalogue has none, and `transcript' and
`fresh', which ask no model, cost 0; a transcript's `:file-tokens' is
about how much the file holds.  `:messages' is how many messages the
conversation sends now.  A `summary' also says what it would cost once
the prompt cache lapsed, `:cost-uncached': its `:cost' while the cache
lasts is the cheaper one, and a client that keeps the answer for a
while reads the other when the cache lapses meanwhile.

OPTS `:brief-model' names the model that writes the `brief' summary in
place of `harness-compaction-brief-model': a model switch has the new
model write it, and asks what that costs."
  (let* ((session (harness-call 'session/get session-id))
         (model (plist-get session :model))
         (messages (harness-call 'session/messages session-id))
         (context (let ((c (plist-get (plist-get session :usage) :context)))
                    (if (and (numberp c) (> c 0)) c (harness-compaction--messages-tokens messages))))
         (warm (harness-compaction--warm-p session))
         (ends (harness-compaction--verbatim-tokens messages)))
    (list :context context :model model :model-label (harness-compaction--model-label model)
          :messages (length messages)
          :cached (and warm t)
          :carry-on (harness-compaction--resend model context warm)
          :carry-on-cached (harness-compaction--resend model context t)
          :compacting (and (gethash session-id harness-compaction--running) t)
          :kind harness-compaction-kind
          :kinds (list (harness-compaction--estimate-summary session-id session context warm ends)
                       (harness-compaction--estimate-brief session messages ends
                                                           (plist-get opts :brief-model))
                       (harness-compaction--estimate-transcript context)
                       (harness-compaction--estimate-fresh (length messages) context)
                       (harness-compaction--estimate-truncate session-id context)))))

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

(defun harness-compaction--narrative-value (value)
  "Return VALUE as a short one-line string, or nil when it says nothing.
A string keeps its first line; a number, a symbol and a small list are
named as they are.  Bounded to `harness-compaction--narrative-line-max'."
  (let ((text (cond ((stringp value) value)
                    ((numberp value) (format "%s" value))
                    ((eq value t) "yes")
                    ((and (symbolp value) value) (format "%s" value))
                    ((and (consp value) (stringp (car value))) (car value)))))
    (let ((line (and text (harness-first-line (string-trim text)))))
      (and line (not (string-blank-p line))
           (harness-truncate-end line harness-compaction--narrative-line-max)))))

(defun harness-compaction--narrative-input (input)
  "Return a tool call's INPUT as one line of its main arguments, or nil.
The first of `harness-compaction--narrative-param-keys' it holds names
the call -- the file it read, the command it ran, the question it
asked; without one, the first two entries that name something show."
  (when (listp input)
    (let ((named (cl-loop for key in harness-compaction--narrative-param-keys
                          for value = (plist-get input key)
                          for text = (harness-compaction--narrative-value value)
                          when text return (format "%s: %s" (substring (symbol-name key) 1) text))))
      (or named
          (let (parts)
            (cl-loop for (key value) on input by #'cddr
                     for text = (harness-compaction--narrative-value value)
                     when text do (push (format "%s: %s" (substring (symbol-name key) 1) text) parts)
                     when (= 2 (length parts)) return nil)
            (and parts (string-join (nreverse parts) ", ")))))))

(defun harness-compaction--narrative-tool-line (block)
  "Return BLOCK, a tool_use block, as one line naming what it asked."
  (let ((name (or (plist-get block :name) "a tool"))
        (input (harness-compaction--narrative-input (plist-get block :input))))
    (harness-truncate-end (format "[called %s%s]" name (if input (concat ": " input) ""))
                          harness-compaction--narrative-line-max)))

(defun harness-compaction--narrative-result-line (block)
  "Return BLOCK, a tool_result block, as one line of what it answered."
  (let* ((content (plist-get block :content))
         (text (cond ((stringp content) content)
                     ((listp content)
                      (string-join (cl-loop for b in content
                                            when (equal (plist-get b :type) "text")
                                            collect (or (plist-get b :text) ""))
                                   " "))
                     (t (format "%s" (or content "")))))
         (line (harness-first-line (string-trim text))))
    (and (not (string-blank-p line))
         (harness-truncate-end
          (format "[result%s: %s]" (if (plist-get block :is_error) " (error)" "") line)
          harness-compaction--narrative-line-max))))

(defun harness-compaction--narrative-block-text (block)
  "Return BLOCK as text for the narrative a brief summary reads, or nil.
Text is kept as it is; thinking is kept its first line, marked; a tool
call becomes one line naming the tool and its main arguments, and a
result one line of what it answered.  Nothing carries a payload."
  (pcase (plist-get block :type)
    ("text" (let ((text (plist-get block :text)))
              (and (stringp text) (not (string-blank-p text)) text)))
    ("thinking" (let ((text (plist-get block :text)))
                  (and (stringp text) (not (string-blank-p text))
                       (harness-truncate-end (format "[thinking] %s" (harness-first-line text))
                                             harness-compaction--narrative-line-max))))
    ("tool_use" (harness-compaction--narrative-tool-line block))
    ("tool_result" (harness-compaction--narrative-result-line block))
    (_ nil)))

(defun harness-compaction--narrative-messages (messages)
  "Return MESSAGES as the narrative a brief summary reads.
Every message keeps its role and its text, in order; each tool call is
one line naming the tool and its main arguments, and each result one
line of what it answered.  So the summary reads every turn of the
conversation without the payloads tools read and wrote, which are most
of it.  Messages that say nothing are left out, and neighbouring
messages of one role merge, as `session/messages' leaves them."
  (let (out)
    (dolist (message messages)
      (let ((content (cl-loop for block in (plist-get message :content)
                              for text = (harness-compaction--narrative-block-text block)
                              when text collect (list :type "text" :text text)))
            (role (plist-get message :role)))
        (when content
          (if (and out (eq (plist-get (car out) :role) role))
              (setf (plist-get (car out) :content)
                    (append (plist-get (car out) :content) content))
            (push (list :role role :content content) out)))))
    (nreverse out)))

(defun harness-compaction--block-text (block)
  "Return BLOCK as text for a summariser sent the conversation in one message."
  (pcase (plist-get block :type)
    ("text" (or (plist-get block :text) ""))
    ("thinking" (format "[thinking] %s" (or (plist-get block :text) "")))
    ;; The input is JSON inside text, so it must be text: the bytes
    ;; `harness-json-encode' gives turn into raw-byte characters here,
    ;; which the next `json-serialize' rejects with `json-value-p'
    ;; naming the whole message.
    ("tool_use" (format "[called %s with %s]" (plist-get block :name)
                        (condition-case nil
                            (harness-json-encode-text (or (plist-get block :input) :empty))
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
conversation; without it, `sample' is the conversation's narrative --
every user and assistant message, each tool call and result in one
line, never a payload.  A hosted loop without STATE is sent the context
as one message of text, since only the newest user messages ever reach
it.  The images that tool results returned are left out whatever the
context: a summary is written from the conversation's words, and a
request carrying every picture of a conversation that outgrew its
window could be too large for the provider to take."
  (let* ((messages (harness-agent-strip-result-images (harness-call 'session/messages session-id)))
         (contextual (if (eq context 'sample)
                         (harness-compaction--narrative-messages messages)
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

(defun harness-compaction--verbatim-text (node)
  "Return NODE's text as a person reads it, or nil when it says nothing.
Bounded to `harness-compaction--verbatim-max-chars'."
  (let ((text (string-trim
               (mapconcat #'harness-compaction--block-text
                          (or (plist-get node :blocks)
                              (list (list :type "text" :text (or (plist-get node :content) ""))))
                          "\n"))))
    (unless (string-blank-p text)
      (if (> (length text) harness-compaction--verbatim-max-chars)
          (concat (harness-truncate-end text harness-compaction--verbatim-max-chars)
                  "\n[The message was longer; only its start is kept.]")
        text))))

(defun harness-compaction--verbatim-ends (path trailing)
  "Return the first and last messages a compaction keeps as they are.
PATH is the session's node path, TRAILING the unanswered user nodes
carried over after the compaction, which the last side must not repeat.
Return (:first TEXT :last TEXT): the first message of the conversation
and its most recent one before the carried-over run, each as a person
reads it (`harness-compaction--verbatim-text'), for a compaction to
keep verbatim rather than paraphrase; a side with no message is nil."
  (let* ((carried (mapcar (lambda (node) (plist-get node :id)) trailing))
         (spoken (cl-remove-if
                  (lambda (node)
                    (or (memq (plist-get node :id) carried)
                        (and (fboundp 'harness-outside-node-p)
                             (harness-outside-node-p node))))
                  (cl-remove-if-not
                   (lambda (node) (memq (plist-get node :kind) '(user assistant plan)))
                   path)))
         (first (car spoken))
         (last (car (last spoken))))
    (list :first (and first (harness-compaction--verbatim-text first))
          :last (and last (not (eq last first)) (harness-compaction--verbatim-text last)))))

(defun harness-compaction--verbatim-tokens (messages)
  "Return the tokens the verbatim ends of MESSAGES add to a compaction.
MESSAGES are the provider messages about to be compacted; their first
and last are kept as they are in what replaces them, which the cost
estimate counts."
  (let ((first (car messages))
        (last (car (last messages))))
    (if (or (null first) (eq first last))
        0
      (+ (harness-compaction--messages-tokens (list first))
         (harness-compaction--messages-tokens (list last))))))

(defun harness-compaction--with-verbatim-ends (content ends)
  "Return CONTENT, a summary, with ENDS' first and last messages verbatim.
ENDS is `harness-compaction--verbatim-ends''s (:first TEXT :last TEXT).
Each side is named for the model that goes on from the compaction, so
it reads the task and the most recent message as they were written, not
as the summary paraphrased them."
  (concat content
          (when (plist-get ends :first)
            (format (concat "\n\nThe conversation opened with this message, kept verbatim rather than"
                            " summarised:\n\n%s")
                    (plist-get ends :first)))
          (when (plist-get ends :last)
            (format (concat "\n\nIts most recent message before this compaction, kept verbatim rather than"
                            " summarised:\n\n%s")
                    (plist-get ends :last)))))


(defun harness-compaction--start-over (session-id)
  "Drop the provider conversation the model of SESSION-ID would go on with.
A hosted loop (Claude Code, Copilot) keeps the conversation itself and
is sent only the newest user messages: one still holding the session's
would take the compaction as one more message of it, and the whole
conversation would stay, read back uncached once its cache lapsed.
Without the state its next request starts a new conversation, which the
compaction opens.  A state of another provider (the one a handoff
leaves behind) is no conversation the session's model goes on with, and
stays."
  (when (and (harness-method-exists-p 'session/provider-state)
             (harness-call 'session/provider-state session-id))
    (harness-log 'info "compaction: %s starts a new provider conversation from the compaction" session-id)
    (harness-call 'session/set-provider-state session-id nil)))

(defun harness-compaction--done-hint (kind input-tokens meta)
  "Return the hint saying INPUT-TOKENS of context became KIND.
META is the compaction node's, whose `:file' names a transcript and
`:truncate-dropped' how many nodes a truncation dropped."
  (format "Compacted: %s tokens → %s"
          (harness-format-tokens input-tokens)
          (pcase kind
            ('brief "brief summary")
            ('transcript (format "transcript in %s"
                                 (abbreviate-file-name (or (plist-get meta :file) "a file"))))
            ('fresh "a fresh start")
            ('truncate (format "a cut conversation (%d nodes dropped)"
                               (plist-get meta :truncate-dropped)))
            (_ "summary"))))

(defun harness-compaction--with-history (session-id content kind)
  "Return CONTENT, a compaction of KIND for SESSION-ID, ending in the history note.
The note (`harness-compaction--history-note') says the conversation is
still on record for the session_history tool; it is left out when the
session's model does not have the tool, and from a `fresh' start, whose
note says so already."
  (if (and (not (eq kind 'fresh)) (harness-compaction-history-p session-id))
      (concat content "\n\n" (harness-compaction--history-note))
    content))

(defun harness-compaction--finish (session-id content old-head model usage input-tokens trailing context
                                               &optional kind meta keep)
  "Record CONTENT for SESSION-ID and return the compaction node.
CONTENT is the summary, its caveat included and for a model-written
one the conversation's first and last messages kept verbatim around it
\(`harness-compaction--with-verbatim-ends'), or for KIND `transcript'
the note pointing at the file, for `fresh' the note saying nothing was
carried over, for `truncate' the note saying the oldest nodes were cut.
It gets the line pointing at the session_history tool
\(`harness-compaction--with-history').  OLD-HEAD is the head that was
compacted, MODEL the summariser (the session's model for a transcript,
a fresh start or a truncation, which none wrote), USAGE its usage event
(nil when no request was made), INPUT-TOKENS the size of what was
compacted, TRAILING the unanswered user nodes to carry over, CONTEXT what
the summariser was given (see `compaction/compact'), KIND one of
`harness-compaction-kinds' \(`summary' by default), META more for
the node's `:meta': a transcript's `:file', a handoff's `:handoff', and
KEEP nodes to append after the compaction node, verbatim, before
TRAILING.  META `:mid-turn' says it was made in the middle of a turn
\(`harness-compaction-mid-turn'): the content then ends in the note
telling the model to carry on (`harness-compaction--mid-turn-note').
The conversation starts over from the node
\(`harness-compaction--start-over')."
  (let* ((kind (or kind 'summary))
         (keep (append keep nil))
         (content (harness-compaction--with-history session-id content kind))
         (content (if (harness-json-true-p (plist-get meta :mid-turn))
                      (concat content "\n\n" harness-compaction--mid-turn-note)
                    content))
         (node (harness-call 'session/append session-id
                             (list :kind 'compaction :content content
                                   :meta (append (list :compacted-head old-head :model model
                                                       :compaction (symbol-name kind)
                                                       :context context
                                                       :input-tokens input-tokens
                                                       :summary-tokens (harness-estimate-tokens content))
                                                 meta)))))
    (harness-call 'session/hint session-id (harness-compaction--done-hint kind input-tokens meta))
    (dolist (n keep)
      (harness-call 'session/append session-id n))
    (dolist (u trailing)
      (let ((carried (plist-put (copy-sequence (plist-get u :meta)) :carried-from (plist-get u :id))))
        ;; A message sent to a turn that runs reaches the model with the
        ;; conversation that starts here, so the copy is delivered
        ;; already: a chat would show it queued for good otherwise.
        (when (harness-json-true-p (plist-get carried :steering))
          (setq carried (plist-put carried :delivered-after (plist-get node :id))))
        (harness-call 'session/append session-id
                      (list :kind 'user :content (plist-get u :content) :blocks (plist-get u :blocks)
                            :meta carried))))
    (harness-compaction--start-over session-id)
    ;; The conversation starts over from the compaction: whatever the
    ;; summariser's request cached, the next request reads none of it.
    ;; The reset leaves `:cache-pending' when the old conversation had a
    ;; cache, so that next request stamps the new one (see
    ;; `harness-session--cache-stamp').
    (harness-call 'session/usage-add session-id
                  (list :input (plist-get usage :input) :output (plist-get usage :output)
                        :cache-read (plist-get usage :cache-read)
                        :cache-write (plist-get usage :cache-write)
                        :cost (plist-get usage :cost)
                        ;; The compaction is all the conversation holds now.
                        :context (+ (harness-estimate-tokens content)
                                    (harness-compaction--nodes-tokens keep))
                        :last-output 0
                        :model model
                        :cache-reset t))
    (harness-emit 'compaction/done session-id node)
    node))

(defun harness-compaction--transcript (session-id session &optional meta)
  "Compact SESSION-ID into a transcript file; return the compaction node.
SESSION is its record from before the compaction began, META more for
the node's `:meta'.  The file is the one a handoff writes
\(`session/write-transcript'); the node holds the note pointing at it,
which `session/messages' sends as it is."
  (let* ((old-head (plist-get session :head))
         (trailing (harness-compaction--trailing-user-nodes (harness-call 'session/nodes session-id)))
         (input (or (let ((c (plist-get (plist-get session :usage) :context)))
                      (and (numberp c) (> c 0) c))
                    (harness-compaction--messages-tokens (harness-call 'session/messages session-id))))
         (written (harness-call 'session/write-transcript session-id
                                (list :title "Compacted conversation"
                                      :about (format "Compacted %s: the session goes on from a note pointing here"
                                                     (format-time-string "%Y-%m-%d %H:%M %Z")))))
         (file (plist-get written :file)))
    (harness-log 'info "compaction: %s written to %s" session-id file)
    (harness-compaction--finish session-id
                                (harness-compaction--transcript-note file (plist-get written :lines))
                                old-head (plist-get session :model) nil input trailing 'full
                                'transcript (append (list :file file) meta))))

(defun harness-compaction--fresh (session-id session &optional caveat meta)
  "Start SESSION-ID afresh; return the compaction node.
SESSION is its record from before the compaction began, CAVEAT a note
to end the node with, or nil, and META more for the node's `:meta'.
Nothing of the conversation is carried over: the node is a note saying
so (`harness-compaction--fresh-note'), which `session/messages' sends as
it is, and which points the model at the session_history tool to look
back with."
  (let* ((old-head (plist-get session :head))
         (trailing (harness-compaction--trailing-user-nodes (harness-call 'session/nodes session-id)))
         (messages (harness-call 'session/messages session-id))
         (input (or (let ((c (plist-get (plist-get session :usage) :context)))
                      (and (numberp c) (> c 0) c))
                    (harness-compaction--messages-tokens messages)))
         (note (harness-compaction--fresh-note (length messages) input
                                               (harness-compaction-history-p session-id))))
    (harness-log 'info "compaction: %s starts afresh" session-id)
    (harness-compaction--finish session-id (if caveat (concat note "\n\n" caveat) note)
                                old-head (plist-get session :model) nil input trailing 'full
                                'fresh meta)))

;;;; Truncating

(defun harness-compaction--node-tokens (node)
  "Cheap token estimate for NODE."
  (harness-estimate-tokens
   (concat (or (plist-get node :content) "")
           (let ((output (plist-get node :output)))
             (if (stringp output) output ""))
           (if-let* ((input (plist-get node :input)))
               (condition-case nil (harness-json-encode-text input) (error ""))
             ""))))

(defun harness-compaction--nodes-tokens (nodes)
  "Cheap token estimate for NODES."
  (cl-reduce (lambda (sum n) (+ sum (harness-compaction--node-tokens n))) nodes :initial-value 0))

(defun harness-compaction--node-units (nodes)
  "Return NODES in units (START . END), each tool call with its results.
A `tool-call' node and the `tool-result' nodes that answer it, right
after it, are one unit, as `session/messages' pairs them; every other
node is a unit of its own.  START and END are indices into NODES, END
exclusive, in order."
  (let ((n (length nodes)) (i 0) units)
    (while (< i n)
      (let ((end (1+ i)))
        (when (eq (plist-get (nth i nodes) :kind) 'tool-call)
          (let ((call-id (plist-get (nth i nodes) :call-id)))
            (while (and (< end n)
                        (eq (plist-get (nth end nodes) :kind) 'tool-result)
                        (equal (plist-get (nth end nodes) :call-id) call-id))
              (cl-incf end))))
        (push (cons i end) units)
        (setq i end)))
    (nreverse units)))

(defun harness-compaction--truncate-plan (session-id)
  "Return what `truncate' keeps of SESSION-ID and what it drops.
The result is (:keep NODES :dropped NODES :kept-tokens N :dropped-tokens N
:trailing NODES): the newest nodes kept verbatim, whole units
\(`harness-compaction--node-units'), up to `harness-compaction--truncate-keep'
of the usable window, and the unanswered user nodes carried over after
them.  The path before the last compaction, if any, is dropped too.
Signal `harness-error' when nothing would be dropped."
  (let* ((session (harness-call 'session/get session-id))
         (path (harness-call 'session/nodes session-id))
         (start (cl-position 'compaction path :key (lambda (n) (plist-get n :kind)) :from-end t))
         (tail (if start (nthcdr (1+ start) path) path))
         (trailing (harness-compaction--trailing-user-nodes tail))
         (candidates (if trailing (butlast tail (length trailing)) tail))
         (units (harness-compaction--node-units candidates))
         (budget (max 1 (floor (* harness-compaction--truncate-keep
                                   (harness-compaction--usable (harness-compaction--window session)
                                                               (harness-compaction--reserve session))))))
         (kept-units nil) (tokens 0) (stopped nil))
    (dolist (unit (reverse units))
      (unless stopped
        (let ((toks (harness-compaction--nodes-tokens (cl-subseq candidates (car unit) (cdr unit)))))
          (if (or (null kept-units) (<= (+ tokens toks) budget))
              (progn (push unit kept-units) (cl-incf tokens toks))
            (setq stopped t)))))
    (if (null kept-units)
        (signal 'harness-error (list "Nothing to truncate: the conversation already fits the window"))
      ;; Kept-units is oldest-first (each older unit was pushed on top),
      ;; so its head is the first node the kept suffix begins at.
      (let* ((keep-start (car (car kept-units)))
             (keep (cl-subseq candidates keep-start))
             (dropped (cl-subseq candidates 0 keep-start)))
        (if (null dropped)
            (signal 'harness-error (list "Nothing to truncate: the conversation already fits the window"))
          (list :keep keep :dropped dropped :kept-tokens tokens
                :dropped-tokens (- (harness-compaction--nodes-tokens candidates) tokens)
                :trailing trailing))))))

(defun harness-compaction--truncate-note (dropped-n dropped-tokens kept-n kept-tokens history)
  "Return the note that opens a conversation whose oldest nodes were cut.
DROPPED-N nodes of about DROPPED-TOKENS tokens were dropped, and
KEPT-N of about KEPT-TOKENS tokens kept, verbatim, below.  HISTORY
non-nil says the model has the session_history tool to look the rest up
with; without it, the user is the one to ask."
  (concat
   (format (concat "This conversation was cut short, to keep the context small: the oldest %d"
                   " node%s, about %s tokens, are not carried over.  The most recent %d node%s,"
                   " about %s tokens, are kept below as they were.")
           dropped-n (if (= dropped-n 1) "" "s") (harness-format-tokens dropped-tokens)
           kept-n (if (= kept-n 1) "" "s") (harness-format-tokens kept-tokens))
   "  "
   (if history
       (format (concat "You start without the older part, so before you answer, look back at what you"
                       " need of it with the %s tool -- the task, what was decided and done, where the"
                       " work stood -- rather than guessing, and check the files and the state before"
                       " you act.")
               harness-compaction-history-tool)
     (concat "You start without the older part: check the files and the state before you act, and"
             " ask the user for what you need of the earlier conversation rather than guessing."))))

(defun harness-compaction--truncate (session-id session &optional meta)
  "Cut SESSION-ID's oldest context away; return the compaction node.
SESSION is its record from before the compaction began, META more for
the node's `:meta'.  The newest nodes, whole units, are kept verbatim
after the note (`harness-compaction--truncate-note'); the rest are
dropped, and the note points at the session_history tool.  No model is
asked anything."
  (let* ((old-head (plist-get session :head))
         (plan (harness-compaction--truncate-plan session-id))
         (keep (plist-get plan :keep))
         (dropped (plist-get plan :dropped))
         (input (or (let ((c (plist-get (plist-get session :usage) :context)))
                      (and (numberp c) (> c 0) c))
                    (harness-compaction--messages-tokens (harness-call 'session/messages session-id))))
         (note (harness-compaction--truncate-note (length dropped) (plist-get plan :dropped-tokens)
                                                  (length keep) (plist-get plan :kept-tokens)
                                                  (harness-compaction-history-p session-id))))
    (harness-log 'info "compaction: %s cuts %d nodes, keeping %d" session-id (length dropped) (length keep))
    (harness-compaction--finish session-id note old-head (plist-get session :model) nil input
                                (plist-get plan :trailing) 'full 'truncate
                                (append (list :truncate-dropped (length dropped)
                                              :truncate-kept (length keep)
                                              :dropped-tokens (plist-get plan :dropped-tokens))
                                        meta)
                                keep)))

(defun harness-compaction--forked-state (session-id model)
  "Return a promise of the provider state to summarise SESSION-ID with on MODEL.
That is a fork of the session's state when MODEL's provider can continue
it and fork it (a hosted loop: Claude Code, Copilot), so the summary
comes from the real conversation without writing into it; else nil, and
MODEL gets the transcript as messages."
  (if (harness-compaction--fork-p session-id model)
      (harness-catch (harness-call-async 'provider/fork model
                                         (harness-call 'session/provider-state session-id model))
                     (lambda (e)
                       (harness-log 'warn "compaction: provider fork failed, sending the transcript: %s"
                                    (harness-error-short-message e))
                       nil))
    (harness-resolved nil)))

(defun harness-compaction--request (session-id session model state promise context
                                                &optional kind caveat meta)
  "Ask MODEL for the summary of SESSION-ID, whose record is SESSION.
STATE is the provider state to send it with, CONTEXT what it is given
\(`full' or `sample'), and PROMISE settles with the compaction node.
KIND is the kind of summary (`summary' or `brief'), CAVEAT a note to
end it with, or nil, and META more for the node's `:meta' (see
`harness-compaction--finish').  The node's content keeps the
conversation's first and last messages verbatim around the summary
\(`harness-compaction--with-verbatim-ends').  The unanswered user
messages carried over after it are those there are when the summary
is in, not when it was asked for: one sent to the turn meanwhile, which
a summary of a long conversation takes a while to write, lies before
the compaction node otherwise, where the model never reads it."
  (let* ((old-head (plist-get session :head))
         (path (harness-call 'session/nodes session-id))
         (trailing (harness-compaction--trailing-user-nodes path))
         (ends (harness-compaction--verbatim-ends path trailing))
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
                          session-id (harness-compaction--with-verbatim-ends
                                      (if caveat (concat summary "\n\n" caveat) summary) ends)
                          old-head model usage
                          (or (plist-get usage :context)
                              (and (plist-get usage :input)
                                   (+ (plist-get usage :input) (or (plist-get usage :cache-read) 0)))
                              estimate)
                          (harness-compaction--trailing-user-nodes (harness-call 'session/nodes session-id))
                          context kind meta))
                      (error (harness-compaction--fail session-id promise err))))))
               (_ nil)))))))

(defun harness-compaction--compact-now (session-id opts)
  "Compact SESSION-ID at once as OPTS says; return a promise of the node.
OPTS are those of `compaction/compact' without the flags that decide when
to run (`:queue', `:interrupt', `:idle').  A compaction already running
returns its promise."
  (or (gethash session-id harness-compaction--running)
      (let* ((session (harness-call 'session/get session-id))
             (kind (harness-compaction--kind (plist-get opts :kind) (plist-get opts :context)))
             (context (if (eq kind 'brief) 'sample (harness-compaction--context (plist-get opts :context))))
             (kind (if (and (eq kind 'summary) (eq context 'sample)) 'brief kind))
             (model (or (plist-get opts :model)
                        (if (eq kind 'brief)
                            (harness-compaction--brief-model session)
                          (plist-get session :model))))
             (caveat (if (plist-member opts :caveat)
                         (plist-get opts :caveat)
                       (and (eq kind 'brief) (harness-compaction--brief-caveat model))))
             (meta (plist-get opts :meta))
             (promise (harness-make-promise)))
        (puthash session-id promise harness-compaction--running)
        (harness-finally promise (lambda () (remhash session-id harness-compaction--running)))
        (if (memq kind '(transcript fresh truncate))
            (condition-case err
                (harness-resolve promise
                                 (pcase kind
                                   ('truncate (harness-compaction--truncate session-id session meta))
                                   ('fresh (harness-compaction--fresh session-id session
                                                                      (plist-get opts :caveat) meta))
                                   (_ (harness-compaction--transcript session-id session meta))))
              (error (harness-compaction--fail session-id promise err)))
          (let ((where (if (harness-json-true-p (plist-get meta :mid-turn))
                           " in the middle of the turn"
                         "")))
            (harness-call 'session/hint session-id
                          (if (eq kind 'brief)
                              (format "Compacting context%s: a brief summary by %s…"
                                      where (harness-compaction--model-label model))
                            (format "Compacting context%s…" where))))
          (harness-then (if (eq context 'sample)
                            ;; A sample is the point: do not hand the
                            ;; summariser the whole conversation on a fork.
                            (harness-resolved nil)
                          (harness-compaction--forked-state session-id model))
                        (lambda (state)
                          (condition-case err
                              ;; The record from before the hint: its head is
                              ;; the one compacted.
                              (harness-compaction--request session-id session model state promise context
                                                           kind caveat meta)
                            (error (harness-compaction--fail session-id promise err))))
                        (lambda (err) (harness-compaction--fail session-id promise err))))
        promise)))

(harness-defmethod compaction/compact (session-id &optional opts)
  "Compact the transcript of SESSION-ID; return a promise.
OPTS `:kind' is one of `harness-compaction-kinds': `summary' (the
default), `brief', `transcript', `fresh' or `truncate'.

A `summary' is written by the session's model, or OPTS `:model'.  OPTS
`:context' is `full' (the default), which lets the summariser see the
whole conversation (on a fork of the session's provider state when its
provider can), or `sample', which sends it the conversation's narrative
-- every user and assistant message, each tool call and result in one
line -- never the payloads: a bound on what a summariser that has to be
sent the conversation as text costs.  A summary of a sample is a
`brief' one,
and a `brief' one is always of a sample, written by OPTS `:model' or
else `harness-compaction-brief-model' (the simple tier of the session's
provider by default), and ends in a note saying what it lacks.  OPTS
`:caveat' replaces that note, nil for none; a handoff ends its summary
with its own.  A summariser that keeps the conversation itself (a hosted
loop) works on a fork of the session's provider state when it can; one
with no state of this session gets the context as one message of text,
since that is all such a provider is ever sent.

A `transcript' is written to a file in the session's directory
\(`session/write-transcript'), and the node holds a note telling the
model to read what it needs of it; no model is asked anything.  A
`fresh' start carries nothing over: the node holds a note saying so,
ending in OPTS `:caveat' when given; no model is asked anything either.
A `truncate' cuts the oldest nodes away and keeps the most recent, whole
tool exchanges, verbatim after the note (`harness-compaction--truncate'),
up to `harness-compaction--truncate-keep' of the usable window; no model
is asked anything either, for a conversation too big to summarise.
Every node ends in a line pointing the model at the session_history
tool, which searches and reads the conversation it replaced, when the
session has that tool.

The node replaces the transcript for the provider (`session/messages'
restarts at it, as a user message); the conversation's first and last
messages are kept verbatim in it (`harness-compaction--verbatim-ends'),
so a short task and the latest message survive the summary; unanswered
user messages at the end
of the transcript are carried over after it, and the conversation the
session's provider kept, if any, goes (`harness-compaction--start-over').
OPTS `:meta' is more for the node's `:meta'.  A second call while one
is running returns the running promise.

While a turn runs (`agent/running'), OPTS `:queue' registers the
compaction and runs it at the turn's next boundary -- the next step, or
its end -- and OPTS `:interrupt' also cancels the running turn first
\(`agent/cancel') and compacts once it is over; both resolve at once to
\(:queued t :kind KIND :interrupt BOOL), never when the compaction later
runs.  OPTS `:idle' refuses a session running a turn, as compacting by
hand does: the turn would go on writing after the conversation it
replaces.  An idle session with `:queue' or `:interrupt' compacts at
once."
  (or (gethash session-id harness-compaction--running)
      (let ((running (and (harness-method-exists-p 'agent/running)
                          (harness-call 'agent/running session-id))))
        (cond
         ((and running (or (harness-json-true-p (plist-get opts :queue))
                           (harness-json-true-p (plist-get opts :interrupt))))
          (harness-compaction--enqueue session-id opts))
         ((and running (harness-json-true-p (plist-get opts :idle)))
          (signal 'harness-error
                  (list "The session is running a turn: compact it once the turn is over")))
         (t (harness-compaction--compact-now session-id opts))))))

(defun harness-compaction--fail (session-id promise err)
  "Reject PROMISE with ERR and tell SESSION-ID about it.
ERR is reported short (`harness-error-short-message'): the failure of a
summariser can carry a whole transcript or request body as its data, and
none of that belongs in *Messages*, in a hint or in the tree."
  (let ((msg (harness-error-short-message err)))
    (harness-log 'warn "compaction of %s failed: %s" session-id msg)
    (ignore-errors (harness-call 'session/hint session-id (format "Compaction failed: %s" msg)))
    (harness-emit 'compaction/failed session-id msg)
    (harness-reject promise err)))

;;;; Waiting for the next boundary

(defun harness-compaction--kind-name (kind)
  "Return the name people read for KIND."
  (pcase kind
    ('brief "brief summary")
    ('transcript "transcript file")
    ('fresh "fresh start")
    ('truncate "cut old context")
    (_ "summary")))

(defun harness-compaction--enqueue (session-id opts)
  "Register OPTS as the compaction SESSION-ID gets at its next boundary.
The running turn goes on.  Return a promise that resolves at once to
\(:queued t :kind KIND :interrupt BOOL), never when the compaction later
runs -- a tool awaiting it would otherwise hold its own step.  OPTS
`:interrupt' also cancels the running turn (`agent/cancel'), after the
entry is stored, so the compaction runs once the turn is over.  A
compaction already waiting is replaced."
  (let* ((kind (harness-compaction--kind (plist-get opts :kind) (plist-get opts :context)))
         (interrupt (and (harness-json-true-p (plist-get opts :interrupt)) t))
         (opts (plist-put (copy-sequence opts) :kind (symbol-name kind))))
    (when (gethash session-id harness-compaction--pending)
      (harness-log 'info "compaction: replacing the compaction queued for %s" session-id))
    (puthash session-id (list :opts opts :interrupt interrupt) harness-compaction--pending)
    (harness-call 'session/hint session-id
                  (if interrupt
                      (format (concat "Compaction queued: the turn is being interrupted and the"
                                      " conversation compacted (%s) once it is over")
                              (harness-compaction--kind-name kind))
                    (format "Compaction queued: a %s at the turn's next boundary"
                            (harness-compaction--kind-name kind))))
    (when interrupt
      (harness-call 'agent/cancel session-id))
    (harness-resolved (list :queued t :kind (symbol-name kind) :interrupt interrupt))))

(defun harness-compaction--run-pending (session-id)
  "Run the compaction waiting for SESSION-ID; return a promise.
None waiting resolves to nil at once; one already under way returns its
promise."
  (let ((entry (gethash session-id harness-compaction--pending)))
    (cond
     ((null entry) (harness-resolved nil))
     ((plist-get entry :running) (plist-get entry :running))
     (t
      (let* ((promise (harness-make-promise))
             (running (plist-put (copy-sequence entry) :running promise)))
        (puthash session-id running harness-compaction--pending)
        (condition-case err
            (harness-then (harness-compaction--compact-now session-id (plist-get entry :opts))
                          (lambda (node)
                            (when (eq (gethash session-id harness-compaction--pending) running)
                              (remhash session-id harness-compaction--pending))
                            (harness-resolve promise node)
                            nil)
                          (lambda (err)
                            (when (eq (gethash session-id harness-compaction--pending) running)
                              (remhash session-id harness-compaction--pending))
                            (harness-reject promise err)))
          (error
           (when (eq (gethash session-id harness-compaction--pending) running)
             (remhash session-id harness-compaction--pending))
           (harness-reject promise err)))
        promise)))))

(defun harness-compaction--gate (value next session)
  "Hold SESSION's next boundary until the compaction queued for it is done.
VALUE and NEXT are those of the `agent/step' and `agent/before-turn'
filters: the step that goes on must find the compaction in its messages."
  (if (or (not (plist-get value :proceed))
          (not (gethash (plist-get session :id) harness-compaction--pending)))
      (funcall next value)
    (harness-then (harness-compaction--run-pending (plist-get session :id))
                  (lambda (_) (funcall next value))
                  (lambda (_) (funcall next value))))
  nil)

(defun harness-compaction--on-turn-ended (session-id &rest _)
  "Run the compaction that waited for SESSION-ID's turn, now that it is over.
A turn interrupted by a queued compaction ends `cancelled', so it runs
then too.  What the turn learned of compacting in its middle goes with
it (`harness-compaction--mid-turn')."
  (remhash session-id harness-compaction--mid-turn)
  (when (gethash session-id harness-compaction--pending)
    (harness-run-soon
     (lambda ()
       (when (and (harness-call 'session/exists-p session-id)
                  (or (not (harness-method-exists-p 'agent/running))
                      (not (harness-call 'agent/running session-id))))
         (harness-compaction--run-pending session-id))))))

(defun harness-compaction--on-deleted (session-id &rest _)
  "Forget the compaction of SESSION-ID, which is gone."
  (remhash session-id harness-compaction--mid-turn)
  (remhash session-id harness-compaction--pending))

;;;; A message that comes while a compaction runs

(defconst harness-compaction--hold-text "the compaction"
  "What a turn waits for while a compaction runs: the words `agent/hold' says.")

(defun harness-compaction--on-hold (value session-id)
  "Say a compaction holds the turn of SESSION-ID, while one of it runs.
The sync filter `agent/hold' (harness-agent.el), VALUE being what the
handlers before this one said: the first that says something wins.  The
answer is (:text WORDS :phase PHASE): a message sent to the turn waits
for the compaction, instead of lying before it where the model never
reads it, and meanwhile the turn is compacting."
  (or value
      (and (gethash session-id harness-compaction--running)
           (list :text harness-compaction--hold-text :phase 'compacting))))

(defun harness-compaction-show-waiting (session-id)
  "Show the messages SESSION-ID's turn holds for the compaction as queued.
The message that opened the turn is in no transcript until the
compaction is done, and a message sent meanwhile waits with it
\(`agent/show-waiting'): a UI draws them above its compose box, as it
draws the queue's, instead of leaving them out of sight.  A failure to
say so is logged, never raised: the turn must not stop for it."
  (when (harness-method-exists-p 'agent/show-waiting)
    (condition-case err
        (harness-call 'agent/show-waiting session-id harness-compaction--hold-text)
      (error (harness-log 'warn "compaction: could not show the messages waiting in %s: %s"
                          session-id (harness-error-short-message err))))))

(defun harness-compaction--note-waiting (session-id message)
  "Show SESSION-ID's turn as compacting, naming MESSAGE, which waits for it.
MESSAGE is the `:message' of the `agent/before-turn' value, (:text TEXT
:from FROM), the one that opened the turn.  The session reads running
and its activity line says the conversation is compacted and which
message waits, which shows as a queued message too
\(`harness-compaction-show-waiting').  A failure to say so is logged,
never raised: the turn must not stop for it."
  (condition-case err
      (harness-call 'agent/note-activity session-id
                    (append (list :phase 'compacting)
                            (when-let* ((detail (harness-agent-waiting-text
                                                 (list (plist-get message :text)))))
                              (list :detail detail)))
                    t)
    (error (harness-log 'warn "compaction: could not show %s as compacting: %s"
                        session-id (harness-error-short-message err))))
  (harness-compaction-show-waiting session-id))

(defun harness-compaction--wait-gate (value next session)
  "Hold SESSION's turn while a compaction of it runs, then let it go on.
VALUE and NEXT are those of the `agent/before-turn' filter.  A message
that starts a turn while the conversation is being compacted -- one
compacted by hand, say, which no turn waits for -- would otherwise go
at once with the conversation as it is, and its exchange would come
before the compaction node, which the conversation restarts at, so the
model would forget it; or, while the prompt cache is cold, it would ask
what goes first when the compaction already is the answer.  So the turn
waits for the compaction, whether it ends well or not, shown as
compacting, and the gates after this one -- the cold-cache question,
the automatic compaction -- see the session as the compaction left it.
A compaction that failed leaves the conversation as it was, and they
decide as they would have."
  (let ((promise (and (plist-get value :proceed)
                      (gethash (plist-get session :id) harness-compaction--running))))
    (if (null promise)
        (funcall next value)
      (let ((id (plist-get session :id)))
        (harness-log 'info "compaction: the turn of %s waits for the compaction under way" id)
        (harness-compaction--note-waiting id (plist-get value :message))
        (harness-then promise
                      (lambda (_) (funcall next value) nil)
                      (lambda (_) (funcall next value) nil)))))
  nil)

;;;; Automatic compaction

(defun harness-compaction--before-turn (value next session)
  "Compact SESSION before its turn when the context is nearly full.
VALUE and NEXT are the `agent/before-turn' filter arguments.  SESSION
is read again first: a handler earlier in the chain (the fallback) may
have moved it to another model, whose window and compaction decide.
The compaction is of `harness-compaction-kind'."
  (let ((session (or (ignore-errors (harness-call 'session/get (plist-get session :id))) session)))
    (if (or (not (plist-get value :proceed))
            (not (harness-compaction-needed-p session))
            (harness-compaction-hosted-p session))
        (funcall next value)
      ;; The turn's message waits for the compaction, which takes a while.
      (harness-compaction-show-waiting (plist-get session :id))
      (harness-then (harness-call 'compaction/compact (plist-get session :id)
                                  (list :kind harness-compaction-kind))
                    (lambda (_node) (funcall next value))
                    (lambda (_err) (funcall next value)))))
  nil)

;;;; Automatic compaction in the middle of a turn

(defun harness-compaction--note-activity (session-id phase)
  "Show SESSION-ID's running turn as doing PHASE, or as waiting for the model.
PHASE is a symbol such as `compacting', or nil for the turn's usual
wait for its model.  The chat says what the turn does while it takes
no step (`agent/activity'); a turn that is not running shows nothing,
and a failure to note it is logged, never raised."
  (when (harness-method-exists-p 'agent/note-activity)
    (condition-case err
        (harness-call 'agent/note-activity session-id (and phase (list :phase phase)))
      (error (harness-log 'warn "compaction: could not note the activity of %s: %s"
                          session-id (harness-error-short-message err))))))

(defun harness-compaction--mid-turn-due-p (session-id)
  "Say whether the boundary SESSION-ID's turn is at is due a compaction.
Called at a step boundary where the context is over its limit, and so
counts it.  The first compaction of a turn is due at once.  One that
did not help -- the context is over the limit again at the next
boundary -- or failed is tried again only after
`harness-compaction--mid-turn-cooldown' boundaries, twice as many after
a second try that did not help and so on up to eight times as many:
otherwise a conversation that stays over a small limit would be
compacted at every step, and a summariser that keeps failing asked
every time, with a note of its failure each.  A boundary that finds the
context under the limit forgets all that (`harness-compaction--before-step')."
  (let* ((state (gethash session-id harness-compaction--mid-turn))
         (tries (or (plist-get state :tries) 0))
         (since (1+ (or (plist-get state :since) 0)))
         (pause (* harness-compaction--mid-turn-cooldown (expt 2 (min (max (1- tries) 0) 3))))
         (due (or (zerop tries) (>= since pause))))
    (puthash session-id
             (if due (list :tries (1+ tries) :since 0) (list :tries tries :since since))
             harness-compaction--mid-turn)
    due))

(defun harness-compaction--before-step (value next session)
  "Compact SESSION in the middle of its turn when the context is over its limit.
VALUE and NEXT are the `agent/step' filter arguments, the step being the
turn's next request to its model, after the results of the tools the
last one asked for are in.  The `agent/before-turn' gate only looks
when a turn starts, and a turn of many tool calls can outgrow the window
long before it ends.  So, with `harness-compaction-mid-turn' on, a
context over the limit (`harness-compaction-needed-p') has the step wait
for a compaction of `harness-compaction-kind', and goes on from it: the
node tells the model its work is not finished.  Whatever the turn is
doing, nothing else decides: not the cache, not who is waiting.  A
provider that compacts on its own side is left alone, as before a turn,
and a compaction that failed or did not help is not repeated at every
step (`harness-compaction--mid-turn-due-p').  The step goes on whether
the compaction was made or not.  SESSION is read again first: a handler
earlier in the chain may have changed its model."
  (let* ((id (plist-get session :id))
         (session (or (ignore-errors (harness-call 'session/get id)) session)))
    (cond
     ((or (not (plist-get value :proceed)) (not harness-compaction-mid-turn))
      (funcall next value))
     ((not (harness-compaction-needed-p session))
      (remhash id harness-compaction--mid-turn)
      (funcall next value))
     ((or (harness-compaction-hosted-p session)
          (not (harness-compaction--mid-turn-due-p id)))
      (funcall next value))
     (t
      (harness-compaction--note-activity id 'compacting)
      (let ((carry-on (lambda (&rest _)
                        (harness-compaction--note-activity id nil)
                        (funcall next value))))
        (harness-then (harness-call 'compaction/compact id
                                    (list :kind harness-compaction-kind :meta (list :mid-turn t)))
                      carry-on carry-on)))))
  nil)

(defun harness-compaction--init ()
  "Hook automatic and queued compaction into the turn loop."
  ;; A compaction under way holds a turn at 11, beside the one a cache
  ;; about to lapse makes (harness-cache-compact.el), and a queued one
  ;; runs at 12: both before cowboy (15) and the automatic compaction
  ;; (20), so the fresh context is what those gates see.  What a
  ;; message sent to a turn so held does is the agent's
  ;; (`harness-agent--hold-message').
  (harness-add-filter 'agent/before-turn #'harness-compaction--wait-gate 11)
  (harness-add-filter 'agent/hold #'harness-compaction--on-hold)
  (harness-add-filter 'agent/before-turn #'harness-compaction--gate 12)
  (harness-add-filter 'agent/step #'harness-compaction--gate 12)
  (harness-add-filter 'agent/before-turn #'harness-compaction--before-turn 20)
  ;; In the middle of a turn after the gates that may refuse the step or
  ;; hold it (the budget's and the merge queue's, 30): a step that is
  ;; not taken is not compacted for, and a hold ends before the context
  ;; is looked at.
  (harness-add-filter 'agent/step #'harness-compaction--before-step 35)
  (harness-on 'agent/turn-ended #'harness-compaction--on-turn-ended)
  (harness-on 'session/deleted #'harness-compaction--on-deleted))

(harness-compaction--init)

(harness-declare-event 'compaction/done "(SESSION-ID NODE) after a compaction node is appended.")
(harness-declare-event 'compaction/failed "(SESSION-ID MESSAGE) when a compaction fails.")

(harness-define-module 'compaction
  :doc "Summarise the transcript when it nears the context window, before a turn or in the middle of one; queue or interrupt one while a turn runs."
  :requires '(session provider agent)
  :init #'harness-compaction--init)

(provide 'harness-compaction)
;;; harness-compaction.el ends here
