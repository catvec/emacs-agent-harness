# Why the harness is slow: a lease that kills quiet commands, and a teardown that blocks the loop (2026-11-17)

**Symptom.** "What is causing such bad performance of the harness right now?"
Long waits in every session, tools that die for no reason, a harness process
that looks busy while nothing gets done.

**Short answer.** Not a compute ceiling and not a threading mistake.  Emacs
runs Lisp on one thread, and the harness already puts that thread in a child
`emacs --batch` (`harness-process`), so the UI stays responsive by design.
What was slow was **work being thrown away and then paid for again**, and **one
blocking call sitting in a timer that runs ten times a second**.

Two defects account for nearly all of it:

1. A 60-second **lease** ended any command that printed nothing for 60 s,
   though a command that prints nothing is the normal case: a `sleep`, a quiet
   build, a clone on a slow link.  **119 of 311 runs in 12.4 hours of this
   harness's own records were killed this way, 1031 minutes of tool work thrown
   away**, and every one had to be re-run from the start.  The killed runs had
   a median life of 419 s against 43 s for the ones that finished: it was the
   long work that got killed.
2. Ending one of those runs happened **inside the 0.1 s poll timer** and waited
   up to 5 s for the supervisor's process, then deleted its scratch directory.
   That blocked the whole harness event loop, every session's work with it.
   The harness's own latency records show **stalls of 2-7.5 s, one of 38 s and
   one of 341 s**, all inside `harness-sandbox-session--poll-runtime`.

A third, smaller defect wrote an error report every few seconds forever: the
latency recorder's flush asked `make-directory` for a directory that already
existed, and every `file-already-exists` signal was reported with a full stack
trace.  **434 reports in 24 minutes** in the reading taken while this document
was finished -- one every 3.3 s -- each a stack trace, in the same process
that was trying to serve sessions.

## What was measured, and how

The harness records its own slow boundaries and event-loop gaps in
`latency-PID.log` in `harness-state-directory` (`lisp/harness-latency.el`), one
file per process, rotated at 256 KiB.  Those files, `error-details.log`,
`jobs-lifecycle.jsonl`, the `*harness-log*` buffer and `/proc/pressure/*` were
read while the harness lagged.  Nothing here is inferred from the code alone.

### It is not a compute ceiling

`/proc/pressure/cpu` read `some avg10=3.13`, `full avg10=0.00`: the CPUs had
work queued for 3% of the time and no task was stalled on CPU at all.  The
load average was 12-27 on 16 cores, and that was **other work** -- a task board
running a dozen sessions, each with sub-agents -- not the harness processes,
which were not on the CPU.  `/proc/pressure/io` was the busy resource
(`some avg10=20`, `full avg10=5.7`): the machine was waiting on disk, from the
test suites and the many sessions, not from a compute limit.

The harness process itself was mostly **idle**: `loop-gap` records show it
sleeping in `accept-process-output` inside `harness-server--event-loop`, which
is what an idle event loop looks like.  A process that is waiting is not a
process that needs more CPU.

### It is not a threading mistake

Emacs Lisp has no shared-memory parallelism for Lisp code; there is one
interpreter thread and cooperative interleaving in the event loop.  The
architecture already accounts for it: the harness runs in a child
`emacs --batch` and the UI talks to it over ACP, so harness work does not
compete with typing and redisplay (see `docs/architecture.md`, "Processes").
The remaining exposure is **blocking calls on that one thread**, and that is
what defect 2 was.

### The lease: runs killed for being quiet

`harness-sandbox-session--lease-seconds` is 60.  The poll ends a run when no
*frame* has arrived for 60 s, on the theory that "silence means the transport
has gone -- a pipe nobody reads, a process the harness lost".  But the
supervisor only writes a frame when a command **prints**:

```
draw() { ... while chunk=$(dd bs=384 count=1 <&9 ...); do say "$1" "$2" "$chunk"; done; }
```

`draw` is the only writer of `O` and `E` frames, and it blocks on the
command's output.  A command that prints nothing for a minute produces no
frame for a minute, so the lease cannot tell it from a dead transport.

`jobs-lifecycle.jsonl`, 122 minutes of this harness's own use:

| How the run ended | Runs | Wall time spent in them |
| :--- | ---: | ---: |
| "its output stopped reaching the harness" | 32 | 168 min |
| finished or exited on its own | 37 | 89 min |

