# Rust and the harness backend: measured costs, Emacs-owned contracts, and a staged route

**Status: research only.** This document changes no production code and proposes no
rewrite. It answers a narrower question than "would Rust be faster?": *which parts of
the harness server are worth moving out of Emacs Lisp, what must stay in Emacs, what
has actually been measured, and what would have to be true before a migration stage is
worth starting?*

The short answer:

1. The harness already runs its backend in a separate `emacs --batch` process behind
   ACP ([`lisp/harness-server.el`](../../lisp/harness-server.el), `harness-server-main`).
   The original reason to split it from the UI — one Emacs thread shared by tool work
   and redisplay — has already been paid for.
2. The largest measured cost in the connection/transcript path is **the payload the
   server chooses to send**, not the language it is written in. A full
   `session/list` of 1,000 synthetic sessions carrying 40 KB of provider state each is
   **40.8 MB** and takes about **0.27–0.30 s** to send (plus ~0.05 s to parse in a
   Python client); the same listing without provider state is **0.77 MB** and
   **0.019–0.039 s**. The pending performance task already fixes that with a lean listing
   (`task/speed-up-harness-connection-and-xywzvi9m`, commit `972b26e`, report
   `docs/analysis/transcript-load-2026-11-07.md`, unmerged at the time of writing).
3. The rest of the user-visible wait is mostly **client rendering**: 177–471 ms in
   Emacs for 400–1,200 synthetic nodes, and 36 ms decode + 20 ms apply for 1,200 nodes
   in Flutter, measured by that same task. A Rust server does not make Emacs redraw or
   Flutter rebuild widgets faster.
4. Rust has real, defensible benefits — async transport, TLS/WebSocket, no byte-code
   compile at start-up, offloading blocking SQLite work, lower memory — but only the
   transport and SQLite benefits are not already available from targeted worker
   processes. **A full rewrite is not justified by the measurements.**
5. **Recommendation:** ship the measured Lisp/payload/client fixes first; add
   instrumentation; then use **staged extraction with a Rust ACP edge** (and, only if
   measured, a Rust SQLite/search worker) as the first and possibly only Rust steps.
   Keep the session, task, permission and provider core in Emacs Lisp until a gate
   says otherwise. Reject hybrid-core and full-rewrite options now.

The rest of this document gives the source evidence, the measurements, the option
comparison, the compatibility boundaries, the risks, effort ranges, and the stop/go
criteria.

---

## 1. Scope, sources and evidence classes

### 1.1 What "the backend" means here

The repository has two Emacs processes and one wire
([`docs/architecture.md`](../architecture.md), "Processes"):

```
 user's Emacs                         harness process (emacs --batch -Q)
 harness.el, core, lisp/ui,     ACP   harness.el, core, lisp/modules
 harness-acp (client only),  <------> (acp serves 127.0.0.1:ephemeral,
 harness-files,               TCP     token per spawn; every tool runs here),
 harness-emacs-endpoint,              the user's other modules
 the user's UI modules
```

This report calls the right-hand process **the backend**. It is not the Flutter app,
and it is not the Emacs UI buffers. The backend is ~130 k lines of Emacs Lisp:

- `harness.el` (loader, update, verification), 1,915 lines, plus `lisp/*.el` core
  libraries, 16,207 lines.
- `lisp/modules/*.el`: 92 files, 91 modules, 111,804 lines.
- The user's Emacs UI is `lisp/ui/*.el`: 62 files, 55 modules, 80,946 lines.
  It is a client and stays a client in every option below.

Counts are from the tree at `f86bb0c` (2026-11-07), using `wc -l`,
`grep '(harness-define-module'`, and `grep '(harness-defmethod'`.

### 1.2 Sources read

- The binding module contract: [`docs/architecture.md`](../architecture.md)
  (16,737 lines), especially "Layers", "Processes", "The bus", "Which modules load",
  "Modules of your own", "Projects' plugins", and "Data shapes".
- The generated module pages: [`docs/modules/`](../modules/) (147 files: 146 module pages and an index), produced by
  `scripts/module-docs.sh` from the module sources via
  [`lisp/harness-module-docs.el`](../../lisp/harness-module-docs.el).
- The trust and security contracts: [`docs/trust-model.md`](../trust-model.md),
  [`docs/policy.md`](../policy.md), [`docs/secret-sandbox.md`](../secret-sandbox.md),
  [`docs/remote-auth.md`](../remote-auth.md).
- The prior performance investigation: task `t-xywzvi9m`
  (`task/speed-up-harness-connection-and-xywzvi9m`, commit `972b26e`), its report
  `docs/analysis/transcript-load-2026-11-07.md`, and its benchmark
  `scripts/analysis/bench-transcript-load.el` / `.sh` on that branch.
- The prior UI-thread investigations:
  [`docs/analysis/ui-thread-blocking-2026-10-22.md`](ui-thread-blocking-2026-10-22.md)
  and [`docs/analysis/ui-thread-blocking-2026-10-23.md`](ui-thread-blocking-2026-10-23.md).
- The clients: [`lisp/ui/harness-ui.el`](../../lisp/ui/harness-ui.el),
  [`harness_client/lib/src/acp/`](../../harness_client/lib/src/acp/),
  [`harness_client/lib/src/services/harness_api.dart`](../../harness_client/lib/src/services/harness_api.dart),
  [`harness_client/lib/src/acp/capabilities.dart`](../../harness_client/lib/src/acp/capabilities.dart).
- The server source named in each section.

### 1.3 Evidence classes

Every claim below is labelled, implicitly or explicitly, as one of:

- **Measured**: a number from a run, with the method in Appendix A.
- **Documented**: a design or contract statement in `docs/` or a module docstring.
- **Source-derived**: a count or a call path read from the source (for example,
  `harness-session--load-all` reads every `sessions/*.json`).
- **Assumed**: an expectation about Rust that has not been measured here.

The distinction matters because the question "would Rust fix the latency?" is
answered differently for each class.

---

## 2. What the backend is today

### 2.1 Lifecycle

`harness-start` ([`harness.el`](../../harness.el), `harness-start`) does this in the
user's Emacs:

1. Sets up the load path and loads the core files and core libraries.
2. Reads and applies the administrator policy (`harness-policy-load`,
   `harness-policy-apply`; [`lisp/harness-policy.el`](../../lisp/harness-policy.el)).
3. Loads every selected module on its side (the UI side loads `lisp/ui`; the server
   side loads `lisp/modules`).
4. With `harness-process` non-nil, disables the ACP server in the UI and spawns the
   child through `harness-server-spawn`.
5. Initialises modules, runs `harness-start-hook`, emits `harness/started`.

The child is an `emacs --batch -Q` process
([`lisp/harness-server.el`](../../lisp/harness-server.el), `harness-server--command`).
The parent writes a generated `server-config.el` containing every readable
`harness-` variable the user set, plus `auth-sources`, `exec-path`, selected TRAMP
options, and the directory-local trust variables
(`harness-server--forwarded`, `harness-server--write-config`). The child:

- reads `HARNESS_SERVER_CONFIG`, `HARNESS_SERVER_TOKEN`, `HARNESS_SERVER_PARENT`,
  `HARNESS_SERVER_HOST`, `HARNESS_SERVER_PORT`;
- installs `harness-server--guard` so an error in a process filter or sentinel is
  logged rather than killing the process;
- loads the config, sets its own module directories and ACP settings, requires
  `harness`, and runs `harness-start`;
- prints `HARNESS-ACP-ADDRESS host:port` on stderr and then runs
  `harness-server--event-loop`, which never returns.

The event loop is important:

- Batch Emacs runs timers only inside `accept-process-output`; a timer that a timer
  starts would otherwise wait for unrelated output. `harness-server--wait-time`
  computes the earliest timer and `harness-server--event-loop` never sleeps past it.
- Errors that escape a filter or sentinel are logged and, on a Lisp-nesting overflow,
  unwound to the loop rather than ending the process.
- SIGPIPE is ignored, and every write to a peer goes through `harness-process-send`,
  which queues a write behind one already in flight to the same process. This is what
  keeps a slow client from nesting `process-send-string` waits until
  `max-lisp-eval-depth` overflows.

The parent supervises the child ([`lisp/ui/harness-ui.el`](../../lisp/ui/harness-ui.el),
`harness-ui--ensure-server`, `harness-ui--on-current-server-exit`):

- requests made before the child listens are queued (`harness-ui--queue`);
- an unplanned exit restarts it with exponential backoff, up to five starts in a
  minute;
- `harness-restart` stops and restarts it, interrupting running turns; sessions and
  tasks persist and are recovered by `harness-resilience` / `harness-tasks`;
- `harness-reload` reloads both sides in place, keeping running sessions and buffers
  (`harness--reload`, `harness-server--reload`, ACP method `harness/reload`).

A standalone server is the same child without a parent:
`scripts/harness-server` sets `HARNESS_SERVER_HOST`/`PORT`/`TOKEN` and runs
`harness-server-main`; `HARNESS_SERVER_CONFIG` is a file of Emacs Lisp forms, not a
data file. This is a lifecycle contract, not an implementation detail: the UI learns
the address from stderr, the token from the spawn callback or the `acp-token` file, and
the child exits when its parent dies.

**Migration consequence:** a Rust backend must reproduce process spawn,
configuration generation, token delivery, address announcement, parent-death
supervision, SIGTERM flush, event-loop fairness, crash recovery, logging, and
`harness-reload` (or an agreed replacement). A sidecar behind the existing server
inherits all of that for free; a full rewrite must rebuild it.

### 2.2 The bus is the backend's API

The backend is not a set of HTTP routes. It is a **dynamic method registry** plus
events and filters ([`lisp/harness-core.el`](../../lisp/harness-core.el)):

- `harness-define-module` registers a module with `:requires`, `:init`, `:shutdown`.
- `harness-defmethod` defines `harness-method/NAME` and registers `NAME` in a hash
  table (`harness-register-method`).
- `harness-call` synchronously calls a registered method; `harness-call-async`
  wraps the result in a promise.
