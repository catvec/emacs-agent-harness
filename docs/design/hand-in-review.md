# A hand-in review that reads the design first

## Why lines are not enough

A diff is read a line at a time. A line can show a typo or a missing
check; it rarely shows that the change solves the wrong problem, that
two parts grew in different directions, or that a boundary is in the
wrong place. Those are the flaws worth a reviewer's time, and they show
in the shape of the whole.

So the hand-in takes a document that explains the shape, draws it
before the code, and lets the reviewer comment on it a section at a
time. The evidence grows a kind that can be tried, not only looked at:
a page, a URL or a command, with the narration of what to show. And the
review can start a conversation that presents the work, with voice
where the voice module is loaded, so the reviewer can interrupt and ask
to see another part.

## The document

`hand_in` takes an optional `design`: the path of a Markdown document
in the worktree, and optionally its title and a summary. The harness
reads the file when the work is handed in and keeps its text in the
report, so a review reads what the author explained and not what the
file says after the branch moved. The path is checked against the
session's directories, as every path in the report is.

The report draws the document first, before the problem and the
summary, and folds as the report's other sections do. It draws up to
`harness-ui-report-design-max-chars` of it; the whole of it is behind
`[Open design]`, which opens the file where it lives.

## Sections are threads

Every Markdown heading starts a section, and a line inside a fenced
code block is no heading. Each section is a quote target: `C-c >` on
one starts a thread whose location is the document and the section's
line range, so the thread card says `design.md:11-23`, not "the
report". The patch review already knew how to place a reference to a
file and lines; a `buffer` reference is a second shape of the same
thing, at the newest revision, with the section as the location's
excerpt.

A design thread is a change-review thread with another location, not a
second kind of thread. It is answered where the review is answered, it
is part of the round of feedback that sends the task back, and the
reply that revises the document is the reply to it. The summary the
hand-in wrote above the document is a report reference, quotable the
same way.

## Demos

A report's evidence may be a `demo`: a page or directory in the
worktree, an HTTP URL, an argv command, a working directory, a title, a
narration, and optionally the workspace whose computer runs it. Handing
one in runs nothing. A demo is data until the reviewer acts on it:
`[Open demo]` opens its page or URL, `[Run demo]` starts its command
where the harness runs after a confirmation and keeps the output in a
buffer of its own, and `[Stop demo]` ends it. The command is a list,
never a shell string, so what is shown is what runs.

Each demo is numbered in the report (`demo-1`, `demo-2`), so the review
and the app name the same one, and the harness can find it again from
the report the task handed in.

The narration is what the presenter says while it shows the demo. It is
drawn as Markdown under `Narration`, so the reviewer can read the steps
before trying them, and the presenter has the same words.

## The demo on the workspace computer

A demo is best tried where it runs: on the computer of the workspace
the work belongs to, with the reviewer watching that computer's screen
in the app and talking to the presenter that drives it. `Start demo` is
that one flow, and it goes through `demo/start`:

- **The binding.** The call names the session that handed the work in
  and the demo's id. The harness resolves the task, the report it last
  handed in, and the demo in it, and keeps that binding in the run: the
  task, the demo, the reviewed commit of the task's worktree, and the
  workspace. A demo whose worktree has changed since the hand-in, or
  whose computer is checked out on another commit, is not started: it
  would show other source than the one reviewed.
- **The workspace.** The demo's own `:workspace`, or the one workspace
  whose root holds the task's project; a start that names none runs the
  demo where the harness does and says so (`placement: host`), and the
  app shows no screen for it rather than a false one.
- **The computer.** On a workspace, `demo/start` asks the box for its
  status, maps the demo's directory through the box's mounts, runs the
  command there in the background and opens the demo's page in the
  box's browser. Its screen comes back from `workspace/box/vnc` as a
  URL and the websocket an RFB client speaks to; the app draws it,
  letterboxed, and sends the reviewer's pointer and keys to it while
  they have control.
- **The control.** `Control · agent` is the presenter's; tapped, the
  reviewer takes the computer (`workspace/box/take-over`) and the
  presenter's tool refuses until they hand it back
  (`workspace/box/return-control`).
