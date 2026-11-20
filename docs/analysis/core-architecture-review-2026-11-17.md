# The harness core, reviewed for a re-architecture

**Status: review, plus one fix.** The review changes no architecture. It also
carries a fix for a defect it found in the live harness (§3.5, Defect 1: the
listener's accept queue), and two tests that hold it. Counts and line references
are for the tree at `78f0ada` (the branch advanced by two merges while this was
written; every count in §1.1 was re-verified there and is unchanged). It answers
four questions:

1. What is the core architecture, concretely?
2. How well did the module loader, the method/event/filter bus, and the ACP
   surface actually work — measured against *this* program's history, not in
   the abstract?
3. Where does it break at several computers × several clients × several
   projects × tens of tasks each?
4. Given that, what does Elixir/BEAM or Go buy, and what would it cost?

Every claim carries a `file:line`, a commit, or a measurement. Where a claim is
my judgement rather than evidence, it says so.

**Status of the performance claims.** An earlier draft's performance section
rested on a synthetic bench that loaded 7 of the tree's 170 modules, started no
server and connected no client; it reported 40 streaming sessions at ~3% CPU
while the live harness was taking minutes per message. **That bench and its
numbers are withdrawn.** They are replaced by an end-to-end bench
(`scripts/analysis/bench-end-to-end.sh`) that starts a real harness server, loads
its full module set (104 modules, asserted), connects a real ACP client, drives
real turns, and seeds realistic transcripts. It measures the local path as
healthy **when the server is idle** (42 ms connect, 41 ms reconnect, flat to 12
streaming sessions).

That bench still did not reproduce the reported symptoms, so I stopped benching
and looked at the live harness instead. That found the causes, both measured, both
in §3.5: **the listener's accept queue is five deep** (`:server t`), which makes a
busy harness unreachable and hangs a connect for ~2 minutes — found live,
reproduced deterministically, fixed, and under test; and **every tool call waits
out a 30-second permission judge that then gives no verdict**, so the call is
denied and the turn loses minutes of wall clock — 10 timeouts in 20 seconds in the
live log. The first is Emacs-shaped and would not exist in Go or on BEAM; the
second would follow the code to any runtime.

Along the way I read the live log's `replay: … missed on 100%` lines as cache
misses and was wrong: `:ratio` is the share **reused**, so that line reports a
99.96% hit. The cache is fine; the log line is inverted. That correction is in
§3.5 too, because a log that misleads its own author will mislead the next one.

The reviewability findings — the bus is closed, the layers hold, the method set
is stable, `:requires` is unverified — stand on static evidence, are reproducible,
and are unaffected by the bench error. The performance verdict does not, and has
been rewritten from the live measurements.

---

## 1. What the core actually is

The stated design (`DESIGN.md`) is: a core that loads modules and lets them talk
without knowing each other, all features in modules, all UIs as ACP clients.

### 1.1 Size

| Part | Files | Lines |
|---|---:|---:|
| `harness.el` (loader, reload, update) | 1 | 2,122 |
| Core libraries (`lisp/*.el`) | 25 | 19,247 |
| Server modules (`lisp/modules/`) | 107 | 141,701 |
| UI modules (`lisp/ui/`) | 71 | 95,232 |
| Tests (237 suites) | 237 | — (7,780 `ert-deftest`s) |
| Flutter client | 175 `.dart` | 82,264 |
| Binding contract (`docs/architecture.md`) | 1 | 17,508 |

Counts of the bus, all verified by grep over non-test sources in this tree:

| Thing | Count |
|---|---:|
| Modules (`harness-define-module`) | 162 |
| Bus methods registered (`harness-defmethod`) | **558** |
| Distinct methods *called* via `harness-call` | 279 |
| `harness-call` sites / `harness-call-async` sites | 1,461 / 71 |
| Events declared / emitted / subscribed | 111 / 146 / 67 |
| Filter chains joined | 24 |
| Tools (`harness-define-tool`) | 98 |
| Commits | 1,343 |

1,343 commits. The core proper — loader plus `harness-core.el` — is **3,268
lines, 1.6% of the Lisp**. That ratio is the single best fact about this
architecture: the thing you would rewrite is tiny, and the thing you would have
to port is enormous.

### 1.2 The three primitives

`lisp/harness-core.el` defines the whole bus:

- **Methods** — `harness-register-method` into `harness--methods`, a hash table
  (`:535`). `harness-call` is `(apply (harness-method-fn m) args)` (`:557`).
  A miss signals `harness-no-such-method` (`:563`).
- **Events** — `harness-on` into `harness--subscribers`, an alist per event
  sorted by priority (`:601`, `:611`). `harness-emit` is a `dolist` calling each
  subscriber synchronously, each wrapped in `condition-case` so one failure does
  not reach the others (`:639`).
- **Filters** — `harness-add-filter` into `harness--filters` (`:674`). A
  synchronous chain is a `dolist` passing a value through (`:696`); an
  asynchronous chain is a CPS walk with a `NEXT` continuation and a `:final`
  stop (`:781`).
- **Promises** — `harness-promise`, a state/`value`/callbacks struct (`:271`),
  with a dispatch depth limit of 20 that defers deeper callbacks to the command
  loop (`:295`).

None of this is a message bus. It is a dispatch table, a subscriber list, and a
continuation chain, all in one address space and one thread. `harness-call` does
not serialize, queue, or cross a process boundary.

### 1.3 The module contract, in full

`lisp/modules/harness-tasks.el:7203` is a representative declaration:

```elisp
(harness-define-module 'tasks
  :doc "Task mode: one session per task, through review and the merge queue, …"
  :requires '(store project session agent)
  :init #'harness-tasks--init
  :shutdown #'harness-tasks--shutdown)
```

The struct (`:826`) is `name doc requires init-fn shutdown-fn file feature state
error`. That is the entire static contract. There is no `:provides`, no schema,
no version, no typed method signature. 162 modules declare themselves this way.

### 1.4 ACP is a projection of the bus, not a protocol over it

`lisp/modules/harness-acp.el`:

- **10** hand-written standard ACP methods (`harness-acp--define-standard`, 10
  uses at `:1417`–`:1763`).
- **Every** bus method whose name begins with one of **53** allowed prefixes
  (`harness-acp-extension-prefixes`, `:159`) is callable as `_harness/NAME`
  (`harness-acp--call-extension`, `:1221`).
- The wire signature of each is derived at runtime by reflecting on the Elisp
  function's arglist: `harness-acp--map-params` (`:1119`) calls
  `help-function-arglist` and matches JSON keys to Lisp argument names.

So the ratio is **10 standard methods to 558 extension methods**, and the
extension methods' parameter names *are* the internal Lisp argument names. Rename
an argument and you have silently changed the protocol.

`initialize` advertises the live list (`:1443`, `list :methods (harness-acp--extension-methods)`), and clients gate on it.

---

## 2. How well did it work? — measured

This is the question you actually asked. Here is the evidence, in both
directions.

### 2.1 What genuinely worked

**(a) The presentation/state split held, and it is the real achievement.**

- UI files that `require` a state module (`session|tasks|agent|perms|provider`):
  **0 of 71**.
- Server modules that `require` a UI module: **0 of 107**.
- `harness-ui-*` symbols appearing in `lisp/modules/`: 41 occurrences, and every
  one I opened is a docstring cross-reference (`harness-session.el:699`,
  `harness-acp.el:233`), not a call.

The DESIGN.md litmus test — "can a module be tested without the presence of any
of the others" — is at least true of this seam. Note it is enforced **only by
convention**: `test/harness-test-layout-test.el` checks that suites live beside
modules, and nothing checks the dependency direction. A lint rule would cost
twenty lines and is the cheapest thing on this list.

**(b) The bus is stable. Method churn is near zero.**

Across the last 300 commits, grepping the diff for `(harness-defmethod NAME`:

- 7 method names were **removed** in total: `acp/remote-forget-code`,
  `acp/remote-pair`, `cowboy/compact`, `sandbox/check-command`, `task/search`,
  `task/search-warm`, `task/set-priority`.
- The rest of the churn is adding `&optional` arguments.

For a 558-method surface built by one person over 1,343 commits, that is
remarkably disciplined. It means the naming convention (`area/verb`) plus the
"methods are the API" rule actually produced a stable interface. Whatever you
rewrite *to*, keep this convention; it is load-bearing.

**(c) Hot reload works, and it is the best-engineered thing in the tree.**

`harness--reload` (`harness.el:1144`):

1. Byte-compiles **every** file out of tree first, and refuses to load anything
   if one fails.
2. `harness--reload-snapshot` (`:1027`) records `load-history` and each
   function's `symbol-function` *before* loading; afterwards it `fmakunbound`s
   exactly the functions a library used to define and no longer does, guarded by
   `symbol-file` so a function that moved files survives.
3. Re-applies policy, re-runs every ready module's `:init` (which is required to
   be idempotent — `harness-on`/`harness-add-filter` dedupe by named function,
   `:611`/`:677`), and reports `:unbound`.

