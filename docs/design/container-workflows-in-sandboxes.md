# Container workflows inside Harness sandboxes

Status: implemented on this task's branch. Tracking thread:
https://chatgpt.com/c/6af69ea3-9d4c-8191-bb5d-52dcf04af016

## Problem

The native Android parity task t-v8hy4zr4 reported "Docker unavailable" inside
its sandbox, while Docker Compose is installed on the host. That single word
conflated five different things. This document separates them, states what the
harness can honestly support, and adds the one capability that makes the
supported case work without widening anyone's authority.

## What was measured

Every probe below ran in a real Harness sandbox, not on the host. The task
sandbox is a `bwrap` jail: a tmpfs `/`, read-only `/usr` and `/etc`, a private
`/dev` and `/proc`, a `/tmp` that is the session's temporary directory, and a
tmpfs over `/home/noah`. There is no `/run`, no `/var/run` and no `/sys` in it.

| Probe | Result | What it means |
| --- | --- | --- |
| `command -v docker docker-compose` | `/usr/bin/docker`, `/usr/bin/docker-compose` (29.8.1, Compose 5.5.1) | The binary is present and on `PATH`. "Docker unavailable" was never a missing binary. |
| `ls /var/run/docker.sock`, `ls /run` | both `No such file or directory` | The socket is not visible; neither is the directory that holds it. |
| `docker version` | `failed to connect to the docker API at unix:///var/run/docker.sock … connect: no such file or directory` | The CLI is right, the endpoint is unreachable. |
| `command -v podman` | not found | Podman is not installed on this host at all. |
| `unshare --pid --fork` | `unshare failed: Operation not permitted` | The jail already has a PID namespace; a nested one is refused. |
| `unshare --user --map-root-user` | works | A user namespace *can* be nested. |
| `unshare --user --map-root-user --net` | works, `lo` comes up | A nested network namespace works. |
| overlay-on-tmpfs inside a nested userns | works | `overlay` is not the blocker. |
| `newuidmap` inside the jail | `newuidmap: Could not set caps` | `NoNewPrivs` is 1, so the setuid helper cannot elevate. |
| `dockerd --rootless` | `dockerd needs to be started with root privileges … RootlessKit` | Docker's rootless mode needs RootlessKit, which is not installed. |
| `dockerd` inside a nested userns | `chown …: invalid argument` | The daemon cannot create its own socket there. |
| podman-static, `podman info` | `Error determining cgroups mode` | `/sys/fs/cgroup` does not exist in the jail. |
| `mount -t sysfs` inside the jail | `permission denied` | `/` is a parent-owned tmpfs; the jail cannot mount `/sys` for itself. |

The decisive point: the jail's shape, not the host's packages, is what refuses
a container engine. The engine needs three things the jail does not show — an
endpoint (a socket), `/sys/fs/cgroup` to account for processes, and either a
multi-id user namespace or a delegated cgroup subtree to make a container's
own root not the host's root.

## The two supported paths, both measured end-to-end

### A. Docker over the host socket, as a least-authority bind

When the host runs a Docker daemon, the jail needs the socket *file* and a
read-only `/sys`, and nothing else. Measured inside a harness-shaped jail on
the host:

```
srw-rw---- 1 nobody nobody 0 /run/docker.sock
29.8.1 overlayfs
 Container e2eprobe-web-1 Started
READY after 1s
 Container e2eprobe-client-run-… Created
READY                      # a second container reaching the service by name
e2eprobe-web-1 Up 2 seconds
 Container e2eprobe-web-1 Removed
 Network e2eprobe_default Removed
                           # no leftover container, no leftover network
```

The socket is bound at its own path alone (`--ro-bind /run/docker.sock
/run/docker.sock`), never all of `/run`, and `/sys` is bound read-only. A
container this jail started reports `user=[] privileged=false capadd=[[]]
devices=[[]] networkmode=bridge`: no privileged container, no added capability,
no device of the host's.

### B. Rootless Podman, no host daemon at all

Podman's own rootless service socket is a socket of the user's, not the host's
daemon, so it needs no host authority. Measured inside the same jail with a
static podman bundle:

```
 Image busybox:latest Pulled
 Container work-web-1 Creating … Started
work-web-1 Up Less than a second
READY                      # HTTP body fetched from the service
 Container work-web-1 Stopped … Removed
                           # no leftover container
```

