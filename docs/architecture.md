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
 State          session, agent, config, project, store, usage, fallback, naming,
                compaction, handoff, worktree, merge, tasks, tasks-notify, skills,
                perms, sandbox, notifications
 Completion     provider, provider-openai, provider-deepseek, provider-claude,
                provider-bedrock, provider-copilot
 Tool calls     tools, tools-fs, tools-shell, tools-emacs, tools-web, tools-agent,
                tools-sessions, tools-notify, tools-handin, tools-dev
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
 harness-files,               TCP     token per spawn; every tool runs here)
 harness-emacs-endpoint
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
  `kill-emacs-hook`, flushing sessions, tasks and streamed text); the
  end of a process it already replaced, reported late, changes nothing.
  `M-x harness-restart` restarts it with fresh configuration;
  `harness-reload` reloads both sides: the UI first, then it asks the
  process (`harness/reload`), which answers whether every file loaded,
  some failed to, or none were loaded because one does not compile.
- The child's event loop (`harness-server--event-loop`) never sleeps past
  the earliest timer.  Batch Emacs runs due timers from a copy of
  `timer-list` inside `accept-process-output` and then sleeps until the
  next timer of that copy, so a timer a timer starts -- every
  `harness-run-soon` of a request handler, the next step of a turn --
  would otherwise wait for an unrelated timer or process output, seconds
  later.
- Every tool runs in the harness process; no client runs one, so an
  ACP client that is not an Emacs (a phone) loses nothing, and the
  harness works headless.  The user's Emacs is a resource some tools
  reach, as a TRAMP host is for the file tools: the UI lends it to the
  harness when it connects (`clientCapabilities._harness.emacs` in
  `initialize`), and the harness sends that one Emacs the small, fixed
  set of `_harness/emacs/*` requests of lisp/harness-emacs-endpoint.el
  through `emacs/request` (see the tools and acp sections).  The
  `emacs_*` tools ask it for plain data and a few bounded actions
  (show a buffer, insert text, save one, trace a function or a
  variable); none evaluates code.  The
  `elisp` tool evaluates in a child `emacs --batch'
  (lisp/harness-elisp.el), never in the lent Emacs: model-written Lisp
  does not run there at all, since a blocking call would freeze it
  beyond recovery, and no setting or request changes that.
- Chores of the UI, which any client may do, are asked for with
  `client/request` (below): saving user options to `custom-file`
  (`harness-save-user-option`), reverting buffers after a tool
  writes a file (event `tools/file-written`), and desktop notifications
  (lisp/harness-notifications-desktop.el, see notifications), so they
  show where the user is and a click on one opens what it is about.
- Project roots and file lists (lisp/harness-files.el) are computed on
  both sides with the same code; the UI lists files itself so `@`
  completion uses the user's projectile cache.
- Each side notes the commit it loaded the harness from
  (lisp/harness-revision.el, see version): the two load their files
  separately, so a restart of the process alone can leave them on
  different commits.

The harness process cannot prompt: TRAMP connections it opens need
non-interactive authentication (ssh agent), and auth-source secrets
must decrypt without a minibuffer (gpg-agent pinentry, not loopback).

`harness-process` nil keeps everything in one Emacs (tests, debugging);
the same `client/request` and `emacs/request` paths then run over the
local connection.

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
if one fails.  It loads harness.el, the core files, the libraries of
lisp/ (`harness--library-files`: files, the Emacs endpoint, desktop
notifications, server, revision) and the modules, so a module never runs against
a library as it was before an update; a file added to lisp/ that both
sides load belongs in one of those lists.  Records made before a reload
keep their layout: a slot added to a struct goes last and is read in a
way that tolerates records without it (see `harness-acp--client-get`),
or the module drops its stale records (see
`harness-provider-claude--drop-stale-entries`).  After a reload the
`harness/reloaded` event fires and the UI redraws every session buffer.

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
 :budget nil|(:amount F :hard BOOL)    ; given to the session; the Budget setting is not copied
 :head "node-id"
 :queue ((:id "q1" :text "…" :attachments (ATTACHMENT…)) …)
 :pending ((:id "p1" :kind permission|question :payload PLIST :created FLOAT) …)
 :todos ((:id :text :status pending|in-progress|done) …)
 :plan nil|"markdown"
 :provider-state PLIST                 ; owned by the provider it names: (:cli-session-id … :provider "claude")
 :provider-node nil|"node-id")         ; the node that provider conversation reached
```

`:provider-state` is opaque to everyone but the provider that wrote it,
which it names as `:provider` (see "provider", Provider state): only
that provider's models continue it, and `session/provider-state` says
whether a given model can.

`:usage :context` is the input size of the last request (prompt tokens
incl. cache); the UI colours it against `:context-window`.  `:cost`
is what the session's calls were billed and `:list-cost` the same calls
at API prices (they differ when a subscription paid); see "Usage
record".

`:context-window` is looked up in the model catalogue (`provider/model`)
each time the session is described, so it follows the catalogue; only
`:context-window-override` is stored.  A copy of the catalogue's window
would go stale when the catalogue changes, or keep the estimate given
for a model whose provider has not answered yet.  When the
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
 :checkpoint PLIST   ; where a hosted provider's conversation stood after this node
 :meta PLIST)        ; anything else (model, duration, cost …)
```

A user message the user did not write says who sent it in its `:meta`
`:from`: `(:kind system :source "tasks")` for the harness itself, from
`harness-sender-system', or `(:kind session :id "uuid" :name "…")` for
another session's agent, from `harness-sender-session' (name as it was
then).  No `:from` means the user; read it with `harness-node-sender'
and `harness-sender-kind' (harness-util, both sides of ACP), which
tolerate a kind that travelled as a string.  The model still gets the
message as a user message; UIs show the sender instead of "You".

A node the harness wrote to hand the conversation over to a model of
another provider (see "handoff") says so in its `:meta` `:handoff`,
`(:mode "transcript"|"compact" :file PATH :from MODEL :to MODEL)`: the
user message pointing the new model at a transcript file (sender
`(:kind system :source "model handoff")`), or the compaction node of a
summary made for it.  Read it with `harness-node-handoff`.  The chat
shows the note as the harness's, with the two models and a button that
opens the file.  An assistant or thinking node's `:meta` `:model` is
the model of the step that wrote it, which a switch during that step
does not change.

A session's transcript is the path root → `:head`.  A fork copies the
ancestor chain (same node ids) into the new session and records
`:parent-id` / `:fork-node`, so the tree view can merge families by id.
A tool call the fork copies without a result gets one of the fork's
own, after the copied nodes (`:meta (:forked t)`).  That happens when
the parent is mid-turn, as with `spawn_agent` forking it, or when its
head was moved back between a call and its result.  The result goes
to the parent, never to the fork, and providers that pair calls with
results (DeepSeek and other strict OpenAI-compatible servers, Bedrock)
reject a request with an unanswered call.

