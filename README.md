# Emacs Agent Harness

The Magit of agentic harnesses: a modular coding agent whose business
logic is Emacs Lisp and whose interface is Emacs itself.  The harness is a
kernel plus modules; the state layer speaks the Agent Client Protocol, and
the Emacs UI is just another ACP client talking to it (over a direct
in-process transport, or TCP for remote sessions).

See [DESIGN.md](DESIGN.md) for the product design and
[docs/architecture.md](docs/architecture.md) for the module contracts.

## What is implemented

Sessions (metadata plus JSONL transcripts, ACP-shaped), the chat buffer
with markdown, collapsible thinking and tool calls, a queue, @file and
#skill references, attachments (images and audio inlined, clipboard
paste), the conversation tree, compaction, the session list and blocked
notifier, automatic naming, permissions (ask, auto by a cheap model,
non-interactive; directory jail), the sandboxed bash tool, native Emacs
tools, skills, plans and plan mode, sub-agent sessions, the merge queue,
BTW side conversations, git worktrees with a manager, usage and cost
accounting with budgets and a report page, cache-aware turns, the model
switcher, thinking levels, the OpenAI-compatible provider, the Claude CLI
provider for subscription plans, the Brave web search tool, remote ACP
connections (opt-in), safe hot reload, and a kernel that only loads
modules and routes service calls and events.

Known gaps, stated plainly: MCP servers passed to `session/new` are
ignored (with a visible hint); video attachments open externally and have
no thumbnails; audio playback needs an external player and microphone
input is not implemented; the TCP agent endpoint has no authentication,
so keep it on loopback or behind an ssh tunnel.

## Install

Emacs 28.1 or newer is required.  The bundle is self-locating:
`harness.el` puts the `lisp/` directories next to itself on `load-path`,
so a checkout works with only the repository root on `load-path`.  The
package is `harness`; `emacs-agent-harness` is only the repository.

### From a checkout

```elisp
(add-to-list 'load-path "/path/to/emacs-agent-harness")
(require 'harness)
(harness-start)
```

### straight.el

```elisp
(straight-use-package
 '(harness :type git :host sourcehut :repo "catvec/emacs-agent-harness"
           :files ("*.el" "README.md" "LICENSE"
                   "lisp/*.el" "lisp/modules/*.el"
                   "lisp/transports/*.el" "lisp/ui/*.el")))
```

(Keep the `:files` list as it is: straight generates autoloads only for
files in the package root, so the modules are flattened into the build
directory.  `harness.el` finds them either way.)

### Doom Emacs

In `~/.config/doom/packages.el`:

```elisp
(package! harness
  :recipe (:host sourcehut
           :repo "catvec/emacs-agent-harness"
           :files ("*.el" "README.md" "LICENSE"
                   "lisp/*.el" "lisp/modules/*.el"
                   "lisp/transports/*.el" "lisp/ui/*.el")))
```

In `~/.config/doom/config.el`:

```elisp
(use-package! harness
  :init
  ;; (setenv "OPENAI_API_KEY" "...")   ; or another provider's key
  :config
  ;; Start with Emacs.  Drop this line and run `M-x harness-start' by
  ;; hand if you prefer to start the harness per session.
  (harness-start))
```

Then `doom sync` and restart Emacs.  `harness-start` and the other
lifecycle commands are autoloaded.

### Using the checkout on disk instead of the published repository

Replace the remote URL with `:local-repo`; straight symlinks the checkout
into its build directory, so editing the files is enough (no
`git push` + `doom sync -u` round trip):

```elisp
(package! harness
  :recipe (:local-repo "~/documents/ai/emacs-agent-harness"
           :files ("*.el" "README.md" "LICENSE"
                   "lisp/*.el" "lisp/modules/*.el"
                   "lisp/transports/*.el" "lisp/ui/*.el")))
```

With `load-prefer-newer` non-nil and `M-x harness-auto-reload-mode` on,
saving a source file reloads the harness in place.  The mode follows the
symlinks straight creates and watches the true source directories, and
the reload compiles the edited source before swapping it in.

The same recipe works with plain straight:

```elisp
(straight-use-package
 '(harness :local-repo "~/documents/ai/emacs-agent-harness"
           :files ("*.el" "README.md" "LICENSE"
                   "lisp/*.el" "lisp/modules/*.el"
                   "lisp/transports/*.el" "lisp/ui/*.el")))
```

## Quick start

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

### Claude subscription plans

If the `claude` CLI is installed, the harness registers a `claude-cli`
provider that runs completions through it (print mode, stream-json).  It
appears in the model switcher as `claude-sonnet`, `claude-opus` and
`claude-haiku`.  Its own tools are disabled: the harness keeps its
permission model and its own tools.

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

## Merging work back

A forked or worktree session can ask to merge its changes into its
parent's working directory (the `merge` tool, also available to the
agent).  Requests queue on the parent and only one child holds the merge
window at a time; the parent pauses new turns while it does, the child
gets the parent's directory as an allowed path plus a normal turn that
asks it to apply its changes and resolve conflicts, and the window closes
when that turn ends (or after `harness-merge-lock-timeout`).

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
