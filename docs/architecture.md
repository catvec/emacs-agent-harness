# Architecture

This document is the API contract between the harness modules.  The design
goal is that any module can be developed, tested, and replaced in isolation,
and that the whole system can be driven over the Agent Client Protocol (ACP).

Read [DESIGN.md](../DESIGN.md) for the product requirements.  This document
only says how the pieces fit together and where the boundaries are.

## Layering

```
          presentation (Emacs UI) ── ACP client
                     │
                     │ ACP (JSON-RPC objects; local or TCP transport)
                     ▼
  state / business (agent, sessions) ── ACP agent server
                     │
        ┌────────────┼─────────────┐
        ▼            ▼             ▼
   completion      tools      permissions      config
    provider
                     │
                     ▼
                  kernel (modules, services, events, deferred)
```

Dependency rules:

- The kernel depends on nothing.  It knows no ACP, no sessions, no LLMs.
- Every module depends on the kernel.
- The state layer depends on kernels, services and its own contracts.  It
  never requires a UI module.
- The presentation layer speaks **only** ACP.  It may not call state-layer
  functions.  A UI feature that needs new state is a new ACP method or
  session update, not a direct call.
- Providers, tools, permission rules and config backends are leaf modules
  that plug into their respective registries.
- A module must be loadable and testable without any module it does not
  declare in `:requires`.  Tests for it may only use the kernel plus fakes of
  the services it consumes.

`harness.el` is only a distribution bundle: it loads the default module set.
Loading `harness-core.el` alone must start no UI, no network, no timers.

## The kernel (`harness-core.el`)

### Modules

A module is a feature file that declares a manifest:

```elisp
(harness-module-define 'harness-session
  :version "0.1.0"
  :description "Sessions, transcripts and their storage."
  :requires '((harness-core "0.1.0")
              (harness-config "0.1.0"))
  :provides '(harness-session)
  :setup #'harness-session-setup
  :teardown #'harness-session-teardown)
```

- Loading is `harness-module-load`, which `require`s the feature, loads its
  dependencies first (recursively), then runs `:setup`.  `:setup` may use
  dependencies; top-level forms may not.
- `:teardown` must undo everything `:setup` did: services, event handlers,
  timers, processes.  `harness-module-reload` uses it for hot reload.
- The loader records which services and event handlers a module registered
  while its `:setup` ran, and removes leftovers on teardown, so a module
  cannot silently leak registrations.
- `harness-module-list` reports each module's state: `defined`, `loaded`,
  `set-up`, `error`.

### Services

A service is a named object with methods, the D-Bus analogue:

```elisp
(harness-service-register
 "session"
 :module 'harness-session
 :doc "Sessions, transcripts and session lifecycle."
 :methods '((create   . harness-session-service-create)
            (get      . harness-session-service-get)
            (list     . harness-session-service-list)
            (prompt   . harness-session-service-prompt)))

(harness-service-call "session" 'create :cwd dir)
```

Rules:

- Method functions receive keyword arguments and return either a value or a
  `harness-deferred` for work that is not instantaneous.
- A method that returns a deferred is the norm for anything doing I/O,
  model calls or work over N lines of text.
- `harness-service-call` signals a `harness-service-missing` error when the
  service or method does not exist.  Callers that need optional dependencies
  use `harness-service-available-p`.
- `harness-service-describe` returns the full introspection data for one
  service; `harness-event-describe` the same for events.  `M-x
  harness-describe` shows the live registry.  This is how a module author
  discovers what other modules offer (the "D-Bus problem").

### Events

Events let a module publish facts without knowing who listens:

```elisp
(harness-event-define 'session-status-changed
  :module 'harness-session
  :doc "A session moved between idle, running and blocked."
  :payload '((session . harness-session)
             (status . symbol)
             (previous . symbol)))

(harness-emit 'session-status-changed :session s :status 'running :previous 'idle)

(harness-on 'session-status-changed #'my-handler
  :module 'my-module
  :predicate (lambda (payload) ...))
```

Rules:

- Every event is declared with `harness-event-define` before first use;
  emitting an undeclared event signals an error outside of tests.
