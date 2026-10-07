;;; harness-provider-claude.el --- Claude Code CLI as a completion provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives the official `claude' command line (Claude Code) as a hosted
;; completion provider, so subscription users can use Claude models
;; from the harness.  Per harness session one long-lived CLI process is
;; kept alive across turns: the CLI keeps the conversation and the KV
;; cache, the harness only sends new user content and serves tool calls.
;;
;; Wire protocol (newline delimited JSON on stdin/stdout):
;;
;; - We spawn `claude -p --input-format stream-json --output-format
;;   stream-json ...' with every built-in tool disabled and one SDK MCP
;;   server called "harness".  The CLI asks us to serve that server over
;;   `control_request' messages of subtype `mcp_message'; we answer the
;;   JSON-RPC calls (initialize, tools/list, tools/call) inline.  A
;;   tools/call becomes a `tool-call' provider event whose `:respond'
;;   writes the result back, which is how the hosted loop continues.
;;   tools/list answers with the tools of the last request, kept after
;;   its turn: the CLI may list them between turns, and keeps the list
;;   it got for as long as the process lives.
;; - The harness's permission system decides every tool call, so the
;;   CLI only has to let the harness's tools through, never bypass its
;;   checks: `harness-provider-claude-permission-args' fixes its
;;   permission mode and allows `mcp__harness__*' by rule.  When a
;;   permission prompt tool sends the CLI's prompts here instead
;;   (`can_use_tool' control requests), the harness's tools are allowed
;;   and any other refused.  A call the CLI refuses on its own
;;   (`system/permission_denied') becomes a hint.
;; - One built-in tool can stand in for a harness tool: WebSearch for
;;   web_search (`harness-provider-claude-builtin-tools').  A request
;;   whose `:builtin-tools' names it gets `--tools WebSearch', and
;;   `--permission-prompt-tool stdio' unless the permission arguments
;;   already send the prompts somewhere, so the CLI asks before each
;;   search.  The model's tool_use becomes a `tool-call' marked
;;   `:builtin', the CLI's question a `tool-permission' that the
;;   harness's permission chain answers, and the echoed tool_result a
;;   `tool-result'; all three name the harness tool.
;; - Streaming deltas arrive as `stream_event' messages carrying
;;   Anthropic streaming events; `assistant' messages are authoritative
;;   and are used to remember tool_use ids; `result' ends the turn.
;;   The start of each content block, the size of a tool call's input
;;   as it streams and the CLI's compacting notice become `activity'
;;   events: thinking arrives without its text, so they are all that
;;   shows the model is busy.
;; - `--resume ID' recreates a session after a restart and `--resume ID
;;   --fork-session' implements `:fork': the new session starts from
;;   the parent's cached prefix.  Which CLI session a harness session is
;;   in is what its provider state says: one whose state was dropped,
;;   because it went on with another provider, starts a new CLI session
;;   rather than carry on a stale one (see
;;   `harness-provider-claude--ensure-process').  Only the user messages
;;   after the model's last reply are sent, so a new CLI session knows
;;   nothing of what came before unless the harness hands it over (see
;;   the handoff module); a new session with older history does get it
;;   as text, below.
;; - Every assistant message and tool-result echo carries the uuid of
;;   its entry in the CLI session's chain.  They go out as checkpoints
;;   (`checkpoint' events, and `:checkpoint' on tool calls), which the
;;   agent keeps on the nodes holding that content.  A fork or a
;;   checkout at a node then cuts the CLI conversation there: `--resume
;;   ID --fork-session --resume-session-at UUID' keeps the chain up to
;;   and including UUID and nothing after it, so the model never knows
;;   what came later.  A process whose provider state is replaced by
;;   another (`session/provider-state-changed') goes.
;; - A new CLI session opened for a transcript that already has
;;   messages (a cut before any checkpoint, a resume the CLI refused, a
;;   conversation another provider held) gets that transcript as text
;;   with its first message (`harness-provider-history-text').  A CLI
;;   that exits before it starts, when told to resume or fork, gets the
;;   same, in a new CLI session, so a conversation it cannot resume
;;   never leaves the session stuck.
;; - A one-off request whose provider state is not the one its session
;;   has recorded (naming brings a fork of it) runs in a CLI process of
;;   its own, closed once it is done, so it never writes into the
;;   session's CLI session or restarts its process.
;; - A session that runs below its model's context window (a task's is
;;   capped by `harness-tasks-context-limit') is spawned with
;;   `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' set to that percentage, so the
;;   CLI's own compaction happens at the point the harness chose rather
;;   than at its default one.
;; - Every new process is sent an `initialize' and a `get_usage' control
;;   request.  The initialize answer names the account the CLI is logged
;;   in with, which decides how turns are billed, and lists the models
;;   its /model picker offers; the usage report (the data behind the
;;   CLI's /usage, fetched without a model call) gives the plan's quota
;;   and the cost total the process starts from.
;;
;; Models.  The catalogue is what the CLI lists, what its results say
;; (the window each model ran with, the model an alias ran) and, with
;; an Anthropic API key, what the API's /v1/models lists; it is kept in
;; the state directory between starts.  `harness-provider-claude-models'
;; only seeds it, so a model the CLI gains needs no change here; a name
;; nothing lists is resolved (`harness-provider-claude--resolve') or
;; estimated, never given a small window.  See "Model catalogue" below.
;;
;; Context.  A session's CLI loads the CLAUDE.md files, as `claude'
;; does on its own, but not Claude Code's auto memory unless
;; `harness-provider-claude-auto-memory' asks for it (the process gets
;; CLAUDE_CODE_DISABLE_AUTO_MEMORY otherwise).  That memory's index,
;; MEMORY.md, lists notes kept under ~/.claude/projects/, and with it
;; before the conversation the model went to read them with the
;; harness's tools, outside the allowed directories, so every session
;; asked the user for that directory.  The setting is part of the spawn
;; key, so changing it restarts a process in its conversation.
;;
;; One-off questions (a request with `:ephemeral', the permission
;; judge's) are the exception to one process per session: each gets a
;; CLI process of its own, started for it under a key of its own and
;; stopped once it is done, so it never resumes a conversation and
;; leaves none behind.  That process loads no CLAUDE.md and no auto
;; memory and saves no transcript, and a local one runs in a private
;; empty directory rather than the project's: the answer comes from
;; the request alone, not from earlier requests or the project's
;; instructions.
;;
;; Pricing.  A `result' carries `total_cost_usd', a running total for
;; the whole process that `--resume' seeds with the session's earlier
;; spend, so a turn costs the difference to the previous total.  That
;; figure is the CLI's estimate at API list prices.  With an API key, a
;; bearer token or a cloud provider it is what the turn costs.  With a
;; claude.ai subscription nobody pays it: the usage event says
;; `:billing subscription' with the plan, `:cost 0' and the estimate as
;; `:list-cost', unless the account is drawing on extra usage, which is
;; billed at API prices (`:billing extra-usage').
;;
;; Quota.  The plan's windows (the 5-hour session, the week, per-model
;; weeks) and its extra usage come from usage reports and
;; `rate_limit_event' messages.  `provider/quota' returns them, fetched
;; again through a live process, or a short-lived probe process when
;; none runs, once they are older than `harness-provider-claude--quota-ttl';
;; every change is announced as `provider/quota-updated'.
;;
;; Nothing here blocks: output is handled in a process filter, death in
;; a sentinel, and cancellation by an interrupt request plus a timer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
(require 'url-util)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-provider)

(defvar harness-state-directory)

;;;; Customisation

(defcustom harness-provider-claude-program
  (or (executable-find "claude")
      (let ((local (expand-file-name "~/.local/bin/claude")))
        (and (file-executable-p local) local))
      "claude")
  "Path to the `claude' command line program."
  :type 'string :group 'harness)

(defconst harness-provider-claude--interrupt-timeout 3
  "Seconds to wait after an interrupt before killing the CLI process.")

(defcustom harness-provider-claude-extra-args nil
  "Extra command line arguments appended to every `claude' invocation."
  :type '(repeat string) :group 'harness)

(defcustom harness-provider-claude-permission-args
  '("--permission-mode" "default" "--allowedTools" "mcp__harness__*")
  "Arguments that let the `claude' CLI run the harness's tools.
The CLI gets the harness's own MCP tools and no built-in tools, but
those standing in for a harness tool (WebSearch for web_search, see
`harness-provider-claude-builtin-tools'), and the harness's permission
system decides each call, so the CLI only has to let them through.  The
default fixes the CLI's permission mode, so no settings file starts it
in plan or auto mode, and allows every harness tool by rule.  When
WebSearch is on, \"--permission-prompt-tool stdio\" is added so that
the CLI asks the harness before each search, unless these arguments
already settle where its prompts go.

Where managed settings make the CLI ignore such rules,
\(\"--permission-mode\" \"default\" \"--permission-prompt-tool\" \"stdio\")
has the CLI ask the harness instead, which lets its own tools through,
decides the stand-ins with its permission rules and refuses any other.
\(\"--permission-mode\" \"bypassPermissions\") skips the CLI's checks
altogether, as the harness once did, so WebSearch then runs without
the harness's say; managed settings may forbid it."
  :type '(choice (const :tag "Allow the harness's tools by rule"
                        ("--permission-mode" "default" "--allowedTools" "mcp__harness__*"))
                 (const :tag "Let the CLI ask the harness"
                        ("--permission-mode" "default" "--permission-prompt-tool" "stdio"))
                 (const :tag "Bypass the CLI's permission checks"
                        ("--permission-mode" "bypassPermissions"))
                 (repeat :tag "Other arguments" string))
  :group 'harness)

(defcustom harness-provider-claude-auto-memory nil
  "Whether sessions get Claude Code's auto memory.
Claude Code keeps notes of its own on each repository in its auto
memory directory (~/.claude/projects/PROJECT/memory/), and the `claude'
CLI puts their index, MEMORY.md, before every conversation so that the
model opens the notes it lists.  A harness session has neither Claude
Code's file tools nor its instructions for those notes: the model
would open them with the harness's tools, outside the allowed
directories, so each session would ask for that directory or, when
unattended, be refused it.

Off (nil), the default, the CLI loads no auto memory
\(CLAUDE_CODE_DISABLE_AUTO_MEMORY).  On (t) it loads it as `claude'
does, and reading a note asks for its directory, which the prompt's
\"Always allow\" grants every session.  CLAUDE.md files load either
way.  A change reaches each session at its next turn: its CLI process
restarts in the same conversation."
  :type '(choice (const :tag "Off: the CLI loads no auto memory" nil)
                 (const :tag "On: the CLI loads its auto memory" t))
  :group 'harness)

(defconst harness-provider-claude--quota-ttl 60
  "Seconds after which the plan's quota report counts as stale.
A stale report is fetched again after a turn and when `provider/quota'
is asked.  The report comes from the CLI's usage endpoint and makes no
model call.  nil fetches it only when nothing is known yet.")

(defconst harness-provider-claude--probe-timeout 20
  "Seconds to wait for a usage report before answering with what is known.")

(defconst harness-provider-claude--progress-interval 0.25
  "Seconds between reports of how much of a tool call's input has streamed.")

;;;; Constants

(defconst harness-provider-claude-tool-prefix "mcp__harness__"
  "Prefix the CLI adds to the names of tools served by the harness.")

(defconst harness-provider-claude-models
  '((:name "claude-fable-5-1" :label "Claude Fable 5.1" :context-window 1000000
     :max-output 128000 :input-modalities ("text" "image")
     :thinking-levels ("low" "medium" "high" "xhigh" "max")
     :pricing (:input 10.0 :output 50.0 :cache-read 0.25 :cache-write 12.5))
    (:name "claude-opus-5-5" :label "Claude Opus 5.5" :context-window 1000000
     :max-output 128000 :input-modalities ("text" "image")
     :thinking-levels ("low" "medium" "high" "xhigh" "max")
     :pricing (:input 4.0 :output 20.0 :cache-read 0.2 :cache-write 5.0))
    (:name "claude-sonnet-5" :label "Claude Sonnet 5" :context-window 1000000
     :max-output 64000 :input-modalities ("text" "image")
     :thinking-levels ("low" "medium" "high" "xhigh" "max")
     :pricing (:input 2.0 :output 10.0 :cache-read 0.2 :cache-write 2.5))
    (:name "claude-haiku-4-5-20251001" :label "Claude Haiku 4.5" :context-window 200000
     :max-output 64000 :input-modalities ("text" "image")
     :thinking-levels ("low" "medium" "high")
     :pricing (:input 1.0 :output 5.0 :cache-read 0.1 :cache-write 1.25)))
  "Claude models known before the CLI or the API listed any.
The catalogue is what the CLI lists (see the \"Model catalogue\" section
below): these are the models it starts from, and the prices of the
models the listings name, which give none.  A model missing here works
all the same, from the CLI's listing or an estimate.")

(defconst harness-provider-claude-builtin-tools
  '(("web_search" . "WebSearch"))
  "Harness tools that a tool of Claude Code can stand in for.
Each entry is (HARNESS-NAME . CLI-NAME).  WebSearch searches the web on
Anthropic's side.  A request's `:builtin-tools' (see `tools/builtin')
names the harness tools whose stand-ins to turn on.")

(defconst harness-provider-claude-capabilities
  '(:hosted-loop t :fork t :resume t :vision t :thinking t :quota t
    :compaction hosted :cost-reported t :billing t :cache-status t
    :builtin-tools ("web_search"))
  "Capabilities of every Claude Code model.
`:builtin-tools' names the harness tools of
`harness-provider-claude-builtin-tools'.")

(defconst harness-provider-claude-tiers
  '(:cheap "haiku" :balanced "sonnet" :frontier "opus")
  "Claude models named for the common tiers, by family.
Each names the CLI's alias of that name when the CLI lists it, which is
the newest model of the family, else the first model of the catalogue
whose name holds it (see `harness-provider-tier-model').  The
auto-mode judge, for one, runs on the `cheap' one.")

(defconst harness-provider-claude--api-token-sources '("ANTHROPIC_AUTH_TOKEN" "apiKeyHelper")
  "Token sources the CLI reports for credentials billed per token.")

(defconst harness-provider-claude--window-keys
  '((five_hour "5h" "Current session (5 hours)")
    (seven_day "7d" "This week, all models")
    (seven_day_opus "7d Opus" "This week, Opus")
    (seven_day_sonnet "7d Sonnet" "This week, Sonnet")
    (seven_day_oauth_apps "7d apps" "This week, apps"))
  "Rate-limit window keys of the CLI as (KEY NAME LABEL).")

;;;; State

(cl-defstruct (harness-provider-claude-session
               (:constructor harness-provider-claude--make-session)
               (:copier nil))
  "One CLI process serving one harness session."
  id                 ; harness session id
  process            ; the CLI process, or a dead one
  stderr             ; stderr buffer
  (buffer "")        ; unparsed tail of stdout
  cli-session-id     ; Claude Code session id, from system/init
  model              ; model name reported by the CLI
  spawn-key          ; settings it was started with, see `harness-provider-claude--spawn-key'
  ;; Per-turn state
  request            ; the current request plist, nil when idle
  on-event           ; the current :on-event callback
  active             ; non-nil while a turn is in flight
  cancelled          ; non-nil once cancel was requested for this turn
  cancel-timer       ; timer that kills the process after an interrupt
  pending-tools      ; list of (TOOL-USE-ID . NAME) awaiting a tools/call
  own-results        ; tool_use ids whose results the harness produced
  context            ; input size of the last API call, from stream usage
  ;; Slots added later go last, see `harness-provider-claude--drop-stale-entries'.
  account            ; how this process is billed, from its initialize answer
  cost-total         ; the CLI's running cost total so far; nil while unknown
  baseline-id        ; id of the usage request whose session total starts it
  seen-output        ; non-nil once the CLI produced a reply or a result
  probe              ; non-nil for a quota probe, which serves no session
  tools)             ; the harness tools the last request served, kept between turns

(defvar harness-provider-claude--sessions (make-hash-table :test 'equal)
  "Harness session id -> `harness-provider-claude-session'.")

(defvar harness-provider-claude--status nil
  "What the CLI last said about the account, in the shape `provider/quota' returns.")

(defvar harness-provider-claude--refresh nil
  "The usage request in flight as (REQUEST-ID PROMISE TIMER), or nil.")

(defvar harness-provider-claude--probe nil
  "The running quota probe record, or nil.")

(defvar harness-provider-claude--request-count 0
  "Counter that keeps control request ids unique.")

(defvar harness-provider-claude--asked nil
  "When a usage report was last asked for, as a float time.")

(defvar harness-provider-claude--blocks (make-hash-table :test 'equal)
  "Harness session id -> the tool_use block streaming now, as a plist.
Kept beside the session records rather than in them, so reloading this
file leaves the running CLI processes alone.")

(defvar harness-provider-claude--builtin-calls (make-hash-table :test 'equal)
  "Harness session id -> the calls of the CLI's own tools in the current turn.
Each is a plist (:id TOOL-USE-ID :name HARNESS-NAME :input INPUT :asked
BOOL), `:asked' once the CLI asked whether it may run.  Kept beside the
session records, as `harness-provider-claude--blocks' is.")

(defvar harness-provider-claude--turn-failure (make-hash-table :test 'equal)
  "Harness session id -> what the CLI said about the current turn's failure.
Each is a plist (:kind SYMBOL :resets FLOAT :text TEXT): the kind of
failure the CLI reported (`quota', `billing', `rate-limit' or `auth'),
when a used-up quota comes back, and what it said.  Kept beside the
session records, as `harness-provider-claude--blocks' is, so reloading
this file leaves the running CLI processes alone.")

(defvar harness-provider-claude--call-checkpoints (make-hash-table :test 'equal)
  "Harness session id -> alist (TOOL-USE-ID . CHECKPOINT) of the current turn.
The assistant message holding a tool call arrives before the call is
served; its checkpoint goes out with the call's `tool-call' event.
Kept beside the session records, as `harness-provider-claude--blocks' is.")

(defvar harness-provider-claude--spawns (make-hash-table :test 'equal)
  "Harness session id -> how its CLI process was started, as a plist.
`:resume' is the CLI session it resumes or forks (nil for a new one),
`:started' is non-nil once the process announced its session, and
`:blocks' are the content blocks of the turn's first message.  A
process told to resume that exits before it starts is replaced by a new
CLI session, which gets the blocks again with the transcript.  Kept
beside the session records, as `harness-provider-claude--blocks' is.")

(defvar harness-provider-claude--call-output (make-hash-table :test 'equal)
  "Harness session id -> output tokens of the streaming message reported so far.
A `message_delta' counts the message's output so far; the part not
reported yet goes out as a `call-usage' event, for the output rate.
Kept beside the session records, as `harness-provider-claude--blocks' is.")

(defvar harness-provider-claude--side-count 0
  "Counter that keeps the ids of side requests' CLI processes unique.")

(defun harness-provider-claude--drop-stale-entries ()
  "Stop the CLI processes of records older than the current record layout.
A reload keeps live records; one made before slots were added has no
room for them, so its process stops and the session's next turn
resumes the CLI session in a new one."
  (let ((size (length (harness-provider-claude--make-session))))
    (maphash (lambda (id entry)
               (when (< (length entry) size)
                 (let ((proc (harness-provider-claude-session-process entry))
                       (stderr (harness-provider-claude-session-stderr entry))
                       (fn (harness-provider-claude-session-on-event entry)))
                   (when (process-live-p proc)
                     (set-process-sentinel proc #'ignore)
                     (set-process-filter proc #'ignore)
                     (delete-process proc))
                   (when (buffer-live-p stderr) (kill-buffer stderr))
                   (when (and fn (harness-provider-claude-session-active entry))
                     (ignore-errors
                       (funcall fn '(:type done :stop-reason error
                                     :error "The Claude provider was reloaded during this turn")))))
                 (remhash id harness-provider-claude--sessions)))
             harness-provider-claude--sessions)))

(harness-provider-claude--drop-stale-entries)

;;;; Small helpers

(defun harness-provider-claude--strip-prefix (name)
  "Return tool NAME without the CLI's MCP server prefix."
  (if (and (stringp name) (string-prefix-p harness-provider-claude-tool-prefix name))
      (substring name (length harness-provider-claude-tool-prefix))
    name))

(defun harness-provider-claude--emit (entry event)
  "Deliver EVENT to the current turn's callback on ENTRY."
  (let ((fn (harness-provider-claude-session-on-event entry)))
    (when (and fn (harness-provider-claude-session-active entry))
      (funcall fn event))))

(defun harness-provider-claude--finish (entry event)
  "End the current turn on ENTRY by delivering the done EVENT once."
  (when (harness-provider-claude-session-active entry)
    (when-let* ((timer (harness-provider-claude-session-cancel-timer entry)))
      (cancel-timer timer))
    (harness-provider-claude--end-block entry)
    (remhash (harness-provider-claude-session-id entry) harness-provider-claude--builtin-calls)
    (remhash (harness-provider-claude-session-id entry) harness-provider-claude--turn-failure)
    (remhash (harness-provider-claude-session-id entry) harness-provider-claude--call-checkpoints)
    (remhash (harness-provider-claude-session-id entry) harness-provider-claude--call-output)
    (let ((fn (harness-provider-claude-session-on-event entry)))
      (setf (harness-provider-claude-session-active entry) nil
            (harness-provider-claude-session-cancel-timer entry) nil
            (harness-provider-claude-session-on-event entry) nil
            (harness-provider-claude-session-request entry) nil)
      (when fn (funcall fn event)))))

(defun harness-provider-claude--send (entry object)
  "Write OBJECT as one JSON line to ENTRY's CLI process."
  (let ((proc (harness-provider-claude-session-process entry)))
    (if (process-live-p proc)
        (process-send-string proc (concat (harness-json-encode object) "\n"))
      (harness-log 'warn "provider-claude: cannot write to dead process for %s"
                   (harness-provider-claude-session-id entry)))))

(defun harness-provider-claude--stderr-tail (entry)
  "Return the last few lines of ENTRY's stderr, or an empty string."
  (let ((buf (harness-provider-claude-session-stderr entry)))
    (if (buffer-live-p buf)
        (with-current-buffer buf
          (string-trim (buffer-substring-no-properties
                        (max (point-min) (- (point-max) 2000)) (point-max))))
      "")))

(defconst harness-provider-claude--no-auto-memory "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"
  "Environment entry that has the CLI load no auto memory.
Claude Code's documented switch; a CLI too old to know it ignores it.")

(defun harness-provider-claude--environment (&optional effort)
  "Return `process-environment' for a CLI process.
The CLAUDECODE nesting marker goes, and auto memory is off unless
`harness-provider-claude-auto-memory' is on.  With EFFORT `off' it
also turns the CLI's extended thinking off (see
`harness-provider-claude--effort')."
  (append (and (eq effort 'off) (list "MAX_THINKING_TOKENS=0"))
          (and (not harness-provider-claude-auto-memory)
               (list harness-provider-claude--no-auto-memory))
          (cl-remove-if (lambda (e) (string-prefix-p "CLAUDECODE=" e)) process-environment)))

(defun harness-provider-claude--effort (request)
  "Return the thinking level a CLI process serving REQUEST runs at.
That is REQUEST's `:thinking', or `off' when it asks for no thinking
with `:no-thinking'.  The CLI takes no output budget, so it ignores a
request's `:max-tokens', and a model thinking by default spends its
whole output on thinking before a short answer: the auto-mode judge
ended at max_tokens with no verdict, or half of one."
  (if (plist-get request :no-thinking) 'off (plist-get request :thinking)))

(defun harness-provider-claude--model-window (model-id)
  "Return the context window the catalogue gives MODEL-ID, or nil.
Nil too when that window is an estimate: a percentage of a window
guessed wrong would have the CLI compact far from where it should."
  (and (harness-method-exists-p 'provider/model)
       (condition-case nil
           (let ((model (harness-call 'provider/model model-id)))
             (unless (plist-get model :context-window-estimated)
               (plist-get model :context-window)))
         (error nil))))

(defun harness-provider-claude--autocompact-pct (request)
  "Return the percentage the CLI should auto-compact at for REQUEST, or nil.
A session whose context window is smaller than its model's (the harness
caps a task's, say) is told to auto-compact at that part of the window,
so the CLI's own compaction matches the budget the harness gave the
session.  nil leaves the CLI's default, as it does while the model's
window is only an estimate; the first turn teaches the real one."
  (let* ((session (plist-get request :session))
         (window (plist-get session :context-window))
         (model-window (harness-provider-claude--model-window (plist-get request :model))))
    (when (and (numberp window) (> window 0)
               (numberp model-window) (> model-window 0)
               (< window model-window))
      (max 1 (min 99 (round (* 100.0 (/ window (float model-window)))))))))

(defun harness-provider-claude--environment-for (request)
  "Return `process-environment' for the CLI process serving REQUEST.
A session that runs below its model's context window tells the CLI to
auto-compact at the same point (`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE', a
percentage), so the CLI's own compaction matches the shorter budget the
harness gave the session (a task's, say).  A request with
`:no-thinking' also turns the CLI's extended thinking off."
  (let ((pct (harness-provider-claude--autocompact-pct request))
        (env (harness-provider-claude--environment
              (harness-provider-claude--effort request))))
    (if pct
        (cons (format "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=%d" pct) env)
      env)))

;;;; Command line and spawning

(defun harness-provider-claude--prompts-routed-p (args)
  "Non-nil when the CLI arguments ARGS settle where its permission prompts go.
They name a permission prompt tool, or skip the CLI's checks."
  (cl-some (lambda (a)
             (or (member a '("--permission-prompt-tool" "--dangerously-skip-permissions"))
                 (string-prefix-p "--permission-prompt-tool=" a)
                 (equal a "--permission-mode=bypassPermissions")))
           (append args
                   (cl-loop for (a b) on args
                            when (equal a "--permission-mode")
                            collect (concat a "=" b)))))

(defun harness-provider-claude--ask-args (builtin)
  "Return the arguments that make the CLI ask before it runs a BUILTIN tool.
BUILTIN lists the CLI's own tools turned on.  The CLI then sends its
permission prompts here as `can_use_tool' requests, which the harness's
permission chain answers for those tools; the harness's own tools stay
allowed by rule.  Nothing when there is no BUILTIN tool, or when
`harness-provider-claude-permission-args' or
`harness-provider-claude-extra-args' already settle where the prompts
go."
  (unless (or (null builtin)
              (harness-provider-claude--prompts-routed-p
               (append harness-provider-claude-permission-args harness-provider-claude-extra-args)))
    (list "--permission-prompt-tool" "stdio")))

(defun harness-provider-claude--command (model effort system resume fork &optional builtin resume-at)
  "Build the `claude' command line.
MODEL is the model name, EFFORT the thinking level, `off' for no
extended thinking, or nil, SYSTEM the system prompt or nil, RESUME a
CLI session id to continue or nil, and FORK non-nil to fork RESUME into
a new session.  BUILTIN lists the CLI's own tools to turn on
\(\"WebSearch\"); every other one is off.  RESUME-AT, the uuid of an
entry of RESUME's chain, keeps the resumed conversation up to and
including that entry; only a fork is cut, so RESUME itself keeps all
it has."
  (append
   (list harness-provider-claude-program
         "-p" "--input-format" "stream-json" "--output-format" "stream-json"
         "--verbose" "--include-partial-messages"
         "--tools" (string-join builtin ",")
         "--strict-mcp-config"
         "--mcp-config" (harness-json-encode
                         '(:mcpServers (:harness (:type "sdk" :name "harness")))))
   harness-provider-claude-permission-args
   (harness-provider-claude--ask-args builtin)
   (list "--model" model)
   (cond ((eq effort 'off)
          ;; Thinking off.  Flag settings beat the user's settings files,
          ;; whose `env' would otherwise beat the process environment.
          (list "--settings" (harness-json-encode '(:env (:MAX_THINKING_TOKENS "0")))))
         (effort (list "--effort" effort)))
   (when (and system (not (harness-string-blank-p system)))
     (list "--system-prompt" system))
   (when resume (list "--resume" resume))
   (when (and resume fork) (list "--fork-session"))
   (when (and resume fork resume-at) (list "--resume-session-at" resume-at))
   harness-provider-claude-extra-args))

(defun harness-provider-claude--cli-tools (request)
  "Return the CLI's own tools that REQUEST turns on, by their CLI names.
They stand in for the harness tools its `:builtin-tools' names."
  (let ((wanted (plist-get request :builtin-tools)))
    (delq nil (mapcar (lambda (cell) (and (member (car cell) wanted) (cdr cell)))
                      harness-provider-claude-builtin-tools))))

(defun harness-provider-claude--spawn-key (request)
  "Return the settings a CLI process must have been started with to serve REQUEST.
That is (MODEL EFFORT SYSTEM BUILTIN PCT MEMORY): EFFORT `off' for no
extended thinking (see `harness-provider-claude--effort'), the CLI
tools it turns on (nil when none), the auto-compact percentage it was
given (nil without one) and whether it loads its auto memory
\(`harness-provider-claude-auto-memory').  A process started otherwise
is restarted."
  (list (cdr (harness-provider-parse-model (plist-get request :model)))
        (harness-provider-claude--effort request)
        (plist-get request :system)
        (harness-provider-claude--cli-tools request)
        (harness-provider-claude--autocompact-pct request)
        (and harness-provider-claude-auto-memory t)))

(defun harness-provider-claude--builtin-name (entry name)
  "Return the harness tool that the CLI's tool NAME stands in for on ENTRY, or nil.
Only the tools ENTRY's process was started with count."
  (and (stringp name)
       (member name (nth 3 (harness-provider-claude-session-spawn-key entry)))
       (car (rassoc name harness-provider-claude-builtin-tools))))

(defun harness-provider-claude--spawn (entry request resume fork &optional resume-at)
  "Start a CLI process for ENTRY serving REQUEST.
RESUME, FORK and RESUME-AT are passed to `harness-provider-claude--command'."
  (let* ((session (plist-get request :session))
         (cwd (or (plist-get session :cwd) default-directory))
         (host (plist-get session :host))
         (cwd (if (and host (not (file-remote-p cwd))) (concat host cwd) cwd))
         (default-directory (file-name-as-directory (expand-file-name cwd)))
         (effort (harness-provider-claude--effort request))
         (process-environment (harness-provider-claude--environment-for request))
         (model (cdr (harness-provider-parse-model (plist-get request :model))))
         (system (plist-get request :system))
         (command (harness-provider-claude--command model effort system resume fork
                                                    (harness-provider-claude--cli-tools request)
                                                    resume-at))
         (stderr (generate-new-buffer " *harness-claude-stderr*" t))
         (proc (condition-case err
                   (make-process :name (format "harness-claude-%s" (harness-provider-claude-session-id entry))
                                 :command command
                                 :coding '(utf-8 . utf-8)
                                 :connection-type 'pipe
                                 :noquery t
                                 :file-handler t
                                 :stderr stderr
                                 :filter (lambda (_p chunk) (harness-provider-claude--filter entry chunk))
                                 :sentinel (lambda (p e) (harness-provider-claude--sentinel entry p e)))
                 ;; A CLI that cannot start (missing, say) leaves the pipe
                 ;; its stderr was to come through behind.
                 (error (when-let* ((ep (get-buffer-process stderr))) (delete-process ep))
                        (kill-buffer stderr)
                        (signal (car err) (cdr err))))))
    (when-let* ((ep (get-buffer-process stderr)))
      (set-process-query-on-exit-flag ep nil)
      (set-process-sentinel ep #'ignore))
    (harness-log 'info "provider-claude: spawned for %s%s%s%s"
                 (harness-provider-claude-session-id entry)
                 (if resume (format " (resume %s)" resume) "")
                 (cond ((and fork resume-at) (format " forked at %s" resume-at))
                       (fork " forked")
                       (t ""))
                 (let ((builtin (harness-provider-claude--cli-tools request)))
                   (if builtin (format " with %s" (string-join builtin ", ")) "")))
    (puthash (harness-provider-claude-session-id entry) (list :resume resume :started nil :blocks nil)
             harness-provider-claude--spawns)
    (setf (harness-provider-claude-session-process entry) proc
          (harness-provider-claude-session-stderr entry) stderr
          (harness-provider-claude-session-buffer entry) ""
          (harness-provider-claude-session-spawn-key entry) (harness-provider-claude--spawn-key request)
          (harness-provider-claude-session-account entry) nil
          ;; A fresh CLI session starts from zero; a resumed or forked
          ;; one from the spend it restores, which the usage report says.
          (harness-provider-claude-session-cost-total entry) (if resume nil 0.0)
          (harness-provider-claude-session-seen-output entry) nil
          ;; The CLI session the process is in, until its banner says:
          ;; the one it resumes, and none yet for a new one or a fork.
          (harness-provider-claude-session-cli-session-id entry) (and (not fork) resume))
    (harness-provider-claude--send
     entry '(:type "control_request" :request_id "init-1"
             :request (:subtype "initialize" :sdkMcpServers ("harness"))))
    (setf (harness-provider-claude-session-baseline-id entry)
          (harness-provider-claude--request-usage entry))
    proc))

(defun harness-provider-claude--kill (entry)
  "Kill ENTRY's process and its stderr buffer."
  (let ((proc (harness-provider-claude-session-process entry))
        (buf (harness-provider-claude-session-stderr entry)))
    (when (process-live-p proc)
      (set-process-sentinel proc #'ignore)
      (delete-process proc))
    (when (buffer-live-p buf) (kill-buffer buf))
    (harness-provider-claude--end-block entry)
    (setf (harness-provider-claude-session-process entry) nil
          (harness-provider-claude-session-stderr entry) nil)))

;;;; Messages out

(defun harness-provider-claude--read-base64 (path)
  "Return the contents of PATH base64 encoded, or nil."
  (when (and path (file-readable-p path))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path)
      (base64-encode-string (buffer-string) t))))

(defun harness-provider-claude--convert-block (block)
  "Convert harness content BLOCK into an Anthropic content block, or nil."
  (pcase (plist-get block :type)
    ("text" (list :type "text" :text (or (plist-get block :text) "")))
    ("image"
     (when-let* ((data (or (plist-get block :data)
                           (harness-provider-claude--read-base64 (plist-get block :path)))))
       (list :type "image"
             :source (list :type "base64"
                           :media_type (or (plist-get block :mime) "image/png")
                           :data data))))
    ("file" (list :type "text"
                  :text (format "[attached file: %s]" (plist-get block :path))))
    (_ nil)))

(defun harness-provider-claude--user-blocks (request)
  "Return the content blocks of the trailing user messages in REQUEST."
  (let (blocks)
    (dolist (msg (plist-get request :messages))
      (let ((role (format "%s" (plist-get msg :role))))
        (cond ((equal role "assistant") (setq blocks nil))
              ((equal role "user")
               (dolist (b (plist-get msg :content))
                 (when-let* ((c (harness-provider-claude--convert-block b)))
                   (push c blocks)))))))
    (nreverse blocks)))

(defun harness-provider-claude--send-user (entry blocks)
  "Write a user message with content BLOCKS to ENTRY's process."
  (harness-provider-claude--send
   entry (list :type "user" :message (list :role "user" :content blocks))))

(defun harness-provider-claude--control-response (entry request-id reply)
  "Answer control request REQUEST-ID on ENTRY with the MCP message REPLY."
  (harness-provider-claude--send
   entry (list :type "control_response"
               :response (list :subtype "success" :request_id request-id
                               :response (list :mcp_response reply)))))

(defun harness-provider-claude--control-error (entry request-id message)
  "Fail control request REQUEST-ID on ENTRY with MESSAGE."
  (harness-provider-claude--send
   entry (list :type "control_response"
               :response (list :subtype "error" :request_id request-id :error message))))

;;;; MCP server

(defun harness-provider-claude--tool-list (entry)
  "Return the MCP tool descriptors of the tools ENTRY serves.
They are those of the last request, which ENTRY keeps once its turn is
over: the CLI may list the tools while no turn is in flight -- its
handshake can come after a turn that ended at once -- and it keeps the
list it got for the life of the process, so an empty one would leave
every later turn without tools."
  (mapcar (lambda (spec)
            (list :name (plist-get spec :name)
                  :description (or (plist-get spec :description) "")
                  :inputSchema (or (plist-get spec :schema)
                                   '(:type "object" :properties :empty))))
          (harness-provider-claude-session-tools entry)))

(defun harness-provider-claude--take-tool-id (entry name)
  "Return the pending tool_use id for NAME on ENTRY, or a generated one."
  (let ((cell (cl-find name (harness-provider-claude-session-pending-tools entry)
                       :key #'cdr :test #'equal)))
    (if cell
        (progn (setf (harness-provider-claude-session-pending-tools entry)
                     (delq cell (harness-provider-claude-session-pending-tools entry)))
               (car cell))
      (concat "toolu_" (harness-short-id 12)))))

(defun harness-provider-claude--remember-tool-use (entry id name)
  "Remember that the assistant emitted tool_use ID for NAME on ENTRY."
  (when (and id name
             (not (assoc id (harness-provider-claude-session-pending-tools entry))))
    (setf (harness-provider-claude-session-pending-tools entry)
          (append (harness-provider-claude-session-pending-tools entry)
                  (list (cons id (harness-provider-claude--strip-prefix name)))))))

(defun harness-provider-claude--tools-call (entry request-id message)
  "Serve a tools/call MESSAGE under control request REQUEST-ID on ENTRY."
  (let* ((rpc-id (plist-get message :id))
         (params (plist-get message :params))
         (name (harness-provider-claude--strip-prefix (plist-get params :name)))
         (input (plist-get params :arguments))
         (tool-id (harness-provider-claude--take-tool-id entry name))
         (answered nil)
         (respond
          (lambda (result)
            (unless answered
              (setq answered t)
              (let ((content (plist-get result :content))
                    (is-error (harness-json-true-p (plist-get result :is-error))))
                (push tool-id (harness-provider-claude-session-own-results entry))
                (harness-provider-claude--control-response
                 entry request-id
                 (list :jsonrpc "2.0" :id rpc-id
                       :result (list :content (list (list :type "text"
                                                          :text (if (stringp content) content
                                                                  (format "%s" (or content "")))))
                                     :isError (if is-error t :false)))))))))
    (if (harness-provider-claude-session-active entry)
        (harness-provider-claude--emit
         entry (append (list :type 'tool-call :id tool-id :name name :input input :respond respond)
                       (when-let* ((checkpoint (harness-provider-claude--call-checkpoint entry tool-id)))
                         (list :checkpoint checkpoint))))
      (funcall respond (list :content "The harness is not running a turn" :is-error t)))))

(defun harness-provider-claude--handle-mcp (entry request-id message)
  "Answer the JSON-RPC MESSAGE from the CLI under REQUEST-ID on ENTRY."
  (let ((method (plist-get message :method))
        (rpc-id (plist-get message :id)))
    (pcase method
      ("initialize"
       (harness-provider-claude--control-response
        entry request-id
        (list :jsonrpc "2.0" :id rpc-id
              :result (list :protocolVersion (or (harness-plist-get-in message '(:params :protocolVersion))
                                                 "2025-06-18")
                            :capabilities '(:tools :empty)
                            :serverInfo '(:name "harness" :version "3.0.0")))))
      ("notifications/initialized"
       ;; The CLI waits for an answer even though this is a notification.
       (harness-provider-claude--control-response
        entry request-id '(:jsonrpc "2.0" :id 0 :result :empty)))
      ("tools/list"
       (harness-provider-claude--control-response
        entry request-id
        (list :jsonrpc "2.0" :id rpc-id
              :result (list :tools (harness-json-array (harness-provider-claude--tool-list entry))))))
      ("tools/call"
       (harness-provider-claude--tools-call entry request-id message))
      (_
       (harness-log 'debug "provider-claude: unhandled MCP method %s" method)
       (if rpc-id
           (harness-provider-claude--control-response
            entry request-id (list :jsonrpc "2.0" :id rpc-id :result :empty))
         (harness-provider-claude--control-response
          entry request-id '(:jsonrpc "2.0" :id 0 :result :empty)))))))

(defun harness-provider-claude--answer-permission (entry request-id answer)
  "Answer the CLI's permission prompt REQUEST-ID on ENTRY with ANSWER."
  (harness-provider-claude--send
   entry (list :type "control_response"
               :response (list :subtype "success" :request_id request-id :response answer))))

(defun harness-provider-claude--can-use-tool (entry request-id request)
  "Answer the CLI's permission prompt REQUEST under REQUEST-ID on ENTRY.
The CLI asks when a permission prompt tool sends its prompts here (see
`harness-provider-claude-permission-args' and
`harness-provider-claude--ask-args').  The harness's own tools are let
through, since the harness's permission system decides each call when
it serves it.  A tool of the CLI's that stands in for a harness tool
goes to the turn, whose permission chain decides it (see
`harness-provider-claude--ask-builtin'); any other tool is refused."
  (let* ((name (plist-get request :tool_name))
         (ours (and (stringp name) (string-prefix-p harness-provider-claude-tool-prefix name)))
         (builtin (and (not ours) (harness-provider-claude--builtin-name entry name))))
    (if (and builtin (harness-provider-claude-session-active entry))
        (harness-provider-claude--ask-builtin entry request-id request builtin)
      (harness-log 'debug "provider-claude: %s %s for %s"
                   (if ours "allowing" "refusing") name (harness-provider-claude-session-id entry))
      (harness-provider-claude--answer-permission
       entry request-id
       (cond (ours
              ;; Parsing turned {} into nil, which would go back as null.
              (list :behavior "allow" :updatedInput (or (plist-get request :input) :empty)))
             (builtin (list :behavior "deny" :message "The harness is not running a turn"))
             (t (list :behavior "deny"
                      :message (format "The harness runs only its own tools, and %s is not one of them"
                                       name))))))))

;;;; The CLI's own tools

(defun harness-provider-claude--builtin-calls (entry)
  "Return the calls of the CLI's own tools in ENTRY's current turn."
  (gethash (harness-provider-claude-session-id entry) harness-provider-claude--builtin-calls))

(defun harness-provider-claude--builtin-call (entry id)
  "Return the record of call ID of one of the CLI's own tools on ENTRY, or nil."
  (cl-find id (harness-provider-claude--builtin-calls entry)
           :key (lambda (c) (plist-get c :id)) :test #'equal))

(defun harness-provider-claude--announce-builtin (entry id name input)
  "Report call ID on ENTRY of the CLI's tool standing in for harness tool NAME.
INPUT is its input.  The turn hears of each call once, as a `tool-call'
marked `:builtin'.  Return the call's record."
  (or (harness-provider-claude--builtin-call entry id)
      (let ((call (list :id id :name name :input input :asked nil))
            (sid (harness-provider-claude-session-id entry)))
        (puthash sid (append (gethash sid harness-provider-claude--builtin-calls) (list call))
                 harness-provider-claude--builtin-calls)
        (harness-provider-claude--emit
         entry (append (list :type 'tool-call :id id :name name :input input :builtin t)
                       (when-let* ((checkpoint (harness-provider-claude--call-checkpoint entry id)))
                         (list :checkpoint checkpoint))))
        call)))

(defun harness-provider-claude--ask-builtin (entry request-id request name)
  "Ask the turn on ENTRY whether the CLI may run its tool standing in for NAME.
REQUEST is the CLI's `can_use_tool' prompt, answered under REQUEST-ID
once the harness has decided: the `tool-permission' event's `:respond'
gets the harness's DECISION.  CLIs that do not say which call they ask
about mean the oldest one not asked about yet."
  (let* ((id (or (plist-get request :tool_use_id)
                 (plist-get (cl-find-if (lambda (c) (and (equal name (plist-get c :name))
                                                         (not (plist-get c :asked))))
                                        (harness-provider-claude--builtin-calls entry))
                            :id)
                 (concat "toolu_" (harness-short-id 12))))
         (input (or (plist-get request :input)
                    (plist-get (harness-provider-claude--builtin-call entry id) :input)))
         (call (harness-provider-claude--announce-builtin entry id name input))
         (answered nil))
    (plist-put call :asked t)
    (harness-log 'debug "provider-claude: asking the harness about %s (%s) for %s"
                 name id (harness-provider-claude-session-id entry))
    (harness-provider-claude--emit
     entry
     (list :type 'tool-permission :id id :name name :input input
           :respond
           (lambda (decision)
             (unless answered
               (setq answered t)
               (harness-provider-claude--answer-permission
                entry request-id
                (if (eq (plist-get decision :behavior) 'allow)
                    ;; Parsing turned {} into nil, which would go back as null.
                    (list :behavior "allow" :updatedInput (or (plist-get decision :input) input :empty))
                  (list :behavior "deny"
                        :message (or (plist-get decision :message) "The harness denied this call"))))))))))

(defun harness-provider-claude--handle-control (entry msg)
  "Handle a control_request MSG from the CLI on ENTRY."
  (let* ((request-id (plist-get msg :request_id))
         (request (plist-get msg :request))
         (subtype (plist-get request :subtype)))
    (pcase subtype
      ("mcp_message"
       (if (equal (plist-get request :server_name) "harness")
           (harness-provider-claude--handle-mcp entry request-id (plist-get request :message))
         (harness-provider-claude--control-error
          entry request-id (format "unknown MCP server %s" (plist-get request :server_name)))))
      ("can_use_tool" (harness-provider-claude--can-use-tool entry request-id request))
      (_
       (harness-log 'warn "provider-claude: unsupported control request %s" subtype)
       (harness-provider-claude--control-error
        entry request-id (format "unsupported control request %s" subtype))))))

;;;; Messages in

(defun harness-provider-claude--usage-context (usage)
  "Return the prompt size described by the Anthropic USAGE plist, or nil."
  (when (and usage (plist-get usage :input_tokens))
    (+ (or (plist-get usage :input_tokens) 0)
       (or (plist-get usage :cache_read_input_tokens) 0)
       (or (plist-get usage :cache_creation_input_tokens) 0))))

;; What the model is producing, as `activity' events.  The CLI streams a
;; thinking block without its text (only a signature arrives, at its
;; end) and a tool call's input as JSON fragments nobody reads before
;; the call itself, so without these a turn shows nothing for as long
;; as the model thinks or writes a large input.

(defun harness-provider-claude--start-tool-input (entry name)
  "Begin reporting the input of a call to tool NAME streaming on ENTRY."
  (puthash (harness-provider-claude-session-id entry)
           (list :tool name :chars 0 :sent-at (float-time) :timer nil)
           harness-provider-claude--blocks)
  (harness-provider-claude--emit entry (list :type 'activity :phase 'tool-input :tool name :chars 0)))

(defun harness-provider-claude--report-input (entry block)
  "Report how much of BLOCK's tool input has streamed on ENTRY.
BLOCK's keys all exist from the start, so it is updated in place."
  (when-let* ((timer (plist-get block :timer)))
    (cancel-timer timer))
  (setf (plist-get block :timer) nil
        (plist-get block :sent-at) (float-time))
  (harness-provider-claude--emit entry (list :type 'activity :phase 'tool-input
                                             :tool (plist-get block :tool)
                                             :chars (plist-get block :chars))))

(defun harness-provider-claude--input-progress (entry chars)
  "Count CHARS more characters of the tool input streaming on ENTRY.
Reports go out at most every `harness-provider-claude--progress-interval'
seconds; one held back goes out when the interval is up, unless the
block has ended by then, so a report never follows the call it is about."
  (when-let* ((block (gethash (harness-provider-claude-session-id entry) harness-provider-claude--blocks)))
    (setf (plist-get block :chars) (+ chars (plist-get block :chars)))
    (let ((wait (- (+ (plist-get block :sent-at) harness-provider-claude--progress-interval) (float-time))))
      (cond ((<= wait 0) (harness-provider-claude--report-input entry block))
            ((null (plist-get block :timer))
             (setf (plist-get block :timer)
                   (run-at-time wait nil
                                (lambda ()
                                  (setf (plist-get block :timer) nil)
                                  (when (eq block (gethash (harness-provider-claude-session-id entry)
                                                           harness-provider-claude--blocks))
                                    (harness-provider-claude--report-input entry block))))))))))

(defun harness-provider-claude--end-block (entry)
  "Forget the tool input streaming on ENTRY, if any."
  (let ((sid (harness-provider-claude-session-id entry)))
    (when-let* ((block (gethash sid harness-provider-claude--blocks)))
      (when-let* ((timer (plist-get block :timer)))
        (cancel-timer timer))
      (remhash sid harness-provider-claude--blocks))))

(defun harness-provider-claude--call-usage (entry usage)
  "Report the output that USAGE, a `message_delta''s, adds on ENTRY.
USAGE counts the output of the message so far; what was not reported
yet goes out as a `call-usage' event, for the output rate.  The turn's
`usage' event, from the result, counts it with the turn's other calls."
  (let* ((sid (harness-provider-claude-session-id entry))
         (output (plist-get usage :output_tokens))
         (reported (gethash sid harness-provider-claude--call-output 0)))
    (when (and (numberp output) (> output reported))
      (puthash sid output harness-provider-claude--call-output)
      (harness-provider-claude--emit entry (list :type 'call-usage :output (- output reported))))))

(defun harness-provider-claude--handle-stream (entry event &optional sub-agent)
  "Handle an Anthropic streaming EVENT on ENTRY.
SUB-AGENT is non-nil for the stream of a sub-agent's message (its
`parent_tool_use_id'), whose usage the main conversation's output rate
leaves out."
  (pcase (plist-get event :type)
    ("message_start"
     (unless sub-agent
       (remhash (harness-provider-claude-session-id entry) harness-provider-claude--call-output))
     (when-let* ((ctx (harness-provider-claude--usage-context
                       (plist-get (plist-get event :message) :usage))))
       (setf (harness-provider-claude-session-context entry) ctx)))
    ("message_delta"
     (when-let* ((ctx (harness-provider-claude--usage-context (plist-get event :usage))))
       (setf (harness-provider-claude-session-context entry) ctx))
     (unless sub-agent
       (harness-provider-claude--call-usage entry (plist-get event :usage))))
    ("content_block_start"
     (let ((block (plist-get event :content_block)))
       (harness-provider-claude--end-block entry)
       (pcase (plist-get block :type)
         ("tool_use"
          (harness-provider-claude--remember-tool-use
           entry (plist-get block :id) (plist-get block :name))
          (harness-provider-claude--start-tool-input
           entry (or (harness-provider-claude--builtin-name entry (plist-get block :name))
                     (harness-provider-claude--strip-prefix (plist-get block :name)))))
         ((or "thinking" "redacted_thinking")
          (harness-provider-claude--emit entry '(:type activity :phase thinking)))
         ("text"
          (harness-provider-claude--emit entry '(:type activity :phase writing))))))
    ("content_block_stop" (harness-provider-claude--end-block entry))
    ("content_block_delta"
     (let* ((delta (plist-get event :delta))
            (kind (plist-get delta :type)))
       (pcase kind
         ;; Whitespace counts: a delta of "\n\n" separates paragraphs.
         ;; The agent keeps whitespace from opening a message by itself.
         ("text_delta"
          (let ((text (plist-get delta :text)))
            (unless (or (not (stringp text)) (string-empty-p text))
              (harness-provider-claude--emit entry (list :type 'text :delta text)))))
         ("thinking_delta"
          (let ((text (plist-get delta :thinking)))
            (unless (or (not (stringp text)) (string-empty-p text))
              (harness-provider-claude--emit entry (list :type 'thinking :delta text)))))
         ("input_json_delta"
          (let ((json (plist-get delta :partial_json)))
            (when (stringp json)
              (harness-provider-claude--input-progress entry (length json))))))))))

(defun harness-provider-claude--checkpoint (entry msg)
  "Return the checkpoint of the stdout message MSG on ENTRY, or nil.
That is (:cli-session-id ID :uuid UUID): the CLI session and the entry
of its chain holding MSG, the point up to which `--resume-session-at'
keeps a fork.  A message of a sub-agent's chain (`parent_tool_use_id')
is not in the session's chain, and a CLI that sends no uuid gives none."
  (let ((uuid (plist-get msg :uuid))
        (id (or (plist-get msg :session_id) (harness-provider-claude-session-cli-session-id entry))))
    (and (stringp uuid) (not (string-empty-p uuid)) (stringp id)
         (not (plist-get msg :parent_tool_use_id))
         (list :cli-session-id id :uuid uuid))))

(defun harness-provider-claude--handle-assistant (entry message &optional checkpoint)
  "Remember tool_use ids from the authoritative assistant MESSAGE on ENTRY.
A call of the CLI's own tools that stands in for a harness tool is
reported to the turn here, where its input is complete.  An assistant
message that reports an `error' (a usage limit, a billing problem, a
refused login) is remembered for the turn's `done' event.  CHECKPOINT is
the message's (see `harness-provider-claude--checkpoint'): it goes out
with the message's tool calls when it has any, which the turn records
later, and else at once, for the text or thinking the turn has just
recorded from it."
  (when-let* ((error (plist-get message :error)))
    (let* ((old (gethash (harness-provider-claude-session-id entry)
                         harness-provider-claude--turn-failure))
           (kind (harness-provider-claude--failure-kind error))
           (text (harness-provider-claude--failure-text message)))
      ;; A rejected usage window said `quota' already; a plain rate
      ;; limit must not talk it down, and a billing error must win.
      (harness-provider-claude--note-failure
       entry
       :kind (cond ((memq kind '(billing auth)) kind)
                   ((and (eq kind 'rate-limit)
                         (eq (plist-get old :kind) 'quota)) 'quota)
                   (t kind))
       :text text)))
  (let ((calls nil))
    (dolist (block (plist-get message :content))
      (when (equal (plist-get block :type) "tool_use")
        (push (plist-get block :id) calls)
        (harness-provider-claude--remember-tool-use
         entry (plist-get block :id) (plist-get block :name))
        (when checkpoint
          (let ((sid (harness-provider-claude-session-id entry)))
            (puthash sid (cons (cons (plist-get block :id) checkpoint)
                               (gethash sid harness-provider-claude--call-checkpoints))
                     harness-provider-claude--call-checkpoints)))
        (when-let* ((name (harness-provider-claude--builtin-name entry (plist-get block :name))))
          (harness-provider-claude--announce-builtin
           entry (plist-get block :id) name (plist-get block :input)))))
    (when (and checkpoint (null calls))
      (harness-provider-claude--emit entry (list :type 'checkpoint :checkpoint checkpoint))))
  (when-let* ((ctx (harness-provider-claude--usage-context (plist-get message :usage))))
    (setf (harness-provider-claude-session-context entry) ctx)))

(defun harness-provider-claude--call-checkpoint (entry id)
  "Return the checkpoint of the assistant message holding tool call ID on ENTRY."
  (cdr (assoc id (gethash (harness-provider-claude-session-id entry) harness-provider-claude--call-checkpoints))))

(defun harness-provider-claude--result-text (content)
  "Flatten a tool_result CONTENT (string or list of blocks) into text."
  (cond ((stringp content) content)
        ((listp content)
         (mapconcat (lambda (b) (or (plist-get b :text) "")) content "\n"))
        (t (format "%s" content))))

(defun harness-provider-claude--handle-user-echo (entry message &optional checkpoint)
  "Emit tool results from an echoed user MESSAGE on ENTRY, unless they are ours.
The result of a call of the CLI's own tools that the turn has not heard
of yet comes after the call itself.  CHECKPOINT, the message's (see
`harness-provider-claude--checkpoint'), goes out for each result it
holds, once the turn has recorded that result."
  (dolist (block (plist-get message :content))
    (when (equal (plist-get block :type) "tool_result")
      (let ((id (plist-get block :tool_use_id)))
        (if (member id (harness-provider-claude-session-own-results entry))
            (setf (harness-provider-claude-session-own-results entry)
                  (delete id (harness-provider-claude-session-own-results entry)))
          (when-let* ((name (harness-provider-claude--builtin-name
                             entry (cdr (assoc id (harness-provider-claude-session-pending-tools entry))))))
            (harness-provider-claude--announce-builtin entry id name nil))
          (harness-provider-claude--emit
           entry (list :type 'tool-result :id id
                       :content (harness-provider-claude--result-text (plist-get block :content))
                       :is-error (harness-json-true-p (plist-get block :is_error)))))
        (when checkpoint
          (harness-provider-claude--emit entry (list :type 'checkpoint :checkpoint checkpoint :call-id id)))))))

(defun harness-provider-claude--handle-denial (entry msg)
  "Report that the CLI refused to run a tool, from the system MSG on ENTRY.
The harness never hears of a harness tool's call that the CLI refuses,
so the user learns of it here; nor does it decide on one of the CLI's
own tools that the CLI's rules refuse."
  (let* ((name (plist-get msg :tool_name))
         (why (or (plist-get msg :message) "permission denied"))
         (builtin (harness-provider-claude--builtin-name entry name)))
    (cond
     ((and (stringp name) (string-prefix-p harness-provider-claude-tool-prefix name))
      (harness-log 'warn "provider-claude: Claude Code denied %s for %s: %s"
                   name (harness-provider-claude-session-id entry) why)
      (harness-provider-claude--emit
       entry (list :type 'hint
                   :text (format (concat "Claude Code refused to run %s; its permission rules must let"
                                         " the harness's tools through (see the setting"
                                         " harness-provider-claude-permission-args).  It said: %s")
                                 (harness-provider-claude--strip-prefix name) why))))
     (builtin
      (harness-log 'warn "provider-claude: Claude Code denied its %s for %s: %s"
                   name (harness-provider-claude-session-id entry) why)
      (harness-provider-claude--emit
       entry (list :type 'hint
                   :text (format (concat "Claude Code refused to run its %s, which stands in for %s;"
                                         " its permission rules must leave the decision to the harness"
                                         " (see the setting harness-provider-claude-permission-args)."
                                         "  It said: %s")
                                 name builtin why)))))))

;;;; Account, billing and quota

(defun harness-provider-claude--compact (plist)
  "Return PLIST without the keys whose value is nil."
  (let (out)
    (cl-loop for (k v) on plist by #'cddr
             when v do (setq out (append out (list k v))))
    out))

(defun harness-provider-claude--time (value)
  "Return VALUE, epoch seconds or an ISO 8601 string, as a float time, or nil."
  (cond ((numberp value) (float value))
        ((and (stringp value) (not (string-empty-p value)))
         (condition-case nil (float-time (parse-iso8601-time-string value)) (error nil)))))

(defun harness-provider-claude--failure-kind (name)
  "Return the failure kind of the CLI's assistant error NAME, or nil.
`billing_error', `account_on_hold' and `credits_required' mean money is
out; `authentication_failed' a refused login; `rate_limit' a short
term limit, which a rejected usage window turns into a used-up quota."
  (pcase (and name (downcase (format "%s" name)))
    ((or "billing_error" "account_on_hold" "credits_required" "out_of_credits") 'billing)
    ("authentication_failed" 'auth)
    ((or "rate_limit" "rate_limit_error") 'rate-limit)
    (_ nil)))

(defun harness-provider-claude--event-reset (info)
  "Return when the quota window INFO rejected comes back, or nil."
  (or (harness-provider-claude--time (plist-get info :resetsAt))
      (let (best)
        (cl-loop for (_key win) on (plist-get info :unifiedWindows) by #'cddr
                 for used = (plist-get win :utilization)
                 for resets = (harness-provider-claude--time (plist-get win :resetsAt))
                 when (and resets (numberp used) (>= used 0.999))
                 do (setq best (if best (min best resets) resets)))
        best)))

(defun harness-provider-claude--note-failure (entry &rest fields)
  "Note FIELDS (:kind, :resets, :text) of the current turn's failure on ENTRY.
Later notes win; the note is what the turn's `done' event reports."
  (let* ((id (harness-provider-claude-session-id entry))
         (old (gethash id harness-provider-claude--turn-failure)))
    (puthash id (harness-plist-merge old fields) harness-provider-claude--turn-failure)))

(defun harness-provider-claude--failure-text (message)
  "Return the text blocks of an assistant MESSAGE, joined, or nil."
  (let ((text (string-join
               (delq nil (mapcar (lambda (block)
                                   (and (equal (plist-get block :type) "text")
                                        (plist-get block :text)))
                                 (plist-get message :content)))
               "\n")))
    (unless (string-empty-p (string-trim text)) text)))

(defun harness-provider-claude--plan-id (label)
  "Return the plan id of subscription LABEL (\"Claude Max\" gives \"max\"), or nil."
  (when (and (stringp label) (string-match "\\([[:alnum:]_]+\\)[[:space:]]*\\'" label))
    (let ((id (downcase (match-string 1 label))))
      ;; Old CLIs called every login "Claude API".
      (unless (member id '("api" "claude")) id))))

(defun harness-provider-claude--plan-label (plan)
  "Return the display name of subscription PLAN (\"max\" gives \"Claude Max\")."
  (when (and (stringp plan) (not (string-empty-p plan)))
    (concat "Claude " (capitalize (replace-regexp-in-string "_" " " plan)))))

(defun harness-provider-claude-account-info (account)
  "Classify ACCOUNT, the `account' plist of the CLI's initialize answer.
Return (:billing BILLING :plan ID :plan-label LABEL :auth SOURCE
:api-provider NAME :account (:email :organization)).  BILLING is
`subscription' for a claude.ai login (Pro, Max, Team, Enterprise),
`api' for an API key, an API key helper, a bearer token or a cloud
provider (Bedrock, Vertex, Foundry), and nil when the answer does
not say."
  (let* ((provider (plist-get account :apiProvider))
         (key (plist-get account :apiKeySource))
         (token (plist-get account :tokenSource))
         (label (plist-get account :subscriptionType))
         (email (plist-get account :email))
         (key (and (stringp key) (not (member key '("" "none"))) key))
         (cloud (and (stringp provider) (not (member provider '("" "firstParty"))) provider))
         (bearer (and (member token harness-provider-claude--api-token-sources) token))
         (billing (cond ((or cloud key bearer) 'api)
                        ((or (stringp label) (stringp email)
                             (equal token "CLAUDE_CODE_OAUTH_TOKEN"))
                         'subscription)))
         (subscription (eq billing 'subscription))
         (plan (and subscription (harness-provider-claude--plan-id label))))
    (list :billing billing
          :plan plan
          :plan-label (and plan label)
          :auth (or cloud key bearer
                    (and (stringp token) (not (member token '("" "none"))) token)
                    (and subscription "claude.ai"))
          :api-provider (and (stringp provider) provider)
          :account (and subscription (stringp email)
                        (harness-provider-claude--compact
                         (list :email email :organization (plist-get account :organization)))))))

(defun harness-provider-claude--window-name (key)
  "Return (NAME LABEL) of the rate-limit window KEY, a keyword or symbol."
  (let* ((name (string-remove-prefix ":" (format "%s" key)))
         (known (assq (intern name) harness-provider-claude--window-keys)))
    (if known (cdr known) (list name (replace-regexp-in-string "_" " " name)))))

(defun harness-provider-claude--limit-window (limit)
  "Convert LIMIT, one entry of a usage report's `limits', into a window plist."
  (let* ((kind (format "%s" (or (plist-get limit :kind) "limit")))
         (scope (plist-get limit :scope))
         (model (or (harness-plist-get-in scope '(:model :display_name))
                    (harness-plist-get-in scope '(:surface :display_name))))
         (percent (plist-get limit :percent)))
    (harness-provider-claude--compact
     (list :name (pcase kind
                   ("session" "5h")
                   ("weekly_all" "7d")
                   ("weekly_scoped" (if model (concat "7d " model) "7d scoped"))
                   (_ (if model (format "%s %s" kind model) kind)))
           :label (pcase kind
                    ("session" "Current session (5 hours)")
                    ("weekly_all" "This week, all models")
                    ("weekly_scoped" (concat "This week, " (or model "scoped")))
                    (_ (concat (replace-regexp-in-string "_" " " kind)
                               (if model (concat ", " model) ""))))
           :kind kind
           :model model
           :used (and (numberp percent) (/ percent 100.0))
           :resets (harness-provider-claude--time (plist-get limit :resets_at))
           :severity (plist-get limit :severity)
           :active (harness-json-true-p (plist-get limit :is_active))))))

(defun harness-provider-claude--usage-windows (rate-limits)
  "Return the quota windows a usage report's RATE-LIMITS describes.
Recent CLIs list them under `limits'; older ones only name each window."
  (let ((limits (plist-get rate-limits :limits)))
    (if (consp limits)
        (mapcar #'harness-provider-claude--limit-window limits)
      (let (out)
        (dolist (k harness-provider-claude--window-keys)
          (let ((w (plist-get rate-limits (intern (format ":%s" (car k))))))
            (when (and (consp w) (numberp (plist-get w :utilization)))
              (push (harness-provider-claude--compact
                     (list :name (nth 1 k) :label (nth 2 k)
                           :used (/ (plist-get w :utilization) 100.0)
                           :resets (harness-provider-claude--time (plist-get w :resets_at))))
                    out))))
        (dolist (m (plist-get rate-limits :model_scoped))
          (when (numberp (plist-get m :utilization))
            (let ((model (or (plist-get m :display_name) "model")))
              (push (harness-provider-claude--compact
                     (list :name (concat "7d " model) :label (concat "This week, " model)
                           :model model :used (/ (plist-get m :utilization) 100.0)
                           :resets (harness-provider-claude--time (plist-get m :resets_at))))
                    out))))
        (nreverse out)))))

(defun harness-provider-claude--money (amount)
  "Return AMOUNT, a (:amount_minor N :exponent E) plist, in major units, or nil."
  (let ((minor (plist-get amount :amount_minor)))
    (and (numberp minor) (/ minor (expt 10.0 (or (plist-get amount :exponent) 2))))))

(defun harness-provider-claude--extra (rate-limits)
  "Return the extra usage a usage report's RATE-LIMITS describes, or nil.
The result is (:enabled BOOL :used F :limit F :currency STRING
:disabled-reason STRING); extra usage is what a subscription draws on,
at API prices, once a window is used up."
  (let ((spend (plist-get rate-limits :spend))
        (extra (plist-get rate-limits :extra_usage)))
    (cond
     ((consp spend)
      (harness-provider-claude--compact
       (list :enabled (harness-json-true-p (plist-get spend :enabled))
             :used (harness-provider-claude--money (plist-get spend :used))
             :limit (harness-provider-claude--money (plist-get spend :limit))
             :currency (or (harness-plist-get-in spend '(:limit :currency))
                           (harness-plist-get-in spend '(:used :currency))
                           "USD")
             :disabled-reason (plist-get spend :disabled_reason))))
     ((consp extra)
      (let ((scale (expt 10.0 (or (plist-get extra :decimal_places) 2)))
            (used (plist-get extra :used_credits))
            (limit (plist-get extra :monthly_limit)))
        (harness-provider-claude--compact
         (list :enabled (harness-json-true-p (plist-get extra :is_enabled))
               :used (and (numberp used) (/ used scale))
               :limit (and (numberp limit) (/ limit scale))
               :currency (or (plist-get extra :currency) "USD")
               :disabled-reason (plist-get extra :disabled_reason))))))))

(defun harness-provider-claude--usage-changes (report)
  "Return the account status changes a get_usage REPORT implies, or nil."
  (when (or (plist-member report :rate_limits_available) (plist-member report :subscription_type))
    (let* ((status harness-provider-claude--status)
           (available (harness-json-true-p (plist-get report :rate_limits_available)))
           (rate-limits (plist-get report :rate_limits))
           (plan (plist-get report :subscription_type))
           (plan (and (stringp plan) (not (string-empty-p plan)) (downcase plan))))
      (append
       (list :updated (float-time) :available available
             :windows (and available (harness-provider-claude--usage-windows rate-limits))
             :extra (and available (harness-provider-claude--extra rate-limits)))
       (when plan
         (list :plan plan
               :plan-label (if (equal plan (plist-get status :plan))
                               (or (plist-get status :plan-label) (harness-provider-claude--plan-label plan))
                             (harness-provider-claude--plan-label plan))))
       ;; A plan with quota is a subscription even when the account said nothing.
       (when (and (null (plist-get status :billing)) (or plan available))
         (list :billing 'subscription))))))

(defun harness-provider-claude--windows (info)
  "Convert the `unifiedWindows' of a rate_limit_event INFO into window plists."
  (let (out)
    (cl-loop for (key win) on (plist-get info :unifiedWindows) by #'cddr
             do (pcase-let ((`(,name ,label) (harness-provider-claude--window-name key)))
                  (push (harness-provider-claude--compact
                         (list :name name :label label
                               :used (plist-get win :utilization)
                               :resets (harness-provider-claude--time (plist-get win :resetsAt))))
                        out)))
    (nreverse out)))

(defun harness-provider-claude--merge-windows (old new)
  "Return quota windows OLD updated with NEW ones, matched by name."
  (let ((name (lambda (w) (plist-get w :name))))
    (append (mapcar (lambda (w)
                      (let ((n (cl-find (plist-get w :name) new :key name :test #'equal)))
                        (if n (harness-plist-merge w n) w)))
                    old)
            (cl-remove-if (lambda (n) (cl-find (plist-get n :name) old :key name :test #'equal))
                          new))))

(defun harness-provider-claude--publish (changes)
  "Merge CHANGES into the account status, announce it, and return it."
  (let* ((old harness-provider-claude--status)
         (new (harness-plist-merge old changes)))
    (setq harness-provider-claude--status new)
    (unless (equal old new)
      (harness-emit 'provider/quota-updated 'claude new))
    new))

(defun harness-provider-claude--request-usage (entry)
  "Ask ENTRY's CLI for a usage report; return the request id."
  (let ((id (format "usage-%d" (cl-incf harness-provider-claude--request-count))))
    (setq harness-provider-claude--asked (float-time))
    (harness-provider-claude--send
     entry (list :type "control_request" :request_id id
                 :request '(:subtype "get_usage" :skip_behaviors t)))
    id))

(defun harness-provider-claude--handle-account (entry account)
  "Remember how ENTRY's process is billed, from its ACCOUNT plist."
  (let ((info (harness-provider-claude-account-info account)))
    (setf (harness-provider-claude-session-account entry) info)
    (harness-log 'info "provider-claude: %s bills %s%s"
                 (harness-provider-claude-session-id entry)
                 (pcase (plist-get info :billing)
                   ('subscription "through a subscription")
                   ('api (format "per token (%s)" (or (plist-get info :auth) "API")))
                   (_ "in a way the CLI did not say"))
                 (if (plist-get info :plan-label) (format " (%s)" (plist-get info :plan-label)) ""))
    (harness-provider-claude--publish
     (if (eq (plist-get info :billing) 'api)
         ;; Plan quota does not apply to per-token billing.
         (append info '(:available nil :windows nil :extra nil :limit-status nil :using-extra nil))
       (harness-provider-claude--compact info)))))

(defun harness-provider-claude--handle-usage (entry id report error)
  "Handle the usage REPORT (nil after ERROR) answering request ID on ENTRY."
  (when (equal id (harness-provider-claude-session-baseline-id entry))
    (setf (harness-provider-claude-session-baseline-id entry) nil)
    ;; The process's running cost total starts here, unless the CLI has
    ;; already answered, in which case the total may include a turn.
    (let ((total (harness-plist-get-in report '(:session :total_cost_usd))))
      (when (and (numberp total) (not (harness-provider-claude-session-seen-output entry)))
        (setf (harness-provider-claude-session-cost-total entry) (float total)))))
  ;; The session's spend per model may say the windows the CLI ran
  ;; them with, from turns before this process too.
  (condition-case err
      (harness-provider-claude--note-model-usage
       entry (or (harness-plist-get-in report '(:session :model_usage))
                 (harness-plist-get-in report '(:session :modelUsage)))
       t)
    (error (harness-log 'debug "provider-claude: cannot read the report's model usage: %s"
                        (harness-error-message err))))
  (if error
      (harness-log 'debug "provider-claude: usage report failed: %s" error)
    (when-let* ((changes (harness-provider-claude--usage-changes report)))
      (when-let* ((windows (plist-get (harness-provider-claude--publish changes) :windows)))
        (harness-provider-claude--emit entry (list :type 'quota :windows windows)))))
  (harness-provider-claude--settle-refresh)
  (when (harness-provider-claude-session-probe entry)
    (harness-provider-claude--end-probe entry)))

(defun harness-provider-claude--handle-rate-limit (entry info)
  "Fold the rate_limit_event INFO into the account status and ENTRY's turn.
A rejected window is a used-up quota, and tells the turn when it comes
back; the CLI's error code says when it is money that ran out."
  (let ((status (harness-provider-claude--publish
                 (list :windows (harness-provider-claude--merge-windows
                                 (plist-get harness-provider-claude--status :windows)
                                 (harness-provider-claude--windows info))
                       :limit-status (plist-get info :status)
                       :using-extra (harness-json-true-p (plist-get info :isUsingOverage))))))
    (when (equal (plist-get info :status) "rejected")
      (harness-provider-claude--note-failure
       entry
       :kind (let ((code (downcase (format "%s" (or (plist-get info :errorCode) "")))))
               (if (member code '("credits_required" "out_of_credits" "billing_error"))
                   'billing
                 'quota))
       :resets (harness-provider-claude--event-reset info)))
    (when-let* ((windows (plist-get status :windows)))
      (harness-provider-claude--emit entry (list :type 'quota :windows windows)))))

(defun harness-provider-claude--handle-response (entry msg)
  "Handle the CLI's answer MSG to one of our control requests on ENTRY."
  (let* ((response (plist-get msg :response))
         (id (plist-get response :request_id))
         (ok (equal (plist-get response :subtype) "success"))
         (payload (plist-get response :response)))
    (cond
     ((equal id "init-1")
      (harness-provider-claude--handle-initialized entry ok payload))
     ((and (stringp id) (string-prefix-p "usage-" id))
      (harness-provider-claude--handle-usage entry id (and ok payload)
                                             (unless ok (or (plist-get response :error) "failed"))))
     (t (harness-log 'debug "provider-claude: control_response %S" response)))))

(defun harness-provider-claude--turn-cost (entry msg)
  "Return the API-price cost of the turn that result MSG ends on ENTRY, or nil.
The CLI reports a running total for its process, so the turn costs the
difference to the total before it; a total below that one means the
CLI started counting again.  Nil when the starting total is unknown, so
the turn is priced from the model catalogue instead."
  (let ((total (plist-get msg :total_cost_usd))
        (base (harness-provider-claude-session-cost-total entry)))
    (when (numberp total)
      (setf (harness-provider-claude-session-cost-total entry) (float total)))
    (cond ((not (numberp total)) nil)
          ((null base) nil)
          ((>= total base) (- total base))
          (t (float total)))))

(defun harness-provider-claude--billing-fields (entry cost)
  "Return the billing part of a usage event on ENTRY whose API price is COST."
  (let* ((status harness-provider-claude--status)
         (info (or (harness-provider-claude-session-account entry) status))
         (billing (plist-get info :billing))
         (plan (or (plist-get status :plan) (plist-get info :plan))))
    (pcase billing
      ('subscription
       (if (plist-get status :using-extra)
           (list :billing 'extra-usage :plan plan :cost cost :list-cost cost)
         (list :billing 'subscription :plan plan :cost 0.0 :list-cost cost)))
      (_ (list :billing billing :cost cost :list-cost cost)))))

(defun harness-provider-claude--stale-p ()
  "Non-nil when the account status should be fetched again.
Asking counts like an answer, so a CLI that cannot report usage is not
asked again before `harness-provider-claude--quota-ttl' has passed."
  (let* ((status harness-provider-claude--status)
         (last (max (or (plist-get status :updated) 0) (or harness-provider-claude--asked 0))))
    (cond ((zerop last) t)
          ((eq (plist-get status :billing) 'api) nil)
          ((null harness-provider-claude--quota-ttl) nil)
          (t (> (- (float-time) last) harness-provider-claude--quota-ttl)))))

(defun harness-provider-claude--live-entry ()
  "Return a session record with a live CLI process, idle ones first, or nil."
  (let (best)
    (maphash (lambda (_ e)
               (when (and (process-live-p (harness-provider-claude-session-process e))
                          (or (null best)
                              (and (harness-provider-claude-session-active best)
                                   (not (harness-provider-claude-session-active e)))))
                 (setq best e)))
             harness-provider-claude--sessions)
    best))

(defun harness-provider-claude--settle-refresh ()
  "Resolve the usage request in flight with what is known now."
  (when-let* ((refresh harness-provider-claude--refresh))
    (setq harness-provider-claude--refresh nil)
    (cancel-timer (nth 2 refresh))
    (harness-resolve (nth 1 refresh) harness-provider-claude--status)))

(defun harness-provider-claude--refresh (&optional entry)
  "Fetch a fresh usage report; return a promise of the account status.
ENTRY's process asks when it is alive, else any live process, else a
probe started for the purpose.  The promise resolves with what is known
once the report arrives, or after `harness-provider-claude--probe-timeout'."
  (if harness-provider-claude--refresh
      (nth 1 harness-provider-claude--refresh)
    (let ((promise (harness-make-promise)))
      (condition-case err
          (let* ((asker (or (and entry (process-live-p (harness-provider-claude-session-process entry)) entry)
                            (harness-provider-claude--live-entry)
                            (harness-provider-claude--start-probe)))
                 (id (harness-provider-claude--request-usage asker)))
            (setq harness-provider-claude--refresh
                  (list id promise (run-at-time harness-provider-claude--probe-timeout nil
                                                #'harness-provider-claude--settle-refresh))))
        (error
         (harness-log 'warn "provider-claude: cannot ask for usage: %s" (harness-error-message err))
         (harness-resolve promise harness-provider-claude--status)))
      promise)))

(defun harness-provider-claude--start-probe ()
  "Return the quota probe, starting a CLI process that only answers reports.
The probe sends no message, so it makes no model call; it exits once
its usage report has arrived."
  (if (and harness-provider-claude--probe
           (process-live-p (harness-provider-claude-session-process harness-provider-claude--probe)))
      harness-provider-claude--probe
    (let* ((entry (harness-provider-claude--make-session :id "quota-probe" :probe t))
           (default-directory (file-name-as-directory (expand-file-name temporary-file-directory)))
           (process-environment (harness-provider-claude--environment))
           (stderr (generate-new-buffer " *harness-claude-probe-stderr*" t))
           (proc (condition-case err
                     (make-process :name "harness-claude-probe"
                                   :command (append (list harness-provider-claude-program
                                                          "-p" "--input-format" "stream-json"
                                                          "--output-format" "stream-json" "--verbose"
                                                          "--tools" "" "--strict-mcp-config")
                                                    harness-provider-claude-extra-args)
                                   :coding '(utf-8 . utf-8)
                                   :connection-type 'pipe
                                   :noquery t
                                   :stderr stderr
                                   :filter (lambda (_p chunk) (harness-provider-claude--filter entry chunk))
                                   :sentinel (lambda (p _e) (harness-provider-claude--probe-sentinel entry p)))
                   (error (kill-buffer stderr) (signal (car err) (cdr err))))))
      (when-let* ((ep (get-buffer-process stderr)))
        (set-process-query-on-exit-flag ep nil)
        (set-process-sentinel ep #'ignore))
      (setf (harness-provider-claude-session-process entry) proc
            (harness-provider-claude-session-stderr entry) stderr)
      (setq harness-provider-claude--probe entry)
      (harness-log 'info "provider-claude: probing the account and its quota")
      (harness-provider-claude--send
       entry '(:type "control_request" :request_id "init-1" :request (:subtype "initialize")))
      (run-at-time (+ 5 harness-provider-claude--probe-timeout) nil
                   #'harness-provider-claude--end-probe entry t)
      entry)))

(defun harness-provider-claude--end-probe (entry &optional kill)
  "Let the probe ENTRY exit by closing its input, or KILL it.
It is no longer the probe: whoever needs one next starts another."
  (when (eq harness-provider-claude--probe entry)
    (setq harness-provider-claude--probe nil))
  (let ((proc (harness-provider-claude-session-process entry)))
    (when (process-live-p proc)
      (if kill (delete-process proc) (process-send-eof proc)))))

(defun harness-provider-claude--probe-sentinel (entry proc)
  "Clean up after the probe ENTRY once its process PROC has ended."
  (unless (process-live-p proc)
    (unless (zerop (process-exit-status proc))
      (harness-log 'warn "provider-claude: the quota probe exited with status %s%s"
                   (process-exit-status proc)
                   (let ((tail (harness-provider-claude--stderr-tail entry)))
                     (if (string-empty-p tail) "" (concat ": " (harness-truncate-end tail 300))))))
    (let ((buf (harness-provider-claude-session-stderr entry)))
      (when (buffer-live-p buf) (kill-buffer buf)))
    (when (eq harness-provider-claude--probe entry)
      (setq harness-provider-claude--probe nil))
    (harness-provider-claude--settle-refresh)
    (harness-provider-claude--settle-listing-waiters)))

(defun harness-provider-claude--handle-init (entry msg)
  "Handle the system/init banner MSG on ENTRY."
  (let ((id (plist-get msg :session_id))
        (model (plist-get msg :model)))
    (setf (harness-provider-claude-session-cli-session-id entry) id
          (harness-provider-claude-session-model entry) model)
    (when-let* ((spawn (gethash (harness-provider-claude-session-id entry) harness-provider-claude--spawns)))
      (plist-put spawn :started t))
    (harness-log 'info "provider-claude: session %s is CLI session %s (%s)"
                 (harness-provider-claude-session-id entry) id model)
    ;; CLIs whose initialize answer has no account still name an API key here.
    (let ((key (plist-get msg :apiKeySource)))
      (when (and (null (harness-provider-claude-session-account entry))
                 (stringp key) (not (member key '("" "none"))))
        (harness-provider-claude--handle-account entry (list :apiKeySource key))))
    (harness-provider-claude--emit
     entry (list :type 'provider-state :state (list :cli-session-id id :model model)))
    (dolist (server (plist-get msg :mcp_servers))
      (when (and (equal (plist-get server :name) "harness")
                 (not (equal (plist-get server :status) "connected")))
        (harness-log 'error "provider-claude: harness MCP server status %s"
                     (plist-get server :status))
        (harness-provider-claude--emit
         entry (list :type 'hint
                     :text (format "Claude Code reports the harness tool server as %s; tools are unavailable this turn"
                                   (plist-get server :status))))))
    ;; A tools/list answer the CLI refuses, a schema it finds invalid say,
    ;; leaves the server connected but the model with none of its tools.
    (when (and (plist-get (harness-provider-claude-session-request entry) :tools)
               (not (cl-some (lambda (tool)
                               (and (stringp tool)
                                    (string-prefix-p harness-provider-claude-tool-prefix tool)))
                             (plist-get msg :tools))))
      (harness-log 'error "provider-claude: Claude Code offers none of the harness tools to %s"
                   (harness-provider-claude-session-id entry))
      (harness-provider-claude--emit
       entry (list :type 'hint
                   :text "Claude Code refused the harness's tool list; tools are unavailable this turn")))))

(defun harness-provider-claude--handle-result (entry msg)
  "Handle the turn-ending result MSG on ENTRY."
  (let* ((usage (plist-get msg :usage))
         (input (or (plist-get usage :input_tokens) 0))
         (cache-read (or (plist-get usage :cache_read_input_tokens) 0))
         (cache-write (or (plist-get usage :cache_creation_input_tokens) 0))
         (subtype (or (plist-get msg :subtype) ""))
         (is-error (or (harness-json-true-p (plist-get msg :is_error))
                       (string-prefix-p "error" subtype))))
    (when-let* ((id (plist-get msg :session_id)))
      (unless (equal id (harness-provider-claude-session-cli-session-id entry))
        (setf (harness-provider-claude-session-cli-session-id entry) id)
        ;; The session follows, or its next turn would resume the old one.
        (harness-provider-claude--emit
         entry (list :type 'provider-state
                     :state (list :cli-session-id id :model (harness-provider-claude-session-model entry))))))
    (setf (harness-provider-claude-session-seen-output entry) t)
    ;; The windows the CLI ran its models with: the catalogue learns
    ;; them, and the sessions' windows follow.
    (condition-case err
        (harness-provider-claude--note-model-usage entry (plist-get msg :modelUsage))
      (error (harness-log 'warn "provider-claude: cannot read the result's model usage: %s"
                          (harness-error-message err))))
    (harness-provider-claude--emit
     entry (append (list :type 'usage :input input
                         :output (or (plist-get usage :output_tokens) 0)
                         :cache-read cache-read :cache-write cache-write
                         :context (or (harness-provider-claude-session-context entry)
                                      (+ input cache-read cache-write)))
                   (harness-provider-claude--billing-fields
                    entry (harness-provider-claude--turn-cost entry msg))))
    (when (harness-provider-claude--stale-p)
      (harness-provider-claude--refresh entry))
    (harness-provider-claude--finish
     entry
     (cond ((harness-provider-claude-session-cancelled entry)
            '(:type done :stop-reason cancelled))
           (is-error
            (let* ((failure (gethash (harness-provider-claude-session-id entry)
                                     harness-provider-claude--turn-failure))
                   (api-status (plist-get msg :api_error_status))
                   (kind (or (and (equal api-status 402) 'billing)
                             (and (member api-status '(401 403)) 'auth)
                             (and (equal api-status 429)
                                  (if (memq (plist-get failure :kind) '(quota billing))
                                      (plist-get failure :kind)
                                    'rate-limit))
                             (plist-get failure :kind))))
              (append (list :type 'done :stop-reason 'error
                            :error (let ((text (plist-get msg :result)))
                                     (if (and (stringp text) (not (string-empty-p text)))
                                         text
                                       (or (plist-get failure :text)
                                           (format "Claude Code: %s" subtype)))))
                      (when kind (list :error-kind kind))
                      (when-let* ((resets (plist-get failure :resets)))
                        (list :resets resets)))))
           ((equal (plist-get msg :stop_reason) "max_tokens")
            '(:type done :stop-reason max-tokens))
           (t '(:type done :stop-reason end-turn))))))

(defun harness-provider-claude--handle (entry msg)
  "Dispatch one parsed stdout MSG from the CLI on ENTRY."
  (let ((type (plist-get msg :type)))
    (pcase type
      ("control_request" (harness-provider-claude--handle-control entry msg))
      ("control_response" (harness-provider-claude--handle-response entry msg))
      ("system"
       (pcase (plist-get msg :subtype)
         ("init" (harness-provider-claude--handle-init entry msg))
         ("permission_denied" (harness-provider-claude--handle-denial entry msg))
         ;; Compacting takes a while and streams nothing; a null status
         ;; ends it and the CLI waits for the model again.
         ("status"
          (let ((status (plist-get msg :status)))
            (cond ((equal status "compacting")
                   (harness-provider-claude--emit entry '(:type activity :phase compacting)))
                  ((null status)
                   (harness-provider-claude--emit entry '(:type activity :phase waiting)))
                  (t (harness-log 'debug "provider-claude: status %s" status)))))
         ("compact_boundary"
          (harness-provider-claude--emit
           entry '(:type hint :text "Context compacted by Claude Code")))
         (sub (harness-log 'debug "provider-claude: system/%s" sub))))
      ("stream_event" (harness-provider-claude--handle-stream entry (plist-get msg :event)
                                                               (plist-get msg :parent_tool_use_id)))
      ("assistant"
       (setf (harness-provider-claude-session-seen-output entry) t)
       (harness-provider-claude--handle-assistant entry (plist-get msg :message)
                                                  (harness-provider-claude--checkpoint entry msg)))
      ("user" (harness-provider-claude--handle-user-echo entry (plist-get msg :message)
                                                         (harness-provider-claude--checkpoint entry msg)))
      ("rate_limit_event"
       (harness-provider-claude--handle-rate-limit entry (plist-get msg :rate_limit_info)))
      ("result" (harness-provider-claude--handle-result entry msg))
      (_ (harness-log 'debug "provider-claude: ignoring %s message" type)))))

(defun harness-provider-claude--filter (entry chunk)
  "Buffer CHUNK of stdout for ENTRY and handle every complete line."
  (let ((data (concat (harness-provider-claude-session-buffer entry) chunk))
        (start 0) pos)
    (while (setq pos (string-search "\n" data start))
      (let ((line (substring data start pos)))
        (setq start (1+ pos))
        (unless (harness-string-blank-p line)
          (condition-case err
              (let ((msg (harness-json-parse line)))
                (when msg (harness-provider-claude--handle entry msg)))
            (error (harness-log 'error "provider-claude: bad line %s: %S"
                                (harness-truncate-end line 200) err))))))
    (setf (harness-provider-claude-session-buffer entry) (substring data start))))

(defun harness-provider-claude--sentinel (entry proc _event)
  "Handle the death of ENTRY's process PROC.
A process told to resume or fork a CLI session that exits during a
turn before it started could not open that conversation (the CLI
session is gone, or a cut before the CLI compacted it): the turn goes
on in a new CLI session instead (`harness-provider-claude--restart-fresh')."
  (unless (process-live-p proc)
    (when (eq proc (harness-provider-claude-session-process entry))
      (let ((code (process-exit-status proc))
            (tail (harness-provider-claude--stderr-tail entry))
            (spawn (gethash (harness-provider-claude-session-id entry) harness-provider-claude--spawns)))
        (harness-log 'info "provider-claude: process for %s exited %s"
                     (harness-provider-claude-session-id entry) code)
        (let ((buf (harness-provider-claude-session-stderr entry)))
          (when (buffer-live-p buf) (kill-buffer buf)))
        (setf (harness-provider-claude-session-stderr entry) nil)
        (if (and (harness-provider-claude-session-active entry)
                 (not (harness-provider-claude-session-cancelled entry))
                 (plist-get spawn :resume)
                 (not (plist-get spawn :started)))
            (harness-provider-claude--restart-fresh entry spawn code tail)
          (harness-provider-claude--finish
           entry
           (if (harness-provider-claude-session-cancelled entry)
               '(:type done :stop-reason cancelled)
             (list :type 'done :stop-reason 'error
                   :error (format "claude exited with status %s%s" code
                                  (if (string-empty-p tail) "" (concat ": " tail)))))))))))

(defun harness-provider-claude--with-history (request blocks)
  "Return BLOCKS, the new message of REQUEST, after the transcript before it.
A new CLI session knows nothing of the conversation REQUEST continues;
the transcript (`harness-provider-history-text') tells it.  A request
with nothing before its new message gets BLOCKS as they are."
  (let ((text (harness-provider-history-text
               (car (harness-provider-split-history (plist-get request :messages))))))
    (if text (cons (list :type "text" :text text) blocks) blocks)))

(defun harness-provider-claude--restart-fresh (entry spawn code tail)
  "Carry the turn of ENTRY on in a new CLI session; its process could not resume.
SPAWN says how the process that exited with CODE was started and what
the turn sent it, TAIL is the end of its stderr.  The new CLI session
gets the turn's message again, after the transcript."
  (let ((request (harness-provider-claude-session-request entry))
        (why (if (string-empty-p tail) (format "exit status %s" code)
               (harness-truncate-end (harness-first-line tail) 200))))
    (harness-log 'warn "provider-claude: %s could not resume CLI session %s (%s); starting a new one"
                 (harness-provider-claude-session-id entry) (plist-get spawn :resume) why)
    (harness-provider-claude--emit
     entry (list :type 'hint
                 :text (format "Claude Code could not resume its conversation (%s); this turn goes on in a new one, which gets the transcript"
                               why)))
    (setf (harness-provider-claude-session-cli-session-id entry) nil)
    (harness-provider-claude--spawn entry request nil nil)
    (harness-provider-claude--send-user
     entry (harness-provider-claude--with-history request (plist-get spawn :blocks)))))

;;;; Provider entry points

(defun harness-provider-claude--entry (session-id)
  "Return the process record for SESSION-ID, creating it when needed."
  (or (gethash session-id harness-provider-claude--sessions)
      (puthash session-id (harness-provider-claude--make-session :id session-id)
               harness-provider-claude--sessions)))

(defun harness-provider-claude--ensure-process (entry request)
  "Make sure ENTRY has a live process suitable for REQUEST, spawning if needed.
Return `live' when the running process serves REQUEST, else how the
one started for it opens its conversation: `fresh', `resume' or
`fork'.  The running process serves REQUEST when it was started with
the settings REQUEST needs (`harness-provider-claude--spawn-key') and
is in the CLI session REQUEST asks for: the one its session's record
names -- none, when that record's state was dropped, which starts a new
CLI session -- or, for a request without a session record (the
permission judge, tests), the one the entry last held.  A state marked
`:fork-pending' always gets a new process, which forks the CLI session
it names, cut at its `:resume-at' when it has one."
  (let* ((state (plist-get request :provider-state))
         (session (plist-get request :session))
         (recorded (plist-member session :provider-state))
         (key (harness-provider-claude--spawn-key request))
         (proc (harness-provider-claude-session-process entry))
         (live (process-live-p proc))
         (have (harness-provider-claude-session-cli-session-id entry))
         ;; The CLI session the request asks for: the one its provider state
         ;; names.  A request that brings its session's record stays there, and
         ;; no other: one whose record's state was dropped, because the session
         ;; went on with another provider, starts a new CLI session rather than
         ;; carry on a stale one.  Without a session record (the permission
         ;; judge, provider tests) the entry's own session serves.
         (stated (plist-get state :cli-session-id))
         (want (cond (stated stated) (recorded nil) (t have)))
         (fork (and stated (harness-json-true-p (plist-get state :fork-pending)))))
    (if (and live (not fork)
             (equal key (harness-provider-claude-session-spawn-key entry))
             (equal want have))
        'live
      (let ((resume want))
        (when live
          (harness-log 'info "provider-claude: %s for %s; restarting%s"
                       (if fork "forking" "settings or conversation changed")
                       (harness-provider-claude-session-id entry)
                       (if resume (format " with --resume %s" resume) "")))
        (harness-provider-claude--kill entry)
        (harness-provider-claude--spawn entry request resume fork (and fork (plist-get state :resume-at)))
        (cond (fork 'fork) (resume 'resume) (t 'fresh))))))

(defun harness-provider-claude--side-request-p (request)
  "Non-nil when REQUEST is a one-off request beside its session's conversation.
Its provider state is not the one its session has recorded: naming
brings a fork of it, a summary none.  Such a request runs in a CLI
process of its own, so that it neither writes into the session's CLI
session nor restarts the session's process with its own settings.  A
request for a session record without a recorded state, as the
permission judge makes, is none: it has its own process already."
  (let ((session (plist-get request :session)))
    (and (plist-member session :provider-state)
         (not (equal (plist-get request :provider-state) (plist-get session :provider-state))))))

(defun harness-provider-claude--closing (id on-event)
  "Return ON-EVENT wrapped so that the CLI process ID is closed when done."
  (lambda (event)
    (unwind-protect
        (when on-event (funcall on-event event))
      (when (eq (plist-get event :type) 'done)
        (harness-run-soon #'harness-provider-claude-close id)))))

(defun harness-provider-claude--complete (request)
  "Run REQUEST through the Claude Code CLI; return a handle with `:cancel'.
A new CLI session opened for a transcript that has messages before the
new one gets them first, as text (`harness-provider-claude--with-history')."
  (let* ((session (plist-get request :session))
         (sid (or (plist-get session :id) "default"))
         (side (harness-provider-claude--side-request-p request))
         (id (if side (format "%s#side-%d" sid (cl-incf harness-provider-claude--side-count)) sid))
         (entry (harness-provider-claude--entry id))
         (on-event (if side
                       (harness-provider-claude--closing id (plist-get request :on-event))
                     (plist-get request :on-event)))
         (blocks (harness-provider-claude--user-blocks request))
         (mode nil))
    (when (harness-provider-claude-session-active entry)
      (harness-provider-claude--finish
       entry '(:type done :stop-reason error :error "superseded by a new request")))
    ;; Kept after the turn, for a CLI that lists the tools between turns.
    (setf (harness-provider-claude-session-tools entry) (plist-get request :tools))
    (setq mode (harness-provider-claude--ensure-process entry request))
    (setf (harness-provider-claude-session-request entry) request
          (harness-provider-claude-session-on-event entry) on-event
          (harness-provider-claude-session-active entry) t
          (harness-provider-claude-session-cancelled entry) nil
          (harness-provider-claude-session-cancel-timer entry) nil
          (harness-provider-claude-session-pending-tools entry) nil
          (harness-provider-claude-session-own-results entry) nil
          (harness-provider-claude-session-context entry) nil)
    (remhash id harness-provider-claude--builtin-calls)
    (remhash id harness-provider-claude--call-checkpoints)
    (harness-provider-claude--emit entry '(:type start))
    (if (null blocks)
        (harness-provider-claude--finish
         entry '(:type done :stop-reason error :error "No user message to send"))
      ;; Kept for a process that cannot resume, which a new one replaces.
      (when-let* ((spawn (and (memq mode '(resume fork)) (gethash id harness-provider-claude--spawns))))
        (plist-put spawn :blocks blocks))
      (harness-provider-claude--send-user
       entry (if (eq mode 'fresh) (harness-provider-claude--with-history request blocks) blocks)))
    (list :cancel (lambda () (harness-provider-claude--cancel entry)))))

(defun harness-provider-claude--warm (request)
  "Start the CLI process that REQUEST's session will use; non-nil if started.
Spawning the CLI is most of the wait of a short request, so a request
expected soon (the next search of a task board, say) has its process
started ahead, with the settings it will come with.  A session running
a turn is left alone, and so is a live process with those settings."
  (let* ((sid (or (plist-get (plist-get request :session) :id) "default"))
         (entry (harness-provider-claude--entry sid))
         (proc (harness-provider-claude-session-process entry)))
    (unless (or (harness-provider-claude-session-active entry)
                (and (process-live-p proc)
                     (equal (harness-provider-claude--spawn-key request)
                            (harness-provider-claude-session-spawn-key entry))))
      (harness-provider-claude--ensure-process entry request)
      t)))

(defun harness-provider-claude--cancel (entry)
  "Interrupt the current turn on ENTRY, killing the process if it ignores us."
  (when (and (harness-provider-claude-session-active entry)
             (not (harness-provider-claude-session-cancelled entry)))
    (setf (harness-provider-claude-session-cancelled entry) t)
    (if (not (process-live-p (harness-provider-claude-session-process entry)))
        (harness-provider-claude--finish entry '(:type done :stop-reason cancelled))
      (harness-provider-claude--send
       entry (list :type "control_request" :request_id (harness-uuid)
                   :request '(:subtype "interrupt")))
      (setf (harness-provider-claude-session-cancel-timer entry)
            (run-at-time harness-provider-claude--interrupt-timeout nil
                         #'harness-provider-claude--force-cancel entry)))))

(defun harness-provider-claude--force-cancel (entry)
  "Kill ENTRY's process because an interrupt went unanswered."
  (when (harness-provider-claude-session-active entry)
    (harness-log 'warn "provider-claude: interrupt ignored for %s; killing the process"
                 (harness-provider-claude-session-id entry))
    (harness-provider-claude--kill entry)
    (harness-provider-claude--finish entry '(:type done :stop-reason cancelled))))

(defun harness-provider-claude--fork (_model-id state &optional checkpoint)
  "Return a promise of provider state for a fork of STATE.
The child starts from the parent's CLI session id; its first turn
resumes it with --fork-session so the cached prefix is reused.  With
CHECKPOINT, one this provider put on a node (see
`harness-provider-claude--checkpoint'), the fork is of the CLI session
the checkpoint names, cut at its entry: the first turn adds
--resume-session-at, which keeps the chain up to and including that
entry, so the fork knows nothing that came after.  Another provider's
checkpoint gives nil."
  (if checkpoint
      (let ((id (plist-get checkpoint :cli-session-id))
            (uuid (plist-get checkpoint :uuid)))
        (harness-resolved (and (stringp id) (stringp uuid)
                               (list :cli-session-id id :resume-at uuid :fork-pending t))))
    (let ((id (plist-get state :cli-session-id)))
      (harness-resolved (and id (list :cli-session-id id :fork-pending t))))))

(defun harness-provider-claude--quota (&optional refresh)
  "Return a promise of how the account is billed and of its plan quota.
The shape is the one `provider/quota' documents.  A new usage report is
fetched first when REFRESH is non-nil or the last one is stale (see
`harness-provider-claude--quota-ttl'); it makes no model call."
  (if (or refresh (harness-provider-claude--stale-p))
      (harness-provider-claude--refresh)
    (harness-resolved harness-provider-claude--status)))

;;;; Model catalogue
;;
;; The models are what the CLI says they are.  Every `initialize'
;; answer -- each new process's, the quota probe's, and a probe's
;; started when a refresh asks -- lists the models its /model picker
;; offers: aliases such as "opus" and "sonnet[1m]", their labels and
;; effort levels and, from Claude Code 2.1.197 on, the model each one
;; resolves to.  Every result's `modelUsage' says the context window
;; the CLI ran each model with, and the name the process was started
;; with (an alias, say) takes the window of the model its banner names.
;; With an Anthropic API key (`harness-provider-claude-api-key'), GET
;; /v1/models adds every model the API serves, with its window, output
;; limit and effort levels.  What was learned is kept in
;; claude-models.json in the state directory, so the harness knows it
;; from its next start on; `harness-provider-claude-models' is only
;; what is known before anything was learned, and gives the prices.  A
;; name nothing lists gets what `harness-provider-claude--resolve' makes
;; of it, else the catalogue's estimate (see `provider/model').

(defcustom harness-provider-claude-api-key nil
  "Anthropic API key the Claude provider lists the API's models with.
Nil takes the ANTHROPIC_API_KEY environment variable, else auth-source's
entry for api.anthropic.com with user \"apikey\"; `none' lists nothing
from the API.  With a key, GET /v1/models adds every model the API
serves and the window of each to the catalogue; without one it comes
from the CLI alone.  The key only lists models: the CLI signs in with
its own credentials."
  :type '(choice (const :tag "From ANTHROPIC_API_KEY or auth-source" nil)
                 (const :tag "None: the CLI alone lists the models" none)
                 (string :tag "Key"))
  :group 'harness)

(defvar harness-provider-claude--api-base nil
  "Root URL of the Anthropic API the models are listed from.
Nil is ANTHROPIC_BASE_URL when set, as the CLI uses it, else
https://api.anthropic.com.")

(defconst harness-provider-claude--api-models-ttl 3600
  "Seconds the Anthropic API's model listing stays fresh.")

(defconst harness-provider-claude--listed-lately 60
  "Seconds within which a CLI's model listing counts as current.
A refresh asks a probe for the listing only when no CLI process gave
one this recently.")

(defconst harness-provider-claude--one-million 1000000
  "Context window of a model the CLI runs with \"[1m]\" after its name.")

(defconst harness-provider-claude--efforts '("low" "medium" "high" "xhigh" "max")
  "Effort levels of Claude models, lowest first.")

(defvar harness-provider-claude--listing 'unread
  "What the CLI and the API said about the Claude models, as a plist.
`:cli-models' are the `models' of the CLI's last `initialize' answer,
and `:cli-at' when they came; `:api-models' are the entries of the
API's /v1/models, and `:api-at' when they came; `:windows' are the
windows results reported, each (:name NAME :context-window N
:max-output N); `:aliases' the models the CLI ran when started with a
name, each (:name NAME :model MODEL).  The symbol `unread' until it is
read from `harness-provider-claude--listing-file'.")

(defvar harness-provider-claude--cli-answered nil
  "When a CLI last answered `initialize', as a float time.")

(defvar harness-provider-claude--probe-answered nil
  "The quota probe whose `initialize' answer has arrived, or nil.")

(defvar harness-provider-claude--listing-waiters nil
  "Promises to resolve once a CLI next answers `initialize', or gives up.")

(defvar harness-provider-claude--api-asked nil
  "When the API's models were last asked for, as a float time.")

(defvar harness-provider-claude--api-fetch nil
  "The promise of the API listing in flight, or nil.")

(defvar harness-provider-claude--relist-pending nil
  "Non-nil while the catalogue is due to be listed again.")

(defun harness-provider-claude--listing-file ()
  "Return the file the learned model listing is kept in, or nil."
  (and (boundp 'harness-state-directory) (stringp harness-state-directory)
       (expand-file-name "claude-models.json" harness-state-directory)))

(defun harness-provider-claude--listing ()
  "Return the learned model listing, read from its file the first time."
  (when (eq harness-provider-claude--listing 'unread)
    (setq harness-provider-claude--listing
          (let ((file (harness-provider-claude--listing-file)))
            (and file (file-readable-p file)
                 (condition-case err
                     (let ((data (harness-json-parse (harness-read-file file))))
                       (and (consp data) (keywordp (car data)) (eql 1 (plist-get data :version))
                            data))
                   (error (harness-log 'warn "provider-claude: cannot read %s: %s"
                                       file (harness-error-message err))
                          nil))))))
  harness-provider-claude--listing)

(defun harness-provider-claude--save-listing ()
  "Write the learned model listing to its file; a failure is logged."
  (when-let* ((file (harness-provider-claude--listing-file)))
    (condition-case err
        (harness-write-file-atomically file (harness-json-encode harness-provider-claude--listing))
      (error (harness-log 'warn "provider-claude: cannot save %s: %s" file (harness-error-message err))))))

(defun harness-provider-claude--forget-listing ()
  "Forget what the CLI and the API listed, on disk too."
  (setq harness-provider-claude--listing nil
        harness-provider-claude--cli-answered nil
        harness-provider-claude--probe-answered nil
        harness-provider-claude--api-asked nil
        harness-provider-claude--api-fetch nil)
  (when-let* ((file (harness-provider-claude--listing-file)))
    (when (file-exists-p file) (delete-file file))))

(defun harness-provider-claude--learn (&rest changes)
  "Merge CHANGES, a plist, into the learned listing.
When a value changed the listing is saved and the catalogue listed
again; return non-nil then.  A change of the times alone (`:cli-at',
`:api-at') is saved but lists nothing again."
  (let* ((old (harness-provider-claude--listing))
         (changed (lambda (times)
                    (cl-loop for (k v) on changes by #'cddr
                             thereis (and (or times (not (memq k '(:cli-at :api-at))))
                                          (not (equal v (plist-get old k))))))))
    (when (funcall changed t)
      (setq harness-provider-claude--listing (harness-plist-merge '(:version 1) old changes))
      (harness-provider-claude--save-listing)
      (when (funcall changed nil)
        (harness-provider-claude--relist)
        t))))

(defun harness-provider-claude--relist ()
  "Have the catalogue list the Claude models again, from the command loop.
Changes that come together, a listing and a window, list them once."
  (unless harness-provider-claude--relist-pending
    (setq harness-provider-claude--relist-pending t)
    (harness-run-soon
     (lambda ()
       (setq harness-provider-claude--relist-pending nil)
       (when (fboundp 'harness-provider-relist)
         (harness-provider-relist 'claude))))))

;;;;; What the CLI says

(defun harness-provider-claude--note-cli-models (models)
  "Remember MODELS, the `models' of a CLI's `initialize' answer.
Each is a ModelInfo: `value' the name the CLI takes, `displayName',
`description', `supportedEffortLevels', `resolvedModel'.  An answer
without any (an older CLI) leaves what was listed before."
  (let ((kept (cl-remove-if-not (lambda (m) (and (consp m) (keywordp (car m))
                                                 (stringp (plist-get m :value))
                                                 (not (string-blank-p (plist-get m :value)))))
                                (and (listp models) models))))
    (when (and kept (not (equal kept (plist-get (harness-provider-claude--listing) :cli-models))))
      (harness-provider-claude--learn :cli-models kept :cli-at (float-time)))))

(defun harness-provider-claude--settle-listing-waiters ()
  "Resolve the promises waiting for a CLI to list its models."
  (let ((waiters harness-provider-claude--listing-waiters))
    (setq harness-provider-claude--listing-waiters nil)
    (dolist (p waiters) (harness-resolve p t))))

(defun harness-provider-claude--handle-initialized (entry ok payload)
  "Handle the CLI's answer PAYLOAD to ENTRY's `initialize'; OK says it succeeded.
It names the account and lists the models.  A probe that was only to
list them exits once they came, unless a usage report is due from it."
  (when ok
    (when-let* ((account (plist-get payload :account)))
      (harness-provider-claude--handle-account entry account))
    (condition-case err
        (harness-provider-claude--note-cli-models (plist-get payload :models))
      (error (harness-log 'warn "provider-claude: cannot read the CLI's models: %s"
                          (harness-error-message err)))))
  (setq harness-provider-claude--cli-answered (float-time))
  (when (harness-provider-claude-session-probe entry)
    (setq harness-provider-claude--probe-answered entry)
    (unless harness-provider-claude--refresh
      (harness-provider-claude--end-probe entry)))
  (harness-provider-claude--settle-listing-waiters))

(defun harness-provider-claude--model-usage-windows (usage)
  "Return the windows USAGE, a `modelUsage' object, reports.
Each is (NAME WINDOW MAX-OUTPUT): USAGE maps model names to what each
used, with the context window and output limit the CLI ran it with
\(`contextWindow' and `maxOutputTokens'; snake case is read too).
MAX-OUTPUT is nil when not said."
  (when (and (consp usage) (keywordp (car usage)))
    (cl-loop for (k v) on usage by #'cddr
             for window = (and (consp v) (or (plist-get v :contextWindow) (plist-get v :context_window)))
             for out = (and (consp v) (or (plist-get v :maxOutputTokens) (plist-get v :max_output_tokens)))
             when (and (keywordp k) (numberp window) (> window 0))
             collect (list (substring (symbol-name k) 1) (round window)
                           (and (numberp out) (> out 0) (round out))))))

(defun harness-provider-claude--one-million-p (name)
  "Non-nil when model NAME asks for the CLI's window of a million tokens."
  (and (stringp name) (string-suffix-p "[1m]" name)))

(defun harness-provider-claude--note-model-usage (entry usage &optional others-only)
  "Learn the context windows USAGE, a `modelUsage' object, reports on ENTRY.
Each model USAGE names keeps the window the CLI ran it with.  The name
ENTRY's process was started with (an alias such as \"opus\", say) takes
the window of the model its banner names, and is remembered to stand
for that model; not with OTHERS-ONLY, for a report that may cover
earlier processes.  A process started with \"[1m]\" after the name
teaches nothing about the names without it, which run in a smaller
window."
  (let* ((reported (harness-provider-claude--model-usage-windows usage))
         (asked (car (harness-provider-claude-session-spawn-key entry)))
         (asked (and (stringp asked) (not (string-blank-p asked)) asked))
         (ran (harness-provider-claude-session-model entry))
         (ran (and (stringp ran) (not (string-blank-p ran)) ran))
         (main (and asked (not others-only)
                    (or (assoc ran reported) (assoc asked reported)
                        (and (= 1 (length reported)) (car reported)))))
         (listing (harness-provider-claude--listing))
         (windows (plist-get listing :windows))
         (aliases (plist-get listing :aliases))
         (learn (lambda (name window out)
                  (setq windows
                        (cons (append (list :name name :context-window window)
                                      (and out (list :max-output out)))
                              (cl-remove name windows :key (lambda (w) (plist-get w :name))
                                         :test #'equal))))))
    (dolist (r reported)
      (unless (and (harness-provider-claude--one-million-p asked)
                   (not (harness-provider-claude--one-million-p (car r))))
        (funcall learn (car r) (nth 1 r) (nth 2 r))))
    (when main
      (funcall learn asked (nth 1 main) (nth 2 main)))
    (when (and asked ran (not others-only) (not (equal asked ran)))
      (setq aliases (cons (list :name asked :model ran)
                          (cl-remove asked aliases :key (lambda (a) (plist-get a :name)) :test #'equal))))
    (let ((by-name (lambda (a b) (string< (plist-get a :name) (plist-get b :name)))))
      ;; Sorted copies: the lists share cells with the listing they replace.
      (harness-provider-claude--learn :windows (sort (copy-sequence windows) by-name)
                                      :aliases (sort (copy-sequence aliases) by-name)))))

(defun harness-provider-claude--learned-window (name)
  "Return the window a result taught for model NAME, or nil.
That is a plist (:name NAME :context-window N :max-output N)."
  (cl-find name (plist-get (harness-provider-claude--listing) :windows)
           :key (lambda (w) (plist-get w :name)) :test #'equal))

(defun harness-provider-claude--alias-target (name)
  "Return the model the CLI ran when started with NAME, or nil."
  (plist-get (cl-find name (plist-get (harness-provider-claude--listing) :aliases)
                      :key (lambda (a) (plist-get a :name)) :test #'equal)
             :model))

(defun harness-provider-claude--start-listing ()
  "Have a CLI list its models; return a promise, or nil when one just did.
The promise resolves once a CLI answered `initialize' or gave up
\(after `harness-provider-claude--probe-timeout'): a probe is started
for it, which makes no model call."
  (unless (or (and harness-provider-claude--cli-answered
                   (< (- (float-time) harness-provider-claude--cli-answered)
                      harness-provider-claude--listed-lately))
              (and harness-provider-claude--probe
                   (eq harness-provider-claude--probe harness-provider-claude--probe-answered)
                   (process-live-p (harness-provider-claude-session-process harness-provider-claude--probe))))
    (let ((promise (harness-make-promise)))
      (push promise harness-provider-claude--listing-waiters)
      (condition-case err
          (progn (harness-provider-claude--start-probe)
                 (run-at-time harness-provider-claude--probe-timeout nil
                              #'harness-provider-claude--settle-listing-waiters))
        (error (harness-log 'warn "provider-claude: cannot ask the CLI for its models: %s"
                            (harness-error-message err))
               (harness-provider-claude--settle-listing-waiters)))
      promise)))

;;;;; What the API says

(defun harness-provider-claude--api-key ()
  "Return the Anthropic API key to list the models with, or nil.
See `harness-provider-claude-api-key'.  A CLI that runs on Bedrock or
Vertex has models of other names, so it gets none."
  (let ((usable (lambda (s) (and (stringp s) (not (string-blank-p s)) (string-trim s)))))
    (cond ((eq harness-provider-claude-api-key 'none) nil)
          ((stringp harness-provider-claude-api-key) (funcall usable harness-provider-claude-api-key))
          ((or (funcall usable (getenv "CLAUDE_CODE_USE_BEDROCK"))
               (funcall usable (getenv "CLAUDE_CODE_USE_VERTEX")))
           nil)
          (t (or (funcall usable (getenv "ANTHROPIC_API_KEY"))
                 (condition-case nil
                     (progn
                       (require 'auth-source)
                       (let* ((found (car (auth-source-search :host "api.anthropic.com" :user "apikey"
                                                              :max 1 :require '(:secret))))
                              (secret (plist-get found :secret)))
                         (funcall usable (if (functionp secret) (funcall secret) secret))))
                   (error nil)))))))

(defun harness-provider-claude--api-url (after)
  "Return the URL of a page of the API's model list.
It is the first page, or the one after the model id AFTER."
  (concat (string-remove-suffix "/" (or harness-provider-claude--api-base
                                        (let ((env (getenv "ANTHROPIC_BASE_URL")))
                                          (and env (not (string-blank-p env)) env))
                                        "https://api.anthropic.com"))
          "/v1/models?limit=1000"
          (if after (concat "&after_id=" (url-hexify-string after)) "")))

(defun harness-provider-claude--api-error (err)
  "Return a short description of ERR, a failed request for the models."
  (pcase err
    (`(http-error ,status ,body)
     (format "HTTP %s%s" (or status "?")
             (let ((msg (and (stringp body)
                             (ignore-errors (harness-plist-get-in (harness-json-parse body)
                                                                  '(:error :message))))))
               (if (stringp msg) (concat ": " msg) ""))))
    (`(json-error ,status ,_) (format "HTTP %s: not JSON" status))
    (_ (harness-error-message err))))

(defun harness-provider-claude--fetch-api-models (key &optional after acc page)
  "Return a promise of every entry of the API's model list, asked with KEY.
AFTER, ACC and PAGE carry the pages read so far; at most ten are read."
  (harness-then (harness-http-request-json
                 (harness-provider-claude--api-url after)
                 :headers (list (cons "x-api-key" key) (cons "anthropic-version" "2023-06-01"))
                 :timeout 30)
                (lambda (json)
                  (let ((acc (append acc (plist-get json :data)))
                        (last-id (plist-get json :last_id)))
                    (if (and (harness-json-true-p (plist-get json :has_more)) (stringp last-id)
                             (< (or page 1) 10))
                        (harness-provider-claude--fetch-api-models key last-id acc (1+ (or page 1)))
                      acc)))))

(defun harness-provider-claude--list-api (refresh)
  "Ask the API for its models when due; return a promise, or nil when not.
Due is REFRESH, or a listing older than
`harness-provider-claude--api-models-ttl' not asked for within it.
Nothing is asked without a key (see `harness-provider-claude--api-key').
The promise resolves once the listing is learned or failed, which is
logged; what was listed before stays."
  (let ((at (plist-get (harness-provider-claude--listing) :api-at))
        (ttl harness-provider-claude--api-models-ttl))
    (cond
     (harness-provider-claude--api-fetch harness-provider-claude--api-fetch)
     ((and (not refresh)
           (or (and (numberp at) (< (- (float-time) at) ttl))
               (and harness-provider-claude--api-asked
                    (< (- (float-time) harness-provider-claude--api-asked) ttl))))
      nil)
     (t
      (setq harness-provider-claude--api-asked (float-time))
      (when-let* ((key (harness-provider-claude--api-key)))
        (let ((fetch (condition-case err
                         (harness-provider-claude--fetch-api-models key)
                       (error (harness-rejected err)))))
          (setq harness-provider-claude--api-fetch
                (harness-then fetch
                              (lambda (entries)
                                (setq harness-provider-claude--api-fetch nil)
                                (let ((kept (cl-remove-if-not (lambda (e) (and (consp e) (stringp (plist-get e :id))))
                                                              entries)))
                                  (when kept
                                    (harness-provider-claude--learn :api-models kept :api-at (float-time))))
                                t)
                              (lambda (err)
                                (setq harness-provider-claude--api-fetch nil)
                                (harness-log 'warn "provider-claude: listing the API's models failed: %s"
                                             (harness-provider-claude--api-error err))
                                nil)))))))))

;;;;; The catalogue

(defun harness-provider-claude--window-p (value)
  "Non-nil when VALUE is a usable token count: a positive number."
  (and (numberp value) (> value 0)))

(defun harness-provider-claude--api-efforts (capabilities)
  "Return the effort levels the API's CAPABILITIES of a model support, or nil.
Without a word on effort, a model that thinks has the first three."
  (let ((effort (plist-get capabilities :effort)))
    (or (cl-remove-if-not (lambda (level)
                            (harness-json-true-p (plist-get (plist-get effort (intern (concat ":" level)))
                                                            :supported)))
                          harness-provider-claude--efforts)
        (and (harness-json-true-p (harness-plist-get-in capabilities '(:thinking :supported)))
             (list "low" "medium" "high")))))

(defun harness-provider-claude--api-model (entry)
  "Return the model plist of ENTRY of the API's model list, or nil."
  (let ((id (plist-get entry :id)))
    (when (and (stringp id) (not (string-blank-p id)))
      (let* ((caps (plist-get entry :capabilities))
             (image (and (consp caps) (harness-plist-get-in caps '(:image_input :supported))))
             (levels (and (consp caps) (harness-provider-claude--api-efforts caps)))
             (window (plist-get entry :max_input_tokens))
             (out (plist-get entry :max_tokens))
             (label (plist-get entry :display_name)))
        (append (list :name id :label (if (and (stringp label) (not (string-blank-p label))) label id))
                (and (harness-provider-claude--window-p window) (list :context-window (round window)))
                (and (harness-provider-claude--window-p out) (list :max-output (round out)))
                (list :input-modalities (if (and (consp caps) (not (harness-json-true-p image)))
                                            '("text")
                                          '("text" "image")))
                (and levels (list :thinking-levels levels)))))))

(defun harness-provider-claude--name-label (name)
  "Return a readable label for Claude model NAME: \"Claude Opus 5.6\", say."
  (if (string-match "\\`claude-\\([a-z]+\\)-\\([0-9]+\\)\\(?:-\\([0-9]\\)\\)?\\(?:-[0-9]\\{8\\}\\)?\\'" name)
      (format "Claude %s %s%s" (capitalize (match-string 1 name)) (match-string 2 name)
              (if (match-string 3 name) (concat "." (match-string 3 name)) ""))
    name))

(defun harness-provider-claude--described-model (description models)
  "Return the name of the model of MODELS that DESCRIPTION names, or nil.
The CLI describes an alias by the model it stands for: \"Opus 5.5 ·
Most capable for complex work\", or \"Use the default model (currently
Sonnet 5)\"; the family and version read as a model key."
  (when (stringp description)
    (let ((case-fold-search nil))
      (when (string-match "\\b\\([A-Z][a-z]+\\) \\([0-9]+\\)\\(?:\\.\\([0-9]+\\)\\)?\\b" description)
        (let ((key (format "claude-%s-%s%s" (downcase (match-string 1 description))
                           (match-string 2 description)
                           (if (match-string 3 description) (concat "-" (match-string 3 description)) ""))))
          (plist-get (cl-find key models :key (lambda (m) (harness-provider-model-key (plist-get m :name)))
                              :test #'equal)
                     :name))))))

(defun harness-provider-claude--described-pricing (description)
  "Return the prices DESCRIPTION gives, as `:pricing' takes them, or nil.
The CLI describes a model to someone billed per token with its prices:
\"· $5/$25 per Mtok\".  Cache reads cost a tenth of input and cache
writes a quarter more, as Anthropic prices them."
  (when (and (stringp description)
             (string-match "\\$\\([0-9]+\\(?:\\.[0-9]+\\)?\\)/\\$\\([0-9]+\\(?:\\.[0-9]+\\)?\\) per Mtok"
                           description))
    (let ((in (string-to-number (match-string 1 description)))
          (out (string-to-number (match-string 2 description))))
      (list :input (float in) :output (float out) :cache-read (* 0.1 in) :cache-write (* 1.25 in)))))

(defun harness-provider-claude--full-models (entries)
  "Return the Claude models by their full names, the API's first.
ENTRIES are the entries of the API's model list.  A model the API
lists keeps the price `harness-provider-claude-models' gives it, or a
model of the same key; the models only that list knows come after the
API's."
  (let* ((seeds (mapcar #'copy-sequence harness-provider-claude-models))
         (listed (delq nil (mapcar #'harness-provider-claude--api-model entries)))
         (name (lambda (m) (plist-get m :name))))
    (append (mapcar (lambda (m)
                      (let ((seed (or (cl-find (plist-get m :name) seeds :key name :test #'equal)
                                      (cl-find (harness-provider-model-key (plist-get m :name)) seeds
                                               :key (lambda (s) (harness-provider-model-key (plist-get s :name)))
                                               :test #'equal))))
                        (if seed
                            (append m (harness-plist-remove seed :name :label :context-window :max-output
                                                            :input-modalities :thinking-levels))
                          m)))
                    listed)
            (cl-remove-if (lambda (s) (cl-find (plist-get s :name) listed :key name :test #'equal))
                          seeds))))

(defun harness-provider-claude--cli-model (info models)
  "Return the model plist of INFO, a model the CLI lists, or nil.
MODELS are the models by their full names, which give the model INFO
stands for (its `resolvedModel', the model the CLI ran under that
name, the one its description names) its prices and window.  A name
with \"[1m]\" after it has a window of a million tokens; one that
stands for a model MODELS lack has the window of the newest of its
family, flagged as an estimate."
  (let* ((name (plist-get info :value))
         (base (string-remove-suffix "[1m]" name))
         (resolved (plist-get info :resolvedModel))
         (target (or (and (stringp resolved) (not (string-blank-p resolved)) resolved)
                     (harness-provider-claude--alias-target name)
                     (and (cl-find base models :key (lambda (m) (plist-get m :name)) :test #'equal) base)
                     (harness-provider-claude--described-model (plist-get info :description) models)))
         (target-base (and target (string-remove-suffix "[1m]" target)))
         (known (and target-base (cl-find target-base models :key (lambda (m) (plist-get m :name))
                                          :test #'equal)))
         (one-million (or (harness-provider-claude--one-million-p name)
                          (harness-provider-claude--one-million-p target)))
         (levels (plist-get info :supportedEffortLevels))
         (levels (cond ((and (consp levels) (cl-every #'stringp levels)) levels)
                       ((eq (plist-get info :supportsEffort) :false) nil)
                       (t (plist-get known :thinking-levels))))
         (label (plist-get info :displayName))
         (description (plist-get info :description))
         (pricing (or (plist-get known :pricing) (harness-provider-claude--described-pricing description))))
    (append (list :name name
                  :label (if (and (stringp label) (not (string-blank-p label))) label name))
            (cond (one-million (list :context-window harness-provider-claude--one-million))
                  ((harness-provider-claude--window-p (plist-get known :context-window))
                   (list :context-window (plist-get known :context-window)))
                  (t (harness-provider-claude--family-window (or target-base base) models)))
            (and (plist-get known :max-output) (list :max-output (plist-get known :max-output)))
            (list :input-modalities (or (plist-get known :input-modalities) '("text" "image")))
            (and levels (list :thinking-levels levels))
            (and pricing (list :pricing pricing))
            (and target (not (equal target name)) (list :resolves-to target))
            (and (stringp description) (not (string-blank-p description)) (list :description description)))))

(defun harness-provider-claude--with-learned (model)
  "Return MODEL with the window a result taught for its name, when one did."
  (if-let* ((learned (harness-provider-claude--learned-window (plist-get model :name))))
      (append (list :context-window (plist-get learned :context-window))
              (and (plist-get learned :max-output) (list :max-output (plist-get learned :max-output)))
              (harness-plist-remove model :context-window :max-output))
    model))

(defun harness-provider-claude--catalogue ()
  "Return the Claude models, from what the CLI and the API listed and learned.
First the models the CLI lists (its picker's aliases), then the
models they stand for and the models the CLI ran that nothing else
names, then the models by their full names: the API's, then
`harness-provider-claude-models'.  A window a result reported for a
name wins over any listed for it; a model still without one is the
catalogue's to estimate."
  (let* ((listing (harness-provider-claude--listing))
         (full (harness-provider-claude--full-models (plist-get listing :api-models)))
         (cli (delq nil (mapcar (lambda (info)
                                  (condition-case err
                                      (harness-provider-claude--cli-model info full)
                                    (error (harness-log 'warn "provider-claude: cannot read listed model %S: %s"
                                                        (plist-get info :value) (harness-error-message err))
                                           nil)))
                                (plist-get listing :cli-models))))
         (named (mapcar (lambda (m) (plist-get m :name)) (append cli full)))
         (extra nil)
         (unnamed (lambda (name)
                    (not (or (member name named)
                             (cl-find name extra :key (lambda (e) (plist-get e :name)) :test #'equal))))))
    ;; The models the CLI's aliases stand for, with what the alias has.
    (dolist (m cli)
      (let ((target (plist-get m :resolves-to)))
        (when target
          (setq target (string-remove-suffix "[1m]" target))
          (when (funcall unnamed target)
            (push (append (list :name target :label (harness-provider-claude--name-label target))
                          (unless (harness-provider-claude--one-million-p (plist-get m :name))
                            (cl-loop for k in '(:context-window :context-window-estimated :context-window-basis)
                                     when (plist-get m k) append (list k (plist-get m k))))
                          (harness-plist-remove m :name :label :context-window :context-window-estimated
                                                :context-window-basis :resolves-to :description))
                  extra)))))
    ;; The models the CLI ran, which a result named.
    (dolist (w (plist-get listing :windows))
      (let ((name (plist-get w :name)))
        (when (and (stringp name) (string-match-p "\\`claude-[a-z]+-[0-9]" name)
                   (not (harness-provider-claude--one-million-p name))
                   (funcall unnamed name))
          (push (list :name name :label (harness-provider-claude--name-label name)
                      :input-modalities '("text" "image"))
                extra))))
    (mapcar #'harness-provider-claude--with-learned
            (append cli
                    (nreverse extra)
                    (cl-remove-if (lambda (m) (cl-find (plist-get m :name) cli
                                                       :key (lambda (c) (plist-get c :name)) :test #'equal))
                                  full)))))

(defun harness-provider-claude--models (&optional refresh)
  "Return a promise of the Claude models.
They are what `harness-provider-claude--catalogue' says.  What is
known answers at once.  REFRESH asks first: a probe for the CLI's
listing, unless a CLI listed the models moments ago, and the API for
its own when there is a key; the promise resolves once they answered
or gave up.  The API's listing is also asked for, in the background,
when it is older than `harness-provider-claude--api-models-ttl'."
  (let ((asks (delq nil (list (and refresh (harness-provider-claude--start-listing))
                              (harness-provider-claude--list-api refresh)))))
    (if (and refresh asks)
        (harness-then (harness-all asks)
                      (lambda (_) (harness-provider-claude--catalogue))
                      (lambda (_) (harness-provider-claude--catalogue)))
      (harness-resolved (harness-provider-claude--catalogue)))))

(defun harness-provider-claude--family (name)
  "Return the family of Claude model NAME, such as \"opus\", or nil.
NAME is a full name (\"claude-opus-5-6\") or an alias the CLI takes
for the newest model of a family (\"opus\", \"sonnet[1m]\")."
  (let ((case-fold-search nil))
    (cond ((string-match "\\`claude-\\([a-z]+\\)-" name) (match-string 1 name))
          ((string-match "\\`\\([a-z]+\\)\\(?:\\[1m]\\)?\\'" name) (match-string 1 name)))))

(defun harness-provider-claude--family-model (name models)
  "Return the first model of MODELS by a full name of NAME's family, or nil.
Listings put the newest of a family first.  NAME itself does not
count, nor a model with \"[1m]\" after its name."
  (when-let* ((family (harness-provider-claude--family name)))
    (let ((prefix (concat "claude-" family "-")))
      (cl-find-if (lambda (m)
                    (let ((n (plist-get m :name)))
                      (and (stringp n) (string-prefix-p prefix n) (not (equal n name))
                           (not (harness-provider-claude--one-million-p n)))))
                  models))))

(defun harness-provider-claude--family-window (name models)
  "Return the window NAME takes after its family in MODELS, as a plist, or nil.
That is the window of the first model of MODELS of NAME's family that
has one, flagged as an estimate: (:context-window N
:context-window-estimated t :context-window-basis ID)."
  (when-let* ((family (harness-provider-claude--family name))
              (prefix (concat "claude-" family "-"))
              (model (cl-find-if (lambda (m)
                                   (let ((n (plist-get m :name)))
                                     (and (stringp n) (string-prefix-p prefix n) (not (equal n name))
                                          (not (harness-provider-claude--one-million-p n))
                                          (harness-provider-claude--window-p (plist-get m :context-window)))))
                                 models)))
    (list :context-window (plist-get model :context-window)
          :context-window-estimated t
          :context-window-basis (or (plist-get model :context-window-basis)
                                    (plist-get model :id)
                                    (concat "claude:" (plist-get model :name))))))

(defun harness-provider-claude--resolve (name models)
  "Return what the provider knows of model NAME, which MODELS do not list.
The CLI takes names it does not list: a model's full name, an alias
such as \"opus\", either with \"[1m]\" after it.  A name a result
reported has the window the CLI ran it with, and an alias the model
the CLI ran under it (`:resolves-to'); \"[1m]\" after a name is the
model before it with a window of a million tokens.  An alias nothing
was learned of stands for the newest model of its family, its window
flagged as the estimate it is.  A full name nothing knows gets a label
and takes images, and the catalogue estimates its window."
  (let* ((learned (harness-provider-claude--learned-window name))
         (base (string-remove-suffix "[1m]" name))
         (one-million (harness-provider-claude--one-million-p name))
         (alias (not (string-prefix-p "claude-" base)))
         (by-name (lambda (n) (and n (cl-find n models :key (lambda (m) (plist-get m :name)) :test #'equal))))
         (target (or (harness-provider-claude--alias-target name)
                     (harness-provider-claude--alias-target base)))
         (target (and target (string-remove-suffix "[1m]" target)))
         (known (or (funcall by-name target) (and one-million (funcall by-name base))))
         (family (and (not known) alias (harness-provider-claude--family-model base models)))
         (model (or known family))
         (window (plist-get model :context-window))
         (label (concat (if alias (capitalize base) (harness-provider-claude--name-label base))
                        (if one-million " (1M context)" ""))))
    (append (list :label label :input-modalities '("text" "image"))
            (cond (learned
                   (append (list :context-window (plist-get learned :context-window))
                           (and (plist-get learned :max-output)
                                (list :max-output (plist-get learned :max-output)))))
                  (one-million (list :context-window harness-provider-claude--one-million))
                  ((not (harness-provider-claude--window-p window)) nil)
                  ((and known (not (plist-get model :context-window-estimated)))
                   (list :context-window window))
                  (t (list :context-window window :context-window-estimated t
                           :context-window-basis (or (plist-get model :context-window-basis)
                                                     (plist-get model :id)))))
            (cond (target (list :resolves-to target))
                  (model (list :resolves-to (plist-get model :name))))
            (and model
                 (apply #'harness-plist-remove model
                        :id :name :label :provider :provider-label :context-window
                        :context-window-estimated :context-window-basis :resolves-to :description
                        :input-modalities
                        (and (plist-get learned :max-output) '(:max-output)))))))

;;;; One-off requests

(defconst harness-provider-claude--ephemeral-environment
  (list "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1"
        harness-provider-claude--no-auto-memory
        "CLAUDE_CODE_SKIP_PROMPT_HISTORY=1")
  "Environment added to the CLI process of a one-off request.
The process loads no CLAUDE.md (neither the user's, nor the project's,
nor auto memory, whatever `harness-provider-claude-auto-memory' says)
and saves no transcript, so its answer comes from the request alone.
These are documented environment variables of Claude Code: a CLI too
old to know one ignores it.")

(defvar harness-provider-claude--ephemeral-count 0
  "Counter that keeps the process keys of one-off requests apart.")

(defun harness-provider-claude--ephemeral-directory (session)
  "Return the directory the CLI process of a one-off request of SESSION runs in.
For a local session that is a private, empty directory of the harness's
own, made when missing, so no project's settings or hooks come along
either.  A remote session's request runs in the session's directory on
its host, where the environment alone keeps CLAUDE.md out."
  (let ((cwd (or (plist-get session :cwd) default-directory)))
    (if (or (plist-get session :host) (file-remote-p cwd))
        cwd
      (let ((dir (file-name-as-directory (expand-file-name "claude-one-off" harness-state-directory))))
        (unless (file-directory-p dir)
          (make-directory dir t)
          (set-file-modes dir #o700))
        dir))))

(defun harness-provider-claude--end-ephemeral (key)
  "Stop the CLI process of the one-off request KEY and forget it.
Its input is closed, so that it can exit by itself once it has answered
what it was still asked (a usage report, say); it is killed if it still
runs `harness-provider-claude--interrupt-timeout' seconds later."
  (when-let* ((entry (gethash key harness-provider-claude--sessions)))
    (remhash key harness-provider-claude--sessions)
    (let ((proc (harness-provider-claude-session-process entry)))
      (when (process-live-p proc)
        (ignore-errors (process-send-eof proc))))
    (run-at-time harness-provider-claude--interrupt-timeout nil #'harness-provider-claude--kill entry)))

(defun harness-provider-claude--complete-ephemeral (request)
  "Run the one-off REQUEST in a CLI process of its own; return its handle.
The process is started for REQUEST alone, under a key of its own, so
it resumes no CLI session and REQUEST's session keeps its own; it is
stopped once REQUEST is done (`harness-provider-claude--end-ephemeral').
It runs with `harness-provider-claude--ephemeral-environment', in
`harness-provider-claude--ephemeral-directory'."
  (let* ((session (plist-get request :session))
         (key (format "%s~%d" (or (plist-get session :id) "default")
                      (cl-incf harness-provider-claude--ephemeral-count)))
         (on-event (or (plist-get request :on-event) #'ignore))
         ;; The spawn takes the environment from here.
         (process-environment (append harness-provider-claude--ephemeral-environment
                                      process-environment)))
    (condition-case err
        (harness-provider-claude--complete
         (append (list :session (list :id key :host (plist-get session :host)
                                      :cwd (harness-provider-claude--ephemeral-directory session))
                       :provider-state nil
                       :on-event (lambda (event)
                                   (unwind-protect (funcall on-event event)
                                     (when (eq (plist-get event :type) 'done)
                                       (run-at-time 0 nil #'harness-provider-claude--end-ephemeral key)))))
                 (harness-plist-remove request :session :provider-state :on-event)))
      (error (harness-provider-claude--end-ephemeral key)
             (signal (car err) (cdr err))))))

(defun harness-provider-claude--start (request)
  "Start REQUEST, the provider's `:complete'; return a handle with `:cancel'.
A one-off request (`:ephemeral') runs in a CLI process of its own
\(`harness-provider-claude--complete-ephemeral'), any other in its
session's (`harness-provider-claude--complete')."
  (if (harness-json-true-p (plist-get request :ephemeral))
      (harness-provider-claude--complete-ephemeral request)
    (harness-provider-claude--complete request)))

(defun harness-provider-claude-close (session-id)
  "Shut down the CLI process serving SESSION-ID, if any."
  (when-let* ((entry (gethash session-id harness-provider-claude--sessions)))
    (harness-provider-claude--finish entry '(:type done :stop-reason cancelled))
    (harness-provider-claude--kill entry)
    (remhash session-id harness-provider-claude--sessions)
    (remhash session-id harness-provider-claude--spawns)
    (remhash session-id harness-provider-claude--call-checkpoints)
    t))

(defun harness-provider-claude-close-all ()
  "Shut down every CLI process, the quota probe included."
  (dolist (id (hash-table-keys harness-provider-claude--sessions))
    (harness-provider-claude-close id))
  (when harness-provider-claude--probe
    (harness-provider-claude--end-probe harness-provider-claude--probe t))
  (harness-provider-claude--settle-refresh))

(defun harness-provider-claude--on-session-gone (session-id &rest _)
  "Close the process for SESSION-ID when its session is deleted or deactivated.
The processes of its side requests go too, and the one-off ones made
in its name (SESSION-ID-perms~N)."
  (harness-provider-claude-close session-id)
  (let ((prefix (concat session-id "#side-")))
    (dolist (id (hash-table-keys harness-provider-claude--sessions))
      (when (string-prefix-p prefix id)
        (harness-provider-claude-close id))))
  (let ((prefix (concat session-id "-")))
    (dolist (id (hash-table-keys harness-provider-claude--sessions))
      (when (string-prefix-p prefix id)
        (harness-provider-claude-close id)))))

(defun harness-provider-claude--on-state-changed (session-id state)
  "Close the process of SESSION-ID when its provider STATE is another conversation.
The agent replaces the state when the session's head moved off the
conversation the process holds: with a fork of it cut at a checkpoint,
or with none, for a new one.  The next turn starts the process the new
state calls for, rather than going on in the old conversation.  A
state naming the CLI session the process holds, as the one its own
start announces, keeps it, and so does a turn in flight."
  (when-let* ((entry (gethash session-id harness-provider-claude--sessions)))
    (unless (or (harness-provider-claude-session-active entry)
                (and (plist-get state :cli-session-id)
                     (not (harness-json-true-p (plist-get state :fork-pending)))
                     (equal (plist-get state :cli-session-id)
                            (harness-provider-claude-session-cli-session-id entry))))
      (harness-log 'info "provider-claude: the conversation of %s changed; closing its process" session-id)
      (harness-provider-claude-close session-id))))

(defun harness-provider-claude--drop-judge-conversations ()
  "Stop the idle CLI processes the permission judge kept per session.
Before one-off requests had processes of their own, each session's
judge kept one CLI conversation, under SESSION-ID-perms, until the
harness stopped.  Loading this file ends the idle ones."
  (dolist (id (hash-table-keys harness-provider-claude--sessions))
    (let ((entry (gethash id harness-provider-claude--sessions)))
      (when (and (string-suffix-p "-perms" id)
                 (not (harness-provider-claude-session-active entry)))
        (harness-provider-claude-close id)))))

(harness-provider-claude--drop-judge-conversations)

(defun harness-provider-claude--init ()
  "Register the provider and subscribe to session lifecycle events."
  (harness-on 'session/deleted #'harness-provider-claude--on-session-gone)
  (harness-on 'session/deactivated #'harness-provider-claude--on-session-gone)
  (harness-on 'session/provider-state-changed #'harness-provider-claude--on-state-changed))

(harness-define-provider 'claude
  :label "Claude Code"
  :doc "Claude models through the official claude CLI (subscription friendly)."
  :models #'harness-provider-claude--models
  :complete #'harness-provider-claude--start
  :fork #'harness-provider-claude--fork
  :quota #'harness-provider-claude--quota
  :capabilities harness-provider-claude-capabilities
  :tiers harness-provider-claude-tiers
  :warm #'harness-provider-claude--warm
  :close #'harness-provider-claude-close
  :resolve #'harness-provider-claude--resolve)

(harness-define-module 'provider-claude
  :doc "Claude Code CLI as a hosted-loop completion provider."
  :requires '(provider)
  :init #'harness-provider-claude--init
  :shutdown #'harness-provider-claude-close-all)

;; A reload does not initialise a running module again: subscribe the
;; handlers this version adds now.
(when (harness-module-ready-p 'provider-claude)
  (harness-provider-claude--init))

(provide 'harness-provider-claude)
;;; harness-provider-claude.el ends here
