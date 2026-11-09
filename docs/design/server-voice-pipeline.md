# The local voice pipeline runs on the harness server

## What the problem was

The local voice pipeline was a **client** thing, in two places:

- `lisp/ui/harness-ui-voice-providers.el` required `harness-stacks` and
  started the `voice-local` compose stack from the setup page. The UI
  only loads `harness-stacks` when `harness-process` is off, so in the
  split-process setup the stack could not be started at all.
- The `unmute` live sidecar read its `--stt-url` and `--tts-url` from
  that same local stack, and `harness-voice-transcribe-command` and
  `-synthesize-command` ran whisper.cpp and Kokoro as the client's
  children.

Every client therefore needed docker, whisper.cpp and Kokoro on itself.
A phone has none of the three, and a client on another machine had a
second pipeline with its own ports and its own downloaded models.

`docs/computers.md` already said where it belongs: next to the harness
server when it offers an API other processes share (the live voice
pipeline, so every client can connect to one).

## What the change decides

### 1. The pipeline is the harness server's

The new server module `speech` (`lisp/modules/harness-speech.el`) owns
the pipeline, with two ways to run it, both as the harness process's own
children:

| Backend | Configured with | What runs |
| --- | --- | --- |
| `command` | `harness-speech-local-stt-command` and `-tts-command`, each an argv list, with `-stt-url` / `-tts-url` beside it | the programs themselves, started by the harness, ended with it |
| `stack` | nothing (the default) | the bundled `voice-local` compose stack, whose declaration moved here from the UI |

Commands of your own win when both are set. A half configuration (one
command without the other) is a failure with a name, `Both speech
commands needed`, rather than a silent fall back to the stack.

The module starts, stops and reports the pipeline. A start is followed
by a timer that probes the URLs and turns `starting` into `running`
(both answer) or `failed` (a program exited, or
`harness-speech-local-startup-timeout` passed with `No answer in N s`).
Every state change is emitted as `speech/changed` and carries the same
status plist that `speech/status` answers with.

### 2. Speech crosses the existing connection, not a published port

The pipeline answers on loopback only: the services have no
authentication, so they are not put on a network. A client elsewhere
does not reach them at all. Instead it asks the harness:

```text
_harness/speech/transcribe  {audio: BASE64 WAV, format?, language?} -> {text}
_harness/speech/synthesize  {text, voice?}                          -> {audio: BASE64 WAV, mime}
```

The harness posts to the service on its own loopback and returns the
answer the same way. That is the sharing the change is for: a phone
sends its audio on the ACP connection it already has and needs no
whisper.cpp, no Kokoro and no port. A client on the harness's own
machine may use the `:stt-url` / `:tts-url` that `speech/status`
reports instead, which is what the Emacs live sidecar does, since it
owns the microphone and the speaker and posting to loopback saves a
base64 round trip through the harness.

### 3. The client keeps audio and the conversation

`harness-ui-voice-providers.el` no longer requires `harness-stacks` at
all. It asks `_harness/speech/status` over ACP, keeps the last answer in
`harness-voice-pipeline-status`, and follows `speech/changed`, so one
client's `[Start]` redraws every client's setup list. Its provider rows
and the new pipeline line read that one status:

```text
Pipeline  ○ stopped  [Start]
```

