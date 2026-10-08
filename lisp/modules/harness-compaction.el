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
;;   default the cheap tier of the session's provider) summarises only
;;   the first and last messages, as a handoff's new model does
;;   (`compact-new'): cheap and bounded however long the conversation,
;;   but most of its middle is not in it, which the summary's caveat says.
;; - `transcript': the whole transcript goes to a file in the session's
;;   directory (`session/write-transcript', the handoff's), and the node
;;   is a note telling the model where it is and to read what it needs
;;   of it.  No request at all.
;;
;; Automatic compaction makes `harness-compaction-kind'; by hand (the
;; UI's `harness-compact', or the panel of a session whose prompt cache
;; expired) any kind, with what each costs (`compaction/estimate').
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
;; Automatic compaction hangs on the `agent/before-turn' filter: when
;; the last request's context exceeds window minus reserve, the turn
;; waits for the compaction and then proceeds.  Providers that report
;; `:compaction hosted' compact on their own side and are left alone.
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

(defvar harness-provider-fallback-context-window)

(defconst harness-compaction-kinds '(summary brief transcript)
  "The kinds of compaction: what stands in for the conversation from then on.
`summary' is a summary the session's model writes from the whole
conversation; `brief' one `harness-compaction-brief-model' writes from
only its first and last messages, cheap and bounded however long the
conversation, but without most of its middle; `transcript' is the whole
conversation written to a file in the session's directory, with a note
telling the model to read what it needs of it, which takes no request.
They are the handoff's `compact', `compact-new' and `transcript' (see
harness-handoff.el), on the session's own provider.")

(defcustom harness-compaction-kind 'summary
  "How a conversation that nears its model's context window is compacted.
`summary' (the default) has the session's model summarise the whole
conversation, which reads all of it again; `brief' has a cheap model
\(`harness-compaction-brief-model') summarise only its first and last
messages, which costs little however long the conversation, but leaves
most of its middle out; `transcript' writes the whole conversation to a
file in the session's directory and leaves the model a note to read
what it needs of it, which costs no request at all.  Automatic
compaction makes this kind; compacting by hand (`harness-compact', or
the panel above the message box of a session whose prompt cache
expired) offers every kind, with what each costs."
  :type '(choice (const :tag "Summary: the session's model summarises the whole conversation" summary)
                 (const :tag "Brief summary: a cheap model summarises the first and last messages" brief)
                 (const :tag "Transcript: a file the model reads what it needs of" transcript))
  :safe (lambda (v) (memq v '(summary brief transcript)))
  :group 'harness)

(defcustom harness-compaction-brief-model 'auto
  "Model that writes a brief summary, as PROVIDER:NAME, or `auto'.
A brief summary is made from only the first and last messages of a
conversation, a job a cheap model does about as well as any.  `auto'
\(the default) asks the session's provider for its `cheap' tier (see
`harness-provider-tier-model'), falling back to the session's own model
when the provider names none.  A PROVIDER:NAME forces that model, and
nil uses the session's own model."
  :type '(choice (const :tag "The session provider's cheap model" auto)
                 (const :tag "The session's own model" nil)
                 (string :tag "Model" :names model))
  :safe (lambda (v) (or (memq v '(auto nil)) (stringp v)))
  :group 'harness)

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

(defconst harness-compaction--summary-output 2000
  "Tokens a summary is taken to come to when its cost is estimated.
A thorough one runs to one or two thousand, short of
`harness-compaction--max-tokens', which bounds it.")

(defvar harness-compaction--running (make-hash-table :test 'equal)
  "Session id -> promise of the compaction in flight.")

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
              (list (format "Unknown compaction kind %s (use summary, brief or transcript)" kind))))
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
                    (ignore-errors (harness-call 'provider/tier-model model 'cheap)))
               model))
          ((and (stringp choice) (not (string-empty-p choice))) choice)
          (t model))))

(defun harness-compaction--brief-caveat (model)
  "Return the note that ends a brief summary MODEL wrote.
The summary had only the first and last messages to go by, so the
model that goes on from it is told what it lacks, and to look again
rather than trust it, as after a handoff (harness-handoff.el)."
  (format (concat "Harness note: %s wrote this summary from only the first and the most recent messages"
                  " of the conversation, so most of its middle is not in it.  Treat it as possibly incomplete:"
                  " re-investigate anything you are unsure of -- read the files, check the state -- before you"
                  " act on it.")
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

(defun harness-compaction--estimate-summary (session-id session context warm)
  "Estimate a `summary' of SESSION-ID, whose record is SESSION, of CONTEXT tokens.
WARM says the session's prompt cache lasts: a summary on a fork of the
session's own conversation reads it back from there; any other is sent
a prompt of its own, which nothing cached starts, so it pays for all of
it uncached."
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
          :after output)))

