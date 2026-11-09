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
;;   summary, on a request that starts as the conversation's next step
;;   would, so it reads the conversation from the prompt cache while
;;   that lasts and uncached once it lapsed.
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
;; Because nothing is deleted, a compaction can be taken back, and made
;; again, as with undo and redo (`compaction/revert', `compaction/restore'):
;; the latest compaction is marked reverted in its `:meta', and the
;; transcript `session/messages' sends starts at the compaction before it,
;; or at the very start -- the whole conversation the compaction stood
;; for, then what was said since -- instead of at its summary; restoring
;; clears the mark.  The shared rule is `harness-path-from-compaction'
;; (harness-util.el): a reverted compaction is no start of the
;; conversation, and the user messages it carried over after itself are the
;; originals again.  Only the latest compaction can be flipped; an older
;; one keeps the state it had when the next was made, so that undoing the
;; latest returns the conversation exactly to what it was.  A compaction
;; made to hand the conversation to another model cannot be.  Both are
;; refused while a turn or a compaction runs or is queued (the wait a
;; message has), start the prompt cache over and a hosted loop's
;; conversation, as a compaction does, and say in the transcript what the
;; model is sent now.  A conversation given back that is over the context
;; limit but fits the window skips the automatic compaction before the
;; next turn once (`harness-compaction--revert-hold'): the user asked for
;; the model to see it, and it would be compacted again before the model
;; did.  The chats draw [Revert] and [Go post-compaction] on the latest
;; compaction's note and follow its update.
;;
;; Automatic compaction makes `harness-compaction-kind', but where the
;; user can be asked it asks them first, with what each kind costs and
;; what carrying on costs (`harness-compaction-ask'; see "Asking before
;; compacting automatically" below).  Answering it "always" with a kind
;; makes that kind the default and stops the asking, for every session,
;; kept as a decision the UI can undo; a session's own answer is the
;; UI's to turn either way (`harness-toggle-compaction-ask').  By hand (the UI's
;; `harness-compact', or the panel of a session whose prompt cache
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
;; A summary is the chat's next request, so it has the chat's own tools;
;; the instruction tells the model not to call one.  A brief summary is a
;; request of its own, with no tools.  An API provider gets the
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
;; A summary is made as the conversation's next step would be: the same
;; model, system prompt, tools, thinking level and conversation, with the
;; summarisation instruction appended as its last user message
;; (`harness-compaction--prefix-request').  A provider's prompt cache
;; reads a request only as far as it starts like the one that wrote the
;; cache, so the conversation is read at the cache price while the cache
;; lasts; only the instruction is uncached input.  The question before
;; an automatic compaction asks one flat list, the same the cold-cache
;; question asks (`harness-compaction--ask'): Summary, Transcript,
;; Fresh start, Continuation and Pause.  A summary is shown, no cache,
;; when the estimate says its own request would read the conversation
;; uncached, and its row says so.  A `brief' summary renders the
;; conversation's narrative anew, and a hosted loop is sent the
;; instruction as its newest message of a conversation it holds itself:
;; no cache of the chat covers either, so a brief is for a handoff, and
;; neither is made without an estimate that says its own request's prefix
;; is cached (`harness-compaction--prefix-cache-p').  Every automatic
;; path asks `harness-compaction--effective-kind' for the kind it may use,
;; and a summary or brief whose own request is not cached becomes a
;; transcript.  `compaction/compact'
;; is the single place that decides (`harness-compaction--compact-now'), so
;; a queued compaction, a stale caller or a new one cannot bypass it: OPTS
;; `:fallback' is the kind that asks no model to use instead, and without
;; one a summary whose own request is not cached is refused before a
;; request exists.  No choice, approval or saved answer is warmth: a user
;; who picks a summary, a saved always answer and the compact panel all
;; fail closed the same way.  A handoff's OPTS `:transfer' is the one
;; exception, as the conversation is going to a provider that never saw
;; it and no cache can hold it.  When neither the transcript nor a cut
;; can be made, the turn is held rather than the whole conversation sent
;; uncached.
;;
;; `compaction/status' grades how full the window is so a UI can colour
;; the token count progressively.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
;; The choices of the question before an automatic compaction are the
;; ways a conversation is carried over (`harness-carry.el').
(require 'harness-carry)
;; A compaction's text is in the prompt registry.
(require 'harness-prompts)
;; A summary is one of the harness's own one-off calls
;; (`harness-small-ask'), tried again when a provider fails transiently.
(require 'harness-small)

(defvar harness-provider-fallback-context-window)

(declare-function harness-agent-strip-result-images "harness-agent" (messages))
(declare-function harness-agent-step-request "harness-agent" (session-id state on-event))
(declare-function harness-cowboy--non-interactive-p "harness-cowboy" (session))
(declare-function harness-cowboy-parse-answer "harness-cowboy" (text))
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
this kind where nobody is asked, with one exception: a kind that asks a
model to read the conversation (`summary' or `brief') is made only when
the estimate says its own request is cached
\(`harness-compaction-request-warm-p'), and otherwise the conversation
is written to a transcript instead.  A `summary' is the chat's next
request with the instruction appended, so it reads the conversation
from the prompt cache while that lasts; a `brief' renders the narrative
anew, which no cache covers, and is a handoff's.  Where the user can be
asked, the question before it offers the menu both questions share
\(`harness-carry-menu': Summary, Transcript, Fresh start, Continuation
and Pause) with what each costs (`harness-compaction-ask'), carrying on
marked the default; a summary whose own request is not cached is shown,
no cache.  A kind they answer is chosen, but a model kind among them
is still made only when the estimate says its own request is cached, and
a transcript otherwise.  Answering it \"always\" with a kind makes that
kind this one and turns the asking off for every session, and a
session's own answer (`harness-toggle-compaction-ask') wins over it.
Compacting by hand (`harness-compact', or the
panel above the message box of a session whose prompt cache expired)
offers the same list, less Pause, under the same rule: no choice makes
a cold summary.  A standing exception for an informed user to buy a cold
summary is not implemented; it would be a policy decision to ask for
first."
  :type '(choice (const :tag "Summary: the session's model summarises the whole conversation" summary)
                 (const :tag "Brief: a cheap model summarises the narrative, tool calls in brief" brief)
                 (const :tag "Transcript: a file the model reads what it needs of" transcript)
                 (const :tag "Fresh start: nothing carried over; the model looks back when it needs to" fresh)
                 (const :tag "Context cut: drop the oldest messages and keep the newest as they are" truncate))
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

(defcustom harness-compaction-carry-on nil
  "Non-nil to carry on when a conversation nears its context window.
The automatic compaction then sends the conversation as it is, before a
turn and in the middle of one, instead of compacting it or asking what
goes first.  Answering \"always carry on\" to the question sets this,
and the settings page turns it off again.  A conversation past the
model's window is still sent as it is: the provider may refuse it."
  :type 'boolean :safe #'booleanp :group 'harness)

(defconst harness-compaction--system-prompt
  (harness-prompt-default 'compaction-system)
  "System prompt for the compaction summariser.
The default is the registry's `compaction-system'; a model may be sent
an override of it (`harness-prompt-overrides').")

(defconst harness-compaction--request-text
  (harness-prompt-default 'compaction-request)
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

(defvar harness-compaction--asking (make-hash-table :test 'equal)
  "Session id -> (:pid PID :settle FN) while its compaction question waits.
FN takes the choice and who made it, once: it lets the compaction go on.")

(defvar harness-compaction--revert-hold (make-hash-table :test 'equal)
  "Session id -> t while a reverted compaction waits for the next turn.
Set by `compaction/revert' when the conversation it gives back is over
the context limit but still fits the window: the user asked for the
model to see all of it, so the automatic compaction before the next
turn is skipped once (`harness-compaction--before-turn'), and does not
make the compaction again at once.  Gone as it is used, when a compaction
is made, restored, or the session is deleted; not kept across a restart.")

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

(defvar harness-compaction--carried-on (make-hash-table :test 'equal)
  "Session id -> t while the user's answer to carry on still stands.
Set when the automatic compaction question is answered with `carry-on':
the question is not put again, before the next turn or at the next
steps of one, at the size the conversation has or past the model's
window.  A boundary that finds the context under the limit forgets the
answer, a compaction or a trim having changed the conversation, and so
does another answer (`harness-compaction--note-answer').  Gone with the
session, and not kept across a restart; `harness-compaction-carry-on'
is the lasting answer.")

(defun harness-compaction-busy-p (session-id)
  "Non-nil while a compaction of SESSION-ID is under way."
  (and (gethash session-id harness-compaction--running) t))

;;;; Kinds

(defconst harness-compaction--model-kinds '(summary brief)
  "The kinds of compaction that ask a model to read the conversation.
A summary sends it as the chat's next request, with the instruction
appended, which the chat's prompt cache serves; a brief sends it as the
narrative of a request of its own, which none does.")

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
              (list (format "Unknown compaction kind · %s" kind))))
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

(defun harness-compaction--carried-on-p (session-id)
  "Non-nil when SESSION-ID's user chose to carry on.
The answer stands until the conversation changes or another answer
\(`harness-compaction--carried-on'), past the model's window too: a user
who chose to carry on is not asked again, and a provider that cannot
send the conversation says so."
  (and (gethash session-id harness-compaction--carried-on) t))

(defun harness-compaction--carry-on-always-p (session)
  "Non-nil when SESSION carries on instead of compacting or asking.
That is `harness-compaction-carry-on' in a session that would wait for
the user; one nobody asks -- a task, a seed -- compacts as its kind
says, so unattended work is not left to fail on an overgrown context."
  (and harness-compaction-carry-on
       (not (harness-compaction--non-interactive-p session))))

(defun harness-compaction--save-carry-on (session-id)
  "Make carrying on the lasting answer, as \"always carry on\" says.
`harness-compaction-carry-on' then stops the question before an
automatic compaction, and the settings page turns it off again.  A
failure to save is logged, never raised: the answer still stands for
SESSION-ID."
  (condition-case err
      (if (harness-method-exists-p 'config/set)
          (harness-call 'config/set 'harness-compaction-carry-on t)
        (harness-save-user-option 'harness-compaction-carry-on t))
    (error (harness-log 'warn "compaction: could not save carrying on for %s: %s"
                        session-id (harness-error-short-message err)))))

(defun harness-compaction--note-answer (session-id choice)
  "Keep, or forget, SESSION-ID's answer to the automatic compaction question.
CHOICE is what it was answered with: `carry-on' stands until the
conversation changes (`harness-compaction--carried-on'), and any other
answer ends it."
  (if (eq choice 'carry-on)
      (puthash session-id t harness-compaction--carried-on)
    (remhash session-id harness-compaction--carried-on)))

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

(defun harness-compaction--prefix-cache-p (session)
  "Non-nil when a summary request of SESSION would read the conversation cached.
That is when SESSION's own prompt cache lasts for its model
\(`harness-compaction--warm-p'), its provider is sent the conversation at
every request rather than keeping it itself, and the agent's request
builder is there to start the summary exactly as the conversation's next
step would (`harness-agent-step-request'): the same model, system
prompt, tools, thinking level and conversation, with the instruction
appended.  A summary so made is a request whose prefix the chat's cache
covers, so the conversation is read at the cache price; a hosted loop,
and a cold cache, hold no such prefix."
  (and (harness-compaction--warm-p session)
       (not (harness-compaction--hosted-model-p (plist-get session :model)))
       (fboundp 'harness-agent-step-request)
       t))

(defun harness-compaction--instruction (model)
  "Return the user message that asks MODEL to write a compaction summary.
The registry's compaction instructions come first, then the instruction
not to call a tool -- the summary request has the chat's tools, and it
must write, not work -- and the registry's request closes it.  This
text is appended to the conversation, which the prompt cache serves; it
is the only part of the request the cache does not hold."
  (string-join
   (delq nil
         (list (harness-prompt-effective 'compaction-system
                                         harness-compaction--system-prompt model)
               "Do not call any tool.  Answer with the summary alone."
               (harness-prompt-effective 'compaction-request
                                         harness-compaction--request-text model)))
   "\n\n"))

(defun harness-compaction--instruction-tokens (model)
  "Return about how many tokens `harness-compaction--instruction' takes."
  (harness-estimate-tokens (harness-compaction--instruction model)))

(defun harness-compaction--estimate-summary (session-id session context _warm ends)
  "Estimate a `summary' of SESSION, whose record is SESSION, of CONTEXT tokens.
A summary is made on a request that starts as the conversation's next
step would -- same model, system prompt, tools and conversation -- with
the summarisation instruction appended (`harness-compaction--summary-request'),
so the conversation is read from the prompt cache while it lasts
\(`harness-compaction--prefix-cache-p').  Its `:cached' says whether the
request this estimate prices is such a one: nil when the cache lapsed
or the provider keeps the conversation itself, in which case the whole
context is read uncached.  ENDS is `harness-compaction--verbatim-tokens':
what the first and last messages kept verbatim add to the result."
  (let* ((model (plist-get session :model))
         (ask (harness-compaction--instruction-tokens model))
         (output harness-compaction--summary-output)
         ;; A hosted loop forks the conversation it holds and is sent only
         ;; the instruction: no cache of a chat the harness cannot see is
         ;; needed, as the provider serves its own conversation.
         (cached (or (harness-compaction--prefix-cache-p session)
                     (and (harness-compaction--hosted-model-p model)
                          (harness-compaction--fork-p session-id model))))
         (uncached (harness-compaction--cost
                    model (list (harness-compaction--uncached-key model)
                                (+ context ask) :output output)))
         (cost (if cached
                   (harness-compaction--cost
                    model (list :cache-read context :input ask :output output))
                 uncached)))
    (list :kind 'summary :model model :model-label (harness-compaction--model-label model)
          :input (+ context ask) :output output :cached (and cached t)
          :available (and cached t)
          :cost cost :cost-uncached uncached
          :after (+ output ends))))

(defun harness-compaction--estimate-brief (session messages ends &optional model)
  "Estimate a `brief' summary of SESSION, whose provider messages are MESSAGES.
A brief summary of a `sample' renders the conversation's narrative anew,
so no cache of the conversation covers that request: it reads it all
uncached, and is offered only where a handoff has no cached alternative
\(`:available' is nil).  Its model is `harness-compaction-brief-model',
or MODEL when given.  ENDS is `harness-compaction--verbatim-tokens':
what the first and last messages kept verbatim add to the result."
  (let* ((model (or model (harness-compaction--brief-model session)))
         (input (+ (harness-estimate-tokens harness-compaction--system-prompt)
                   (harness-compaction--messages-tokens
                    (harness-compaction--narrative-messages messages))
                   (harness-compaction--instruction-tokens model)))
         (output harness-compaction--summary-output))
    (list :kind 'brief :model model :model-label (harness-compaction--model-label model)
          :input input :output output :cached nil :available nil
          :cost (harness-compaction--cost
                 model (list (harness-compaction--uncached-key model) input :output output))
          :after (+ output ends))))

(defun harness-compaction--estimate-transcript (context)
  "Estimate a `transcript' of a conversation of CONTEXT tokens.
No model is asked anything; the note left in its place is about as
long as an example of it."
  (list :kind 'transcript :model nil :model-label nil :input 0 :output 0 :cached nil :cost 0.0
        :available t
        :after (harness-estimate-tokens (harness-compaction--transcript-note "/a/file.md" 1000))
        :file-tokens context))

(defun harness-compaction--estimate-fresh (count context)
  "Estimate a `fresh' start after COUNT messages of CONTEXT tokens.
No model is asked anything, and only the note saying so stands for
the conversation."
  (list :kind 'fresh :model nil :model-label nil :input 0 :output 0 :cached nil :cost 0.0
        :available t
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
              :available t
              :after (+ (harness-estimate-tokens note) kept-tokens)
              :kept (length kept) :dropped (length dropped)
              :kept-tokens kept-tokens :dropped-tokens dropped-tokens))
    (harness-error
     (list :kind 'truncate :model nil :model-label nil :input 0 :output 0 :cached nil :cost 0.0
           :available t
           :after context :kept (length (harness-call 'session/messages session-id)) :dropped 0))))

(harness-defmethod compaction/estimate (session-id &optional opts)
  "Say what compacting SESSION-ID costs, kind by kind, and what carrying on does.
Return (:context N :model MODEL :model-label LABEL :cached BOOL
:carry-on USD :carry-on-cached USD :compacting BOOL :kind KIND
:kinds ESTIMATES).  N is the context the next message sends, the
last request's or else an estimate of the transcript's; `:cached' says
the session's prompt cache still lasts for MODEL, `:carry-on' what the
next message costs to send N as things are, `:carry-on-cached' what it
would cost read from the cache.  `:compacting' says a compaction is
under way and `:kind' is `harness-compaction-kind'.  ESTIMATES has one
plist per kind of `harness-compaction-kinds', (:kind KIND :model MODEL
:model-label LABEL :input N :output N :cached BOOL :available BOOL :cost
USD :after N): the model that would write it, the tokens it would read
and write (`:cached' when it would read them from the cache), whether it
can be made as it is (`:available': a summary only when its own request
starts as the conversation's next step would and the cache holds it,
a `brief' one only where a handoff has no cached alternative), what that
costs, and the context that stands for the conversation after it -- a
model-written one keeps the conversation's first and last messages
verbatim, which that number includes.  Costs are at list prices, nil
where the catalogue has none, and `transcript' and `fresh', which ask no
model, cost 0; a transcript's `:file-tokens' is about how much the file
holds.  `:messages' is how many messages the conversation sends now.  A
`summary' also says what it would cost once the prompt cache lapsed,
`:cost-uncached': its `:cost' while the cache lasts is the cheaper one,
and a client that keeps the answer for a while reads the other when the
cache lapses meanwhile.

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
                   (list (format "Unknown compaction context · %s" context))))))

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

(defun harness-compaction--with-ask (messages &optional model)
  "Return MESSAGES with the summarisation request in its final user message.
MODEL, when given, is the model asked; its override of the registry's
`compaction-request' is used."
  (let ((ask (list :type "text"
                   :text (harness-prompt-effective 'compaction-request
                                                   harness-compaction--request-text model)))
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
       contextual)
     model)))

(defun harness-compaction--prefix-request (session model &optional state)
  "Return the request that writes a summary from SESSION's own prompt cache.
It starts exactly as the conversation's next step would
\(`harness-agent-step-request'): the same model, system prompt, tools,
thinking level, provider state and conversation, so the provider's prompt
cache serves the conversation; the summarisation instruction is appended
as its last user message, which is all the request adds.  MODEL is the
summariser, the session's own."
  (let* ((base (harness-agent-step-request (plist-get session :id) state nil))
         (messages (plist-get base :messages))
         (ask (list :type "text" :text (harness-compaction--instruction model)))
         (last (car (last messages)))
         (messages
          (if (and last (eq (plist-get last :role) 'user))
              (append (butlast messages)
                      (list (plist-put (copy-sequence last) :content
                                       (append (plist-get last :content) (list ask)))))
            (append messages (list (list :role 'user :content (list ask)))))))
    (append (harness-plist-remove base :on-event :max-tokens)
            (list :messages messages
                  :max-tokens harness-compaction--max-tokens))))

(defun harness-compaction--summary-request (session model state messages &optional warm)
  "Return the one-off request that asks MODEL to summarise SESSION.
STATE is the provider state MODEL gets, as `compaction/compact' has it,
and MESSAGES the conversation it reads.  WARM non-nil says the summary
is made as the conversation's next request would be,
with the instruction appended (`harness-compaction--prefix-request'), so
it reads the conversation from the prompt cache: the caller only says so
when its own model is the session's, its provider is sent the
conversation at every request, and the cache lasts.  Otherwise -- a
hosted loop, another model, a cold cache -- it has a system prompt and a
tool list of its own, which no cache of the conversation covers."
  (if warm
      (harness-compaction--prefix-request session model state)
    (list :model model :session session
          :system (harness-prompt-effective 'compaction-system
                                            harness-compaction--system-prompt model)
          :messages messages :tools nil :provider-state state
          :max-tokens harness-compaction--max-tokens)))

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
  (let ((tokens (format "~%s tokens" (harness-format-tokens input-tokens))))
    (pcase kind
      ('brief (format "Compaction · %s · brief" tokens))
      ('transcript (format "Compaction · %s · transcript · %s"
                          tokens
                          (abbreviate-file-name (or (plist-get meta :file) "file"))))
      ('fresh (format "Fresh start · %s" tokens))
      ('truncate (format "Context cut · %s · %d nodes"
                         tokens (or (plist-get meta :truncate-dropped) 0)))
      (_ (format "Compaction · %s · summary" tokens)))))

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
TRAILING.  Those are nodes of the conversation that stay where they
were in it, moved behind the compaction node; the compaction node
itself then follows the node before the first of them, so the nodes cut
away stay on the session's path, before it, for `session_history' to
read and for the user to go back to (`compaction/revert').  META
`:mid-turn' says it was made in the middle of a turn
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
    ;; Re-appending a kept node moves it behind the compaction node, with
    ;; its id, so what came before it would be cut off the path unless the
    ;; node follows the one before the first of them.
    (when keep
      (setq node (harness-call 'session/update-node session-id (plist-get node :id)
                               :parent (plist-get (car keep) :parent))))
    (remhash session-id harness-compaction--revert-hold)
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
                                (list :title "Compaction"
                                      :about (format "Compaction · %s · session note"
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
         ;; The conversation as the model has it: from the compaction in
         ;; force, a reverted one being none (`harness-path-from-compaction').
         (path (harness-path-from-compaction (harness-call 'session/nodes session-id)))
         (tail (if (harness-node-compaction-p (car path)) (cdr path) path))
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
                                              :dropped-tokens (plist-get plan :dropped-tokens)
                                              ;; The node the cut conversation ends at, which the
                                              ;; compaction node follows: it can be reverted
                                              ;; (`compaction/revert').
                                              :truncate-after (plist-get (car keep) :parent))
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
`harness-compaction--finish').  A summary of the whole conversation on the
session's own model, while its cache lasts, is sent as the conversation's
next request would be, so it reads the conversation from the prompt
cache (`harness-compaction--summary-request').  The node's content keeps
the conversation's first and last messages verbatim around the summary
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
         (warm (and (eq context 'full)
                    (equal model (plist-get session :model))
                    (harness-compaction--prefix-cache-p session)))
         (estimate (or (let ((c (plist-get (plist-get session :usage) :context)))
                         (and (numberp c) (> c 0) c))
                       (harness-compaction--messages-tokens messages)))
         (text "") (usage nil))
    (harness-log 'info "compaction: summarising %s with %s (%s context, %s tokens%s)"
                 session-id model context estimate (if warm ", from the prompt cache" ""))
    ;; A one-off call through `harness-small-ask': a provider's bad minute
    ;; -- a rate limit, a connection cut -- is waited out and the summary
    ;; asked for again, as a step of a turn would be.  A try that failed
    ;; left no summary behind, so the retry cannot duplicate one.
    (harness-prompt-ask
     '(compaction-system compaction-request)
     (harness-compaction--summary-request session model state messages warm)
     (list :label "compaction"
           :on-event
           (lambda (ev)
             (pcase (plist-get ev :type)
               ;; A try that failed is thrown away: so is what it wrote.
               ('restart (setq text "" usage nil))
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

(defun harness-compaction-request-warm-p (session-id kind &optional model)
  "Non-nil when KIND's own request of SESSION-ID is known to read cached input.
Only `compaction/estimate' can say so: its entry for KIND must report
`:cached'.  MODEL, when given, is the model the request would be sent
to; the estimate must price that same model, or it says nothing about
this request.  A summary of the whole conversation can be warm, because
it is sent as the conversation's next request with the instruction
appended (`harness-compaction--summary-request'), so the prompt cache
holds its prefix while it lasts (`harness-compaction--prefix-cache-p');
a `brief' one, whose narrative is rendered anew, cannot be.  A user's
choice, a saved answer or OPTS `:approved' is no evidence either:
warmth is the only thing that may put a model kind on the wire."
  (let* ((estimate (and (harness-method-exists-p 'compaction/estimate)
                        (ignore-errors (harness-call 'compaction/estimate session-id))))
         (entry (and estimate
                     (cl-find kind (plist-get estimate :kinds)
                              :key (lambda (k) (plist-get k :kind))))))
    (and entry
         (harness-json-true-p (plist-get entry :cached))
         (or (null model) (equal model (plist-get entry :model))))))

(defun harness-compaction--compaction-model (session kind opts)
  "Return the model a compaction of KIND for SESSION would ask, as OPTS say.
OPTS `:model' overrides it, as `compaction/compact' does; a brief
summary otherwise uses `harness-compaction-brief-model', and a summary
the session's own model."
  (or (plist-get opts :model)
      (if (eq kind 'brief)
          (harness-compaction--brief-model session)
        (plist-get session :model))))

(defun harness-compaction--effective-kind (session-id kind opts)
  "Return the kind a compaction of KIND as OPTS may use for SESSION-ID.
A kind that asks a model (`harness-compaction--model-kinds') is made
only when the estimate says that request's own prefix is cached, for the
very model the request would go to
\(`harness-compaction-request-warm-p'): nobody's choice, approval or
saved answer overrides that.  OPTS `:transfer' is the one exception: the
conversation is being handed to a provider that never saw it
\(harness-handoff.el), so there is no cache to read and the transfer is
the point; its cost is what that transfer costs.  Otherwise OPTS
`:fallback' is used, a kind that asks no model, and without one the
compaction is refused before a request exists, saying what to use
instead."
  (if (or (not (memq kind harness-compaction--model-kinds))
          (harness-json-true-p (plist-get opts :transfer))
          (let ((session (ignore-errors (harness-call 'session/get session-id))))
            (and session
                 (harness-compaction-request-warm-p
                  session-id kind
                  (harness-compaction--compaction-model session kind opts)))))
      kind
    (let ((fallback (harness-compaction--kind (plist-get opts :fallback))))
      (unless (memq fallback '(transcript fresh truncate))
        (signal 'harness-error
                (list (format (concat "A %s reads the conversation on a request of its own, and the"
                                      " prompt cache does not hold it: it cannot be shown to read"
                                      " cached input.  Use transcript, fresh or truncate instead")
                              (harness-compaction--kind-name kind)))))
      fallback)))

(defun harness-compaction--bounded-compaction (session-id &optional meta)
  "Compact SESSION-ID without asking a model: a transcript, else a cut.
META is the node's `:meta'.  Return a promise of the node, or of nil
when neither could be made."
  (harness-catch
   (harness-call-async 'compaction/compact session-id
                       (list :kind 'transcript :meta meta))
   (lambda (_err)
     (harness-catch
      (harness-call-async 'compaction/compact session-id
                          (list :kind 'truncate :meta meta))
      (lambda (_err) (harness-resolved nil))))))

(defconst harness-compaction--uncacheable-reason
  "context too large · no compaction · message hold"
  "Why a turn is held when its conversation could not be compacted at all.")

(defconst harness-compaction--held-step-reason
  "context full · step hold"
  "Why a step is refused when its compaction was dismissed or held back.
A dismissed question is not an answer to send the whole conversation
uncached with, and neither is `hold'.")

(defun harness-compaction--compact-now (session-id opts)
  "Compact SESSION-ID at once as OPTS says; return a promise of the node.
OPTS are those of `compaction/compact' without the flags that decide when
to run (`:queue', `:interrupt', `:idle').  A compaction already running
returns its promise.  The kind is the one OPTS may use
\(`harness-compaction--effective-kind'): a summary or brief request whose
own prefix is not known to be cached is made as OPTS `:fallback'
instead, and said so in a hint.  The kind and the model the request
would really go to are decided before the guard looks at warmth: OPTS
`:context' `sample' makes a summary a brief, whose model is
`harness-compaction-brief-model', and OPTS `:model' is what either kind
would be sent to."
  (or (gethash session-id harness-compaction--running)
      (let* ((session (harness-call 'session/get session-id))
             (context (harness-compaction--context (plist-get opts :context)))
             (requested (harness-compaction--kind (plist-get opts :kind) (plist-get opts :context)))
             ;; The request's own kind first: a summary of a sample is a
             ;; brief, and that is the request whose warmth matters.
             (requested (if (and (eq requested 'summary) (eq context 'sample)) 'brief requested))
             (context (if (eq requested 'brief) 'sample context))
             (effective (harness-compaction--effective-kind session-id requested opts))
             (downgraded (not (eq effective requested)))
             (kind effective)
             (model (harness-compaction--compaction-model session kind opts))
             (caveat (if (plist-member opts :caveat)
                         (plist-get opts :caveat)
                       (and (eq kind 'brief) (harness-compaction--brief-caveat model))))
             (meta (append (and downgraded
                                (list :requested-kind (symbol-name requested)
                                      :not-warm t))
                           (plist-get opts :meta)))
             (promise (harness-make-promise)))
        (puthash session-id promise harness-compaction--running)
        (harness-finally promise (lambda () (remhash session-id harness-compaction--running)))
        (when downgraded
          ;; Its own request is not known to be cached: say what was made
          ;; in its place.
          (harness-call 'session/hint session-id
                        (harness-compaction--not-warm-hint requested kind)))
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
                           " · mid-turn"
                         "")))
            (harness-call 'session/hint session-id
                          (if (eq kind 'brief)
                              (format "Compaction%s · brief · %s"
                                      where (harness-compaction--model-label model))
                            (format "Compaction%s" where))))
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

A `summary' reads the whole conversation on a request that starts as
the conversation's next step would -- same model, system prompt, tools
and conversation -- with the summarisation instruction appended, so the
provider's prompt cache serves the conversation while it lasts
\(`harness-compaction--prefix-cache-p').  A `brief' summary renders the
conversation's narrative anew, which no cache of the conversation
covers, and is for a handoff, where the new model has to be told it in
text.  Either is made only when `compaction/estimate' says that
request's own prefix is cached, for the very model the request would go
to.  Otherwise OPTS `:fallback', a kind that asks no model
\(`transcript', `fresh' or `truncate'), is made instead, said in a hint
and kept in the node's `:meta' as `:requested-kind'; without
`:fallback' the call is refused before a request exists.  Nobody's
choice, approval or saved answer is warmth: OPTS `:approved' is not a
way around this, and neither is an answer to the question, a saved
cowboy choice, the compact panel or an agent's own tool.  OPTS
`:transfer' is the exception, for a handoff: the conversation goes to a
provider that never saw it, so no cache can hold it and the transfer is
the point.

A `summary' is written by the session's model, or OPTS `:model'.  It
covers the whole conversation.  OPTS `:context' is `full' (the
default), which lets the summariser see the
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
                  (list "session running · compact after the turn")))
         (t (harness-compaction--compact-now session-id opts))))))

(defun harness-compaction--fail (session-id promise err)
  "Reject PROMISE with ERR and tell SESSION-ID about it.
ERR is reported short (`harness-error-short-message'): the failure of a
summariser can carry a whole transcript or request body as its data, and
none of that belongs in *Messages*, in a hint or in the tree."
  (let ((msg (harness-error-short-message err)))
    (harness-log 'warn "compaction of %s failed: %s" session-id msg)
    (ignore-errors (harness-call 'session/hint session-id (format "Compaction failure · %s" msg)))
    (harness-emit 'compaction/failed session-id msg)
    (harness-reject promise err)))

;;;; Reverting a compaction

(defun harness-compaction--latest (session-id)
  "Return the latest compaction node on SESSION-ID's path, reverted or not, or nil."
  (cl-find-if #'harness-node-compaction-p (harness-call 'session/nodes session-id) :from-end t))

(defun harness-compaction--toggle-busy (session-id)
  "Return why SESSION-ID's compaction cannot be reverted or restored now, or nil.
That is the same wait a message has: a compaction under way
\(`harness-compaction-busy-p'), one queued for the turn's next boundary,
or a turn that runs -- it is writing into the conversation whose
context this would change."
  (cond
   ((harness-compaction-busy-p session-id)
    "a compaction is under way; wait for it to finish")
   ((gethash session-id harness-compaction--pending)
    "a compaction is queued for the turn's next boundary")
   ((and (harness-method-exists-p 'agent/running) (harness-call 'agent/running session-id))
    "the session is running a turn; wait for it to end, or stop it")))

(defun harness-compaction--toggle-refusal (session-id node node-id revert)
  "Return why compaction NODE of SESSION-ID cannot be reverted, or nil.
REVERT non-nil says it is a revert, else a restore, and NODE-ID is the
node the caller named, or nil.  The latest compaction on the path is the
only one that can be: an older one keeps the state it had when the next
was made, which undoing the latest returns the conversation to."
  (let* ((verb (if revert "reverted" "restored"))
         (kind (harness-node-compaction-kind node))
         (path (harness-call 'session/nodes session-id)))
    (cond
     ((null node)
      (format "This conversation has no compaction to %s" (if revert "revert" "restore")))
     ((and node-id (not (equal node-id (plist-get node :id))))
      (format "Only the latest compaction can be %s: %s is an older one" verb node-id))
     ((harness-node-handoff node)
      (format "A compaction made to hand the conversation over to another model cannot be %s" verb))
     ((zerop (cl-position (plist-get node :id) path :key (lambda (n) (plist-get n :id)) :test #'equal))
      "There is nothing before this compaction to go back to")
     ((and (equal kind "truncate") (not (plist-get (plist-get node :meta) :truncate-after)))
      (concat "This cut was made before the harness kept the conversation it cut on the record,"
              " so it cannot be " verb))
     ((let ((busy (harness-compaction--toggle-busy session-id)))
        (and busy (format "The compaction cannot be %s now: %s" verb busy)))))))

(defun harness-compaction--mark-reverted (session-id node reverted)
  "Set compaction NODE of SESSION-ID reverted, or in force when REVERTED is nil.
The mark is its `:meta' `:reverted', which the node log keeps and the
UIs follow (`session/node-updated').  Return the node."
  (let ((meta (harness-plist-remove (plist-get node :meta) :reverted)))
    (harness-call 'session/update-node session-id (plist-get node :id)
                  :meta (if reverted (plist-put meta :reverted t) meta))))

(defun harness-compaction--live-tokens (session-id)
  "Estimate the tokens of the conversation SESSION-ID's model is sent now.
The nodes from the compaction in force on (`harness-path-from-compaction'),
the hints, which no model is sent, left out.  A tool call counts its input
as well as its result, which the estimate of the messages
\(`harness-compaction--messages-tokens') does not."
  (harness-compaction--nodes-tokens
   (cl-remove-if (lambda (n) (eq (plist-get n :kind) 'hint))
                 (harness-path-from-compaction (harness-call 'session/nodes session-id)))))

(defun harness-compaction--toggle-text (revert tokens window)
  "Return the sentence that tells the context became TOKENS after a toggle.
REVERT non-nil says the compaction was reverted, else restored; WINDOW
is the model's context window, TOKENS being more than it when the
conversation before the compaction does not fit."
  (if revert
      (format "Compaction · reverted · ~%s tokens%s"
              (harness-format-tokens tokens)
              (if (> tokens window)
                  (format " · window %s" (harness-format-tokens-compact window))
                ""))
    (format "Compaction · restored · ~%s tokens" (harness-format-tokens tokens))))

(defun harness-compaction--toggle (session-id node-id revert)
  "Revert the latest compaction of SESSION-ID, or restore it when REVERT is nil.
NODE-ID, when non-nil, names the compaction the caller means (see
`compaction/revert').  Return the answer of `compaction/revert'."
  (unless (harness-call 'session/exists-p session-id)
    (signal 'harness-error (list (format "No session %s" session-id))))
  (let* ((node (harness-compaction--latest session-id))
         (why (harness-compaction--toggle-refusal session-id node node-id revert)))
    (when why (signal 'harness-error (list why)))
    (let ((state (if revert 'reverted 'compacted)))
      (if (eq revert (harness-node-compaction-reverted-p node))
          ;; Asked for what is the case already -- a second click on a
          ;; button that has not changed yet -- so there is nothing to do.
          (list :state state :changed :false :node-id (plist-get node :id)
                :message (if revert
                             "reverted already"
                           "compacted already"))
        (harness-log 'info "compaction: %s %s the compaction %s" session-id
                     (if revert "reverts" "restores") (plist-get node :id))
        (harness-compaction--mark-reverted session-id node revert)
        ;; The model's next request is another conversation than the last:
        ;; a hosted loop starts a new one, and nothing the provider cached
        ;; of the old one is read, as after a compaction.
        (harness-compaction--start-over session-id)
        (let* ((session (harness-call 'session/get session-id))
               ;; The conversation given back is at least as big as it was when
               ;; the compaction replaced it, the size the model reported then.
               (tokens (max (harness-compaction--live-tokens session-id)
                            (or (and revert (plist-get (plist-get node :meta) :input-tokens)) 0)))
               (window (harness-compaction--window session))
               (text (harness-compaction--toggle-text revert tokens window)))
          (harness-call 'session/usage-add session-id
                        (list :context tokens :last-output 0 :cache-reset t))
          (if (and revert (<= tokens window))
              (puthash session-id t harness-compaction--revert-hold)
            (remhash session-id harness-compaction--revert-hold))
          (harness-call 'session/hint session-id text)
          (list :state state :changed t :node-id (plist-get node :id)
                :context tokens :window window :message text))))))

(harness-defmethod compaction/revert (session-id &optional node-id)
  "Go back to the conversation before the latest compaction of SESSION-ID.
The model is sent that conversation whole again, from the start (or
from the compaction before), followed by whatever was said since --
instead of the summary that stood in for it.  Nothing is deleted: the
compaction node stays where it is, marked reverted in its `:meta'
\(`harness-node-compaction-reverted-p'), and `compaction/restore'
undoes this, any number of times, as the user does with undo and redo.
NODE-ID, when given, is the compaction the caller means; it must be the
latest one, the only one that can be reverted (an older one keeps the
state it had when the next was made, which undoing the latest returns the
conversation to), and it must not be one made to hand the conversation
over to another model.

Refused while a compaction is under way, one is queued, or a turn runs.
The conversation the model is sent is another one, so its prompt cache
is dropped as a compaction drops it (`session/usage-add' `:cache-reset')
and a hosted loop starts a new conversation; the context the session
reports becomes an estimate of the new one.  When that is over the
context limit but fits the window, the automatic compaction before the
next turn is skipped once (`harness-compaction--revert-hold'), or it
would make the compaction again at once; the mid-turn one is not.  A hint
in the transcript says what the model sees now.

Return (:state STATE :changed BOOL :node-id ID :message TEXT :context N
:window N): STATE is `reverted', `:changed' false when the compaction was
reverted already, N the estimated context tokens and the model's window,
TEXT what to tell the user.  The node's update (`session/node-updated')
is what a chat follows to draw the other button."
  (harness-compaction--toggle session-id node-id t))

(harness-defmethod compaction/restore (session-id &optional node-id)
  "Go back to the latest compaction of SESSION-ID, reverted before.
The model is sent its summary (or note, or the cut conversation) again
instead of the conversation before it: the redo of `compaction/revert',
with the same rules, the same refusals and the same answer, whose
STATE is `compacted'."
  (harness-compaction--toggle session-id node-id nil))

;;;; Waiting for the next boundary

(defun harness-compaction--kind-name (kind)
  "Return the name people read for KIND."
  (pcase kind
    ('brief "brief")
    ('transcript "transcript")
    ('fresh "fresh start")
    ('truncate "cut context")
    (_ "summary")))

(defun harness-compaction--not-warm-hint (requested kind)
  "Return the hint saying REQUESTED was not made since its request is not cached.
KIND, which asks no model, was made in its place."
  (format "%s · no cache · %s"
          (capitalize (harness-compaction--kind-name requested))
          (harness-compaction--kind-name kind)))

(defun harness-compaction--say-not-warm (session-id requested kind)
  "Say in SESSION-ID that REQUESTED was not made, KIND instead.
Nothing is said when they are the same, or when REQUESTED asks no
model: then its request is not one a prompt cache could hold."
  (when (and (memq requested harness-compaction--model-kinds)
             (not (eq requested kind)))
    (harness-call 'session/hint session-id
                  (harness-compaction--not-warm-hint requested kind))))

(defun harness-compaction--enqueue (session-id opts)
  "Register OPTS as the compaction SESSION-ID gets at its next boundary.
The running turn goes on.  Return a promise that resolves at once to
\(:queued t :kind KIND :interrupt BOOL), never when the compaction later
runs -- a tool awaiting it would otherwise hold its own step.  OPTS
`:interrupt' also cancels the running turn (`agent/cancel'), after the
entry is stored, so the compaction runs once the turn is over.  A
compaction already waiting is replaced."
  (let* ((context (harness-compaction--context (plist-get opts :context)))
         (requested (harness-compaction--kind (plist-get opts :kind) (plist-get opts :context)))
         ;; A summary of a sample is a brief: that is the request queued.
         (requested (if (and (eq requested 'summary) (eq context 'sample)) 'brief requested))
         (kind (harness-compaction--effective-kind session-id requested opts))
         (interrupt (and (harness-json-true-p (plist-get opts :interrupt)) t))
         (opts (plist-put (copy-sequence opts) :kind (symbol-name kind))))
    (unless (eq kind requested)
      ;; A summary nobody chose, whose own request is not cached, is not
      ;; made: say so now, while the kind is chosen, not when it runs.
      (harness-call 'session/hint session-id
                    (format "%s · no cache · %s"
                            (capitalize (harness-compaction--kind-name requested))
                            (harness-compaction--kind-name kind)))
      (setq opts (plist-put opts :meta
                            (append (list :requested-kind (symbol-name requested)
                                          :not-warm t)
                                    (plist-get opts :meta)))))
    (when (gethash session-id harness-compaction--pending)
      (harness-log 'info "compaction: replacing the compaction queued for %s" session-id))
    (puthash session-id (list :opts opts :interrupt interrupt) harness-compaction--pending)
    (harness-call 'session/hint session-id
                  (if interrupt
                      (format "Compaction · queue · interruption · %s"
                              (harness-compaction--kind-name kind))
                    (format "Compaction · queue · next boundary · %s"
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
    (let ((id (plist-get session :id)))
      (harness-then
       (harness-compaction--run-pending id)
       (lambda (_) (funcall next value))
       (lambda (_err)
         ;; A queued compaction that failed leaves a conversation too
         ;; large to send: bound it before the turn goes on.
         (harness-then
          (harness-compaction--bounded-compaction id)
          (lambda (node)
            (funcall next (if node value
                              (list :proceed nil :reason harness-compaction--uncacheable-reason)))))))))
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
  (remhash session-id harness-compaction--revert-hold)
  (remhash session-id harness-compaction--carried-on)
  (remhash session-id harness-compaction--pending)
  (remhash session-id harness-compaction--asking))

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

;;;; Asking before compacting automatically
;;
;; Compacting costs money -- a summary reads the whole conversation again
;; -- and it changes what the model is sent from then on.  So it is the
;; user's to choose: where they can be asked, the automatic compaction
;; asks first, as the cold-cache question does (harness-cowboy.el), with
;; what each kind costs and what carrying on costs, and it compacts only
;; when told to.  An answer to carry on stands: the question is not put
;; again -- before the next turn, nor at the next steps of one, past the
;; window too -- until the context has been under the limit since, a
;; compaction or a trim having made it another conversation
;; (`harness-compaction--carried-on').  Asking three steps later, for a
;; conversation a few thousand tokens longer, is asking about an answer
;; already given.  "Always carry on" makes it lasting
;; (`harness-compaction-carry-on'), for every session that would wait
;; for the user.  Answering "always" with a kind makes that kind
;; `harness-compaction-kind' and turns `harness-compaction-ask' off, so
;; every session after it compacts unasked, and keeps the answer as a
;; lasting decision whose [Turn off] asks again
;; (`harness-compaction--remember').  A session's own answer
;; (`:compaction-ask' in its `:ext') is the UI's to turn either way
;; (`harness-toggle-compaction-ask'), and wins over the default; so why
;; a compaction went unasked is either that the user chose it or that
;; nobody could be asked (`harness-compaction--by').  Where nobody is
;; asked -- asking off, a session whose own answer turns it off, a
;; non-interactive one -- it makes `harness-compaction-kind', as before,
;; and the transcript says so.
;; Whatever made it, a compaction can be taken back and made again
;; afterwards (`compaction/revert', `compaction/restore'); the question
;; takes nothing of that away.

(defconst harness-compaction--ask-ext-key :compaction-ask
  "The session's `:ext' key that answers whether its compaction asks.
`t' asks, `:false' compacts unasked as `harness-compaction-kind' says,
and no value follows the default, `harness-compaction-ask'.")

(defcustom harness-compaction-ask t
  "Non-nil to ask before an automatic compaction, where the user can be asked.
Automatic compaction is the one the harness makes by itself when a
conversation comes near its context window, before a turn or in the
middle of one.  Compacting spends money -- a `summary' reads the
conversation again, from the prompt cache while it lasts -- so with this
on, in a session that waits for the user, the question comes first, with
what each way costs and what carrying on costs, and the conversation is
compacted only as they answer.  Nil compacts as `harness-compaction-kind'
says without asking, as a session nobody is asked about always does: a
non-interactive one, and any session whose own answer
\(`:compaction-ask' in its `:ext') turns asking off.  Answering the
question \"always\" with a kind turns this off and makes the kind
`harness-compaction-kind' (`harness-ui-compaction-ask');
`harness-toggle-compaction-ask' turns it off or on for one session, and
`harness-set-compaction-ask-all' for every current session, which also
saves this option."
  :type 'boolean :safe #'booleanp :group 'harness)

(defun harness-compaction--non-interactive-p (session)
  "Non-nil when SESSION never waits for the user.
A switch the policy sets wins, then the session's own, then
`harness-non-interactive' where the session works, as the cold-cache
question reads it (`harness-cowboy--non-interactive-p')."
  (if (fboundp 'harness-cowboy--non-interactive-p)
      (harness-cowboy--non-interactive-p session)
    (harness-json-true-p (plist-get session :non-interactive))))

(defun harness-compaction--session-ask (session)
  "Return SESSION's own answer to whether an automatic compaction asks.
That is its `:ext' `:compaction-ask': t to ask, `:false' to compact
unasked, nil for no answer of its own."
  (let ((value (plist-get (plist-get session :ext) harness-compaction--ask-ext-key)))
    (and value (if (harness-json-true-p value) t :false))))

(defun harness-compaction--ask-value (session)
  "Return whether an automatic compaction of SESSION asks, before the rest.
That is the session's own answer when it has one, else the default,
`harness-compaction-ask'."
  (let ((own (harness-compaction--session-ask session)))
    (if own (harness-json-true-p own) harness-compaction-ask)))

(defun harness-compaction--asks-p (session)
  "Non-nil when an automatic compaction of SESSION is put to its user first.
It is not asked where asking is off -- the default's or the session's
own, which wins (`harness-compaction--ask-value') -- nor of a session
that never waits for the user, nor where no `question/ask' can be
had."
  (and (harness-compaction--ask-value session)
       (not (harness-compaction--non-interactive-p session))
       (harness-method-exists-p 'question/ask)))

(defun harness-compaction--by (session)
  "Return who decided that SESSION's compaction is made unasked.
`always' when the user turned asking off -- in the default, or for the
session -- and `unasked' when nobody could be asked, which is a
non-interactive session or one without `question/ask'."
  (if (not (harness-compaction--ask-value session)) 'always 'unasked))

(defun harness-compaction--estimate (session-id)
  "Return `compaction/estimate''s answer for SESSION-ID, or nil."
  (and (harness-method-exists-p 'compaction/estimate)
       (condition-case err
           (harness-call 'compaction/estimate session-id)
         (error (harness-log 'warn "compaction: no estimate for %s: %s"
                             session-id (harness-error-short-message err))
                nil))))

(defun harness-compaction--default-choice (choices)
  "Return the choice of CHOICES that the compaction question marks as its default.
That is carrying on: it changes nothing, and a default that compacts the
conversation is too easy to give by accident."
  (cl-find "carry-on" choices :key (lambda (c) (plist-get c :choice)) :test #'equal))

(defun harness-compaction--option-text (choice default)
  "Return CHOICE as one option of an ordinary question, DEFAULT marked.
An unavailable choice says it is not offered in place of its price."
  (let ((cost (plist-get choice :cost-text))
        (default (and default (equal (plist-get choice :choice) default))))
    (concat (plist-get choice :label)
            (cond ((and cost default) (format " (%s · default)" cost))
                  (cost (format " (%s)" cost))
                  (default " (default)")))))

(defun harness-compaction--not-offered-text (choice)
  "Return the note saying why CHOICE cannot be made as things are.
A summary is the only way the menu offers that asks a model to read the
conversation; one whose own request the prompt cache does not hold is
shown, not offered."
  (format "%s · %s" (plist-get choice :label) (plist-get choice :why)))

(defun harness-compaction--ask-text (session estimate &optional note)
  "Return the question before an automatic compaction.
NOTE, when given, opens it because the answer named no choice."
  (let* ((context (or (plist-get estimate :context)
                      (plist-get (plist-get session :usage) :context)))
         (window (harness-compaction--window session))
         (known (and (numberp context) (> context 0)))
         (over (and known (> context window))))
    (concat
     (if note (concat note "  ") "")
     (cond
      ((and known over)
       (format "Context · ~%s of ~%s tokens"
               (harness-format-tokens context) (harness-format-tokens window)))
      (known
       (format "Context · ~%s of ~%s tokens"
               (harness-format-tokens context) (harness-format-tokens window)))
      (t "Context · near full")))))

(defun harness-compaction--always-names (choices)
  "Return the names of CHOICES the question lets answer \"always\".
That is every choice but `hold', which is no lasting answer: a kind
makes `harness-compaction-kind' and stops the asking
\(`harness-compaction--remember'), and carrying on is
`harness-compaction-carry-on' (`harness-compaction--save-carry-on')."
  (mapcar (lambda (choice) (plist-get choice :choice))
          (cl-remove-if (lambda (choice) (equal (plist-get choice :choice) "hold"))
                        choices)))

(defun harness-compaction--ask-info (session estimate where default choices)
  "Return the `:compaction' of the question before an automatic compaction.
SESSION is the session's record, ESTIMATE `compaction/estimate''s
answer or nil, WHERE `turn' or `step', DEFAULT the name of the choice
marked as the default, and CHOICES the menu.  It is what a client needs
to draw more than the question: what the context is against what the
model can be sent, what carrying on costs with and without the cache,
and per choice its cost, the model doing it and the context after it."
  (let ((window (harness-compaction--window session)))
    (list :reason "context"
          :where (symbol-name where)
          :context (or (plist-get estimate :context)
                       (plist-get (plist-get session :usage) :context))
          :window window
          :usable (harness-compaction--usable window (harness-compaction--reserve session))
          :model (plist-get session :model)
          :model-label (or (plist-get estimate :model-label) (plist-get session :model))
          :cached (and (plist-get estimate :cached) t)
          :carry-on (plist-get estimate :carry-on)
          :carry-on-cached (plist-get estimate :carry-on-cached)
          :default default
          :choices (mapcar (lambda (choice)
                             (list :choice (plist-get choice :choice)
                                   :key (plist-get choice :key)
                                   :label (plist-get choice :label)
                                   :what (plist-get choice :what)
                                   :cost (plist-get choice :cost)
                                   :cost-text (plist-get choice :cost-text)
                                   :after (plist-get choice :after)
                                   :unavailable (and (plist-get choice :unavailable) t)
                                   :why (plist-get choice :why)
                                   :default (and (equal (plist-get choice :choice) default) t)))
                           choices))))

(defun harness-compaction--parse-answer (text choices)
  "Return what TEXT answers among CHOICES, as (:choice NAME :always BOOL), or nil.
CHOICES is what `harness-carry-menu' returns.  TEXT may name a choice
by its name, its label, its number among the options, its key, or the
words the cold-cache question's table gives it (`harness-cowboy--words'),
when the cowboy module is loaded.  An answer of `ignore' is `carry-on':
the menu offers no separate way to send everything and add nothing.
ALWAYS says TEXT said \"always\", which makes the choice a lasting one
where the question allows that."
  (let* ((raw (downcase (string-trim (or text ""))))
         (always (and (string-match-p "\\balways\\b" raw) t))
         (rest (string-trim (replace-regexp-in-string "\\balways\\b[:,]?" "" raw)))
         (rest (string-trim rest "[ \t\n\"'“”.:!-]+" "[ \t\n\"'“”.:!-]+"))
         ;; The words people type, not only the rows' labels: the same
         ;; the cold-cache question's table has, without its module loaded.
         (rest (pcase rest
                 ((or "carry on" "carry-on" "continue") "carry-on")
                 ((or "not now" "later" "hold") "hold")
                 ((or "start afresh" "fresh start") "fresh")
                 ((or "transcript file") "transcript")
                 (_ rest)))
         (number (and (string-match-p "\\`[0-9]+\\'" rest) (string-to-number rest)))
         (name (lambda (c) (format "%s" (plist-get c :choice))))
         (hit (cond
               ((and number (> number 0)) (nth (1- number) choices))
               ((cl-find-if (lambda (c)
                              (member rest (list (plist-get c :key) (funcall name c))))
                            choices))
               ((cl-find-if (lambda (c)
                              (and (not (string-empty-p rest))
                                   (string-prefix-p rest (downcase (plist-get c :label)))))
                            choices))
               ((and (fboundp 'harness-cowboy-parse-answer)
                     (car (harness-cowboy-parse-answer text)))
                (let* ((parsed (car (harness-cowboy-parse-answer text)))
                       (parsed (pcase parsed
                                 ('ignore 'carry-on)
                                 ('brief 'summary)
                                 (other other))))
                  (cl-find (symbol-name parsed) choices :key name :test #'equal))))))
    (when hit
      (list :choice (plist-get hit :choice) :always always))))

(defun harness-compaction--ask-again (session-id estimate where settle note)
  "Ask the compaction question of SESSION-ID again, NOTE saying why.
SETTLE and ESTIMATE are as `harness-compaction--ask' has them, and
WHERE is `turn' or `step'."
  (condition-case err
      (harness-compaction--ask
       session-id (harness-call 'session/get session-id) estimate where settle note)
    (error (harness-log 'warn "compaction: could not ask %s again: %s"
                        session-id (harness-error-short-message err))
           (funcall settle nil 'dismissed))))

(defun harness-compaction--ask (session-id session estimate where settle &optional note)
  "Ask what goes first before compacting SESSION-ID automatically.
WHERE is `turn' or `step'.  SETTLE is called once with CHOICE, BY and
nil: CHOICE a compaction kind, `carry-on', `hold' or nil when the
question was dismissed, and BY `user', `always' or `dismissed'.
ESTIMATE is `compaction/estimate''s answer or nil.  NOTE, when given,
opens the question because the answer named no choice.
The question is one page and one list, the same one the cold-cache
question asks (`harness-carry-menu'): Summary, Transcript, Fresh start,
Continuation and Pause.  A summary is shown, no cache, when its own
request would read the conversation uncached, and an answer that names
it asks again saying so.  The capitals answer \"always\": a kind's makes
it `harness-compaction-kind' and stops the asking
\(`harness-compaction--remember'), and carrying on's is \"always carry
on\", which saves `harness-compaction-carry-on' and stops it too."
  (let* ((choices (harness-carry-menu estimate))
         (default (plist-get (harness-compaction--default-choice choices) :choice))
         (answered nil)
         (pid nil))
    (setq pid
          (harness-call
           'question/ask session-id
           (list :question (harness-compaction--ask-text session estimate note)
                 :options (mapcar (lambda (c) (harness-compaction--option-text c default)) choices)
                 :allow-free-text t
                 :compaction (append (harness-compaction--ask-info session estimate where default choices)
                                     (list :always (harness-compaction--always-names choices))))
           (lambda (text dismissed)
             (setq answered t)
             (when (equal (plist-get (gethash session-id harness-compaction--asking) :pid) pid)
               (remhash session-id harness-compaction--asking))
             (let* ((parsed (and (not dismissed) (harness-compaction--parse-answer text choices)))
                    (choice (and parsed
                                 (cl-find (plist-get parsed :choice) choices
                                          :key (lambda (c) (plist-get c :choice))
                                          :test #'equal))))
               (cond
                ((or dismissed (not (harness-call 'session/exists-p session-id)))
                 (funcall settle nil 'dismissed))
                ((null parsed)
                 (harness-compaction--ask-again
                  session-id estimate where settle
                  (format "“%s” · no choice"
                          (harness-truncate-end (harness-first-line (or text "")) 60))))
                ((plist-get choice :unavailable)
                 (harness-compaction--ask-again
                  session-id estimate where settle
                  (harness-compaction--not-offered-text choice)))
                ;; "always" makes the kind the default and stops the
                ;; asking, kept as a decision by the answer's caller
                ;; (`harness-compaction--decide').
                (t (funcall settle (intern (plist-get parsed :choice))
                            (if (plist-get parsed :always) 'always 'user))))))))
    (unless answered
      (puthash session-id (list :pid pid :settle settle) harness-compaction--asking)
      (harness-emit 'compaction/asked session-id pid))
    pid))

(defconst harness-compaction--hold-reason
  "context full · message hold"
  "Why a held turn did not start, as the hint after it says.")

(defun harness-compaction--decide (session-id session where)
  "Return a promise of what goes first before an automatic compaction.
WHERE is `turn' or `step'.  The answer is (:choice KIND :by BY): KIND a
compaction kind, `carry-on', `hold', or nil when the question was
dismissed, and BY `user', `always', `dismissed' or `unasked'.  An
`always' answer to a kind is kept before the promise settles
\(`harness-compaction--remember'), and the answer names its decision as
`:decision', for the hint that follows; carrying on's is kept by the
gate that reads the answer (`harness-compaction--save-carry-on').  Where
nobody is asked, the answer is `harness-compaction-kind', unless that
asks a model and its own request is not known to be cached: then it is
the bounded kind `harness-compaction--effective-kind' returns instead,
since a cold summary is not made."
  (if (not (harness-compaction--asks-p session))
      (harness-resolved
       (list :choice (harness-compaction--effective-kind session-id harness-compaction-kind
                                                          (list :fallback "transcript"))
             :by (harness-compaction--by session)))
    (let* ((estimate (harness-compaction--estimate session-id))
           (promise (harness-make-promise))
           (settled nil)
           (settle (lambda (choice by &optional _)
                     (unless settled
                       (setq settled t)
                       ;; An "always" answer to a kind is kept before the
                       ;; promise settles; carrying on's is kept by the gate
                       ;; that reads the answer (`harness-compaction--save-carry-on').
                       ;; One that could not be kept is this compaction only,
                       ;; and says so as an answer.
                       (let* ((kind (and (memq choice harness-compaction-kinds) choice))
                              (kept (and kind (eq by 'always)
                                         (harness-compaction--remember choice session-id)))
                              (by (if (and kind (eq by 'always) (not kept)) 'user by)))
                         (harness-resolve promise
                                          (list :choice choice :by by
                                                :decision (plist-get kept :decision))))))))
      (condition-case err
          (harness-compaction--ask session-id session estimate where settle)
        (error
         (harness-log 'warn "compaction: could not ask %s: %s" session-id
                      (harness-error-short-message err))
         (funcall settle (harness-compaction--effective-kind session-id harness-compaction-kind
                                                          (list :fallback "transcript"))
                 'unasked)))
      promise)))

(defun harness-compaction--did-text (choice)
  "Return what automatic compaction as CHOICE did first, in words."
  (pcase choice
    ('brief "brief")
    ('summary "summary")
    ('transcript "transcript")
    ('fresh "fresh start")
    ('truncate "context cut")
    ('carry-on "continuation")
    (_ "compaction")))

(defun harness-compaction--say (session-id choice by session &optional decision)
  "Append the hint saying automatic compaction did CHOICE in SESSION-ID.
BY is who decided it: `user', `always', `dismissed' or `unasked'.
SESSION is the session's record, for the context that carrying on
sends.  DECISION, when given, is the lasting decision an \"always\"
answer kept, which the hint refers to so the chat offers its [Turn off]."
  (let* ((context (plist-get (plist-get session :usage) :context))
         (text
          (string-join
           (delq nil
                 (list "Context"
                       (if (eq choice 'carry-on)
                           (concat "continuation"
                                   (and (numberp context) (> context 0)
                                        (format " · ~%s tokens uncached"
                                                (harness-format-tokens context))))
                         (harness-compaction--did-text choice))
                       (pcase by
                         ('user "answer")
                         ('always "default")
                         ('unasked
                          ;; The configured kind only when it is the one made.
                          (if (eq choice harness-compaction-kind) "automatic" "fallback"))
                         (_ nil))))
           " · ")))
    (when (harness-call 'session/exists-p session-id)
      (if (not (and (stringp decision) (harness-method-exists-p 'session/append)))
          (harness-call 'session/hint session-id text)
        (let ((node (harness-call 'session/append session-id
                                  (list :kind 'hint :content text :meta (list :decision decision)))))
          (when (harness-method-exists-p 'decision/attach)
            (condition-case err
                (harness-call 'decision/attach decision session-id (plist-get node :id))
              (error (harness-log 'warn "compaction: could not name the note of %s: %s"
                                  decision (harness-error-short-message err)))))
          node)))))

(defun harness-compaction--ask-meta (choice by)
  "Return the compaction node's `:meta' for CHOICE made by BY.
It says the compaction was the automatic one and who chose it, so a
client, or the user reading the tree later, can tell it from a
compaction asked for by hand."
  (list :auto (list :choice (symbol-name choice) :by (symbol-name by))))

(defun harness-compaction--on-question-turn-ended (session-id &optional _reason)
  "Let SESSION-ID's compaction question go: its turn ended or was cancelled.
The question is dismissed, and the gate that waits for it settles as a
dismissed answer does, so the turn is not left waiting."
  (when-let* ((asking (gethash session-id harness-compaction--asking)))
    (remhash session-id harness-compaction--asking)
    (if (and (harness-method-exists-p 'question/cancel)
             (harness-call 'session/exists-p session-id))
        (harness-call 'question/cancel session-id (plist-get asking :pid))
      (funcall (plist-get asking :settle) nil 'dismissed))))

(defun harness-compaction--on-question-deleted (session-id &rest _)
  "Let the compaction question of SESSION-ID go: the session is gone."
  (when-let* ((asking (gethash session-id harness-compaction--asking)))
    (remhash session-id harness-compaction--asking)
    (funcall (plist-get asking :settle) nil 'dismissed)))

(defun harness-compaction--compact-with-bounds (session-id kind meta on-ok on-fail)
  "Compact SESSION-ID as KIND, then call ON-OK or ON-FAIL.
ON-OK is called with the node made.  A model kind whose own request is
not known to be cached is made as a transcript, whoever chose it.  When
even that and a cut cannot be made -- the conversation stays as it is,
too large to send -- ON-FAIL is called with no argument, and the caller
holds the turn rather than send it uncached.  META is the node's
`:meta'."
  (let ((opts (list :kind kind
                    :fallback "transcript"
                    :meta meta)))
    (harness-then
     (harness-call 'compaction/compact session-id opts)
     on-ok
     (lambda (_err)
       (harness-then (harness-compaction--bounded-compaction session-id meta)
                     (lambda (node)
                       (if node (funcall on-ok node) (funcall on-fail)))
                     (lambda (_err) (funcall on-fail)))))))

(defun harness-compaction--asked-before-turn (session-id session value next)
  "Ask about the automatic compaction of SESSION-ID before its turn, then go on.
SESSION is its record, VALUE and NEXT those of the `agent/before-turn'
filter.  The turn waits for the question; a dismissed one, or `hold',
holds the message; `carry-on' sends it as it is; a kind compacts, and
none may ask a model to read the conversation unless its own request is
known to be cached, whoever answered for it.  When nothing can be
compacted, the message is held rather than sent uncached."
  (harness-compaction-show-waiting session-id)
  (let ((hold (lambda (&rest _)
                (funcall next (list :proceed nil :reason harness-compaction--uncacheable-reason)))))
    (harness-then
     (harness-compaction--decide session-id session 'turn)
     (lambda (answer)
       (let ((choice (plist-get answer :choice))
             (by (plist-get answer :by))
             (decision (plist-get answer :decision)))
         (harness-compaction--note-answer session-id choice)
         (when (and (eq choice 'carry-on) (eq by 'always))
           (harness-compaction--save-carry-on session-id))
         (cond
          ((memq choice '(hold nil))
           (funcall next (list :proceed nil :reason harness-compaction--hold-reason)))
          ((eq choice 'carry-on)
           (harness-compaction--say session-id choice by session decision)
           (funcall next value))
          (t
           ;; Say what will really go first: a cold summary is a
           ;; transcript, and the hint after says what was not made.
           (harness-compaction--say
            session-id
            (if (memq choice harness-compaction--model-kinds)
                (harness-compaction--effective-kind
                 session-id choice (list :fallback "transcript"))
              choice)
            by session decision)
           (when (memq by '(unasked always))
             (harness-compaction--say-not-warm session-id harness-compaction-kind choice))
           (harness-compaction--compact-with-bounds
            session-id choice (harness-compaction--ask-meta choice by)
            (lambda (_node) (funcall next value))
            hold)))))
     hold)))

(defun harness-compaction--asked-before-step (session-id session carry-on next)
  "Ask about the automatic compaction of SESSION-ID mid-turn, then go on.
SESSION is its record, CARRY-ON a function that lets the step go on
with the conversation as it is, and NEXT the `agent/step' filter's, for
a step that cannot be taken.  `carry-on', the user's own answer, sends
the conversation as it is; a kind compacts and then carries on, and a
model kind among them is made only if its own request is known to be
cached -- a choice is not warmth.  A dismissed question, `hold', and a
question or compaction that failed refuse the step
\(`harness-compaction--held-step-reason',
`harness-compaction--uncacheable-reason') rather than send the whole
conversation uncached."
  (let ((hold (lambda (&rest _)
                (funcall next (list :proceed nil :reason harness-compaction--held-step-reason))))
        (fail (lambda (&rest _)
                (funcall next (list :proceed nil :reason harness-compaction--uncacheable-reason)))))
    (harness-then
     (harness-compaction--decide session-id session 'step)
     (lambda (answer)
       (let ((choice (plist-get answer :choice))
             (by (plist-get answer :by))
             (decision (plist-get answer :decision)))
         (harness-compaction--note-answer session-id choice)
         (when (and (eq choice 'carry-on) (eq by 'always))
           (harness-compaction--save-carry-on session-id))
         (cond
          ((eq choice 'carry-on)
           (harness-compaction--say session-id 'carry-on by session decision)
           (funcall carry-on))
          ((memq choice '(nil hold))
           (funcall hold))
          (t
           ;; Say what will really go first: a cold summary is a
           ;; transcript, and the hint after says what was not made.
           (harness-compaction--say
            session-id
            (if (memq choice harness-compaction--model-kinds)
                (harness-compaction--effective-kind
                 session-id choice (list :fallback "transcript"))
              choice)
            by session decision)
           (when (memq by '(unasked always))
             (harness-compaction--say-not-warm session-id harness-compaction-kind choice))
           (harness-compaction--note-activity session-id 'compacting)
           (harness-compaction--compact-with-bounds
            session-id choice
            (append (harness-compaction--ask-meta choice by) (list :mid-turn t))
            (lambda (_node)
              (harness-compaction--note-activity session-id nil)
              (funcall carry-on))
            (lambda (&rest _)
              (harness-compaction--note-activity session-id nil)
              (funcall fail)))))))
     fail)))

;;;; "Always": compacting without asking, and turning that off

;; An "always" answer to the question changes the two settings that
;; decide what an automatic compaction does where nobody is asked: the
;; kind it makes (`harness-compaction-kind') and whether it asks
;; (`harness-compaction-ask').  Like the cold-cache answer, it is a
;; lasting decision the harness keeps (harness-decisions.el), of the
;; kind `compaction', with the settings before it and after it; the
;; hint written right after it names it, so the chat offers its [Turn
;; off], and then its [Turn on].  Undo puts both settings back as they
;; were before it while they still hold what the answer set; redo sets
;; them again while they still hold what the undo put back.  Settings
;; changed by hand in between are left as they are, and the decision
;; ends there.

(defun harness-compaction--settings ()
  "Return the compaction settings as a decision records them.
That is (:ask BOOL :kind NAME), BOOL t or `:false' and NAME a string,
so that they travel as JSON."
  (list :ask (if harness-compaction-ask t :false)
        :kind (symbol-name harness-compaction-kind)))

(defun harness-compaction--kind-from (kind)
  "Return KIND, a name or a symbol from a decision, as a compaction kind."
  (harness-compaction--kind (or kind harness-compaction-kind)))

(defun harness-compaction--settings-equal (a b)
  "Non-nil when compaction settings A and B say the same.
Each is as `harness-compaction--settings' returns it, perhaps back from
JSON."
  (and (eq (and (harness-json-true-p (plist-get a :ask)) t)
           (and (harness-json-true-p (plist-get b :ask)) t))
       (eq (ignore-errors (harness-compaction--kind-from (plist-get a :kind)))
           (ignore-errors (harness-compaction--kind-from (plist-get b :kind))))))

(defun harness-compaction--set-settings (settings)
  "Make the compaction settings hold SETTINGS, saved as Settings saves them.
SETTINGS is as `harness-compaction--settings' returns it.  Signal when
one cannot be saved, as when the policy sets it."
  (let ((ask (and (harness-json-true-p (plist-get settings :ask)) t))
        (kind (harness-compaction--kind-from (plist-get settings :kind))))
    (if (harness-method-exists-p 'config/set)
        (progn (harness-call 'config/set 'harness-compaction-kind kind :scope 'global)
               (harness-call 'config/set 'harness-compaction-ask ask :scope 'global))
      (harness-save-user-option 'harness-compaction-kind kind)
      (harness-save-user-option 'harness-compaction-ask ask))))

(defun harness-compaction--settings-text (settings)
  "Return SETTINGS in words, for a decision's undo or redo message."
  (if (harness-json-true-p (plist-get settings :ask))
      "an automatic compaction asks what goes first again"
    (format "automatic compaction is made without asking, into %s"
            (harness-compaction--kind-name (harness-compaction--kind-from (plist-get settings :kind))))))

(defun harness-compaction--record-decision (session-id choice before)
  "Keep the \"always\" answer of CHOICE in SESSION-ID as a lasting decision.
BEFORE is what the settings held before it.  Return the decision's id,
or nil without the decisions module or when keeping it failed (logged)."
  (when (harness-method-exists-p 'decision/record)
    (condition-case err
        (plist-get (harness-call 'decision/record 'compaction session-id
                                 (format "Compacting automatically, without asking, into %s"
                                         (harness-compaction--kind-name choice))
                                 (list :choice (symbol-name choice) :before before
                                       :after (harness-compaction--settings)))
                   :id)
      (error (harness-log 'warn "compaction: could not keep the answer in %s as a decision: %s"
                          session-id (harness-error-short-message err))
             nil))))

(defun harness-compaction--remember (choice session-id)
  "Make CHOICE the kind and stop asking, as an \"always\" answer says.
Both settings are saved as the settings page saves them (`config/set'),
and the answer, given in SESSION-ID, is kept as a lasting decision with
the settings before it, which can be undone and redone from any session
\(`harness-compaction--record-decision').  Return (:decision ID) once
they are saved, ID nil when no decision was kept; nil when CHOICE is no
compaction kind, or when the settings could not be saved (logged)."
  (when (memq choice harness-compaction-kinds)
    (let ((before (harness-compaction--settings)))
      (condition-case err
          (progn
            (harness-compaction--set-settings (list :ask :false :kind (symbol-name choice)))
            (list :decision (harness-compaction--record-decision session-id choice before)))
        (error (harness-log 'warn "compaction: could not make %s the kind: %s"
                            choice (harness-error-short-message err))
               nil)))))

(defun harness-compaction--decision-undo (decision)
  "Undo the \"always\" answer DECISION keeps: the `:undo' of the kind `compaction'.
While the settings hold what the answer set, they go back to what they
held before it.  Return (OUTCOME . MESSAGE), as
`harness-decisions-define-kind' says."
  (let* ((record (plist-get decision :record))
         (now (harness-compaction--settings)))
    (cond ((harness-compaction--settings-equal now (plist-get record :after))
           (harness-compaction--set-settings (plist-get record :before))
           (cons 'undone (format "Undone: %s"
                                 (harness-compaction--settings-text (plist-get record :before)))))
          ((harness-compaction--settings-equal now (plist-get record :before))
           (cons 'changed "Not undone: the compaction settings were put back since, so they stay as they are"))
          (t (cons 'changed "Not undone: the compaction settings changed since (in Settings, say), so they stay as they are")))))

(defun harness-compaction--decision-redo (decision)
  "Redo the \"always\" answer DECISION keeps: the `:redo' of the kind `compaction'.
While the settings hold what its undo put back, they hold what the
answer set again.  Return (OUTCOME . MESSAGE), as
`harness-decisions-define-kind' says."
  (let* ((record (plist-get decision :record))
         (now (harness-compaction--settings)))
    (cond ((harness-compaction--settings-equal now (plist-get record :before))
           (harness-compaction--set-settings (plist-get record :after))
           (cons 'done (format "Redone: %s"
                               (harness-compaction--settings-text (plist-get record :after)))))
          ((harness-compaction--settings-equal now (plist-get record :after))
           (cons 'changed "Not redone: automatic compaction is made without asking again already, so it stays so"))
          (t (cons 'changed "Not redone: the compaction settings changed since (in Settings, say), so they stay as they are")))))

(declare-function harness-decisions-define-kind "harness-decisions" (kind &rest spec))

(with-eval-after-load 'harness-decisions
  (harness-decisions-define-kind 'compaction
                                 :undo #'harness-compaction--decision-undo
                                 :redo #'harness-compaction--decision-redo))

;;;; The session's own answer, and the default for every session

(defun harness-compaction--ask-value-name (ask)
  "Return ASK as a session keeps it: t, `:false' or nil for no answer."
  (cond ((null ask) nil)
        ((harness-json-true-p ask) t)
        (t :false)))

(defun harness-compaction--ask-value-hint (value)
  "Return what setting a session's answer to VALUE changed, in words."
  (cond ((eq value t) "Automatic compaction: asking what goes first again")
        ((eq value :false) "Automatic compaction: always, without asking")
        (t "Automatic compaction: as the default says")))

(harness-defmethod compaction/set-ask (session-id ask)
  "Set whether SESSION-ID is asked before an automatic compaction.
ASK true asks, `:false' compacts unasked as `harness-compaction-kind'
says, and nil removes the session's own answer, so that it follows
`harness-compaction-ask'.  The answer is kept in the session's `:ext'
\(`harness-compaction--ask-ext-key'), where it survives a restart and
wins over the default; the transcript says what changed, and
`session/ext-changed' announces it.  Only the user does this, from the
chat or the session list (`harness-toggle-compaction-ask'), over ACP as
`_harness/compaction/set-ask' with `:sessionId' and `:ask'; the agent
has no tool for it.  Return the session's plist."
  (let ((value (harness-compaction--ask-value-name ask)))
    (harness-call 'session/set-ext session-id harness-compaction--ask-ext-key value
                  (harness-compaction--ask-value-hint value))
    (harness-call 'session/get session-id)))

(harness-defmethod compaction/set-ask-all (ask &optional filter)
  "Set whether every session FILTER selects is asked before a compaction.
ASK is as for `compaction/set-ask': nil removes the sessions' own
answers, so that they follow the default.  FILTER is the one of
`session/select', nil for every session; the sessions of completed
tasks are left out, as `session/select' leaves them out when it is
asked for the current ones.  Each change goes the way
`compaction/set-ask' does -- the same `:ext' setting, transcript hint
and `session/ext-changed' event -- and a session already at the value
asked for is left alone.  Only the user does this, over ACP as
`_harness/compaction/set-ask-all' with `:ask' and `:filter', through
`harness-set-compaction-ask-all' and the session list.  Return the ids
changed, newest first."
  (let ((value (harness-compaction--ask-value-name ask))
        changed)
    (dolist (session (harness-call 'session/select (or filter '(:active t :tasks t))))
      (let* ((id (plist-get session :id))
             (now (harness-compaction--session-ask session)))
        (unless (eq (or now 'none) (or value 'none))
          (harness-call 'session/set-ext id harness-compaction--ask-ext-key value
                        (harness-compaction--ask-value-hint value))
          (push id changed))))
    (nreverse changed)))

;;;; Automatic compaction

(defun harness-compaction--before-turn (value next session)
  "Compact SESSION before its turn when the context is nearly full.
VALUE and NEXT are the `agent/before-turn' filter arguments.  SESSION
is read again first: a handler earlier in the chain (the fallback) may
have moved it to another model, whose window and compaction decide.
The compaction is of `harness-compaction-kind'.  Where the user can be
asked (`harness-compaction-ask'), it asks first, with what each kind
costs and what carrying on costs, and does as they answer
\(`harness-compaction--asked-before-turn').  A conversation the user
just gave back whole (`compaction/revert') is let through once, or the
compaction would be made again before the model saw it
\(`harness-compaction--revert-hold').  One whose user answered to carry
on is let through, unasked, past the window too: the answer stands
\(`harness-compaction--carried-on'), and \"always carry on\" stands for
every session (`harness-compaction-carry-on')."
  (let* ((id (plist-get session :id))
         (session (or (ignore-errors (harness-call 'session/get id)) session))
         (held (and (plist-get value :proceed)
                    (gethash id harness-compaction--revert-hold)))
         (needed (harness-compaction-needed-p session)))
    (when held
      (remhash id harness-compaction--revert-hold)
      (harness-log 'info "compaction: %s goes on with the conversation its user reverted" id))
    (cond
     ((or (not (plist-get value :proceed)) held)
      (funcall next value))
     ;; Under the limit again: the conversation changed since -- compacted,
     ;; cut, or given back -- so a question asked from now on is a new one.
     ((not needed)
      (remhash id harness-compaction--carried-on)
      (funcall next value))
     ((harness-compaction-hosted-p session)
      (funcall next value))
     ;; Carrying on is the lasting answer: no question, no compaction.
     ((harness-compaction--carry-on-always-p session)
      (funcall next value))
     ;; The user answered carry on: the message goes, and the question is
     ;; not put again (`harness-compaction--carried-on').
     ((and (harness-compaction--asks-p session)
           (harness-compaction--carried-on-p id))
      (funcall next value))
     ((harness-compaction--asks-p session)
      ;; The turn's message waits for the question and then the
      ;; compaction, which both take a while.
      (harness-compaction--asked-before-turn id session value next))
     (t
      (let ((kind (harness-compaction--effective-kind id harness-compaction-kind
                                                      (list :fallback "transcript")))
            (by (harness-compaction--by session)))
        (harness-compaction-show-waiting id)
        (harness-compaction--say-not-warm id harness-compaction-kind kind)
        (harness-compaction--say id kind by session)
        (harness-compaction--compact-with-bounds
         id kind (harness-compaction--ask-meta kind by)
         (lambda (_node) (funcall next value))
         (lambda (&rest _)
           (funcall next (list :proceed nil :reason harness-compaction--uncacheable-reason))))))))
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
step (`harness-compaction--mid-turn-due-p').  Where the user can be
asked (`harness-compaction--asks-p') the question comes first
(`harness-compaction--asked-before-step'), and a boundary it asked at
counts as a try, so one compacted at is not asked again at once.  One
answered to carry on is not asked about again, past the window too
\(`harness-compaction--carried-on'); without that answer, a context past
the window asks at once, not after the cooldown.
The step goes on once a compaction, or a transcript or a cut in its
place, was made, and is refused when none could be made, or when the
user dismissed the question: the whole conversation is never sent
uncached for want of an answer.  SESSION is read
again first: a handler earlier in the chain may have changed its model."
  (let* ((id (plist-get session :id))
         (session (or (ignore-errors (harness-call 'session/get id)) session))
         (needed (harness-compaction-needed-p session)))
    (cond
     ((or (not (plist-get value :proceed)) (not harness-compaction-mid-turn))
      (funcall next value))
     ((not needed)
      (remhash id harness-compaction--mid-turn)
      (remhash id harness-compaction--carried-on)
      (funcall next value))
     ((harness-compaction-hosted-p session)
      (funcall next value))
     ((harness-compaction--carry-on-always-p session)
      (funcall next value))
     (t
      (let* ((carry-on (lambda (&rest _)
                         (harness-compaction--note-activity id nil)
                         (funcall next value)))
             (asks (harness-compaction--asks-p session))
             ;; Past the window the conversation cannot be sent at all:
             ;; where the user is asked, the question comes at once, and
             ;; not after the cooldown a try that did not help waits for.
             (over (and asks
                        (> (or (plist-get (plist-get session :usage) :context) 0)
                           (harness-compaction--window session)))))
        (cond
         ;; The user answered carry on, and the conversation can still be
         ;; sent: the step goes on, and the question is not put again
         ;; (`harness-compaction--carried-on').
         ((and asks (harness-compaction--carried-on-p id))
          (funcall next value))
         ((and (not over) (not (harness-compaction--mid-turn-due-p id)))
          (funcall next value))
         (asks
          ;; The step waits for the question; its answer decides.
          (harness-compaction--asked-before-step id session carry-on next))
         (t
          (let* ((kind (harness-compaction--effective-kind id harness-compaction-kind
                                                           (list :fallback "transcript")))
                 (by (harness-compaction--by session))
                 (meta (append (harness-compaction--ask-meta kind by)
                               (list :mid-turn t))))
            (harness-compaction--note-activity id 'compacting)
            (harness-compaction--say-not-warm id harness-compaction-kind kind)
            (harness-compaction--say id kind by session)
            (harness-compaction--compact-with-bounds
             id kind meta
             (lambda (_node)
               (harness-compaction--note-activity id nil)
               (funcall carry-on))
             (lambda (&rest _)
               (harness-compaction--note-activity id nil)
               (funcall next (list :proceed nil
                                   :reason harness-compaction--uncacheable-reason)))))))))))
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
  (harness-on 'agent/turn-ended #'harness-compaction--on-question-turn-ended)
  (harness-on 'agent/cancelling #'harness-compaction--on-question-turn-ended)
  (harness-on 'session/deleted #'harness-compaction--on-deleted)
  (harness-on 'session/deleted #'harness-compaction--on-question-deleted))

(harness-compaction--init)

(harness-declare-event 'compaction/asked "(SESSION-ID PENDING-ID) after asking, before an automatic compaction, what goes first and what it costs.")
(harness-declare-event 'compaction/done "(SESSION-ID NODE) after a compaction node is appended.")
(harness-declare-event 'compaction/failed "(SESSION-ID MESSAGE) when a compaction fails.")

(harness-define-module 'compaction
  :doc "Summarise the transcript when it nears the context window, before a turn or in the middle of one, asking the user first with what each kind costs; queue or interrupt one while a turn runs."
  :requires '(session provider agent)
  :init #'harness-compaction--init)

(provide 'harness-compaction)
;;; harness-compaction.el ends here
