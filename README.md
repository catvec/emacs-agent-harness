# emacs-agent-harness

A coding-agent harness (Pi / Claude Code class) built entirely in Emacs Lisp,
using native Emacs UI/UX: major modes, hooks, `defcustom`, `tabulated-list`,
`widget`, `outline`, text properties, faces and `project.el`. Asynchronous
throughout — no blocking work on the Emacs main thread, no third-party
dependencies.

`SPEC.md` is the original specification. `DESIGN.md` is the canonical design and
describes exactly what the code does. `AGENTS.md` is the working guide for
agents (and humans) changing this repository.

## Quick start

```elisp
(add-to-list 'load-path "~/documents/ai/emacs-agent-harness")
(require 'harness)

;; Any OpenAI-compatible endpoint: LiteLLM, DeepSeek, OpenAI, Ollama, vLLM,
;; llama.cpp server, OpenRouter, ...  Providers are pluggable (DESIGN.md §5).
(setq harness-providers
      '((:name local :kind openai :label "LiteLLM"
         :base-url "http://127.0.0.1:4000/v1" :api-key-env "LITELLM_API_KEY"))

      harness-models
      '((:provider local :id "deepseek-chat" :label "DeepSeek Chat"
         :context-window 128000 :price-in 0.27 :price-out 1.10))

      harness-default-model "deepseek-chat")

(harness-setup)                 ; load plugins, open the session index
(global-harness-mode 1)         ; mode-line indicator + key bindings
```

Then `M-x harness-new-session` (`C-c h n`).

## Feature map

| Feature | Where |
|---|---|
| Conversation interface, streaming, input area | `lisp/harness-ui-conversation.el` |
| Tool calls with formatted output | `lisp/harness-tools.el`, `lisp/harness-ui-conversation.el` |
| Pluggable inference providers + model/price stats | `lisp/harness-provider.el`, `harness-provider-openai.el`, `harness-provider-process.el` |
| Sessions named per project, resume, filter by status | `lisp/harness-session.el`, `lisp/harness-ui-sessions.el` |
| Search sessions by content | `lisp/harness-session.el` (SQLite index) |
| Tree view of session messages | `lisp/harness-ui-tree.el` |
| Status line: model, cost, status | `lisp/harness-mode-line.el` |
| Sub-agents: inherited/overridable models, personalities | `lisp/harness-subagents.el` |
| Queued messages with editing | `lisp/harness-queue.el` |
| Auto mode (ask a cheap model about commands) | `lisp/harness-perms.el` |
| Ask-user-question UI (customize-style) | `lisp/harness-ui-ask.el` |
| Control over where buffers open | `harness-buffer-display` (conversation), per-buffer `display-buffer` actions |
| Model selection | `lisp/harness-ui-model.el` |
| Themeable faces | `lisp/harness-faces.el` |
| Plugins / self-extension / dogfooding | `harness-define-tool`, `harness-add-renderer`, `harness-load-plugins`, `harness_eval` tool |
| Hot reload of the harness and plugins | `harness-reload`, `harness-plugin-mode`, `harness-unload-file` |
| `@` file/directory attachments (content, fuzzy completion) | `lisp/harness-attachments.el` |
| Per-session working directory | `harness-session-cwd`, `M-x harness-set-working-directory` |
| Git worktrees per session | `lisp/harness-worktree.el` |
| Long context: budgeting, compaction, chunked transcript search | `lisp/harness-context.el` |

## Directory index

| Path | Contents |
|---|---|
| `SPEC.md` | Original requirements (historical). |
| `DESIGN.md` | Canonical architecture and interfaces. |
| `AGENTS.md` | Conventions and workflow for agents working here. |
| `harness.el` | Entry point: custom group, commands, keymap, plugin loader. |
| `lisp/` | Implementation modules (see DESIGN.md §2). |
| `test/` | ERT tests; no network access. |
| `tasks/` | Task breakdown and progress index. |
| `doc/` | Long-form documentation that does not fit the READMEs. |

## Testing

```sh
./scripts/test.sh          # byte-compile + ERT
```

## License

GPL-3.0-or-later, matching Emacs.
