# The workspace's model and what it is doing

## The problem

A workspace episode runs a model, and a turn spends most of its time
waiting for that model: the first token after a message, a long think,
a tool input being written, a tool running.  The workspace chat named
neither.  Its header said `Running`, its thread rows said `Running`, and
nothing said which model was running or whether the turn was still
waiting for the model to answer.  A user who sent a message into a
workspace saw no answer and no activity, and could not tell a slow
model from a stopped thread.  The Flutter workspace named neither
either, although its conversation screen already had both the model and
an activity bar.

The design's settings line ([workspace mode: implementation
design](workspace-mode-implementation.md#emacs-one-buffer-three-regions))
already asked for the chat's settings under the workspace box, and its
copy inventory already listed activity words; the first slice did not
draw them.

## What the workspace now shows

- **The model**, always.  Under the compose box is the chat's settings
  line: model, thinking level, permission mode, the interactive switch,
  and, while an episode is live, what it has used (the context and what
  the episode cost).  The same line is the chat's; its buttons run the
  same commands.
- **Change it in the app too.**  The Flutter workspace's footer, under
  the message field, carries the model and the permission mode as
  pickers.  With a live episode they change that episode; with none,
  they change the workspace's defaults, which its next episode starts
  with.  The Emacs settings line does the same, as a chat's does.
- **The model before the first episode** too: a workspace with no
  thread, or a thread with none live, names the defaults its next
  episode starts with.
- **What the turn is doing** while it runs: `Waiting for the model…`,
  `Thinking…`, `Writing…`, `Compacting the conversation…`,
  `Preparing <tool>…`, `Checking permission for <tool>…`,
  `Running <tool>…`, or `Working…` from a harness that reports no
  activity.  The header puts it after the state (`Running · Thinking…`),
  a thread row shows it in place of `Running`, the Emacs workspace
  draws it above the compose box where the person types -- the header
  and the rail scroll away with a long timeline -- and the Flutter
  screen puts it above the composer as a chat does.
- **Loading at once**: sending a message marks the thread running and
  waiting for the model before the harness's first activity arrives, so
  the words appear with the message, not a round trip later.
- The page's own `Loading…` state is unchanged.

## The shape of the change

### Harness view

`workspace/get` and `workspace/list` already read each live thread's
session.  The view now adds, to every thread:

- `:activity`: the live episode's `agent/activity` while it runs, else
  nil.  `agent/activity` says the phase (`waiting`, `thinking`,
  `writing`, `tool-input`, `compacting`, `tool`), its tool and title,
  how many tools, and since when.
- `:model`, `:thinking`, `:permission-mode`, `:non-interactive`: the
  live episode's own, else the workspace's defaults.  The defaults are
  resolved where the episode would start them: the workspace's own
  model, then `harness-workspace-model` and its neighbours, then the
  harness's configured options at the workspace root.
- The workspace record itself carries the resolved `:model`,
  `:thinking`, `:permission-mode` and `:non-interactive`, so a client
  can name them before its first thread exists.

The extra fields are additive; older clients ignore them.  Nothing is
persisted that was not before: the view is a copy.

### Emacs

- The settings line is drawn under the compose box by
  `harness-ui-settings-line`, the component the chat and the task board
  use.  The model, thinking level, permission mode and interactive
  switch are buttons of `harness-ui-setting-specs`; the context and the
  cost are figures from `harness-ui-format-context` and
  `harness-ui-format-spend`.  It is fitted to the narrowest window that
  shows the buffer, as the chat's is.
- `harness-ui-setting-target-function` is buffer-local.  With a live
  episode, a setting changes that session (the shared commands and
  model picker do the rest).  Without one, the target is the workspace
  defaults, changed through `workspace/update` and applied to the next
  episode.
- The header, the thread rows and the line above the compose box use
  `harness-chat--activity-text`, so the workspace and a chat word
  activity the same way.  A running turn with no activity yet says
  `Working…`, as the chat's line does; the line is drawn only while the
  selected thread runs.
- `_harness/activity` session updates merge into the thread at once, so
  a phase change redraws without a workspace fetch; `_harness/session`
  updates merge a model, thinking or permission change.
- `workspace/get`'s new fields fill a view opened mid-turn.

### Flutter

- `WorkspaceSummary` and `WorkspaceThread` parse the new fields,
  `TurnActivity` included.
- The desktop subtitle adds the model after the state
  (`Kitchen renovation · Running · scripted · 12 notes`); a phone's
  status row has it on the right.
- A footer under the workspace message field carries two pickers: the
  model and the permission mode.  It is the chat's footer's shape; a
  live episode is changed through `session/set_model` and
  `session/set_mode`, a thread with no episode through `workspace/update`.
  Without a connection the values only show.
- The conversation's activity bar is now a shared widget
  (`ActivityBar`, `lib/src/ui/widgets/activity_bar.dart`), used above
  the session composer and above the workspace composer.  A send with
  no activity yet reads `Waiting for the model`.
- A tool's label now leads with `Running` (`Running Read file`) so a
  bar says what is happening, not only the tool's name.
- The activity bar's spinner and its one-second clock run only while
  there is an elapsed time to show, so a static preview draws no
  animation and the widget tests settle.

## Copy inventory

The line and the activity words are nouns and noun phrases, or the
participles the chat already uses; no new sentence is interface copy.
The exact strings asserted in the tests:

| String | Where |
|---|---|
| `<model label>`, e.g. `scripted (Demo)`, `DeepSeek Flash (DeepSeek)` | settings line |
| `<thinking icon> medium`, `<thinking icon> default` | settings line |
| `Auto` / `Ask` / `Accept Edits` / `YOLO` | settings line |
| `interactive` / `non-interactive` | settings line, when on |
| `12.3k/200k` | settings line, live episode |
| `$0.420` | settings line, live episode |
| `Waiting for the model…` | header, thread row, line above the box, activity bar |
| `Thinking…` / `Writing…` | header, thread row, line above the box, activity bar |
| `Working…` | line above the box, when a running turn reports no activity |
| `Compacting the conversation…` | header, thread row, line above the box, activity bar |
| `Preparing <tool>…` / `Running <tool>…` / `Checking permission for <tool>…` | header, thread row, line above the box, activity bar |
| `Running Read file` | Flutter activity bar, tool phase |
| `Working` | Flutter activity bar, running with no activity |
| `Waiting for the model` | Flutter activity bar, a send in flight |
| `Model` / `Permission mode` | picker menu titles |
| `Model · <error>` / `Permission · <error>` | a failed change's snackbar (the error is the harness's data) |
| `Change model` / `The harness takes provider:model.` / `Use model` | the chat's fallback model prompt, when the harness lists no models |
| `Model of this thread` / `Model of this workspace` | model button tooltip |
| `Thinking level of this thread` / `... of this workspace` | thinking tooltip |
| `Permission mode of this thread` / `... of this workspace` | permission tooltip |
| `This episode cost $0.420.` | cost figure tooltip |

