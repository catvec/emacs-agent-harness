# Screenshots

The pictures in `docs/media`, the README's first picture and its
gallery, are taken by a script, not by hand.  When a view changes, or a
new one arrives, its picture is taken again with one command and
committed with the change.  This page says how to take them, how the
script makes what they show, and how to add or change a picture.

## Taking them again

```sh
scripts/media.sh                    # every picture, in about a minute
scripts/media.sh tasks usage        # only these
HARNESS_MEDIA_DUMPS=~/media-text scripts/media.sh   # and the text of each, to check
```

The pictures go to `docs/media`, replacing the ones there.  Look at
them, check the text if anything looks off (see Checking a picture),
and commit them along with the change they show.

It needs an Emacs built with Cairo (for `x-export-frames`) and `git`,
plus somewhere to draw.  `scripts/media.sh` picks, in this order:

1. Xvfb, when it is installed: a virtual X server.
2. A headless `kwin_wayland --virtual` with a rootful Xwayland, on KDE.
   kwin's own Xwayland would need `/tmp/.X11-unix`, so a small Python
   snippet hands Xwayland a socket in a private runtime directory
   (`-listenfd`), and `DISPLAY` names that socket.  This needs
   `python3`.
3. `$DISPLAY`: a frame then shows on your screen while the run lasts.

Either of the first two keeps your screen untouched.

| Variable | Use |
|---|---|
| `HARNESS_MEDIA_OUT` | Where the pictures go (default `docs/media`) |
| `HARNESS_MEDIA_DUMPS` | Also write the text of each picture there |
| `HARNESS_MEDIA_WORK` | Scratch directory (default `scripts/.dev/media`, which git ignores) |
| `HARNESS_MEDIA_DISPLAY` | Draw on this X display rather than a private one |
| `HARNESS_MEDIA_RUNTIME` | Where the private display's sockets go (default `$XDG_RUNTIME_DIR`, else `/tmp`); a Unix socket path must stay under 108 bytes |

The pictures, by the name `scripts/media.sh` takes:

| Name | Shows | Function |
|---|---|---|
| `chat` | The task board in the fullscreen layout, the session of the task in review beside it: the feedback it was sent back with, the fix, the report it handed in again and the review banner | `harness-media-shot-chat` |
| `chat-permission` | A chat waiting for permission to run `pip install` | `harness-media-shot-chat-permission` |
| `chat-question` | A chat waiting for the answer to a question | `harness-media-shot-chat-question` |
| `attachments` | A compose box holding a picture and a video, their thumbnails in the chips, and a link still downloading with its progress | `harness-media-shot-attachments` |
| `tasks` | The task board, every column filled, a task typed in its box | `harness-media-shot-tasks` |
| `tasks-search` | The board searched in words: one task matches the query, the archive it did and `[Undo]` | `harness-media-shot-tasks-search` |
| `tasks-long` | That board after weeks of merges, its completed list held back to keep the box in the window | `harness-media-shot-tasks-long` |
| `tasks-message` | The task board writing a message to a task's session: the box in its message colours | `harness-media-shot-tasks-message` |
| `report` | The board with a task's report popped out, at its end: the chart it handed in, the test run it quotes, the review banner and the feedback box | `harness-media-shot-report` |
| `report-image` | That chart, clicked: shown larger in a popout of its own | `harness-media-shot-report-image` |
| `sessions` | The session list | `harness-media-shot-sessions` |
| `popout-permission` | The session list with a session's permission request popped out under it | `harness-media-shot-popout-permission` |
| `popout-question` | The task board with a task's question popped out under it | `harness-media-shot-popout-question` |
| `tree` | The conversation tree: a session, a fork and a BTW | `harness-media-shot-tree` |
| `usage` | The usage dashboard over 30 days, by model, with the fallback list beneath the plan | `harness-media-shot-usage` |
| `usage-projects` | The usage dashboard by project, the tasks' worktrees folded under the demo project | `harness-media-shot-usage-projects` |
| `usage-worktrees` | The same, the demo project's worktrees unfolded | `harness-media-shot-usage-worktrees` |
| `worktrees` | The worktrees of the demo project | `harness-media-shot-worktrees` |
| `settings` | The settings page for the demo project, which overrides two settings | `harness-media-shot-settings` |
| `settings-policy` | The settings page under an administrator's policy (docs/policy.md): the banner listing what it sets, the settings it sets locked | `harness-media-shot-settings-policy` |
| `btw` | A BTW under the rate-limit session's chat, `acme/ratelimit.py` beside it | `harness-media-shot-btw` |
| `menu` | The menu, opened from that chat | `harness-media-shot-menu` |
| `version` | The version page of a harness straight.el installed from GitHub, behind GitHub and its development checkout: the commits it lacks and how to pull them | `harness-media-shot-version` |
| `insights` | The Insights report over 30 days of every project: the totals, the summary the scripted model wrote, the messages by hour and weekday | `harness-media-shot-insights` |
| `insights-activity` | The same report further down: the busiest sessions, the tools, the permission decisions and the tasks | `harness-media-shot-insights-activity` |
| `chat-cowboy` | A chat whose prompt cache went cold yesterday, `orders.py` beside it: another session's message waits while the panel asks what goes first, each choice with its cost | `harness-media-shot-chat-cowboy` |
| `notes` | A session's chat whose `spawn_agent` call runs, and the sub-agent's chat beside it: the note under the spawn call says what the child does, with a recap of it and its facts, and the note under the child's `bash` call says it is still running | `harness-media-shot-notes` |

