# DESIGN.md — Emacs Agent Harness

Canonical design reference. `SPEC.md` is the original requirements (historical);
this file is what the code is actually built against. When a decision changes,
change this file in the same commit.

---

## 1. Overview

`emacs-agent-harness` is an LLM coding agent harness implemented entirely in
Emacs Lisp, using native Emacs UI/UX idioms (major modes, hooks, `defcustom`,
`tabulated-list-mode`, `widget`, `outline-mode`, text properties, faces,
`project.el`).

It is both an *application* (a Pi/Claude-Code-like agent) and a *platform*: the
core is a small set of extensible registries and hooks, and every user-visible
feature is written on top of them. The harness dogfoods itself — the agent can
add tools, renderers, and commands to its own running instance via
`harness_eval` / `harness_define_tool` / the plugin loader.

### 1.1 Design constraints (from SPEC.md, treated as hard requirements)

1. **Never block the Emacs main thread.** All network I/O uses
   `make-network-process` with `:nowait t` + process filters/sentinels. No
   `accept-process-output`, no `url-retrieve-synchronously`, no `sleep-for` in
   request paths.
2. **No expensive work on the main thread.** Streaming rendering is O(delta),
   not O(buffer). Tool output is truncated before it is ever inserted. Session
   search runs against an SQLite index, not by re-reading files. Parsing is
   incremental per SSE line.
3. **Built-ins only.** No third-party package is required at runtime
   (`json`, `url-util`, `project`, `tabulated-list`, `widget`, `outline`,
   `sqlite`, `gnutls` are all part of Emacs 29+). Optional integration is via
   `with-eval-after-load` / `bound-and-true-p` only.
4. **Follow Emacs patterns.** `lexical-binding: t`; `defcustom` for everything
   user-visible; `harness-` prefix; `harness--` for private symbols; hooks for
   every extension point; major modes for every buffer; `C-c <key>` prefix;
   `thing-at-point`, `derived-mode-p`, `cl-defstruct`, `cl-defgeneric` where
   the codebase already does.
5. **Extensible from the start.** Registries + hooks + renderer dispatch. See
   §9.

---

## 2. Module map

```
emacs-agent-harness/
├── harness.el                     entry point: custom group, keymap, autoloads,
│                                  plugin loader, commands (new/resume/switch)
├── lisp/
│   ├── harness-core.el            structs, registries, hooks, ids, cost, utils
│   ├── harness-faces.el           faces (themeable), status glyphs
│   ├── harness-http.el            async HTTP/1.1 + SSE client
│   ├── harness-provider.el        pluggable provider API: registry, generics,
│   │                              model/price stats, stream event protocol
│   ├── harness-provider-openai.el reference provider: OpenAI-compatible
│   │                              /chat/completions (LiteLLM, DeepSeek, ...)
│   ├── harness-provider-process.el transport helper for providers implemented
│   │                              as an external process (streaming JSON over
│   │                              stdio; the escape hatch for CLI providers)
│   ├── harness-session.el         session lifecycle, persistence, project link,
│   │                              sqlite content index / search
│   ├── harness-tools.el           tool registry, core tools, async execution
│   ├── harness-perms.el           permission policy, pending approvals, auto-mode
│   ├── harness-agent.el           the run loop (streaming state machine)
│   ├── harness-subagents.el       child sessions, personalities, model override
│   ├── harness-attachments.el     @-notation completion and content attachment
│   ├── harness-context.el         token budgeting, compaction, chunked search
│   ├── harness-worktree.el        git worktree per session
│   ├── harness-queue.el           queued messages + editable queue buffer
│   ├── harness-ui-conversation.el conversation buffer + input area
│   ├── harness-ui-sessions.el     tabulated-list session browser
│   ├── harness-ui-tree.el         outline-based message tree
│   ├── harness-ui-ask.el          widget-based ask-user-question UI
│   ├── harness-ui-model.el        model selection UI
│   └── harness-mode-line.el       per-buffer status line + global indicator
└── test/                          ERT tests, mock provider, no network
```

Load order is the above order; `harness.el` `require`s everything. Modules lower
in the list may not be required by modules higher in the list — they communicate
through the hooks and registries defined in `harness-core.el`. That keeps the
core independent of the UI and makes `harness-core` + `harness-provider` +
`harness-agent` usable headless (tests, batch use).

---

## 3. Data model (`harness-core.el`)

All structs use `cl-defstruct` with `:copier` so events can carry snapshots.

