# Every failure is work to do

## What was wrong

Two things, and they are the same thing at two levels.

**The workflow let a failure be dismissed.** `harness_client/tool/check_build.sh`
ran the app's tests twice: once for the branch, once at the base, and then
said *"all N failing tests already fail at BASE; this branch adds none"* and
**passed**. `scripts/test.sh` exited nonzero but its output carried no rule
about what to do. `docs/dev-loop.md` called a base failure "somebody else's
breakage... held against nobody", and `CLAUDE.md` said to "fix the failure
when appropriate". Every one of those is a discretionary out. A red `main`
became a licence for every branch to go in red on top of it.

**The failures themselves were real and unrepaired.** On `main` at `322e52c`,
`flutter test` reported:

```
2005 tests: 1968 passed, 21 failed, 16 skipped
```

and `check_build.sh` passed, because all 21 also failed at the base. They were
not one flake. They were four defects:

1. **`HarnessScopeBar` overflowed by 26 px** (`layout_widgets.dart:387`), which
   failed **15 tests** across `layout_test`, `new_task_images_test`,
   `quota_widget_test`, `reconnect_widget_test` and `widget_flows_test`. The
   scope `Row` sat inside `Expanded`, with the trailing `SpendChip` unbounded
   after it: a long project name plus a plan chip is wider than a 390-point
   phone.
2. **Two tests asserted stale money.** `formatMoney` writes cents (`$50.00`),
   the tests still said `$50.0`.
3. **A settings heading was read after it scrolled out of the lazy list.**
   `desktop_looks_test` reached the Look row, which scrolled `Appearance` past
   the built range, then asserted it was on stage.
4. **Reduced motion was not honoured.** `workspace_screenshots_test` asserted
   `transientCallbackCount == 0` and got 2: `_EntryReveal` ran its 280 ms
   controller and three `AnimatedContainer`s animated, all under
   `disableAnimations: true`.

## What the change decides

**A failing test fails the check, full stop.** `check_build.sh` still runs the
base's tests, but only to *diagnose*: it prints how many failures this branch
brought and how many it found, and then fails either way. There is no waiver,
and no `known_test_failures` count in the stamp, because a count of excused
failures has no meaning once nothing is excused.

**The rule travels with the failure.** A person who reads a failing run must
not have to have read a document first, so the output says it:

- `scripts/test.sh` prints a `TEST FAILURES: investigate and repair EVERY one
  of them` block on a failing run, names the suites to repair, and exits
  nonzero. `--status` says the same while still refusing the run.
- `harness_client/tool/check_build.sh` prints the same block on a failing test
  step, whether the failures are new or were already at the base.
- `report_flutter_tests.py` ends a failing report with it. Its `--failures`
  output stays a bare list of names, because `check_build.sh` compares that.
- A **passing** run prints none of it: green output stays a plain report of
  what passed. Tests pin both directions.

**The written rules lose their discretion.** `CLAUDE.md`, `docs/dev-loop.md`
and the `client-check` plugin's refusal text now say every failure is to be
investigated and repaired, that a base failure is still a failure, and that
skipping, deleting, weakening or relabelling a test is not a repair. A repair
another live task owns is coordinated by naming that task and its evidence,
not by leaving the failure in place.

## The 21 failures

- **Scope bar:** each half of the line is now `Flexible` inside a
  `spaceBetween` row, so the name and the chip give way within their own share
  instead of pushing each other off the edge. The name keeps the larger share.
- **Money:** the two assertions and the `QuotaExtra.describe` docstring now say
  `$50.00` / `$20.00`, which is what `formatMoney` has always written.
- **Settings:** a `_showSection` helper scrolls the heading back before it is
  read, and the test asserts the sentence-case name is there and the upper-case
  one is not.
- **Reduced motion:** `HarnessMotion` in `harness_theme.dart` is one answer to
  `disableAnimations` -- `of(context, duration)` for implicit animations,
  `allowed(context)` for a decision, `repeatIfAllowed` for a repeating
  controller. `_EntryReveal` starts its controller only when motion is allowed,
  the thread tile, concept tag and composer button take their duration from
  `HarnessMotion.of`, and the test asserts every `AnimatedContainer` and
  `AnimatedSwitcher` in the surface has `Duration.zero` and that nothing is
  still asking for frames 600 ms later.