- The payload is a plist.  `:payload` documents the keys, for humans and for
  `harness-describe`.
- Handlers run in emission order, are expected to be quick, and must not
  signal; errors are caught, reported, and do not stop other handlers.
- `harness-on` records the owning module so teardown/reload can remove
  handlers even if the module forgot.
- Modules that need cross-module request/response use services, not events.
  Events are notifications only.

### Deferreds

`harness-deferred` is the one async primitive:

```elisp
(let ((d (harness-deferred-new)))
  (harness-deferred-then d #'on-ok #'on-error)
  (harness-deferred-resolve d value)   ; later, from any callback
  (harness-deferred-cancel d))         ; abortable work
```

Deferreds are cancellable, multi-observer, and settle exactly once.  Any
module exposing async work returns a deferred.  The ACP layer turns a
deferred into a JSON-RPC response and `$/cancel`-style aborts.

### Responsiveness

Emacs is single threaded, so "never block the UI thread" means:

- Socket and process I/O is always filter/callback based
  (`make-network-process`), never `accept-process-output` loops.
- Streaming deltas are coalesced and flushed on a timer (default 33 ms), not
  one redisplay per token.
- Work over large text runs in chunks scheduled with `run-at-time 0` or
  `timer-set-idle-time`; a chunk is bounded by time (`harness-budget-run`),
  not by line count.
- Synchronous file I/O is allowed only for small local files with
  `file-readable-p`-guarded paths.  Remote (TRAMP) and large operations must
  go through the async helpers or a process.

The kernel provides `harness-budget-run`, `harness-defer`, and
`harness-idle-coalesce` for this.

## ACP (`harness-acp.el` and transports)

`harness-acp.el` implements ACP v1 as specified at
<https://agentclientprotocol.com/protocol/v1/overview>, over a transport
interface.  It contains no session or model logic.

- Agent-side methods: `initialize`, `session/new`, `session/load`,
  `session/resume`, `session/close`, `session/list`, `session/delete`,
  `session/prompt`, `session/set_mode`, `session/set_config_option`, and the
  `session/cancel` notification.
- Client-side methods: `session/request_permission`, `fs/read_text_file`,
  `fs/write_text_file`, `terminal/*`.
- Outbound notifications: `session/update` with the v1 update variants
  (`user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk`,
  `tool_call`, `tool_call_update`, `plan`, `available_commands_update`,
  `current_mode_update`, `config_option_update`, `session_info_update`,
  `usage_update`).
- Extensions use the reserved `_harness/` prefix, advertised in
  `initialize` under `agentCapabilities._meta`.

Method handling is a table: ACP method → service method.  The ACP module
calls services by name with the kernel's late binding, so it can be tested
against fake services and state modules can be added or removed.  The table
and the event-to-update mapping are the single place where the protocol
surface is defined.

Transports implement `harness-acp-transport` objects with `send` (message
plist → other side) and a receive callback.  Two ship in tree:

- `harness-acp-inprocess.el`: direct function call to the peer's receive
  handler.  Same process, no serialization, no sockets.  Used by the local
  Emacs UI.
- `harness-acp-tcp.el`: newline-delimited JSON over a TCP socket (or any
  byte stream), non-blocking, used to control a harness on another host.

Both use the same ACP message plists; only framing differs.

## Session state (`harness-session.el`)

A session is the unit of conversation:

- identity: `sessionId` (uuid string), name, optional parent session
- scope: `cwd` (absolute), project root, optional git worktree
- configuration: model, thinking level, permission mode, mode
- state: status (`idle`, `running`, `blocked`), transcript, usage, cost
- relationships: parent/child tree for forks and subagents

The transcript is an ordered vector of entries.  An entry is a plist shaped
like an ACP `session/update` payload plus `:id` and `:time`.  Storing the
ACP shape is deliberate: `session/load` replays stored updates, the UI
renders the same objects that arrive live, and there is exactly one
representation of "a thing that happened in a conversation".

Storage lives under `(xdg-data-home)/harness/sessions/<project-id>/<id>/`:
`session.json` (metadata) and `transcript.eld`/`transcript.jsonl`
(append-only entries).  Reads are lazy: the session list loads metadata
only.