The killed runs had a median life of 253 s; the ones that finished had a
median of 41 s.  So the killed ones were **the long ones** -- builds, test
suites, the work that matters -- and they were killed at the 60 s mark for the
crime of being quiet.

The same file read again at the end of this work covers 12.4 hours
(2026-11-17 21:26 to 2026-11-18 09:47), which is long enough that the
one-hour window above is no longer the best evidence:

| How the run ended | Runs | Wall time spent in them | Median life |
| :--- | ---: | ---: | ---: |
| "its output stopped reaching the harness" | 119 | 1031 min | 419 s |
| finished or exited on its own | 112 | 296 min | 43 s |

**17.2 hours of tool work thrown away in 12.4 hours of wall time**, which
is what a run being killed and paid for again looks like in a log: the
killed runs are ten times the length of the ones that finished.  Three of
the 119 died before 60 s of life (54 s, 3.9 s, 0.7 s) -- the 0.7 s one is
a runtime that never started, not a lease; the other two are runs that
were already quiet when they began, which is the same defect.


It was reproduced against this very session, twice, with nothing else running:

```
$ date +%T; sleep 100          # a command that prints nothing
23:52:33
                               # (killed)
23:53:33  WARN [server] sandbox: 99428517-1x4p35 stopped reporting; ending its 1 command
```

60.0 seconds, exactly the lease.

### The teardown: 2-7.5 s stalls, once 341 s

Ending a runtime is synchronous by design, and for good reason: "this answers
only when the instance is, which is what makes 'stopped' true".  But the poll
called it **from the timer**:

```elisp
(harness-sandbox-session--stop runtime "its output stopped reaching the harness" t)
```

`--stop` sends `quit`, then loops on `accept-process-output` for up to
`harness-sandbox-session--settle` (5 s), then deletes the scratch directory
recursively.  While that runs, the harness's single thread is not serving any
session.

The `loop-gap` records -- the watchdog noticing that a second passed without
its timer running -- name the blocker:

| Loop gaps | Total | Blocked in |
| ---: | ---: | :--- |
| 5 | 223 s | `harness-sandbox-session--stop` <- `harness-sandbox-session--poll-runtime` |
| 2 | 8 s | `harness-acp--read-now` <- `harness-acp--poll-sockets` |
| 61 | 270 s | (Lisp busy; no single frame named) |

The largest were 341.6 s, 38.1 s, 9.2 s, 7.8 s and 7.5 s.  A 341-second gap is
the harness being unable to run a timer for nearly six minutes.  That is what
"bad performance right now" is: not slow code, but a stopped loop.

### The error loop: a stack trace every 3.3 seconds

`error-details.log` held 747 reports for 22:41-23:07 alone, of which **407**
were the same error:

```
Error:   (file-already-exists "File exists" "/home/noah/.emacs.d/.local/cache/harness")
Stack trace:
   0  make-directory-internal ("/home/noah/.emacs.d/.local/cache/harness")
   1  files--ensure-directory ("/home/noah/.emacs.d/.local/cache/harness")
   2  make-directory ("/home/noah/.emacs.d/.local/cache/harness/" t)
   3  harness-latency-flush nil
   4  harness-latency--tick nil
```

`harness-latency-flush` runs once a second, from a timer, and called
`make-directory` on its own state directory every time.  Each signal is
reported by `harness-error-report--around-timer` with a stack trace -- far more
expensive than the write it was trying to do.  This is a loop that costs more
the longer it runs.

Read again while this document was being finished, the log held **434
of these reports in 24 minutes** (09:24:37 to 09:48:51), 185 of them in
the last ten minutes alone -- the loop had not stopped, and it is in the
harness that is serving sessions right now.  The figure above (490 in 26
minutes) was from the first reading; the two agree on the rate, about
18 a minute, or one every 3.3 s, each a full stack trace.

## What changed

### A heartbeat, so silence means what the lease thinks it means

The supervisor now reads its control line with a timeout and says `H` when the
timeout expires:

```sh
while :; do
  IFS= read -r -t "$beat" chunk
  st=$?
  line="$line$chunk"
  if [ "$st" -gt 128 ]; then say H; continue; fi
  ...
```

`H` is a frame of the same pipe, which is the point: it says the pipe still
carries a frame from the supervisor to the harness.  A transport that has gone
carries none, so the lease still ends a run whose supervisor died -- the case it
was written for.  The harness moves `:checked` on any frame, and now also when
a run starts, so a run's first lease window begins at its start rather than at
the runtime's.

