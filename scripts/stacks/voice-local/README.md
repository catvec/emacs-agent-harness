# Local voice stack

A docker compose stack for the harness's `unmute` voice provider: speech
to text with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) or
NVIDIA [Parakeet TDT 0.6B](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), and text
to speech with [Kokoro](https://github.com/hexgrad/kokoro) behind
[Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI).

The harness starts it from `M-x harness-stacks`, or the voice setup
page, and selects the speech model there. By hand, name one speech
profile:

```sh
docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local \
    --profile whisper up -d
docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local \
    --profile parakeet up -d
```

## What runs

| Service | Port | Image | Profile | Purpose |
| --- | --- | --- | --- | --- |
| `whisper` | container 8080, random loopback | `ghcr.io/ggml-org/whisper.cpp:main` | `whisper` | `/inference` for speech to text |
| `parakeet` | container 8081, random loopback | built from `parakeet/Dockerfile` | `parakeet` | `/inference` and `/v1/audio/transcriptions` for speech to text |
| `tts` | container 8880, random loopback | `ghcr.io/remsky/kokoro-fastapi-cpu:v0.8.2` | none | `/v1/audio/speech` for text to speech |

The compose file publishes each port as `"127.0.0.1::8080"`,
`"127.0.0.1::8081"` or `"127.0.0.1::8880"`, so the runtime picks a free
loopback port: two stacks, or anything already on those ports, never
collide. `docker compose ... port SERVICE PORT` prints the one this
stack got.

`whisper` and `parakeet` are profile services: exactly one speech model
runs beside Kokoro, which has no profile and always starts. A by-hand
`up` must name one profile. Stopping must name every profile the stack
can run (`--profile whisper --profile parakeet down`), because compose
removes only the profiles a command enables; the harness does that from
its stacks page, and its model switch stops the previous engine first.

## Speech to text

Both engines answer the same shape the harness posts: one WAV upload in
a multipart `file` field, JSON with a `text` field back. The local voice
sidecar and `scripts/harness-voice-stt` therefore work with either, and
`harness-voice-stt-model` decides which one runs.

### Parakeet

The `parakeet` service is `parakeet/server.py` in a
`python:3.12-slim` image with sherpa-onnx pinned. It loads one model
from the `parakeet-models` volume; a missing model is downloaded from
the sherpa-onnx releases and unpacked there on first start. The model
directory is about 650 MB on disk, the download 460 MB.

| `PARAKEET_MODEL` | Language | `harness-voice-stt-model` |
| --- | --- | --- |
| `sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8` | English | `parakeet-0.6b` |
| `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` | 25 European languages | `parakeet-0.6b-v3` |

Both answer with punctuation and case. The model's `PARAKEET_FEATURE_DIM`
is 80 for v2 and 128 for v3; the harness sets both variables from the
model record. Further settings:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PARAKEET_THREADS` | `4` | Decoding threads |
| `PARAKEET_DOWNLOAD` | `1` | Set to `0` to refuse a download and require the volume to be complete |
| `PARAKEET_MODEL_URL` | the sherpa-onnx release URL | A mirror with the same `NAME.tar.bz2` layout |

`GET /health` answers once the model is loaded. The server loads one
model per process, averages stereo to mono, lets sherpa-onnx resample
and holds one decode at a time, which is short relative to the audio.

The weights are NVIDIA's `nvidia/parakeet-tdt-0.6b-v2` and `-v3`,
CC-BY-4.0; the int8 ONNX conversions are the sherpa-onnx project's.

### whisper.cpp

`WHISPER_MODEL` chooses the whisper.cpp model file, downloaded into the
`whisper-models` volume on first start. The harness sets it from the
voice effort level, or from a chosen whisper model:

| Effort | `WHISPER_MODEL` | Rough size | Notes |
| --- | --- | --- | --- |
| low | `ggml-tiny.en.bin` | 75 MB | fastest, least accurate; good on a laptop |
| medium | `ggml-base.en.bin` | 142 MB | the default; a reasonable CPU trade-off |
| high | `ggml-small.en.bin` | 466 MB | slower on CPU, noticeably better with accents |

The multilingual models (`ggml-tiny.bin` and so on) take any language;
the `.en` models are English only. A quantized large model
(`ggml-large-v3-turbo-q5_0.bin`, 574 MB) is a good middle ground on a
machine with more CPU. Set any of them by hand:

```sh
WHISPER_MODEL=ggml-small.en.bin docker compose -f scripts/stacks/voice-local/docker-compose.yml \
    -p voice-local --profile whisper up -d
```

## Text to speech

The `tts` service is Kokoro-FastAPI's CPU image: an OpenAI-compatible
`/v1/audio/speech` route with the Kokoro-82M model baked in. It accepts
the model name `tts-1`, answers WAV, and needs no key. `DEFAULT_VOICE`
names the voice it warms at startup; the image defaults to `af_heart`,
and the harness's `harness-voice-unmute-voice` names the same voice. Set
another voice from the shell:

```sh
HARNESS_TTS_VOICE=af_bella docker compose -f scripts/stacks/voice-local/docker-compose.yml \
    -p voice-local up -d
```

The provider posts the reply text to `/v1/audio/speech` and resamples
the WAV to 16 kHz before playback. If you point
`harness-voice-unmute-tts-url` at a service of your own, set
`harness-voice-unmute-voice` to a voice that service knows, such as
OpenAI's `alloy`.

Kokoro-FastAPI is not part of this repository. Its wrapper is Apache
2.0 and the Kokoro-82M weights are Apache 2.0; the image is pulled from
GitHub Container Registry. Check the image's own notices before
redistributing it.

## Images

The images are overridable, so a pinned tag, a local build or a mirror
works without editing the file:

```sh
HARNESS_WHISPER_IMAGE=ghcr.io/ggml-org/whisper.cpp:main \
HARNESS_PARAKEET_IMAGE=harness-voice-parakeet:2.0.1 \
HARNESS_TTS_IMAGE=ghcr.io/remsky/kokoro-fastapi-cpu:v0.8.2 \
docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local \
    --profile parakeet up -d
```

The Parakeet service has a `build:` context and an `image:` name, so the
first start builds and tags it; setting `HARNESS_PARAKEET_IMAGE` names
the tag of that build, or an image already built locally. Its Dockerfile
pins `sherpa-onnx==2.0.1` and installs numpy.

`whisper-entrypoint.sh` looks for the server at
`/app/build/bin/whisper-server` and, for older tags, `/app/whisper-server`;
the model downloader is looked for at `/app/models/download-ggml-model.sh`
and then `/app/download-ggml-model.sh`. If a tag moves those again, change
the entrypoint, not the sidecar: the sidecar only speaks HTTP.

## GPU and CPU

Every service runs on the CPU. whisper.cpp with `ggml-base.en.bin` is
real-time on a modern laptop, and larger models are not; Parakeet 0.6B
decodes several times faster than real time on a laptop CPU, and v3
costs the same as v2. Kokoro-82M is small enough for CPU use.
Kokoro-FastAPI also publishes a GPU image; set
`HARNESS_TTS_IMAGE=ghcr.io/remsky/kokoro-fastapi-gpu:v0.8.2` and give
the container a GPU (`--gpus all`, or the compose `deploy` reservation
for an NVIDIA device) when you want one. The Parakeet image is CPU-only;
a GPU build would replace it with a sherpa-onnx build that has CUDA.

## Network

The services share the compose network `voice-local_voice`, one
network per stack. A harness running on this machine reaches them
through the published loopback ports. A harness server running inside a
container is attached to that network by the `stacks` module (the
selected container runtime's `network connect`), so it can also reach
`http://whisper:8080`, `http://parakeet:8081` and `http://tts:8880` by
name; name the server's container with `HARNESS_SERVER_CONTAINER`, or
let it find itself inside the container.

## Checking it

```sh
stack="docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local --profile whisper"
curl -fsS "http://$($stack port whisper 8080)/"          # whisper.cpp answers
curl -fsS "http://$($stack port tts 8880)/health"        # Kokoro answers
curl -fsS -o reply.wav -H 'Content-Type: application/json' \
     -d '{"model":"tts-1","voice":"af_heart","input":"The merge queue is empty.","response_format":"wav"}' \
     "http://$($stack port tts 8880)/v1/audio/speech"    # and speaks
$stack ps
```

For Parakeet, the same with `--profile parakeet`:

```sh
stack="docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local --profile parakeet"
curl -fsS "http://$($stack port parakeet 8081)/health"
curl -fsS -F file=@recording.wav "http://$($stack port parakeet 8081)/inference"
```

The harness sidecar reports connection errors in the voice controls
until the services answer, so starting the stack and the voice session
in either order is fine.
