# Live voice: one route, one shared pipeline, the transcript as the message

Design note, November 2026.  Three faults were reported together after a
real call, and they turned out to be one design problem seen from three
sides:

- the voice indicator appeared in session B while the words still went to
  session A;
- stopping A and starting B timed out after 120 seconds;
- later speech sometimes showed only 1–5 % on the level meter.

This page says what each one actually was, what the change decides, and
what it deliberately does not do.

## What the code did, before any change

The input path was **already deterministic**.  Nothing in it called a
model.  A delegation went

```text
sidecar delegation -> harness-voice-distilled-text (regexps)
                   -> harness-voice-conversation-request (plain-text block)
                   -> session/prompt
```

`harness-voice-distilled-text` removed `um`, `uh`, stutters and an
explicit `no wait, ...` correction; `harness-voice-conversation-request`
prepended a `Voice conversation before this request:` block when the
request looked dependent.  Both were local and synchronous, so the
"input LLM" the report suspected did not exist — but the *effect* the
report objected to did: the words were rewritten and a context envelope
was added before the session's own agent ever saw them.

The routing fault was structural, not a race:

- `harness-voice-live--buffer` and `--session` were captured once, when
  the call started, and never moved.
- `harness-voice-live--controls` is a **global** compose hook, so every
  compose box in the frame drew `Live · Listening` — including boxes the
  words never went to.
- The only retarget-ish path, `harness-voice-live--release-others`, tore
  the whole sidecar down and ran only from `harness-voice--adopt`.

So "the indicator is in B but the words go to A" was exactly what the
code said: the indicator was drawn everywhere, the destination was
frozen at start.

The 120 seconds was not the sidecar.  It was the shared local pipeline's
own start deadline (`harness-speech-local-startup-timeout`, 120 s, whose
failure text is `No answer in 120 s`).  The sidecar's own startup timeout
is 15 s and its stop timeout 3 s.  A start that waited on a pipeline that
was already starting, or that had failed, waited out the whole deadline
before saying anything.

The 1–5 % was the **metric**, not the microphone.  `pcm_energy` is the
mean absolute sample: a speaking mouth at amplitude 0.05 reads 3 %, a
0.25 tone reads 16 %.  The gate's floor is 0.004, so 1–5 % is normal
capture drawn on a linear 0–100 % bar, where it looks like a dead
microphone.  Nothing was wrong with the gain, and changing it would have
been the wrong fix.

## What the change decides

### 1. One authoritative route, and it is a value

`harness-voice-live--route` returns a plist:

```text
(:kind session|workspace :buffer B :session S :workspace W :thread T
 :name "what the UI calls it" :generation N)
```

`--session` and `--buffer` remain, as fields of that route.  Every
delegation, turn and reply carries the generation it was captured under,
so "where do these words go" has one answer at any moment, and a stale
answer is recognisable as stale.

### 2. Retarget, do not restart

`harness-voice-live-retarget` moves the route and raises the generation.
The sidecar, the microphone, the speech services and the pipeline keep
running.  `harness-voice--adopt` retargets a live call instead of
resetting it, `Start` in another box retargets instead of erroring, and
`harness-voice-live-follow-selection` (default t) moves the route to the
selected window's compose box at the next utterance — not on a redisplay
hook, so reading another chat does not move the call.

### 3. Generation guards, at three points

| What arrives late | What happens |
| --- | --- |
| a queued delegation whose route moved | answered `retargeted`; never sent |
| a turn that outlives a switch | answered `retargeted`; its reply is not spoken |
| a transcript for a burst that started before the switch | sent to the route recorded at the burst's **onset** (`--utterance-routes`) |

The third is the one that matters for the reported symptom: the sidecar
names a burst from its onset, so the person can select B while A's speech
is still being transcribed, and A's words still go to A.

### 4. The UI agrees with the route

A box that is not the target shows `Live · <target name>` and a
`[Use here]` control; the target box shows the plain status.  The
mode-line indicator always names the target.  Interrupt, Cancel work,
Mute and the compact pipeline line are drawn only in the target box,
because they act on the call, not on the box.

![Two chats under one live call: the target on the left, and the box on
the right that names it and offers Use here](media/voice-routing.png)

### 5. One shared pipeline, visibly starting

`harness-voice-live--begin` asks `--pipeline-need` what the local
provider still needs:

| Pipeline | What the call does |
| --- | --- |
| running | spawn the sidecar |
| starting | join it: `Live · Initializing`, poll the cached state |
| stopped | start it, `Live · Initializing`, poll |
| failed | fail at once with the harness's own reason, `[Start]` to retry |

Only the `unmute` provider uses the harness pipeline; the fixture,
GPT-Live and a custom sidecar need nothing of it.  Stopping voice never
stops the shared pipeline: it belongs to the harness server and other
clients may be using it.

### 6. The transcript is the message

`harness-voice-live--dispatch` sends the transcript unchanged:

- a session target: `session/prompt` with one text block;
- a workspace target: `_harness/workspace/prompt` with `:id` and
  `:opts (:thread ...)`, so the workspace's own agent routes it to that
  thread's live episode.

No distillation, no context envelope, no meta-instruction, no
interpretation model.  The session's agent has the conversation it is in;
the voice only delivers the words.  This is also the shortest path: the
transcript reaches its target in the event that carried it.

The Flutter client had the same distillation in
`voice_conversation.dart`; it is removed there too, and
`VoiceSegmentDrop.noRequest` became `retargeted`, which is the drop the
client can actually have.

### 7. The level is drawn in decibels

