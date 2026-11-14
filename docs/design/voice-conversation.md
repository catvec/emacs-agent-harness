# The voice conversation and the message it sends

Design note, November 2026.  This page separates two records that live
voice keeps: the **voice conversation** (what was said and heard on the
audio side) and the **session message** (what crosses into the chat).
It states what happens to a transcript between the sidecar and
`session/prompt`, and why the second record is the first one's words,
unchanged.

## Superseded: the distilled request

An earlier version of this page described a different design.  A local,
deterministic step rewrote every transcript before it crossed into the
chat: `harness-voice-distilled-text` removed hesitation sounds (`um`,
`uh`, `er`), comma-set discourse markers (`, like,`), stutters and
repeated starts, non-speech annotations and an explicit `no wait, X`
self-correction.  A second step,
`harness-voice-conversation-request`, prepended a plain-text
`Voice conversation before this request:` block -- up to four earlier
turns -- when the request looked dependent, matching pronouns (`it`,
`that`, `the second one`), continuations (`also`, `then`) and answers
(`yes`, `okay`).

Neither step called a model: both were local regexps and word sets.  But
both changed what the person said before the session's own agent read
it, and the block repeated earlier turns the session already had.  That
is the behaviour this change removes.  The rest of this page describes
what replaced it.

## Decision

### The transcript is the message

The session message is the transcript as the speech model returned it.
Nothing is removed from it and nothing is added to it: no distillation,
no context envelope, no meta-instruction and no interpretation model.
The session's own agent reads the words in the conversation it is
already in, so it is the only reader that can tell which earlier turn a
pronoun points at and which hesitation carries no request.  A rewrite
before the agent sees the words takes that judgement away from the one
place that has the conversation.

The timing now follows [voice turn completion](voice-turn-completion.md):
audio chunks enter an unsent conversational turn, ordinary endings get a
1.2-second grace period, and explicit continuation intent or a possible cut-off
holds the thought until it is completed or released. No interpretation model
is added. The full reasoning about where the words go -- one route, its
generation and the shared pipeline -- is in [the routing
design](live-voice-routing.md).

### The voice conversation

The voice conversation is the audio-side record of one live call:

- captions of user utterances **as the speech model returned them**, and a
  committed turn's `raw`/`sent` record when its words cross into the session;
  adjacent chunks can form one request, while a recovery cue stays only in
  the audio-side captions;
- every line the voice actually spoke: spoken commentary, a spoken
  result, a backchannel, or the provider's own transcript line.

It is kept by the client that owns the call (the Emacs live transport, or
the Flutter `VoiceController`), not by the chat session.  It is bounded
(40 turns by default, each at most 4000 characters), cleared when a call
starts or ends, and never edited back into a transcript that was already
shown.  The voice transcript and the captions are its visible form.

A turn records `raw` and `sent`, and they are the same text.  The two
fields remain because a transcript shown in the voice transcript and a
prompt that crossed into the chat are two different events: a future
provider may deliver a cleaned transcript of its own, and the record has
to be able to say what crossed when that differs.  Today nothing differs,
and the transcript does not draw a `Sent` line for text that is identical
to the caption.

### What crosses, in order

The prompt contains the transcript's words, joining adjacent chunks of the
same unsent thought in order. No held-output, file/line or related-session
block is added, and no other session is looked up for one: the session voice
mode is used in is the context, and a workflow that really spans sessions or
projects belongs to the workspaces feature. A reply superseded by new input
is not replayed or repeated into the request; the session already has the
agent turn that produced it.

A burst the speech model made no words of sends no session prompt and
answers its delegation with empty text, so the sidecar is not left
waiting.  The transcript says `Not sent · no words` beside what was heard,
and the pipeline's burst stops at `dropped · no words`.

### The destination

A call has one destination at a time, recorded as a route (see the
[routing design](live-voice-routing.md)).  A session target receives
`session/prompt`; a workspace target receives `_harness/workspace/prompt`
with the thread, so the workspace's own agent puts the words in that
thread's live episode.  Moving the destination retargets the running call
rather than restarting it, and a transcript or a reply whose route moved
is dropped rather than delivered to the wrong thread.

## The voice conversation is not the session transcript

