# Container compose stacks

The optional `stacks` module lets a module or a plugin declare the compose
services it needs beside the harness — a speech stack, a database, a search
index — and start and stop them from Emacs. The services run on the selected
[container runtime](container-runtime.md): Docker over its socket, or rootless
Podman.

```elisp
(require 'harness-stacks)

(harness-define-compose-stack 'voice-local
  :label "Local voice"
  :doc "whisper.cpp or Parakeet for speech to text and Kokoro for text to speech, on loopback."
  :directory (expand-file-name "scripts/stacks/voice-local" harness-directory)
  :project "voice-local"
  :network "voice"
  :endpoints '((whisper 8080) (parakeet 8081) (tts 8880))
  :profiles #'harness-voice-stack-profiles
  :all-profiles '("whisper" "parakeet")
  :env #'harness-voice-stack-env)
```

| Key | Meaning |
| --- | --- |
| `:directory`, `:file` | Where the compose file lives (`docker-compose.yml` by default) |
| `:project` | The compose project name (the id by default) |
| `:network` | The compose network the stack's services join, one per stack |
| `:endpoints` | Service name to its container port; the published loopback port is discovered |
| `:profiles` | Compose profiles every command enables, for services behind one; a list, or a function returning one for each command |
| `:all-profiles` | Every profile the stack can use, enabled by `down` so another selection's services go too |
| `:env` | A function returning extra environment variables for the stack's commands |

## Starting and stopping

| Command | Effect |
| --- | --- |
| `M-x harness-stacks` (or `M-x harness-compose-stacks`) | The stacks page: runtime, state, endpoints, `[Start]` and `[Stop]` |
| `M-x harness-compose-stack-up` | `RUNTIME compose -p PROJECT -f FILE up -d`, then join the network |
| `M-x harness-compose-stack-down` | `RUNTIME compose -p PROJECT -f FILE --profile … down`, with every profile the stack can use |
| `M-x harness-compose-stack-status` | `running`, `starting`, `stopped` or `error`, with a one-line detail |

Commands are argv lists, never shell snippets, and run in the stack's
directory. A missing runtime is one line in the state: `Executable unavailable ·
docker` for a CLI that is not installed, `Socket unavailable · /var/run/docker.sock`
for a Docker daemon the harness cannot reach. The stacks page names the selected
runtime and `[Change]` opens the runtime page.

## The network

Each stack gets its own container network, and its services publish their ports
on loopback with no fixed host port: `"127.0.0.1::8080"` in the compose file
publishes container port 8080 on a free loopback port the runtime picks. Two
stacks, or a program already on 8080, never collide.

`harness-compose-stack-endpoint` reads the published port from the runtime's
`compose ps` JSON and returns `http://127.0.0.1:PUBLISHED/PATH`. A stack may
still declare a fixed port as `(SERVICE HOST-PORT . CONTAINER-PORT)`; it wins
over the discovered one.

When the harness server runs in a container instead, the container joins the
stack's network with the runtime's `network connect` command, so the server
also reaches the services by name. `HARNESS_SERVER_CONTAINER` names that
container; without it, a process inside a container finds itself through
`/.dockerenv` and `HOSTNAME`. `HARNESS_STACK_NETWORK` names the network
outright when the compose file gives it a name of its own. An already attached
network counts as success.

## The bundled voice stack

`scripts/stacks/voice-local/` runs the local voice services:

| Service | Image | Port | What |
| --- | --- | --- | --- |
| `whisper` | `ghcr.io/ggml-org/whisper.cpp:main` | container 8080, random loopback | whisper-server, its model in a named volume; profile `whisper` |
| `parakeet` | built from `parakeet/Dockerfile` (`sherpa-onnx`) | container 8081, random loopback | Parakeet TDT 0.6B over `/inference`, its model in a named volume; profile `parakeet` |
| `tts` | `ghcr.io/remsky/kokoro-fastapi-cpu:v0.8.2` | container 8880, random loopback | Kokoro-FastAPI, an OpenAI-compatible `/v1/audio/speech` route on the CPU |

```sh
docker compose -f scripts/stacks/voice-local/docker-compose.yml -p voice-local \
    --profile whisper up -d
```

The `speech` module declares this stack as the harness server's local
voice pipeline and starts it from any client's voice setup list (`Pipeline`,
`[Start]`), or from `M-x harness-stacks`. Whisper and Parakeet are
profile services, so exactly one speech model runs beside Kokoro, and
the voice setup page's **Speech to text** choice names the profile. A
by-hand `up` names one: `--profile whisper` or `--profile parakeet`.
Kokoro's image is published; a first Parakeet start builds its small
image and downloads a 460 MB model into the stack's volume. The first
pull, that build and Kokoro's twenty-second model load are the large
part of a first start.

The `unmute` voice provider takes its speech-to-text URL from what the
harness reports for the running stack's service for the selected model
(`speech/status`), so the random port is never typed by hand, and its
text-to-speech URL from the stack's `tts` service, or from
`harness-voice-unmute-tts-url` when you point it at a service of your
own. With `harness-voice-stt-model` at `auto`, the whisper model is the
one `harness-voice-effort` picks: `ggml-tiny.en.bin` at **low**,
`ggml-base.en.bin` at **medium**, `ggml-small.en.bin` at **high**; the
server's `harness-speech-local-whisper` names it outright, and
`parakeet-0.6b` and `parakeet-0.6b-v3` are the Parakeet models, as
[voice.md](voice.md#speech-models) describes. The Kokoro voice is the
server's `harness-speech-local-voice` (`af_heart` by default), and the
client's `harness-voice-unmute-voice` names the voice it asks for;
`DEFAULT_VOICE` in the stack does the same. Both are harness server
settings. The images are overridable with `HARNESS_WHISPER_IMAGE`,
`HARNESS_PARAKEET_IMAGE` and `HARNESS_TTS_IMAGE`; see the stack's
README for the CPU and GPU cases and for a service of your own.

The stack belongs to the server: `harness-speech` requires
`harness-stacks`, registers the stack and calls it the local voice pipeline.
A client shows its state over ACP (`speech/status`) and needs no container
runtime of its own; when the harness's runtime is unavailable, the pipeline
line says what it still needs, such as `Socket unavailable ·
/var/run/docker.sock` or `Executable unavailable · podman`.

## What is verified

The registry, command construction, status parsing, dynamic port discovery,
the network join, the endpoints, the profile function, the all-profile `down`
and the page's copy are covered by `lisp/modules/harness-stacks-test.el`
without a daemon. The runtime seam is covered by
`lisp/modules/harness-container-runtime-test.el`. The compose files are checked with
`compose config`, which shows the empty published ports and the per-stack
network, and with each profile to show the services it enables. A real stack
on Docker was run by hand: it published a random loopback
port, answered through it, and a probe container reached its service by name
over the stack's network. The bundled voice stack was started through the
module the same way: whisper.cpp transcribed its `jfk.wav` sample, and
Kokoro's CPU image answered `/health` and an OpenAI-shaped
`/v1/audio/speech` request on its random loopback port. The Parakeet server's
routes, WAV decoding and model download are covered without Docker by
`test/harness-voice-parakeet-test.py`, and were run against the real
`sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8` model outside the image. Pulling
the speech images, building the Parakeet image and running the models in
containers is not part of the suite.
