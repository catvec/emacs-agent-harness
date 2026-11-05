# NVIDIA OpenShell as the sandbox

The harness confines the commands of its `bash` and `elisp` tools in a
kernel sandbox: bubblewrap or `systemd-run` on GNU/Linux, MXC on macOS.  It
can run them in [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)
instead.  OpenShell is a different kind of jail, and this page says what that
means, how to set it up, what a command sees in it and what it cannot give.

It is **opt-in**: `harness-sandbox-backend` is `auto` by default, which never
picks OpenShell.  Nothing about how commands run changes for anyone who does
not ask for it; an `openshell` on the exec path is only listed among the
backends the machine has.

## Why, and why not

OpenShell is not a wrapper like `bwrap`.  A *gateway* (a service of yours,
which the installer starts as a user service) makes each sandbox a container
from an image, with a supervisor outside it and a policy inside it that
Landlock and seccomp enforce.  Every connection the command makes goes
through the supervisor, which lets out only what the policy lists.

| | bwrap | OpenShell |
|---|---|---|
| What runs the command | a namespace of this machine | a container of the gateway's engine (Docker or Podman) |
| What it sees of the system | this machine's `/usr` and `/etc`, read-only | **the image's**: the tools a command runs must be in it |
| Your directories | bind mounts | bind mounts, and the same list in the policy for Landlock |
| Network on | the machine's network, open | **only the endpoints you list** (`harness-sandbox-openshell-network-rules`): none by default |
| Network off | an empty network namespace | a policy without any rule: nothing leaves |
| Linux capabilities | `--cap-add` of the ones the user gave | **none, and none can be given** |
| Start of a command | milliseconds | a container per command: a second or more |
| Set up | `apt install bubblewrap` | a gateway, an image, and the gateway's permission for bind mounts |