This path needs `--storage-opt ignore_chown_errors=true` (single-id mapping
cannot chown an image's `nobody`-owned paths), `netns = "host"` in
`containers.conf` (a nested netavark network would need the cgroup and netns
authority the jail does not have), and helper binaries on
`helper_binaries_dir`. Compose itself works because podman delegates to the
`docker compose` provider over podman's own socket.

### What is *not* supported, with the evidence above

A nested engine that needs its own cgroups, its own multi-id user namespace or
its own network stack is not available in a `bwrap` jail whose `/` is a
parent-owned tmpfs. That is `dockerd` inside the jail, a rootless podman with
real subuid ranges, and a netavark bridge network. The engine's own error says
which of the three it wanted; the probe reports exactly that line.

## The change

One new capability on the existing generic seam, `sandbox/wrap`, plus a probe
that answers "what would it take for a container to run here" as data.

- `sandbox/wrap` takes `:containers` — a request for the mounts a container
  CLI needs and nothing more: the session's `/run` as a private tmpfs, the
  declared socket file read-only at its own path, and `/sys` read-only
  (which carries `/sys/fs/cgroup` with it). It never binds `/run` whole, never
  binds the socket read-write, and never adds a capability. A backend that
  cannot give it (systemd-run, MXC, OpenShell, the `off` policy, a remote
  directory) signals `harness-sandbox-unavailable` rather than run the command
  with less.
- `sandbox/containers` is the staged probe. It answers one stage at a time —
  `policy`, `backend`, `binary`, `sysfs`, `cgroup`, `socket`, `permission` —
  each with a one-line reason and the next step, so a caller can say which of
  the five conflated things actually happened.  Whether a user namespace can
  be nested is reported as `:nesting`, as a fact rather than a failing stage:
  the two supported paths below do not need one.
- `container-runtime` reports the probe's reason in place of the old generic
  `Socket unavailable`, so a runtime the sandbox cannot serve says which
  stage failed.  The page itself is unchanged: its reason column already
  carries that line, and no new button was added.

## Security boundary

Unchanged, and deliberately so:

- The host Docker socket is the host's authority. Binding its file read-only
  into the jail does not widen it: whoever can connect to it can already
  manage every container on the machine, and on this host that is membership
  of the `docker` group (gid 10002), which the user already has. The harness
  never gains a socket the user does not have.
- Nothing here enables privileged containers, adds a Linux capability, changes
  a host setting, or makes a container's root the host's root.
- Rootless Podman's socket is the *user's* socket. A sandbox that reaches it
  reaches containers the user could start anyway; it does not reach the host
  daemon.
- The probe reads state; it starts nothing. The one command it runs is the
  runtime's own `version`, which the module already ran.

## Prerequisites, by path

| Path | Prerequisite | Diagnostic when missing |
| --- | --- | --- |
| Docker socket | a daemon on the host; `docker` and a compose provider in the jail; the user in the socket's group | `Socket unavailable · PATH`, `Socket permission · PATH`, `Compose provider unavailable · docker` |
| Rootless Podman | `podman`, a compose provider, a static bundle or a host install; `ignore_chown_errors`; `netns=host` | `Executable unavailable · podman`, `Podman storage · vfs`, `Podman network · host` |
| Either | read-only `/sys` from the host, which the harness now binds | `Sysfs unavailable · /sys/fs/cgroup` |

## Alternatives considered

- **Expose `/run` whole.** Rejected: it shows every socket the user can reach,
  of which the container socket is one.
- **Mount the socket read-write.** Rejected: the socket's mode already decides
  who may connect; a read-write bind would only widen what a container can
  change on the host.
- **Privileged containers or added capabilities to satisfy the engine.**
  Rejected: it converts the sandbox into a way to become host root.
- **A daemon on demand in a nested namespace.** Measured and rejected: the
  jail's `NoNewPrivs` and single-uid mapping make it fail at the engine's own
  socket creation and at image-layer chown.
- **Host-only execution.** Rejected: it proves nothing about the sandbox, and
  the acceptance criteria require a real sandbox run.

## Trying it

Reproduce the limitation, in a task sandbox:

```sh
command -v docker docker-compose     # present: a missing binary is not the reason
ls /var/run/docker.sock /run         # neither exists: the socket is not visible
unshare --pid --fork true            # Operation not permitted: a nested PID ns is refused
docker version                       # the CLI is right; the endpoint is unreachable
```

Run the supported path, on a host with a Docker daemon:

```sh
scripts/container-sandbox-e2e.sh     # builds the jail with sandbox/wrap and runs a stack
```

Its stages are the evidence: engine, up, readiness, reachability from
another container, teardown, and a cleanup count of `containers=0 networks=0`.
Inside a sandbox without `/sys` it prints `sandbox-unavailable: sysfs: Sysfs
unavailable · /sys` and exits 3, which is the diagnostic this change is for.

The probe, from Emacs:

```elisp
(harness-call 'sandbox/containers (expand-file-name "~/documents/ai/emacs-agent-harness"))
;; => (:ok t :stage nil ...) on a host whose sandbox shows a socket and /sys
```

## What remains unproven

The Docker path needs a daemon the *user's* machine runs; a host without one
falls back to the podman path or reports `Socket unavailable`. The podman path
needs a bundle; the harness does not download one itself, and the run recorded
here used a static podman 6.2.0 bundle from `podman-static`, bound read-only
into the probe jail rather than installed on the host. Neither path gives a
container its own network namespace inside the jail: the Docker path reaches a
service by name over the compose network, and the podman path ran with
`netns = "host"` and one service. A two-service podman stack that must reach
each other over a bridge is not supported inside the jail, and says so through
the probe rather than half-working.

The podman path was measured against a bundle the harness does not manage.
Making that bundle a prerequisite the harness checks for — rather than a path a
user supplies — is the next step if the socket-free path is to be the default.
