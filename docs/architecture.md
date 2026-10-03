# Architecture and module contracts

This is the binding contract between modules.  A module may rely on
anything written here and on nothing else about another module.  If a
module needs something more, add it here first.

## Layers

```
 Presentation   lisp/ui/*        Emacs buffers, faces, keymaps, mouse.  Talks ACP only.
                                 Runs in the user's Emacs; everything below runs in
                                 the harness process (see Processes).
 ------------------------------- ACP (JSON-RPC over loopback TCP; in-process lisp objects
                                 when `harness-process' is nil)
 State          session, agent, config, project, store, usage, naming, compaction,
                worktree, merge, tasks, tasks-notify, skills, perms, sandbox,
                notifications
 Completion     provider, provider-openai, provider-claude, provider-bedrock,
                provider-copilot
 Tool calls     tools, tools-fs, tools-shell, tools-emacs, tools-web, tools-agent,
                tools-sessions, tools-notify
 ------------------------------- bus (lisp/harness-core.el)
 Core           harness.el (loader, reload), harness-core (methods, events, filters,
                promises, modules), harness-util (json, ids, paths), harness-http (curl, SSE,
                binary bodies)
```

The core never shows UI and never calls a model.  UI modules never
`require` a state module and never touch a session struct: they hold
an ACP connection (local by default) and render what arrives.  State
modules never `require` a UI module.  That is the litmus test from
DESIGN.md: every module is testable alone, with a fake connection or a
fake provider, and without mocks of the rest.

## Processes

Emacs runs Lisp on one thread, so harness work done in the user's Emacs
competes with typing and redisplay no matter how asynchronous the
protocol around it is: an ACP request to an in-process harness still
runs its handler on the UI's thread.  With `harness-process` on (the
default) the layers above are split across two Emacs processes:

```
 user's Emacs                         harness process (emacs --batch -Q)
 harness.el, core, lisp/ui,     ACP   harness.el, core, lisp/modules
 harness-acp (client only),  <------> (acp serves 127.0.0.1:ephemeral,
 harness-files, client-tools  TCP     token per spawn)
```

- `harness-start` in the user's Emacs loads only the UI and the ACP client,
  then `harness-server-spawn` (lisp/harness-server.el) starts the child
  once init has finished, so settings made later in the init file reach
  it.  Requests made before the child listens are queued by `harness-ui`.
- The child is configured from a generated file: every `harness-`
  variable the user set (minus UI ones) plus
  `harness-server-forward-variables`; `harness-server-init-file` covers
  anything else (hooks, bus filters).
- The child announces `HARNESS-ACP-ADDRESS host:port` and its log lines on
  stderr (batch Emacs buffers stdout); the parent copies the log into
  `*harness-log*`.  Its stdin is closed, so a stray prompt fails rather
  than hangs; it exits when its parent dies.  The parent restarts it
  with backoff when it crashes and stops it with SIGTERM (which runs
  `kill-emacs-hook`, flushing sessions, tasks and streamed text).
  `M-x harness-restart` restarts it with fresh configuration;
  `harness-reload` reloads both sides.
- Work about the user's Emacs runs there, asked for by the harness with
  `client/request` (below): the `emacs_*` and `elisp` tools
  (lisp/harness-client-tools.el), saving user options to `custom-file`
  (`harness-save-user-option`), reverting buffers after a tool
  writes a file (event `tools/file-written`), and desktop notifications
  (lisp/harness-notifications-desktop.el, see notifications), so they
  show where the user is and a click on one opens what it is about.
- Project roots and file lists (lisp/harness-files.el) are computed on
  both sides with the same code; the UI lists files itself so `@`
  completion uses the user's projectile cache.

The harness process cannot prompt: TRAMP connections it opens need
non-interactive authentication (ssh agent), and auth-source secrets
must decrypt without a minibuffer (gpg-agent pinentry, not loopback).

`harness-process` nil keeps everything in one Emacs (tests, debugging);
the same `client/request` path then runs over the local connection.

## The bus

```elisp
(harness-define-module 'NAME :doc "…" :requires '(a b) :init #'fn :shutdown #'fn)
(harness-defmethod session/get (id) "Doc." …)          ; registers method `session/get'
(harness-call 'session/get id)                         ; sync; may return a promise
(harness-call-async 'session/get id)                   ; always a promise
(harness-on 'session/updated #'named-fn)               ; events; named fns dedupe on reload
(harness-emit 'session/updated id changes)
(harness-add-filter 'agent/system-prompt #'fn 40)      ; sync value transformer
(harness-run-filter 'agent/system-prompt "" session)
(harness-run-filter-async 'permission/decide decision request) ; async decision chain
```

Async filter gotcha: `harness-run-filter-async` adopts any promise a
handler returns and calls NEXT with its value.  A handler that stores
NEXT to call later (merge holds, budget prompts) must return nil.

An error signalled inside a `harness-then` handler rejects the derived
promise *and* is logged (with a backtrace when `harness-log-level` is
`debug`), because a rejection nobody observes would otherwise vanish.
Explicit rejections (`harness-reject`, `harness-rejected`) are not logged.

Promises: `harness-make-promise`, `harness-resolve`, `harness-reject`,
`harness-then`, `harness-all`, `harness-with-promise`, `harness-await`
(tests only).  Long work returns a promise; never block the main thread.

Naming: bus methods are `area/verb` symbols and are exactly the ACP
extension methods (`_harness/area/verb` on the wire).  Events are
`area/past-tense`.  Files: `lisp/modules/harness-NAME.el` defines
module `NAME` and provides feature `harness-NAME`.

Reload safety: keep state in `defvar`s (never re-initialised), register
subscribers with named functions, and make `:init` idempotent.
`harness-reload` compiles every file first and refuses to load anything
if one fails.  After a reload the `harness/reloaded` event fires and the
UI redraws every session buffer.

## Data shapes

All shapes are keyword plists (the JSON convention in harness-util:
objects are plists, arrays are lists, `nil` is null, `:false` is false).
`harness-json-encode` gives bytes (unibyte UTF-8 since Emacs 30) for a
process, a file or an HTTP body; JSON that goes inside other text (a
prompt, a tool result) or inside other JSON comes from
`harness-json-encode-text`, since bytes there break the next encoding.
Symbols used as enum values travel as strings over the wire and are
interned back by the ACP layer for a fixed set of keys (`:status`,
`:permission-mode`, `:kind`, `:behavior`, `:scope`).

### Session

```elisp
(:id "uuid"  :name "short title or nil"  :kind main|fork|btw|subagent
 :project "/abs/root/"  :cwd "/abs/dir/"  :host nil|"/ssh:user@host:"   ; TRAMP prefix
 :worktree nil|"/abs/worktree/"
 :model "PROVIDER:MODEL"            ; e.g. "claude:claude-fable-5-1"
 :permission-mode ask|accept-edits|auto|yolo
 :thinking nil|"low"|"medium"|"high"|"xhigh"|"max"
 :non-interactive nil|t             ; its own switch, from harness-non-interactive at creation
 :status idle|running|blocked|inactive
 :parent-id nil|"uuid"  :fork-node nil|"node-id"
 :created FLOAT  :updated FLOAT
 :usage (:input N :output N :cache-read N :cache-write N :cost F :list-cost F :context N :turns N
         :billing api|subscription|extra-usage :plan "max")    ; billing and plan of the latest call
 :context-window N                  ; in effect: the override, else the model's
 :context-window-override nil|N     ; a window set for the session
 :budget nil|(:amount F :hard BOOL)
 :head "node-id"
 :queue ((:id "q1" :text "…" :attachments (ATTACHMENT…)) …)
 :pending ((:id "p1" :kind permission|question :payload PLIST :created FLOAT) …)
 :todos ((:id :text :status pending|in-progress|done) …)
 :plan nil|"markdown"
 :provider-state PLIST)                ; opaque, owned by the provider (e.g. CLI session id)
```

`:usage :context` is the input size of the last request (prompt tokens
incl. cache); the UI colours it against `:context-window`.  `:cost`
is what the session's calls were billed and `:list-cost` the same calls
at API prices (they differ when a subscription paid); see "Usage
record".

`:context-window` is looked up in the model catalogue (`provider/model`)
each time the session is described, so it follows the catalogue; only
`:context-window-override` is stored.  A copy of the catalogue's window
would go stale when the catalogue changes, or keep the 128000 stand-in
given for a model whose provider has not answered yet.  When the
catalogue changes, the sessions whose window moved get `session/changed`.

### Node (conversation DAG)

```elisp
(:id "n-…" :parent "n-…"|nil :session "uuid" :ts FLOAT
 :kind user|assistant|thinking|tool-call|tool-result|hint|compaction|plan
 ;; user / assistant / thinking / hint / compaction / plan:
 :content "text"  :blocks (BLOCK…)          ; blocks only when non-text content exists
 ;; tool-call (:title from `harness-tool-title': the tool's label, then what the call is about):
 :tool "read_file" :call-id "toolu_…" :input PLIST :title "Read file: src/x.el"
 ;; tool-result:
 :call-id "toolu_…" :output "text" :is-error BOOL :attachments (ATTACHMENT…)
 :usage PLIST        ; assistant nodes: this response's usage
 :meta PLIST)        ; anything else (model, duration, cost …)
