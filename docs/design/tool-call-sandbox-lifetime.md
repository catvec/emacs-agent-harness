# A tool call's sandbox ends with the call

> **Follow-up.** The measurement below is unchanged and the constraint it
> records still holds for `bash`: a call's sandbox is the call's.  The
> report it records — that each `bash` call is its own namespace and that
> a background process does not outlive it — **is correct**, and it is
> still correct.  What was wrong was the harness's answer to it: the
> earlier revision of this note treated one self-contained command per
> call as the only possible workflow, and changed only the tool's
> description.  The harness now offers a way past the constraint that
> does not weaken it: `bash_job`, a process the harness holds in a second
> sandbox of the session's own, reachable from that session's later calls
> and no other's.  See
> [`tool-call-persistent-jobs.md`](tool-call-persistent-jobs.md).  The
> sections below that argue only documentation was possible are the
> earlier revision's, kept for the measurement and the alternatives;
> read the follow-up for the fix.

## The report

An agent building a Godot game wrote in its plan, and told itself in a
thinking block, that

> Each bash call is its own sandbox namespace → every playtest run is
> one self-contained script.

and, later,

> Each tool call is its own sandbox namespace — background processes
> don't persist between calls. So every playtest run must be one
> self-contained script: starts Xvfb, launches the game, drives real
> input, screenshots, and stops.

That conclusion decided how it worked: it packed a display server, the
game and its input driver into one command, rather than starting a
server in one call and using it in the next. The question was whether
the harness does that on purpose, whether it is a defect, and whether
the harness tells an agent so.

## What was measured

