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
| `HARNESS_MEDIA_STEPS` | Also take the pictures of the steps between, where a picture is made of clicks (`chat-decisions-before`, `chat-decisions-redone`, …), to review them; the docs keep only the pictures named below |
| `HARNESS_MEDIA_WORK` | Scratch directory (default `scripts/.dev/media`, which git ignores) |
| `HARNESS_MEDIA_DISPLAY` | Draw on this X display rather than a private one |
| `HARNESS_MEDIA_RUNTIME` | Where the private display's sockets go (default `$XDG_RUNTIME_DIR`, else `/tmp`); a Unix socket path must stay under 108 bytes |

The pictures, by the name `scripts/media.sh` takes:

| Name | Shows | Function |
|---|---|---|
| `chat` | The task board in the fullscreen layout, the session of the task in review beside it: the feedback it was sent back with, the fix, the report it handed in again and the review banner, with the changes the task made: the files as a tree and the threads | `harness-media-shot-chat` |
| `chat-permission` | A chat waiting for permission to run `pip install`, a cheap model's summary of the command under it | `harness-media-shot-chat-permission` |
| `chat-question` | A chat waiting for the answer to a question | `harness-media-shot-chat-question` |
| `attachments` | A compose box holding a picture and a video, their thumbnails in the chips, and a link still downloading with its progress | `harness-media-shot-attachments` |
| `compose-chips` | A compose box whose message names an image, a file of the project and a task: every reference the same inline chip, the list of attachments above | `harness-media-shot-compose-chips` |
| `tasks` | The task board, every section filled but Pending (no limit holds a task back), a task typed in its box | `harness-media-shot-tasks` |
| `tasks-search` | The board searched in words, the query typed in its own compose box: one task matches, the archive it did and `[Undo]`, and the box, in its search colours, ready for the next search | `harness-media-shot-tasks-search` |
| `quick-search` | The quick search opened from the rate-limit session's chat, `acme/ratelimit.py` beside it: its popout lists the command that attaches a file, with `[Run]` and `[Describe]`, and, under a Sessions heading with `[All matches]`, the session that wrote the API guide, with `[Open]` and the passage the session search found in it | `harness-media-shot-quick-search` |
| `tasks-long` | That board after weeks of merges, its completed list held back to keep the box in the window | `harness-media-shot-tasks-long` |
| `tasks-message` | The task board writing a message to a task's session: the box in its message colours | `harness-media-shot-tasks-message` |
| `report` | The board with a task's report popped out, at its end: the chart it handed in, the test run it quotes, the review banner and the feedback box | `harness-media-shot-report` |
| `report-image` | That chart, clicked: shown larger in a popout of its own | `harness-media-shot-report-image` |
| `sessions` | The session list | `harness-media-shot-sessions` |
| `popout-permission` | The session list with a session's permission request popped out under it, summary and all, as wide as the `sessions` picture | `harness-media-shot-popout-permission` |
| `popout-question` | The task board with a task's question popped out under it | `harness-media-shot-popout-question` |
| `tree` | The conversation tree: a session, a fork and a BTW | `harness-media-shot-tree` |
| `usage` | The usage dashboard over 30 days, by model, with the fallback list beneath the plan | `harness-media-shot-usage` |
| `usage-projects` | The usage dashboard by project, the tasks' worktrees folded under the demo project | `harness-media-shot-usage-projects` |
| `usage-worktrees` | The same, the demo project's worktrees unfolded | `harness-media-shot-usage-worktrees` |
| `worktrees` | The worktrees of the demo project, a task's assumed as the project (`a`), reset again after the picture | `harness-media-shot-worktrees` |
| `settings` | The settings page for the demo project, which overrides two settings | `harness-media-shot-settings` |
| `settings-policy` | The settings page under an administrator's policy (docs/policy.md): the banner listing what it sets, the settings it sets locked | `harness-media-shot-settings-policy` |
| `btw` | A BTW under the rate-limit session's chat, `acme/ratelimit.py` beside it | `harness-media-shot-btw` |
| `menu` | The menu, opened from that chat | `harness-media-shot-menu` |
| `version` | The version-and-update page of a harness straight.el installed from GitHub, ten commits behind GitHub: a row each for what runs, the checkout (with [Reload]) and the remote (with [Update]), the commits it lacks as changelog entries with their message bodies, the development checkout with what it has pushed, and a vendored plugin with its version and [Update] | `harness-media-shot-version` |
| `insights` | The Insights report over 30 days of every project: the totals, the summary the scripted model wrote, the messages by hour and weekday | `harness-media-shot-insights` |
| `insights-activity` | The same report further down: the busiest sessions, the tools, the permission decisions and the tasks | `harness-media-shot-insights-activity` |
| `chat-cowboy` | A chat whose prompt cache went cold yesterday, `orders.py` beside it: another session's message waits while the panel asks what goes first, each choice with its cost | `harness-media-shot-chat-cowboy` |
| `chat-decisions` | Two chats: an "Always deny" answer for `bash` in the left one, a `bash` call that rule denied in the right one, naming the answer; [Undo] was clicked on the right, so both strike the answer through and offer [Redo] | `harness-media-shot-chat-decisions` |
| `chat-decisions-cold` | Two chats whose prompt caches went cold: the left one answered "always" start afresh, the right one took that default unasked and names the answer; both offer [Undo] | `harness-media-shot-chat-decisions-cold` |
| `notes` | A session's chat whose `spawn_agent` call runs, and the sub-agent's chat beside it: the note under the spawn call says what the child does, with a recap of it and its facts, and the note under the child's `bash` call says it is still running | `harness-media-shot-notes` |
| `chat-queue` | A chat whose turn runs, `acme/db.py` beside it: a message sent during the turn that the model has taken reads as any other, one sent since says "queued" beside the name with `[edit]` and `[delete]`, each with its key, and two more queued messages, drawn as messages of the user's, say "queued" with `[send now]`, `[edit]` and `[delete]`, above the line saying what the turn does | `harness-media-shot-chat-queue` |
| `prompt-region` | Lines of `acme/ratelimit.py` selected, and `C-c h >` on them: the newest session's box holds where they come from and the code in a fenced block | `harness-media-shot-prompt-region` |
| `slots` | The demo project's task slots: the four tasks in slots as rows of the session list's columns, at three priorities, the blocked one with its question and `[Answer…]` under it; four tasks waiting, by priority and next in line; and how long tasks waited for a slot this week. Taken last: it sets a limit, starts a task and queues four (`harness-media--fill-slots`) | `harness-media-shot-slots` |
| `quote-reply` | A chat whose agent replied in three paragraphs, `acme/webhooks.py` beside it: the reply quoted in the box with `C-u C-c >` (`C-c >` itself starts a thread), the middle of its long paragraph elided with `C-c [` (`[...]`), the quote split with `M-RET` and an answer typed under each part, point in the box | `harness-media-shot-quote-reply` |
| `quote-thread` | A chat whose agent answered a reply that quoted it, `acme/webhooks.py` beside it: the agent's answer quoted in the box, and under it the thread it answers, one `>` level deeper: the user's inline reply, its answers and the agent's message they quoted; the answer's line split with `M-RET` and an answer typed under it, point in the box | `harness-media-shot-quote-thread` |
| `thread-reply` | The chat of a task (a session adopted on the board), `acme/webhooks.py` beside it: the agent's two paragraphs, and the user's reply in two threads -- a part of each paragraph selected and `C-c >` pressed, a card in the box for each, what it replies to, the words typed under it -- drawn as the cards they were, the words under each as far in as its card, and a link to the thread it made; the agent's answers in those threads drawn as its own messages under the thread's name (one thread open, one closed); and the box with a card for the agent's answer in the first thread and a reply typed under it, point in the box | `harness-media-shot-thread-reply` |
| `thread-reply-review` | The review of the slow-request task, its report at the threads, the filter on all: the first is made by a reply in the chat -- the user selected a part of what the agent said and asked about it, which `C-c >` made a thread when the message was sent, and the agent answered in the thread with `review_comment`, its call in the session -- a comment of the user's with the quote above the question, and the agent's answer under it linking to the conversation. Taken last of all: the thread is on the review of a task every other picture shows | `harness-media-shot-thread-reply-review` |
| `review-thread-lines` | Ediff on `acme/app.py` in the slow-request task's review, three lines of the branch's version selected with `C-SPC` and `C-n` and `C-c >` pressed: the report's box holds the card (the file, the side, the lines, the lines themselves) with the question typed under it, point in the box. The reply is given up after, and Ediff left | `harness-media-shot-review-thread-lines` |
| `notes` | A session's chat after its `spawn_agent` call started a sub-agent, and the sub-agent's chat beside it: the sub-agents panel above the session's compose box lists the child running, with its name as a link, how long its turn has gone on and what it does now, and the note under the child's `bash` call says it is still running | `harness-media-shot-notes` |
| `chat-denied` | A session's chat whose `bash` call its own rule refuses: the denial names the handle, and the call offers `[Approve]`, the user's yes, which no mode, rule or judge can deny | `harness-media-shot-chat-denied` |
| `chat-denied-approved` | The same chat after the user approved that call: it reads user-approved, the agent's `rerun_approved` call under it ran the very command, with the handle linking the two | `harness-media-shot-chat-denied-approved` |
| `access` | The jail and permissions view of a session kept to a jail, its Overview: the settings in one group (the mode, interactive or not, the network the agent gave up with `drop_access`, writing, the capability the user gave its commands to trace the test run, the sandbox), the directories (the ops notes it may only read) and a line each for the tools, the rules and the judgements | `harness-media-shot-access` |
| `access-tools` | The Tools page of that view: the tools it is offered, the web tools gone with the network the agent gave up and the sub-agents the user turned off, listed apart by why | `harness-media-shot-access-tools` |
| `access-judgements` | The Judgements page of that view: each of the session's calls drawn as the chat draws it, under what was decided, by whom and its handle; the two the access settings refused offer `[Approve]`, the test run waits for the user, the agent's own `drop_access` is unfolded | `harness-media-shot-access-judgements` |
| `review` | The slow-request task in review, its report at the changes: the two files as a tree with their marks, the threads below them in the same buffer by file, and the drafts waiting to go with the feedback. Taken last: it puts a second commit on that task's branch and the threads of its review (`harness-media--review-prepare`, `harness-media--review-threads`) | `harness-media-shot-review` |
| `review-threads` | The threads of that review, a section of its report below the files, the filter on all: each comment with who wrote it, when, its version and its place in the thread, one with where it was made and the lines of the diff, the agent's answer linking to its conversation, a draft with its `[Edit]` and `[Delete]` buttons and its thread's `[Delete thread]` | `harness-media-shot-review-threads` |
| `review-banner` | The session of that task, its review banner showing the changes with no click on [Review Changes]: the files as a tree, the first approved, the threads by file under them, and [Verify] and [Send back] below | `harness-media-shot-review-banner` |
| `review-ediff` | Ediff on a file of that review: the files as a tree on the left with the file compared highlighted and the threads under them, the merge base and the branch with the threads drawn under their lines, the control panel offering to comment, reply, edit or delete a draft, delete a thread of drafts and go to the threads, and to switch its settings, the report with its box at the bottom | `harness-media-shot-review-ediff` |
| `review-diff` | That report with the diff chosen since the last review: the Diff line marks it, the files are those the work changed since the version before (one, here), and the threads below them, those of the file the diff leaves out too, with their file. Taken after the other review pictures, and it puts the report back at the branch against main | `harness-media-shot-review-diff` |
| `review-to-review` | The threads of that review on its "to review" filter: the two threads the agent closed that the reviewer has not looked at yet, each with the agent's answer; the thread the reviewer closed themselves is not there | `harness-media-shot-review-to-review` |
| `review-select` | The same Ediff, the end of the agent's answer on the renamed function selected with the mouse: the thread is a string an overlay shows, which no region holds, so the text of its comments has the mouse's keys and the selection is marked. Taken on the way to `review-quote`, by the same function | `harness-media-shot-review-quote` |
| `review-quote` | That selection after `C-c >`: the reply opens in a buffer below the version with the selected part quoted, `> ` before each line, point under it, and the answer typed. The reply is given up after the picture | `harness-media-shot-review-quote` |
| `links` | A chat whose agent wrote a message of links, `acme/app.py` beside it: a tool call (`harness:call/bash`, the newest call of the bash tool), a session by its name, a message of it, a thread of a task's review and the task, each written by a name or a handle and written out in full by the linking module when the message ended; each reads as the words the agent gave it. Taken last: it makes two sessions of its own and a thread on the slow-request task's review (`harness-media--links-sessions`) | `harness-media-shot-links` |
| `links-followed` | That chat after a click on the link to the thread: the task's report opened under it, its review at the thread the link names, point on it | `harness-media-shot-links-followed` |

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