Session events: `session-created`, `session-deleted`, `session-updated`
(name/model/config/status), `session-status-changed`, `session-entry-added`
(one transcript entry), `session-usage-changed`.

## Completion providers (`harness-provider.el`)

Providers register against the `provider` service:

```elisp
(harness-provider-register
 "openai-compatible"
 :capabilities '(streaming tool-calls image-input thinking)
 :models #'harness-provider-openai-models
 :complete #'harness-provider-openai-complete
 :count-tokens #'...)
```

`complete` receives a normalized request:

```elisp
(:model "claude-sonnet-4-5" :messages (...) :tools (...) :thinking nil
 :max-output-tokens 4096 :abort d)
```

and returns a deferred.  Streaming is reported through a callback plist:
`on-text`, `on-thought`, `on-tool-call`, `on-usage`, `on-done` (stop reason),
`on-error`.  Providers translate wire formats (SSE, JSON, SDK) into this one
shape; the agent never sees provider-specific data.  Optional capabilities
(quota, cache status, dynamic pricing) are extra service methods, and the
UI enables features when a provider advertises them.

The built-in OpenAI-compatible provider (`harness-provider-openai.el`) is
built on the async HTTP client service (`harness-http.el`).

## Tools (`harness-tools.el`)

```elisp
(harness-tool-register
 'read
 :module 'harness-tools-emacs
 :description "..."
 :schema '((path . (:type string :required t)) ...)   ; JSON Schema
 :kind 'read
 :read-only t
 :handler #'harness-tool-emacs-read)
```

A handler receives a `harness-tool-context` (session, cwd, abort deferred,
`report` callback) and arguments, and returns a deferred of a result plist:

```elisp
(:content ((:type "text" :text "...")) :is-error nil
 :locations ((:path "..." :line 3)) :truncated nil :meta ...)
```

Tools are the first choice to be implemented with native Emacs facilities;
`bash` exists for what Emacs cannot do.  Context-bomb protection is a
property of the registry: results larger than
`harness-tools-max-output-bytes` are replaced by a truncated body plus an
explicit instruction to use range parameters, unless the tool opts out with
`:unbounded t`.

## Permissions (`harness-perms.el`)

Permission decisions are a chain: each function in
`harness-permission-functions` returns `allow`, `deny` (with a
constructive reason), `ask`, or nil to defer to the next one.  The chain
runs as a deferred.  Independent rule modules (directory jail, auto mode,
non-interactive mode) plug into the chain and are separately testable.

`ask` turns into an ACP `session/request_permission` request when a client
is attached; headless callers can supply their own asker.  Denials always
carry a message that tells the model what to do instead.

## Configuration (`harness-config.el`)

Settings are ordinary Emacs customization variables.  Resolution order,
most specific last:

1. built-in defaults and the user's `custom-file` values
2. project configuration (project root `.dir-locals.el` entry under the
   `harness` pseudo-mode)
3. directory configuration (nearest `.dir-locals.el` below the project root)

Persistence uses Emacs' own `dir-locals` machinery
(`add-dir-local-variable`), so settings never live in a parallel format.
`harness-config-set` persists to the most specific file that already sets
the variable, else the project file, else the global `custom-file`.

## Presentation (`harness-ui*.el`)

UI modules are ACP clients.  `harness-ui.el` owns a client connection and
re-broadcasts ACP notifications as Emacs events; feature modules render
them.  The chat buffer, session list, conversation tree, notifier and
config controls are separate modules so that, for example, the notifier can
be tested by feeding it updates.

Positions ("right side vertical split", ...) are presets applied when a
session buffer is displayed; one session per position, opening another
session in the same position replaces the buffer there.

## Module inventory