The session's own transcript already holds the agent's text and the
transcripts it answered.  The voice conversation is the other side of the
same call: what the person actually said and what the voice actually
spoke.  It is per call, not per session: a new call starts a new voice
conversation, while the session keeps its history.  Mute, pause and
interrupt do not clear it; ending or restarting the call does.  It is
bounded so a long call does not grow a second unbounded transcript in
memory.

## Latency and cost

| Step | Cost | Basis |
| --- | --- | --- |
| Transcript → `session/prompt` | ordinary 1.2-second grace; explicit holds have no silence deadline | client-local completion policy; no model call |
| Route lookup | a plist compare | no I/O |
| Held output | a bounded list already in memory | no model |

Consecutive chunks of one unfinished thought now stay together. This
intentionally favors not interrupting the person over the earlier immediate
send policy. Completed turns remain separate session messages.

## Alternatives considered

- **A small model interprets the transcript.**  The most capable option,
  but it adds a network round trip before every request, a second failure
  path, and a place where the person's words can be changed before the
  session sees them.  The session's own agent is already a model with the
  full conversation; adding another before it buys nothing.
- **Keep the deterministic distillation and drop only the context block.**
  Half the report.  The words would still be rewritten before the agent
  read them, and the argument that the agent has the conversation applies
  just as much to `um` as to `it`.
- **Keep the context block and drop only the distillation.**  Sends the
  same earlier turns the session already has, grows with the call, and
  pushes the session's context window toward the audio side's small talk.
- **Immediate delivery versus chunk joining.** The earlier design rejected
  even a 600 ms join window in favor of latency. That decision is superseded
  by [voice turn completion](voice-turn-completion.md): an audio silence
  threshold alone cannot distinguish a breath from a finished thought, and
  asking people to avoid natural pauses is the wrong safety trade-off.
  The new grace period is bounded for ordinary endings, while explicit
  intent to continue remains held regardless of elapsed silence.
- **A fixed request envelope.**  A stable `<voice-request>` block would be
  easy to parse in a test and wrong for a chat: it costs tokens on every
  turn, makes an ordinary request look like an event, and adds a format the
  agent has to be taught.
- **Let the sidecar interpret.**  It belongs to the provider: GPT-Live has a
  conversation model, the local pipeline has only an STT service.  A client
  rule would make the two behave differently, and a chat format does not
  belong in the audio process.
- **Restart the call when the destination moves.**  Costs a microphone
  reopen and a pipeline start for what is a pointer change; the reported
  120-second stop/start was this cost being paid on a shared pipeline.
  Retargeting keeps the audio path running.

## Shape of the change

`lisp/ui/harness-ui-voice-conversation.el`

- `harness-voice-conversation`: turns, bounded; `-hear` records an
  utterance's raw and sent text (the same text today); `-say` records what
  the voice actually spoke; `-clear` starts a call.
- The distillation section and the request/context section are gone, with
  `harness-voice-distilled-text`, `harness-voice-conversation-request`,
  `harness-voice-conversation-needs-context-p` and their options.

`lisp/ui/harness-ui-voice-live.el`

- One conversation per call, reset on start.
- `harness-voice-live--dispatch` sends the transcript unchanged to the
  route's target; `harness-voice-live--delegate` captures the utterance's
  route and hands it on.
- A burst with no words is answered without a prompt and its pipeline burst
  is marked `dropped · no words`.

`harness_client/lib/src/voice/voice_conversation.dart`

- The same pure rules and bounds in Dart, without the distillation and
  context, wired into `VoiceController._sendPrompt`, so a request composed
  on a phone has the same shape.  `VoiceSegmentDrop.noRequest` became
  `retargeted`, which is now the only reason a client drops a transcript.

Docs and tests

- This page, `docs/voice.md`, `docs/voice-turn-taking.md`,
  `docs/voice-realtime.md`, `docs/voice-pipeline-visualization.md`.
- `lisp/ui/harness-ui-voice-conversation-test.el` (the words are kept as
  heard, nothing is added) and `lisp/ui/harness-ui-voice-live-test.el`
  (the transcript crosses unchanged, and routing through the real
  transport), plus the Flutter `voice_conversation_test.dart` and
  controller tests.
