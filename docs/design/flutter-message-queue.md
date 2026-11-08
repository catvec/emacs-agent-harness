# Queuing a message in the Flutter client

Design note, November 2026. **Implemented in the Flutter client.** This page
is the design for a conversation whose agent is at work and whose next message
is written meanwhile: the message waits for the next turn rather than being
refused, and can be sent sooner, rewritten or dropped.

## The problem

The chat's box took a message only while no turn ran: `SessionController.send`
returns early when `promptInFlight` is set, and the composer's send button is
replaced by *Stop* for the duration of a turn. The harness has held messages
for the next turn all along (`session/queue`), sends them as a turn of its own
when the running one ends (`harness-agent--send-queued`), and announces every
change of the queue (`session/queue-changed`). The app used none of it: a
message typed while the agent worked could not be sent at all, and a message
queued from Emacs or another device was invisible.

## What the harness already decides

The client adds no queue of its own and no timer that sends one. The queue is
the session's record:

- `session/queue ID TEXT` puts an item in it and answers the item, with its id.
- A turn that ends `end-turn` sends the whole queue as one turn of its own. A
  cancelled or failed turn leaves it waiting.
- `agent/send-queue SESSION-ID [QIDS]` sends all of it, or only the named
  items, now. With no turn running that is a turn of its own; while one runs
  the items steer it, and reach the model at its next step.
- `session/queue-remove ID QID` drops an item, and answers what is left.
- `session/queue-changed ID ITEMS` says what the queue holds now, to every
  client, whichever device changed it.

The app therefore queues through `session/queue` (whose answer is the item,
so the strip shows it before the event arrives), sends through
`agent/send-queue` without a timeout (its answer comes when the turn ends),
and follows the queue from `session/queue-changed`, never from a re-read of
the session that could race it.

## The shape in the app

- **The box offers the queue while a turn runs.** *Queue message*, a playlist
  icon beside *Stop*, is enabled by words alone; Enter does the same on a
  desktop. The hint says `Message for the next turn`. When the harness has no
  `session/queue` the button is not offered and the box behaves as before.
- **A strip above the box draws the queue**: `Queue` and its count, `Send all`
  when there are several, then one row per message: `Queued` (and who sent it,
  when another client did), its words, and `Send now`, `Edit`, `Delete`. A
  message with pictures shows `(1 image)` or `(2 images)` where its words
  would be. The rows scroll within a limited height, so a long queue does not
  take the conversation's room.
- **Send now** sends that item alone; the others stay queued. While a turn
  runs the message steers it and waits in the transcript, marked *Queued*, as
  steering messages always have; when none runs it starts a turn.
- **Edit** takes the message out of the queue and puts its words in front of
  what the box holds, as a message that could not be sent goes back. It is not
  offered for an item with pictures: queued attachments are files of the
  harness's machine, and the app's pictures are picked on the device.
- **Delete** drops the item. No undo: the harness keeps no copy of it.
- **What could not be queued goes back to the box**, with the harness's own
  words in the error banner, as a message lost with the connection does. The
  text is never lost silently.
- The strip is shown when nothing else needs the room: an answer to a question
  or a permission takes the screen, and the queue comes back after it.

## What it gives up, and the alternatives

- **Sending into the running turn instead of queueing.** The Emacs chat's
  `C-c C-c` steers the running turn; the app's box refuses that today and its
  voice screen is the one path that sends while the agent works. The queue is
  the requested behaviour and the safer default for a phone: a message read at
  the next step changes the work in flight, one queued for the next turn is a
  new instruction. `Send now` is the one-tap way to steer when that is what
  the person wants, so nothing the Emacs chat offers is unreachable.
- **Queueing while no turn runs.** It is possible in the harness (a message
  waits for a turn that ends), but it is a trap in the app: nothing would send
  it, and a person would see a queue that never moves. The box sends when
  idle, and only the running turn offers the queue. A queue that another
  client left is still drawn, and can be sent or dropped from there.
- **A sheet of the whole queue.** A queue of many messages could be one line,
  `Queue · 3`, that opens a sheet. The strip keeps every message and its
  actions one tap away, which is what a phone's conversation needs; the rows'
  scroll is the cost, and it is bounded to a part of a page.
- **Pictures in the queue.** `session/queue` takes attachments as files of the
  harness's machine, and a phone's picture has to be copied there first; the
  app has no upload method for a prompt's bytes (task pictures go another
  way). The queue button therefore takes words only, and the attach button
  steps aside while the agent works rather than offering a picture the queue
  could not carry. An item with pictures, queued in Emacs, is shown and can be
  sent or dropped, but not edited.

## What is checked

`test/message_queue_test.dart` draws the conversation with the scripted
harness and asserts, exactly:

| State | Copy |
|---|---|
| the strip | `Queue`, `2`, `Queued`, `Send all` |
| an item's actions | `Send now`, `Edit`, `Delete` |
| the box while the agent works | `Message for the next turn`, `Queue message` |
| the strip's meaning | `Queued messages, 2` |
| an item of pictures only | `(1 image)` |
| a harness without the queue | no queue button; `The agent is working…` |

It also drives the behaviour: a message typed while the turn runs leaves the
box and waits in the strip; two messages go out in the order they were added;
`Send now` sends one and leaves the other; `Send all` sends both; `Edit`
brings the words back and empties the queue; `Delete` drops the message; a
`session/queue-changed` from another client appears with its sender; a refused
queue says why and puts the words back; a harness without `session/queue`
offers no queue button.

`test/message_composer_layout_test.dart` checks the queue button and *Stop*
fit at 320 and 360 points, that nothing is queued with an empty box, and that
what was typed is cleared once it is queued. The pictures are
`screenshots/android-message-queue.png` and
`screenshots/message-queue-320-text2.png`, drawn by
`test/message_queue_screenshots_test.dart`.