The sidecar now reports three numbers from one chunk: `input` (mean
absolute, unchanged, the gate's own scale), `peak` (loudest sample) and
`dbfs` (the same `input` on a decibel scale).  The meter draws dBFS on a
documented −60…0 dB scale (`harness-voice-pipeline-level-floor`), and the
pipeline details keep the raw numbers.  This is a **scale, not a gain**:
no sample is changed and the gate's threshold is untouched.

## Alternatives considered

- **Restart the sidecar on a switch.**  What the code effectively did.
  It costs the microphone, the speech services and several seconds per
  switch, and it is what made "stop A, start B" look like a timeout.
- **One sidecar per session.**  Two microphones cannot be open at once,
  and the person has one mouth.  The call is one call; only its
  destination moves.
- **Route by the buffer the call started in, and require an explicit
  switch.**  Predictable, but it is the reported bug: the person selects
  B, speaks, and the words go to A.  Following the selection at the next
  utterance is what a person expects; the option exists for anyone who
  wants the old behaviour.
- **Keep distillation, drop only the context block.**  Half the report.
  The words would still be rewritten before the agent saw them, and the
  agent is the only reader that can tell which earlier turn a pronoun
  points at.
- **An input interpretation model.**  Adds a network round trip and a
  second failure path between the microphone and the session, and changes
  what the person said.  Explicitly rejected by the report.
- **Change the microphone gain, or lower the gate.**  The measurement was
  correct; only its presentation was misleading.  Changing gain to make a
  number look bigger would have made the gate's own decisions worse.
- **Draw the level as a percentage of full scale with a non-linear
  curve.**  A curve nobody can name.  dBFS is a scale with a definition,
  and the raw numbers stay beside it.

## Shape of the change

`lisp/ui/harness-ui-voice-live.el`

- The route: `--route`, `--route-set`, `--route-same-p`,
  `--route-of-buffer`, `--route-label`, `--selected-route`,
  `--follow-selection`, `--route-drop-in-flight`, `--route-current-p`,
  `--utterance-route`, `--utterance-route-set`, `harness-voice-live-retarget`,
  `harness-voice-live-use-here`, `--adopt-other-box`, `--here-p`.
- The pipeline: `--begin`, `--pipeline-need`, `--pipeline-starting-p`,
  `--pipeline-start`, `--watch-pipeline`, `--pipeline-tick`, `--spawn`.
- Dispatch: `--dispatch` (session or workspace), `--transcript-route`.
- Removed: `--pending-items`, `--pending-context`, `--prompt`, and the
  distillation call in `--delegate`.

`lisp/ui/harness-ui-voice-conversation.el`

- Removed `harness-voice-distill`, `harness-voice-distilled-text` and its
  helpers, `harness-voice-conversation-carry-context`,
  `-context-turns`, `-context-chars`, `-turn-chars`,
  `harness-voice-conversation-context`, `-request`, `-needs-context-p`.
- `harness-voice-conversation-hear` takes `(conversation raw &optional sent now)`.

`lisp/ui/harness-ui-voice-pipeline.el`

- `peak` and `dbfs` on the model, `harness-voice-pipeline-level-floor`,
  `--level-fraction`, `level-detail`; `level-label` says
  `Level · N dBFS` when the path measured decibels.

`lisp/ui/harness-ui-voice.el`

- `--adopt` retargets a live call; `--on-kill` moves it to another box;
  `--indicator` shows the call from the route's buffer.

`scripts/harness_voice_sidecar.py`, `scripts/harness-voice-live-unmute`,
`scripts/harness-voice-live-gpt`

- `pcm_peak`, `LEVEL_FLOOR_DBFS`, `level_dbfs`, `LevelMeter.reading`,
  `announce_level(level, peak, dbfs)`.

`harness_client/lib/src/voice/`

- `voice_conversation.dart`: the distillation rules, `distilledText`,
  `voiceRequestNeedsContext`, `context`, `request()` removed; `hear`
  records the words as heard and as sent.
- `voice_controller.dart`: `_sendPrompt` sends the transcript; a burst
  with no words is dropped as `noWords`.
- `voice_backend.dart`, `voice_pipeline.dart`: `noRequest` → `retargeted`.

## Tests

- `lisp/ui/harness-ui-voice-live-test.el`: routing (retarget without
  restart, switch during capture, switch during a turn, repeated
  switches, non-target box copy, follow-selection, workspace thread,
  many utterances), end to end through the real sidecar process
  (`routing` mode of `test/harness-voice-live-sidecar-test.py`), the
  shared pipeline (ready, initializing, failure, joining a start,
  stopping keeps it), and the transcript sent unchanged.
- `lisp/ui/harness-ui-voice-pipeline-test.el`: the dBFS label and the
  details' raw numbers.
- `test/harness-voice-gate-test.py`: `pcm_peak`, `level_dbfs` and the
  reading the meter draws.
- `harness_client/test/voice_controller_test.dart`,
  `voice_conversation_test.dart`, `voice_pipeline_test.dart`.

## Limits

- The end-to-end tests drive a **scripted sidecar process**, not a
  microphone: they prove the routing, the generation guards and the
  protocol, not the audio path.  A real-device check is a person speaking
  into a real microphone, and it is not part of this change.
- The dBFS scale is a presentation of the same measurement.  It does not
  make a quiet microphone louder, and a level that is genuinely too low
  for the gate still needs the gate's own floor, not the meter.
- A workspace target needs the workspace's own live episode to exist;
  the prompt is routed to the thread, and the workspace decides what that
  thread does with it.