The states are the harness's own words; the client never decides
whether the pipeline is up. The `unmute` sidecar's URLs come from the
harness status too (`harness-voice-unmute--pipeline-url`), so the
provider's readiness is `Local voice pipeline · stopped`, `· not
checked`, or the harness's own failure line.

### 4. Dictation and spoken replies fall back to the harness

The WAV capability used to need `harness-voice-transcribe-command` and
`harness-voice-synthesize-command` on the client. Now:

- neither set: the client sends its WAV to `_harness/speech/transcribe`
  and its text to `_harness/speech/synthesize`, and the harness does the
  speech;
- a command set: that command runs on the client, exactly as before.

The validation before the microphone opens is the same either way: with
no command, the pipeline must be running, so a stopped one refuses
dictation with `Local voice pipeline · stopped` before the microphone is
on. The player stays local: only the speech crosses the wire, the WAV
comes back and this machine speaks it.

### 5. The whisper model and the voice are the server's settings

`harness-voice-whisper-model` and the effort-driven `WHISPER_MODEL`
environment are gone from the client: a client cannot pick the model of
a pipeline it does not run. They are `harness-speech-local-whisper` and
`harness-speech-local-voice` on the server. `harness-voice-effort` stays
for providers that declare `:efforts` fragments of their own.

## What was rejected

- **Publishing the pipeline's ports on the network** so any client could
  post to it directly. The services answer no authentication and take
  arbitrary audio and text; putting them on a LAN would be a new
  unauthenticated surface for the sake of saving a base64 hop. The ACP
  connection already authenticates and already carries the session.
- **Keeping the client-side commands as the primary path** and adding
  the harness pipeline beside them. Then a phone still needs the local
  install, which is the problem. The client command stays only as an
  explicit override for a person who wants their own machine's model.
- **A new sidecar process for the pipeline**, run by the client, talking
  to the server. That adds a process and a protocol where the harness
  already has a module and a bus.
- **Moving `harness-stacks` into the UI.** It would let a client start
  containers on itself, the opposite of the change.

## The shape of the change

| File | What it does now |
| --- | --- |
| `lisp/modules/harness-speech.el` (new) | owns the pipeline: its two backends, start and stop, the watch, `speech/status`, `speech/start`, `speech/stop`, `speech/transcribe`, `speech/synthesize`, `speech/changed` |
| `lisp/modules/harness-speech-test.el` (new) | 18 tests: the stack declaration, both backends, the states and their copy, transcription and synthesis against a fake service, the ACP surface and the forwarded event |
| `test/harness-speech-service.py` (new) | the fake service the tests and the demo run: whisper.cpp's multipart `/inference` and Kokoro's OpenAI `/v1/audio/speech`, no model |
| `lisp/modules/harness-acp.el` | `speech/` is a callable method prefix; `speech/changed` is forwarded as `_harness/event` |
| `lisp/ui/harness-ui-voice-providers.el` | no `harness-stacks`; `harness-voice-pipeline-*` read and follow the harness status; the pipeline line and `[Start]` / `[Stop]`; the `unmute` URLs from `speech/status` |
| `lisp/ui/harness-ui-voice.el` | dictation and spoken replies fall back to `_harness/speech/transcribe` and `_harness/speech/synthesize`; `harness-voice--transcriber-error` validates the pipeline before the microphone |
| `docs/voice.md`, `docs/computers.md`, `docs/stacks.md`, `docs/modules/*` | the pipeline as the server's, with the layout above |

## Copy

Interface text is nouns, noun phrases and adjectives (see `CLAUDE.md`).
The new and changed strings, decided before the code:

| Where | Text |
| --- | --- |
| setup page, pipeline label | `Pipeline` |
| its states | `● running`, `◐ starting`, `○ stopped`, `✕ failed`, `○ not checked` |
| its buttons | `[Start]` / `[Stop]`, tooltips `Local voice pipeline · start` / `· stop` |
| its tooltip | the harness's one-line detail (`2 of 2 services`, `No answer in 120 s`) |
| provider reasons | `Local voice pipeline · stopped`, `· starting`, `· not checked`, `· failed · DETAIL` |
| echo after a start or stop | `Local voice pipeline · running`, `· stopped`, `· failed · DETAIL` |
| dictation refused, pipeline down | `Local voice pipeline · stopped` / `· not checked` |
| command refused | `Speech command unset`, `Speech program unavailable · NAME`, `Speech URLs unset`, `Speech audio unset`, `Speech audio unreadable`, `Speech text unset` |
| the service's own failures | `Local voice pipeline · HTTP 503`, `· no audio`, `· could not connect to the server (…)` |

They are asserted exactly in `harness-ui-voice-providers-test.el`
(`setup-copy`, `setup-pipeline-line`, `setup-pipeline-tooltips`,
`pipeline-result-copy`) and `harness-speech-test.el` (`status-copy`).

## How it was verified

- `lisp/modules/harness-speech-test.el`: 18/18, against the fake service
  run as the harness's child, including a pipe into a real ACP
  connection for `_harness/speech/transcribe` and
  `_harness/speech/synthesize` and the `speech/changed` event reaching
  the client.
- `lisp/ui/harness-ui-voice-providers-test.el`: 21/21, with the exact
  rendered copy of the setup page, every pipeline state and tooltip, the
  listener, and the `unmute` provider's reasons.
- `lisp/ui/harness-ui-voice-test.el`: 29/29, with the fallback
  transcription and synthesis over a stubbed ACP call.
- `lisp/ui/harness-ui-voice-live-test.el`: 34/34.
- `scripts/lint.sh` clean for the changed files.
- **The real page, real pipeline:** `docs/media/voice-setup.png`, taken by
  `scripts/media.sh voice-setup`, is the client's setup list drawn by
  `harness-voice-setup--insert` while the harness ran the bundled speech
  fixture as its two children and the client read `speech/status` over
  ACP.  Its `Pipeline  ● running  [Stop]` line is the copy the tests
  assert, not a mock.
- **The round trip, end to end:** `demo/voice-pipeline/demo.sh` starts a
  headless harness whose `command` backend is the fixture and a second,
  ordinary Emacs as a client over TCP ACP.  The client has no speech
  program of its own, and the demo prints `running · 2 of 2 programs`,
  the transcript and the synthesized bytes, then the two pids and
  `programs ended` once it stops the pipeline.

## Where it still stops short

- The pipeline is one per harness: every client of that harness shares
  it, which is the point, but there is no per-client queueing.
- A `command` backend is trusted to serve the routes named beside it;
  nothing checks the shape of its answers beyond JSON and a RIFF header.
- Transcribing and synthesizing are request/response over ACP, so a
  phone's dictation has the round trip of the connection. That is what
  makes the client need nothing installed, and the live sidecar on the
  harness's own machine still avoids it.
