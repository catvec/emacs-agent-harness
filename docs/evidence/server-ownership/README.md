# Backend ownership and remote listener recovery

The reported port conflict exposed separate process-lifecycle, state-ownership,
and listener-recovery defects. These reproductions use isolated test state and
local sockets; no production harness was stopped or modified.

## Reproductions and attribution

On the pre-fix tree (`c6a256c`), the new regressions reproduced:

- `harness-server-a-stopped-process-ending-late-changes-nothing`: stop followed
  immediately by ensure-server started a new live child while the old one was
  still live. Stop cleared the only child handle before asynchronous shutdown
  completed. The normal restart tried to wait, but replaced the original
  sentinel and left this reconnect window open. The previous test explicitly
  expected overlap; it now requires exclusive handoff and retains the check
  that a late old exit report cannot replace the new process.
- `harness-server-refuses-a-second-state-owner`: a second real backend announced
  its own ephemeral ACP address against the first backend's state directory.
  There was no exclusive state owner. A socket was never a sufficient fence:
  private ACP already used independent ephemeral ports.
- `harness-acp-remote-occupied-port-selects-a-free-port`: an unrelated local
  listener prevented remote serving. Retries continually attempted the same
  occupied preferred port, rather than selecting a free port.

Source history places discarded handles and the shared config filename in
`3430ab9` (2026-09-30), and persistent fixed-port retrying in `a927188`
(2026-10-21). These identify the code's origins, not a claim that every live
incident followed this path.

Testing the new ownership rejection also exposed a stranded-startup bug: the
server installed its nonfatal callback error guard before loading startup
configuration. A startup error could therefore leave a process alive without
announcing an address. The exact boundary was tested with the server source
from `07f1634^` and `07f1634` (2026-10-20), using current libraries, the same
config containing `(error "attribution startup failure")`, and a three-second
external timeout. The parent revision exited 255 immediately; `07f1634` logged
the error but stayed alive until timeout (124). This was a historical boundary
probe, not a full historical application test or a git-bisect run.

## Repairs and invariants

- Every backend acquires Emacs's native file lock for
  `STATE/.harness-owner` before loading backend libraries/policy/modules.
  Its lock is `STATE/.#.harness-owner`. Canonical directory identity, native
  atomic acquisition, and a noninteractive refusal prevent another live owner
  from starting, independently of ports. Editor lock-disable/relocation
  preferences cannot bypass it. Failure to establish a lock fails closed.
- Ownership lasts for the Emacs process's lifetime, including module stop and
  reload: stopping modules does not prove that old callbacks or later shutdown
  hooks cannot save state. A dead process's native lock is reclaimed on the
  next start, including after SIGKILL. In-process backend users must exit that
  Emacs before handing its directory to another backend. The UI parent does
  not acquire the backend lock.
- Stop retains the child handle until death. Reconnect/restart requests wait
  behind it; repeated restarts coalesce, an explicit stop cancels the pending
  replacement, and a stopping child's late address is ignored. The original
  sentinel keeps its shutdown watchdog cleanup.
- Forwarded config is a private, per-launch snapshot (mode 0600), cleaned up on
  child exit or spawn failure. Another launch cannot replace its contents.
- Configuration errors retain batch Emacs's fatal startup behavior; errors
  from harness startup explicitly exit nonzero. The nonfatal running-callback
  guard remains in use.
- Address-in-use falls back from the preferred remote port to port zero on
  the same host, preserving authentication and policy checks. Existing address
  and sign-in reporting uses the actual port. Other bind errors retain retry
  and error reporting. A saved client address or manually configured reverse
  proxy may need its port updated; those cannot be transparently redirected.

The lock requires all competing backends to run the updated code. An older
already-running backend does not know about this lock; stop existing backends
before starting the updated version. Nothing here attaches to or kills an
unidentified process just because it owns a port.

## Verification

Tests cover independent real Emacs processes, duplicate real backend startup,
canonical path aliases, separate state directories, reload, disabled editor
locks, unavailable locking, SIGKILL recovery, startup configuration errors,
private immutable launch snapshots, real occupied sockets, authenticated HTTP
behavior, interface retrying, repeated restarts, stop cancellation, and late
announcements/exits.

Focused suites: `lisp/harness-server-test.el`,
`lisp/harness-state-lock-test.el`, `lisp/modules/harness-acp-remote-test.el`,
`lisp/ui/harness-ui-test.el`. Final verification uses the repository's full
runner and its clean-commit `scripts/test.sh --status`, separately from lint.

A live `scripts/dev.sh` instance, socket `harness-ownership-pass`, confirmed
`:old-retained t` and `:restart-pending t` while the old child was alive;
afterward it confirmed the old child dead, a different current child, and a
connected UI. The remote control page reopened after the restart:
[rendered page](remote-after-restart.png). This is a real local development
instance, not a phone or emulator. It was stopped after verification. No UI
labels, tooltips, headings, or status strings were added or changed; the
rendered page's existing copy was inspected.