- **The presenter.** The start opens a BTW of the task's session and
  briefs it with the run, the workspace, the reviewed commit and the
  `present_demo` tool, whose actions are the box's: click, type, key,
  scroll, drag, open, launch, windows and screenshot. It is the same
  conversation the voice speaks through: the reviewer's words go to it,
  its replies are spoken, and it can be interrupted.
- **The states.** The answer is `running`, `missing`, `not-ready`,
  `denied`, `error` or `lost`, with a reason code: `no-demo`,
  `worktree-dirty`, `workspace-missing`, `box-methods-missing`,
  `box-not-running`, `mount-missing`, `commit-mismatch`,
  `demo-not-runnable`, `spawn-failed`, `vnc-unavailable`. The app draws
  each as it is, and the same run answers a second tap, so a double
  click is one demo.
- **The stop.** `demo/stop` stops what the run started and nothing
  else: the process on the harness's machine, control given back on a
  computer, never the box itself and never the presenter's
  conversation. A run is in memory, so one started before a restart is
  `lost`, which the app shows rather than a screen that no longer moves.

The box's methods belong to the workspace work (task t-ies2341h). This
branch calls them, and answers `not-ready`/`box-methods-missing` when
they are not there; the host placement above is the whole flow without
them, so the review works and says what it cannot show.

## The walkthrough

A report with a design or a demo gets a generated `walkthrough` brief:
the document's name, summary and first part, the demos with their URLs,
commands, workspaces and narration, and the rules of a presenter -- one
or two sentences a step, wait for the reviewer, change nothing.

`[Walkthrough]` starts a BTW of the task's session, on the task's model,
and sends the brief. Where the voice module is loaded, voice is turned
on first, so the first answer is spoken and the reviewer can interrupt.
The task stays in review throughout: the walkthrough presents, and a
change the reviewer wants goes through the review's feedback and
threads, as any other change does.

## Alternatives

- **Only the diff.** The review would need nothing new, and would keep
  missing the flaws that no line shows. The document is where a
  reviewer sees the shape.
- **Run the demo at hand-in.** Filing the work would have side effects,
  and a broken command would fail the hand-in or hang it. Nothing runs
  until the reviewer asks, and the confirmation says what will run and
  where.
- **A separate design-review tool.** It would give the document a home
  of its own and take it out of the review that already has the
  threads, the changes and the decision. A section thread is the same
  thread list, so the design and the code are read and answered
  together.
- **Render the demo's HTML in the app.** A web demo belongs in a
  browser, on the computer it runs on; drawing the page in the app would
  run its code in another place and show it differently. The app shows
  that computer's screen instead, which is the same pixels the presenter
  clicks.
- **A web view for VNC.** The noVNC page is a client, not the screen;
  an app that embeds it would need a web view, a package and a second
  place that knows the box's address. The app speaks RFB itself over the
  socket the page uses, with the packages it already has.
- **The presenter driving a browser on the reviewer's device.** The
  reviewer's screen is not the demo's; a click there would not move the
  page the reviewer is watching. The presenter drives the computer the
  demo runs on, and the app shows that computer.
- **A new kind of session for the walkthrough.** A BTW is already a
  conversation beside a session, with the same tools, model and
  transcript, and the voice module already speaks one. A new kind
  would duplicate that to gain nothing.

## What this leaves out

A diagram is a Markdown image or ASCII art in the document; there is no
diagram editor, and the picture is read where the report reads Markdown.
The box, its mounts and its VNC endpoint are the workspace work; this
branch calls them and says when they are absent. Emacs cannot draw the
screen: it starts the run and opens the box's noVNC page in the
desktop's browser, and the app is where the screen, the takeover and the
voice are one page. The presenter is a BTW with the task's tools: its
brief tells it not to change the work, the box's methods are the only
ones it drives, and the reviewer is in the conversation to stop it. A
demo command whose server outlives the run is stopped by hand in the
box, since the box offers no way to end one process.
