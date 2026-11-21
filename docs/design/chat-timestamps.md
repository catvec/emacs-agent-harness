# A timestamp on every message in the session transcript

## The problem

A session's history says what was said but not when.  A long turn — an
agent reading files, running checks and thinking for twenty minutes —
reads as one stretch with no way to tell whether its last message came
seconds or an hour after its first.

Every message needs its own time, and the transcript must not become a
wall of clocks.  A time after each name would be one: the names are what
the eye reads down, and a clock between two of them interrupts it.

## What the chat does

Two pieces, no setting:

- **A time on every sender line, at the right edge.**  The user's message
  line, the line that opens an agent turn and the line of a message
  another session or the harness sent each show when they were sent.  The
  time is not after the name but at the right edge of the line, so the
  names stay a column of their own and the times line up in another one:
  a column to glance down, out of the way of reading.  It is dim
  (`harness-summary-face`) and its tooltip has the whole date and second.

  A run of coalesced tool calls stands for all of its events, so its
  summary carries the stretch of time they took on the agent line it
  draws: the earliest and the latest of the times it holds — the calls,
  the thinking between them, and the times of the lines a slot-change
  note keeps — as `14:05–14:32`, worked out from the times themselves
  rather than from the order they arrived in.  One reading when both
  ends read the same, and none when no event has a time.  Tool calls and
  assistant text in the middle of a turn carry none: they have no sender
  line, and the turn's line above them gives the context.  The line under
  the header dates one of them when a window starts in the middle of it.

  A line too narrow for its words and the time both draws the time after
  the words: the space that would have put it at the edge collapses, and
  the space before it keeps the two apart.

- **A pinned time on a line under the header.**  The chat's header line
  already carries the session's name, where it came from and its figures;
  adding a clock there made it too full.  The clock of the first message
  the window shows sits on a line of its own, directly under the header,
  in the first row of the window, so scrolling through a long turn keeps
  saying when the thing at the top happened — including through the
  middle of a message, where no sender line is in sight.  It is only the
  clock: the day and year stay on the sender lines, and the header area
  carries no date.  The line is hidden when that message already shows
  its own timestamp on the line the window starts on, and when no message
  shows, so nothing is said twice.  A chat shown in two windows has a
  line in each, each saying what its own window shows.

A time ends `harness-chat--time-inset` columns in from the edge of the
line, on the sender lines and on the pinned line alike, so their columns
of times line up.  There is no setting: every message shows its time
whatever a reader would choose.

## How it is worked out

Each rendered block (`harness-chat-block`) carries `time`, the message's
`:ts` or the last time known before a block the UI made without one, and
`time-head`, whether it has a sender line to show it on.  The transcript
is walked oldest first, keeping the last timestamp seen
(`harness-chat--time-known`):

- a new block notes its time when it is appended (`harness-chat--note-time`);
- a whole render, a page of history added above, blocks dropped above
  every window, a regroup and a block taken out work the transcript out
  again (`harness-chat--refresh-heads`), drawing again only the blocks
  whose marker changed.

Every block's text carries `harness-chat-time` as a text property, and a
block whose sender line shows it also carries `harness-chat-time-head` on
that first line.  A coalesced group's summary text carries the time of
its first member, which is the group's place in the transcript's
timeline; the stretch the summary shows is worked out when it is drawn
(`harness-chat--group-time-range`), so a member that joins the run, or a
note that grows a line, is part of it without any time being noted
again.  The time is drawn by `harness-chat--time-right`, a space whose
`display` is a `(space :align-to (- right N))` spec: Emacs works out the
column at display time, so one rendered block is right on a line in
every window that shows it, whatever the width.  A group's stretch takes
that same space, so its line's times end in the same column as a single
time's.

The time line is a window-specific overlay (`overlay-put` `window`) at
the start of the first whole line the window shows
(`harness-chat--first-whole-line`).  Its `before-string` is the clock
and a rule to the window's right edge, ending in a newline, so it draws
in a row of its own above that line without being buffer text.  It runs
from `pre-redisplay-functions` (`harness-chat--refresh-time-bar`), so it
follows scrolling, resizing and the transcript growing, and it changes
the overlay only when the time or the line it stands on changed.  It is
absent while the message at the top shows its own timestamp, and when no
message shows.  It takes the clock alone (`harness-chat--time-clock`);
the day and year are the sender lines' (`harness-chat--time-label`).

