# Voice mode on the engine the machine has

## The problem

Voice mode on macOS failed with `Executable unavailable · docker` on a
machine whose container runtime was Podman. Two separate faults produced
one message:

1. **The CLI was looked for on `exec-path` only.** An Emacs started from
   the Dock inherits the system's directories, not Homebrew's, so a
   Podman installed at `/opt/homebrew/bin/podman` was invisible to
   `executable-find`. Docker, which the machine did not have at all,
   was the backend `auto` tried first, and the reason named it.
2. **The sandbox and the stacks each decided which engine they used.**
   The sandbox's container probe looked for `docker` and `podman` by
   name and mounted the first socket at a known path; the stacks asked
   the `container-runtime` module. On a Podman machine those two
   answers could disagree, so a sandboxed command could be shown a
   Docker socket the stacks never used.

The instruction was also about shape: voice mode should not configure
whether it uses Podman or Docker. It should run a compose stack through
one shared module, and that module should detect the engine or have the
setting.

## What this decides

**One module owns the engine.** `harness-container-runtime` is the only
place that decides between Docker and Podman. It already built the
compose command, the network command and the environment; it now also
answers which engine a *sandboxed command* should reach, so there is one
answer rather than two.

**Voice mode names no engine, and gains no setting.** It goes
`voice → speech → stacks → container-runtime`, as before. No voice
provider record, no voice command and no voice option mentions Docker or
Podman, and a test holds it that way. The client is never asked to
choose an engine; the machine's engine is the answer.

**The setting stays where it was.** `harness-container-runtime` (`auto`,
`docker`, `podman`) is the setting, unchanged. `auto` is the default.

**A CLI is found where it is installed.** The new option
`harness-container-runtime-program-directories` lists the directories a
CLI is looked for in after `exec-path` (`/opt/homebrew/bin`,
`/usr/local/bin`, `/opt/local/bin`, `/run/current-system/sw/bin`). The
directory a CLI is found in is put on the PATH of the commands it runs,
so `podman compose` finds the `podman-compose` beside it, and the CLI
itself is run by its absolute path. This is the fix for the macOS
symptom, and it is deliberately a lookup rather than a special case for
Podman: Docker installed by Homebrew has the same problem.

**`auto` names an engine the machine has.** When no backend answers,
`auto` takes the first whose CLI is *installed*, not the first in the
order. A machine with Podman and no Docker is told `Compose unavailable ·
Podman` rather than `Executable unavailable · docker`: the reason names
what the user can fix.

**The sandbox shows the stacks' engine.** `harness-container-runtime-engine`
returns `:id`, `:label`, `:program` and `:socket` and runs nothing. The
sandbox reads it for `sandbox/containers` and for `:containers` on
`sandbox/wrap`, so a container command reaches the same engine the
stacks use, and a Podman machine is shown no Docker socket. With the
container runtime module not loaded, the sandbox keeps its old fallback.

**The runtimes page shows the program.** One new line, `Program
/path/to/cli`, so the engine actually used is visible rather than
inferred from a socket.

## The circle, and how it is avoided

`harness-container-runtime-need-reason` asks the sandbox's
`sandbox/containers` probe (a missing socket, `/sys` or cgroup is a
reason the runtime cannot run). The probe now asks
`harness-container-runtime-engine` which engine to show. If the engine
answer asked whether the backend *answers*, that question would run the
version command, whose reason is the probe: a circle.

Two functions break it, and both are deliberate:

- `harness-container-runtime--resolve-installed` resolves by what is
  *installed* (a file to run) and never runs anything.
- `harness-container-runtime-engine` describes the engine from the
  record and the filesystem only: its `:socket` is the path the backend
  *declares*, not a search for a socket that answers.

`harness-container-runtime--exec` likewise does not resolve: it runs the
argv and environment its caller gave it. A caller asking whether the
runtime answers is not asked again.

## Alternatives considered

**Special-case macOS in voice mode.** Rejected: it puts an engine
decision in the client, which is the thing the task asked to remove, and
it leaves the sandbox disagreeing with the stacks.

**Set `exec-path` from a login shell at startup.** Rejected as the only
fix: it changes the whole process's path for every feature, it is slow,
and it does not help an Emacs that is already running when Podman is
installed. The directory list is local to the commands that need it.

**Run the CLI by absolute path in the argv.** This is done (a CLI off
`exec-path` is run by its path), but the argv a stack logs keeps the
program's name, and the PATH entry is what makes the *provider* the CLI
delegates to resolve. Rewriting the visible argv would make the log and
the page show a path the user did not choose.

**Have the sandbox ask `harness-container-runtime-socket-path`.** It
searches for a socket at the known paths when the declared one is
missing. For an engine description that is wrong twice: it would show a
Docker socket to a Podman machine, and it would run a filesystem search
inside the availability question. The description is the declared path;
the sandbox checks that the path exists itself.

**A second engine setting in voice mode.** Rejected outright by the
instruction: one setting, in the module that owns the engine.

## The shape of the change