```elisp
(cl-defstruct (harness-message ...)
  id            ; string, unique within session ("m-<n>")
  role          ; 'system | 'user | 'assistant | 'tool
  content       ; string (utf-8)
  thinking      ; string, reasoning trace (nil when absent)
  tool-calls    ; list of harness-tool-call (assistant messages only)
  tool-call-id  ; string (role 'tool only)
  tool-name     ; string (role 'tool only)
  status        ; 'complete | 'streaming | 'error | 'aborted
  error         ; string or nil
  timestamp     ; float (time-to-seconds)
  duration      ; float or nil
  usage         ; plist (:in N :out N :cache-read N :cache-write N :cost F)
  meta)         ; plist, free for plugins

(cl-defstruct (harness-tool-call ...)
  id            ; provider tool_call id
  name          ; tool name
  args-string   ; raw JSON arguments as streamed (accumulated)
  args          ; parsed alist, or nil if unparseable
  status        ; 'pending | 'awaiting-approval | 'running | 'ok | 'error
                ; | 'denied | 'aborted
  result        ; string, full (untruncated) output
  error         ; string or nil
  detail        ; plist, tool-supplied structured detail for renderers
  started finished
  meta)

(cl-defstruct (harness-session ...)
  id            ; string, "<yyyymmddThhmmss>-<8 hex>"
  name          ; user-visible name, defaults to a generated title
  project-root  ; absolute path or nil
  project-name  ; string (project.el name) or directory basename
  file          ; absolute path of the .jsonl session file
  provider      ; provider name (symbol)
  model         ; model id string
  messages      ; list of harness-message, oldest first
  status        ; 'idle | 'working | 'streaming | 'awaiting-approval
                ; | 'awaiting-answer | 'classifying | 'aborted | 'exited
  status-detail ; plist, e.g. (:tool "bash" :reason "policy")
  queue         ; list of harness-queued-message, oldest first
  approvals     ; list of harness-approval still pending
  usage         ; accumulator plist (:in :out :cache-read :cache-write :cost)
  parent        ; parent session id or nil
  children      ; list of child session ids
  created updated
  buffer        ; live conversation buffer, or nil
  run           ; opaque run token for the in-flight provider request
  title-generated ; bool, whether an LLM title was requested
  meta)         ; plist, free for plugins and plugins-only state
```

`harness-approval`:

```elisp
(cl-defstruct (harness-approval ...)
  id session tool-call
  kind          ; 'tool | 'question
  prompt        ; string shown to the user
  detail        ; plist for renderers (diff, command, args, ...)
  callback      ; function called with the decision
  created)
```

`harness-queued-message`: `(id text created attachments)`.

Registry: `harness--sessions` is an `equal`-hash of id → `harness-session`.
`harness-session-list` returns sessions sorted by `updated` descending.
Registries are also defined for tools, providers, models, renderers.

### 3.0 JSON encoding conventions

Everything that crosses the wire or hits disk is encoded by
`harness-json-write' and decoded by `harness-json-read'.  The mapping is:

| JSON | Lisp |
|---|---|
| object | plist (keyword keys) or alist (symbol/string keys) |
| array | **vector** when the elements are objects or arrays; a list is fine for arrays of scalars |
| null | nil |
| false | `:false` |
| string/number/bool | the obvious thing |

The vector rule is not stylistic.  `json-encode' decides whether a list is an
object or an array by looking at its shape, so a one element array of objects
(`({"a": 1})`) is indistinguishable from an object and is silently encoded as
one.  `harness-json-array` (`vconcat`) is the explicit way to say "this is an
array"; tool specs, wire tool calls and persisted queues all go through it.
Decoding always produces lists for arrays, which is fine: reading is
unambiguous.

### 3.1 Hooks (the extension contract)

| Hook | Args | When |
|---|---|---|
| `harness-session-created-hook` | `session` | after a session enters the registry |
| `harness-session-updated-hook` | `session events` | any mutation; `events` is a list of symbols |
| `harness-session-deleted-hook` | `session` | session killed |
| `harness-status-changed-hook` | `session old new` | status transition |
| `harness-message-added-hook` | `session message` | message appended |
| `harness-message-updated-hook` | `session message events` | in-place message mutation |
| `harness-tool-call-updated-hook` | `session tool-call` | tool call state change |
| `harness-stream-hook` | `session message kind text` | `kind` is `text`/`thinking` |
| `harness-run-finished-hook` | `session` | run loop reached idle |
| `harness-approval-added-hook` / `-resolved-hook` | `session approval [decision]` | approval lifecycle |
| `harness-user-message-functions` | `session text` → text | transform an outgoing message (attachments use this) |
| `harness-content-render-functions` | `content` → handled-p | render a message body (the attachment renderer uses this) |
| `harness-run-aborted-hook` | `session` | a run was aborted (subagents stop their children) |
| `harness-after-reload-hook` | – | the harness or a plugin was reloaded |
| `harness-context-updated-hook` | `session` | the summary or context view changed |

`events` symbols: `messages`, `stream`, `status`, `usage`, `queue`,
`approvals`, `meta`. UI handlers switch on them; `messages` means "structure
changed, re-sync", `stream` means "append-only delta, do the cheap thing".

---

## 4. HTTP + SSE (`harness-http.el`)

A purpose-built async HTTP/1.1 client. Not a general-purpose library — it
supports exactly what LLM APIs need: POST/GET, headers, `Content-Length` and
`Transfer-Encoding: chunked`, TLS, streaming callbacks.

```elisp
(harness-http-request
  "https://api.example.com/v1/chat/completions"
  :method "POST"
  :headers '(("Authorization" . "Bearer sk-...") ("Accept" . "text/event-stream"))
  :body "{\"stream\":true}"
  :on-event  (lambda (event) ...)   ; one SSE event (data joined), or nil for raw
  :on-chunk  (lambda (string) ...)  ; raw body bytes (decoded utf-8)
  :on-complete (lambda (status headers body) ...)
  :on-error  (lambda (err) ...))
