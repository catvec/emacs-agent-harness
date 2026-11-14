# Voice turn completion

## Problem and scope

An audio endpoint is not necessarily the end of a person's thought. The local
Emacs pipeline currently delegates each VAD chunk immediately, and Flutter's
clip provider does the same after transcription. A breath, a thinking pause,
“one second”, or a recorder's size limit can therefore send an unfinished
request and start an unwanted reply.

The clients will own a pending **conversational turn**, separately from the
backend's audio chunks. This applies to automatic live voice and Flutter's
transcribed clip provider, not Emacs's manually submitted dictation. A backend
without transcripts (Flutter's audio-prompt option) cannot use lexical intent;
it keeps its documented audio-only behavior rather than inventing words.

## Completion policy

A small deterministic classifier uses the end of the accumulated transcript.
The shared examples are in `test/fixtures/voice-turn-completion.json`. It is a
conservative English-language fallback, not a claim to understand prosody or
all languages. It never asks a second model to rewrite a request.

- **Ordinary ending:** retain the transcript for a 1.2-second grace period
  after its final transcript arrives. Speech onset or an outstanding
  transcription blocks submission and cancels the timer. Once all chunks are
  resolved and speech has stopped, a fresh grace period may begin.
- **Continuation intent:** a trailing direct pause cue such as “one second”,
  “hold on”, “let me think”, “give me a moment”, or a trailing hesitation such
  as “um” holds the draft without an automatic timeout. A cue followed by a
  completed thought does not keep holding it. A quoted/named phrase is not a
  command to wait.
- **Possible cut-off:** a dangling conjunction/preposition, an unfinished
  request stem, trailing ellipsis/dash, or a backend's explicit `truncated`
  flag holds the draft without an automatic timeout. Punctuation supplied by
  speech recognition is not proof that a dangling clause is complete.
- **More words:** append chunks in their original order with a single space,
  preserving their wording. Reclassify the accumulated ending. A later
  complete chunk can finish a previously held thought; a later cut cannot.
- **Recovery:** an entire utterance consisting of “continue” or “go on”
  (optionally “please”, ignoring case and terminal punctuation) releases an
  existing draft immediately, even if its ending looked incomplete. The cue
  remains visible in the audio-side captions, not appended to the request.
  With no pending draft it is an ordinary request to the agent, sent unchanged.
  Embedded or quoted uses are ordinary content, not control commands.
- **Manual override:** `Submission` submits a pending draft once. It cannot send
  over active speech or a transcription still in flight; those must finish
  first so the override does not itself cut the speaker off.

Ordinary silence therefore gets a small bounded delay. Explicit intent to
continue and suspected truncation never expire into an unsolicited send.
There is no silence-only timeout that overrides “let me think”.

## Ownership, output and lifecycle

Captions remain immediate. The unsent accumulated text and its reason are
visible independently of the agent's work. Delivery and the conversation's
`sent` record happen only at commitment, never when a chunk is merely held.
One committed turn may have several source segments; each source must reach
its terminal pipeline state rather than remaining stuck at transcription.
Stable chunk ids are deduplicated on receipt, including while pending, so a
provider retry cannot repeat a phrase or send the request twice. Repeated words
without stable ids are not assumed to be duplicates. A bounded pending-text
limit fails closed with `Unsent speech limit`, retaining the complete draft
in the audio transcript instead of silently clipping it or auto-submitting.

Speech onset and accepted/transcribing chunks track work that has not yet
resolved. Empty/dropped chunks unblock ordinary grace without discarding a
held draft. A transcription failure must not silently submit an earlier
fragment as though the missing words never happened: retain it as a possible
cut-off, with the existing failure visible. Missing-audio failure remains a
hold even after later complete words; explicit recovery or submission is
required to send the known words intentionally.

Assistant output remains held while input is pending, including across a long
thinking pause. The bundled sidecars accept `{"event":"turn_hold",
"active":true}` and its false counterpart; the base sidecar and GPT playback
honor it. Flutter's optional `VoiceTurnControl.setTurnHeld` capability does the
same for live remote audio. No microphone muting is used for this hold: the
person must remain able to continue. Unknown/custom providers may ignore the
extension; their internal autonomous speech cannot be guaranteed by a client.
The live model's instructions also explicitly ask it not to interrupt pauses
and to obey continuation/recovery cues. Finalized user captions can identify
pause intent before a live model delegates. Those captions can hold output,
but they do not invent a session request: normal autonomous greetings stay
provider-owned, and `Submission` is only available for a delegated draft.
A newer caption-only pause also prevents an older pending delegated request
from submitting: a delayed earlier transcript must not override an audible
“hold on”. Its words are not added to the request. Explicit recovery or manual
submission can release the existing delegated draft. With no such draft,
caption-only recovery returns the floor to the live provider. A delegation,
when it arrives, enters the ordinary pending-turn guard.

End, fatal failure, backend replacement, explicit mute/pause, and route changes
cancel pending submission, timers and held-output release. Pending words are
never delivered to a new session or workspace thread. Timer callbacks are
scoped to the pending generation/lifecycle, not whichever route is current
when they fire. A canceled pending draft is accounted for as canceled in the
pipeline; closing a call does not flush it into the agent.

## Cut-off metadata

The Python VAD keeps its existing tuple events. It exposes which utterance ids
ended at its recording limit, and the local sidecar propagates `truncated:
true` on those segment/delegation events. Normal silence endpoints are not
marked. GPT-Live streams continuously: the provider's [migration
protocol](https://developers.openai.com/api/docs/guides/live-migration)
explicitly removes manual input commits. Its local VAD can mark hard-cut
segment telemetry, but the provider's transcript/delegation has no correlated
input id, so the adapter does not falsely attach that flag to unrelated
words or invent an unsupported commit. GPT-Live also has no response boundary
for output generations: chunks received while held are dropped, not buffered,
but audio arriving after an explicit release cannot be labeled old versus new
by this protocol. Flutter's
`VoiceUtterance.truncated` and `VoicePrompt.truncated` carry the equivalent
fact from the clip detector through the live protocol/controller. A forced
size cut is an audio chunk boundary, not permission to submit a turn.

## Interface copy inventory

Both clients reuse their existing controls and visual style. No explanatory
paragraph is added to the live surface.

| Surface | Exact new copy |
| --- | --- |
| Normal grace status | `Finishing thought` |
| Continuation-intent status | `Waiting for continuation` |
| Fragment/forced-cut status | `Possible cut-off` |
| Pending transcript heading | `Unsent speech` |
| Submission action | `Submission` |
| Submission tooltip | `Pending speech submission` |
| Pending text safety limit | `Unsent speech limit` |

The existing listening, transcribing, muted, stopped and failure copy remains
unchanged. These are noun phrases/status adjectives; explanations belong in
this document and explicit help, not tooltips. Exact rendered-copy assertions
cover the changed states and tooltip. Live screenshots and the changed UI
strings receive a separate final inspection.

## Alternatives and trade-offs

A longer VAD silence threshold alone cannot obey explicit thinking intent,
and delays every complete request. A semantic model could use more context,
but adds latency, failure modes and cost before every request; it must not be
the only thing preventing interruption. This change instead makes the local
fallback safe, visible and reversible. It can conservatively hold a complete
sentence ending in a suspicious word; `continue`, `go on` and `Submission` make
that false positive recoverable without repeating the request.

Transcripts remain original text, not summaries or inferred intentions. The
only composition is joining adjacent chunks of the same unsent turn. No agent
turn is canceled merely because the person takes the floor.

## Verification and demonstration

The clients run the same classification examples, plus timer/event tests for
ordinary breath pauses, long explicit holds, resumed speech before a deadline,
slow/out-of-order transcription, duplicate events, recovery with and without a
draft, canceled lifecycles, route changes and held output. Python tests verify
that only actual hard cuts carry truncation metadata and that held playback
cannot restart on a normal listening event.

The review demonstration uses scripted transcripts, not a microphone or paid
speech API: a complete-looking request ending in “hold on” stays unsent, a
continuation is combined, a likely fragment displays its reason, and “go on”
releases it exactly once. It shows both the draft and the eventual session
message. This verifies client behavior, not real-world speech recognition
accuracy; live microphones and provider endpoint behavior remain deployment
checks.
