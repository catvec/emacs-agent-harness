# Emacs Agent Harness

The Magit of agentic harnesses: a modular coding agent whose business
logic is Emacs Lisp and whose interface is Emacs itself.  The harness is a
kernel plus modules; the state layer speaks the Agent Client Protocol, and
the Emacs UI is just another ACP client talking to it (over a direct
in-process transport, or TCP for remote sessions).

See [DESIGN.md](DESIGN.md) for the product design and
[docs/architecture.md](docs/architecture.md) for the module contracts.

## Quick start

```elisp
(add-to-list 'load-path "/path/to/emacs-agent-harness")
(add-to-list 'load-path "/path/to/emacs-agent-harness/lisp")
(add-to-list 'load-path "/path/to/emacs-agent-harness/lisp/modules")
(add-to-list 'load-path "/path/to/emacs-agent-harness/lisp/transports")
(add-to-list 'load-path "/path/to/emacs-agent-harness/lisp/ui")

(require 'harness)
(harness-start)
```

`harness-start` loads the default module set and connects the local UI.
Nothing starts before it: a bare harness never shows a UI or calls a
model.

Set an API key (or configure any OpenAI-compatible endpoint):

```elisp
(setenv "OPENAI_API_KEY" "...")
```

Then:

- `M-x harness-ui-chat-new` — create a session in a directory and open its chat.
- Type a message and press `RET`.
- `@` completes file references; `#name` attaches a skill.
- `C-c C-s` opens the session list, `C-c C-m` the model switcher.

## Chat buffer

| key | action |
|---|---|
| `RET` | send (or queue while the agent is running) |
| `S-RET`, `C-j` | newline in the message |
| `C-c C-c` / `C-c C-q` | send / queue explicitly |
| `C-c C-k` | cancel the running turn |
| `C-c C-s` | session list |
| `C-c C-m` | switch model |
| `C-c C-p` / `C-c C-t` | permission mode / thinking level |
| `C-c C-a` | attach a file |
| `C-c C-b` | ask in a side conversation (btw fork) |
| `C-c C-e` | jump back to the message box |
| `q` | bury the chat |

Every action also exists as a clickable button in the composer line.
Thinking and tool calls start collapsed (`▸`); click or press the toggle
to expand.  Collapsed thinking previews its first line, tool lines show
what they acted on and their status, and consecutive safe tool calls
(`read`, `glob`, `search`, ...) coalesce into a summary line so long
transcripts stay readable.

**Plan mode** (`C-c C-p`-style session mode) keeps the agent read-only and
asks it to record a complete plan with the `plan` tool, which appears as a
styled plan block in the transcript before anything is changed.

The agent can run work in a **sub-agent** session (`subagent` tool): a
full session parented to the current one, shown in the session list, whose
final report comes back as the tool result.

The header line shows the session name, status, model, context usage,
cost and permission mode.

## Permissions

Tool calls run through a permission chain.  By default the directory jail
asks before touching files outside the session directory; reads inside
the session are allowed.  Approvals appear in a focused panel at the
bottom of the frame:

- `y` allow once, `a` always allow this session
- `n` reject, `N` always reject
- `C-g` cancel (rejects)

`M-x harness-auto-reload-mode` watches the source tree and hot-reloads the
harness after saves.  A reload validates every file first and restores
the running version on failure, so a bad edit never kills a session.

## Sessions

`M-x harness-ui-sessions` shows the sessions of the current project (or
all with `s`), as a tree with forks and subagents under their parent.
`f` forks, `r` renames, `d` deletes, `RET` opens.  Sessions are scoped to
their project, resume from disk, and record token usage and cost.

## Web search

`websearch` uses the Brave Search API.  Set `BRAVE_API_KEY` (or customize
`harness-search-brave-api-key`) to enable it; without a key the tool
explains what to configure.  Other backends plug in through
`harness-search-register-provider`, and the tool always uses the first
registered provider.

## Remote sessions

The harness runs an ACP agent, and the UI is an ACP client, so a UI can
drive a harness on another machine.  On the host, enable the server:

```elisp
(setq harness-acp-server-port 0           ; free port, recorded on disk
      harness-acp-server-host "127.0.0.1") ; keep it on loopback
```

On the client, `M-x harness-ui-connect`, give the host and the port from
`harness-acp-server-file` (use an ssh tunnel rather than binding the
server to a public address: ACP carries no authentication, and an agent
endpoint can run tools).

## Side conversations

`C-c C-b` opens a **btw** conversation: a fork of the current session in
a side window, asked immediately with your question.  The main session
keeps running untouched; the fork stays visible in the conversation tree,
and `q` closes the side window when you are done.

## Worktrees

`M-x harness-ui-worktrees` (or `C-c C-w` in a chat) manages git
worktrees of the session's repository: create one with a fresh branch and
open a session inside it, open or create a session in an existing
worktree, and remove worktrees you no longer need.  Sessions record their
worktree, so the session list and the conversation tree show where each
one runs.

## Usage and budgets

`M-x harness-ui-usage` (or `C-c C-u` in a chat) opens a full report:
total tokens and cost, spend for today/this week/this month, a graphical
breakdown by project and model, budgets, and a cost-sorted table of every
session.

Every model call appends a timestamped usage entry to the transcript, so
period reports are exact.  Configure budgets with
`harness-usage-budgets`:

```elisp
(setq harness-usage-budgets
      '((:scope project :project "/home/me/work/api"
         :period monthly :amount 25.0 :hard t)))
```

`:hard t` refuses new turns while the budget is exceeded (the agent
explains why in a hint); without it the budget is informational and shows
up in the report with a warning bar.

## Completion providers

`harness-provider-openai-instances` configures any number of
OpenAI-compatible endpoints (OpenAI, OpenRouter, Ollama, ...); each
becomes a set of models in the model switcher.  Provide an API key
through the environment variable named in the instance, or configure
`:api-key` directly.  Models advertise a context window and prices when
known, which drive the usage display, cost tracking and compaction.

## Development

`docs/dev-loop.md` describes the live development loop: a GUI Emacs
daemon that can be evaluated, driven with real keystrokes and
screenshotted, which is how features are verified here.  `scripts/lint.sh`
compiles every file out of tree; `scripts/test.sh` runs the ERT suites.
