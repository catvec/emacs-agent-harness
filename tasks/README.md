# tasks/ — work breakdown

Index of the units of work for `emacs-agent-harness`. Each task file tracks one
logical change: status, subtasks, acceptance criteria, and notes. Never delete a
completed task file.

## Dependency graph

```
01-docs ─┬─ 02-core ─┬─ 03-http ── 04-provider ── 06-tools ── 07-perms ── 08-agent
         │           └─ 05-session ────────────────┘                │
         └────────────────────────────────────────── 09..14-ui ─────┘
                                                                    │
                                        15-subagents 16-queue 17-plugins
                                                                    │
                                                      18-tests 19-review
```

## Inventory

| # | File | Status | Description |
|---|---|---|---|
| 01 | `01-docs.md` | completed | README, DESIGN, AGENTS, task index |
| 02 | `02-core.md` | pending | structs, registries, hooks, utilities |
| 03 | `03-http.md` | pending | async HTTP/1.1 + SSE client |
| 04 | `04-provider.md` | pending | pluggable provider API, OpenAI provider, process transport |
| 05 | `05-session.md` | pending | session lifecycle, JSONL persistence, SQLite search |
| 06 | `06-tools.md` | pending | tool registry and built-in tools |
| 07 | `07-perms.md` | pending | permission policy, async approvals, auto mode |
| 08 | `08-agent.md` | pending | asynchronous run loop |
| 09 | `09-ui-conversation.md` | pending | conversation buffer and input area |
| 10 | `10-ui-sessions.md` | pending | session browser, filters, search UI |
| 11 | `11-ui-tree.md` | pending | outline-based message tree |
| 12 | `12-ui-ask.md` | pending | widget-based ask-user-question UI |
| 13 | `13-ui-model.md` | pending | model selection and model browser |
| 14 | `14-mode-line.md` | pending | per-buffer status line, global indicator |
| 15 | `15-subagents.md` | pending | subagent tool, personalities, model override |
| 16 | `16-queue.md` | pending | queued messages and queue editor |
| 17 | `17-plugins.md` | pending | plugin loader, self-extension tools, entry point |
| 18 | `18-tests.md` | pending | ERT suite, byte-compile gate |
| 19 | `19-review.md` | pending | patch series review over the mailing list |