(defun harness-compaction--estimate-brief (session messages)
  "Estimate a `brief' summary of SESSION, whose provider messages are MESSAGES.
Its model is sent the system prompt and a sample of MESSAGES, all of it
uncached."
  (let* ((model (harness-compaction--brief-model session))
         (input (+ (harness-estimate-tokens harness-compaction--system-prompt)
                   (harness-compaction--messages-tokens
                    (car (harness-compaction--sample-messages messages)))
                   (harness-estimate-tokens harness-compaction--request-text)))
         (output harness-compaction--summary-output))
    (list :kind 'brief :model model :model-label (harness-compaction--model-label model)
          :input input :output output :cached nil
          :cost (harness-compaction--cost
                 model (list (harness-compaction--uncached-key model) input :output output))
          :after output)))

(defun harness-compaction--estimate-transcript (context)
  "Estimate a `transcript' of a conversation of CONTEXT tokens.
No model is asked anything; the note left in its place is about as
long as an example of it."
  (list :kind 'transcript :model nil :model-label nil :input 0 :output 0 :cached nil :cost 0.0
        :after (harness-estimate-tokens (harness-compaction--transcript-note "/a/file.md" 1000))
        :file-tokens context))

(harness-defmethod compaction/estimate (session-id)
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
and the context that stands for the conversation after it.  Costs are
at list prices, nil where the catalogue has none, and `transcript',
which asks no model, costs 0; its `:file-tokens' is about how much
the file holds."
  (let* ((session (harness-call 'session/get session-id))
         (model (plist-get session :model))
         (messages (harness-call 'session/messages session-id))
         (context (let ((c (plist-get (plist-get session :usage) :context)))
                    (if (and (numberp c) (> c 0)) c (harness-compaction--messages-tokens messages))))
         (warm (harness-compaction--warm-p session)))
    (list :context context :model model :model-label (harness-compaction--model-label model)
          :cached (and warm t)
          :carry-on (harness-compaction--resend model context warm)
          :carry-on-cached (harness-compaction--resend model context t)
          :compacting (and (gethash session-id harness-compaction--running) t)
          :kind harness-compaction-kind
          :kinds (list (harness-compaction--estimate-summary session-id session context warm)
                       (harness-compaction--estimate-brief session messages)
                       (harness-compaction--estimate-transcript context)))))

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
META is the compaction node's, whose `:file' names a transcript."
  (format "Compacted: %s tokens → %s"
          (harness-format-tokens input-tokens)
          (pcase kind
            ('brief "brief summary")
            ('transcript (format "transcript in %s"
                                 (abbreviate-file-name (or (plist-get meta :file) "a file"))))
            (_ "summary"))))

(defun harness-compaction--finish (session-id content old-head model usage input-tokens trailing context
                                               &optional kind meta)
  "Record CONTENT for SESSION-ID and return the compaction node.
CONTENT is the summary, its caveat included, or for KIND `transcript'
the note pointing at the file.  OLD-HEAD is the head that was
compacted, MODEL the summariser (the session's model for a transcript,
which none wrote), USAGE its usage event (nil when no request was
made), INPUT-TOKENS the size of what was compacted, TRAILING the
unanswered user nodes to carry over, CONTEXT what the summariser was
given (see `compaction/compact'), KIND one of `harness-compaction-kinds'
\(`summary' by default) and META more for the node's `:meta': a
transcript's `:file', a handoff's `:handoff'.  The conversation starts
over from the node (`harness-compaction--start-over')."
  (let* ((kind (or kind 'summary))
         (node (harness-call 'session/append session-id
                             (list :kind 'compaction :content content
                                   :meta (append (list :compacted-head old-head :model model
                                                       :compaction (symbol-name kind)
                                                       :context context
                                                       :input-tokens input-tokens
                                                       :summary-tokens (harness-estimate-tokens content))
                                                 meta)))))
    (harness-call 'session/hint session-id (harness-compaction--done-hint kind input-tokens meta))
    (dolist (u trailing)
      (harness-call 'session/append session-id
                    (list :kind 'user :content (plist-get u :content) :blocks (plist-get u :blocks)
                          :meta (plist-put (copy-sequence (plist-get u :meta)) :carried-from (plist-get u :id)))))
    (harness-compaction--start-over session-id)
    ;; The conversation starts over from the compaction: whatever the
    ;; summariser's request cached, the next request reads none of it.
    (harness-call 'session/usage-add session-id
                  (list :input (plist-get usage :input) :output (plist-get usage :output)
                        :cache-read (plist-get usage :cache-read)
                        :cache-write (plist-get usage :cache-write)
                        :cost (plist-get usage :cost)
                        :context (harness-estimate-tokens content)
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
                                    (harness-error-message e))
                       nil))
    (harness-resolved nil)))

(defun harness-compaction--request (session-id session model state promise context
                                                &optional kind caveat meta)
  "Ask MODEL for the summary of SESSION-ID, whose record is SESSION.
STATE is the provider state to send it with, CONTEXT what it is given
\(`full' or `sample'), and PROMISE settles with the compaction node.
KIND is the kind of summary (`summary' or `brief'), CAVEAT a note to
end it with, or nil, and META more for the node's `:meta' (see
`harness-compaction--finish')."
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
                          session-id (if caveat (concat summary "\n\n" caveat) summary) old-head model usage
                          (or (plist-get usage :context)
                              (and (plist-get usage :input)
                                   (+ (plist-get usage :input) (or (plist-get usage :cache-read) 0)))
                              estimate)
                          trailing context kind meta))
                      (error (harness-compaction--fail session-id promise err))))))
               (_ nil)))))))

(harness-defmethod compaction/compact (session-id &optional opts)
  "Compact the transcript of SESSION-ID; return a promise of the compaction node.
OPTS `:kind' is one of `harness-compaction-kinds': `summary' (the
default), `brief' or `transcript'.

A `summary' is written by the session's model, or OPTS `:model'.  OPTS
`:context' is `full' (the default), which lets the summariser see the
whole conversation (on a fork of the session's provider state when its
provider can), or `sample', which sends it only the first and last few
messages with a note of what was left out, never the whole
conversation: a bound on what a summariser that has to be sent the
conversation as text costs.  A summary of a sample is a `brief' one,
and a `brief' one is always of a sample, written by OPTS `:model' or
else `harness-compaction-brief-model' (the cheap tier of the session's
provider by default), and ends in a note saying what it lacks.  OPTS
`:caveat' replaces that note, nil for none; a handoff ends its summary
with its own.  A summariser that keeps the conversation itself (a hosted
loop) works on a fork of the session's provider state when it can; one
with no state of this session gets the context as one message of text,
since that is all such a provider is ever sent.

A `transcript' is written to a file in the session's directory
\(`session/write-transcript'), and the node holds a note telling the
model to read what it needs of it; no model is asked anything.

The node replaces the transcript for the provider (`session/messages'
restarts at it, as a user message); unanswered user messages at the end
of the transcript are carried over after it, and the conversation the
session's provider kept, if any, goes (`harness-compaction--start-over').
OPTS `:meta' is more for the node's `:meta'.  A second call while one
is running returns the running promise.  OPTS `:idle' refuses a session
running a turn, as compacting by hand does: the turn would go on
writing after the conversation it replaces."
  (or (gethash session-id harness-compaction--running)
      (let* ((session (harness-call 'session/get session-id))
             (_ (when (and (plist-get opts :idle)
                           (harness-method-exists-p 'agent/running)
                           (harness-call 'agent/running session-id))
                  (signal 'harness-error
                          (list "The session is running a turn: compact it once the turn is over"))))
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
        (if (eq kind 'transcript)
            (condition-case err
                (harness-resolve promise (harness-compaction--transcript session-id session meta))
              (error (harness-compaction--fail session-id promise err)))
          (harness-call 'session/hint session-id
                        (if (eq kind 'brief)
                            (format "Compacting context: a brief summary by %s…"
                                    (harness-compaction--model-label model))
                          "Compacting context…"))
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
have moved it to another model, whose window and compaction decide.
The compaction is of `harness-compaction-kind'."
  (let ((session (or (ignore-errors (harness-call 'session/get (plist-get session :id))) session)))
    (if (or (not (plist-get value :proceed))
            (not (harness-compaction-needed-p session))
            (harness-compaction-hosted-p session))
        (funcall next value)
      (harness-then (harness-call 'compaction/compact (plist-get session :id)
                                  (list :kind harness-compaction-kind))
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
