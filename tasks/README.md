# tasks/ — work breakdown

Index of the units of work for `emacs-agent-harness`.  Each task file records
one logical change: status, scope and acceptance criteria.  Completed files are
kept as a record of what was done and why; see AGENTS.md.

## Dependency graph

```
01-docs ─┬─ 02-core ─┬─ 03-http ── 04-provider ── 06-tools ── 07-perms ── 08-agent
         │           └─ 05-session ────────────────┘                │
         └────────────────────────────────────────── 09..14-ui ─────┤
                                                                    │
                        15-subagents 16-queue 17-plugins 18-tests   │
                                                    │               │
                                              17-plugins (hot reload)
                                                                    │
                                                          19-review (pending)
```

## Inventory

| # | File | Status | Description |
|---|---|---|---|
| 01 | `01-docs.md` | completed | Project documentation and conventions |
| 02 | `02-core.md` | completed | Core data model, registries and hooks |
| 03 | `03-http.md` | completed | Asynchronous HTTP/1.1 and SSE client |
| 04 | `04-provider.md` | completed | Pluggable provider API, OpenAI provider, process transport |
| 05 | `05-session.md` | completed | Session storage, project link and search |
| 06 | `06-tools.md` | completed | Tool registry and built-in tools |
| 07 | `07-perms.md` | completed | Permissions, approvals and auto mode |
| 08 | `08-agent.md` | completed | Asynchronous run loop |
| 09 | `09-ui-conversation.md` | completed | Conversation buffer and input area |
| 10 | `10-ui-sessions.md` | completed | Session browser |
| 11 | `11-ui-tree.md` | completed | Message tree |
| 12 | `12-ui-ask.md` | completed | ask_user_question tool and UI |
| 13 | `13-ui-model.md` | completed | Model selection |
| 14 | `14-mode-line.md` | completed | Status line and global indicator |
| 15 | `15-subagents.md` | completed | Subagents, personalities and model inheritance |
| 16 | `16-queue.md` | completed | Queued messages and their editor |
| 17 | `17-plugins.md` | completed | Plugin loader, self-extension tools and hot reload |
| 18 | `18-tests.md` | completed | ERT suite and byte-compile gate |
| 19 | `19-review.md` | pending | Patch series review over the mailing list |
