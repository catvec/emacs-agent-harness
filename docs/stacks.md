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
| `M-x harness-compose-stack-log` | The last command the stack ran, where, its exit status and its whole output |

Commands are argv lists, never shell snippets, and run in the stack's
directory. A missing runtime is one line in the state: `Executable unavailable ·
docker` for a CLI that is not installed, `Socket unavailable · /var/run/docker.sock`
for a Docker daemon the harness cannot reach. The stacks page names the selected
runtime and `[Change]` opens the runtime page.

## When a command fails

A command runs with pipes, not with the pseudo-terminal Emacs would
otherwise give a process, and its standard output and standard error are
kept as it wrote them. Its exit status and its output are remembered as the
stack's last command (`harness-compose-stack-last-command`), whether it
started the stack, stopped it or only asked its state.

The state's detail is the exit status and the reason: `exit 1 · Error: no
image found in manifest list for architecture "arm64"`. The reason is the
line that says what went wrong, and a runtime's own wrapper is skipped:
`podman compose` runs an external provider (`/opt/homebrew/bin/podman-compose`
from Homebrew, say), and when the provider fails podman ends its output with
one line naming that provider, its whole argv and the exit status. That line
is the last and the least it says; the provider's own complaint came before
it, and it is what the detail keeps.

The reason is never cut to a width. The reason a command failed is what the
detail is for, and cutting it where it passes some column is what made the
failure unreadable in the first place — `exit 1 · Error: executing
/opt/homebrew/bin/podman-compose -p voice-local -f /Users/… up: exit status
1` is the wrapper line, and shortening it leaves neither the reason nor the
command. Progress before the reason is still dropped, and a runtime's
control sequences with it; what stays is the line that says what failed,
whole.

On the stacks page a failed stack puts that line under its row, indented
with the endpoints, and the row itself keeps `[Start]` and `[Log]` where
they are: a reason long enough to push them off the row would be a row
whose buttons move with every message. A short detail — `2 of 2 services`,
`No services` — stays on its row, where it says the state. A client of its
own truncates for the width it knows, and the tooltip and the log carry the
whole of it.

`[Log]` on the stacks page — `M-x harness-compose-stack-log` — shows the
whole of it: the exact argv as a shell command line, the directory it ran in,
the environment the stack added, the exit status and every line of output.
The same log is `speech/log` for the voice pipeline, and
`harness-speech--describe` carries the command, the directory and the exit
status in `speech/status` for a client that wants to say what failed.

### Compose providers that differ

Docker Compose and podman-compose are not the same program, and a stack that
runs on one can fail on the other. Two differences the harness handles for
both:

- **The working directory.** Docker Compose reads the file's own directory as
  the project's; podman-compose reads the directory its command runs in.
  Running every command in the stack's directory makes the file's relative
  volumes and build contexts mean the same thing to either (`:directory` of
  the stack record).
- **Standard input and output.** A provider decides what to do by what its
  own streams are. Emacs gives `make-process` a pseudo-terminal unless it is
  told not to, and the harness tells it not to, so a provider that reads its
  standard input -- `-f -`, a prompt -- sees the end of the input it was given
  instead of waiting for a terminal that never answers.

What neither runtime can do is run an image that has no build for the
machine's architecture: the whisper.cpp image is published for `linux/amd64`
only, and an Apple-silicon podman machine is `linux/arm64`, so its pull fails
with `no image found in manifest list for architecture "arm64", variant "v8",
OS "linux"`. The reason then names exactly that, and `HARNESS_WHISPER_IMAGE`
takes an image built for the machine instead.

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
the network join, the endpoints, the profile function, the all-profile `down`,
the page's copy, the log and the reason a failed command reports are covered by
`lisp/modules/harness-stacks-test.el` without a daemon. It holds a
podman-shaped failure verbatim — the provider's own error, then podman's
wrapper line naming `/opt/homebrew/bin/podman-compose` and its argv — and
asserts the exact detail and the exact log. The runtime seam is covered by
`lisp/modules/harness-container-runtime-test.el`, which runs a real command
through the asynchronous runner and asserts that it gets pipes rather than a
terminal, runs in the directory it was given, and reports both streams and a
nonzero status. The compose files are checked with
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