- `harness-on` subscribes a named function to an event; `harness-emit` announces one.
- `harness-add-filter` joins a synchronous or asynchronous filter chain; a handler
  gets a value and a `NEXT` continuation, and `:final` stops the chain.
- The module loader compiles and reloads modules in place; `:init` runs again on
  reload, and the contract requires idempotent initialisation.

ACP is a thin projection of that bus
([`lisp/modules/harness-acp.el`](../../lisp/modules/harness-acp.el)):

- Standard ACP methods (`initialize`, `authenticate`, `session/new`, `session/load`,
  `session/list`, `session/prompt`, `session/cancel`, `session/set_mode`,
  `session/set_model`) are mapped by hand with
  `harness-acp--define-standard`.
- Every bus method under an allowed prefix is callable as `_harness/NAME`
  (`harness-acp--extension-allowed-p`, `harness-acp--extension-methods`).
  The prefixes are in `harness-acp-extension-prefixes`; user modules add theirs to
  `harness-acp-extra-method-prefixes`.
- Bus events listed in `harness-acp--forwarded-events` (63 names; and user-added
  `harness-acp-extra-events`) are sent to clients as `_harness/event` notifications.
- `initialize` advertises the dynamic surface in `_harness.methods` and
  `_harness.events` (`harness-acp--define-standard "initialize"`), and the Flutter
  client gates every feature on those lists.

This is the single most important architectural fact for a rewrite: **the wire API is
whatever the loaded Lisp modules register.** It is not a fixed OpenAPI document that a
Rust implementation can generate from a schema. A server that loaded only the core
modules advertised **189 extension methods and 78 events** in our measurement (see
§5.2); across the shipped module and core sources the source defines **434 unique
methods** and **127 declared event names** (91 declared individually in modules, 33
from two declaration lists in `harness-agent` and `harness-session`, 3 in
`harness.el`). A Rust server that serves only a fixed subset is a different product
unless the missing methods are proxied back to Emacs.

### 2.3 State and persistence

The state layer is [`lisp/modules/harness-store.el`](../../lisp/modules/harness-store.el)
(`store/load`, `store/save`, `store/append`, `store/read-all`, `store/sqlite`) on top
of `harness-state-directory`. The main shapes
([`docs/architecture.md`](../architecture.md), "Data shapes"):

- `sessions/ID.json` — the session record (settings, status, usage, queue, pending
  requests, head, provider state, `ext`).
- `sessions/ID.nodes.jsonl` — append-only log of nodes (messages, thinking, tool
  calls, tool results, hints) and node updates.
- `sessions/ID.responses.jsonl`, `sessions/ID.request.jsonl` — what the provider was
  sent and returned, used by the replay module to preserve prompt caches.
- `tasks.json`, `task-stores.json` — the task board and its per-project stores.
- `usage.db` — SQLite usage rows (or `usage/records.jsonl` without SQLite).
- `search.db` — rebuildable SQLite FTS5 index of transcripts.
- `memory.db` — the truth for lasting memories, with FTS5 and optional vectors.
- `budgets.json`, `secret-sources.json`, `redactions.jsonl`,
  `worktree-locks.json`, `merged-worktrees.json`, `outputs/`, `insights/`, `pet/`,
  `acp-address`, `acp-token`, `acp-remote-sessions.eld`, `error-details.log`.

Two invariants matter for a migration:

- **Lazy transcripts.** `session/list` must not load node logs;
  `harness-session--load-all` reads only `sessions/*.json`, and nodes are loaded on
  demand (`harness-session--from-plist` leaves them on disk). Our 1,000-session
  start-up measurement shows the record-only load is cheap; loading 40 MB of provider
  state is not.
- **Single-writer atomicity.** Emacs is one thread, so a whole-file rewrite (a
  redaction of a node log) cannot interleave with an append from this process; files
  are replaced by rename. A multi-process Rust service must reproduce that
  serialization with locks or a single writer, or redaction can lose appends. This is
  a correctness boundary, not a performance detail.

### 2.4 Sessions and the turn loop

The session module ([`lisp/modules/harness-session.el`](../../lisp/modules/harness-session.el))
owns the session record, the node DAG, the queue, steering, pending requests, and
provider state. It provides 60 bus methods (the largest single surface). The agent
module ([`lisp/modules/harness-agent.el`](../../lisp/modules/harness-agent.el)) owns
the turn loop: prompt, stream, tool calls, steering, queue, stop filters, hosted vs
native provider loops. It is event-driven and never blocks.

The task layer ([`lisp/modules/harness-tasks.el`](../../lisp/modules/harness-tasks.el),
7,083 lines) turns a task into a session, schedules it per project with a limit and
priority, manages review, feedback, backlog refinement, worktrees, and the merge queue.
The merge module ([`lisp/modules/harness-merge.el`](../../lisp/modules/harness-merge.el))
uses `git merge-tree`/`commit-tree` and `git merge --ff-only`; the worktree module
([`lisp/modules/harness-worktree.el`](../../lisp/modules/harness-worktree.el)) wraps
`git worktree`. The supervisor module
([`lisp/modules/harness-supervisor.el`](../../lisp/modules/harness-supervisor.el))
adds a plan/step/worker layer with its own permission gates.

These modules are portable in principle — they are state machines over plists and
subprocesses — but they are also where the most intricate state lives: task
pre-emption, review rounds, merge bases, conflict resolution sessions, provider cache
semantics, recovery after restart. A Rust rewrite would have to port the behaviour and
the tests, not just the data shapes.

### 2.5 Permissions, sandbox, secrets, remote access

The permission layer ([`lisp/modules/harness-perms.el`](../../lisp/modules/harness-perms.el),
6,147 lines) is an asynchronous filter chain. The stages the shipped modules install,
in priority order:

```
 2 secret-sandbox  refuse a call reading or writing a secret's source
 3 secrets         refuse a write whose input holds a secret placeholder
 4 access          apply the session's access profile; fail closed
 5 access          request_escalation: the user alone answers
 5 dir-request     request_directory_access: the user alone answers
 6 away-request    set_non_interactive: the user alone answers
 6 session move    session_move: the user confirms every move
 8 read-only       deny what a supervising/read-only session may not use
 9 supervisor      refuse hand_in while a plan step is undone
10 jail            every path inside an allowed root
20 mode            ask / accept-edits / auto / yolo + standing rules
21 secret-sandbox  run_with_secret: the user answers every use
25 task write-up   keep a backlog write-up turn read-only
28 supervisor      approve plan calls when no user is there
30 auto            a cheap model judges the rest; denial -> user when present
40 non-interactive judge gave no verdict and nobody is there: deny
90 ask-user        the pending request the UI answers
```

The chain fails closed: a filter failure has a handler that denies. The user can
approve a denied call afterwards (`rerun_approved`), and the call runs unchanged.

