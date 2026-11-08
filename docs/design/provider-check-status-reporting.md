# Provider self-test: honest skips and the transcript round trip

## What was wrong

A live self-test report showed:

```
SKIP  Transcript round trip
      Nothing could be rendered: Wrong type argument: stringp, ((:type "thinking" ...) (:type "tool_use" ...))
```

The check had raised an exception while doing its own work, and had caught
it into `(skip . "Nothing could be rendered: ...")`.  Two defects met in
that line.

- The transcript the check built was not a transcript the harness writes.
  It appended one `assistant` node whose `:content` was a list of provider
  blocks (`thinking` and `tool_use`).  The harness stores an assistant
  message as text in `:content` and stores thinking, a tool call and a tool
  result as nodes of their own kinds; `session/messages` renders an
  assistant node's `:content` as text, so the check was asking the renderer
  to render a shape no session ever contains.  The exception was the
  renderer rejecting that shape, not a provider problem.
- The check caught every error into a SKIP.  A SKIP means *unverified*: a
  check that could not measure its claim.  Here the check had run and had
  found out something exact -- the harness could not render the transcript
  it was handed -- and reported it as if the check had not run at all.  The
  check could therefore never fail, which is the opposite of what a
  self-test is for.

The same report showed two cache checks as SKIP with details such as
`repeats 0/2 cached ... repeated misses in one run; not unsupported` and
`independent prefixes 0/4 cached ... primed prefixes missed in one run;
not unsupported`.  Those were not exceptions: every probe had run,
telemetry was present, controls were cold and no request failed.  But a
reader could not tell a measurement of misses from a check that never ran,
because both were printed SKIP.

## The status rule

The report keeps its three statuses; the change is what each one means.

- **PASS** -- the check ran and the behavior it tests held.
- **FAIL** -- the check ran and the behavior it tests did not hold, or the
  check's own work (rendering, recording, classification) errored.  A check
  that fails its own subject is exactly what the self-test exists to show.
- **SKIP** -- the check could not measure the claim: an optional feature is
  not advertised, telemetry is missing, there are too few samples, a
  control is warm, a dependency is unavailable, the account is out of quota
  or money, the provider rate-limited or could not be reached, or the
  request budget ran out.

For the cache experiments the capability record is a separate judgement.
One complete run of misses is a FAIL of that check -- the check ran, and
the reuse it measures did not happen -- while the record still calls one
run `unverified` and needs a second independent run before it calls the
capability `unsupported`.  The result's detail says so in those words, and
the check's advice says to rerun to confirm.

Alternatives considered:

- **A fourth `unverified` status.**  It would name the distinction
  precisely, but the status is part of the result record, the
  `provider-check/result` event, the report page, the summary counts and
  the architecture contract.  The three statuses already have a place for
  a measured miss: FAIL.  Adding a status would make every reader handle
  four cases to separate two things the detail line can already say.
- **Keep one-run cache misses as SKIP.**  It keeps the old conservative
  reading, but it leaves the cache checks unable to fail their own subject
  and makes a completed experiment look like one that did not run.  That is
  the confusion this change fixes.
- **Fix only the transcript check.**  The exception would become a FAIL and
  the fix would be smaller, but the cache SKIPs would still read as errors
  that the check had swallowed.  The user's report showed both, and both
  are answers to the same question: did the check run?
- **A separate "error" status for exceptions.**  The runner already turns
  an uncaught check error into FAIL; the transcript check was the one place
  a check hid its own error behind a hand-built SKIP.  Catching the error
  in the check and returning FAIL with a harness-side detail gives a better
  message than the runner's generic, deliberately provider-text-free
  failure text, without a new status.

The runner's existing rule is unchanged: an uncaught error, a timeout or a
failed assertion is a FAIL; only `harness-provider-check-unavailable` and
`harness-provider-check-budget` are the exceptions that stay SKIP.

## The transcript round trip

`harness-provider-check--transcript-round-trip-nodes` now writes the nodes
the harness itself writes:

- a `user` node;
- a `thinking` node carrying `:meta (:signature ...)`;
- an `assistant` text node;
- a `tool-call` node with its call id, tool and input;
- a `tool-result` node with the same call id.

The check appends them, renders the step request, writes the session to the
store and reloads it as a restart does, renders again, and compares the
system prompt, messages and tools.  The rendered request now contains the
thinking block with its signature, the text block, the `tool_use` block and
the `tool_result` block.  It also fails when any of those is missing: a
renderer that drops them would otherwise pass by dropping them the same
way twice.

A failure to create the session, append the nodes, reload or render is a
FAIL with the harness-side short message.  The session is deleted in an
`unwind-protect` either way.  The check still makes no model request, so it
tests the harness rather than the provider, and it still runs for every
model.

Alternatives considered:

- **Teach the renderer to accept an assistant node holding blocks.**  That
  would give one node two shapes, and the shape the check invented is not
  the shape the agent writes.  The renderer reflects the transcript the
  harness keeps; the check should build that transcript.
- **Use a node's `:blocks` field.**  The renderer supports it, but the
  agent writes `:content` for assistant text and separate nodes for
  thinking and tool calls.  Testing `:blocks` would exercise a path a real
  session does not take.

## What is still a skip

The other skips in a provider report remain skips because they measure
nothing about the provider, not because an error was swallowed:

- quota, fork and embeddings when the provider does not advertise the hook,
  or when no embedding model was given;
- image checks when the model does not advertise image input, and the
  thinking check when no level is advertised (or the catalogue it needs did
  not answer);
- a model that declines to call a tool: the provider suite has no tool
  exchange to judge (the model suite turns the same refusal into a FAIL);
- a hosted loop whose synthetic prefix sessions are unsupported;
- the request budget, an unavailable account, a rate limit, a refused
  credential or an unreachable provider;
- a cache check with missing telemetry, too few samples, a warm control, a
  failed or throttled request, identity mixing, repeated session ids, or
  requests that did not overlap.

Each of those is an unmeasured claim, with the detail line saying why.
None of them is an error the check caught and hid.

## Verification

The offline suite runs with a fake provider and exercises:

- the transcript round trip end to end with the session and agent layers
  loaded: PASS, two renders, the same messages, and thinking signature,
  `tool_use` and `tool_result` blocks present in the request;
- an injected rendering exception: FAIL, with the harness-side detail, not
  SKIP;
- the exact-prefix verdict for every branch: environment, incomplete
  probes, missing telemetry, too few samples, warm control (SKIP); observed
  reuse (PASS); repeated misses and partial reuse (FAIL with "unverified,
  not unsupported");
- the independent-prefix verdict for every branch: environment, throttled,
  identity mismatch, failed requests, repeated sessions, too few prefixes,
  missing telemetry, warm control, no overlap (SKIP); observed reuse
  (PASS); serial-only reuse, partial reuse and a complete miss run (FAIL
  with "unverified, not unsupported");
- an end-to-end independent-prefix run with every cache-read zero: FAIL,
  with 0/4 prefixes cached and cold controls.

`scripts/test.sh test/harness-provider-check-test.el`, the full
`scripts/test.sh`, `scripts/lint.sh` and `scripts/module-docs.sh --check`
are the repository's checks for the final tree.  No live paid run is part
of this change.
