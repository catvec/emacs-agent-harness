# Provider AFL and terminal-lifecycle evidence

The first campaign used AFL++ in non-instrumented mode, seed `20261124`,
10,000 executions or 60 seconds per target, four concurrent targets. All
inputs were local fixtures. No live model or user session was used.

- `initial-campaign.txt`: 3,238 executions across ten targets; one logical
  MCP round-trip failure. The source was the working tree based on `0bff057`
  before duplicate-member rejection, with the raw-SSE work in progress.
- `mcp-line-original.json`: exact bytes saved by AFL at execution 92 of that
  target, without its generated filename or a JSON re-encoding.
- `mcp-line-reduced.json`: manually reduced reproduction. The initial
  campaign did not complete a successful `afl-tmin` minimization within its
  budget; this file is not attributed to the minimizer.
- `mcp-identity-repro.el` and `mcp-revision-checks.txt`: direct checks of the
  original ID disagreement and the repaired parser's handled refusal.
- `final-campaign.txt`: final full mutation campaign against source commit
  `c513531`, using the checked-in runner, seed `20261126`, eleven targets,
  60 seconds per target and at most 10,000 executions each.
- `baseline-test-summary.txt`: five new checks fail at `0bff057`; the sixth
  consumer-redelivery check already passed.
- `sse-terminal-repro.el`: portable test of terminal delivery for a non-string
  error message, independent of timers, network calls and the new fuzz target.
- `sse-bisect.log` and `sse-bisect-output.txt`: full search identifying
  `4c2023c` as the first revision to lose terminal delivery for that payload.
- `sse-revision-checks.txt`: direct parent/child, two-week-window start,
  previous repair HEAD and fixed-source checks. A parent that emits a malformed
  error event counts as good only for this missing-delivery reproduction.
- `verdict-rejection-repro.el` and `verdict-revision-checks.txt`: the first
  full integration run exposed a regression introduced by the stricter reader:
  discarded rejection evidence could turn a conflicting reply into permission.
  The repaired verdict reader retains that conflict, with the existing specific
  diagnostic. This follow-up is not attributed to the original harness or AFL.

Run a campaign from the checkout:

```sh
TMPDIR=/var/tmp .harness/plugins/fuzz/run.sh all 60 20261126
```

It prints the artifact directory and saves `report.el`, including the original
bytes of each finding. The report also names the retained AFL work directory.
Exit 0 means no findings, 1 means findings, and 2 means a campaign failure.
The final full ERT suite additionally runs both short AFL integration tests
when AFL++ is installed.

Replay the historical missing-terminal failure in an isolated checkout:

```sh
# Copy sse-terminal-repro.el outside the checkout before changing revisions.
emacs -Q --batch -L lisp -L lisp/modules -l /absolute/path/sse-terminal-repro.el
```

At `4c2023c^` it prints one terminal event and exits 0. At `4c2023c`,
`b444511` and `0bff057` it prints `finished=t terminal-count=0` and exits 1.
The repaired source prints one protocol-error ending and exits 0.

Replay the MCP finding in Emacs with the fuzz plugin loaded:

```elisp
(harness-fuzz-replay
 'mcp-line
 :input "\"{\\\"id\\\":2,\\\"id\\\":1,\\\"method\\\":\\\"ping\\\"}\"")
```

The original parser exposes both IDs, while its encoder preserves only the
last. The repaired shared JSON reader rejects the ambiguous object; the target
accepts that handled refusal. Its regression also covers nested duplicates and
equivalent escaped member names, plus valid arrays beginning with JSON false.

The campaign counts are finite exploration, not proof of correctness or code
coverage. See the systemic analysis in
[the reliability investigation](../../analysis/harness-reliability-2026-11-24.md).
