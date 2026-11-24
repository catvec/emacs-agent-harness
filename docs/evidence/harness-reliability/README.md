# Harness reliability evidence

[Investigation and repair](../../analysis/harness-reliability-2026-11-24.md).

## Repeat the historical reproductions

Keep this directory outside the checkout being bisected. Its script loads the
historical checkout's modules and helpers. All session state is temporary; no
live session store is read or rewritten.

```sh
# From a disposable clone, with EVIDENCE pointing to this directory:
git bisect start ac3fb53 b444511
git bisect run bash "$EVIDENCE/bisect.sh" hydration
git bisect log
git bisect reset

git bisect start c546c72 b444511
git bisect run bash "$EVIDENCE/bisect.sh" routing
git bisect log
git bisect reset
```

The restart reproduction persists a frozen request using the actual replay
method when that feature exists, then loads the canonical session again. Before
the frozen-body feature exists there is no new sidecar to corrupt hydration.

The routing reproduction intercepts transport admission without a network
request, lets the durable marker be written, and rejects the terminal setter.
Before durable tracking exists there is no marker to strand. On failing revisions
the callback signals `terminal save failed`; on the repair it delivers `done`
and allows an audited same-pin retry. Revisions with unrelated dependency/API
failures are skipped (exit 125), not counted as failures of this reproduction.

The raw logs name the original temporary scripts used in the searches;
`bisect.sh` and the two `.el` files preserve those reproductions for reruns.

## Validation

The focused run passed 357 tests across seven suites (agent, lifecycle,
OpenRouter health and policy, hydration, resilience and retry), exit 0.
The separate server regression passed outside the restricted sandbox, exit 0.
`scripts/lint.sh` completed with exit 0 and warnings.

The expanded final fault checks cover eleven lifecycle tests and 24 routing health
tests. Use the full runner for final verification on the committed tree:

```sh
TMPDIR=/var/tmp scripts/test.sh
scripts/test.sh --status
```

The full runner records all suite logs in `scripts/.dev/test-logs/` and its
commit, worktree state and result in `scripts/.dev/test-stamp.json`. The status
command refuses a selected run, a dirty tree, an older commit or any failure.

`revision-checks.txt` records direct checks of the known-good base, offending
commits, their parents, the hydration repair, the original HEAD, and the repaired
working tree. Every exit status matched the expected result.

The initial lifecycle fault-injection suite was also run against original HEAD;
all eleven tests fail there (`lifecycle-original-summary.txt`). The repaired
suite passes all eleven. `pause-project-repro.el` runs the pause-all fixture
under an explicit parent project; it fails before fixture isolation and passes
after it. The Git signing regression requires no signing key: its injected
signing program always refuses, and a successful fixture commit proves the
fixture did not try to use it.