;; => a harness-http-request struct usable with `harness-http-cancel'
```

Implementation notes (non-blocking guarantees):

- `open-network-stream` with `:nowait t` and `:type 'tls` for https. The
  sentinel sends the request on `"open"`, and reports `failed` / `connection
  broken` / `deleted` through `on-error`. DNS + TCP + TLS handshake therefore
  never block.
- The process coding system is `binary`; we decode UTF-8 ourselves. This avoids
  Emacs' stream decoders corrupting a multibyte character split across TCP
  segments.
- Header parsing is incremental; only after `\r\n\r\n` do we start forwarding
  body bytes.
- Chunked decoding is a two-state machine (`size` / `data`), so a chunk header
  split across two segments works.
- SSE framing is line-based; `data:` lines are accumulated until a blank line.
  Multi-line `data:` payloads are joined with `\n` (per the SSE spec).
- `harness-http-timeout` (default 120s) is enforced with a timer that kills the
  process; the timer is the only timer allocated per request.
- `:on-event` is invoked with the raw event string; `harness-provider` performs
  the JSON parse. This keeps `harness-http` protocol-agnostic and testable.
- Nothing here touches a buffer that is visible; the process has no buffer
  (`:buffer nil`), so there is no unbounded text accumulation.

## 5. Providers — pluggable inference backends (`harness-provider.el`)

A provider is anything that can (a) run an inference request and stream the
result back, and (b) report stats about the models it can serve (id, label,
context window, price). The standard OpenAI-compatible HTTP provider and a
hypothetical provider that shells out to a CLI and talks JSON-RPC over stdio are
both first-class implementations of the same interface. **Only the
OpenAI-compatible provider ships**; the process transport that a CLI/JSON-RPC
provider would need is provided as a helper so such a provider is a pure plugin.

### 5.1 The interface

The API is `cl-defgeneric`-based, so a plugin can define its own provider struct
and implement methods on it without touching core:

```elisp
(cl-defgeneric harness-provider-capabilities (provider)
  "Return a plist: (:streaming BOOL :tools BOOL :reasoning BOOL :images BOOL
                    :usage-in-stream BOOL :system-role SYMBOL)")
(cl-defgeneric harness-provider-chat (provider request callbacks)
  "Start an inference request. Return an opaque handle (`harness-provider-cancel' on it).")
(cl-defgeneric harness-provider-cancel (provider handle))
(cl-defgeneric harness-provider-models (provider callback)
  "Asynchronously report the models this provider serves.
CALLBACK is called with a list of `harness-model-stats'. Must not block.")
```

`harness-provider-chat` is called by the agent loop and never by the UI. The
core supplies `harness-provider-chat-async`, a wrapper that resolves the
session's provider name → provider instance, normalises the transcript, applies
capability fallbacks (e.g. renders tool results as text for providers without
`:tools`), and guarantees exactly one terminal callback.

### 5.2 Request and callbacks

```elisp
(cl-defstruct (harness-provider-request ...)
  model messages tools system temperature max-tokens stream metadata)
```

`callbacks` is an open plist of closures; unknown keys are ignored, so the
protocol can grow without breaking providers:

| Key | Signature | Meaning |
|---|---|---|
| `:on-delta` | `(kind text)` | incremental output; `kind` ∈ `text`, `thinking` |
| `:on-tool-call` | `(index tool-call)` | tool call created/updated (see §5.4) |
| `:on-usage` | `(plist)` | token usage, may arrive mid-stream or at the end |
| `:on-done` | `(finish-reason usage)` | exactly once, on success |
| `:on-error` | `(error-symbol message)` | exactly once, on failure |

`finish-reason` ∈ `stop`, `length`, `tool-calls`, `error`, `aborted`.

### 5.3 Stats and pricing

```elisp
(cl-defstruct (harness-model-stats ...)
  provider id label
  context-window max-output
  ;; prices are per 1M tokens, in `currency'
  price-in price-out price-cache-read price-cache-write currency
  capabilities               ; plist, as above
  source)                    ; 'static | 'discovered | 'default
