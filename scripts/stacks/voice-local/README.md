# Local voice stack

A docker compose stack for the harness's `unmute` voice provider: speech
to text with [whisper.cpp](https://github.com/ggml-org/whisper.cpp), and
text to speech with [Kokoro](https://github.com/hexgrad/kokoro) behind
[Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI).

The harness starts it from `M-x harness-stacks`, or the voice setup
page; by hand:

```sh
docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local up -d
```

## What runs

| Service | Port | Image | Purpose |
| --- | --- | --- | --- |
| `whisper` | container 8080, random loopback | `ghcr.io/ggml-org/whisper.cpp:main` | `/inference` for speech to text |
| `tts` | container 8880, random loopback | `ghcr.io/remsky/kokoro-fastapi-cpu:v0.8.2` | `/v1/audio/speech` for text to speech |

The compose file publishes each port as `"127.0.0.1::8080"` or
`"127.0.0.1::8880"`, so the runtime picks a free loopback port: two
stacks, or anything already on 8080 or 8880, never collide. `docker
compose ... port SERVICE PORT` prints the one this stack got.

Both services start with the stack. whisper.cpp runs on the CPU and
downloads its model into the `whisper-models` volume on first start;
Kokoro-FastAPI's CPU image has the Kokoro-82M model baked in and is
ready after its first model load, about twenty seconds.

## Speech to text

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

## Text to speech

The `tts` service is Kokoro-FastAPI's CPU image: an OpenAI-compatible
`/v1/audio/speech` route with the Kokoro-82M model baked in. It accepts
the model name `tts-1`, answers WAV, and needs no key. `DEFAULT_VOICE`
names the voice it warms at startup; the image defaults to `af_heart`,
and the harness's `harness-voice-unmute-voice` names the same voice. Set
another voice from the shell:

```sh
HARNESS_TTS_VOICE=af_bella docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local up -d
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

The whisper and text-to-speech images are overridable, so a pinned tag
or a local build works without editing the file:

```sh
HARNESS_WHISPER_IMAGE=ghcr.io/ggml-org/whisper.cpp:main \
HARNESS_TTS_IMAGE=ghcr.io/remsky/kokoro-fastapi-cpu:v0.8.2 \
docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local up -d
```

`whisper-entrypoint.sh` looks for the server at
`/app/build/bin/whisper-server` and, for older tags, `/app/whisper-server`;
the model downloader is looked for at `/app/models/download-ggml-model.sh`
and then `/app/download-ggml-model.sh`. If a tag moves those again, change
the entrypoint, not the sidecar: the sidecar only speaks HTTP.

## GPU and CPU

Both services run on the CPU. whisper.cpp with `ggml-base.en.bin` is
real-time on a modern laptop, and larger models are not; Kokoro-82M is
small enough for CPU use. Kokoro-FastAPI also publishes a GPU image; set
`HARNESS_TTS_IMAGE=ghcr.io/remsky/kokoro-fastapi-gpu:v0.8.2` and give
the container a GPU (`--gpus all`, or the compose `deploy` reservation
for an NVIDIA device) when you want one.

## Network

The services share the compose network `voice-local_voice`, one
network per stack. A harness running on this machine reaches them
through the published loopback ports. A harness server running inside a
container is attached to that network by the `stacks` module (the
selected container runtime's `network connect`), so it can also reach
`http://whisper:8080` and `http://tts:8880` by name; name the
server's container with `HARNESS_SERVER_CONTAINER`, or let it find
itself inside the container.

## Checking it

```sh
stack="docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local"
curl -fsS "http://$($stack port whisper 8080)/"          # whisper.cpp answers
curl -fsS "http://$($stack port tts 8880)/health"        # Kokoro answers
curl -fsS -o reply.wav -H 'Content-Type: application/json' \
     -d '{"model":"tts-1","voice":"af_heart","input":"The merge queue is empty.","response_format":"wav"}' \
     "http://$($stack port tts 8880)/v1/audio/speech"    # and speaks
$stack ps
```

The harness sidecar reports connection errors in the voice controls
until the services answer, so starting the stack and the voice session
in either order is fine.
