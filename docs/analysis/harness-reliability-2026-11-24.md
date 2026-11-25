# Harness reliability investigation

The recent stuck sessions have several triggers, but share a failure mechanism:
request and persistence errors can outlive the asynchronous operation that owned
them, while the task scheduler waits for a completion event that never arrives.
Fixing each trigger leaves the mechanism available to the next error.

This investigation uses isolated temporary sessions and historical checkouts.
The findings below are reproduced code defects; they do not attribute every
reported live incident to a cause without that incident's logs.

## Regressions isolated with git bisect

| Reproduction | Last good boundary | First bad commit | Code explanation |
| --- | --- | --- | --- |
| Persist a real frozen request, restart, and read the session's cwd and head | `ac3fb53^` | `ac3fb53` (November 17) | New `ID.frozen.json` records contain `:id` and sort before `ID.json`. The loader accepted every JSON file as a session, accepted the first matching ID, and skipped the canonical record. |
| Complete a substantive request while its terminal state write fails | Before durable send tracking | `0a85222` (November 18) | `--tracked-complete` persists the in-flight token before sending, then calls its fallible terminal setter before forwarding `done`. A rejected write both suppresses completion and retains the token. |

Both searches started at `b444511`, within the requested two-week window.
The second searched through the original HEAD, `c546c72`. Raw bisect logs and
runnable reproductions are in [the evidence directory](../evidence/harness-reliability/README.md).
The parent and offending revisions were also checked directly for the restart
reproduction. The observed restart failure is specifically `:cwd = nil`, with
the head lost as well, rather than an unrelated test or dependency failure.

The restart corruption already has a repair in `3f784e3`, followed by recovery
improvements in `d544435` and `3ae8301`. The current hydration suite passes; this
change does not replace those repairs. Its architectural lesson remains relevant:
the replay feature's own tests did not exercise a real restart through the session
loader. A well-tested producer introduced data that another module misclassified.

## Why the fixes kept leaving sessions stuck

### Completion had no owner responsible for failures

`agent/prompt` returns a turn promise, but startup, gates and retries operate on
other promise chains. A callback exception rejects the *continuation's* promise;
it does not settle the turn promise. Several chains discarded that rejection.
The error was logged while `agent/running` remained true indefinitely.

Likewise, `provider/complete` deliberately contains consumer callback exceptions
so one consumer cannot break the transport. That containment also meant an agent
exception in its final event handler could disappear after the provider had
already marked `done` delivered. No more events could finish that turn.

This gap predates the recent regressions. Blame traces the opening chain and the
unprotected terminal usage update to `45d67bb` (September 30), and the head-follow
chain to `22beae4` (October 3). Those are history observations, not additional
bisect results. Recent cache, routing and persistence failures exposed paths the
turn lifecycle had never made exception-safe.

The repair skips malformed stream data before it reaches internal handlers,
while giving the turn loop a failure boundary around request construction
and processing of valid events, and observes entire opening, step-gate, stop and retry
continuations. An internal failure cancels the captured provider and supported
tool executions, records an `internal` error, and completes the turn. It does not
retry a possibly executed operation. A rejection handler is attached *after*
the success continuation: an error handler passed to the same `harness-then`
only handles rejection of its input, not an exception thrown by its success
callback.

### Bookkeeping could prevent task completion

`--end` counted usage, updated receipts, persisted session fields, dismissed
pending interactions and emitted step reports before resolving the turn promise.
Some of those operations ran after removing the turn from the registry. An error
could leave either a running turn without a future, or a pending future without
a registered turn. Tasks and parents waiting for `agent/turn-ended` were stranded
in either case. A step-ended subscriber could also reenter `--end` before its
registry entry was removed and publish completion twice.

The repair makes registry cleanup, terminal notification and promise settlement
an unconditional cleanup path. Optional bookkeeping failures are reported
individually and cannot skip the remaining independent work. A per-turn finishing
claim prevents reentry. Failure to persist evidence remains visible in the log;
the guarantee is in-process completion, not a claim that a failed disk wrote it.

### Old continuations retained authority over new work

A step gate could resolve after cancellation and call `--step` for the old turn.
The step entry point did not check ownership. An opening gate also recorded its
message and flushed its waiting UI state before checking whether its turn was
still current. That could append older input after a newer turn and overwrite
what the new turn listed as waiting.

The repair checks ownership both at the step entry point and when gates settle.
Opening and held messages are preserved as the old turn ends, before another
turn can start. Releasing the obsolete gate then changes neither the transcript
nor the replacement request. This also means cancellation can preserve input
without waiting for a broken gate to release it. A provider that calls back
synchronously can also end a turn before returning its cancellation handle. The
step now clears the previous handle before requesting a new one, then cancels
the exact returned handle if its turn has already ended. The regression shows
that the original code leaked that request after completing the failed turn.

### Process liveness was confused with request liveness

The November 20 dead-owner recovery (`bfdf5a0`) handles a process that exits.
It cannot handle a request that ended while its process remained alive. A failed
terminal save left exactly that state: an in-flight marker with a live owner and
no request left to clear it.