```

A session's transcript is the path root → `:head`.  A fork copies the
ancestor chain (same node ids) into the new session and records
`:parent-id` / `:fork-node`, so the tree view can merge families by id.

### Content blocks (provider messages, prompts, attachments)

```elisp
(:type "text" :text "…")
(:type "image" :mime "image/png" :data "BASE64")            ; or :path "/abs" (read lazily)
(:type "audio" :mime "audio/wav" :data "BASE64")
(:type "file" :path "/abs/f" :size N :mime "text/plain")     ; reference only
(:type "thinking" :text "…" :signature "…")
(:type "tool_use" :id "…" :name "…" :input PLIST)
(:type "tool_result" :tool_use_id "…" :content "…" :is_error BOOL)
```

ATTACHMENT = `(:path "/abs" :size N :mime "…" :name "display")`.

### Usage record

`(:input N :output N :cache-read N :cache-write N :cost F :list-cost F
:billing api|subscription|extra-usage|nil :plan ID)`; amounts in USD.

- `:cost` is what the call was billed.  `:list-cost` is the call at
  API list prices.  They are the same unless a subscription paid.
- `:billing` says who paid:
  - `api`: per token, through an API key, a bearer token or a cloud
    provider.
  - `subscription`: a plan such as Claude Max paid, so `:cost` is 0.
  - `extra-usage`: the plan's extra usage, billed at API prices.
  - nil: the provider did not say; it reads as per-token billing.
- `:plan` is the subscription's id, such as "max".

When a provider reports no cost, `session/usage-add` prices one from the
model catalogue.  A missing list cost is the cost, or priced too when a
subscription paid.  Budgets count `:cost`, so usage a plan covers spends
none of them.  `harness-billing-of`, `harness-usage-list-cost`,
`harness-usage-covered` and `harness-format-spend` (harness-util) read
these keys on either side of ACP.

## Module contracts (state layer)

### config

Layered settings: directory `.dir-locals.el` (most specific) →
project-root `.dir-locals.el` → customize default.  Variables are
`defcustom`s with `:safe` predicates so dir-locals never prompt:
`harness-model` (default "claude:claude-fable-5-1"),
`harness-permission-mode`, `harness-thinking`,
`harness-allowed-directories`, `harness-budget`, `harness-sandbox-policy`,
`harness-non-interactive`, `harness-tasks-directory` (the tasks
module's folder of task files).

The other harness options (the `harness` customize group, less the
ones that decide how the harness starts or reaches the UI:
`harness-process`, `harness-state-directory`, the module lists, the
`harness-server-*` and `harness-acp-*` options, minor modes) have a
global value only.  Options named `...-api-key`, `-token`, `-secret`
or `-password` are secrets: their values never leave the harness and
never go to a `.dir-locals.el`.

`harness-config-sections` names the options most people change, in
sections by what they are for (new sessions, files and safety, task
board, notifications, models and services); `config/describe` lists
them first, each with its `:section`, then the advanced ones.  A
setting a page should not lead with but must keep working stays a
global `defcustom` and is advanced; what only the harness's own code
has an opinion about is a `defconst`/`defvar` named `MODULE--thing`.
See docs/configuration-audit.md for the rule and the audit behind it.

- `config/get KEY CWD` → value for a session at CWD (KEY is the symbol
  or its name; layered settings only).
- `config/set KEY VALUE &key scope cwd printed` — scope
  `directory|project|global`; default: project if a project is found,
  else directory, and global for an option that does not layer.
  `:printed t` says VALUE is the value printed with `prin1`, which is
  how a JSON client sends symbols and lists.  The value must fit the
  option's customize type, and a directory-local one its `:safe`
  predicate.  Persists with `add-dir-local-variable` (no backup file
  is left behind), or for `global` with `harness-save-user-option`,
  which asks the UI's Emacs to `customize-save-variable` (its custom
  file).
- `config/unset KEY &key scope cwd` — removes KEY from that layer: a
  `project` or `directory` scope deletes it from the `.dir-locals.el`
  (and the file once nothing is left in it); `global` sets the option
  back to its standard value.
- `config/layers CWD` → `((global . V) (project . V) (directory . V))` for display.
- `config/describe CWD` → `(:cwd :root :project :in-project :files
  :modules :settings)` for a settings page: every option, layered ones
  first, each with its doc, customize `:type`, module, `:standard`,
  `:global`, `:project`, `:directory` and effective `:value` with the
  `:source` layer it comes from, plus the layers whose value does not
  fit the type (`:invalid`).  Types and values are printed (`read`
  them back), so they survive JSON; an unset layer is null, one set
  to nil is `"nil"`.  A secret has `:has-value` instead of values.
- Event `config/changed KEY VALUE SCOPE CWD` after a set or unset;
  after an unset VALUE is the value now in effect at CWD, and for a
  secret it is nil.

### project

- `project/root CWD` → root directory (project.el, falling back to CWD).
- `project/name ROOT` → display name.
- `project/files ROOT &optional QUERY LIMIT` → promise of relative paths,
  fuzzy filtered; nil outside a project.  Never blocks: projectile's
  cache when it has the project, else an asynchronous listing
  (projectile's command, or `git ls-files`) stored back into projectile's
  cache.  No cache of its own.  Implemented by lisp/harness-files.el.

### store

Persistence under `harness-state-directory`:
- `store/save NAME OBJ`, `store/load NAME` (JSON files, atomic write).
- `store/append NAME OBJ`, `store/read-all NAME` (JSONL).
- `store/sqlite` → open built-in sqlite handle for `usage.db` (nil when
  Emacs lacks sqlite; callers fall back to JSONL).
- `store/list PREFIX` → names.

### session

Owns session records, nodes, status, queue, pending requests, persistence
(sessions/ID.json + sessions/ID.nodes.jsonl).

Restarts: records are written shortly after a change, at once when the
status changes, and all of them on exit; nodes are appended as they
come.  Every session loads `inactive` (closed until something resumes
it).  One saved `running` or `blocked` was interrupted mid-turn by a
harness that stopped, so loading settles it: each tool call without a
result gets one (`:is-error t`, `:meta (:interrupted t)`) and a hint
says what it was doing or which question it waited on.  Pending
requests are not restored: the turn that would read their answers is
gone.

- `session/create &rest PLIST` — `:cwd` required; `:name :model
  :permission-mode :thinking :kind :parent-id :host :worktree`, and
  `:context-window` to set the session's own window.  Fills
  project, defaults from `config/get`.  → session.  Event `session/created`.
- `session/get ID`, `session/list &optional FILTER` (`:project :status
  :kind :parent-id :active`), `session/delete ID`.
- `session/update ID &rest PLIST` — settings and name; appends a `hint`
  node ("model → …") and persists the setting through `config/set` when
  `:persist t`.  `:context-window N` sets the session's own window, nil
  its model's again; a new `:model` drops a window set for the old one
  unless PLIST sets one too.  Event `session/updated ID CHANGES`.
- `session/set-status ID STATUS`.  Event `session/status ID STATUS`.
- `session/resume ID` (loads nodes, status idle), `session/deactivate ID`
  (closed: still listed and readable; the next message sent to it resumes it).
- `session/fork ID &rest PLIST` — copies ancestor chain; `:kind fork|subagent`,
  `:name`, `:cwd` (defaults to parent's).  Asks the provider to fork its
  state via `provider/fork` when supported; without a forked state the
  fork has none, never the parent's own, which would carry on the
  parent's provider conversation.  → new session.
- `session/btw ID &optional NAME`: a BTW side conversation over ID, a
  new, empty `btw` session sharing nothing with ID or with any other
  BTW (no nodes, no fork node, no provider state, no directory grants).
  It takes ID's cwd, project, host, worktree, model, thinking and
  permission mode; `:parent-id` is ID only so lists show it under ID.
  Returns the new session.
- `session/nodes ID &optional (:limit N :before NODE-ID)` → path nodes,
  oldest first; `session/node ID NODE-ID`; `session/tree ID` → every
  node of the family (session + ancestors + forks) as a list with
  `:session` set, plus `:sessions` summaries.
- `session/append ID NODE` → node with id/ts/parent filled; advances head.
  Event `session/node-added ID NODE`.
- `session/update-node ID NODE-ID PLIST` (tool result streaming, titles).
  Event `session/node-updated ID NODE`.
- `session/set-head ID NODE-ID`.
- `session/hint ID TEXT` → appends hint node.
- `session/queue ID TEXT &optional ATTACHMENTS`, `session/queue-update ID QID TEXT`,
  `session/queue-remove ID QID`, `session/queue-take ID` → items, cleared.
  Event `session/queue-changed ID ITEMS`.
- `session/pending-add ID REQUEST` → id; `session/pending-resolve ID PID ANSWER`;
  `session/pending ID`.  Event `session/pending-changed ID ITEMS`.
  Status becomes `blocked` while anything is pending.
- `session/usage-add ID USAGE &optional CONTEXT` → accumulated usage.
  Event `session/usage ID USAGE-TOTAL RECORD`.
- `session/set-todos ID TODOS`, `session/set-plan ID TEXT`.
- `session/messages ID` → provider messages (content blocks) built
  from the path, tool calls paired with results.  A steering message
  marked `:delivered-after NODE-ID` stands after that node (and the
  tool results right after it), where the model got it.
- `session/transcript-text ID` → searchable plain text.
- Event `session/changed ID SESSION` fires after any of the above (for UIs
  that just want to redraw).

### provider

```elisp
(harness-define-provider 'ID
  :label "Claude Code" :doc "…"
  :models FN            ; () → promise of MODEL plists
  :complete FN          ; (REQUEST) → HANDLE plist (:cancel FN)
  :fork FN              ; (MODEL PROVIDER-STATE) → promise of new state    [optional]
  :quota FN             ; (&optional REFRESH) → promise of QUOTA (below)     [optional]
  :capabilities PLIST)  ; static defaults, merged with per-model ones
```

MODEL = `(:id "ID:NAME" :provider ID :name "NAME" :label "…"
:context-window N :max-output N :input-modalities ("text" "image")
:thinking-levels (…) :pricing (:input F :output F :cache-read F :cache-write F)
:capabilities (…))`.  Pricing is USD per million tokens.

The catalogue is cached per provider.  Defining a provider again, as
every `harness-reload` does, forgets that provider's models and no
other's.  A provider whose models are not cached is asked by the first
`provider/model` that needs one: a static catalogue answers at once and
is cached before the call returns.  Until a slower provider answers,
and for a model its provider does not list, a stand-in MODEL with a
128000-token window is returned.  A failed listing is cached as empty
(or keeps the models listed before), so lookups do not ask again before
a refresh (`provider/models t`).  `provider/models-updated` follows
every listing that is cached.

Capabilities: `:hosted-loop` (provider runs the tool loop and keeps the
history; the agent only sends new user content), `:fork`, `:resume`,
`:vision`, `:audio-in`, `:thinking`, `:cache-status`, `:quota`,
`:compaction hosted`, `:cost-reported` (usage events carry `:cost`),
`:billing` (usage events say who paid: `:billing`, `:plan`,
`:list-cost`), `:pricing dynamic` (pricing comes from the model
catalogue), `:builtin-tools` (a list of the harness tools the provider
has a tool of its own for, which it can run in their place: Claude Code
and Copilot list `"web_search"`; see `tools/builtin`).

REQUEST = `(:model "ID:NAME" :session SESSION :system "…" :messages (MSG…)
:tools (TOOL-SPEC…) :thinking LEVEL :max-tokens N :provider-state PLIST
:on-event FN)`.  MSG = `(:role user|assistant|tool :content (BLOCK…))`.
TOOL-SPEC = `(:name :description :schema JSON-SCHEMA-PLIST)`.  For hosted
loops only the trailing user message is sent.  A REQUEST may also carry
`:builtin-tools`, a list of harness tool names (from `tools/builtin`):
the provider turns on its own tools in their place for this request,
and `:tools` lacks them.

Events delivered to `:on-event` (one plist each, in order):

```elisp
(:type start)
(:type text :delta "…")
(:type thinking :delta "…")
(:type tool-call :id "…" :name "…" :input PLIST :respond FN-OR-NIL)
   ;; :respond present ⇒ hosted loop; call it with a tool result
   ;; (:content "…" :is-error BOOL) and the provider continues the turn.
(:type tool-result :id "…" :content "…" :is-error BOOL)  ; hosted loops echo results
(:type usage :input N :output N :cache-read N :cache-write N :cost F-OR-NIL :context N
       :list-cost F-OR-NIL :billing api|subscription|extra-usage|nil :plan ID)  ; see Usage record
(:type provider-state :state PLIST)     ; persist on the session
(:type activity :phase PHASE :tool NAME :chars N)  ; what the model is busy with, see below
(:type quota :windows (…))
(:type hint :text "…")                  ; provider-side notices (compaction, retries)
(:type done :stop-reason end-turn|tool-use|max-tokens|cancelled|error :error "…")
```

A provider that runs one of its own tools in place of a harness tool
(one the request's `:builtin-tools` names) reports its calls with three
events, all naming the harness tool and the provider's call id:
- `tool-call` with `:builtin t` and no `:respond`, once per call, as
  soon as the provider knows the call's input.  The agent records the
  call node (meta `:builtin t`), shows it running, and runs nothing.
- `(:type tool-permission :id ID :name NAME :input PLIST :respond FN)`
  when the provider wants to know whether the call may run.  The agent
  asks `tools/authorize`, so the harness's permission chain decides it
  as a call of NAME, and calls FN with the DECISION: `(:behavior allow
  ...)` or `(:behavior deny :message TEXT ...)`, TEXT being what the
  model is to be told.
- `tool-result`, which the agent records as the call's result (meta
  `:builtin t`, plus `:denied t` after a refusal).  Results of other
  calls, which hosted loops echo too, are not recorded twice.

A built-in call still open when the provider's request ends (`done`, or
the turn cancelled) gets an error result saying it got none, so every
call in the transcript has a result.

`activity` says what the model is busy with when its output alone would
not: PHASE `thinking` (a thinking block began, whether or not its text
streams), `writing` (a text block began), `tool-input` (the model writes
the input of a call to `:tool`, `:chars` characters so far, reported at
most every quarter second), `compacting`, or `waiting` (for the model
again).  The Claude provider sends all of them: the CLI streams a
thinking block without its text and a tool call's input as JSON
fragments, so without them a turn shows nothing for as long as the model
thinks or writes a large input.  The OpenAI provider sends `tool-input`.
Text deltas that are only whitespace are still text (a `"\n\n"` delta
separates paragraphs); the agent keeps them from opening a message.

Forking: `provider/fork` returns a new provider state that may be marked
pending (for the CLI: `(:cli-session-id PARENT :fork-pending t)`); the
first completion consumes it and emits a `provider-state` event that the
agent persists, replacing the pending one.  When it returns nil or
fails, the fork starts without provider state: copied as is, the
parent's would make the fork resume the parent's own CLI session.

Methods: `provider/list`, `provider/models &optional REFRESH` (cached union
across providers), `provider/model MODEL-ID` → MODEL, `provider/capabilities MODEL-ID`,
`provider/complete REQUEST` → HANDLE, `provider/fork MODEL-ID STATE` → promise,
`provider/quota PROVIDER-ID &optional REFRESH`.  The model used when nothing
more specific is configured is `harness-model`.

Billing and quota: `provider/quota` (PROVIDER-ID a symbol or its name;
REFRESH asks for fresh data first) returns a promise of QUOTA, nil when
the provider reports none:

```elisp
(:billing api|subscription|nil      ; who pays for the account's calls
 :plan "max" :plan-label "Claude Max" :account (:email "..." :organization "...")
 :auth "claude.ai"|"ANTHROPIC_API_KEY"|"bedrock"|...  :api-provider "firstParty"|...
 :available BOOL                    ; the plan reports quota windows
 :windows ((:name "5h" :label "Current session (5 hours)" :used FRACTION
            :resets FLOAT :severity "normal" :active BOOL :model "Fable") ...)
 :extra (:enabled BOOL :used F :limit F :currency "USD" :disabled-reason "...")
 :limit-status "allowed"|"allowed_warning"|"rejected"
 :using-extra BOOL                  ; calls draw on extra usage, billed at API prices
 :updated FLOAT)                    ; when the windows were last reported