## How the pictures are made

`scripts/media.sh` starts the display, makes a scratch HOME, and runs
`emacs -Q -l scripts/harness-media.el -f harness-media-main` there.
Everything else is in `scripts/harness-media.el`, which
`harness-media-run` drives in four steps.

**The look** (`harness-media--setup-look`): no menu, tool or scroll
bars, the theme `modus-vivendi-tinted`, the Hack font at 12 pt when it
is installed, and a frame of 160 columns by at most 54 lines.  The
first picture is 180 columns wide (`harness-media-hero-columns`), so the
board and the session beside it get 90 each.  The constants at the top
of the file (`harness-media-theme`, `harness-media-font`,
`harness-media-columns`, ...) change them all.

**The harness** (`harness-media--setup-harness`): the harness of the
checkout, started in this Emacs (`harness-process` nil), its state
under the scratch HOME.  The real providers are disabled and two
scripted stand-ins take their place:

- `claude`, labelled "Claude Code", with the real provider's model
  catalogue (read from `harness-provider-claude.el`, so it never goes
  stale) and a quota of the Max plan: sessions show "Max · 5h 23% · 7d
  41%" and cost nothing per token.
- `openrouter`, with GPT-5 and Gemini 2.5 Pro, billed per token: the
  session list and the usage page show dollars.

Both answer every request from a script (see below).  Their tool calls
go through the real agent loop, permissions and tools, run on the demo
project, so every tool output in the pictures is genuine.  Nothing
calls a model or the network.

**The world** (`harness-media--build-world`):

- `harness-media--make-project` makes `~/src/acme-api`, a small Python
  WSGI orders API with tests and a git history of three commits.  Its
  files are the `harness-media--*` string constants.  The scratch HOME
  makes every path read `~/src/acme-api`.
- `harness-media--make-harness-repos` makes the harness's own
  repositories, for the version picture: a bare repository standing in
  for GitHub, straight.el's shallow clone of it in `~/.emacs.d/straight`,
  and a development checkout, `~/src/emacs-agent-harness`; GitHub and
  the checkout are ten commits ahead of the clone.  The scratch
  `~/.gitconfig` sends GitHub's URL to the bare repository, and
  `GIT_ALLOW_PROTOCOL=file` lets git use no other protocol
  (`harness-media--harness-origins`), so neither the clone nor the
  version checks the harness runs by itself reach the network.  The
  check finds GitHub by itself, as the repository the clone pulls from.
- `harness-media--seed-usage` records a month of model calls across
  three projects, and `harness-media--seed-budgets` adds three budgets,
  sized from that usage so their meters land at different levels.  The
  weekly one is hard, so it stays at $5 at least: early in the week the
  seeded spend is small, and the world's own turns must still fit.
