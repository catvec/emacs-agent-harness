# Switching local speech models

## The fixed model

The local voice provider ran one speech-to-text engine, whisper.cpp,
and the only choice was an indirect one: `harness-voice-effort`, meant
for how much compute a provider may spend, picked `ggml-tiny.en.bin`,
`ggml-base.en.bin` or `ggml-small.en.bin` for the whole stack. There was
no way to run another engine, and whisper's small models are the
weakest part of an otherwise local pipeline. NVIDIA's Parakeet TDT 0.6B
is much better on English at roughly the same CPU budget: it decodes
about 7 seconds of audio in half a second, with punctuation and case,
while whisper base is real-time at best.

The model a person wants is a choice, not a compute level. It belongs on
the voice setup page next to the stack it runs in, and choosing one
should do what it says: stop the model that ran, start the one that was
chosen.

## Decision

The local speech-to-text model is a registry entry and a setting.

- `harness-define-voice-stt-model` registers a model: label, engine,
  download size, the compose service and profile that run it, the route
  it answers on, and the stack environment that loads it.
- `harness-voice-stt-model` names the model in use. `auto`, the default,
  keeps today's behaviour and follows `harness-voice-effort` to one of
  the three whisper models. Any other value picks that model outright;
  an unknown value falls back to the effort preset, so a stale setting
  never leaves local voice without a model.
- The bundled models are whisper tiny, base and small (English), and
  Parakeet 0.6B v2 (English) and v3 (25 European languages), the two
  int8 ONNX conversions the sherpa-onnx project publishes.
