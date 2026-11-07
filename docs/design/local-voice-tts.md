# Text to speech for the local voice pipeline

## The missing half

The local voice provider is a pipeline around two OpenAI-compatible
services: whisper.cpp turns speech into text, and a speech service turns
the reply into audio. The bundled `voice-local` stack started whisper.cpp
only. The setup list therefore read `Local pipeline · Text to speech
endpoint unset`, and starting a voice session could not speak.

The stack had an `unmute` service behind a compose profile, but it was
not a usable endpoint: Kyutai Unmute publishes no image, wants a GPU and
serves a websocket protocol rather than the OpenAI audio routes. The
profile was already off, and pointing the provider at that service would
not have produced speech either.

## Decision

The `voice-local` stack now runs a `tts` service beside whisper.cpp:
[Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI)'s CPU image,
pinned to `v0.8.2`, on container port 8880 published on a random loopback
port like whisper's. The local provider resolves text to speech from that
service, and still lets `harness-voice-unmute-tts-url` override it. The
`unmute` service and its profile are removed.

`harness-voice-unmute-voice` now defaults to `af_heart`, the voice the
Kokoro image warms at startup. The sidecar sends the OpenAI model name
`tts-1`, which Kokoro-FastAPI accepts, and a `response_format` of `wav`.

The sidecar resamples a reply WAV to the pipeline's 16 kHz PCM16 mono.
Kokoro and OpenAI answer at 24 kHz; without the resample the reply played
1.5 times slower and lower. The resampler also downmixes stereo and reads
a streamed WAV whose RIFF and data sizes stay at `0xffffffff`, which is
what an OpenAI-compatible server sends on a chunked response.

## Why Kokoro-FastAPI

It is a published, multi-architecture CPU image with the Kokoro-82M model
baked in. A first start is a pull, not a build or a model download. Its
`/v1/audio/speech` route takes the OpenAI request shape, accepts `tts-1`
and OpenAI voice names (`alloy`, `af_heart` and the other Kokoro names),
answers WAV, and needs no key. The wrapper and the model weights are
Apache 2.0, and the image is actively maintained.

The costs are a 1.45 GB first pull and roughly twenty seconds of model
load before the first reply; both are visible in the stack's `starting`
state. The image tag is pinned for a reproducible first start and can be
replaced with `HARNESS_TTS_IMAGE`.

Alternatives considered:

- **Kyutai Unmute.** No published image, GPU only, and a websocket
  protocol, not the OpenAI REST routes. It never was the endpoint this
  provider describes, so it is removed rather than kept behind a profile.
- **The official Piper HTTP server.** It exposes `/synthesize`, not
  `/v1/audio/speech`; using it would need a wrapper service, a new
  request flavor in the sidecar, or a build step, and it downloads its
  voice on first use. It remains a good endpoint for
  `harness-voice-unmute-tts-url` when a user runs one.
- **OpenedAI Speech.** Upstream declares itself obsolete and its
  maintained image is larger and Coqui-heavy.
- **Speaches.** It can serve Kokoro TTS as well, but it also carries a
  second speech-to-text stack the harness does not need and downloads
  its models at runtime.
- **Building a small Piper image in this repository.** It would avoid a
  third-party image but add a Dockerfile, a voice download and a wrapper
  to maintain, to reproduce a route the published image already serves.

## Shape of the change

`scripts/stacks/voice-local/docker-compose.yml`

- A `tts` service: `ghcr.io/remsky/kokoro-fastapi-cpu:v0.8.2` (override
  `HARNESS_TTS_IMAGE`), `DEFAULT_VOICE` from `HARNESS_TTS_VOICE`
  (default `af_heart`), `API_LOG_LEVEL=WARNING`, port
  `"127.0.0.1::8880"`, the stack's `voice` network.
- The `unmute` service, its profile and `HARNESS_UNMUTE_IMAGE` are gone.

`lisp/ui/harness-ui-voice-providers.el`

- The stack declares `(tts 8880)` and no profile.
- `harness-voice-unmute--tts-url` asks `harness-voice-unmute-tts-url`
  first, then the running stack's `tts` `/v1/audio/speech`.
- `harness-voice-unmute-need` reports `Local voice stack · not running`
  when whisper is absent and `Text to speech endpoint unset` when only
  the TTS side is absent.
- `harness-voice-setup--insert` asks the selected stack for its state
  before it draws the provider rows, so a stale cached state from a
  stack started outside Emacs cannot report a service that is running.
- `harness-voice-unmute-voice` defaults to `af_heart`.
- The stack and provider doc strings name whisper.cpp and Kokoro.

`scripts/harness_voice_sidecar.py`

- `pcm_from_wav(data, rate=LOCAL_RATE)` returns PCM16 mono at the
  pipeline rate: it downmixes channels, resamples when the server's rate
  differs, and reads a streamed WAV to the end of its body.

`scripts/harness-voice-live-unmute`

- The default voice matches the stack, and the defaults point at the
  whisper.cpp and Kokoro ports of a stack run directly.

Docs: the stack's README, `docs/stacks.md`, `docs/voice.md`, the project
README and the generated `ui-voice` module page.

## What the user sees

- `M-x harness-voice-setup`, Local pipeline, `[Start]`: the stack line
  goes `◐ starting` to `● running` with `2 of 2 services`, and the
  provider row loses its red `Text to speech endpoint unset` note. The
  provider's own choice line, in `M-x harness-voice-select-provider`,
  reads `Local pipeline · live · ready`.
- `M-x harness-stacks` lists `whisper` and `tts`, each with its random
  loopback URL.
- The first spoken reply is synthesized locally and played at the right
  speed; the provider needs no URL, key or GPU.
- A user who runs their own speech service sets
  `harness-voice-unmute-tts-url` and `harness-voice-unmute-voice`; the
  stack's Kokoro service is not required then.

## Testing

- `test/harness-ui-voice-providers-test.el`: the two endpoints, no
  profile, the exact stack and provider doc copy, readiness copy with
  both services and with only whisper, the configured-URL override and
  the missing-endpoint errors.
- `test/harness-voice-gate-test.py`: 24 kHz to 16 kHz resampling,
  unchanged 16 kHz audio, stereo downmix, a streamed `0xffffffff` WAV,
  an unsupported sample width, the sidecar's synthesize path, and the
  default voice.
- Live: `voice-local` started through the stacks module; Kokoro's
  `/health` and `/v1/audio/speech` answered on the published port; a
  sidecar-shaped request returned RIFF audio at 24 kHz and the helper
  returned 16 kHz PCM; screenshots of the voice setup and stacks pages.
- The full `scripts/test.sh` before hand-in. The image pull and model
  are not part of the suite, since CI has no container runtime.

## Risks

- The first start pulls 1.45 GB and the first reply can wait on Kokoro's
  model load. The stack line shows `starting` and the image tag is
  overrideable.
- whisper.cpp and Kokoro both want CPU. On a slow machine a reply's
  synthesis may lag behind the agent; the sidecar reports a speech error
  and keeps the session, and the user can lower the whisper effort.
- Linear resampling is not an anti-aliasing filter. At 24 kHz to 16 kHz
  the speech band is well below the new Nyquist, so the small loss is
  acceptable for a spoken reply and avoids a heavy audio dependency.
- The pinned image tag can be withdrawn or moved upstream; `HARNESS_TTS_IMAGE`
  is the escape hatch, and the stack README documents it.