The interval is `harness-sandbox-session--heartbeat` (10 s), clamped to a third
of the lease so the two cannot be confused.

The read accumulates across timeouts because a `run` line carries the command's
script in base64 and can exceed `PIPE_BUF`, so it may arrive in pieces; a
timeout in the middle of one must not throw the pieces away.  The control line
is split with `IFS=' ' read -r op a b c <<< "$line"`, which expands nothing in
it.  The first version turned globbing off for the whole program (`set -f`) and
that was wrong in a way worth recording: `alive_of` reads
`/proc/[0-9]*/environ`, and without globbing that is a literal path matching
nothing, so **every survivor count became 0** and the harness could no longer
see a process it had left behind.  Three runs of a `setsid` daemon reported
`X ... 0 0` against the original's `X ... 0 1`; the module's own
`a-cancel-answers-only-when-nothing-is-left` and
`what-a-call-leaves-running-is-the-sharing` tests are what caught it.

### The teardown leaves the loop

`--stop` keeps its promise for the callers that need it (a session ending, a
permission change: these must know the instance is gone).  The poll now calls
`--stop-later`, which marks the runtime ended, sends `quit`, and returns.  The
sentinel finishes the end when the process is gone, and a timer ends a
supervisor that will not go, so nothing waits on the loop.