| module | provides | requires |
|---|---|---|
| `harness-core` | kernel | — |
| `harness-acp` | ACP protocol over transports | core |
| `harness-acp-inprocess` | local transport | acp |
| `harness-acp-tcp` | TCP transport | acp |
| `harness-http` | `http` service | core |
| `harness-config` | `config` service | core |
| `harness-sandbox` | `sandbox` service | core |
| `harness-session` | `session` service | core, config |
| `harness-provider` | `provider` service | core |
| `harness-provider-openai` | provider registration | provider, http |
| `harness-tools` | `tool` service | core |
| `harness-tools-emacs` | core tool set | tools, sandbox |
| `harness-skills` | `skill` service, skill tools | config, tools |
| `harness-perms` | `permission` service | tools |
| `harness-perms-jail` | directory jail rules | perms, tools |
| `harness-agent` | `agent` service | session, provider, tools, perms |
| `harness-subagents` | `subagent` tool | agent, session, tools |
| `harness-ui` | ACP client + events | acp, inprocess, perms |
| `harness-ui-chat` | chat buffer | ui |
| `harness-ui-ask` | approval/question panels | ui |
| `harness-ui-sessions` | session list | ui, chat |
| `harness-ui-tree` | conversation tree | ui, chat, sessions |
| `harness-ui-config` | model/thinking/mode controls | ui |
| `harness-ui-notifier` | blocked notifier | ui |

`harness.el` loads: acp, inprocess, config, session, provider,
provider-openai, tools, tools-emacs, perms, perms-jail, agent,
subagents, ui, and the UI feature modules selected by
`harness-ui-modules` (all by default).  A user can replace any of them by
customizing the list.

### Sub-agents

`harness-subagents` registers the `subagent` tool.  A call creates a new
session whose parent is the calling session (so the conversation tree and
the session list show it), inherits the caller's model and thinking level,
runs the given prompt to completion and returns the child's final message
as the tool result.  With `:fork` the child starts from a fork of the
caller's transcript instead of an empty one.  Nesting is capped by
`harness-subagents-max-depth`.

## Sandbox

Every process the harness spawns goes through `harness-sandbox-spawn`.
The backend is chosen at startup in preference order: bwrap,
`systemd-run --user`, none.  Policies either prefer confinement (warn
loudly once when no backend exists) or require it (fail closed).  bwrap
gets read-only system trees, only the needed `/etc` entries, a tmpfs for
`/tmp` used as HOME and TMPDIR (the real home is never mounted), a
read-write session cwd, pid/ipc/uts namespaces and `--die-with-parent`;
network is allowed unless a policy opts into `--unshare-net`.
`:permission-mode` is a prompt-level hint and never a security boundary.

## ACP extension surface

Beyond the standard ACP v1 methods, the harness and its UI agree on
extensions under the reserved `_harness/` prefix (advertised in
`initialize` under `agentCapabilities._meta.harness`):

- `_harness/session/info`, `_harness/session/fork`,
  `_harness/session/rename`, `_harness/session/entries`
- `_harness/agent/configuration`
- `_harness/skills/list`, `_harness/skills/load`
- notifications `_harness/session_status` (status, model, unread),
  `_harness/sessions_changed`
- the `_harness/question` request (client side), used by the agent's
  `ask` tool.

The session status extension exists because ACP has no session status
notification, and the blocked notifier must work without a chat buffer.

## Reload

`harness-reload` reloads every loaded module safely: all sources are
byte-compiled to a temporary location first; if any fails, nothing is
touched.  Unloading removes services, handlers, features and the
module's setup, but keeps function definitions and variable values in
place, so outstanding dynamic bindings and caches survive.  If a module
fails while loading, snapshots of every module's definitions restore the
previous version and re-run its setup.  The kernel never reloads itself.
Open sessions are re-adopted from kernel state after the session module
reloads, and `harness-reloaded` makes UI modules redraw their buffers.

## Testing

- Every module has an ERT file in `test/`; `scripts/test.sh` runs them in
  batch with `emacs -Q`.
- A test loads only the kernel plus the module under test and fakes the
  services it consumes.  `test/harness-test-helpers.el` provides a fake
  provider, an in-memory session store, and an echo ACP client.
- Live verification uses `scripts/dev.sh` (see `docs/dev-loop.md`): launch a
  GUI Emacs, drive it, screenshot it, read `*Messages*`.