- `harness-media--build-tasks` submits tasks and drives them, as a user
  would, into every column of the board: two verified and merged, one
  verified and waiting in the merge queue, one in review (sent back
  once: the first picture shows its session), one asking a question,
  two working (their turns held half way), two written up for the
  backlog.  They run in real worktrees, commit and merge.  Every round
  of work ends with `hand_in`, as a task session is told to (a round
  without it would put `[No report]` on its card).  The pagination task
  hands in a latency chart it writes, `docs/orders-latency.svg`, and
  its real test run, which the report pictures show.
- `harness-media--build-sessions` runs the conversations: the rate-limit
  session, a fork of it and a BTW over it (the tree, BTW, menu and
  attachments pictures), the permission and question chats, and two
  older sessions, closed since.
- `harness-media--age` moves the times of the tasks, the sessions and
  the tree's nodes back, so the pictures read "done 2h ago" and "took
  14m" rather than "just now".
- `harness-media--seed-history` writes a month of earlier chats for
  the Insights pictures. The report reads transcripts from disk, where
  the world's nodes all date from today; `harness-media--age` moves
  them in memory only. Day by day back from yesterday, it writes chats
  in the three projects at working hours, with their tool calls,
  failures and denials, and the permission decisions those calls took.
  The first Insights shot does it, and those shots come last, so the
  other pictures never show these chats. The scripted model answers
  the report's request with `harness-media--insights-summary`.

The random generator is seeded, so runs look alike, though times
follow the clock, and ids drawn while turns run side by side can come
out in another order.

**The pictures**: each shot function lays out the frame, waits for the
views to draw, sizes the frame to what they show and calls
`harness-media--capture`, which exports the frame with
`x-export-frames` to `NAME.png` (and writes `NAME.txt` when dumping).

## The scripted agents

A request is answered by the first entry of `harness-media--scripts`
whose regexp matches the newest user message, case aside.  An entry
names a function that returns the turn as a list of events, built with:

| Helper | Event |
|---|---|
| `(harness-media--think TEXT)` | Thinking |
| `(harness-media--say TEXT)` | Text (Markdown) |
| `(harness-media--tool NAME :key VALUE ...)` | A tool call; the agent runs the real tool |
| `(harness-media--todos (TEXT . STATUS) ...)` | A `todo_write` call |
| `(harness-media--git-commit MESSAGE)` | A `bash` call committing everything |
| `(harness-media--tool "hand_in" :summary TEXT :evidence ITEMS)` | Hand the work in: the turn ends and the task waits for review with a report |
| `(list :type 'hold)` | Stop here and never finish: the turn stays running |
| `(list :type 'usage ...)` | The request's usage, when the default will not do |

As with a real model, a tool call ends the request; once the agent has
run the tool it asks again, and the script goes on where it stopped.
Each request reports a plausible usage (context from what was sent,
billing by provider) unless the script gives one.
`harness-media--task-script` builds a task's turn: todos, the changes,
a commit and a summary, or, with HOLD, half of it and a hold; with
EVIDENCE it hands the summary in with that evidence rather than saying
it.

Requests that are not a conversation get answers of their own: the
auto-mode judge always allows, session titles come from
`harness-media--titles` (matched against the first message), backlog
write-ups from `harness-media--write-ups`, and the task board's search
from `harness-media--search-answer`, which reads the query in the board
dump and answers the JSON the search asks for (the `tasks-search`
picture archives the pagination task that way).

## Adding or changing a picture

**A view changed.**  Take its picture again (`scripts/media.sh NAME`),
check it and commit it.  When the view needs something the world does
not have yet, a column of the board that stays empty, say, add it to
the world as below.

**A new view.**  Write a shot function and add it to
`harness-media-shots`:

```elisp
(defun harness-media-shot-dashboard ()
  "The new dashboard."
  (harness-media--view #'harness-dashboard)  ; opens it taking the whole frame
  (harness-media--capture "dashboard"))
```

- `harness-media--view` calls a function that opens the view, with
  `harness-ui-default-position` bound to `full`, waits, then fits the
  frame to the view's text.  Its optional THEN runs in the view's buffer
  first (to pick a period or a grouping, say), and MOST caps the height.
- `harness-media--chat-shot` shows a project file beside a session's
  chat and fits the frame to both; `harness-media--code-layout` is the
  rate-limit session beside `acme/ratelimit.py`, which the BTW and menu
  pictures start from.