The repair forwards completion despite the failed terminal save and retains an
in-process proof naming the exact token and owner whose terminal callback ran.
The next same-pin dispatch may use that proof to persist an audited recovery
before sending. Unknown or active tokens still refuse. A recovered send remains
uncertain (`:partial`), so it cannot authorize automatic endpoint movement. A
reload keeps the proof; after a process exit the existing dead-owner recovery
applies.

Testing this exposed another defect in the ownership proof itself. Repeated
`process-attributes` calls on this machine reported start times differing by
0.01 seconds for the same process. Exact floating-point comparison classified
that live process as a reused PID. The deterministic regression uses 100.0 and
100.01; it fails on the old comparison.

New owners keep a stable cached identity and Linux's raw `/proc/PID/stat` start
counter. PID reuse is checked against that counter. Older records with only a
wall-clock start time remain recoverable when the PID disappears, but a differing
wall-clock reading alone no longer proves death. An inaccessible process or an
owner on another host remains unknown. This conservatism avoids sending a second
request merely because a reconstructed timestamp moved.

## Regression coverage

`harness-agent-lifecycle-test.el` covers request construction failure, rejected
opening and step gates, a failure inside the final event handler, failed terminal
bookkeeping, reentrant completion, and obsolete opening and step callbacks. The
terminal matrix injects failure at six separate session methods and requires one
completion event, a settled promise, and no registered turn.

All eleven lifecycle regressions fail on the original HEAD (`c546c72`) and
pass on the repair; the original-run summary is kept with the evidence. The OpenRouter health suite adds terminal-write failure,
exact-token/owner proof checks, stable owner identity, and wall-clock drift. The
terminal-save and wall-clock drift regressions were separately observed failing
before their respective repairs. Existing hydration, retry, resilience and
routing suites remain part of validation.

The focused run passed 357 tests in seven suites before the final two ownership
assertion tests were added. Byte compilation completed with exit 0 and warnings.
Full-suite verification is recorded by `scripts/.dev/test-stamp.json`; `scripts/test.sh --status` checks
its result against the current commit and worktree. Integration tests requiring live
models remain opt-in; these reproductions require no paid model calls.

## Validation failures that required follow-up

The first full run exposed a malformed-event regression in the initial failure
boundary. The existing gremlin test expects malformed text/usage to be ignored
and a valid final event and tool error result to survive. Event data is now
checked before internal failure handling; that assertion is preserved.

The pause-all fixture assumed two temporary directories could never belong to
the same parent project. A deterministic reproduction places both beneath a
parent project: one task waits for the other's slot, and the test times out
waiting for two running tasks. Explicit project markers make its independence
real. The parent-project reproduction now passes without lengthening the wait.

The new Git-tool fixture inherited `commit.gpgsign = true` and blocked while
creating its first commit, outside any asynchronous timeout. It now disables
signing in its own repository and checks that creating the commit succeeds. A
regression injects a Git configuration requiring signatures with a signing
program that always fails; the old fixture fails it and the repair passes.
The SSH fixture also no longer tries to create `/run/sshd` on the host: it
starts its temporary daemon directly and uses its existing availability check
where that daemon cannot run.

Other tests of unrelated or absent projects saw `/tmp/` as their project during
the run. The final full verification uses `TMPDIR=/var/tmp`, a clean temporary
parent, without changing the user's Git configuration or deleting that parent
project. These environment-sensitive results are kept distinct from passing
full-suite verification. The clean-parent run also exposed two stale test
assumptions about `TMPDIR`: the access-view test hardcoded `/tmp` in its expected
path, and a sandbox test used the default temporary directory when its case
specifically required a file under the literal `/tmp` mount. The former now
checks the actual path prefix while retaining its width, ellipsis, suffix and
button assertions; the latter explicitly creates its test file under `/tmp`.

## Reliability boundaries that remain

A transport that never produces a terminal event is still governed by its own
timeouts and the resilience watchdog. A tool without a canceller can continue
running after its turn ends. A failed disk cannot provide durable recovery until
writes work again. An unknown live dispatch is still refused rather than being
silently replayed. These changes close the reproduced lifecycle and ownership
holes; they are not evidence that every possible stall or provider failure has
been eliminated.

## AFL follow-up: the systemic problem is failure ownership

The provider implementation is a trigger, not the only owner of the failure.
The core must keep malformed data and adapter exceptions from destroying a
session's ability to finish, cancel and accept another request. Several layers
previously had local protections whose composition did not provide that
guarantee:

| Systemic weakness | Concrete failure | Protection added |
| --- | --- | --- |
| A local `finished` flag stood for successful downstream delivery | OpenAI marked a stream finished, then error classification threw before emitting `done` | Claim finish before reentry, but deliver its terminal event in unconditional cleanup |
| Exception containment had no completion responsibility | HTTP and SSE logged callback errors while the agent still waited on another promise | The adapter owns protocol errors inside those callback boundaries; the agent owns internal failures inside its turn boundary |
| Persistence and diagnostics sat on the critical completion path | A terminal write or usage/diagnostic exception suppressed the signal tasks needed | Independent bookkeeping cannot prevent registry cleanup, notification and promise settlement; adapter terminal failures become protocol errors |
| Unvalidated data retained authority across requests | Bad tool inputs poisoned saved history; old callbacks and duplicate deliveries could affect new work | Safe history shapes, per-turn ownership checks, request-scoped cancellation and per-step tool-ID deduplication |
| Two components interpreted the same wire value differently | Duplicate JSON `id` members used the first value in a plist and the last when re-encoded | Reject duplicate object members, including nested objects and escaped spellings, in both shared JSON readers |
| Tests stopped before recovery or changed the timing model | Accepting fakes hid poisoned history; synchronous mocks let an outer `condition-case` catch real asynchronous failures | Real persisted sessions, strict next-request checks, cold reload, delayed wire callbacks and deliberate terminal-stage failures |

This is why fixing ten similar triggers did not necessarily remove the eleventh:
the invariant was not owned by an exception-safe lifecycle boundary. A healthy
process, a caught exception, an in-memory flag and a persisted marker each
described only part of the operation. None alone proved that its waiting caller
had been released.

### A new historical reproduction

The raw SSE payload `{"error":{"message":42}}` reproduces a missing terminal
event before this repair. The adapter sets `finished`, then calls
`harness-openai--failure-kind`, which calls `downcase` on the non-string value.
The HTTP layer contains that exception; a second finish attempt sees the flag
and cannot emit anything. Cancellation used the same flag and could not repair
the missing terminal event either.

Git bisect identifies `4c2023c` (October 3), which introduced that classification
call, as the first bad commit for **missing terminal delivery**. The parent emits
one event; the child emits none and raises `wrong-type-argument`. The parent
still emitted malformed error data: it is good only for this precise liveness
reproduction. The defect already exists at the start of the requested two-week
window, so it cannot be honestly attributed to a new change during that window.
[The portable reproduction, bisect log and direct revision checks](../evidence/provider-afl/README.md)
are saved. This does not attribute an unrecorded live incident to that payload.

The repair handles parser and dialect callback errors before SSE can swallow
them, emits a protocol error, and stops the captured HTTP producer, including a
handle returned after a synchronous failure. Terminal processing claims finish
before calling an audit hook and cannot lose its event to usage, tool-argument
decoding or diagnostics failures. It does not retry an operation whose effects
may already have happened.

### What AFL found and what the oracle found

The initial AFL++ campaign exercised 3,238 inputs across ten targets. It found a
duplicate-member MCP round-trip failure after 92 executions of that target.
That is a logical invariant failure (adapter exit 42), not an Emacs segfault.
The retained original input and a manually reduced example reproduce it.

Expanding coverage to the real OpenAI SSE lifecycle exposed the terminal defect
above while checking the seed corpus. That finding came from the new oracle and
regression, rather than claiming it was an AFL-discovered mutation. Five of six
new targeted provider checks fail at `0bff057`; the consumer-redelivery check
already passed there. A malformed-wire test also requires the real asynchronous
agent/session path to finish, accept a new prompt and survive cold reload.

The runner is `.harness/plugins/fuzz/run.sh`. It retains reports and replay
inputs and fails its command when findings are present. The final campaign's
exact counts are in [the retained report](../evidence/provider-afl/final-campaign.txt).
Stock Emacs uses AFL's non-instrumented mode: these are mutation campaigns, not
evidence of coverage saturation. A fresh Emacs per input contains failures but
limits throughput, and mutations that fail parsing explore little deeper code.

### Architectural limits still requiring attention

This pass establishes tested failure boundaries; it does not establish a
universal fault-isolation guarantee for every provider. In particular:

- The resilience watchdog reports stalls; it is not a universal hard deadline
  that settles every request. A provider that emits nothing still depends on
  its transport timeout or cancellation. Cancellation now has core settlement
  independent of the provider acknowledgement, but a notification alone is no
  recovery policy.
- Terminal ownership still exists at several layers. A longer-term simplification
  is one request supervisor that owns its identity, completion, cancellation and
  deadline, with adapters supplying data rather than controlling the caller's
  lifecycle. Existing exact-token and per-turn checks are concrete protections
  along that boundary, not a completed state-machine migration.
- The shared plist JSON convention is not a complete wire type system: null,
  empty arrays and empty objects can become indistinguishable without a schema.
  Duplicate-member rejection removes the reproduced identity disagreement; it
  does not make all decode/encode operations lossless. Its validator preserves
  native array identity until member checking finishes, so arrays beginning with
  JSON false cannot be mistaken for objects during that check.
- Durable unknown effects cannot be fixed by clearing an in-flight flag and
  replaying. Recovery needs operation-specific evidence or an explicit uncertain
  outcome. No exactly-once guarantee across machine crashes is established here.
- This campaign covers canonical events and one raw provider decoder. Equivalent
  conformance/fault-injection checks are still needed for the other adapters and
  their real incident traces. Every saved finding should become a deterministic
  regression before broadening mutation budgets.
