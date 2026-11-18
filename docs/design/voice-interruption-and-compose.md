# Voice interruption, controls and workspace compose

## Problem

Interrupting live voice could leave Emacs reporting an interrupted call rather
than an open capture path. Held dictation did not recognize “oh, actually send
it” as a release control. A real workspace compose box failed the chat-only
session check with `Live voice compose unavailable`.

## Ownership and recovery

Capture, playback and agent work are independent. An interruption silences the
current answer, not the microphone or the agent. The interruption is a control
event, not a made-up user utterance. No dictation is synthesized to explain a
button press. Explicit **Cancel work** additionally requests cancellation of the
captured agent turn through the supported harness cancellation path. Completion
is not rollback: an already-completed action has happened, and a tool without a
cancellation facility is reported as unavailable rather than as stopped.

The sidecar historically emitted `listening` followed by `interrupted`. Emacs
stored the last event as its call state; its microphone predicate accepted only
`listening` and `speaking`. Interruption must instead be a transient playback
fact with a listening call state. Explicit mute remains authoritative. The wire
`mute.on` boolean must match the UI's mute state, not its inverse.

An interrupted answer stays silent through later text, synthesis and tool
completion. A newer turn gets its own output ownership. Control acknowledgments
must not revive old output or overwrite a newer call/route. Agent control
requests carry a stable turn identity; a stale cancel cannot stop a newer turn.

`agent/activity` supplies the opaque `:turn-id`, including at the initial turn
gate. `agent/voice-control` audits interruption as a hint/control event and
requires that captured token for cancellation. Its result distinguishes
`requested`, `completed`, `stale` and `unavailable`, plus per-tool outcomes.
The client suppresses playback immediately, even while the request settles,
and invalidates late status/tool-label callbacks when ownership changes.

Identity is additive, never a substitute for a phase. A turn held at its gate
has reported no activity, so `agent/activity` returns the `:turn-id` alone and
must not invent a phase: a reader that speaks of what a turn *does* needs a
`:phase`, and one that only needs to address the turn reads `:turn-id`. The
sub-agent note and the tool note both follow that rule, and `:turn-id` joins
`:since` in the fields an exact-shape assertion ignores.

Supported tool cancellation is deliberately narrow: the shared foreground
`bash` handler records its exact `(session, turn, call)` run. A captured
canceller calls the sandbox's existing per-run kill contract, never looks up a
replacement call, and never intentionally tears down background jobs or the
whole session runtime. The existing sandbox fail-safe can still tear down an
unkillable runtime. Unshared/remote commands, provider-built-in actions and
other tools report cancellation unavailable. A delayed permission approval
cannot start work for a cancelled or replaced originating turn.

## Held speech and literal words

Only a whole, unquoted control utterance can release an existing draft.
Decorated forms such as “oh, actually send it” count as controls; their words
stay in audio captions, not in the delivered request. With no draft they remain
ordinary input. Embedded, named, quoted, negated or content-bearing commands
remain genuine dictation. A standalone pause-only segment can hold an existing
draft without becoming request text. A content-bearing segment ending in “hold
on” is preserved unchanged; this change does not guess which of those words
were intended as content.

There is no interpretation model or text distillation. Original dictated
spacing and wording survive, aside from joining separate content chunks with a
single space. Source ordering, deduplication, unresolved-transcription guards
and generation-scoped deadlines keep the prior speech-end contract.

## Workspace integration

A workspace route is `(workspace, thread)`; its live episode may not exist
until the first prompt. Workspace buffers intentionally do not bind a chat
session ID. Live eligibility therefore uses the existing compose and route
contracts rather than a session-ID requirement. WAV spoken replies retain the
chat/session restriction. A workspace message still goes through
`_harness/workspace/prompt`, never through a guessed session.

The first episode also needs timely attachment. `workspace/episode-changed`
carries `(workspace, thread plist, session, divider)` before `agent/turn-started`;
it is not a session event. The old session-ID event guard discarded it, and a
debounced workspace fetch could not catch up in time. The voice client now binds
that payload to the matching route and unresolved delegation before handling
agent events. An unresolved delegation matches no session, not any session.