That is a small dynamic linker with an unload path, in ~200 lines. It is why the
project can be developed by dogfooding itself. **Nothing in Go gives this for
free.** BEAM gives code replacement, but not "unbind what vanished" semantics —
you would write this again either way.

**(d) Capability negotiation is real, and it degrades per feature.**

The Flutter client gates every optional feature on the advertised method list:
**54** `api.can('…')` call sites, from `hand_in_report_screen.dart:139`
(`demo/start`) to `task_controller.dart:215` (`task/slots`). A harness with half
its modules disabled renders a smaller app rather than breaking. That is exactly
what the bus was for, and it worked.

**(e) Failure isolation is consistently applied.**

Every dispatch site wraps its callee: `harness-emit` (`:648`), `harness-run-filter`
(`:703`), `harness--run-async-chain` (`:804`), `harness-module-start` (`:975`,
`:996`), `harness--promise-dispatch` (`:347`). One broken module does not take the
system down, and that is the property that let 162 modules grow.

**(f) Timers are tracked and cancelled.** ~60 timer `defvar`s across server and
UI, and 248 non-test `cancel-timer` sites — a ratio above 4 cancels per timer,
which is the signature of cancel-on-every-exit-path discipline rather than
cancel-if-remembered. The ones I spot-checked (`harness-merge--timers`,
`harness-tasks--lend-timers`, `harness-agent--progress-timers`,
`harness-session-search--timer`, `harness-admission`) all cancel by key and
remove the key. No leak found.

### 2.2 What did not work

**(a) The module system orders *initialisation*, not *loading*.**

`harness--module-order` (`harness-core.el:934`) is a correct topological sort.
But it is applied only in `harness-modules-init` (`:1009`), which runs `:init`
functions. The files themselves load in `harness--module-files` (`harness.el:622`)
order, which is `directory-files` order — **alphabetical**. Measured: 61
server-side files, `sorted-p: t`.

Consequence: any module that calls another module's function at load time is
depending on the letter its filename starts with. `docs/module-audit.md:109`
records 14 modules that did exactly that in October. Re-measured at `9544288`
against the loader's own parser (`harness--module-sources` /
`harness--module-header`, which unions the declaration with top-level
`require`s):

```
module files=177  declarations=162  declared edges=298
undeclared file-level requires: 60 modules / 93 edges
declared edges loaded after their requirer: 198 of 298 (66%)
```

**66% of declared dependency edges are loaded in the wrong order, and 60 modules
call into a module they `require` without declaring it** — up from 14 in
October. The `:requires` list is documentation, not a constraint: it orders
`init` and nothing else. (An earlier draft of this report said "180 undeclared,
28%" from a cruder regexp scan that counted library files and missed the
header's union; the numbers above are the loader's own.)

**The lifecycle is asymmetric, and it is prose.** `harness-define-module`
(`harness-core.el:826`) accepts `name doc requires init-fn shutdown-fn` and
nothing else — there is no `:provides`, `:emits` or `:calls`, so a module's
interface is discoverable only by reading its source or re-parsing it. Measured
at `9544288`: **131 modules have `:init`, 78 have `:shutdown`, and 55 have one
without the other** (53 `:init`-only, 2 `:shutdown`-only). An `:init` that arms
a timer or a hook and no `:shutdown` that disarms it leaks on every reload — a
scan of the `:init` functions finds **55 that add a timer or a hook with no
`ready-p` guard**, so each reload re-arms them. Init failure is
isolated and visible (dependents fail with `"requirements not ready"`, unrelated
modules still start) but **sticky**: nothing is rolled back and `harness-start`
never retries. `harness-module-disable` (`:1033`) has **zero production
callers**, does not stop the module's subscriptions or methods, and cannot be
reversed — there is no enable.

**(b) The call graph is closed — I expected it not to be, and was wrong.**

My hypothesis was that a 558-method stringly-typed bus would be full of dangling
`harness-call`s. I measured it with the tree's own scanner instead of guessing:
every `:calls` entry across all modules and core files, against every
`:methods` entry.

```
methods called=436  defined=558  MISSING=5
  client/customize-save   client/notify   computer/mcp   emacs/mcp   server/stop
```

All five are not defects:

- `client/notify` and `client/customize-save` are **client-side** methods — the
  harness calls the *client* with them (`harness-ui.el:1041`, `:1045` handle
  them). They are correctly absent from the server's registry.
- `emacs/mcp` and `computer/mcp` are served by `harness-emacs-endpoint.el:1738`
  and `harness-computer-endpoint.el:222` as ACP method constants, not bus
  methods.
- `server/stop` is registered directly into the ACP table by
  `harness-server.el:392` (`puthash "_harness/server/stop" …`), deliberately
  outside the bus.

So the bus is **closed to 5 explainable exceptions out of 436 call sites.** That
is not luck: it is what a consistent `area/verb` convention plus a stable method
set buys you (§2.1b), and it is much better than I expected from a dynamic
registry. It is also the strongest single piece of evidence that this
architecture is *not* slop.