```

- `harness-models` (`defcustom`) is the static model table: a list of plists
  (`:provider :id :label :context-window :price-in ...`) merged into
  `harness-model-stats` by `harness-model-stats` (the lookup function).
  Static entries win; discovered entries fill the gaps.
- `harness-provider-models` may discover models at runtime (`/v1/models`,
  `ollama list`, `--version` probing, ...). Results are cached in
  `harness-model-cache` and refreshed on demand with `M-x
  harness-refresh-models`; discovery is async and failure falls back to the
  static table.
- The mode line, model-selection UI and cost accounting all read stats through
  the single function `harness-model-stats`, so a provider with no pricing
  simply shows tokens and a nil cost (`harness-model-stats-price-p`).
- `harness-usage-cost usage stats` computes the money for one usage plist;
  `harness-session-usage` accumulates per session.

### 5.4 Tool calls over a streaming protocol

A provider must be able to express tool calls even if its wire protocol is not
OpenAI's (e.g. a JSON-RPC CLI that sends whole `tool_use` blocks). The unit of
transport between providers and the agent loop is therefore a
`harness-tool-call` struct, not a JSON delta:

- Providers that stream partial arguments (OpenAI) mutate `args-string` and
  re-emit `:on-tool-call` with the same `index`;
- Providers that emit a complete call (Anthropic-style, JSON-RPC CLI) emit it
  once with `args-string` fully populated.

The agent loop treats both identically: it accumulates nothing itself, it just
records the latest struct per index. `harness-provider--parse-tool-args` parses
`args-string` when the stream ends.

### 5.5 Reference provider: OpenAI-compatible

`harness-provider-openai.el` implements the interface for
`/chat/completions`, covering LiteLLM, DeepSeek, OpenAI, Groq, vLLM, Ollama,
llama.cpp server, OpenRouter, etc. It supports:

- `stream: true` + `stream_options: {include_usage: true}`
- `delta.content` → text deltas
- `delta.reasoning_content` / `delta.reasoning` → thinking deltas
- `delta.tool_calls[i]` accumulation keyed by `index`
- `finish_reason` → terminal event
- tool results and tool calls serialised to the OpenAI wire shape
- a non-streaming fallback when `:stream` is nil

A provider instance is created from a `defcustom` plist:

```elisp
(setq harness-providers
      '((:name local :kind openai :label "LiteLLM"
         :base-url "http://127.0.0.1:4000/v1" :api-key-env "LITELLM_API_KEY")
        (:name work :kind process :label "Acme CLI"
         :command "acme" :args ("serve" "--json") :api-key-env "ACME_KEY")))
```

`:kind` selects the implementing module: `openai` →
`harness-provider-openai`, anything else → looked up in
`harness-provider-kinds` (a registry a plugin populates).

### 5.6 Process transport (`harness-provider-process.el`)

For providers that are an external program rather than an HTTP endpoint, the
core offers a transport (not a provider): a subprocess with
newline-delimited-JSON framing, started lazily, with

```elisp
(harness-provider-process-request transport request &key on-message on-error)
;; request -> one JSON line on stdin;
;; each JSON line on stdout -> (on-message parsed-line)
```

and `harness-provider-process-transport` (struct) managing the child process,
its stderr ring buffer, restart-on-crash, and shutdown. A JSON-RPC CLI provider
is then ~100 lines in a plugin: implement `harness-provider-chat` by writing one
JSON request and translating `on-message` notifications into the callbacks of
§5.2. This transport is what makes the "custom provider" requirement reachable
without core changes; no CLI-specific provider is implemented here
intentionally.

## 6. Session lifecycle, persistence, search (`harness-session.el`)

- **Creation**: `harness-session-create` picks the project via
  `project-current` (falling back to `default-directory`), names the session
  from the project, and appends a header record to a new JSONL file under
  `harness-session-directory/<project-slug>/`.
- **Persistence**: one JSON object per line. Line 1 is the session header
  (`{"type":"session",...}`), later lines are messages, queue snapshots and
  title updates. Appends are `write-region` of a single line, so a crash loses
  at most the in-flight assistant message. On resume the file is read once,
  parsed line by line, and replayed.
- **Index**: `harness-session-index` (SQLite, via the built-in `sqlite-open`)
  stores `(session_id, project, message_id, role, text, ts)`. Rows are inserted
  when a message is finalized (one prepared statement, no file I/O on the main
  thread beyond the row insert). If Emacs lacks SQLite the index degrades to
  `harness--search-fallback`, which greps the session directory in a subprocess.
- **Search**: `harness-search-sessions` runs a `LIKE`-based query, returns a
  list of `(session match-snippet)` and is presented by
  `harness-ui-sessions` (search mode).
- **Resume**: `harness-session-resume` re-reads the file, rebuilds the struct,
  registers it, and opens the conversation buffer. Resumed sessions are idle;
  the previous run state is never restored.
- **Working directory**: every session has one (`harness-session-cwd`),
  starting at the project root.  Tools, `@` attachment lookup and git resolve
  against it, so moving a session -- to a git worktree, for example -- moves
  all of them at once.  `M-x harness-set-working-directory` changes it and the
  header line shows it.
- **Project association**: `project.el` only (`project-current`,
  `project-root`, `project-name`, `project-files`). `projectile` is used only
  as an optional fallback when `project.el` finds nothing.
- **Filtering**: status filters are computed from the live log
  (`harness-session-blocked-p`, `harness-session-active-p`).

## 7. Tools and permissions

### 7.1 Tool registry (`harness-tools.el`)

```elisp
(harness-define-tool NAME
  :description "..."          ; sent to the model
  :parameters JSON-SCHEMA      ; plist, JSON-serialised for the provider
  :category 'edit              ; for permission policies
  :read-only BOOL              ; hint for auto-mode and parallel execution
  :approval 'ask|'never        ; per-tool default
  :function (lambda (args ctx) ...)
  :async (lambda (args ctx done) ...)  ; alternative to :function
  :render (lambda (tool-call) ...)     ; optional custom renderer
  :include BOOL)