All of it in one task session of this repository, whose bash runs under
the real `bwrap` backend (`HARNESS_SANDBOX=bwrap`, sandbox policy
`required` by the test's own setting). Each probe is a separate tool
call, as an agent's would be.

| Question | Result |
| --- | --- |
| Is the PID namespace shared between calls? | No. `/proc/1` is `bwrap` in every call, and its start time is new in each call (`52420414`, then `52420675`; again `52653697`, then `52656040`), so each call has a PID namespace with its own init. The namespace *inode numbers* must not be read as identity: they were the same across two calls and differ across others, so they are recycled rather than reused. |
| Does a file written in a call exist in the next? | Yes. A file in the session's temporary directory and one in the working directory both read back in the next call. |
| Does a background process survive a call? | No. A server started with `&` answered `curl` inside its call, and the next call's `curl` to the same port failed with exit 7 (connection refused); `pgrep` found no such process. The same held for a `setsid` heartbeat whose loop was still running at the end of its call: no further ticks appeared in the next call. |
| Does `nohup` or `setsid` change that? | No. Both leave the shell's process group, neither leaves the PID namespace, and the namespace is what ends. The same script run in a `bwrap` without `--unshare-pid` is the counter-check: its loops kept writing to the heartbeat after the command ended (11 lines, then 23 a second later), which is the behaviour the flag prevents. |
| Is `$HOME` shared? | No. `$HOME` keeps its path inside the sandbox but is an empty tmpfs: a file written there in one call is gone in the next. |
| Is the network shared? | Yes, by default. A machine listener is visible in `awk`'s view of `/proc/net/tcp` from inside a call. Only `:network nil` unshares it, and then `/proc/net/tcp` inside shows no listener at all. So a listener would be reachable if its process outlived a call — which it does not. |
| Does the harness kill the process on purpose? | Not at the normal end of a call: `harness-run-command` (`lisp/harness-util.el`) walks and kills the process tree only for a timeout. At the normal end it is the kernel that ends the namespace's processes when bwrap's init exits. |

The behaviour is therefore real, and it is the sandbox working as
designed, not a bug in the harness's process handling.

## Why it is a boundary and not an accident

`--unshare-pid --unshare-ipc --unshare-uts --die-with-parent
--new-session` in `harness-sandbox--bwrap-command` is the jail's process
boundary (`docs/trust-model.md`, `DESIGN.md` "Actual Linux Jail"). A
background process that outlived the call would be a process of the
session's still running after the call's permission decision, its
timeout, and its transcript entry were over, in a namespace whose init
had gone. Keeping one alive would mean either a PID namespace that
outlives calls — one long-lived sandbox per session, with the command
shell inside it — or letting the command escape into the harness's
namespace. The first is a design change to the jail's lifetime; the
second removes the PID boundary. Both are security-sensitive, both
change what a session's containment means, and neither is a bug fix.

That is why the change here is not to the call's sandbox. The fix that
followed took the first road deliberately and in a narrower form than
"every call shares a namespace": the session's calls share **one runtime
per session**, held by the harness process, built from the same profile
and with the same `--unshare-pid` and `--die-with-parent`, destroyed when
nothing of the session is left in it rather than kept warm — so
containment is drawn around the runtime, which is bounded and owned,
instead of being removed.  A job is one run in that runtime.
See [`tool-call-persistent-jobs.md`](tool-call-persistent-jobs.md).

MXC on macOS has no PID namespace, so a background process there can
outlive its call; the harness then neither ends it at the call's end nor
stops it later. That asymmetry is a backend limit: `sandbox/status`'s
`:limits` line for MXC already says it has no PID namespace, and the
module commentary now says what that means for a background process.  A
job is refused there for the same reason: nothing would end it.
`systemd-run` was called a PID namespace here and is not one: it is a
unit and a cgroup, stopped when the command exits, and it sets no
`PrivatePIDs`.  What it gives a command is the unit's lifetime, which is
enough to end what the command started.  It holds no job: the harness
would have systemd-run's client, not its unit, so it could not stop what
it started, and a job there is refused for that reason.

## What the harness got wrong

It never said so, where an agent would read it. The `bash` tool's
description described the file system, `/tmp`, the caps and the
timeout, and said nothing about process lifetime, so every agent has to
spend calls finding out — this agent spent several, and the model that
found out wrote the rule into its plan as folklore. Two other task
sessions in this project drew the same conclusion independently, one of
them after trying `nohup`.

The transcript of the game session shows the cost, read-only and without
steering it. It first ran Xvfb and Godot in one call, then found the
display gone in the next and guessed at the reason ("It seems processes
get killed between bash calls? … Background processes may be reaped"),
then examined `ps` and saw PID 1 was `bwrap`, and then tested `setsid`
in case leaving the process group was enough. It arrived at the rule in
its plan only after all of that, and its plan's "Constraints found"
records it as a constraint of the environment — which it is, though the
harness had not said so.

## The change

Documentation and instruction, at the points a model reads before it
plans, with no change to containment:

- The `bash` tool's description says that in the sandbox each call is a
  session of its own, that a process left running at its end — server,
  daemon, background job, `nohup` and `setsid` included — ends with it,
  that the files in the working directory and the session's `/tmp`
  stay, and that a server, display or emulator is therefore started and
  stopped within one self-contained command. This is the text a model
  sees in the tool list before it writes its plan. It says "in the
  sandbox" because that is where the harness guarantees it: a command
  the policy runs unconfined is not in a namespace of the harness's.
- `harness-tools-shell.el`'s commentary says the same for a reader of
  the code, names the mechanism per backend, and records that the elisp
  tool's background Emacs ends the same way, while a remote or
  unconfined command is not in a namespace of the harness's and keeps
  what it leaves.
- `harness-sandbox.el`'s commentary states the lifetime as part of the
  jail's contract, next to the mounts.
- `docs/trust-model.md`, `docs/architecture.md` and `DESIGN.md` say it
  where the jail is described, so a reader of the design pages meets it
  with the rest of the boundary.
- `scripts/module-docs.sh` regenerates `docs/modules/tools-shell.md`
  and `docs/modules/sandbox.md` from the source, as the repository
  requires.

That revision stopped at documentation.  The `bash` description it wrote
has since been scoped per backend (bwrap's namespace; `systemd-run`'s
unit and cgroup, no `PrivatePIDs`; MXC and unconfined commands that keep
what they leave) and now points at `bash_job`, so the tool list names
both the limit and the way past it.

## The supported workflow, said plainly

A playtest, a browser session, a dev server or a game that needs a
display, an emulator and a driver can be one self-contained script that
starts what it needs, uses it, and stops it, all inside one tool call.
Files that outlive it — screenshots, logs, build output — go to the
working directory or the session's temporary directory, where the next
call and the file tools find them. A `trap` in that script, or an
explicit stop at the end of it, is what cleans up its own processes at
the call's own end; the kernel does the rest.

A server or a display that several calls must share is a `bash_job`: the
harness starts it in a sandbox of the session's own and holds it, so the
next call of that session reaches it and no other session's does, and it
is stopped by its own stop action, its deadline, a permission change that
would make its mounts wrong, or its session or task ending.  A job is
not a wider sandbox: it is the same profile a command gets, and it lives
at most its `timeout`.  Where a workflow genuinely needs a long-lived
machine rather than a session's process — a persistent display, a browser
with its profile, a server the user can open — the harness has a place
designed for it: a workspace computer's box (`docs/workspace-mode.md`,
`workspace/box/exec` with `:background`), whose processes are meant to
outlive a chat.  That is a separate thing from a session's sandbox and
does not widen it.

## Alternatives considered and not taken

- **One long-lived sandbox per session, with every bash call running
  inside it.** What would make a background server reachable across calls
  without a new tool. It also makes every call share a PID namespace, a
  mount set and a lifetime with every other, and puts a second process's
  mounts beyond the call that granted them, and it needs a way for the
  user to see and stop it. Not done; a job is a second, explicit, bounded
  sandbox instead (`docs/design/tool-call-persistent-jobs.md`).
- **A session "detached job" tool that starts a process outside the
  namespace.** It would be a hole in the PID boundary with no owner and
  no cleanup, and it would let an unconfined process inherit what the
  sandbox was built to keep from it. The job tool that was built is not
  this: it wraps its command in the same sandbox profile, so the process
  is confined, owned and bounded.
- **Silence, and a note in a skill.** The tool description is read by
  every session before it plans; a skill is not. The agents that got
  this wrong were not reading a sandbox skill, and two of them wrote the
  constraint into their plans as if it were a project rule.

## What it costs

- One more sentence in a tool description, which every request carries
  (about 80 tokens in the tool list), and a paragraph of commentary in
  two modules. The description is the one place where a session learns
  the rule without spending calls on it.
- No behavioural change to a `bash` call, no change to any policy,
  permission, mount or capability. The regression test pins both the
  description and the lifetime so a later change to either has to say
  so.  The job tool is additional and changes none of this: a call's
  sandbox is still the call's.

## How a reader checks it

- `harness-tools-shell-bash-description-states-the-process-lifetime`
  holds the tool's description to the exact per-backend sentences about
  process lifetime and to the pointer at `bash_job`, in
  `lisp/modules/harness-tools-shell-test.el`.
- `harness-tools-shell-bwrap-ends-a-calls-background-processes` runs two
  real `bash` calls under bwrap: the second finds the file the first
  wrote in the session's `/tmp` and finds no further heartbeat from the
  background loop the first left.
