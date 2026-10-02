# Emacs Agent Harness

Emacs Agent Harness runs AI coding agents in GNU Emacs. It is written
in Emacs Lisp and supports Claude, GitHub Copilot, OpenAI-compatible
APIs and AWS Bedrock.

![A session beside the code it wrote: the agent read the project, added rate limiting, ran the tests and summed up](docs/media/chat.png)

## Features

- **Native Emacs interface.** Chats, the task board, the session list
  and the dashboards are Emacs buffers. They work with the keyboard and
  the mouse and follow your theme.
- **Never blocks your editor.** The harness runs in a separate Emacs
  process, and your Emacs only hosts the UI.
- **Multiple providers.** Claude through the `claude` CLI (subscription
  or API key), GitHub Copilot through the `copilot` CLI,
  OpenAI-compatible endpoints, and AWS Bedrock.
- **Built-in tools.** Tools for files (read, write, edit, search), the
  shell, Emacs (buffers, documentation, `*Messages*`, Emacs Lisp
  evaluation), web search and fetch, sub-agents and skills, plus tools
  that let an agent inspect and drive other sessions and tasks.
- **Permissions and sandboxing.** Four permission modes (Ask, Accept
  edits, Auto, YOLO), per-session directory access, and a kernel
  sandbox for tool processes (bubblewrap or `systemd-run`).
- **Task board.** Run tasks in parallel, each in its own session and git
  worktree, review the results, and merge them back through a merge
  queue.
- **Notifications.** A desktop notification, and a push to your phone
  through Gotify once you set it up, when a task waits for your review
  or is done. Agents can notify you too.
- **Conversation management.** Fork sessions, ask side questions in
  BTW conversations, browse the conversation tree, and let long
  conversations compact automatically.
- **Cost tracking.** Cost per turn, subscription quotas, budgets and a
  usage dashboard.
- **Remote control.** The harness speaks the Agent Client Protocol
  (ACP), so another Emacs or any ACP client can drive it, including one
  on your phone, paired by scanning a QR code.
- **Modular and reloadable.** Every feature is a module, and the whole
  harness reloads in place without losing running sessions.

## Screenshots