A hosted-loop provider (Claude Code, Copilot) holds the conversation
itself and only gets new user content each turn, so its conversation
and the transcript must agree.  `:checkpoint` is opaque provider data
saying where that conversation stood once the node's content was in it
(for Claude Code `(:cli-session-id ID :uuid UUID)`, the CLI session and
the entry of its chain holding the node).  `:provider-node` is the node
the session's provider conversation reached: the head when its last
turn ended.  When the head is not at or after it (checked out at an
earlier node, or on another branch), the next turn first cuts the
conversation at the last checkpoint on the head's path, or starts a new
one, seeded with the transcript, when there is none
(`session/provider-continuation`, `harness-agent--follow-head`).  A fork
at an earlier node does the same for its first turn.  Either way the
model never knows what came after the node.  A session from before
`:provider-node` is taken to be where its conversation is, unless its
head has a later node of its own (it was moved back) or it is a fork
made at an earlier node of its parent, when the old forks got the
parent's whole conversation; such a session starts a new one.

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
`harness-permission-mode`, `harness-thinking`, `harness-btw-thinking`
(the level BTWs start at, default "low"; nil for the session's),
`harness-allowed-directories`, `harness-sandbox-policy`,
`harness-non-interactive`.  `harness-budget` has a global value only:
it is one budget for all sessions together (see usage).

The other harness options (the `harness` customize group, less the
ones that decide how the harness starts or reaches the UI:
`harness-process`, `harness-state-directory`, the module lists, the
`harness-server-*` and `harness-acp-*` options, minor modes, and less
`harness-corporate-mode`) have a global value only.  `config/set` and
`config/unset` refuse the ones of `harness-config-hidden-options`,
`harness-corporate-mode` among them, as set in the init file only.
Options named `...-api-key`, `-token`, `-secret` or `-password` are
secrets: their values never leave the harness and never go to a
`.dir-locals.el`.

Where an option holds records (the provider endpoints, Bedrock's
per-model defaults, the standing permission rules, a model plist), its
customize type names the keys of the record in `:options`: each key
with a `:tag`, a value type of its own, a `:doc`, and the `:value` it
starts from.  (`harness-provider.el` holds the shared model, price,
modality and thinking-level types; `harness-provider-model-type` adds
a provider's own keys to the model type.)  Keys the type does not name
stay matched, as `plist` does, so a record written in Lisp is never
refused for having an extra key; the settings page draws them last, to
be removed.  A key that names a value type the value does not fit is
refused on save, where a free-form plist would have taken it.

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
says what it was doing or which question it waited on.  Only calls
from the last compaction on count, as for forks: earlier ones reach no
provider, so a result for one would answer nothing.  Pending
requests are not restored: the turn that would read their answers is
gone.

- `session/create &rest PLIST` — `:cwd` required; `:name :model
  :permission-mode :thinking :kind :parent-id :host :worktree`,
  `:context-window` to set the session's own window and
  `:context-window-limit` to cap its model's window at a number of
  tokens (see the compaction section).  Fills
  project, defaults from `config/get`.  A `btw` session without
  `:thinking` takes `harness-btw-thinking` when its model offers that
  level (the catalogue lists it in `:thinking-levels`), else
  `harness-thinking`.  → session.  Event `session/created`.
- `session/get ID`, `session/list &optional FILTER` (`:project :status
  :kind :parent-id :active`), `session/delete ID` (its temporary
  directory goes too).
- `session/tmp-dir ID` → the session's own temporary directory, made if
  missing, or nil.  Every local session has one:
  `harness-UID/ID/` in `temporary-file-directory` (`/tmp/harness-1000/ID/`;
  the internal `harness-session--tmp-root` moves the root, which the
  tests do).  It is made with the session (mode 700, as is the root),
  made again whenever it is asked for and missing (a reboot empties
  /tmp), and deleted with the session.  Being made when asked for is the
  point: callers ask right before they rely on it.  /tmp is shared, so
  only a real directory of the user's own, in a root of the user's own,
  is handed out; a symbolic link or somebody else's directory gives nil
  and one warning in the log.  Remote sessions have none (nothing is
  made on their host).  The perms jail lists it (source `tmp`), bash
  binds it writable in the sandbox, and the system prompt and
  `session_info` name it.
- `session/update ID &rest PLIST` — settings and name; appends a `hint`
  node ("model → …") and persists the setting through `config/set` when
  `:persist t`.  `:context-window N` sets the session's own window, nil
  its model's again; a new `:model` drops a window set for the old one
  unless PLIST sets one too.  `:context-window-limit N' caps its
  model's window at N tokens, nil the model's again, a
  `:context-window' set for the session winning over it.  Event
  `session/updated ID CHANGES`.
- `session/set-all SETTINGS &optional FILTER` — the same change on every
  session FILTER selects (`session/list`'s filter plus `:except` ids);
  returns the ids that changed, newest first.  A session already holding
  the value is skipped, and each one changed gets the same event and hint
  as `session/update`.  This is what `harness-set-model-all` uses to move
  every session to another model or provider at once, when no session
  would lose its conversation (else `handoff/switch-all`).
- `session/provider-state ID &optional MODEL` → the provider state of
  ID that MODEL (default the session's model) can continue, or nil.  A
  state belongs to the provider it names (`:provider`); a model of
  another provider gets nil, as if the session had none.  A state
  written before states named their provider belongs to the provider
  that answered last (the `:meta` `:model` of the newest assistant or
  thinking node), else to the session's model's: another provider
  having answered since means the state's own never saw those turns.
  The record itself is not changed.
- `session/set-status ID STATUS`.  Event `session/status ID STATUS`.
- `session/resume ID` (loads nodes, status idle), `session/deactivate ID`
  (closed: still listed and readable; the next message sent to it resumes it).
- `session/fork ID &rest PLIST` — copies the ancestor chain up to
  `:node` (default the head; ID's head never moves); `:kind
  fork|subagent`, `:name`, `:cwd` (defaults to parent's).  Each copied
  tool call without a result gets one in the fork.  It is an error
  result, `harness-session-forked-output`, saying the session was
  forked before the call returned and its result went to ID.
  `:call-id` names ID's call that forks it to start a sub-agent
  (spawn_agent passes its own).  That call's result is no error:
  `harness-session-spawned-output` tells the fork it is the sub-agent
  the call started, that its task is the next message, and that its
  final message is what the call returns.  Settling keeps the whole
  transcript, the current turn included; trimming back to the last
  finished turn or step would drop the context a fork is for: the
  request being worked on, the reasoning and the results already in.
  Asks the provider to fork its state via `provider/fork` when
  supported: at the parent's head (when that is where its provider
  conversation is) the whole state, at an earlier node the state cut at
  the last checkpoint up to it, and none when no checkpoint precedes
  the node, or when the fork's model is of another provider, which
  cannot continue the parent's state (`session/provider-state`).
  Without a forked state the fork has none, never the parent's own,
  which would carry on the parent's provider conversation; the provider
  then starts a new one from the transcript.  The fork's
  `:provider-node` is the node.  → new session.
- `session/btw ID &optional NAME`: a BTW side conversation over ID, a
  new, empty `btw` session sharing nothing with ID or with any other
  BTW (no nodes, no fork node, no provider state, no directory grants).
  It takes ID's cwd, project, host, worktree, model and permission
  mode; `:parent-id` is ID only so lists show it under ID.  It thinks
  at `harness-btw-thinking` as configured at ID's cwd ("low" by
  default, so quick questions get quick answers) when the model offers
  that level, else at ID's level.  Returns the new session.
- `session/nodes ID &optional (:limit N :before NODE-ID)` → path nodes,
  oldest first; `session/node ID NODE-ID`; `session/tree ID` → every
  node of the family (session + ancestors + forks) as a list with
  `:session` set, plus `:sessions` summaries.
- `session/append ID NODE` → node with id/ts/parent filled; advances head.
  Event `session/node-added ID NODE`.
- `session/update-node ID NODE-ID PLIST` (tool result streaming, titles).
  Event `session/node-updated ID NODE`.
- `session/set-head ID NODE-ID` — time travel: the next message
  continues from NODE-ID, with a provider conversation cut to match (see
  "Node").  Refused while ID runs a turn.  Event `session/head-moved ID NODE-ID`.
- `session/set-provider-state ID STATE`.  Event
  `session/provider-state-changed ID STATE` when STATE differs from the
  one held, so a provider whose live process holds the old conversation
  lets it go.
- `session/set-provider-node ID NODE-ID` (the agent, when a turn ends);
  `session/provider-continuation ID &optional NODE-ID` → `(:mode
  current)`, `(:mode checkpoint :checkpoint CP :node ID)` or `(:mode
  fresh)`: how the provider conversation goes on from NODE-ID (default
  the head).
- `session/hint ID TEXT` → appends hint node.
- `session/queue ID TEXT &optional ATTACHMENTS FROM` (FROM, when
  non-nil, is who sent it, not the user: the item keeps it as `:from'),
  `session/queue-update ID QID TEXT`,
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
  tool results right after it), where the model got it.  Every tool_use
  is answered in the message right after it, whatever the path holds.
  A call whose result is not there gets a stand-in error result
  (`harness-session-missing-result-output`), in a user message of its
  own when none follows.  A tool_result that answers no call of the
  message before it becomes text.  That covers a call cancelled
  mid-turn, a result that came after its turn ended, and a head moved
  back between a call and its result.  The transcript itself is not
  changed, and a message that needs no change comes out as it is.
- `session/transcript-text ID` → searchable plain text.
- Event `session/changed ID SESSION` fires after any of the above (for UIs
  that just want to redraw).

### provider

```elisp
(harness-define-provider 'ID
  :label "Claude Code" :doc "…"
  :models FN            ; (&optional REFRESH) → promise of MODEL plists
  :complete FN          ; (REQUEST) → HANDLE plist (:cancel FN)
  :fork FN              ; (MODEL PROVIDER-STATE &optional CHECKPOINT) → promise of new state [optional]
  :quota FN             ; (&optional REFRESH) → promise of QUOTA (below)     [optional]
  :warm FN              ; (REQUEST) → BOOL: get ready for a request like it  [optional]
  :close FN             ; (SESSION-ID) → BOOL: free what it keeps for one   [optional]
  :resolve FN           ; (NAME &optional MODELS) → MODEL plist or nil: a name
                        ; its listing lacks (an alias, a variant)          [optional]
  :capabilities PLIST   ; static defaults, merged with per-model ones
  :tiers PLIST)         ; a model per tier, see below
```

MODEL = `(:id "ID:NAME" :provider ID :name "NAME" :label "…"
:context-window N :context-window-estimated BOOL :context-window-basis "…"
:max-output N :input-modalities ("text" "image")
:thinking-levels (…) :pricing (:input F :output F :cache-read F :cache-write F)
:pricing-fn SYMBOL :resolves-to "NAME" :capabilities (…))`.  Pricing is
USD per million tokens.  `:context-window-estimated` marks a window
nobody gave for this model, and `:context-window-basis` says what it
was drawn from (see below); `:resolves-to` is the model an alias stands
for.  A model whose rates change with the clock carries `:pricing-fn`,
a symbol called as `(MODEL USAGE AT)` that returns the pricing plist in
effect at AT; `usage/price` uses its answer instead of `:pricing`.  This
is how the DeepSeek provider follows its peak and off-peak tiers, and it
keeps the catalogue plain data that crosses the wire unchanged.

Model tiers: `:tiers' names a model (`:cheap' `:balanced' `:frontier'
are the common ones) by a name, id or regexp, so the harness can pick a
model on its own - the auto-mode judge asks for the cheap one -
without the user naming one.  A tier the provider does not name, and a
provider that declares none, falls back to its own catalogue sorted by
price: `provider/tier-model MODEL-ID &optional TIER' returns the `:cheap'
one by default, or nil when the provider is unknown or lists nothing
(the caller then uses what it has).  MODEL-ID may also be a provider id
alone.  This is what ties the judge to the
session's provider.  Claude, DeepSeek, Bedrock and Copilot name their
tiers; the dynamic OpenAI-compatible catalogues fall back to price.
The other way round, `provider/model-tier MODEL-ID` says which tier a
model is in its provider: the one `:tiers' names it for (`:balanced'
first, then `:frontier', then `:cheap', when several do), else its
place in the catalogue by price (cheapest third `:cheap', dearest third
`:frontier'), else `:balanced'.  So Claude's Fable 5.1, which no tier
names and which costs the most, is `:frontier'.  The fallback module
maps a model to "its model of similar ability" at another provider
through the two.

The catalogue is cached per provider.  Defining a provider again, as
every `harness-reload` does, forgets that provider's models and no
other's.  A provider whose models are not cached is asked by the first
`provider/model` that needs one: a static catalogue answers at once and
is cached before the call returns.  A failed listing is cached as empty
(or keeps the models listed before), so lookups do not ask again before
a refresh (`provider/models t`), which a models function that takes an
argument is told of, so it asks its source rather than its cache.
`provider/models-updated` follows every listing that is cached.  A
provider that learns something its listing should show (a new list
from its source, the window a model really ran with) calls
`harness-provider-relist ID` to have it listed and announced again.

The model lists are not hard-coded.  Each provider lists what its
source lists, with the windows the source gives: the Claude CLI's
`initialize` answer and results, the Anthropic, OpenAI-compatible,
DeepSeek and Copilot model listings, Bedrock's (sections below).  What
a provider ships is a seed for before its source answered, and for
prices.  So a new model works without a code change.

Every MODEL has a context window, and an unknown slug never silently
gets a small one.  A model its provider lists without a window, one
its provider flags as its own guess (Bedrock's family defaults), and a
name no listing holds (an alias, a model a slower provider has not
listed yet, a model of a provider that is gone) get an estimate,
flagged `:context-window-estimated t`, drawn in this order from:
1. the same model where a provider sizes it, its own provider first:
   `harness-provider-model-key` drops vendor and region prefixes, dates
   and Bedrock versions, so `us.anthropic.claude-opus-4-5-20251101-v1:0`,
   `anthropic/claude-opus-4.5` and `claude-opus-4-5` are one model;
2. the model of its own provider that shares the most leading name
   words with it, two at least (`claude-opus-5-6` takes after
   `claude-opus-5-5`, not after `claude-haiku-4-5`);
3. the window most of its provider's models have;
4. `harness-provider-fallback-context-window` (200000).
A provider's own guess gives way to the first two only.  Estimates are
drawn from windows providers gave, never from another estimate, and
made again whenever a listing changes.  A name no listing holds goes to
its provider's `:resolve` first (Claude Code's aliases, Copilot's
`default`, a Bedrock profile ARN), whose answer is estimated only where
it gives no window; the log says once per model when a listed
provider's model got an estimate.  The model picker shows an estimated
window as `~200k`.

Capabilities: `:hosted-loop` (provider runs the tool loop and keeps the
history; the agent only sends new user content, so switching to it
from another provider starts a conversation without the history unless
it is handed over: see "handoff"), `:fork`, `:resume`,
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
loops only the trailing user message is sent: the user messages after
the last assistant message, less tool results.  A turn's
`:provider-state` is the session's state when the request's model can
continue it (`session/provider-state`), else nil.  A REQUEST may also carry
`:builtin-tools`, a list of harness tool names (from `tools/builtin`):
the provider turns on its own tools in their place for this request,
and `:tools` lacks them.  `:no-thinking t` asks for no extended
thinking (the auto-mode judge sends it); Claude Code, which takes no
`:max-tokens`, then runs the CLI with `MAX_THINKING_TOKENS=0`, and
other providers may ignore it.

A REQUEST with `:ephemeral t` is a one-off question, such as the
auto-mode judge's.  The provider answers it from the request alone, as
if nothing came before it and nothing comes after it: it brings no
earlier conversation, keeps none, and loads no context of its own
(project instructions, memory).  Providers that send the whole request
every time (the HTTP APIs) already work that way.  Claude Code starts
a throwaway CLI process for it, and Copilot a throwaway session (see
below).

Events delivered to `:on-event` (one plist each, in order):

```elisp
(:type start)
(:type text :delta "…")
(:type thinking :delta "…")
(:type tool-call :id "…" :name "…" :input PLIST :respond FN-OR-NIL :checkpoint PLIST)
   ;; :respond present ⇒ hosted loop; call it with a tool result
   ;; (:content "…" :is-error BOOL) and the provider continues the turn.
(:type tool-result :id "…" :content "…" :is-error BOOL)  ; hosted loops echo results
(:type checkpoint :checkpoint PLIST :call-id "…")  ; hosted loops: where the conversation stands
(:type usage :input N :output N :cache-read N :cache-write N :cost F-OR-NIL :context N
       :list-cost F-OR-NIL :billing api|subscription|extra-usage|nil :plan ID)  ; see Usage record
(:type call-usage :output N)            ; hosted loops: one model call's output, counted by the turn's usage
(:type provider-state :state PLIST)     ; persist on the session
(:type activity :phase PHASE :tool NAME :chars N)  ; what the model is busy with, see below
(:type quota :windows (…))
(:type hint :text "…")                  ; provider-side notices (compaction, retries)
(:type done :stop-reason end-turn|tool-use|max-tokens|cancelled|error :error "…"
       :error-kind quota|billing|rate-limit|auth|… :resets FLOAT)  ; the last two optional
```

A `done` with `:stop-reason error` may say what kind of failure it was,
when the provider knows: `:error-kind` `quota` (a plan's usage limit is
used up: Claude Max's 5-hour or weekly window, Copilot's monthly
allowance), `billing` (out of money: a prepaid balance or credit spent,
an account on hold), `rate-limit` (a short-term limit; the provider
works again in a moment), or another symbol for anything else (`auth`).
`:resets` is when a quota comes back, as a float time, when the
provider was told.  The Claude provider reads the CLI's assistant
`error` field (`rate_limit` while a usage window is `rejected`,
`billing_error`, `account_on_hold`) and the `resetsAt` of the
`rate_limit_event` that rejected the call; the OpenAI-compatible one
HTTP 402 (DeepSeek's "Insufficient Balance") and a 429 whose code is
`insufficient_quota`; Copilot a `session.error` of type `quota` or
status 402.  The fallback module (below) classifies failures that come
without a kind from their text.

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

`call-usage` reports the output tokens of one model call of a hosted
loop's turn as soon as the call ends. A hosted loop sends a single
`usage` event, for the whole turn, at its end, and that event is the one
that counts: `call-usage` is not recorded anywhere. The agent passes it
on as `agent/call-usage`, so the usage module can measure the output
rate during a long turn.
- Claude Code sends the output that each `message_delta` adds to its
  message.
- Copilot sends each main-conversation `assistant.usage`. Sub-agent
  calls do not count, because their deltas do not stream into the
  conversation either.
- Native loops send none: their `usage` event is already per call.

Forking: `provider/fork` returns a new provider state that may be marked
pending (for the CLI: `(:cli-session-id PARENT :fork-pending t)`); the
first completion consumes it and emits a `provider-state` event that the
agent persists, replacing the pending one.  When it returns nil or
fails, the fork starts without provider state: copied as is, the
parent's would make the fork resume the parent's own CLI session.

Provider state: a state belongs to the provider that wrote it and says
so as `:provider` (a string).  The agent tags each `provider-state`
event with the provider of the model the step went to -- not the
session's model, which a switch during the step changes -- and
`provider/fork` tags what it returns (`harness-tag-provider-state`,
`harness-provider-state-owner`).  Each step sends only a state its
model can continue (`session/provider-state`); a state of another
provider is dropped from the session at that step, since that
provider's turns are ones the state's conversation never saw.  So a
session switched away and straight back resumes its conversation,
while one that ran a step elsewhere starts a new one there, which
`handoff/check` calls lossy.  Naming a whole conversation, compaction
and forks work on a fork of a state their model can continue, never on
another provider's.

Checkpoints: a hosted loop says where its conversation stands as
content lands in it, so that a fork or a checkout at a node can cut the
conversation there later.  A `checkpoint` event without `:call-id`
marks the text or thinking node the turn wrote last (unless a tool call
came after it), one with `:call-id` that call's result, and a
`tool-call` brings its own `:checkpoint`; the agent stores each as the
node's `:checkpoint`.  `provider/fork MODEL STATE CHECKPOINT` returns a
state holding the conversation as it was at CHECKPOINT and nothing
after it (Claude Code: `(:cli-session-id ID :resume-at UUID
:fork-pending t)`, a fork of that CLI session cut with
`--resume-session-at`), or nil when the provider cannot cut there: a
fork function of two arguments, another provider's checkpoint, or
Copilot, whose events carry no checkpoints yet.

Replay: a hosted loop that starts a new conversation for a request whose
`:messages` have messages before the new one (a cut before any
checkpoint, a conversation another provider held, one the CLI could not
resume) sends them first, as text, with the new message
(`harness-provider-split-history`, `harness-provider-history-text`: tool
inputs and results cut at `harness-provider-history-block-limit`, the
oldest messages but the first dropped past
`harness-provider-history-limit`, thinking left out).

Methods: `provider/list`, `provider/models &optional REFRESH` (cached union
across providers), `provider/cached-models PROVIDER-ID` (one provider's
cached models, at once: a provider not listed yet is asked, and gives
nil until it answers; no other provider holds it up),
`provider/model MODEL-ID` → MODEL, `provider/capabilities MODEL-ID`,
`provider/complete REQUEST` → HANDLE, `provider/fork MODEL-ID STATE &optional
CHECKPOINT` → promise, `provider/quota PROVIDER-ID &optional REFRESH`,
`provider/warm REQUEST` (ask the provider to prepare what a request like
REQUEST, which has no messages, will need -- the Claude CLI spawns its
process now, so the answer comes sooner; a failure is only logged) and
`provider/close MODEL-ID SESSION-ID` (free what the provider keeps for a
session id of a request that is not a session of its own, such as a task
board's search; the CLI kills its process).  The model used when nothing
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
provider learns something new; the UI caches QUOTA from it, and the
usage module counts `:extra :used` in month budgets over everything
(see usage).

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

The Claude provider's models are what the CLI says they are.  Every
`initialize` answer (each new process's, the quota probe's, and a
probe's started when a refresh asks) lists what its /model picker
offers: aliases such as `opus` and `sonnet[1m]`, their labels and effort
levels and, from Claude Code 2.1.197 on, the model each resolves to.
Every result's `modelUsage` gives the context window the CLI ran each
model with, and the name a process was started with takes the window
of the model it ran.  With an Anthropic API key
(`harness-provider-claude-api-key`, else ANTHROPIC_API_KEY or
auth-source), `GET /v1/models` adds every model the API serves, with
its window, output limit and effort levels.  What was learned is kept
in `claude-models.json` in the state directory;
`harness-provider-claude-models` only seeds the catalogue and gives
prices.  An alias or a name nothing lists is resolved
(`harness-provider-claude--resolve`): a learned window, a `[1m]`
variant's million tokens, the window of the model it resolves to, else
the window of its family's newest listed model, flagged as an estimate.

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

A session whose context window is below its model's (a task's is capped
by `harness-tasks-context-limit') is spawned with
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` set to that percentage, so the CLI
auto-compacts at the shorter budget the harness gave the session rather
than at its own default.  The percentage is part of the settings a
process was started with, so changing the cap restarts the CLI with
`--resume`, like the model and system prompt.

The CLI loads the CLAUDE.md files as `claude` does, but not Claude
Code's auto memory: every process it starts gets
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` unless
`harness-provider-claude-auto-memory` is on.  The memory's index,
MEMORY.md, lists notes kept under `~/.claude/projects/PROJECT/memory/`,
which Claude Code reads and writes with its own file tools, following
instructions in its own system prompt.  A harness session has neither,
so the model opened the notes with the harness's file tools, outside
the allowed directories, and every session asked the user for that
directory (or, unattended, was refused it).  Whether a process loads
the memory is part of the settings it was started with, so changing the
option restarts the CLI with `--resume`.

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

The CLI asks for the harness's tools (MCP `tools/list`) once, in a
handshake that follows the harness's `initialize`, and keeps the list
for the life of the process.  That handshake can come while no turn is
in flight: a request whose trailing messages are only tool results
spawns the process and ends at once ("No user message to send"), as
the first step after a mid-turn switch to Claude Code did.  So the
process record keeps the tool set of its last request after the turn
(`tools` slot) and `tools/list` answers from it, never with an empty
list for want of a running turn.

Every `assistant` message and tool-result echo of the CLI carries the
uuid of its entry in the CLI session's chain; messages of a sub-agent's
chain (`parent_tool_use_id`) do not count.  The provider reports them
as checkpoints `(:cli-session-id ID :uuid UUID)`: a message with a
`tool_use` on that call's `tool-call` event (the call is served later),
any other at once, and an echo once per result it holds.  A fork at a
checkpoint is `(:cli-session-id ID :resume-at UUID :fork-pending t)`,
which spawns `--resume ID --fork-session --resume-session-at UUID`: the
CLI keeps the chain up to and including that entry (print mode only,
which the provider uses).  A running process is reused only when it was
started with the request's settings and holds the CLI session the
request's state names -- a session whose state was dropped, because it
went on with another provider, starts a new CLI session rather than
carry on a stale one; a `:fork-pending` state always gets a new one.
`session/provider-state-changed` to a state naming another CLI session,
or none, closes the session's idle process.

A process told to resume or fork that exits before it announces its
session (`system/init`) could not open that conversation: the CLI
session is gone, the uuid lies before a compaction of the CLI's (a
resume loads only the chain since the last one), or the CLI is too old
for `--resume-session-at`.  The turn then goes on in a new CLI session,
which gets the transcript and the turn's message, and a hint says so; a
session never gets stuck on a conversation the CLI cannot resume.  A
new CLI session opened for a transcript that has messages before the
new one gets them the same way.

A request whose provider state is not the one its session has recorded
(naming the whole conversation sends a fork of it) runs in a CLI
process of its own, closed when it is done.  It never restarts the
session's process with its own settings or writes into the session's
CLI session.

A one-off request (`:ephemeral t', the permission judge's, or naming a
session from its first message) gets a CLI
process of its own whatever its state, under a key of its own
(SESSION-ID~N), never resumed and stopped once it is done (its input is
closed, and it is killed if it still runs a few seconds later).  It
runs with `harness-provider-claude--ephemeral-environment'
(`CLAUDE_CODE_DISABLE_CLAUDE_MDS=1',
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1',
`CLAUDE_CODE_SKIP_PROMPT_HISTORY=1'; a CLI that does not know one
ignores it), so it loads no CLAUDE.md and no auto memory and saves no
transcript, and a local session's runs in a private empty directory,
`claude-one-off/' in the state directory, rather than the project's, so
no project settings or hooks apply either.  This keeps the permission
judge's verdicts on the call alone.  When the judge kept one CLI
conversation per session, started in the project, each verdict saw the
earlier ones (whether the work had been handed in, say) and the
project's CLAUDE.md, and judged by them.

The Bedrock provider (`provider-bedrock`) is a native loop over the
Converse API: one ConverseStream request per call, its binary event
stream decoded into `text`, `thinking`, `usage` and `tool-call` events.
Each entry of `harness-bedrock-endpoints` is a provider (default
`bedrock`); model ids are `ID:MODEL-ID`.  Its catalogue comes from
ListFoundationModels and ListInferenceProfiles, cached an hour per
endpoint; a refresh lists again, and a listing that fails keeps the
models listed before.  Context windows and prices, which Bedrock does
not report, come from `harness-bedrock--model-defaults`; a family's
catch-all window there is flagged as a guess, which the same model's
window at another provider replaces, or else that of the endpoint's
closest model by name that the defaults size.  A model no default knows gets
the endpoint's `:default-context`, else an estimate, and a name the
listing lacks (an application inference profile ARN) is described from
the defaults by its `:resolve`.  Usage events carry tokens and
`:billing api` but no cost, so `session/usage-add` prices them from the
catalogue.  Claude and Nova requests carry prompt cache points; Claude
reasoning returned with tool calls is kept and sent back with them while
the tool loop lasts.  `harness-http-request` takes `:binary t` for such
framings: the response then reaches `:on-chunk` as unibyte strings.

An endpoint can point at a gateway in front of Bedrock instead.  Its
`:endpoint-url` holds the prefix that Bedrock's paths go under, and a
query that every request keeps (`harness-bedrock--url`).  Listing
follows a runtime URL whose host is not AWS's
(`harness-bedrock--control-url`), so a gateway's keys and headers never
go to AWS.  Requests are authenticated in one of three ways:

- An API key in the header the endpoint names.  It comes from a
  variable, auth-source, or `:bearer-token-command`, whose output is
  kept until the key expires.  The command runs again once when the
  gateway refuses the key, for a chat request or a listing.
- SigV4 for the gateway's own URL.
- SigV4 for Bedrock's own URL, with `:sign-for-aws`, for a gateway that
  passes requests on unchanged.  The AWS host is signed but not sent.

`${NAME}` in `:headers` is read from the environment and kept out of
every message.  Saving the setting re-registers the providers.  It also
forgets the cached models, quirks and kept keys of each endpoint whose
entry changed (`harness-bedrock--forget-endpoint`), so an edit shows
at once, and a listing that fails after it does not bring back the
models of the old setup.  The tests run a stub gateway from harness-bedrock-mock.el
(`:prefix` and `:checks`), and nothing else is reachable while they
run.

The OpenAI-compatible provider (`provider-openai`) makes a provider of
each entry of `harness-openai-endpoints`.  Its models are what the
server lists at /models, asked again after an hour or when a refresh
asks; a listing that fails keeps the models listed before.  The window
comes from whichever field the server names it with (`context_length`
and `top_provider.context_length` of OpenRouter and others,
`context_window` of Groq, `max_context_length` of Mistral and LM
Studio, `max_model_len` of vLLM, `max_input_tokens` of LiteLLM), else
the endpoint's `:default-context`, else the catalogue's estimate:
plain OpenAI lists ids alone.

The DeepSeek provider (`provider-deepseek`, `deepseek:` models) is the
OpenAI-compatible one with `:flavor deepseek`: the streaming comes from
harness-provider-openai.el, which splits DeepSeek's cached input out of
`prompt_tokens` (its `:input` bills the cache misses, `:cache-read` the
hits), sends the reasoning efforts DeepSeek accepts, and rebuilds
`reasoning_content` on assistant messages from their recorded thinking
(empty when there is none).  DeepSeek acts on three efforts only — low,
high and max (`harness-openai--deepseek-efforts`) — and collapses the
levels in between the way its own API does (minimal is low; medium and
xhigh are high), so a model advertises that three-step ladder and the
thinking menu offers no level DeepSeek cannot tell apart.  Its /models
route reports the ladder (`effort.supported_levels'), which the
catalogue takes as the model's `:thinking-levels'.  DeepSeek's thinking
mode, on by default,
rejects a tool-using history whose assistant messages omit that field,
so the whole conversation goes back to it, not just the model's own
call.  The handling follows an official DeepSeek host, not only the
flavor: a hand-written OpenAI-compatible endpoint at `api.deepseek.com`
still gets it (even when it names `:flavor openai'), so its tool loops
do not 400, and the cache fields it reports are split so cached input is
billed at the cache-hit rate, while OpenAI and OpenRouter hosts still
drop thinking.
`harness-deepseek-*` adds registration and prices.  Its models are
what DeepSeek's /models lists (names, windows, output limits,
modalities, effort levels), asked in the background once the listing
is an hour old, so the catalogue never waits on the network;
`harness-deepseek-model-specs` adds prices and labels, and is what is
listed before /models answered or when it cannot be reached.  A model
DeepSeek adds is priced by the tier its name says (flash or pro).
The provider is created only while a key is found
(`harness-deepseek-api-key`, DEEPSEEK_API_KEY, or auth-source), so
nothing uncallable is listed; see `harness-deepseek-always-register`.
DeepSeek bills peak hours
(01:00-04:00 and 06:00-10:00 UTC, Monday to Friday, minus Chinese public
holidays) at double the off-peak rate, so the catalogue carries
`:pricing' (off-peak) and `:peak-pricing' and the model's
`:pricing-fn' picks between them; cached input, cache-miss input and
output are priced separately.  A `provider/pricing-warning` event and a
session hint say once per peak window that a call costs more.

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
  turn turns into `sessions.fork`.  A fork at a checkpoint is nil:
  Copilot reports none yet (`sessions.fork` takes a `toEventId` it
  could use), so a fork or a checkout at an earlier node starts a new
  Copilot session.  The first message to a session created for a
  transcript with messages carries them (see "Replay").
- Side requests are one-off questions: naming, compaction and the
  permission judge.  A request is one when it sets `:ephemeral` (the
  judge's, and naming a session from its first message) or
  `:max-tokens` (a turn
  of the conversation never caps its answer), when its provider state
  is not the one its session has recorded (naming the whole
  conversation brings a fork of it), or when its session record has no
  state at all (the judge's and naming's).  Any
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
no session process runs.  `copilot:default` resolves to
`harness-provider-copilot-default-model`, with that model's window,
levels and prices.

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
rules, `harness-perms--auto-allow-tools`,
`harness-perms--inspection-tools`) and in the text agents read
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
- Corporate mode (`harness-corporate-mode`) turns off the tools of kind
  `net` other than web search (`harness-tools--corporate-net-tools`:
  web_search).  No session gets them; the list without a session still
  has them.  `tools/execute` and `tools/authorize` deny a call of kind
  `net` to any other tool (one the harness lacks included) before the
  `permission/decide` chain, whatever the mode and the standing rules:
  reason "corporate mode: network tools other than web search are
  off", a hint to work with the project and the tools the session has,
  `:denied t`, and `permission/decided` as for any decision.
  web_search stays, and so does a provider's own search standing in
  for it (`tools/builtin`); their calls go to the chain as in any mode.
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
20 mode, 25 write-up (the tasks module: a backlog write-up only reads),
30 auto (LLM judge), 40 non-interactive, 90 ask-user (turns `ask` into a
pending request and resolves when answered).  A judge denial reaches 90
as an `ask` in an interactive session, so the user answers it; in a
non-interactive session it stays a denial.

- The sandbox guard asks `sandbox/check-command` about every `exec` call
  whose input has a `:command` (the bash tool), passing the directory it
  runs in and the session's own worktree (`:worktree`, else `:cwd`).  A
  refusal is a final deny, in every mode, yolo and standing rules
  included: the command would do damage only because it runs sandboxed
  (see sandbox).  A guard that fails lets the chain go on.

- `permission/answer SESSION-ID PENDING-ID ANSWER` — ANSWER
  `(:behavior allow|deny :scope once|session|always :reason :pattern)`,
  or an option id string such as "allow-session" (what ACP clients send
  back), also as `(:option ID :pattern P)`.
- Patterns: a prompt about a path outside the roots (the jail's, or an
  agent's `request_directory_access`) is answered for a glob pattern,
  not for one file.  Its payload's `:pattern` is everything in the
  directory it asks for (`DIR/**`: the directory holding a file, or a
  directory itself), with symbolic links resolved.  No other prompt
  carries one (see the tool prompt below).  ANSWER's `:pattern`,
  absolute or relative to the session's cwd, replaces it: more specific
  (`DIR/sub/**`, `DIR/*.el`, one file) or less (a parent).  Roots and
  rule paths alike are directories, holding themselves and all below,
  or globs, which have a `*` or a `?` (`*` within a name, `**` across
  directories, `**/` also none, `?` one character;
  `harness-glob-regexp` in harness-util, shared with the glob tool),
  matched case-sensitively against resolved paths by
  `harness-perms--within-p`.  Brackets are no classes there: they match
  themselves, so a directory such as `Photos [2024]` stays a directory.
  `DIR/**` also holds DIR itself, and a glob ending in `/` holds
  everything below the directories it matches.  A grant of `DIR/**` is
  kept as the directory DIR/, so default grants read as before; a grant
  narrowed to one file keeps its name.
- What a shell command reaches: the bash tool's `:paths` is where it
  runs, which is all the jail checks (the sandbox confines the command,
  and the mode and the judge read it whole).  For an `exec` call with a
  `:command`, `harness-perms--command-paths` reads the paths the
  command line names: a best-effort word scan (quotes, backslashes,
  comments, `;` `&` `|` `(` `$(` and backquotes, redirections) that
  keeps words that are absolute, start with `~` or `$HOME`, or with
  `./` or `../`, and the values of `--option=…` and `NAME=…` words;
  not the programs it runs (the first word of a command, after
  assignments, keywords and prefixes such as `sudo` or `xargs`), not
  `/dev/null` and the like, and on this machine not an absolute word
  whose first directory does not exist, so a `/api/v1` in a grep is no
  path (on a remote host nothing is looked up, and `~` words are left
  out).  The call is about its subject paths
  (`harness-perms--subject-paths`): the ones it names outside the
  session's directories, or, when it names none there, where it runs,
  as before.  The tool prompt shows them, so `ls -la
  ~/.claude/projects/x` run in the project names `~/.claude/projects/x`
  and not the project (being about the call, it offers no pattern, see
  below), and the rules weigh them (below).
- The jail asks instead of denying when a path lies outside the roots
  and someone can answer: a pending `permission` request whose payload
  carries `:dir`, `:pattern` and the options allow-once (this call may
  reach the pattern) / allow-session (grant the pattern to the session)
  / allow-always (add it to `harness-allowed-directories`) / deny-once
  / deny-always (a standing rule `(:path PATTERN :behavior deny)`, for
  every tool).  After a grant the rest of the chain still decides the
  call itself; a pattern that leaves the call's path out makes the jail
  ask again.  A rule that denies the call anyway denies it at once,
  without asking.  Non-interactive sessions are denied with a hint as
  before.  The prompt names the directory with symbolic links resolved,
  since that is what the jail compares and what a grant opens.
- Agents ask for a directory themselves with the `request_directory_access`
  tool (`path`, `reason`).  The dir-request stage owns that tool's
  decision and always makes it final, so the mode, standing rules,
  `harness-perms--auto-allow-tools` and the auto judge never see it.
  In every mode, auto and yolo included, a directory is granted only
  by a person answering the prompt.  A directory that is already
  reachable is allowed at once and nothing is granted.  Non-interactive
  sessions are denied with a hint, and so is a directory a path rule
  for no tool in particular denies (`harness-perms--dir-rule`, what
  deny-always records); no rule grants one.  Otherwise the session
  blocks on a `permission` prompt (`:dir`, `:pattern`, the agent's
  reason, options allow-session / allow-always / deny-once /
  deny-always; a generic allow-once answer grants to the session).  The
  decision hands the handler the grant as `:granted` in its `:input`,
  and the handler tells the agent what it can reach, saying so when the
  user granted another pattern than it asked for.  Being a permission
  and not a question, the
  prompt cannot be answered by another agent through `session_control`.
  The auto judge is also told to deny calls that widen the agent's own
  permissions some other way (for example `harness-allowed-directories`
  in `.dir-locals.el`, the permission mode, or the sandbox).
- The roots of a session are its cwd, its worktree, its own temporary
  directory (`session/tmp-dir`, asked for on every look at the roots, so
  it exists whenever the jail lets a call into it), the configured
  `harness-allowed-directories`, its grants and the tool output
  directory.  The temporary directory needs no grant and cannot be
  revoked.
- Inspecting the harness itself is one of the things that make it
  powerful, so no mode, judge or jail stands in its way.  The harness
  is no root, but a call of kind `read` may read it, in every mode,
  with the user there or away: `harness-perms-inspection-dirs` lists
  `harness-directory`, the checkout its harness.el links into when it
  is a symbolic link (a straight.el build directory links every source
  into the package's repository), and `harness-state-directory` (the
  sessions with their transcripts, the task boards, usage).  The jail
  lets such a read through (`harness-perms--inspectable-p`) and the
  mode stage allows it with no judge asked ("reading the harness itself
  never needs approval"); a standing rule still decides first.
  Writes, commands, sub-agents and directory grants there are jailed as
  anywhere outside the roots, and their denial says reading needs no
  grant.  The credentials in the state directory
  (`harness-perms--private-files`: `acp-token`, and `server-config.el`
  with the API keys forwarded to the harness process) are left out,
  since what a tool reads goes to the model's provider; so is a search
  below a directory that holds them, which the tools that only list
  names (`harness-perms--listing-tools`: list_dir, glob, file_info) may
  still look at.  Symbolic links are resolved first, out of the harness
  as much as into it.
- `permission/allow-dir SESSION-ID DIR &optional SCOPE` (SCOPE `always`
  grants every session), `permission/revoke-dir SESSION-ID DIR`,
  `permission/dirs SESSION-ID` (`(:dir :source cwd|worktree|tmp|config|session|outputs
  :revocable)` plists, for the directory buffer), `permission/allowed-dirs SESSION-ID`
  (the full effective root list), `permission/rules SESSION-ID`
  (`(:mode :non-interactive :auto-allow :session :always :roots :inspect)`:
  `:auto-allow` holds the inspection tools too, and `:inspect` the
  directories of the harness itself),
  `permission/pending SESSION-ID`.
- Session directory grants are stored on the session record
  (`:allowed-dirs`), so they survive restarts and forks inherit them.
- Rules are plists `(:tool NAME-or-nil :kind KIND-or-nil :path PATTERN-or-nil
  :behavior allow|deny)`; session rules live in memory, always-rules in
  `harness-perms-rules`.  A rule with a `:path` (absolute, or relative to
  the session's cwd) applies to calls with paths only: an allow rule when
  the pattern holds every path of the call, a deny rule when it holds
  any.  For a shell command an allow rule needs every subject path (the
  ones it names outside the session's directories, else where it runs),
  so a rule for the project no longer lets `rm -rf ~` run in it; a deny
  rule holds when any path it names, inside or out, or where it runs
  lies in the pattern.  The mode stage checks them first, before the
  auto-allow list and the mode.  A tool prompt (the mode asking, or the
  auto judge objecting) is about the call itself, whose paths the jail
  already let through: it offers no pattern, and its allow-session /
  allow-always / deny-always answers record `(:tool NAME :behavior B)`,
  for every call of the tool, a `:pattern` in the answer notwithstanding.
- Events `permission/requested SID PENDING` (PENDING `(:id :kind permission
  :payload (:tool :input :kind :paths :call-id :title :options))`, plus
  `:dir`, `:pattern` and `:reason` for a directory prompt; a tool
  prompt's `:paths` are its subject paths, and a shell command's prompt
  has `:cwd`, where it runs; UIs offer only the listed `:options`, and
  show a pattern only when there is one),
  `permission/decided SID REQUEST DECISION`, `permission/dir-allowed SID DIR`.
- Modes: `ask` (reads inside the jail allowed; everything else asks),
  `accept-edits` (reads/writes inside the jail allowed; exec/net ask),
  `auto` (reads inside the jail allowed; a cheap model,
  `harness-perms-auto-model`, decides the rest with a reason; falls back
  to ask).  The judge model defaults to `auto', which asks the session's
  own provider for its `:cheap' tier (`provider/tier-model'), so a
  session on DeepSeek is judged by a DeepSeek model and one on Claude by
  Claude Haiku; a provider without tiers is sorted by price, and the
  session's own model is the last resort.  Naming a model, or nil for
  the session's own, overrides it.  `yolo` allows everything; the jail
  still applies.  Tools in
  `harness-perms--auto-allow-tools` are allowed in every mode: the meta
  tools, skill lookups, `web_search`, which only sends its
  query to the configured search provider, so task sessions can search,
  `notify`, which only reaches the user through the notification
  providers they set up, so unattended sessions can say they need them,
  and `hand_in`, which only records a task's report and ends the turn.
  So are the tools in `harness-perms--inspection-tools`, which only
  inspect the harness or the user's live Emacs: `emacs_buffers`,
  `emacs_buffer`, `emacs_windows`, `emacs_describe`,
  `emacs_find_definition`, `emacs_messages`, `session_info`,
  `session_list`, `session_read`, `session_search`, `session_wait`,
  `task_list`, `task_wait` and `notification_providers`.
  The model provider's own search, standing in for `web_search` (see
  `tools/builtin`), is decided as `web_search` too, so the same rules
  and the same auto-allow apply to it.
  `web_fetch` reaches any URL and stays with the mode (the judge in auto).
- Switching a session that waits on a `permission` prompt into `yolo`
  answers the prompt (a `session/updated` handler): answering it
  allow-once lets the call run, since yolo would have allowed it without
  asking.  Only what the mode stage now allows is answered, so a
  standing deny rule still decides; a directory prompt keeps waiting,
  because not even yolo grants a directory without the user.
- The judge is a safety check, not the agent's manager.  Its prompt
  (`harness-perms--judge-system`) has it decide one thing: whether the
  call risks serious harm that is hard to undo.  That means destroying
  data outside the roots, force pushes, system changes, sending secrets
  away, or widening its own permissions.  It leans to allowing:
  reads anywhere, edits, builds, tests, local git and scratch files
  anywhere (temporary directories included) are ordinary work, and so
  is inspecting the harness itself wherever it lives, with any tool,
  Emacs Lisp included, its credentials (`acp-token`,
  `server-config.el`) excepted: the judge sees only the inspection the
  rules above do not already allow.  It
  never rules on the task, its scope, its review or the project's
  workflow, and it is given nothing to rule on them with.  The user
  message (`harness-perms--judge-text`) holds the call alone: the tool,
  the first sentence of its description, the input, the working
  directory, the allowed roots and where the harness lives
  (`harness-perms--judge-harness`: its code and state directories and
  its credential files).  The request is `:ephemeral`, so the
  provider brings no earlier verdicts and no project instructions
  (CLAUDE.md).  A judge's denial carries `harness-perms-judge-deny-hint`.
  A long input is cut (`harness-perms--judge-input-chars') and the block
  above it says so; the judge is told to weigh what the call would do,
  never whether a value looks complete, since a cut input once read as
  the agent's own truncated edit ("the replacement string is
  truncated ... that would corrupt the file").
- A judge denial is a verdict on one call, not on the work, so an
  interactive session puts it to the user instead of enforcing it
  (`harness-perms--judge-decision`): stage 30 hands on an `ask` that
  keeps the judge's reason and `:judge-deny', stage 90 opens the
  permission prompt (`harness-perms--judge-prompt-reason` words it as
  "The permission judge would deny this call: …"), and the user answers
  it like any other permission request: allow once, for the session, or
  always.  Switching the session to yolo used to be the only way past a
  denial the user disagreed with.  A non-interactive session has nobody
  to ask: the denial stands and the agent is steered to another
  approach.  A judge that gives no verdict at all leaves the call `ask`
  as before, which the user is asked about in an interactive session.
- Jail denials are final and carry a constructive hint listing the
  allowed roots and how to widen them.  A path elsewhere in the
  system's temporary directory (and the agent's own request for one)
  also sends the agent to the session's own temporary directory, where
  scratch files go without stopping the session.  A path in the harness
  itself (and the agent's own request for one) adds that reading it
  needs no grant, and a read refused for reaching the credentials names
  them (`harness-perms--inspection-hint`).
- Non-interactive (the user is away) is no permission policy of its
  own and refuses nothing for being unattended: the auto judge
  (stage 30, `harness-perms--judge-p`) decides what would ask the user,
  in every mode, and its verdict stands.  The judge gets two calls:
  when the first ends at its output limit (`max-tokens`) without a
  verdict, which a reasoning model does after spending the small first
  budget thinking, stage 30 asks again with more room
  (`harness-perms--judge-retry-max-tokens') before it gives the call
  up; a verdict written before the cap is taken as it stands.  The
  judge asks for no extended thinking (`:no-thinking`), so the verdict
  is not left unwritten or half written behind the model's thinking.
  A call
  it gives no verdict on
  (it failed, timed out or answered without one; stage 30 passes the
  `ask` on with `:no-verdict` saying why) nobody can approve, so stage
  40 denies it, with that cause as the reason and a hint that this was
  no verdict on the call, which may be tried once more.  Directories are
  still granted by a person only: the jail and the dir-request stage
  deny.  After every denial in a non-interactive session, whoever made
  it, the `permission/decided` handler sends the agent a steering
  message (`harness-perms-steering-text`), once per call and only while
  a turn runs to take it, marked as from
  `harness-sender-system "non-interactive mode"`: the user is away, so
  respect the denial and reach the goal another way.
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
- The bash tool passes the session's own temporary directory
  (`session/tmp-dir`) as `:writable`.  It is bound at its real path,
  after the private tmpfs on /tmp, so a command can leave files there
  for the next command and the other tools, while the rest of /tmp
  stays private to each command.
- A CWD inside a linked git worktree also gets the repository's common
  git directory read-write (its `hooks/` and `config` stay read-only, so
  nothing planted there runs when the harness uses git unconfined; the
  main checkout's `index` and `HEAD` stay read-only too, since git there
  would see the main checkout's files, absent from the sandbox, as
  deleted and could wreck its index) and
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
  queues, even while a turn runs.  OPTS `:from`, when the user is not
  the sender, is the sender plist (see "Node") kept on the message's
  node (and on a queued item).  An empty message is refused.  An
  inactive session is resumed first (`session/resume`), so a message
  sent to a closed session brings it back; queueing leaves it closed.
- `agent/cancel SESSION-ID`.
- `agent/send-queue SESSION-ID` — sends every queued item as one turn;
  the message is the user's when any item is, else from the first
  item's sender.
- Sync filter `agent/message` (value the message's blocks; args SID
  and `(:from FROM :steering BOOL)`) on every message as it is
  delivered: when it starts a turn or steers one, a queued message when
  its queue goes out, never while it waits there.  What it returns is
  the message (nil leaves it as it was); the tasks module sends a task
  waiting for review back this way.
- Sync filter `agent/system-prompt` (value string, args session); sync
  filter `agent/tools`; sync filter `agent/builtin-tools` (see
  `tools/builtin`); async filter `agent/before-turn` (value
  `(:proceed t :reason)`, args session) — budgets, merge holds and
  compaction hook in here; async filter `agent/step` at every step
  boundary (same value shape) — merge holds pause here; async filter
  `agent/step-error` when a provider request fails (value `(:retry
  nil)`, args session and FAILURE `(:error TEXT :error-kind KIND
  :resets FLOAT :model MODEL-ID :step N)`, the `done` event's keys plus
  the model the step ran on) — a handler that returns `(:retry t)`
  has the step run again, on the session's model as it is then: the
  fallback module switches the model and retries.  A turn retries at
  most `harness-agent--max-error-retries` (8) times; otherwise, and
  without a handler, the turn ends with `error` as before.
- Events `agent/turn-started SID`, `agent/turn-ended SID REASON`,
  `agent/stream SID NODE-ID KIND DELTA` (kind text|thinking),
  `agent/tool-call SID NODE`, `agent/tool-result SID NODE`,
  `agent/activity-changed SID ACTIVITY`.
- The system prompt's Environment section names the working directory,
  the session's own temporary directory (asked for with
  `session/tmp-dir` at every step, so it exists whenever the model is
  told about it; the line is left out when there is none), the project,
  the date, the system and the Emacs version.
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
  A turn has no step limit: long unattended work is the point, and the
  loop ends when the model stops, the provider errors or hits its
  output limit, the user cancels, or an `agent/step` filter (a merge
  hold) pauses it at a boundary.  Automatic compaction runs between
  turns (`agent/before-turn'), not inside one, so a native-provider
  turn that outgrows the window reaches the provider's own error;
  budgets refuse new turns.
- Each step reads the session's model afresh: a model switch reaches a
  running turn at its next step, never mid-step.  The step sends only
  the provider state its model can continue and drops one of another
  provider (see "provider", Provider state); what the step writes (the
  `:meta` `:model` of its nodes, the provider state it reports) is the
  step's model's.
- Every node a model produces (assistant, thinking, tool-call) records
  that model in `:meta :model`.
- Handoff to a hosted loop: a hosted provider only gets the trailing
  user message, its own conversation being the rest.  When the
  transcript holds output of another provider's model after this
  provider's last (a fallback, or a model switched by hand), what that
  conversation missed -- from there, or from the last compaction --
  is rendered as text at the head of the trailing user message:
  messages, tool calls and results, each cut to
  `harness-agent--handoff-item-chars`, the oldest left out beyond
  `harness-agent--handoff-max-chars`; thinking is left out.  A request
  that ends in tool results (a step retried mid-turn) closes the text
  by asking the model to carry on, since a hosted provider drops tool
  results it did not ask for.
- Streaming updates of the live node are not persisted one by one; on
  exit (`kill-emacs-hook`) and shutdown the text streamed so far is.
- Provider conversation and head: before a turn's gate,
  `harness-agent--follow-head` asks `session/provider-continuation`.
  When the head moved off the provider conversation, it stores the
  provider's fork cut at the last checkpoint on the head's path
  (`provider/fork` with that checkpoint), or no state, and the head as
  `:provider-node`.  The turn then runs on the cut conversation, or a
  new one seeded with the transcript.  Every turn's end records the
  head as `:provider-node`.  `checkpoint` events and a `tool-call`'s
  `:checkpoint` are stored on their nodes (see "provider").
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
  prices (rows from before list costs count their cost).  By project a
  row also has `:main`, the main checkout its project belongs to
  (`harness-files-owning-checkout`, resolved here so the UI never reads
  the disk for it): a linked git worktree's, such as a task's, is its
  repository's main checkout, also once the worktree is removed or git
  pruned its registration; any other project's is its own root, and the
  row without a project has "".
- `usage/budgets`, `usage/set-budget BUDGET`, `usage/remove-budget ID`,
  `usage/budget-status ID &rest (:now)` (ID may be "session:SID" for a
  session's implicit budget) → `(:budget :spent :amount :remaining
  :fraction :hard :per-day :days-left :period-start :period-end
  :baseline :reported :sources)`;
  `usage/session-budgets SID` (every budget that applies to the
  session), `usage/project-budgets ROOT` (the project budgets of ROOT
  and the period budgets of everything or of ROOT, as statuses; what
  the task board shows), `usage/plan-budget AMOUNT PERIOD DAYS`,
  `usage/totals`, `usage/series (:bucket day|hour …)`, `usage/record ROW`.
  BUDGET = `(:id :scope session|project|period :target ID-OR-ROOT
  :amount F :hard BOOL :period day|week|month :days business|all
  :baseline F :baseline-period-start "YYYY-MM-DD")`.
- `:spent` is the recorded cost, plus `:reported`, plus `:baseline`.
- A budget over everything (scope period, no target, a day, week or
  month: `harness-usage-backfills-p`) backfills from what providers
  report they billed in its period.  `:reported` is the sum of each
  source's `:outside`, and `:sources` lists them as `(:source ID :label
  NAME :kind extra-usage|cost-report :amount :recorded :outside :at
  :detail TEXT)`, plus `:since :until` for a cost report.  `:amount` is
  what the source reported as of `:at`, `:recorded` what the harness
  recorded before then that the source counts too, and `:outside` the
  rest, never below 0.  Two sources:
  - Extra usage: a `provider/quota-updated` QUOTA whose `:extra :used`
    is in US dollars covers the calendar month of its `:updated` time.
    That is Claude Code's usage credits (the CLI's `get_usage`) or
    Copilot's overage.  It counts in month budgets, less that
    provider's rows billed `extra-usage`.  A QUOTA without `:extra`
    (per-token billing) drops the provider's report.
  - Anthropic's cost report (below), for the UTC days of the period's
    local dates, less the Claude rows billed per token.  It is fetched
    in the background, from the command loop, when a status is computed
    without `:now` and the last try for that period is older than
    `harness-usage-cost-report-interval` (600 s).  A failure, or a
    missing key, is remembered for as long and keeps the amount fetched
    before.
  Reports live in memory, and `usage/reported-changed REPORT` fires when
  one changes (forwarded to clients, and the dashboard reloads).
  Project, session and per-project budgets do not backfill: a provider
  cannot say what one project spent, and a session spends only through
  the harness.
- A baseline is what was spent that the harness never recorded and no
  provider reports (other tools, the console, days before it kept
  usage), set by hand so a budget made mid-month does not start at $0.
  It counts besides `:reported`: a period budget's only while the
  current period starts on `:baseline-period-start` (set-budget fills
  in the period containing now, and moves any date or float time to its
  period's start), one without a period always.  The status's
  `:baseline` is that part, 0 otherwise.  nil or 0 clears it.
- `usage/fetch-api-cost &rest (:period :now)` gives a promise of what
  Anthropic billed in the calendar `:period` (day, week or month, the
  default) containing `:now`, from its Admin API (`GET
  /v1/organizations/cost_report`, UTC days, amounts in cents):
  `(:available t :amount :recorded :outside :period :period-start
  :since :until)`.  `:recorded` is what the harness recorded in that
  time for Claude calls billed per token, which the report counts too,
  and `:outside` the rest.  The answer also updates what budgets over
  everything count, at once.  It needs an Admin API key
  (`harness-anthropic-admin-api-key`, ANTHROPIC_ADMIN_KEY, or
  auth-source host api.anthropic.com user admin); without one nothing
  is fetched and it gives `(:available nil :reason)`.  Pro and Max
  subscriptions have no cost report.
- Hard budgets block via `agent/before-turn`; soft ones emit
  `usage/budget-warning` and a session hint at 80% and 100%.  Budgets
  count billed cost, so calls a subscription covers spend none; what
  providers report and a baseline count toward both.
- The Budget setting (`harness-budget`, `(:amount F :hard BOOL)`) is
  one implicit budget, id "settings", for all sessions together: it
  counts every recorded call and applies to every session, after the
  explicit ones in `usage/session-budgets` and `usage/project-budgets`
  (so the task board's header shows it too).  `usage/budget-status
  "settings"` gives its status while it is set; `usage/budgets` lists
  only the explicit ones.  Sessions no longer copy it into their own
  `:budget`; the session module drops the copies saved before, once
  (marker `session-budget-copies-dropped.json`).
- Pricing: `usage/price MODEL-ID USAGE` → cost using the model's pricing.
- Output rate: how fast each session's model writes, measured here in
  the harness process, never in the UI.
  - Tokens: the accounting's own counts, never a second count of the
    stream. Each `session/usage` record supplies them, and on a hosted
    loop so does each model call's `agent/call-usage` (see provider
    `call-usage`). A hosted loop's record of the turn's total is not
    measured again once its calls were.
  - Seconds: the streaming time, meaning the time the agent's activity
    (`agent/activity-changed`) is in `thinking`, `writing` or
    `tool-input`. The wait for the first token, the tools' runs and
    compaction do not count.
  - Calls: a call with no output, or with less than 0.25 s of streaming
    (output that arrived all at once), is left out.
  - The rate: Σoutput / Σseconds over the session's newest calls on its
    current model, counting back until they cover
    `harness-usage-rate-window` seconds of streaming (30). It is kept in
    memory after the turn, so an idle session keeps its last rate, and
    is dropped when the session is deleted.
  - Interface: `usage/rate SID` returns `(:rate F :output N :seconds F
    :calls N :at FLOAT :model ID)` or nil. `usage/rates` returns every
    measured session's rate, each with `:session`. Each new rate
    triggers `usage/rate-updated SID RATE`, which ACP forwards.

### fallback

When a provider runs out of quota or money, its sessions carry on with
another.  `harness-fallback-models` (global, *Models and services*) is
the order of preference, first used to last: each entry a provider id,
standing for that provider's model of similar ability (the tier of the
session's model, see `provider/model-tier`), or a model id used as it
is.  nil turns the switching off; running out is still noticed, shown
and hinted.

- Marks: a provider that ran out is marked, the whole provider (key
  `"deepseek"`) or one model (key `"claude:claude-fable-5-1"`, when only
  a window scoped to a model is used up).  MARK = `(:key :provider
  :model :kind quota|billing :reason TEXT :since F :until F :source
  error|quota)`.  `:until` is when the limit resets, when known, else
  an hour on (`harness-fallback--retry-after`); a mark ends then, or
  when the user clears it, and a timer announces it.  Marks persist in
  fallback.json.
- What counts: a failed step whose FAILURE (see `agent/step-error`)
  has `:error-kind` `quota` or `billing`, or, without a kind, whose
  error text reads as running out of quota or money (HTTP 402,
  "insufficient balance", "usage limit", "hit your limit",
  `insufficient_quota`...; `harness-fallback-error-kind`).  A
  rate limit, an outage or a refused login never does.  Also
  `provider/quota-updated`: a plan window used up (used >= 1, resetting
  later), unless the plan's extra usage pays for calls, marks the
  provider until it resets (a window scoped to a model, that model);
  such marks follow the quota and go when it says calls work again.
- Choosing: a session's own model comes first; a session moved by the
  fallback remembers its own (`:original`).  When it is out, the first
  entry of `harness-fallback-models` whose model is neither marked nor
  that of an unregistered provider wins.  `harness-fallback-choose
  SESSION` returns `(:model ID :entry ENTRY :reason …)`, or nil.
- Switching: `agent/before-turn` (priority 10, before compaction)
  moves a session whose model is out to the chosen one, and back to its
  own once that works again; `agent/step-error` marks what ran out,
  moves the session and retries the step, so a turn, and a task, carry
  on.  The model changes through `session/update` (`:silent`) with a
  hint of its own ("Claude Code is out of quota until 19:00: carrying
  on with DeepSeek-V4-Pro"), and `fallback/switched SID FROM TO WHY`
  (WHY `out` or `back`).  A model changed by anyone else forgets the
  session's own; a fork takes over its parent's.  With nothing left the
  turn ends with its error and a hint naming every provider that is
  out and when it resets.
- Notifications (`notification/send`, source "fallback"): low urgency
  when a provider runs out and sessions move on, normal when nothing is
  left.
- `fallback/status` → `(:models (ENTRY …) :marks (MARK …) :moved
  ((:session SID :original MODEL :model MODEL) …) :enabled BOOL)`,
  ENTRY = `(:entry STRING :provider ID :model MODEL-OR-NIL :label
  :provider-label :registered BOOL :mark MARK-OR-NIL :tiers
  ((:tier "cheap" :model ID :label …) …))`, `:tiers` for a provider
  entry only.  `fallback/clear KEY` forgets the mark KEY (a provider's
  forgets its models' marks too); → non-nil when one went.
  `fallback/mark KEY &rest (:kind :until :reason)` marks by hand.
  Event `fallback/changed` after any mark or session record changes.

### compaction

- `compaction/compact SESSION-ID &optional OPTS` → promise; summarises
  the transcript with the session's model (OPTS `:model` another),
  appends a `compaction` node whose `:meta` points at the compacted
  head, records the summariser (`:model`), what it was given
  (`:context`) and the size compacted, sets it as head, hints
  before/after.  `session/messages` starts at the node, as a user
  message ("Summary of the conversation so far: ..."), followed by the
  unanswered user messages carried over after it.  OPTS `:context` is
  `full` (the default) or `sample`, which keeps only the first and last
  few messages (`harness-compaction--sample-head`/`-tail`) with a user
  message saying how many were left out: a bound on what a summariser
  sent the conversation as text costs.  A summariser whose provider
  keeps the conversation and can fork it (a hosted loop) works on a
  fork of the session's provider state, so it summarises the real
  conversation and leaves the session's own alone; one whose provider
  is sent the transcript anyway (an API provider) gets it as messages.
  A summariser that keeps the conversation and has no state of this
  session (the target of a switch) is sent only the newest user
  messages, so the context goes inside one message as structured text.
- Auto: `agent/before-turn` compacts when the context comes within
  `harness-compaction--context-reserve` of the window unless the provider
  reports `:compaction hosted`.  The window is the session's
  (`:context-window' override, else its model's, capped by its
  `:context-window-limit'), so a session capped below its model's
  window compacts at the cap, which is how task sessions compact
  earlier (`harness-tasks-context-limit', 256k tokens by default).
  It judges the session as it is then, read again: the fallback,
  earlier in the chain, may have moved it to another model.

### handoff

Switching a session to a hosted loop (Claude Code, Copilot) of another
provider starts a new conversation there, which is sent only the user
messages after the model's last reply: without a handoff the new model
knows nothing of the task.  An API provider is sent the whole transcript
and a provider that still holds the session's conversation resumes it,
so switching to either loses nothing.

- `handoff/check SESSION-ID MODEL` → `(:id :name :from :from-label :to
  :to-label :to-provider :lossy :history :running :reason :risks
  :cache-cost)`.  Lossy when MODEL's provider differs from the
  session's, runs a hosted loop, cannot continue the session's state
  (`session/provider-state`), and the session has history it would
  miss (anything a model or tool wrote since the last compaction) with
  no handoff already waiting for it.  `:reason` says why or why not.
  For a lossy switch `:risks` are `harness-handoff-risks`: a cold prompt
  cache (cache writes where carrying on would read), reduced fidelity
  (the model explores again; tool calls and thinking reach it as text),
  provider state left behind (resume, the provider's own compaction,
  its built-in tools), and that it takes effect at the next step, not
  mid-step; `:cache-cost` prices the session's context at MODEL's
  cache-write and cache-read list prices.
- `handoff/check-all MODEL &optional FILTER` → the checks of the
  sessions `session/set-all` would change.
- `handoff/switch SESSION-ID MODEL &optional MODE` → promise of `(:id
  :model :from :lossy :mode :summarizer :context :deferred :file :node
  :fallback :error)`.
  The model changes at once (`session/update`); a lossy switch then
  hands over as MODE says, any other is a plain switch.  `compact`
  summarises on the old model (`compaction/compact` with `:model`, the
  warm cache) and `compact-new` has the *new* model summarise instead,
  from a bounded context (`:context sample`: the first and last few
  messages): use it when the old provider cannot answer -- its plan ran
  out, it is down -- or to keep the job small.  The compaction node,
  marked `:handoff` with the mode, summariser and context, opens the new
  conversation, ending in a harness note that the handoff is lossy and
  the model should re-investigate rather than trust it.  When no summary
  can be made (the summariser fails or its plan ran out) the transcript
  goes over instead (`:fallback` says why).  `transcript` writes
  `session/transcript-text` to `CWD/.harness/handoff/ID-TIME.md` -- in
  the session's directory, which its tools may read and the new
  provider's prompt cache holds as it reads, unlike the state directory,
  and kept out of git by a `.gitignore` of `*` there -- and appends a
  user message from the harness (`:source "model handoff"`, `:meta
  :handoff`) telling the new model to read it before it answers, with
  the same lossy warning.  `none` only switches.
- `handoff/switch-all MODEL &optional FILTER MODE` → the ids switched;
  MODE applies to the lossy ones.
- A handoff must land in the trailing user messages.  An idle
  session's starts at once and a turn started meanwhile waits for it;
  a running session's waits for the turn's next step: the
  `agent/before-turn` and `agent/step` gates (priority 10, before
  automatic compaction) run it and hold the step until it is done, and
  a turn that ends first has it run right after.  A handoff waiting for
  a provider the session has left again is dropped.  Event
  `handoff/done SESSION-ID RESULT`.

### naming

- `naming/name SESSION-ID &optional OPTS` → promise of name.  A session
  with no name is named as soon as its first message is sent: on
  `agent/turn-started`, not when the turn ends, since a task's first
  turn lasts until the task is done.  That request (OPTS `(:opening t)`)
  runs beside the turn and holds only the opening message (and the
  latest one when the conversation has moved on since, as a fork's has),
  each cut to 3000 characters, and the question.  It goes to
  `harness-naming-model` (`auto`, the default: the session provider's
  `:cheap` tier, `provider/tier-model`) with `:ephemeral t`,
  `:no-thinking t`, a 40-token budget and no provider state, so the
  hosted providers answer it apart from the session's conversation (a
  CLI process of its own for Claude Code, a throwaway session for
  Copilot) and the question never lands in it.  A session still nameless
  when a later turn starts (its naming failed) is named then; btw and
  subagent sessions never are.  Without `:opening` the whole
  conversation is titled on the session's model, on a fork of its
  provider state when possible so the cached prefix is reused.  Hints
  "Naming session…" then the result; a session renamed while the model
  was asked keeps its new name.  Events `naming/done SID NAME`,
  `naming/failed SID MESSAGE`.
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
  each merge is a transaction that never leaves the parent's checkout
  mid-merge.  `git merge-tree --write-tree` merges the child's branch
  into the parent's HEAD off to the side; a clean result becomes a merge
  commit (`git commit-tree`, message as `git merge --no-ff` writes it)
  and the checkout moves onto it with `git merge --ff-only`, which git
  refuses, changing nothing, when it would overwrite uncommitted or
  untracked work there or a merge is already in progress (the merge
  fails; a HEAD that moved meanwhile is merged again).  On conflict the
  parent is untouched and the lock passes on at once, and the parent's
  commit is to be `git merge`d into the child's branch, in its own
  worktree.  By default (`harness-merge-conflict-resolver` `fresh`) the
  harness starts a fresh `subagent` session for it -- a child of the
  child session, in its worktree, with its settings and
  `harness-merge-resolver-model` or its model -- prompted (from
  `harness-sender-system "merge queue"`) with only the files, both
  sides' commits and what to do: a child that waited long in the queue
  would pay for its whole history on a cold prompt cache.  Its turn
  ending without `merge_done` fails the merge (event `merge/resolver
  CHILD PARENT RESOLVER`; `merge/queue` items carry `:resolver`).  With
  `child`, the child session itself gets that as a steering message.  A merged child's worktree loses
  the harness's lock (`worktree/unlock`; see worktree).
- `merge/status CHILD-SID`; the `merge_done` tool (called by the child
  or its resolver) checks the child's
  worktree contains the parent's commit, merged and committed, and
  queues the branch again.
- Events `merge/queued CHILD PARENT POSITION`, `merge/started`,
  `merge/conflict CHILD PARENT FILES`, `merge/finished CHILD PARENT STATUS`
  (merged|failed|aborted|cancelled).

### tasks

Task mode: one session per task.  TASK =
`(:id "t-…" :project ROOT :cwd DIR :prompt "…" :attachments (…)
:state pending|refining|active|merging|review|done
:column pending|needs-input|active|review|merging|done
:backlog BOOL :note "the words a backlog task was written up from" :refined F
:session SID :outcome nil|end-turn|error|cancelled|duplicate|merge-failed|merged|…
:error "…" :duplicate-of ID :main-tree BOOL :worktree DIR :branch NAME :base NAME :merge-status nil|queued|merging|conflict
:merge-queued F :conflicts (FILE…) :merged BOOL :archived BOOL :created F :started F :finished F
:verified BOOL :verified-at F :feedback ((:text "..." :at F) ...))`.
`:column` is derived on every read: `needs-input` when the session is
blocked on a request or the task stopped part way, `merging` while its
branch holds a place in the merge queue (`:merge-status` is queued,
merging or conflict; `:merge-queued` is when it joined, which orders the
board's section), `review` while its finished work waits for the user's
verdict.

- `task/submit CWD PROMPT &optional (:attachments :model :permission-mode
  :thinking :non-interactive :refine :main-tree)` → task; it starts when
  one of `harness-tasks-max-running` slots is free.  Missing options come from
  `harness-tasks-model`, `-permission-mode` (auto), `-thinking` and
  `-non-interactive` (off), else from what the directory configures, so
  a task is interactive unless `harness-tasks-non-interactive` or the
  directory's `harness-non-interactive` is on; an explicit false turns
  non-interactive off whatever they say.  `task/settings` reports the
  values a new task would get, the configured ones included, and the
  board submits them with each task.
  With `:refine` the task goes to the backlog instead (below).
  With `:main-tree` it works in the project's main checkout: no worktree
  is made, it gets no branch, and nothing merges when its turn ends, so
  it can touch the checkout itself -- cleaning up uncommitted changes,
  say.  The flag is explicit, never the default; the `task_submit` tool
  offers it as `main_tree` and the board as a worktree switch beside the
  other new-task settings.  A refined (`:refine`) task keeps it for when
  it starts, and its session, made at the task's directory for the
  write-up, then stays there rather than moving into a worktree.
- A task's session also runs on `harness-tasks-context-limit' (256000)
  tokens of context at most, so it compacts earlier than an interactive
  session; nil gives it the whole window.  A refined task's write-up
  session, and a session adopted by `task/adopt', get it too.  A
  provider that compacts on its own side keeps deciding by itself,
  except Claude Code, which is spawned with the limit as
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' (see the claude provider).
- Backlog refinement (once called grooming): a `:refine` task is
  `refining` while a session at its directory -- `ask` and
  non-interactive, `harness-tasks-refine-model` and
  `-refine-thinking` (low), read-only through the tasks module's
  `permission/decide` stage at 25, which denies (final) whatever the
  mode and its rules leave undecided in a turn of a write-up, before
  the auto judge could allow it -- writes it up as told by
  `harness-tasks--refine-prompt` (brief, no changes, no questions, a
  self-contained ticket: title line, what and why, what to change, how to
  tell it is done, related tasks, open questions); after
  `harness-tasks--refine-tool-calls`
  (8) tool calls it is steered once to write up with what it has, which
  keeps it brief.  It is told to search the board first -- one `task_list`
  (`include_archived t`, `limit 50`, the task at hand marked
  `(this task)`) -- and to refuse a request the board already has: an
  exact duplicate is neither written up nor added to the backlog, but
  waits for the user.  The refusal is its final reply, first line
  `Duplicate of ID` (`harness-tasks--refusal`, markdown and a trailing
  full stop aside); `--finish-refinement` then sets `:outcome duplicate`,
  `:duplicate-of` the task named when it is on this harness's board
  (`harness-tasks--duplicate-of`: an id, or a unique id prefix, of the
  task's project, never the task itself) and `:error` the message after
  the first line, shown to the user.  `task/refine ID` with no TEXT
  writes a refused task up all the same, sending
  `harness-tasks--refine-anyway-text`; with TEXT -- or with
  `task/prompt`, like any feedback -- the write-up is done again with
  it.  A write-up also names the related tasks in the same code area in a
  "Related tasks" section -- id, title, branch, session, where each
  stands and what it changes -- and tells whoever does the task to
  coordinate with them rather than redo their work: check where they
  stand, message their sessions, cherry-pick their commits (see also
  `harness-tasks--start-message`).  Otherwise its final reply becomes
  `:prompt` (the original stays in `:note`) and the task waits in
  `pending` with `:backlog t`: the scheduler never starts it, only
  `task/start`, so the backlog survives restarts.  A turn of a backlog
  task's session before it starts is feedback (`task/prompt`) and
  rewrites the write-up; a write-up that stops needs input (restarts:
  below).  `task/refine ID &optional TEXT` refines a queued task or
  writes one up again.  Starting continues the same session: in git it
  moves into the task's new worktree (`session/update :cwd :worktree`),
  its provider conversation is dropped (the Claude CLI keeps
  conversations per directory; the new one gets the transcript, the
  write-up's conversation, as text: see "Replay") and it is prompted with
  `harness-tasks--start-message`, the write-up and the quoted note, under the
  task's own settings.  Dropping a backlog task deletes its session.
  The messages task mode composes itself (starting a written-up task,
  the restart resume, the nudge to finish a write-up) are marked as
  from `harness-sender-system "tasks"`; the task's prompt, a
  `task/prompt` follow-up and `task/reject` feedback are the user's.
- `task/adoptable &optional CWD` lists the project's open sessions that
  are not tasks; `task/adopt SESSION-ID` makes one a task (its first
  message is the prompt; a worktree session keeps its worktree and merges
  like any task; an idle one waits in `needs-input` with `:outcome adopted`).
- Starting: in a git project (`harness-tasks-worktrees`) `worktree/create`
  on branch `harness-tasks-branch-prefix` + slug + id, then a session in
  that worktree (`harness-tasks-permission-mode`, interactive by
  default) prompted with the task; a system-prompt section tells it to
  commit on its branch and not merge.  Outside git the session runs in CWD.
  A `:main-tree` task skips the worktree: its session runs at the
  project's main root, and the system prompt says the work takes effect
  there, with no branch to make and nothing to merge.  The worktree
  stays locked until its branch is merged; a follow-up to a merged task
  locks it again (see worktree).
- The session's name is the task's title: `naming/system-prompt` adds
  `harness-tasks--naming-instructions` (nil for none) so the model titles task
  sessions like tickets, as soon as the task's first turn starts (see
  naming), so the board shows the ticket title while the task works.
- With nothing to review (below), a turn ending `end-turn` queues
  `merge/enqueue SID TARGET`, TARGET being the project's root session
  named `harness-tasks--merge-session-name`
  (created on demand); `merge/finished … merged` makes the task `done`.
  While its branch holds a place in the queue the task is in the
  `merging` column (`:merge-queued` says when it joined).
  Failures the agent can fix (uncommitted work) are steered by the merge
  queue; others, or more than `harness-tasks--merge-attempts`, set
  `:outcome merge-failed`.  Outside git, and in the main tree
  (`:main-tree`), `end-turn` makes it `done`.
- Review (`harness-tasks-require-verification`, default t): finished
  work is not done until the user has looked at it.  A turn ending
  `end-turn` puts the task in `review` instead, and emits `task/review
  TASK`; in git, when it works on a branch, that branch waits unmerged,
  so nothing reaches the base branch unreviewed.  `task/verify ID` accepts the work (`:verified t
  :verified-at F`): its branch goes through the merge queue as above
  and the task is `done` once merged, waiting in `merging` between the
  two (outside git, or when the branch merged already, at once).
  `task/reject ID FEEDBACK &optional
  ATTACHMENTS` sends it back: the feedback (words, attachments or both)
  goes to the same session, in its own worktree and with its provider
  conversation, as a prompt opened by `harness-tasks--reject-message`;
  the task is `active` again and returns to `review` when that turn
  ends.  Each round is appended to `:feedback`.  Any other message that
  reaches the session while its task waits for review sends it back the
  same way, with the message as the feedback: typed in its chat,
  `task/prompt` (`task_control` message), another ACP client, another
  session's agent (`session_send`), its queue going out once the turn
  ended.  The tasks module's `agent/message` filter
  (`harness-tasks--on-message`) makes the task active at once, keeps
  the round and opens the message with the reject text; only the
  harness's own messages (`:from` system) do not count.  Any other new
  turn of work (a follow-up, a message from the chat) clears the
  verification, so it is reviewed again; the merge
  queue's own steering (commit first) does not.  Only clean ends go to
  review: a turn that stops needs input as before, and `task/complete`
  (Mark done) counts as accepting the work.  A merge that finishes for
  work nobody verified (one queued before the option was turned on)
  puts the task in review, merged.  `task/archive` works in review too;
  `task/archive-done` leaves those tasks alone.  With the option nil a
  task is done once merged, or outside git once its turn ends.
  `task/settings` reports the option as `:require-verification` (t, or
  false rather than nil), and a board's Review switch turns it off and
  on with `config/set`, globally and saved; tasks already in review wait
  on until verified.
- A turn starting in a task's session makes the task active again, so a
  message sent from a done task's chat buffer reopens it; an archived task
  comes back to the board.
- `task/list &optional CWD`, `task/get ID`, `task/settings &optional CWD`,
  `task/start ID` (ignores the limit; not while a write-up runs),
  `task/update ID PROMPT` (not started only; writes a stopped write-up by
  hand), `task/set-all SETTINGS &optional FILTER` (apply `:model',
  `:thinking', `:permission-mode' and `:non-interactive' to every task
  FILTER selects and, when started, its session; FILTER is `:columns'
  (default `harness-tasks-bulk-columns': running, pending and blocked),
  `:ids', `:except' and `:cwd', and review, done and archived tasks are
  never touched; this is the board's bulk edit), `task/prompt ID TEXT &optional ATTACHMENTS` (follow-up or
  steering; reopens; in review it sends the task back, as above), `task/refine ID &optional TEXT`,
  `task/merge ID` (retry; not in review), `task/retry ID` (have a task
  that stopped carry on where it stopped: a failed merge is queued
  again, a stopped write-up is written again, a pending task starts, a
  stopped turn is prompted with `harness-tasks--retry-prompt` from
  `harness-sender-system "tasks"`, and a task whose work never began is
  started over; it refuses a task that is working, blocked on a
  question, in review or done), `task/verify ID`,
  `task/reject ID FEEDBACK &optional ATTACHMENTS` (both in review only),
  `task/complete ID` (counts as verified), `task/archive ID &optional
  RESTORE` (deactivates the session; removes a merged task's worktree and
  branch), `task/archive-done &optional CWD`, `task/cancel ID` (drops a
  task that has not started, stops a running turn or write-up),
  `task/delete ID &optional DELETE-SESSION` (keeps the worktree),
  `task/for-session SESSION-ID` (the task of a session, or nil, which
  `hand_in` and the session's review banner use; the banner at the end
  of a report popout has the task already) and
  `task/hand-in ID REPORT` (record `:summary` and `:evidence` as the
  work ID handed in; the write-up tool's `:end-turn` ends its turn, which
  the review step then picks up).  A round of work whose turn ends
  without a hand-in -- the model replied instead, or had no tools to
  call -- gets a `:report` marked `:missing t` instead
  (`harness-tasks--missing-report`): no evidence, and as `:summary` the
  session's last message of the round.  A round starts at `:started`,
  at each round of `:feedback`, and at `:reopened` (new work on a task
  in review or done); a report handed in before the round started
  speaks for earlier work, so a round that ends without a hand-in of
  its own replaces it.  The board's button for such a report reads
  [No report], its popout says "Not handed in", and the session's
  review banner says so in a line.
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

### tasks-search

The task board's search: a query in words ("did I have a task about the
question button?", "restart the errored tasks") finds tasks and may act
on them, answered by a cheap model that returns JSON only.

- `task/search CWD QUERY &optional (:shown IDS)` → promise of
  `(:query QUERY :ids IDS :actions ACTIONS :model MODEL :looked LOOKED)`.
  Nothing changes yet.  IDS are the tasks QUERY is about, best match
  first, archived ones included; ACTIONS are what QUERY orders, each
  `(:task ID :action NAME :text TEXT :title TITLE :confirm BOOL)`, NAME
  one of `harness-tasks-search-actions` (`archive`, `restore`, `stop`,
  `retry`, `start`, `verify`, `complete`, `message`, `reject`), TEXT the
  words a message or a send-back carries, and `:confirm` t for an action
  that interrupts work, merges it or sends words to an agent (stop,
  verify, complete, message, reject, and archive of a working task),
  false for the rest.  `:shown` is what the board shows now, which
  "them" in QUERY means.  `:looked` says what the model read besides the
  board.
- The message to the model carries a compact dump of the board: for
  every task (newest first, at most `harness-tasks-search--max-tasks`)
  its id, column and state, title, the request it was asked in, the todo
  it is on, what it waits for the user on, the summary it handed in, its
  branch, times and errors.  The system prompt
  (`harness-tasks-search--system`) is constant, and the model must
  answer one line of JSON `{"show":[ID…],"do":[{"task":ID,"action":…}]}`.
  Unknown ids are dropped and acted-on tasks are always shown.  When the
  model asks to look further instead of answering -- `{"grep":TEXT}` over
  the sessions' transcript logs (`sessions/*.nodes.jsonl` under the state
  directory, searched in a subprocess) or `{"read":[ID…]}` for the latest
  transcript, at most `harness-tasks-search--read-limit` tasks -- it gets
  one more round (`harness-tasks-search--final-text` closes it) and must
  answer then.
- The model is `harness-tasks-search-model`: `auto` (the default) takes
  the provider of the task model's `cheap` tier (`provider/tier-model`),
  nil uses the task model itself, a string forces one.
  `harness-tasks-search-thinking` (nil) is its thinking level, the
  output budget is `harness-tasks-search--max-tokens`, and a call taking
  longer than `harness-tasks-search--timeout` fails.
  `harness-tasks-search--request` runs it as a side session in
  `task-search/` under the state directory, so the project's Claude
  history and CLAUDE.md stay out of it.  Every search gets its own
  session id, and its process is closed when it ends
  (`provider/close`).
- `task/search-warm CWD` → `(:model MODEL :warm BOOL)`: start the model
  process the next search of CWD's board will use (`provider/warm`), so
  the answer comes sooner; a process left unused is closed after
  `harness-tasks-search--warm-idle` seconds.
- `task/search-apply ACTIONS` → promise of one result per action,
  `(:task :action :title :ok :error :undo)`, run in order: archive stops
  a working task first and archives it once it stopped
  (`harness-tasks-search--stop-wait`), stop never drops a task that has
  not started, retry is `task/retry`, message is a follow-up to the
  task's session (or words added to the prompt of a task with no session
  yet), and the rest are the tasks methods.  ARCHIVE and RESTORE carry
  `:undo`, the action that undoes them.
- Searches are not sessions: their cost is recorded with `usage/record`
  under the board's project with `:session nil`.
- Settings `harness-tasks-search-model`, `harness-tasks-search-thinking`;
  the demo provider answers search requests heuristically (word match
  plus action verbs), so the dev daemon, the tests and the screenshots
  work offline.

### pet

A companion pet, after the ones Claude Code hatched for April Fools'
Day 2026 (`/buddy`): an egg hatches into a creature with random bones,
a cheap model names it and gives it a personality, and later, now and
then, lends it a line about the user's work.  One pet per harness.

- Bones are rolled, never stored: Mulberry32 seeded with the 32-bit
  FNV-1a of the seed and `harness-pet--salt` draws, in order, the rarity
  (`harness-pet-rarities`: common 60, uncommon 25, rare 10, epic 4,
  legendary 1 in 100, with 1 to 5 stars), the species (18 in
  `harness-pet-species`), the eyes, a hat (none for a common one), shiny
  (1 in 100), then the stats DEBUGGING, PATIENCE, CHAOS, WISDOM and
  SNARK (`harness-pet-stats`): from the rarity's floor, one peak stat
  (floor+50 to floor+79, at most 100), one dump stat (floor−10 to
  floor+4, at least 1), the rest floor to floor+39.  A last draw seeds
  the inspiration words the model names it after.  `harness-pet-roll
  SEED` → `(:rarity :species :eye :hat :shiny :stats :inspiration)`.
- The record, `pet.json` under the state directory: `(:seed :name
  :personality :hatched :xp :pets :muted :said)`, SAID its last
  `harness-pet--memory` sayings.  A change it makes while growing is
  saved `harness-pet--save-delay` seconds later (`harness-pet-flush` at
  shutdown and on `kill-emacs-hook`); other changes at once.
- `pet/get` → the VIEW: `(:hatched :hatching :reactions :watching
  :model)`, and once hatched also `:seed :name :personality :hatched-at
  :rarity :stars :species :eye :hat :shiny :stats :level :xp :level-xp
  :next-xp :pets :muted :thinking :said`.  Booleans are t or `:false`;
  `:thinking` is t while it waits for a line; LEVEL is
  `max(1, floor((1 + sqrt(1 + 0.8·xp)) / 2))`, a level L starting at
  `5L(L−1)` xp.
- `pet/hatch` → promise of the VIEW once it hatched (the one hatching is
  shared; one that hatched already is returned).  A new seed is rolled
  and the model asked for `{"name":…,"personality":…}`
  (`harness-pet--hatch-system`); with no model, a failed or late call,
  or an answer without them, it hatches all the same with a name from
  `harness-pet--fallback-names` and a plain personality.  Its first
  words follow, as for a petting.
- `pet/pet` (counts, +1 xp at most once a minute, and it answers),
  `pet/rename NAME` (one line, at most `harness-pet--max-name`
  characters), `pet/set-muted BOOL`, `pet/release` (forgets it; the next
  egg brings a new seed) → the VIEW.  `pet/watch CLIENT ON` → the VIEW:
  CLIENT, an id the UI makes up, shows the pet now or not.
- It speaks only while some client watches it, it is not muted and
  `harness-pet-reactions` is on; never two lines within
  `harness-pet--min-gap` seconds, never two at once.  Asked -- a message
  of the user's that names it, a petting, hatching, a level gained --
  it answers every time.  Unasked, at most once every
  `harness-pet-cooldown` seconds (60): on a message the user writes, by
  chance (`harness-pet-chance`, 0.3), and at the end of a turn of the
  user's that failed tests (a command's output, `test-fail`), failed
  otherwise (`error`) or changed more than `harness-pet--large-diff`
  lines (`large-diff`), see `harness-pet-turn-reason`.  It reads the
  session's name, its project and the last nodes of the transcript (at
  most about 3000 characters).  The line is one line, without a leading
  "NAME:" or quotes, at most `harness-pet--max-saying` characters
  (`harness-pet-sanitise`); "..." is silence.
- Every call is `provider/complete` with `:ephemeral t` and `:no-thinking
  t`, a session id of its own (closed with `provider/close` when it
  ends) and `pet/` under the state directory as its directory, so no
  project instructions, memory or history reach it; a call taking
  longer than `harness-pet--timeout` is cancelled.  Its cost is recorded
  with `usage/record` with `:session nil`, under the project of the
  session it spoke about.
- Model: `harness-pet-model`, `auto` (the default) the cheap tier
  (`provider/tier-model`) of the session's model, or of `harness-model`
  for a hatching or a petting; nil that model itself; a string forces
  one.
- Growing: +2 xp for every message the user writes, +1 for every turn
  of theirs that ends well.  Event `pet/changed VIEW` after any change
  (growing only while watched or when it gains a level), `pet/said
  SAYING` with `(:text :ts :reason :session :session-name)`.  Both are
  forwarded to clients; the methods are `_harness/pet/...` over ACP.
- The demo provider names pets and speaks their lines from a script,
  so the dev daemon and the tests run offline.

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

### tools-fs, tools-shell, tools-emacs, tools-web, tools-agent, tools-sessions, tools-notify, tools-handin

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
| `elisp` | Emacs Lisp | code, timeout | exec |
| `emacs_buffers` | List buffers | filter, all | read (needs no approval: `harness-perms--inspection-tools`) |
| `emacs_windows` | List windows | — | read (needs no approval: `harness-perms--inspection-tools`) |
| `emacs_buffer` | Read buffer | name, offset, limit | read (needs no approval: `harness-perms--inspection-tools`) |
| `emacs_open` | Open buffer | name (buffer or path), line | read |
| `emacs_insert` | Insert text | name, text, position (point/start/end) | write |
| `emacs_save_buffer` | Save buffer | name | write |
| `emacs_describe` | Describe symbol | symbol, buffer | read (needs no approval: `harness-perms--inspection-tools`) |
| `emacs_find_definition` | Find definition | symbol, type (function/variable/face) | read (needs no approval: `harness-perms--inspection-tools`) |
| `emacs_trace` | Trace symbol | action (start/stop/list), symbol, type (function/variable), callers, limit | write |
| `web_search` | Web search | query, count | net |
| `web_fetch` | Fetch page | url, max_chars | net |
| `emacs_messages` | Emacs messages | count | read (needs no approval: `harness-perms--inspection-tools`) |
| `ask_user` | Question | question, options (strings, or `{label, diagram}` / `{label, image}` objects: every option has a diagram or none does), allow_free_text | meta (answered with `question/answer SID PID ANSWER`; event `question/asked`) |
| `request_directory_access` | Request access | path, reason | meta (perms module; decided only by the user's answer to a directory prompt, in every mode) |
| `session_info` | Session info | — | read (needs no approval: `harness-perms--inspection-tools`) |
| `plan` | Plan | plan | meta |
| `todo_write` | Todo list | todos | meta |
| `spawn_agent` | Sub-agent | prompt, fork, model, name, cwd, worktree | meta (the jail checks `cwd`, as it checks bash's) |
| `skill_search` / `skill_load` | Search skills / Load skill | query / name | read |
| `session_list` | List sessions | status, kind, parent_id, name, include_inactive, all_projects, limit | read (needs no approval: `harness-perms--inspection-tools`) |
| `session_search` | Search sessions | query, regexp, all_projects, max_sessions, max_matches | read (needs no approval: `harness-perms--inspection-tools`) |
| `session_read` | Read session | session_id, limit, before, kinds, max_chars | read (needs no approval: `harness-perms--inspection-tools`) |
| `session_send` | Message session | session_id, message, mode (send/queue), wait | meta |
| `session_control` | Control session | session_id, action (cancel/resume/close/rename/answer), name, question_id, answer | meta |
| `session_wait` | Wait for sessions | session_id / session_ids, until (stopped/idle/blocked/running/changed), mode (all/any), timeout_seconds | read (needs no approval: `harness-perms--inspection-tools`) |
| `task_list` | List tasks | column (pending/needs-input/active/review/merging/done), include_archived, all_projects, limit (the most recent) | read (needs no approval: `harness-perms--inspection-tools`) |
| `task_submit` | Submit task | prompt, cwd, model, thinking, refine (for the backlog), main_tree (no worktree: the project's main checkout) | meta |
| `task_control` | Control task | task_id, action (start/message/cancel/merge/verify/reject/complete/archive/restore/delete), message (the feedback, for reject) | meta |
| `task_wait` | Wait for tasks | task_id / task_ids, until (settled/done/needs-input/active/review/merging/changed; settled counts review), mode, timeout_seconds | read (needs no approval: `harness-perms--inspection-tools`) |
| `hand_in` | Hand in the finished work | summary, evidence (image/video/file/code/note/tool_call, each with a caption) | meta (task sessions only; needs no approval: `harness-perms--auto-allow-tools`) |
| `open_harness` | Open harness in Emacs | path (default: the session's worktree, else its cwd), focus | exec (tools-dev; offered in a checkout of the harness only; needs no approval: `harness-perms--auto-allow-tools`) |
| `notify` | Notification | message, title, urgency (low/normal/critical), providers, url | meta (needs no approval: `harness-perms--auto-allow-tools`) |
| `notification_providers` | Notification providers | (none) | read (needs no approval: `harness-perms--inspection-tools`) |
| `merge_done` | Finish merge | none | meta (merge module) |

The tools of kind read that take a path (`read_file`, `list_dir`,
`glob`, `grep`, `file_info`, `emacs_open`) may read the harness itself
as well as the session's roots: its code and its state directory, its
credentials aside (see perms).

`hand_in` (tools-handin) is how a task's session finishes: the tool
records the summary and evidence on the task (`task/hand-in'`) and asks
the turn to end via the result's `:end-turn' -- `harness-agent--finish-turn'
cancels the provider and ends the turn with `end-turn', as if the model
had stopped itself -- so the review step puts the task in front of the
user.  The filter `agent/tools' drops it where `task/for-session' finds
no task.  Evidence is required: an image or a video (a path inside the
session's roots), a file, code, a note, or `tool_call' naming an
earlier call of the session, which is copied into the report as a
snapshot so the view can show it as the link it is.

`open_harness` (`tools-dev`) opens a second Emacs running the harness
from a checkout of this project -- a task's worktree, say -- so harness
changes can be tried live instead of only read.  It runs that
checkout's own live development loop (`scripts/dev.sh start`) with
`HARNESS_DEV_SOCKET=harness-dev-HASH`, a socket derived from the
checkout's true name, so the same worktree reuses its instance and two
worktrees never share one; the instance's state and compiled files stay
in that checkout's `scripts/.dev/state-SOCKET`.  The result lists the
`scripts/dev.sh` commands that drive it (shot, keys, eval, errors,
reload, stop) prefixed with that socket.  `path` defaults to the
session's worktree, else its cwd; a directory that is not a checkout
(`harness.el` and `scripts/dev.sh` side by side) is refused.  The sync
filter `agent/tools` drops the tool outside such checkouts: it is for
this project only.  The bus method `harness-dev/open PATH &optional
FOCUS` does the same for the UI (focus raises the frame); the task
board's [Open harness] button on a review card calls it, and the tool
is in `harness-perms--auto-allow-tools', so the agent needs no approval
to use it.

Fast paths run in Emacs (`insert-file-contents`, `directory-files-recursively`,
`replace`); anything that can take long (grep, bash) runs as an
asynchronous process started with `start-file-process` so TRAMP works.

`read_file` returns an image or a video as an `:attachments` entry the
chat shows the user: the picture of an image (an SVG is read as text
from its top and also shown), and a video as a poster, its thumbnail
under a play button, which plays it.  A video is something the model
cannot see: it is told what the file is and to inspect it with
`ffmpeg`.  Text behind a video's extension (TypeScript's `.ts`) is
still read as text.

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
Corporate mode leaves both searches on and turns `web_fetch` off (see
tools).

The session and task tools (`tools-sessions`) let an agent coordinate the
rest of the harness.  Sessions are named by id, a unique id prefix or a
unique name; a session cannot message, control or wait on itself.
Listing and search default to the current project (worktrees included).
`session_search` greps the `sessions/*.nodes.jsonl` logs in a subprocess,
so transcripts are not loaded into memory to be searched.  `session_send`
prefixes the message with `[Message from session ID "NAME"]` and goes
through `agent/prompt` (a turn, steering, or the queue) with
`:from` naming the calling session, so that session's chat shows the
message as coming from here rather than from the user; `session_read`
and `session_search` tag such nodes the same way.  Waits are
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

Every tool runs in the harness; none runs in a client.  The `emacs_*`
tools are about the user's Emacs, which they reach as a resource: their
handlers check the input, ask the Emacs a client lent to the harness
for plain data with `harness-tools-ask-emacs METHOD PARAMS` (→ promise;
`emacs/request` under a deadline, `harness-tools--emacs-timeout'), and
word the result here.  The lent Emacs answers from
lisp/harness-emacs-endpoint.el, which knows no tool: `buffers` (every
buffer's name, mode, modified flag, size and file), `windows` (the
window tree, frame by frame), `buffer` (a range of lines, stopping at
the characters the tool names, so a long buffer comes in ranges),
`describe` (a symbol as function, variable and face, as
`describe-function` and `describe-variable` would: its value printed in
part, in a buffer the tool names or the user's, where it is
buffer-local, its standard value, watchers, advice, keys, aliases and
file), `definition` (where a function, variable or face is defined and
the text of its definition, found as `find-function` finds it but read
into a temporary buffer, never visited and never macroexpanded, so none
of its code runs; a buffer visiting the file is read as it stands) and
`messages`; and it does the few bounded actions the same tools need:
`open` (show a live buffer, or visit an existing local regular file
under the size the tool names -- never a directory, a remote path or a
prompt), `insert` (text into a live editable buffer, left unsaved),
`save` (a buffer to its local file, every question the save could ask
turned into an error) and `trace` (record the calls of a function, an
:around advice under trace.el's name so `untrace-all` removes it too,
or the changes of a variable, a watcher, into `*trace-output*`: bounded
printing, optional callers from the backtrace, `inhibit-trace` around
the recording, and a limit of records after which the trace removes
itself).  With no Emacs lent -- a
headless harness, or only clients such as a phone -- the call fails at
once, saying so and pointing at read_file and the elisp tool; one that
does not answer in time fails the call, logs, and shows a desktop
notice, rather than leaving the turn pending.  `write_file`/`edit_file`
emit `tools/file-written PATH`; the UI reverts unmodified buffers
visiting PATH.

The `elisp` tool runs in the harness too, and always evaluates in a
child `emacs --batch' process: Emacs runs Lisp on one thread, so
model-written code that blocks (a `call-process' waiting on a child, a
loop that never yields) would freeze the user's typing and redisplay,
and neither a timer nor a signal can end it.  The child gets the
harness on its `load-path', the working directory as its
`default-directory', a timeout, and the process tree killed when it
overruns (lisp/harness-elisp.el); its result comes back as JSON, in the
shape `harness-elisp-payload` describes (value, output, messages or
error).  It never runs in the lent Emacs, and no request of
lisp/harness-emacs-endpoint.el evaluates code: model-written Lisp does
not run in the user's Emacs at all, whatever anyone configures.  A call
that asks for the user's Emacs (the old `emacs` input) is refused with
that explanation; the `emacs_*` tools are the whole of what a model may
do to the live Emacs.

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
(harness-acp-close CONN &optional REASON)   ; rejects what waits with REASON ("closed")
(harness-acp-closed-reason ERR)             ; that REASON, when a close is what rejected ERR
(harness-acp-connection-p CONN) (harness-acp-connected-p CONN)
(harness-acp-open-p CONN)                   ; connected, or TCP still connecting
```

What is sent while a TCP connection connects waits and goes out once
the socket is up, so a client keeps a connection while `harness-acp-open-p`
holds rather than connecting again, which would drop it along with
every request it carries.

RESPOND returns non-nil when the answer went out and nil when it could
not: its connection closed since the request came, or it was answered
already.  A request answered later than it came, such as a permission
prompt waiting for the user, belongs to the connection it came on; the
harness keeps it pending on the session when that connection goes, and
never sends it again on another.  An answer that cannot go out where
the request came goes through the bus method that answers it
(`permission/answer`, `question/answer`).

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
options:[{optionId,name,kind}], _harness:{pendingId, tool, paths, cwd, dir,
pattern, reason}}` (`cwd`: where a shell command runs; `paths`: what
the call is about, see perms) → `{outcome:{outcome:"selected",optionId}}`, plus
`_harness:{pattern}` when the client answers a request about a path
outside the allowed directories for another glob pattern than its
`_harness.pattern` (only such a request has one, see perms),
and `_harness/ask_user {sessionId, requestId, question, options, diagrams}` → `{answer}`.
Its `options` are the answers' labels; `diagrams`, present when the
options have them, holds one per option, `{type: "ascii", text}` or
`{type: "image", path, mime}`: a path on the harness's machine, never
the image data, since the pending question is saved with the session.

Extension methods: any bus method whose name starts with `session/`,
`agent/`, `provider/`, `tools/list`, `usage/`, `fallback/`, `worktree/`, `merge/`,
`config/`, `skills/`, `permission/`, `question/`, `compaction/`, `handoff/`, `naming/`, `task/`,
`notification/`, `sandbox/status`, `harness-dev/`, `harness/api`, `harness/version`, `harness/reload`, `acp/remote-` is callable as `_harness/NAME` with a
params object whose keys become the plist arguments (`{"id": …}` →
`:id`).  Methods take a single plist argument on the wire; the ACP
layer maps positional bus signatures through a small table.

Harness → UI requests for chores any client may do go through the bus
method `client/request METHOD PARAMS` → promise of the first client's
answer; it rejects at once when no client is connected or all decline
(never callable over ACP).  Methods: `_harness/client/customize-save
{symbol, value}` (value printed; only `harness-` options),
`_harness/client/notify {id, title, body, urgency, source, kind,
session, task, project, url}` -> `{backend}` once a desktop
notification shows (see notifications), or an error.  No tool uses it.

A client lends its Emacs to the harness by adding `_harness: {emacs:
{version, pid, host}}` to the `clientCapabilities` of `initialize`
(`harness-emacs-endpoint-client-capabilities`; the UI does, again after
a reload).  The bus method `emacs/request METHOD PARAMS` → promise sends
`_harness/emacs/METHOD` to exactly one such client, never to the rest:
the most recently active (the last to send a request or notification)
among those that may call methods, so an unauthenticated client that
claims an Emacs is not asked.  It rejects at once when none is
attached, with the Emacs's message when it refuses, and when it
disconnects first.  `emacs/attached` lists the lent Emacsen, the one
asked first at the head.  Neither is callable over ACP.  Requests, all
answered with plain data or one bounded action
(lisp/harness-emacs-endpoint.el):
`buffers {}` → `{buffers: [{name, mode, modified, size, file}]}`;
`windows {}` → `{windows: [{frame, selected, name, mode, width, height,
file}]}`; `buffer {name, offset, limit, maxChars}` → `{exists, mode,
file, modified, total, first, lines, truncated}`; `open {name, path,
line, maxBytes}` → `{name, mode, size, modified, file, visited}`;
`insert {name, text, position, maxChars}` → `{name, inserted, line}`;
`save {name}` → `{name, path, size}`; `describe {symbol, buffer,
maxValueChars}` → `{known, function: {kind, signature, definition,
aliases, file, advice, keys, doc}, variable: {kind, value, buffer,
local, global, locals, localCount, standard, watchers, file, doc},
face: {doc, file}}`; `definition {symbol, type, maxChars}` → `{known,
type, name, aliases, kind, advised, loaded, native, autoload, file,
visiting, modified, line, endLine, lines, truncated, printed, note}`;
`trace {action, symbol, type, limit, callers}` → `{started: {symbol,
type, count, limit, callers}, line, stopped: [...], traces: [...],
buffer, lines}`; `messages {count}` → `{text}`.  There is no `eval`
request: a lent Emacs never evaluates model-written code, so nothing
that asks it can freeze it.

The server writes its address to `<state>/acp-address` and, when
`harness-acp-token` is set (always, for the harness process), the token
to `<state>/acp-token` (mode 600); `scripts/harness-acp-stdio`
authenticates with it on behalf of the editor it bridges.

Errors follow ACP's codes.  A call before `authenticate` (when a
client must authenticate) gets -32000, ACP's `auth_required`, which
clients answer by offering the `authMethods` of `initialize`; so a
method that fails gets -32603 (internal error), never -32000.  A wrong
token is -32000 too.  Notifications under `$/` (such as `$/ping`
heartbeats) are ignored without a log line.

Other transports hand their connections to the server:
`harness-acp-add-client KIND &key process writer remote` registers a
client whose messages to it go through WRITER `(CLIENT JSON-TEXT)`,
`harness-acp-client-receive CLIENT TEXT` dispatches one message it
sent, and `harness-acp-drop-client` disconnects one.  A client with
REMOTE, a plist describing another device
(`harness-acp-client-remote-info`), must authenticate even when
`harness-acp-token` is nil, unless a function of
`harness-acp-authorize-functions` (called with the client) lets it in.
Modules add auth methods too: `harness-acp-auth-methods-functions`
(client → list of `AuthMethod` plists) are listed by `initialize`
before the token, and `harness-acp-authenticate-functions` (client,
method id, params → nil for a method not its own, else a value or a
promise) answer `authenticate` for them; once the answer resolves the
client is authenticated.

Corporate mode (`harness-corporate-mode`): `acp/start` refuses an
address beyond this machine whatever `harness-acp-allow-remote` says,
`harness-acp-connect` refuses a harness elsewhere, a client with REMOTE
is refused, and turning the mode on (`harness-corporate-mode-change-hook`)
drops such clients and moves a server listening beyond this machine
back to 127.0.0.1.

The local transport dispatches lisp objects directly, no JSON, and
delivers notifications through `harness-run-soon` so callers are never
re-entered.

### acp-remote

ACP for phones and other devices on the network, off until
`harness-acp-remote`.  One listener (`harness-acp-remote-host`
0.0.0.0, `harness-acp-remote-port` 4276, binary sockets) reads the
first bytes of each connection: `{` hands it to ACP's line framing
(client kind `remote-tcp`), anything else is an HTTP request.  A
WebSocket upgrade (RFC 6455, implemented in the module: handshake,
streaming frame decoder over a unibyte buffer, ping/pong, close codes
1002/1009) on any path, `/acp` documented, becomes a client of kind
`websocket`; the subprotocol `acp.v1` is chosen when offered, and
`Acp-Connection-Id` is sent, as ACP's draft transport asks.  A text
message may carry several newline-separated JSON-RPC messages.
`GET /pair?code=C` pairs, `GET /` explains; every answer is
`Connection: close`, `Cache-Control: no-store`, `Referrer-Policy:
no-referrer`.

Pairing: `acp/remote-pair` → `(:url "http://ADDR:PORT/pair?code=C"
:ws-url "ws://ADDR:PORT/acp" :address :port :expires :lifetime)` makes
the one code in force (100 random bits, `harness-acp-remote-code-lifetime`).
Opening the link from an address other than this machine's consumes
it and pairs that address (devices `(:id :address :agent :paired
:seen)`, in memory only, dropped after `harness-acp-remote-idle-timeout`
without a connection), answers the waiting `authenticate` requests of
that address and emits `acp/remote-changed`.  Every client the
listener registers carries `:remote (:address A :transport T [:agent
UA :origin O :web BOOL])`; `harness-acp-authorize-functions` lets in a
paired address unless `:web` (an Origin naming a web page, not an
app's own), `harness-acp-auth-methods-functions` offers `pair`, and
`harness-acp-authenticate-functions` answers `authenticate pair` with a
promise settled by the pairing or rejected (-32000) after the code
lifetime.  A bearer token equal to `harness-acp-token` (subprotocol
`bearer.T`, `Authorization: Bearer T`, `?token=T`) authenticates too.

Methods (callable as `_harness/acp/remote-*`): `acp/remote-status` →
`(:running :enabled :corporate :host :port :address :address-set
:addresses ((:address :interface :kind lan|vpn|other) ...) :ws-url
:code-expires :devices (... :connected N) :clients)`,
`acp/remote-start` and `acp/remote-stop` (save `harness-acp-remote`;
stopping drops the clients, the code and every pairing),
`acp/remote-pair`, `acp/remote-forget-code`, `acp/remote-revoke ID`,
`acp/remote-set-address ADDRESS` (saves `harness-acp-remote-address`,
"" detects; drops the code).  Event `acp/remote-changed (:what
started|stopped|connected|disconnected|paired|revoked|address|corporate
:address A)`, forwarded to UIs.  Corporate mode refuses start and pair,
closes connections as they are accepted, and its change hook stops the
listener.

### version

Whether the running harness is the latest.  What runs is noted by
lisp/harness-revision.el, on both sides: `harness-start-hook` and
`harness-reload-hook` run `harness-revision-note-loaded`, which reads
the checkout `harness.el` comes from, links followed (straight.el's
build directory leads into its clone), and `harness-revision-loaded`
keeps the promise of `(:directory :loaded :version :commit :branch
:dirty)` until the next load; `:error` instead of a commit when that is
not the top of a git working tree (a package archive, or a harness
inside another repository).

Origins, in this order and each once: the loaded checkout as it is now
(kind `loaded`); local checkouts (kind `local`): the directories of
`harness-version-origins`, then the main checkouts of the harness that
sessions' projects belong to (`session/list`,
`harness-files-owning-checkout`); repositories by URL (kind `remote`,
read with `git ls-remote`).  The repository the loaded checkout pulls
from (`:upstream t`) comes first of its kind: the remote its branch
tracks and the branch it tracks there (`for-each-ref
%(upstream:remotename)`, the remote's URL from `git config`), or
`origin` and the branch its HEAD names on a detached HEAD.  straight.el
and other package managers set that remote to the recipe's repository,
so an install from GitHub is compared with GitHub and one from sourcehut
with sourcehut.  It is named after its host (github, sourcehut, gitlab,
codeberg, bitbucket, else the host, else upstream) and left out when
`harness-version-origins` names its URL on its branch or on none.  It is
read in the harness process, which has no straight.el, and from any
package manager's clone.  Nothing is fetched: the relation (`rev-list
--left-right --count`) and the newest eight commits each side lacks
(`log --no-merges`) are worked out in the first local repository
holding both commits, local checkouts first and the loaded one last,
as package managers clone shallowly.  When none holds both and the
loaded checkout lacks the origin's commit (`cat-file -e`), the harness
lacks it too: the origin is ahead, uncounted.

`version/check (&optional max-age)` → promise of the report `(:checked
:version :running :origins :verdict)`, each origin `(:name :kind
:location :branch :upstream :commit :subject :date :dirty :status
:missing :extra :missing-commits :extra-commits :error)`, `:status`
same, newer, older, diverged, ahead (a commit the harness lacks, no
local repository holding both), unknown (the running commit is in none)
or error, and `:verdict` behind (an origin is newer, diverged or
ahead), unknown (one cannot be placed, or none could be read) or
latest.  The last report answers
while it is about the revision running now and at most MAX-AGE seconds
old; otherwise a check runs, or the one running is joined (replaced
after five minutes).  Checks also run 30 s after the start, 3 s after
`harness/reloaded` and every half hour; each report is announced as
`version/checked REPORT`, forwarded to UIs.  Git always runs
asynchronously, without optional locks, with a timeout and never
prompting (`harness-revision-git-environment`: no terminal, an empty
GIT_ASKPASS, ssh in BatchMode, no credential helper for ls-remote).  A
failing command rejects its promise without signalling in a handler, so
an origin out of reach is an `error` origin, not an error in the log.

## Presentation contracts

`harness-ui` owns the connection (`harness-ui-connection`, local by
default; `harness-connect-remote` swaps it, and an empty address swaps
it back to this Emacs's own harness; `harness-ui-connected-hook`
runs after every connect, where the chat reopens the sessions its
buffers showed open, as a harness that just started has them all
closed -- not one a buffer showed inactive, nor one a buffer still
loading has not heard of yet), the face set
(`harness-user-face`, `harness-agent-face`, `harness-tool-face`,
`harness-thinking-face`, `harness-hint-face`, warning ramps), the
session cache updated from `_harness/session` updates, the tool cache
(every tool's spec from `_harness/tools/list` without a session,
fetched once per connection and again after `harness/reloaded`;
`harness-ui-fetch-tools`), through which views name every tool by its
label (`harness-ui-tool-label`, `harness-ui-tool-title`), window
positions (`harness-ui-display-session SID &optional POSITION`; presets
`right`, `left`, `bottom`, `full`, `other`, `fullscreen`; one session
per position, replacing),
the global keymap and the transient menu `harness-menu` (with a group for
the commands of the buffer it is opened from, which each mode lists in
its `harness-menu-group` property; opened from a side window it gets a
side window of its own across the bottom of the frame, never in another
window's slot, and below a window such as a BTW at the bottom already,
which keeps its height: the windows above lend the menu its lines and
get them back as it closes.  Only when several windows share the bottom
does it go to the top),
and icons via `icons.el` (`define-icon`) with text fallbacks.  Every
command has a mouse target: buttons, header-line segments, or mode-line
segments.

Pending requests (`harness-ui-pending`): the permission prompts and
questions a session waits on, held per session -- fed both by the ACP
requests that block a client and by the session's pending list, so a
view that is not watching a session can still answer it -- and drawn,
answered and keyed by this module wherever they show: the chat's tail
panels and a popout of their own.  The request records and the diagram
each question shows belong to the session, not to the buffer drawing
them, so the chat and a popout of the same request agree.  Views get one
line about a session with `harness-ui-pending-summary` ("has a question
for you"), a kind with `harness-ui-pending-status`, and the full request
with `harness-ui-pending-popout` (from the session list and the task
board, SPC, through `harness-ui-popout-at-point-functions`).  Opening a
popout brings the session's cached pending list into the store first
(`harness-ui-pending-sync-session`), which is how a request a view
already shows becomes answerable there when no chat has synced it.
A permission prompt about a path outside the session's directories
(one with a `:pattern`, see perms) shows the glob pattern its answers
hold for on a line of its own (`pattern: ~/notes/**  [Edit] e`), with
`[Edit]`/`e` (`harness-ui-pending-edit-pattern`, also `C-c C-p` in
the chat) to change it in the minibuffer, more or less specific;
`M-n` offers patterns around the request's own, and the answer carries
the edited pattern.  Any other prompt is about the call alone and
shows no pattern; `C-c C-p`, or `e` on such a panel, edits the newest
request that has one.  The facts under a panel's title
(`harness-ui-pending--permission-facts`) say what the call reaches:
`kind: write   paths: ~/proj/lisp/a.el` on one line for most calls;
for a shell command `kind: exec   runs in: ~/proj`, where it runs, and
below it `paths: ~/.claude/projects/x`, what it is about: the paths it
names outside the session's directories (left out when that is just
where it runs).

Connecting again never strands a session.  The connection the UI swaps
out closes with the reason `replaced`, and the requests still waiting
on it are rejected with that reason (`harness-ui-connection-replaced-p`):
`harness-ui-call` and the chat do not report them, since the harness
goes on with them (a prompt's turn runs, and the redrawn transcript
shows it).  A permission prompt or question shown from before answers
through the bus methods (`permission/answer`, `question/answer`): the
pending module records the connection with each request, and a RESPOND
whose connection is gone would never be heard.  While a chat buffer
fetches its transcript again (after every reload and reconnect) it
holds back node updates, which the fetched nodes carry, but applies
the session record and the activity as they come: a status, queue or
prompt that changed meanwhile is not lost.

Chat buffer (`harness-ui-chat`): transcript region (read-only) + queue
list + attachments row + compose region at the bottom.  Rendering is
incremental (append and in-place update by node id using markers);
older history renders in chunks on demand so a million-token session
stays snappy.  A checkout (`session/head-moved`) makes the transcript
another path, so the buffer loads it again rather than leave the
branch behind on screen.  Markdown is rendered by the built-in renderer in
`harness-ui-markdown` (headings, emphasis, code spans, fenced code with
the language's major mode, lists, quotes, links).  A click or `RET` on
a link opens it (`harness-ui-markdown-open-link`): a URL with
`browse-url`, anything else as a file in `default-directory` -- the
session's directory, in a chat -- in another window, at the line a
`#L12` or `:12` suffix names.  The link's keymap binds `mouse-2` as well
as `mouse-1`: its `follow-link` property makes a quick `mouse-1` a
`mouse-2`, and an unbound one reached the global `mouse-yank-primary`,
which pasted the primary selection into the transcript (read-only, but
rear-nonsticky, so an insertion inside it gets through).  Its double and
triple clicks are bound to `ignore`: unbound, they ran as single clicks
and opened the link again after the first click had.  Tool and thinking
nodes collapse; runs of coalescable tools fold into a summary block.
Thinking between two calls of a run does not break it but folds in
with them, since a model that thinks before every call would never
have a run otherwise; thinking before a run's first call or after its
last stays out.  Only the newest block joins a run as the transcript
grows, and a loaded transcript is grouped as a whole.  Two calls of a
coalescable tool stay out of runs: one whose result shows a picture or
a video, which a group would hide, and one the session waits on, whose
permission prompt is open (the pending record names the call), until
the user answers it.  Such a call leaving its run, or coming back to it
once answered, has the transcript grouped anew, as a load groups it:
other calls of its step may have come after it meanwhile.  A group
with a call of a group the user had opened is open too, and no other.
A page of history can start with the result of a
call on the page before it: the result shows alone, as the result of
an earlier tool call, until that page loads, then joins its call
(`harness-chat--adopt-orphans`), so the run folds as it would in a
single load.
A tool call's header says how it went, marked the way a Japanese table
marks it (`harness-ui-level-icon`), each ending on a background of
its own: a green circle when it ran (`harness-tool-face`), a yellow
circle and "running" while it runs, a red triangle and "failed" when it
ran and reported an error, such as a non-zero exit or an edit whose
text did not match (`harness-tool-error-face`), or a yellow circle and
"denied" when the permission system refused it, so it never ran
(`harness-tool-denied-face`); a denied call's text is labelled as the
reason rather than as output.  The icons and their words take
`harness-success-face`, `harness-caution-face` and
`harness-failure-face`, which inherit the theme's `success`, `warning`
and `error`.  A summary block counts the failed and denied calls it
folds, and the tree starts each tool result's row with the same icon.
The panel of a question whose options have diagrams shows one diagram
at a time, in an area under the options; its tabs, `n` and `p` on the
panel, `C-c C-f` and `C-c C-b`, and point moving onto an option switch
it (all of it in `harness-ui-pending`).  Switching redraws the options
and that area alone, in place, so point, the windows and the compose box
stay put.  A permission panel whose one line of input leaves something
out (a value past its width, a further line of one, a line too long)
ends that line in `[Show all]`, `[Show all N lines]` when values have
lines it hides, and binds TAB on the panel
(`harness-ui-pending-toggle-input`); whole, each value takes a line of
its own and a cut one a verbatim block under its key, until `[Show
less]`.  Which requests show whole is the request's state, like the
diagram shown, so the chat and the popout agree, and point stays on
the toggle through the redraw.  A module hosted by a chat buffer can
put a read-only panel of its own above the box with
`harness-chat-panel-functions` and take the box's message with
`harness-chat-send-function`.
Tools go by their labels everywhere: a tool block's header shows the
label in `harness-tool-title-face` and what the call is about after it
in `harness-tool-subject-face` (the faces stand in for the colon of the
title), a summary block counts the calls by label ("5 tool calls: Read
file ×3, Search files, Find files", then " · thinking ×2" for the
thinking folded in with them), and so do the permission panel,
the activity line and the mode line.  A title recorded before tools had
labels starts with the tool's name ("read_file x.el"), which the label
replaces, so old transcripts read the same.  Under a folded call's
header one dim line sums up the input its title leaves out
(`harness-ui-tool-input-summary`): a list reads as its labels,
comma-separated, and a list of other objects, such as the items of a
todo list, as how many there are, never as a Lisp form; a todo_write,
whose title already counts its items, has no such line.
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
"interactive"), thinking level, context, output rate, cost and [menu]; clicking a
setting changes it, and the non-interactive one toggles.  The output
rate ("48 tok/s", `harness-ui-format-rate`) is the session's rate as the
usage module measured it. It is dimmed when the session is not running,
because it is then the last rate measured. The session has no rate
until it has been measured, and a narrow window drops the rate first.
The UI keeps the rates in a cache (`harness-ui-session-rate`). It is
filled with `_harness/usage/rates` on connect and kept current by
`usage/rate-updated`. Every change runs `harness-ui-rate-functions`,
which redraws the chat headers, the session list and the task board.
Other UI
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
line, in a window shorter than the buffer too, a board under a BTW say,
by scrolling that never moves point out of the box), a prompt that is a
field of its own (`C-a` stops after it, so
`C-a C-k` clears the line), the placeholder, @file and /skill
completion, attachments (`C-c C-a`, pasting `C-y`, drag and
drop), skill expansion (`harness-compose-with-expanded-text`) and ACP
attachment blocks.  `harness-compose-insert` takes `:face`, the box's
background (`harness-compose-face` by default) and `:accent`, the face
of the prompt and of the bar down the box's left edge, through which a
host whose box does something else than compose -- the task board's,
which sends to a session -- marks it; `harness-compose-bar` draws that
same bar on the host's own lines around the box.  Without either
argument the box is the plain one.
A host draws the attachments above the box with
`harness-compose-insert-attachments`, one a line: the paperclip leads
the first, the names under it line up with its name, and a prefix the
host passes starts every line (the board's message box passes its bar).
Each line is fitted to the narrowest window showing the buffer -- the
daemon's initial frame, which never shows, aside -- in pixels of the
frame drawing it (`string-pixel-width`, so icons, thumbnails and text
scaling count): a name too long is shortened in the middle
(`harness-compose--shorten`), keeping its start and, room permitting,
a path's whole file name, while the tooltip tells the whole path; a
thumbnail takes a third of the room at most, and a download keeps room
for its progress at its widest, so its line never grows as it ticks.
When a window showing the box changes size, the box has its host draw
the lines again (a buffer-local `window-size-change-functions`,
debounced, and only once the room really changed).
An attachment chip leads with a thumbnail (`harness-compose-thumbnail-lines`)
when it is an image, or a video whose thumbnail the media module makes
with ffmpeg in the background (a chip asks for it through
`harness-ui-media-video-thumbnail' and is drawn again when it lands).  A
link dropped from a browser or a page (`dnd-protocol-alist` for
http/https/ftp, plus the X types through `x-dnd-types-alist`: a raw
image, a browser's file promise, `text/html`, text, and X direct save)
downloads with `harness-http-download` behind a chip whose spinner,
progress bar and size an overlay redraws, so the buffer's text is not
touched while it ticks; the file attaches under the name the server or
the link gave, or the link goes in as text when it turns out to be a
web page.  Sending waits for a download in flight.  The X handlers take
what the drop says the dragged media is (a browser's `text/html` or
`application/x-moz-file-promise-url` names the image inside a link),
and dropped text goes into the box rather than into the read-only
transcript around it.  A link off a selection arrives propertized
(`foreign-selection`), which is why the code that hands one to curl
strips text properties first.
Media on the clipboard is read without touching `kill-ring`: `C-y` in a
compose box attaches the image, or the files a file manager copied, and
pushes captures on the media ring (`harness-ui-media-ring`), a ring of
its own under `harness-state-directory/clips/` deduplicated by the
SHA-1 of the bytes, which `M-y` goes back through and
`C-u M-x harness-compose-attach-clipboard` picks from; `yank-media`
attaches them too (`harness-compose-yank-media`).  The box binds no
`C-c C-v`: in a chat that is the review banner's [Verify], so the two
never fight, and other MIME types are chosen from with
`M-x harness-compose-attach-clipboard`.
Completion reads the project's files and the skills when it is asked,
so a token typed before they arrived is offered them once they have.
Popups that show as you type (corfu's `corfu-auto`, company) give up
when the buffer changed since the last key, and a host changes all the
time (a chat streams, a board follows its tasks): once the token stops
changing, the box asks them again (`harness-compose--popup`).  @ and
`C-c C-a` find files through one table (`harness-compose--file-table`):
part of a name matches the project's files, never listing while you
wait, and a path -- starting with `/`, `~`, `./` or `../`, the relative
ones against the box's project root -- completes over the file system
directory by directory in the `file` category, with file name handlers
off so that a remote name never opens a connection.  A completed path
attaches only a regular file; a directory stays in the box for its
files to complete.  `C-c C-a` ignores a leading @, and a directory
chosen there reads again from inside it; `C-u C-c C-a`, or a directory
that is no project, browses with `read-file-name`.  An @
reference typed out in full, or pasted, names its file all the same:
`harness-compose-take` attaches the regular files the references in the
text name (`@skill:` ones and missing files aside, trailing punctuation
tolerated) and leaves the references in the text.  An answer to a
question, on the board or in a popout, carries no attachment: there a
file the text names goes as its reference
(`harness-compose-without-references`).

Dragging images out (`harness-ui-drag`): the images the UI shows -- the
transcript's (`harness-chat--image-string`, `harness-ui-image-string`),
a compose chip's thumbnail and name, a report's and the image popout's
-- drag into another application as a file.  `harness-ui-drag-source`
(a string), `harness-ui-drag-region` (buffer text) and
`harness-ui-drag-props` (a plist of text properties about to be put on
text, the image strings' click properties, so that an image drawn in
pieces, line-high strips say, drags from each) set the
`harness-ui-drag` property, the file or t for the image displayed
there, lay `harness-ui-drag-map` (down-mouse-1) over the keymap the
text already has, and add a word to its `help-echo`.
`harness-ui-drag-start` follows the mouse with `track-mouse` while the
button is down: a release before it moved `harness-ui-drag-threshold`
pixels goes back to `unread-command-events` as a mouse-1 click, so
links, buttons and `follow-link` work as before; further, it is
`dnd-begin-file-drag`, whose drop on the source frame itself is
ignored, so letting go over Emacs cancels.  An image held only as
`:data` is written to the session's own temporary directory
(`session/tmp-dir`) as `image-SHA.EXT`, SHA the start of its bytes'
SHA-1, so a second drag writes nothing; the directory is asked for when
such an image is drawn and again on the press, and never waited for:
until it is known, and for a buffer of no session, the file goes to a
private directory of this Emacs (mode 700), deleted when Emacs exits.
Nothing is made draggable where `x-begin-drag` is missing (only X,
macOS and Haiku start drags), nor is a remote file, which the drag
would copy here while the UI waits; on a text terminal's frame a press
is a plain press.

Views share positions with sessions: the task board, session list,
usage dashboard, worktree list, conversation tree and log open through
`harness-ui-display-view`, replacing the session in their position (and
returning to the position they had last); a session opened from a view
(`harness-ui-session-opener`) replaces the view.  Menus, help and the
BTW overlay keep their own windows.

Fullscreen layout (`harness-fullscreen`, `F` on an overview, `C-c h F`):
an overview -- a view that sets `harness-ui-overview-function`, the
task board and the session list -- takes the left of the frame in a
side window (`harness-ui-fullscreen-width`), and every other window but
one, the slot, makes way for it.  The slot shows the session in sight,
else the one the overview function names (at point, else the most
recent).  While the layout lasts the `fullscreen` position is the
default: sessions and views shown without a position take the slot, and
an overview takes the left.  The layout is kept per frame in a weak
table (`harness-ui--fullscreen-layouts`), with the window configuration
from before it.  `harness-ui-bury` (`C-c C-z` in a chat, where plain
keys type) puts the slot's buffer away and brings back the last buffer
of the user's the slot showed, keeping the layout; `q` on the overview
(`harness-ui-quit-view`) ends it, restoring the configuration, but for
a buffer of the user's left in the slot, which stays in sight.

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
where its value in effect comes from; toggles, menus and models save
at once, text saves with RET (C-x C-s saves every edit).  A type whose plist
names its keys (`:options`) is drawn as a form: one line per key,
`[X] Base URL: …` with the key's help under it, the key's name width
aligned, and a key the value does not set greyed out with the value it
would start from (`harness-ui-config--present` rewrites the type; the
values it accepts do not change).  In a list, each record folds into a
line summing it up, `[Edit]` opens it into the form and `[Hide]` folds
it again; `[INS]` adds a record, open, from the type's starting value.
[More] unfolds a long documentation, whose first line shows with the
keys' help doing the rest.  A string whose customize type says what it
names, with `:names` (`model` for PROVIDER:MODEL, `provider` for a
provider id, and `:provider ID` for the names provider ID gives its own
models; see `harness-model`), is a dropdown, `harness-ui-config-model`,
alone or with the constants of its menu, in a list too: a button naming
the model, then its id and context window.  The button opens a picker
(`completing-read`) of the UI's catalogue of `provider/models`, grouped
by provider and annotated with context window and price.  Text that
matches no candidate is taken as typed, and a model no provider lists
gets a warning line.  [Remove override]
deletes a project value, [Reset to default] a customized global one.
Secrets show as set or not and are set through `read-passwd`; long
texts open in `string-edit`.  The page reloads on `config/changed`,
keeping edits not saved yet, point, and the records left open.

Session settings: `harness-set-model`, `-thinking`, `-permission-mode`
and `harness-toggle-non-interactive` (`C-c h m` `T` `p` `i`) change what
the buffer's `harness-ui-setting-target-function` names -- a session
id, or a settings plist with its setter -- and otherwise the current
session.  The menu's `i` entry says whether that is non-interactive
("Non-interactive: on"), and has no state where the command would
ask for a session.

A model switch asks the harness first (`handoff/check`, or
`handoff/check-all` for `harness-set-model-all`, which asks once for the
whole batch).  A lossy one asks how to hand over through
`harness-ui-switch-function`: with the `ui-switch` module the question is
a banner above the session's compose box -- the chat panel the review
banner uses (`harness-chat-panel-functions`) -- with the two models, the
reason, the risks, the cache cost and the running turn as labelled rows,
and one button per choice (current model summarises, new model
summarises a limited context, full transcript, no handoff, cancel).  Its
keys answer while point is on the banner and a click answers from
anywhere; the banner says the handoff is lossy and the new model is told
to re-investigate.  Without a chat buffer to show it in (a switch asked
for outside the UI, or over ACP) the minibuffer question of
`harness-ui--read-handoff` asks instead.  The answer goes to
`handoff/switch` (`handoff/switch-all`); cancelling changes nothing, not
even the default for new sessions.  A switch that loses nothing goes
through `session/set_model` (`session/set-all`) as before, and so does
any switch when the harness cannot check.

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

Remote control page (`harness-ui-remote`, `C-c h P`,
`harness-remote-control`): whether the harness serves other devices
(start or stop), the ACP address their clients connect to, the address
of this machine that QR codes carry (chosen among the interfaces), the
pairing QR code and the paired devices (unpair at point).  The QR code
starts folded and unfolds with a fresh code (`acp/remote-pair`); it
folds again once `acp/remote-changed` says a device paired, when its
code expires, and when hidden, which drops the code
(`acp/remote-forget-code`).  It is drawn by `harness-ui-qr`
(`harness-qr-encode TEXT &optional LEVEL MASK` → `(:size :version
:level :mask :modules)`, byte mode, versions 1–40; `harness-qr-image`
one SVG path, black on white; `harness-qr-insert`, half blocks without
images).  In corporate mode the page shows a notice only.

Version page (`harness-ui-version`, `C-c h v`, `harness-version`): the
verdict, the commit running (with, when the harness runs in its own
process, the commit this Emacs loaded the UI from, and a reload button
when the two differ), each origin with its commit and status (the
repository the loaded checkout pulls from says so), the commits the
harness lacks (an origin at the same commit with the same status as one
listed above says so instead of listing them again; an ahead one has
none to list), and what to do: reload when the loaded checkout moved
on, pull into the loaded checkout (`straight-pull-package` under
straight.el) when a remote has newer commits, push when only a local
checkout has them.
Opening it shows the last report at once and asks `version/check` with
a max-age of a minute; `g` asks with 0; `version/checked` redraws it,
and the menu's Version entry says "not the latest" after a report that
found the harness behind.

Task board (`harness-ui-tasks`, `C-c h a`): the project's tasks in six
sections -- requires your input, ready for review, merging, in progress,
pending, completed -- with each card's current todo, progress, elapsed
time, output rate (while its session is open), cost and merge state, one-click answers to a blocked task's
question or
permission, and a compose box that submits a task, edits a pending one,
messages a task's session, answers its question or takes the feedback
that sends a task back from review (`C-g` leaves an edit, message,
answer or feedback for a new task again: a question stays waiting,
never cancelled).  The same box does all of these, so what `C-c C-c`
will do is made plain: a box that sends to an existing session -- a
message, an answer, feedback on a write-up, or feedback that sends a
task back from review -- wears the message colours
(`harness-compose-message-face`, with the prompt and a bar in
`harness-compose-message-accent-face`, carried onto the label line and
the [cancel] beside it), shows the message icon and names where it
sends ("Message to session “X”", "Refine “X” with feedback",
"Answer the session's question “…”", "Send back “X” with feedback");
composing a task, new or edited, keeps the plain box.  A task in
review shows [Verify] and [Send back]: `v`
accepts the work (its branch then merges), `R` sends it back to its
session with the feedback written in the compose box (`C-u R` reads it
in the minibuffer); `m`, a message, opens the same box, since any
message to a task in review sends it back.  A verified task waits in
merging -- queued for the queue's turn, merging, or its session
resolving the conflicts -- saying so on its card until the branch is in
and it moves to completed.  A card of a task that handed a report in
also shows [Review], popping the report out; it is one of the items
`harness-ui-popout-at-point-functions' offers.  While the task waits
for review, the report ends with the banner of its session, [Verify]
and [Send back], and a box for the feedback.  The header counts the
tasks to review, and `task/review` says in the echo area that one is
ready (`harness-ui-tasks--notify-review`).  The header also says, as a
chat's does for its session, what the board's tasks cost and who pays
(see Cost display below), then the fullest budget that applies to the
project.  The header's Review switch
([Review: on], `V`) turns review off and on again for every project
(`harness-tasks-require-verification`, saved through `config/set`):
off, finished tasks merge and complete by themselves, and Ready for
review shows only while tasks from before still wait there; turning it
off while tasks of the board wait for review offers to verify them.
`config/changed` brings every board the new value.  RET opens the session, and
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
buttons under the New task label), and so does the worktree switch
beside them: `own worktree` (the default in a git project) or `main
tree`, where the next task works in the project's own checkout, with
nothing to merge (`harness-ui-tasks-toggle-main-tree`; new tasks only,
never bulk).  A
Submit / Refine toggle beside that label, showing only the current mode
(a click or `C-c C-t` switches it), picks what a new task does: start,
or go to the backlog, written up by an agent and
waiting in pending until you start it (`s`); `r` refines a queued task,
retries a stopped write-up, writes one up all the same when it refused
the task as a duplicate, or sends feedback on a backlog task's.  A task
whose write-up refused it as a duplicate shows it in Requires your
input, naming the task it duplicates and saying why: `k` drops it, `r`
writes it up anyway, `m` takes what makes it another task than the one
it duplicates.  `I` or
[Add session] makes an ongoing session a task.  A card in Ready for
review whose worktree is itself a checkout of the harness gets an
[Open harness] button: it starts the worktree's own live development
loop in an Emacs of its own, frame raised, through `harness-dev/open`,
so the work can be tried before it is verified.  `b` or [BTW] (or the
usual BTW command) opens a BTW side conversation over the board about
its tasks (`task/btw`).  `SPC` over a card, or [Answer…] / [Request…]
on it, pops out what the task at point needs -- the permission prompt or
question its session waits on, a task's report -- through the shared
`harness-ui-popout-at-point`, which runs whichever view of the item
registered for it.  The board reads what a session waits on through
`harness-ui-pending`, its shared notion of it.
Boards reload after any
task, merge, turn, status, worktree, budget or reload event.  New tasks show at
the top of in progress (latest started first), review lists the latest
finished first and completed the latest completed (verified, else
finished) first; merging is the queue's own order, from when each
branch joined it; pending is the queue, in the order its tasks start,
with the backlog among it (oldest first; only queued tasks have a place
in line).

The board's search (`harness-ui-tasks-search`, `/` on the board,
[Search] in its header, `C-c h /` anywhere, which opens the project's
board first) reads a line in the minibuffer and sends it to
`_harness/task/search`; the board then shows only the tasks the answer is
about, archived ones included, under a banner that says the line, how
many tasks it shows and what the model looked at besides the board.
`harness-ui-tasks-filter` carries that: `:show` a predicate over a task,
`:banner` a function returning the text above the columns, `:clear` the
function that drops it, which `C-g` on the board runs when the compose
box has nothing to leave ([Clear] does too).  The columns left without a
task are hidden.  An action the answer does not need confirmed runs at
once, and the banner and the echo area say what it did (the toast), with
[Undo] when it can be undone (archive and restore undo each other);
`task/search-apply` runs them.  An action that interrupts work, merges
it or sends words to an agent is proposed instead: the banner asks, with
a button that does it and [Skip], and `/` then RET on an empty line does
it too (the prompt names what an empty line would do).  The header's
[Search] segment spins while the model works, and each search opens with
`_harness/task/search-warm` so its process is started before the line is
typed; the model's name shows while it answers.  The best match gets
point once the board shows it (`harness-ui-tasks--focus`).

Companion pet (`harness-ui-pet`, `C-c h z`, `harness-pet`, menu `z`):
the buffer `*harness pet*`, the only place the pet shows.  Before it
hatches: the egg, [Hatch it] (`h`) and what hatching does.  After: a
card with its stars, rarity and species, the creature in its rarity's
colour (`harness-ui-pet-art SPECIES EYE HAT FRAME`, five lines, three
frames per species, the hat centred on the head) beside its five stats
as meters, below it in a window too narrow for both, its name (gold
when shiny) and personality, its level with an experience meter, and
what it said last on a band of its own (`harness-pet-speech-face`,
the action between asterisks in `harness-pet-action-face`), then the
two before it and a footer saying whether and through which model it
speaks.  Prose is filled to the window and drawn again when its width
changes.  The header line has [Pet] (`p`, `SPC`), [Rename] (`r`),
[Mute]/[Unmute] (`m`) and [Release] (`R`, asks first), or [Hatch], and
`g`, `q`.  The buffer tells the harness whether it is on screen
(`_harness/pet/watch`, client `HOST:PID`) from
`window-buffer-change-functions` while it lives, as it is killed and
after every connect, so the pet only speaks while someone can see it.
It follows `pet/changed` and `pet/said`, and `config/changed` of a
`harness-pet-` option.  Animations -- the egg wobbling then cracking
and sparkles as it hatches, hearts as it is petted, a fidget as it
speaks (after the sparkles, when its first words come while it
hatches) -- are a few frames each on one timer that stops with the
last frame or as soon as the buffer is off screen, so nothing runs
while nothing happens; `harness-ui-pet-animations` nil keeps it still.

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
`provider/quota-updated` (`harness-ui-quota`).  The task board's header
shows its tasks the same way: `harness-ui-sessions-total` takes their
sessions as one (their usage summed, the billing and plan of the one
updated last, the provider of the new-task model), which
`harness-ui-format-spend` formats with the plan's windows, saying
"These tasks" in its tooltip; `harness-ui-spend-segment` makes the
chat's and the board's text a header segment, its `%` escaped, that
opens the dashboard.  The board adds the fullest budget of the
project from `usage/project-budgets`: `harness-ui-format-budgets`
reads `budget 62%`, coloured as a quota window, and describes each
budget in its one-line tooltip (`harness-ui-describe-budget`).  In a
narrow window the board's segment (`harness-ui-tasks--spend-segment`)
outlasts the counts and most buttons, its budget making room first.
The dashboard's budget lines are made from the same pieces
(`harness-ui-budget-label`, `harness-ui-budget-spent`,
`harness-ui-budget-pace`).  Under the Plan section
the dashboard's Fallback section edits `harness-fallback-models` (from
`fallback/status`, saved with `config/set`, global): the entries in
order, each with whether it is available, out of quota until when, out
of money, or not set up, and [try now] (`fallback/clear`), [up],
[down] and [remove]; [add] (`f`) offers each provider ("model of
similar ability") and each model.  `M-<up>`/`M-<down>` move the entry
at point, `d` removes it (or the budget at point), `c` clears its mark.
It follows `fallback/changed` and `config/changed`.

The Budgets section lists the harness's budgets, the Budget setting's
and the sessions' own (`usage/budget-status` on "settings" and
"session:SID").  A budget's line has [delete]
[baseline] [plan] right after its name, padded to one width so the
meters line up: the dashboard does not wrap lines, and buttons at the
end of a budget's long line were out of sight.  [delete] or `d` deletes
the budget with `usage/remove-budget`, or a session's own one with
`session/update :budget nil`, and says the Budget setting's is changed
with `M-x harness-settings`; `harness-delete-budget` (`C-c h B`,
"Delete budget" in the harness menu) does it from anywhere, the budget
read by name (on a budget's line, that one is the default).  A hard
budget's refusal says it is deleted there, or the setting's, where it
is changed.

Other buffers: settings page (`harness-ui-config`, above), sessions list (`tabulated-list-mode`, tree indentation for
children, filter/sort by any column; a Tok/s column shows each session's
output rate, dimmed while it is not running; SPC on a session pops out what it
waits on (a session that waits on nothing leaves SPC scrolling), its
status cell's tooltip says so (`harness-ui-sessions-requests`);
scoped to the current project, its
git worktrees and so its tasks' sessions included, each session's root
resolved to its main checkout once with `harness-files-owning-checkout`;
a task's session is of kind task and goes by its task's title, as on the
board, until the model names it after its first turn — the list loads
the tasks with `_harness/task/list` and follows `task/changed' and
`task/deleted'),
conversation tree (`harness-ui-tree`), usage dashboard (`harness-ui-usage`,
svg charts via svg.el; by project, the rows of a project's git
worktrees, its tasks' and sub-agents', fold by their `:main` into one
line with their sum and count, folded until TAB, RET or a click unfolds
it, `w` or `[show worktrees]` every project, the main checkout's own
usage first, then each worktree's; a redraw keeps every window's start
and point lines), worktrees (`harness-ui-worktree`), notifier
(`harness-ui-notify`: global mode-line segment with blocked/running/idle
counts, clickable), BTW side window (`harness-ui-btw`: a new, empty
session listed under the session it is opened over but sharing nothing
with it or with other BTWs (`session/btw`), or, over a view that sets
`harness-ui-btw-start-function`, a new conversation the view starts, shown
in the session's own chat buffer with point in its compose box, so the
question is written and sent like any message; nothing is read in the
minibuffer.  The buffer is the full chat: its header line (model,
permission mode, non-interactive, thinking, context, output rate, cost, [menu]),
keys and menu are a session's, `harness-ui-btw-minor-mode` only adding a BTW segment in
front of the header through `harness-chat-header-functions` (what it
is about, [close], [keep]) and `C-c C-k`/`C-c C-o` to close and keep
it; one over a session starts in that session's permission mode, and
every one at the BTW thinking level (`harness-btw-thinking`).  The
first message names it `btw: ...`, unless it was named by hand.
Closing it returns there; a BTW nothing was asked in is deleted with
its buffer, once the harness confirms it holds no node of its own,
and an idle one is closed.  Keeping it makes it a normal session
window in that place, with nothing of the BTW left in its header),
popout (`harness-ui-popout`: one item of a session or task -- the request
it waits on, a task's report -- in a selected bottom side window fitted
to it; a KEY names the item and reusing it reuses the buffer, so state
the owner keeps there survives: whoever owns the item passes a TITLE and
a RENDER, and with `:compose' the shared compose box under the content,
whose C-c C-c gives the owner the text and attachments.  `q' closes it,
`g' draws it again, and C-g closes it once there is nothing else to
quit; `harness-ui-popout-at-point-functions' lets a view pop out the item
at point with one key), media
(`harness-ui-media`: inline images, audio record/playback with svg
meters, video posters that play the video, and the attachments a tool
result or a message carries; a compose chip's thumbnail comes through
`harness-ui-media-video-thumbnail`, which makes one in the background and
tells the chip when it is there), popouts (`harness-ui-popout`: one item of
a session or a task in a small selected bottom side window, fitted to
its content up to `harness-ui-popout-max-height` or the popout's own
`:max-height`, one buffer per KEY the owner picks; `q`/`g` on the
content under the owner's own keys, `C-c C-c` sends its optional shared
compose box, `C-g` closes it, and `harness-ui-popout-at-point` runs the
first `harness-ui-popout-at-point-functions` that knows the item at
point; a popout opened from another (`:parent`) takes that one's
window, says [back], and gives the window back when it closes, and
`harness-ui-popout-pixel-width`/`-pixel-height` size what it draws for
the window it shows, or will show, in; `harness-ui-popout-image` is
one image as large as the frame allows, `harness-ui-popout-image-max-height`
of it, scaled down to fit or up by `harness-ui-popout-image-max-scale`
at most, with Emacs's image keys and [Open externally]), the review of
a task (`harness-ui-review`: one banner, the board's Ready for
review -- its heading, the handed-in report in full and always
expanded, then [Verify] (`C-c C-v`), [Send back] (`C-c C-x`) and
[Review] -- shown above the compose box of the task's session, a chat
panel (`harness-chat-panel-functions`), and at the end of its report
popout (`harness-ui-report-panel-functions`); the session's box sends
as always and the harness takes any message to the task's session for
the feedback that sends it back (`harness-tasks--on-message'), so
[Send back] only points at the box, while
`harness-ui-report-compose-functions` gives the report box's text to
`task/reject` as the feedback; `harness-ui-review-minor-mode` puts
those two keys over the buffer's own, only for as long as it shows; it
follows the task events of its session and draws again only when what
it shows changes, finding the chat buffer by session id with `equal`,
since an id from the harness process is a fresh string), the switch
banner of a session (`harness-ui-switch`: the chat panel that asks how
to hand the conversation over when a lossy model switch needs it -- the
models, the reason, the risks and costs as labelled rows, and a button
and a key per way to hand over, falling back to the minibuffer question
when no chat buffer shows; see "Switching model or provider"), and the
handed-in report (`harness-ui-report`: the summary as markdown and the
evidence -- images as wide as the popout and up to
`harness-ui-report-image-max-height` of the frame high, the popout
growing to `harness-ui-report-max-height` for them, a click or RET
showing one larger in an image popout whose [back] returns to the
report; videos and files through ui-media, code as a block, notes, and
a referenced tool call drawn as the call it links to, with [Open in
the session]; opened from the board's [Review] button and from the
banner, in a popout of its own, to which other modules add panels and a
box, which follows `task/changed` and closes once the review is decided
-- the task turns verified, or is sent back with a new round of
`:feedback` -- wherever that was done; the report of a task decided
before it opened stays).
