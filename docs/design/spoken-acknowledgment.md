# The spoken acknowledgment of an accepted request

Design note, November 2026.  A person who has just spoken a request
into a voice session hears nothing until the agent's first sentence: the
microphone closes a moment after they stop, the request crosses into the
session, and the model reads the transcript, its context and its tools
before it says anything.  That silence reads as a hang, and it is longest
exactly when the work is hardest.

The harness answers it with **one short spoken receipt**: "On it",
"Hmm, thinking", "Right".  It says only that the request arrived.  It
never says what the work is doing, how far it has got, or that anything
is finished.

## The decision

The receipt is a phrase from a **local bank**, played by whoever already
owns the speaker.  There is no synthesis round trip and no model call on
the request's path.

```text
accepted request ─┬─> prompt request (sent first, never waits)
                  └─> one bank phrase ──> the player that owns the speaker
```

Where it is spoken:

- **Live voice** (the `unmute` local pipeline, the scripted `fixture`, a
  `custom` sidecar written against `scripts/harness_voice_sidecar.py`):
  `harness-voice-live--delegate-next` sends `{"event":"acknowledge",
  "delegation":ID}` right after `harness-ui-call-turn` returned.  The
  sidecar synthesized the phrases once, in the background, when the call
  started; playing one is a memory read handed to the player thread it
  already runs.
- **WAV dictation**: `harness-ui-turn-accepted-functions` (a new generic
  hook, run inside `harness-ui-call-turn` once the request is out) tells
  `harness-voice--acknowledge`.  It makes the cheap decisions in that
  call and starts the player from a zero-delay timer, so even the process
  spawn is out of the request's own call.  The WAVs are generated once
  per voice into `harness-state-directory/voice/acknowledgments/`.

Both banks are generated before they are needed: the live sidecar's at
`start`, the WAV client's on its first accepted request (and by
`M-x harness-voice-acknowledge-prime`).  A request that arrives before
its phrase exists is heard in silence, and the generation goes on for
the next one.

## Why not a model

A model in this path would need a key, a network, a deadline and a
cancellation, and its answer would arrive after the silence it is meant
to cover.  The latency it adds is larger than the silence it fixes.  A
bank has none of those failure modes: it cannot fail the request, it
cannot be slow to a deadline, and it has nothing to leak into a later
conversation.  A recorded phrase also cannot invent progress, which a
model asked to "acknowledge" reliably can.

## What it must never do

Each of these is a test in `lisp/ui/harness-ui-voice-test.el`,
`lisp/ui/harness-ui-voice-live-test.el` or
`test/harness-voice-gate-test.py`:

| Risk | The rule | Where |
| --- | --- | --- |
| Latency on the request | The prompt goes out first.  The live receipt is sent after `harness-ui-call-turn` returned; the WAV receipt's player starts from a zero-delay timer.  Neither failure can fail the turn: the hook is wrapped per function, and the receipt swallows its own errors. | `harness-ui--turn-accepted`, `harness-voice--acknowledge`, `harness-voice-live--delegate-next` |
| Saying something false | The banks hold receipts only -- an interjection or a noun phrase, no verb of work and no full stop. | `harness-ui-voice-acknowledgment-phrase-bank-copy` |
| Chattering | One receipt per accepted request.  A request queued behind a running turn is not a new request (its prompt carries no `:prompt`), and the bank never plays the same phrase twice in a row. | `harness-voice--acknowledgment-request-p`, `harness-voice-live--acknowledge-possible-p`, `...-variety-and-repeat-suppression`, `test_no_phrase_plays_twice_in_a_row` |
| Competing with a person | The receipt is dropped, not queued, while the gate hears speech, holds a transcript or waits for one, and it is never replayed afterwards. | `AcknowledgmentTest` (Python) |
| An unmuted room | `harness-voice-acknowledgment`, `harness-voice-live-acknowledgment`, the sidecar's mute (`C-c v`) and the sidecar's `--no-acknowledgment` each stop it. | `...-off-muted-and-unsent`, `...-switches-off`, `test_no_acknowledgment_argument_silences_it` |
| Interrupting the user | `C-c V` sends `acknowledgment-cancel` and stops a receipt already sounding; a reply that starts stops one too. | `...-yields-to-speech-and-interrupt`, `test_a_reply_stops_a_receipt_that_is_sounding` |
| Stale playback | A receipt belongs to a delegation and a turn.  A cancelled, finished, replaced or other-session request drops it; the WAV receipt is played only while its own prompt is still in flight, its session is the box's and the box still owns voice. | `...-drops-a-finished-turn`, `...-drops-a-stale-one`, `...-acknowledgment-stops-with-the-session`, `...-follows-a-cancelled-turn` |
| A late receipt after the answer | The sidecar drops a receipt once the reply has started or the bank has been used for this turn; the client checks again in its timer. | `test_a_held_transcript_or_a_started_reply_drops_the_receipt`, `test_acknowledge_is_never_queued_behind_a_reply` |
| Reconnecting | The receipt is not replayed after a reset: `harness-voice--reset` and the mode's off switch stop it, and a replaced connection drops the prompt it belonged to. | `...-drops-a-stale-one` |

## Settings