| | |
|---|---|
| ![A chat waiting for permission to run pip install, with the allow and deny buttons](docs/media/chat-permission.png) | ![A chat waiting for the answer to a question, with three options](docs/media/chat-question.png) |
| A permission request, answered in the chat | A question from the agent, answered with a digit |
| ![The task board with tasks needing input, in review, in progress, pending and completed](docs/media/tasks.png) | ![The conversation tree of a session, its fork and a BTW](docs/media/tree.png) |
| The task board: each task has a session and a worktree | The conversation tree of a session, a fork and a BTW |
| ![The usage dashboard: a month of cost per day, cost by model, the plan's quota and budgets](docs/media/usage.png) | ![The settings page for one project, which overrides two settings](docs/media/settings.png) |
| Usage: cost per day and model, plan quota, budgets | Settings, here as one project overrides them |
| ![The session list with forks, BTWs and task sessions](docs/media/sessions.png) | ![The worktrees of a project, with their branches and sessions](docs/media/worktrees.png) |
| The session list | The worktrees of a project and their sessions |
| ![A BTW side conversation open under a session](docs/media/btw.png) | ![The harness menu opened from a chat](docs/media/menu.png) |
| A BTW side conversation under its session | The menu, with the chat's own commands |

## Requirements

- GNU Emacs 29.1 or later
- `curl`
- For the default provider: the `claude` command line (Claude Code),
  logged in

Optional dependencies:

| Dependency | Used for |
|---|---|
| `bwrap` (bubblewrap) | Kernel sandbox for tool processes |
| `rg` (ripgrep) | Faster file search |
| GitHub Copilot CLI 1.0 or later (`copilot`) | Models of a GitHub Copilot plan |
| `OPENROUTER_API_KEY` or `OPENAI_API_KEY` | OpenRouter and OpenAI models |
| An AWS profile or `AWS_BEARER_TOKEN_BEDROCK` | Models on AWS Bedrock |
| `BRAVE_API_KEY` | Web search with any model; until it is set, Claude Code and Copilot sessions use the CLI's own web search (`harness-websearch-builtin`) |
| `ffmpeg`, `mpv` | Audio recording and playback, video thumbnails |
| `notify-send` (libnotify), or Emacs with D-Bus support | Desktop notifications on GNU/Linux; macOS uses `osascript` |
| A [Gotify](https://gotify.net) server | Notifications on your phone |

## Installation

### Doom Emacs

In `packages.el`:

```elisp
(package! harness
  :recipe (:host sourcehut :repo "catvec/emacs-agent-harness"
           :files ("harness.el" "lisp" "scripts" "icons")))
```

In `config.el`:

```elisp
(require 'harness)
(harness-start)
```

### straight.el

```elisp
(straight-use-package
 '(harness :host sourcehut :repo "catvec/emacs-agent-harness"
           :files ("harness.el" "lisp" "scripts" "icons")))
(require 'harness)
(harness-start)
```

### Manual installation

Clone the repository:

```sh
git clone https://git.sr.ht/~catvec/emacs-agent-harness ~/src/emacs-agent-harness
```

Then add it to your init file:

```elisp
(add-to-list 'load-path "~/src/emacs-agent-harness")
(require 'harness)
(harness-start)
```

## Getting started

`harness-start` loads the UI, enables `harness-global-mode` and the
mode line notifier, and starts the harness in the background.

1. Press `C-c h n` and choose the directory the session works in. The
   session opens in a window on the right.
2. Type a message in the compose box at the bottom of the chat buffer
   and press `C-c C-c` to send it.
3. Press `C-c h ?` to open a menu of every command.

When the menu is opened from a harness buffer (a chat, the task board,
the session list, the conversation tree, the worktree list, the usage
dashboard or the directory access list), it also lists that buffer's
own commands under the keys they have there. Key chords such as
`C-c C-c` appear as they are, and single-letter keys appear behind `.`:
for example, `. s` runs what `s` does on the task board.

### Choosing the prefix key

All global commands use the prefix `C-c h`. To use another prefix, set
`harness-ui-prefix-key` with `M-x customize-option` or in your init
file:

```elisp
(setopt harness-ui-prefix-key "C-c x")
```

A value set with `setopt` or Customize takes effect immediately. A
value set with `setq` takes effect only if it is set before
`harness-start`.

### The harness process

The harness runs in its own `emacs --batch` process, so model streams
and tool calls never block your editor. The process receives every
`harness-` variable you set. If its modules need other variables, list
them in `harness-server-forward-variables`, or put the code in a file
named by `harness-server-init-file`.

- `M-x harness-restart` restarts the process with your current
  settings.
- `M-x harness-show-log` (`C-c h L`) shows its log.

## Usage

### Key bindings

| Key | Command | Description |
|---|---|---|
| `C-c h n` | `harness-new-session` | Start a new session in a directory |
| `C-c h s` | `harness-switch-session` | Switch to another session |
| `C-c h o` | `harness-open-latest-session` | Open the newest session of the current project |
| `C-c h O` | `harness-open-session` | Open a session chosen by name |
| `C-c h l` | `harness-sessions` | Show the session list |
| `C-c h a` | `harness-tasks` | Show the task board |
| `C-c h t` | `harness-tree` | Show the conversation tree |
| `C-c h f` | `harness-fork-session` | Fork the current session |
| `C-c h b` | `harness-btw` | Open a BTW side conversation |
| `C-c h k` | `harness-cancel-turn` | Cancel the running turn |
| `C-c h D` | `harness-delete-session` | Delete the current session |
| `C-c h m` | `harness-set-model` | Choose the model |
| `C-c h T` | `harness-set-thinking` | Choose the thinking level |
| `C-c h p` | `harness-set-permission-mode` | Choose the permission mode |
| `C-c h i` | `harness-toggle-non-interactive` | Toggle non-interactive mode, in which a session never waits for you |
| `C-c h d` | `harness-directories` | Manage the directories a session may access |
| `C-c h u` | `harness-usage` | Show the usage and cost dashboard |
| `C-c h w` | `harness-worktrees` | List the git worktrees of the project |
| `C-c h S` | `harness-settings` | Show the settings page |
| `C-c h r` | `harness-record-audio` | Start or stop recording from the microphone |
| `C-c h c` | `harness-connect-remote` | Connect the UI to a remote harness |
| `C-c h P` | `harness-remote-control` | Pair phones and other devices, and serve them ACP |
| `C-c h R` | `harness-reload` | Reload the harness in place |
| `C-c h L` | `harness-show-log` | Show the harness log |
| `C-c h ?` | `harness-menu` | Open the menu of every command |

The menu (`C-c h ?`) also renames the session (`r`).

With a prefix argument (`C-u`), the commands that open a session ask
where to show it: `right` (the default, see
`harness-ui-default-position`), `left`, `bottom`, `full` or `other`.

### Chat buffers

Each session is shown in a chat buffer: a read-only transcript with an
editable compose box at the bottom. Typing anywhere in the buffer goes
to the compose box, including `?`, so open the menu with `C-c h ?` or
the `[menu]` button in the header line.

| Key | Action |
|---|---|
| `C-c C-c` | Send the message; while the agent is working, it steers the current turn |
| `C-c C-q` | Queue the message for the next turn |
| `RET` | Insert a newline |
| `@` | Complete a project file to attach; part of a name finds a file in any subdirectory |
| `/` | Complete a skill |
| `C-c C-a` | Attach a project file found the same way (`C-u C-c C-a` attaches any file) |
| `C-c C-v` | Attach the image in the clipboard |
| `C-c C-y` / `C-c C-n` | Allow or deny the newest permission request |
| `C-c C-f` / `C-c C-b` | Show the next or previous diagram of a question's options |
| `C-c C-k` | Cancel the running turn |
| `TAB` | Complete in the compose box; elsewhere, fold or unfold the block at point |
| `C-c C-s` | Search the transcript |
| `C-c C-w` | Copy the last reply |
| `C-c C-e` | Jump to the bottom |
| `C-c C-r` | Redraw the buffer |

Permission requests and questions from the agent appear inline above
the compose box. An indicator in the mode line, visible from any buffer,
shows how many sessions need your attention. Clicking it opens the
session list, or the waiting session itself when only one needs you.

A digit answers a question with that option; any other answer goes in
the compose box. When the options are easier to compare by sight, such
as layouts or architectures, the agent can give each one a diagram,
ASCII art or an image. The diagrams share one area under the options
and show one at a time. Switch between them with the tabs above the
area, `n` and `p` on the panel, `C-c C-f` and `C-c C-b` anywhere in the
buffer, or by moving point onto an option.

The header line shows the session's status, name, model, permission
mode, whether it is `non-interactive` or `interactive`, thinking level,
context and cost. Click the model, the permission mode, the
non-interactive switch or the thinking level to change it. A
non-interactive session never waits for you, which suits a session you
leave to work while you are away. Whatever would ask you for
permission, the auto-mode judge decides instead, whatever the
permission mode. After any denial the agent is told to find another
way. Access to directories outside the session's own still needs you,
so it is denied while you are away. New sessions
start non-interactive when `harness-non-interactive` is set, and task
sessions while `harness-tasks-non-interactive` is. From then on each
session has its own switch.

Opening an inactive session shows it without resuming it. Its compose
box stays available, and the first message you send resumes it.

### Forks and side conversations

`C-c h f` forks the current session. The fork starts from the
conversation so far and continues independently.

`C-c h b` opens a BTW ("by the way") side conversation in a window
below the session. A BTW is a new, empty session that shares nothing
with the session or with other BTWs, which makes it a good place for
quick questions. It has the full chat interface, including the header
line with the model, permission mode and thinking level, which start
from the session's, and whether it is non-interactive. Two extra
controls appear at the front of its header line:

- `[close]` (`C-c C-k`) closes the BTW. A BTW in which nothing was
  asked is deleted.
- `[keep]` (`C-c C-o`) keeps it as a normal session.

### Task board

`C-c h a` opens the task board of the current project. Each task runs in
its own session and, in a git project, in its own worktree and branch,
so several tasks can work in parallel.

- Write a task in the compose box at the bottom of the board and press
  `C-c C-c` to submit it. `C-c C-t` switches the box between **Submit**,
  which starts the task at once, and **Refine**, which has an agent
  write the task up first. A refined task waits in *Pending*, across
  restarts, until you start it with `s`.
- `C-c h m`, `C-c h T`, `C-c h p` and `C-c h i` set the model, thinking
  level, permission mode and non-interactive mode of the next task, or
  of the task at point.
- Finished work waits in *Ready for review*. Press `v` to verify it
  (its branch merges and the task is done) or `R` to send it back to
  its session with feedback. With `harness-tasks-require-verification`
  set to nil, tasks complete without review.
- `I` adds an ongoing session to the board as a task, and `b` opens a
  BTW conversation about the tasks.
- `RET` opens the session of the task at point. From that session,
  `C-c h a` leads back to the board.

Press `?` on the board, or `C-c h ?` in its compose box, to see all of
the board's commands.

### Notifications

The harness tells you when a task's work waits for your review and
when a task is done, so you can leave it working:

- A desktop notification, shown by your Emacs. Clicking it opens the
  task board on that task. It uses `notify-send` on GNU/Linux (or
  Emacs's D-Bus support) and `osascript` on macOS; set
  `harness-notifications-desktop-backend` to choose.
- A push through [Gotify](https://gotify.net), for your phone, once it
  is set up. Create an application in Gotify and give the harness its
  address and token:

  ```elisp
  (setopt harness-gotify-url "https://push.example.com")
  (setopt harness-gotify-token "AbCdEf123")
  ```

  The token can also come from the `GOTIFY_TOKEN` environment variable
  (the address from `GOTIFY_URL`) or from auth-source:
  `machine push.example.com login harness password AbCdEf123`.

`M-x harness-test-notifications` (`N` in the `C-c h ?` menu) sends a
test notification and says what each provider did with it.

- `harness-notifications-providers` lists the providers used, by
  default `(system gotify)`. One that is not set up is skipped.
- `harness-tasks-notify-events` picks the task events that notify you:
  `review` and `done` by default, and `needs-input` for a task that
  asks a question or stopped part way.
- Agents can notify you with the `notify` tool, for example when long
  work you asked for has finished. Clicking such a notification opens
  the session.

## Configuration

`C-c h S` (`M-x harness-settings`) opens the settings page, which lists
every harness option and edits it like a Customize buffer. A toggle at
the top switches between the global value, saved with Customize, and
the value for the current project, saved in its `.dir-locals.el`. Each
setting shows where its effective value comes from.

The following settings can be set per project and per directory through
`.dir-locals.el`. A directory's value takes precedence over its
project's, and a project's over the global value.

- `harness-model`
- `harness-thinking`
- `harness-permission-mode`
- `harness-allowed-directories`
- `harness-budget`
- `harness-sandbox-policy`
- `harness-non-interactive`
- `harness-context-reserve`
- `harness-tasks-directory`

The settings page lists the other options too; they have a global value
only.

## Providers and billing

### Claude

The default provider drives the `claude` command line. How turns are
billed depends on how it is logged in:

- With an API key (or through Bedrock, Vertex or a gateway token), each
  turn shows what it costs.
- With a Claude subscription (Pro, Max or Team), turns cost nothing per
  token. Sessions show the plan and its quota instead, for example `Max`
  with the 5-hour and weekly windows in the chat header.

### GitHub Copilot

Install GitHub Copilot CLI 1.0 or later with
`npm install -g @github/copilot`, then run `copilot login` once. Copilot
models appear in the model picker (`C-c h m`) as `copilot:` models,
listed from what your plan offers. `copilot:default` stands for
`harness-provider-copilot-default-model`.

Copilot runs the agent loop with the harness's tools only (its own shell
and file tools are disabled) and keeps the conversation, so a session
can resume it after a restart. Each turn shows the AI credits it used at
their dollar value (one credit is $0.01), as covered by the plan. The
month's allowance is shown with the plan's quota, and turns past the
allowance are billed when additional usage is enabled. If `copilot` is
not installed or not logged in, the turn reports it and explains how to
fix it.

### OpenAI-compatible APIs

Each entry of `harness-openai-endpoints` registers an OpenAI-compatible
API as a provider, with models named `ID:MODEL`. OpenRouter
(`OPENROUTER_API_KEY`) and OpenAI (`OPENAI_API_KEY`) are configured by
default.

### AWS Bedrock

`bedrock:` models run on AWS Bedrock and authenticate with an AWS
profile or a Bedrock API key (`AWS_BEARER_TOKEN_BEDROCK`). See
`harness-bedrock-endpoints` for the configuration.

### Usage and budgets

The usage dashboard (`C-c h u`) lists every quota window with its reset
time, the plan's extra usage, and the value at API prices that the plan
covered.

Budgets count billed cost only. A budget created partway through a
month can start from what was already spent outside the harness: press
`s` on its line in the dashboard (or use the add-budget wizard) to set
that baseline, which counts until the period rolls over. Organisations
billed per token can fetch the baseline instead: with an Anthropic Admin
API key (`harness-anthropic-admin-api-key`), `I` on a monthly budget
offers the month's API cost minus what the harness recorded.

## Corporate mode

Corporate mode turns off the harness features that could carry data off
your machine. It is meant for work machines whose policy lets code and
data go to the model provider in use and nowhere else.

Turn it on in `config.el` (Doom) or your init file, before
`(harness-start)`:

```elisp
(setq harness-corporate-mode t)
```

It turns off:

- Remote control. The harness serves ACP on this machine only and
  ignores `harness-acp-allow-remote`. Pairing phones and other devices
  is refused, and the UI cannot connect to a harness elsewhere
  (`harness-connect-remote`).
- Network tools. Sessions do not get `web_fetch`, `web_search` or the
  web search that Claude Code and Copilot run themselves. When a model
  calls one anyway, the call is denied and the model is told why.

It leaves alone:

- The model provider. The provider you choose still receives what
  sessions send it.
- Shell commands. They follow the permission mode and the sandbox, as
  always, so a command can still reach the network. Use a permission
  mode that asks before commands run (Ask or Accept edits), and set
  `harness-sandbox-policy` to `required` so that no command runs
  outside the sandbox.

The settings page does not list the option, and no ACP client can
change it. If you change it later with `setopt` or Customize, the
harness process restarts so that the change reaches it.

## Persistence

Sessions and tasks are stored in `harness-state-directory` (`harness/`
in your Emacs directory by default). They survive restarts of Emacs and
of the harness process.

- After a restart, sessions stay closed until you open one again
  (`C-c h s` or `C-c h l`), with its whole transcript. A turn that the
  restart interrupted is marked in the transcript.
- The task board comes back as it was. Tasks waiting for review still
  wait, and tasks that were working carry on by themselves. Set
  `harness-tasks-resume-interrupted` to nil to make them wait for you
  instead.

### Task storage in git projects

The tasks of a git project are stored in its repository, in
`.git/harness/tasks.json` of the main checkout. That directory is shared
by all of the repository's worktrees and is not part of any working
tree, so the records never show in `git status`, never get committed
and never get in the way of a merge. Set
`harness-tasks-store-in-repository` to nil to keep them in the state
directory instead.

Tasks saved by earlier versions move into their repositories
automatically. A copy of the file they came from is kept as
`tasks.json.bak` in the state directory.

### Task files

The board of a git project is also a folder of Markdown files, one per
task, in `docs/tasks/` of the main checkout. Set
`harness-tasks-directory` to use another folder; a project's
`.dir-locals.el` may name its own folder, or nil for none.

Each file starts with YAML front matter (`id`, `title`, `state`,
`column`, `session`, `branch`, `merge`, `model`, `created`, `verified`
and so on), followed by the task's prompt, the request it was written
from, the feedback from each time it was sent back from review, and its
plan.

- The harness writes a file whenever its task changes. It reads back
  edits to the prompt, the request, the title, the model, the thinking
  level, and `state: done`.
- Adding a file creates a backlog task. Deleting a file, or moving it
  into `docs/tasks/archive/`, archives its task, and archiving a task on
  the board moves its file there.
- Front matter keys that the harness does not know are preserved.
- Files are written only in the main checkout, never in a task's
  worktree, and the harness does not commit them.

See the tasks section of [docs/architecture.md](docs/architecture.md)
for the file format.

## Remote control

The harness process serves the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP) on
`127.0.0.1`, on an ephemeral port, with a new token each time it
starts. The address and the token are written to `acp-address` and
`acp-token` in the state directory. Set `harness-acp-token` to choose
the token yourself.

- From another Emacs, `M-x harness-connect-remote` (`C-c h c`) with a
  `host:port` address connects the UI to that harness. An empty address
  connects it back to the local harness.
- `scripts/harness-acp-stdio` bridges ACP to standard input and output,
  for editors that start ACP agents as subprocesses.

### Pairing a phone

A phone (or any other device on the network) can drive the harness
with an ACP client of its own, such as ACP UI, Agmente or Ferngeist.
ACP defines no way to pair a device, so the harness pairs it with a web
link, which works whatever client the phone uses:

1. Press `C-c h P` to open the remote control page, then `[start
   serving]` (`s`). The harness listens on port 4276 of every network
   interface, for ACP over WebSocket and for ACP's own line framing
   (plain TCP clients such as VACP).
2. Unfold the pairing QR code (`TAB` or a click on its heading). It
   starts folded because the code it carries pairs whichever device
   scans it.
3. Scan the code with the phone's camera and open the link. The page
   that opens says the phone is paired and gives the address to add in
   its ACP client, `ws://ADDRESS:4276/acp`.
4. Add a remote agent with that address in the phone's ACP client and
   connect.

A client that supports ACP authentication can also connect first: the
harness offers it the method "Pair with a QR code", whose answer waits
until the QR code is opened on that device.

Each code works once and expires after ten minutes; unfolding the QR
code again or pressing `n` makes a new one, and hiding it drops it. A
pairing belongs to the device's network address. It lasts while the
device uses it, ends once it goes unused for eight hours, ends when the
harness stops serving, and is never saved. The page lists the paired
devices, and `k` or `[unpair]` unpairs one at once. A WebSocket that a
web page opens is never let in by a pairing, since any page the phone
shows could open one. Clients can authenticate with
`harness-acp-token` instead, as the subprotocol `bearer.TOKEN`, an
`Authorization: Bearer TOKEN` header or `?token=TOKEN` in the address.

The connection is not encrypted. Pair on a network you trust, or over a
VPN such as Tailscale, whose addresses also stay fixed per device. The
page shows the address of this machine that QR codes carry, chosen
among its network interfaces (local network first); `a` picks another.

| Option | Default | Meaning |
|---|---|---|
| `harness-acp-remote` | `nil` | Serve other devices; the page turns it on and off |
| `harness-acp-remote-host` | `"0.0.0.0"` | Address the listener binds |
| `harness-acp-remote-port` | `4276` | Port of the listener |
| `harness-acp-remote-address` | `nil` (detect) | Address of this machine in pairing links |
| `harness-acp-remote-code-lifetime` | `600` | Seconds a pairing code is valid |
| `harness-acp-remote-idle-timeout` | `28800` | Seconds unused before a pairing ends |

Corporate mode turns all of this off.

## Architecture

The core only loads modules and passes messages between them. Every
feature is a module, and the UI talks to the rest of the harness over
ACP, so it works the same with a local or a remote harness.

| Area | Modules |
|---|---|
| Core | `config` `project` `store` `session` `agent` `perms` `sandbox` `usage` `compaction` `naming` `skills` `worktree` `merge` `tasks` `notifications` `tasks-notify` `acp` `acp-remote` |
| Providers | `provider` `provider-claude` `provider-copilot` `provider-openai` `provider-bedrock` `provider-demo` |
| Tools | `tools` `tools-fs` `tools-shell` `tools-emacs` `tools-web` `tools-agent` `tools-sessions` `tools-notify` |
| User interface | `ui` `ui-chat` `ui-compose` `ui-sessions` `ui-tasks` `ui-tree` `ui-notify` `ui-usage` `ui-worktree` `ui-btw` `ui-media` `ui-dirs` `ui-config` `ui-qr` `ui-remote` |

Further documentation:

- [DESIGN.md](DESIGN.md): the design the harness implements
- [docs/architecture.md](docs/architecture.md): module contracts
- [docs/ui-guide.md](docs/ui-guide.md): the presentation layer, for
  writing UI modules
- [docs/dev-loop.md](docs/dev-loop.md): the live development loop
- [docs/screenshots.md](docs/screenshots.md): how the screenshots are
  taken, and how to take them again when a view changes

## Development

```sh
scripts/test.sh                              # run every test suite, each in a clean Emacs
scripts/test.sh test/harness-core-test.el    # run one suite (optionally with an ERT selector)
scripts/lint.sh [--checkdoc]                 # byte-compile every file out of tree
scripts/dev.sh start                         # start a clean development Emacs
scripts/media.sh [NAME...]                   # take the screenshots in docs/media again
```

Tests that talk to real models run only when `HARNESS_INTEGRATION=1` is
set. See [docs/dev-loop.md](docs/dev-loop.md) for the full workflow.

`M-x harness-reload` (`C-c h R`) checks and byte-compiles every source
file, then reloads the harness in place, keeping running sessions. If
any file fails to compile, nothing is reloaded.
`harness-auto-reload-mode` reloads the harness whenever one of its
source files changes.

## License

Emacs Agent Harness is free software, released under the GNU General
Public License, version 3. See [LICENSE](LICENSE) for the full text.