The gap is that nothing **checks** this. `harness-module-docs-test.el:390-402`
verifies events (declared and forwarded); nothing verifies calls. The five
exceptions above are exactly the kind of thing a check would need to allowlist —
which is the right shape for such a check to take.

Two caveats on the one check that does exist. It matches emitted names
*syntactically*, so it is blind to a computed name — the one way an undeclared
event could still reach the bus. And the sibling check,
`scripts/module-docs.sh --check`, is **not wired into `scripts/test.sh`**, so the
source-derived module pages can drift from the modules without failing anything.
A's sharper version of this: there are **~590 `harness-method-exists-p` guards
against ~1,450 `harness-call` sites, and no test that a literal call name has a
method** — the guards are the codebase compensating at runtime for a check it
never runs at build time.

**(c) The bus has no contract beyond a docstring.**

A method knows its name, function, docstring, owning module, and a free-form
`:params` plist that is documentation only (`harness-core.el:532`). There is:

- no schema for arguments,
- no version,
- no return type,
- no way for a caller to know a method is deprecated,
- no compile-time or load-time check that a call matches its target.

Method signatures *did* change 15 times in 300 commits, and the wire signature
follows `help-function-arglist` — so those changes are protocol changes, and
nothing marks them as such.

**(d) Events carry arbitrary Lisp and are consumed synchronously.**

146 distinct events are emitted from 238 `harness-emit` sites, 67 are subscribed
with `harness-on`, and 111 are declared. The declaration
(`harness-declare-event`, `:607`) stores a docstring and nothing reads it — the
shape is a human-readable arglist in prose, e.g. `merge/finished "(CHILD-ID TARGET
STATUS) merged, failed, aborted or cancelled."` (`harness-merge.el:1302`).
Nothing parses it, and the tree's own check verifies only that an emitted event is
declared and that a UI-heard event is forwarded — I ran it: 0 undeclared, 0
unheard. Shape and arity are unchecked.

Emitters call subscribers **on the emitting stack**. `harness-emit` has no queue.
A slow subscriber delays the emitter. Ties in priority run **last-registered
first** (`harness--insert-handler`, `:627`, conses then stable-sorts), so ordering
between equal priorities depends on registration order, which on reload depends on
`:init` order.

I originally wrote that payloads "happen to be JSON-safe". That was wrong. They are
not, and the failure is silent: `harness--json-prepare` ends in
`(t (format "%s" obj))` (`harness-util.el:77`), so any non-JSON value is
stringified rather than refused. A closure in a payload reaches the wire as
`"#[(x) ((1+ x)) (t)]"`. Real function-valued payloads exist:
`question/ask`'s `on-answer` (`harness-tools-question.el:268`), the closure
`agent/tool-canceller` returns, and `tools/execute`'s `:report`/`:note`. These
work in-process and would be silently corrupted across a language boundary —
which is precisely the class of thing a re-architecture has to find before it
starts, not after.

**(e) The filter chain has one global failure policy, and it was fail-open.**

`harness-set-filter-failure` (`:712`) is called exactly once in the whole tree,
by `harness-perms.el:6813` for the `permission/decide` chain. Every other chain
defaults to fail-**open** ("a function that signals is skipped", `:699`).

This was not theoretical. Commit `424dbdf` records what it cost:

> "The chain fails open. A stage that signalled an error, or whose promise was
> rejected, handed the decision on as it was, so the mode stage after it decided
> a call nobody had checked: with the jail failed, a path no one compared with the
> session's directories, allowed in yolo mode and, as a read, in every other."

An audit of every path-taking tool found **five** ways past the jail, all
consequences of that default. The fix — per-chain fail-closed policy — is right,
but it is opt-in, applied to one chain, and a new chain added tomorrow inherits
the unsafe default silently.

The `permission/decide` chain now has **18 stages** from 9 modules
(`secret-sandbox:2,21`, `secrets:3`, `access:4,5`, `tools-sessions:6`, `computers:7`,
`readonly:8`, `supervisor:9,28`, `tasks:25`, `perms:5,6,10,20,30,40,90`), ordered
by bare integer literals in nine files. Reading `harness-perms.el` alone does not
tell you the effective policy. This is the single most review-hostile thing in the
tree, and it is a *security* boundary.

**(f) Fanout re-encodes per client — real, but not the bottleneck I expected.**

`harness-acp--broadcast-update` (`harness-acp.el:713`) loops over clients →
`harness-acp--client-notify` → `harness-acp--client-send` → **`harness-json-encode`
inside the per-client branch** (`:623`, `:628`). One streamed token to N clients
costs N encodes. Not amortised, no cache. That is a genuine defect and an easy
fix.

But I measured it before claiming it mattered, and it does not matter much yet:

| Payload | encode | ×10 clients | realistic load | CPU |
|---|---:|---:|---|---:|
| streamed token, 248 B | 0.024 ms | 0.237 ms | 30 tok/s × 10 sessions | **71 ms/s (7% of a thread)** |
| 4 KB tool result | 0.061 ms | 0.608 ms | 10/s × 10 sessions | **61 ms/s (6%)** |

