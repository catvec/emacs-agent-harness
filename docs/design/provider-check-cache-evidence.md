# The provider self-test: cache evidence and bounded concurrency

## What the self-test is for

`C-c h S !` (`harness-provider-check`) answers two different questions
about the model in front of the user: does the generic provider API do
what its plugin claims, and is the model good enough for the harness.
It has always been an explicit, paid run, separate from
`scripts/test.sh`, and its report page has always been the place where
a FAIL names the advertised feature to fix or remove.

Two things were missing for the cache side of that judgement.

- The checks were a serial chain.  A provider's answers were asked for
  one after another even where nothing connected them, so a run of
  seventeen checks paid the sum of every latency, and one slow check
  held up the rest.
- Nothing measured prompt-cache reuse.  Whether a provider reuses an
  exact prompt prefix, whether a short keep-warm request during a wait
  refreshes it, and whether independent sessions cache their own
  different prefixes were assumptions a user could only hear about
  from a provider's documentation.  The harness's own cache
  warm/expiry code suggests what *might* work; it does not know what
  the account actually does.

The user's desktop usually has about twelve sessions running.  Those
sessions do not share a prompt prefix: each has its own conversation
and its own early content.  The question that matters is therefore
whether every session caches and reuses its *own* prefix when twelve
of them ask at once.  One prefix shared by many sessions is a
different question, a different experiment, and not evidence for this
one.

This change turns the two into one coherent extension of the same
self-test: independent checks run together under explicit bounds, the
cache experiments measure exact-prefix reuse and independent-prefix
reuse across many sessions, and the runs save a conservative
capability record the rest of the harness can read.

Nothing here enables an automatic billable request, and nothing here
changes a cache safeguard.  The record is evidence, not a decision.

## The runner

The old runner kept one `--advance` chain and one set of "current
check" fields on the job: the running check, its handle, its abort
flag, its metadata, the base completion and the tool attempt.  Running
two checks at once would have overwritten them.

The new runner separates the two lifetimes:

- A `harness-provider-check-run` is one check's own state: the job, the
  plan entry, its internal sessions, the provider handles it has open,
  its abort flag and the promises it waits on.
- A `harness-provider-check-job` is shared context: the model, the
  provider, the plan, the results, the dependencies, and the bounds.
  What several checks may read is a promise on the job: the catalogue
  metadata, the base completion, and the tool attempt a model check
  reuses instead of making a second paid call.

Each request goes through a small gate.  At most
`harness-provider-check-concurrency` (3) checks run at once, each with
one request in flight, except that the independent-prefix experiment
may hold its whole batch in flight (bounded by
`harness-provider-check-max-concurrency`, 12); a single job may start
at most `harness-provider-check-max-requests` (64) requests, every
request is cut to `harness-provider-check-max-output-tokens` (512),
each check has `harness-provider-check-timeout` (90s) and the job has
`harness-provider-check-total-timeout` (900s).  The gate is a queue,
not a semaphore with a fixed pool: a check that is waiting on a
dependency does not occupy a slot, so the run uses the provider
politely without serialising itself.

Only genuine dependencies keep their order, and they are data in the
plan (`:after`):

- the catalogue before every check that reads model metadata;
- completion before usage;
- the tool turn before the model checks that read its receipt;
- the cache experiments before the capability record;
- the phases inside one cache experiment, which are a sequence by
  construction.

A cache experiment is marked `:solo`: while it runs, no ordinary probe
starts, so its measured concurrency is the experiment's, not the
runner's.  The ordinary probes each carry a fresh nonce as the first
thing in their synthetic prefix, so they cannot warm one another even
when their requests overlap.

Cancellation is per job and reaches every check: each run remembers its
handles, `provider/check-cancel` aborts the job, every handle's cancel
is called, queued requests are refused, and the results already
settled are kept.  Results are announced as they settle, but the job's
promise resolves in plan order, so a report is deterministic even
though the run is not.

The request plan stays under the 64-request bound:

- the ordinary provider suite is 35 requests (9 for the exact-prefix
  experiment and 18 for the 4-session independent-prefix experiment,
  plus the contract checks);
