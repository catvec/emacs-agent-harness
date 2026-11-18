# Retry ownership: one layer above the providers

## What was wrong

The review asked why a provider was retrying its own requests.  Noah's
words: *"shouldn't some other layer above a provider be responsible for
retrying? … make sure the retry is not provider-specific and not
implemented in [OpenRouter]."*

`harness-provider-openrouter.el` had grown a retry subsystem of its own:

- `:retry` in the routing policy, with `:max-attempts`, `:max-seconds`
  and `:max-output-tokens`, validated as a required part of the policy;
- a `harness-openrouter--budget` struct, one per session, and a table of
  them;
- `harness-openrouter--budget-take` counting attempts at dispatch, and
  `--budget-refusal` reading the policy's bounds;
- an `agent/step-error` filter at priority 45, ahead of the generic
  retry's 60, deciding on `--retry-decision` whether a failure was worth
  another try and how long to wait;
- `--transient-failure-p` / `--retryable-failure-p`, re-reading typed
  error codes and HTTP statuses;
- `--bounded-request`, clamping `:max-tokens` to the policy's output
  bound;
- `--http-retry`, a dialect hook telling the shared transport to replay
  nothing for a governed request.

Every one of those is retry policy, and retry policy already lived in
`harness-retry.el` — the generic `agent/step-error` handler at priority
60, with `harness-retry-max-attempts`, `harness-retry-delay`,
`harness-retry-max-delay` and `harness-retry-jitter`, and the same
helpers `harness-small` uses for the harness's own one-off calls.  Two
layers decided the same question with different numbers, and the
provider-owned one won for OpenRouter's sessions because it ran first.

There was a real bug in the duplicated logic, too.  `--retry-decision`
computed a jittered delay for its **time-fit check**, then computed it
again for the **scheduled wait**.  Two calls, two `random` draws: with
`max-attempts 2`, `max-seconds 1`, elapsed 0, count 1,
`harness-retry-delay` 0.9 and `harness-retry-jitter` 0.2, deterministic
draws of 0 and 999 returned `(:retry t :delay 1.07982)` — the check
admitted 0.9 s and the caller slept 1.08 s, past the promised bound.
The dispatch guard did stop the late POST, so no request went out
unauthorised, but the wait still broke the bound the policy promised.

## What the change decides

**One owner.**  `harness-retry.el` is where a failure is read, bounded,
waited out and repeated, for every provider.  Its numbers are the
harness's numbers: `harness-retry-max-attempts`,
`harness-retry-delay`, `harness-retry-max-delay`,
`harness-retry-jitter`, and a new `harness-retry-max-seconds` (nil by
default: no elapsed bound).  A provider keeps no copy of any of them.

**A provider says what its requests need, never how they are retried.**
`harness-retry-policy-functions` is a hook of functions of a session,
each returning a policy plist or nil:

- `:owner` — a few words for the hints ("OpenRouter"), so what a person
  reads says whose request was repeated;
- `:count-sends` — the provider authorises and counts every send itself.

That is the whole schema (`harness-retry-policy-keys`), and it has no
number in it.  OpenRouter answers `(:owner "OpenRouter" :count-sends t)`
for a session its policy routes and nil for every other session, so an
ordinary provider's session behaves exactly as it did.

**Why `:count-sends` is the right shape, and not a nuisance.**  A
request the OpenRouter policy governs must be re-checked — pin,
provider allowlist, recorded price, catalogue freshness — immediately
before it is sent, and only that module can do that check.  So the
shared layer cannot repeat the request itself; it must ask the module
to send again, and count the sends where they happen.  `:count-sends`
says precisely that, and nothing more: the module makes the request,
the shared layer counts it.