```

`ctx` is a `harness-tool-context` struct (`session`, `tool-call`, `cwd`,
`abort-flag`). Synchronous tools return a `harness-tool-result`
(`:content`, `:error`, `:detail`, `:meta`); async tools call `done` with one.
Tools that need the user (approval, `ask_user_question`, subagents) are always
async, because the run loop must stay non-blocking.

Built-in tools: `bash`, `read`, `write`, `edit`, `glob`, `grep`, `todo`,
`ask_user_question`, `spawn_subagent`, `harness_eval`, `harness_define_tool`.

Large outputs are truncated by `harness-tool-truncate` before the result enters
a message (default 64 KB / 2000 lines, tail-biased for command output). The full
text is kept in the tool-call struct so the UI can expand it.

### 7.2 Permissions (`harness-perms.el`)

`harness-permission-policy` is a list of rules evaluated in order:

```elisp
((:tool "bash" :match "^git status" :action allow)
 (:tool "bash" :action ask)
 (:tool "read" :action allow)
 (:category edit :action ask)
 (:default ask))
```

Actions: `allow`, `ask`, `deny`, `auto`. `auto` means "ask the auto-mode
classifier". `harness-permission-check` returns an action; a rule can also be
minted at runtime by the user answering "always allow" (persisted in
`harness-permission-rules-file`).

**Approvals are asynchronous.** Creating one puts the session in
`awaiting-approval`, records a `harness-approval` with a `callback`, and returns
to the event loop. The user resolves it from the conversation buffer, the
sessions list, or `M-x harness-approve-next`, whichever session they are looking
at. The callback then continues the tool call. No `y-or-n-p`, no recursive
edit — other sessions stay fully responsive.

### 7.3 Auto mode

When the verdict is `auto`, `harness-perms--classify` sends the tool call,
the session's working directory and a short policy prompt to
`harness-auto-mode-model` (a cheap model), and interprets a single-word reply
(`allow` / `deny` / `ask`). While it runs the session status is `classifying`.
Failures degrade to `ask`. This mirrors `@czottmann/pi-automode`.

## 8. Agent loop (`harness-agent.el`)

One run per session, all asynchronous:

```
send(text)
  ├─ session status = working, queue drained first
  ├─ append user message, persist
  ├─ provider-chat(messages, tools)
  │    ├─ on-delta text/thinking ─► append to open assistant message, stream hook
  │    ├─ on-delta tool_call     ─► update tool-call struct in place
  │    ├─ on-usage               ─► session usage accumulator
  │    └─ on-done(finish)
  │         ├─ no tool calls ─► status idle, run-finished-hook, drain queue
  │         └─ tool calls    ─► execute in order (async chain)
  │                ├─ permission → allow | ask(approval) | deny | auto
  │                ├─ tool result becomes a role='tool' message
  │                └─ all done ─► provider-chat again (next iteration)
  └─ harness-agent-abort(session) cancels the request, marks messages aborted
