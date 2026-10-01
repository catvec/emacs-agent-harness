# Presentation layer guide

UI modules live in `lisp/ui/`, require only `harness-core`,
`harness-util`, `harness-acp` and `harness-ui` (plus each other where
noted), and talk to the harness exclusively through the ACP connection
held by `harness-ui`.  Never `require` a state module and never call a
`session/…` bus method directly: the same code must work against a
remote harness.

## What `harness-ui` gives you

Connection and requests

- `(harness-ui-request METHOD PARAMS)` → promise; `(harness-ui-call METHOD PARAMS CALLBACK &optional ON-ERROR)` for the common case; `(harness-ui-notify METHOD PARAMS)`.
- Extension methods are `"_harness/NAME"` with params keyed by the bus method's argument names, e.g. `("_harness/session/nodes" (:id SID :opts (:limit 50)))`, `("_harness/session/update" (:id SID :name "x"))`, `("_harness/agent/cancel" (:session-id SID))`.
- Standard ACP: `session/new {cwd}`, `session/prompt {sessionId prompt}`, `session/cancel`, `session/set_mode`, `session/set_model`, `session/load`.

Incoming traffic (add named functions to these lists)

- `harness-ui-update-functions` `(SESSION-ID UPDATE)` for every `session/update`; `(plist-get UPDATE :sessionUpdate)` is one of `agent_message_chunk`, `agent_thought_chunk`, `user_message_chunk`, `tool_call`, `tool_call_update`, `plan`, `current_mode_update`, `_harness/node` (`:node` is a full node plist), `_harness/session` (`:session`), `_harness/hint`, `_harness/session_deleted`.
- `harness-ui-event-functions` `(EVENT ARGS)` for `_harness/event`: `agent/turn-started`, `agent/turn-ended`, `session/queue-changed`, `session/pending-changed`, `session/status`, `agent/quota`, `usage/budget-warning`, `merge/queued`, `merge/finished`, `config/changed`, `harness/reloaded`, …
- `harness-ui-permission-functions` and `harness-ui-question-functions` `(PARAMS RESPOND)`: return non-nil to own the request; call `RESPOND` with `(:outcome (:outcome "selected" :optionId ID))` / `(:answer STRING)`.
- `harness-ui-sessions-changed-hook`, `harness-ui-redraw-hook` (reload/reconnect: rebuild your buffers from scratch).

Session cache and context

- `(harness-ui-session ID)`, `(harness-ui-sessions &optional PRED)`, `(harness-ui-refresh-sessions CB)`, `(harness-ui-read-session PROMPT)`.
- `harness-ui-session-id` is buffer-local; `(harness-ui-current-session-id)`.
- Wire shape: enum values are strings (`"idle"`, `"running"`, `"blocked"`, `"inactive"`, `"ask"`, …), lists are lists, plists are plists, `:false` is false.

Display

- `(harness-ui-display-session ID &optional POSITION)` and `(harness-ui-display-buffer BUFFER POSITION)`; positions `right`, `left`, `bottom`, `full`, `other`; one session per position.  The chat module sets `harness-ui-open-session-function`.
- Faces: `harness-user-face`, `harness-agent-face`, `harness-tool-face`, `harness-tool-error-face`, `harness-tool-title-face`, `harness-thinking-face`, `harness-hint-face`, `harness-summary-face`, `harness-dim-face`, `harness-label-face`, `harness-status-*-face`, `harness-context-*-face`, `harness-queue-face`, `harness-compose-face`.
- Icons: `(harness-ui-icon 'harness-icon-running)` etc.; `(harness-ui-status-icon STATUS)`.  Define new ones with `(harness-ui-define-icon NAME FILE SYMBOL TEXT DOC)`: FILE names a monochrome SVG in `icons/` drawn in `currentColor` (so it takes the surrounding face's colour), SYMBOL is the terminal fallback.  Never use emoji, and avoid codepoints with an emoji presentation (▶ ⏸ ⚙ ℹ ⚠ ▪) as symbols.
- Helpers: `harness-ui-format-context`, `harness-ui-model-label`, `harness-ui-button`, `harness-ui-mouse-keymap`, `harness-format-tokens`, `harness-format-cost`, `harness-relative-time`, `harness-truncate-middle`.
- Markdown: `(harness-ui-markdown-render TEXT)` → propertized string (`harness-ui-markdown.el`).
- Keys: add commands to `harness-ui-map` (prefix `C-c a`) and entries to the `harness-menu` transient (append with `transient-append-suffix`).

## Rules of the house

- Built-in widgets only: `button.el`, `widget.el`, `tabulated-list-mode`, `transient`, `icons.el`, `svg.el`, `image.el`, header and mode lines.  No box-drawing UI except where the medium is a graph.
- Never block: the UI runs in the user's Emacs and the harness in its own process (see "Processes" in architecture.md), so the only way to freeze the user is UI code itself.  Never call the bus (`harness-call`, `harness-method-exists-p`): the modules are not loaded here.  Project roots and file lists come from `harness-files` (`harness-files-project-root`, `harness-files-list` → promise).  Every request is asynchronous; show a lightweight loading state (`harness-dim-face` text, a header-line spinner) and replace it when the result arrives; failures show in the buffer, not just the echo area.
- Every keyboard command has a mouse target: a button, a header-line segment or a mode-line segment with `help-echo`.
- Redraw incrementally with markers and `inhibit-read-only`; never re-render the whole transcript on a delta.
- Buffers must survive `harness-reload`: keep state in buffer-local variables, rebuild from `harness-ui-redraw-hook`.
- Respect the user's theme: faces inherit from standard faces and specify light/dark variants only for backgrounds.