Two session-row tests were also reconciled with the fixture rather than
weakened: `s2` bills `$0.12+Max` (extra usage past the plan's window), so four
rows say who pays, not three.

## What did not change

The copy inventory: no user-visible string changed except two money
assertions and the `QuotaExtra.describe` docstring, which are not UI text. No
test was skipped, deleted or loosened; the two money assertions are *stricter*
than the code's old docstring. Exit codes stay nonzero on every failing path.

## Verification

- `flutter test` -- **2005 tests: 1989 passed, 0 failed, 16 skipped**, exit 0
  (was 1968/21/16, exit 1).
- `flutter analyze` -- no issues.
- `python3 harness_client/tool/test_check_build.py` -- 42 tests, OK, including
  the new report-directive and base-failure-fails tests.
- `scripts/test.sh test/harness-test-runner-test.el` -- 8 tests, including the
  new runner-directive test.
- `scripts/test.sh` (full, committed tree) -- **224 files, 0 failed**,
  exit 0; `scripts/test.sh --status` reports PASS (full, 224 suites) on the
  final commit of this change.
- `scripts/lint.sh` -- exit 0 (the base's warnings only).
- `harness_client/tool/check_build.sh` on `c643bf9` -- **PASSED**: pub get,
  analyze, 2005 tests with none failing, the release APK, and both tool
  tests, including the base-failure one.

The numbers above were taken on the branch as it stood. The branch was then
25 commits behind `main`, which had gone on changing the same files, so the
last verification was taken again on the **merged tree** -- `main` at
`7461153` with this branch merged into it -- because that is the tree the
merge queue puts on `main`, and a test that passes on the branch alone says
nothing about it. Taken on the final merge commit `1daed5c`:

- `scripts/test.sh` (full, merged tree) -- **230 files, 0 failed**, exit 0,
  `TEST RESULT: PASS (full run)`.
- `harness_client/tool/check_build.sh` (merged tree) -- **PASSED** in 649 s
  for `1daed5c`: pub get, analyze, `2114 tests: 2098 passed, 0 failed,
  16 skipped`, the release APK, and all three tool tests.

The app gained 109 tests and Emacs gained 6 suites between the branch point
and `main`, and the repair still holds on all of them. On the branch itself
the last full run is **224 files, 0 failed**, exit 0, with
`scripts/test.sh --status` exit 0 on the same commit.

A third defect the rule found: two suites picked their test port by
hashing the time and the pid, so two suites of one full run could pick the
same port and one test's server would answer another's call. The jobs suite
now binds a port and asks the kernel which one it got.

## A second defect the rule found

Following the rule -- no failure is a flake -- turned up a real one behind
two suites that failed only in a loaded full run.
`harness-provider-check-total-timeout-stops-a-job` set
`harness-provider-check-total-timeout` to 1 with `setq` and never restored
it, so every later test in that Emacs ran its check jobs under a one-second
whole-run budget: they were cancelled with the checks they had not reached,
and a check that never ran read as a nil result. It is let-bound now. The
test helper also fails loudly when a job settles with fewer results than
its plan, instead of handing the tests a partial list, and
`harness-test-wait` scales its bound by `HARNESS_TEST_JOBS` (which
`scripts/test.sh` now exports), so a fixed ten-second wait is not a failing
test when four suites share the machine.

## A fourth defect the rule found

`harness-ui-access-hidden-pages-follow-the-session-when-shown` failed in one
full run and passed alone. It is not a flake. A view that a window shows arms
a refresh timer when a change arrives; the page can be hidden again before the
timer fires, and the timer's callback drew it anyway, so a page nothing showed
followed a change it was meant to miss. On an idle machine the timer fires
before the page is hidden, or its fetch comes back after the test has read the
row, so the failure is invisible; in a loaded full run both happen and the
hidden row reads the new setting. The callback now asks
`harness-ui-view-follow-p' again, and marks the page stale when no window
shows it, as the hidden path always did. Its regression test,
`harness-ui-access-a-refresh-armed-while-shown-does-not-draw-a-hidden-page',
arms the timer, hides the page and waits for the timer and its fetch to come
back: it fails on the old code and passes on the new.

## A fifth defect the rule found

Three suites failed in a full run on a machine at load 22 with 16 cores,
and passed alone. Two of them waited on a promise with
`harness-test-await', the one wait helper that still took a fixed bound:
`harness-test-wait' scales its bound by `HARNESS_TEST_JOBS' and the await
did not, so a 30-second bound meant for an idle machine was a failing test
when four suites shared a saturated CPU. It scales the same way now.

The third, `harness-jobs-a-server-started-in-one-call-is-used-in-later-ones',
read the stopped job's server in the instant the stop returned. The job's
record says stopped as soon as the stop is asked for, and the kernel ends
its run a moment later, so the read is now a bounded wait for the server to
stop answering rather than an assertion about the same instant.

## A sixth defect the rule found

Two timestamp tests failed in a full run that began before midnight and
finished after it, and pass at every other hour.
`harness-chat--time-label' names the day of a time that is not today, and
`harness-chat--time-clock' is the clock alone. The pinned line under the
header is drawn from the clock, and the tests read a time half an hour
before now: after midnight that time is yesterday's, so the line read
`23:41' where the label said `Nov 14 23:41'. The comparisons of the line
against the label are against the clock now, as the repair of the earlier
timestamp flake did for the others, and the times the tests use are asked
for as `harness-ui-chat-test--earlier-today', which stays on this day
whatever the hour. Run at 00:27, the two tests fail on the old code and
pass on the new.

## A seventh defect the rule found

`harness-tasks-git-merge-queue-column' timed out after 120 seconds in a
full run at load 21 and passes in a second alone.
`harness-tasks-test-wait-state' waited 30 seconds, which
`harness-test-wait' scaled to 120 for a four-suite run -- exactly the
timeout of one git command, as `harness-run-command' takes 120 seconds.
A merge runs several git commands in turn, so a single slow one used the
test's whole budget and the test reported a timeout of its own where the
command's timeout was the thing to see. The bound is a minute now, well
above one command, so the command's own timeout is what a failure reads.

## An eighth defect the rule found

`harness-ui-pet-board-recaps-its-tasks' and
`harness-commit-attribution-prompt-sync-uploads-the-redacted-prompt' timed
out in a full run at load 21 to 25 with 16 CPUs, and pass alone. Both wait
on a server another process starts, and both waited on
`harness-test-wait-scale', which counted the run's own suites and nothing
else: four suites' worth of time is not four when the machine has three
other Emacs processes at 80% of its CPU. The scale is the job count times
the machine's load per CPU now, so a wait competes with what the run puts
on the machine and what is there already. At load 21 on 16 CPUs that is
two, and a ten-second bound becomes eighty seconds rather than forty.

## A ninth defect the rule found

A fresh full run of the tree that already carried the eight repairs failed
one suite, `harness-codex-quota-test.el`, and it did not fail the same way
twice: `harness-codex-quota-protocol-failures-are-sanitized` expects a
`error` status and sometimes got `missing`. Reproduced outside ERT, a fake
CLI whose body is `exit 5` answered `missing` three times in forty.

`missing` is the status the one consumer of it explains as *"Codex CLI is
not available; install it and run `codex login'"*
(`harness-provider-responses.el:1647`). `harness-codex-quota-read' wrapped
both `make-process` and the send of the first request in a single
`condition-case`, and answered `missing` for either. The two cases are not
the same thing: `make-process` signals `file-missing` when the program is
not installed, but a CLI that *starts* and then exits before it reads
anything makes `process-send-string` signal `Process ... not running:
exited abnormally with code 5`. So a broken installation was reported as an
absent one, and the person was told to install what they already had.

It is a race because the send only fails in the window between the CLI
dying and its sentinel running; when the sentinel runs first the status is
already `error`. A slow machine opens that window wide, which is why the
test failed in a full run and passed alone.

`missing` is now what `make-process` alone refuses to start. A send that
fails is `error`, as a process that dies mid-conversation already was. The
regression test,
`harness-codex-quota-a-cli-that-dies-is-not-missing', reproduces the window
deterministically -- the process is let die while its sentinel is still
queued -- and fails on the unfixed code.

## A tenth defect the rule found

The rule has a second half -- the passing path must stay truthful -- and
this change broke it. `scripts/test.sh --status` printed the repair
directive whenever the record was not verified, and a pass on a commit that
is no longer HEAD is not verified. So a run that failed *nothing* told the
reader to "investigate and repair EVERY one of them" and sent them through
the logs of a green run, naming failures that were not there.

The directive names work to do, so it is printed only when the run it
reports on failed. A stale pass says what it actually needs, which is the
run again. The exit status is unchanged: the record still refuses to verify
a tree it did not test. The regression test,
`harness-test-runner-a-stale-pass-names-no-failures', takes a passing run,
commits after it, and holds `--status` to refusing the tree without naming a
failure; it fails on the old output.


