# Container runtimes

The optional `container-runtime` module is the seam between
[compose stacks](stacks.md) and the daemon they run on. A stack never calls
`docker` or `podman` itself: it asks the runtime for the compose command, the
network command and the environment the commands need, so adding a backend
changes no stack.

## The bundled backends

| Backend | CLI | Socket | What |
| --- | --- | --- | --- |
| Docker | `docker compose` | `/var/run/docker.sock` | The shared Docker daemon, over its Unix socket |
| Podman | `podman compose` | none | Rootless Podman: no daemon and no socket, so it can run in a jail |

A backend that is not available does not silently fall back when it was chosen
outright: the stacks and runtimes pages say what it still needs, such as
`Executable unavailable · podman` or `Socket unavailable · /var/run/docker.sock`.

## Choosing a runtime

```elisp
(setq harness-container-runtime 'auto)    ; Docker when it answers, else Podman
(setq harness-container-runtime 'docker)  ; the shared daemon
(setq harness-container-runtime 'podman)  ; rootless, no daemon
```

`M-x harness-container-runtimes` shows the backends, which one is in use, the
socket and a `[Select]` button for each. `M-x harness-container-runtime-select`
does the same from the keyboard. The stacks page shows the selected runtime and
`[Change]` opens this page.

`auto` asks Docker first and Podman second, followed by any backend a plugin
declared, and picks the first whose CLI and compose provider answer. Availability
is cached for thirty seconds and asked again on a refresh.

## The Docker socket

The socket is not assumed to be at one path:

1. `DOCKER_HOST`, when it names a Unix socket (`unix:///run/docker.sock`);
2. the backend's declared path, `/var/run/docker.sock`;
3. `/run/docker.sock`, where a sandbox or a rootless daemon often shows it.

When the socket is found at another path, the runtime adds
`DOCKER_HOST=unix://PATH` to every command it runs, so the CLI looks there too.
The `[Request]` button on the runtimes page asks again; if a socket is found
elsewhere it sets `DOCKER_HOST` for the session and reports `Socket found · PATH`.

Nothing here grants the socket: seeing and connecting to it is the user's
sandbox, group or daemon permission. Podman is the backend that needs no socket
at all.

## Adding a backend

```elisp
(harness-define-container-runtime 'my-runtime
  :label "My runtime"
  :doc "A compose-compatible CLI over a socket."
  :command '("my-runtime")
  :compose '("my-runtime" "compose")
  :socket "/run/my-runtime.sock"
  :needs '((executable "my-runtime")
           (socket "/run/my-runtime.sock")))
```

`:command` is the argv prefix of the CLI, `:compose` the compose command,
`:socket` the socket it talks to (or nil), and `:needs` what it needs:
`(executable NAME)`, `(socket PATH)`, or a function returning a one-line reason
when it cannot run. The availability check runs `compose version`, so a missing
compose plugin is reported as plainly as a missing daemon.

## What is verified

`lisp/modules/harness-container-runtime-test.el` covers the registry, the automatic
order, the explicit choice that never falls back, availability caching, socket
discovery, `DOCKER_HOST`, the compose and network argv, the process runners and
the exact copy of the runtimes page, all without a daemon. A real Docker daemon
with its socket at `/run/docker.sock` was used by hand through this module to
start a compose stack on its own network, publish a random loopback port and
reach a service by name from another container; the bundled voice stack's
whisper service was started the same way and transcribed a sample.
