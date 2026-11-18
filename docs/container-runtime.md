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
declared, and picks the first whose CLI and compose provider answer. When none
answers, it names the first whose CLI is *installed*: a machine with Podman and
no Docker is told about its Podman, not about the Docker it never installed.
Availability is cached for thirty seconds and asked again on a refresh.

## Where the CLI is looked for

A CLI is looked for on `exec-path` first, then in
`harness-container-runtime-program-directories`:

```elisp
(setq harness-container-runtime-program-directories
      '("/opt/homebrew/bin" "/usr/local/bin" "/opt/local/bin"))
```

That list is what makes voice mode work on macOS. An Emacs started from the
Dock has only the system's directories on `exec-path`, so a Homebrew Podman is
invisible to it, and before this the runtime reported `Executable unavailable ·
docker` on a Mac that had Podman all along. The directory a CLI is found in is
put at the front of the PATH of its commands, so the compose provider it
delegates to (`podman compose` runs an external `podman-compose`) is found
beside it, and the CLI itself is run by its absolute path.

The runtimes page shows the program it resolved, as `Program  /path/to/cli`,
next to the socket.

## The engine the sandbox shows

`harness-container-runtime-engine` answers, without running anything, which
backend, CLI and socket the harness uses:

```elisp
(harness-container-runtime-engine)  ; (:id podman :label "Podman" :program "…" :socket nil)
```

The sandbox reads it for `sandbox/containers` and for `:containers` on
`sandbox/wrap`, so a container command inside a sandbox reaches the same engine
the stacks use: a machine whose stacks run on Podman is shown no Docker socket
it never had. It runs nothing and asks no backend whether it answers, because
that question is the sandbox's own probe; asking it there would be a circle.
When the container runtime module is not loaded, the sandbox falls back to the
first socket at a known path and the first of `docker` and `podman` installed.

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

## Container workflows inside a sandbox

A Harness sandbox does not show a container command what it needs by default,
and "Docker unavailable" is not one fact but five. The sandbox module's
`sandbox/containers` probe reports which stage fails, and its reason is what
the runtimes page shows instead of a generic socket line:

| Stage | Reason | What to do |
| --- | --- | --- |
| `binary` | `Container CLI missing · LABEL` (the engine's, or `docker, podman` with no runtime module) | install the CLI in the sandbox's image, or use a backend that has it |
| `sysfs` | `Sysfs unavailable · /sys` | the sandbox must show `/sys` read-only (an older harness build did not) |
| `cgroup` | `Cgroup filesystem absent · /sys/fs/cgroup` | the host must delegate the cgroup file system; a jail with a private `/` cannot make one |
| `socket` | `Engine socket unavailable · PATH` | start the daemon, or tell the harness where its socket is with `DOCKER_HOST` |
| `permission` | `Engine socket permission · PATH` | the user needs to be in the socket's group; the harness grants nothing itself |
| `policy` | `Sandbox policy off · no confinement` | the sandbox policy has to confine commands before a socket can be shown |

A request for containers is made with `:containers` on `sandbox/wrap`. What it
adds is deliberately small: a private `/run` of the command's own, `/sys`
read-only (which carries `/sys/fs/cgroup` with it), and the engine's socket
read-only at the path it already has. It never binds `/run` whole, never binds
a socket writable, never adds a Linux capability and never makes a container
privileged. A backend that cannot give it — systemd-run, MXC, OpenShell, the
`off` policy, a remote directory — signals `harness-sandbox-unavailable`
rather than let the command reach an engine outside the jail.

### What is supported, and what is not

| Path | Supported | Requirements |
| --- | --- | --- |
| Docker over the host's socket | yes, measured end to end | a daemon; `docker` and a compose provider in the sandbox; the user in the socket's group |
| Rootless Podman, no daemon | yes, measured end to end | a static podman bundle; `storage-opt ignore_chown_errors=true`; `netns = "host"`; the helper binaries on `helper_binaries_dir` |
| A nested engine with its own cgroups and subuid ranges | no | the jail's `/` is a parent-owned tmpfs: it cannot mount `/sys`, and bwrap maps one uid, so `newuidmap` cannot get a range |
| A bridge network inside the jail | no | netavark needs the network and cgroup authority the jail does not have; use the Docker path, or `netns=host` with one service |

The two supported paths were run through the harness's own `sandbox/wrap`, with
a real compose stack (service readiness, a second container reaching the
service by name, teardown, and no container or network left). The exact
commands are `scripts/container-sandbox-e2e.sh`, and its output is kept in
`docs/evidence/`. A host without a daemon reports `Engine socket unavailable ·
/var/run/docker.sock`, and the podman path needs the bundle; the harness does
not download one itself.

### The security boundary

Binding the host's Docker socket into a sandbox does not widen what anyone can
do: a process that can reach that socket can manage every container on the
machine, and on this host that is membership of the `docker` group, which the
user already has. Rootless Podman's socket is the *user's*, so a sandbox that
reaches it reaches containers its user could start anyway, not the host
daemon. Nothing in this module enables a privileged container, adds a
capability, or changes a host setting; the probe reads state and starts
nothing.

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
order, the explicit choice that never falls back, the `auto` fallback to an
installed CLI, availability caching, socket discovery, `DOCKER_HOST`, the
compose and network argv, a CLI that is only off `exec-path`, the engine
answer, the process runners and the exact copy of the runtimes page, all
without a daemon. `lisp/modules/harness-speech-test.el` holds the macOS case:
Docker absent, Podman only in a program directory, and the voice pipeline
starts through Podman with no engine setting of its own. A real Docker daemon
with its socket at `/run/docker.sock` was used by hand through this module to
start a compose stack on its own network, publish a random loopback port and
reach a service by name from another container; the bundled voice stack's
whisper service was started the same way and transcribed a sample.
