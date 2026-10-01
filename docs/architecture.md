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
                worktree, merge, tasks, skills, perms, sandbox
 Completion     provider, provider-openai, provider-claude
 Tool calls     tools, tools-fs, tools-shell, tools-emacs, tools-web, tools-agent,
                tools-sessions
 ------------------------------- bus (lisp/harness-core.el)
 Core           harness.el (loader, reload), harness-core (methods, events, filters,
                promises, modules), harness-util (json, ids, paths), harness-http (curl, SSE)
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
  (`harness-save-user-option`), and reverting buffers after a tool
  writes a file (event `tools/file-written`).
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
promise *and* is logged (with a backtrace when `harness-debug-backtraces`
is on), because a rejection nobody observes would otherwise vanish.
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
 :non-interactive nil|t
 :status idle|running|blocked|inactive
 :parent-id nil|"uuid"  :fork-node nil|"node-id"
 :created FLOAT  :updated FLOAT
 :usage (:input N :output N :cache-read N :cache-write N :cost F :context N :turns N)
 :context-window N
 :budget nil|(:amount F :hard BOOL)
 :head "node-id"
 :queue ((:id "q1" :text "…" :attachments (ATTACHMENT…)) …)
 :pending ((:id "p1" :kind permission|question :payload PLIST :created FLOAT) …)
 :todos ((:id :text :status pending|in-progress|done) …)
 :plan nil|"markdown"
 :provider-state PLIST)                ; opaque, owned by the provider (e.g. CLI session id)
