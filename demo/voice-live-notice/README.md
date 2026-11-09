# A live voice call that does not hang up when one reply fails

`demo.sh` runs the real local sidecar
(`scripts/harness-voice-live-unmute`) in a real Emacs compose box. Two
fake programs stand in for `pw-record` and `pw-play`, and a stub speech
service (`speech_service.py`) answers the way the bundled `voice-local`
pipeline does:

- a WAV for text it has phonemes for;
- **HTTP 200 with an empty body** for text it has none for, which is
  what Kokoro answers an emoji with (measured against the running
  pipeline).

```sh
demo/voice-live-notice/demo.sh
```

Two runs:

1. **A reply that ends in an emoji.** `Loud and clear — 1, 2, 3
   received. 🙂` is sent to the sidecar one sentence at a time. The
   piece after the last full stop has no letter or digit in it, so Emacs
   never sends it; the sentence before it is spoken, and the call goes
   on.
2. **A reply the speech service refuses.** A normal sentence, which the
   stub answers with an empty body, as Kokoro does for a script it has
   no phonemes for. The sidecar reports `notice` rather than `error`,
   Emacs shows it, and the call goes on.

```text
== the call · refused
   status · Live · Listening
   heard · Add a docstring to parse.
   sent · the request reached the chat
   said · Nothing changed; it was only a read-only check.
   reply · a normal sentence, which the service answered with an empty body
   notice · Live voice · Local speech · no audio
   error · none
   call · still up
   status · Live · Listening
   spoke · And the next reply is spoken.
   call · still up
== the transcript
   ...
   Voice · 14:09
   Nothing changed; it was only a read-only check.
   Live
   Local speech · no audio
```

Before the change both runs ended with `Live voice failed · Local
speech · no audio returned`, the sidecar gone and the microphone shut:
one empty body from the speech service took the whole session down.

The agent is the one stand-in: no harness server runs a turn here, so
`client.el` streams the reply the chat would stream. The sidecar
process, the sidecar protocol, the compose box, the controls, the
transcript and the speech service (a stub, but one that answers the way
the real one does) are the real thing. `python3` is the only
requirement.

| File | What it is |
| --- | --- |
| `demo.sh` | The two runs, with the stub service and the fake sound server |
| `client.el` | The compose box, the sidecar start and the streamed replies |
| `speech_service.py` | whisper.cpp's `/inference` and Kokoro's `/v1/audio/speech`, answering as the bundled stack does |

See [docs/voice.md](../../docs/voice.md),
[docs/voice-realtime.md](../../docs/voice-realtime.md) for the sidecar
protocol, and the design at
[docs/design/live-voice-failures-do-not-end-the-call.md](../../docs/design/live-voice-failures-do-not-end-the-call.md).