```

- Iteration cap `harness-agent-max-iterations` (default 100) prevents runaway
  loops; hitting it appends a system note and stops.
- Tool calls are executed **sequentially** by default (deterministic ordering of
  results); `harness-agent-parallel-tools` allows read-only calls to run
  concurrently, with results still appended in the original order.
- Aborting notifies the provider handle (`harness-http-cancel`), marks the open
  assistant message `aborted`, resolves any pending approvals with `aborted`,
  and sets status idle.
- Queued messages are appended to the transcript when the queue is popped, not
  when they are submitted, so the transcript order matches reality.
- The system prompt is assembled per run from `harness-system-prompt` plus
  `harness-system-prompt-functions` (project instructions, tool list, custom
  personalities) — assembled fresh so plugins can inject context (e.g. current
  file, git status) cheaply.

## 9. UI architecture and extensibility

### 9.1 Conversation buffer (`harness-ui-conversation.el`)

`harness-conversation-mode` derives from `special-mode`; the buffer itself is
writable (`buffer-read-only` nil) but all rendered output is marked with the
`read-only` text property, leaving only the input area editable.

Rendering is incremental and marker-based:

- `harness-ui--render-message` appends a message block and records
  `(start . end)` markers in `harness-ui--markers` (a buffer-local hash keyed by
  message id).
- A `stream` event inserts the delta directly at the block's end marker:
  O(delta) work, no re-render.
- A `messages` event re-renders only the messages whose markers are missing or
  stale (normally: the current message).
- Tool-call blocks are rendered by `harness-ui--render-tool-call`, dispatching
  on the tool's `:render` function, with a default renderer that shows a
  one-line header + truncated output (foldable with `TAB`).
- Renderer dispatch is a registry: `harness-renderers` maps a message/part
  `:kind` to a function. Plugins add renderers with
  `harness-add-renderer`; the core's text/tool/diff/etc. renderers are
  registered the same way, so nothing is special-cased.

Input area: the buffer ends with the prompt text property `harness-prompt`.
`RET` (`harness-ui-send`) submits, `C-j` inserts a newline, `C-c C-k` clears.
Submitting while `working` enqueues instead. The input area is regenerated by
marker after each render so point ends up in the right place and `window-point`
follows the stream only when the user was already at the end (`harness-ui-follow`).

Perf guards: `harness-ui-max-rendered-messages` (default 200) renders only the
tail and leaves a "load earlier" button; `harness-ui-truncate-lines` reuses
`harness-tool-truncate`.

### 9.2 Other views

- `harness-ui-sessions.el` — `harness-sessions-mode` (tabulated-list). Columns:
  project, name, status, model, tokens/cost, updated. Commands: filter by
  status (`/` then `i/w/b/a`), group by project (`g`), view (`RET`), resume,
  rename, delete, kill, search (`s` uses §6 search). Blocked sessions sort first.
- `harness-ui-tree.el` — `harness-tree-mode` derives from `outline-mode`. Each
  message is a heading (collapsible with `TAB`/`S-TAB`); tool calls and results
  are sub-headings. `RET` jumps to the message in the conversation buffer.
- `harness-ui-ask.el` — `harness-ask-mode` uses `widget`. One widget per
  question (`radio-button-choice`, `editable-field`, `checkbox`), a description
  area, and `[Submit]`/`[Cancel]` buttons; `C-c C-c` submits. Answers go back to
  the waiting tool call through an async callback. Modeled on the customize UI.
- `harness-ui-model.el` — `harness-select-model` (`completing-read` with
  annotations), `harness-model-mode` for a browseable list with costs.
- `harness-mode-line.el` — `harness-mode-line-mode` (buffer-local) sets
  `mode-line-format` to a `(:eval ...)` that renders status, model, session
  name, tokens, cost and pending-approval count. Global indicator via
  `harness-global-mode` adds `harness-mode-line-global-string` to
  `global-mode-string`, showing the number of blocked sessions.

### 9.3 Window/buffer placement

`harness-buffer-display` (defcustom, action list consumed by
`display-buffer`) controls where each buffer opens: conversation
(`harness-conversation-display-action`), sessions list, tree, ask buffer.
Defaults: conversation in the selected window, auxiliary buffers via
`display-buffer-at-bottom` / side windows. All go through `display-buffer`, so
users can override with standard `display-buffer-alist` entries.

### 9.4 Keymap layout

`harness-command-map` on `C-c h`:

| Key | Command |
|---|---|
| `C-c h n` | `harness-new-session` |
| `C-c h r` | `harness-resume-session` |
| `C-c h l` | `harness-list-sessions` |
| `C-c h s` | `harness-search-sessions` |
| `C-c h m` | `harness-select-model` |
| `C-c h a` | `harness-approve-next` |
| `C-c h A` | `harness-toggle-auto-mode` |
| `C-c h t` | `harness-tree` |
| `C-c h q` | `harness-queue-edit` |
| `C-c h b` | `harness-switch-buffer` (next blocked session) |
| `C-c h TAB` | `harness-switch-session` (cycle sessions) |
| `C-c h c` | `harness-compact-session` |
| `C-c h w` | `harness-worktree-create` |
| `C-c h W` | `harness-worktree-remove` |
| `C-c h C-w` | `harness-worktree-switch` |
| `C-c h F` | `harness-conversation-search` (whole transcript, chunked) |

In conversation buffer: `RET` send, `C-j` newline, `C-c C-k` clear input,
`C-c C-a` approve, `C-c C-d` deny, `C-c C-e` edit queued, `C-c C-t` tree,
`C-c C-b` abort, `C-c C-f` search the transcript, `C-c C-z` compact,
`C-c C-w` change the working directory, `TAB` completes in the input area and
folds tool output everywhere else, `g` refresh, `q` bury.

## 10. Subagents (`harness-subagents.el`)

A subagent is a normal session with `parent` set. The `spawn_subagent` tool:

```jsonc
{"prompt": "...", "personality": "reviewer", "model": "optional-override",
 "background": false}