The sandbox ([`lisp/modules/harness-sandbox.el`](../../lisp/modules/harness-sandbox.el))
is the actual boundary: `bwrap`, `systemd-run`, `mxc` on macOS, or OpenShell, wrapping
every model-started process with a computed mount profile
(`harness-tools-shell-sandbox-profile`). The permission mode is a prompt-level hint;
the kernel is the boundary ([`docs/trust-model.md`](../trust-model.md), "The boundary
is the kernel"). File tools are themselves an MCP server running in that sandbox
([`lisp/harness-mcp-fs.el`](../../lisp/harness-mcp-fs.el), started by
`harness-mcp-define-server` in
[`lisp/modules/harness-tools-fs.el`](../../lisp/modules/harness-tools-fs.el)).

Secrets ([`lisp/modules/harness-secrets.el`](../../lisp/modules/harness-secrets.el))
mask tool output and log text; redaction
([`lisp/modules/harness-redact.el`](../../lisp/modules/harness-redact.el), 3,138 lines)
removes a secret from node logs, records, search index, provider logs, and task
records. The redaction engine is one synchronous call; a large SQLite `VACUUM` blocks
the whole harness meanwhile (documented in `docs/modules/redact.md` and
`docs/modules/session-search.md`: "seconds to minutes").

Remote ACP ([`lisp/modules/harness-acp-remote.el`](../../lisp/modules/harness-acp-remote.el),
2,779 lines) implements WebSocket (RFC 6455) in Lisp, session secrets (`hs1_…`,
SHA-256), approval in Emacs, OIDC, and a plain HTTP 401 surface. It explicitly does
**not** encrypt: "The connection is not encrypted by this module: Emacs has no TLS
server. Serve it over a VPN such as Tailscale, or put a TLS proxy in front."

**Migration consequence:** permissions and sandbox are the highest-risk code to move,
and their measured latency contribution is not established. They should be the last
things considered for Rust, not the first. Remote transport is the opposite: it is
already a security/capability gap (no TLS, hand-rolled WebSocket), and it is a clean
place for a Rust edge.

### 2.6 Tools, MCP and providers

Tools are declared with `harness-define-tool`
([`lisp/modules/harness-tools.el`](../../lisp/modules/harness-tools.el)): name, label,
description, JSON schema, kind, path function, handler. Execution runs the permission
chain, the handler with a timeout, the output filters (secrets masking), the
context-bomb guard, and the result filters. There are **83 tool definitions** in the
source.

MCP ([`lisp/modules/harness-mcp.el`](../../lisp/modules/harness-mcp.el)) starts tool
servers in the session's sandbox and talks JSON-RPC over pipes. The file tools are an
Emacs batch worker; the `elisp` tool is another batch Emacs
([`lisp/harness-elisp.el`](../../lisp/harness-elisp.el)); the user's Emacs can be lent
as an external MCP server through `_harness/emacs/mcp`
([`lisp/harness-emacs-endpoint.el`](../../lisp/harness-emacs-endpoint.el)).

Providers ([`lisp/modules/harness-provider.el`](../../lisp/modules/harness-provider.el))
are registered functions: `:models`, `:complete`, `:fork`, `:quota`, `:warm`,
`:close`, `:resolve`, `:embed`, `:capabilities`, `:tiers`. There are 10 provider
files (the registry plus Claude Code CLI, Copilot CLI, OpenAI-compatible, Responses,
Bedrock, DeepSeek, demo, gremlin and check), 17,873 lines. HTTP is a curl subprocess with an SSE
parser ([`lisp/harness-http.el`](../../lisp/harness-http.el)); it never blocks the main
thread, but every chunk is parsed in Lisp.

**Migration consequence:** a Rust provider runtime is feasible (HTTP/SSE is a natural
Rust fit), but the provider contract is dynamic and user providers can be Lisp. A
sidecar could serve built-in providers while leaving the contract intact; a full
rewrite would need a plugin ABI for providers.

### 2.7 Editor integration: what the backend asks the user's Emacs to do

The server never evaluates model-written Lisp in the user's Emacs. The boundary is a
fixed MCP vocabulary ([`lisp/harness-emacs-endpoint.el`](../../lisp/harness-emacs-endpoint.el)):
`buffers`, `windows`, `buffer`, `open`, `insert`, `save`, `describe`, `definition`,
`trace`, `messages`, `snapshot`. None carries code. The `elisp` tool evaluates in a
background batch Emacs, in the sandbox; with `snapshot`, that child starts from a copy
of the user's variables and buffers, taken in slices and with credentials withheld
([`lisp/harness-snapshot.el`](../../lisp/harness-snapshot.el)).

The server also asks the UI for chores: desktop notifications and saving a user
option to `custom-file` through `client/request`
([`lisp/harness-notifications-desktop.el`](../../lisp/harness-notifications-desktop.el)),
and reverting a buffer after a tool writes its file through the Emacs endpoint
(`harness-emacs-endpoint-revert-visiting`). The UI lends its Emacs in `initialize` via
`harness-emacs-endpoint-client-capabilities`.

**Migration consequence:** a Rust server can still speak `_harness/emacs/mcp` and
spawn batch Emacs for `elisp`; it does not need Emacs internals. But it must implement
the MCP host, the fixed vocabulary client, snapshot reassembly, and the client/request
chores. That is real work, and it is only worth doing if the core moves.

### 2.8 Clients

**Emacs UI.** 55 modules, 80,946 lines. It connects with
`harness-acp-connect`: a local connection dispatches Lisp objects directly into the
server with no JSON, and a TCP connection speaks the wire protocol
([`lisp/modules/harness-acp.el`](../../lisp/modules/harness-acp.el),
`harness-acp-connect`, `harness-acp--conn-send`). After `initialize` it immediately
refreshes sessions, models, quotas, rates, quota rates and live usage
(`harness-ui--open` in [`lisp/ui/harness-ui.el`](../../lisp/ui/harness-ui.el)). It
handles `session/update` (`_harness/session`, `_harness/session_deleted`),
`session/request_permission`, `_harness/ask_user`, `_harness/client/customize-save`,
`_harness/client/notify`, and `_harness/event`.

**Flutter app.** 110 Dart files, 43,975 lines; 101 test files, 1,132
`test`/`testWidgets` cases. It speaks ACP over TCP or WebSocket
([`harness_client/lib/src/acp/transport_io.dart`](../../harness_client/lib/src/acp/transport_io.dart),
[`websocket_transport.dart`](../../harness_client/lib/src/acp/websocket_transport.dart));
it reads `_harness.methods` and `_harness.events` and gates every feature on them
([`capabilities.dart`](../../harness_client/lib/src/acp/capabilities.dart)). This is a
major compatibility asset: a partial server can still be used, one panel at a time.

**ACP-native editors.** `scripts/harness-acp-stdio` bridges stdio to the ACP TCP
server and authenticates with the token file, so any ACP client that spawns an agent
can use the harness.

---

## 3. What Emacs actually owns

The useful question is not "how many lines are in Lisp?" but "which responsibilities
cannot leave Emacs without changing the product?" The table below separates them.

| Responsibility | Where it lives | Can a Rust backend own it? | What remains in Emacs |
|---|---|---|---|
| Rendering, keymaps, faces, windows, minibuffer, completion, images, media | `lisp/ui/*.el` (80,946 lines, 55 modules) | No; this is the editor UI | All of it |
| Editor endpoint: buffers, windows, insert/save, describe/definition/trace, messages | `lisp/harness-emacs-endpoint.el` | No; it is the user's Emacs | All of it |
| Emacs snapshot for the `elisp` tool | `lisp/harness-snapshot.el` | Only the transport; the copy is made in Emacs | The copy and credentials policy |
| `elisp` evaluation | `lisp/harness-elisp.el` | Rust can spawn `emacs --batch`; cannot replace Emacs Lisp | The Emacs runtime and sandbox wrapper |
| Customize options, `:safe`, `:type`, dir-locals layering | `lisp/modules/*.el` (300 server `defcustom`s), `lisp/ui/*.el` (96), layer logic in `harness-config.el` | Only with a new config schema and migration | Customize, dir-locals, `:safe` semantics |
| Administrator policy (`/etc/harness/policy.el`) | `lisp/harness-policy.el` | Data is readable; enforcement uses Emacs `custom-set`, watchers, `ignored-local-variables` | Policy application and trust |
| Project plugins (`.dir-locals.el` `eval`) | `lisp/modules/harness-plugins.el` | No; it is Emacs Lisp loaded with Emacs's trust | Plugin loading and scoping |
| Module system, methods, events, filters, hooks, reload | `lisp/harness-core.el`; `harness.el` | Only as a fixed Rust API or an RPC bridge | Dynamic registration, reload |
| Session/turn/task/merge state machines | `lisp/modules/harness-session.el`, `harness-agent.el`, `harness-tasks.el`, ... | Yes, in principle | The tests and the contracts |
| Permissions, sandbox, secrets, redaction | `lisp/modules/harness-perms.el`, `harness-sandbox.el`, `harness-secrets.el`, `harness-redact.el` | Yes, but high risk; the kernel is the boundary | The prompts, policy, trust |
| Provider adapters and HTTP/SSE | `lisp/modules/harness-provider*.el`, `lisp/harness-http.el` | Yes, for built-ins; user providers are Lisp | The dynamic provider registry |
| Process lifecycle, spawn, restart, reload, update | `harness.el`, `lisp/harness-server.el`, `lisp/ui/harness-ui.el` | Yes, but must reproduce the contract | The UI supervisor and config generation |
| Local in-process mode (`harness-process nil`) | `harness-acp-connect` local path | No | The whole in-process harness |
| TRAMP remote files and `auth-source` credentials | `harness-util`, tools, server config forwarding | Only by replacing remote semantics | TRAMP/auth-source |

The last two rows are easy to miss:

- `harness-process nil` is a supported mode for tests and debugging. The local ACP
  connection dispatches Lisp objects directly, with no JSON
  (`harness-acp--server-receive`). A Rust backend cannot be "in this Emacs"; local
  mode either stays on the Emacs implementation or becomes a TCP connection with a
  different latency and failure model.
- Remote file access is Emacs TRAMP. The server forwards the user's TRAMP settings
  (`harness-server--tramp-variables`) and uses TRAMP names everywhere: permission
  paths, file tools, ssh, worktrees. A Rust backend would need an equivalent remote
  layer, or keep an Emacs worker for remote paths. This is a large hidden dependency.

A concise way to put it: **the backend is an Emacs program that happens to have a
socket, not a web service that happens to have an editor client.** By my estimate
(not a measurement), roughly 60% of the server lines are portable orchestration; the
remaining 40% is either Emacs-specific (config, plugins, endpoint, elisp, TRAMP,
local mode, reload) or security-critical logic whose port would be a
reimplementation, not a translation.

---

## 4. Extension, configuration, plugin and dynamic-Lisp inventory

This is the part a language comparison usually omits. The harness is designed to be
extended by users in Emacs Lisp, at runtime, without rebuilding anything.

### 4.1 What can be extended

| Mechanism | Current surface | Where | What a Rust core would have to do |
|---|---|---|---|
| Modules | 146 (91 server, 55 UI) | `harness-define-module` | Provide an equivalent module lifecycle, or keep Emacs as host |
| Bus methods | 434 unique registered; 189 advertised by a core-only server | `harness-defmethod`, `harness-register-method` | Dynamic dispatch by symbol, or a bridge |
| Events | 127 declared names (63 forwarded verbatim; 78 advertised by a core-only server) | `harness-declare-event`, `harness-emit`, `harness-on` | Pub/sub with the same names and payloads |
| Filter chains | 23 distinct chains joined in the source | `harness-add-filter`, `harness-run-filter*` | Ordered, async, fail-closed chains |
| Tools | 83 definitions | `harness-define-tool` | Tool registry, schemas, permission pipeline |
| Providers | 10 provider files (9 adapters + registry) | `harness-define-provider` | Provider registry with dynamic functions |
| Options | 300 server `defcustom`s, 96 UI | `defcustom` + `harness-config-keys` | Typed config schema and migration |
| UI hooks | 30 `harness-*` hook variables | `add-hook`, `run-hooks` | UI-side only; no change if UI stays |
| ACP extension prefixes/events | `harness-acp-extra-method-prefixes`, `harness-acp-extra-events` | user modules/plugins | Dynamic method allowlist |

The method and event counts are lower bounds: modules can register methods at runtime
(e.g. `harness-register-method`), and a plugin can add a prefix. The ACP surface is
computed at `initialize` time from whatever is loaded.

### 4.2 Three concrete extension paths

**(a) A user module outside the tree.** `harness-extra-module-directories` points at a
directory of `harness-NAME.el` files. The module can define a method, a tool, an
event, an option, and a UI half; the UI half calls `_harness/hello/greet` and hears
`hello/greeted` ([`docs/architecture.md`](../architecture.md), "Modules of your own",
has a complete `hello/greet` example). The module's options are forwarded to the
server, its file is compiled and reloaded, and its methods are callable over ACP.
A Rust core cannot load that file; it could only call an Emacs subprocess that did.

**(b) A project plugin.** `.dir-locals.el` contains an `eval` entry that `require`s the
plugin and a `harness-plugin-modules` list. The server applies the project's
directory-local variables with Emacs's own
`hack-dir-local-variables-non-file-buffer`, taking only what the user already trusts
(`harness-plugins--apply`). Each session freezes its plugin list in `:ext`
(`harness-plugins--freeze`), and a plugin's tools are visible only to sessions whose
list names its module. The repository's own workflow depends on this: its
[`.dir-locals.el`](../../.dir-locals.el) loads
`.harness/plugins/dev/harness-dev-plugin.el`, which defines `open_harness`, the task
board's Open harness action, and the `client-check` hand-in check for the Flutter app.
A full rewrite that drops plugins would break the harness's own development loop.

**(c) A dynamic provider/tool.** `harness-define-provider` and `harness-define-tool`
are ordinary macros that register functions. A user can define a provider in a module
and have `provider/models`/`provider/complete` see it; a tool can call other bus
methods from its handler. None of this is visible to a static Rust binary without an
RPC bridge.

### 4.3 Configuration and policy

`harness-config-keys` names 12 settings that participate in layering; the others are
global. `config/describe` lists every option, its layer, its type, and whether policy
locks it (`lisp/modules/harness-config.el`). The policy file
(`/etc/harness/policy.el`) is a data alist, read but never evaluated
(`harness-policy-load`); applying it sets each option's default, replaces its
`custom-set` function, adds a variable watcher that refuses `setq`, and adds it to
`ignored-local-variables` (`harness-policy--guard`). A Rust server would need a
configuration model with the same types, defaults, layering, and lock semantics, plus
a migration for users' existing `custom-file` and `.dir-locals.el` values. That is a
product migration, not a serialization task.

### 4.4 Reload, updates, and why they matter

`harness-reload` checks every source file, refuses to load anything if one fails,
then loads all files again in place. It keeps running sessions and buffers; module
`:init` functions run again so new subscribers and filters take effect; functions a
file no longer defines are unbound (`harness--reload-snapshot`). The self-update path
(`harness-update`) fetches, verifies the commit by byte-compiling every source in a
batch Emacs, fast-forwards, and reloads (`harness--verify-commit`,
`harness--update-checkout`, `harness--updated`).

The prior performance task measured the verification step at **10,779.8 ms** for a
local update, against 63.5 ms of git work. That cost is not the server's request path,
but it is part of the development loop and the update experience. A Rust backend could
remove the server-side byte-compile, but the Emacs UI's 81 k lines still have to be
compiled and reloaded. It also introduces a second update mechanism for a native
binary. Neither is a reason to rewrite; both are reasons to be careful.

**Migration matrix for extensions:**

| Option | User modules | Project plugins | Options/policy/dir-locals | Hot reload | Local mode |
|---|---|---|---|---|---|
| Sidecar | Preserved (Emacs still loads them) | Preserved | Preserved | Preserved | Preserved |
| Hybrid (Rust control plane) | Only if an Emacs plugin host remains | Only with a host + scope bridge | Needs a config service or host | Broken unless reload is reimplemented | Broken |
| Staged extraction | Preserved per stage if Emacs remains the host for that stage | Preserved | Preserved | Preserved until the core moves | Preserved until the core moves |
| Full rewrite | Lost or requires an Emacs sidecar/host | Lost or requires a host | Reimplemented/migrated | Lost (restart) | Lost |

This matrix is why "hybrid" is not a free intermediate: it either keeps an Emacs
plugin/config host (becoming a more complex staged extraction) or gives up the
extensibility that makes the harness what it is.

---

## 5. Performance: measured costs and what they do and do not say

### 5.1 The prior task's measurements

Task `t-xywzvi9m` investigated slow connection and transcript loading in both clients.
Its report (`docs/analysis/transcript-load-2026-11-07.md` on
`task/speed-up-harness-connection-and-xywzvi9m`, commit `972b26e`) and the live
measurements it recorded give:

**Live sample (busy machine, one local authenticated bridge):**

| Stage | Value |
|---|---:|
| connect / auth / initialize | 1,624 ms |
| `task/list` after that | 443 ms |
| five fresh connections: TCP | 0.98, 0.17, 0.17, 0.19, 0.17 ms |
| five fresh connections: auth reply | 4,321.29, 805.67, 108.09, 0.16, 85.71 ms |
| five fresh connections: initialize | 246.27, 14.32, 3.64, 1.87, 2.09 ms |
| five fresh connections: `session/get` | 228.87, 10.94, 0.42, 0.49, 40.80 ms |

The task's live notes concluded that TCP is consistently fast and the time until the
auth reply is variable; they explicitly warned not to assume authentication
computation is the cause: "server event-loop scheduling or work may dominate."

**Synthetic, aggregate (no private transcript content):**

| Measurement | Before | After the task's fix |
|---|---:|---:|
| 200 sessions × 40 KB provider state, full `session/list` | 8,542,601 bytes | 524,601 bytes (lean) |
| build + encode, median | 21.44 ms (full) | 17.61 ms (lean) |
| 400 nodes × ~5 KB replay: updates | 800 | 400 (nodes only) |
| replay bytes | 3,731,646 | 1,672,090 |
| build updates, median | 0.82 ms | 0.09 ms |
| Emacs chat render, 400 nodes × 5 KB | 222.22 ms | 177.46 ms |
| Emacs chat render, 1,200 nodes × 5 KB | 606.83 ms | 470.92 ms |
| Flutter 1,200 nodes: JSON decode | — | 35.91 ms |
| Flutter 1,200 nodes: apply | — | 20.20 ms |
| Flutter 1,200 nodes: displayed order | — | 2.76 ms first, 0.000 ms repeated |
| update git work | — | 63.47 ms |
| update verify (byte-compile every source in a batch Emacs) | — | 10,779.80 ms |

The task's fixes, in source terms:

- A `_lean` filter on `session/list` that omits `:provider-state`, `:provider-node`,
  `:allowed-dirs` and `:move` (`lisp/modules/harness-session.el` on that branch); both
  clients ask for it.
- `session/load` with `_harness.replay: "nodes"` sends one `_harness/node` update per
  node instead of a chunk plus the whole node (`lisp/modules/harness-acp.el`).
- Flutter opens a session with one `session/load`, not a load + `session/get` +
  `session/nodes`, and memoises `TranscriptState.displayItems`
  (`harness_client/lib/src/state/session_controller.dart`,
  `models/transcript.dart`).
- Emacs chat scans hyphens instead of a UUID regexp when finding session ids
  (`lisp/ui/harness-ui.el`).
- The update page records stages (`fetching`, `checking`, `installing`, `reloading`)
  and redraws once a second while running (`harness.el`, `lisp/ui/harness-ui-version.el`).

The task's own limits are important: the live numbers are samples from a busy
machine, the synthetic transcripts are one shape, and Flutter widget-build timings in
the test environment were not representative and were not quoted.

### 5.2 Independent measurements for this report

To distinguish "server language" from "payload" and "client", I ran a throwaway
standalone server against synthetic state directories in this session's temporary
directory. No live harness was restarted, no real transcript was read, and no user
data was used. The method is in Appendix A.

**Startup (time from process launch to the `HARNESS-ACP-ADDRESS` line, `nice 19`,
`ionice 3`, warm byte-code cache unless noted):**

| State | Warm start |
|---|---:|
| no sessions | 360–366 ms |
| 5 sessions | 361–364 ms |
| 100 sessions | 366–368 ms |
| 500 sessions | 409–430 ms |
| 1,000 minimal sessions | 477–504 ms |
| 1,000 sessions × 40 KB provider state | 656–1,005 ms |
| first start, fresh state, byte-compiling the server | 3,021 ms |

The first start's state directory grew to 3.7 MB of `.elc` files. Warm starts reuse
it. At 1,000 × 40 KB the Emacs process reached **154,664 KB RSS** (VmHWM), against
**97,428 KB** with no sessions and **99,540 KB** with 1,000 minimal records; user CPU
was 0.35–0.55 s at 100 Hz.

**`session/list` over the real ACP wire (1 MB client reads, JSON parsed after the
last byte):**

| State | Receive | Parse | Bytes |
|---|---:|---:|---:|
| 200 sessions, no provider state | 3.4–3.9 ms | 1.3 ms | 153,526 |
| 200 sessions × 40 KB | 22.1–22.6 ms | 9.9–10.1 ms | 8,153,526 |
| 1,000 sessions, no provider state | 18.9–38.8 ms | 6.6–7.6 ms | 767,926 |
| 1,000 sessions × 40 KB | 270.4–304.6 ms | 51.8–52.6 ms | 40,767,926 |

**The same `session/list` broken into server-side stages in a batch Emacs, same
state:**

| State | Build plists | ACP normalise | JSON encode | Bytes |
|---|---:|---:|---:|---:|
| 200 × 40 KB | 0.65 ms | 0.57 ms | 21.03 ms | 8,153,491 |
| 1,000 minimal | 3.05 ms | 2.89 ms | 46.71 ms | 767,891 |
| 1,000 × 40 KB | 3.47 ms | 3.13 ms | 82.44 ms | 40,767,891 |

**Idle ACP control path:** with the 1,000 × 40 KB state, a fresh connection's
`initialize` took 0.8–1.6 ms and `authenticate` 0.1 ms; `session/get` of one 40 KB
record took 0.5–0.7 ms; `session/nodes` of an empty log took 0.1–0.3 ms. The same
`initialize` advertised **189 extension methods and 78 events** for the modules that
server loaded (the core set; a full user module set declares more).

These numbers say several things at once:

1. **The wire cost is the payload, not the session count.** 1,000 sessions without
   provider state are 0.77 MB and ~19 ms; the same 1,000 with 40 KB each are 40.8 MB
   and ~270–305 ms. `session/get` for one 40 KB record is under a millisecond. The
   cost scales with bytes sent, not with the number of session records.
2. **Server-side Lisp is not the dominant cost for a lean listing.** Building the
   plists is 3 ms; normalising is 3 ms; encoding 0.77 MB is 47 ms. Encoding 40.8 MB is
   82 ms. The ~190 ms difference between the 40.8 MB encode (82 ms) and the 40.8 MB
   wire receive (270–305 ms) is transport/backpressure and client receive, not Lisp
   serialization.
3. **Idle auth is not slow.** ACP `authenticate` with the shared secret is a
   constant-time string comparison (`harness-instance-equal-p`), not a key
   derivation; one comparison cannot take seconds. The live 4.3 s auth sample is
   most plausibly a busy server or event loop, not auth computation. Rust would not
   fix it by making the comparison faster; it would only help if the server's
   scheduling and long handlers changed.
4. **Start-up is sub-second in steady state; the first start after an update is
   seconds.** That is byte-compilation of Lisp, which a native binary avoids. But the
   UI's Lisp still compiles, and the cold start happens once per update, not per
   connection.
5. **Memory is modest but grows with provider state.** 97 MB baseline, 155 MB at
   1,000 × 40 KB. Rust would reduce this, but memory was not a reported symptom and is
   not a reason by itself.

### 5.3 What the numbers mean for "would Rust fix it?"

| Cost | Measured / documented | Does Rust help? | Better first lever |
|---|---|---|---|
| 40 MB `session/list` | 8 MB/22 ms at 200; 40.8 MB/270–305 ms at 1,000 | Some: faster serde/transport, maybe 2–5× on the CPU/send part | **Lean listing** (95%+ bytes removed) — already designed |
| Session load from disk | 1,000 records + 40 KB state: 0.66–1.0 s start-up | Some: faster JSON parse/startup | Lean/lazy provider state; instrument |
| Cold start after update | 3.0 s first compile; 0.36 s warm | Yes: no Lisp byte-compile | Keep the update verify step only while Lisp exists |
| Auth handshake | 0.1 ms idle; 0.16–4,321 ms live | No: the work is a constant-time compare; the delay is scheduling/load | Do not block the event loop; measure handlers |
| Emacs chat render | 177–471 ms for 400–1,200 nodes | No | Emacs renderer work (the task's scan fix is one part) |
| Flutter decode/apply/order | 35.9 + 20.2 + 2.8 ms for 1,200 nodes | No | Client-side; already memoised |
| UI redraw/freeze | 240 ms batch redraw; 1.6 s live stalls (prior docs) | No | UI visibility/memoisation (already fixed in `lisp/ui`) |
| Update verify | 10.8 s | Partly: removes server Lisp compile, not UI Lisp | Larger update architecture, not a rewrite |
| SQLite VACUUM/redaction | "seconds to minutes" while the harness does nothing | Yes: a separate process can vacuum while Emacs serves | Rust SQLite worker |
| Remote ACP | Hand-rolled WebSocket, no TLS | Yes: Rust TLS/WebSocket/backpressure is a natural fit | Rust ACP edge |

The table is the core of the answer: **the two strongest Rust cases are not the
reported connection/transcript symptom; they are remote transport and blocking SQLite
work.** The reported symptom is addressed first by payload and client changes.

### 5.4 Assumed benefits that are not established here

These are plausible but unmeasured, and should not be used to justify a rewrite:

- "Rust eliminates GC pauses in the server." The prior UI investigations measured
  heavy GC in the **UI** (for example 145 ms collections against a ~300 MB heap in
  `ui-thread-blocking-2026-10-23.md`). The server's GC behaviour under a real
  workload has not been profiled here. A Rust backend would not remove UI GC, which is
  where the freezes were measured.
- "Rust makes concurrent sessions faster." The Emacs event loop is already
  asynchronous and interleaves sessions; the limit is long synchronous handlers, not
  the number of sessions. A sidecar/worker can remove those without moving the
  session state machine.
- "Rust improves security." Emacs Lisp is garbage-collected and has no raw pointers,
  so the raw-memory bug class is largely absent already. Rust would not address the
  bug classes that matter here: authorization logic, path and shell parsing, sandbox
  profile construction, secret handling, and remote authentication — all of which a
  rewrite would have to reimplement, with new bugs. Rust's type system helps; it is
  not a security proof.
- "Rust reduces memory." Likely, but memory was not a reported problem; 155 MB at
  1,000 large sessions is not a crisis.
- "Rust makes the backend easier to maintain." The backend is 130 k lines of Lisp
  with a 16.7 k-line binding contract and 6,198 tests. A Rust rewrite starts that
  maintenance cost over, plus a bridge to Emacs for the parts that cannot move.

### 5.5 Unknowns and the measurements that would settle them

The following are the most useful missing numbers. They should be collected before any
migration stage is funded.

1. **Real cold-start breakdown.** Time from spawn to address for a real user's state,
   split into: process start, core/library load/compile, module load, each module's
   `:init`, `harness-session--load-all` (count and bytes), provider/model listing,
   sandbox detection, ACP listen, first request. Our total is 0.36–3.0 s; the split is
   unknown.
2. **Event-loop lag and handler occupancy.** For each method: handler time, encode
   time, write time, queue wait. Histograms, not averages. This would explain the live
   auth outliers and show whether `session/list`, provider listing, or redaction is
   the blocker.
3. **Server GC and heap.** `gcs-done`, `gc-elapsed`, heap size, and pause distribution
   on a real 1,000-session state with running turns. The UI GC was measured; the
   server was not.
4. **Client-perceived time to interactive.** Time from click/connect to first
   transcript row and to last row visible, separately for Emacs and Flutter, with
   real node counts. Server response time is not the user's wait.
5. **Provider/model listing cost.** `provider/models` and `provider/quota` can invoke
   a CLI or network; measure them on connect. The UI fires six refreshes immediately
   after `initialize` (`harness-ui--open`), and the live "connection" delay may be
   dominated by these, not by `session/list`.
6. **SQLite blocking.** Time of `session/search-purge`, `session/search-rebuild`,
   memory consolidation, and redaction on a realistic 100 MB+ `search.db`, including
   the VACUUM and WAL checkpoint.
7. **Tool and MCP start-up.** Time to start the `fs` and `elisp` workers, and the
   per-call overhead of the sandbox/MCP pipe. This decides whether a Rust worker is
   worth it.
8. **Flutter device profile.** Widget-build and scroll timings on a mid-range phone,
   not the test environment. The prior task explicitly did not quote these.
9. **Usage of extension points.** How many users actually use
   `harness-extra-module-directories`, project plugins, custom providers/tools, local
   mode, or remote ACP. This sets the compatibility bar for any option.

A minimal instrumentation plan (Stage 0) is:

- In `harness-server-main` / `harness-start`, log monotonic timestamps at each phase:
  config load, core load, library load, each module load and `:init`, session load
  (count and bytes), provider listing, sandbox detect, ACP listen.
- In `harness-acp--handle-request`, record per-method start/end, handler time, encode
  bytes/time, write time, and queue wait; emit a histogram every N requests or on
  demand.
- In `harness-server--event-loop`, record the actual wait, the due-timer delay, and
  the inbox slice duration; count slices that exceed the 50 ms budget.
- In `harness-session`, record `gcs-done`/`gc-elapsed` and heap size at start and at
  each N sessions; log the time of `harness-session--load-all`.
- In `harness-session-search`, time each `session/search-*` call and each VACUUM.
- In the clients, record first-row/last-row visible times, not just request times.

None of this changes behaviour, and all of it is useful even if no Rust is ever
written.

---

## 6. Options compared

### 6.1 Option A — Sidecar

A Rust process beside the unchanged Emacs backend, owning one leaf job:

- **ACP edge**: TLS/WebSocket reverse proxy, one upstream ACP connection per
  downstream client, forwarding bytes after the handshake; no method semantics, no
  auth duplication.
- **SQLite worker**: owns `search.db` (rebuildable cache), serves search/index/purge/
  rebuild, possibly memory search; Emacs keeps the session/turn logic.
- **Provider/HTTP worker**: built-in providers stream over a local JSON-lines socket;
  Lisp provider contract remains for user providers.
- **Transcript service**: node log read/write/redaction; the most invasive sidecar.

**Preserves:** ACP wire, Emacs UI, Flutter, plugins, config/policy, hot reload, local
mode, Emacs endpoint, security chain.

**Risks:** a second process to supervise; IPC authentication and secret handling;
duplicate state if the sidecar owns data; version skew; packaging; a new failure mode.
The sidecar must not be reachable by other local users, and must not become a bypass
around the permission chain or sandbox.

**Effort:** 2–8 weeks for the ACP edge; 3–6 months for a SQLite/search worker;
4–8 months for a transcript service.

**Verdict:** the lowest-risk way to get real Rust benefits. Recommended for the ACP
edge and, if measured, the SQLite worker.

### 6.2 Option B — Hybrid (Rust control plane, Emacs workers)

Rust owns the ACP server, session/transcript store and maybe the task scheduler; Emacs
becomes a worker for tools, permissions, providers and editor integration. This is the
mirror image of today's split.

**Why it is attractive:** it gives Rust the long-lived state and transport, which is
where async/concurrency and memory layout help most.

**Why it is hard:**

- The bus is the API. A Rust control plane would need a dynamic method/event/filter
  registry, or a bridge that forwards unknown methods to Emacs. Once it forwards, the
  session state is split across two runtimes.
- Plugins and user modules run in Emacs and call bus methods; a Rust core must let
  them register methods/events/tools and see them in the same namespace. That is an
  RPC plugin ABI, not a port.
- Hot reload, local mode, `client/request` chores, and the Emacs endpoint all assume
  an Emacs process on the other end. They can be kept, but then the "hybrid" is a
  staged extraction with a permanent Emacs worker, not a simpler architecture.
- Consistency: a session append and the transcript index must agree; a redaction and
  a running turn must not interleave; a task merge and a session status change must be
  atomic enough for recovery. Two writers make this harder.

**Effort:** 18–30 months for a small team, with a permanent bridge and a permanent
dual test matrix.

**Verdict:** not now. It is only sensible after staged extraction proves which state
must move and a plugin/config/hot-reload strategy is designed and accepted.

### 6.3 Option C — Staged extraction (strangler)

Define a stable seam, move one subsystem at a time behind it, and keep the old path as
a fallback until the new one passes parity:

0. Instrument and fix in Lisp.
1. Rust ACP edge (TLS/WebSocket proxy).
2. Rust SQLite/search/redaction worker.
3. Rust transcript service (only if measured).
4. Rust tool/provider workers (only if measured).
5. Core session/turn scheduler (only if the first stages prove it is the bottleneck).

Each stage is shippable, reversible, and has its own stop/go gate. The ACP wire does
not change; clients do not change; plugins/config/hot reload remain until (and unless)
the core moves.

**Effort:** 2–4 weeks for Stage 0; 4–8 weeks for Stage 1; 3–6 months for Stage 2;
4–8 months for Stage 3; 24–48 months to reach the core if every gate passes.

**Verdict:** the recommended framework. It is also the only option that can stop
early without having paid for a rewrite.

### 6.4 Option D — Full rewrite

A Rust backend that implements ACP, the bus, sessions, tasks, merge/worktree,
permissions, sandbox, providers, tools, MCP, config, plugins, remote ACP, and the
Emacs endpoint bridge; Emacs keeps the UI and perhaps a plugin/config host.

**What it must reimplement or replace:**

- 434 bus methods, 189 advertised extension methods, 127 declared event names
  (78 advertised by a core-only server), at least 248 distinct client-used method
  names, 83 tools, 23 filter chains, 146 modules.
- 300 server options with types/safe predicates/layering and a policy format whose
  enforcement uses Emacs customization.
- Plugins and user modules, or an explicit decision to drop them.
- Hot reload and the self-update verification/reload loop.
- Local in-process mode, or an explicit decision to drop it.
- The Emacs endpoint, snapshot and `elisp` worker bridge, or an explicit Emacs
  subprocess.
- Permissions, sandbox profiles, secrets, redaction, instance auth, MCP auth, remote
  auth — the security-critical core.
- State migration and dual-running/rollback for existing users.
- Packaging and update for a native binary on Linux/macOS (and any other platform).

**Effort:** order of **3–6 engineer-years** for functional parity, plus 6–12 months of
stabilization; high uncertainty (±50%). Calendar: 1.5–3 years with 3–4 engineers
working on it as a program, not as a task. The existing 6,198 tests and 16.7 k-line
contract are an asset for verification, but they do not write the Rust code.

**Verdict:** reject now. It is not justified by the measured latency, and it gives up
the extension model, hot reload, local mode, and the Emacs-native development loop
that the project relies on.

### 6.5 Comparison

| Criterion | A Sidecar | B Hybrid | C Staged | D Full rewrite |
|---|---|---|---|---|
| Fixes measured connection/transcript cost | Partly (transport) | Potentially | Yes, stage by stage | Potentially |
| Keeps ACP wire | Yes | Yes, if proxied | Yes | Must reimplement |
| Keeps Emacs UI working | Yes | Yes | Yes | Yes (UI stays) |
| Keeps Flutter working | Yes | Yes | Yes | Must reimplement exact shapes |
| Keeps plugins/user modules | Yes | Only with a host | Yes until core moves | No, unless a host |
| Keeps config/dir-locals/policy | Yes | Only with a host | Yes until core moves | No, unless a host |
| Keeps hot reload/local mode | Yes | No | Yes until core moves | No |
| Security reimplementation | None | Partial | Only for moved parts | Yes, all of it |
| Operational complexity | +1 process | +2 runtimes | +1 per stage | +1 binary, -1 Emacs server |
| Reversibility | High | Medium | High per stage | Low |
| Effort | Weeks–months | 18–30 months | 2–4 years to core | 3–6 engineer-years |
| Recommendation | **Yes, targeted** | No | **Yes, framework** | **No** |

---

## 7. Compatibility boundaries in detail

A migration is only as safe as its boundaries. These are the contracts that must not
change silently, with the test oracle that can prove they did not.

### 7.1 ACP wire and extension methods

**Must hold:**

- JSON-RPC 2.0, one message per line over TCP; WebSocket framing for remote clients.
- Standard ACP v1 methods and their result shapes:
  `initialize`, `authenticate`, `session/new`, `session/load`, `session/list`,
  `session/prompt`, `session/cancel`, `session/set_mode`, `session/set_model`.
- `initialize` result: `protocolVersion`, `agentCapabilities` (`loadSession`,
  `promptCapabilities`, `sessionCapabilities.list`), `agentInfo`, `authMethods`,
  `_harness.methods`, `_harness.events`.
- `_harness/NAME` for every allowed bus method; exact parameter names, plist/JSON
  shapes, error codes, and `:false`/`:empty` conventions.
- `session/update` notification kinds: `user_message_chunk`, `agent_message_chunk`,
  `agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan`,
  `current_mode_update`, `_harness/session`, `_harness/node`, `_harness/hint`,
  `_harness/activity`.
- Agent-to-client requests: `session/request_permission`, `_harness/ask_user`,
  `_harness/client/customize-save`, `_harness/client/notify`, `_harness/emacs/mcp`.
- Auth: local ACP token, loopback rule, remote session secrets, approval, OIDC,
  `auth_required` (-32000), corporate mode refusal.
- Backpressure and replay ordering: a session loaded by a slow client holds its
  live updates until the replay is done; writes to one client queue behind one
  another (`harness-process-send`).

**Oracle:** the existing Emacs UI and Flutter app are the best conformance clients.
Run both against the candidate server, plus the existing ACP tests
(`test/harness-acp-test.el`, `test/harness-acp-tcp-test.el`,
`test/harness-acp-remote-test.el`, `test/harness-acp-client-test.el`) and the Flutter
tests. Record and replay real ACP traffic with synthetic sessions (no private
content) to catch shape drift.

### 7.2 State files and atomicity

**Must hold:**

- Directory layout and file names under `harness-state-directory`.
- JSON/JSONL encoding, plist conventions, `:false` vs null, node log append/update
  semantics, lazy loading of node logs.
- Atomic writes; node-log redaction rewrites the whole file in one step; appends from
  the single writer never interleave.
- File modes for credentials (`acp-token` 0600, `server-config.el`, remote session
  records).
- Recovery: a session saved `running`/`blocked` is settled on load; unanswered tool
  calls get interrupted results; queued/steering messages are restored; tasks resume
  or return to pending.

**Oracle:** a bidirectional compatibility test: old Emacs writes, new backend reads and
writes, old Emacs reads again; plus crash/recovery tests at every write boundary. A
dual-write period needs a consistency checker and a rollback path.

### 7.3 Configuration, policy, plugins

**Must hold:**

- 300 server options with their types, defaults, safe predicates, groups, and
  layering (`harness-config-keys`); `config/describe` output used by the settings page.
- `.dir-locals.el` layering and Emacs's trust rules; project plugins loaded only from
  the main checkout, only with trusted entries, frozen per session.
- `/etc/harness/policy.el` as data, applied above every layer, locked with refusal
  reasons; corporate mode; allowed models.
- `harness-extra-module-directories` and user modules.

**Oracle:** the existing config/plugin/policy tests
(`test/harness-config-test.el`, `test/harness-plugins-test.el`,
`test/harness-policy-test.el`, `test/harness-server-test.el`) plus a migration test
that reads a real user's `custom-file`/dir-locals into the new model and back.

### 7.4 Emacs client

**Must hold:**

- `harness-acp-connect` local mode (no JSON) and TCP mode; the UI's post-connect
  refresh burst; `client/request` chores; `_harness/event` dispatch; permission and
  question prompts; `_harness/session` cache updates.
- Lending the Emacs as an MCP server (`_harness/emacs/mcp`) and the fixed vocabulary;
  snapshot slices; `elisp` child; TRAMP paths.
- The UI's more than 200 distinct `_harness/...` calls (a lower bound from source)
  must not return "method not found".

**Oracle:** run the real Emacs UI against the candidate backend; compare every view's
data and every prompt. The UI is unforgiving: a missing event leaves a view stale; a
missing method breaks a command.

### 7.5 Flutter client

**Must hold:**

- TCP and WebSocket transports; `initialize` capabilities; feature gating on
  `_harness.methods`/`events`.
- Session list/load/prompt/cancel/mode/model; task board; usage; workspace; memory;
  demo; permission/question answers; images; `_harness/event` notifications.
- Auth methods, session secrets, `_harness.sessionRefresh`, `auth_required`.

**Oracle:** the app's 1,132 tests and a device run against the candidate backend. The
capability model means a partial server degrades one panel at a time; use that to
stage methods, but test each panel.

### 7.6 Security contracts

**Must hold:**

- The permission chain's order and fail-closed behaviour; directory jail; standing
  rules; modes; judge; non-interactive denial; user approval/rerun.
- Kernel sandbox profiles (`bwrap`, `systemd-run`, `mxc`, `openshell`), mount sets,
  network, `/tmp`, home hiding; `sandbox/confined-p` and `required` fail-closed.
- Secret masking, redaction scope and record format, provider-log redaction, search
  index purge/rebuild, memory redaction.
- Instance id/token, derived credentials, constant-time compare, MCP auth, ACP token,
  remote session secrets, corporate mode.
- Policy enforcement at every settings change.

**Oracle:** `test/harness-perms-test.el` (202 tests), `test/harness-sandbox-test.el`,
`test/harness-containment-test.el`, `test/harness-secrets-mask-test.el`,
`test/harness-redaction-test.el`, `test/harness-acp-remote-test.el`, plus the trust
model's checking section. Any Rust implementation of these should run a differential
harness against the Lisp implementation before it is trusted.

### 7.7 Operations

**Must hold:**

- Spawn/config/token/address/parent-death/SIGTERM/log format/restart backoff.
- `harness-restart` and `harness-reload` semantics; running sessions survive a reload.
- Update fetch/verify/merge/reload; version reporting and UI/server commit skew.
- Standalone server (`scripts/harness-server`) and ACP stdio bridge.

**Oracle:** `test/harness-server-test.el`, `test/harness-update-test.el`,
`test/harness-version-test.el`, plus a supervised-process test that kills the child
at every lifecycle point.

---

## 8. Operational and security risks by option

| Risk | A Sidecar | B Hybrid | C Staged | D Full rewrite |
|---|---|---|---|---|
| Two processes, supervision, crash loops | Medium | High | Medium per stage | Medium (one binary) |
| IPC authentication / local attack surface | Medium: must not be a bypass | High: two trust domains | Medium | Medium |
| State consistency / dual writers | Low if stateless; high if owns data | High | Medium, bounded per stage | High migration |
| Permission/sandbox bypass | Low if sidecar stays behind the chain | High: every bridge is a potential bypass | Low until security parts move | High |
| Secret leakage in IPC/logs | Medium | High | Medium | High |
| Plugin trust / `.dir-locals` eval | Unchanged | Must bridge trust | Unchanged until core | Lost or host |
| Corporate mode / policy enforcement | Unchanged | Must enforce in both | Unchanged until core | Reimplement |
| Remote auth duplication | None if proxy only | Medium | Low | High |
| Supply chain (crates, binaries) | Medium | Medium | Medium | High |
| Packaging/platform matrix | Medium | Medium | Medium | High |
| Update/version skew | Low | High | Medium | High |
| Rollback | High | Medium | High per stage | Low |
| Test burden | Low–medium | Very high | Medium per stage | Very high |
| Maintenance split | One extra service | Two runtimes forever | One per stage, can retire | All Rust + Emacs bridge |

Mitigations that apply to any option:

- Keep the sidecar on stdin/stdout or a mode-0600 Unix socket, never a TCP listener
  reachable by other users; inherit the instance secret; do not log secrets.
- Keep the permission chain and sandbox in Emacs until a Rust implementation passes a
  differential security suite; never let a Rust fast path skip the chain.
- Feature-flag every stage, default off in production, with the old path as fallback.
- Replay recorded ACP sessions against old and new implementations; compare every
  result and event.
- Keep a single writer per state file; use locks or a dedicated service, not
  optimistic dual writes.
- Pin crate versions and audit the dependency tree; sign binaries; publish checksums.
- Measure before and after each stage; a stage that does not meet its gate is removed,
  not kept "for the future".

---

## 9. Effort ranges

These are planning ranges for a senior engineer familiar with Rust and with this
codebase, including tests and documentation but excluding long-tail provider/API
changes. They are not commitments.

| Work item | Scope | Effort | Confidence |
|---|---|---|---|
| Stage 0: instrumentation + Lisp/payload fixes | metrics spans, client-perceived SLOs; land the measured fixes | 2–4 weeks | High |
| Stage 1: Rust ACP edge | TLS/WebSocket reverse proxy, one upstream per client, connection limits, packaging | 4–8 weeks | High |
| Stage 2: Rust SQLite/search worker | `search.db` ownership, FTS5 query parity, purge/rebuild, redaction hooks | 3–6 months | Medium |
| Stage 3: Rust transcript service | node logs, replay, redaction, dual-write/rollback | 4–8 months | Medium |
| Stage 4: Rust provider/HTTP runtime | HTTP/SSE, built-in providers, Lisp contract bridge | 3–6 months | Medium |
| Stage 5: Rust tool/MCP workers | fs/shell/elisp workers, sandbox profile, MCP protocol | 6–12 months | Low–medium |
| Hybrid control plane | ACP + session/task state in Rust, Emacs workers, plugin bridge | 18–30 months | Low |
| Full rewrite parity | all server modules, clients, security, state migration | 3–6 engineer-years; +6–12 months stabilization | Low |

Basis for the ranges: 130 k server Lisp lines, 16.7 k lines of binding contract,
6,198 ERTS, 83 tools, 434 methods, 300 options. A Rust reimplementation typically
needs 0.7–1.5× the effective code plus 1–2× the test code; the uncertainty is in the
security and compatibility edges, not in the happy path.

---

## 10. Recommendation and stop/go criteria

### 10.1 Recommendation

**Do not start a Rust rewrite now.** The measured evidence does not support it as a
latency fix: the largest server-side cost is an optional payload, and the rest of the
wait is client rendering and a busy event loop. The project already paid for the
architectural split that matters (a separate backend process).

**Adopt staged extraction as the decision framework, and fund only these first:**

1. **Stage 0 — measure and fix in Lisp (2–4 weeks).**
   - Land or verify the `t-xywzvi9m` fixes: lean `session/list`, nodes-only replay,
     one Flutter read, memoised display order, cheaper Emacs session-id scan.
   - Add the per-phase/per-method instrumentation in §5.5.
   - Define client-perceived SLOs (cold connect, first transcript row, full
     transcript, task board first paint) and measure them on real state.
   - **Stop here if the SLOs are met.** That is a successful outcome; no Rust is
     needed.

2. **Stage 1 — Rust ACP edge (4–8 weeks), only if remote/TLS is a real requirement
   or transport is a measured top cost.**
   - A small Rust reverse proxy: TLS termination, WebSocket upgrade/framing, one
     upstream ACP connection per downstream client, connection limits/timeouts,
     backpressure, structured logs.
   - It forwards bytes after the handshake; Emacs keeps auth, methods, events, and
     permission semantics. No method reimplementation.
   - **Go:** WSS/TLS works; zero wire regressions against Emacs UI, Flutter, and ACP
     tests; p95 added latency under 5 ms; no secret in logs; clean shutdown.
   - **Stop:** no remote requirement, >10 ms overhead, or any auth/ordering
     regression.

3. **Stage 2 — Rust SQLite/search worker (3–6 months), only if Stage 0 measures
   blocking.**
   - Own `search.db` (a rebuildable cache), serve search/index/purge/rebuild over a
     local authenticated channel; Emacs keeps session/turn logic and the redaction
     orchestration.
   - **Go:** a real 100 MB index's VACUUM/purge no longer stalls the harness for more
     than 100 ms; query results match the Lisp implementation; redaction parity;
     crash/rebuild works.
   - **Stop:** no measured stall, or parity/security cannot be shown.

4. **Stage 3 — Rust transcript service (4–8 months), only if the lean fixes are not
   enough.**
   - Node log read/write/replay/redaction, with dual-read and a rollback path.
   - **Go:** transcript p95 under 100 ms for the target node counts; zero lost
     appends; redaction parity; state compatibility both ways.
   - **Stop:** lean listing/replay already meets the SLO; or dual-write complexity
     exceeds the gain.

5. **Stages 4–5 and any core extraction: do not fund until Stages 1–3 have data.**
   The burden of proof is on the extraction, not on the status quo.

**Reject now:** hybrid control plane and full rewrite. Revisit only if two or more
stages show that the remaining bottleneck is the Lisp core itself, and if a
plugin/config/hot-reload strategy and a multi-year team are in place.

### 10.2 Stop/go criteria in one table

| Gate | Metric | Go when | Stop when |
|---|---|---|---|
| 0 Baseline | client-perceived cold connect, first row, full transcript p50/p95; server start-up; event-loop lag; GC; SQLite blocking | a target is still above SLO **and** is server-side | SLOs met after Lisp/payload/client fixes |
| 1 ACP edge | added p95 latency; WSS/TLS correctness; auth/order regressions | remote/TLS needed, <5 ms overhead, zero regressions | no remote need, >10 ms overhead, any regression |
| 2 SQLite | harness stall during VACUUM/purge; query parity; redaction parity | >1 s stall on real index, parity proven | no measured stall or parity failure |
| 3 Transcript | transcript p95; append/redaction correctness; state compatibility | >100 ms p95 after lean fixes, parity/rollback proven | lean fixes sufficient |
| 4 Tools/providers | worker start-up and per-call overhead; security parity | measured tool/provider bottleneck, security parity | no bottleneck or parity risk |
| 5 Core | remaining server CPU/blocking after 1–4; plugin/config/hot-reload plan | core is the bottleneck and the plan is accepted | any earlier stage suffices |
| Full rewrite | — | never on current evidence | always |

### 10.3 What to do first, concretely

1. Merge/verify `t-xywzvi9m` and re-run its benchmark on current `main`; record the
   lean/full numbers on the same machine.
2. Add the Stage 0 instrumentation; collect a week of real p50/p95 data from the
   user's normal workload (aggregate only, no transcript content).
3. If remote/TLS is a product requirement, prototype the Rust ACP edge against the
   existing Emacs server and the existing clients. This is the smallest useful Rust
   deliverable and the best test of the "one upstream per client" proxy design.
4. If the SQLite measurements show multi-second stalls, prototype the Rust search
   worker on a copy of `search.db`; compare results and purge semantics.
5. Re-evaluate after 3–6 months of data. Do not start a core extraction on the
   strength of a language preference.

---

## 11. Open questions for the user

These change the recommendation and should be answered before a stage is funded:

1. **Is remote/TLS access a product requirement?** If not, the strongest Rust case
   (the ACP edge) has no local benefit, and the honest recommendation may be "no Rust
   at all; finish the Lisp/client work."
2. **Are plugins, user modules, `.dir-locals.el` and hot reload non-negotiable?** If
   yes, a full rewrite must keep an Emacs plugin/config host, which makes it a hybrid
   or a staged extraction, not a clean port.
3. **What is the session scale and the latency target?** 1,000 sessions at 40 KB each
   is 40 MB; 10,000 sessions changes the answer toward a Rust store. The target p95
   for cold connect, first row and full transcript should be explicit.
4. **Is the `t-xywzvi9m` branch going to merge?** The measurements here assume its
   lean/replay/client fixes are the intended direction. If not, the baseline is worse
   and the first action is still those fixes.
5. **Is there a multi-year team for a backend program?** Full rewrite is 3–6
   engineer-years; a solo/small team should prefer sidecars.
6. **Which platforms must a Rust binary support?** Linux and macOS are the current
   sandbox targets; Windows is not supported by the sandbox code. Binary packaging
   and signing are a product decision.
7. **Is memory/start-up a product goal?** If yes, Rust helps; if not, it is not a
   reason to rewrite.
8. **What is the risk appetite for reimplementing permissions, sandbox, secrets and
   remote auth?** These are the highest-consequence parts and the least likely to be
   improved by a language change alone.

---

## 12. References

**Core and lifecycle**

- [`harness.el`](../../harness.el): `harness-start`, `harness-stop`,
  `harness--reload`, `harness-reload`, `harness-update`, `harness--verify-commit`.
- [`lisp/harness-server.el`](../../lisp/harness-server.el):
  `harness-server-main`, `harness-server-spawn`, `harness-server--event-loop`,
  `harness-server--write-config`, `harness-server--forwarded`.
- [`lisp/ui/harness-ui.el`](../../lisp/ui/harness-ui.el): `harness-ui--open`,
  `harness-ui-refresh-sessions`, `harness-ui-refresh-models`,
  `harness-ui-refresh-quotas`, `harness-ui--ensure-server`,
  `harness-ui--on-current-server-exit`, `harness-restart`.
- [`lisp/harness-core.el`](../../lisp/harness-core.el): `harness-register-method`,
  `harness-call`, `harness-define-module`, `harness-on`, `harness-emit`,
  `harness-add-filter`, `harness-run-filter-async`, `harness-modules-init`.

**ACP and clients**

- [`lisp/modules/harness-acp.el`](../../lisp/modules/harness-acp.el):
  `harness-acp--define-standard`, `harness-acp--extension-methods`,
  `harness-acp--normalise`, `harness-acp-connect`, `harness-acp--client-send`,
  `harness-acp--server-receive`, `harness-acp--handle-request`.
- [`lisp/modules/harness-acp-remote.el`](../../lisp/modules/harness-acp-remote.el):
  WebSocket, session secrets, approval, OIDC, corporate mode.
- [`docs/architecture.md`](../architecture.md): "Processes", "The bus",
  "Which modules load", "Modules of your own", "Projects' plugins", "Data shapes",
  "acp".
- [`harness_client/lib/src/acp/capabilities.dart`](../../harness_client/lib/src/acp/capabilities.dart),
  [`acp_client.dart`](../../harness_client/lib/src/acp/acp_client.dart),
  [`connection_target.dart`](../../harness_client/lib/src/acp/connection_target.dart),
  [`services/harness_api.dart`](../../harness_client/lib/src/services/harness_api.dart).

**State, tasks, permissions**

- [`lisp/modules/harness-session.el`](../../lisp/modules/harness-session.el):
  `harness-session--load-all`, `harness-session--from-plist`,
  `harness-session--init`.
- [`lisp/modules/harness-store.el`](../../lisp/modules/harness-store.el):
  `store/load`, `store/save`, `store/append`, `store/sqlite`.
- [`lisp/modules/harness-tasks.el`](../../lisp/modules/harness-tasks.el),
  [`harness-merge.el`](../../lisp/modules/harness-merge.el),
  [`harness-worktree.el`](../../lisp/modules/harness-worktree.el),
  [`harness-supervisor.el`](../../lisp/modules/harness-supervisor.el).
- [`lisp/modules/harness-perms.el`](../../lisp/modules/harness-perms.el),
  [`harness-sandbox.el`](../../lisp/modules/harness-sandbox.el),
  [`harness-access.el`](../../lisp/modules/harness-access.el),
  [`harness-secrets.el`](../../lisp/modules/harness-secrets.el),
  [`harness-redact.el`](../../lisp/modules/harness-redact.el).
- [`docs/trust-model.md`](../trust-model.md), [`docs/policy.md`](../policy.md),
  [`docs/secret-sandbox.md`](../secret-sandbox.md).

**Extensions and configuration**

- [`lisp/modules/harness-config.el`](../../lisp/modules/harness-config.el):
  `harness-config-keys`, `config/describe`, `config/set`.
- [`lisp/harness-policy.el`](../../lisp/harness-policy.el):
  `harness-policy-load`, `harness-policy-apply`, `harness-policy--guard`.
- [`lisp/modules/harness-plugins.el`](../../lisp/modules/harness-plugins.el):
  `harness-plugins--apply`, `harness-plugins--freeze`,
  `harness-plugins--planted-p`.
- [`.dir-locals.el`](../../.dir-locals.el) and
  [`.harness/plugins/dev/`](../../.harness/plugins/dev/).

**Editor integration**

- [`lisp/harness-emacs-endpoint.el`](../../lisp/harness-emacs-endpoint.el):
  `harness-emacs-endpoint-server`, `harness-emacs-endpoint-answer`,
  `harness-emacs-endpoint-client-capabilities`.
- [`lisp/harness-snapshot.el`](../../lisp/harness-snapshot.el): `harness-snapshot-slice`.
- [`lisp/harness-elisp.el`](../../lisp/harness-elisp.el): `harness-elisp-batch-main`.
- [`lisp/harness-mcp-fs.el`](../../lisp/harness-mcp-fs.el) and
  [`lisp/modules/harness-mcp.el`](../../lisp/modules/harness-mcp.el).

**Performance evidence**

- `task/speed-up-harness-connection-and-xywzvi9m`, commit `972b26e`, report
  `docs/analysis/transcript-load-2026-11-07.md` (unmerged at the time of writing).
- `scripts/analysis/bench-transcript-load.el` / `.sh` on that branch.
- [`docs/analysis/ui-thread-blocking-2026-10-22.md`](ui-thread-blocking-2026-10-22.md)
  and [`docs/analysis/ui-thread-blocking-2026-10-23.md`](ui-thread-blocking-2026-10-23.md).
- [`docs/test-performance.md`](../test-performance.md).

---

## Appendix A: measurement method

All measurements were taken in this session's temporary directory
(`/var/tmp/harness-1000/<session>/`) on 2026-11-07, on the same machine as the
repository, with `nice -n 19` and `ionice -c3`. No live harness was restarted and no
real transcript was read.

**Synthetic state.** Each `sessions/bench-NNNNN.json` was a minimal valid session
record: `id`, `name`, `kind: "main"`, `project` and `cwd` under
`/tmp/harness-bench-project/`, `model: "demo:scripted"`, `permission-mode: "ask"`,
`status: "idle"`, `created`/`updated`, `usage`, and `provider-state` containing a
`conversation` string of 0 or 40,000 `x` characters. Records were written with
Emacs's `json-encode`. The 1,000 × 40 KB state is 40 MB on disk.

**Server.** `scripts/harness-server` with:

```sh
HARNESS_SERVER_CONFIG=<tmp>/cfg.el \
HARNESS_SERVER_TOKEN=<test token, 16+ chars> \
HARNESS_SERVER_HOST=127.0.0.1 HARNESS_SERVER_PORT=0 \
nice -n 19 ionice -c3 scripts/harness-server
```

`cfg.el` was:

```elisp
;;; -*- lexical-binding: t; -*-
(setq harness-state-directory "<tmp>/state/")
(setq harness-enabled-modules nil)
```

Start-up time was measured from process launch to the first
`HARNESS-ACP-ADDRESS` line on stderr. The server was killed with SIGTERM after the
measurement. A compiled state directory (`elc-server/`) was copied from the first
warm-up run so warm starts did not recompile.

**ACP client.** A small Python client connected to the printed address, sent
line-delimited JSON-RPC `initialize`, `authenticate`, `_harness/session/list`,
`_harness/session/get` and `_harness/session/nodes`, and timed from `sendall` to the
last byte of the matching line, then separately timed `json.loads`. It read with
1 MB `recv` chunks. (An earlier version used 64 KB chunks and accumulated the whole
line with `buf += chunk`; that measured the client's quadratic buffer copying, not the
server, and is not quoted. Benchmark clients must use a linear buffer.)

**Server-side stages.** A batch Emacs loaded the same state through
`test/harness-test-helpers.el` and the `store project config provider session acp ui`
modules, then timed `(harness-call 'session/list)`, `(harness-acp--normalise ...)` and
`(harness-json-encode ...)` three times and reported the mean; the first call was a
warm-up. This is the same decomposition the prior task used, with the addition of the
ACP normalise stage.

**Memory.** `VmHWM`/`VmRSS` and `utime`/`stime` from `/proc/<pid>/status` and
`/proc/<pid>/stat` after the address was printed, before SIGTERM.

**Limits.** The records are synthetic and minimal; a real record has more fields and
may be larger. The machine was shared with the user's live harness and other tasks;
the runs were niced but not isolated. The numbers are medians/ranges of a few runs,
not a controlled benchmark. They are enough to show the order of magnitude and the
payload effect, not to predict a specific user's latency.

## Appendix B: raw summary

| Run | Start-up | List receive | List parse | Bytes | RSS |
|---|---:|---:|---:|---:|---:|
| 0 sessions | 360–366 ms | — | — | — | 97,428 KB |
| 200, no state | 807 ms (first) | 3.4–3.9 ms | 1.3 ms | 153,526 | — |
| 200 × 40 KB | 480 ms | 22.1–22.6 ms | 9.9–10.1 ms | 8,153,526 | — |
| 1,000, no state | 477–504 ms | 18.9–38.8 ms | 6.6–7.6 ms | 767,926 | 99,540 KB |
| 1,000 × 40 KB | 656–1,005 ms | 270.4–304.6 ms | 51.8–52.6 ms | 40,767,926 | 154,664 KB |
| First start, fresh state | 3,021 ms | — | — | — | — |

Server-side stages for 1,000 × 40 KB: build 3.47 ms, normalise 3.13 ms, encode
82.44 ms, 40,767,891 bytes. For 1,000 minimal: build 3.05 ms, normalise 2.89 ms,
encode 46.71 ms, 767,891 bytes. For 200 × 40 KB: build 0.65 ms, normalise 0.57 ms,
encode 21.03 ms, 8,153,491 bytes.

Idle ACP control path on the 1,000 × 40 KB state: `initialize` 0.8–1.6 ms,
`authenticate` 0.1 ms, `session/get` 0.5–0.7 ms, `session/nodes` 0.1–0.3 ms. That
`initialize` advertised 189 extension methods and 78 events for the core module set
the server loaded.

## Appendix C: what the pending performance fix changes

The `t-xywzvi9m` branch changes the numbers in Appendix B in four ways:

- The lean `session/list` removes `:provider-state` and three other keys. On the
  prior task's fixture, 200 sessions went from 8.54 MB to 0.52 MB; our no-state
  fixture is 0.77 MB for 1,000 sessions. The wire and parse costs fall with the bytes.
- Nodes-only replay halves the update count and the bytes, and removes the redundant
  chunk plus whole-node payload.
- Flutter reads a session once and memoises the displayed order.
- Emacs's session-id scan is cheaper, and the update page reports its stage.

If that branch merges, the baseline for any Rust decision should be its numbers, not
the pre-fix numbers in this report. The recommendation to measure first is unchanged;
the expected outcome is that the remaining server-side cost is small enough that the
first Rust stage is optional.