- `harness-media--fullscreen-layout` is the first picture's layout: it
  opens the board in the `fullscreen` position and a task's session from
  its card, as a user would, and fits the frame to the session's last
  round, from the message that started it to the compose box.
- `harness-media--expand` unfolds a tool call in a chat and
  `harness-media--to-bottom` scrolls a chat to its compose box.
- `harness-media--world` holds the ids of what the world made: the
  sessions `:ratelimit`, `:fork`, `:btw`, `:permission`, `:question`,
  `:guide` and `:flaky`, and `:tasks`, a plist of task ids.

Then show it in the README's gallery, next to a picture of about the
same height, with a caption row under the pair.

**A new conversation.**  Create a session and prompt it in
`harness-media--build-sessions`:

```elisp
(let ((id (harness-media--new-session :name "Short name" :model "claude:claude-opus-5-5"
                                      :permission-mode 'accept-edits)))
  (harness-media--prompt id "The user's message")   ; waits until idle; '(blocked) for a pending request
  (setq harness-media--world (append (list :mine id) harness-media--world)))
```

and add its script to `harness-media--scripts`, a regexp of the message
with a function returning the events.  An `ask_user` call, or a command
in Ask mode, leaves the session waiting with its panel showing.

**Tasks.**  `harness-media--submit` takes the prompt and the options of
`task/submit` (`:refine t`, `:non-interactive :false`, ...);
`harness-media--wait-task` waits until a task is where it should be,
and `task/verify` or `task/reject` move it on.  Give a new task a
script, a title in `harness-media--titles`, and its times in the plan
of `harness-media--age`.

## Checking a picture

You do not have to open a picture to check it: with
`HARNESS_MEDIA_DUMPS` set, each `NAME.txt` holds the frame's size and,
for every window, its header line, the text it shows (folded text left
out) and its mode line.  The first line of each window says how many
lines it has and whether its text shows from the top: "below the top"
means the window had to scroll, so the beginning is cut off.

Before committing, check that

- the text is what the view should show, with no error and no hint
  that should not be there;
- no real path or name shows (`grep -rE '/home|/tmp' DUMPS` finds
  nothing);
- each picture still pairs well with its neighbour in the gallery: the
  heights are in the header of each `NAME.txt`.

## Things to keep in mind

- **Paths.**  Tool calls in scripts take paths relative to the session's
  directory: an absolute path would show the scratch HOME's real path.
- **Names.**  Keep session and task names within 28 characters, the
  width of the session list's Name column; longer ones end in "…".
- **Code beside a chat.**  The code window is half the frame, 80
  columns, line numbers included: keep its lines within 76 characters
  or they wrap.
- **Heights.**  Frames are fitted to their content, measured in pixels
  (images such as the usage chart and the tree's lanes are taller than
  a line), up to 54 lines.  A chat keeps its compose box at the bottom
  of its window with padding, which the fitting leaves out.
- **Times.**  Anything a view shows as "N ago" needs a time in
  `harness-media--age`, or it reads "just now".
- **Bugs.**  When a picture shows the UI doing something wrong, fix the
  UI rather than the picture.  Taking these pictures found four so
  far: the chat header dropped the % of quota windows, Markdown tables
  with inline code did not line up, a budget had "1 days left", and a
  report's file evidence gave its link count for its size ("1 B").
- **Missing pictures.**  `test/harness-docs-test.el` fails when the
  README links a picture that is not in `docs/media`, which git.sr.ht
  and GitHub would show as a broken image: take it again with
  `scripts/media.sh NAME`.
- **Old pictures on GitHub.**  GitHub caches images by their URL, so a
  picture taken again under the same name can show the old one for a
  while after the push.  Reload without the cache, or wait.
- **Sandboxed runs.**  An agent taking the pictures from the harness's
  sandbox has a private `/tmp` and may have no `$XDG_RUNTIME_DIR` it
  can write: set `HARNESS_MEDIA_RUNTIME` to a short directory it may
  write.  The X display of your desktop is out of its reach too, which
  is why the headless display exists.
- **GPU drivers.**  Some crash Xwayland when it starts headless (seen
  with NVIDIA), so it runs with `-shm -extension GLX`, which the
  pictures do not miss.