So encode-once is worth doing because it is three lines, not because it is the
wall. **Caveat:** these are isolated `harness-json-encode` timings extrapolated
by arithmetic, not a measurement of a live fan-out — they count encoding only,
not the sends, the per-socket write queues, or the replay on reconnect. Read them
as "the encode is cheap per operation", which is the claim they support. (Bench:
`bench-fanout.el` in this session's temp dir.)

**(f2) An open question: the search index logged a schema error it should not.**

While building the end-to-end bench, a freshly started server logged, from a
timer, `sqlite-error ("SQL logic error" "no such table: meta")` at
`harness-session-search--ensure-schema` (`harness-session-search.el:362`). The
obvious reading — that the `ignore-errors` around the version `SELECT` is in the
wrong place — **is wrong**: reproduced on a brand-new database, `ignore-errors`
catches the missing table, the `let` completes, and the schema is created
normally. So the failure needs the table to be missing on a handle whose schema
was already made, which points at handle lifetime rather than schema creation:
`store/sqlite` (`harness-store.el:74`) **closes the handles of any other state
directory** when it opens one, so a second state directory in one process — the
bench's temp dir beside a server's own, say — can have its handle closed and
replaced underneath a running query. That is a hypothesis, not a finding; it is
recorded here because the error is real and reproducible in a log, and it is the
kind of thing that would make a long-lived server misbehave intermittently.

**(g) There is no sequence number, generation, or resume cursor on updates.**

I grepped for it: the only cursors in `harness-acp.el` are `session/list`
pagination (`:1577`–`:1600`). Ordering is socket FIFO and nothing else.

The consequence is a real, shipped bug class:

- `d91fef2` "Fix system messages ordering in mobile" — nodes appended during a
  replay arrived interleaved with older replayed ones. Fixed with a per
  `(client, session)` hold-back queue (`harness-acp--replay-begin`/`--end`,
  `:685`/`:696`), which is correct but is a patch in the client-send path, not a
  protocol property.
- Reconnect has no resync. The Emacs chat's reconnect path
  (`harness-ui-chat.el:5858`) re-fetches only sessions it showed open and
  *inactive*; nodes appended while its socket was down are not re-read.

That last one is the strongest single argument that the protocol layer is
under-designed: two clients, one of which silently loses data on reconnect.

**(h) Backpressure punishes the client.**

The async writer bounds a socket at 32 MiB / 65,536 messages
(`harness-util.el:2193`, `:2199`) and on overflow **closes the peer**
(`:2425`). The Emacs UI works around it by pacing exactly two methods
client-side — `harness-ui--bulk-methods` is literally
`'("_harness/session/list" "_harness/task/list")`, with the comment "a burst of
them overflows it and the harness drops the connection" (`harness-ui.el:472`).
Flutter has no equivalent, and `da26ff3` records a phone being dropped by an
8.7 MB listing. A protocol with flow control would not need a hard-coded list of
two method names in one client.

**(i) The Emacs UI is a client of state but a co-resident of the process.**

62 of 71 non-test UI files `require 'harness-core`; there are **937**
`"_harness/…"` call sites covering **261 distinct methods** — 47% of the entire
server surface. Flutter uses **78**. So:

- the Emacs UI is the only client that exercises half the API,
- and it exercises it through the same generic reflection path,
- and it has 4 `harness-method-exists-p` guards against Flutter's 54 `can()`
  sites — because it usually talks to its own harness, where the modules it
  needs are the ones it loaded.

The asymmetry is invisible until someone points the Emacs UI at a remote server
with a different module set, which `harness-server-address` explicitly supports.

**(j) One genuine bypass, small and guarded.**

`harness-ui-report.el:532,552,582` calls `harness-call 'demo/status|start|stop`
directly — a `funcall` on the in-process method table. It *is* guarded by
`harness-method-exists-p` (`:532`, `:548`, `:582`), so against a remote harness it
degrades to a `user-error` rather than misbehaving, but it is a UI reaching past
ACP into the bus, and it only works when the UI shares a process with the server.
Three call sites, all about the demo module, all in one file. That is the only
real violation of the layer rule I found — a good result for 71 UI files.

---

## 3. Where it breaks at your target scale

Your target: several computers × several clients × several projects × tens of
tasks each. Let me separate what the architecture forces from what Emacs forces.

### 3.1 The current real scale is already large, and it mostly copes

This checkout has **482 registered git worktrees** and 62 GB of them, and
`git worktree list` still takes **52 ms**. The task store is sharded per project
repository (`harness-tasks.el:1566`) and handles *another harness owning the same
checkout* (`:1574`, "a store naming another state directory is another harness's
… it is left alone"). That is a genuine multi-instance design decision, made
correctly.

So the file-system and store layer is not where this breaks.

### 3.2 What the architecture forces (would still be wrong in Go or Elixir)

**One in-memory task table for every project.** `harness-tasks--table` (`:935`)
holds every task of every project, loaded at once by `harness-tasks--load`
(`:1713`) and written back whole by `harness-tasks--save` (`:1655`). Sharding the
files does not shard the memory or the save. With 10 projects × 30 tasks this is
fine; with 50 projects it is a full-table rewrite on every task change, debounced
by `harness-tasks--dirty`.

**Merge locks are process-local.** `harness-merge--locks` (`harness-merge.el:168`)
is a `defvar` hash table. Worktree locks *are* persisted
(`harness-worktree--locked-roots-file`, `:75`) but merge locks are not. Two
harness processes on one repository can enter the merge queue for the same target
concurrently. Nothing in the design prevents it; nothing detects it.

**Fanout is O(clients × payload).** §2.2(f). At 3 clients it is 3 encodes; at 10
it is 10. With streamed tokens this is the hot path.

**No resync means no cheap reconnect.** §2.2(g). A phone that sleeps and wakes
must re-read its transcript; a chat buffer silently misses what happened.

**No supervision.** `harness-resilience` is a *recovery* module, not a
supervision tree: on a crashed turn it prompts the session to carry on
(`harness-resilience--carry-on`, `:251`) and counts attempts. There is no
restartable unit, no isolated failure domain, no "this worker died, restart it
with its last state". A crash in a process filter is caught by
`harness-server--command-error` (`harness-server.el:189`) and *logged*; the work
that was in flight is gone.

That is the gap BEAM's supervisor trees actually fill, and it is the one place
your instinct is right for a reason beyond taste.

### 3.3 What Emacs forces (would be fixed by any other runtime)

- **No parallelism.** One Lisp thread. The only real thread in the tree is the
  socket writer (`harness-util.el:2430`), mutex-guarded (9 `with-mutex` sites).
  Everything else — ~60 timer variables, 12 process filters, 18 sentinels, 64
  subprocess spawns — is cooperative on one thread. One slow handler stalls
  every session.
- **`accept` is on that one thread, so a busy loop stops new clients.** The
  kernel completes a client's TCP handshake and queues it; Emacs takes it off
  the queue only when the event loop reaches the listener's `:log` callback. A
  turn, a compaction or a large transcript write therefore delays every
  connection, and with the default backlog of 5 (§3.5, Defect 1) the sixth
  client's SYN is dropped and the client waits out `tcp_syn_retries` — about
  two minutes here — before failing. This is not a throughput limit but an
  availability one: the harness is unreachable precisely while it is working.
  No other runtime in this comparison has it, because accept is not on the same
  thread as the work.
- **The timer list is a sorted list, and insertion is linear.** `run-at-time`
  calls `timer--activate` (`timer.el:162`), which walks `timer-list` from the
  head until it finds a later fire time. Measured in a bare `emacs -Q --batch`
  (31.1): appending a timer behind 0 / 100 / 500 / 1,000 / 2,000 / 4,000
  existing ones costs **2 µs / 218 µs / 751 µs / 1,454 µs / 2,495 µs /
  6,640 µs**, while prepending in front of the same list costs 2–82 µs. The cost
  is in the walk, not the timer. (Two runs agreed within ~10% at 1,000 and above
  — 1,454 vs 1,573 µs — so treat these as the right order, not exact.)
  The harness's exposure depends entirely on how many timers are *live at once*,
  and that is O(sessions), not O(events): every per-session timer is a one-shot
  that replaces its predecessor by key — `harness-agent--progress-timers`
  (`harness-agent.el:523`), the `harness-session--touch` debounce
  (`harness-session.el:491`), `harness-debounce`'s own table
  (`harness-core.el:516`), and `harness-usage--live`'s `:timer`
  (`harness-usage.el:927`). The streaming delta path itself creates none:
  `session/update-node` with `:transient` neither touches the record nor
  schedules a save. So a streaming session holds a handful of timers (progress,
  usage, a debounce), not one per delta. Measured, the cost per insertion at the
  counts that implies is **283 µs at 100 live / 523 µs at 200 / 755 µs at 300 /
  1,115 µs at 500** — real, linear, and paid once per timer creation.

  How much that hurts depends on creation rate, which is per event rather than
  per session: a few timers per second per streaming session is ~1 ms/s at 200
  sessions, and the same 200 sessions with tools running (per-chunk progress
  announcements) multiplies it. That is the honest statement of the risk — a
  millisecond-scale cost that scales with *event rate × live timers*, not the
  "every loop turn stalls" picture. It is a real reason a heap beats a list, and
  at the stated target it is **not** the first ceiling; the ACP inbox drain and
  the quadratic delta path (§3.5) bind earlier.
- **Full transcripts resident.** `harness-session--load-nodes` (`:506`) loads a
  whole node log into a hash table on first touch and never evicts. N open
  sessions × full transcripts, plus one synchronous `write-region` per node
  (`harness-session--persist-node`, `:526` → `store/append`,
  `harness-store.el:34`).
- **GC.** The tree's own measurements (`docs/analysis/ui-thread-blocking-2026-10-23.md`)
  show 145 ms collections on a ~300 MB heap, and 58% of UI CPU samples in GC.
  That was the *UI*, not the server — but the same allocator is on both sides.

### 3.4 The only real measurements in the repo

`docs/analysis/rust-backend-2026-11-07.md` §5.2, a standalone server against
synthetic state:

| Measurement | Value |
|---|---|
| start, no sessions | 360–366 ms |
| start, 1,000 sessions | 477–504 ms |
| RSS idle / 1,000 × 40 KB sessions | 97 MB / 155 MB |
| `session/list`, 1,000 lean sessions | 0.77 MB, 19–39 ms |
| `session/list`, 1,000 × 40 KB | 40.8 MB, 270–305 ms |
| server-side JSON encode of those 40.8 MB | **82 ms** |

The important reading: of the ~300 ms for the 40 MB listing, Lisp accounts for
82 ms. **The rest is transport and the payload decision.** The prior analysis's
conclusion — "the wire cost is the payload, not the session count" — is correct
and it is the same conclusion I reach independently.

### 3.5 Ceiling of the current design — end-to-end, on the production path

An earlier version of this section rested on a synthetic bench. That bench loaded
7 of the tree's 170 modules, never started a server, never connected a client,
and reported 40 streaming sessions at 3% CPU while the live harness was taking
minutes per message. **It has been thrown away and replaced.**

`scripts/analysis/bench-end-to-end.sh` measures what a user waits for, on the
production path, and refuses to report unless it can prove it is there:

- a real `emacs --batch` harness server, started as `harness-server-main` starts
  one, with `HARNESS_SERVER_CONFIG`, `HARNESS_SERVER_TOKEN` and
  `HARNESS_SERVER_PARENT` set by the bench as the spawning UI sets them;
- a real ACP client over TCP, the same `harness-acp-connect` +
  `harness-acp-initialize` the Emacs UI and the Flutter client use;
- real turns through the demo provider, so deltas are streamed, persisted and
  fanned out for real;
- a **seeded realistic state**: 60 sessions × 200 nodes × 40 KB on disk, in the
  harness's own `sessions/ID.json` + `sessions/ID.nodes.jsonl` format.

Before measuring it asserts three things and errors if any fails: **the server
loaded its full module set** (104 modules; a subset is an error, not a fast
number), **an ACP client is connected**, and **`session/list` answers**.

| Measure | Result |
|---|---|
| connect (socket + initialize + auth) | **42 ms** |
| reconnect (fresh socket) | **41 ms** |
| one prompt, demo provider | 10.16 s, 39 deltas, `end_turn` |
| 1 streaming session | late p95 32.3 ms, max 45.7 ms, 0 over 100 ms |
| 4 streaming sessions | late p95 33.8 ms, max 46.4 ms, 0 over 100 ms |
| 12 streaming sessions | late p95 32.7 ms, max 42.5 ms, 0 over 100 ms |

The p95 of ~32 ms is the 50 Hz heartbeat's own resolution, not queueing.

**What this establishes, and what it does not.** The local TCP path is fast *when
the server is idle*. It connects in tens of milliseconds, reconnects as fast, and
does not degrade out to 12 concurrent streaming sessions against a realistic
state. That is a real measurement of the real path — but it is a measurement of
an idle server, and the harness is not idle.

**The reported symptoms are not on this path, and they are not a mystery. They
are two defects, both of which I found in the live harness while it was running
the way the report describes.** Neither needed a synthetic bench: both are
visible in `ss`, in the server's own log, and in the kernel.

#### Defect 1 — the listener's accept queue is five connections deep

Every listener in the tree was created with `:server t`. In Emacs,
`make-network-process`'s `:server` argument is not a boolean: it is **QLEN, the
listen backlog**. `:server t` is the default QLEN, which Emacs documents as **5**
(measured: `:server t` → 5, `:server 1` → 1, `:server 512` → 512).

A backlog of 5 is not a queue, it is a race. When the event loop is busy — running
a turn, compacting, writing a transcript — the kernel completes the TCP handshake
and puts the connection in the accept queue, but Emacs does not call `accept`.
Six such connections fill the queue. The seventh is not refused: the kernel
**drops its SYN**, and the client retransmits. On this machine
`tcp_syn_retries = 6`, so the client waits **about two minutes** before the
connect fails, and every retry starts the same wait.

**Caught live, on this harness, while writing this section.** The user's own
server, with no client connected, sat with a permanently full queue:

```
$ ss -ltn | grep :4276
LISTEN   Recv-Q=6   Send-Q(backlog)=5   0.0.0.0:4276
```

`Recv-Q=6` on a backlog of 5, `established=0`, unchanged across 60 seconds of
polling and 6 probe connections. `/proc/net/tcp` agrees — state `0A` (LISTEN)
with `rx_queue = 00000006` — so these are six connections the kernel accepted and
Emacs never took. A connect against that listener times out at the TCP level:

```
$ python3 -c 'socket.create_connection(("127.0.0.1",4276),timeout=4)'
TimeoutError: timed out
```

That is exactly "cannot connect in under a minute", and exactly "takes five
minutes to reconnect": each attempt waits out the SYN retransmits, and the
retries stack.

**Reproduced deterministically, and the fix confirmed.** A blocked event loop with
`:server t` accepts 6 of 10 concurrent clients and hangs the other 4; a single
extra connect to the full queue is still hanging after 45 s. The same blocked loop
with `:server 512` accepts **40 of 40 with a maximum wait of 0.00 s**:

| Event loop | Backlog | Concurrent connects | Result |
|---|---|---|---|
| blocked | 5 (`:server t`) | 10 | 6 accepted, 4 hang (12 s timeout) |
| blocked | 5 (`:server t`) | 1 more, queue full | still hanging after 45 s |
| blocked | 512 (`:server 512`) | 40 | **40 accepted, max wait 0.00 s** |

Fixed at all five listeners — `harness-acp.el`, `harness-acp-remote.el`,
`harness-claude-plugin.el`, `harness-chatgpt-plan.el`, `harness-workspace-box.el`
— through one `harness-listen-backlog` constant in `harness-core.el`. Two tests
now guard it: one reads the kernel's backlog off the live socket and asserts it
is not 5, the other scans the tree for any listener left on `:server t`. The
first **fails on the old code** (`(>= 5 512)` is false) and passes on the new.

#### Defect 2 — every tool call waits out a 30-second judge that then gives no verdict

This one I got wrong first, and the correction is worth keeping. The live log is
full of lines like `replay: … missed on 100% of 237436 tokens`, and I read them as
cache misses. **They are not.** `harness-session.el:4035` computes
`:ratio` as `cache-read / previous` — the share **reused** — and
`harness-replay.el:1291` prints that number after the words "missed on". So a
perfect cache hit logs as "missed on 100%", and the response lines prove it is a
hit: `prompt=237672 cache-read=237568` is **99.96% served from cache**. The cache
is working; the log line is inverted. (Filed below as a separate finding.)

What the live log *does* show, and what actually costs minutes, is the permission
judge:

```
03:51:22.149 WARN [server] perms: auto judge timed out for bash
03:51:22.150 WARN [server] perms: auto judge timed out for bash
03:51:22.150 WARN [server] perms: auto judge timed out for bash
03:51:25.059 WARN [server] perms: auto judge timed out for bash
03:51:40.362 WARN [server] perms: auto judge timed out for bash
… 10 timeouts in 20 seconds …
```

`harness-perms--auto-timeout` is **30 seconds** (`harness-perms.el:409`), and it is
spent **per tool call**, not per turn. When it expires the judge settles with the
ask decision carrying `:no-verdict` (`:4016-4022`), and in a non-interactive
session the next stage **denies the call**
(`harness-perms--unapproved`, `:4415-4420`). So each tool call costs a full 30 s of
wall clock and then fails. A turn that wants five tools spends **2.5 minutes
waiting** before its work even starts, and the work then does not happen. That is
"a single message takes five minutes", with the mechanism in the log and the
constants in the code.

Why the judge times out is the next question, and the log answers it too: the
judge's own model calls are in the same log at 1,200–6,800 prompt tokens each,
running concurrently with every other session's. The judge is a real model call
with a 30 s budget on a machine at load average 10–15, so under load it simply
does not answer in time — and the harness then denies the user's work rather than
proceeding.

This is a design defect, not a tuning one: **a safety check that denies the user's
work when it is slow converts load into lost work.** The fix is to make the
timeout fall back to what the mode would do without a judge (ask, or allow under
an explicit policy) instead of denying, and to make the judge's budget a function
of whether anyone can be asked. I have not changed it: it is a policy decision
about what the harness may do unattended, and it should be yours.

#### A finding, not a defect: the cache-miss log line is inverted

`harness-replay.el:1291` logs `(round (* 100 ratio))` as "missed on N%", where
`:ratio` is the share **reused** (`harness-session.el:4035`,
`harness-cache.el:456` treats a *high* ratio as healthy). Every reader of that log
— me included, for most of this investigation — concludes the cache is failing
when it is working at 99.96%. It costs nothing to fix and it cost me a wrong
conclusion, which is the argument for fixing it.

#### What this means for the re-architecture

Defect 1 is **Emacs-shaped**; Defect 2 is not, and that distinction matters:

- Defect 1 exists because Emacs's single event loop is the only thing that can
  `accept`, so any work it is doing stops every client from connecting — and
  because the API's default is 5. On BEAM each acceptor is its own process and
  the listen backlog is a socket option nobody sets to 5; on Go the accept loop
  is a goroutine. **Neither runtime would have this bug.**
- Defect 2 would follow the code to any runtime. A 30 s budget that denies on
  expiry is a policy, and a port would port it. **Rewriting the harness would not
  fix it**, which is the single most useful thing this investigation found about
  the rewrite question: the worst user-visible failure here is not the language.

The earlier hypothesis in this section — the `harness-acp-remote` 60-second
refusal ladder and the 2/5/15/30/60 listener retry ladder — is real code and a
real risk for a phone with a stale secret, but it is **not** the explanation for
the local Emacs client's minutes, because the local client does not go through
that module at all (`harness-acp-remote` defaults to nil). Defect 1 explains both
the local client and the phone, with one mechanism; Defect 2 explains the rest of
the wait.

---

## 4. Elixir/BEAM or Go?

You named two things BEAM gives you: process trees and supervision. Let me check
each against what this code actually needs, then do the same for Go.

### 4.1 What BEAM gives you that this code needs

| Need | Evidence it is needed | BEAM primitive |
|---|---|---|
| Supervision with restart | no supervision today (§3.2) | OTP `Supervisor`/`GenServer` |
| Isolated failure domains | one crash loses in-flight work | processes are isolated, crashes are signals |
| Real concurrency | one thread, §3.3 | preemptive scheduler, N cores |
| Per-session state without a global table | `harness-sessions`, `harness-tasks--table` | one process per session, state is process-local |
| Timers at scale | ~60 timer variables, 248 cancel sites, one thread | per-process `:timer`/`receive after` |
| Backpressure | socket bound closes peer | mailboxes with `max_heap_size`, `GenStage` demand |
| Hot code reload | `harness-reload` already does this | `:code.load_file` — but see below |
| Distribution across computers | several computers is your target | `:erlang` distribution, or not — see risk |

That last row is where your instinct is strongest and where the trap is. BEAM
distribution would let one node hold sessions and another hold tools, which maps
onto the existing client/computer split. But distributed Erlang assumes a
**trusted** network with cookie auth — it is not a security boundary — and this
harness has a whole `docs/trust-model.md` (761 lines) about not trusting devices.
You would run BEAM distribution inside one trust domain and keep ACP across the
boundary, which is fine, but it means distribution buys you less than it appears.

**Where BEAM is genuinely better than Go for this specific program:** the shape
of the domain is "hundreds of long-lived stateful things, each with a lifecycle,
each failing independently". That is Erlang's home turf, and a Go implementation
would spend its effort re-inventing supervision with goroutine + channel +
context plumbing, which is exactly where Go programs get subtle bugs.

### 4.2 What BEAM costs you here

- **You would lose the Emacs side entirely or keep it.** 95,232 lines of UI,
  the `elisp` tool, the Emacs endpoint, TRAMP, `.dir-locals.el` plugins,
  Customize, and `harness-reload` all stay in Emacs. So a BEAM core is a
  **split** architecture, not a replacement: Elixir server + Emacs UI speaking
  ACP, exactly as today, but with the server in another language.
- **You would write the plugin system again, or lose it.** A `.dir-locals.el`
  that `require`s a plugin defining `open_harness` cannot be loaded by BEAM. The
  repo's own dev loop uses it (`.dir-locals.el:16-23`).
- **The dynamic surface is the product.** 558 methods, 111 declared events, 98 tools,
  discovered at runtime and advertised to clients. In BEAM this becomes
  `GenServer` calls with a registry — doable, but the "any module can add a
  method and a client can call it" property needs deliberate design, not a
  `defmethod` macro.

### 4.3 What Go gives you

- Clear, boring, reviewable structure — which is your stated primary motivation.
- Real parallelism, excellent HTTP/WebSocket/TLS, a great static type system for
  the data shapes, trivial deployment.
- No supervision tree: you build it from `context`, `errgroup`, and restart
  loops. It is well-trodden but it is *your* code, not a runtime guarantee.
- No hot reload. You would restart the process and recover sessions from disk —
  which the harness already does (`harness-resilience`), so this is less
  catastrophic than it sounds.

### 4.4 The honest comparison for *this* program

| | Elixir/BEAM | Go |
|---|---|---|
| Supervision, isolation, lifecycle | built in | hand-built, well understood |
| Concurrency at 100s of sessions | natural | natural |
| Reviewability by you | high (immutable, small modules) | highest |
| Type safety of the 558-method surface | low (dynamic, like today) | high (but you must design it) |
| Hot reload | partial | none |
| Emacs integration | stays in Emacs | stays in Emacs |
| Effort to reach parity | very high | very high |
| Ecosystem for this domain | strong (LiveView, GenStage) | strongest |

Neither is a small job: the prior analysis puts a full backend rewrite at 3–6
engineer-years, and that estimate was for Rust with the same ACP contract.

### 4.5 What I would actually recommend

Your stated problem is **"I cannot read the Elisp and tell whether it is good."**
That is a *reviewability* problem, and the static evidence says the architecture
is in better shape there than it looks from outside: the bus is closed, the
layers hold, the method set is stable. Those findings stand.

What does **not** stand is the corollary I drew from them — that the architecture
is therefore *fast enough*, and that a rewrite would be premature. That rested on
a synthetic bench that ran 7 of 170 modules while the live system was stalling for
minutes. That bench is replaced (§3.5), and the replacement measures the real
local path: **42 ms to connect, 41 ms to reconnect, no degradation to 12
concurrent streaming sessions** against a realistic state. That is a real result
and it is *not* a subset measurement.

But it also **did not reproduce your symptoms**, and finding out why is what
produced the two measured defects in §3.5. Five minutes per message and a phone
that cannot connect were **not** the remote path's refusal ladder — that was my
first hypothesis and it was wrong, because the local Emacs client does not go
through `harness-acp-remote` at all. They are:

- **the listener's accept queue, five deep** (`:server t`), which makes a busy
  harness unreachable and hangs a connect for ~2 minutes on the kernel's SYN
  retransmits — **found live on your harness, fixed, and now under test**;
- **a 30-second permission judge that denies on timeout**, so every tool call
  waits out the budget and then fails — **10 timeouts in 20 seconds in the live
  log; not fixed, because what to do unattended is your call**.

So, in order:

1. **Decide what a slow judge does (hours).** This is the live, unfixed cause of
   minutes per message: `harness-perms--auto-timeout` is 30 s per tool call
   (`harness-perms.el:409`), and on expiry a non-interactive session **denies**
   (`:4415-4420`). A safety check that loses the user's work when it is slow turns
   load into lost work. Falling back to ask — or to the mode's own policy — rather
   than deny is the fix; which one is a policy decision, so I left it to you.
2. **Watch the accept queue in production (hours).** The fix is in, but the defect
   was invisible for as long as it was because client connect/disconnect logged at
   `debug` and the default level is `info`. Those now log at `info` with a reason.
   Consider an alert when `Recv-Q` on the listener approaches the backlog.
3. **Fix the inverted cache-miss log line (minutes).** `harness-replay.el:1291`
   prints the *reused* share as "missed on". It cost me a wrong conclusion in this
   very report; it will cost the next reader one too.
4. **Make the filter-chain policy fail-closed by default (hours).** `424dbdf`
   shows the fail-open default put five holes in the jail, and the fix is opt-in
   per chain. Invert the default and make the "only adds" chains opt *out*. Also
   pull the 18 `permission/decide` priorities into one shared constant list, so
   the effective policy is readable in one place instead of nine.
5. **Turn the scanner into assertions (days).** The bus is already closed, the
   layers already hold, and `docs/modules/` already renders the graph; what is
   missing is that nothing *checks* any of it. Add the five checks in the
   Appendix as tests, then fix the one that fails: the 60 modules whose
   file-level `require`s are undeclared. After that the dependency graph is
   readable from the declarations alone. The accept-queue fix is the model: one
   test reads the kernel's socket, one scans the tree, and the bug cannot come
   back silently.
6. **Fix the two protocol defects that lose data** (§2.2 g/h): a per-session
   sequence number with `session/subscribe(since:)`, and flow control in the
   protocol instead of a 32 MiB hard close. Encode-once fanout is a nice cleanup
   and cheap, but the encode is only ~0.024 ms per token (§2.2f) — do it because
   it is cheap, not because it is the wall.
7. **Make streaming incremental (hours).** Send the delta and let the client
   concatenate, instead of re-`concat`ing the whole answer and re-merging it into
   the node on every chunk (§3.5). It is the one measured cost that grows with
   answer length rather than session count, it is the same fix in any language,
   and it is small — unlike the rewrite it is often cited to justify.
8. **Then** decide on the rewrite. The driver should be *accept and event-loop
   coupling, long-blocking handlers, and transcript memory*, not aggregate
   throughput — the end-to-end bench (§3.5) puts the local path at 42 ms to
   connect and flat to 12 streaming sessions when the server is idle. The
   accept-queue defect is the clearest argument *for* another runtime in this
   whole report, and it is also the cheapest one to fix here (a constant), which
   is the honest tension: the architecture is not what failed, the runtime's
   defaults were. And the worst user-visible failure, the judge, is **not**
   runtime-shaped at all — a port would keep it. Not reviewability, which step 5
   largely solves. Taste is a legitimate reason to prefer Go, but it is not
   evidence the Elisp is wrong.

If you do rewrite, **extract rather than replace**, and start with the part whose
boundary is already clean: the ACP edge. That is a small service with a fixed
protocol (the 10 standard methods plus a declared subset of extensions), and it is
where the correctness bugs live (no resync, flow control by disconnection). It can
be written in Go in weeks and validated against the existing clients without
touching the 141 k lines of state logic. Note that the *performance* case for this
extraction is weaker than I first assumed — the measured win is the protocol
semantics, not the CPU.

The 558-method dynamic bus is the thing that makes a full rewrite expensive, and
it is also the thing that has worked best. Rewriting the part that works to fix
the part that does not would be the expensive mistake here.

---

## 5. Direct answers to your questions

**"How well has the module loader worked?"**
The *contract* worked: 162 modules, failure isolation everywhere, stable naming,
hot reload that is better than most dynamic languages offer. The *loader* is
weak in two specific ways, both now measured against its own parser: load order
is alphabetical while dependency order is applied only to `:init` (**198 of 298
declared edges, 66%, load after the module that requires them**), and
`:requires` is unverified documentation (**60 modules, 93 edges** call into a
module they `require` without declaring it, up from 14 in October). Both are
fixable with static checks, not a rewrite.

**"How well have the ACP module/action methods worked?"**
The method *registry* worked well: 558 methods, 7 removed in 300 commits, 436 call
sites all resolving, clients gating on capabilities. The *protocol projection* is
the weak part: the wire signature is reflected from Lisp arglists, there is no
version, no schema and no sequence number, and the result is that the Emacs UI
uses 261 methods while Flutter uses 78, with silent data loss on reconnect. Note
the split — the bus itself is sound, and it is the *serialization of the bus onto
a wire* that is under-designed. That is a much smaller thing to fix than it looks,
and it is exactly the part worth extracting into its own service.

**"How well has the event bus worked?"**
Adequately, and less than it appears — B's independent audit sharpens this. Events
are declared (0 undeclared, 0 unheard: I ran the tree's own check) but the
declaration is only a docstring that nothing reads (`harness-core.el:604`), so the
"contract" is English prose. 146 distinct events are emitted and 67 subscribed;
111 declared. Payloads are documented as arglists in prose
(`harness-agent.el:3162`), and `harness--json-prepare` will silently *stringify* a
non-JSON payload rather than refuse it (`harness-util.el:77`), so a closure
reaches the wire as `"#[(x) …]"`. It is a good in-process notification mechanism
and it is not a message bus. Carry forward the *convention* (`area/past-tense`,
declared events, named handlers), not the mechanism.

**"How does it scale to several computers, several clients, several projects,
tens of tasks each?"**
**The local path, measured end-to-end** (§3.5): 104 modules loaded, a real ACP
client, realistic seeded transcripts — **42 ms to connect, 41 ms to reconnect,
no degradation to 12 concurrent streaming sessions**. An earlier draft answered
this question from a synthetic bench that loaded 7 of 170 modules; that number is
withdrawn, and the end-to-end one replaces it.

**But the reported symptoms are not on that path either.** Five minutes per
message and a phone that cannot connect are **two measured defects** (§3.5), not
a scaling limit:

- **the listener's accept queue is five deep** (`:server t`), so a busy event loop
  drops the sixth client's SYN and the connect hangs for ~2 minutes on the
  kernel's retransmits — caught live on this harness with `Recv-Q=6` on a backlog
  of 5 and `established=0`, reproduced deterministically, fixed at all five
  listeners, and now under test. It explains both the local Emacs client and the
  phone, with one mechanism.
- **a 30-second permission judge that denies on timeout** — `harness-perms--auto-timeout`
  is 30 s **per tool call** (`harness-perms.el:409`), and when it expires a
  non-interactive session denies the call (`:4415-4420`). The live log shows **10
  timeouts in 20 seconds**, so a turn that wants five tools spends 2.5 minutes
  waiting and then loses the work. That is the "minutes per message".

My earlier answer here — that the symptoms were on the remote WebSocket path and
its 5-refusals-to-60-seconds lockout — was **wrong**, and worth naming as wrong:
the local Emacs client does not go through `harness-acp-remote` at all (it
defaults to nil), so that module cannot explain its minutes. I also read the live
log's `replay: … missed on 100%` lines as cache misses; `:ratio` is the share
**reused**, so those lines report 99.96% hits. The cache was never the problem.
What the report can say with evidence:

- *Files and stores*: already at 482 worktrees, coping.
- *Tasks*: one global in-memory table and one whole-file save — fine at tens,
  wrong at hundreds. Sharded on disk (`harness-tasks.el:1566`), not in memory.
- *Clients*: fanout is O(clients × payload) with no resync. The **no-resync
  reconnect is the real client-side problem**, because it loses data rather than
  slowing down — and a client that disconnects and re-reads its transcript makes
  the accept-queue defect worse, since every reconnect is another connect into a
  queue that is already full.
- *Computers*: the design is sound (a computer is a client's MCP server; the
  server keeps no computer of its own — `harness-computers.el:1-40`).
- *Sessions*: **memory** is the wall, not CPU, because `harness-session--load-nodes`
  never evicts. A long-blocking handler is the other one — and the accept queue is
  where a long-blocking handler becomes a client-visible outage.
- *Timers*: Emacs keeps them in a sorted list, so `run-at-time` is linear in the
  live count — 1,454 µs behind 1,000 live timers, measured. The harness holds
  O(sessions) live timers, not one per delta, because every per-session timer
  replaces its predecessor by key and the transient update path creates none. At
  a few hundred live timers an insertion is ~0.3–0.8 ms, paid per timer created —
  a real linear cost and a real reason a heap beats a list, but not the first
  ceiling here.

**"Is the Elisp architecture good or slop?"**
Good — and I went in expecting to find more slop than I did. The three things
that most often indicate a rot in a dynamically-typed modular system all came
back clean: the bus is closed (436 calls, 558 definitions, 5 explainable
exceptions), the layer rule holds in both directions (0 violations across 178
files), and the method set is stable (7 removals in 300 commits). The genuinely
weak parts are narrow and named: the wire protocol has no version, schema or
sequence number; `:requires` orders init only, so 66% of its edges load in
the wrong order and 60 modules' real dependencies are undeclared; the
permission chain's 18 stages are ordered by bare integers in 9 files. Every one
of those is days of work, not a rewrite.

The parts that *look* like slop — 17 k lines of architecture doc, 558 methods,
162 modules — are the cost of a genuinely modular system grown fast by one
person, and the doc is mostly load-bearing (it is where the wire contract, the
trust model and the permission semantics actually live). The thing you most need
— the ability to see the architecture and judge it — already exists in
`docs/modules/` and `lisp/harness-module-docs.el`; it needs to be turned into
assertions, not replaced by another language.

---

## Appendix: what to check first, and what it would prove

If the goal is "I want to see the architecture and know whether it is sound",
these five checks are the whole architecture in about 150 lines of ERT. I ran the
first two against the tree as it stands; the state of each is in the table.

| Check | What it proves | State today |
|---|---|---|
| every `harness-call 'X` has a `harness-defmethod X` | the bus is closed | **passes**, 436 called / 558 defined / 5 allowlisted exceptions |
| every `harness-emit 'E` has a `harness-declare-event E` | events are declared | **already a test**, `harness-module-docs-test.el:384` |
| every top-level `(require 'harness-M)` is in `:requires` | the dependency graph is honest | **fails**: 60 modules, 93 edges undeclared |
| no `lisp/ui/*.el` requires a state module | the layer rule holds | **holds**, 0 of 71 — unenforced |
| no `lisp/modules/*.el` requires a `harness-ui-*` module | the reverse rule holds | **holds**, 0 of 107 — unenforced |

The first and the last three are worth adding, and they are cheap: the scanner
already reads every file and records `:calls`, `:methods`, `:file-requires` and
`:requires` (`harness-module-docs.el:280`, `:379`), so each check is a set
difference over data the tree already computes to generate `docs/modules/`.

The one that will actually change how the code reads to you is the third. Today
a module's `:requires` is documentation, and a quarter of the real edges are
missing from it — which means when you open `harness-tasks.el` and read
`:requires '(store project session agent)`, you are being told the truth about
four dependencies and not told about `priority`, `readonly`, `worktrees` and the
rest. Fix the declarations and the dependency graph becomes readable from the
declarations alone, which is what a module system is for.

That is the honest answer to the motivation behind the rewrite. The architecture
is better than its reputation — the bus is closed, the layers hold, the method
set is stable, and reload is better than most dynamic languages manage. What is
missing is not a different language; it is the checks that let you see that from
the outside without reading 141 k lines.
