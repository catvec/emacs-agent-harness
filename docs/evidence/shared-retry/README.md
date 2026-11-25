# Shared retry and cache-prefix evidence

This investigation is isolated: all sessions, pins and transcripts here are
fixtures under temporary state. No provider was called and no running user
session was restarted or edited.

The five admission ownership tests fail before the core migration. The two
OpenRouter cancellation tests fail before the adapter migration. The unsent-turn
and unsent-oneoff tests are run from the current test file against the unchanged
`fa19846` worktree (its own `harness-test-helpers` and production modules).
The turn uses nine failed admissions instead of the configured first attempt
plus two retries; the one-off caller never settles within its test bound.
They pass with the repair. New assertions exercise independent logical budgets,
elapsed time before the first send, terminal accounting failure, reload, and
cancellation after protocol completion.

The shared rate-limit target is also checked against `fa19846`. Load that
checkout's helpers/core on the load path, load this checkout's
`harness-fuzz-session.el` and `harness-fuzz-limits.el` with a no-op
`harness-fuzz-define-target`, then call:

```elisp
(harness-fuzz-limits--check
 (unibyte-string 1 1 0 0 2 1 0 1 0 2 0 3 0 4 0 5 8 0 2 4))
```

It rejects the old code's total send/admission attempt count. The same grammar
passes the repaired core; this is a full older core/helper comparison with the
new fixture, not a claim that AFL happened to discover the original seed.
The history introducing counted sends (November 11–12) and admission waiting
(November 13) was inspected; no new first-bad bisect is claimed in this pass.

The development 60-second campaigns ran 66 shared-limit inputs (seed 20261127)
and 19 prefix inputs (20261128) without findings. Later combining the prefix
oracle with failed/cancelled turns exposed an overly strict assumption: a
serializer may coalesce another user node into the final user message while
retaining its old content. That run (seed 20261129) reported 14 findings. Its
report is retained, not relabelled as a pass. An append-only extension rule and
a regression distinguish that case from replacing old content or reordering
its keys. Every saved finding is replayed after the correction; confirmation
campaign artifacts are kept separately. Stock Emacs uses AFL dumb mode;
execution counts do not establish coverage saturation.

The prefix oracle reads original JSON value slices independently of the replay
implementation. Byte changes in old values are rejected even if they decode to
equivalent JSON; legal appended content remains possible. It covers routine
settings/state changes, tools and cold session loads, plus retry/recovery in the
shared-limit target. Explicit prompt/model/schema changes remain deliberate
cache reset/recovery cases in the older `session-soak` target. TTL, provider
cache eviction and internal prompt handling are outside this client oracle.

Target commands:

```sh
TMPDIR=/var/tmp .harness/plugins/fuzz/run.sh cache-prefix 60 42
TMPDIR=/var/tmp .harness/plugins/fuzz/run.sh shared-rate-limits 60 42
```

The final full suite is run on the clean committed tree. Its structured stamp is
in `scripts/.dev/test-stamp.json`; `scripts/test.sh --status` validates that it
matches HEAD and includes every suite. Lint and focused checks are separate.

Confirmation: all 14 saved append-only findings replay successfully after the
oracle correction (`append-findings-replayed.txt`). The combined rate-limit /
prefix target then ran 69 inputs with seed 20261130 and no findings. The separate
prefix target ran 19 inputs with seed 20261128 and no findings. Their confirmation
reports are retained. Subsequent focused checks cover the final single-owner
terminal accounting path; full-suite verification exercises the committed code,
including the built-in AFL integration campaign.