```

- The child inherits the parent's provider and model unless `model` or the
  personality's `:model` overrides it.
- `harness-personalities` is an alist of `(name . plist)` with `:model`,
  `:system-prompt`, `:tools`; built-ins: `general`, `planner`, `reviewer`,
  `researcher`.
- The child's conversation buffer is created but **not** displayed; it is
  reachable from the sessions list, `harness-view-subagents`, and
  `harness-switch-session`. "View subagent using the first-class conversation
  view" is exactly this: no separate viewer.
- The parent's tool call completes with the child's final assistant text when
  the child goes idle. `background: true` returns the session id immediately.
- Child status changes are propagated to the parent's mode line so a parent
  blocked on a subagent is visible.

## 11. Queue (`harness-queue.el`)

Submitting while a session is busy appends a `harness-queued-message`, which is
rendered in a distinct "Queued" region at the end of the conversation buffer.
`C-c C-e` opens `harness-queue-mode` (derived from `text-mode`): one message per
section, separated by `\f` (form feed) so parsing is trivial, `C-c C-c` commits,
`C-c C-k` discards, `C-c C-d` deletes the message under point. Order is
preserved and the queue is persisted in the session file so it survives restart.

## 12. Theming (`harness-faces.el`)

Every visual element is a `defface` under the `harness` custom group, derived
from existing Emacs faces (`font-lock-keyword-face`, `success`, `error`,
`warning`, `shadow`, `mode-line-*`) so third-party themes colour the harness
without any work. `harness-status-faces` maps each session status symbol to a
face; `harness-status-glyphs` maps it to a short glyph. A theme can override
both without touching code.

## 13. Plugin system

```elisp
;; ~/.emacs.d/agent-harness/plugins/my-plugin.el
(require 'harness)

(harness-define-tool "deploy" ...)
(harness-add-renderer :kind 'chart :function #'my-chart-render)
(add-hook 'harness-run-finished-hook #'my-notifier)
(define-key harness-conversation-mode-map (kbd "C-c C-p") #'my-command)
(provide 'my-plugin)
```

- `harness-plugins-directory` is loaded by `harness-load-plugins` during
  `harness-setup`; each `*.el` is `load`ed in alphabetical order, and errors
  are caught and reported without aborting startup.
- Plugins can be authored *by the agent itself*: the `harness_eval`,
  `harness_define_tool` and `harness_write_plugin` tools let the running harness
  extend its own session. This is the "dogfood its own core functionality"
  requirement — every feature in this document could be added as a plugin.

## 13.1 Hot reload

Reloading a plugin must not mean restarting Emacs, and it must not leave the
harness in a half-defined state.  The rule is: **use the built-in machinery,
make everything re-loadable, and keep the registries honest.**

What that means concretely:

- **Nothing in the core is stateful in a way a reload destroys.**  Registries
  are `defvar`'d hash tables (re-loading a file does not re-run `defvar` when
  the variable is already bound), sessions and buffers are untouched by
  redefining functions, and live runs keep working because their callbacks are
  closures, not global function references.
- **Registries remember their owner.**  `harness-define-tool` and
  `harness-add-renderer` record the file that defined them
  (`load-file-name` / `buffer-file-name`).  `harness-unload-file` removes that
  file's tools and renderers before the file is re-loaded, so iteration does
  not accumulate dead registrations.
- **Reload is `load`, not a private loader.**  `harness-reload-plugin` calls
  `harness-unload-file` then `load`; `harness-reload-plugins` does that for
  every plugin; `harness-reload` reloads the harness modules in dependency
  order (core first, `harness.el` last) so a change to a lower module is
  picked up exactly like a restarted Emacs would.  `load-prefer-newer` is
  respected, and byte-compiled files are used when current.
- **`harness-plugin-mode`** is a global minor mode that watches the plugin
  directory (and, when `harness-plugin-watch-harness-dir` is set, the harness
  source directory) with `file-notify-add-watch`, debounces per file, and
  reloads a file after it is saved.  This is what makes plugin development
  feel live: edit, save, the tool list in the next request already has it.
- **Coexistence with Doom.**  `harness-reload` calls
  `doom/reload-autoloads` when it exists (guarded by `fboundp`, never
  required), so a harness reload after adding an autoloaded command picks it
  up the way `doom/reload` would.  `C-M-x`/`eval-defun`, `M-x load-file` and
  `doom/reload` all work unchanged; the harness adds no reload engine of its
  own.
- **Reload is visible.**  `harness-reload` reports what it reloaded, and every
  reload runs `harness-after-reload-hook`, which the UI uses to re-render
  conversation buffers so a changed renderer takes effect immediately.
- **The harness can reload itself.**  `harness_eval` evaluates Elisp in the
  running instance and `harness_reload` is registered as a tool, so an agent
  editing the harness (or a plugin) can call it directly and see the result in
  its own next request.  This is the dogfooding requirement: the harness
  extends itself with the same mechanism a person uses.

## 14. Testing

- `test/` holds ERT tests. Nothing in the test suite touches the network: a
  mock provider returns scripted deltas and a mock HTTP server is a plain
  `make-network-process` on port 0 that speaks an HTTP subset.
- `test/harness-test-util.el` provides `harness-test-with-session`,
  `harness-test-with-temp-home`, and a synchronous "wait until predicate"
  helper built on `while` + `accept-process-output` (allowed in tests; it is the
  one place blocking is fine).
- `scripts/test.sh` runs byte-compilation with `-Werror`-style warnings and ERT
  in batch.

## 15. Attachments and long context

### 15.1 `@` attachments (`harness-attachments.el`)

While composing, `@` completes file and directory names of the session's
working directory, fuzzy matched (`harness-attachments--fuzzy-score`), and
what is picked is attached **by content**: the text of a file, or the listing
of a directory, is appended to the message as an `<attached path=...>`
block.  The agent therefore does not spend a turn finding the file and cannot
be defeated by a path that moved in between.

Two halves, deliberately separable:

- **Completion** is a `completion-at-point-function` registered in the
  conversation buffer.  Candidates come from the session's working directory,
  so `@` follows a session into a git worktree, and the candidate cache is
  keyed by the directory's mtime so completion does not re-walk a tree on
  every keystroke.
- **Expansion** is `harness-attachments-expand`, called through
  `harness-user-message-functions` in `harness-agent-send`.  It lives in the
  send path, not the UI, so a plugin, a queued message and a test attach the
  same way.

Budgets are enforced here rather than trusted to the model: a file larger than
`harness-attachment-max-bytes` is truncated with a note, the total per message
is capped, and a directory listing is bounded.  A reference that does not
resolve to an existing path is left as ordinary text, which is what makes an
at sign in prose harmless.

Rendering is the `harness-content-render-functions` hook's first customer: the
conversation view's text renderer offers content to those functions before
falling back to plain text, so the attachment renderer adds folded, labelled
sections without the core knowing about attachments.

### 15.2 Long context (`harness-context.el`)

A session can outlive its model's context window.  Three rules keep that
graceful:

1. **The transcript is not the request.**  `harness-context-build-messages`
   returns what is actually sent: the summary plus a recent tail.  Nothing is
   deleted by compaction, so the UI and search still see everything, and
   `harness-context-summary-addition` delivers the summary through the system
   prompt (a supported extension point) rather than as a fake message.
2. **The buffer stays small.**  The conversation view renders a window of
   messages; `harness-conversation-load-earlier` prepends only what is
   missing instead of rebuilding, which keeps point, folds and the input area
   where they were.
3. **The big walks stay off the main thread.**  Searching a whole transcript
   is chunked across timers (`harness-context-search`), and cross-session
   search remains a SQLite query.  Sizing is O(1) per message because each
   message caches its character count once.

Compaction is a cheap-model request and therefore asynchronous: the run it
interrupts waits for it, not the other way round.  A failure is recorded with
a timestamp (`:summary-error-at`) so a broken summariser is not asked again on
every turn, and the run degrades to the provider's error rather than looping.
Token counts shown in the mode line come from the provider's usage; the
*estimator* here is only used to decide when to compact and is deliberately
crude.

The context module is optional: the agent loop calls it through
`fboundp`-guarded functions and falls back to sending the whole transcript, so
`harness-core` + `harness-provider` + `harness-agent` remain usable headless.

## 16. Git worktrees (`harness-worktree.el`)

An agent that edits files should not do it in the working tree you are using.
A session can create its own worktree on its own branch and work there.

Because every filesystem path in the harness resolves through
`harness-session-cwd` -- tools, `@` completion, the summariser's view of the
project -- pointing the session at the worktree moves all of it at once, and
the header line shows where it is working.  There is no separate "worktree
mode" for any of the other modules to know about.

- **Creating** runs git asynchronously (`git worktree add -b BRANCH PATH`); a
  checkout of a large repository is exactly the kind of thing that must not
  freeze Emacs.  The session's directory only changes once the checkout has
  succeeded.  By default the worktree is created in a sibling directory
  (`<project>-worktrees/<slug>`) rather than inside the project.
- **Cleaning up** is opt-in on session close
  (`harness-worktree-cleanup-on-exit`) and on Emacs exit
  (`harness-worktree-cleanup-on-emacs-exit`), and it never discards work: git
  refuses to remove a dirty worktree and the refusal is reported rather than
  forced away.  `harness-worktree-remove` takes an explicit `force`.
- **The agent can ask for one**: the `worktree` tool exposes create, list and
  remove, because a worktree is as reasonable a request as a directory.

## 17. Open questions / future work

- Anthropic-native provider (currently reachable via LiteLLM or a compatible
  gateway).
- MCP client integration behind the same tool registry.
- Session compaction / summarisation when context grows (hook point exists:
  `harness-system-prompt-functions` + `harness-before-request-hook`).
- Image/attachment parts in messages (struct has `meta`, renderer registry is
  ready).
- Native JSON-RPC bridge to external harnesses (the sibling
  `emacs-llm-agent-status` protocol could be a provider/observer plugin).