- the opt-in twelve-session stress is 59 requests, because it runs only
  the cache checks: the catalogue, both cache experiments and their
  evidence record.  It does not repeat the provider contract checks,
  and it does not raise the bound.

Alternatives considered:

- **A fixed worker pool over the whole plan.**  Simple, but it makes a
  check that is waiting on its dependency hold a worker, and it makes
  the concurrency of the cache experiment depend on unrelated probes.
  The dependency graph plus a request gate is smaller and measures what
  it says it measures.
- **Parallelising only the cache checks.**  It would leave the largest
  latency win (the provider contract checks) untouched and keep the
  shared-current-check state that makes the next parallel change risky.
- **Unbounded `promise-all` over the plan.**  It would send one request
  per check at once, which is exactly what a rate-limited or
  pay-per-token account should not see from a diagnostic.

## The exact-prefix cache experiment

One check, "Exact-prefix cache reuse and keep-warm", sends nine
synthetic requests in a fixed sequence:

| Phase | What it is for |
|---|---|
| `prime` | Establish the prefix in the provider's cache. |
| `repeat-immediate` | Is the same prefix read back at once? |
| `repeat-persistence` | After a bounded wait (2s by default), still read back? |
| `warm-1`, `warm-2` | Two short keep-warm messages on the same prefix. |
| `resume` | Does the request after the keep-warm read the cache? |
| `control-prime` | A second prefix, never refreshed: cold control. |
| `control-resume` | That prefix after the same wait: no-refresh baseline. |
| `mismatch` | A prefix with one deliberate difference: identity control. |

Realistic request identity is what is under test, so every request in
the shared group carries the same model, the same synthetic system
prompt with the same filler (about 2k tokens, over the 1,024-token
minimum some providers document), the same synthetic tool schema, the
same thinking level (the first the model advertises, the cheapest
realistic one), and the same message order.  The nonce is the very
first byte of the system prompt: two probes with different nonces
share no prefix at all.  Each request names a different provider
session, so a cache hit cannot be conversation state.

The system prompt is synthetic: the registry's plain provider-check
system prompt and a filler of repeated neutral text.  No user
conversation, message, or project name is sent.

What the check does *not* do:

- It does not wait out a provider's advertised lifetime.  A 2-second
  persistence point is a measured interval, not a TTL, and the report
  says "TTL unverified" in those words.  A hit after a wait neither
  measures a lifetime nor extends one.
- It does not treat a single hit as a guarantee, or one run of misses as
  "unsupported".  Unsupported needs repeated misses with cold controls in
  two independent runs; a second run of the same model supplies the count
  through the saved record.  A complete run of misses is a FAIL of the
  check itself -- it ran, and the reuse it measures did not happen -- while
  the record keeps that run `unverified` until the second run.
- It does not call missing telemetry zero.  A usage event with no
  cache-read field is `missing`, and the check is SKIP: unknown, not
  zero.  A run that could not measure its claim -- no telemetry, too few
  samples, a warm control, a failed or throttled request -- is a SKIP; a
  run that measured misses is a FAIL, never a SKIP
  ([provider-check-status-reporting.md](provider-check-status-reporting.md)).

The detail line reports, in noun phrases: repeats cached, keep-warm
cached, whether the resumed request was cached, the persistence wait,
whether the controls were cold, the telemetry, the cost and its source,
the sample size, and that TTL is unverified.  The result also carries
the structured evidence, which is what the capability record is built
from.

## The independent-prefix cache experiment

The second check, "Independent-prefix cache reuse", models the user's
usual desktop rather than a shared conversation.  It gives each of N
independent sessions (N = 4 by default, 12 with the opt-in stress) its
own synthetic prefix, different from the first byte, and its own
session id, stable for the whole experiment.  The model, tool schema,
thinking level and message order are otherwise the same, as they are
for real sessions of one model.

For every prefix the experiment sends:

1. `prime` — one request in that session, which establishes that
   session's prefix;
2. `baseline` — a second serial request in the same session, the
   per-prefix baseline: that prefix reused with no concurrency.

The specs interleave prime and baseline per prefix, so each prefix's
baseline follows its own prime and the run is 2N serial requests.