```

`:usage :context` is the input size of the last request (prompt tokens
incl. cache); the UI colours it against `:context-window`.

### Node (conversation DAG)

```elisp
(:id "n-…" :parent "n-…"|nil :session "uuid" :ts FLOAT
 :kind user|assistant|thinking|tool-call|tool-result|hint|compaction|plan
 ;; user / assistant / thinking / hint / compaction / plan:
 :content "text"  :blocks (BLOCK…)          ; blocks only when non-text content exists
 ;; tool-call:
 :tool "read_file" :call-id "toolu_…" :input PLIST :title "read_file src/x.el"
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

`(:input N :output N :cache-read N :cache-write N :cost F)`; cost in USD.
When a provider reports no cost, `usage` computes one from pricing.

## Module contracts (state layer)

### config

Layered settings: directory `.dir-locals.el` (most specific) →
project-root `.dir-locals.el` → customize default.  Variables are
`defcustom`s with `:safe` predicates so dir-locals never prompt:
`harness-model` (default "claude:claude-fable-5-1"),
`harness-permission-mode`, `harness-thinking`,
`harness-allowed-directories`, `harness-budget`, `harness-sandbox-policy`,
`harness-non-interactive`, `harness-context-reserve`.

- `config/get KEY CWD` → value for a session at CWD (KEY is the symbol).
- `config/set KEY VALUE &key scope cwd` — scope `directory|project|global`;
  default: project if a project is found, else directory.  Persists with
  `add-dir-local-variable`, or for `global` with `harness-save-user-option`,
  which asks the UI's Emacs to `customize-save-variable` (its custom file).
- `config/layers CWD` → `((global . V) (project . V) (directory . V))` for display.
- Event `config/changed KEY VALUE SCOPE CWD`.

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
  :permission-mode :thinking :kind :parent-id :host :worktree`.  Fills
  project, defaults from `config/get`.  → session.  Event `session/created`.
- `session/get ID`, `session/list &optional FILTER` (`:project :status
  :kind :parent-id :active`), `session/delete ID`.
- `session/update ID &rest PLIST` — settings and name; appends a `hint`
  node ("model → …") and persists the setting through `config/set` when
  `:persist t`.  Event `session/updated ID CHANGES`.
- `session/set-status ID STATUS`.  Event `session/status ID STATUS`.
- `session/resume ID` (loads nodes, status idle), `session/deactivate ID`.
- `session/fork ID &rest PLIST` — copies ancestor chain; `:kind fork|btw|subagent`,
  `:name`, `:cwd` (defaults to parent's).  Asks the provider to fork its
  state via `provider/fork` when supported.  → new session.
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
  from the path, tool calls paired with results.
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
  :quota FN             ; () → promise of (:windows ((:name :used FRAC :resets FLOAT)…))  [optional]
  :capabilities PLIST)  ; static defaults, merged with per-model ones
```

MODEL = `(:id "ID:NAME" :provider ID :name "NAME" :label "…"
:context-window N :max-output N :input-modalities ("text" "image")
:thinking-levels (…) :pricing (:input F :output F :cache-read F :cache-write F)
:capabilities (…))`.  Pricing is USD per million tokens.

Capabilities: `:hosted-loop` (provider runs the tool loop and keeps the
history; the agent only sends new user content), `:fork`, `:resume`,
`:vision`, `:audio-in`, `:thinking`, `:cache-status`, `:quota`,
`:compaction hosted`, `:cost-reported` (usage events carry `:cost`),
`:pricing dynamic` (pricing comes from the model catalogue).

REQUEST = `(:model "ID:NAME" :session SESSION :system "…" :messages (MSG…)
:tools (TOOL-SPEC…) :thinking LEVEL :max-tokens N :provider-state PLIST
:on-event FN)`.  MSG = `(:role user|assistant|tool :content (BLOCK…))`.
TOOL-SPEC = `(:name :description :schema JSON-SCHEMA-PLIST)`.  For hosted
loops only the trailing user message is sent.

Events delivered to `:on-event` (one plist each, in order):

```elisp
(:type start)
(:type text :delta "…")
(:type thinking :delta "…")
(:type tool-call :id "…" :name "…" :input PLIST :respond FN-OR-NIL)
   ;; :respond present ⇒ hosted loop; call it with a tool result
   ;; (:content "…" :is-error BOOL) and the provider continues the turn.
(:type tool-result :id "…" :content "…" :is-error BOOL)  ; hosted loops echo results
(:type usage :input N :output N :cache-read N :cache-write N :cost F-OR-NIL :context N)
(:type provider-state :state PLIST)     ; persist on the session
(:type quota :windows (…))
(:type hint :text "…")                  ; provider-side notices (compaction, retries)
(:type done :stop-reason end-turn|tool-use|max-tokens|cancelled|error :error "…")
```

Forking: `provider/fork` returns a new provider state that may be marked
pending (for the CLI: `(:cli-session-id PARENT :fork-pending t)`); the
first completion consumes it and emits a `provider-state` event that the
agent persists, replacing the pending one.

Methods: `provider/list`, `provider/models &optional REFRESH` (cached union
across providers), `provider/model MODEL-ID` → MODEL, `provider/capabilities MODEL-ID`,
`provider/complete REQUEST` → HANDLE, `provider/fork MODEL-ID STATE` → promise,
`provider/quota PROVIDER-ID`.  `harness-default-model` is
"claude:claude-fable-5-1".

### tools

```elisp
(harness-define-tool "read_file"
  :description "…"                       ; what the model sees
  :schema '(:type "object" :properties (:path (:type "string" :description "…")) :required ("path"))
  :kind read|write|exec|net|meta          ; permission class
  :paths (lambda (input) (list …))        ; paths touched, for the jail
  :coalescable t                          ; may be folded into a summary block in the UI
  :title (lambda (input) "read_file x.el") ; short label
  :handler (lambda (input ctx) …))        ; → RESULT | string | promise
```

CTX = `(:session-id ID :cwd "/abs/" :host PREFIX :call-id "…" :report FN)`;
`:report` accepts a string for progress.  RESULT = `(:content "…"
:is-error BOOL :attachments (…) :meta PLIST)`.

- `tools/list &optional SESSION-ID` → TOOL-SPECs, filtered through sync
  filter `agent/tools` (value: list of names; args: session).
- `tools/execute SESSION-ID CALL` (CALL = `(:id :name :input)`) → promise of
  RESULT.  Pipeline: lookup → `permission/decide` (async filter) →
  handler (with `harness-tools-timeout`) → context-bomb guard → sync
  filter `tools/result` → events `tools/started`, `tools/finished`.
- Context bomb: outputs over `harness-tools-max-output-chars` (30000) are
  saved to `harness-state-directory/outputs/CALL-ID.txt` and replaced
  by the head plus an instruction to range-read that file.
- Denied calls return `(:is-error t :content "Denied: REASON. HINT")`.

### perms

Async filter `permission/decide`: value is a DECISION
`(:behavior allow|deny|ask :reason "…" :input UPDATED :final BOOL)`,
args are the REQUEST `(:session SESSION :tool NAME :input PLIST :kind KIND
:paths (…))`.  Chain (priority): 10 jail, 20 mode, 30 auto (LLM judge),
40 non-interactive, 90 ask-user (turns `ask` into a pending request
and resolves when answered).

- `permission/answer SESSION-ID PENDING-ID ANSWER` — ANSWER
  `(:behavior allow|deny :scope once|session|always :reason)`, or an
  option id string such as "allow-session" (what ACP clients send back).
- The jail asks instead of denying when a path lies outside the roots
  and someone can answer: a pending `permission` request whose payload
  carries `:dir` and the options allow-once / allow-session (grant the
  directory to the session) / allow-always (add it to
  `harness-allowed-directories`) / deny-once.  After a grant the rest
  of the chain still decides the call itself.  Non-interactive sessions
  are denied with a hint as before.
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
- Events `permission/requested SID PENDING` (PENDING `(:id :kind permission
  :payload (:tool :input :kind :paths :call-id :title :options))`),
  `permission/decided SID REQUEST DECISION`, `permission/dir-allowed SID DIR`.
- Modes: `ask` (reads inside the jail allowed; everything else asks),
  `accept-edits` (reads/writes inside the jail allowed; exec/net ask),
  `auto` (reads inside the jail allowed; a cheap model,
  `harness-perms-auto-model`, decides the rest with a reason; falls back
  to ask), `yolo` (allow everything; the jail still applies).  Tools in
  `harness-perms-auto-allow-tools` are allowed in every mode.
- Jail denials are final and carry a constructive hint listing the
  allowed roots and how to widen them.
- Non-interactive: `ask` becomes `deny` with the reason "non-interactive
  mode: the user is away" and a hint to find another approach inside the
  permitted scope; a steering message is sent to the agent once per call.

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

### agent

- `agent/prompt SESSION-ID BLOCKS &optional OPTS` → promise of
  `(:stop-reason …)`.  Idle session: starts a turn.  Running session:
  steering — the text is queued and injected at the next step boundary
  (appended to the next tool result, or sent as the next user turn if
  the model stops first).  OPTS `:queue t` only queues.
- `agent/cancel SESSION-ID`.
- `agent/send-queue SESSION-ID` — sends every queued item as one turn.
- Sync filter `agent/system-prompt` (value string, args session); sync
  filter `agent/tools`; async filter `agent/before-turn` (value
  `(:proceed t :reason)`, args session) — budgets, merge holds and
  compaction hook in here; async filter `agent/step` at every step
  boundary (same value shape) — merge holds pause here.
- Events `agent/turn-started SID`, `agent/turn-ended SID REASON`,
  `agent/stream SID NODE-ID KIND DELTA` (kind text|thinking),
  `agent/tool-call SID NODE`, `agent/tool-result SID NODE`.
- Turn loop: build system prompt → messages → `provider/complete`;
  stream deltas into a live assistant/thinking node (created on first
  delta, updated in place); on `tool-call` append a tool-call node, run
  `tools/execute`, append the tool-result node; native loops re-call the
  provider until `end-turn`; hosted loops respond through `:respond`.
  Steering text is drained at every boundary.  `max-turns`
  (`harness-agent-max-steps`, 200) ends runaway loops.
- Streaming updates of the live node are not persisted one by one; on
  exit (`kill-emacs-hook`) and shutdown the text streamed so far is.

### usage

- Subscribes `session/usage`; records to sqlite (`usage` table:
  ts, session, project, model, input, output, cache_read, cache_write, cost).
- `usage/summary &key group-by since until project` → rows
  `(:key :input :output :cache-read :cache-write :cost :calls)`;
  group-by `project|model|day|session`.
- `usage/budgets`, `usage/set-budget BUDGET`, `usage/remove-budget ID`,
  `usage/budget-status ID &rest (:now)` (ID may be "session:SID" for a
  session's implicit budget) → `(:budget :spent :amount :remaining
  :fraction :hard :per-day :days-left :period-start :period-end)`;
  `usage/session-budgets SID`, `usage/plan-budget AMOUNT PERIOD DAYS`,
  `usage/totals`, `usage/series (:bucket day|hour …)`, `usage/record ROW`.
  BUDGET = `(:id :scope session|project|period :target ID-OR-ROOT
  :amount F :hard BOOL :period day|week|month :days business|all)`.
- Hard budgets block via `agent/before-turn`; soft ones emit
  `usage/budget-warning` and a session hint at 80% and 100%.
- Pricing: `usage/price MODEL-ID USAGE` → cost using the model's pricing.

### compaction

- `compaction/compact SESSION-ID` → promise; summarises the transcript
  with the session's model, appends a `compaction` node whose `:meta`
  points at the compacted head, sets it as head, hints before/after.
- Auto: `agent/before-turn` compacts when
  `context > window - harness-context-reserve` unless the provider
  reports `:compaction hosted`.

### naming

- `naming/name SESSION-ID` → promise of name.  Auto after the first
  turn ends when the session has no name: forks provider state when
  possible so the cached prefix is reused; hints "naming…" then the result.
- Sync filter `naming/system-prompt` (value string, args session) lets
  modules add to `harness-naming-system-prompt` per session (tasks ask
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
  `worktree/root-of PATH`, `worktree/branch PATH`,
  `worktree/status PATH` → `(:dirty :ahead :behind :branch)`.  All return promises.
- Sessions created with `:worktree PATH` get `:cwd` = PATH.

### merge

- `merge/enqueue CHILD-SID PARENT-SID` → position; `merge/queue PARENT-SID`;
  `merge/cancel CHILD-SID`.  When the parent reaches a step boundary
  (`agent/step` filter) or is idle, the head of the queue gets the lock:
  the harness runs `git merge --no-ff` of the child's branch in the
  parent's cwd; on conflict the child session receives a steering
  message describing the conflicts and its jail is widened to the
  parent's cwd until it resolves; then the lock passes on.
- `merge/status CHILD-SID`; the `merge_done` tool releases a conflict lock.
- Events `merge/queued CHILD PARENT POSITION`, `merge/started`,
  `merge/conflict CHILD PARENT FILES`, `merge/finished CHILD PARENT STATUS`
  (merged|failed|aborted|cancelled).

### tasks

Task mode: one session per task.  TASK =
`(:id "t-…" :project ROOT :cwd DIR :prompt "…" :attachments (…)
:state pending|active|merging|done :column pending|needs-input|active|done
:session SID :outcome nil|end-turn|error|cancelled|merge-failed|merged|…
:error "…" :worktree DIR :branch NAME :base NAME :merge-status nil|queued|merging|conflict
:conflicts (FILE…) :merged BOOL :archived BOOL :created F :started F :finished F)`.
`:column` is derived on every read: `needs-input` when the session is
blocked on a request or the task stopped part way.

- `task/submit CWD PROMPT &optional (:attachments :model :permission-mode
  :thinking :non-interactive)` → task; it starts when one of
  `harness-tasks-max-running` slots is free.  Missing options come from
  `harness-tasks-model`, `-permission-mode` (auto), `-thinking` and
  `-non-interactive` (on); an explicit false turns non-interactive off.
- `task/adoptable &optional CWD` lists the project's open sessions that
  are not tasks; `task/adopt SESSION-ID` makes one a task (its first
  message is the prompt; a worktree session keeps its worktree and merges
  like any task; an idle one waits in `needs-input` with `:outcome adopted`).
- Starting: in a git project (`harness-tasks-worktrees`) `worktree/create`
  on branch `harness-tasks-branch-prefix` + slug + id, then a session in
  that worktree (`harness-tasks-permission-mode`, non-interactive by
  default) prompted with the task; a system-prompt section tells it to
  commit on its branch and not merge.  Outside git the session runs in CWD.
- The session's name is the task's title: `naming/system-prompt` adds
  `harness-tasks-naming-prompt` (nil for none) so the model titles task
  sessions like tickets.
- A turn ending `end-turn` queues `merge/enqueue SID TARGET`, TARGET being
  the project's root session named `harness-tasks-merge-session-name`
  (created on demand); `merge/finished … merged` makes the task `done`.
  Failures the agent can fix (uncommitted work) are steered by the merge
  queue; others, or more than `harness-tasks-merge-attempts`, set
  `:outcome merge-failed`.  Outside git `end-turn` makes it `done`.
- `task/list &optional CWD`, `task/get ID`, `task/settings &optional CWD`,
  `task/start ID` (ignores the limit), `task/update ID PROMPT` (pending
  only), `task/prompt ID TEXT &optional ATTACHMENTS` (follow-up or
  steering; reopens),
  `task/merge ID` (retry), `task/complete ID`, `task/archive ID &optional
  RESTORE` (deactivates the session; removes a merged task's worktree and
  branch), `task/archive-done &optional CWD`, `task/cancel ID`,
  `task/delete ID &optional DELETE-SESSION` (keeps the worktree).
- Events `task/changed TASK`, `task/deleted ID`.  Records persist in
  `tasks.json`, written shortly after a change and on exit
  (`harness-tasks-flush`).
- Restarts: when the module starts, an active task without an outcome
  that nothing in this process works on was interrupted.  Without a
  session it starts over (as pending, or in its worktree when it has
  one); otherwise, with `harness-tasks-resume-interrupted` (default t),
  its session is resumed and sent `harness-tasks-resume-prompt` (the task
  itself when it never got it), past the concurrency limit since it held
  a slot before; with nil it waits in needs-input with `:outcome
  interrupted`.  Merges in flight are queued again.

### tools-fs, tools-shell, tools-emacs, tools-web, tools-agent, tools-sessions

Tool names and inputs (all paths relative to cwd or absolute; TRAMP
prefixes come from the session host):

| tool | input | kind |
|---|---|---|
| `read_file` | path, offset, limit | read |
| `write_file` | path, content | write |
| `edit_file` | path, old_string, new_string, replace_all | write |
| `list_dir` | path, depth | read |
| `glob` | pattern, path | read |
| `grep` | pattern, path, glob, case_sensitive, max_results | read |
| `bash` | command, timeout, cwd | exec |
| `elisp` | code | exec |
| `emacs_buffers` | filter, all | read |
| `emacs_buffer` | name, offset, limit | read |
| `emacs_describe` | symbol | read |
| `web_search` | query, count | net |
| `web_fetch` | url, max_chars | net |
| `emacs_messages` | count | read |
| `ask_user` | question, options, allow_free_text | meta (answered with `question/answer SID PID ANSWER`; event `question/asked`) |
| `session_info` | — | read |
| `plan` | plan | meta |
| `todo_write` | todos | meta |
| `spawn_agent` | prompt, fork, model, name | meta |
| `skill_search` / `skill_load` | query / name | read |
| `session_list` | status, kind, parent_id, name, include_inactive, all_projects, limit | read |
| `session_search` | query, regexp, all_projects, max_sessions, max_matches | read |
| `session_read` | session_id, limit, before, kinds, max_chars | read |
| `session_send` | session_id, message, mode (send/queue), wait | meta |
| `session_control` | session_id, action (cancel/resume/close/rename/answer), name, question_id, answer | meta |
| `session_wait` | session_id / session_ids, until (stopped/idle/blocked/running/changed), mode (all/any), timeout_seconds | read |
| `task_list` | column, include_archived, all_projects | read |
| `task_submit` | prompt, cwd, model, thinking | meta |
| `task_control` | task_id, action (start/message/cancel/merge/complete/archive/restore/delete), message | meta |
| `task_wait` | task_id / task_ids, until (settled/done/needs-input/active/changed), mode, timeout_seconds | read |

Fast paths run in Emacs (`insert-file-contents`, `directory-files-recursively`,
`replace`); anything that can take long (grep, bash) runs as an
asynchronous process started with `start-file-process` so TRAMP works.

The session and task tools (`tools-sessions`) let an agent coordinate the
rest of the harness.  Sessions are named by id, a unique id prefix or a
unique name; a session cannot message, control or wait on itself.
Listing and search default to the current project (worktrees included).
`session_search` greps the `sessions/*.nodes.jsonl` logs in a subprocess,
so transcripts are not loaded into memory to be searched.  `session_send`
prefixes the message with `[Message from session ID "NAME"]` and goes
through `agent/prompt` (a turn, steering, or the queue).  Waits are
entries re-checked on session and task events, settled by their
condition, their timeout (`harness-tools-sessions-wait-default`, at most
`-wait-max`) or the end of the waiting turn; a timeout is a report, not
an error.  Nothing here grants permissions: permission requests and
permission modes stay with the user, and `task_submit` uses the task
defaults.  The task tools need the `tasks` module.

`elisp` and the `emacs_*` tools are about the user's Emacs, so their
handlers (`harness-tools-in-client NAME`) forward the call to the UI as
`_harness/client/tool {name, input}`; `harness-client-tools-run` answers
it there.  `write_file`/`edit_file` emit `tools/file-written PATH`; the UI
reverts unmodified buffers visiting PATH.

### acp

Server: `acp/start &key host port` (default 127.0.0.1, port from
`harness-acp-port`, 0 = ephemeral) → `(:host :port)`, `acp/stop`,
`acp/status`.  Started by `:init` when `harness-acp-server-enabled`.

Client API used by every UI:

```elisp
(harness-acp-connect &optional ADDRESS)     ; nil → in-process; "host:port" → TCP
(harness-acp-request CONN METHOD PARAMS)    ; → promise of result plist
(harness-acp-notify CONN METHOD PARAMS)
(harness-acp-set-handler CONN FN)           ; FN (METHOD PARAMS RESPOND); RESPOND nil for notifications
(harness-acp-close CONN)
(harness-acp-connection-p CONN) (harness-acp-connected-p CONN)
```

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
change), `_harness/node` (a finalised or updated node), `_harness/hint`.
Requests agent → client: `session/request_permission {sessionId, toolCall,
options:[{optionId,name,kind}]}` → `{outcome:{outcome:"selected",optionId}}`
and `_harness/ask_user {sessionId, requestId, question, options}` → `{answer}`.

Extension methods: any bus method whose name starts with `session/`,
`agent/`, `provider/`, `tools/list`, `usage/`, `worktree/`, `merge/`,
`config/`, `skills/`, `permission/`, `question/`, `compaction/`, `naming/`, `task/`,
`sandbox/status`, `harness/api`, `harness/version`, `harness/reload` is callable as `_harness/NAME` with a
params object whose keys become the plist arguments (`{"id": …}` →
`:id`).  Methods take a single plist argument on the wire; the ACP
layer maps positional bus signatures through a small table.

Harness → UI requests for work in the user's Emacs go through the bus
method `client/request METHOD PARAMS` → promise of the first client's
answer; it rejects at once when no client is connected or all decline
(never callable over ACP).  Methods: `_harness/client/tool {name, input}`
→ tool result, `_harness/client/customize-save {symbol, value}` (value
printed; only `harness-` options).

The server writes its address to `<state>/acp-address` and, when
`harness-acp-token` is set (always, for the harness process), the token
to `<state>/acp-token` (mode 600); `scripts/harness-acp-stdio`
authenticates with it on behalf of the editor it bridges.

The local transport dispatches lisp objects directly, no JSON, and
delivers notifications through `harness-run-soon` so callers are never
re-entered.

## Presentation contracts

`harness-ui` owns the connection (`harness-ui-connection`, local by
default; `harness-connect-remote` swaps it; `harness-ui-connected-hook`
runs after every connect, where the chat reopens the closed sessions its
buffers show, as a harness that just started has them all closed), the face set
(`harness-user-face`, `harness-agent-face`, `harness-tool-face`,
`harness-thinking-face`, `harness-hint-face`, warning ramps), the
session cache updated from `_harness/session` updates, window
positions (`harness-ui-display-session SID &optional POSITION`; presets
`right`, `bottom`, `full`, `other`; one session per position, replacing),
the global keymap and the transient menu `harness-menu`, and icons via
`icons.el` (`define-icon`) with text fallbacks.  Every command has a
mouse target: buttons, header-line segments, or mode-line segments.

Chat buffer (`harness-ui-chat`): transcript region (read-only) + queue
list + attachments row + compose region at the bottom.  Rendering is
incremental (append and in-place update by node id using markers);
older history renders in chunks on demand so a million-token session
stays snappy.  Markdown is rendered by the built-in renderer in
`harness-ui-markdown` (headings, emphasis, code spans, fenced code with
the language's major mode, lists, quotes, links).  Tool and thinking
nodes collapse; runs of coalescable tools fold into a summary block.
Auto-scroll follows unless the user scrolled up.

Compose box (`harness-ui-compose`): the editable box shared by chat
buffers and the task board.  A host calls `harness-compose-setup`
(`:project`, `:placeholder`, `:redraw` functions; `:bottom` keeps the box at
the bottom of the window) from its mode and
`harness-compose-insert` where it draws the box; it gets multi-line
editing, the placeholder, @file and /skill completion, attachments
(`C-c C-a`, clipboard `C-c C-v`, drag and drop), skill expansion
(`harness-compose-with-expanded-text`) and ACP attachment blocks.

Views share positions with sessions: the task board, session list,
usage dashboard, worktree list, conversation tree and log open through
`harness-ui-display-view`, replacing the session in their position (and
returning to the position they had last); a session opened from a view
(`harness-ui-session-opener`) replaces the view.  Menus, help and the
BTW overlay keep their own windows.

Session settings: `harness-set-model`, `-thinking`, `-permission-mode`
and `harness-toggle-non-interactive` change what the buffer's
`harness-ui-setting-target-function` names -- a session id, or a
settings plist with its setter -- and otherwise the current session.

Task board (`harness-ui-tasks`, `C-c a a`): the project's tasks in four
sections -- requires your input, in progress, pending, completed -- with
each card's current todo, progress, elapsed time, cost and merge state,
one-click answers to a blocked task's question or permission, and a
compose box that submits a task, edits a pending one, messages a
task's session or answers its question (`C-g` leaves an edit, message
or answer for a new task again: a question stays waiting, never
cancelled).  RET opens the session.  The session setting commands
change the task at point, or from the compose box the settings the next
task starts with (shown as buttons under the New task label).  `I` or
[Add session] makes an ongoing session a task.  Boards reload after any
task, merge, turn, status, worktree or reload event.  New tasks show at
the top of in progress (latest started first) and completed lists the
latest finished first; pending is the queue, in the order its tasks
start.

Other buffers: sessions list (`tabulated-list-mode`, tree indentation for
children, filter/sort by any column), conversation tree
(`harness-ui-tree`), usage dashboard (`harness-ui-usage`, svg charts
via svg.el), worktrees (`harness-ui-worktree`), notifier
(`harness-ui-notify`: global mode-line segment with blocked/running/idle
counts, clickable), BTW side window (`harness-ui-btw`), media
(`harness-ui-media`: inline images, audio record/playback with svg
meters, video thumbnails/open).