- `lisp/modules/harness-container-runtime.el`
  - `harness-container-runtime-program-directories` (new option)
  - `harness-container-runtime--find-program`, `-program`,
    `-installed-p`, `--path-env`, `--declared-socket`,
    `--resolved-argv` (new)
  - `harness-container-runtime-engine`,
    `harness-container-runtime-container-program` (new)
  - `resolve` gains the installed fallback; `--env` gains the PATH
    entry; `--exec` and `run` run the resolved program; the page gains
    the `Program` line.
- `lisp/modules/harness-sandbox.el`
  - `harness-sandbox--container-engine` (new, soft `fboundp` on the
    runtime module)
  - `--container-socket` and `--container-cli` read the engine when the
    runtime module is loaded, and keep their old answer when it is not;
    the probe's `binary` reason names the engine's label.
- Tests: the runtime suite (a CLI off `exec-path`, the `auto` fallback,
  the engine answer runs nothing, the page copy), the sandbox suite (the
  socket and CLI follow the engine, no Docker socket on a Podman
  machine), the speech suite (the macOS case end to end: Docker absent,
  Podman only in a program directory, the pipeline starts through
  Podman), and the voice-provider suite (no engine setting in voice
  mode).
- Docs: `docs/container-runtime.md` (where the CLI is looked for, the
  engine answer, the `binary` reason), `docs/stacks.md` (voice mode
  names no engine), the generated `docs/modules/container-runtime.md`.

## Copy

One new authored label, `Program`, a noun, with a path as its value. The
existing statuses are unchanged: `ready`, `Executable unavailable ·
NAME`, `Socket unavailable · PATH`, `Compose unavailable · LABEL`. The
probe's `binary` reason keeps its shape and names one label instead of
two when the runtime module is loaded: `Container CLI missing · Podman`.
No new buttons, tooltips, menus or echo-area messages.

## What this is not: per-sandbox isolation

The review asked this change be read against the requirements of the
Terminal-Bench task (`t-q565kq24`), which asks whether a sandbox's
containers can be separated from another sandbox's, and whether that
boundary exists in the container interface provider. It does not, and
this change does not build it. Recording the line between the two is the
point of this section, so neither is mistaken for the other.

**What this change does.** It makes the harness agree with itself about
*which engine* it uses: one discovery, one CLI, one socket, shared by the
stacks, the runtimes page and the sandbox probe. Before it, a Podman
machine could be shown a Docker socket the stacks never used.

**What it does not do, and does not claim:**

- **`sandbox/wrap :containers` is still unreachable from a tool call.**
  Only `harness-sandbox.el` and its tests mention it; the `bash` tool
  never passes it, so an agent cannot run a container through the
  harness's own path. The capability exists and is tested; it is not
  wired to anything a session can call.
- **There is no per-sandbox isolation.** The engine is one per
  *machine*, not one per sandbox: one daemon (or one rootless storage
  root), one image store, one network namespace, shared by every
  session. Two sandboxes' containers can see each other. Making the
  engine consistent does not partition it, and `harness-container-runtime-engine`
  answers about the machine, not about a scope.
- **The sandbox module has no sandbox identity.** There is no session or
  scope id in `harness-sandbox.el` (`HARNESS_SESSION` or the like), so it
  could not label, namespace or storage-root a container as belonging to
  one sandbox even if a boundary wanted it. That id has to be threaded
  down before a label or a scope can exist.

**The division agreed with `t-q565kq24`** (its session `56da3c6c`), so
the two do not compete:

- This task owns *which engine*: discovery, CLI, socket, PATH, the
  resolve-free engine answer.
- `t-q565kq24` owns *which scope*: per-sandbox identity, a container
  label or namespace or storage root per scope, and the tool-call wiring
  that makes `:containers` reachable from `bash`.
**The hook is in, and it is deliberately narrow.**
`(harness-container-runtime-engine-for-scope SCOPE &optional ID)` is
resolve-free like `--resolve-installed`, returns the scope unchanged in
`:scope` (it is opaque here), and returns `:program` for the machine's
CLI. `:socket` is **always nil** for a scope, and that is an answer, not
a gap: this module cannot give a scope an engine of its own, and the
machine's socket is shared by every scope that reaches it, which is the
one thing a per-sandbox boundary must not do. A caller that needs one
scope's containers apart partitions at the storage and network layer and
shows no socket; it must not fall back to
`harness-container-runtime-engine`, whose socket is the shared one. The
test stubs `available-p` and `--exec` to error if they are reached, so
the resolve-free property is held rather than intended.

A real engine per scope -- rootless Podman with its own `--root` and
storage, or a Docker-in-Docker sidecar -- is what a per-scope socket
would need, and it is a larger task than either of ours. Neither task
should let a reader read `:socket nil` as "isolated".

The environment limit they measured also stands, and is not something
this module can fix: inside this session's bwrap jail there is no `/sys`
(the kernel refuses a nested sysfs mount), no engine socket, and
`newuidmap` cannot map a subuid range, so a nested rootless engine cannot
start here whatever the harness chooses.
