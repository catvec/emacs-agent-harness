# Workspace streaming

A workspace reply is one harness session node.  This document says how
the node reaches the core timeline and the two clients, why a reply
used to appear as only its first word, and what keeps a live stream,
a reload and a transcript replay showing the same complete text.

## The symptom

In the Flutter workspace chat an assistant reply showed one word or
token and then stopped.  The turn ended normally, the thread went
idle, and reading the workspace again after a reconnect showed the
same fragment.  The text was not missing from the session: opening the
episode's transcript showed the whole answer.

## Root cause

Two independent breaks met at the workspace timeline:

1. **The state layer copied the first chunk and never updated it.**
   `harness-agent--stream` opens an assistant node with
   `session/append`, whose content is the first visible chunk.  The
   workspace module only listened to `session/node-added`; it copied
   that chunk into `workspaces/ID.timeline.jsonl` as the message's
   text.  The rest of the stream arrives as `session/node-updated`
   (`:transient t` per delta, then one final update), which the module
   did not follow.  `workspace/timeline` returned the stored copy, so
   every later read — the end of the turn, a reconnect, a restart —
   returned the first chunk.

2. **The Flutter client watched workspace events, not the episode.**
   `AppController` received every `session/update`, but kept only the
   session record from it.  `WorkspaceController` reloaded the whole
   timeline on `workspace/*` events and had no path for
   `agent_message_chunk` or `_harness/node`.  Nothing accumulated
   between reloads, and the reload at the end of the turn returned the
   fragment from (1).

The event order adds one trap: the opening node is announced on
`session/node-added` (as `_harness/node` with the first chunk), and the
same chunk is then emitted on `agent/stream`.  A client that appends
every chunk to an entry it already has would show the first word twice.

## Reproduction, before the fix

A demo-provider reply of three text chunks (`The `, `quote `,
`is open.`) and two thinking chunks produced these timeline reads at
each `agent/stream` event:

```
delta            timeline message
"The "           "The "
"quote "         "The "
"is open."       "The "
```

The deltas were right and the stored message never moved.  After the
fix the same test reads `The `, `The quote `, `The quote is open.`,
and the complete message after a fresh process loads the session.

## What the fix does

### Harness state (`lisp/modules/harness-workspace.el`)

- A timeline message entry still records its `:episode` and `:node`.
  The node is the transcript's own copy of the words, so
  `workspace/timeline` and the recent messages a brief quotes resolve
  a message's text from `session/node` when the entry is read.  The
  stored text remains the fallback for a node whose session was
  deleted or whose read fails.
- `session/node-updated` is followed for the final assistant node, so
  a thread's `:summary` is the complete last reply instead of the
  first chunk.  Transient updates are not written to the timeline and
  do not emit a workspace event: they are already on the episode's
  ACP stream.
- The timeline file stays append-only.  No message entry is rewritten
  and no revision record is added; the session node is the source of
  truth, exactly as the workspace design describes.

### Flutter client (`harness_client/lib/src`)

- `WorkspaceEntry` carries the `node` id and whether it is still
  `streaming`.
- `AppController` forwards each `session/update` to
  `WorkspaceController.applySessionUpdate`.
- The controller learns episode → thread routing from the loaded
  timeline, the threads' live episodes, `workspace/episode-changed`,
  `workspace/thread-changed` and `workspace/timeline-appended`.  An
  update for a session that is not a workspace episode returns before
  it touches the entry list, so conversations outside the workspace
  are unaffected.
- `agent_message_chunk` is a delta: it is appended to the entry of its
  node.  `_harness/node` is the whole node: it replaces the entry's
  text.  The opening chunk that the entry already holds is recognised
  by the node id and is not appended again.
- `agent_thought_chunk`, `_harness/activity`, tool calls and session
  status are not message text and are ignored.  A workspace reply is
  only the assistant node, never the thinking, the activity or a
  permission card.
- A reload is merged by node id.  A read that began before the newest
  chunk cannot erase words already on screen, and a node is never
  listed twice.  After a reconnect the reload is the replay: the
  server resolves the final text from the node, and the client has one
  complete entry.
- The timeline item is keyed by its node rather than its text, so a
  chunk rebuilds the words in place and does not replay the entry's
  reveal animation on every token.

## Alternatives considered

- **Emit a `workspace/timeline-updated` event with the full text on
  every delta.**  It would make the client a snapshot viewer, but sends
  the growing message again on every token and adds a second stream
  beside the ACP chunks the client already receives.
- **Persist the final text by rewriting the timeline line.**  It
  breaks the append-only log and races a new entry appended while the
  file is read and written.
- **Append a revision record per assistant message.**  It keeps the
  log append-only but duplicates the transcript in the workspace store
  and needs a fold on every read.  The session node already exists.
- **Open the episode's transcript inside the workspace.**  It works,
  but loses the workspace's own thread context and is a different UI,
  not a streaming fix.

## Tests and evidence

- `test/harness-workspace-test.el`: a real multi-chunk demo reply
  (thinking then three text chunks) records the text as each chunk
  arrives, one complete message at the end, a complete thread summary,
  no thinking text, and the same message after a fresh session load.
  Another test keeps two threads' replies apart.
- `harness_client/test/workspace_streaming_test.dart`: the opening node
  plus its first delta are one piece of text; a reply grows in the
  rendered workspace; the final node replaces rather than appends;
  thinking, activity, tool calls and other sessions do not change the
  answer; a stale reload does not erase live text; a reconnect replays
  one complete reply.
- `harness_client/test/workspace_streaming_screenshots_test.dart`:
  rendered frames of one reply arriving in pieces and its final text.
- `harness_client/test/workspace_streaming_real_harness_test.dart`
  (run with `tool/with_real_harness.sh`): the Emacs harness and demo
  provider stream a real multi-chunk workspace reply into the app's
  controller, then replay it whole on reload.

## Limits

- Progressive display needs the live ACP connection; a client that
  connects after the turn read `workspace/timeline` and saw the
  complete text, which is the replay path.
- Thread summaries written before this change stay as they were until
  the thread's next assistant node; the message bubbles themselves are
  resolved from the node as soon as they are read.
- The Emacs workspace buffer still refreshes on workspace events
  rather than per chunk; it shows the complete text when the thread
  changes at the end of the turn.  This change does not add new Emacs
  UI text or keys.

## Overlaps with open workspace work

- **Workspace polish (t-ies2341h)**: no layout, screenshot, tag or
  concept code is changed; the only user-visible difference is that an
  assistant bubble's text continues to grow.
- **Pending action cards (t-pr936o6y)**: the pending and episode-status
  fields, cards and their copy are untouched.  This work adds `node`
  and `streaming` to a timeline message and leaves the thread model
  alone; a chunk for a blocked episode can still carry the text that
  preceded the request, and the card remains a separate surface.
- **Connection and transcript performance (t-xywzvi9m)**:
  `session_controller.dart`, `transcript.dart` and the transcript load
  paths are not changed.  `AppController` gains one forwarding line for
  workspace episodes; every other session's update returns at the
  episode→thread map before scanning entries.  The server resolves
  message text only for the page `workspace/timeline` returns, not the
  whole log.