Then it reuses exactly the same N prefixes:

3. `round-1` — one request per prefix, all N in flight at once, each in
   its own session;
4. `round-2` — the same N prefixes again, still concurrently, in
   reverse order, so a second round also interleaves the sessions.

Finally it asks two fresh prefixes that were never primed (the
controls), concurrently and separately.  They should read no cached
tokens; a warm control would mean the hits are not coming from the
primed content.

Every request under test carries its prefix's nonce at the very start
of its system prompt and its prefix's own session id.  A result whose
prefix or session id does not match its spec is recorded as an identity
mismatch, not smoothed over.  No prefix and no session is shared
between two sessions, so a hit for one session cannot come from another
session's conversation, and a swap would show up as a mismatch or a
miss.

The evidence is per prefix: its prime, baseline, round 1 and round 2,
with cache-read, prompt tokens, output, latency and the same session id
throughout.  It also reports:

- how many prefixes hit in both rounds (`cached`), how many hit in the
  baseline, round 1 and round 2 separately, and how many controls were
  cold;
- the requested sessions and the number of distinct session ids;
- the measured peak concurrency and median latency of the concurrent
  rounds;
- prompt, cached and output tokens, the cost and its source, and any
  throttle, error, identity mismatch or environment problem.

The classification is conservative:

- **observed** requires every primed prefix to hit in the serial
  baseline and in *both* concurrent rounds, both controls to be cold,
  telemetry present for every reuse request, no throttle, error,
  identity mismatch or repeated session, and a measured peak of at
  least two overlapping requests.  It is an observation, not a
  guarantee.
- **unverified** is everything else that is not a complete miss run:
  a partial batch (some prefixes hit, some did not), missing or partial
  telemetry, a serial baseline that hits while the concurrent rounds
  miss, a warm control, a throttle, a failed request, identity mixing,
  requests that did not overlap, or too few samples.
- **unsupported** needs a complete run in which every primed prefix
  missed in the baseline and in both rounds, the controls were cold and
  nothing was throttled or mixed, repeated in two independent runs.

A 4-prefix ordinary run makes 18 requests (4 primes + 4 baselines + 4
+ 4 concurrent + 2 controls); the 12-session stress makes 50.  There is
no shared-prefix experiment in the plan: it would answer a different
question, and it must not substitute for this evidence.

Alternatives considered:

- **One shared prefix for all sessions.**  That is what this experiment
  replaced.  It measures whether a cache is keyed by a prompt shared
  across sessions, not whether each session's own conversation is
  cached; it can pass while independent sessions miss.
- **Never-primed prefixes as the only controls.**  They control for
  "caching is on", not for "this prefix was cached": the serial
  per-prefix baseline and both concurrent rounds do the latter.
- **Twelve sessions by default.**  The user asked for a test that
  reflects their usual twelve, and the ordinary run stays at four to
  keep a paid diagnostic cheap.  The twelve-session mode is one key
  (`S` on the page) and one explicit option, never a default and never
  part of the ordinary suite; it runs only the cache checks.
- **Comparing against fresh sessions without a primed prefix.**  A cold
  fresh session says nothing about whether the primed prefixes were
  reused; the never-primed controls answer the isolation question, and
  the baseline answers the priming question.

## The capability record

The provider suite ends with "Cache capability evidence", which
classifies the experiments and saves one record per provider/model
under the harness state directory.  The record separates advertised,
observed, unsupported and unverified findings, and the classification
is deliberately asymmetric:

- **observed** needs telemetry present, sample counts, and cold
  controls.  For independent-prefix reuse it needs every primed prefix
  to hit in the baseline and both concurrent rounds; for exact-prefix
  reuse it needs at least two repeat samples.  A hit is an observation,
  never a guarantee.
- **unsupported** needs repeated misses with cold controls in two
  independent runs.  One run is unverified.  The check that measured the
  misses is a FAIL about that run, and says "unverified, not unsupported"
  in its detail.
- **unverified** is everything else: no telemetry, too few samples, a
  warm control, a rate limit, a partial batch, identity mixing, an
  incomplete probe, any TTL or lifetime extension claim.  Missing
  telemetry is unknown, not zero.

