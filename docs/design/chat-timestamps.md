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

- **A pinned time in the header line.**  A chat's header line is the one
  part of the buffer every window always shows.  It gains a segment, after
  the session's name and where it came from, with the time of the first
  message the window shows.  It is the message's own time, not its
  group's, so scrolling through a long turn keeps saying when the thing
  at the top happened.  It is hidden when that message already shows its
  own timestamp on the line the window starts on, and when no message
  shows, so nothing is said twice.

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

The header reads those properties at `(window-start)` of the window whose
header line is being drawn.  Redisplay binds `selected-window` to that
window while it evaluates a `:eval` mode or header line, so a window
scrolled to a different part of the same session gets its own time.  When
the start is above the first message — a transcript shorter than its
window starts on the blank room the compose box's padding makes — the
first message's property is found by walking to the next one; that walk
is over blank lines, not the transcript.  The header never measures the
window, which a header line must not do (`harness-chat--at-bottom-p`).

## Alternatives

- **A time on every message.**  Precise, but a turn of thirty tool calls
  and four messages reads as a wall of clocks.  Grouping by elapsed time
  keeps the precision for anything more than a few minutes apart and
  drops it where it adds nothing.
- **Day separators only.**  The usual chat pattern, but it says nothing
  about a long turn, which is the case this is for.
- **A sticky line drawn inside the transcript.**  Emacs has no overlay
  pinned to the top of a window; the header line is the surface that is
  always visible, and the chat's already carries the session's figures.
  A segment there needs no scroll hook and no overlay.
- **The group's timestamp in the header rather than the message's.**  It
  would repeat the last marker instead of saying when the message at the
  top was sent, which leaves the long turn's middle as undated as before.
- **The Flutter client's transcript.**  The same idea fits its session
  page, but the Emacs chat is the session history this change is about:
  it is where a task's session is read and reviewed.  The client's model
  already carries each item's timestamp, so a later change there can use
  the same rules without touching this one.

## Interface copy

- Visible text: the clock (`14:05`), or `Nov 7 14:05` for another day and
  `2026-11-07 14:05` for another year — data, not prose.
- Sender-line time tooltip: `Message time: 2026-11-07 14:05:12`.
- Pinned time tooltip: `First message on screen: 2026-11-07 14:05:12`.
- The setting's description is prose, as setting descriptions are.

No headings, buttons, empty or loading states are added.

## Tests

`test/harness-ui-chat-test.el` covers, with exact rendered text:

- messages within the interval share one timestamp, and the next group
  starts on the first message after it;
- the time's face and its whole-time tooltip;
- the pinned segment of a window at a user's timestamp (none), inside a
  group (the message's time), at an agent line (its time), and with no
  transcript (none);
- the clock/day/year forms and the full tooltip form;
- a coalesced run carrying its first call's time on the agent line, with
  the pinned segment only once that line scrolled away.

`scripts/test.sh --changed` covers the suites the change touches, and the
full `scripts/test.sh` runs before the work is handed in.