```

Event `provider/quota-updated PROVIDER-ID QUOTA` fires whenever a
provider learns something new; the UI caches QUOTA from it.

The Claude provider learns the billing from the `account` of each CLI
process's initialize answer:
- an API key, an API key helper, a bearer token or a cloud provider
  bills per token;
- a claude.ai login (Pro, Max, Team, Enterprise) is a subscription.

Quota comes from the CLI's `get_usage` control request (the data behind
`/usage`, no model call) and from `rate_limit_event` messages.  It is
asked for again after a turn once `harness-provider-claude--quota-ttl`
(60 s) has passed.  With no CLI process running, a short-lived probe
process answers instead, sending no message.

Each result's `total_cost_usd` is a running total for the process,
seeded on `--resume` with the session's restored spend.  A turn
therefore costs the difference to the previous total, starting from the
`session.total_cost_usd` the spawn-time usage report gives.

The Claude provider never needs the CLI to bypass its permission
checks.  The CLI gets no built-in tools (`--tools ""`), only the
harness's MCP tools, whose calls the harness's permission system
decides.  `harness-provider-claude-permission-args` only has to let
them through.  It defaults to `--permission-mode default --allowedTools
mcp__harness__*`: a fixed mode, so no settings file starts the CLI in
plan or auto mode, plus an allow rule.  Where managed settings make the
CLI ignore such rules, `--permission-prompt-tool stdio` sends its
permission prompts to the harness instead, as `can_use_tool` control
requests; the harness allows its own tools and refuses any other.  A
tool call the CLI refuses on its own (`system/permission_denied`)
becomes a `hint` that names the setting.

The one exception is WebSearch, which stands in for web_search
(`harness-provider-claude-builtin-tools`; capability `:builtin-tools`).
A request whose `:builtin-tools` names web_search starts the CLI with
`--tools WebSearch`, plus `--permission-prompt-tool stdio` unless the
permission arguments already send the prompts somewhere or bypass the
checks, so the CLI asks before every search.  The model's `tool_use`
becomes a `tool-call` marked `:builtin` (named web_search), the
`can_use_tool` question a `tool-permission` that the harness's
permission chain answers (allow, or deny with the message for the
model), and the echoed `tool_result` a `tool-result`.  The process
records which tools it was started with, so a request that turns
WebSearch on or off restarts it with `--resume`.

The Bedrock provider (`provider-bedrock`) is a native loop over the
Converse API: one ConverseStream request per call, its binary event
stream decoded into `text`, `thinking`, `usage` and `tool-call` events.
Each entry of `harness-bedrock-endpoints` is a provider (default
`bedrock`); model ids are `ID:MODEL-ID`.  Its catalogue comes from
ListFoundationModels and ListInferenceProfiles; context windows and
prices, which Bedrock does not report, come from
`harness-bedrock--model-defaults`.  Usage events carry tokens and
`:billing api` but no cost, so `session/usage-add` prices them from the
catalogue.  Claude and Nova requests carry prompt cache points; Claude
reasoning returned with tool calls is kept and sent back with them while
the tool loop lasts.  `harness-http-request` takes `:binary t` for such
framings: the response then reaches `:on-chunk` as unibyte strings.

The Copilot provider (`copilot:` models) drives `copilot --headless
--stdio`, the GitHub Copilot CLI's server mode that GitHub's Copilot
SDKs use: JSON-RPC 2.0 framed by `Content-Length` headers, SDK protocol
version 3 or newer.  Per harness session one CLI process:
- `connect` then `auth.getStatus` start it; a CLI that is not logged
  in, too old, missing or silent fails the turn with what to do.
- `session.create` / `session.resume` open a Copilot session whose only
  tools are the harness's (external tools, `availableTools` set to their
  names) and whose system prompt is the harness's (`systemMessage` mode
  replace); resuming an open session again applies changed settings.
- The exception is Copilot's own web_search, which stands in for the
  harness's (`harness-provider-copilot-builtin-tools`; capability
  `:builtin-tools`).  A request whose `:builtin-tools` names it lists
  it in `availableTools` and sends no external tool of that name.  Its
  `tool.execution_start` (or the `toolRequests` of the model's
  `assistant.message`) becomes a `tool-call` marked `:builtin`, a
  `permission.requested` about it, matched by `toolCallId` or
  `toolName`, a `tool-permission` whose decision answers
  `session.permissions.handlePendingPermissionRequest` (approve-once,
  or reject with the message as feedback), and its
  `tool.execution_complete` a `tool-result`.  Which permission kind the
  CLI uses for web_search was not checked against the real CLI.
- `session.send` runs a turn.  `assistant.message_delta` and
  `assistant.reasoning_delta` stream, `external_tool.requested` becomes a
  `tool-call` whose `:respond` answers `session.tools.handlePendingToolCall`,
  `assistant.usage` reports each model call, `session.idle` ends the
  turn, and `session.abort` cancels it (the process is killed when it
  stays busy).  A request the CLI leaves unanswered (opening a session,
  forking one, sending) fails after `harness-provider-copilot--startup-timeout`
  (30 s) instead of hanging.
- The provider state is `(:copilot-session-id ID :model NAME)`; a fork's
  is `(:copilot-session-id PARENT :fork-pending t)`, which the first
  turn turns into `sessions.fork`.
- Side requests are one-off questions: naming, compaction and the
  permission judge.  A request is one when it sets `:max-tokens` (a turn
  of the conversation never caps its answer), when its provider state
  is not the one its session has recorded (naming brings a fork of it),
  or when its session record has no state at all (the judge's).  Any
  number of them run at once, beside the conversation's turn and beside
  each other, each in a throwaway session: a fork of the conversation
  its own state names, else of the one its session has recorded (so a
  summary for compaction sees the real conversation), else a new
  session.  They never write into the conversation, and their sessions
  are deleted afterwards (by the next process when theirs goes away
  first).  Only a new turn of the conversation takes over from the
  running one.

Copilot plans include a monthly allowance, counted in AI credits ($0.01
each, at each model's token prices) or, on the legacy billing, in
premium requests.  A turn's usage says `:billing subscription`, `:cost`
0 and as `:list-cost` the dollar value of the nano AI units the CLI
reports (none on the legacy billing: the catalogue's token prices price
it); `extra-usage` at that value once the allowance is used up and
additional usage is on.  Quota comes from `account.getQuota`
(`premium_interactions`: a window named `credits` or `premium`, plus
`:extra`) and from the snapshots in `assistant.usage`.  The catalogue
comes from `models.list` (context window, image input, reasoning
efforts, token prices as `:pricing`), or before `copilot login` from
`models.getBuiltInCatalog`, asked of a short-lived probe process when
no session process runs.

### tools

```elisp
(harness-define-tool "read_file"
  :label "Read file"                      ; required: the name people read
  :description "…"                       ; what the model sees
  :schema '(:type "object" :properties (:path (:type "string" :description "…")) :required ("path"))
  :kind read|write|exec|net|meta          ; permission class
  :paths (lambda (input) (list …))        ; paths touched, for the jail
  :coalescable t                          ; may be folded into a summary block in the UI
  :subject (lambda (input) "x.el")        ; what a call is about, or nil
  :handler (lambda (input ctx) …))        ; → RESULT | string | promise