Workspace identity is `(workspace, thread)`, not the derived episode ID. A
route-generation-scoped resolved-thread value bridges the first message of an
empty workspace until its cache catches up. Speech before or after that fetch
must not retarget the call or drop the pending draft. Explicit thread switches
still invalidate captured input, and a late old-episode event may resolve only
its old delegation, never replace the newly selected route.

### A control line runs before the box it describes

The voice control is a line above the prompt
(`harness-compose-controls-functions`), and `harness-compose-insert` draws
those lines *before* it places `harness-compose-start` and
`harness-compose-end`. A control that asked `harness-compose-live-p` — which
reads exactly those markers — therefore answered no on every draw, and a
workspace bar rendered `Voice · no session` over a box whose Start works. The
bug is invisible to any check that looks at the box after the draw, which is
why it survived the workspace route work.

`harness-compose-host-p` is the predicate a control asks. It is true when the
markers are live, and also for the buffer `harness-compose-insert` is
currently inserting into (`harness-compose--drawing`, bound around the
controls loop only). It stays false for a buffer that merely hides a box
(`harness-compose-hide`), so a control never claims a host that has none.

The alternative — moving the controls loop after the markers are placed —
would put the control line *inside* the box's overlay range and let a
read-only control line sit in the region the draft occupies. The predicate
states the contract instead of reordering the drawing, and keeps
`harness-compose-live-p` meaning what its name says for every caller that
acts on a real box. The regression test takes the box off first, as a
workspace does, so the draw it inspects genuinely has no markers; it fails if
`harness-voice-live--target-p` or `harness-voice--mode-available-p` goes back
to the markers alone.

## Pending-answer coordination

A pre-queue `harness-voice-live-submit-functions` hook arbitrates committed raw
input before recording it as sent or adding it to the agent queue. Its
once-only `CONTINUE` and `COMPLETE` callbacks are invalidated on ownership reset.
This lets the separate permission/question task answer a blocked turn rather
than queue its answer behind that same turn. Jobs include route/source IDs and
playback-overlap captured at speech onset. The hook does not approve anything
by itself. No permission, provider/model configuration or task pause changes.

## Copy-first inventory

No layout, heading/menu redesign or new configuration surface. Existing action
labels remain `Interrupt C-c V`, `Cancel work`, `Mute C-c v`, `Unmute C-c v`,
`Send`, `End`, `Transcript`, `Setup`. Existing tooltips remain
`Playback · interruption` and `Agent turn · cancellation`.

Changed states and control history use these exact noun phrases:

- `Live · Listening` (idle capture after interruption/recovery)
- `Control` (audio transcript heading)
- `Playback interrupted`
- `Cancellation requested`
- `Turn completed`
- `Cancellation stale`
- `Cancellation unavailable`
- `Tool cancellation requested`, `Tool completed`, `Tool cancellation unavailable`

Server error payloads, actual user transcripts and actual model output are data,
not authored UI copy. Regression assertions and live mock screenshots check the
rendered labels/tooltips separately from functional tests.

## Alternatives

Restarting the sidecar on every interruption was rejected: it loses capture and
pending input and can race shared speech services. Treating any barge-in as work
cancellation was also rejected: it changes the existing separate Interrupt /
Cancel work contract, can stop a tool the person only wanted to speak over, and
cannot undo an already-completed external action. Sending a synthetic user
message was rejected because it falsifies the transcript and starts or steers
model work instead of using the supported control path.

## Verification boundary

Tests and the interactive demo use scripted sidecars, fake PCM/devices, mocked
speech services and isolated harness state. No physical phone, microphone,
speaker or ongoing voice call is touched. The demo proves state/control routing
and race handling, not real-world speech recognition accuracy. Focused checks,
final lint and the full committed-tree check are reported separately with
actual outcomes.
