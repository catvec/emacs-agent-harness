# UI freeze diagnosis and slow-client isolation

## Problem and scope

Recurring pauses over ten seconds in Noah's Emacs Harness UI on marcuse.
The November 15 observation established transport backpressure, but did not
capture the operation that stopped the UI reading. This change fixes
reproduced transport, rendering and logging mechanisms, hardens polling and
shutdown, and adds bounded evidence collection for a recurrence.
It does **not** claim that a lab reproduction retrospectively identifies the
exact blocking instruction in Noah's UI.

All destructive, busy, graphical and slow-reader experiments used isolated
Emacs processes. The active UI was only read, briefly, for existing messages.
No live reload/restart, input, audio, phone operation, deployment, permission
change, task cancellation or session modification was performed.

## Evidence ledger

### Historical observation, not a stack trace

The task's verified November 15, 2026 local EST evidence:

- At 00:51:44.322 and 00:51:45.182, writes to
  `harness-acp-server <127.0.0.1:48038>` had waited 40 and 41 seconds.
  `ss` associated that connection with UI PID 7614 and server PID 7987,
  listening on port 42751. This proves a client was not draining fast enough.
- The UI answered a read-only query quickly at 00:59. The socket observation
  is not a definitive timestamp match to the reported pause.
- 1,692 collections / 301.97 seconds of cumulative GC, a roughly 4 MB log,
  load averages 12.67/20.97/21.59, concurrent nice'd compilation Emacsen,
  and zero memory pressure are leads, not attribution of this interval.
- LSP `file-truename(nil)` timer errors and missing `-perms` session errors
  do not establish a causal link to the pause. No LSP or permission state
  was changed to suppress them.

A subsequent read-only check found 365 of 441 retained `*Messages*` lines
reporting missing files. The repeated five relative paths were under
`docs/media/voice-ribbon-review/`: `voice-ribbon-versus-ordinary.png`,
`voice-ribbon-versus-compact.png`, `voice-ribbon-versus-bar-language.png`,
`voice-ribbon-versus-large-text.png`, and `voice-ribbon-motion.gif`.
These are **review images**, not evidence that the voice runtime or audio
pipeline blocked. The checkout does not contain the runtime ribbon module.

### Existing fixes retained

The October task t-73qb714x, commit `ff6c7cd`, already introduced ACP receive
slices, per-slice redraw/pinning, hidden-chat deferral, Markdown fontification
caching, and nested-write serialization. These are not reimplemented here.
`e9dbed8` already capped log entries/buffer size and snapshot work;
`5bbde9b` already removed repeated long-chat layout measurements.

What remained: a write still blocked its caller, the bounded log still did
whole-buffer work per entry, and deferred image descriptors could retain a
relative pathname.

## Reproduced mechanisms and fixes

### 1. A slow client held a transport caller

`process-send-string` waits for writable space and can run timers/filters in
that wait. October's queue prevented recursive sends to the same descriptor,
but did not make the first send asynchronous. Its optional limit was checked
only by another send, and ACP did not supply one. A single stopped reader
could therefore keep a broadcast/request callback on its stack indefinitely.
This is not equivalent to the entire Emacs event loop being dead: a healthy
RPC could complete **nested inside that wait**.

ACP writes now use a per-process FIFO and an IO-only Emacs thread. The
creator/main thread owns filters, sentinels, watchdogs, error delivery and
pending-promise rejection; the writer suppresses timer dispatch and never
runs application callbacks or logging. The mutex covers only queue state,
never blocking IO. Queued strings are snapshotted before returning.

Limits include the active write as well as queued writes:

- 32 MiB of encoded bytes;
- 65,536 messages, including zero-length messages;
- 120 seconds of age for the oldest outstanding write, checked every 100 ms,
  without needing another send.

An over-limit connection closes; messages are never truncated or reordered.
Closing a transport rejects its requests once and releases its writer,
without cancelling unrelated sessions or their tasks. Queued EOF/close frames
are drained before graceful descriptor close; cancellation discards the queue.
The ordinary synchronous subprocess sender keeps its API, with an independent
limit timer as well.

An accepted OS write is not a peer acknowledgement. A blocked main thread
cannot run a Lisp watchdog, so deadlines are not real-time guarantees against
arbitrary CPU-bound Lisp. Queue limits still bound admission independently of
timer progress. A connection may have to reconnect/refetch after overflow;
persistent session state, rather than the discarded transport backlog, is the
source of truth.

#### Paused sockets and process shutdown

Two additional hazards surfaced during aggregate-check diagnosis:

- A paused client socket (`process-filter` equal to `t`) must not enter the
  explicit poll's `accept-process-output`. In an isolated blocked-reader
  fixture that call stalled despite its zero timeout. Polling now skips
  paused input; resuming the normal filter still drains queued traffic.
  This is an independently reproduced polling hazard, not proof that Noah's
  socket had that filter when the November pause occurred.
