# Incremental lifecycle consolidation and valid ACP fuzzing

Source commit `49f17e9` extracts shared completion/cancellation mechanics.
The compatibility baseline is `14780d1`, before that extraction. Neither
revision uses a new scheduler or changes retry/deadline policy in this pass.

`baseline-summaries.sexp` and `consolidated-summaries.sexp` are the results of
32 identical deterministic 16-action ACP scripts against those two source
revisions. Both processes exited 0; `cmp` exited 0. The summaries include
method/reply counts, turn starts/ends, tool effects, scripted provider plans
and actual prompt reply IDs/stop reasons, including cancellation and errors.
Each run also requires successful prompts after a real store flush and reload.
This compares those observables, not timestamps, random session IDs or every
notification byte, and is not a proof of equivalence for arbitrary programs.

`compare-conversations.el` reproduces the comparison with the *new* ACP fixture
against either checkout's real modules. From the new checkout, for example:

```sh
HARNESS_COMPARE_ROOT=/path/to/baseline TMPDIR=/var/tmp \
  emacs -Q --batch -L /path/to/baseline/lisp -L /path/to/baseline/lisp/modules \
  -L .harness/plugins/fuzz \
  -l docs/evidence/lifecycle-consolidation/compare-conversations.el > baseline.sexp

HARNESS_COMPARE_ROOT="$PWD" TMPDIR=/var/tmp \
  emacs -Q --batch -L lisp -L lisp/modules -L .harness/plugins/fuzz \
  -l docs/evidence/lifecycle-consolidation/compare-conversations.el > current.sexp

cmp baseline.sexp current.sexp
```

The three `afl-SEED.txt` reports retain a 180-second campaign per seed,
2,000-execution ceiling, using stock Emacs and AFL++ non-instrumented mode.
They completed 238, 239 and 239 executions (716 total) with no crashes,
invariant failures or hangs. An earlier 60-second development campaign ran
92 conversations without findings. The extended runs used committed source
`49f17e9`; `manifest.json` records the parameters and revision.

For one bounded 60-second campaign:

```sh
TMPDIR=/var/tmp .harness/plugins/fuzz/run.sh acp-conversation 60 42
```

`extended-campaign.el` is the exact runner for the longer campaigns. Set
`HARNESS_ACP_SEED` and `HARNESS_ACP_REPORT` (a directory for its reports), then
run it with `-L lisp -L lisp/modules -L .harness/plugins/fuzz`. Its explicit
180-second setting overrides the normal tool-call duration ceiling; reports
and raw AFL work directories are retained. Exit 1 means findings.

These are valid **standard ACP** command conversations through real codecs,
dispatch, state, agent and pure tools. `_harness/` extensions and external
providers are outside this grammar. The bytecode decoder limits each mutated
program to 32 actions; every program also performs setup and cold recovery.
Logical inconsistencies signal an error (adapter exit 42), so AFL can save
them without an Emacs segfault. The oracle's own tests deliberately corrupt
RPC delivery and verify rejection; they also require the tool path to execute.
Finite campaigns do not establish coverage saturation or correctness.
