# Emacs Agent Harness

Emacs Agent Harness runs AI coding agents in GNU Emacs. It is written
in Emacs Lisp and supports Claude, GitHub Copilot, DeepSeek,
OpenAI-compatible APIs and AWS Bedrock.

![The task board in the fullscreen layout, a task's session beside it: the feedback the task was sent back with, its fix, and the report it handed in again, waiting to be verified or sent back](docs/media/chat.png)

## Features

- **Native Emacs interface.** Chats, the task board, the session list
  and the dashboards are Emacs buffers. They work with the keyboard and
  the mouse and follow your theme.
- **Never blocks your editor.** The harness runs in a separate Emacs
  process, and your Emacs only hosts the UI.
- **Multiple providers.** Claude through the `claude` CLI (subscription
  or API key), GitHub Copilot through the `copilot` CLI, DeepSeek,
  OpenAI-compatible endpoints, and AWS Bedrock.
- **Fault tolerance.** A connection reset, an empty reply, a refused
  host or a timeout is tried again, bounded and waiting longer each
  time; a rate limit waits the `Retry-After` it asked for. An answer cut
  in the middle is retried as a step, and the partial answer the failed
  step had streamed is dropped rather than sent to the model twice
  (`harness-http-max-retries`, `harness-retry-max-attempts`).
- **Built-in tools.** Tools for files (read, write, edit, search), the
  shell, commands on other hosts over ssh, the user's Emacs (buffers, windows, showing and editing a
  buffer, saving it, documentation, `*Messages*`, and debugging its
  Lisp: describing symbols, finding definitions, tracing functions
  and variables), Emacs Lisp
  evaluation in a separate background Emacs (and in your own Emacs,
  for code a judge model expects to return at once, unless you turn
  `harness-emacs-eval` off; the judge may look up the functions and
  variables it does not know before it rules, and the code can read and
  change the harness's own state with `harness-call`), web search and
  fetch, sub-agents and skills, plus tools that let an agent inspect and
  drive other sessions and tasks and watch the harness's events.
- **Remote hosts.** Agents work on other machines through TRAMP: a
  session in a remote directory, the `ssh` tool, and TRAMP paths given
  to any tool.
- **Permissions and sandboxing.** Four permission modes (Ask, Accept
  edits, Auto, YOLO), per-session directory access, and a kernel
  sandbox for tool processes (bubblewrap or `systemd-run` on GNU/Linux,
  MXC's `mxc-exec-mac` on macOS).
- **Polite with your machine.** The tools that start processes (`bash`,
  `elisp`, `ssh`, and those of plugins, such as the harness
  repository's `open_harness`) hold a slot per machine -- one per
  processor plus a slight burst (`harness-tool-slots-count`), so a task
  board full of agents cannot start processes without end -- and the
  calls waiting go by session priority (low, medium or high; `C-c h +`
  and `C-c h -` raise and lower it, `C-c h y` sets it, and a task's is
  its session's), so the commands of a task you marked high go
  before a low one's. The limit follows the machine's 5-minute load
  average too, so a load that lasts counts and a short burst does not:
  under load fewer slots are handed out, down to one, and the full limit
  comes back as the load falls (`harness-tool-slots-load-window`,
  `harness-tool-slots-load-high`, `harness-tool-slots-load-floor`). The
  test suites run at idle CPU and I/O priority, yielding to whatever you
  are doing.
- **Task board.** Run tasks in parallel, each in its own session and git
  worktree, review the results, and merge them back through a merge
  queue. A per-project limit on running tasks starts the waiting ones
  by priority (low, medium, high). A task can start at once (Submit),
  be written up by an agent first (Refine), or be planned first by a
  strong model, read-only, for a cheaper one to carry out (Plan).
- **Quick search.** Say what you want -- "how do I attach a file?",
  "where did I debug the merge queue?", "the task about the docs" -- and
  a cheap model finds the command to run, the session to open, at the
  message where it was said, or the task, from any buffer, and answers a
  question in words when words answer it. It favours tasks on the task
  board and commands and sessions elsewhere, and looks wider when what
  it favours has no answer (see [Quick search](#quick-search)).
- **Supervisor mode.** A session on an expensive model plans and
  coordinates while workers on cheaper models make the changes. The
  harness enforces it with tools rather than a prompt: the supervising
  session has no write tools, its shell is read-only and offline, and
  every turn ends on a decision. A cheap model judges a new session's
  opening message by default and starts it supervising or hands-on, and
  a note in the harness's own voice says so, with buttons to stop the
  judging for later sessions and to put this one in the other mode; a
  click on the header line (or `C-c h V`) switches it at any time.
  Task sessions follow `harness-supervisor-tasks`, and the task board's
  settings line has the same switch for the task about to be submitted;
  `C-c h V` in the session list switches every marked session.
- **Session list.** Mark sessions as you mark files in Dired, and the
  list's keys and the harness's setting commands act on every marked
  session at once: delete, cancel, make tasks, give a priority, switch
  the model, the thinking level or the permission mode (see
  [Session list](#session-list)).
- **Notifications.** A desktop notification, and a push to your phone
  through Gotify once you set it up, when a task waits for your review
  or is done. Agents can notify you too.
- **Conversation management.** Fork sessions, ask side questions in
  BTW conversations, browse the conversation tree, and compact long
  conversations, automatically or by hand: into a summary, a cheap
  brief one, or a transcript file the model reads from.
- **Session search.** Find any session by what was said in it: words
  in any form, ranked by a full-text index the harness keeps in SQLite,
  the exact text, a regular expression, or, with an embedding model,
  meaning. A match opens its session right where it was said. Agents
  search the same way, and so does the quick search.
- **Secret masking and redaction.** What a tool returns is searched for
  secrets before it is stored or sent to the model, and each one is
  replaced by a placeholder. A secret that got into the transcripts
  anyway is taken out of every copy the harness keeps -- node logs, the
  search index, the conversation logs of Claude Code and Copilot, task
  records, files and buffers -- by naming where it can be read, never by
  typing it, and the sessions it was taken out of say so (see [Secrets
  and redaction](#secrets-and-redaction)).
- **Cost tracking.** Cost per turn, subscription quotas, budgets and a
  usage dashboard.
- **Insights.** A report on how a day, a week or a month of work with
  the agents went: sessions, tools, permissions, tasks, cost and the
  hours you work, with a summary your own model writes. It is built from
  the harness's own records, so it is the same for every provider.
- **Remote control.** The harness speaks the Agent Client Protocol
  (ACP), so another Emacs or any ACP client can drive it, including one
  on your phone, paired by scanning a QR code.
- **Modular and reloadable.** Every feature is a module. Out of the box
  only a small core loads, and you enable the rest in your init file,
  as Doom Emacs's `init.el` does ([Choosing modules](#choosing-modules)).
  Modules of your own load beside them, every module has a page saying
  what it provides and uses ([docs/modules](docs/modules/README.md)),
  and the whole harness reloads in place without losing running
  sessions.
- **A companion pet.** Hatch a small creature of a random species and
  rarity. It stands at the bottom of your chats, of the task board and
  of the session list, blinks and wiggles now and then, once in a while
  turns around as a little 3D model of itself, and has a word to say
  about your work. One switch turns it off everywhere.

## Screenshots

| | |
|---|---|
| ![A chat waiting for permission to run pip install, with the allow and deny buttons](docs/media/chat-permission.png) | ![A chat waiting for the answer to a question, with three options](docs/media/chat-question.png) |
| A permission request, answered in the chat | A question from the agent, answered with a digit |
| ![A call the harness denied, with an [Approve] button under it and the handle the denial named](docs/media/chat-denied.png) | ![That call after the user approved it: marked user-approved, the agent's rerun under it with what the command printed](docs/media/chat-denied-approved.png) |
| A denied call: the harness blocked it, [Approve] lets it run anyway | Approved: the agent reruns the call exactly as it was denied |
| ![The task board with tasks needing input, in review, merging, in progress, in the backlog and completed, each fact in its column](docs/media/tasks.png) | ![The conversation tree of a session, its fork and a BTW](docs/media/tree.png) |
| The task board: each task has a session and a worktree | The conversation tree of a session, a fork and a BTW |
| ![A task's report popped out of the board: its chart large, the test run it quotes, and the banner and box to verify it or send it back](docs/media/report.png) | ![The chart of that report shown larger, in a popout of its own](docs/media/report-image.png) |
| A task's report: verify it or send it back from there | An image of the report, clicked: shown larger |
| ![A chat whose turn runs: a message sent during it says delivered, one sent since says sent, and two queued messages drawn as your messages, each saying queued beside your name with send now, edit and remove buttons, above the line saying what the agent is doing](docs/media/chat-queue.png) | ![A compose box whose message names an image, a file and a task, each reference the same chip: the image's thumbnail, the file's or the task's icon, then its name as a link](docs/media/compose-chips.png) |
| Messages sent mid-turn say where they stand; queued ones send now, one by one | An image, a file and a task, named in the text: one chip, a click opens it |
| ![The usage dashboard: a month of cost per day, cost by model, the plan's quota, the fallback list and budgets](docs/media/usage.png) | ![The settings page for one project, which overrides two settings](docs/media/settings.png) |
| Usage: cost per day and model, plan quota, fallback list, budgets | Settings, here as one project overrides them |
| ![The session list with forks, BTWs and task sessions](docs/media/sessions.png) | ![The worktrees of a project, with their branches and sessions](docs/media/worktrees.png) |
| The session list | The worktrees of a project and their sessions |
| ![The session list with a permission request popped out, its allow and deny buttons under it](docs/media/popout-permission.png) | ![The task board with a question popped out, its options and a box to type another answer under it](docs/media/popout-question.png) |
| A request popped out of the session list, answered there | A question popped out of the task board, answered there |
| ![A BTW side conversation open under a session](docs/media/btw.png) | ![The task board writing a message to the session of a task at work, the compose box in amber](docs/media/tasks-message.png) |
| A BTW side conversation under its session | Messaging a task's session: the box says so, in its colours |
| ![The harness menu opened from a chat](docs/media/menu.png) | ![The quick search opened from a chat: a popout under the code and the chat lists the command that attaches a file, with Run and Describe, and the session that wrote the API guide, with Open and the passage found in it, under a Sessions heading with All matches](docs/media/quick-search.png) |
| The menu, with the chat's own commands | Quick search from a chat: a command to run, and a session found by what was said in it, to open |
| ![The task board filtered by a search typed in its compose box: the query, one task matches, the archive it did and [Undo], and the box, blue, ready for the next search](docs/media/tasks-search.png) | |
| A search in words, typed in the board's own box: the board shows what it is about, and acts | |
| ![The Insights report over 30 days: the totals, the summary the model wrote, and the messages by hour of day and by weekday](docs/media/insights.png) | ![The Insights report further down: the busiest sessions, each tool's calls and failures, the permission decisions and the tasks](docs/media/insights-activity.png) |
| Insights: a month of work, summed up by your model | The sessions, tools, permissions and tasks behind it |
| ![Two chats: an Always deny answer in the left one, a call the rule denied in the right one, both struck through and offering [Redo] after [Undo] was clicked on the right](docs/media/chat-decisions.png) | ![Two chats: an always answer to the cold-cache question in the left one, a default taken unasked in the right one, which names that answer, both offering [Undo]](docs/media/chat-decisions-cold.png) |
| A lasting answer, undone from another session: both offer [Redo] | An "always" cold-cache answer, and a chat it decided for |
| ![The task slots page: four slots in use, each a box with its task, priority, state and time at work; the queue by priority, the next four in line, and how long tasks waited for a slot this week](docs/media/slots.png) | |
| A project's task slots: who holds them, who waits, for how long | |
| ![A chat whose agent replied in three paragraphs, the reply quoted in the compose box with C-c > and answered inline: the middle of the long paragraph elided as [...], the quote split in two with an answer under each part](docs/media/quote-reply.png) | ![A chat whose agent answered a reply that quoted it: the agent's answer quoted in the compose box with the thread under it one level deeper, the user's answers and the agent's message they quoted, and an answer typed under the agent's line](docs/media/quote-thread.png) |
| Answering a reply inline: `C-c >` quotes it, `C-c [` elides what you skip as `[...]`, `M-RET` splits the quote to answer a part | The thread kept: the message the reply answers, and what that answered, nested under the quote |

## Requirements

- GNU Emacs 29.1 or later
- `curl`
- For the default provider: the `claude` command line (Claude Code),
  logged in

Optional dependencies:

| Dependency | Used for |
|---|---|
| `bwrap` (bubblewrap) | Kernel sandbox for tool processes |
| `mxc-exec-mac` (MXC, macOS 15+) | Kernel sandbox for tool processes on macOS |
| `rg` (ripgrep) | Faster file search |
| GitHub Copilot CLI 1.0 or later (`copilot`) | Models of a GitHub Copilot plan |
| `OPENROUTER_API_KEY` or `OPENAI_API_KEY` | OpenRouter and OpenAI models |
| `DEEPSEEK_API_KEY` | DeepSeek models, with off-peak pricing tracked |
| An AWS profile or `AWS_BEARER_TOKEN_BEDROCK` | Models on AWS Bedrock |
| `BRAVE_API_KEY` | Web search with any model; until it is set, Claude Code and Copilot sessions use the CLI's own web search (`harness-websearch-builtin`) |
| `ffmpeg`, `mpv` | Audio recording and playback, video posters (playing videos, and the thumbnails and durations shown; `ffprobe` comes with `ffmpeg`) |
| `notify-send` (libnotify), or Emacs with D-Bus support | Desktop notifications on GNU/Linux |
| `terminal-notifier` 3 or later (`brew install terminal-notifier`) | Desktop notifications on macOS that open what they are about when clicked ([Notifications](#notifications)) |
| A [Gotify](https://gotify.net) server | Notifications on your phone |

## Installation

The repository is on sourcehut and mirrored on
[GitHub](https://github.com/catvec/emacs-agent-harness). Where sourcehut
cannot be reached, use `:host github` in the recipes below, or clone
`https://github.com/catvec/emacs-agent-harness`.

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

### Updating

`M-x harness-update` (`U` in the `C-c h ?` menu) updates the harness
and reloads it in place, keeping running sessions. It updates the git
checkout the harness runs from: the clone of a manual installation, or
the clone that straight.el keeps for a Doom Emacs or straight.el
installation. A checkout straight.el installed is updated with
straight's own pull (`straight-pull-package`), the way its package
manager updates it, in an Emacs that loaded straight.el. Any other
checkout is fast-forwarded to the branch it tracks, or else to the
same-named branch of `origin` (or of its only remote); a detached
HEAD, or a checkout with no remote, is refused with a message that
says so. A checkout with local changes is refused either way, and a
fast-forward changes nothing when the branch has commits of its own.

When the update brings commits, the newest is checked in a separate
Emacs, outside the checkout: `harness.el` must load, and every file
must compile with no merge conflict marker in its code. Only then does
`harness-reload` load the update in your Emacs and in the harness
process. A commit that fails the check is never installed -- a
fast-forward cannot conflict, and a straight.el pull that landed on a
broken commit is put back where it was -- so the harness keeps running
what it ran until a fixed commit arrives. Git and the checking Emacs
run in the background, so Emacs stays responsive.

The commits an update brought are its changelog: each one's subject and
message body, newest first, never diff or file statistics. The version
page (`C-c h v`) shows it with what the last update did, and the
harness log (`C-c h L`) lists the commits by hash and subject.

The harness has no numbered releases: it follows its `main` branch, so
the commit is the version. `harness-update` names it: the commits it
moved between, or the one it is at when nothing is new.

Package managers can update the harness too, with `doom sync -u` or
`M-x straight-pull-package`. The harness loads its files from the
package manager's git clone rather than from its build directory, so
an update takes effect at the next `harness-reload` or restart, with no
rebuild. A Doom package pinned with `:pin` does not follow a branch:
you update it by changing the pin.

## Getting started

`harness-start` loads the UI, enables `harness-global-mode` and the
mode line notifier, and starts the harness in the background. It loads
the core modules, and the others you enable ([Choosing
modules](#choosing-modules)).

1. Press `C-c h n` and choose the directory the session works in. The
   session opens in a window on the right.
2. Type a message in the compose box at the bottom of the chat buffer
   and press `C-c C-c` to send it.
3. Press `C-c h ?` to open a menu of every command, or `C-c h /` to say
   what you want in words and have the command, session or task found
   (see [Quick search](#quick-search)).

When the menu is opened from a harness buffer (a chat, the task board,
the session list, the conversation tree, the worktree list, the usage
dashboard or the directory access list), it also lists that buffer's
own commands under the keys they have there. Key chords such as
`C-c C-c` appear as they are, and single-letter keys appear behind `.`:
for example, `. s` runs what `s` does on the task board.

### Choosing modules

Every feature is a module, and out of the box only the core loads
(`harness-core-modules`): sessions and the turn loop, Claude Code for
the default model, compaction and retries, session names, the file,
shell and Emacs tools with the permissions and the sandbox that guard
them, the tools that ask you a question, plan, keep a todo list,
describe the session and start sub-agents, worktrees, usage and costs,
the settings page, and the chat, the session list and the requests a
session waits on. You enable the rest in your init file,
after `(require 'harness)` and before `(harness-start)`, grouped as
Doom Emacs's `init.el` groups its own:

```elisp
(harness-enable-modules
 :features tasks merge supervisor notifications tasks-notify
 :providers openai deepseek
 :tools sessions handin web
 :ui btw tree)
```

`:features` names modules as they are, `:providers` model providers
(`openai` is `provider-openai`), `:tools` the tools an agent gets
(`web` is `tools-web`) and `:ui` parts of the interface (`tree` is
`ui-tree`). A module brings along what it requires and its UI:
`tasks` loads the task board, `ui-tasks`, and `acp-remote` its
remote control page, `ui-acp-remote`. One that only makes use of
another when it is there leaves it to you: `tasks` merges each task's
worktree back once `merge` is enabled.

To load every module, as the harness did before it had a core:

```elisp
(setq harness-enabled-modules t)
```

- [docs/modules/README.md](docs/modules/README.md#choosing-modules)
  lists every module, with a `harness-enable-modules` form to copy:
  uncomment the ones you want. Each module has a page there saying what
  it is, what it provides and what it uses.
- `M-x harness-enable-module` (`X` in the `C-c h ?` menu) enables a
  module at once: your Emacs loads its UI, and the harness process its
  part when it restarts, which it offers. Add it to your init file to
  keep it.
- `M-x harness-describe-modules` (`O` in the menu) lists the modules
  that run on either side and those that do not, and `M-x
  harness-describe-module` shows a module's page.
- `harness-disabled-modules` leaves modules out whatever would load
  them, the core's included; disabling a module disables its UI too.

The sections below name the modules of the features they describe.

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

Your Emacs reads what the process sends over a local socket. Emacs
does not read a socket while some timer keeps setting itself to run at
once: it runs timers and redisplays, over and over, and a chat would
show nothing new, though clocks and spinners go on ticking, until you
touched the keyboard. Any package's timer can do that, and GUI Emacs
on macOS may also leave the socket unread for a reason of its own.
`harness-acp-client-poll-interval` guards against both: a timer reads
the socket that many seconds apart, 0.1 by default, on every system.
Set it to nil to turn it off; `setopt` takes effect at once. The log
(`C-c h L`) notes the first time a poll read something Emacs had not
delivered.

### Running the latest version

With the `version` module (`:features version`), `C-c h v` (`M-x
harness-version`) shows the commit the harness runs, compares it with the
places newer commits come from, and can update it from there:

- the checkout it was loaded from, as that checkout is now: what a pull
  or a merge brought there runs only after a reload (`C-c h R`) or a
  restart;
- the repository that checkout pulls from: the remote its branch
  tracks, else `origin`, else its only remote, and the branch it tracks
  there, else the same-named one. straight.el sets it to the recipe's
  repository, so an install from GitHub is compared with GitHub and one
  from sourcehut with sourcehut. Nothing needs configuring where one of
  them cannot be reached;
- the local checkouts of the harness that your sessions work in, such
  as a development checkout;
- `harness-version-origins`: any others you list, such as a mirror the
  install does not pull from. It is empty by default.

Each origin says whether it has commits the harness lacks, and lists
them as changelog entries: the subject of each and its message body,
never a diff or file statistics. Nothing is fetched, so the commits are
counted only when a local repository has them, such as a development
checkout. Otherwise the page says that the origin has commits the
harness lacks, without counting them. The page then says what to do:
reload, update with the `[Update harness]` button (`u`), which runs
`harness-update` and reloads, or push first. After an update the page
says what came in, with the same changelog, and, when the reload was
refused, how to restart Emacs or go back. The harness checks by itself,
in its own process, shortly after it starts or reloads and then every
half hour. Git never prompts there. The page shows the last result at
once, and `g` checks again. After a check finds that the harness is behind,
the menu's Version entry says so, and a small icon nags until it is not:
an arrow up in a circle, in the mode line indicator (after its
"harness", even with no session active), in each chat's header line
and in the task board's. Hovering over it names the origins with
commits the harness lacks, and a click opens the page, which says what
to do. The icon goes as soon as the harness reloads, and comes back
only if the check the harness makes a few seconds later finds it
behind still. `harness-ui-version-nag-places` chooses where it shows:
any of `mode-line`, `chat-header` and `board-header` (all three by
default), or nil for nowhere.

## Usage

### Key bindings

| Key | Command | Description |
|---|---|---|
| `C-c h n` | `harness-new-session` | Start a new session in a directory |
| `C-c h s` | `harness-switch-session` | Switch to another session |
| `C-c h o` | `harness-open-latest-session` | Open the newest session of the current project |
| `C-c h O` | `harness-open-session` | Open a session chosen by name |
| `C-c h >` | `harness-prompt-region` | Start a message with the selected text, in any buffer (see [Prompting with the region](#prompting-with-the-region)) |
| `C-c h l` | `harness-sessions` | Show the session list (see [Session list](#session-list)) |
| `SPC` | `harness-ui-sessions-requests` | Pop out what the session at point waits on |
| `b` | `harness-ui-sessions-toggle-blocked` | In the session list, show only the sessions waiting for you, or every session again |
| `m` / `u` / `DEL` | `harness-ui-sessions-mark` / `harness-ui-sessions-unmark` / `harness-ui-sessions-unmark-backward` | In the session list, mark the session at point and move down, unmark it and move down, or move up and unmark the session there (a numeric argument does that many rows) |
| `U` / `t` | `harness-ui-sessions-unmark-all` / `harness-ui-sessions-toggle-marks` | In the session list, unmark every session, or invert the marks of the rows listed |
| `d` / `k` / `x` | `harness-ui-sessions-delete` / `harness-ui-sessions-cancel` / `harness-ui-sessions-deactivate` | In the session list, delete the marked sessions, cancel their turns, or deactivate them; without a mark, the session at point |
| `M-t` | `harness-ui-sessions-make-task` | In the session list, make the marked sessions, else the one at point, tasks on their projects' boards |
| `+` / `-` | `harness-ui-sessions-raise-priority` / `harness-ui-sessions-lower-priority` | In the session list, raise or lower the priority of the marked sessions, else of the session at point (with `C-u`, ask for the level) |
| `p` | `harness-ui-sessions-set-priority` | In the session list, set the priority of the marked sessions, else of the session at point |
| `T` / `I` | `harness-ui-sessions-toggle-tasks-only` / `harness-ui-sessions-toggle-internal` | In the session list, list only the sessions that work on a task (with their sub-agents, forks and BTWs), or show the harness's own model calls, which it leaves out |
| `P` / `C` | `harness-ui-sessions-toggle-pause` / `harness-ui-sessions-toggle-column` | In the session list, pause the live updates or resume them, or show or hide a column |
| `y` / `n` | `harness-ui-sessions-allow` / `harness-ui-sessions-deny` | On the lines of a listed session waiting on a permission request, answer it with Allow or Deny, as the request's own `y` and `n` do |
| `C-c h g` | `harness-search-sessions` | Search what was said in every session: words, the exact text, a regexp or meaning (see [Searching sessions](#searching-sessions)) |
| `C-c h a` | `harness-tasks` | Show the task board |
| `C-c h /` | `harness-quick-search` | Quick search: find a command, a session or a task in words; on the task board, in its compose box (see [Quick search](#quick-search)) |
| `C-c h F` | `harness-fullscreen` | Start or end the fullscreen layout: the task board, session list or a main session on one side, a session beside it |
| `C-x 4 4` / `C-x 5 5` / `C-x t t` | Emacs's `other-window-prefix` / `other-frame-prefix` / `other-tab-prefix` | Before a command that shows a view or a session — `C-c h a`, `C-c h s`, `RET` or a click on a task or session — show it in another window, a new frame or a new tab, as for any buffer |
| `C-c h t` | `harness-tree` | Show the conversation tree |
| `C-c h f` | `harness-fork-session` | Fork the current session |
| `C-c h b` | `harness-btw` | Open a BTW side conversation (`C-u`: on a model of your choice) |
| `C-c h k` | `harness-cancel-turn` | Cancel the running turn |
| `C-c h C` | `harness-compact` | Compact the conversation: choose a summary, a brief summary, a transcript file, a fresh start or a cut of its older context, each with what it costs; a session running a turn is asked to interrupt it or queue the compaction |
| `C-c h D` | `harness-delete-session` | Delete the current session |
| `C-c h m` | `harness-set-model` | Choose the model |
| `C-c h M` | `harness-set-model-all` | Choose a model and switch every current session and task of every project to it |
| `C-c h T` | `harness-set-thinking` | Choose the thinking level |
| `C-c h H` | `harness-set-thinking-all` | Choose a thinking level and set it on every current session and task of every project |
| `C-c h p` | `harness-set-permission-mode` | Choose the permission mode |
| `C-c h +` / `C-c h -` | `harness-priority-raise` / `harness-priority-lower` | Raise or lower the priority of the session in front of you: low, medium or high, the order the harness serves its commands in (with `C-u`, ask for the level) |
| `C-c h y` | `harness-set-priority` | Set the priority of the session in front of you — a task's priority is its session's |
| `C-c h Y` | `harness-set-priority-all` | Give every current session and task of every project one priority |
| `C-c h i` | `harness-toggle-non-interactive` | Toggle non-interactive mode, in which a session never waits for you |
| `C-c h I` | `harness-set-non-interactive-all` | Turn non-interactive mode on or off for every current session and task of every project |
| `C-c h V` | `harness-toggle-supervisor` | Toggle supervisor mode: a session that supervises plans and leaves the changes to workers on cheaper models, a hands-on one may change files itself (see [Supervisor mode](#supervisor-mode)) |
| menu `V` | `harness-set-supervisor-all` | In the `C-c h ?` menu, turn supervisor mode on or off for every current session and task of every project (see [Supervisor mode](#supervisor-mode)) |
| `C-c h d` | `harness-directories` | Manage the directories a session may access |
| `C-c h W` | `harness-move-session` | Move a session to another working directory, and with it to that directory's project (see [Moving a session](#moving-a-session-to-another-directory)) |
| `M` | `harness-ui-sessions-move` | In the session list, move the session at point to another directory |
| `C-c h u` | `harness-usage` | Show the usage and cost dashboard |
| `C` | `harness-cost-compare` | In the usage dashboard, compare what the recorded usage would have cost at other models' prices |
| `C-c h A` | `harness-insights` | Show the Insights report: how a period of work with the agents went |
| `C-c h B` | `harness-delete-budget` | Delete a budget, chosen by name |
| `C-c h w` | `harness-worktrees` | List the git worktrees of the project |
| `C-c h Q` | `harness-slots` | Show the project's task slots: who holds each one and at which priority, who waits for one and for how long (`S` on the task board) |
| `C-c h S` | `harness-settings` | Show the settings page |
| `C-c h z` | `harness-pet` | Show your companion pet, or the egg it hatches from |
| `C-c h r` | `harness-record-audio` | Start or stop recording from the microphone |
| `C-c h c` | `harness-connect-remote` | Connect the UI to a remote harness |
| `C-c h P` | `harness-remote-control` | Pair phones and other devices, and serve them ACP |
| `C-c h v` | `harness-version` | Show whether the harness runs the latest commit, and update it |
| `C-c h R` | `harness-reload` | Reload the harness in place |
| `C-c h L` | `harness-show-log` | Show the harness log |
| menu `x` | `harness-redact-secret` | In the `C-c h ?` menu, take a secret out of everything the harness stored (see [Secrets and redaction](#secrets-and-redaction)) |
| menu `E` | `harness-secrets-list-sources` | In the `C-c h ?` menu, list the sources of the secrets that tool output is masked of; `a` adds one |
| `C-c h ?` | `harness-menu` | Open the menu of every command |

The menu (`C-c h ?`) also renames the session (`r`) and prompts with the
region (`>`). A session you have not named gets a short title from a
cheap model as soon as you send its first message, while the agent works
on it (see `harness-naming-auto` and `harness-naming-model`). A task
gets its title as soon as you submit it (see [Task board](#task-board)).

The session list (`C-c h l`) has a row for each session: its name,
status, kind, model, mode, priority, context, output, output rate, cost,
when it was last updated and its project. Every cell starts under its
header on every row, whatever the cells before it hold -- a name cut to
fit, an emoji, an icon drawn wider than a letter -- and the figures are
right-aligned, so their ends line up; the Cost column has room for the
longest it reads, such as `$0.0058+Max`.
In the session list the harness prefix's setting commands -- `C-c h m`,
`C-c h T`, `C-c h p`, `C-c h i` and `C-c h V` -- change every marked
session, or the session at point when none is marked; the list's own
`m`, `T`, `p` and `i` are other commands, so the prefix is how they are
reached there (see [Session list](#session-list)).

With a prefix argument (`C-u`), the commands that open a session ask
where to show it: `right` (the default, see
`harness-ui-default-position`), `left`, `bottom`, `full`, `other` or
`fullscreen` (see [Fullscreen overviews](#fullscreen-overviews)).

Emacs's own window prefixes work on them as on any buffer: `C-x 4 4`
before a command that shows a view or a session — `C-c h a`, `C-c h l`,
`C-c h s`, or `RET` and a click on a task or session — shows it in
another window, `C-x 5 5` in a new frame and `C-x t t` in a new tab,
and `C-x 4 1` in the selected window. Without one, a view or a session
shows in the frame you run the command in: click a frame, then press
`C-c h a` to open the board there. A session you pick from a list the
harness still has to fetch (`C-c h s`) goes to the frame, and the
window, frame or tab, you asked for, though it shows a moment later.

### Quick search

`C-c h /` (also `/` in the `C-c h ?` menu) finds a command, a session or
a task from anywhere, by saying what you want: "how do I attach a
file?", "where did I debug the merge queue?", "the task about the docs".
It is the [task board's search](#task-board) for the whole harness, and
it takes the line in the same compose box, so there is no prompt of its
own to learn.

![The quick search opened from a chat: a popout under the code and the chat lists the command that attaches a file, with Run and Describe, and the session that wrote the API guide, with Open and the passage found in it, under a Sessions heading with All matches](docs/media/quick-search.png)

A popout opens at the bottom of the frame, with a box to type in. `RET`
(or `C-c C-c`) sends the line to a quick, cheap model
(`harness-tasks-search-model`, the provider's simple tier by default),
together with where you typed it, the harness's commands, your tasks and
your sessions. It answers with the commands, sessions and tasks the line
is about, and the popout lists them, each with its buttons. The line
stays in the box, to be refined. `M-p` and `M-n` bring
back earlier searches, the task board's among them
(`harness-quick-search-history`), `TAB` moves between the buttons, and
`C-g` closes the popout (so does `q` outside the box). The model's
process starts as the popout opens, and what a search costs is recorded
like any other call.

- **Where you are sets what it favours.** On a task board it favours
  tasks, in the session list and in a conversation tree sessions, and
  anywhere else -- a chat, a file, the settings page -- commands, then
  sessions. It only favours: the model reads the rest too, and the
  popout lists commands, sessions and tasks in the order the place
  suggests. Its first line says where the search was opened from and
  what it favours; `[Search sessions]` and `[Search commands]` ask the
  same line again, favouring those.
- **A question gets an answer in words.** When words answer the line --
  "how do I attach the API guide?", "what does verify do?", "how many
  tasks failed?" -- the model writes the answer too, in Markdown, and the
  popout shows it first, above what the search found, rendered and
  whole: no line of it is cut, however long it is. The popout grows
  taller for it than for a list, up to
  `harness-quick-search-answer-height` of the frame (0.8). An answer
  taller still keeps the box at the bottom, the end of the answer above
  it, and `M-v` scrolls back to its start. A line that only finds
  something, or orders something done, gets no answer in words: the
  list is the answer. A model that writes prose instead of the JSON it
  is asked for has its prose shown as the answer, rather than the search
  failing.
- **Commands** come with their keys and what they do. The model knows
  the harness menu's commands, those under the `C-c h` prefix, those the
  mode of the buffer you are in lists in the menu (a chat's `C-c C-c`, a
  board's `v`) and every other interactive `harness-*` command, each
  with the key it has where you are, what the menu calls it or the first
  line of its documentation, and the mode it belongs to. `[Run]` runs
  one in the buffer you opened the search from, as if you had typed it
  there, and shows only for a command that runs there; `[Describe]`
  shows its documentation. Only harness commands are offered and run,
  never any other command of Emacs. The walk over every symbol of Emacs
  that finds them is done ahead, while Emacs is idle, and again after
  files load, so opening the search or sending a line does not repeat it
  each time (a command defined a moment ago may be missing for a
  second).
- **Sessions** are all of them, not only the tasks': chats, BTW side
  conversations, sub-agents and forks, of every project, the one you are
  in left out. They are found by what was said in them, with the
  [session search](#searching-sessions), and not only by their names.
  Where the search favours sessions (the session list, a conversation
  tree, `[Search sessions]`), it first looks in every transcript for the
  words of your line that say something -- "where did I write the API
  guide?" looks for "write API guide" -- and hands the model what it
  found. Elsewhere the model may ask to look, once, and the same search
  answers; it takes the session search's syntax (`"a phrase"`, `pars*`,
  `OR`, `-word`). `[Open]` opens a session in its project, as the
  session list does, and, when your words were found in what was said
  there, at that message with the words highlighted, as `RET` on a match
  does in `C-c h g`; the passage found shows under the session.
  `[All matches]`, on the Sessions heading, opens the session search's
  own view (`C-c h g`) of every session that matches the words the
  search looked for -- the same "write API guide", or what the model
  asked the transcripts for -- with every match.
- **Tasks** are the project's, as the board's search reads them.
  `[Board]` shows one on its board, with the others the search found. An
  order about tasks ("stop the docs task") is only proposed in the
  popout: `[Do it]` does it and `[Skip]` leaves it.
- **It does not stop at nothing.** When what the place favours has no
  answer, the model is told to look beyond it -- once, in the sessions'
  transcripts or in the commands -- and to say so in a note above the
  results ("No task matched; these sessions mention it."). If it still
  answers with nothing, the search adds the sessions and commands that
  come nearest the line itself (the sessions by what their transcripts
  say), with a note that says so, and only when there is nothing at all
  does the popout say "Nothing found".

On a task board `C-c h /` is the board's own search, the one `/` starts
there, which filters the board. The session list keeps `/` for its fuzzy
filter; `C-c h /` opens the quick search there.

### Chat buffers

Each session is shown in a chat buffer: a read-only transcript with an
editable compose box at the bottom. Typing anywhere in the buffer goes
to the compose box, including `?`, so open the menu with `C-c h ?` or
the `[menu]` button in the header line. A region selected in the
transcript is dropped on the way, not deleted. On a request's panel the
panel's own keys answer it instead: a question's digits, up to its
number of options, and a permission's `y`, `s`, `a`, `n` and `N`, and
`e` when it has a pattern to edit. In the compose box those keys type,
so `C-c .` is how you aim a key at a panel from there (see
[Pressing a panel's key from the compose box](#pressing-a-panels-key-from-the-compose-box)).

| Key | Action |
|---|---|
| `C-c C-c` | Send the message; while the agent is working, it steers the current turn |
| `C-c C-q` | Queue the message for the next turn |
| `RET` | Insert a newline |
| `@` | Complete a file to attach: part of a name finds a project file in any subdirectory, a path (`/`, `~/`, `./`, `../`) any file. The file's `@path` stays in the text as a chip you can click; one typed out in full attaches its file when the message is sent. `@task:` completes a task of the project the same way |
| `/` | Complete a skill, or `/compact` |
| `C-c C-a` | Attach a file found the same way, by part of a name or by path (`C-u C-c C-a` browses the file system), or a task as `task:ID` |
| `C-c .` then a key | Press that key on the panel above the box: a question's digit, a permission's `y` or `n`. With a numeric argument, on the Nth panel up. `C-g` quits |
| `M-<` / `M->` | Go to the top or the bottom of the compose box. Pressed again, from outside the box or with a prefix argument, they go to those of the buffer |
| `C-y` | Attach the image on the clipboard (or the files a file manager copied), keeping `kill-ring` out of it; text yanks as usual |
| `M-y` | Right after a media yank, swap it for an earlier capture; otherwise the usual `yank-pop` |
| `C-c C-y` / `C-c C-n` | Allow or deny the newest permission request |
| `C-c C-p` | Edit the pattern the newest request about a path outside the session's directories is answered for |
| `C-c C-f` / `C-c C-b` | Show the next or previous diagram of a question's options |
| `C-c C-k` | Cancel the running turn |
| `C-c C-u` | Go to the parent session: the session this one was forked from or started by (also on the `↑` in the header line, when there is one; a seed conversation in between is skipped, being a shared prompt cache rather than a conversation) |
| `TAB` | Complete in the compose box; on a permission request cut short, show its whole input; elsewhere, fold or unfold the block at point |
| `M-n` / `M-p` | Jump to the next or previous message: what you or the agent wrote, the agent's plan included. Thinking and tool calls are passed over, so a long run of them takes one key to get past |
| `M-N` / `M-P` | Jump to the next or previous message you wrote — the prompt the session started with included, however far down it is |
| `C-M-n` / `C-M-p` | Jump to the next or previous tool call or thinking block; a run of tool calls folded under one summary line is one stop. Coming from the box, the first jump lands on the newest one |
| `C-c C-s` | Search the transcript |
| `C-c C-t` | Show or hide the session's todo list |
| `C-c C-w` | Copy the last reply |
| `C-c >` | Quote, to reply: the selected text, or the agent's reply or plan at point (elsewhere the one above it, from the box the last), goes in the compose box as a Markdown quote, point under it. An answer that quotes nothing comes with the message it answers nested under it, so a thread's replies quote each other. A selection keeps its code blocks, inline code and links as Markdown, and leaves out what a fold hides. It is the [compose-quote](lisp/vendor/compose-quote/README.md) library's command (see *Answering inline*, below). `C-c h >` does it for the selection of any buffer (see [Prompting with the region](#prompting-with-the-region)) |
| `M-RET` | In a quote in the compose box: split it where point is, to answer that part: the quote above, an empty line for your answer, the quote below |
| `C-c [` | In a quote in the compose box: elide the region, or the rest of its paragraph from point (with `C-u`, the rest of the quote), leaving `[...]`, so a bit of front matter stays for context |
| `C-c C-e` | Jump to the bottom; while the window is scrolled away from it, the header line shows `↓ newer messages`, which does the same |
| `C-c C-r` | Redraw the buffer |
| `C-c C-z` | Bury the session: its window shows the buffer it showed before (a side window closes) |

`C-c C-q` queues a message for the next turn. A queued message shows
just as it will once sent, your name, its text and its attachments, but
with a dim `queued` beside your name, so it never looks sent, and its
buttons. The queued messages come last in the conversation, the line
saying what the agent is doing under them. `[send now]` sends that
message alone, and the others stay queued: while the agent works it
gets the message at its next step, otherwise the message starts a turn
of its own (the tooltip says which). `[edit]` takes a message back into
the box and `[×]` drops it. A message sent while a turn runs, queued or
not, gives its state on the line with your name: *sent* until the model
takes it at its next step, then *delivered*. Nothing is said once the
turn is over, unless the model never got the message because you
cancelled the turn: *not delivered*, and the next turn reads it.

**Answering inline.** A long message is seldom answered by one reply.
`C-c >` puts it in the box as a quote; once point is in a quote the echo
area names the two keys that take it apart (`compose-quote-inline-hint`
turns that off). `M-RET` splits the quote where point is: the part above
stays a quote, the empty line it opens is for your answer to that part,
and the quote goes on below it. `C-c [` cuts what you do not answer down
to `[...]`, so a bit of its front matter stays for context while the
rest goes. What you send is the box as it stands, the quotes and your
answers one under the other, and one undo undoes a split or an elision.
These keys are the [compose-quote](lisp/vendor/compose-quote/README.md)
library's, which the harness vendors in `lisp/vendor/compose-quote`. It
needs nothing of the harness and works in any Emacs buffer, a mail reply
too: `(add-hook 'message-mode-hook #'compose-quote-mode)` gives
`message-mode` the same three keys.

The thread keeps its quotes. An answer that quotes nothing of its own is
quoted with the message it answers nested under it, one `>` level
deeper, so the replies of a thread quote each other and what the thread
is about reads back in order:

```
> All green in the logs.
>
> > > The build is green.
> >
> > Good.
> >
> > > The deploy is pending.
> >
> > I will watch it.
```

A message that quotes something already is quoted as it stands: its
writer answered inline, so it carries the thread itself. The agent
answers inline too: a message of yours that quotes the agent's and
answers under the quotes is sent to the model with a note saying so, so
its answer keeps the quotes and goes on under them, and the thread a
thing is discussed in goes on from both sides. The note is the
harness's own, and the transcript keeps your message as you wrote it.

Drag a file from your file browser onto a chat or the task board and it
attaches. Drag a *link* — an image from a web page, a video, any address
— and it downloads in the background with curl, behind a chip that shows
a spinner, a progress bar and the size; the file attaches with its own
name when it arrives, and sending waits for it. A link to a web page is
not downloaded: its address goes into the message as text, which is
usually what you wanted. Images and videos show a thumbnail in the
attachment chip (`harness-compose-thumbnail-lines`; videos need
`ffmpeg`), so you can see what you are about to send. Each attachment
has a line of its own above the box, fitted to the window: a long name
is shortened in the middle, and hovering over it shows the whole path.

Images drag *out* too: press on an image in the transcript, on an
attachment chip's thumbnail or name, or on an image of a report or its
larger popout, move the mouse, and drop it on a file manager, a browser
or a chat app, which receives it as a file. A click without moving
still opens the image as before, and letting go over Emacs again
cancels. An image that only exists in the conversation, like a pasted
screenshot, is first written to the session's temporary directory (see
below). Dragging works on a graphical frame where Emacs can start
drags (X, macOS, Haiku), and the hover text says when an image can be
dragged.

Copied an image (in a browser, or with a screenshot tool)? `C-y` in a
compose box attaches it instead of yanking text: it goes on the *media
ring*, a kill ring of its own that only compose boxes read, so no other
mode ever yanks a picture as raw bytes. `M-y` right after goes back
through earlier captures, their thumbnails showing in the box, and
`C-u M-x harness-compose-attach-clipboard` picks one by name. Files
copied in a file manager attach the same way, `yank-media` finds them
too, and `M-x harness-compose-attach-clipboard` chooses among the
clipboard's other MIME types. The box binds no `C-c C-v`: in a chat
that key is the review banner's `[Verify]`, so a screenshot never has
to fight the banner's key. Set
`harness-compose-yank-media` to nil to leave `C-y` and `M-y` alone.

Whatever you attach, paste or drop also puts a reference to it into the
message, where point is (or at its end), so a sentence can name it. The
reference shows as a small chip, the same chip for every kind of
attachment, in the colour of a link:

- An image is `[image 1]`, `[image 2]`, and so on, led by its thumbnail.
  You can write "in [image 2] the button is cut off" and the model knows
  which screenshot you mean: it gets the same `[image 2]` right before
  that image. Numbers never shift under a sentence you already wrote: a
  new image takes the number after the highest one attached, and every
  message starts again at 1.
- A file is `@lisp/notes-util.el`, its path in the project (else under
  `~` or absolute), led by a file icon. The chip shows the file's name,
  `@notes-util.el`, shortened in the middle when it is long; the text
  keeps the whole path. It is what `@` completes, so a file you complete
  or attach with `C-c C-a` looks the same.
- A task is `@task:t-1a2b`, with the task's title after it and a task
  icon. The model gets the task as text: its id and title, column, priority,
  session and branch, then its prompt (cut at 3,000 characters), and the
  task tools to read more.

Click a chip (`mouse-1` or `mouse-2`) to open what it names: a file or an
image in a buffer, a video or a sound in its player, a task in its
session's chat, or on the task board while it has no session yet.
`mouse-3` offers *Open*, *Remove from the message* and *Copy the path*
(a task's id, for a task); the tooltip says what the chip is. Point
steps over a chip as a whole. Delete the reference (`DEL` right after it
takes it whole) and the attachment goes with it; undo or yank the
reference back and the attachment returns. The `×` on an attachment's
line removes its references too. The attachment lines above the box
stay, each with its larger thumbnail, size and `×`, since they also hold
downloads still on their way and files with no reference, such as one
whose name has a space. In the transcript a sent message keeps the look
of its references -- the tokens of images, the `@` reference of each file
and `@task:` ones are in the chip's colour -- and each image has its token
over it; a task you attached follows your words as a paragraph of its own.

`M-x harness-compose-attach-task` attaches a task by its title, `C-c C-a`
with `task:ID`, and so does `@task:` in the box, which completes the
project's tasks by id with their titles and columns. On the task board,
`@` on a task's card attaches that task to the board's box (see
[Task board](#task-board)).

A message you send while the agent works takes its images along the
same way, whichever provider runs the session: Claude Code and Copilot,
which hear such a message inside the next tool result, are handed its
images with that result, each after its token.

Permission requests and questions from the agent appear inline above
the compose box. An indicator in the mode line, visible from any buffer,
shows how many sessions need your attention, and nags with a small
icon while the harness is not the latest (see
[Running the latest version](#running-the-latest-version)). Clicking it opens the
session list on just the sessions waiting for you, from every project
(`M-x harness-sessions-waiting`), under a banner that counts them. A
line under each says what it waits on, with the task board's buttons
to settle it there: `[Allow]` and `[Deny]` for a permission request,
which `y` and `n` press too, and `[Answer…]` for a question, which pops
it out.
`RET` or a click on a session opens it in its project: with Doom
Emacs's workspaces, the project's workspace becomes current first, with
the windows and buffers you left in it, and a session already showing
there gets its window selected instead of opening again. The project's
workspace is the one named after the project, or one that records the
project's directory (as some forks of Doom do); of two, the one with
the project's files open. A project without a workspace gets a new one,
as switching project makes it but without asking for a file, and the
session takes its window instead of opening beside Doom's dashboard
(`harness-ui-switch-project-function`, nil to never switch). `b`, or
the banner's `[Show all]`, shows every session again. With nobody
waiting, the click opens the session list as usual.

A permission request shows the call's input on one line, cut short to
fit. When that line leaves something out, such as the rest of a long
command or a second line of it, it ends in `[Show all]`
(`[Show all 2 lines]` when a value has lines the first one hides).
Click it or press `TAB` on the request to see the whole input in place,
each value on a line of its own and a long one verbatim under its name;
`[Show less]` or `TAB` again puts it back on one line. This works the
same in the chat and in the popout the session list and the task board
open with `SPC`, and a request shown whole in one shows whole in the
other.

While the agent works through a todo list (`todo_write`), the list stays
in view: a panel above the compose box gives the progress and lists
every item with its state. `C-c C-t`, `TAB` on the panel, or a click on
its fold button folds it to the progress and the item in hand and
brings the items back; the list disappears when the agent clears it.

A session that other sessions merge their work into -- the sub-agents it
started, in worktrees of their own -- shows that queue in the same place,
a panel of its own above the compose box: one line per child, marked
queued, merging, in conflict, merged or failed, with the reason the
queue gave, the live merges first and the last few finished under them.
It follows the merges as they happen, and disappears when the queue is
empty and nothing was merged recently.

A session that started sub-agents lists the ones still running there
too, in a panel of their own above the compose box: one line per child
with its name, which opens the child when clicked, how long its turn has
gone on and what it is doing now -- the text the activity line gives, or
its current todo item until its first activity arrives. It follows the
children as they work, draws at most once a second, and disappears when
none is running. A seed conversation (see **Cache seeds**) is left out,
being no worker.

A tool call that runs for a while says what it is doing under its own
header, in dim lines that go when the call ends. `spawn_agent`, which
returns as soon as its child starts, makes that note of the child as it
starts it -- what the child does now, a recap of it, made again when it
goes stale, and its context against the window it compacts at, its
turns, steps and tool calls; `task_wait` shows the same for every
session it waits on, a section each; a `bash` command still running
says how many lines it has written and shows the latest one.

![A session's chat after its spawn_agent call started a sub-agent, and the sub-agent's own chat beside it: the panel above the session's compose box lists the running child, with its name as a link, how long its turn has gone on and what it is doing, and the note under the child's bash call says it is still running with the latest line](docs/media/notes.png)

A session may use its working directory, its worktree, the directories
in `harness-allowed-directories` and the ones you grant it. It also has
a temporary directory of its own, `/tmp/harness-UID/ID/` (under
`temporary-file-directory`), which needs no grant. The agent keeps
scratch files, logs and screenshots there. Its shell commands can write
there even in the sandbox, where the rest of `/tmp` is private to each
command. The directory is made with the session, made again if it went
missing, and deleted with the session. `C-c h d` lists all of these
directories. Remote sessions have no temporary directory.

In the sandbox a shell command sees the system directories and, of
yours, only these directories, each at its own path: a directory you
grant the session reaches its commands at once, as it reaches the other
tools. `~` is your home directory there as well, emptied, so
`~/.emacs.d/x` names the same file inside as outside, and only what the
session may use shows in it. The `elisp` tool's background Emacs runs
in the same sandbox and sees the same directories, plus the harness's
own Lisp (`harness.el` and `lisp/`), read-only, so it can load it.

On macOS the sandbox is MXC's `mxc-exec-mac` (macOS 15 or later; set
`harness-sandbox-mxc-program` when it is not on your `PATH`), which
confines a command with Seatbelt rather than with mounts: the same
directories are readable or writable at their own paths, but the rest
of `~` cannot be read rather than being emptied, `/tmp` cannot be
written (each command gets a private `$TMPDIR` instead, removed when
it ends), and a command's output arrives only once it exits.

Every permission request offers the same five answers, under the same
names and keys wherever it shows (the chat, BTW, the popout, an ACP
client): `[Allow]` `y`, `[Allow for session]` `s`, `[Always allow]` `a`,
`[Deny]` `n` and `[Always deny]` `N`; the session list and the task
board show the first and the fourth. *Allow* is the narrowest yes and
records nothing: it lets the call run, or reach the path it asks about,
this once, and for the agent's own request for a directory
(`request_directory_access`), which is no call to run, it grants the
directory until the agent's turn ends, so the agent can do what it
asked for and has to ask again in a later turn. A button's tooltip, and
the echo area after it, say what it covers for the request at hand.
The one exception is an agent's request to move a session (see
[Moving a session](#moving-a-session-to-another-directory)), which you
answer with `[Allow]` or `[Deny]` only.

A permission request about a path outside the session's directories
(a tool call reaching there, or the agent asking for a directory) is
answered for a glob pattern, not for a single file. By default the
pattern covers everything in a directory. For a tool call that is the
root of the repository the path lies in (the closest directory above it
with `.git` or another version control directory), so that one answer
opens the project or package the agent is finding its way around, such
as `~/.emacs.d/**`, rather than one directory of it after another. When
there is no repository, or its root is or holds your home directory or
the session's own working directory, it is the directory that holds
the file, or the directory itself, such as `~/notes/**`; for the
agent's own request, the directory it asked for. The panel shows the
pattern on its own line. Press `e` on the panel, `C-c C-p`, or click
`[Edit]` to change it in the minibuffer, either more specific
(`~/notes/*.org`, a subdirectory, one file) or less (`~/**`). `*`
matches within a name and `**` across directories, and `M-n` offers
patterns around the request's own, from the file itself up to the
directory above the pattern's. The answer grants or denies the
pattern: once (for the one call, or until the turn ends for the agent's
own request), for the session, or always (as an entry of
`harness-allowed-directories`, or a rule in `harness-perms-rules` for
*Always deny*). Any other request, such as the permission mode asking
about a file edit or a command, or the auto-mode judge objecting to
one, is about the call itself and shows no pattern: for a tool that
runs no command, *Allow for session*, *Always allow* and *Always deny*
hold for every call of that tool, and a call outside the session's
directories still asks for the directory first.

For a shell command those answers are about what the command line
runs, not about bash: the harness reads the line into a syntax tree of
the commands it runs -- through pipes, `&&` and `;`, subshells,
`$(...)` and backquotes, `if`, loops and `case`, and after a wrapper
such as `sudo`, `env` or `xargs` -- and the panel says what a lasting
answer would cover, on a line of its own and in the buttons' tooltips,
such as `lasting answers: every gcloud and gsutil call`. A single
command gives its program, so always allowing `gcloud compute instances
list --project p` lets your other `gcloud` calls run without asking,
while `rm`, `make` and unrelated commands still ask. A line with
several commands of the same program keeps the words they share, up to
three and never an argument, so two `gcloud compute instances` commands
give `gcloud compute instances` rather than all of gcloud. A rule is a
prefix: it matches a later command that starts with those words, such as
`gcloud compute instances delete`, not the arguments the call happened
to pass. A line that also runs something else needs that command covered
too, so allowing
`gcloud ... && rm -rf build` does not let a later `gcloud ... && rm -rf
~` run. A command the reader cannot read keeps the whole-tool answer,
and the note says so. *Always deny* is scoped the same way: denying a
`rm` call refuses later calls that run `rm`, not every command.

An answer that lasts -- *Allow for session*, *Always allow*, *Always
deny* -- leaves a note in the session's chat, under the call it
answered, whether you answered in the chat, a popout, the session list
or the task board: `Always allowing every bash call to gcloud and
gsutil, in every session [Undo]`. `[Undo]` takes back what that answer
recorded, the rule or the directory, for the session or from
`harness-perms-rules` and `harness-allowed-directories`, and nothing
else. The call it answered
stays allowed or denied. Once undone the note is struck through and
offers `[Redo]`, which records it again, and then `[Undo]` again. When
the rule has changed since, edited in Settings say, or another answer
recorded it again, the button leaves it as it is, and the note says so
under it and offers nothing more; it says so too when the rule or the
directory is gone already. An answer that recorded nothing new, the
same rule being there already, offers no `[Undo]`.

Such an answer belongs to no one session: undo it, or redo it, from
whichever session shows it, now or after a restart, and every chat
showing it follows. A call that a rule from such an answer denies,
in any session, names it under the call, with the same button:

```
 › Bash rm -rf build/  ● denied
   decided by: Always denying every bash call, in every session  [Undo]
```

`M-x harness-decision-undo` and `M-x harness-decision-redo` do the same
for an answer whose note is not on screen: they offer the answers that
can move that way, newest first.

The tools that inspect your Emacs never ask. When `emacs_find_definition`
shows a definition, the file it names may then be read without a grant
for the rest of the session, by the tools that only read, so the agent
can read the code around it: only that file, not its directory, and not
for writing.

The harness decides a call as it happens, so a session never waits on a
prompt nobody can answer, but it is never the last word: every call it
refuses is kept under a handle, and the refusal the agent reads names
it. A refused call in the transcript offers `[Approve]` (or
`M-x harness-chat-approve-denied-call` on the call at point). Clicking
it says yes on your behalf, in the transcript and once only: the agent
is told, and runs the call exactly as it was refused, with its own tool
and arguments, through the `rerun_approved` tool. The call shows as
user-approved, and the rerun links to the call it was refused as. A
handle you have not approved, one another session was refused, and one
already rerun are refused, so nothing but the very call you approved
ever runs. What the harness recorded stays in the session, so an
approval outlives a reload.

A shell command is about what its command line names, not only the
directory it runs in. The prompt for `ls -la ~/.claude/projects/x`,
run in the project, says `runs in: ~/proj` and, below it, `paths:
~/.claude/projects/x`, so it shows what the command reaches and not
only where it runs; like any prompt about a call, it has no pattern.
A command that names nothing outside the session's directories is
about where it runs, as before. Paths are read from the same syntax
tree that scopes a lasting answer, from every command the line runs: a
pipeline, a list, a subshell or a substitution all contribute the paths
they name, a redirection's target counts wherever it stands, and a
here-document's body is data, not paths. The words kept are absolute
paths, `~` and `$HOME` paths, and `./` or `../` paths, but not the
program being run or `/dev/null`. An allowing rule must cover every path the command names
outside the session's directories, so allowing commands in the project
does not let one that reaches elsewhere through. A denying rule stops
a command that names any path it covers.

A link in the agent's reply opens with a click or `RET`, and the
transcript stays as it was: a web address goes to `browse-url`, a file
opens in another window. A relative file name is taken in the session's
directory, and a `#L12` or `:12` after it goes to that line.

An image the agent reads (`read_file`) shows in the transcript, under
the call's header and outside its fold, so a collapsed call still shows
the picture; so does an SVG, read as text and shown as an image, and a
video attached to a message. A video shows its thumbnail as a poster
under a play button, with its duration and size under it. Click the
poster or the Play button, or press `RET` on it, to play the video with
`mpv`, `ffplay` (`harness-ui-media-video-player`, nil picks the first
installed) or, failing those, the desktop's own player; the poster then
shows Stop. A video `read_file` reads is shown to you and told to the
model, which cannot see it and inspects it with `ffmpeg` instead.

A model that reads images sees an image `read_file` reads too, not only
you. It gets the file itself when it is a PNG, JPEG, GIF or WebP of at
most `harness-tools-fs-image-max-bytes` (3.75 MiB) and
`harness-tools-fs-image-max-side` (2000) pixels on a side. A larger
image, or one of a type models do not read (BMP, TIFF ...), is made fit
with `ffmpeg` (`harness-tools-fs-ffmpeg`; nil never runs it): fitted
into that many pixels, its first frame only, a JPEG kept a JPEG and the
rest PNG. The copies are kept under `model-images/` in the state
directory, so reading the image again makes none. Where `ffmpeg` cannot
help, the model gets the file itself if it is within the byte limit and
8000 pixels on a side, the most providers take. Otherwise it is told
that you see the image and it does not, and how to make a smaller copy.
A model that reads no images is told that you see it and it does not.
A provider whose loop the harness runs is sent the whole conversation
again at every step, those images with it, so it keeps only the newest
`harness-agent-history-images` (16): past that the oldest go in chunks
of half as many, so the request stays the same between two chunks and
the prompt cache with it. The result of a call whose image went says so,
and the model can read the file again.

A digit answers a question with that option (with point in the compose
box, where a digit types, `C-c .` and the digit does); any other answer
goes in the compose box. An answer typed there takes the box's attachments with
it, in a chat, a popout or on the task board: "it looks like [image 1]"
with a screenshot attached reaches the model with the screenshot. When
the options are easier to compare by sight, such
as layouts or architectures, the agent can give each one a diagram,
ASCII art or an image. The diagrams share one area under the options
and show one at a time. Switch between them with the tabs above the
area, `n` and `p` on the panel, `C-c C-f` and `C-c C-b` anywhere in the
buffer, or by moving point onto an option.

An image is a file the agent made, usually an SVG it wrote or a cropped
screenshot of a mockup, in its session's temporary directory. Images
are drawn black on white, as a browser shows them, so a drawing made
for a white page reads under a dark theme too
(`harness-ui-image-colors`, also for the transcript's images; nil draws
them in the colours of the text around them). Each is sized to show
whole: at most `harness-ui-image-max-height` pixels high and half the
window's height in a chat, so a short window such as a BTW still shows
it with the options around it. An image larger than Emacs draws at all
(`max-image-size`, ten times the frame), such as a whole page's
screenshot, shows as a line saying so that opens it outside Emacs; the
agent is told to crop one over 8000 pixels on a side. Only you see the
images; the model gets your answer. Try one with the demo provider's
`images` prompt. When the UI reaches the harness at a host and port,
which may run on another machine, or the image is on a remote host, the
UI asks the harness for the image (`question/image`) instead of reading
the file itself.

The same request can be read and answered without opening the session:
`SPC` in the session list, or on the task board, pops out
what the session at point waits on, in a small window with the same
panel -- the permission prompt or the question in full, its options,
diagrams and keys, and a box for a typed answer. It closes itself once
the request is settled, and the session's own view stays where it was.
The popout of a question with images grows taller than others, up to
`harness-ui-pending-popout-max-height` of the frame, and fits the image
in beside the options and the box.
Both views also answer in place, with the same buttons from the same
code: a blocked session's row in the session list and a task's card on
the board carry `[Allow]` and `[Deny]`, or `[Answer…]`.

The header line shows the session's name, model, permission mode,
thinking level, context and cost, and `non-interactive` while the
session is. A session that [supervises](#supervisor-mode) starts the
line with a `supervisor` badge, or a `hands-on` one once you switched
that off; a click there toggles it, and a window too narrow for the
whole line drops the badge before the session's own segments. Click
the name, the model, the permission mode or the
thinking level to change it, and `non-interactive` to make the session
interactive again; `C-c h i` or the menu turns the mode on. The mode
line shows the session's status, a spinner while a turn runs, and how
long the turn has gone on. Neither repeats what the buffer shows: the
todo list has its panel and what the turn does now has the activity
line, both above the compose box. Switching a session that waits on a permission prompt to
YOLO answers the prompt, since yolo would have allowed the call
anyway; a directory prompt still waits for your answer. A
non-interactive session never waits for you, which suits a session you
leave to work while you are away. Whatever would ask you for
permission, the auto-mode judge decides instead, whatever the
permission mode. The one exception is a supervising session's plan:
the judge never rules on `submit_plan` or `retry_step`, which are
allowed (see **Approving plans** under
[Supervisor mode](#supervisor-mode)). The judge runs on the session's own provider: its
simple tier (Claude Haiku, DeepSeek Flash, or the cheapest model that
provider lists, see [Model tiers](#model-tiers)), so a session on one provider is never judged through
another. Set `harness-perms-auto-model` to force one model. The judge
sees only the one call: no conversation, and no project instructions
such as CLAUDE.md. It refuses only what risks serious harm that is
hard to undo, such as wiping data outside the project, force pushes,
system changes, leaking secrets, or widening its own permissions. It
never rules on the task or your workflow, and when in doubt it allows.
Each of its calls is recorded as a session of kind `internal`, with the
prompt it saw, its verdict and what it cost, which the session list
shows on request (see [Session list](#session-list)).
It also follows the `autoMode` rules that Claude Code's own auto mode
follows, taken from the same places: your `~/.claude/settings.json`
and your organization's managed settings, never a project's. So with
the same settings it is no stricter than Claude Code. Pushing to the
repositories, buckets and services your organization lists as trusted
counts as ordinary work, and the organization's `soft_deny` and
`hard_deny` rules hold as they do in Claude Code. No entry lifts the
judge's own rules. Set `harness-perms-claude-auto-mode` to nil to
leave them out.
A call it would deny is put to you in an interactive session, with the
judge's reason, so you can allow it; in a non-interactive session the
denial stands and the agent is told to find another
way. Access to directories outside the session's own still needs you,
so it is denied while you are away. New sessions, task sessions
included, start interactive unless `harness-non-interactive` is set.
Setting `harness-tasks-non-interactive` makes every new task session
start non-interactive. From then on each
session has its own switch. Switching a session that waits on a
permission prompt to non-interactive hands the prompt to the judge,
which decides it as it would a new call, denial and steering included;
a directory prompt still waits for your answer.

`C-c h I` (`harness-set-non-interactive-all`) is `C-c h i` for
everything, as `C-c h M` is `C-c h m`: it turns non-interactive mode on
or off at once for every current session (idle, running or blocked) and
every current task (pending, active or needing input) of every project,
for the next task of every open task board, and for new sessions too,
unless a prefix argument (`C-u C-c h I`) leaves the default alone. It
says how many sessions and tasks changed, and when it turns the mode
off, what still turns it on for new work: a project's `.dir-locals.el`
that sets `harness-non-interactive`, or `harness-tasks-non-interactive`.
It changes neither. A completed task — one in the board's `done`
column — is over: its session is left alone by this and by every other
"for all sessions" command (`C-c h M`, `C-c h H`, the menu's `V`),
even a session still running, idle or blocked (see
[Task board](#task-board)).

An agent can do the same when you ask it to, with its
`set_non_interactive` tool, for itself, another session, or everything.
Turning the mode on takes you out of the loop, so the harness asks you
first, every time, in every permission mode, as it does for a directory
outside the session: neither the judge nor a permission rule can allow
it, and a non-interactive session, which has nobody to ask, is denied at
once. Turning it off only brings you back, so it asks nothing.

Opening an inactive session shows it without resuming it. Its compose
box stays available, and the first message you send resumes it.

### Pressing a panel's key from the compose box

What sits above the compose box and answers to a key -- a question's
digits, a permission's `y`, `s`, `a`, `n` and `N`, the cache panel's
choices, the task board's `F` -- answers only while point is on it. With
point in the box those same keys are typing, so they go into your
message, which is what you want nine times in ten. When you mean the
panel, `C-c .` and then the key says so, the same way everywhere: the
dot is the one the harness menu already puts before a view's plain keys
(`. F`).

- `C-c . 1` picks the first option of the question above the box,
  `C-c . y` allows the permission request, `C-c . F` starts the
  fullscreen layout from the task board's box. Point comes back to where
  it was in the box, and your draft with it.
- The key is pressed on the nearest panel above the box that has it. A
  numeric argument takes the Nth panel up: `M-2 C-c . 1` answers the
  second question from the box. `C-g` at the prompt for the key quits.
- Each panel says so in a dim line of its own, with a key it has:
  `from the box: C-c . 1`. The box's tooltip names `C-c .` too, and so
  does the harness menu, under the chat's, the popout's and the board's
  own commands.
- A popout (`SPC`) is a panel of its own box: `C-c . q` closes it and
  `C-c . g` draws it again from there, as `q` and `g` do on its content.
- The task board's keys for the task at point need a card under point,
  which the box does not have. Pressing one from the box says so, rather
  than guessing which task you meant.

Point on the panel works as before, with no prefix. To use another key
than `C-c .`, bind `harness-compose-panel-key` in `harness-compose-map`;
the hints follow it.

`M-<` and `M->` are the box's own too: in the box they go to its top and
its bottom, not to the buffer's, which holds the transcript above the box
and no text to edit. Pressed again at the box's edge, from outside the
box, or with a prefix argument, they go on to the buffer's top and
bottom, so the transcript is one more press away.

### Prompting with the region

Select text in any buffer and press `C-c h >` (`harness-prompt-region`,
also `>` in the menu) to start a message with it. It works in the
harness's own buffers and in every other.

![Lines of a Python file selected on the left, and on the right the newest session of the project, its compose box holding where they come from, the file and its lines, and the code in a fenced python block, ready for the request](docs/media/prompt-region.png)

- In a chat, the task board or a popout it does what `C-c >` does: the
  selection goes into the compose box as a Markdown quote, point under
  it for your reply.
- In any other buffer the text becomes the start of a message in the
  compose box of the newest session of the buffer's project. Its chat is
  shown and selected, with point in the box under the text, ready for
  what you want done with it. A draft already in the box stays above
  the text. A project with no session yet gets a new one.
- The text comes with where it is from: a line naming the file and its
  lines (``From `lisp/foo.el` (lines 12–30):``), or the buffer's name
  when it has no file. Code from a programming or configuration buffer
  goes in a fenced code block in its language, any other text as a
  Markdown quote.
- `C-u C-c h >` asks which session gets it instead: one of the
  project's, newest first, or a new one.

### Moving a session to another directory

A session works in the directory it was started in, and the session
list files it under that directory's project. When a session started in
one place turns out to work on another, move it there: `C-c h W`
(`M-x harness-move-session`, also called `harness-session-move`) asks
for the new directory, starting next to the session's own, and `M` does
the same for the session at point in the session list, `m` for the
session of the directory access list (`C-c h d`). The session then
works in the new directory and is listed under its project, also after
a restart. It no longer reaches the old directory, unless you move it
with a prefix argument (`C-u C-c h W`), which keeps the old directory
allowed. The directories you granted it stay granted.

The conversation goes on where it was, but the model's provider starts
a new conversation in the new directory, which gets the transcript:
the Claude Code CLI keeps its conversations per directory. A session in
the middle of a turn moves when the turn ends, and moving it back to
where it works cancels that. Some sessions cannot move:

- a session working in a worktree, whose branch merges back through the
  merge queue;
- a task's session, which stays with its task: submit a task in the
  other directory instead;
- a session that branches are queued to merge into, until those merges
  are through;
- a session on a remote host, to another host.

Agents can move a session too, their own or another one, with the
`session_move` tool. You confirm every move, whatever the permission
mode, yolo included: the request offers only `[Allow]` and `[Deny]`,
and neither is remembered. An agent moving its own session may use the
new directory for the rest of its turn, and the session moves when the
turn ends. A non-interactive session cannot ask, so its agent says in
its answer where it wanted to move.

### Compacting a conversation

A conversation that nears its model's context window is compacted
before the next turn, unless its provider compacts on its own side, as
Claude Code does: something much smaller stands in for it from then on,
and the earlier messages stay in the conversation tree. There are five
kinds:

- **Summary**: the session's model summarises the whole conversation.
  It reads all of it again, from the prompt cache while that lasts.
- **Brief summary**: a cheap model (the simple tier of the session's
  provider, such as Claude Haiku or DeepSeek Flash; see
  `harness-compaction-brief-model`) summarises the conversation's
  narrative: every user and assistant message, each tool call and
  result named in a line, never a payload. It costs cents however long
  the conversation, but what tools read and wrote is left out, and the
  summary says so.
- **Transcript file**: the whole conversation goes to a file in
  `.harness/transcripts/` in the session's directory (git ignores it),
  and the model is told to read what it needs of it. No model is asked
  anything, so it costs nothing.
- **Fresh start**: nothing is carried over, not even a summary. The
  model starts with a short note saying so, and looks back at what it
  needs with `session_history` (below). It costs nothing.
- **Cut old context**: the oldest messages are dropped and the most
  recent ones are kept as they were. A short note says what went, so
  the model knows to look the rest up with `session_history` rather
  than assume the conversation it has is all of it. It costs nothing,
  and it is the one to reach for when the conversation is too big to
  summarise: nothing has to be read to make it.

Whichever kind it is, the conversation it replaced stays on record.
The compaction ends in a line pointing the model at the
`session_history` tool, which searches and reads the session's own
conversation from before its last compaction (or a handoff from another
model): matches newest first with node ids, one node whole with the
nodes around it, or the last nodes before the compaction, and
`all=true` for the whole conversation. A model that needs what a summary
left out looks it up instead of guessing.

The first three kinds are the ways a switch to another provider can hand the
conversation over (see [Switching model or provider](#switching-model-or-provider)),
here on the session's own model. Automatic compaction makes the kind
`harness-compaction-kind` says, a summary by default; the settings page
has both under **Compaction**.

With the `ui-compact` module (`:ui compact`), `C-c h C` (`M-x
harness-compact`, or Compact context in the menu) compacts the current
session by hand, between turns: it asks which kind,
naming what each costs, beside a table of who writes each, what it
costs and what it does, and of what carrying on without compacting
costs. Typing `/compact` in the message box asks the same;
`/compact brief`, `/compact summary`, `/compact transcript`,
`/compact fresh` or `/compact truncate` (or just `b`, `s`, `t`, `f` or
`c`) compacts that way at once. The chat then shows the
compaction where the conversation now starts, with `[open the
transcript]` for a transcript file.

Asking mid-turn does not have to wait: when the session is running a
turn, the question first offers to interrupt the step and compact now,
or to queue the compaction for the turn's next boundary (its next step,
or its end), and `/compact` offers the same. Interrupting ends the
turn: the step in flight, and anything it had not recorded yet, are
lost, so queueing is the one to pick when the turn has work to finish.
The agent itself can do this with the `compact` tool: it names a kind
and asks to `queue` the compaction (the default) or to `interrupt` the
turn first, which is what an agent does when it sees the context
filling up mid-task.

A provider's prompt cache lasts only a while after its last use: five
minutes or an hour for Claude, hours for DeepSeek (see
`harness-cache-ttl`). Once it expires, the next message re-sends the
whole conversation uncached, at the full input price. With the
`ui-cache` module (`:ui cache`), a panel above
the message box says when the cache expired and what the next message
will cost instead of what it would have cost cached. After a redaction
took a secret out of a session and started its provider conversation
over (see [Secrets and redaction](#secrets-and-redaction)), the panel
reads "Prompt cache dropped at HH:MM, by a redaction" in place of when
the cache expired, and names the uncached price alone: there is no
cached one to compare it with. It never shows while the session's turn
is running — a session waiting on a tool approval included, whose next
request is that turn's own — nor while a message you sent has no answer
yet, even when the chat has not caught up with the turn: only once the
session is waiting for you. Its last line offers
to compact the conversation first, a button and a key per kind with
what each costs:

```
Compact it first   b  Brief summary (~$0.011)   s  Summary (~$0.463)   t  Transcript file (free)   f  Fresh start (free)   c  Cut old context (free)
```

Press the key with point on that line, or click a button, and the
conversation compacts that way. The panel goes once the compaction is
done: the next message sends only what stands in for the conversation.

### A message to a session whose cache went cold

Not every message comes from you while you watch. Feedback on a task
that sat in review for a day, a message from another session's agent,
the merge queue reporting a conflict: any of them can reach a session
whose prompt cache lapsed long ago, and sending it as it is would pay
for the whole conversation again, uncached. So a message that meets a
cold cache, whoever sent it, waits while the session asks what goes
first. This is the `cowboy` module (`:features cowboy`), which brings
its panel, `ui-cowboy`. The session is blocked on the question, and
the chat (or its popout) shows it in place of the cache panel:

```
 ◷ Prompt cache cold  since 09:12 · Claude Opus · ~84.0k tokens
   A message from the harness (tasks) waits: “The tests fail on CI; …”
   Carrying on sends the whole conversation again, uncached: about $0.315 instead of the $0.025 it would cost cached.  What goes first?

    b  Brief summary    ~$0.011           a cheap model summarises the narrative, tool calls in brief · the default
    s  Summary          ~$0.463           the session's model summarises it all, reading it uncached
    t  Transcript file  free              the conversation goes to a file the model reads as it needs
    f  Start afresh     free              nothing is carried over; the model looks back when it needs to
    c  Carry on         ~$0.315 uncached  the whole conversation goes again, uncached
    q  Not now                            the message waits; nothing is sent yet

    B   S   T   F   C  the same, from now on without asking
   Whichever you choose, the model can search and read the conversation it leaves out (session_history).
   or type a choice below: “transcript”, “always brief”
```

A key with point on the panel, or a click on a choice, answers it; so
does a digit, or a choice typed in the message box ("transcript",
"always brief"). The compaction goes first, then the message, which
sees only what stands in for the conversation. Carry on sends it as
before, and not now keeps the message, unsent, until the next one goes
with it. Whatever you pick, the model can look back with
`session_history`. Another session's agent cannot answer the question
for you.

A capital letter, or "always" with a choice, makes that choice the
default and stops the asking (`harness-cowboy-default`,
`harness-cowboy-ask`, saved like any setting; **Cold cache** on the
settings page). The note that says so offers `[Undo]`, as a lasting
permission answer does: it turns asking back on, with the default as
it was, and then offers `[Redo]`. So does every note, in any session,
saying the default went first unasked because of that answer:

```
 Prompt cache cold since 09:12: starting afresh, the default, as asking is off (harness-cowboy-ask)
 decided by: Always starting afresh when the prompt cache is cold, without asking  [Undo]
```

Settings changed by hand since are left as they are, and the note
says so. A session that never waits for you, such as a
non-interactive task, is never asked: no model judges what to do, the
default goes first. The default default is the brief summary, the one
choice that never pays for the whole conversation uncached and still
leaves the model a summary to go on. A summary that cannot be made gives
way to the transcript file, and that to carrying on: the message always
goes, unless you hold it. `harness-cowboy-min-context` leaves smaller
conversations to go uncached without asking.

A cache can go cold before its time. When a redaction takes a secret out
of a session on Claude Code or Copilot, the session's provider
conversation is dropped with it, and the next message would start a new
one with the whole transcript as its first message, uncached (see
[Secrets and redaction](#secrets-and-redaction)). So that message meets
the question whatever the clock of the cache says. The question reads
"a redaction dropped this session's provider conversation at HH:MM, so
no prompt cache holds it", and compares no cached price, as there is
none to be had.

### Searching sessions

`C-c h g` (`M-x harness-search-sessions`) asks what to look for and
lists the sessions that said it, best match first, each with its best
matches and what was found in them highlighted. `RET` on a match opens
its session there, with point on the words found, however far back
they are. On a session's line it opens at its best match.

```
 2 sessions match “sqlite cost”  ·  full-text index

 ● Usage dashboard  emacs-agent-harness · 3d ago
     you          …record the cost of each turn in sqlite, one row per…
     agent        …usage.db now keeps the cost per model…
```

There are four ways to search. `m` goes from one to the next, and the
header line shows them all:

- **Words** (the default): every word must be there, in any form, so
  "crash" finds "crashes" too. The best matches come first. `"a
  phrase"` matches as a phrase, `pars*` matches a prefix, `OR` between
  two words takes either, and `-word` leaves out the sessions that have
  it. When no session has every word, the ones with some of them are
  listed, and the line above them says so.
- **Literal**: the text exactly as you typed it, symbols and all.
- **Regexp**: an extended regular expression, as `grep -E` reads it.
- **Meaning**: what is near in meaning, even in other words. This needs
  an embedding model (below).

`a` switches between every project and the project you searched from
(`harness-ui-search-default-scope` sets where a search starts), `s`
searches for something else, `g` searches again, `+` lists more
sessions, and `n` and `p` go from match to match. With `C-u`, `C-c h g`
asks how to search first.

The search reads a full-text index of the transcripts, which the
harness keeps in `search.db` beside `usage.db` in its state directory.
It is built in the background from the transcripts and kept up to date
as sessions go on. It is only a cache: deleting it loses nothing, and
it is built again. Until it is built, or with
`harness-session-search-index` set to nil, a word search matches the
text as you typed it, and the results say so. Agents search the same
index with the `session_search` tool, and so does the quick search (the
task board's too) when it looks in the sessions' transcripts: it hands
your words, in the search's syntax, to this search, and `[All matches]`
in its popout opens the results here, for the words it looked for.

Searching by meaning needs an embedding model. Set
`harness-session-search-embedding-model` to one, such as
`"openai:text-embedding-3-small"`, or a local server's: with an entry
`(:id local :base-url "http://localhost:11434/v1" :api-key "ollama")`
in `harness-openai-endpoints` for Ollama, `"local:nomic-embed-text"`.
Then the text of your messages, the replies, plans and summaries is
embedded in the background, and word searches rank their matches by
meaning too. When no session has the words, they list the sessions
nearest in meaning instead. That text goes to the model's provider,
which is why this is off until you set it. In corporate mode only a
server on this machine embeds.
`harness-session-search-embedding-dimensions` asks a model that can
shorten its vectors for fewer dimensions.

### Secrets and redaction

A secret that a tool prints does not stay where it was printed. It goes
into the transcript, the node log on disk, the search index and its
embeddings, the conversation log that the `claude` CLI keeps and replays
with `--resume`, the chat buffer and the harness log. The model's
provider has received it too. The harness works on both ends. It masks
secrets in what tools return, so that exact secret text is not recorded
in the first place. When one got in anyway, it takes the secret out of
every copy it keeps and records that it did.

#### Masking

What a tool returns is searched for secrets before anything stores it,
shows it or sends it to the model. Each secret found is replaced by a
placeholder:

```
[redacted: spaces-key sha256:9c4e1f07]
```

The label says which source or detector found it. The digits are the
first 8 hex digits of the secret's SHA-256: the same value always gets
the same digits, and they tell nothing else about it. Masking applies to

- the result of every tool: the shell, the file tools, the search tools,
  what the `emacs_*` tools read from your Emacs, and the rest;
- the progress lines and notes that a running tool reports, and the
  message of a tool that failed;
- the output of a provider's own tool that the harness records (the web
  search of Claude Code or Copilot);
- the harness log (`C-c h L`).

A result is masked before the size guard cuts it, so the file that holds
the whole of an oversized result is masked too. A result that had
something masked says so on its node in the transcript: the labels,
fingerprints and counts, never the text around them. A result that
masking cannot check is withheld instead of let through.

Two things find secrets:

- **Sources** are secrets you name by where they can be read: a string
  in a JSON file, the group of a regexp in a file, an environment
  variable of the harness, or the output of a command. The harness
  reads the value itself, keeps it in memory only, and masks it wherever
  it shows up, as written and as JSON escapes it, with the source's
  label. A file is read again when it changes, and a variable when its
  value does. A source that cannot be read is skipped, the list of
  sources says why, and the values it had when it last could be read stay
  masked. A value shorter than `harness-redaction-min-length` (8
  characters) is not treated as a secret.
- **Detectors** look for what is shaped like a secret, and label it with
  their name:

| Detector | Finds | Default |
|---|---|---|
| `digitalocean-token` | A DigitalOcean token: `dop_v1_`, `doo_v1_` or `dor_v1_` and 64 hex digits | on |
| `aws-access-key-id` | An AWS access key id: `AKIA`, `ASIA`, `ABIA` or `ACCA` and 16 capitals or digits | on |
| `spaces-access-key-id` | A DigitalOcean Spaces access key id: `DO` and 18 capitals or digits, two of them digits at least | on |
| `github-token` | A GitHub token: `ghp_`, `gho_`, `ghu_`, `ghs_` or `ghr_` and 36 letters or digits, or `github_pat_` and 22 more | on |
| `anthropic-key` | An Anthropic API key, `sk-ant-` and 20 characters or more | on |
| `openai-key` | An OpenAI API key: `sk-proj-`, `sk-svcacct-` or `sk-admin-` and 20 characters or more | on |
| `slack-token` | A Slack token: `xoxa-`, `xoxb-`, `xoxp-`, `xoxo-`, `xoxs-` or `xoxr-` and 10 characters or more | on |
| `google-api-key` | A Google API key, `AIza` and 35 characters | on |
| `stripe-key` | A live Stripe key, `sk_live_` or `rk_live_` and 16 characters or more | on |
| `private-key` | A PEM private key, the whole block from its BEGIN line to its END line | on |
| `secret-assignment` | The value of a name such as `secret`, `secret_key`, `client_secret`, `api_key`, `auth_token`, `access_token`, `private_key`, `password` or `token`, after `:` or `=`, quoted or not: 16 characters or more, with a letter and a digit | on |
| `jwt` | A JSON Web Token: three dot-separated parts, the first two starting `eyJ` | off |

Masking is on by default, with the detectors marked on, and no source is
registered until you add one. `jwt` is off because a JWT is mostly a
session credential that expires. There is no generic detector for
high-entropy strings: commit ids, content hashes, build ids, UUIDs and
base64 data look as random as a secret, and masking them would hide what
the model has to read. A secret in no known format is protected by a
source.

The price of masking:

- **False positives.** A detector masks what looks like a secret,
  whatever it is. `secret-assignment` now and then masks a long
  identifier that follows a name such as `token`. An agent that reads a
  file with an example key in it sees a placeholder in its place, and may
  describe the file wrongly, or fail to edit around it.
- **The write guard.** A call of a tool that writes (`write_file`,
  `edit_file`, `emacs_insert` and the like) whose input holds a
  placeholder is refused: the placeholder stands where a secret was, and
  writing it would put it in a file in the secret's place. The refusal
  says what to do instead, and you can approve the call from the chat, for
  a document about placeholders, say. A shell command is not checked.
- **Time.** Every result and every log line goes through a few regexp
  passes and one exact search for each registered value: tens of
  milliseconds for a megabyte of output with the default detectors, a
  fraction of a millisecond for a log line. Nothing is skipped for its
  size, as a result left unchecked because it was big would leak.

Masking does not cover

- what you type and what the model writes: a secret in a message of
  either is stored as it is;
- a copy that a tool transformed: a value that was base64 encoded,
  hashed or cut in pieces is not the value any more. Progress lines are
  masked a chunk at a time, so a secret split between two chunks shows as
  two halves in the live progress line, though the result is masked
  whole;
- what a provider's own tool already returned to its CLI. The harness
  masks the record it keeps of the web search of Claude Code or Copilot,
  but the CLI got the text first, and its log holds it;
- anything a model provider received before the secret was named (see
  [What redaction cannot do](#what-redaction-cannot-do)).

#### Adding sources

`M-x harness-secrets-add-source` (`a` in the list of sources) asks where
the secret is -- a JSON path in a file, a regexp with one group around the
secret in a file, an environment variable of the harness, or a command
that prints it -- and what to call it. The harness reads the value to
prove that the source names one, and keeps the source in
`secret-sources.json` in the state directory: where the value is, never
the value. A secret cannot be typed here, as that would put it on disk.

`M-x harness-secrets-list-sources` (`E` in the `C-c h ?` menu) lists the
sources: the label, where the value is read, how many values it holds,
the fingerprint of each, whether it comes from the option or was added
by hand, and why it cannot be read, if it cannot. `d` stops masking the
source at point (only one added by hand), `g` reads them again and `l`
lists the redactions that were run. There is never a value in the list.

The option `harness-secrets-sources` names sources in your init file. It
takes the same references, and `:literal` too, the value itself, which is
then in your init file and in the harness process's configuration file:
prefer a file or a variable. For example:

```elisp
(setq harness-secrets-sources
      '((:file "~/infra/terraform.tfstate"
         :json-path "outputs.spaces_keys.value" :label "spaces-keys")
        (:env "DO_TOKEN" :label "do-token")
        (:file "~/.netrc" :regexp "password \\([^ \n]+\\)" :label "netrc")))
```

A `:json-path` is dot-separated keys (`outputs.keys.value`), with `*`
for every key or element and `["a.b"]` for a key with dots; a path that
selects an object or an array stands for every string in it. A command
runs once, when the source is first read. `harness-secrets-detectors`
chooses the built-in detectors: `default` (the ones marked on), `t` for
all of them, `nil` for none, or a list of names.
`harness-secrets-extra-detectors` adds patterns of your own, each `(NAME
REGEXP [GROUP])`: NAME labels the placeholder, REGEXP is an Emacs regexp
and GROUP the group that is masked (the whole match by default).

#### Redacting a secret

`M-x harness-redact-secret` (`x` in the `C-c h ?` menu) takes a secret
out of everything the harness stored. It asks

1. where the secret is: a JSON path in a file, chosen from the keys and
   types of the file, which the harness reads for you, never from its
   values; a regexp with one group around the secret in a file; an
   environment variable of the harness; a command that prints it, which
   the harness runs and whose output is not recorded; or the value
   itself, typed with `read-passwd`. A typed secret is never echoed or
   kept in a history or a message, goes only to a harness on this
   machine, and is cleared from memory when the request is done;
2. what to call it, the label of its placeholder;
3. which sessions to clean: all of them, the project's, the current
   session and its forks, or sessions you name;
4. why. The reason is kept in the records, and may stay empty.

The harness scans first, and the buffer `*harness redaction*` shows what
it found: counts and session ids, never a snippet of the text around a
secret. Nothing changes until you answer yes, and the question says what
the redaction costs in prompt cache, if it costs any (below). The report
that follows says what is left, if anything.

An agent redacts with the `redact_secret` tool, whose input names where
the secret is and never the secret:

```json
{"mode": "scan",
 "source": {"file": "terraform.tfstate",
            "json_path": "outputs.spaces_keys.value"},
 "scope": "all"}
```

- `source` is `{file, json_path}`, `{file, regexp}` (group 1 of each
  match is the secret) or `{env}`. The tool takes no literal and no
  command, and refuses a key it does not know without quoting it. The
  file has to be one the session may read.
- `mode` is `scan` (the default: counts by session, changes nothing),
  `redact` (needs a `reason`), or `shape`, which lists the keys and types
  of `source.file` with the `json_path` to each, so that the agent can
  pick a path without seeing a value or the length of one.
- `scope` is `self` (this session and its forks, the default),
  `sessions` (the ids in `sessions`), `project` (the sessions of the
  directory in `project`) or `all`. `include_forks` (default true) adds
  the forks of the sessions named.

To the permission system a scan and a shape are reads; a redaction is
not, so it asks in ask mode and the judge weighs it in auto mode. The
call and the result hold no secret, by construction: the call says where
the secret is, and the result is made of counts, session ids, labels and
fingerprints. So the session that redacts never has to be redacted
itself. A model that puts the value in the call anyway, in a regexp, say,
has its own session added to the scope.

A redaction takes the secret out of

- the node logs of the sessions: every field of every line, node
  updates included. A log is read, cleaned and replaced by a rename in
  one step that never yields, so no append is lost and no log is torn,
  and the lines without the secret stay byte for byte. The nodes in
  memory and the text of the session record are cleaned too;
- the search index: the rows, the full-text index and the vectors of the
  chunks that held it. The logs are indexed again, then the index is
  merged and vacuumed and its write-ahead log emptied, so the old text
  is gone from `search.db` itself;
- the conversation logs of the CLIs: Claude Code's under
  `~/.claude/projects` (`$CLAUDE_CONFIG_DIR/projects`, or
  `harness-provider-claude-projects-directory`) and Copilot's under
  `~/.copilot/session-state` (`$COPILOT_HOME`, or
  `harness-provider-copilot-state-directory`). A log that no session of
  the harness owns and that was written in the last minute may have a
  CLI of your own at work in it, and is left alone and listed;
- the task records, with the scopes all and project, and the copy
  `tasks.json.bak`;
- the transcript files that compaction and handoff write, the files that
  hold cut tool outputs whole, the sessions' temporary directories and,
  for the scope all, the other files of the state directory. A file that
  is binary, a database or over 64 MiB is counted and reported as found,
  not redacted, and a link is never followed;
- the log buffers: `*harness-log*`, `*Messages*` and the other
  `*harness...` buffers that visit no file, in the harness process. Your
  Emacs cleans its own too when it can read the secret as the harness
  did (a typed secret, a command's output, the same file or variable)
  and the fingerprint is one the harness redacted; it leaves them alone
  for a harness on another machine. The chat of a session that changed
  loads its transcript again.

The vacuum rewrites the whole index. With a large `search.db` it takes a
while, the harness process does nothing else meanwhile, and it needs free
disk space of at least the size of the index: a copy in the temporary
directory, and as much again in the state directory for the write-ahead
log.

A session whose provider conversation held the secret does not resume
it. Claude Code and Copilot keep the conversation themselves, so besides
cleaning their logs the harness drops the session's provider state and
the checkpoints on its nodes. The next turn starts a new conversation,
which gets the redacted transcript. A session starts over when its
nodes held the secret, or its provider's own log did. A hit only in the
session's record, such as its queue, name or todos, resets nothing: no
provider conversation was sent those, and a new one is made from the
nodes anyway.

The reset costs the prompt cache. The provider caches the conversation
it keeps, and the new conversation opens with the transcript as text, a
different start from the one the cache holds. The old cache could not be
used again in any case: it holds the secret. So the harness marks the
cache as dropped at the moment of the reset, rather than letting it
count as warm for the minutes it would have lasted. The next message to
the session meets the cold-cache question (see [A message to a session
whose cache went cold](#a-message-to-a-session-whose-cache-went-cold)):
what goes first, before the whole conversation is sent again, as one
message, uncached. A session that is never asked, a non-interactive task
say, goes the way `harness-cowboy-default` says: a brief summary, unless
you chose another. A session on a provider that is sent the whole
transcript with every request (an API provider) loses nothing this way.
Its next request is built from the redacted transcript and still reads
the cache up to the first redacted spot, so its cache is not marked.

The scan and the question say what the reset will cost, before anything
changes. The report of a scan lists the sessions whose provider
conversation would start over, and those whose cache would go, with the
tokens it holds. The question before the redaction ends with it: "2
provider conversations start over, dropping ~126k tokens of prompt
cache". After the redaction the report names the sessions whose cache
went with the reset.

A session that runs a turn has its log, nodes and record cleaned at
once. Its provider conversation cannot be dropped under it, and what the
turn writes next can bring the secret back, so the rest waits for the
turn to end. The report lists the session as waiting, and the harness
goes on by itself then. Tool output is masked of the pending secrets
meanwhile. The session keeps its cache until the turn ends and loses it
with the reset then, so its next message meets the cold-cache question,
or `harness-cowboy-default`, from the end of the turn on. The wait is
kept in memory only: a harness that stops before the turn ends has lost
the secret, and says so in a hint when it starts. Run the redaction again
then.

Each session that a redaction changed records it. A hint in its
transcript says what was redacted, where, at whose request and why, and
an entry in its record (`:redactions`, the last 50) holds the time, who
asked (the session or you), the reason, the label, fingerprint and
source of each secret, the nodes, fields and files that changed, the
counts, what became of the provider conversation and whether its prompt
cache went with it. The harness adds a line for each redaction to
`redactions.jsonl` in the state directory, and `M-x harness-redactions`
lists them (`RET` shows one whole). None of it holds a value.

A redaction ends by scanning the same scope and stores again, and by
counting the secret in the files of the search index. A copy that was
left, or that something wrote back, is listed, and the redaction is not
reported as complete.

After a leak, add the secret as a source first, so that it is masked
from now on, then scan, then redact, and rotate the secret.

#### What redaction cannot do

It cannot recall what a model provider already received, nor what an
embedding provider got if you use one
(`harness-session-search-embedding-model`). Whoever has the secret still
has it: rotate it. Copies outside the harness's own stores are not
touched: shell history, terminal scrollback, git, the kill ring,
screenshots, and the file the secret was read from.

#### Options

| Option | Default | Meaning |
|---|---|---|
| `harness-secrets-mask` | `t` | Mask secrets in tool output, progress and the harness log, and refuse writes of placeholders |
| `harness-secrets-sources` | `nil` | References to the secrets to mask, besides those added by hand |
| `harness-secrets-detectors` | `default` | The built-in detectors that run: `default`, `t`, `nil` or a list of names |
| `harness-secrets-extra-detectors` | `nil` | Patterns of your own, `(NAME REGEXP [GROUP])` |
| `harness-redaction-min-length` | `8` | Shortest value, in characters, treated as a secret |
| `harness-provider-claude-projects-directory` | `nil` (the CLI's own) | Where the `claude` CLI keeps its conversation logs |
| `harness-provider-copilot-state-directory` | `nil` (the CLI's own) | Where the `copilot` CLI keeps its session state |

### Forks and side conversations

`C-c h f` forks the current session. The fork starts from the
conversation so far and continues independently. A session can be
forked while it works: the tool calls still running finish in the
original session only, so the fork records that they have no result
there.

A session started from another names it in its own header line, right
after its own name: `↑ fork of Planner`, `↑ sub-agent of Planner`, or,
for a BTW opened over a session, `↑ opened over Planner`. Clicking that
name, or `C-c C-u`, goes up to the parent: the window that shows it
already is selected when there is one, else the parent takes the
child's place; the child stays in the session list and the conversation
tree. A session with no parent says so instead.

`C-c h t` shows the conversation tree (the `ui-tree` module, `:ui
tree`): every message of the session, its forks and its BTWs as a
git-like graph. On a message, `f` forks the
session there and `c` checks the message out, moving the session's head
back to it. Either way the next message continues from that message: the
model knows the conversation up to it and nothing that came after, which
stays in the tree on its own branch. With Claude Code the CLI's own
conversation is cut at that message, so the fork keeps its cached
prefix. Where nothing can be cut there (Copilot, or a session older than
this), the new conversation gets the transcript up to the message.

`C-c h b` opens a BTW ("by the way") side conversation in a window
below the session (the `ui-btw` module, `:ui btw`). A BTW is a new, empty session that shares nothing
with the session or with other BTWs, which makes it a good place for
quick questions. It has the full chat interface, including the header
line with its model, permission mode, thinking level and whether it is
non-interactive. The permission mode starts from the session's; the
model and the thinking level are those of a quick question, below. Two
extra controls appear at the front of its header line:

- `[close]` (`C-c C-k`) closes the BTW. A BTW in which nothing was
  asked is deleted.
- `[keep]` (`C-c C-o`) keeps it as a normal session.

The rest of its keys are the chat's: `C-c >`, for one, quotes its
answer, or the part of it you select, in the box to follow up on it.

So that quick questions get quick answers and cost little, a BTW runs on
a cheap model and starts at the `low` thinking level, whatever the
session's model and level are. Two settings, independent of each other:

- `harness-btw-model` is the model. By default (`auto`) it is the
  simple tier of the provider of the session's model (Haiku for a Claude
  Code session on Opus, say); the BTW keeps the session's own model when
  its provider names no simple one. Set it to a model (`PROVIDER:MODEL`)
  to run every BTW on that one, or to nil to keep the session's model.
- `harness-btw-thinking` is the level. Set it to choose another one, or
  to nil to start from the session's level. A model that does not offer
  the level gets the nearest one it offers below it (DeepSeek, which has
  `low`, `high` and `max`, thinks at `low` for `medium`), or its weakest
  when it has none below. So a BTW thinks no harder than its model has
  to, on the session's own model (when its provider has no cheaper one)
  as on a cheap one, whatever the session's level is. Only a model that
  lists no levels leaves it to the session: the BTW then starts at the
  session's level when its model is the session's or offers that too,
  else at the usual one (`harness-thinking`).

A project can set both for itself (see [Configuration](#configuration)),
and the BTW's model and level can be changed in the BTW like in any
session. `C-u C-c h b` asks which model to run that one BTW on, from
the models the providers list, instead of `harness-btw-model`; an empty
answer opens nothing. The same goes for the BTW on the task board
(`C-u b`) and on a node of the conversation tree. A policy that fixes
`harness-model` ([docs/policy.md](docs/policy.md)) fixes a BTW's model
too: it runs on that model, `harness-btw-model` changes nothing, and a
model asked for must be the policy's.

### Sub-agents

Sub-agents are the `tools-agent` module, in the core, as are the
question (`tools-question`), plan (`tools-plan`), todo list
(`tools-todo`) and session info (`tools-session-info`) tools, each a
module of its own; the tools that list, read, message and wait on
other sessions and tasks are `tools-sessions` (`:tools sessions`).

An agent hands a job to a sub-agent of its own with `spawn_agent`: one
prompt runs in a child session, and the call never blocks the
conversation. It returns as soon as the child starts, naming its
session; the child's answer comes later, in a message of the harness's
own (**System · sub-agent**), so a session can start as many sub-agents
as it needs and carry on while they work instead of waiting for one
after another. Several `spawn_agent` calls made in one step run at
once, and calls made one after another overlap just the same. While
sub-agents run the session has work outstanding, so a task does not go
to review until they are back; a child that itself has work going on (a
wait it registered, a sub-agent it started) is reported when that is
over, not when its turn merely ends. A task that is pre-empted, or
returned to *Pending*, stops its sub-agents with it: each one's turn is
cancelled, with the sub-agents it started, and the session hears of it
as it hears of any cancelled sub-agent, adding why in parentheses.

`fork=true` forks the session, so the child shares the conversation and
its cached prefix; a fresh child starts with the prompt alone.
`worktree=true` gives the child a git worktree and branch of its own, so
several children can change files at once; each branch merges back into
the parent's working directory through the merge queue, one at a time.
`thinking="high"` sets the child's thinking level, one the child's model
offers (after any `model` override); without it the child thinks at this
session's level. A level the model does not offer fails the call, naming
the levels it does, so no child runs at a level its model cannot act on.
To wait for some other session without blocking, `session_wait`
registers a wake-up and returns at once: a message of the harness's own
arrives when the session is done, and the registration outlives the
turn that made it.

To react to what happens in the harness rather than wait on one
session, `watch_events` hooks a session into its events: a task done, a
merge that conflicts, a session that began waiting on you, a tool call
that failed. The agent names the kinds of event, narrows them to a
session or a task if it likes, and says in a prompt what it looks for
and what it may do about it (`wake` unless it names other actions); each
event that matches is put to a cheap model with that prompt, which
decides whether the event calls for one of those actions or can be
ignored. Like `session_wait`, the call never blocks: it registers the
watch and returns at once, and a decision arrives as a message of the
harness's own (**System · event watch**) whose first line is the
decision as JSON, so the agent can restart work, tell another session or
leave it. A watch asks the model about one event at a time and at most
`harness-tools-events-max-calls-per-minute` (12) times a minute, ends
after its first decision unless the agent asks for more, and ends too
with `unwatch_events`, at its timeout, or when you cancel the session's
turn.

### Supervisor mode

A session in supervisor mode plans and coordinates; workers on cheaper
models make the changes. The session investigates just enough to plan,
then submits a plan (`submit_plan`): steps, each a self-contained job
with a tier that says how hard it is. The harness starts a worker
session for every step on the model of its tier, reports back when a
step fails and when the plan has finished, and the supervisor checks the
work and decides what comes next. The plan shows in the chat as soon as
it is submitted, and every worker is a sub-agent session of its own,
named `Step ID: title`, that you can open and read like any other.

Supervisor mode is the `supervisor` module (`:features supervisor`),
which brings its UI, `ui-supervisor`; the cache seeds below are the
`seed` module (`:features seed`).

The harness enforces the rule itself, with tools and not with a prompt,
because a model that is only told to delegate drifts back to "I'll just
do it myself": one small edit, then another, until the expensive model
does the cheap work at the expensive price. A supervising session is not
offered the tools that change things, and the permission layer denies a
call to one anyway, in every permission mode.

- **Judged by default: supervising or hands-on.** `harness-supervisor`
  (new top-level sessions) and `harness-supervisor-tasks` (the sessions
  of tasks) are each one of three, on the settings page under
  **Supervisor mode**: `auto`, the default, has a cheap model read the
  session's opening message and start it the way the message reads;
  **Always supervise** and **Always hands-on** fix the mode instead.
  Both can be set per project like the other settings of new sessions
  (see [Configuration](#configuration)); the session of a task takes
  `harness-supervisor-tasks` when its work starts, the write-up before
  that only reading. They decide how a session starts;
  from then on each session has its own switch, and changing a setting
  leaves the sessions that exist as they are. A task can carry a mode
  of its own, set on the task board's settings line for the next task,
  or with `C-c h V` in the session list on the sessions of the tasks you
  marked (see [Session list](#session-list)): its session then starts
  with that, whatever the setting says. A task planned in the board's
  [Plan mode](#task-board) works hands-on, unjudged, unless it carries a
  mode of its own: a strong model planned it already. Sub-agents, BTW
  side conversations and the harness's own model calls never supervise,
  and a fork starts as its parent is.

- **The session judge.** Under `auto` the harness asks
  `harness-supervisor-judge-model` (by default the session provider's
  simple model) one question about the opening message: a supervising job
  or a hands-on one? It is a request of its own, tiny, with no tools and
  no thinking, and it runs beside the session's first turn, which never
  waits for it: the session starts supervising as new sessions always
  did, and turns hands-on when the judge reads the message that way.
  Either way a note in the harness's own voice says which, as the naming
  of a session reads "renamed to X" rather than repeating what the model
  said: "judged supervising (claude:claude-haiku)", or "judged hands-on
  (…)", or "not judged (…): supervising as configured". The judge's own
  answer is not shown in the chat (the call is recorded as a session of
  kind `internal` under the session, which the session list shows on
  request; see [Session list](#session-list)), and the note never
  reaches the model. The note carries the two things to do about the
  choice as buttons, like the
  [Undo] of a lasting permission answer: one stops the judging of new
  sessions, by writing the setting that decided this one at the project
  it read, and one puts this session in the other mode, as `C-c h V`
  does. Each click shows the way back, `[undo: …]`, and an undo the way
  on, `[redo: …]`; the note records which state each action is in, so a
  chat draws them again after a reload. The judge is
  asked once, never for a session whose setting is not `auto`, and never
  over a switch you made, before the message or after it: a flip drops
  the pending judgement, and a verdict that arrives after it is ignored.
  A model that is unavailable, answers something unusable or does not
  answer in time leaves the configured default standing, and the note
  says so. A plan call the model wrote before it turned hands-on is
  refused, so nothing starts behind the mode's back.
- **The header button and `C-c h V`.** The header line of a session
  starts with a `supervisor` badge, or a `hands-on` one once the mode is
  off; a window too narrow for the whole line drops it before the
  session's own segments. A
  click on it, or `C-c h V` (`harness-toggle-supervisor`), flips it, and
  the transcript says so. A hands-on session works as sessions always
  did: it may write. Switch the mode back on and writes are denied
  again from the next call, in a turn that is running too; the shorter
  tool list follows at its next step. Only you flip the mode: the agent
  has no tool for it.
- **Every session at once.** `harness-set-supervisor-all` (the menu's
  `V`, beside the other "for all sessions" entries) turns the mode on or
  off for every current session the plugin governs, of every project:
  the sessions of the current tasks (running, pending or blocked)
  included, even a closed one. Sub-agents and side conversations are
  left alone (they never supervise), and so is a session whose task is
  [completed](#task-board) or already at the value asked for. Unless a
  prefix argument says otherwise it also sets `harness-supervisor` and
  `harness-supervisor-tasks`, so new top-level and task sessions
  follow, and it says what still wins over those: a project whose
  `.dir-locals.el` sets `harness-supervisor`. It never rewrites a
  `.dir-locals.el`.
- **What a supervising session can and cannot do.** It reads: files,
  search, other sessions and tasks, your Emacs's buffers and
  documentation, skills and the web. It coordinates: it asks you
  (`ask_user`), keeps its todo list, notifies you, hands work to other
  sessions and tasks (`session_send`, `task_submit`, `task_control` and
  the like), and reads or changes what one of them runs with
  (`session_settings`: a worker's window, model, thinking or budget),
  asks for a directory and hands a task's work in. It plans
  (`submit_plan`, `retry_step`, `no_plan_needed`). And it runs shell
  commands that are read-only and offline: every directory is mounted
  read-only and the network is cut, so `git log` and `grep` work and
  anything that writes fails. That takes a sandbox that can confine the
  command; where none can (`harness-sandbox-policy` is `off`, the
  directory is on another host, neither bubblewrap nor `systemd-run` is
  installed, or on macOS MXC's `mxc-exec-mac`), the session has no bash
  at all, rather than an unconfined one. `write_file`, `edit_file`,
  `ssh`, `elisp`, `spawn_agent` and the
  other tools that change files or run code are not offered, and a call
  to one is denied for good, with a hint to put the change in a step of
  the plan.
- **Every turn ends on a decision.** A supervising turn is not over
  until the model made one: `submit_plan` when the work changes files,
  however small; `no_plan_needed`, with a one-line reason, when it
  answered a question, there is nothing to do or a plan is still
  running; `retry_step`; `hand_in` in a task; or handing the work to
  another session or task (`task_submit`, `task_control`,
  `session_send`, `session_control`, and `session_settings` when it
  changes a setting — giving a worker a larger window or a stronger
  model is coordination, and a read decides nothing). A model that stops
  without one is
  sent back with a reminder, twice at most in a turn; after that the
  turn ends, and the transcript says it ended without a decision.
  `no_plan_needed` does not end the turn: the answer follows it.
- **A soft step budget.** A turn that investigates for too long is
  steered, never stopped. After `harness-supervisor-step-budget` tool
  calls (30) the session is told to stop investigating and submit the
  plan with what it knows, and it is told again every half budget after
  that (at 45, 60 and so on). The budget is small because workers read
  the code they change, so the supervisor needs only enough to split the
  work, and the nudge says so. The default used to be 80, which came from
  164 real sessions (the median reached its plan after 61 tool calls,
  the 75th percentile after 80 and the 90th after 103) under a prompt
  that had supervisors gather everything for their forks.
- **Planning for cost.** The supervisor's tokens are the expensive
  ones: each of its calls reads the whole conversation again on the hard
  model, and its system prompt says so. It investigates only what the
  plan needs: where the work goes, how it splits, what the parts share.
  It writes each prompt for its tier. A medium worker can do a whole
  programming task from a brief the size of a ticket (the goal, the
  constraints, the decisions, the files it owns, how to verify it); a
  simple worker needs its edits spelled out file by file. It splits no
  further than parallel work or a cheaper tier calls for, since fewer,
  larger medium steps cost less. It plans for parallel work: units that
  each own their files, with the components they share defined once, in
  the summary of the plan. A shared component gets a step of its own,
  first, only when the others cannot be written against its spec. Steps
  are fresh unless the conversation is short (see **The fork limit**).
  It does not poll or read the workers while they run, and checks a
  finished plan by what settles it most cheaply, the reports, a diff or
  the test output, and not file by file. The description of
  `submit_plan` says the same about the summary, the prompts, the tiers
  and the contexts.
- **Plans, tiers and models.** Each step has a tier and a one-line
  reason for it: `simple` for mechanical, well-specified edits and
  `medium` for the rest. The tiers are those of the supervisor's
  provider (see [Model tiers](#model-tiers)): on Claude, simple steps
  run on Haiku and medium ones on Sonnet. A plan has no `hard` steps,
  and `submit_plan` refuses one. The supervisor itself runs on the
  hard model, so a step that seems to need it is not broken down
  enough: the supervisor makes the hard decisions, writes them into
  the prompts and splits the work until every step is medium at most.
  Only `retry_step` puts a step on hard, after its worker was not up to
  it (see **Retry and escalation**), and no step ever runs on the
  frontier model. `harness-supervisor-tiers` names a model for a tier
  instead, or a model and a thinking level (a tier it leaves out keeps
  the default). A provider is given a few seconds to list its models
  before a plan decides, so one that answers late still gives a step
  the model of its tier; a provider that names no model for a tier (its
  `:tiers` none, and none of its priced models ranking as that tier)
  runs that step on the supervisor's own model, and the hint and the
  answer of `submit_plan` name the provider and say why, so a worker is
  never silently the expensive one. Plans of old, with the tiers
  `mundane` and `standard`, read as simple and medium.
- **Thinking levels.** Thinking goes with the tier: planning well is
  worth the top effort, and the many small steps are not. A tier can
  name the thinking level its model runs at, as DeepSeek's do: Flash
  thinks at low on simple, at high on medium and at max on hard. A
  session that starts supervising takes the level of its provider's
  hard tier, and each worker the level of its step's tier (the one
  `harness-supervisor-tiers` gives it, else the one the provider of the
  worker's model names), fitted to the levels its model offers: a
  worker whose tier names no level, as Claude's tiers do not, thinks at
  its supervisor's level, and a Haiku worker of a supervisor at max
  thinks at high. The answers of `submit_plan` and `retry_step` and the
  report of a failed step name the level a worker runs at. The
  supervisor's level
  is raised when the mode is turned on and put back as it was when it
  is turned off; a level you choose while the session supervises is
  left as it is when the mode goes off, and after a restart of the
  harness the raised one stands. Workers keep the level they started
  with. The levels are set with the tiers, on the settings page under
  **Model tiers**.
- **Fork or fresh, and `after`.** A step's context is `fresh` (the
  default) or `fork`. A fresh worker starts without the supervisor's
  conversation, in the same directory, and its first message holds what
  it needs: the plan's summary, the same for every fresh worker, where
  the supervisor writes the approach and what the steps share (the
  interfaces, names and data shapes, and which step makes each); its
  own step; the plan's other steps, a line each, in the form
  `- ID: TITLE (after A, B)`; the attempt before it, when it starts
  again; and the reports of the steps it waits for. So the supervisor
  writes what the steps share once, in the summary, and not in every
  prompt. A fork worker is a fork of the supervisor at the call that
  submitted the plan, so it sees everything the supervisor learned, but
  only while that conversation is short (see **The fork limit**). A fork
  that inherits the whole conversation needs neither the plan nor the
  other steps, since the `submit_plan` call is in it; a fork whose
  conversation was compacted (see **Retry and escalation**) is given
  them. `after` lists the steps that must be done first, and a worker is
  given the reports of the steps it follows. Steps with no order between
  them run at once in the same working tree (a task's worktree, in a
  task), so the supervisor gives them different files, and every worker
  is told that others may run beside it and to keep to its step's files.
- **The fork limit.** Fresh is the default because a fork is costly. No
  fork reads its parent's prompt cache: its system prompt names its own
  directories, its tools differ from the supervisor's, and its model
  usually does. So a fork's first request writes the whole conversation
  into its model's cache, and every request after it reads it again,
  which with a long supervisor conversation and several workers was most
  of a plan's cost. A fork step is therefore allowed only while the
  supervisor's conversation is short: `harness-supervisor-fork-limit`
  says how short (20000 tokens by default, nil for no limit; it is on
  the settings page under **Supervisor mode**). The conversation is
  estimated from the transcript at about four characters a token. The
  estimate leaves out the system prompt and the tools, which a fresh
  worker has too, and the thinking, whose signatures tie it to the
  supervisor's model. Past the limit `submit_plan` refuses the plan. The
  refusal names the fork steps, the size and the limit, and tells the
  supervisor to make the steps fresh and to put what the workers need in
  the summary and their prompts. A plan made before the limit existed,
  or past a limit lowered since, can still have fork steps: they start
  from a compaction of the conversation, the same one a step that starts
  again gets when no warm seed holds its context (see **Retry and
  escalation**), and a hint tells the supervisor so.
- **Cache seeds.** A provider's prompt cache serves only the model that
  wrote it, so every fork onto a cheaper model would pay to write the
  whole conversation into that model's cache, and no two forks share a
  prefix, since a system prompt names its own directories. Fork steps
  are for a short conversation only (see **The fork limit**), but even a
  short one is written again for each of several forks. When a plan
  has two or more fork steps on one model, the harness forks them
  through a *seed*: a fork of the supervisor on that model, sent one
  tiny message that writes the context into the cache once. Each worker
  is then a fork of the seed, sends the seed's system prompt word for
  word, and reads the context from the cache. The seed is a sub-agent
  session like any other, named "Shared context for ..." in the session
  list, and stays there until you delete it. The harness marks it as a
  seed, so the header's `↑` (`C-c C-u`), `C-c h o` and the session
  pickers pass over it. One fork step on a model has nothing to share
  and is forked directly.
- **Short context for workers.** A worker is a sub-agent, and
  sub-agents work on a deliberately short context window,
  `harness-subagent-context-limit` (256000 tokens by default, nil for
  no cap): a fresh worker's window is that limit, and a fork gets what
  it inherits plus the limit, never more than the supervisor's own
  limit or its model's window. Calls stay cheap, a worker that
  outgrows its window compacts early, and its report stays short. The
  worker's transcript says so, in a hint at its start ("Context window
  capped at 256k tokens, as a sub-agent's is
  (harness-subagent-context-limit)"), as the transcript of any
  sub-agent does. A worker compacted before it starts (a fork step that
  starts again with no warm seed, or one whose plan is past the fork
  limit; see **Retry and escalation**) is capped from the summary it
  starts with, not from all the supervisor holds.
- **Reports back.** Submitting the plan ends the turn: the supervisor
  does not wait or poll, and the harness reports to it in messages of
  its own (**System · supervisor**). A worker ends with a short report
  of what it changed, how it checked it and anything the other steps
  need to know. A finished step is a hint in the transcript and starts
  the steps that waited for it, which are given that report. A step that
  did not get done (its worker could not be made, its turn failed, was
  cancelled or blocked, or its session was deleted) is a message of its
  own: the step, its tier and model, why, the steps held on it and the
  ways on. When the last step is done, a message lists every step with
  its result and asks the supervisor to check the work as cheaply as
  settles it (the reports it lists, a diff, the test output), reading a
  file or a worker's session only where a report leaves doubt, and to
  decide. An idle session starts a turn on a message, and a running turn
  is steered.
- **Retry and escalation.** After a failure the supervisor calls
  `retry_step`, which runs the step again on a new worker, with notes on
  what went wrong and, when the model was not up to it, a higher tier:
  medium, or hard, the only way a step gets the hard model. It
  does not end the turn, so several steps can be retried in one
  message. Or the supervisor submits a new plan, which supersedes the
  steps of the earlier ones that have not started (their running steps
  finish as usual), or it asks you. A fresh step that starts again,
  retried or interrupted by a restart, gets a new fresh worker, started
  as the first was. A fork step that starts again does not make its
  worker read the whole conversation uncached on a model that never saw
  it, which a higher tier usually is. With a warm seed on the step's
  model its worker forks through the seed; otherwise it forks the
  supervisor and is compacted before its first turn, as the cold-cache
  question would for a session nobody is asked about (a brief summary by
  default, see `harness-cowboy-default`), and a hint tells the
  supervisor which. A fork step whose plan is past the fork limit starts
  from the same kind of compaction. The message of a worker that starts
  again also says which session, model and error the attempt before had,
  so it can read what was tried (`session_read`) and not repeat it.
- **In tasks.** The session of a task starts as the task's own setting
  says, else `harness-supervisor-tasks` (judged, by default, from the
  message that starts the work), and a
  supervising task session plans and delegates: the last step of its plan
  commits (`git add -A && git commit`). Once the plan has finished and the
  supervisor has checked the result, it calls `hand_in`; feedback from
  your review leads to a new plan that fixes the work. While workers run,
  the task stays active, with a line of what it waits for, instead of
  going to review when the turn that submitted the plan ends, and it
  keeps its slot meanwhile (see the limit under [Task board](#task-board)),
  so work you send back from review can pre-empt it. The session
  that writes a backlog task up only reads, and takes the setting when
  the task starts.
- **When a task goes back to the queue.** A task pre-empted by work you
  sent back from review, or returned to *Pending* with `u`, stops its
  plan's workers with it. Each running step is marked interrupted, with
  why, and its worker's turn is cancelled together with the sub-agents
  the worker started; a worker still being made never gets its step. The
  supervisor is told once, in one message of the harness's own for all the
  steps, which waits in its session while the task waits in the queue:
  nothing runs or starts again by itself, and the steps held behind an
  interrupted one wait for the supervisor. When the task carries on, the
  supervisor reads the report and runs the steps again with `retry_step`,
  or plans again.
- **Merging back.** The merge queue takes a target rather than a
  parent: the session a branch merges into, or the main checkout
  itself. A sub-agent started in a worktree (`spawn_agent` with
  `worktree`) merges into the session that started it, beside whatever
  else merges there. A session that is itself a worktree -- a task's --
  merges into the main checkout, and may be the target of the sessions
  it starts in between, at any depth: one queue, one conflict
  resolution, one set of events.
  A merged branch lands as one commit, not as the small ones its agent
  made: its subject is the session's name, and its body lists the
  commits the branch brought and their diffstat, so the history reads
  as one pull request per task. A branch whose work is already in the
  target merges without a commit.
  Order follows the work: a branch may be queued upward while the
  merges into its own worktree are still to come, but it waits for
  them, and the session may not hand in (`hand_in`) until they are
  through, so what reaches main is built on what it was built on. A
  merge that failed is the child's to fix and does not hold the
  session back; the queue says so and the panel shows it.
- **After a restart.** Workers die with the harness. Once it is up
  again, the steps that were running are marked interrupted and
  reported as a failure is: to the session of a task as a message, so
  the task carries on, and to any other session queued, to go with your
  next message instead of starting an expensive turn you did not ask
  for. `retry_step` runs an interrupted step again.
- **Approving plans.** In Ask mode you approve each plan
  (`submit_plan`), in the permission prompt, before any worker starts,
  and each retry (`retry_step`, which starts a worker too) the same way.
  In Accept edits, Auto and YOLO mode, and in any non-interactive
  session whatever its mode, plans and retries are allowed without
  asking, and without the auto-mode judge: it never rules on a plan. A
  plan changes nothing by itself. Every call a worker makes is decided
  in the worker's own session, by its mode and the judge as usual, and
  the workers run with the supervisor's permission mode, directory
  grants and non-interactive switch, so in Ask mode their edits ask too.
  A standing deny rule for `submit_plan` still denies it.
- **A plugin.** Without `supervisor`, everything else works as before:
  no turn has to end on a decision, sessions keep every tool, and the
  header line shows no segment. So leave it out of
  `harness-enable-modules` (or, when every module loads, add
  `supervisor` to `harness-disabled-modules`, which takes
  `ui-supervisor` with it), and `seed` too if nothing should share a
  cache this way.

### Priorities

Every session has a **priority**: low, **medium** (the default) or
**high**. It is always the session's own — a task's priority is its
session's, and every task has that session from the moment it is
submitted, so a task waiting for a slot already carries the priority it
will start with, and setting a task's priority is setting its session's.
The harness serves the work of a session by it: the tools that start
processes hold a slot per machine and give the waiting calls to the
highest priority session first (the "Polite with your machine" bullet in
[Features](#features)), and the task board starts waiting tasks the same
way (see [Task board](#task-board)).

The commands take the session in front of you:

- `C-c h +` and `C-c h -` raise and lower it a level and say what it is
  now (`C-u` on either asks for the level);
- `C-c h y` sets it, asking for the level (`harness-set-priority`);
- `C-c h Y` gives every current session and task session of every
  project the level you choose (`harness-set-priority-all`);
- in the session list (`C-c h l`), a **Priority** column shows each
  session's arrow -- up for high, down for low, nothing at medium, the
  default -- and a click on it asks for and sets the priority of the
  session on that row, while `+`, `-` and `p` set the priority of every
  marked session, or of the session at point when none is marked (see
  [Session list](#session-list));
- the chat's header line shows the same arrow beside the session's name
  when the priority is not the default, and a click on it, like the
  list's and a card's, offers the levels as a menu at the click.

A session with no priority of its own takes its parent's, so the
sub-agents and forks working for a task work at the task's priority. An
agent sets one with the `set_priority` tool (a `session_id`, and
`all=true` for every current session and task of every project at once),
the session of a task being the one `task_list` shows for it;
`task_control`'s `priority` action does the same for a task's session.

### Session list

`C-c h l` lists the sessions of the current project, its git worktrees
and so its tasks' sessions included; `a` lists every project's. A row
has the session's status, name, kind, model, thinking level, priority,
context, average output rate, cost and when its last message came, and
the project when every project is listed. Forks, BTWs and sub-agents
are indented under their parents, a task's session goes by its task's
title, and the column headers sort. `/` filters by name, model, status,
kind and permission mode, `i` hides or shows inactive sessions and `b`
shows only the sessions waiting for you. `RET` opens a session in its
project, `o` in another position, `f` forks it, `r` renames it and `M`
moves it to another directory (see
[Moving a session](#moving-a-session-to-another-directory)).

- **Columns.** *Avg tok/s* is the session's output tokens over the
  seconds its model spent streaming them, averaged over its whole life,
  so waiting for a first token and running tools do not count; hover
  over it for the current rate beside it. A task's card on the board
  shows the same average (`48 tok/s avg`). *Think* is the session's
  thinking level, empty on its model's default. *Last msg* is how long
  ago its last message from you or the agent came; a session saved
  before the harness kept that shows its last change of any kind
  instead. *Mode* and *Output* are hidden by default
  (`harness-ui-sessions-hidden-columns`), and `C` shows or hides a
  column in that list only. *Project* shows only when every project is
  listed, as in one project's list it says the same on every row.
- **Marks.** Sessions are marked as files are in Dired. `m` marks the
  session at point and moves to the next row (a numeric argument marks
  that many), `u` unmarks it and moves on, `DEL` moves up and unmarks
  the session there, `U` unmarks every session and `t` inverts the
  marks of the rows listed. A `*` before a row shows its mark, and the
  mode line counts them. The marks stay through a redraw, `g`, the
  filters, a change of scope and a pause. A session a filter hides
  stays marked and is acted on with the rest, so `U` is the way to be
  rid of marks out of sight.
- **Acting on the marked sessions.** `d` deletes them after one
  question, `k` cancels the turns of those that run or wait for you,
  `x` deactivates them, `M-t` makes them tasks on their projects' task
  boards, `+` and `-` raise and lower their priority and `p` sets it,
  asking for the level once. With no mark each acts on the session at
  point. `d`, `k`, `x` and `M-t` unmark the sessions they acted on and
  leave the mark on one they skipped, such as an idle session `k` has no
  turn to cancel; `+`, `-` and `p` leave the marks, so several changes
  can be given to the same sessions. `f`, `r` and `M` act on one
  session and refuse while any is marked. `RET`, `o`, `SPC`, `y` and
  `n` are always the session at point's.
- **Settings.** The harness's setting commands act on the marked
  sessions too: `C-c h m` sets the model, `C-c h T` the thinking level,
  `C-c h p` the permission mode, `C-c h i` non-interactive mode and
  `C-c h V` supervisor mode; the menu (`C-c h ?`) runs the first four
  too. They change every marked session, or the session at point when
  none is marked, as in that session's chat, and the offer they make is
  what the marked sessions agree on. A marked session that works on a
  task passes the setting on to its task, which keeps it for its next
  start. A model switch that would lose conversations asks once, for all
  of them, how to hand them over (see
  [Switching model or provider](#switching-model-or-provider)). The
  marks stay, so more can be given to the same sessions. The list binds
  no key of its own to these commands: its `m`, `T`, `p` and `i` are
  others, so the prefix is how they are reached there.
- **Tasks only.** `T` lists only the sessions that work on a task, with
  the sub-agents, forks and BTWs under them, and `T` again lists them
  all.
- **The harness's own model calls.** The permission judge, the Elisp
  judge, the session judge, auto-naming, recaps, the Insights summary,
  the pet and the task board's search each record the call they make as
  a session of kind `internal`: its model, status, cost and time, with
  the prompt as a message the harness sent and the reply, which you can
  open and read. They come and go with every call, so the list leaves
  them out; `I` shows them, and the mode line says `+internal` while
  they show (`harness-ui-sessions-hidden-kinds` names the kinds left
  out). They are records, not conversations: nothing can be sent to one,
  the notifier and the session pickers leave them out, the task board
  and the conversation tree do not reload for them, and the newest 100
  are kept, the oldest that are not running being deleted as new ones
  start.
- **Pause.** The list follows the sessions as they change, a few times a
  second while a model streams. `P`, or the `[Pause]` button in the mode
  line, makes it hold still until you resume it or reload it with `g`;
  changes, rates, token counts and a reload of the UI leave a paused
  list alone, while its own commands -- the filter, the scope, the
  toggles -- still redraw it. The mode line says so, and a mark shows at
  once even on a paused list.

`SPC` pops out what a blocked session waits on, with `y` and `n` to
allow or deny a permission request, and `F` gives the list the
fullscreen layout (see [Fullscreen overviews](#fullscreen-overviews)).

### Task board

`C-c h a` opens the task board of the current project. Each task runs in
its own session and, in a git project, normally in its own worktree and
branch, so several tasks can work in parallel; a task that has to touch
your checkout itself can be submitted to the **main tree** instead (the
`own worktree` / `main tree` switch below).

The task board is the `tasks` module, which brings the board itself,
`ui-tasks`. The rest of what this section describes is modules of its
own, enabled beside it: `merge` gives each task a worktree (from the
core's `worktree` module) and merges it back (without it tasks work in
the main tree), `tools-handin` gives task sessions the `hand_in` tool
they finish with, `ui-review` and `ui-patch-review` show the reports to
verify or send back, `recap` writes the recaps on the cards,
`tasks-notify` notifies you, and `tasks-search` is the board's search:

```elisp
(harness-enable-modules
 :features tasks merge recap tasks-notify tasks-search
 :tools handin sessions
 :ui review patch-review)
```

- Write a task in the compose box at the bottom of the board and press
  `C-c C-c` to submit it. `C-c C-t` cycles the box through three modes
  (`C-u C-c C-t` asks for one by name;
  `harness-ui-tasks-refine-by-default` picks the board's first):
  - **Submit** starts the task at once.
  - **Refine** has an agent write the task up first, briefly: it reads
    as much of the code as it needs to name the files and functions,
    changes nothing, and turns a sentence into a task description.
  - **Plan** has a strong model -- the hard tier of the task model's
    provider, Opus for Claude (see [Model tiers](#model-tiers)) -- read
    the code, make the decisions and hand in a plan
    (`submit_task_plan`) written for a cheaper model, the medium tier
    (Sonnet), which carries it out once the task starts. The planning
    session only reads, as a supervisor does: it gets the reading tools
    alone, its shell runs read-only and offline, anything that would
    ask you is denied, and it is told to hand the plan in after about 40
    tool calls. A turn that ends without a plan is sent back, twice at
    most, to hand one in. The plan becomes the task's prompt and its
    session's plan, and a reply to the planning session is feedback it
    answers with a new plan. Plan is there beside
    [supervisor mode](#supervisor-mode), not instead of it: a planned
    task's work runs hands-on, since its plan is made already, while
    the work of a submitted or refined task supervises or not as its
    switch says.

  A refined or planned task waits in *Backlog*, across restarts, until
  you start it with `s`. *Pending* holds only the tasks
  waiting for a slot, which the queue starts by itself as slots free;
  *Backlog* is its own section, and the queue never starts one of
  those: `Q` on a backlog card (or its [Queue it] button) puts it back
  in *Pending*, where it starts by itself as soon as a slot frees, and
  `s` starts it at once. Right after its count, the *Backlog* heading
  has the project's switch between the two ways out, **[Manual queue]**,
  the default, and **[Auto queue]**: click it, or press `W`. With the
  auto queue a task joins *Pending* by itself as soon as its write-up
  is done -- one done again after your feedback too -- and the queue
  starts it like any waiting task, by priority as slots free, and not
  while the queue is suspended. A write-up that fails, or that finds
  the task a duplicate, still waits for you, and switching moves none
  of the tasks already in the backlog. The switch is kept per project,
  across restarts; `task_control`'s `auto-queue` and `manual-queue`
  flip it too.
  Refining and planning look at the board
  first: a task it already has is refused rather than written up (drop
  it, or write it up anyway), and the write-up or plan names the tasks
  working on the same code, to coordinate with instead of redoing their
  work.
- The board's keys are letters, which type in the compose box. `C-c .`
  and then a key presses it on the board from the box: `C-c . F`
  starts the fullscreen layout, say (see [Pressing a panel's key from
  the compose box](#pressing-a-panels-key-from-the-compose-box)). The
  empty box shows the key in its hint, and its tooltip names it. The
  keys for the task at point need a card under point, which the box has
  none of, and say so.
- `@` on a card attaches its task to the compose box, whatever the box
  is for: the new task, the message or the feedback it sends carries the
  task along as text (its id, title, column, session, branch and prompt),
  and `@task:ID` goes into the text as a chip a click opens, so
  "do what t-1a2b should have done" names the task it means. `C-c C-a`
  attaches a task too, as `task:ID`, and `@task:` in the box completes
  the project's tasks. An answer to a question is text only: a task its
  text names goes as its reference, and anything else attached stops it.
- The lines above the compose box are the current mode's alone. A step
  of a task has a model and a thinking level of its own, and nothing
  else. In Refine and Plan a line per step says which model does it, at
  which thinking level: first `refine` or `plan`, which write the task
  up or plan it, then `work`, which does it once you start it. Below
  them one line holds what the whole task works with, whatever step it
  is in -- permission mode, interactive or not, supervisor mode, where
  it works -- and ends with how many tasks work at once. Submit has
  that line alone, starting with the work's model and thinking level.
  Click a model or a thinking level to change it for the board's new
  tasks.
  Refine writes up on `harness-tasks-refine-model` (the task's own
  model when nil) at `harness-tasks-refine-thinking`, and works on the
  task model. Plan plans on the hard tier and works on the medium tier
  of the task model's provider, falling back on the task model where
  the provider names no model for a tier; the choices travel with each
  task (`task_submit`'s `plan` does the same for an agent), so the tiers
  are only defaults, not options.
- `harness-tasks-max-running` limits how many of a project's tasks work
  at once (nil, the default, means no limit). The settings line above
  the compose box ends with it in every mode, as
  `N at a time`, or `all at once` without a limit: click it to set
  another, a number or `no limit`. A write-up or a plan takes no slot:
  the limit counts the tasks at work, and a refined or planned task
  takes one only once you start it.
  Like turning review off, that sets the option for every project and
  saves it for later sessions. Raising the limit starts waiting tasks
  at once, and lowering it stops no task at work; at `0` no task starts
  by itself, and the button turns to a warning colour. Every project
  has that many slots of its own; a task submitted while they are all
  taken waits in *Pending* and starts in the order *Pending* lists --
  by priority, then within one the work sent back from review, the
  tasks paused or pre-empted, and the oldest -- when one frees up, or
  at once with `s`. Only top-level
  sessions are limited: a task takes a slot while its own session
  works on it, running or waiting for your answer mid-turn, and while
  its turn is over but the workers of its supervisor plan or its
  sub-agents are still running. The
  sessions working for it -- its sub-agents and forks, and the sessions
  resolving its merge conflicts -- never take one, and neither does a
  task in *Merging*, so the merge queue never holds up the next task.
  The harness's own model calls -- a task's title, the recaps, the
  permission judges and the like -- are neither tasks nor turns: they
  never take a slot or wait for one, so a title or a verdict comes even
  with the board full or the limit at `0`. Being ordinary requests to
  the model, they are tried again below the board when the connection is
  lost, as any request is; a title that still fails is not asked for
  again while its task waits, and its session is named from its first
  message once the task starts.
- With a limit, a task that has waited on you -- a question, a
  permission request -- for five minutes **lends its slot**
  (`harness-tasks-lend-blocked-slot-after`, in seconds; nil never
  lends): the queue starts the next task in it,
  whose card says `borrowed slot`, and the waiting task's card says
  `slot lent`, each naming the other in its tooltip. Answering takes the
  slot back at once: the borrower goes back to the front of *Pending*,
  its turn stopped and whatever it left running stopped with it, keeping
  its session, branch and worktree, and carries on where it stopped when
  a slot frees, its session told why; the task you answered works on in
  its slot. A borrower that finished in the meantime leaves nothing to
  take back. A task waiting on you that still has workers or sub-agents
  running keeps its slot, and so does a borrower that comes to wait on
  you: it never lends a slot it only borrowed.
- `S` on the board, or `C-c h Q` from anywhere, opens the project's
  **Task slots** page: a box for each slot, in use or free -- the task
  that holds it, its priority's arrow, what it is doing (running,
  waiting on you, starting) and for how long -- then the queue by
  priority, with how many wait and the longest and average wait so far,
  the next five in line, and how long tasks waited for a slot over the
  last `harness-tasks-slot-wait-days` days (7), by priority. `RET` or a
  click on a box opens its task's session, `TAB` goes from box to box,
  and `[Set limit]` (`l`) is the board's `N at a time`. The page keeps
  itself current without churn: it asks the harness again once a burst
  of the board's events settles, and only while a window shows it (a
  hidden page asks once when it shows again); its times run on the
  board's own 15-second clock; and a redraw that would change nothing is
  skipped. The harness answers it with `task/slots`, which counts the
  slots as the scheduler does.
- Each card is one line, with a subtitle that recaps the task: what it is
  doing or has done so far, written by a short model call and refreshed
  at the first of so many turns, seconds or tool calls since the last
  one, like a warranty's months or miles (see
  `harness-tasks-recap-turns`, `harness-tasks-recap-seconds` and
  `harness-tasks-recap-tool-calls`). The recap shows by default where it
  matters most, in *Requires your input* beside what the task waits for;
  elsewhere `TAB` on a card, or a click on its chevron, shows it. A card
  in *Merging* says on its one line when the merge is under way or in
  conflict.
- A section's cards line up: the titles start at one column, whatever
  arrow or icon a card has before its title; the facts -- how long the
  task has worked or waited, its tokens, its output rate, its cost --
  stand in right-aligned columns that the section's cards share; and
  the buttons start at one column. A section short of room lets a
  column go on all its cards at once, the tokens first, never on one
  card alone. A pending card says how long its task has waited since it
  joined the queue.
- A board taller than its window holds its least urgent cards back,
  behind `… N more  [Show all]`. A section opened with `[Show all]` keeps
  its `[Show fewer]` only while folding it would still hold cards back:
  once its list shrinks to fit, the line goes, as `[Show all]` does from
  a capped section that comes to fit.
- A button you push on a card is held down at once -- dimmed and sunk --
  until the harness has answered what it asked for, for at least 0.3
  seconds and at most 15, and pushing it again meanwhile does nothing. A
  key typed on a card (`s`, `v`, `k`, ...) holds that card's button for
  it down the same way.
- `C-c h m`, `C-c h T`, `C-c h p` and `C-c h i` set the model, thinking
  level, permission mode and non-interactive mode of the next task, or
  of the task at point. New tasks run in auto mode and are interactive
  unless your configuration says otherwise, so a request that needs
  you, such as access to another directory, waits for you in *Requires
  your input* instead of being denied. In Refine and Plan the model
  and thinking level these set are the `work` line's, and the message
  says so; the `refine` or `plan` line's are set by a click on them.
  While the supervisor module is
  loaded the settings line also shows a `supervisor` / `hands-on`
  switch, the same one a session's header has: it sets
  [supervisor mode](#supervisor-mode) for the task about to be
  submitted. Plan has none, as a planned task works hands-on: there
  `C-c h V` says so instead of changing anything. To change many tasks
  at once, mark their sessions in the session list and use the same keys
  there (see [Session list](#session-list)).
- The `own worktree` / `main tree` switch beside those settings, in a
  git project, picks where the next task works: **own worktree**, on its
  own branch, merged back when it is done, or **main tree**, the
  project's checkout itself, with no branch and nothing to merge. Use
  the main tree for work that has to touch the checkout directly, such
  as cleaning up uncommitted changes; those tasks show `main tree` on
  their card, and a refined task keeps the choice for when you start it.
  An agent can ask for the same thing with `task_submit`'s `main_tree`.
- Every task has a **priority**: low, medium (the default) or high. A
  task has no priority of its own — it is its session's, which every
  task gets as it is submitted, so setting a task's priority is setting
  its session's (see [Priorities](#priorities)). It
  matters when `harness-tasks-max-running` limits how many of a
  project's tasks work at once: the others wait in *Pending*, and a
  free slot goes to the highest priority waiting. Within a priority,
  work you sent back from review goes first, then the tasks put back in
  the queue after they worked (paused, pre-empted, or their borrowed
  slot taken back), the first put back first, and then the rest, oldest
  first. *Pending* lists them in that order, each card saying its place
  (`#1 in line` starts next), and so does `task_list`, whose pending
  lines say `#N in line` and why a task is ahead of older ones. A priority
  stops a task at work only for work you send back from review, which
  can take the slot of a task it outranks (see *Ready for review*
  below); the only other task stopped to free a slot is one working in
  a slot lent while its lender waited on you, once you answer, whatever
  the priorities. A backlog task still waits for you to start it. The
  `medium priority` button beside the Submit / Refine / Plan switch sets the
  next task's (a click cycles it through high and low);
  `+` and `-` on a card raise and lower that task's — the session's it
  already has, waiting or not — to reorder the
  queue; to give many tasks a priority at once, mark their sessions in
  the session list and press `p` there (see
  [Session list](#session-list)). A high task shows `↑`
  before its title and a low one `↓`, and nothing more: no words among
  the card's facts repeat it. An
  agent sets it with `task_submit`'s `priority`, `task_control`'s
  `priority` action or `set_priority` on the task's session, and the
  board's search understands "do the docs
  task first".
- The `own worktree` / `main tree` switch and the priority button above
  the compose box apply to the next task only; the main-tree switch
  keeps it on when clicked again, and the priority notice's `[keep on]`
  keeps the priority for every task. A coloured line above the box says
  which mode is armed.
  A task that stopped -- its session errored, was cancelled or was
  interrupted -- has [Retry] on its card, and one at work or stopped
  part way has [Pause], which puts it back in *Pending* to carry on
  where it stopped. *Requires your input* sorts by priority, and a
  message that restarts a stopped task shows it in progress at once,
  even while the cold-cache compaction holds its turn up.
- Task sessions run on at most 384k tokens of context
  (`harness-tasks-context-limit`): they compact sooner than interactive
  sessions, so a long task works from a smaller transcript between
  turns. Set it to another number of tokens to tune that, or to nil to
  give task sessions the whole window like any other session. The
  session's transcript says so in a hint when it is created, so the cap
  is never silent. A
  provider that compacts on its own side keeps its own threshold,
  except Claude Code, which the harness tells to compact at the same
  point.
- A turn is not capped: the harness does not limit how many model calls
  a turn may make, so a task runs as long as the work needs. It ends
  when the agent hands in, the provider stops it (an error, or the
  model hitting its output limit), a merge hold pauses it at a step
  boundary, or you cancel it from its session. Automatic compaction
  (above) runs between turns, so a turn that outgrows the model's
  window reaches the provider's own error; budgets still refuse *new*
  turns once they are spent.
- Finished work waits in *Ready for review*. Press `v` to verify it
  (its branch merges and the task is done) or `R` to send it back to
  its session with feedback. Any message you send to a task waiting
  for review sends it back the same way, with your message as the
  feedback, wherever you write it: in the task's session (no need to
  press `[Send back]` first), with `m` on the board, or from another
  device. The task goes back to work and comes back for review when it
  is done, within `harness-tasks-max-running`: its slot may have gone
  to another task while it waited for review. With no slot free it
  **pre-empts** a task at work that it outranks -- one of a lower
  priority, or one of its own priority that is not itself work sent
  back from review, so a task that just started gives way to your
  feedback -- taking the lowest-ranked such task's slot, the one that
  started last among equals. A task whose turn is over but whose
  supervisor plan's workers or sub-agents still run counts as at work
  too. The task pre-empted goes back to
  *Pending*, its turn stopped and the work its session left running
  stopped with it: the workers of its plan and its sub-agents are
  cancelled, and what they were on is reported to the task, to read
  when it carries on (nothing restarts by itself: it retries or plans
  again). It carries on where it stopped when a
  slot frees, its session told why, as a session is after a restart.
  When every task at work outranks it (a higher priority, or other
  feedback of its priority), the task sent back waits at the front of
  its priority in *Pending* with your feedback, which reaches its
  session when it starts, with anything else you send it meanwhile;
  raising its priority above a task at work starts it at once. A
  suspended queue holds it too, until you resume the queue or start it
  with `s`. A pending card says why the task waits: pre-empted by
  which task, its borrowed slot taken back by which task, or sent back
  and waiting for a slot. Only you review: a
  message another session's agent
  sends the task (`session_send`, or `task_control`'s message) reaches
  it as that session's, not as your feedback. The task deals with it
  and waits for review again, its report standing unless it hands in a
  new one; an agent sends work back only with `task_control` reject.
- `u` returns a task at work to *Pending*, one that only waits on its
  supervisor's workers too. Its turn stops and it keeps its session,
  branch and worktree. It goes to the front of its priority's queue and
  carries on where it stopped when a slot frees, or at once with `s`;
  returning it starts nothing itself. `P`, or a click on
  **[Queue: running]** right after the *Pending* heading's count,
  suspends the project's queue, so that no waiting task starts by
  itself until you resume it; the switch then reads
  **[Queue: suspended]**, and a click or `P` resumes it.
  Whatever its session left running outside its turn stops with it, as
  it does for a task that is pre-empted: the workers of its supervisor
  plan and its sub-agents are cancelled, and what they were on is
  reported to the task, to read when it carries on.
- When the project is the harness itself, and its own plugin is
  loaded (see [Development](#development)), a card in *Ready for
  review* whose worktree is a checkout of the harness also has
  **Open harness** in its menu (right-click the card): it opens an
  Emacs running that worktree's harness in an instance of its own,
  its frame raised, so the work can be tried before it is verified.
  It is not a button on
  the card; a click on the card's title opens the task's session, as
  on any card. The agent has the same as the `open_harness` tool, which
  starts such an instance for its own worktree and says how to drive it
  (`scripts/dev.sh` with its socket). The socket is linked into the
  session's temporary directory, so the agent's sandboxed commands
  reach it.
- These instances stop by themselves once nothing needs them. One
  opened for you to look at (Open harness, or the agent's
  `open_harness` with `focus`) stays until its task is done, archived
  or deleted. One the agent opened to test its work stops once that
  work stops: when the task goes to review, is done, or stops on an
  error or a cancel; when a sub-agent finishes; when a conversation is
  closed or has been idle for an hour. Removing a worktree stops its
  instance first, and every instance exits once the Emacs you run the
  harness in quits. A sweep every ten minutes also stops the instances
  of finished tasks that an older harness left running.
- To skip review, press `V` on the board, or turn off *Require
  verification* under Task board on the settings page. Finished tasks
  then merge and complete without waiting for you, and if tasks are
  already waiting for review, `V` offers to verify them. Both set
  `harness-tasks-require-verification`, so it applies to every project
  and is saved for later sessions. Press `V` again to turn review back
  on.
- A verified task waits in *Merging* while its branch goes through the
  merge queue: queued for the queue's turn, merging, or, when the merge
  conflicts, a fresh session the harness starts in its worktree
  resolving them (`harness-merge-conflict-resolver`; it spares the
  task's long, long-cold session). That session runs on a model no
  stronger than the medium tier -- Sonnet for a task on Opus or Fable --
  and thinks no harder than the level its provider's medium tier names,
  else at medium (`harness-merge-resolver-model`). The card says
  where it stands; the task moves to *Completed* once the branch is in.
- A task's session finishes by *handing its work in* (`hand_in`): the
  agent gives a final summary and the evidence for it -- an image or a
  video of what it built whenever there is anything to see, a file, a
  code block, a note, or a link to an earlier tool call, the tests or a
  command it ran. The turn ends there and the task waits for your
  review. In the session itself a banner above the compose box shows
  that report in full, already expanded -- the summary, then every piece
  of evidence, a referenced call with its whole output -- and offers
  `[Verify]` (`C-c C-v`), `[Send back]` (`C-c C-x`; type the feedback
  in the box, `C-c C-c` sends it) and `[Review]`, which pops it out, so
  you can read the work and accept it without going back to the board.
  The two keys work only while the banner shows; otherwise `C-c C-v`
  is nothing there, the box pasting with `C-y`. `C-c >` on the summary
  quotes it in the box, as it does a part of it you select, so the
  feedback can answer it point by point. Two flags change where the
  hand-in goes. `cannot_continue` is for a task that cannot be
  finished: say what blocks it in the summary; it goes to *Requires
  your input* instead, and nothing merges. `no_merge` is for
  informational work that changes nothing: it still waits for your
  review, and verifying it completes the task without the merge queue.
- `[Review]` on a card that has a report, or on the banner, pops the
  handed-in summary and evidence out beside the board: images large, as
  wide as the popout, videos as thumbnails, files as buttons, and each
  referenced tool call as the call it links to, with
  `[Open in the session]`. Click an image, or press `RET` on it, to see
  it larger still in a popout of its own; `q` goes back to the report.
  While the task waits for review, the report ends with the same banner
  as its session: `[Verify]` (`C-c C-v`) and `[Send back]` (`C-c C-x`),
  and a box under it for the feedback (`C-c C-c` sends it), so you can
  read the work and accept it in one place; `C-c >` quotes the summary
  in that box, or the part of the report you select. Once the review
  is decided -- the task verified, or sent back with feedback -- the
  report closes, wherever that was done: from the board, from the
  session's banner or from the report's own banner. The board's
  item-at-point key (`SPC`) opens the report too, along with whatever
  else the task has to show.
- While the task waits for review, its report also shows its changes,
  under the evidence and above the banner, to go through them the way a
  patch is reviewed on a mailing list: the files its branch changes
  against its merge base with the branch it was made from, a row each,
  with its status, what changed (`+3 −1`), a check mark once you looked
  at it, and your comments on it. `RET` on a file, or a click, compares
  it in Ediff, the merge base against the branch, in the report's frame.
  There `c` comments on the current difference (one line in the
  minibuffer), `N` and `P` go on to the next or previous file, and `q`
  comes back to the report as it was, point on the next file. Each
  comment goes into the report's box for the feedback the way a reply to
  a patch has it: the lines it is about quoted from the diff with `> `,
  under their file's `diff --git` line, a few lines of context first
  (`harness-ui-patch-review-context-lines`), your comment under them.
  Edit the box as you like and write around the comments; `C-c C-c`
  sends it all back to the task as its feedback, in one go. Git runs in
  the Emacs that shows the board, so the changes show where the task's
  repository is on this machine. Ediff's own settings apply
  (`ediff-split-window-function` puts the two versions side by side);
  `harness-ui-patch-review-ediff-window-setup` keeps its control panel
  in the frame. The module (`ui-patch-review`) is self-contained:
  without it, left out of `harness-enable-modules` or added to
  `harness-disabled-modules`, the changes leave the report.
- `I` adds an ongoing session to the board as a task, and `b` opens a
  BTW conversation about the tasks.
- `SPC` on a task that needs input pops out what it waits on -- the
  permission prompt or the question, with its options and diagrams --
  and answers it there. The card offers the same as [Answer…] or
  [Request…] next to [Allow] and [Deny].
- `/` searches in words, in the board's own compose box. It turns the
  box into a search box, in colours of its own, and what the box held
  -- a task being written, a message -- waits aside and comes back once
  the search is sent or `C-g` closes the box. A line there is a
  question about the tasks ("did I have a task about the question
  button?"), an order ("restart the errored tasks", "get rid of the
  pagination task"), or a session or a command to find ("where did I
  debug the merge queue?", "how do I attach a file?"). `RET` sends it,
  and `M-p` and `M-n` bring back earlier searches. The line goes with a
  dump of the board, the other sessions and the harness's commands to a
  quick, cheap model (`harness-tasks-search-model`, the provider's
  simple tier by default), which favours tasks here and answers with
  the tasks it is about, what to do with them, the sessions and
  commands it found and, when words answer the line ("how many tasks
  failed?", "what is the docs task waiting for?"), the answer in words.
  The board then shows only those tasks, archived ones included, under
  a banner that says what it shows, has the answer in words, whole and
  rendered as Markdown, and lists the sessions and commands found, each
  with its `[Open]`
  (at the message where your words were found, for a session found in
  its transcript), `[Run]` or `[Describe]`; `C-g` on the board, once the
  box is closed, or `[Clear]` shows every task again. When no task
  matches, the search looks wider instead of saying so: the banner then
  lists the sessions and commands that come nearest, with a note that
  says that. An order that is easily undone or does no harm -- archive
  of a task not at work, restore, retry, start, a new priority -- runs
  at once and the banner says so, with `[Undo]`; one that interrupts
  work, merges it or sends words to an agent -- stop, archive of a
  working task, verify, mark done, message, send back -- is offered
  instead, and `/` then `RET` on the empty box runs it. The model may
  look further once, in the sessions' transcripts (by the
  [session search](#searching-sessions)) or the commands, when what it
  was given does not say enough. `[Search]` in the header does the same,
  and `C-c h /` on a board is this search; from anywhere else it opens
  the [quick search](#quick-search).
- The header line shows what the board's tasks cost or, when a
  subscription pays, the plan with its 5-hour and weekly quota, as a
  chat's header does, then the fullest budget of the project. Click it
  to open the usage dashboard. A narrow window keeps it after most
  buttons are gone. The header does not count the tasks: each column's
  heading counts its own.
- `RET` opens the session of the task at point. From that session,
  `C-c h a` leads back to the board. `F` lays the board out fullscreen,
  with that session beside it (see
  [Fullscreen overviews](#fullscreen-overviews)).
- Typing on the board goes to the compose box, like in a chat: any
  letter that is not one of the board's keys, and a key for the task at
  point (`s`, `e`, `m`, `v`, ...) typed off a card, which has no task to
  act on.
- A cheap model titles a task like a ticket as soon as you submit it,
  from its prompt, so the board and `task_list` show that title, not the
  raw prompt, even while the task waits for a slot; the card's second
  line then shows the prompt. A refined or planned task is titled from
  what you wrote, the same way. When the task starts, its session takes the
  title rather than being named again, and shows in the session list
  (`C-c h l`) under it, of kind task. Nothing waits for the title: a
  task whose naming fails starts all the same, and its session is named
  from its first message; one still waiting for a slot stays untitled
  until it starts. At most two titles are asked for at once, and when
  more wait (a burst of new tasks, or a board of untitled ones found at
  start-up), the highest priority task's goes first, the oldest first
  among equals.

Press `?` on the board, or `C-c h ?` in its compose box, to see all of
the board's commands.

### Commit messages without Claude attribution

Agents commit in the repositories the harness works in, and Claude Code
writes lines into their messages that credit Claude: `Co-Authored-By:
Claude <noreply@anthropic.com>`, `Generated with [Claude
Code](https://claude.com/claude-code)`. The harness can take those
lines out as each commit is made. Its `commit-msg` module installs a
`commit-msg` hook in the repository that drops them and keeps every
other byte of the message. The hook belongs to the repository, so it
acts on every commit made there, in the main checkout and in every
worktree, yours included.

It is off unless you turn it on, for one project at a time:

- On the settings page (`C-c h S`), opened from a buffer of the
  project, switch to the **Project** scope and turn on *Strip Claude
  attribution* under **Commits**. It takes effect at once.
- Or write it in the project's `.dir-locals.el`:

  ```elisp
  ((nil . ((harness-commit-msg-strip-attribution . t))))
  ```

  A `.dir-locals.el` edited by hand takes effect at the next start or
  reload of the harness (`M-x harness-reload`), or as soon as a worktree
  or a session is made in the project.

The global value of `harness-commit-msg-strip-attribution` (the
settings page's **Global** scope, or `(setopt
harness-commit-msg-strip-attribution t)`) turns it on in every
repository the harness works in. Turning it on project by project is
the better habit.

To turn it off, turn the setting off where you turned it on: the
harness then removes the hook it installed (at once from the settings
page, at the next start or reload after a hand edit).
`M-x harness-commit-msg-uninstall` takes the hook out of a repository
right away. If the setting is still on for that repository, the hook
comes back, and the command says so. The harness never touches a
`commit-msg` hook somebody else wrote, nor a `core.hooksPath` that
points elsewhere.

It is off by default because a tool that many repositories share must
not rewrite commit messages unasked. Your workflow, or a colleague's,
may depend on the trailer of a co-signing agent, which the hook would
drop silently.

### Fullscreen overviews

The task board, the session list and a main session can take the whole
frame: press `F` on one of them, or `C-c h F` from anywhere. The anchor
stays on one side of the frame — the left by default, the right with
`harness-ui-fullscreen-side` — and the session you inspect shows beside
it: the one already in sight, else the task or session at point, else
the anchor's most recent child for a session, else the most recent one.
Every session you open while the layout lasts takes the slot beside the
anchor, however you open it — `RET` or a click on the board or the
session list, `C-c h s`, a notification — and so does anything else the
harness shows without a position. A main session is no exception: it
takes the anchor side only when you press `F` on it, so the board or
list you opened it from stays in sight.

- A main session is one with no parent session: the root of its forks,
  sub-agents and BTW conversations. Put one in the layout and its most
  recently updated child shows beside it, so a parent stays in sight
  while you read the work it started.
- `C-c C-z` in the session beside the anchor buries it: the buffer that
  was there before comes back, such as the file the session took the
  place of, and the layout stays, so the next session you open takes the
  slot again. It is a key chord because plain keys in a session type
  into its compose box.
- `q` on a harness view — the board, the session list, the settings
  page, usage, insights, the worktrees, the version page, the tree, the
  directories, the log, the pet — buries it the same way, bringing back
  what its window showed and keeping the layout. In a chat, board or
  popout compose box `q` still types into the box. On the anchor itself
  `q` (or `F` again) ends the layout, and the windows come back as they
  were. A file you visited in the slot stays in sight.
- Opening the other overview while the layout is on (`C-c h l` beside
  the board, say) puts it on the anchor side instead. The session list
  the mode line or a notification opens for the sessions waiting for you
  is not an overview taking over: it shows beside the anchor, so the
  board stays put.
- The layout keeps its shape: a session shown in the `left` or `right`
  position inside a layout takes the slot beside the anchor rather than
  growing a second, skinny column, and a magit or transient popup is
  never mistaken for the slot. `harness-ui-fullscreen-width` sets the
  width of the anchor: a fraction of the frame (half, by default) or a
  number of columns, clamped so the slot keeps a usable width.
- The layout follows its anchor's window. When something takes that
  window away — you close it, or a project switch brings the project's
  own windows back — the layout is dropped and the buffers it showed
  get back the positions they had before it, rather than staying marked
  fullscreen with no layout to show in.
- A window prefix sends what you open elsewhere and leaves the layout as
  it is: `C-x 4 4 RET` on a task shows its session in another window,
  `C-x 5 5` in a new frame, `C-x t t` in a new tab. `C-x 5 5 C-c h F`
  (or `C-x t t`) starts the layout in a new frame (or tab) instead of
  this one. A view opens in the frame you run its command in, so click
  a frame and press `C-c h a` to open the board there.
- `fullscreen` is a position too, so `C-u C-c h a` and then `fullscreen`
  opens the board in the layout.

### Remote hosts

Agents work on other machines through TRAMP, as you do in Emacs:

- A session started in a TRAMP directory works on that host: press
  `C-c h n` and choose a directory such as `/ssh:box:/srv/app/`. Every
  tool of the session runs there.
- Any session reaches a host with the `ssh` tool (the `tools-ssh`
  module, `:tools ssh`), which runs a shell command there. The host is an alias from `~/.ssh/config`,
  `user@host:port`, or a TRAMP prefix such as `/ssh:user@host#2222:`
  (`/ssh:jump|ssh:host:` through a jump host). The other tools take
  TRAMP paths as well: `read_file`, `write_file`, `edit_file`,
  `list_dir`, `glob`, `grep` and `file_info` work on
  `/ssh:box:/etc/hosts` as on a local file, and `bash` runs on the host
  given a directory there.

The harness connects without a terminal, so nothing can answer a
password, passphrase or host key prompt: the host must accept a key
from ssh-agent (or one without a passphrase) and be in
`~/.ssh/known_hosts`. `ssh -o BatchMode=yes HOST true` in a terminal
shows whether it is. When a connection fails, the agent is told why,
in ssh's own words, and how the host is set up.

A host is a directory outside the session's like any other. The first
call that reaches it asks for access: to `/ssh:box:/srv/app/` when the
call runs there, to the host's root `/ssh:box:/` when it runs in the
home directory. Granting the root lets the session work anywhere on the
host, with every tool. A non-interactive session, such as a task's,
needs the host in `harness-allowed-directories` beforehand. An `ssh`
call is a command, so the permission mode decides it as it decides a
`bash` command. Commands on another host run outside the sandbox, which
confines this machine.

The harness process reaches hosts through a TRAMP of its own, and the
TRAMP settings you made, such as `tramp-default-method`,
`tramp-remote-path` and `tramp-default-proxies-alist`, are copied into
it.

### Notifications

Notifications are the `notifications` module; `tasks-notify` sends the
task board's, and `tools-notify` gives agents the `notify` tool:

```elisp
(harness-enable-modules
 :features notifications tasks-notify
 :tools notify)
```

The harness tells you when a task's work waits for your review and
when a task is done, so you can leave it working:

- A desktop notification, shown by your Emacs. Clicking it opens the
  task board on that task. It uses `notify-send` on GNU/Linux (or
  Emacs's D-Bus support) and `terminal-notifier` on macOS (see below);
  set `harness-notifications-desktop-backend` to choose.
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

On macOS, a click opens what the notification is about when two things
are in place:

- [terminal-notifier](https://github.com/julienXX/terminal-notifier):
  `brew install terminal-notifier`. The first notification asks whether
  terminal-notifier may show notifications; allow it (System Settings >
  Notifications > terminal-notifier).
- The Emacs server, which the click reaches through `emacsclient`:
  `(server-start)` in your init file, or `M-x server-start`. Doom Emacs
  starts it already.

A click then brings Emacs to the front and opens the session, or the
task board on the task. A notification clicked after Emacs restarted,
from the Notification Center, lists the sessions waiting for you, as
clicking the mode line's notifier does. Without the server a click only
brings Emacs to the front; Emacs says so once, in the echo area and in
the log (`M-x harness-show-log`).

Without terminal-notifier, a graphical Emacs shows the notification as
its own, through AppleScript: a click brings Emacs to the front, but
cannot tell which notification it was. Only a terminal Emacs falls back
to `osascript`, whose notifications macOS gives to Script Editor, so a
click opens Script Editor. A click brings forward the Emacs
application, or for Emacs in a terminal, the terminal. Set
`harness-notifications-desktop-macos-app` to a bundle id
(`"org.gnu.Emacs"`, `"com.googlecode.iterm2"`) when that finds the
wrong one.

### Insights

Insights are the `insights` module (`:features insights`).

`C-c h A` (`M-x harness-insights`) opens the Insights report in a
buffer of its own, `*harness insights*`. It shows how a period of your
work with the agents went, like Claude Code's `/insights`. The report is
built from the harness's own records: the transcripts, the usage log,
the task board and a log of permission decisions. So it reads the same
for Claude, Copilot, OpenAI-compatible APIs, DeepSeek, Bedrock and ACP
agents. From the top:

- **Totals**: the sessions that worked, the messages you wrote, active
  time (pauses over ten minutes left out), cost, tool calls and tasks
  done.
- **Summary**: a few paragraphs a model writes from the figures: what
  you worked on, how you work, where things went wrong and what to try.
- **Activity**: your messages by hour of day and by weekday, the days
  you worked and your streaks.
- **Usage**: the usage dashboard's cost chart, then cost by model and by
  provider. These are the dashboard's figures for the same period.
- **Projects**, **Sessions** (by kind, and the busiest), **Tools**
  (calls, failure and denial rates, time), **Permissions** (how often
  you were asked, and what you answered) and **Tasks** (done, merged,
  accepted the first time, sent back, failed, merge conflicts, and the
  tasks worth a look).

| Key | Action |
|---|---|
| `t` | Cycle the period: today, 7 days, 30 days, all |
| `p` | Narrow the report to one project and its git worktrees, or widen it to every project |
| `RET` | On a session or task line, open its session |
| `n` | Write the summary again |
| `g` | Compute the report again |

The report opens on 30 days of every project
(`harness-ui-insights-default-period`,
`harness-ui-insights-default-scope`). It lives in its buffer only; there
is no export. The harness process computes the figures, with a child
Emacs reading the transcripts. Until they arrive, the buffer shows a
placeholder, so your Emacs never waits.

By default a cheap model of your provider writes the summary: the simple
tier of `harness-model`, or set `harness-insights-model`. Its input is
the figures and each session's name and first request, never code or
tool output. The call is recorded as an internal session (see
[Session list](#session-list)), and the report leaves internal sessions
out of the sessions it counts and lists. A summary is kept for a day for
the same period and project (`harness-insights-narrative-max-age`). Set
`harness-insights-narrative` to `manual` to write one only when you
press `n`, or to nil for none at all. When no model can be reached, for
example offline, the report shows without a summary.

A transcript says when a call was denied, but not when you were asked.
So the harness also logs every permission decision, to
`insights/permissions-YYYY-MM.jsonl` under the state directory, and
keeps two years of it. The Permissions section starts from the day you
first ran a harness with Insights. Set
`harness-insights-record-permissions` to nil to stop the log.

### Companion pet

The pet is the `pet` module (`:features pet`).

`C-c h z` (`M-x harness-pet`) opens the pet's buffer. The first time
there is an egg: press `h` to hatch it. It hatches into one of 18
species, from common to legendary (one in a hundred), sometimes with a
hat and, rarely, shiny, with five stats. The cheapest model of your
provider names it and gives it a personality. Each species is drawn in
a few lines of text, and is also built as a small low-poly 3D model, its
hat included, which it turns around as a rare treat (below).

Once it hatched, it keeps you company in other places too:

- **Chats.** The whole creature sits in the bottom right corner, on top
  of whatever comes first below the transcript: the activity line while
  the agent works ("Thinking…"), a request waiting for you, the queue or
  the todo list. When none of those shows, it sits on the compose box,
  as Claude Code's companion sits beside its prompt. It is drawn in its
  rarity's colour, with its name beside its eyes, and takes only as many
  lines as it is tall. What it last said about the session shows in a
  speech bubble on its left, joined to it, for a minute, or until the
  session's next turn starts. The bubble widens rather than grow taller
  than the creature.
  Hovering names the pet, and a click opens its buffer. Side
  conversations (BTW) go without it.
- **The task board.** It sits in the board's bottom right corner in the
  same way. Its bubble there recaps the board's tasks, or says what it
  last said about itself, never what it said about a task's work: that
  stays in the task's chat. The compose label and settings lines narrow
  to make room for its bottom rows, so it adds only a few lines of its
  own. Each task that gets done gives it experience.
- **The session list.** It stands under the last row, after a blank
  line, at the right, its bubble recapping the sessions on the list as
  on the board. It is no session's: `RET` and the row commands find
  nothing there.
- **Small windows.** A window narrower than 40 columns or shorter than
  20 lines shows its face on one line instead, as in `(·>`. The face
  comes with its name or the first few of its words, and only blinks:
  there is no more of it to move. Set `harness-ui-pet-figure` to `face`
  to get that everywhere.
- **Header lines, if you want them.** Its face on one line, as in `(·>`,
  can end each chat's header line (`chat-header`), where it blinks now
  and then while the session works. Its face and name can also show in
  the board's header line (`board-header`). Either is the first thing to
  go when the window is narrow.

`harness-ui-pet-places` chooses among these places: `chat`, `board` and
`sessions` by default, `chat-header` and `board-header` too if you add
them. nil keeps the pet to its own buffer. `harness-ui-pet-figure`
chooses how it shows in the chats, on the board and under the session
list: `whole` (the default) or `face`.

While you are at your Emacs (one of its frames has focus) and it is on
screen, it now and then says a line, and each line shows only where it
belongs:

- **In a chat**, about that chat's session: the message you just sent,
  a test run that failed or a big change. It also tells you, as its own
  news, when the harness renames the session or compacts its
  conversation, the latter with a joke about forgetting (the Men in
  Black neuralyzer and the like). Those it says even while it would
  otherwise keep quiet.
- **On the task board and the session list**, recaps of the sessions
  they list. On the board these are the recaps the task cards already
  get. A session on the list that is no task's is recapped when a turn
  of it ends while its own chat is not on screen.
- **In its buffer and wherever its figure shows**, what it says about
  itself: when you pet it, its first words, a level it grew.

It always answers when you call it by name in a message or pet it
(`p`). Its voice is dry: a colleague at the next desk who notices
things, never cutesy. It may start a line with a small gesture, as in
*squints at the diff*; set `harness-pet-actions` to nil to keep it to
words. A line leaves its bubble after a minute
(`harness-ui-pet-saying-lifetime`; nil keeps it until the next one),
and its buffer keeps the last few. It grows a level as you work. `r`
renames it, `m` mutes it, `s` spins it and `R` lets it go, after which
the next egg hatches another.

It moves, too. Every 6 to 14 seconds the pet in a chat, on the board or
under the session list blinks, blinks twice or wiggles, and it fidgets
for a moment as it says something. Each of these is a few frames that
stop on their own. Rarely, about once in eight minutes while it is on
screen, it turns once around instead: for two seconds its drawing gives
way to a low-poly 3D model of it, flat-shaded like a toy and wearing its
hat, which the harness draws as it goes. That needs a graphical Emacs
frame that can show SVG images: in a terminal the pet only blinks,
wiggles and fidgets, and a figure that is just a face never turns. `s`
in the pet's buffer spins it whenever you like, twice there and once in
its figures on screen elsewhere; where it cannot, the echo area says
why. Nothing moves while the pet is off screen, and
`harness-ui-pet-animations` set to nil keeps it still.

It costs little. It never asks a model anything about what is not on
screen, nor while no frame of your Emacs has focus, nor while it is
muted. It comments unasked at most once a minute
(`harness-pet-cooldown`), recaps included, and on your messages only by
chance (`harness-pet-chance`). It then asks a cheap model
(`harness-pet-model`) for one short line, with no thinking and no
context from your project beyond the last few messages, or the recap.
Nothing runs while nothing happens: the
creature in a chat, on the board or under the list is drawn again only
when it changes, says something else, or has more or less room, and
never to make it move. A frame changes how a few of the buffer's lines
are displayed, without editing its text, so typing and scrolling stay as
quick. That is a frame every 0.18 seconds while one of its moves plays,
or every 0.09 seconds for a turn, a couple of seconds at most, and a
move comes every 6 to 14 seconds. The 24 pictures of a turn are drawn
the first time it plays, a few milliseconds each, and kept. Once no pet
is on screen, or animations are off, its timers go.

Want a particular pet? `harness-pet-overrides` sets any of its
attributes by hand, over what it hatched with: its name and
personality, species, rarity, eyes, hat, whether it is shiny, and each
of its five stats. For instance

```elisp
(setq harness-pet-overrides
      '(:name "Pickles" :species dragon :rarity legendary :shiny t :snark 100))
```

What you leave out stays as it hatched. A rarity set here reshapes the
rest: a legendary pet gets a hat and stats from the legendary floor, a
common one loses its hat. The pet changes everywhere as soon as the
option does, and its voice follows: the model is told what it is now.
Set before the egg hatches, it shapes the name and personality the
model gives it. The settings page offers it as a form with one line per
attribute, and the pet's buffer says which are set by hand. While the
name is set here, `r` cannot rename the pet. Its level and experience
are what it grew, not attributes: nothing here changes them.

To keep it quiet, set `harness-pet-reactions` to nil. To turn it off
altogether, press `O` in its buffer, click [Turn off] there, or set
`harness-pet-enabled` to nil (also on the settings page). It then shows
nowhere else, grows no more and asks no model anything. Its buffer only
says it is asleep and offers to turn it on again, as it was. To remove
the code itself, leave `pet` out of `harness-enable-modules`, or, when
every module loads, add it to `harness-disabled-modules`, which takes
`ui-pet` with it.

## Configuration

`C-c h S` (`M-x harness-settings`) opens the settings page, which edits
every harness setting like a Customize buffer. A toggle at the top
switches between the global value, saved with Customize, and the value
for the current project, saved in its `.dir-locals.el`. Each setting
shows where its effective value comes from.

The page leads with the settings most people change, grouped by what
they are for: **New sessions** (model, thinking, permission mode,
non-interactive, supervisor mode), **Supervisor mode** (whether
sessions and tasks supervise or a cheap model judges them, the judge's
model, the models of a plan's tiers, the step budget, the fork limit),
**Model tiers**
(each provider's simple, medium, hard and frontier models and the
thinking levels they run at, see [Model tiers](#model-tiers)),
**Spending** (the
budget, one for all sessions together), **Compaction** (what stands in
for a conversation that grew too long, and which model writes a brief
summary), **Files and safety** (directory access,
sandbox policy, standing permission rules), **Task board** (what task
sessions start with, and when their work counts as done), **Commits**
(whether commits lose the lines crediting Claude, see [Commit messages
without Claude attribution](#commit-messages-without-claude-attribution)),
**Notifications** (which task events notify you, and through which
providers) and **Models and services** (extra providers, web search,
keys).

Everything else is under **Advanced**, one click away (`a`), listed by
module, with a count of how many differ from their defaults. The
options of the interface itself (where windows open, the prefix key,
labels, faces) are in Customize, through the button at the end of the
page.

The following settings can be set per project and per directory through
`.dir-locals.el`. A directory's value takes precedence over its
project's, and a project's over the global value.

- `harness-model`
- `harness-thinking`
- `harness-btw-thinking`
- `harness-btw-model`
- `harness-permission-mode`
- `harness-allowed-directories`
- `harness-sandbox-policy`
- `harness-non-interactive`
- `harness-supervisor`
- `harness-commit-msg-strip-attribution`

The rest of the settings have a global value only.

The number of settings is now small on purpose: prompts, timeouts,
polling intervals, per-tool limits and other details of how the harness
works are constants, not options, so they can change without breaking
anyone's configuration. [docs/configuration-audit.md](docs/configuration-audit.md)
is the audit behind that, and the rule for adding a setting.

Settings that hold records — the OpenAI-compatible and Bedrock
endpoints, Bedrock's per-model defaults, each provider's model tiers,
the standing permission rules — are edited as forms: every key the harness reads is named (Base URL,
Context window, Thinking…), has a value of its own kind, and says what
it is for. Each record in a list folds to one line; `Edit` opens it and
`INS` adds one, filled in from what that kind of record starts as.

Settings that name a model (the default model, the task, refine, recap,
search, auto-mode judge and session judge models, the models of a
plan's tiers, Copilot's default model, and the fallback list) are
dropdowns rather than text fields.
The button names
the model (`Fable 5.1 (Claude) ▾`), next to its id and context window,
and opens a picker of the models the configured providers list, grouped
by provider, with their context window and price. A pick saves at once.
An id no provider lists can still be typed in the picker, and the page
then warns that the harness does not know that model's context window.

## Providers and billing

### Claude

The default provider drives the `claude` command line. How turns are
billed depends on how it is logged in:

- With an API key (or through Bedrock, Vertex or a gateway token), each
  turn shows what it costs.
- With a Claude subscription (Pro, Max or Team), turns cost nothing per
  token. Sessions show the plan and its quota instead, for example `Max`
  with the 5-hour and weekly windows in the chat header, and so does the
  task board for its tasks.

Sessions get your CLAUDE.md files, as `claude` loads them, but not
Claude Code's auto memory, the notes Claude Code keeps on each
repository in `~/.claude/projects/`. Harness sessions cannot use those
notes as Claude Code does: the model would read them from outside the
session's allowed directories, so every session would ask you for
access. To give sessions that memory anyway, turn on
`harness-provider-claude-auto-memory` (Claude Code, under Advanced on
the settings page). Reading a note then asks for its directory: answer
Always allow and no session asks again.

The CLI keeps every conversation in a log under `~/.claude/projects/`
(`$CLAUDE_CONFIG_DIR/projects/` when that is set, or
`harness-provider-claude-projects-directory`) and replays it with
`--resume`. A secret that got into a conversation is in that log too, and
a redaction takes it out of there; see [Secrets and
redaction](#secrets-and-redaction).

### GitHub Copilot

Copilot is the `provider-copilot` module (`:providers copilot`).

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

The CLI keeps what each session said and did under
`~/.copilot/session-state/` (`$COPILOT_HOME/session-state/`, or
`harness-provider-copilot-state-directory`), and resumes the session from
it. A redaction takes a secret out of those files as it does out of
Claude Code's logs (see [Secrets and redaction](#secrets-and-redaction)).

### OpenAI-compatible APIs

With the `provider-openai` module (`:providers openai`), each entry of
`harness-openai-endpoints` registers an OpenAI-compatible API as a
provider, with models named `ID:MODEL`. OpenRouter
(`OPENROUTER_API_KEY`) and OpenAI (`OPENAI_API_KEY`) are configured by
default.

### DeepSeek

DeepSeek is the `provider-deepseek` module (`:providers deepseek`),
which brings `provider-openai` along.

Set `DEEPSEEK_API_KEY` (or `harness-deepseek-api-key`, or an
auth-source entry for `api.deepseek.com`) and `deepseek:` models appear
in the model picker. The provider is created when a key is found and
removed when none is; `harness-deepseek-always-register` keeps it
regardless. Models are `deepseek-flash` (V4.1 Flash, text and images),
`deepseek-v4-pro` and the still-accepted legacy names
`deepseek-v4-flash` and `deepseek-v4-flash-vision-exp`.

DeepSeek prices by the clock: peak hours (01:00-04:00 and 06:00-10:00
UTC, Monday to Friday, except Chinese public holidays) cost double the
off-peak rate. The recorded cost follows the rate in effect and cached
input is billed at the cheaper cache-hit rate. When a call is made in a
peak window, the session is told once, as a hint, and a
`provider/pricing-warning` event fires; nothing is blocked.
`harness-deepseek-pricing` holds the rates, so update it from the
[DeepSeek pricing page](https://api-docs.deepseek.com/quick_start/pricing)
when they change, and extend `harness-deepseek-off-peak-dates` each year
with the Chinese public holiday calendar.

DeepSeek's thinking mode (on by default) requires the reasoning of
earlier assistant turns to come back as `reasoning_content` once a
request carries tools, so the provider replays the recorded thinking of
each assistant message, empty when it has none.  This follows an
official DeepSeek host, so an OpenAI-compatible endpoint you added
yourself at `api.deepseek.com` gets it too, and its cached input is
billed at the cache-hit rate rather than the cache-miss rate; OpenAI
and OpenRouter are unaffected and still drop thinking.  Thinking effort
uses DeepSeek's own three-step ladder — low, high, max — which its
/models route reports, so
the thinking menu offers exactly those levels and never a `medium` or
`xhigh` that DeepSeek would just collapse onto `high`.

### AWS Bedrock

With the `provider-bedrock` module (`:providers bedrock`), `bedrock:`
models run on AWS Bedrock and authenticate with an AWS profile or a
Bedrock API key (`AWS_BEARER_TOKEN_BEDROCK`). See
`harness-bedrock-endpoints` for the configuration.

#### Through a gateway

A gateway or proxy in front of Bedrock gets an endpoint of its own. On
the settings page (`C-c h S`), under **Models and services**, add one
with `INS` to the **Endpoints** described as "AWS Bedrock endpoints"
(the **Endpoints** above it is for OpenAI-compatible APIs). Its **ID**
names its models (`ID:MODEL`). Set **Runtime URL** to the gateway's
URL, path prefix included. For example,
`https://gateway.example.com/bedrock` sends ConverseStream to
`https://gateway.example.com/bedrock/model/MODEL/converse-stream`. A
query in the URL is added to every request.

Models are listed at the same URL (`…/foundation-models` and
`…/inference-profiles`), and never at AWS with the gateway's keys.
If the gateway lists them somewhere else, set **Listing URL**. If it
does not list them at all, set **Models** to name them.

What to set depends on how the gateway authenticates:

| The gateway takes | Set |
|---|---|
| A key of its own as `Authorization: Bearer KEY` | **Authentication** API key, and **API key variable**: the environment variable that holds the key |
| The key in another header, such as `x-api-key` | The same, plus **API key header** `x-api-key` |
| A short-lived token that a command prints | **Authentication** API key, and **API key command** (see below) |
| More headers, such as a team or project id | **Headers**. `${NAME}` in a value is replaced by environment variable `NAME`, so secrets stay out of the settings |
| AWS keys signed for its own URL (API Gateway, a VPC endpoint) | **Authentication** AWS keys, and a **Profile**. For API Gateway, also set **Signing service** to `execute-api` |
| AWS keys signed for Bedrock, because it passes requests on unchanged | **Authentication** AWS keys, and **Sign for Bedrock's own URL** |
| Nothing the harness sends (mutual TLS, a VPN) | **Authentication** None |

The token is the last line the API key command prints; a leading
`Bearer ` is dropped. It is kept until it expires (the `exp` claim of
a JWT), or for an hour otherwise. When the gateway refuses it, the
command runs again and the request is retried once. While a command or
**API key variable** is set, `AWS_BEARER_TOKEN_BEDROCK` is not sent to
the gateway. If the setup is incomplete, the first request names what
is missing.

For example, here is a gateway that takes a key of its own in
`x-api-key` and lists models under its own prefix:

```elisp
(:id gateway :label "Gateway" :auth bearer
 :endpoint-url "https://gateway.example.com/bedrock"
 :bearer-token-env "GATEWAY_API_KEY" :bearer-token-header "x-api-key")
```

And here is one whose token comes from a login command, with its
models named:

```elisp
(:id gateway :label "Gateway" :auth bearer
 :endpoint-url "https://gateway.example.com/bedrock"
 :bearer-token-command "gateway-login --print-token"
 :models ("us.anthropic.claude-sonnet-4-5-20250929-v1:0"))
```

Requests go through curl, so curl's own settings apply:

- `CURL_CA_BUNDLE` for a gateway whose certificate a private CA signs
- `HTTPS_PROXY` and `NO_PROXY` for a proxy
- `~/.curlrc` for anything else, such as `cacert = /path/to/ca.pem`

The harness process takes its environment from Emacs when it starts.
Set the variables before it starts, or restart it after setting them.
Saving the endpoint re-registers its provider and clears what was
cached for it, so a changed URL or model list shows at once.

### Model tiers

Some calls get their model from the harness rather than from you: the
auto-mode judge, a session's title, a brief summary, the plan and the
work of a task in the board's Plan mode (until you pick others), the
workers of a supervisor's plan. The harness picks such a model by tier, from the
provider the session is on. Each provider names a model for each of four
tiers, weakest first:

| Tier | For | Claude | DeepSeek |
|---|---|---|---|
| simple | Small, well-specified work, and the harness's own calls: the judge, titles, summaries | Haiku | Flash, low thinking |
| medium | Everyday work: a planned task's work, the steps of a supervisor's plan | Sonnet | Flash, high thinking |
| hard | The strongest model the harness picks: what a task in Plan mode and a supervisor plan on, and a step retried after its worker was not up to it | Opus | Flash, max thinking |
| frontier | The very top model. Only you pick it; the harness never does | Fable | none |

A tier names a model (a name, id or regexp of the provider's
catalogue), the model at a thinking level, as DeepSeek runs its one
Flash model at three levels, or no model at all. A tier that a provider
leaves out is filled from its models sorted by price. When a provider
has no model for a tier, the harness uses the nearest tier it has
instead: a Fable session that falls back to DeepSeek carries on on
DeepSeek's hard tier. The tiers of each provider are on the settings
page (`C-c h S`) under **Model tiers** (`harness-provider-claude-tiers`,
`harness-deepseek-tiers`, `harness-bedrock-tiers` and
`harness-provider-copilot-tiers`); OpenAI-compatible endpoints take
`:tiers` in their entry. Tiers saved in the names of old, `cheap`,
`balanced` and `frontier`, are read as simple, medium and hard.

### Switching model or provider

`C-c h m` (`harness-set-model`) chooses the model for the current
session, and `C-c h T` its thinking level. `C-c h M`
(`harness-set-model-all`) chooses one model and switches every current
session of every project to it, and every current task (pending, active
or needing input); `C-c h H` (`harness-set-thinking-all`) does the same
for the thinking level. Both make the choice the default for new
sessions too, and the setting of the next task on every open task
board, unless a prefix argument (`C-u C-c h M`) says otherwise. Only
idle, running and blocked sessions change — deactivated ones are history
and are left alone, unless a current task goes on in one — no running
turn is cancelled (it takes the new model at its next step), and each
session records the change once, as a hint. A session whose task is
completed (in the board's `done` column) is over and is left alone too,
even while it is still running, idle or blocked; so are the records of
completed tasks, which `task/set-all` never touches. When the default
changes,
they then say what still wins over it: a project whose `.dir-locals.el`
sets `harness-model` (or `harness-thinking`), at the project or the
directory layer, and `harness-tasks-model` (or `harness-tasks-thinking`)
for tasks. They never rewrite a `.dir-locals.el`: change it yourself,
or in the settings page (`C-c h S`) switched to the project's values.
Use them when a plan runs out of credit, a provider fails, or a cheaper
model should take over work already in flight.

Claude Code and Copilot keep the conversation themselves and are sent
only your newest message, so switching a session to one of them from
another provider would start a conversation that knows nothing of the
work so far. With the `handoff` module (`:features handoff`), which
brings its banner, `ui-handoff`, such a switch asks first — once for
all of them with `C-c h M` — and lists the risks: a cold prompt cache (with what the
session's context costs to write), lower fidelity (the model explores
again; tool calls and thinking reach it only as text), the old
provider's own state left behind, and that a running turn finishes its
current step first. The question shows as a banner over the session's
message box — the models, the risks and the costs, then one button and
key per way to hand over — and as a minibuffer question when the session
has no chat buffer open. Then choose:

- **`c` current model summarises**: it summarises the conversation,
  whose cache is warm, and the new one starts from that summary;
- **`n` new model summarises** (advanced): the new model writes the
  summary itself, from the conversation's narrative — every user and
  assistant message, each tool call and result in a line — so the whole
  conversation's payloads never run through it. Use this when the
  current provider cannot answer at all — its plan ran out, it is down —
  or to keep the job cheap. What tools read and wrote is left out, so
  the summary is a lossy one;
- **`t` full transcript**: the whole transcript is written to
  `.harness/handoff/` in the session's directory (git ignores it), and
  the new model is told to read it before it answers; its prompt cache
  holds it as it reads;
- **`s` no handoff**, or **`q` cancel**.

If the summariser fails, the transcript goes over instead. Whichever
handoff you choose, the message that opens the new conversation says the
context may be lossy and tells the model to re-investigate anything it
is unsure of — read the files, check the state — before it acts.

A switch to an API provider (which is sent the whole conversation), to
another model of the same provider, or back to a provider before any
other ran a step in the session (it resumes its own conversation) loses
nothing and does not ask.

The session list has the same thing scoped to the sessions you choose:
mark them (`m`, see [Session list](#session-list)) and `C-c h m`,
`C-c h T`, `C-c h p`, `C-c h i` and `C-c h V` change the model,
thinking level, permission mode, non-interactive mode and supervisor
mode of every marked session at once, as they do in a session's chat.
Without a mark they change the session at point. A marked session
that works on a task passes the setting on to its task, which keeps it
for its next start; tasks in review, done or archived are history and
are left alone. A model switch that would lose conversations asks once,
for all the marked sessions, how to hand them over, with the choices
above. Each command changes only its own setting, so the priorities
stay as they were unless you press `p` (or `+` and `-`), and the marks
stay, so more settings can be given to the same sessions.

### Session settings, from an agent

`session_settings` reads and changes what a session runs with: its
model, thinking level, context window limit and budget. It works on the
calling session by default and on another one by id, a unique id prefix
or a name. `action=read` shows the model, the thinking, the context
window and the limit that caps it — with what set the limit: the
sub-agent cap (`harness-subagent-context-limit`), the task cap
(`harness-tasks-context-limit`), or a limit set for the session — the
budget, and the permission mode and non-interactive state. It cannot
change those last two, nor allowed directories, the working directory or
the host: a call naming one of them is refused, and the refusal names
the tool that has it (`set_non_interactive`, `request_directory_access`
or `session_move`).

`action=set` changes the model, the thinking level (`default` for the
model's own), the context window limit (a token count such as `200000`
or `200k`, or `model` for the model's own window) and the session's own
budget (in US dollars, with `budget_hard` for one that stops the
session's next turn once it is spent, or `none` to remove it). Every
change goes through the same `session/update` the UI uses, so the chat,
the header line and remote clients refresh, and it leaves a hint in the
affected session's transcript naming who made it, the setting, the old
value and the new one — `Context window limit 128k → 200k, set by
session «planner»`, or "set by the session itself" for its own — and,
for a running session, that it takes effect from its next request. A
change to another session shows in the caller's result too. A setting
your administrator's policy fixes is refused before anything changes
(see [Policy](#policy)).

The permission chain decides every call. A read changes nothing, so it
is a read: ask mode allows it, as it allows reading a transcript. A set
changes harness state, so in ask mode the harness asks you about it, or
lets a standing rule decide; in auto mode, and in a session with nobody
there, the auto-mode judge weighs it; yolo allows it. Raising its own
budget or model is no special case — the same chain decides it, and the
budget is money, not a permission.

### Usage and budgets

The usage dashboard (`C-c h u`) lists every quota window with its reset
time, the plan's extra usage, and the value at API prices that the plan
covered.  With the `fallback` module (`:features fallback`), its
Fallback section sets `harness-fallback-models`, the order
of use when a provider runs out of quota or money, first entry first:
each entry a provider id (that provider's model of the same
[tier](#model-tiers), or of the nearest tier it has, shown with the
thinking level the tier names: `simple→DeepSeek-V4.1-Flash low`) or one
model id.  A session keeps the model it was given -- the default, one
picked with `C-c h m`, a task's -- while that works; once it runs out,
the session carries on with the first entry that has not, moves back
up the list as entries come back, and returns to its own model as soon
as its quota does.  To prefer Claude, put the default model on Claude
and list what comes after it.  There `f` adds an entry, `c` forgets
that one ran out so it is tried again, `M-<up>` and `M-<down>` move the
entry at point, and `d` removes it.

`C` (or the header's `[compare]`, `M-x harness-cost-compare`) answers
"how much would this have cost using a different provider?": it
re-prices the tokens the dashboard recorded at every priced model of
the catalogue and lists them cheapest first, each with how much more or
less it is than those tokens at API prices — the value the comparison
is about, since a plan-covered call was billed nothing.  `g` refreshes
it, `t` changes the period, and a prefix argument asks which period, or
which session (`C-u C-u`).  Nothing is recorded or changed: the
recorded cost, the rows and the budgets stay as they are.

Grouped by project, every task's git worktree is folded under the
project it belongs to: one line per project, with the total and how many
worktrees it holds. `TAB`, `RET` or a click on a project shows its main
checkout's usage and each worktree's, and hides them again; `w` (or
`[show worktrees]`) does it for every project at once.

Budgets count billed cost only. A budget over everything (a day, week
or month budget for no one project) also counts what providers report
they billed in its period beyond what the harness recorded, so one
created partway through a month does not start at $0: a plan's extra
usage this month (Claude Code's usage credits, Copilot's additional
requests) and, with an Anthropic Admin API key
(`harness-anthropic-admin-api-key`), what Anthropic billed per token,
fetched again every ten minutes (`I` fetches it now). The budget's line
says how much, as "incl. $5.00 reported by Claude Code". What was spent
outside the harness that no provider reports, such as a project
budget's spending, which no provider can single out, is a baseline:
press `s` on the budget's line in the dashboard (or use the add-budget
wizard) to set it; it counts until the period rolls over.

To delete a budget, click `[delete]` beside its name in the dashboard or
press `d` on its line; from anywhere, `C-c h B` (Delete budget in the
harness menu) asks for it by name. A session's own budget (a `session`
line) is deleted from that session alone. The budget for all sessions
together, the `all sessions (setting)` line, is the Budget setting
(`harness-budget`, under Spending in the settings) and is removed
there: choose No budget.

## Corporate mode

Corporate mode turns off the harness features that could carry data off
your machine, except web search. It is meant for work machines whose
policy lets code and data go to the model provider in use, and search
queries to a search engine, and nowhere else.

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
- Network tools other than web search. Sessions do not get
  `web_fetch`, which reaches any URL. When a model calls it anyway, the
  call is denied and the model is told why.
- The `ssh` tool, which runs commands on other machines. Sessions do
  not get it, and a call to it is denied.
- Embedding session text on another machine. Searching sessions by
  meaning embeds their text only with a server on this machine (see
  [Searching sessions](#searching-sessions)); the full-text index never
  leaves it.

It leaves alone:

- The model provider. The provider you choose still receives what
  sessions send it.
- Web search. `web_search` sends its queries to the search provider
  (`harness-websearch-provider`, Brave by default), and Claude Code and
  Copilot run their own web search on their side (see
  `harness-websearch-builtin`). Both are `web_search` calls, which the
  permission rules decide as usual: if your policy rules out web search
  too, add `(:tool "web_search" :behavior deny)` to
  `harness-perms-rules`.
- Remote hosts through TRAMP. A session started in a TRAMP directory
  works on its host, and a tool given a TRAMP path reaches another host
  once you grant access to it (see [Remote hosts](#remote-hosts)).
- Shell commands, and the `elisp` tool's background Emacs. They follow
  the permission mode and the sandbox, as always, so a command can
  still reach the network. Use a permission mode that asks before
  commands run (Ask or Accept edits), and set `harness-sandbox-policy`
  to `required` so that no command runs outside the sandbox.

The settings page does not list the option, and no ACP client can
change it. If you change it later with `setopt` or Customize, the
harness process restarts so that the change reaches it. An
administrator can force it on with a policy (below).

## Policy

An administrator can fix settings so that the user cannot change them,
as Claude Code's managed settings do. The policy is a file only root
can write, `/etc/harness/policy.el` on Linux and macOS, holding one
alist of options and values. It is read as data and never evaluated:

```elisp
;; /etc/harness/policy.el
((harness-corporate-mode . t)
 (harness-disabled-modules . nil)
 (harness-permission-mode . ask)
 (harness-sandbox-policy . required)
 (harness-allowed-models . ("claude:*")))
```

Each setting is then unset (its default), set by you or your project,
or set by policy. A policy value wins over the others, and nothing
changes it: not the settings page, `setopt`, Customize, `setq`,
`.dir-locals.el`, an ACP client or an agent. The settings page shows
such settings locked, and says where the policy is.

Sessions keep the model, permission mode and thinking level a policy
fixes. A policy on the permission rules or the allowed directories
removes the "Always" answers from prompts. `harness-allowed-models`,
which anyone can set, keeps the harness to some models and refuses
requests for others.

A policy file that cannot be read, or that does not hold a valid
policy, stops the harness from starting rather than being ignored. The
file is read again by `harness-reload`. [docs/policy.md](docs/policy.md)
has the whole design: why that path, what each setting means under a
policy, and what a policy does not protect against.

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
- `secret-sources.json` holds the sources added with
  `harness-secrets-add-source`: where each secret can be read, never the
  value. `redactions.jsonl` has a line for each redaction that was run:
  when, who asked, why, the secrets by label and fingerprint, what was
  found where, and what the check afterwards found; no value, and no
  snippet of text (see [Secrets and redaction](#secrets-and-redaction)).

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

## Remote control

The harness process serves the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP) on
`127.0.0.1`, on an ephemeral port, with a new token each time it
starts. The address and the token are written to `acp-address` and
`acp-token` in the state directory. Set `harness-acp-token` to choose
the token yourself.

- From another Emacs, `M-x harness-connect-remote` (`C-c h c`) with a
  `host:port` address connects the UI to that harness. An empty address
  connects it back to the local harness. Switching leaves running
  sessions alone. Turns go on, and a permission prompt or question
  already on screen can still be answered after you come back.
- `scripts/harness-acp-stdio` bridges ACP to standard input and output,
  for editors that start ACP agents as subprocesses.

### Pairing a phone

Pairing is the `acp-remote` module, which brings its page,
`ui-acp-remote`: `(harness-enable-modules :features acp-remote)`.

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

Once it is let in, the phone's ACP client can list the harness's
sessions with ACP's `session/list`: newest first, a page at a time, for
one directory when the client asks, each with its title, its directory
and when it last changed, the closed ones included. It then opens one
with `session/load` and carries on in it. The harness announces the
method in its answer to `initialize` (`sessionCapabilities.list`),
which is where clients look before they call it. A phone is offered what
a client in Emacs is: the harness's own methods, which go beyond ACP's,
are under `_harness/` (`_harness/session/list` takes the harness's own
filters), and a client that asks for one by its plain name is told where
it is.

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
ACP, so it works the same with a local or a remote harness. The core
modules load always, the others when enabled ([Choosing
modules](#choosing-modules)); a module's UI half, `ui-NAME`, loads
with it.

| Area | Core | Enabled by you |
|---|---|---|
| Sessions | `config` `project` `store` `session` `agent` `compaction` `retry` `priority` `usage` `naming` | `cowboy` `handoff` `fallback` `seed` `supervisor` `insights` `pet` `version` `decisions` `session-search` `cost-compare` `commit-msg` |
| Tasks and git | `worktree` | `tasks` `tasks-notify` `tasks-search` `recap` `merge` |
| Safety | `perms` `sandbox` | `tool-slots` `tool-slots-load` `readonly` `secrets` `redact` `judge` |
| Providers | `provider` `provider-claude` | `provider-copilot` `provider-openai` `provider-deepseek` `provider-bedrock` `provider-demo` |
| Tools | `tools` `tools-fs` `tools-shell` `tools-emacs` `tools-question` `tools-plan` `tools-todo` `tools-session-info` `tools-agent` | `tools-ssh` `tools-web` `tools-sessions` `tools-notify` `tools-handin` `tools-emacs-eval` `tools-dev` `tools-events` `tools-compact` `skills` |
| Connections | `acp` | `acp-remote` `notifications` |
| User interface | `ui` `ui-chat` `ui-compose` `ui-pending` `ui-sessions` `ui-notify` `ui-config` `ui-usage` `ui-priority` `ui-worktree` | `ui-btw` `ui-tree` `ui-compact` `ui-cache` `ui-review` `ui-report` `ui-patch-review` `ui-popout` `ui-media` `ui-dirs` `ui-qr` `ui-acp-remote` `ui-handoff` |

[docs/modules](docs/modules/README.md) has a page for each module,
generated from its source by `scripts/module-docs.sh`: what it is, what
it requires and brings along, and the methods, tools, events, filter
chains and hooks it provides and uses. `M-x harness-describe-module`
shows one in Emacs. [docs/module-audit.md](docs/module-audit.md) is an
audit of the modules and their API made with them.
Beside the modules, `lisp/vendor` holds libraries the harness ships that
need nothing of it, and may be used without it: `compose-quote`, which
the compose box quotes with, is the first. See
[lisp/vendor/README.md](lisp/vendor/README.md).

### Modules of your own

Your own modules load beside the harness's, from the directories you
list in `harness-extra-module-directories`. Each directory is absolute
or relative to `user-emacs-directory`:

```elisp
(setq harness-extra-module-directories '("harness-modules"))
```

As in the harness's own tree, each file named `harness-NAME.el` there
is a module called `NAME`. Like the harness's optional modules, it
loads once enabled, with `harness-enable-modules` (or with
`harness-enabled-modules` t, which loads every module), and
`harness-disabled-modules` leaves it out. Other files are not modules,
but a module can `require` them: the directories are on `load-path`.

The name also decides where a module runs:

- `ui` and `ui-NAME` (in `harness-ui-NAME.el`) are UI modules and
  load in your Emacs.
- Any other module loads in the harness process, or in your Emacs too
  when `harness-process` is off.

A module whose name the harness already has is left out, with a
warning in the log (`C-c h L`).

Your modules are handled like the harness's own:

- The harness compiles them, and `harness-reload` (`C-c h R`) and
  `harness-update` reload them.
- `harness-auto-reload-mode` watches their directories.
- `M-x harness-describe-modules` lists the modules of your Emacs and of
  the harness process, with the file of each of yours.
- `M-x harness-describe-module` shows a page for each, read from its
  source: its `:doc`, the Commentary of its file, and what it provides
  and uses ([docs/architecture.md](docs/architecture.md#pages-of-the-modules)
  says what the pages read).
- The options of a module in the harness process show on the settings
  page, under Advanced, by module.

The harness process reads the list of directories when it starts, so
run `M-x harness-restart` after changing it.

A minimal pair: a method in the harness process, and a command in
your Emacs that calls it.

```elisp
;;; harness-modules/harness-hello.el  -*- lexical-binding: t; -*-
(require 'harness-core)

(defcustom harness-hello-greeting "Hello"
  "How `hello/greet' greets."
  :type 'string :group 'harness)

(harness-defmethod hello/greet (name)
  "Greet NAME."
  (format "%s, %s!" harness-hello-greeting name))

;; Clients, your Emacs among them, may call it as `_harness/hello/greet'.
(defvar harness-acp-extra-method-prefixes)
(with-eval-after-load 'harness-acp
  (add-to-list 'harness-acp-extra-method-prefixes "hello/"))

(harness-define-module 'hello :doc "Says hello.")
(provide 'harness-hello)
```

```elisp
;;; harness-modules/harness-ui-hello.el  -*- lexical-binding: t; -*-
(require 'harness-ui)

(defun harness-hello (name)
  "Have the harness greet NAME."
  (interactive "sName: ")
  (harness-ui-call "_harness/hello/greet" (list :name name)
                   (lambda (greeting) (message "%s" greeting))))

(harness-define-module 'ui-hello :doc "Asks hello to greet." :requires '(ui))
(provide 'harness-ui-hello)
```

Enable them in your init file with `(harness-enable-modules hello)`:
`ui-hello` is the UI half of `hello`, so it comes with it. The harness
process receives every `harness-` variable you set, so
`(setq harness-hello-greeting "Hi")` in your init file reaches the
module.
[docs/architecture.md](docs/architecture.md#modules-of-your-own) has
the rest of the contract, such as how a module's events reach the UI.

### A project's own plugins

A project can carry harness modules of its own, for tools and commands
that only make sense in it. The harness does not load them. The
project's `.dir-locals.el` does, as Emacs applies any project's
settings: an `eval` entry requires the plugin, and
`harness-plugin-modules` names the plugin modules that the project's
sessions use.

```elisp
;; my-project/.dir-locals.el
((nil . ((eval . (let ((top (locate-dominating-file default-directory ".dir-locals.el")))
                   ;; Not from a checkout nested in another, such as a task's worktree.
                   (unless (locate-dominating-file
                            (file-name-directory (directory-file-name top))
                            (lambda (dir) (and (not (file-equal-p dir "~"))
                                               (file-exists-p (expand-file-name ".git" dir)))))
                     (require 'harness-deploy-plugin
                              (expand-file-name ".harness/plugins/deploy/harness-deploy-plugin" top)))))
         (harness-plugin-modules . (deploy)))))
```

The `unless` matters because Emacs trusts an entry wherever the same
file is, and a task's worktree (in `.worktrees/` of the checkout) holds
a copy of the project that its agent can change. With a plain
`require`, visiting a file of a worktree would load that worktree's
copy of the plugin into your Emacs, if no copy had loaded yet. With
the `unless`, the plugin loads only from the main checkout.

The plugin's files can be anywhere in the repository:

```
my-project/
  .dir-locals.el
  .harness/plugins/deploy/
    harness-deploy-plugin.el  ; what .dir-locals.el requires
    harness-deploy.el         ; module deploy: its tool, in the harness process
    harness-ui-deploy.el      ; module ui-deploy: its command, in your Emacs
```

The same `.dir-locals.el` applies in your Emacs and in the harness
process. So the file it requires loads each half once the part of the
harness that half needs has loaded:

```elisp
;;; harness-deploy-plugin.el  -*- lexical-binding: t; -*-
(let ((dir (file-name-directory load-file-name)))
  (with-eval-after-load 'harness-tools
    (require 'harness-deploy (expand-file-name "harness-deploy" dir)))
  (with-eval-after-load 'harness-ui
    (require 'harness-ui-deploy (expand-file-name "harness-ui-deploy" dir))))
(provide 'harness-deploy-plugin)
```

The modules follow the rules of [modules of your
own](#modules-of-your-own): `harness-NAME.el` holds module `NAME`, and
`ui` modules run in your Emacs. A plugin module starts as soon as its
file has loaded.

Emacs decides whether the plugin loads, as it does for any project.
Neither entry is safe as it is, so Emacs asks before applying them: the
first time you visit a file of the project, and again whenever they
change. Answering `!` trusts them for good, and Emacs saves them in
`safe-local-variable-values`. Until then nothing of the plugin loads.

The harness process cannot ask you anything. Before a session of the
project starts, it applies the project's directory-local variables as
your Emacs would, with what you trust there. Your Emacs passes it your
settings for this, and every later change, so what you trust reaches
new sessions without a restart. Entries you have not trusted are left
out. Only a project whose variables set `harness-plugin-modules` has
them applied there: the `eval` entries you trusted for editing your
other projects never run in the harness process. The harness applies
the variables of the project's main checkout, never those of a task's
worktree: a change an agent makes in a worktree reaches the harness
only once it is merged.

A tool that a plugin module defines is offered only to the sessions
whose list names that module. A session of any other project neither
sees it nor can call it.

Each session freezes its list when it starts, which is when it enters
its sandbox, and keeps it, across restarts of the harness too. A
sub-agent, a fork, a side conversation or a task that an agent submits
takes the list of the session that started it. So the list changes
only from outside every sandbox, when you trust a new value in your
Emacs. An agent that rewrites `.dir-locals.el` changes nothing until
you trust what it wrote.

For the same reason the harness never applies a checkout that an agent
could have made: one nested in another checkout, such as a task's
worktree, one in a `.git` directory, or one in the sessions' temporary
directories. A copy of your trusted `.dir-locals.el` there, beside
plugin code of the agent's own, would otherwise load that code. A
project nested in another checkout, such as a submodule, gets no
plugins.

A plugin is code from the repository, and it runs outside the sandbox
with your Emacs's rights. Trust a project's plugin only if you trust
the project that far. Emacs asks again when `.dir-locals.el` changes,
but not when the plugin's own files change. Whoever can write those
files writes code the harness runs: an agent working in the project's
main checkout rather than a worktree, for example. The harness process
loads a plugin's code once, so a change to it reaches the harness at
the next `M-x harness-restart`.

A plugin tells the harness about its tools the way a module of your
own does:
- it adds a tool to `harness-perms-extra-auto-allow-tools` when the
  tool never needs approval;
- it adds a tool to `harness-tool-slots-tools` when the tool starts
  processes;
- it adds its methods' prefix to `harness-acp-extra-method-prefixes`
  when its UI half calls them;
- a UI module adds actions to the menu of a task board card through
  `harness-ui-tasks-action-functions`.

The harness's own repository has one plugin, `.harness/plugins/dev/`,
which its `.dir-locals.el` loads: the `open_harness` tool and the task
board's Open harness (see [Development](#development)).

Further documentation:

- [DESIGN.md](DESIGN.md): the design the harness implements
- [docs/architecture.md](docs/architecture.md): module contracts
- [docs/modules](docs/modules/README.md): a page for each module,
  generated from its source (`scripts/module-docs.sh`)
- [docs/module-audit.md](docs/module-audit.md): an audit of the modules
  and their API, and what is left to do
- [docs/ui-guide.md](docs/ui-guide.md): the presentation layer, for
  writing UI modules
- [docs/dev-loop.md](docs/dev-loop.md): the live development loop
- [docs/screenshots.md](docs/screenshots.md): how the screenshots are
  taken, and how to take them again when a view changes

## Development

```sh
scripts/test.sh                              # run every test suite, each in a clean Emacs
scripts/test.sh --changed                    # only the suites the working tree's changes touch
scripts/test.sh test/harness-core-test.el    # run one suite (optionally with an ERT selector)
scripts/lint.sh [--checkdoc]                 # byte-compile every file out of tree
scripts/dev.sh start                         # start a clean development Emacs
scripts/media.sh [NAME...]                   # take the screenshots in docs/media again
scripts/module-docs.sh [--check]             # write the module pages in docs/modules again
make -C lisp/vendor/compose-quote test       # a vendored library's own tests, on their own
```

A development Emacs (`scripts/dev.sh`) loads every module; set
`HARNESS_DEV_MODULES=default` to try the harness as a new user gets it,
with the core only. Run `scripts/module-docs.sh` after changing what a
module provides or uses, and commit the pages it writes;
`scripts/module-docs.sh --check` fails while they are out of date.

Tests that talk to real models run only when `HARNESS_INTEGRATION=1` is
set. See [docs/dev-loop.md](docs/dev-loop.md) for the full workflow.

The tools for developing the harness are not part of it. They are this
repository's own plugin, in `.harness/plugins/dev/` (see
[A project's own plugins](#a-projects-own-plugins)), which the
repository's `.dir-locals.el` loads. To get them in the sessions and
tasks that work on the harness, visit a file of your checkout and
answer `!` when Emacs asks about its directory-local variables.

They are:
- the `open_harness` tool, which runs a worktree's harness in an Emacs
  of its own for the agent to try its work in;
- Open harness, in the menu of a task waiting for review (see
  [Task board](#task-board)).

A development Emacs (`scripts/dev.sh start`) never asks: it leaves out
the directory-local variables that are not safe as they are, so it
does not load the plugin. To try the plugin there, set
`enable-local-variables` back to `t` in it, visit a file of the
checkout and answer `!`.

The libraries vendored in `lisp/vendor` have suites of their own.
`scripts/test.sh` runs them with the harness's, and `scripts/lint.sh`
compiles their sources with the rest. A library needs nothing of the
harness, so its suite also runs on its own, in an Emacs with nothing but
its directory on the load path: `make -C lisp/vendor/compose-quote test`.
[lisp/vendor/README.md](lisp/vendor/README.md) has the rules, and how to
take a library from a repository of its own.
A test run is minutes and an edit is seconds, so a run is never worth
repeating just to look at it. While you work, run only the suites your
change touches (`scripts/test.sh --changed` picks them, or name the
files yourself); the full run, with no arguments, is the one to make
once before handing work in. Every suite's whole output is kept in
`scripts/.dev/test-logs/<suite>.log` and the run's own lines and
summary in `scripts/.dev/test-logs/last-run.txt` (`HARNESS_TEST_LOGS`
moves them), so never pipe a run through `grep` or `tail`: a detail you
did not see is still in the log, and reading it costs nothing where
running the suite again costs minutes. A failing run prints each
failing suite's log path.

`scripts/test.sh` runs the suites at idle CPU and I/O priority
(`nice -n 19`, `ionice -c 3`), so a run yields to whatever else you are
doing -- a game, an editor, a build -- and uses what the machine has
left, which on an idle machine is all of it. Set `HARNESS_TEST_NICE=0`
or `HARNESS_TEST_IONICE=0` to run them at the usual priority.

`M-x harness-reload` (`C-c h R`) checks and byte-compiles every source
file, then reloads the harness in place, keeping running sessions. If
any file fails to compile, nothing is reloaded. The UI reloads first,
then the harness process. Each ready module's `:init` runs again, so
what new code wires in there takes effect. A module enabled since the
start loads; one no longer enabled runs on until a restart, and the
reload says so. The echo area says whether
the process reloaded every file, some failed to load or a module failed
to initialise, or it refused the reload.
`harness-auto-reload-mode` reloads the harness whenever one of its
source files changes.

## License

Emacs Agent Harness is free software, released under the GNU General
Public License, version 3. See [LICENSE](LICENSE) for the full text.
