# Provider chaos testing

Provider implementations are a fallible boundary. A malformed response may
produce a tool error or a failed turn, but must not leave a pending turn forever,
repeat a tool effect, or poison the conversation used by future requests.

The gremlin provider already has fixed scripts for malformed events, duplicate
completion, hangs, floods and tool storms. The AFL plugin tests pure protocol
boundaries. `harness-provider-chaos-test.el` adds the missing recovery oracle:
a real registered faulty provider drives the actual agent and session store,
then the same session must accept another prompt and work after a cold load.

## Run the tests

The short campaign runs automatically in every full `scripts/test.sh` run. It
includes 38 single-event corpus cases, 32 reproducible sequences of eight events,
and targeted tests of duplicates, missing completion, cancellation, malformed
terminal envelopes and invalid tool arguments. Every session and stored record
is temporary. The only tool is a pure counter; no real provider or paid API is
called.

```sh
TMPDIR=/var/tmp scripts/test.sh lisp/modules/harness-provider-chaos-test.el

# A larger bounded campaign; 1024 traces were exercised during development.
HARNESS_PROVIDER_CHAOS_SEEDS=1024 TMPDIR=/var/tmp \
  scripts/test.sh lisp/modules/harness-provider-chaos-test.el

# Replay one failing seed on the same revision.
HARNESS_PROVIDER_CHAOS_START_SEED=5 HARNESS_PROVIDER_CHAOS_SEEDS=1 \
  TMPDIR=/var/tmp scripts/test.sh lisp/modules/harness-provider-chaos-test.el \
  harness-provider-chaos-seeded-sequences-survive-turn-and-reload
```

A failure prints its seed and event trace in
`scripts/.dev/test-logs/harness-provider-chaos-test.log`. Keep that log and the
commit hash: adding corpus entries can change which events a seed selects.
The corpus test prints the individual case, so a failing mixed sequence can also
be reduced to a single event regression. No random global state or sleeps are
used to choose event order; the campaign owns a deterministic generator, and
held callbacks control cancellation and replacement-turn interleavings.
Cancellation is also tested for retry after a transport cancellation function
signals an exception before stopping its producer.

## What is checked

The oracle requires an ordinary recognized turn result, exactly one terminal
notification, no remaining active turn or pending interaction, and a successful
next prompt. It flushes the actual store, forgets memory, loads the record and
node journal, and requires another successful prompt with no hydration fault.
Old callbacks must not modify the resulting transcript or finish a replacement
turn.

The fake provider validates the next request's tool identifiers, names and JSON
argument object shape. A fake that accepts any history would miss a malformed
response being saved and rejected forever by a stricter provider. Tool effects
are counted separately, including a duplicate delivered after the first result
was already recorded. Each hosted delivery still receives a response. A new
independent request may reuse an ID; deduplication is scoped to a provider step,
not a global cache of tool names or argument values.

## Defects this campaign found

| Fault | Before the repair | Required behavior |
| --- | --- | --- |
| String or vector terminal reason | Unusable reason escaped into core state | Normalize known strings; reject invalid terminal control fields with a protocol error |
| Duplicate tool-call ID | The handler executed twice, even after the first call completed | One execution per request ID, with a reply to a duplicate hosted RPC |
| Malformed terminal event after the handle returned | An error ended the turn while its producer remained uncancelled | Request cancellation of the captured producer exactly once, including the synchronous handle-return race |
| Non-object tool arguments | A handler could execute and the bad input was saved into future request history | No execution; an error result; replayable object-shaped history with the invalid input type recorded as metadata |

Five targeted checks fail on the preceding reliability-pass commit `f30f3b7`;
[the baseline summary](../evidence/provider-chaos/baseline-summary.txt) records
those failures. The stricter-history oracle separately reproduced
[the poisoned-history failure](../evidence/provider-chaos/history-poison-reproduction.txt).

An existing gremlin assertion expected every unknown-tool delivery to say
`Unknown tool`, including one whose arguments were a string. That assertion now
checks the exact object-argument error for that delivery while retaining the
unknown-tool checks for the two object-shaped deliveries, all three error results,
and normal turn completion.

## AFL coverage and remaining scope

The AFL plugin's `provider-events` target previously filtered out atoms and
improper envelopes before calling the guard. It now delivers those values to the
actual guard and has seeds for malformed terminal fields and circular Lisp
objects. Its regression verifies that all malformed inputs reach the boundary.
The existing AFL adapter also provides saved crash inputs and `afl-tmin` shrinking;
see [the plugin guide](../../.harness/plugins/fuzz/README.md). AFL++ is not
installed in the development environment, so its adapter and seeds were checked
without running an AFL mutation campaign.

These tests start at the canonical event boundary after an adapter. They do not
mutate every provider's JSON/SSE/CLI decoder or establish exactly-once execution
across machine crashes. Sanitized incident recordings replayed through real
adapter parsers, with truncated frames and varied chunk boundaries, are the next
separate layer. A provider that ignores cancellation still depends on transport
and process timeouts; the replacement-turn checks ensure its late events have
lost authority over the session.
