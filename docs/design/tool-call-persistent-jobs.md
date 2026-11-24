# A session's jobs: processes that outlive a tool call

## The report, and what was wrong with the answer

An agent building a Godot game concluded, correctly, that
"each bash call is its own sandbox namespace — background processes
don't persist between calls", and from that, that every playtest had to
be one self-contained script.  That is true of the harness's `bash`
tool.  **The report was right.**  The first answer to it was to say so in
the tool's description and to document the constraint
(`docs/design/tool-call-sandbox-lifetime.md`); that documented a limit
and changed no behaviour.

The user's request was different: tool calls that share a process, so a
task does not pay the startup of a server, a display or an emulator on
every call.  "Put it in one command" is the workaround the failing agent
had already found; it is not the fix.  This document is the fix, and it
is two things at once:

- **a shared, authorised workspace**: consecutive calls edit the same
  files and read each other's results, because the harness's directories
  were never per call.  This was already true and stays true; the tests
  beside this design hold it;
- **managed, persistent processes**: `bash_job`, a *job* that belongs to a
  session, that the harness holds, and that every later call of that
  session reaches.

Neither is `jailhost` running arbitrary commands.  See "What `jailhost`
is here" below.

## What `jailhost` is here

The user's phrase names the machine a session's commands run on, inside
its jail: the **harness process's own host**, under the `sandbox`
module's confinement.  In this checkout that is **`bwrap`**
(bubblewrap), started by `harness-sandbox--bwrap-command` through
`sandbox/wrap`, with the session's directories bind-mounted, `/proc` and
`/dev` from the sandbox, a private home directory, the session's
temporary directory as `/tmp`, the machine's network unless the session
is offline, and `--unshare-pid --unshare-ipc --unshare-uts
--die-with-parent`.

It is not:

- a virtual machine or a container the harness runs on top of;
- a second computer (`computer_*`, the workspace box, a client machine);
- `systemd-run`, whose unit the harness holds no handle to;
- ChatGPT's own executor — the Godot agent ran under *this* harness, and
  the limit it measured is this harness's `bash` sandbox.

What "giving the sandbox clearance" means, then, is exactly what it
already means for `bash`: the permission chain decides a call, the access
module's profile says what the session may reach, and the sandbox mounts
that.  A job is one run in the runtime the session's calls share, held
for as long as the job's own timeout; the runtime is built from the same
profile and confined the same way.  It is not a way around the chain, and
a directory the session never had is not mountable by asking for a job.

## Why a call's sandbox cannot be the thing that persists, and what replaced it

`bwrap` wraps each command with `--unshare-pid --die-with-parent
--new-session`.  The PID namespace is the command's, and when the
sandbox's init exits the kernel ends every process left in it.  That is
the jail's process boundary and it stays: removing `--unshare-pid`, or
running a command outside the sandbox, would leave processes nobody
confines and nobody stops, beyond the permission decision, the timeout
and the transcript entry that the call was granted under.

What replaced it is a **runtime the session's calls share**
(`harness-sandbox-session`): the harness runs one supervisor inside one
confined instance, keeps its standard input and standard output as the
only channel, and starts each call's command in that instance.  So the
namespace is the *runtime's*, not the call's, and it is still a namespace:
a `setsid` child, a double-forked daemon and a `nohup`ed server are all
inside it, are all enumerated by the run token they inherit, and all end
with it.  Consecutive calls are therefore in one namespace, which is what
makes a display, an emulator or a playtest survive from one call to the
next -- and it is the runtime, not the call, that the boundary is drawn
around.

The runtime is held on demand and destroyed when nothing of the session is
left in it (`harness-sandbox-session-idle-seconds`), so the machine does
not accumulate one namespace per session that has stopped working.

## The design

### What a job is