- Emacs's native SIGTERM path can run shutdown hooks with a writer's Lisp
  thread context. A traced isolated server showed that wrong context; the
  corrected legacy-control regression fails with exit 15, not a passing
  graceful exit. An earlier apparent hang in that new fixture was actually
  the paused-poll issue above, and is not claimed as a SIGTERM hang.

Managed server stop now uses a private, per-spawn cooperative request,
requiring normal ACP authentication **and** a separate parent-only secret.
The secret is removed from the child's environment before modules/tools load;
standalone servers do not register this method. It schedules shutdown on the
main Lisp dispatch path. The positive blocked-writer regression records
`(:main t :writers 1 :active 1)`, then exits zero; a traced request reached the
main-thread kill hook in about 31 ms.

Stop remains nonblocking and idempotent. If cooperative dispatch cannot run,
a watchdog sends TERM after two seconds, then KILL after three more. The
watchdog targets the exact live process object, never a retained bare PID,
and its control socket/timer are cleared on exit. Forced escalation can bypass
normal cleanup; it is a last resort for an explicitly stopped, unresponsive
process, not a claim that arbitrary native fatal-signal callbacks are safe.

The first full check's original headless test timed out waiting ten seconds
for process exit. Its exact stack at that interval was not captured, and a
cleanup error could have masked a body error. Neither that deadline nor the
assertions were waived: the corrected 29-test server suite, including the
original test with its unchanged ten-second wait, passes. The production fix
addresses the confirmed wrong-context hazard and previously unbounded stop.

### 2. Relative image descriptors repeatedly failed at display time

The viewer checked `file-readable-p` in the render buffer's directory but
passed a relative filename into `create-image`. Deferred loading later uses
the image loader's search context; a readable file could produce an unresolved
image and `Cannot find image file` on repeated cache flush/display attempts.

The viewer now expands a local file to an absolute path **before** creating
the descriptor. It does not call `file-truename`, probe a remote host, recreate
assets, change labels, or suppress errors globally. The original source still
supplies captions, fallback text and tooltips. Actually absent files still
return the existing fallback without constructing an image.

The GUI regression constructs an image from a relative review path, transfers
it to a buffer with another directory, flushes the image cache, and checks its
actual pixel dimensions. This tests deferred loading, not just the descriptor
shape. The five-path reproduction used readable **mock** PNG/GIF files; it did
not recover or inspect Noah's original review images.

### 3. A bounded log still repeated megabyte-scale work

Every entry counted all retained lines. At the character cap, pruning a line
at the front followed by appending at the back also moved Emacs's buffer gap
across megabytes for each entry. The existing 4 MiB cap prevented unbounded
memory, not repeated scanning/movement under a storm.

The log now maintains a line count keyed by its character-modification tick.
External edits invalidate it. Appends count only new text; deletion counts
only removed text. Character pruning, like the existing line pruning, removes
a chunk (at least a quarter of the character cap) instead of a line each time.
The entry/character/line limits remain enforced, including a single huge
multiline entry. The newest text stays; up to an extra quarter of the oldest
character history may be dropped when pruning.

Receive slicing is still essential: even faster synchronous logging of an
arbitrarily long loop is not a UI scheduling guarantee. A new ACP regression
feeds a large log-output burst into an already full log, checking FIFO order,
size/count invariants and a concurrent heartbeat between receive slices.

## Durable lightweight evidence

`harness-latency.el` installs at harness startup in both UI and server Emacsen,
and removes its own hooks/timer/advice on stop. It is controlled by
`harness-latency-enabled` (default on) and `harness-latency-threshold`
(default 250 ms).

Named boundaries cover RPC polls/filters/handlers/slices, promise dispatch, individual
UI update/event listeners, chat/board/review rendering, header/layout work,
snapshot slices, explicit redisplay and logging. Optional modules register
module-specific entry points themselves; the shared recorder does not name
or depend on the review implementation. Fast calls retain no record.
Each slow completion records operation/category, wall time, GC time/count and
at most 32 bounded **function names**, with no arguments, return values,
buffers, paths, prompts, tokens or tool output.

A one-second watchdog adds:

- an actual stack sample when a still-active slow boundary yields;
- event-loop gaps over two seconds, with GC deltas and time since a
  pre-redisplay observation;
- GC-window totals and individual slow collection observations.

The distinction is intentional: CPU-bound Lisp cannot be sampled/preempted by
a Lisp timer. Its completion names the boundary and caller stack, not the
already-returned inner instruction. A loop gap is not proof of which operation
caused it. Automatic redisplay has no after hook; `since-redisplay` is **not**
labelled redisplay CPU time. Explicit Harness redisplays use a timed wrapper;
`redisplay` itself is left a primitive, with no native-compilation trampoline
installation in the display path. Advice synchronisation is non-reentrant
when installation itself loads libraries.