The record holds advertised facts (the provider's declared cache
lifetime and prices), observed, unsupported and unverified findings,
the sample counts and hits, the settings that produced them, the cost
and its source, and the request identity version.  Its scope
fingerprint covers provider, model, advertised capabilities, cache
lifetime, prices and the synthetic request identity; the evidence
schema is version 2, because version 2 replaced the old shared-prefix
cross-session finding with independent-prefix reuse.  A record from
schema 1 is stale by construction.  `provider/cache-evidence` compares
the fingerprint with the current configuration and returns `:stale`
when anything changed.  A stale record is kept, not silently reused as
current.

The record changes no setting and starts no request.  The harness's
existing cache warm/expiry/compaction behavior is untouched.  A future
change that wants to use the record to enable a keep-warm policy needs
its own review, because a capability observation is not a cost or
privacy decision.

Alternatives considered:

- **A per-provider boolean "cache works".**  It would collapse the
  difference between advertised, observed and unverified, and would
  invite `if cache-works then keep-warm` in unrelated code.
- **Deriving a TTL from the persistence wait.**  It would turn a
  two-second measurement into a lifetime claim; the record keeps
  advertised TTL and unverified TTL apart instead.
- **Reusing the session cache stamp.**  A session's `:cache-at` is
  about a conversation's next message, not about a provider's prefix
  capability, and it is reset by compaction.  A separate record is the
  smaller and clearer shape.

## The page and its copy

The confirmation before a paid run now carries the harness's estimate:
checks, the upper bound on paid requests, the output cap, and the
worst-case cost from the catalogue's input and output prices — or
"cost unknown" when the catalogue has none.  A provider with no prices
is not shown as zero cost.  The estimate is computed by
`provider/check-estimate` without starting a job; the page also shows
it once the job starts.

The page lists the cache capability record when the run saved one:
each capability's label and its observed, unsupported or unverified
state, with the record's scope and check time.  Labels are noun phrases
("exact-prefix reuse", "cache lifetime", "independent-prefix reuse"),
and states are single adjectives; the page never turns them into advice
or a sentence about the provider.  The stress run shows "cache stress
12 sessions" in its header, so the extra spending is visible while it
is happening.

The copy was inventoried before implementation and checked against the
rendered page:

- confirmation: "Run live checks of LABEL? up to N paid requests ·
  output ≤N tokens · cost ≤$N" (or "cost unknown", or "Several paid API
  requests" when no estimate can be had);
- page header: "Estimate: …", "cache stress 12 sessions";
- independent-prefix detail: "independent prefixes 12/12 cached ·
  baseline 12/12 · round 1 12/12 · round 2 12/12 · controls 0/2 cached
  · sessions 12/12 (all distinct) · peak 12 parallel · throttled 0 ·
  errors 0 · median 1.06s · prompt … · cached … · output … · cost …
  · TTL unverified";
- capability section: "Cache capabilities", the capability labels, the
  states, "scope MODEL · checked HH:MM:SS";
- keys and menu: "Cache stress · 12 sessions", help "Cache stress run:
  twelve independent sessions, each with its own prefix".

## What the live runs showed

Both runs were explicit, paid DeepSeek runs through the development
harness, on `deepseek:deepseek-flash`, with the bounds above.  No
provider was substituted, and no new credential or setting was added.

The ordinary provider suite ran on 2026-11-07 at 09:31:

- 16 checks, at most 35 requests, output cut to 512 tokens, estimated
  at $0.03 worst case; it took 31.7 seconds and reported 12 PASS, 0
  FAIL, 4 SKIP.
- exact-prefix reuse: 2/2 repeats and 2/2 keep-warm pings read cached
  tokens, the resumed request read the cache, the prefix was still
  cached after the 2s persistence point, and both controls were cold;
  15,602 prompt tokens, 9,216 cached, 162 output, $0.0011 estimated;