Nothing new appears in the chat's chrome.  The switch is a setting in the
customize group the voice setup page already links, `harness-voice`:

- `harness-voice-acknowledgment` (default t) -- the receipt, for both
  capabilities.
- `harness-voice-live-acknowledgment` (default t) -- the live sidecar's
  receipt alone.
- `harness-voice-acknowledgment-phrases` -- the bank; the live sidecar is
  started with the same list (`--acknowledgment-phrase`), so a receipt
  sounds the same in either capability.
- `harness-voice-acknowledgment-voice` -- the voice the WAV bank is
  generated in; nil is the pipeline's voice.
- `harness-voice-acknowledgment-timeout` -- the bound on one WAV receipt's
  player.

Precedence: mute, a stopped session and a reply that has started stop the
receipt whatever the settings say; then `harness-voice-acknowledgment`,
then the capability's own switch; then the bank decides which phrase; and
the reply always outranks the receipt.

The latency budget is **300 ms** from the request going out to the
receipt's player starting, warm.  The measurements, the fallbacks and the
limits are in
[the analysis](../analysis/spoken-acknowledgment-2026-11-09.md), and both
halves are reproducible here:
`scripts/analysis/bench-acknowledgment.sh` for Emacs's own path and
`scripts/analysis/bench-acknowledgment-sidecar.sh` for the shipped
sidecar's, which is where the ~21 ms tick floor is measured.

## Scope

In scope, and covered by tests: the `unmute` and `fixture` live sidecars
(and any `custom` sidecar built on `scripts/harness_voice_sidecar.py`),
and WAV dictation's receipts.

Out of scope, by decision:

- **GPT-Live**: the voice model speaks its own acknowledgment under its
  prompt policy, and a recorded phrase over a live speech-to-speech
  session would talk over the model.  `GptSidecar` leaves
  `acknowledgements` off, and a test holds it that way.
- **The Flutter client's voice screen**: it plays audio on a phone through
  its own backend, and its budget is a mobile asset, not this tree's
  sidecars.  It is not changed here and gets no receipt from this path.
- **Task submissions** (`task_control`, the task board): the receipt is
  voice's.  A typed task submission has the board's own arrival mark.

## Verification

`scripts/test.sh` (no arguments) runs every suite; on this branch 208 of
209 suites pass.  The one that does not,
`lisp/ui/harness-ui-patch-review-test.el` with
`harness-ui-patch-review-tool-open-reveals-a-closed-thread-by-prefix`, is
not this work: the branch touches neither the file nor anything it loads,
and the same test fails on `main` (`cb5621e`) in a clean worktree of it,
with the same assertion -- `window-live-p` on the buffer the test's own
frame never shows.  It is left alone rather than fixed here.

The receipt's own suites all pass:

| Suite | Tests |
| --- | --- |
| `lisp/ui/harness-ui-test.el` | the turn-accepted hook: after the request, a failure never fails the turn, and its cost |
| `lisp/ui/harness-ui-voice-test.el` | the WAV capability's receipt, its settings and their rendered lines |
| `lisp/ui/harness-ui-voice-live-test.el` | the live capability's receipt and the order of prompt and receipt |
| `lisp/ui/harness-ui-voice-providers-test.el` | the sidecar's acknowledgment arguments |
| `test/harness-voice-gate-test.py` | 82 tests of the sidecar, the receipt's gate, and the in-process latency budget |

`scripts/lint.sh` compiles every file with no new warning, and
`scripts/module-docs.sh --check` reports the module pages current.

## What the interface shows

Nothing new: the receipt is speech, not chrome.  The only user-visible
surface it adds is the settings group the voice setup page already links,
`harness-voice`, where each setting renders its docstring's first
sentence.  Those five lines are asserted exactly, in
`harness-ui-voice-acknowledgment-setting-copy`, and read as the
repository's copy rule asks -- a noun phrase, not a story:

- `Harness Voice Acknowledgment` -- "Whether an accepted request gets one short spoken receipt."
- `Harness Voice Acknowledgment Phrases` -- "Phrases the WAV capability may play as a request receipt."
- `Harness Voice Acknowledgment Timeout` -- "Maximum seconds one receipt plays before its player is stopped."
- `Harness Voice Acknowledgment Voice` -- "Voice the WAV capability generates its receipts in."
- `Harness Voice Live Acknowledgment` -- "Whether a live voice request gets the sidecar’s short spoken receipt."

The five spoken phrases are data, not interface copy, and the bank's
copy test holds them to receipts only: no verb of work, no full stop.

## The alternative that was rejected

**A synthesized receipt at request time.**  One extra speech request per
request, in the path the receipt exists to shorten.  A Kokoro or Piper
synthesis is hundreds of milliseconds on a warm service, and the first
call after a restart is seconds; the receipt would arrive after the first
sentence it was meant to pre-empt.  It also fails in the interesting
case: a stopped pipeline, a busy service or no network would make the
acknowledgment a failure path in the request's own turn.

**A model-written acknowledgment.**  Rejected above: latency, a failure
mode, and the risk of inventing progress.

**A UI line instead of speech.**  The problem is an *audio* silence in a
conversation; a line of chrome the person is not looking at does not fill
it, and it would add prose to an ordinary page, against this
repository's copy rule.