The page states keep their words: `Loading…` while the workspace is
read, `Workspace · unavailable` and `Retry` on failure, `No threads`,
`No messages`.  Flutter's `Default model` is the fallback label when a
harness does not send a model.

## Alternatives considered

- **Only the header, as another segment.**  It says what runs now, but
  the header is one line that the overflow control shortens, and it
  scrolls away with the timeline.  The settings line is where every
  session already says its model, and it sits under the box the user
  writes in.
- **Only the thread rail.**  A phone hides the rail behind a sheet, and
  a parked thread's line would still need the defaults from somewhere.
- **Fetch `agent/activity` from the client when it renders.**  It works
  for a view that opens once, but not for the phase changes that matter
  (the first token, a tool starting); those are the `_harness/activity`
  updates the chat already consumes.  The view's `:activity` is for the
  first paint; the updates keep it.
- **Draw the model from the UI's session cache only.**  The cache has
  the live episode, but nothing for a parked thread or a workspace with
  no thread yet.  The harness resolves the defaults in one place and
  both clients read them.
- **A new activity vocabulary for the workspace.**  The chat already
  has `Waiting for the model…`, `Thinking…` and the tool labels; a
  second set would make the same turn read differently in two views.

## Tests

- `test/harness-workspace-test.el`: the view's model, permission mode,
  non-interactive switch and activity for a parked thread, a live
  episode and a running turn; the episode's own model wins over the
  workspace default; the workspace record carries the resolved defaults.
- `test/harness-ui-workspace-test.el`: the settings line's exact words
  and tooltips with and without a live episode and with no thread; the
  context and cost figures; the header and row activity words; the
  line above the box, its `Working…` fallback and its absence when the
  turn is idle; the activity and session update paths; the optimistic
  waiting state on send; the settings line's target for the episode and
  for the workspace.
- Flutter `test/workspace_screen_test.dart`: the model in the subtitle
  and the phone status row, the activity bar's thinking, tool and
  loading words, the exact desktop copy, the footer's model and
  permission pickers, and that a live episode changes through
  `session/set_model`/`session/set_mode` while a thread with no episode
  changes the defaults through `workspace/update`.
  `test/workspace_pending_test.dart` reads the model and activity from
  a connected workspace.
  The screenshot cases in `test/workspace_screenshots_test.dart` draw
  the model and the `Running Read file` bar on a phone and a desktop.

## Safety

- No provider, credential or global setting is changed: the line
  changes the selected episode, or the workspace's own defaults when
  there is none, through the same `workspace/update` the settings pages
  use.
- The activity view is read-only and additive.  No transcript, session
  or workspace record is written by drawing it.
- The new lines draw only what the harness already reports; a harness
  without `agent/activity` says `Working` while a turn runs, and a
  harness that sends no model shows the fallback label rather than a
  guess.