**The budget is the shared layer's, counted at the send.**
`harness-retry-send` takes a send from the budget of the request in
hand: it refuses one past the count (`1 + harness-retry-max-attempts`)
or past the elapsed bound, and counts the one that goes out.  A retry
marks the budget `retrying`, so the next send continues the same
request's count and clock instead of starting a fresh one; a send that
is *not* a retry starts both again, so a step after a successful one is
not charged to the previous request.  *(Superseded: this revision kept
one budget per session, which two requests of one session shared.  The
budget is the request's now -- see "The second revision" below.)*

**The wait is drawn once.**  `harness-retry-wait-plan ATTEMPT FAILURE
&optional ELAPSED` returns `(:delay D :fit BOOL)`: one
`harness-retry-backoff` call, and the fit test is made on that very
value.  The decision uses the delay from the same plist it validated,
so the admitted wait and the taken wait cannot differ.  A wait that
does not fit stops the request with the bound it would have passed.

**`permanent` is a kind, not a code list in the provider.**  The
generic transport gained a `:failure-kind` dialect hook: given the
stream and the error, a provider may decode its own typed fields into
the kinds the shared layer already reads (`transport`, `rate-limit`,
`quota`, `billing`, `permanent`).  OpenRouter's hook maps
`error_type` codes in `--permanent-types` to `permanent` and its
transient codes to `transport` / `rate-limit`, and answers nil for a
request no policy governs (so ordinary OpenRouter keeps the transport's
own reading).  `harness-retry` ends the turn at once, `:final`, on
`permanent`.

**The transport's replay count is the shared layer's answer.**
`harness-retry-transport-retries REQUEST` returns 0 for a session whose
provider counts its sends, and nil (`harness-provider-openai` then uses
`t`, the transport's own policy) otherwise.  The `:http-retry` dialect
hook is gone.

## The output limit, separately

The policy's `:max-output-tokens` (example value 4096) went with the
rest.  It was an arbitrary example that had three problems:

1. It was a real cap on **each model completion** — not a model
   default, a context length or a tool-call count.  Ordinary harness
   steps send no `:max-tokens` at all, so a routed session silently
   gained a 4096 ceiling nothing else had.
2. It could truncate a tool call: reasoning and tool-call arguments are
   completion tokens, and a cut call arrives with unparsable arguments
   (the harness keeps them as `(:raw …)`).
3. It applied to one provider, from one module, through a policy — a
   general request concern in the wrong place.

So the policy has no output field.  What a request asks for is the
request's, and a ceiling for *every* provider is the request layer's:
`harness-provider-max-output-tokens` (nil by default) applied by
`harness-provider-bound-output` at `provider/complete`.  With it nil
the request is passed on untouched, `:max-tokens` omitted or not, so
every endpoint's own default applies as before.  A one-off call that
names a smaller limit keeps it.

## Alternatives considered

- **Teach `harness-retry` about OpenRouter.**  Rejected: the shared
  layer would need the catalogue, the pin and the price checks to
  re-authorise a retry, which is the provider's own job, and it would
  put OpenRouter's field names in a module every provider loads.
- **Keep a policy `:retry` block but apply it in the shared layer.**
  Rejected: two providers' sessions would then be bounded by two
  different sets of numbers from one place, which is the duplication
  again with extra steps.  Noah asked for one retry policy for the
  harness; the numbers are options, not policy fields.
- **Have the provider call `harness-retry-backoff` and sleep itself.**
  Rejected: that is the old design with a shared helper — ownership
  still in the provider, and the jitter bug still possible at each
  call site.
- **Give the shared layer an `:attempts` number in the provider
  policy.**  Rejected: the number belongs to
  `harness-retry-max-attempts`.  A provider answering a second number
  would drift from it, which is exactly the state this revision
  removes.
- **Retry a truncated tool call automatically.**  Rejected: a request
  that ran into its output limit is not a transient failure, and the
  same request may well hit the same limit again.  The step ends at
  `max-tokens` (no call) or hands on the call it did write.

## What stays as it was

Every safeguard the earlier revisions added is unchanged, and each has
a test:

- the pin, the provider allowlist, the recorded price and catalogue
  freshness are checked before **every** send, retries included, and a
  policy edited — disabled, removed, narrowed, lowered — while a retry
  waits refuses that retry (`policy-changed`, `disabled`,
  `pin-not-vetted`, `over-max-price`);
- a policy *removed* while a retry waits refuses it
  (`--withdrawn-refusal` over the request's own authority) rather than
  falling through to the ungoverned pass-through;
- a governed request is one POST: the transport is asked for no replay
  of it;
- a wait that cannot fit inside `harness-retry-max-seconds` stops the
  request instead of being slept;
- same-provider pinning: no retry, fallback, quota path or alias moves
  a pinned session (`harness-openrouter--guard`);
- fail-closed: an unreadable price, an ambiguous endpoint, a stale
  catalogue, an absent limit or a policy with a hole sends nothing;
- cancellation: a turn cancelled while a retry waits sends nothing;
- no fallback outside DeepInfra/Cohere;
- the catalogue is the only source of a price; the policy holds
  spending limits only;
- the example is still commented out and routing is inactive.

## How it is verified

- `harness-retry-a-jittered-wait-is-checked-as-it-is-spent`: the exact
  scenario above, with `random` mocked to draw 0 then 999.  It asserts
  the plan's delay is 0.9 s, that it fits a 1 s bound, and that exactly
  one draw was made — the old code fails it on the draw count and, with
  a 999 draw first, on the fit.
- `harness-retry-a-jittered-wait-past-the-bound-does-not-fit`: the same
  numbers with the long draw first; the plan refuses the value it
  reports.
- `harness-retry-a-wait-past-the-bound-stops-without-waiting`: a
  decision with an unfittable wait carries no `:delay` and returns in
  under a second.
- `harness-retry-counts-a-counted-providers-sends` and
  `-counts-the-clock-from-the-first-send`: the shared count, the
  refusal wording, and the clock measured from the first send.
- `harness-retry-a-permanent-rejection-ends-the-turn-at-once`: a
  `permanent` failure is not retried even with a later filter that
  would retry anything.
- `harness-provider-openrouter-transport-test.el` (real curl against a
  local server): one POST under `harness-retry-max-attempts` 0, a reset
  and a 503 sharing one budget of two sends, a typed rejection not
  repeated, a typed transient code repeated at the same pinned endpoint
  with the same restriction fields, `Retry-After: 3600` under a 1 s
  bound, time spent by the first attempt counting, six policy edits
  while a retry waits, a retry going back to its own endpoint after a
  hand switch, a stale dearer pin, cancellation during a backoff, and
  plain OpenAI / ungoverned OpenRouter still replaying as before.
- the three reproductions of the second revision, as integrated tests
  over the real wire and a real turn:
  `harness-openrouter-transport-a-small-call-keeps-its-restrictions`
  (a recap whose policy is removed or disabled during its wait sends one
  restricted POST and stops: no `provider` object is ever missing),
  `harness-openrouter-transport-a-small-call-keeps-the-elapsed-bound`
  (one POST under a 0.1 s bound, and the stop names it),
  `harness-openrouter-transport-two-requests-do-not-share-a-budget`
  (a step and a recap in flight together, each refused on its own),
  `harness-openrouter-a-disabled-policy-does-not-hand-a-request-on`,
  `-a-removed-policy-does-not-hand-a-request-on` and
  `-a-lowered-policy-does-not-hand-a-request-on` (a 402 with the
  policy edited mid-request: zero sends to the other provider, the
  session keeps its model, one POST);
- `harness-retry-a-retried-step-keeps-one-request-budget`: the step
  after a retry carries count 2 and the clock the first send started,
  and the session keeps no state at all;
- `harness-retry-two-requests-of-one-session-do-not-share-a-budget`:
  two requests of one session, each with its own count and clock.
- `harness-provider-openai-a-counted-session-gets-no-lower-replay` and
  `harness-provider-openai-a-dialects-failure-kind-is-used`: the
  transport asks the shared layer, and a dialect's kind is used, or
  ignored when it answers nil or fails, without changing how a request
  is sent.
- `harness-provider-openrouter-output-bound-test.el`: a routed request
  carries its own `:max-tokens` or none, the generic ceiling cuts
  larger and missing limits when set and does nothing when nil, and a
  cut tool call is reported as `(:raw …)`, not invented.

The jitter regression and the shared bounds are in
`harness-retry-test.el`; the round trip through the real HTTP layer is
in the wire suite; the plain-provider coverage is in both the OpenAI
suite and the wire suite's "what must not change" section.

## The second revision: whose request is it?

Noah's direction, in his words: *"The simplest fix is to bind the
routing policy to the request when it starts, so every retry or
fallback keeps the same restrictions. If the policy changes mid-wait,
the request can stop and start fresh under the new rules, rather than
silently dropping the old restrictions. It's local to one request,
nothing complicated."*

The first revision above kept one attempt budget **per session**, and
read the policy **in force** at each send.  Both were wrong for the
same reason: a session is not a request.  Three failures were
reproduced against the hand-in that preceded this revision:

1. **A small call lost its restrictions.**  `harness-small-ask` has its
   own retry loop (a recap or a name has no `agent/step-error`), and it
   never marked the session's budget `retrying`, so
   `--withdrawn-refusal` -- which asked "is a retry pending for this
   session?" -- did not see it.  A recap of a DeepInfra-pinned session
   whose policy was removed during its wait sent its second POST with
   **no `provider` object at all**: the same conversation, unrestricted,
   to whatever endpoint OpenRouter chose.  Two POSTs, one restricted and
   one not.
2. **A disabled policy permitted fallback after an in-flight 402.**
   `--guard` asked whether the policy was *enabled now*.  Disabling it
   mid-request therefore read as "not governed any more", and the
   fallback moved the session to `other-provider:other-model` -- after
   the request had already been disclosed to the pinned endpoint.  A
   disabled policy is documented as a *refusal*; it is not permission.
3. **A small call bypassed the elapsed bound.**  `harness-retry-send`
   keyed its budget by session and saw "no retry pending" on the small
   call's second send, so it reset the clock.  With
   `harness-retry-max-seconds` 0.1 the pair took 1.14 s and made two
   POSTs: a new request after the deadline, not merely an in-flight
   call finishing late.

**What the change decides.**  The budget and the authorisation belong
to the *logical request*, and travel with it:

- `harness-retry--request` is a struct carried on the request plist
  under `harness-retry--request-key`: `count`, `since`, `retrying` and
  `authority`.  A fresh request carries none; `harness-retry-send`
  returns the request carrying the state it counted, and the provider
  sends *that*;
- the transport hands the state back in the request's `done` event
  (`harness-retry--carry` in `harness-provider-openai`), so the layer
  above sees what the failed attempt spent and what authorised it.  No
  event of an ordinary request changes;
- `harness-retry-attempt-plan` is the one decision, for a step and for
  a small call alike: it takes the attempt and the elapsed time the
  caller read from the request, and returns `:retry`, `:delay`,
  `:reason`, `:state` and `:final`.  `harness-small-ask` calls it
  instead of its own comparison, so a small call and a step are bounded
  by one set of numbers read at one place;
- `harness-agent` puts the decided `:state` on the turn and the next
  step sends it (`harness-agent-turn-retry`), which is how a retried
  step continues its request instead of starting another; the state is
  stripped from the payload kept for a cache refresh, so resending a
  payload is a new request and spends nothing of the failed one's;
- `harness-retry-authorise` records what the provider checked
  (`:policy`, `:route`) in the same state.  A repeat is judged against
  **that** (`--resend-refusal`), never against the policy of the
  moment: an edit, a disable or a removal refuses the repeat with
  `policy-changed`, and the next request a session starts afresh is the
  one that sees the new policy.  Re-selecting for a repeat is exactly
  the silent switch the policy exists to prevent;
- the pinned endpoint a repeat goes to is the one recorded in the
  authority, not the session's pin of the moment -- so a hand switch
  starts a fresh request rather than re-pointing one already sent;
- `--guard` takes the failure as an optional fourth argument
  (`harness-fallback-guard-functions` passes it) and refuses a move
  whenever the failed request carries an authority, whatever a policy
  configured *now* says.  A disabled or removed policy cannot disclose
  a request that was already sent under it;
- nothing is kept by session.  `harness-retry-budget`,
  `harness-retry-budget-start`, `harness-retry-pending-p` and the
  `harness-retry--budgets` table are gone; the only per-session table
  left is the per-turn tally an **uncounted** provider uses, and it is
  no longer written for a counted one.

**Why not a session-shaped flag with a serial.**  The task's own review
asked for "the smallest request-local design" and warned against "a
session-only mutable pending flag being consumed/reset by a concurrent
naming/recap call".  A per-session table with a request id would still
be one mutable cell two requests write to; carrying the state on the
request is smaller, and it is the shape the request already has (a
plist that travels from the caller through the transport and back).

**Rollback is not a widening.**  `nil` policy is still the legacy
pass-through for a request started under it, and the documented way to
stop governed traffic.  What changed is that a request *already sent*
under a policy does not become ungoverned when the policy is removed:
its repeat is refused (`--withdrawn-refusal`), its fallback is refused,
and the next request -- a new one -- is the plain provider again.

## Failures seen while verifying

The second revision's runs: every suite this change touches passed on
the committed tree (retry 21, small 12, the three OpenRouter suites
75/10/16, the output-bound suite 3, fallback 28, OpenAI 52 plus 2 live
skips, agent 102, cache-warm 37).  `scripts/test.sh` on the committed
tree passed 216 suites with none failed, `scripts/test.sh --status`
reports `PASS (full, 216 suites, 0 failed)` against that commit, and
`scripts/lint.sh` exits 0 with no warning from any file this change
touches.  One flake was found and fixed rather than explained: a
time-bound test asserted the exact second an attempt took, which is
machine-dependent under a parallel run, and now asserts that it is past
the bound.

`scripts/module-docs.sh --check` still reports the pre-existing drift in
`speech.md` and five `ui-*.md` pages (identical on `main` without this
change); the three pages this change alters -- `retry.md`,
`provider-openrouter.md` and `agent.md` -- are regenerated and
committed.

Earlier runs (the first revision), recorded as they happened rather than
assumed away:

- `harness-skills-scan-test.el` (`bounds-what-it-lists`) failed in the
  first full run on the final commit.  Re-run alone on the same clean
  tree it passes 10/10: the test lists the home directory's skills and
  the count moves with what else is installed, so it is not a
  regression from this change.  A later run of the same suite on the
  same tree failed and a third passed, so it is load- or
  environment-sensitive, not stable evidence either way.

  **Corrected later; both explanations above are wrong.**  The test
  builds its own temporary root and lists nothing of the home
  directory, so what else is installed cannot move it.  It failed
  because `harness-skills-scan-files` applied its file-count and byte
  bounds in `directory-files` (readdir) order, which is creation order
  on tmpfs and a hash order on ext4, so which files survived the bound
  depended on the filesystem.  It is not load-sensitive and not
  environment-sensitive in the sense of a flaky test: on an ext4
  `TMPDIR` it failed 12 of 12 runs, and the same tree with `TMPDIR` on
  `/dev/shm` passed.  Fixed by taking the bounds in name order; see
  [skill-file-bounds-in-name-order.md](skill-file-bounds-in-name-order.md)
  and `docs/evidence/skill-file-bounds/`.  The "216 suites with none
  failed" run above is reproducible only where readdir happens to
  return creation order.
- `harness-ui-chat-test.el`
  (`header-counts-tokens-as-they-stream`) and
  `harness-ui-pet-test.el` (`board-recaps-its-tasks`) failed in the
  second full run and both pass 282/282 and 56/56 when re-run alone.
- `harness-update-test.el`
  (`plugin-fast-forwards-its-own-checkout`) failed in the same run and
  passes 51/51 alone.
- `scripts/module-docs.sh --check` reports drift for `README.md`,
  `speech.md` and the `ui-*.md` pages.  The `ui-*.md` pages and
  `speech.md` differ on a tree without this change too (they are
  pre-existing drift on `main`); `README.md` differs because this
  change adds `harness-retry-policy-functions` and removes this
  module's `agent/step-error` filter, and that row is committed.  The
  other six generated pages are left as `main` has them.
