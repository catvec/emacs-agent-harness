# Emacs Agent Harness (v3)

An agent harness that is native to Emacs: sessions, tools, permissions,
cost tracking and remote control are all Emacs Lisp, the UI is Emacs
buffers, and the default model is Claude Fable 5.1 through the `claude`
command line, so a Claude subscription is enough.

![chat](docs/media/chat-tour.png)

This is a clean-room implementation of [DESIGN.md](DESIGN.md).  The
core only loads modules and passes messages between them; every feature
is a module, and the UI talks to the rest over the Agent Client
Protocol.  The harness runs in its own Emacs process, so nothing it
does can freeze yours; your Emacs keeps only the UI.

## Install

Requires Emacs 29.1 or newer (31.1 is what it is developed on), `curl`,
and the `claude` CLI logged in for the default provider.  Optional:
`bwrap` for the kernel sandbox, `rg` for fast search, `OPENROUTER_API_KEY`
or `OPENAI_API_KEY` for OpenAI-compatible providers, `BRAVE_API_KEY` for
web search.

```elisp
;; straight / Doom
(package! harness :recipe (:host sourcehut :repo "catvec/emacs-agent-harness"
                           :files ("harness.el" "lisp" "scripts")))

;; or a plain checkout
(add-to-list 'load-path "~/src/emacs-agent-harness")
(require 'harness)
(harness-start)          ; loads the UI and starts the harness process
```

`harness-start` enables `harness-global-mode` (prefix `C-c a`) and the
mode line notifier, then starts the harness as `emacs --batch` in the
background.  It gets every `harness-` variable you set; list other
variables it needs in `harness-server-forward-variables`, or put code in
`harness-server-init-file`.  `M-x harness-restart` restarts it with your
current settings; its log is in `M-x harness-show-log`.  `M-x harness-menu` (`C-c a ?`) shows everything.

## Use

| key | command |
|---|---|
| `C-c a n` | new session in a directory (opens on the right by default) |
| `C-c a s` / `C-c a l` | switch session / session list |
| `C-c a a` | task mode: a board of one-session tasks, each in its own worktree and done once merged; `I` adds an ongoing session, and `C-c a m` `T` `p` `i` set the next task up (or change the task at point) |
| `C-c a m` `T` `p` `i` | model, thinking level, permission mode, non-interactive |
| `C-c a f` / `C-c a b` | fork the session / BTW side conversation |
| `C-c a t` `u` `w` | conversation tree, usage dashboard, worktrees |
| `C-c a k` | cancel the running turn |
| `C-c a c` | connect the UI to a remote harness |
| `C-c a R` | reload the harness in place |

In a chat buffer: `C-c C-c` sends (steering the agent if it is mid-turn),
`RET` inserts a newline, `C-c C-k` cancels the turn, `C-c C-q` queues
for the next turn, `@` completes project files as attachments, `/`
completes skills, `C-c C-a` attaches a file, `C-c C-v` pastes a
clipboard image, `TAB` folds a block.
Permission and question panels appear inline above the compose box; the
mode line shows how many sessions need you from any buffer.

Settings persist through `.dir-locals.el` (project, then directory) and
customize (global): `harness-model`, `harness-permission-mode`,
`harness-thinking`, `harness-allowed-directories`, `harness-budget`,
`harness-sandbox-policy`, `harness-non-interactive`.

| | |
|---|---|
| ![permission](docs/media/chat-permission.png) | ![question](docs/media/chat-question.png) |
| ![tree](docs/media/tree.png) | ![usage](docs/media/usage.png) |
| ![worktrees](docs/media/worktrees.png) | ![dark](docs/media/chat-dark.png) |

## Remote control

The harness process serves ACP on `127.0.0.1` (ephemeral port) with a
token per start, written next to the address in the state directory
(`acp-address`, `acp-token`; set `harness-acp-token` to choose it).
From another Emacs, `M-x harness-connect-remote host:port` swaps the UI's
connection; `scripts/harness-acp-stdio` bridges stdio for editors that
spawn ACP agents.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the module
contracts, [docs/ui-guide.md](docs/ui-guide.md) for the presentation
layer and [docs/dev-loop.md](docs/dev-loop.md) for the live development
loop (`scripts/dev.sh`, `scripts/test.sh`, `scripts/lint.sh`).

Modules: `config project store session agent provider provider-claude
provider-openai provider-demo tools tools-fs tools-shell tools-emacs
tools-web tools-agent perms sandbox usage compaction naming skills
worktree merge tasks acp` and, in the presentation layer, `ui ui-chat
ui-sessions ui-tasks ui-tree ui-notify ui-usage ui-worktree ui-btw ui-media`.
