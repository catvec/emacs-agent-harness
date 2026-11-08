# Grouped timestamps in the session transcript

## The problem

A session's history says what was said but not when.  A long turn — an
agent reading files, running checks and thinking for twenty minutes —
reads as one stretch with no way to tell whether its last message came
seconds or an hour after its first.  A time on every sender line would
answer that and clutter the transcript: most messages in a turn are
seconds apart, and a time on each is noise.

The transcript needs a sparse clock it does not have to be read carefully
to find, and it needs the time to stay in sight while the transcript is
scrolled away from the last one.

## What the chat does

Two pieces, one setting:

- **A group timestamp on a sender line.**  When a message is sent at
  least `harness-chat-time-group` seconds (default 300) after the last
  timestamp shown, its sender line shows the clock.  Messages sent near
  each other share the timestamp before them: one time for a burst of
  messages and a turn's work, a new one every few minutes of a long
  turn.  The time is dim (`harness-summary-face`) and its tooltip has the
  whole date and second.

  Only a line that names a speaker carries one: the user's message line,
  the line that opens an agent turn, and the line of a message another
  session or the harness sent.  A run of coalesced tool calls stands for
  its first call, so its summary carries that call's time on the agent
  line it draws.  Tool calls and assistant text in the middle of a turn
  carry none: the turn's own line already gives the context, and a time
  on every call would be the clutter the grouping is for.

- **A pinned time on a line under the header.**  The chat's header line
  already carries the session's name, where it came from and its figures;
  adding a clock there made it too full.  The clock of the first message
  the window shows — the message's own time, not its group's — sits on a
  line of its own, directly under the header, in the first row of the
  window, so scrolling through a long turn keeps saying when the thing at
  the top happened.  It is only the clock: the day and year stay on the
  sender lines, and the header area carries no date.  The line is hidden
  when that message already shows its own timestamp on the line the
  window starts on, and when no message shows, so nothing is said twice.
  A chat shown in two windows has a line in each, each saying what its
  own window shows.

The setting, `harness-chat-time-group`, is in the `harness-ui-chat`
group.  0 puts a time on every sender line; a larger value groups more.

## How it is worked out

Each rendered block (`harness-chat-block`) carries `time`, the message's
`:ts` or the last time known before a block the UI made without one, and
`time-head`, whether its sender line shows it.  The transcript is walked
oldest first, keeping the last timestamp shown (`harness-chat--time-shown`)
and the last timestamp seen (`harness-chat--time-known`):

- a new block notes its time when it is appended (`harness-chat--note-time`);
- a whole render, a page of history added above, blocks dropped above
  every window, a regroup and a block taken out work the transcript out
  again (`harness-chat--refresh-heads`), drawing again only the blocks
  whose marker changed.

Every block's text carries `harness-chat-time` as a text property, and a
block whose sender line shows it also carries `harness-chat-time-head` on
that first line.  A coalesced group's summary text carries its first
member's.

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

- **A time on every message.**  Precise, but a turn of thirty tool calls
  and four messages reads as a wall of clocks.  Grouping by elapsed time
  keeps the precision for anything more than a few minutes apart and
  drops it where it adds nothing.
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
- **The group's timestamp on the time line rather than the message's.**  It
  would repeat the last marker instead of saying when the message at the
  top was sent, which leaves the long turn's middle as undated as before.
- **The Flutter client's transcript.**  The same idea fits its session
  page, but the Emacs chat is the session history this change is about:
  it is where a task's session is read and reviewed.  The client's model
  already carries each item's timestamp, so a later change there can use
  the same rules without touching this one.

## Interface copy

- Visible text: the clock (`14:05`), or `Nov 7 14:05` for another day and
  `2026-11-07 14:05` for another year — data, not prose — on the sender
  lines; and the clock alone on the pinned line, with the rule after it.
  The pinned line never shows the date.
- Sender-line time tooltip: `Message time: 2026-11-07 14:05:12`.
- Pinned-line time tooltip: `First message on screen: 2026-11-07 14:05:12`.
- The setting's description is prose, as setting descriptions are.

No headings, buttons, empty or loading states are added.

## Tests

`test/harness-ui-chat-test.el` covers, with exact rendered text:

- messages within the interval share one timestamp, and the next group
  starts on the first message after it;
- the time's face and its whole-time tooltip;
- the pinned line under the header at a user's timestamp (none), inside a
  group (the message's time), at an agent line (its time), and with no
  transcript (none);
- the pinned line's own overlay, at the window's first whole line, the
  window it belongs to, and the clock and rule it draws;
- the clock/day/year forms of the sender lines and the full tooltip form;
- the pinned line showing only the clock for a message two days old,
  where the sender line still names the day;
- a coalesced run carrying its first call's time on the agent line, with
  the pinned line only once that line scrolled away.

`scripts/test.sh --changed` covers the suites the change touches, and the
full `scripts/test.sh` runs before the work is handed in.
