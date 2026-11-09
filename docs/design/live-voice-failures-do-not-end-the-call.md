# A failed reply does not end the call

## What the problem was

Live voice ended itself when the agent answered. The user's Emacs held

```elisp
harness-voice-live--error  "Live voice failed · Local speech · no audio returned"
harness-voice-live--state  failed
```

after one turn: the transcription worked, the request reached the chat,
the agent answered, and the session was torn down before a word of the
reply was heard.

The chain, read from the code and then reproduced against the running
pipeline (`speech/status` reported Kokoro on
`http://127.0.0.1:32796/v1/audio/speech`):

1. The agent's reply streams to Emacs as sentences. Emacs strips the
   markup (`harness-voice--speech-text`) and sends what is left as
   `commentary`, one piece per sentence boundary. A reply that ends
   `… received. 🙂` gives a second piece of just `🙂`.
2. The sidecar posts each piece to the speech service. Kokoro answers
   text it has no phonemes for — an emoji, an em dash, a stray backtick —
   with **HTTP 200 and an empty body** (verified: `🙂`, `—`, `…`, `` ` ``,
   `**`, `,` all answer 0 bytes; `1, 2, 3`, `` `/home/noah` `` and
   `Hi 🙂` answer a WAV).
3. `harness-voice-live-unmute:synthesize` treated "not a RIFF" as a
   failure and sent `error` on the sidecar pipe.
4. In `harness-ui-voice-live.el` the `error` event means *the session is
   over*: `harness-voice-live--fail` disposes the process, marks the
   state `failed` and drops the turn. One unspeakable fragment ended a
   call that was otherwise healthy.

The same over-broad `error` closed the call on a single failed
transcription, on a transient TTS 5xx, and on any `error` event from
GPT-Live — all conditions the sidecar itself carries on from.

A second, quieter defect lived on the same path: `on_result` decides
which sentences of the full reply the commentary already spoke
(`_unspoken`), comparing them with `_normal`. The pieces Emacs sends are
markup-stripped; the full reply is not. A sentence with `code` or
`**bold**` in it therefore never matched and was spoken a second time.

## What the change decides

### 1. The pipe has two kinds of "went wrong"

| Event | Means | What the client does |
| --- | --- | --- |
| `notice` | one reply or one utterance could not be done | shows it, keeps the session |
| `error` | the sidecar cannot carry on | ends the session, as before |

`notice` is new; `error` keeps its meaning and its existing handler.
The rule for a sidecar is: `fail()` — a missing key, no microphone, a
dead connection, the loop dying — sends `error`; anything a later turn
can recover from sends `notice`.

That is a narrower contract than "report every problem as an error",
which is what the protocol had, and it is the one the two capabilities
need: a WAV dictation that fails is a failed job with a visible state,
while a live session that fails one sentence should not hang up.

### 2. Text with nothing to say is never synthesized

Two filters, one on each side of the pipe:

- **Emacs** (`harness-voice-live--speakable-p`): a piece with no letter
  or digit is not sent at all. It is not speech, so not sending it costs
  nothing, and the common trigger — the emoji that ends a friendly
  reply — never reaches a speech server.
- **The sidecars** (`harness_voice_sidecar.speakable`): the same test
  before anything is queued for synthesis, because a sidecar is also
  driven by providers that do not filter (GPT-Live shapes its own audio)
  and by a `delegate_result` whose text never passed through Emacs's
  sentence splitter.

An empty body is still possible for text that *has* letters (a speech
server out of phonemes for a script it does not know, say). That is now
a `notice` — "Local speech · no audio" — and the call goes on. The
reply is lost either way; the difference is whether the person loses the
microphone with it.

### 3. A failed reply is named where it happened

The client keeps the notice in `harness-voice-live--notice`, shows it in
the controls (`Live voice · Local speech · no audio`, caution face,
tooltip the same line) and writes it into the transcript under a `Live`
heading, so the place a reply went unspoken stays in the call's record.
It is cleared when a new call starts. Nothing else about the call
changes: the stage stays `Listening`, `[Start]` does not appear, and the
next turn is tried as usual.

### 4. A sentence is spoken once

`_normal` now flattens markup the way `harness-voice--speech-text` does
— link destinations, HTML, leading list and heading marks, `` ` ``, `*`
and `_` — before it compares the reply's sentences with the commentary.
Both sides of the comparison are then the text a voice would say.

## What it does not do

- It does not retry the lost reply. The sidecar reports the notice and
  drops that piece; the next turn speaks normally. A retry could speak a
  stale sentence into a person who has moved on, which is exactly what
  the held-output machinery exists to avoid.
- It does not change `error`. A sidecar that reports one still ends the
  call, and the startup and stop timeouts still kill a broken process.
- It does not touch the WAV capability, whose per-job failures already
  show in its own state without ending anything.

## The client's own settings are kept

The second report was smaller: the voice provider had to be chosen again
in every new Emacs. `harness-voice-select-provider` (and
`-select-effort`, `-select-stt-model`) only did `setq`; nothing wrote the
choice anywhere, so the next start fell back to the `defcustom` default
(`wav`).

The three are client configuration, not harness settings — the docstrings
already say so — so they are saved where this Emacs keeps its
customizations, through `customize-save-variable`, which is what
Customize itself does. One helper (`harness-voice--save-choice`) does
that for all three:

- it asks `harness-policy-refuse` first, so an option an administrator's
  policy sets is refused before anything changes;
- with no custom file (Emacs started with `-q`) it sets the value for the
  session and lets Customize say it cannot be saved, rather than writing
  into an init file that is not the user's.

The harness's own `config/set` was rejected for this: it saves global
options in the *server's* custom file, and a voice provider is chosen per
client, so a remote UI would be saving another machine's configuration.

## Verification

- `test/harness-voice-gate-test.py` — an empty synthesis body is a
  notice; a speech service error is one reply; unspeakable text never
  reaches synthesis; a markup sentence is spoken once; a failed
  transcription leaves the microphone listening and the next utterance
  reaches the agent.
- `lisp/ui/harness-ui-voice-live-test.el` — a sidecar `notice` shows its
  exact copy in the controls and the transcript, in the caution face, and
  the session stays active and listening; an unspeakable piece is never
  sent while the sentence beside it is.
- `lisp/ui/harness-ui-voice-providers-test.el` — the three choices are
  each saved, a save writes the custom file, and a policy value is
  refused before it is touched.
- **The call itself:** `demo/voice-live-notice/demo.sh` runs the real
  local sidecar in a real compose box against a stub speech service that
  answers as Kokoro does.  One run ends a reply in an emoji (never sent
  at all, because there is nothing to say); the other has the service
  answer a normal sentence with an empty body, and the demo prints the
  notice, `call · still up` and the next reply being spoken.
- **In a live frame:** `docs/evidence/live-voice-notice/` holds the two
  screenshots taken from `scripts/dev.sh` running this branch: a call
  whose controls read `Live · Listening · … · Live voice · Local speech ·
  no audio` with the `Live` block in the transcript, the session still
  up and `[End]` still the button, and the voice setup page with `Local
  pipeline` selected.  The provider choice was saved from that frame too:
  `harness-voice-select-provider` wrote `(harness-voice-provider 'unmute)`
  into the client's custom file and the option holds it after the call.