Two modules are off, so that nothing outside the world reaches a
picture: `recap`, whose lines are written by a model (the pictures get
hand-written ones), and `tool-slots-load`, which on a busy machine tells
every active chat "Tool slots reduced from 18 to 5: system load 1.8x" and
pins "Tool slots limited to 5 of 18" above its compose box.  A run of
the pictures does not depend on how loaded the machine is.

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
  would, into every section of the board but Pending: two verified and
  merged, one verified and waiting in the merge queue (whose lock on the
  main checkout `harness-media--hold-merge-queue` holds, so its merge
  never starts), one in review (sent back
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
- `harness-media--seed-rates` gives every session the output it streamed
  and the seconds that took, at its model's pace
  (`harness-media--rates`), for the session list's Avg tok/s column and
  the cards of the board.  The scripted agents replay their turns in a
  blink, so the usage module measured next to nothing.
- `harness-media--age` moves the times of the tasks, the sessions (their
  last messages too, for the Last msg column) and the tree's nodes back,
  so the pictures read "done 2h ago" and "took 14m" rather than "just
  now".
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
write-ups from `harness-media--write-ups`, and the search's model --
the task board's and the quick search's, whose system prompt starts
"You are the search box" -- from `harness-media--search-answer`, which
reads the query in the first message and answers the JSON the search
asks for (the `tasks-search` picture archives the slow-request task
that way; the `quick-search` one first asks to look in the sessions'
transcripts for the guide, and, told what the session search found --
the real one, over the sessions of the run -- names the command that
attaches a file and the session that wrote the API guide, which the
popout then shows with the passage found in it).  The pictures type the
query in the search's compose box and send it with the box's own
command, `harness-quick-search-box-submit`, as `RET` does.

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
- `harness-media--keys` presses keys in the selected window through the
  command loop, as a user's keyboard would, and `harness-media--type`
  types a text, so a picture shows what keys do and not only what a
  function leaves behind.  `quote-reply` quotes, elides and splits that
  way.  Select the window first and check the buffer after each step
  (`harness-media--box-expect` does it for a compose box): a key that did
  nothing then fails the run, not the picture.  A prompt would wait for
  a keyboard nobody is at, so press no key that asks.
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
- **Internal sessions.**  The harness records its own model calls (the
  judge's verdicts, session titles, recaps) as sessions of kind
  `internal`, children of the session they were made for when there is
  one.  The session list leaves them out, but `session/list` does not:
  code that looks for a session by its parent or its name must skip
  them.
- **Bugs.**  When a picture shows the UI doing something wrong, fix the
  UI rather than the picture.  Taking these pictures found five so
  far: the chat header dropped the % of quota windows, Markdown tables
  with inline code did not line up, a budget had "1 days left", a
  report's file evidence gave its link count for its size ("1 B"), and
  the sub-agents panel's lines wrapped in a chat half the frame wide.
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