- independent-prefix reuse: 4/4 prefixes cached in the baseline and in
  both rounds, controls 0/2 cached, peak 4 parallel, all 6 session ids
  (4 prefixes and 2 controls) distinct, median 1.27s, 31,192 prompt
  tokens, 18,432 cached, 370 output, $0.0022 estimated; observed, not a
  guarantee.  This run was made just before the display fix that
  separates the control sessions from the prefix count; the twelve-
  session run below shows the final line.
- the four skips were the transcript round trip (a pre-existing
  renderer error in unchanged code, fixed later in
  [provider-check-status-reporting.md](provider-check-status-reporting.md)),
  quota reporting (none reported), provider fork (not advertised) and
  embeddings (no embedding model).

The twelve-session cache stress ran on the final code on 2026-11-07 at
09:38:

- 4 cache checks, at most 59 requests, estimated at $0.05 worst case;
  it took 44.6 seconds and reported 4 PASS, 0 FAIL, 0 SKIP.
- independent-prefix reuse: **12/12 prefixes** cached in the serial
  baseline and **12/12 in round 1 and 12/12 in round 2**, with the
  never-primed controls at 0/2 cached and all 14 session ids (12
  prefixes + 2 controls) distinct; peak 12 parallel, no throttling, no
  errors, median 1.06s;
- every prefix's prime read no cache, then its baseline, round 1 and
  round 2 each read 1,536 cached tokens, with 192-197 uncached input
  tokens per concurrent request; 86,563 prompt tokens, 55,296 cached,
  1,053 output, $0.0055 estimated at the catalogue's prices (the
  provider reported no cost of its own);
- the record saved schema 2 with four observed findings (exact-prefix
  reuse, keep-warm reuse, persistence, independent-prefix reuse), no
  unsupported ones, and keep-warm benefit, cache lifetime and keep-warm
  extension unverified; the advertised TTL 10,800 (3 hours) is the
  provider's claim, not a measurement.

The first earlier live run of this change (before the correction) found
a real bug: the cache experiments started before the catalogue check
had settled, so they used no advertised thinking level and could not
price their requests.  The plan now declares the catalogue dependency
for both cache experiments, and the fake-provider suite asserts it.
The same earlier run also showed the pre-existing transcript SKIP; its
code was unchanged by this task, and a later change rebuilt that check
from the harness's own node shapes, so a rendering error is a FAIL now
and the check itself passes
([provider-check-status-reporting.md](provider-check-status-reporting.md)).

## What remains unverified

- A two-second persistence point says nothing about a provider's TTL,
  and no run waits out one.  `prompt-cache-ttl` and
  `prompt-cache-keep-warm-extension` are always unverified by design.
- A hit or a miss is one observation.  Unsupported needs two
  independent runs, and the record counts them.
- The independent-prefix experiment measures each session's own prefix
  under concurrency.  It does not measure a prefix shared by several
  sessions; that is a different question and is not inferred.
- A provider that shares a cache across users, or routes a request
  through a different backend, cannot be told apart from an ordinary
  hit by these probes; the report says "observed", not "shared".
- The concurrency measurement is a peak from measured request
  intervals; a provider that queues requests internally can show a
  lower actual concurrency than requested, which the report states
  rather than hiding.  Twelve requests were in flight in the stress run
  and the measured peak was 12.
- One live run is one sample per experiment.  The record says observed,
  not guaranteed, and an unsupported finding needs two independent runs;
  the numbers above are DeepSeek's behaviour at the time of the runs,
  and a changed provider, model, price or configuration makes them
  stale.

## Verification

The offline suite covers what the change can deterministically break:
independent checks overlap, dependencies still wait, cancellation
reaches every request in flight, the request and output bounds hold, a
rate limit is a SKIP rather than a verdict, evidence classification is
conservative across runs, a changed scope makes a record stale,
independent prefixes are distinct from the first byte and keep one
session id, each prefix is primed before reuse, two rounds reuse the
same prefixes concurrently, the old shared-only shape and a swapped
session are rejected, a partial batch stays unverified, the stress plan
stays under the request bound, the confirmation carries the estimate,
the page draws the capabilities and the rendered copy is asserted
exactly.  `scripts/lint.sh`, `scripts/test.sh` and
`scripts/test.sh --status` are the repository's own checks for the
final tree.