```

A tool has two names: NAME, the identifier the model calls it by, and
its `:label`, a short name in sentence case for people ("Read file",
"Bash", "Web search").  The label is required (`harness-define-tool`
signals without one) and every UI shows it wherever it names a tool;
the identifier stays for the model, for configuration (permission
rules, `harness-perms--auto-allow-tools`) and in the text agents read
about other sessions (`session_read`).  `harness-tools-label NAME`
returns the label, or NAME for a tool nobody registered.
`harness-tool-title NAME INPUT` titles a call: the label, then a colon
and the `:subject` of INPUT ("Read file: x.el"), or the label alone
when the subject is nil.  Without a `:subject` function, or when it
fails, the subject is the first line of the first string in INPUT.
Tool-call nodes, permission prompts, the activity of a running turn and
ACP `tool_call` titles all carry this title.

CTX = `(:session-id ID :cwd "/abs/" :host PREFIX :call-id "…" :report FN)`;
`:report` accepts a string for progress.  RESULT = `(:content "…"
:is-error BOOL :attachments (…) :meta PLIST)`.

- `tools/list &optional SESSION-ID` → TOOL-SPECs `(:name :label
  :description :schema :kind :coalescable)`, filtered through sync
  filter `agent/tools` (value: list of names; args: session).  Without
  SESSION-ID every registered tool: how UIs learn the labels.
- `tools/execute SESSION-ID CALL` (CALL = `(:id :name :input)`) → promise of
  RESULT.  Pipeline: lookup → `permission/decide` (async filter) →
  handler (with `harness-tools--timeout`) → context-bomb guard → sync
  filter `tools/result` → events `tools/started`, `tools/finished`.
- `tools/builtin SESSION-ID` returns the names of the harness tools
  that the session's provider runs a tool of its own for, and
  `tools/list` leaves them out.  They must be in the provider's
  `:builtin-tools` capability, among the tools the session gets
  otherwise, and picked by sync filter `agent/builtin-tools` (value:
  list of names, initially nil; args: session, the names the provider
  offers); tools-web picks web_search (see below).  The agent passes
  them in the request's `:builtin-tools`.
- `tools/authorize SESSION-ID CALL` (CALL = `(:id :name :input :kind)`)
  returns a promise of the DECISION on a call the provider runs itself.
  It comes from the same `permission/decide` chain as `tools/execute`,
  judged as a call of the harness tool NAME (its kind and paths; else
  CALL's `:kind`, else exec; the REQUEST carries `:builtin t`), and
  nothing runs.  Emits `permission/decided`.  The `:behavior` is allow
  or deny; a denial carries `:message`, the text `tools/execute` would
  have returned.
- Context bomb: outputs over `harness-tools-max-output-chars` (30000) are
  saved to `harness-state-directory/outputs/CALL-ID.txt` and replaced
  by the head plus an instruction to range-read that file.
- Denied calls return `(:is-error t :denied t :content "Denied: REASON. HINT")`.
  The agent keeps `:denied t` in the `:meta` of the call's tool-result
  node, so a view can tell a call the permission system refused, which
  never ran, from one that ran and failed (`harness-ui-tool-outcome`).

### perms

Async filter `permission/decide`: value is a DECISION
`(:behavior allow|deny|ask :reason "…" :input UPDATED :final BOOL)`,
args are the REQUEST `(:session SESSION :tool NAME :input PLIST :kind KIND
:paths (…))`.  Chain (priority): 5 dir-request, 7 sandbox-guard, 10 jail,
20 mode, 30 auto (LLM judge), 40 non-interactive, 90 ask-user (turns `ask`
into a pending request and resolves when answered).

- The sandbox guard asks `sandbox/check-command` about every `exec` call
  whose input has a `:command` (the bash tool), passing the directory it
  runs in and the session's own worktree (`:worktree`, else `:cwd`).  A
  refusal is a final deny, in every mode, yolo and standing rules
  included: the command would do damage only because it runs sandboxed
  (see sandbox).  A guard that fails lets the chain go on.

- `permission/answer SESSION-ID PENDING-ID ANSWER` — ANSWER
  `(:behavior allow|deny :scope once|session|always :reason)`, or an
  option id string such as "allow-session" (what ACP clients send back).
- The jail asks instead of denying when a path lies outside the roots
  and someone can answer: a pending `permission` request whose payload
  carries `:dir` and the options allow-once / allow-session (grant the
  directory to the session) / allow-always (add it to
  `harness-allowed-directories`) / deny-once.  After a grant the rest
  of the chain still decides the call itself.  Non-interactive sessions
  are denied with a hint as before.  The prompt names the directory
  with symbolic links resolved, since that is what the jail compares
  and what a grant opens.
- Agents ask for a directory themselves with the `request_directory_access`
  tool (`path`, `reason`).  The dir-request stage owns that tool's
  decision and always makes it final, so the mode, standing rules,
  `harness-perms--auto-allow-tools` and the auto judge never see it.
  In every mode, auto and yolo included, a directory is granted only
  by a person answering the prompt.  A directory that is already
  reachable is allowed at once and nothing is granted.  Non-interactive
  sessions are denied with a hint.  Otherwise the session blocks on a
  `permission` prompt (`:dir`, the agent's reason, options
  allow-session / allow-always / deny-once; a generic allow-once
  answer grants to the session).  The handler then tells the agent
  what it can reach.  Being a permission and not a question, the
  prompt cannot be answered by another agent through `session_control`.
  The auto judge is also told to deny calls that widen the agent's own
  permissions some other way (for example `harness-allowed-directories`
  in `.dir-locals.el`, the permission mode, or the sandbox).
- `permission/allow-dir SESSION-ID DIR &optional SCOPE` (SCOPE `always`
  grants every session), `permission/revoke-dir SESSION-ID DIR`,
  `permission/dirs SESSION-ID` (`(:dir :source cwd|worktree|config|session|outputs
  :revocable)` plists, for the directory buffer), `permission/allowed-dirs SESSION-ID`
  (the full effective root list), `permission/rules SESSION-ID`
  (`(:mode :non-interactive :auto-allow :session :always :roots)`),
  `permission/pending SESSION-ID`.
- Session directory grants are stored on the session record
  (`:allowed-dirs`), so they survive restarts and forks inherit them.
- Rules are plists `(:tool NAME-or-nil :kind KIND-or-nil :behavior allow|deny)`;
  session rules live in memory, always-rules in `harness-perms-rules`.
  The mode stage checks them first, before the auto-allow list and the mode.
- Events `permission/requested SID PENDING` (PENDING `(:id :kind permission
  :payload (:tool :input :kind :paths :call-id :title :options))`, plus
  `:dir` and `:reason` for a directory prompt; UIs offer only the
  listed `:options`),
  `permission/decided SID REQUEST DECISION`, `permission/dir-allowed SID DIR`.
- Modes: `ask` (reads inside the jail allowed; everything else asks),
  `accept-edits` (reads/writes inside the jail allowed; exec/net ask),
  `auto` (reads inside the jail allowed; a cheap model,
  `harness-perms-auto-model`, decides the rest with a reason; falls back
  to ask), `yolo` (allow everything; the jail still applies).  Tools in
  `harness-perms--auto-allow-tools` are allowed in every mode: the meta
  tools, skill and Emacs lookups, `web_search`, which only sends its
  query to the configured search provider, so task sessions can search,
  and `notify`, which only reaches the user through the notification
  providers they set up, so unattended sessions can say they need them.
  The model provider's own search, standing in for `web_search` (see
  `tools/builtin`), is decided as `web_search` too, so the same rules
  and the same auto-allow apply to it.
  `web_fetch` reaches any URL and stays with the mode (the judge in auto).
- Jail denials are final and carry a constructive hint listing the
  allowed roots and how to widen them.
- Non-interactive: `ask` becomes `deny` with the reason "non-interactive
  mode: the user is away" and a hint to find another approach inside the
  permitted scope; a steering message is sent to the agent once per call.
  The session's own `:non-interactive` switch decides, off as much as
  on.  It starts from `harness-non-interactive` when the session is
  created (an explicit false turns it off whatever the setting says);
  forks and sub-agents start with their parent's.  Changing the setting
  later leaves the sessions that exist alone.  The setting decides by
  itself only for a request without a session record.

### sandbox

- `sandbox/wrap CWD COMMAND-LIST &optional (:network t :writable (…) :readable (…))` →
  command list (bwrap / systemd-run / plain).  `sandbox/status` →
  `(:backend bwrap|systemd|none :available (…) :policy …)`.  Fails closed
  when `harness-sandbox-policy` is `required` and no backend exists.
- A CWD inside a linked git worktree also gets the repository's common
  git directory read-write (its `hooks/` and `config` stay read-only, so
  nothing planted there runs when the harness uses git unconfined) and
  the host's `user.name`/`user.email` as `GIT_AUTHOR_*`/`GIT_COMMITTER_*`,
  so worktree sessions can commit.
- Git in the sandbox sees no other worktree's files, so it takes every
  other worktree for deleted.  `sandbox/check-command CWD COMMAND
  &optional OWN` gives nil or `(:reason :hint)`: why a shell command must
  not run confined in CWD.  It refuses `git worktree prune`, and `git
  worktree unlock|remove|move` of a worktree that is outside OWN (the
  session's own worktree, by default the one holding CWD), is OWN itself,
  is locked by the harness (reason `harness: ...`), or cannot be told
  (variables, globs, `xargs`).  It reads the command line as the shell
  does, closely enough: quotes, operators and redirections, `$(...)` and
  backticks, `sh -c` and `eval` scripts, wrappers (env, timeout, xargs,
  find...), `cd`, git's global options (`-C`, `-c alias.NAME=...`), and
  worktrees named by the end of their path, as git allows; a `cd` in a
  subshell or a pipe does not carry on.  Shell variables, scripts run
  from files and aliases from git's config are not resolved: the locks
  protect the harness's worktrees from those.  The reason points to
  `worktree/prune` and `worktree/remove`, which run outside the sandbox.
  Commands that run unconfined (no backend, policy `off`, remote CWD)
  are never refused.  The perms module's sandbox guard calls it.

### agent

- `agent/prompt SESSION-ID BLOCKS &optional OPTS` → promise of
  `(:stop-reason …)`.  Idle session: starts a turn.  Running session:
  steering — the text is queued and injected at the next step boundary
  (appended to the next tool result, or sent as the next user turn if
  the model stops first), and only once.  OPTS `:queue` true only
  queues, even while a turn runs.  An empty message is refused.  An
  inactive session is resumed first (`session/resume`), so a message
  sent to a closed session brings it back; queueing leaves it closed.
- `agent/cancel SESSION-ID`.
- `agent/send-queue SESSION-ID` — sends every queued item as one turn.
- Sync filter `agent/system-prompt` (value string, args session); sync
  filter `agent/tools`; sync filter `agent/builtin-tools` (see
  `tools/builtin`); async filter `agent/before-turn` (value
  `(:proceed t :reason)`, args session) — budgets, merge holds and
  compaction hook in here; async filter `agent/step` at every step
  boundary (same value shape) — merge holds pause here.
- Events `agent/turn-started SID`, `agent/turn-ended SID REASON`,
  `agent/stream SID NODE-ID KIND DELTA` (kind text|thinking),
  `agent/tool-call SID NODE`, `agent/tool-result SID NODE`,
  `agent/activity-changed SID ACTIVITY`.
- Turn loop: build system prompt → messages → `provider/complete`;
  stream deltas into a live assistant/thinking node (created on the
  first delta with visible text: whitespace before it is held back and
  opens the node with that text, so a stray newline never makes an empty
  message; updated in place); on `tool-call` append a tool-call node, run
  `tools/execute`, append the tool-result node; native loops re-call the
  provider until `end-turn`; hosted loops respond through `:respond`.
  Steering is drained at every boundary (each tool result and each
  step), so it is delivered once; a model that stops with steering
  waiting gets one more step with it as the newest user message.
  `max-turns` (`harness-agent-max-steps`, 200) ends runaway loops.
- Streaming updates of the live node are not persisted one by one; on
  exit (`kill-emacs-hook`) and shutdown the text streamed so far is.
- Activity: `agent/activity SID` returns what the running turn does now,
  nil when none runs: `(:phase PHASE :since FLOAT ...)`, `:since` being
  when the phase began.  PHASE is `waiting` (for the model: at every
  step and after each tool), `thinking`, `writing`, `tool-input`
  (`:tool`, `:chars`), `compacting` (from the provider's `activity`
  events and the deltas), or `tool` while calls run: the oldest is
  `:tool` with `:title`, `:checking` until its permission is decided
  (its time then starts again), `:detail` the last line of its
  `tools/progress` (at most every `harness-agent--progress-interval`,
  0.5 s), and `:count` when several run.  Every change is announced as
  `agent/activity-changed`, with nil when the turn ends.  The state
  lives beside the turn records, so a reload keeps it.

### usage

- Subscribes `session/usage`; records to sqlite (`usage` table:
  ts, session, project, model, input, output, cache_read, cache_write, cost,
  turn, list_cost, billing; older tables gain the last two in place).
- `usage/summary &key group-by since until project session model billing` → rows
  `(:key :input :output :cache-read :cache-write :cost :list-cost :calls)`;
  group-by `project|model|day|hour|session|billing` (billing keys "api",
  "subscription", "extra-usage", "" when unrecorded); sorted by list
  cost.  `:cost` is what was billed, `:list-cost` the same usage at API
  prices (rows from before list costs count their cost).
- `usage/budgets`, `usage/set-budget BUDGET`, `usage/remove-budget ID`,
  `usage/budget-status ID &rest (:now)` (ID may be "session:SID" for a
  session's implicit budget) → `(:budget :spent :amount :remaining
  :fraction :hard :per-day :days-left :period-start :period-end
  :baseline)`;
  `usage/session-budgets SID`, `usage/plan-budget AMOUNT PERIOD DAYS`,
  `usage/totals`, `usage/series (:bucket day|hour …)`, `usage/record ROW`.
  BUDGET = `(:id :scope session|project|period :target ID-OR-ROOT
  :amount F :hard BOOL :period day|week|month :days business|all
  :baseline F :baseline-period-start "YYYY-MM-DD")`.
- A baseline is what was spent that the harness never recorded (other
  tools, the console, days before it kept usage), set by hand so a
  budget made mid-month does not start at $0.  `:spent` is the recorded cost plus
  the baseline that counts: a period budget's only while the current
  period starts on `:baseline-period-start` (set-budget fills in the
  period containing now, and moves any date or float time to its
  period's start), one without a period always.  The status's
  `:baseline` is that part, 0 otherwise.  nil or 0 clears it.
- `usage/fetch-api-cost &rest (:now)` gives a promise of this month's
  cost from Anthropic's Admin API (`GET /v1/organizations/cost_report`,
  UTC days, amounts in cents): `(:available t :amount :recorded
  :outside :period-start :since :until)`.  `:recorded` is what the
  harness recorded in that time for Claude calls billed per token,
  which the report counts too, and `:outside` the rest, offered as a
  month budget's baseline.  It needs an Admin API key
  (`harness-anthropic-admin-api-key`, ANTHROPIC_ADMIN_KEY, or
  auth-source host api.anthropic.com user admin); without one nothing
  is fetched and it gives `(:available nil :reason)`.  Pro and Max
  subscriptions have no cost report.
- Hard budgets block via `agent/before-turn`; soft ones emit
  `usage/budget-warning` and a session hint at 80% and 100%.  Budgets
  count billed cost, so calls a subscription covers spend none; a
  baseline counts toward both.
- Pricing: `usage/price MODEL-ID USAGE` → cost using the model's pricing.

### compaction

- `compaction/compact SESSION-ID` → promise; summarises the transcript
  with the session's model, appends a `compaction` node whose `:meta`
  points at the compacted head, sets it as head, hints before/after.
- Auto: `agent/before-turn` compacts when the context comes within
  `harness-compaction--context-reserve` of the window unless the provider
  reports `:compaction hosted`.

### naming

- `naming/name SESSION-ID` → promise of name.  Auto after the first
  turn ends when the session has no name: forks provider state when
  possible so the cached prefix is reused; hints "naming…" then the result.
- Sync filter `naming/system-prompt` (value string, args session) lets
  modules add to `harness-naming--base-system-prompt` per session (tasks ask
  for ticket titles).

### skills

- Scans `harness-skills-directories` (defaults: `~/.claude/skills`,
  `./.claude/skills`, `~/.config/harness/skills`, `./.harness/skills`)
  for `NAME/SKILL.md` with front matter.
- `skills/list &optional CWD`, `skills/search QUERY &optional CWD`,
  `skills/load NAME &optional CWD` → `(:name :description :content :path :source :files)`,
  `skills/refresh`, `skills/expand TEXT CWD` → `(:text EXPANDED :skills (…))`
  (explicit `/name` or `@skill:name` references get the skill content
  attached; the compose UI calls this over ACP).
- Tools `skill_search`, `skill_load`.  Adds a short skills index to the
  system prompt via `agent/system-prompt`.

### worktree

- `worktree/list ROOT`, `worktree/create ROOT &key branch path base`,
  `worktree/remove ROOT PATH &optional FORCE`, `worktree/prune ROOT`,
  `worktree/lock ROOT PATH &optional REASON`,
  `worktree/unlock ROOT PATH &optional ANY`, `worktree/lock-existing ROOT`,
  `worktree/root-of PATH`, `worktree/branch PATH`,
  `worktree/status PATH` → `(:dirty :ahead :behind :branch)`.  All return promises.
- Sessions created with `:worktree PATH` get `:cwd` = PATH.
- `worktree/list` gives `(:path :branch :head :bare :detached :locked
  :main)` plists, plus `:lock-reason`, `:prunable` (git would prune it)
  and `:missing` (its directory is gone) when they apply.
- Locks: `worktree/create` locks every worktree it makes (`git worktree
  add --lock --reason "harness: BRANCH"`).  Agents run git in a sandbox
  that shows only their own worktree, where `git worktree prune` takes
  every other worktree for deleted and drops its registration: its files
  stay, without an index, and git fails in them.  Prune never touches a
  locked worktree, and git removes one only when forced twice.  The
  harness's locks are those whose reason starts with `harness: `
  (`harness-worktree-lock-prefix`); other locks are left alone.
  - `worktree/lock` (default reason `harness: BRANCH`; a locked worktree
    keeps its lock) and `worktree/unlock` (lifts only a harness lock,
    unless ANY) resolve to non-nil when they changed something and emit
    `worktree/locked` / `worktree/unlocked` (ROOT PATH).
  - The merge queue unlocks a child's worktree once its branch is
    merged, so merged worktrees can be pruned again; a failed, aborted or
    cancelled merge leaves the lock on.  A merged task that goes back to
    work locks its worktree again.
  - `worktree/remove` lifts a harness lock first, and puts it back when
    git still refuses (local changes).  FORCE is `git worktree remove -f
    -f`, past local changes and any lock.  Task archive and the worktree
    list's `d` go through it.
  - `worktree/prune` runs `git worktree prune -v` outside the sandbox,
    where git sees every worktree, so it prunes only worktrees really
    gone, and skips locked ones as git does.  It returns git's lines plus
    a `Kept ...` line for each locked worktree whose directory is missing
    (`worktree/remove` takes those away).
  - Worktrees made before locks: `worktree/lock-existing ROOT` locks the
    registered worktrees in the directory the harness puts its worktrees
    in (`harness-worktree-directory-function`, ROOT/.worktrees/ by
    default) that have no lock, whose directory exists, and that the sync
    filter `worktree/lock-existing-p` (value t, args ROOT WORKTREE) does
    not turn down; the tasks module turns down merged tasks' worktrees.
    The main checkout and foreign worktrees are never touched.  On
    `harness/started` and `harness/reloaded` it runs for the main
    checkout of every repository the sessions work in, once per
    repository: worktree-locks.json in the state directory lists those
    done, so a merged and unlocked worktree stays unlocked.  The
    worktree list runs it again with `L` (for worktrees registered again
    by hand after a prune), and `l` locks or unlocks the worktree at
    point.
  - The sandbox module's `sandbox/check-command`, through the perms
    module's sandbox guard, refuses `git worktree prune` and touching
    other worktrees in sandboxed commands (see sandbox).
- Nothing re-registers a worktree whose registration was pruned anyway;
  that is a repair by hand, after which `L` locks it.

### merge

- `merge/enqueue CHILD-SID PARENT-SID` → position; `merge/queue PARENT-SID`;
  `merge/cancel CHILD-SID`.  When the parent reaches a step boundary
  (`agent/step` filter) or is idle, the head of the queue gets the lock:
  the harness runs `git merge --no-ff` of the child's branch in the
  parent's cwd; on conflict the child session receives a steering
  message describing the conflicts and its jail is widened to the
  parent's cwd until it resolves; then the lock passes on.  A merged
  child's worktree loses the harness's lock (`worktree/unlock`; see
  worktree).
- `merge/status CHILD-SID`; the `merge_done` tool releases a conflict lock.
- Events `merge/queued CHILD PARENT POSITION`, `merge/started`,
  `merge/conflict CHILD PARENT FILES`, `merge/finished CHILD PARENT STATUS`
  (merged|failed|aborted|cancelled).

### tasks

Task mode: one session per task.  TASK =
`(:id "t-…" :project ROOT :cwd DIR :prompt "…" :attachments (…)
:state pending|refining|active|merging|review|done
:column pending|needs-input|active|review|done
:backlog BOOL :note "the words a backlog task was written up from" :refined F
:session SID :outcome nil|end-turn|error|cancelled|merge-failed|merged|…
:error "…" :worktree DIR :branch NAME :base NAME :merge-status nil|queued|merging|conflict
:conflicts (FILE…) :merged BOOL :archived BOOL :created F :started F :finished F
:verified BOOL :verified-at F :feedback ((:text "..." :at F) ...)
:file "docs/tasks/ID-SLUG.md" :updated F :extra (RAW-ENTRY ...))`.
`:column` is derived on every read: `needs-input` when the session is
blocked on a request or the task stopped part way, `review` while its
finished work waits for the user's verdict.  `:file` (relative
to `:project`), `:updated` (when the harness last wrote the file) and
`:extra` (the raw frontmatter entries the harness does not know) belong
to the task's file (below); the record also keeps `:file-base` and
`:file-synced` for it, which methods and events leave out.

- `task/submit CWD PROMPT &optional (:attachments :model :permission-mode
  :thinking :non-interactive)` → task; it starts when one of
  `harness-tasks-max-running` slots is free.  Missing options come from
  `harness-tasks-model`, `-permission-mode` (auto), `-thinking` and
  `-non-interactive` (on); an explicit false turns non-interactive off.
  With `:refine` the task goes to the backlog instead (below).
- Backlog refinement (once called grooming): a `:refine` task is
  `refining` while a session at its directory -- `ask` and
  non-interactive, so read-only, `harness-tasks-refine-model` and
  `-refine-thinking` (low) -- writes it up as told by
  `harness-tasks--refine-prompt` (brief, no changes, no questions, a
  self-contained ticket: title line, what and why, what to change, how to
  tell it is done, open questions); after `harness-tasks--refine-tool-calls`
  (8) tool calls it is steered once to write up with what it has, which
  keeps it brief.  Its final reply becomes `:prompt`
  (the original stays in `:note`) and the task waits in `pending` with
  `:backlog t`: the scheduler never starts it, only `task/start`, so the
  backlog survives restarts.  A turn of a backlog task's session before
  it starts is feedback (`task/prompt`) and rewrites the write-up; a
  write-up that stops needs input (restarts: below).
  `task/refine ID &optional TEXT` refines a queued task or
  writes one up again.  Starting continues the same session: in git it
  moves into the task's new worktree (`session/update :cwd :worktree`),
  its provider conversation is dropped (the Claude CLI keeps
  conversations per directory) and it is prompted with
  `harness-tasks--start-message`, the write-up and the quoted note, under the
  task's own settings.  Dropping a backlog task deletes its session.
- `task/adoptable &optional CWD` lists the project's open sessions that
  are not tasks; `task/adopt SESSION-ID` makes one a task (its first
  message is the prompt; a worktree session keeps its worktree and merges
  like any task; an idle one waits in `needs-input` with `:outcome adopted`).
- Starting: in a git project (`harness-tasks-worktrees`) `worktree/create`
  on branch `harness-tasks-branch-prefix` + slug + id, then a session in
  that worktree (`harness-tasks-permission-mode`, non-interactive by
  default) prompted with the task; a system-prompt section tells it to
  commit on its branch and not merge.  Outside git the session runs in CWD.
  The worktree stays locked until its branch is merged; a follow-up to
  a merged task locks it again (see worktree).
- The session's name is the task's title: `naming/system-prompt` adds
  `harness-tasks--naming-instructions` (nil for none) so the model titles task
  sessions like tickets.
- With nothing to review (below), a turn ending `end-turn` queues
  `merge/enqueue SID TARGET`, TARGET being the project's root session
  named `harness-tasks--merge-session-name`
  (created on demand); `merge/finished … merged` makes the task `done`.
  Failures the agent can fix (uncommitted work) are steered by the merge
  queue; others, or more than `harness-tasks--merge-attempts`, set
  `:outcome merge-failed`.  Outside git `end-turn` makes it `done`.
- Review (`harness-tasks-require-verification`, default t): finished
  work is not done until the user has looked at it.  A turn ending
  `end-turn` puts the task in `review` instead, and emits `task/review
  TASK`; in git its branch waits unmerged, so nothing reaches the base
  branch unreviewed.  `task/verify ID` accepts the work (`:verified t
  :verified-at F`): its branch goes through the merge queue as above
  and the task is `done` once merged (outside git, or when the branch
  merged already, at once).  `task/reject ID FEEDBACK &optional
  ATTACHMENTS` sends it back: the feedback goes to the same session, in
  its own worktree and with its provider conversation, as a prompt
  opened by `harness-tasks--reject-message`; the task is `active` again and
  returns to `review` when that turn ends.  Each round is appended to
  `:feedback`.  Any other new turn of work (a follow-up, a message from
  the chat) clears the verification, so it is reviewed again; the merge
  queue's own steering (commit first) does not.  Only clean ends go to
  review: a turn that stops needs input as before, and `task/complete`
  (Mark done) counts as accepting the work.  A merge that finishes for
  work nobody verified (one queued before the option was turned on)
  puts the task in review, merged.  `task/archive` works in review too;
  `task/archive-done` leaves those tasks alone.  With the option nil a
  task is done once merged, or outside git once its turn ends.
- A turn starting in a task's session makes the task active again, so a
  message sent from a done task's chat buffer reopens it; an archived task
  comes back to the board.
- `task/list &optional CWD`, `task/get ID`, `task/settings &optional CWD`,
  `task/start ID` (ignores the limit; not while a write-up runs),
  `task/update ID PROMPT` (not started only; writes a stopped write-up by
  hand), `task/prompt ID TEXT &optional ATTACHMENTS` (follow-up or
  steering; reopens), `task/refine ID &optional TEXT`,
  `task/merge ID` (retry; not in review), `task/verify ID`,
  `task/reject ID FEEDBACK &optional ATTACHMENTS` (both in review only),
  `task/complete ID` (counts as verified), `task/archive ID &optional
  RESTORE` (deactivates the session; removes a merged task's worktree and
  branch), `task/archive-done &optional CWD`, `task/cancel ID` (drops a
  task that has not started, stops a running turn or write-up),
  `task/delete ID &optional DELETE-SESSION` (keeps the worktree).
- Events `task/changed TASK`, `task/deleted ID`, `task/review TASK` (its
  work waits for the user's review), `task/done TASK HOW` (it became
  done; HOW is `merged` when the merge queue merged its branch,
  `finished` when its turn ended with nothing to merge or review,
  `verified` when the user verified it with nothing left to merge, or
  `completed` when it was marked done by hand, `task/complete`; a task
  already done emits nothing).  Records are written
  shortly after a change and on exit (`harness-tasks-flush`), each into
  its project's store; a store whose text would not change is skipped.
- Stores: a git project's records go to `harness/tasks.json` in the
  repository's common git directory (`harness-files-git-common-dir`,
  read from `.git` and `commondir` files, no git process):
  `.git/harness/tasks.json` of the main checkout, the same file from
  every worktree and out of every working tree, so `git status`, commits,
  merges and the merge queue never see it.  It is
  `{"state-directory": DIR, "tasks": [...]}`, DIR being the state
  directory of the harness it belongs to, which holds the tasks'
  sessions: a harness with another state directory that still exists
  leaves it alone and keeps its tasks of that repository in its own
  state directory; one whose owner is gone takes it over.  Other
  projects' records, and every record with
  `harness-tasks-store-in-repository` nil, are a JSON array in
  `tasks.json` in the state directory.  `task-stores.json` there lists
  the repository stores, which a start reads before `tasks.json` (a
  repository copy wins), and `task/list CWD` reads its project's store if
  the list missed it.  Each save puts every record where its project
  keeps it, so records move by themselves: the first save after an
  upgrade (or after an in-place reload) moves git projects' tasks out of
  `tasks.json` into their repositories, copying it to `tasks.json.bak`
  first, and turning the option off brings them back.  A repository
  store left without records is deleted; one that cannot be written
  leaves its records in `tasks.json`.
- Task files: a git project whose tasks this harness keeps in its own
  repository store also has a markdown file per unarchived task in
  `harness-tasks-directory` (default `docs/tasks`, relative to the main
  checkout; a layered config key, so a project's `.dir-locals.el` can
  name another folder, or nil for none).  Other projects, a repository
  another harness owns, and `harness-tasks-store-in-repository` nil (the
  tests and the dev daemon) get none.  Files go only into the main
  checkout, never into a task's worktree, and the harness never commits
  them.  The store keeps the whole record; the files show what people
  read, and take their edits.  A file:

  ```markdown
  ---
  id: t-k3j9x2ab
  title: Add CSV export to reports
  state: pending
  column: pending
  backlog: true
  session: 5b3e8a0c-6d1f-4a7e-9c2b-0f1e2d3c4b5a
  model: claude:claude-fable-5-1
  created: 2026-10-01T13:20:01Z
  refined: 2026-10-01T13:22:40Z
  updated: 2026-10-01T13:22:40Z
  labels: [reports]
  ---

  # Add CSV export to reports

  Reports should be exportable as CSV ...

  <!-- harness:request -->
  ## Request

  > csv export for the reports page

  <!-- harness:plan -->
  ## Plan

  1. ...
  ```

  - Frontmatter, in this order and only when set: `id`, `title` (the
    session's name, else the prompt's first line), `state`, `column`,
    `backlog`, `outcome`, `error` (300 characters at most), `session`,
    `branch`, `base`, `merge` (the merge status, or `merged`), `model`,
    `thinking`, `created`, `started`, `refined`, `finished`, `verified`
    (when the user verified the work), `updated` (times in ISO 8601 UTC,
    to the second).  Keys the harness does not know follow, as written.
    It is a YAML subset the module reads and writes itself: `key: value`
    lines whose values are plain, single- or double-quoted or `|` / `>`
    block scalars, or lists (`[a, b]`, `- a` lines).  Strings are written
    plain when that reads back the same, else double-quoted.
  - Body: the prompt, its first line a level-1 heading when it reads as
    a title (short, and no markdown of its own); then, each behind a
    `<!-- harness:NAME -->` marker line, the sections the harness keeps:
    `request` (`:note` quoted, once a write-up replaced it), `review`
    (each round of `:feedback`, quoted under a `### Sent back TIME`
    heading, oldest first; read back only when the file brings a lost
    task back) and `plan` (the session's plan, never read back).
    Reading takes the text before the first marker outside a code fence
    as the prompt, a leading `# Title` (or a setext `===` title)
    becoming its plain first line.
  - Names: `ID-SLUG.md` (a slug of the title) for the files the harness
    makes.  A file keeps its name, and `:file` follows a file renamed by
    hand.  `README.md`, `index.md`, `template.md` and names starting
    with `.`, `_`, `#` or `~` are no tasks
    (`harness-tasks--directory-ignore`); subfolders are not read.
  - Writing: each save first reads what changed in the folder, then
    writes the file of every task whose rendering (without `updated`)
    changed since its file was last in step (`:file-synced`), before the
    stores.  Archiving a task moves its file into the folder's
    `harness-tasks-directory-archive` subfolder (`archive`; nil deletes
    it instead) and restoring the task moves it back; deleting or
    cancelling a task deletes its file; a project that picks another
    folder gets its files moved there.
  - Reading: the files whose mtime or size changed are read on load (the
    folders of the loaded tasks' projects), by `task/list` (its
    project's folder; every known one without CWD), before each save,
    and every `harness-tasks--directory-poll` seconds (default 2; nil for
    none, as file notifications never reach the batch harness process).
    An edit is what differs from what the file said last (`:file-base`),
    so a file the harness has yet to write again is no edit.  Taken are
    the prompt and the request; `title`, which renames the task's
    session; `model` and `thinking` of a task that has not started; and
    `state: done`, which completes the task (`task/complete`; a task in
    review is verified, `task/verify`).  The other known fields, and the
    review and plan sections, are the harness's: a file that contradicts
    them is written again, and one that contradicts nothing is left as
    written until its task changes.
  - A file no task has becomes one, with its `id` when that is free,
    else a fresh one: `pending` in the backlog (only `task/start` starts
    it, and no permission mode is read from a file), or `review` or
    `done` as written, with its rounds of feedback and its verification.
    Without a heading, a frontmatter `title` becomes the prompt's first
    line.  Its `session`, when that still exists, works in the project
    and is no other task's, makes it the task it was (state, outcome,
    worktree from the session), except that nothing carries on by
    itself: a task that was at work waits with `:outcome interrupted`,
    and `merging` comes back `active`.  So a lost store comes back from
    the files, at load or when the board is opened.  A file without
    frontmatter is a task all the same; an empty one, or one whose `---`
    frontmatter never closes, is not (yet).
  - A file deleted by hand, or moved out of the folder (into `archive/`,
    say), archives its task when the task is `pending`, `review` or
    `done` and nothing works on it; a task in progress gets its file
    back.  A file that comes back to the folder (found by its `id`)
    brings its archived task back.
- Restarts: when the module starts, an active task without an outcome
  that nothing in this process works on was interrupted.  Without a
  session it starts over (as pending, or in its worktree when it has
  one); otherwise, with `harness-tasks-resume-interrupted` (default t),
  its session is resumed and sent `harness-tasks--resume-prompt` (the task
  itself when it never got it), past the concurrency limit since it held
  a slot before; with nil it waits in needs-input with `:outcome
  interrupted`.  A backlog task cut short before its session got the
  work starts again (with nil: back to the backlog), keeping a worktree
  it got; a write-up cut short is written again by its session (with
  nil: `:outcome interrupted`).  Merges in flight are queued again, and
  tasks in review wait on for the user.

### notifications

Any module tells the user something with `notification/send`, and
providers deliver it.  NOTIFICATION = `(:title :body :urgency
low|normal|critical :source :kind :session :task :project :url)`: a
title or a body is required, urgency defaults to normal, `:source` and
`:kind` say who sends it and why, `:session`, `:task` and `:project` say
what it is about (a click on a desktop notification opens it), and
`:url` is a link for providers that can open one.  `notification/send`
fills in `:id` and `:ts`.

- `notification/send NOTIFICATION &optional PROVIDERS` -> promise of
  `(:id ID :results ((:provider NAME :status sent|failed|skipped :detail
  TEXT :error TEXT) ...))`, a result per provider, in order.  PROVIDERS
  (names; strings accepted) overrides `harness-notifications-providers`
  (default `(system gotify)`).  The sync filter
  `notification/before-send` (value NOTIFICATION, no args) sees it first
  and may change it, or drop it by returning nil (the result is then
  `(:id ID :dropped t :results nil)`).  Every provider that is set up
  gets it at once; one that signals, rejects or takes longer than
  `harness-notifications--timeout` (30 s) is `failed`, one not set up, or
  unknown, is `skipped`, and neither holds up the others.  It never
  rejects for a provider, and signals when the notification has neither
  a title nor a body.  Event `notification/sent NOTIFICATION RESULTS`.
- `notification/providers` -> `(:name :label :doc :ready :enabled)` for
  every provider, in definition order.
- `(harness-notifications-define-provider 'NAME :label :doc :send FN
  :ready FN)` adds or replaces a provider.  SEND gets the NOTIFICATION
  and returns anything or a promise (a plist's `:detail` says how it
  went); it signals or rejects when it cannot deliver.  READY (no
  arguments, quick: it runs before every notification) says whether it
  is set up; without it, it always is.
- `system`: a desktop notification.  With a client connected
  (`acp/status`), the harness asks it to show one with `client/request
  "_harness/client/notify"` (params `:id :title :body :urgency`, plus
  `:source :kind :session :task :project :url` when set; the URL ends
  the body, and without a title the body's first line is the title), so
  it shows on the user's desktop even for a remote harness, and a click
  on it opens what it is about (see Presentation contracts).  When no
  client answers within 10 s, or every client declines, the harness
  process shows it itself.  Ready while a client is connected or this
  process has a desktop backend.
- Desktop backends (lisp/harness-notifications-desktop.el, loaded on
  both sides): `harness-notifications-desktop-notify &rest (:title :body
  :urgency :on-action)` -> promise of `(:backend NAME :id ID)`.
  `harness-notifications-desktop-backend` is `auto` (the first that
  works of `notify-send`, `dbus`, `osascript`, `w32`), one of those, or
  a function of that plist.  notify-send runs as an asynchronous process
  with `--print-id` (an id says the server took it) and, with
  `:on-action`, `--action=default=Open`: the process then waits and
  prints `default` when the notification is clicked (at most
  `harness-notifications-desktop-max-waiting` processes wait; an old
  notify-send without these options shows a plain notification).  D-Bus
  calls org.freedesktop.Notifications asynchronously and hears
  ActionInvoked in an interactive Emacs; a batch Emacs, which reads no
  D-Bus events, calls it synchronously with a 2 s timeout and hears no
  clicks.  The body is escaped for markup (`&`, `<`, `>`); the title is
  never markup.
- `gotify`: `POST URL/message` through harness-http, the application
  token in `X-Gotify-Key` (so never on a command line), with `title`,
  `message` (the title when there is no body), `priority` (from
  `harness-notifications--gotify-priorities`: low 2, normal 5, critical 8) and `extras`
  (`client::display` `text/plain`; `client::notification` `click.url`
  for `:url`).  Ready once an address and a token are found:
  `harness-gotify-url` and `harness-gotify-token` (a secret), else the
  GOTIFY_URL and GOTIFY_TOKEN environment variables, else for the token
  auth-source (the URL's host, login `harness`; its answer is trusted
  for 5 minutes).  Failures read `Gotify: HTTP 401 Unauthorized: ...`.

### tasks-notify

Notifies the user about tasks through `notification/send` (`:source
"tasks"`, `:task :session :project` set, urgency normal) for the events
in `harness-tasks-notify-events` (default `(review done)`), sent to
`harness-tasks-notify-providers` (nil: the default providers):

- `review` (`task/review`): "Ready for review: TITLE", body "PROJECT: "
  and the start of the agent's last reply (200 characters on one line),
  or "waits for you to verify it or send it back".  Kind `task-review`.
- `done` (`task/done` with HOW `merged` or `finished`; `verified` and
  `completed` are the user's own doing): "Task done: TITLE", body
  "PROJECT: merged into BASE" (or "merged"), or "PROJECT: finished".
  Kind `task-done`.
- `needs-input` (opt-in, from `task/changed`): a task whose `:column`
  turns `needs-input` from another column it was seen in, unless its
  outcome is `cancelled`: "Task needs you: TITLE", body "PROJECT: has a
  question for you", "needs your permission" or "stopped: OUTCOME" and
  its error.  Kind `task-needs-input`.

TITLE is the session's name, else the prompt's first line without its
leading `#`, at most 80 characters; PROJECT is `project/name` of the
task's project.

### tools-fs, tools-shell, tools-emacs, tools-web, tools-agent, tools-sessions, tools-notify

Tool names, labels and inputs (all paths relative to cwd or absolute;
TRAMP prefixes come from the session host):

| tool | label | input | kind |
|---|---|---|---|
| `read_file` | Read file | path, offset, limit | read |
| `write_file` | Write file | path, content | write |
| `edit_file` | Edit file | path, old_string, new_string, replace_all | write |
| `list_dir` | List directory | path, depth | read |
| `glob` | Find files | pattern, path | read |
| `grep` | Search files | pattern, path, glob, case_sensitive, max_results | read |
| `bash` | Bash | command, timeout, cwd | exec |
| `elisp` | Emacs Lisp | code | exec |
| `emacs_buffers` | List buffers | filter, all | read |
| `emacs_buffer` | Read buffer | name, offset, limit | read |
| `emacs_describe` | Describe symbol | symbol | read |
| `web_search` | Web search | query, count | net |
| `web_fetch` | Fetch page | url, max_chars | net |
| `emacs_messages` | Emacs messages | count | read |
| `ask_user` | Question | question, options (strings, or `{label, diagram}` / `{label, image}` objects: every option has a diagram or none does), allow_free_text | meta (answered with `question/answer SID PID ANSWER`; event `question/asked`) |
| `request_directory_access` | Request access | path, reason | meta (perms module; decided only by the user's answer to a directory prompt, in every mode) |
| `session_info` | Session info | — | read |
| `plan` | Plan | plan | meta |
| `todo_write` | Todo list | todos | meta |
| `spawn_agent` | Sub-agent | prompt, fork, model, name | meta |
| `skill_search` / `skill_load` | Search skills / Load skill | query / name | read |
| `session_list` | List sessions | status, kind, parent_id, name, include_inactive, all_projects, limit | read |
| `session_search` | Search sessions | query, regexp, all_projects, max_sessions, max_matches | read |
| `session_read` | Read session | session_id, limit, before, kinds, max_chars | read |
| `session_send` | Message session | session_id, message, mode (send/queue), wait | meta |
| `session_control` | Control session | session_id, action (cancel/resume/close/rename/answer), name, question_id, answer | meta |
| `session_wait` | Wait for sessions | session_id / session_ids, until (stopped/idle/blocked/running/changed), mode (all/any), timeout_seconds | read |
| `task_list` | List tasks | column (pending/needs-input/active/review/done), include_archived, all_projects | read |
| `task_submit` | Submit task | prompt, cwd, model, thinking, refine (for the backlog) | meta |
| `task_control` | Control task | task_id, action (start/message/cancel/merge/verify/reject/complete/archive/restore/delete), message (the feedback, for reject) | meta |
| `task_wait` | Wait for tasks | task_id / task_ids, until (settled/done/needs-input/active/review/changed; settled counts review), mode, timeout_seconds | read |
| `notify` | Notification | message, title, urgency (low/normal/critical), providers, url | meta (needs no approval: `harness-perms--auto-allow-tools`) |
| `notification_providers` | Notification providers | (none) | read |
| `merge_done` | Finish merge | none | meta (merge module) |

Fast paths run in Emacs (`insert-file-contents`, `directory-files-recursively`,
`replace`); anything that can take long (grep, bash) runs as an
asynchronous process started with `start-file-process` so TRAMP works.

`web_search` asks the search provider `harness-websearch-provider`
(Brave, whose key comes from `harness-brave-api-key`, `BRAVE_API_KEY` or
auth-source).  `harness-websearch-register-provider NAME FN &optional
READY` adds one; READY says whether it can search now, and
`harness-websearch-ready-p` asks it (Brave: a key is set; auth-source is
asked at most every five minutes, since it may decrypt a file).  Some
model providers search the web themselves (`:builtin-tools`; Claude Code
has WebSearch, Copilot its web_search).  tools-web's filter on
`agent/builtin-tools` lets that search stand in for `web_search` as
`harness-websearch-builtin` says: `fallback` (the default) while the
search provider cannot search, so searching works before anything is
set up; `always`; or `never`.  The session then has no `web_search` of
the harness's, and the provider's searches show as `web_search` calls.

The session and task tools (`tools-sessions`) let an agent coordinate the
rest of the harness.  Sessions are named by id, a unique id prefix or a
unique name; a session cannot message, control or wait on itself.
Listing and search default to the current project (worktrees included).
`session_search` greps the `sessions/*.nodes.jsonl` logs in a subprocess,
so transcripts are not loaded into memory to be searched.  `session_send`
prefixes the message with `[Message from session ID "NAME"]` and goes
through `agent/prompt` (a turn, steering, or the queue).  Waits are
entries re-checked on session and task events, settled by their
condition, their timeout (`harness-tools-sessions--wait-default`, at most
`-wait-max`) or the end of the waiting turn; a timeout is a report, not
an error.  Nothing here grants permissions: permission requests and
permission modes stay with the user, and `task_submit` uses the task
defaults.  The task tools need the `tasks` module.

`notify` (`tools-notify`) sends a notification through
`notification/send` with `:source "agent"`, `:kind "agent"` and the
calling session's `:session` and `:project`, so a click opens the
session; its title defaults to the session's name.  The result names
the providers that delivered it, failed (and why) or were skipped as
not set up; it is an error only when none delivered it, and then says
how providers are set up.  A session sends at most
`harness-tools-notify--rate-limit` notifications (default 10 in 600 s);
past that it is told when it can send again.  `notification_providers`
lists `notification/providers`: set up or not, used by default or not.

`elisp` and the `emacs_*` tools are about the user's Emacs, so their
handlers (`harness-tools-in-client NAME`) forward the call to the UI as
`_harness/client/tool {name, input}`; `harness-client-tools-run` answers
it there.  `write_file`/`edit_file` emit `tools/file-written PATH`; the UI
reverts unmodified buffers visiting PATH.

### acp

Server: `acp/start &key host port` (default 127.0.0.1, port from
`harness-acp-port`, 0 = ephemeral) → `(:host :port)`, `acp/stop`,
`acp/status`.  Started by `:init` when `harness-acp--server-enabled`.

Client API used by every UI:

```elisp
(harness-acp-connect &optional ADDRESS)     ; nil → in-process; "host:port" → TCP
(harness-acp-request CONN METHOD PARAMS)    ; → promise of result plist
(harness-acp-notify CONN METHOD PARAMS)
(harness-acp-set-handler CONN FN)           ; FN (METHOD PARAMS RESPOND); RESPOND nil for notifications
(harness-acp-close CONN)
(harness-acp-connection-p CONN) (harness-acp-connected-p CONN)
(harness-acp-open-p CONN)                   ; connected, or TCP still connecting
```

What is sent while a TCP connection connects waits and goes out once
the socket is up, so a client keeps a connection while `harness-acp-open-p`
holds rather than connecting again, which would drop it along with
every request it carries.

Wire: JSON-RPC 2.0, one message per line.  Standard ACP methods:
`initialize`, `authenticate`, `session/new {cwd}` → `{sessionId}`,
`session/load {sessionId}` (replays the transcript as updates),
`session/prompt {sessionId, prompt:[blocks]}` → `{stopReason}`,
`session/cancel`, `session/set_mode {sessionId, modeId}`,
`session/set_model {sessionId, modelId}`.  Agent → client:
`session/update {sessionId, update}` with `sessionUpdate` one of
`user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk`,
`tool_call`, `tool_call_update`, `plan`, `current_mode_update`, and
the extension kinds `_harness/session` (full session plist after any
change), `_harness/node` (a finalised or updated node), `_harness/hint`,
`_harness/activity` (`activity`: what the running turn does, as
`agent/activity` returns it; null once the turn ends).
Requests agent → client: `session/request_permission {sessionId, toolCall,
options:[{optionId,name,kind}]}` → `{outcome:{outcome:"selected",optionId}}`
and `_harness/ask_user {sessionId, requestId, question, options, diagrams}` → `{answer}`.
Its `options` are the answers' labels; `diagrams`, present when the
options have them, holds one per option, `{type: "ascii", text}` or
`{type: "image", path, mime}`: a path on the harness's machine, never
the image data, since the pending question is saved with the session.

Extension methods: any bus method whose name starts with `session/`,
`agent/`, `provider/`, `tools/list`, `usage/`, `worktree/`, `merge/`,
`config/`, `skills/`, `permission/`, `question/`, `compaction/`, `naming/`, `task/`,
`notification/`, `sandbox/status`, `harness/api`, `harness/version`, `harness/reload` is callable as `_harness/NAME` with a
params object whose keys become the plist arguments (`{"id": …}` →
`:id`).  Methods take a single plist argument on the wire; the ACP
layer maps positional bus signatures through a small table.

Harness → UI requests for work in the user's Emacs go through the bus
method `client/request METHOD PARAMS` → promise of the first client's
answer; it rejects at once when no client is connected or all decline
(never callable over ACP).  Methods: `_harness/client/tool {name, input}`
→ tool result, `_harness/client/customize-save {symbol, value}` (value
printed; only `harness-` options), `_harness/client/notify {id, title,
body, urgency, source, kind, session, task, project, url}` -> `{backend}`
once a desktop notification shows (see notifications), or an error.

The server writes its address to `<state>/acp-address` and, when
`harness-acp-token` is set (always, for the harness process), the token
to `<state>/acp-token` (mode 600); `scripts/harness-acp-stdio`
authenticates with it on behalf of the editor it bridges.

The local transport dispatches lisp objects directly, no JSON, and
delivers notifications through `harness-run-soon` so callers are never
re-entered.

## Presentation contracts

`harness-ui` owns the connection (`harness-ui-connection`, local by
default; `harness-connect-remote` swaps it, and an empty address swaps
it back to this Emacs's own harness; `harness-ui-connected-hook`
runs after every connect, where the chat reopens the closed sessions its
buffers show, as a harness that just started has them all closed), the face set
(`harness-user-face`, `harness-agent-face`, `harness-tool-face`,
`harness-thinking-face`, `harness-hint-face`, warning ramps), the
session cache updated from `_harness/session` updates, the tool cache
(every tool's spec from `_harness/tools/list` without a session,
fetched once per connection and again after `harness/reloaded`;
`harness-ui-fetch-tools`), through which views name every tool by its
label (`harness-ui-tool-label`, `harness-ui-tool-title`), window
positions (`harness-ui-display-session SID &optional POSITION`; presets
`right`, `bottom`, `full`, `other`; one session per position, replacing),
the global keymap and the transient menu `harness-menu` (with a group for
the commands of the buffer it is opened from, which each mode lists in
its `harness-menu-group` property; opened from a side window it gets a
side window of its own, at the bottom, or at the top when a window such
as a BTW is at the bottom already, never in another window's slot),
and icons via `icons.el` (`define-icon`) with text fallbacks.  Every
command has a mouse target: buttons, header-line segments, or mode-line
segments.

Chat buffer (`harness-ui-chat`): transcript region (read-only) + queue
list + attachments row + compose region at the bottom.  Rendering is
incremental (append and in-place update by node id using markers);
older history renders in chunks on demand so a million-token session
stays snappy.  Markdown is rendered by the built-in renderer in
`harness-ui-markdown` (headings, emphasis, code spans, fenced code with
the language's major mode, lists, quotes, links).  Tool and thinking
nodes collapse; runs of coalescable tools fold into a summary block.
A tool call's header says how it ended, each on a background of its
own: a check mark (`harness-tool-face`), "failed" when it ran and
reported an error, such as a non-zero exit or an edit whose text did
not match (`harness-tool-error-face`), or "denied" when the permission
system refused it, so it never ran (`harness-tool-denied-face`); a
denied call's text is labelled as the reason rather than as output.  A
summary block counts the failed and denied calls it folds.
The panel of a question whose options have diagrams shows one diagram
at a time, in an area under the options; its tabs, `n` and `p` on the
panel, `C-c C-f` and `C-c C-b`, and point moving onto an option switch
it.  Switching redraws the options and that area alone, in place, so
point, the windows and the compose box stay put.
Tools go by their labels everywhere: a tool block's header shows the
label in `harness-tool-title-face` and what the call is about after it
in `harness-tool-subject-face` (the faces stand in for the colon of the
title), a summary block counts the calls by label ("5 tool calls: Read
file ×3, Search files, Find files"), and so do the permission panel,
the activity line and the mode line.  A title recorded before tools had
labels starts with the tool's name ("read_file x.el"), which the label
replaces, so old transcripts read the same.
Auto-scroll follows unless the user scrolled up.  While the session
runs, an activity line under the last block says what the turn does
and for how long: waiting for the model, thinking, writing, preparing a
tool call (with the size of its input so far), running one (with the
last line it reported), checking its permission, or compacting, behind
a spinner.  It is an overlay string redrawn by the spinner's timer, so
it ticks without editing the buffer; a blocked session shows its panel
instead, and the mode line names the phase too.  It has a background of
its own (`harness-chat-activity-face`) and a blank line under it, which
set it apart from the compose box: an overlay string is drawn over the
face of the text it precedes, the box's prompt, so both lines are drawn
over `default` extended to the window's edge.  A buffer opened
mid-turn asks `agent/activity`; a harness that reports none gets
"Working" with the turn's duration.  A block whose renderer
signals is shown unformatted with a note, so one bad node never costs the
buffer the rest of its transcript or its compose box.  Opening a session
from any view never resumes it: an inactive session shows its transcript,
a notice and the compose box, and the first message sent from it resumes
it (through `agent/prompt`).  The header line shows the session's
status, name, model, permission mode, whether it is non-interactive
("non-interactive" in `harness-non-interactive-face`, else a dim
"interactive"), thinking level, context, cost and [menu]; clicking a
setting changes it, and the non-interactive one toggles.  Other UI
modules hook into a chat buffer without owning it:
`harness-chat-send-functions` sees each message sent
or queued from its box (the text as typed, and the attachments),
`harness-chat-header-functions` (buffer-local) puts segments in front of
its header line, leaving the session's own segments as they are, and the
buffer-local `harness-chat-placeholder` replaces the empty box's usual
hint.

Compose box (`harness-ui-compose`): the editable box shared by chat
buffers and the task board.  A host calls `harness-compose-setup`
(`:project`, `:placeholder`, `:redraw` functions; `:bottom` keeps the box at
the bottom of the window) from its mode and
`harness-compose-insert` where it draws the box; it gets multi-line
editing whose lines wrap under the text and never scroll sideways (the
whole host buffer wraps, so a host fits the lines it wants kept on one;
with `:bottom` the growing box keeps its last line on the window's last
line), a prompt that is a field of its own (`C-a` stops after it, so
`C-a C-k` clears the line), the placeholder, @file and /skill
completion, attachments (`C-c C-a`, clipboard `C-c C-v`, drag and
drop), skill expansion (`harness-compose-with-expanded-text`) and ACP
attachment blocks.
Completion reads the project's files and the skills when it is asked,
so a token typed before they arrived is offered them once they have.
Popups that show as you type (corfu's `corfu-auto`, company) give up
when the buffer changed since the last key, and a host changes all the
time (a chat streams, a board follows its tasks): once the token stops
changing, the box asks them again (`harness-compose--popup`).  `C-c C-a`
reads a project file by part of its name over the same list, never
listing while you wait; `C-u C-c C-a`, or a directory that is no
project, reads any file.

Views share positions with sessions: the task board, session list,
usage dashboard, worktree list, conversation tree and log open through
`harness-ui-display-view`, replacing the session in their position (and
returning to the position they had last); a session opened from a view
(`harness-ui-session-opener`) replaces the view.  Menus, help and the
BTW overlay keep their own windows.

Settings page (`harness-ui-config`, `C-c h S`, `harness-settings`):
every harness option on one page, like a customize buffer, about the
project of the current buffer (in a chat buffer, of the session's
working directory).  A Global / Project toggle at the top (`s`, or the
radio buttons, or the header line) picks what is edited: the customize
value, or the project's `.dir-locals.el` (a directory's, outside a
project).  Session defaults, the layered settings, come first in both
scopes; the other options are listed by module in the Global scope and
folded into one line in the Project scope.  Each setting is a
`wid-edit` widget built from its customize type, with its doc and
where its value in effect comes from; toggles and menus save at once,
text saves with RET (C-x C-s saves every edit).  [Remove override]
deletes a project value, [Reset to default] a customized global one.
Secrets show as set or not and are set through `read-passwd`; long
texts open in `string-edit`.  The page reloads on `config/changed`,
keeping edits not saved yet.

Session settings: `harness-set-model`, `-thinking`, `-permission-mode`
and `harness-toggle-non-interactive` (`C-c h m` `T` `p` `i`) change what
the buffer's `harness-ui-setting-target-function` names -- a session
id, or a settings plist with its setter -- and otherwise the current
session.  The menu's `i` entry says whether that is non-interactive
("Non-interactive: on"), and has no state where the command would
ask for a session.

Desktop notifications: `harness-ui` answers `_harness/client/notify` by
showing the notification on this Emacs's desktop
(`harness-notifications-desktop-notify`), with `{backend}` once it
shows or an error when it cannot.  One about a session or a task can be
clicked; the click, out of the process filter or D-Bus handler, brings
a graphical frame of this Emacs to the front and runs
`harness-ui-notification-functions` (the wire plist; the first that
returns non-nil has shown what it is about), else opens its session.
The task board's function opens the board of the notification's
`:project` with point on the task's card, once the board shows it
(within 10 s).  `harness-test-notifications` (menu `N`) sends a test
notification through `_harness/notification/send` and says in the
echo area what each provider did with it.

Task board (`harness-ui-tasks`, `C-c h a`): the project's tasks in five
sections -- requires your input, ready for review, in progress, pending,
completed -- with each card's current todo, progress, elapsed time,
cost and merge state, one-click answers to a blocked task's question or
permission, and a compose box that submits a task, edits a pending one,
messages a task's session, answers its question or takes the feedback
that sends a task back from review (`C-g` leaves an edit, message,
answer or feedback for a new task again: a question stays waiting,
never cancelled).  A task in review shows [Verify] and [Send back]: `v`
accepts the work (its branch then merges), `R` sends it back to its
session with the feedback written in the compose box (`C-u R` reads it
in the minibuffer).  The header counts the tasks to review, and
`task/review` says in the echo area that one is ready
(`harness-ui-tasks--notify-review`).  RET opens the session, and
`C-c h a` there leads back to the open board listing its task, whatever
directory the session works in; elsewhere a task's worktree belongs to
the main checkout's board (`harness-files-main-root`).  Redraws, after
every change and on every tick of the clock, leave point and each
window where they were: on the same line of the same card (its buttons
are on the second), on the same button, on the same line above the
box; never on another button.  Any click on a button pushes it, a slow
one too, rather than reaching the board's own click, which opens the
session.  The session setting commands change the task at point, or
from the compose box the settings the next task starts with (shown as
buttons under the New task label).  A
Submit / Refine toggle beside that label, showing only the current mode
(a click or `C-c C-t` switches it), picks what a new task does: start,
or go to the backlog, written up by an agent and
waiting in pending until you start it (`s`); `r` refines a queued task,
retries a stopped write-up or sends feedback on a backlog task's.  `I` or
[Add session] makes an ongoing session a task.  `b` or [BTW] (or the
usual BTW command) opens a BTW side conversation over the board about
its tasks (`task/btw`).  Boards reload after any
task, merge, turn, status, worktree or reload event.  New tasks show at
the top of in progress (latest started first), review lists the latest
finished first and completed the latest completed (verified, else
finished) first; pending is the queue, in the order its tasks start,
with the backlog among it (oldest first; only queued tasks have a place
in line).

Cost display: whatever shows what a session cost goes through
`harness-ui-format-spend`.  That is a price when calls are billed per
token, and the plan's name (`Max`) when a subscription pays, after any
extra usage billed (`$0.40+Max`); the tooltip explains it and gives
the value at API prices.  The chat header adds the plan's 5-hour and
weekly windows (`Max · 5h 9% · 7d 57%`, coloured as they fill)
and opens the usage dashboard.  The dashboard's Plan section shows
every quota window with its reset time and the plan's extra usage,
and its chart stacks what a plan covered on top of the billed cost.
The UI keeps each provider's QUOTA from `provider/quota` and
`provider/quota-updated` (`harness-ui-quota`).

Other buffers: settings page (`harness-ui-config`, above), sessions list (`tabulated-list-mode`, tree indentation for
children, filter/sort by any column; scoped to the current project, its
git worktrees and so its tasks' sessions included, each session's root
resolved to its main checkout once with `harness-files-main-checkout`),
conversation tree (`harness-ui-tree`), usage dashboard (`harness-ui-usage`,
svg charts via svg.el), worktrees (`harness-ui-worktree`), notifier
(`harness-ui-notify`: global mode-line segment with blocked/running/idle
counts, clickable), BTW side window (`harness-ui-btw`: a new, empty
session listed under the session it is opened over but sharing nothing
with it or with other BTWs (`session/btw`), or, over a view that sets
`harness-ui-btw-start-function`, a new conversation the view starts, shown
in the session's own chat buffer with point in its compose box, so the
question is written and sent like any message; nothing is read in the
minibuffer.  The buffer is the full chat: its header line (model,
permission mode, non-interactive, thinking, context, cost, [menu]),
keys and menu are a session's, `harness-ui-btw-minor-mode` only adding a BTW segment in
front of the header through `harness-chat-header-functions` (what it
is about, [close], [keep]) and `C-c C-k`/`C-c C-o` to close and keep
it; one over a session starts in that session's permission mode.  The
first message names it `btw: ...`, unless it was named by hand.
Closing it returns there; a BTW nothing was asked in is deleted with
its buffer, once the harness confirms it holds no node of its own,
and an idle one is closed.  Keeping it makes it a normal session
window in that place, with nothing of the BTW left in its header), media
(`harness-ui-media`: inline images, audio record/playback with svg
meters, video thumbnails/open).
