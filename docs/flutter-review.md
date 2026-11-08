# The change review on the phone

The Flutter app reviews a task's change the way Emacs does: the same threads,
the same drafts, the same revisions and the same marks, kept by the harness.
The app has no comment store of its own. A comment written on a phone is an
operation of the harness's review, read by Emacs and by the agent as any
other; a thread resolved there is resolved here.

This document says what the review is, what the app builds on, what the phone
adds, and what is not there yet.

## What the review is

A task's review is the harness's `change-review` data for the task, read over
ACP, plus the operations a person makes on it:

| Data | Method | What the app does with it |
|---|---|---|
| The set | `patch-review/get` | The task, its versions, its threads, each comment's author, body, time, place and revision, its drafts, and each thread's status history. |
| The files | `patch-review/changes` (added) | The file tree, git's status letter, added and deleted lines, binary and rename flags, the version's revision and base. |
| One file | `patch-review/diff` (added) | The unified patch at that revision, parsed into hunks, lines and both line numbers. |
| The marks | `patch-review/viewed` | Which files are viewed and which are approved, each against the blob it was marked on. |
| An operation | `patch-review/apply` | A comment, a reply, an edit, a deletion, a close, a reopen, a review mark. The harness fills the user, the time and a missing id. |
| The marks set | `patch-review/set-viewed` | Viewed or approved on or off. |
| The replies | `patch-review/send-replies` | A working task's drafts go to its agent as one message. |
| Feedback | `task/reject` | A task waiting for review goes back with its drafts quoted above the words typed. |
| The last close | `patch-review/last-close`, `patch-review/discard-last-close` | The harness's message about the last closed thread, sent or dropped with the replies. |

The two read methods are the only backend addition. They read the task's
repository on the harness's machine -- the phone cannot -- and answer the
same revision the comments record, so a comment made on the phone is pinned
to the commit whose lines were on the screen. No client path or `git` call
goes over the wire.

## What the phone does with it

### The review page

`lib/src/ui/screens/review_screen.dart` is the task's review:

- A summary: `Review` or `Replies` (a task at work), the version and short
  revision, files and their added/deleted lines, files viewed and approved,
  open threads and those closed by someone else whose close has not been
  looked at. The version is a `Versions` menu when the task has more than one:
  `v2 · 9a8b7c6`, `v1 · 0a1b2c3`. An earlier one says `Earlier version`; it is
  read as it was, and has no viewed or approved marks, because a mark of an
  old tree would be a lie about the new one. `New thread` in the summary
  starts a thread on the change as a whole, with no line to pick.
- Two tabs, `Files` and `Threads`, each with its count. They are a
  `HarnessTabStrip`, which scrolls rather than squeezing its labels when the
  screen is narrow or the text is large.
- The file tree, or a flat list, with git's letter, the counts, the thread
  count and the viewed/approved marks on each file. A file is set in one
  step per directory above it, so it reads under the directory that holds
  it; the flat list starts every file at the same edge. The control that
  changes the view is named and drawn as the view it gives: `Flat list`
  with a list icon while the tree shows, `File tree` with a tree icon while
  the flat list shows. A search field filters by path. Directories fold, and
  keep their fold while the review is open.
- The threads on the change as a whole at the end of the list, with their
  own `New thread`.
- A bottom bar with the draft count and one full-width way to the feedback,
  `Feedback` or `Replies`, never a row of small desktop buttons.
- A banner for a newer revision than the one on screen: it says what is
  shown and what is new, and replaces the diff only when `Reload` is tapped.
  Loading, no changes, an error, reconnecting and a notice each have their
  own honest state.

The way in is the task's bar above the message box (`task_bar.dart`):
`Changes, threads and feedback` with `Review`. The bar has the same way as an
icon when the keyboard is up and the bar is one line.

### A file

`lib/src/ui/screens/review_file_screen.dart` shows one file:

- The name and path, the git letter and the counts, the viewed and approved
  marks as labelled pills, and the file's threads as a third pill. `New
  thread` beside them writes about the file as a whole, with no line picked:
  the place it records is the file.
- Next and previous file in the header. They step over approved files while
  `Skip approved` is on, and wrap round the list.
- The diff (`review_diff_view.dart`): unified on a phone, with an optional
  split view only when the window is at least 700 points wide. Hunk headers,
  both line numbers and a readable `+`/`-` prefix; additions and deletions
  have ink of their own, so the meaning does not rest on a tint. With that
  room the controls say what they do (`Comment on lines`, `Wrap lines`,
  `Split view`); on a phone they are icons with tooltips.
- Wrap on or off; off, each line pans horizontally and every visible line
  pans together. Wrap is the deliberate control for long code; the line is
  never clipped without a way to read it.
- Hunk navigation with `Hunk 2/5` between the arrows, so the reader knows
  where they are. The scroll position and hunk of each file are kept while
  the review is open.
- Thread markers where their line is, in the file, collapsed to a summary;
  tapping one opens the thread. A comment whose revision is earlier than the
  diff's is not drawn against lines it never saw.
- Long-press or `Select lines`, then tap the other end of a range:
  `Comment` opens the composer with the range, its excerpt and the revision.
  A saved comment records all three. A new comment on an approved file takes
  the approval off, as Emacs does.
- A binary file says `Binary file` / `No text diff`; a deletion shows its
  removed lines; a rename shows both paths; an empty diff says `No changes`.

### A thread

`lib/src/ui/screens/review_thread_screen.dart` shows a conversation:

- Every comment with its author, its time and its place, the thread's status
  and revision, and the close's own state (`To review` until looked at).
- `Reply` on a comment answers that comment; `Quote` puts its words, quoted,
  in the box; `Reply` under the box sends nothing yet -- it saves a draft,
  which goes with the feedback or the replies. The box is part of the page
  body, so the keyboard lifts it rather than covering it.
- `Resolve` and `Reopen`; `Mark reviewed` for a close by someone else. A
  closed thread stays readable, and a reply to it opens it again.
- Long replies fold to a few lines with `Show more`; a long conversation
  keeps its first comment and last three, with `N earlier replies`.
- Next and previous thread in the header, in the order the list shows.
- `Feedback` opens the same page as the review's bottom bar.

### A reply in the conversation

The same reply form is in the conversation itself, where the harness keeps
threads too: a message of the user's may hold a reply's data in its blocks,
and an agent writes a reply as a `<thread>` block in its message. Both draw
as a card in the message -- the quote, whose words it is, the answer under
it, and the thread's `Open` or `Closed` state -- never as the raw tags.
`lib/src/models/chat_thread.dart` reads the strict form the harness reads:
lowercase tags, `id` and `status` in double quotes, an optional `<quote>`
first, no wrapper tag, and no block inside code. The body of a message keeps
the words around its replies; a reply's words are the card's, and are not
drawn twice.

- `Reply` on a message starts a new thread with that message quoted: its
  words, its node and its session. `Reply to thread` answers an existing one
  and sends its id; a reply of the user's quotes what its card quotes, as the
  Emacs chat does, and an agent's answer quotes the answer itself.
- The bar over the composer names what is answered (`Reply · Message · Agent`)
  and shows the start of the quote; `Cancel reply` writes a message of one's
  own again. The bar and the quoted target are kept in `SessionController`, so
  they survive opening a page and coming back, and a send that fails leaves
  them for the next try. A second reply replaces the first: only one target
  can go out.
- On a phone held upright at twice the text, the box gives the keyboard its
  room: the bar keeps one line (`Reply · Message`) with the quote one tap
  away, the field stops at two lines and scrolls, and the plan and the
  settings step back until the keyboard goes. A message of one's own says
  `Message`; the controls take a row of their own under the field, which
  keeps the width for words. `test/message_composer_layout_test.dart` holds
  the width and wrapping, and measures the box on the page at 320 and 360
  points.
- Tapping a quote in a card shows the message it is of: the transcript
  scrolls it into view. A quote from another session says `Another session`;
  a quote of a review comment opens its thread, and a quote of a change opens
  the file at the revision it was read at. A card's `Open thread` opens the
  thread in the task's review when the session is a task's.
- A long quote folds after four lines or some of its words with `Show more`,
  and a long answer after some of it; both open to all of it with `Show less`,
  as a review reply does. The cards are buttons for a reader: the quote has
  `Show message`, and the actions say `Reply`, `Reply to thread`, `Open
  thread` and `Cancel reply`.
- The block the app sends is the harness's own: one text block whose text is
  the answer and whose `_harness.thread` holds `refs` and, for an existing
  thread, `id`. The harness makes it the comment of the review as it makes
  the Emacs chat's reply; the app has no comment store.

### Feedback

`lib/src/ui/widgets/review_composer.dart` holds the comment composer and the
feedback page:

- The composer is a page whose bottom bar is in its body: with the keyboard
  up, both the field and `Save` stay above it. The field grows to six lines
  and scrolls; its text is the draft from the first keystroke, so leaving the
  page and coming back finds it.
- The feedback page lists the drafts (including the harness's last close),
  the words box, and `Send feedback` or `Send replies` full width. A tap
  while a send is in flight is refused by the controller, not just by a
  disabled button. Drafts and the words go out once; an empty page says
  `Nothing to send`.

### Drafts and the connection

Drafts live in the app, not in a page. `ReviewController` binds each to its
task, thread and revision; `AppController` keeps them for a task across the
controllers a connection makes. A dropped connection therefore loses no
typed words; when it comes back, the harness's comments and drafts are read
again, and the local drafts are still there. A send that fails leaves the
draft in place with the harness's reason on the page. A reconnect never
resends an operation by itself.

The controller also guards every operation: a second `send` while one is in
flight returns without doing anything, an operation already saved can be
retried without adding a second comment (the client id is the comment id),
and a save that finds a newer revision shows it rather than moving the
comment to it.

### Late answers and the revision

A review is read over a connection that answers in any order, while the
person chooses versions, refreshes and reconnects. Nothing that comes back
for an earlier state is allowed to land on a newer one:

- A diff is keyed by the revision **and** the path, so the same path at two
  versions is two files, and a rename is read at the path it has now. A
  request is identified with the generation of the review read that began
  it; a success, a failure and their cleanup check that identity before
  they touch the cache, the loading set or the error map. A stale answer is
  refused with `ReviewStale` and the diff page asks again for the revision
  it shows. Changing the version, loading again, reconnecting or disposing
  the page invalidates the requests that were out.
- A quiet refresh captures the read that began it and the version chosen at
  that moment, and applies the set, marks, files and navigation only if both
  are still current. An older refresh cannot undo a newer version choice.
  Threads read back after a comment take the same guard.
- A comment is anchored to the diff that was on screen, not to the
  controller's current selection: the diff view passes its own
  `ReviewFileDiff` to the composer, which takes the revision and excerpt from
  it. Draft keys include the revision, so the same line in another version is
  another draft; the words typed for one are never sent against the other.
- A failed version choice restores the version whose files are still shown
  and leaves every draft where it was written. A comment on an earlier
  version does not take the newest file's approval off.

## Copy inventory

Every string the review adds is a heading, a label, a tooltip or a state
word: a noun, a noun phrase or an adjective, never a sentence. The words
below are the ones the widget tests assert (`review_screen_test.dart`,
`review_model_test.dart`); a changed word is a changed test.

| Where | Copy |
|---|---|
| Task bar | `Changes, threads and feedback`, `Review` |
| Review heading | `Review`, `Replies`, `Revision 9a8b7c6`, `v2 · 9a8b7c6`, `34 files · +556 −120`, `2/34 viewed`, `1/34 approved`, `4 open · 1 to review`, `New thread` |
| Tabs, filters, menus | `Files`, `Threads`, `All`, `Open`, `To review`, `Closed`, `Drafts`, `File tree`, `Flat list`, `Skip approved: on`, `Skip approved: off`, `Review`, `Reload`, `Report` |
| Tooltips | `Search files`, `Hide file search`, `Refresh review`, `Review actions`, `Previous file`, `Next file`, `Select lines`, `Wrap lines`, `No wrap`, `Split view`, `Unified view`, `Previous hunk`, `Next hunk`, `Previous thread`, `Next thread` |
| File status and marks | `Added`, `Deleted`, `Modified`, `Renamed`, `Copied`, `Type changed`, `Viewed`, `Not viewed`, `Approved`, `Not approved`, `Threads`, `New thread`, `Binary file`, `No text diff`, `Earlier revision` |
| Diff | `Comment on lines`, `Wrap lines`, `No wrap`, `Split view`, `Unified view`, `Hunk 1/2`, `Line 42`, `Lines 40–42`, `Added line 42`, `Deleted line 38`, `End of file marker`, `Loading diff`, `Diff unavailable`, `No diff`, `No changes in this file`, `Retry` |
| Threads | `Reply`, `Quote`, `Edit`, `Delete`, `Resolve`, `Reopen`, `Mark reviewed`, `To review`, `Show more`, `Show less`, `1 earlier reply`, `5 earlier replies`, `Show in the diff`, `Send`, `Drop`, `Draft`, `Last thread closed` |
| Conversation replies | `Thread`, `New thread`, `Open`, `Closed`, `Reply`, `Reply to thread`, `Open thread`, `Cancel reply`, `Show more`, `Show less`, `Message`, `Agent`, `You`, `Plan`, `Thinking`, `Tool call`, `Hand-in report`, `Change`, `Buffer`, `Another session`, `No message`, `No change`, `No review thread` |
| Versions | `Versions`, `Earlier version`, `v1 · 0a1b2c3`, `Revision 9a8b7c6` |
| Composer and feedback | `Comment`, `Draft`, `Save`, `Cancel`, `Delete draft`, `Drafts`, `Words`, `Markdown`, `Replies only`, `Send feedback`, `Send replies`, `Task back · drafts attached`, `Nothing to send`, `No drafts`, `No comments`, `No words` |
| Review states | `Loading review`, `No changes`, `No changed files`, `No files`, `No matching file`, `No threads`, `No threads on the change`, `No ${filter} threads`, `Review unavailable`, `Review closed`, `Reconnecting`, `New revision`, `Shown v2 · new aaaaaaa` |
| Notices | `Feedback sent`, `1 reply sent`, `5 replies sent`, `Replies sent · last close`, `Last close · sent`, `Last close dropped`, `Thread resolved`, `Thread reopened`, `Marked reviewed`, `Viewed theme.dart`, `Not viewed theme.dart`, `Approved theme.dart`, `Not approved theme.dart`, `Approval off · new comment`, `Draft deleted`, `Revision loaded` |

A server's error text is data: it is shown as the harness wrote it, not
rewritten into a noun phrase.

## Parity

| Emacs (Ediff/threads) | Flutter | Notes |
|---|---|---|
| Read the change file by file at a revision | Yes | `Files` tab, counts and status. |
| Read one file's hunks and both line numbers | Yes | Unified; split on a wide window. |
| Jump to the next/previous file | Yes | Wraps; skips approved files when the mark says so. |
| Jump to a hunk | Yes | `Hunk n/m`, arrows. |
| Comment on a line or a range | Yes | Long-press or `Select lines`; excerpt and revision recorded. |
| Reply to a comment | Yes | `Reply` sets `reply-to` to that comment. |
| Quote a comment | Yes | Markdown quote in the draft. |
| Resolve, reopen, mark a close reviewed | Yes | Through `set-status`, `mark-reviewed`, `unmark-reviewed`. |
| Closed threads stay readable | Yes | All filters and the thread page. |
| Threads on the change as a whole | Yes | At the end of the files, and a group in the threads tab. |
| View and approve a file | Yes | Separate marks, named; approval withdrawn by a new comment. |
| Skip approved files | Yes | On by default; the count is in the summary. |
| Kind/binary/rename/deleted file | Named | Binary has no preview; a rename names both paths. |
| Feedback, including replies without words | Yes | `task/reject` for a task in review, `send-replies` at work. |
| The last-close message | Yes | Listed as a draft and sent or dropped. |
| A newer revision | Offered, not forced | `New revision` banner, `Reload`. |
| Earlier-revision comments | Read, not drawn on the new lines | Labelled `Earlier revision` and kept at their own place. |
| Ediff control panel | Not applicable | The page's own controls are the panel. |
| A version picker / older versions | Yes | `Versions` reads a version as it was; an earlier one is read, not marked viewed or approved, and a comment made there is pinned to it. |
| A reply in a conversation thread | Yes | Cards from the user's blocks and the agent's `<thread>`; `Reply` and `Reply to thread`; navigation to the quoted message. |
| A word-level (refinement) diff | No | Whole-line additions and deletions only. |
| Thread status history as a list | No | The current status and the close's reviewed state are shown; the history is in the data. |
| Bulk "assume viewed" | No | Marks are made file by file. |
| Pictures inside a diff | No | A binary file is named, not drawn. |

## Known gaps and coordination

- **One palette.** The app's light theme is, at this commit, the same dark
  palette as its dark theme (`HarnessTheme.material` builds a dark scheme for
  both; the README still calls them both themes). The review uses only theme
  colours, and its own ink has light variants (`ReviewStyle`), so it will
  read in a light theme when the app has one. This is an app-level design
  question, not a review one; changing the whole palette here would change
  every screen and every screenshot.
- **No word-level diff.** Additions and deletions are whole lines. A
  refined, Ediff-style word comparison would need a parser on both sides.
- **History.** Threads carry their status history; the page shows the current
  state and the close, not the whole log.
- **No image diff or rich binary preview.** A binary file is an honest
  placeholder.
- **Huge patches.** The list builds only what is visible and the parser is
  linear; a 4,000-line patch parses and draws without a stall. A patch of
  hundreds of thousands of lines is not paginated server-side.

## Verification

- Unit and widget tests: `flutter test test/review_model_test.dart
  test/review_race_test.dart test/review_screen_test.dart` -- the model's
  parser and tree; delayed answers for a version no longer shown, a stale
  failure, old cleanup against a newer request, a refresh across a version
  choice and across a reconnect; and the page
  at 320, 390 and 900 points, at text scale 2, with the keyboard, selected
  ranges, drafts across navigation and reconnect, two clients, the stale
  revision, binary and rename files, a version change under the diff, a
  4,000-line diff, and the exact copy of each state.
- Pictures: `HARNESS_SHOTS=screenshots flutter test
  test/review_screenshots_test.dart` writes `screenshots/review-files.png`,
  `review-diff.png`, `review-comment-keyboard.png`,
  `review-thread-keyboard.png`, `review-wide-split.png`,
  `review-new-thread.png`, `review-320-text2.png` and `review-task-bar.png`,
  drawn with the fonts of a phone.
- Conversation replies: `test/chat_thread_test.dart` for the strict form, the
  `<thread>` data of a message, a local echo, the reply's data and the card at
  320 points and twice the text; `test/chat_thread_screen_test.dart` for a
  card read from the harness, answering a message, answering a thread,
  switching the target, the words and the target across navigation, and the
  exact block each send carries. `HARNESS_SHOTS=screenshots flutter test
  test/chat_thread_screenshots_test.dart` writes `chat-thread-360.png`,
  `chat-thread-320-text2.png`, `chat-reply-keyboard.png`,
  `chat-reply-keyboard-320-text2.png`,
  `chat-reply-keyboard-360-text2.png`, `chat-reply-360-text2.png`,
  `chat-composer-keyboard-360-text2.png` and `chat-thread-wide.png`.
  `test/message_composer_layout_test.dart` is the portable check: the field
  keeps the width of a 320- or 360-point phone, a placeholder and a sentence
  break at words, the keyboard lifts the box, and a long message scrolls
  rather than growing the page.
- The real harness: `tool/with_real_harness.sh flutter test
  test/review_real_harness_test.dart` creates a task whose branch is
  committed to, reads its files and patch, writes a comment pinned to that
  revision, reads it from a second client, reconnects and reads it again,
  closes it, and sends a draft with no words as feedback once. It refuses a
  fixture that is not an empty directory outside a repository, so it never
  writes in a checkout.
- The harness's own tests: `scripts/test.sh lisp/modules/harness-patch-review-test.el`
  covers the two new read methods, a rename, a path that leaves the
  repository, and the identity the harness fills for a UI's operations.