A job is a command (`bash -c`, as `bash` runs one) started as a run of its
session's runtime.  It is not a sandbox of its own any more: the runtime
is built once from `harness-tools-shell-sandbox-profile`, the very profile
a `bash` call of the session gets -- the session's working directory,
worktree and own temporary directory, the configured and granted
directories read-write, the skills and read-only directories read-only,
the `tools/sandbox-options` filter's options (a read-only session's job is
read-only; an offline session's is offline), and its Linux capabilities
where the backend can give them -- and the job is one command in it.

So a job and a `bash` call of the same session are in **one** namespace,
which is what the user asked for: what a call leaves running is the next
call's, and a job is the same thing said explicitly, with an id, a
deadline and an owner.

### The generic layer it sits on, and what a backend must promise

Persistence is not a bwrap workflow.  `sandbox/hold` is the one method
that names a backend for holding an instance:

  (:command ARGV :backend BACKEND :capabilities PLIST :why TEXT)

The adapters live below it (`harness-sandbox--hold-facts`) and each says
what its backend can promise of an instance's lifecycle: `:exec`,
`:stream`, `:cancel`, `:enumerate`, `:destroy`.  The runtime manager asks
those facts and refuses to hold an instance where they are not there,
rather than testing a program's name.  Everything above that boundary --
the runtime manager, the `bash` tool, the jobs, the access view -- asks
`sandbox/hold` and never a backend.

What each backend promises today, and what was measured:

| Backend | Holds an instance | Verified cancel | Enumerate descendants | Measured here |
|---|---|---|---|---|
| `bwrap` | yes | yes | yes (`/proc` is the namespace's) | yes, real |
| `systemd-run` | yes | yes (cgroup) | **no**: no `PrivatePIDs`, so `/proc` is the machine's | not measured |
| `mxc` (macOS) | yes, when its executor carries the pipe | yes | yes: the inherited environment, from the process table | against a stand-in executor |
| `openshell` | **no**: its wrapper deletes the sandbox with the command | -- | -- | not available |
| none / `off` / remote | **no** | -- | -- | -- |

A backend without the facts is refused by `harness-sandbox-session-problem`
with `sandbox/hold`'s own reason.  That is a limitation *of this
implementation*, not a proof that persistence is impossible there: a
systemd adapter that named its unit could supply the missing fact, which
is where the next work is.

MXC is the one whose facts are conditional.  It has no PID namespace and
no handle on a command, so what it can promise is the supervisor's own:
the supervisor finds a run's processes by the environment they inherited
-- `/proc` on Linux, the process table (`ps -E` on BSD, `ps e` elsewhere)
where there is none -- and, where neither is available, by the process
group the run was started in, asked of the kernel.  That last way is what
a Mac under MXC has, and it is why this adapter promises `:enumerate` at
all: Seatbelt refuses to exec the setuid `/bin/ps`, so `ps` cannot run in
the jail, and macOS 27 withholds an Apple platform binary's environment
from the call `ps -E` makes -- and the supervisor and its commands are
`/bin/bash`.  A supervisor that demanded either one answered
`R VERSION  ps-with-environment` and exited, which made every command in
that sandbox fail before it ran.  Whichever way is chosen, the supervisor
sends TERM to each process of the run, waits, then KILLs what ignored
it, and ends every process of the instance before it says it is going.
What that needs of the executor is that the supervisor's standard input
and output are the harness's pipe while it runs; an executor that collects
a command's output into a file and hands it over at the end, or that
closes its standard input, can run a command but cannot hold one.  So
`sandbox/hold` measures it once (`harness-sandbox--mxc-streaming`, a
command that reads a line and echoes it back before it ends), keeps the
answer, and refuses with it where it does not hold; `sandbox/status`'s
`:limits` says the same once it has been asked, without asking itself.

### Every spawn is checked, not only the first

A job outlives the call that started it, so the checks a call makes once
cannot be made once here.  `harness-tools-jobs--prepare` runs before
**every** spawn — `start`, `restart`, and an automatic rebuild after a
permission change — and it:

1. reads the session again (`session/get`), so what the job runs with is
   the session's current context, not the call's copy;
2. authorises the job's directory against `permission/dirs` **now**
   (`harness-tools-jobs--cwd-authorized-p`): a directory the session was
   granted and then lost is not mounted again, and a session that moved
   away from it is caught even when no `session/moved` handler ran;
3. asks the **effective** confinement of that directory
   (`harness-tools-jobs--confinement-problem`), which is two questions,
   both required: the policy in effect *there* (`config/get` for the
   directory, so a project `.dir-locals.el` that says `off` is seen) and
   what `sandbox/hold` says the backend can promise
   (`harness-sandbox-session--missing-capabilities`) — one view standing
   in for the other would be a way past the check; and
4. holds the **built command** to it
   (`harness-tools-jobs--spawn-confinement`,
   `harness-tools-jobs--confined-p`): the command that
   `harness-tools-shell-wrap-profile` builds must differ from the command
   itself, and the backend that holds it must promise a job's lifecycle.
   Neither half is a program's name: a backend this module has never
   heard of is allowed by what it promises and refused by what it does
   not.

The checks fail by stopping the job, with the reason recorded on it and
shown in the access view.  Nothing is left running and nothing is
restarted unconfined.

### What ends it

Five things end a job, and each holds when the others do not:

1. **The sandbox's own `timeout`.**  The command line inside the sandbox
   is `timeout --signal=TERM --kill-after=5s SECONDS bash -c COMMAND`.
   The job's deadline therefore ends it *inside* the sandbox, whatever the
   harness is doing, including a harness that has died without running a
   handler.
2. **`--die-with-parent`.**  The sandbox's parent is the harness; when the
   harness dies the sandbox's init gets its parent's death and the kernel
   ends the job's processes with it.
3. **The harness's stops**: `bash_job`'s stop, the access view's
   `[Stop]`, a restart, the deadline tick (`--tick-all`), the module's
   shutdown and `kill-emacs-hook`.
4. **The end of what owns it**: `session/deleted`, `session/deactivated`,
   `session/moved`, `task/done` and `task/cancelled`.
5. **The work being stopped**: `agent/stop-outstanding`, the filter task
   mode calls when a task is paused, returned to the pending queue or
   pre-empted (`harness-tools-jobs--stop-outstanding`), and
   `task/cancelled`, which `task/cancel` emits for a task at work.  Only
   the session's own jobs stop, so a pause ends its own work and no other
   task's.  The command a paused turn was waiting on is not a job: it is
   the turn's own tool call, and it stops with the turn, through
   `agent/tool-canceller` (`agent/cancel` asks each running call).
6. **The runtime going idle.**  A job is a run of the session's runtime,
   and a runtime is kept only while something of the session is in it: a
   command in flight, or a process the session left.  A job of the runtime
   is such a process, so it keeps the runtime alive for as long as it
   runs, and a runtime with nothing in it is destroyed (see
   `harness-sandbox-session-idle-seconds`).  The job's next call, or a
   restart after a change, starts a fresh runtime -- the run is what
   builds it.

A job that ends by itself keeps its exit status.  One the sandbox's own
`timeout` ended reads as `stopped` with the timeout as its reason (exit
124 or 137), not as a failure, because it is the deadline doing its work.

The deadline is the job's: `start` sets it, and **no restart extends it**.
A restart by a call or by a change of access runs the rest of the same
span, and a restart after it has run out is refused with that reason.

### What it may reach, and what changes it

The mounts of a runtime are fixed when it starts.  A job must therefore
not keep authority its session no longer has, and must not silently
ignore one it has gained.  `access/changed`, `permission/dir-revoked`,
`config/changed` and `session/moved` recompute the profile and compare it
with the one the runtime was built with:

- different: the runtime is **ended** -- with every process in it -- and
  the job is started again, in the runtime the next call builds.  Its
  `:restarts` counts it, and what it printed before the restart stays in
  its log above what it prints after.  Nothing is kept warm: a runtime is
  built when a call needs one;
- impossible to build, or unconfined, or a directory the session lost: the
  job is stopped, and its reason says why;
- the same: nothing happens.

The generation is not the job's own idea of what the session may reach.
`harness-sandbox-session--profile-now` re-reads the session, re-authorises
its working directory against `permission/dirs` and asks
`harness-sandbox-session-problem` again, so a revoked or downgraded
directory cannot keep the mounts the runtime was built with -- including
the session's **own cwd**, which bwrap binds whether or not it is among
the writable ones.  A working directory the session may only read is
mounted read-only, and `drop_access keep_read=true` on it is proved by a
test that writes from inside the sandbox and finds no file afterwards.

The profile is the job's fingerprint, so **every effective access input
must be in it**.  `harness-sandbox-extra-read-only-dirs` is one that the
sandbox reads itself rather than through the profile, so the job's profile
carries it as `:extra-read-only` (`harness-tools-jobs--profile`); taking a
directory out of the setting rebuilds the job, and the test proves the old
path cannot be read rather than that a counter moved.

A restart that a change causes is not the session's decision and can come
again and again, so restarts are counted and capped
(`harness-tools-jobs-max-restarts`, five by default): at the cap the job
is stopped with that as its reason instead of being spawned for ever.

The two passes are ordered so that each says the last word on what it
decided.  The jobs pass notes which jobs are running, then the runtime
pass ends the runtime and emits `sandbox/rebuilt`, and the jobs pass gives
the noted jobs a run in the runtime the next call builds.  A reason a pass
recorded -- a directory gone, a policy that no longer confines, a restart
cap reached -- is what the session reads: a stop keeps a reason the job
already has, and the runtime's own ending is recorded only where there was
none.

### The record every branch writes to

A job is a plist, and `setf` of a `plist-get` key a plist does not have
binds the *variable* it was given rather than the stored list.  A key set
on a job but missing from the record it was made with is therefore set on
a local, never reaches the job, and leaves a branch that looks taken and
is never taken.  `:was-running` was such a key: the pass that notes a job
to carry into a rebuilt sandbox wrote it, the pass that reads it found
nil, and a job was never started again in the new sandbox.

So the record is built from one list, `harness-tools-jobs--job-keys`, and
two tests hold it: one reads the module's source and fails if the module
writes a key the list does not name, and one checks that a new job has a
place for every key.  The source test is what would have caught the bug;
it is held to the file on disk so it cannot drift from the code it
checks.

### Ownership, isolation, and what sharing does not give

A job belongs to the session whose call started it.  `bash_job` lists,
shows, logs and stops only that session's jobs; an id of another
session's is *not found* rather than refused, so nothing about it is
shown.  `sandbox/jobs` and `sandbox/job-stop` take the session id, so a
client cannot reach another session's job either.

The sandbox is the isolation of what the job *can touch*: it sees the
session's directories and nothing else, as a bash command does, and a test
holds that a file outside them is unreadable from a job and that the job's
own `/proc/1` is `bwrap`.

**The network is not isolated per job or per session.**  It is the
machine's, as it is for `bash`, unless the session is offline: a job that
listens on a port is reachable from this machine and from any other
session's commands, and no two jobs can bind the same address and port.
Job ownership is about who can list, read and stop a job; it is not a
network namespace.  The tool description says so, and no test claims
otherwise.

### Bounds on what a job costs

- **Output is bounded in memory.**
  `harness-tools-jobs-output-limit` (256 KiB by default) bounds the
  buffer the filter fills; the front is dropped, the end is kept, and a
  line says how much went.  The same bound applies to the history kept
  across restarts and to the log file, which is written while the job
  runs (`--log-interval`, one second) as well as when it stops.
- **Time is bounded** by the deadline, which a restart does not move, and
  by `harness-tools-jobs-ttl` on what a call may ask for.
- **Count is bounded** by `harness-tools-jobs-max-per-session` and by the
  restart cap.
- **A start that cannot run leaves no entry**: the job is put in the
  tables only once its checks pass, and forgotten if `make-process`
  fails.

## Where a job cannot run

A job needs a backend whose sandbox the harness can both **hold** for more
than one call and **end** itself:

The runtime manager asks `sandbox/hold` what a backend promises and
refuses to hold an instance where the facts are not there.  No module
above it names a backend.

- **bwrap**: supported.  A namespace of its own, so a run's processes can
  be enumerated in `/proc` and ended, and ending the init ends them all.
  This is what the tests measure with a real bwrap.
- **systemd-run**: holds an instance and can stop it (its cgroup), and its
  output is the pipe systemd-run passes through, but it names **no**
  `:enumerate`: the unit is not given `PrivatePIDs`, so a `setsid`
  descendant that left the cgroup would not be found in `/proc` and a
  cancel could not be verified.  Refused, with that reason.  A named unit
  and `systemctl --user stop` would supply it; that adapter change is not
  made here.
- **MXC** (macOS): holds an instance where its executor carries the pipe.
  `Seatbelt exec` runs one program -- the supervisor -- and confines what
  it does; the supervisor is the second operation, since it finds a run's
  processes by the environment they inherited, from `/proc` or from the
  process table where there is none, and ends them on `kill`, verifies
  that none is left, and ends every process of the instance before it says
  it is going.  What that turns on is measured once by
  `harness-sandbox--mxc-streaming`: an executor that collects a command's
  output and hands it over when the command ends, or that closes its
  standard input, can run a command but cannot hold one, and is refused
  with that reason.  Measured here against a stand-in executor, not on a
  Mac.
- **OpenShell**: refused.  Its wrapper deletes the sandbox with the
  command that made it, so a held instance would go with its first command.
- **No backend, the `off` policy** (globally or for the project), **a
  remote directory, a read-only session**: refused.  A runtime there would
  be an unconfined process outliving its call, or, for a read-only
  session, a process with no writable temporary directory for its log.  A
  `:scratch` directory is refused too: it would be deleted under a process
  that outlives the call.

Each is refused with its reason, and `sandbox/status`'s `:jobs` says it in
the access view before a job is asked for.  None of these refusals is
proof that persistence is impossible on that backend; each is what this
implementation can verify today.

## What the user and the agent see

- **The agent** has `bash_job`: `start`, `list`, `status`, `logs`, `stop`,
  `restart`.  The `bash` description says the runtime is shared and held on
  demand, so a `bash` call already keeps what it leaves running, and it
  says where that is not so (another host, a read-only session, the `off`
  policy, a backend that cannot promise a verifiable cancel and
  teardown).  A model that reads only the tool list therefore knows both
  the workflow and when it does not apply, without a backend's name in
  it.
- **The user** has the access view's `Jobs` section: each job's id, state,
  how long it has run of its timeout, its command, and `[Stop]`; `No jobs`
  when there are none; `unavailable` with the reason where the harness
  cannot hold one.

## Alternatives considered and not taken

- **A long-lived sandbox per session that every bash call runs in.**
  Considered and then built, above the generic sandbox API: it is what
  `harness-sandbox-session` is.  The earlier version of this document
  rejected it, on the ground that it would make every call share one PID
  namespace -- which is exactly what makes a display or a playtest survive
  a call, and the reason the user asked for it.  What the earlier version
  was right about is that the sharing must be *bounded*: one runtime per
  session, built from that session's profile, destroyed when nothing of it
  is left, and never shared across sessions.
- **A job with a sandbox of its own, in the same profile.**
  The first implementation, and what this document used to describe.  It
  gave persistence only to a job, so a process a plain `bash` call left
  running still ended with the call, and it named bwrap itself rather than
  asking the generic layer.  It is what the review asked to be replaced.
- **A detached process outside the sandbox** (`nohup` on the host, a
  supervisor outside bwrap).  It is the hole the jail exists to close.
- **Only the tool-description fix** (the previous hand-in).  It is true
  and worth keeping, and it does not give the workflow the user asked for.
- **A workspace computer's box.**  It belongs to the workspace, outlives
  the chat, and is not bounded by the session's permissions.  The two are
  for different needs.

## How a reader checks it

`lisp/modules/harness-tools-jobs-test.el`, run with real bwrap (the tests
skip where it cannot start):

- the workflow: `harness-jobs-a-server-started-in-one-call-is-used-in-later-ones`
  (call 1 starts a job that writes a file and serves it, calls 2 and 3
  read it over the network, `list` shows it running, `stop` ends it and
  the file stays);
- confinement on every spawn: `harness-jobs-a-project-that-says-off-refuses-a-job`,
  `harness-jobs-a-global-off-policy-refuses-a-job`,
  `harness-jobs-a-backend-that-cannot-hold-one-refuses-a-restart`,
  `harness-jobs-the-built-command-is-what-is-checked`;
- the directory and the session: `harness-jobs-a-revoked-directory-stops-the-job`,
  `harness-jobs-a-session-that-moves-stops-its-job`;
- access inputs: `harness-jobs-a-read-only-mount-taken-away-cannot-be-read`,
  `harness-jobs-a-read-only-session-keeps-no-write-authority`,
  `harness-jobs-a-permission-change-rebuilds-or-stops-a-job`;
- lifecycle: `harness-jobs-returning-a-task-stops-its-jobs` (and the
  other session's job is untouched), `harness-jobs-a-cancelled-task-stops-its-jobs`,
  `harness-jobs-a-paused-task-takes-its-listener-with-it` (the port is
  dead afterwards), `harness-jobs-a-job-ends-when-its-task-is-done`,
  `harness-jobs-a-job-ends-with-its-session`,
  `harness-jobs-a-job-ends-when-the-harness-shuts-down`,
  `harness-jobs-a-job-ends-when-its-time-is-up`;
- the record and its reasons: `harness-jobs-every-key-the-module-sets-is-in-the-record`,
  `harness-jobs-a-new-job-has-every-key`,
  `harness-jobs-restart-runs-the-command-again-and-says-so` (a restart
  keeps the earlier run's output in the log),
  `harness-jobs-restarts-stop-at-the-limit`;
- bounds: `harness-jobs-output-is-bounded-and-says-so`,
  `harness-jobs-a-never-ending-flood-stays-bounded`,
  `harness-jobs-restarts-stop-at-the-limit`,
  `harness-jobs-a-start-that-cannot-run-leaves-no-job`;
- ownership and limits: `harness-jobs-a-job-is-its-own-sessions`,
  `harness-jobs-a-job-with-a-changed-mount-is-its-own-namespace`,
  `harness-jobs-a-job-of-another-host-is-refused`,
  `harness-jobs-a-refused-backend-says-why`,
  `harness-jobs-logs-returns-the-lines-asked-for`,
  `harness-jobs-restart-runs-the-command-again-and-says-so`,
  `harness-jobs-the-tool-is-described-and-offered`.

`lisp/modules/harness-sandbox-session-test.el`, the runtime manager
itself, with a real bwrap:

- the generic boundary: `harness-sandbox-session-the-generic-layer-says-what-holds-an-instance`
  (`sandbox/hold`'s facts, and a backend that lacks one being named);
- the transport: `harness-sandbox-session-nothing-it-is-sent-makes-it-read-a-file`
  (a symlink and a fake output file planted where a pathname-reading
  harness would follow them change nothing reported);
- cancel against destroy: `harness-sandbox-session-a-cancel-answers-only-when-nothing-is-left`
  (a `TERM`-ignoring `setsid` child is cancelled and its token has no
  process left; a `nohup`ed daemon is counted as owned work);
- lifetime: `harness-sandbox-session-a-runtime-goes-when-nothing-needs-it`
  (an idle runtime is destroyed, the next call builds another and the
  files are still there), and
  `harness-sandbox-session-a-permission-change-rebuilds-and-says-so` (a
  change ends the runtime and the transcript says so);
- the permission generation, at the level a session uses it:
  `harness-sandbox-session-a-real-keep-read-downgrade-takes-the-writes-away`
  (`drop_access keep_read=true` on the session's own cwd, through the
  tool: the sandbox refuses the write and leaves no file, and reading
  still works), and
  `harness-sandbox-session-a-working-directory-that-is-only-readable-is-bound-read-only`;
- bounds: `harness-sandbox-session-a-concurrent-cap-is-enforced`,
  `harness-sandbox-session-output-is-bounded-in-memory-and-on-disk`,
  `harness-sandbox-session-a-runtime-record-names-every-key-it-sets` (the
  record, held to the module's own source).

`lisp/ui/harness-ui-access-test.el`:
`harness-ui-access-sandbox-says-the-shared-sandbox-and-its-cost` (exact
rendered copy, each state of the `Sandbox` row),
`harness-ui-access-jobs-section-copy` (the `Jobs` section's copy) and
`harness-ui-access-jobs-are-listed-and-stopped-through-the-harness`.

`scripts/jobs-demo.sh` plays the same workflow by hand, in throwaway
directories, with the real bwrap: call 1 starts a server as a job of a
session, calls 2 and 3 reach it from separate calls, call 4 reads the file
it wrote through the harness's file tools, call 5 stops it and call 6
finds the port dead and the file still there.  It prints what each call
got, then the confinement of a call and what a job cannot reach.

`scripts/jobs-game/demo.sh` is the acceptance run the review asked for, and
it is a game rather than an HTTP server: call 1 launches a game as a job
of a session, call 2 takes a screenshot of the frame it has drawn, call 3
sends it input, call 4 takes a second screenshot with the player moved and
reads the world file, call 5 writes what the playtest scored where the
harness's own file tools read it, call 6 lists the job and the runtime
holding it, call 7 stops it and proves no frame is drawn afterwards while
its files stay, call 8 proves the runtime went when nothing of the session
was left in it and that the next call builds another with the files
intact, and call 9 downgrades the session's working directory with
`drop_access keep_read=true` and proves a write there is refused with
`Read-only file system`.

Both runs are kept whole in `docs/evidence/tool-call-persistent-jobs/`,
beside the access view's section as a live harness drew it and the two
frames the game drew.  What the game run does **not** show: a real X
display.  This machine has no X server it can start (no `Xvfb`, no
attainable `Xorg`), so the game renders its frames to PNG with Pillow and
the "screenshot" is the game's own frame.  That proves the workflow --
launch once, use and drive it from later calls, stop, downgrade -- and it
does not prove a window manager path.

## What is not done, and what remains unsupported

- bwrap is the backend this implementation holds a runtime on and has
  measured with a real one.  MXC holds one too, but it was measured
  against a stand-in executor rather than on a Mac.  systemd-run,
  OpenShell, no backend, the `off` policy and remote
  directories are refused, each with its reason in code, in
  `sandbox/hold`'s `:why` and in the tool's description.  systemd-run is
  the nearest to support: it promises everything but `:enumerate`, and
  naming its unit would give that.
- A job's output is bounded by dropping the front; there is no separate
  rotation with several files.  One bounded file per job.
- The network is the machine's.  There is no per-job network namespace,
  port allocation or listener registry, and the design does not claim one.
- A read-only session cannot hold a runtime at all: it has no writable
  temporary directory for the runtime's log, so there is no shared runtime
  for it (`harness-sandbox-session-problem`).  The `bash_job` tool is not
  offered to it, and a job it already had stops, its reason naming the
  session's own state rather than the runtime's ending beneath it.
- A real X11 or Wayland window is not measured: no display server can be
  started on this machine, so the game acceptance run draws its frames to
  PNG instead.  The workflow is real; a window manager path is not.
- Idle teardown is immediate by default
  (`harness-sandbox-session-idle-seconds` is 0), which is a policy choice,
  not a measurement: what a runtime's start-up costs a session that makes
  one call every few minutes is not measured beyond the demo.  A
  deployment that values latency over idle processes can raise it, and
  `nil` keeps a runtime until the session ends.