The runtime **stays the session's** until its process is gone, reading as
`stopped`.  That matters: `harness-sandbox-session-ensure` is documented as the
one admission point, and it waits for a runtime that is being destroyed rather
than starting a second supervisor for the same session.  (The first version of
this change removed the runtime from the hash at once and did start a second
one; three of the module's own tests caught it.)

### The flush stops signalling

`harness-latency-flush` asks for the directory only when it is missing
(`harness-latency--ensure-directory`), and that cannot signal.  The tick no
longer produces an error report for doing nothing.

### A test that compared two board keys across a clock

Not part of the slowness, but the full run found it and it is the same
kind of defect: a test that fails for a reason it does not measure.
`harness-ui-tasks--board-key` carries `(truncate (float-time) 5)` so the
board is drawn again every five seconds, and seven assertions in
`lisp/ui/harness-ui-tasks-test.el` read a key, did something that must
not change it, and read it again.  A five-second boundary between the
two readings changed the key by itself: the full run failed
`card-tooltip-has-the-average-output-rate` with `359002659` against
`359002660`, about one run in five by the arithmetic.  The comparison
now takes the tick out of both readings
(`harness-ui-tasks-test--key-unchanged`), and the `should-not` cases use
it too -- a `should-not` could otherwise pass on a tick, which is a test
that stops checking.  The clock is not frozen: the waits between the
readings run on it.

## Alternatives considered

- **Raise the lease.** It would kill fewer quiet commands, but it makes the
  case it exists for -- a transport that has gone -- take longer to notice, and
  it still cannot tell "quiet" from "dead".  The heartbeat answers the actual
  question.
- **Keep the blocking stop and give the poll its own timer.** The wait is the
  problem, not which timer it runs in; any timer that waits blocks the loop.
- **Delete the scratch directory in a child process.** `rm -rf` would make the
  discard cheaper, but the wait for the supervisor is the larger cost, and a
  child process per teardown is a new thing to supervise.  The sentinel does it
  when the process is already gone.
- **Cache `harness-config--work-dirs`.** It builds a view of every task (6.8 ms
  over this repository's 637 tasks) and is asked per new session.  A
  one-second cache was written and then **reverted**: it served a stale answer
  to `harness-commit-msg--selected-p`, which decides whether to install a git
  hook, and broke that module's own test.  A 6.8 ms saving is not worth a
  correctness decision answered from a cache.
- **Give the harness more threads.** Emacs Lisp has none for Lisp code.  The
  useful concurrency is already there (a separate process for the harness, one
  for each sandbox runtime, one for each MCP worker); what was missing was not
  yielding that one thread.

## What is still slow, and why it is not fixed here

These are real and measured, and each is a larger change than this one:

- **The task table is one in-memory table for every project** (637 tasks, a
  10.6 MB store), loaded whole and written whole.  Fine at this size; it is the
  next ceiling.
- **`session/append` runs the whole commit-attribution chain per node**,
  including `config--work-dirs`, which walks that table.  The GC stack of the
  harness process names it: `harness-tasks--view` <- `harness-method/task/list`
  <- `harness-config--work-dirs` <- `harness-commit-attribution--active-p`.
- **GC is frequent**: about 110 collections a minute in the harness process
  (one every 0.53 s), 307 a minute in the UI during its busy window.  Most are
  under 250 ms; the heap is large enough that each is expensive.
- **The state directory is 9.1 GB**, of which `search.db` is 3.2 GB and
  `sessions/` 3.1 GB.  Disk pressure (`full avg10=5.7`) is the machine's busy
  resource.

## Verification

Each test was checked for teeth by reverting the change it covers and
watching it fail, then restoring it and watching it pass:

| Test | Without the fix | With it |
| :--- | :--- | :--- |
| `a-quiet-command-outlives-the-lease` | fails, 8.4 s (run ended at the lease) | passes |
| `the-poll-does-not-wait-for-a-runtime-to-go` | fails, 12.09 s blocking in one look | passes, 1.2 s |
| `flush-never-asks-for-a-directory-that-is-there` | fails (`make-directory` asked) | passes |

`the-poll-does-not-wait-for-a-runtime-to-go` drives
`harness-sandbox-session--poll-runtime` -- the call the timer makes ten
times a second -- not `--stop-later` on its own.  The first version of it
called `--stop-later` directly and passed with the poll still blocking,
which is exactly the defect; it was rewritten and re-checked against the
reverted poll before being kept.

`a-transport-that-is-gone-is-still-ended` holds the other direction: the
lease still ends a run whose frames have stopped, so the heartbeat cannot
be read as having disabled it.

The whole module suites: `lisp/modules/harness-sandbox-session-test.el`
(23 tests) and `lisp/harness-latency-test.el` (10), both green.  The
supervisor's protocol was also driven directly outside ERT (`R`, `S`,
`H`, `O`, `X`, `P`, `K`, `D`), including a 10.7 KB control line that
arrives in pieces.

The full suite, `scripts/test.sh` with no arguments, on the tree this
document is in: `TEST RESULT: PASS (full, 233 suites, 0 failed)`, 577 s
at load 10-17, and `scripts/test.sh --status` accepts it.

That was the run before the compose repair below.  The two runs after it
each failed one suite, `harness-tools-shell-tramp-test`, and nothing
else: 232 of 233 green, that suite killed at the runner's 900 s timeout.
It is not this change's -- see "A TRAMP suite the full run killed at its
timeout" below, which names the task that owns its fix -- and this branch
does not touch `harness-files.el`, the TRAMP suite, or the code it hangs
in.  The compose suite itself is green at 284 tests.

### The failure the full run found in the compose test, and what it was

`harness-ui-chat-completion-sources` failed in the full run above with
`Timed out after 40s waiting for files fetched`, and passed alone.  It is
not a flake; it is a race in the test's fixture, and it is repaired here.

The test opened the chat buffer and *then* wrote `notes.txt` into the
repository it completes from.  Opening a chat lists the project
(`harness-compose-fetch-completions'), and `harness-files--start-listing'
answers a caller with the listing already in flight for that root rather
than starting a second one.  So when the test asked for a listing while
the open's own was still running, it was handed that one -- a snapshot of
the directory taken before `notes.txt` existed -- and the file it waited
for was not in it.  Traced, with the listing's output delayed by 0.6 s to
stand in for a loaded machine:

```
+1.595s START listing  notes-exists=nil   <- the box's listing, as it opened
+1.623s JOIN  listing                     <- the test's fetch, after the write
+2.200s -> nil                            <- a snapshot from before the file
```

The window is one `git ls-files` subprocess: about 2 ms on an idle
machine, which is why the test passed alone and in every earlier run, and
long enough under load to outlive the write.  Waiting for "some files"
did not save it, because the listing that answered was a real one.

The file is written before the buffer is opened now, and the wait names
the file it wants (`notes.txt to be listed`) rather than settling for a
non-empty answer -- an empty listing is a legitimate answer, so
`(lambda () harness-compose--files)` could not tell "arrived" from
"arrived empty".  A new test,
`harness-ui-chat-a-listing-in-flight-is-a-snapshot`, pins both halves: the
file made first is in what the open listed, and a file made while a
listing is in flight is not in the snapshot that answers a later fetch.
It was checked for teeth by making its claim false, which failed it.

The same shape in `harness-ui-tasks-compose-is-the-chat-box` was checked
and is sound: it writes its file before it makes the board.

### A TRAMP suite the full run killed at its timeout, owned by another task

The full run after the compose repair failed
`lisp/modules/harness-tools-shell-tramp-test.el` with exit 124 -- killed at
the runner's 900 s timeout, not a failed assertion.  Its first test passed
in 1.2 s; the second, `harness-tramp-tools-run-on-remote-cwd`, never
finished.  Either test passes alone; together the second one hangs, which
is why the timings file has this suite recorded at 804 s.

SIGUSR2 on the stuck Emacs named the call:

```
harness-call(session/create :cwd "/mock::/tmp/harness-tmp-.../")
  harness-method/project/root
    harness-files-project-root
      project-current -> project-try-vc -> locate-dominating-file
        directory-files "/mock:marcuse:/tmp/"
```

`harness-files-project-root' asked `project-current' about every directory,
and on a remote one that walks the host's tree for a project marker.  The
first test leaves a TRAMP connection open, so the walk blocks with no
timeout; this machine's `/tmp` holds 124,746 entries, which is the other
half of why it never came back.

**This repair is not mine to make: another live task already owns it.**
`task/provider-readiness-assessment-and-jibzilj2` fixes exactly this at
`34cbf91` ("Fix the remote project lookup that hung a session after any
remote command"), with the same diagnosis and a regression of its own; the
fix returns a remote directory as its own root instead of probing it.  That
commit is on that task's branch and not on `main`, which is why this tree
still has the defect.  Checked here rather than assumed: with `34cbf91`'s
`lisp/harness-files.el` in place both tests pass in 2.1 s where the second
had hung for 900 s.  It is left to that task to merge; this branch does not
carry a second copy of the same change.

### Three other tests the full run made fail, and what each was

A full run before that one failed on four different suites across three
attempts -- `harness-acp-test`, `harness-merge-test`,
`harness-sandbox-session-test`, `harness-core-test` -- never the same
pair twice, which is what load looks like rather than a defect.  Each
was run down before being called a flake:

- **`a-cancel-answers-only-when-nothing-is-left`** (mine to answer for:
  it is the sandbox suite) failed twice, reading a survivor count of 0
  and of 2 where it wants at least 3.  It is a real race and it is now
  fixed: the test grepped `/proc/*/environ` for the run's token as soon
  as the supervisor had *accepted* the run, and accepting it says `S` as
  the processes are started -- the `setsid` child has to be forked and
  exec'd before it carries the token.  The count is waited for now.  It
  passed six times in isolation before that fix and still failed in a
  full run, which is why the fix is a wait and not a retry.
- **`harness-merge-hand-in-waits-for-merges-into-the-session`** and
  **`fresh-resolver-timeout-answers-its-call`** timed out at 80 s and
  160 s -- `harness-test-wait`'s bound scaled up by a load of 26.  Both
  pass at that commit when run again.
- **`change-review-ui-diff-view-acts-on-the-thread-under-the-line`** is
  a vendored library's own test (`lisp/vendor/change-review`), which
  this change does not touch at all.  It failed once in 173 and passed
  six whole-file runs, eight bare-Emacs runs, and six more under eight
  CPU burners.  It is not repaired here: it is not this change's, and
  guessing at it would be worse than reporting it.  The full run above
  passed with it.

One thing the tests caught in the *test* rather than the code, worth
recording because it cost more time than the fix did: the ownership
test's frame reader skipped heartbeats by searching the buffer for
`^[^\n]*$` from `point-min`.  That regexp matches the empty string at
`point-max`, where `re-search-forward` succeeds without moving point, so
the loop never ended -- and because the predicate was spinning inside
`harness-test-wait`, `accept-process-output` was never reached and the
buffer never filled.  The test burned 99% CPU for minutes and reported
nothing.  It reads lines now (`split-string` and `cl-find-if`), which
cannot loop.  A test helper that can spin without yielding is worse than
a failing test: it reads as a hang in the code under test.

The live reproduction above, run again after the fix with the module's
own supervisor driven from a scratch Emacs (not ERT) and the real lease
in force:

```
supervisor up: "R 1"
run accepted: "S run-livequiet"
after 75.1s (lease 60s): 7 heartbeat frames; X frame yet: nil
finished: "X run-livequiet 0 0"
output frame: "O run-livequiet cXVpZXQtZmluaXNoZWQK"   ; "quiet-finished"
total 91.0s
```

A `sleep 90` that prints nothing for its whole life -- 30 s past the
lease -- with the heartbeat frames arriving every 10 s and the command
ending on its own with status 0.  Before the change the same command was
ended at 60.0 s; that was reproduced twice against this session and is
recorded in the section on the lease.