- The voice setup page grows a **Speech to text** line under the local
  stack, with the selected model's engine and download size and a
  `[Change]` control. `M-x harness-voice-select-stt-model` is the same
  choice from anywhere. Selecting a model stops a running live session
  (its sidecar holds the previous model's endpoint) and restarts a
  running stack.

Two engines in one compose file means a compose profile per engine:
`whisper` and `parakeet`, with Kokoro unprofiled. The stack record's
`:profiles` became a function, called for every compose command, so the
profile follows the setting. `down` enables every profile the stack can
use (`:all-profiles`): compose removes only the profiles a command
enables, and a stop that named only the new engine would leave the old
one running, invisible to `ps`.

The Parakeet service is a small image built from a Dockerfile in the
stack directory: `python:3.12-slim`, sherpa-onnx pinned, and a
standard-library HTTP server. The server speaks whisper.cpp's
`/inference` as well as the OpenAI `/v1/audio/transcriptions` route, so
neither the local sidecar nor `scripts/harness-voice-stt` changed: both
post a WAV in a `file` field and read `{"text": ...}` back. It loads
one model per process, averages stereo to mono, lets sherpa-onnx
resample, downloads its model directory into a volume on first start,
and answers `/health`.

## Why Parakeet through sherpa-onnx

The model is NVIDIA's; the runtime is not.

- **NVIDIA NeMo.** The reference implementation, and the shape a
  `.nemo` checkpoint wants. The toolchain pulls PyTorch and its CUDA
  stack for a model that runs in well under a second on a CPU; the image
  is several gigabytes before a model is downloaded.
- **A hand-written ONNX TDT decoder.** The converted ONNX files are
  small and CPU-friendly, but the transducer's blank/predictor loop,
  durations and vocabulary are work the sherpa-onnx project already
  maintains.
- **sherpa-onnx.** A 4 MB pip wheel on ONNX Runtime, with
  `OfflineRecognizer.from_transducer(model_type="nemo_transducer")`
  taking the encoder, decoder, joiner and tokens directly and resampling
  the input. It runs on the CPU, needs no key, and the same project
  publishes the int8 model directories, so the model's source is one
  URL.
- **An existing published server image.** There is no maintained CPU
  image that serves Parakeet over HTTP; the alternative is building one
  anyway, without the route compatibility this server adds.

Alternatives to the server's place in the stack, considered:

- **A second compose stack for Parakeet.** It would duplicate the Kokoro
  service (and its 1.45 GB image) in every stack, or need a stack that
  borrows another's network. Profiles keep one stack with one TTS
  service.
- **One `stt` service whose image, entrypoint and volumes are
  interpolated.** Compose can substitute the image name, but the
  whisper.cpp image and a Python image load the model differently;
  expressing both as variables makes the file harder to read than two
  services behind profiles, and `build` would run for whisper too.
- **Replacing whisper.cpp with sherpa-onnx's Whisper models.** It would
  make one image serve every model, but it changes a working path, its
  model names and its downloads to save one service definition.

The cost is a first start that builds the image and downloads 460 MB of
model (about 650 MB on disk), after which both live in a volume and a
local image cache. The compose model tag is pinned for a reproducible
build; `HARNESS_PARAKEET_IMAGE` and `PARAKEET_MODEL_URL` override the
image and the download mirror.

## Shape of the change

`scripts/stacks/voice-local/docker-compose.yml`

- `whisper` moves behind `profiles: ["whisper"]`; a `parakeet` service is
  added behind `profiles: ["parakeet"]`, built from `./parakeet`, with
  `PARAKEET_MODEL`, `PARAKEET_FEATURE_DIM` and `PARAKEET_THREADS`, the
  `parakeet-models` volume, port `127.0.0.1::8081` and the stack's
  network. `tts` is unchanged.

`scripts/stacks/voice-local/parakeet/`

- `Dockerfile`: `python:3.12-slim`, `sherpa-onnx==2.0.1`, numpy.
- `server.py`: the registry-free runtime. It checks a model directory,
  downloads and safely extracts its tar.bz2 when missing, adapts WAV
  uploads (1/2/3/4-byte samples, any channel count) to mono floats, and
  answers `/inference`, `/v1/audio/transcriptions` and `/health`. It
  has a `--self-test` that checks those routes and the readers without a
  model.

`lisp/ui/harness-ui-voice-providers.el`

- The speech model registry, `harness-voice-stt-model`, the `auto`
  resolution that follows the effort levels, the choice text and reader,
  `harness-voice-select-stt-model`, and the setup line.
- `harness-voice-unmute--stt-endpoint` reads the selected model's
  service and route, and the missing-service reason reads `Speech to
  text service · not running`.
- The `voice-local` stack declares the `parakeet` endpoint, the profile
  function, `:all-profiles` and the model's environment. Its doc and the
  provider's say whisper.cpp or Parakeet.

`lisp/modules/harness-stacks.el`

- `:profiles` may be a function, `:all-profiles` names every profile for
  `down`, and `harness-compose-stack-down` enables them. Nothing else
  changes for a stack without profiles.

Docs: the stack's README, `docs/voice.md`, `docs/stacks.md`, the
project README, the generated `ui-voice` module page.

## What the user sees

- `M-x harness-voice-setup`, with **Local pipeline** selected, shows
  `Local voice stack` and under it
  `Speech to text  Effort preset · Whisper base (English) · 142 MB  [Change]`.
  `[Change]` lists `Parakeet 0.6B (English) · sherpa-onnx · 650 MB`, the
  v3 multilingual model and the three whisper models, with `Effort
  preset` first. Under `auto` the effort buttons pick the whisper model
  and restart a running stack the same way; with a model chosen they
  change only the provider's own fragments.
- Choosing Parakeet: the line reads `Speech to text  Parakeet 0.6B
  (English) · sherpa-onnx · 650 MB`, a running live session ends, and a
  running stack reads `◐ starting` again. When it is `● running`, the
  first utterance is transcribed by Parakeet.
- `M-x harness-stacks` lists the stack; `compose ps` shows `parakeet` and
  `tts`, and after switching back, `whisper` and `tts` — never both
  speech engines.
- The first Parakeet start downloads its model; the container log names
  the URL and the unpack. Until the server listens, the provider says
  `Speech to text service · not running`.
- A user who runs their own speech service sets
  `harness-voice-unmute-stt-url` and no stack is required.

## Testing

- `lisp/ui/harness-ui-voice-providers-test.el`: the model registry, the
  `auto` resolution and its fallbacks, choice copy, the stack's profile,
  endpoints and environment, the selected service's URL, the setup
  line's exact words and tooltips, the selection stopping a session and
  restarting only when the resolved model changes, and the server's
  `--self-test` plus its Python suite.
- `lisp/modules/harness-stacks-test.el`: function profiles on every
  command, and `down` with every profile.
- `test/harness-voice-parakeet-test.py`: multipart fields and boundaries,
  the two routes, text and JSON responses, stereo downmix and rate,
  missing/oversized/invalid uploads, a failing recognizer, the model
  directory check, a download from a `file://` archive, and a refused
  archive that leaves the destination.
- Real model: the server was run against
  `sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8` with `PARAKEET_TEST_MODEL`
  set, and its own test WAV transcribed to the sentence the sherpa
  project publishes; `scripts/harness-voice-stt` and the sidecar's
  multipart helper both read the text from `/inference`.
- Live: the setup page and the stacks page in a development harness;
  the container runtime is not part of the suite, and this task's
  sandbox has no Docker daemon, so the compose build is checked with
  `docker compose config` for both profiles rather than a start.
- Full `scripts/test.sh` and `scripts/lint.sh` before hand-in.

## Risks

- **A 460 MB download on first start.** It is one time per volume, its
  URL and progress are in the container log, and `PARAKEET_MODEL_URL`
  points at a mirror. A failed download says so and leaves the stack
  without a speech service, which the voice setup names.
- **English is the default model's limit.** v2 is English; the v3 entry
  is the multilingual one. A user who speaks another language picks v3
  or a whisper multilingual model of their own; the registry has no
  language gate.
- **Parakeet's license and provenance.** The weights are NVIDIA's
  `nvidia/parakeet-tdt-0.6b-v2`, CC-BY-4.0; the conversions are the
  sherpa-onnx project's. The README says both, as the Kokoro section
  names its licenses.
- **Compose profile semantics.** `down` must name a profile's services
  to remove them, which is why the stack declares `:all-profiles` and
  `down` uses it. A stack that adds a profile without adding it there
  can leave a container behind; the stack README and the module's
  commentary say so.
- **The image build is untested here.** The Dockerfile pins the one
  package whose API the server uses and a CI without a runtime cannot
  build it; the server itself is tested without Docker, and the compose
  file is validated for both profiles.