The time is read from the text properties at `(window-start)`, as the
header's time was before it moved: when the start is above the first
message — a transcript shorter than its window starts on the blank room
the compose box's padding makes — the first message's property is found
by walking to the next one; that walk is over blank lines, not the
transcript.  It never measures the window.

## Alternatives

- **The time after each name.**  A time on every message is what the
  transcript needs, but one drawn between the name and the words turns
  the column of names into a row of mixed figures.  At the right edge it
  is still on every message and reads as a column of its own, which the
  eye skips until it wants it.
- **A time on every line of a turn.**  Tool calls and the agent's text in
  the middle of a turn are the bulk of a long turn's lines, and a time on
  each of them is the wall of clocks this is not.  They have no sender
  line, so they carry none; the line under the header dates the one at
  the top of the window.
- **A group timestamp every few minutes.**  The first version showed a
  time only when the message came a setting's seconds after the one
  before it.  It kept the transcript sparse, and left most messages
  undated: a turn's four messages seconds apart said nothing about when
  any of them was sent.
- **Day separators only.**  The usual chat pattern, but it says nothing
  about a long turn, which is the case this is for.
- **The time in the header line.**  The first version put it there, after
  the session's name and origin.  It needed no scroll hook and no overlay,
  and every window had one.  But the header already carries the name, the
  session it came from and the session's figures, and the review found it
  too full; the time moved to a line of its own under it.
- **A sticky line drawn inside the transcript.**  Emacs has no buffer
  text that stays at the top of a window by itself, and text in the
  transcript scrolls.  The time line is therefore an overlay string at
  the start of the first whole line, not buffer text: it takes a row of
  its own above the transcript and leaves no mark in the buffer.
- **A time on the time line alone.**  It dates the message at the top of
  the window and nothing else, which leaves every message scrolled past
  as undated as before.
- **The Flutter client's transcript.**  The same idea fits its session
  page, but the Emacs chat is the session history this change is about:
  it is where a task's session is read and reviewed.  The client's model
  already carries each item's timestamp, so a later change there can use
  the same rules without touching this one.

## Interface copy

- Visible text: the clock (`14:05`), or `Nov 7 14:05` for another day and
  `2026-11-07 14:05` for another year — data, not prose — at the right
  edge of the sender lines; and the clock alone on the pinned line, with
  the rule after it.  The pinned line never shows the date.
- Sender-line time tooltip: `Message time: 2026-11-07 14:05:12`.
- A collapsed run's stretch, in that same sender-line slot:
  `14:05–14:32`, or `Nov 7 23:58–Nov 8 00:03` over a day's turn — data
  again, and one time (`14:05`) when both ends read the same.
- A collapsed run's tooltip: `Message times:
  2026-11-07 14:05:12–2026-11-07 14:32:40`, or `Message time: ...` when
  both ends read the same.
- Pinned-line time tooltip: `First message on screen: 2026-11-07 14:05:12`.
- No setting's description is added: nothing here is prose the reader
  turns off.

No headings, buttons, empty or loading states are added.

## Tests

`lisp/ui/harness-ui-chat-test.el` covers, with exact rendered text:

- every message with a sender line — the user's, the line opening an
  agent turn, a message another session or the harness sent — showing
  its own time, however near the message before it was sent;
- the space that puts it at the right edge, the column every line's time
  ends in, and what a line too narrow for it draws;
- the agent's text in the middle of a turn carrying its time but showing
  none, the line under the header finding it;
- the time's face and its whole-time tooltip;
- the pinned line under the header at a sender line (none, the line has
  its own time), in the middle of a message (that message's time), and
  with no transcript (none);
- the pinned line's own overlay, at the window's first whole line, the
  window it belongs to, and the clock and rule it draws;
- the clock/day/year forms of the sender lines and the full tooltip form;
- the pinned line showing only the clock for a message two days old,
  where the sender line still names the day;
- a coalesced run carrying the stretch of its events on the agent line --
  earliest to latest, from the times themselves rather than their order,
  in the one timestamp slot, at the right edge, with both ends in the
  tooltip -- one reading when both ends read the same, the one known
  time when only one event has one, and nothing when none has; the times
  of the lines a slot-change note keeps are part of the stretch, and the
  day and year of each end are written as a sender line writes them;
- opening and folding the run again keeps its line and its stretch, and a
  member call carries no time of its own;
- a coalesced run's line, with the pinned line only once that line
  scrolled away;
- the delivery notes of a message the turn never took, and of one that
  waits, which the time's place at the edge leaves where they were.

`scripts/test.sh --changed` covers the suites the change touches, and the
full `scripts/test.sh` runs before the work is handed in.