Use it when you want what it adds -- a policy the supervisor enforces, a
network that is closed unless you open a door, an image of tools that is not
your machine -- and can live with what it cannot do (see
[What it cannot do](#what-it-cannot-do)).

## Requirements

- OpenShell **0.1.5 or later**: the `openshell` command line and a gateway.
  The harness checks that the program has the options it passes.
- A container engine the gateway uses: Docker 28 or later, or rootless
  Podman 5 with its user socket (`systemctl --user start podman.socket`).
  The microVM and Kubernetes drivers cannot be used: they share few or no
  host directories.
- On GNU/Linux a kernel with Landlock ABI 3, Linux 6.2 or later (OpenShell's
  own requirement; a sandbox that cannot enforce the policy does not start).
- A **local** gateway: its mounts are directories of the machine it runs on.
  As with every backend, a session in a remote (TRAMP) directory is not
  wrapped.

## Set it up

### 1. Install OpenShell and start its gateway

```sh
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
openshell status        # the gateway answers: Status: Connected
```

On GNU/Linux the gateway is the user service `openshell-gateway`
(`systemctl --user status openshell-gateway`), on macOS a Homebrew service.
The harness uses the gateway `openshell` itself picks: the active one
(`openshell gateway select`), or the one named by `$OPENSHELL_GATEWAY` in
the environment of the harness's Emacs.

### 2. Let the gateway mount directories

A sandbox sees a directory of yours only through a bind mount, and a gateway
refuses them unless its operator allows them.  In `~/.config/openshell/gateway.toml`
(merge it into what is there; `podman` for a Podman gateway):

```toml
[openshell]
version = 2

[openshell.gateway]
compute_driver = "docker"

[openshell.drivers.docker]
allow_driver_config = true
enable_bind_mounts = true

[openshell.drivers.docker.resource_admission]
enabled = false
```

Then `openshell-gateway config preflight --path ~/.config/openshell/gateway.toml`
and `systemctl --user restart openshell-gateway`.

**Know what this allows.**  OpenShell calls these settings unsafe overrides:
with them, a request to *this gateway* can bind any path of the machine into
a sandbox.  Run a gateway for the harness alone, bound to loopback as the
installer leaves it, as your own user, and let nothing else register sandboxes
with it.  What keeps a command in its sandbox to the directories of its
session is the policy the harness writes for each one (below), which the
supervisor enforces with Landlock.

### 3. Make an image with your tools

A command runs in the image, so the image has what your commands run: at least
`bash` and `sleep` (the sandbox's main process), and what you use -- `git`,
`make`, a compiler, and **Emacs 29.1 or later** for the `elisp` tool.  The
gateway's default image is a bare Ubuntu.  For instance:

```dockerfile
FROM nvcr.io/nvidia/base/ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash coreutils git ca-certificates make ripgrep emacs-nox \
 && rm -rf /var/lib/apt/lists/*
```

Build it with the engine the gateway uses (`docker build -t harness-sandbox:latest .`,
or `podman build`): `--from` does not build, it names an image the engine has
or can pull.

### 4. Tell the harness

```elisp
(setq harness-sandbox-backend 'openshell
      harness-sandbox-openshell-image "harness-sandbox:latest"
      ;; The elisp tool starts Emacs at this path; the image's:
      harness-elisp-emacs "/usr/bin/emacs"
      ;; Where commands whose session has the network on may go.
      harness-sandbox-openshell-network-rules
      '("github.com:443" "pypi.org:443" "files.pythonhosted.org:443"))
```

All of them, and what else there is:

| Option | |
|---|---|
| `harness-sandbox-backend` | `openshell` asks for it |
| `harness-sandbox-openshell-program` | the `openshell` program, by name or path |
| `harness-sandbox-openshell-image` | the image; nil for the gateway's default |
| `harness-sandbox-openshell-driver` | `docker` (default) or `podman`: the key of the driver config that carries the mounts |
| `harness-sandbox-openshell-network-rules` | the endpoints a command with the network on may reach: `"HOST:PORT"` strings, or `(NAME :endpoints (...) :binaries (...))` rules |
| `harness-sandbox-openshell-image-paths` | directories *of the image* a command may read besides `/usr`, `/etc` and the like, `/opt` for a toolchain kept there |
| `harness-sandbox-openshell-extra-args` | more arguments for `openshell sandbox create`, such as `("--cpu" "2" "--memory" "4Gi")` |

These are read from their global values only: a project's `.dir-locals.el`
cannot widen the network, pick the image or add arguments for the sessions in
it.  `harness-sandbox-extra-read-only-dirs` means nothing to OpenShell, whose
image is no copy of this machine's `/usr`.

### 5. Check it

- The jail and permissions view (`C-c h j`) names the backend in its Sandbox
  row, with what it cannot do, and, when OpenShell was asked for and cannot be
  used, why.  `sandbox/status` says the same: `:backend`, `:requested`,
  `:problem`, `:limits`.
- **[Detect again]** (`D` in that view; `sandbox/detect`, and
  `M-x harness-sandbox-detect` where the harness runs in your Emacs) looks
  for the backends again: the program, its options, and the gateway
  (`openshell status`).  The backend is chosen when the harness starts, so
  press it after starting a gateway that was down.
- **[Test OpenShell]** (`O`; `sandbox/check`, `M-x harness-sandbox-openshell-check`)
  starts a throwaway sandbox the way a command's goes, runs `echo` in it and
  says how it went.  It finds what the detection cannot: a gateway that
  refuses the mounts, an image without bash, a kernel without Landlock.

Both buttons show in the Sandbox row where OpenShell is installed or was asked
for.

When OpenShell cannot be used the harness **falls back** to the backend `auto`
would pick (bwrap, `systemd-run`), logs why and says so in the view; it falls
back to no sandbox only when there is none, and then
`harness-sandbox-policy` decides, as always (`required` refuses to run the
command).

## What a command gets

Each `bash` call and each evaluation of the `elisp` tool is a command, and
each one gets a sandbox of its own, made for it and deleted when it is done:

1. `openshell sandbox create --detach --no-keep` with the policy file and the
   mounts of the command's directories;
2. `openshell sandbox exec` runs the command in the sandbox, in its working
   directory; its output, standard error and exit status come back as they
   are, with none of what `create` prints;
3. `openshell sandbox delete`, in the background.  A command killed at its
   timeout loses its sandbox too; one the harness could not delete ends by
   itself an hour or so after it was made.

What the sandbox shows is the access model of the session, as OpenShell can
say it:

| The session's | In the sandbox |
|---|---|
| working directory, the grants, its temporary directory, scratch directories | read-write bind mounts, each at its own path |
| read-only directories, the skills, the tool output | read-only bind mounts |
| a worktree's git directory | read-write, its `hooks`, `config`, `index` and `HEAD` read-only inside it; the commit identity in the environment |
| `$HOME` | a tmpfs at `/tmp/harness-home`, `$HOME` pointing there, the directories of your real home that were shown, shown under it: `~/.claude/skills` reads as it does outside |
| `/tmp` | the sandbox's own, empty |
| read-only (`:read-only`: a supervising session, a read-only profile) | every mount read-only; `/tmp` and `$HOME` stay writable |
| network off | no network rule at all |
| network on | the endpoints of `harness-sandbox-openshell-network-rules` |
| `HARNESS_SANDBOX` | `openshell`, so a script can tell it is confined |

The policy file (`<state directory>/openshell/policy-*.yaml`, named for what is
in it) lists the same directories under `filesystem_policy` for Landlock, plus
the image's system paths, runs the command as your uid and gid (so what it
writes is yours), and demands that Landlock enforce it
(`compatibility: hard_requirement`).  Anything not listed is refused.

## What it cannot do

The harness does not pretend.  `sandbox/status` lists these as `:limits` and the
access view prints them under the Sandbox row:

- **No Linux capability can be given.**  The workload is a non-root user with
  none, and OpenShell has no way to add one.  `request_escalation` for a
  capability is refused with that reason; a command that asks is not run.
- **The network is never open.**  OpenShell denies every connection no rule
  allows.  A session with the network *on* reaches exactly the endpoints of
  `harness-sandbox-openshell-network-rules`, and nothing when that is empty
  -- not even `127.0.0.1` of the machine.  The access view's network switch
  still turns even that off.
- **The image is the system.**  Tools of this machine are not there unless the
  image has them; `harness-sandbox-extra-read-only-dirs` does not apply.
- **A sandbox per command takes a moment**, longer the first time an image is
  pulled.
- **No argument of a command may be longer than 32 KiB** (the gateway's
  limit): put a long script in a file and run that.  A policy lists 256 paths
  at most.
- **Mounts need the gateway's permission** (step 2), and a directory the
  gateway keeps for itself (`/opt/openshell`, `/etc/openshell`, `/run/openshell`,
  `/proc`, `/dev`...) or the image's own `/usr`, `/lib`, `/bin` cannot be a
  mount: it is left out, with a line in the log.

## When it goes wrong

| You see | Because | Do |
|---|---|---|
| Sandbox row: *OpenShell asked for, not used: the program openshell ... is not installed* | no `openshell` on the exec path | install it, or set `harness-sandbox-openshell-program` to its path |
| ... *too old: `openshell sandbox create` has no --no-auto-providers* | an OpenShell older than 0.1.5 | upgrade it |
| ... *no OpenShell gateway is registered* | `openshell status` has none | `openshell gateway add ...`, or rerun the installer |
| ... *the gateway ... does not answer* | the service is down | `systemctl --user start openshell-gateway`, then [Detect again] |
| ... *does not accept this user* | an expired login | `openshell gateway login` |
| A command ends with exit 125, *OpenShell could not start a sandbox ... driver config* or *bind mounts require enable_bind_mounts* | step 2 is missing | add the settings, restart the gateway |
| ... *bind source path does not exist* | a granted directory is gone | give it up in the access view |
| ... *Landlock* or *ABI* | a kernel older than 6.2, or Landlock off | upgrade it, or use another backend |
| ... an image that cannot be found or pulled | the name, or the engine | `docker images`, `docker pull`; the image must be one the *gateway's* engine has |
| A command ends with 127, `bash`, `sleep` or `emacs: command not found` | the image lacks it | add it to the image |
| `Permission denied` reading a path of the image | Landlock allows only what is listed | name its directory in `harness-sandbox-openshell-image-paths` |
| `Could not resolve host`, a connection refused | no network rule | add the endpoint to `harness-sandbox-openshell-network-rules` |
| Files a command made belong to another user | a rootless Podman maps users | `userns = "keep-id"` in the gateway's Podman table (see its configuration reference), or run the gateway on Docker |
| `Cannot run command: OpenShell cannot run this command: an argument of N bytes ...` | over the 32 KiB limit | write the script to a file |

Every command's own stderr is its own; when the sandbox cannot be made the
script prints what `openshell` said, up to 40 lines.  The sandboxes the
harness makes carry the label `harness=emacs-agent-harness`:
`openshell sandbox list --selector harness=emacs-agent-harness` lists any left,
`openshell sandbox delete NAME` removes one.

## Tests

`test/harness-sandbox-openshell-test.el` runs the module against
`test/fixtures/fake-openshell.py`, a stand-in for the command line.  It
answers the calls the harness makes as OpenShell 0.1.5 does and checks what
the gateway checks of them (the policy file against the documented schema,
the driver config's mounts against the Docker driver's rules); where bwrap
works it runs the command in the mounts and the network the sandbox
describes, so the same checks that need a real OpenShell -- a command writes
its directories and no other, reads nothing it was not shown, reaches no
network, and the `elisp` tool's Emacs is read-only and offline when a
session is -- run on any machine with `python3` and `bwrap`.
`harness-openshell-real-run-confines` and the `-under-openshell-` tests of
`test/harness-supervisor-test.el` run the same checks against a real
OpenShell, and skip without one that [Test OpenShell] would pass.
