# Local voice stack

A docker compose stack for the harness's `unmute` voice provider: speech
to text with [whisper.cpp](https://github.com/ggml-org/whisper.cpp), and
[Kyutai Unmute](https://github.com/kyutai-labs/unmute) for the
OpenAI-compatible speech endpoints the sidecar posts to.

The harness starts it from `M-x harness-stacks`, or the voice setup
page; by hand:

```sh
docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local up -d
```

## What runs

| Service | Port | Image | Purpose |
| --- | --- | --- | --- |
| `whisper` | container 8080, random loopback | `ghcr.io/ggml-org/whisper.cpp:main` | `/inference` and `/load` for speech to text |
| `unmute` | container 8000, random loopback | `kyutai/unmute:latest` | `/v1/audio/transcriptions` and `/v1/audio/speech` |

The compose file publishes each port as `"127.0.0.1::8080"`, so the
runtime picks a free loopback port: two stacks, or anything already on
8080, never collide. `docker compose ... port SERVICE PORT` prints the
one this stack got.

By hand, only `whisper` starts by default: Kyutai Unmute is behind the
`unmute` profile, because it is the heavy service. The harness passes
the profile, so `[Start]` in `M-x harness-stacks` starts both services
and `[Stop]` stops both:

```sh
docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local --profile unmute up -d
```

The voice provider in Emacs does not need Unmute when whisper.cpp runs:
set `harness-voice-unmute-stt-url` to
`http://127.0.0.1:8080/inference` and point
`harness-voice-unmute-tts-url` at any OpenAI-compatible speech endpoint,
such as a Piper server. With both options nil (the default) the
provider reads the random loopback ports this stack published for the
two services, so nothing has to be copied by hand.

## Models and effort

`WHISPER_MODEL` chooses the whisper.cpp model file, downloaded into the
`whisper-models` volume on first start. The harness sets it from the
voice effort level:

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
WHISPER_MODEL=ggml-small.en.bin docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local up -d
```

## Images

Both images are overridable, so a pinned tag or a local build works
without editing the file:

```sh
HARNESS_WHISPER_IMAGE=ghcr.io/ggml-org/whisper.cpp:main \
HARNESS_UNMUTE_IMAGE=kyutai/unmute:latest \
docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local up -d
```

`whisper-entrypoint.sh` looks for the server at
`/app/build/bin/whisper-server` and, for older tags, `/app/whisper-server`;
the model downloader is looked for at `/app/models/download-ggml-model.sh`
and then `/app/download-ggml-model.sh`. If a tag moves those again, change
the entrypoint, not the sidecar: the sidecar only speaks HTTP.

## GPU and CPU

Kyutai Unmute is built for a GPU; the upstream project documents its
CUDA and Apple Silicon setups, and its image needs the NVIDIA container
toolkit (`--gpus all`, or `deploy.resources.reservations.devices` in a
compose file) to use one. On a CPU-only machine, build Unmute for CPU
following its README, point `HARNESS_UNMUTE_IMAGE` at that build, or run
whisper.cpp alone and set `harness-voice-unmute-tts-url` to a CPU
text-to-speech service: then start only the `whisper` service rather
than the whole stack. Speech to text on CPU with `ggml-base.en.bin` is real-time
on a modern laptop; larger models are not.

## Network

The services share the compose network `voice-local_voice`, one
network per stack. A harness running on this machine reaches them
through the published loopback ports. A harness server running inside a
container is attached to that network by the `stacks` module (the
selected container runtime's `network connect`), so it can also reach
`http://whisper:8080` and `http://unmute:8000` by name; name the
server's container with `HARNESS_SERVER_CONTAINER`, or let it find
itself inside the container.

## Checking it

```sh
stack="docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local"
curl -fsS "http://$($stack port whisper 8080)/"          # whisper.cpp answers
curl -fsS "http://$($stack port unmute 8000)/v1/models"  # Unmute answers, with the profile
$stack ps
```

The harness sidecar reports connection errors in the voice controls
until the services answer, so starting the stack and the voice session
in either order is fine.
