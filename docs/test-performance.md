# Test performance

`scripts/test.sh` runs each ERT file in its own Emacs, with at most four
suites at a time by default. `HARNESS_TEST_JOBS` changes that limit.
The runner starts suites with the longest recorded times first. A full
suite run updates its timing without losing other suites' timings; an ERT
selector does not overwrite the estimate for the whole suite. Set
`HARNESS_TEST_TIMINGS` to move the cache.

The common fixtures in `test/harness-test-helpers.el` keep each test's
state directory separate while reusing byte-compiled modules within a
suite. Server tests can share the UI and child-process compilation caches
separately. The harness loader still checks the source and core files for
freshness; the caches are removed with the suite's temporary state.

For new tests, prefer observable events over sleeps:

- `harness-test-with-clock` and `harness-test-clock-fire` advance a test
  clock and fire an actual scheduled timer, while asynchronous waits retain
  real deadlines.
- `harness-test-fire-debounce` fires a scheduled debounce. For a negative
  assertion, check that no relevant timer is scheduled instead of sleeping
  to see whether one fires.
- `harness-test-with-held-demo` holds a matching demo-provider response until
  the test releases it. This makes the order of concurrent work explicit.
- `harness-test-with-command-watchdog` captures a real command watchdog so
  a test can fire it after the child is ready. Tests of process termination
  still launch a process and verify its result and cleanup.
- The HTTP fixture's `:pause-after` sends a specified number of chunks and
  holds the connection open, letting download-cancellation tests wait for
  actual received data without a timed stream.
- `harness-test-mark-project` provides a project-discovery marker without
  launching Git. It is not a Git repository; tests of Git or worktrees need
  a real repository.

## Measurements and remaining work

On the same machine, a four-worker run of 156 files and 5,228 tests took
326 seconds after the first compilation-cache change, 226 seconds after the
first timer-fixture changes, and 223 seconds in the latest run. These are
wall-clock observations under different system loads, not a controlled
benchmark. The latest run had one supervisor test timeout, which contributes
15 seconds. The count of tests taking at least one second fell from 131 in
the 226-second run to 116 in the latest run. A one-second limit is a goal
for finding work, not a hard assertion: process startup and contention can
vary with the machine.

The latest run's supervisor suite timed out waiting for a plan to be
recorded. Its first suite rerun timed out in a different test with the same
symptom; a subsequent suite run and eight sequential runs of the two affected
tests passed. A later full run found that a supervisor approval fixture could
inherit a parent project's settings from `/tmp`, disabling supervision. The
supervisor session fixtures now mark their own temporary projects; a regression
test verifies that they ignore a parent project's supervisor setting. This is
a plausible cause of the earlier timeouts, but their logs do not establish it.
The wait helper prints the plan, requests, live work and session nodes on a
future timeout to aid diagnosis.

The longest remaining cases include the standalone vendored-library suites,
real server restarts, TRAMP, process-tree termination, and exhaustive QR and
pet rendering checks. Some exercise the process or integration itself;
others may have further avoidable work. Keep that coverage when speeding them
up. A trial changing the common wait poll from 20 ms to 5 ms made little
difference to a representative suite, so the default remains 20 ms.
