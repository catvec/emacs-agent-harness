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
| `chat` | `acme/ratelimit.py` beside a finished turn: reads, edits, a test run, a summary | `harness-media-shot-chat` |
| `chat-permission` | A chat waiting for permission to run `pip install` | `harness-media-shot-chat-permission` |
| `chat-question` | A chat waiting for the answer to a question | `harness-media-shot-chat-question` |
| `tasks` | The task board, every column filled, a task typed in its box | `harness-media-shot-tasks` |
| `tasks-long` | That board after weeks of merges, its completed list held back to keep the box in the window | `harness-media-shot-tasks-long` |
| `tasks-message` | The task board writing a message to a task's session: the box in its message colours | `harness-media-shot-tasks-message` |
| `sessions` | The session list | `harness-media-shot-sessions` |
| `popout-permission` | The session list with a session's permission request popped out under it | `harness-media-shot-popout-permission` |
| `popout-question` | The task board with a task's question popped out under it | `harness-media-shot-popout-question` |
| `tree` | The conversation tree: a session, a fork and a BTW | `harness-media-shot-tree` |
| `usage` | The usage dashboard over 30 days, by model | `harness-media-shot-usage` |
| `worktrees` | The worktrees of the demo project | `harness-media-shot-worktrees` |
| `settings` | The settings page for the demo project, which overrides two settings | `harness-media-shot-settings` |
| `btw` | A BTW under the first picture's chat | `harness-media-shot-btw` |
| `menu` | The menu, opened from that chat | `harness-media-shot-menu` |

## How the pictures are made

`scripts/media.sh` starts the display, makes a scratch HOME, and runs
`emacs -Q -l scripts/harness-media.el -f harness-media-main` there.
Everything else is in `scripts/harness-media.el`, which
`harness-media-run` drives in four steps.

**The look** (`harness-media--setup-look`): no menu, tool or scroll
bars, the theme `modus-vivendi-tinted`, the Hack font at 12 pt when it
is installed, and a frame of 160 columns by at most 54 lines.  The
constants at the top of the file (`harness-media-theme`,
`harness-media-font`, `harness-media-columns`, ...) change them all.

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
- `harness-media--seed-usage` records a month of model calls across
  three projects, and `harness-media--seed-budgets` adds three budgets,
  sized from that usage so their meters land at different levels.
- `harness-media--build-tasks` submits tasks and drives them, as a user
  would, into every column of the board: two verified and merged, one
  verified and waiting in the merge queue, one in review (sent back
  once), one asking a question, two working
  (their turns held half way), two written up for the backlog.  They
  run in real worktrees, commit and merge.
- `harness-media--build-sessions` runs the conversations: the first
  picture's session, a fork of it and a BTW over it, the permission and
  question chats, and two older sessions, closed since.
- `harness-media--age` moves the times of the tasks, the sessions and
  the tree's nodes back, so the pictures read "done 2h ago" and "took
  14m" rather than "just now".

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
| `(list :type 'hold)` | Stop here and never finish: the turn stays running |
| `(list :type 'usage ...)` | The request's usage, when the default will not do |

As with a real model, a tool call ends the request; once the agent has
run the tool it asks again, and the script goes on where it stopped.
Each request reports a plausible usage (context from what was sent,
billing by provider) unless the script gives one.
`harness-media--task-script` builds a task's turn: todos, the changes,
a commit and a summary, or, with HOLD, half of it and a hold.

Requests that are not a conversation get answers of their own: the
auto-mode judge always allows, session titles come from
`harness-media--titles` (matched against the first message), and
backlog write-ups from `harness-media--write-ups`.

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
  chat and fits the frame to both; `harness-media--hero-layout` is the
  first picture's layout, which the BTW and menu pictures start from.
- `harness-media--expand` unfolds a tool call in a chat and
  `harness-media--to-bottom` scrolls a chat to its compose box.
- `harness-media--world` holds the ids of what the world made: the
  sessions `:hero`, `:fork`, `:btw`, `:permission`, `:question`,
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
  UI rather than the picture.  Taking these pictures found three so
  far: the chat header dropped the % of quota windows, Markdown tables
  with inline code did not line up, and a budget had "1 days left".
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