At most 64 records wait in memory. The recorder flushes at most once per
watchdog tick to a private `latency-PID.log` under the local
`harness-state-directory`, with a 256 KiB rotation threshold and one `.1`
predecessor (plus at most one bounded batch). Excess records are counted, not
queued forever. Disk failures keep only that bounded queue and do not recurse
through the harness log/ACP. Remote state directories are not probed. Startup,
stop and explicit diagnostic flushes are exceptions to the periodic cadence.

These files are separate for the UI and server PID: correlate their wall
clock timestamps with a future send/backpressure record. They are diagnostic
metadata, not a replacement for a native/CPU profiler when an uninstrumented
operation blocks. Recording itself does not make all arbitrary handlers
incremental; a newly identified expensive operation still needs its own fix.

## Measurements

Fresh isolated Emacs 31.1 processes; wall times, not inferred CPU times:

| Experiment | Before | After | What it establishes |
|---|---:|---:|---|
| One 16 MiB notify to a real stopped TCP reader | 12.010 s, ending only at external safety-close | 33.532 ms caller; configured 0.5 s deadline closed at 559.725 ms | Transport caller isolation and independent close |
| Healthy RPC during that experiment | 10.659 ms, nested in blocked sender | 66.321 ms, concurrent main-thread callbacks | Both remained serviceable; not a claim that baseline's whole loop stopped |
| Five readable relative review-image paths, 100 forced cache flush/redraw cycles | 1,000 exact missing-image reports; 192.391 ms; 1 GC | 0 reports; 137.408 ms; 0 GC | Repeated missing-image mechanism fixed, **not** a ten-second freeze reproduction |
| Compiled core, 4,004,000-character seeded log, 80,000 entries of 1,000 characters, one synchronous batch | 18.701 s; 3 GCs / 44.124 ms GC | 4.393 s; 2 GCs / 15.961 ms GC | Full-buffer log amplification reduced; synthetic stress, not the historical workload |
| ACP delivery of 600 × 64,000-character log entries into a full log | Not remeasured: October slicing retained | 2.412 s total, 68 slices, largest heartbeat gap 48 ms | Large-output backlog yields and stays bounded |

Timings vary with host scheduling and concurrent tests. The slow-client
benchmark explicitly checked main-thread handler/callback identity, heartbeat
progress, healthy-connection survival and slow-connection cleanup. Its
baseline loads `dd59e2a` transport sources in the isolated process. The
log benchmark compiles both versions separately; it does not compare
interpreted source to production bytecode.

The recorder has a measurable cost. In the isolated development Emacs,
100,000 compiled empty calls took 57.670 ms directly (one GC), versus
556.415 ms through the installed recorder (12 GCs): about 5 microseconds
extra per boundary, including GC. Fast scopes use a compact vector and a
shared bounded function name; they retain no report. This is not a claim of
zero overhead, or the same GC cost in a much larger long-lived Emacs.

Focused tests, lint, the final full-suite run, current-commit status, and their
complete retained logs are linked in the task evidence. Aggregate success is
reported separately from selected-suite success, never inferred from it.

## Alternatives and limits

- **Only shorten receive slices:** already done in October; cannot interrupt
  a single blocked write or a single expensive handler.
- **Only add a send timeout:** bounds a nested wait but still holds the caller
  for the whole timeout; it does not isolate independent clients.
- **Drop/coalesce arbitrary wire messages:** unsafe for permission requests,
  RPC replies, ordered transcript deltas and graceful close. This change
  preserves FIFO and closes an overflowing transport instead.
- **Ignore missing-image messages:** hides the broken descriptor and does not
  fix display. Absolute descriptors preserve fallback behavior and captions.
- **Raise GC thresholds or blame host load/OpenRouter:** not supported by the
  interval evidence, and would alter state without fixing the reproduced
  mechanisms. No provider policy or GC tuning is changed.
- **Always-on full profiler/backtraces with arguments:** more overhead and
  potentially sensitive content. Bounded function-name timing is the default;
  deeper profiling can follow an identified boundary in an isolated instance.

The exact November 15 blocking UI operation remains uncertain. The fixes
remove demonstrated failure mechanisms and contain a slow client; the new
records narrow a future recurrence without claiming immunity to unrelated
packages, host suspension, filesystem stalls or uninstrumented CPU-bound work.

## Demo and copy checkpoint

See [the offline reproduction and isolated preview](../../demo/ui-freezes/README.md).
The preview uses mock content and creates no agent turn or permission request.

Production labels, headings, buttons, menus, tooltips, loading/empty/success/
error states are unchanged. The copy inventory is therefore empty; diagnostic
records/logs are data and option descriptions are explicit setting help.
The image regression asserts unchanged source/fallback/tooltip text exactly.
The preview's headings are noun phrases and its image/text are mock transcript
content, not new production controls. The final diff's visible strings and the
isolated screenshots are checked separately from functional tests.
