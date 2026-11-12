# Price-aware OpenRouter endpoint pinning

This document is the design for `harness-provider-openrouter.el`: a
provider module that owns everything OpenRouter-specific, and an
opt-in policy that chooses one exact endpoint for one exact model per
session and keeps every request of that session on it.  It ships
**disabled**: `harness-openrouter-routing` is nil by default, and a
configured policy that is not `:enabled` sends nothing at all.

No live activation is part of this change.  The concrete values a
policy needs (the owner price, each endpoint's privacy evidence, the
limits) are left for Noah to approve; this document says which ones and
why.

## The problem

Noah wants DeepSeek's `deepseek/deepseek-v4.1-flash-1017` served by one
provider per session, chosen by price, so the provider's prompt cache
stays warm.  OpenRouter's default routing picks a provider per request
and may fall back to another one; its `order` preference is a hint that
still permits fallbacks.  Either behaviour can move a session between
providers mid-conversation and lose the cache.

The price rule Noah asked for, in his words: *"sort by increasing
price, filter out anything greater than deepseek platform's official
price. only allow vetted providers and have deepinfra and cohere rn."*

Two constraints sharpen that into something safe to ship:

- A wrong provider is worse than a stopped session.  Unknown, stale or
  malformed price evidence must **block**, never fall through to the
  next provider.  Falling through is the silent switch the policy
  exists to prevent.
- A switch starts a cache-cold conversation.  So a switch is the
  user's decision, never the router's.

## The decision

### 1. Boundary: a separate module over the shared transport

`lisp/modules/harness-provider-openrouter.el` owns OpenRouter's request
fields (`provider`, `service_tier`, `session_id`, `usage.include`, the
`reasoning` object, `max_tokens`), its error metadata, its answer
audit and the routing policy.  `harness-provider-openai.el` stays the
generic OpenAI-compatible transport and knows none of those names.

The seam is a `:dialect` plist the generic module reads from an
endpoint, with hooks for headers, extra body fields, the stream chunk
reader, the error-detail reader, the response audit and the state an
answer reports.  A provider module fills it in; the transport calls it.
Nothing OpenRouter-specific is a `(if (eq id 'openrouter) ...)` branch
inside the generic module — there is no such branch left, and the
generic module's own tests assert that a plain OpenAI endpoint and a
custom compatible endpoint are sent the body they were always sent.

The generic transport also gained two things the policy needs and that
belong to no one provider:

- `harness-fallback-guard-functions`, a hook a module can add to so that
  a session whose model is pinned on purpose cannot be moved by
  `harness-fallback`.  It is a `defvar`, not a `defcustom`: no user
  setting may quietly drop a guard.  `harness-fallback--switch`,
  `harness-fallback--before-turn` and `harness-fallback--step-error` all
  ask it, and `fallback/refused` records what a guard kept from
  happening.
- The `:final` flag of a stop decision, which ends the
  `agent/step-error` chain where the decision is made, so a module
  loaded later cannot turn a permanent rejection into a retry whatever
  priority number it registered with.

This avoids a second HTTP/SSE/streaming stack: there is one transport,
one parser, one tool loop.  The OpenRouter module is a dialect over it
plus the policy, and it enforces its own retry bounds in front of the
generic retry.

Ownership: `harness-openai-claim-endpoint` records that this module
registers `openrouter`, so the generic module's
`harness-openai--register-all` skips it.  OpenRouter is no longer in
`harness-openai-endpoints`'s default and no longer in the generic
key-needed host list; the dialect's `:key-needed` flag replaces that.

### 2. The policy shape

`harness-openrouter-routing`, a plist, nil by default:

| Key | Meaning |
| --- | --- |
| `:enabled` | `t` to route. A configured policy without it sends nothing. |
| `:model` | the exact checkpoint, `deepseek/deepseek-v4.1-flash-1017`. Only `openrouter:MODEL` is routed. |
| `:owner-price` | DeepSeek's own published platform rate: `(:prompt N :completion N :cache-read N)` in USD per million tokens, plus `:source`, `:read-at`, `:max-age`. It is the ceiling. An optional `:request` bounds a per-request fee. |
| `:endpoints` | the vetted allowlist, each with `:key`, `:slug` (exact tag), `:provider`, `:tag`, `:tier`, `:quantization`, `:host` and its own `:evidence`. |
| `:freshness` | seconds a catalogue reading may be old at dispatch. |
| `:privacy` | what every endpoint's evidence must establish: `:no-training t`, `:retention "zero"`, `:zdr-eligible t`, `:safety-retention :excluded` or `:allowed`, `:regions`. |
| `:retry` | `:max-attempts`, `:max-seconds`, `:max-output-tokens` for the same endpoint. |

Every field a check reads must be present and well formed.  A policy
with a hole blocks and says which hole; it never guesses.

### 3. Selection: filter, then cheapest

Selection is a filter and a sort, and nothing else:

1. Candidates are exactly the policy's `:endpoints`.  An endpoint the
   policy does not name is never considered, however cheap the
   catalogue says it is — this is what "only vetted providers" means
   mechanically.
2. A candidate is dropped when its fresh catalogue listing is dearer
   than `:owner-price` in **any** priced component (prompt,
   completion, cache-read).  The owner price is the most the policy
   pays: DeepSeek's own rate for the checkpoint.  A listing that prices
   a component this module cannot weigh (a cache write, a per-request
   fee, an image) blocks rather than being dropped: the ceiling does not
   bound what it would charge.
3. The cheapest survivor is chosen.  The sort key is
   `prompt + completion` per token (one input and one output token in
   the same unit, so the ordering needs no guess at the traffic mix),
   then cache-read, then the endpoint key so the order is total.
4. A candidate whose listing **cannot be read** — absent, ambiguous,
   another model, another provider name, another tier, a missing or
   malformed price, a price that varies by the time of the week, a stale
   reading, a stale owner price, an endpoint the catalogue marks
   unavailable — blocks the whole decision rather than being dropped.
   "Cannot read this price" is not "this price is too high", and
   dropping it would quietly choose the next provider.

**Why the live catalogue forced the last two rules.**  The listing for
this checkpoint, read on 2026-11-10, has both shapes in it:

- DeepInfra's `deepinfra/fp8` shows `prompt 0.098`, `completion 0.294`,
  `cache-read 0.00294` per million with `discount: 0.51`.  The listed
  figure is already the discounted, promotional rate: at the 51%
  discount those are 0.2, 0.6 and 0.006 list.  So the promo is read by
  sorting, with no promo-specific code — when the discount ends the
  listing shows the list rate and the sort changes its mind.
- Two entries for this model price by the clock, with `pricing
  .overrides`: DeepSeek's own endpoint (peak and off-peak, and off-peak
  at weekends) and Alibaba's.  Neither is on the allowlist, but the
  shape is not exotic, so a windowed listing is refused as unreadable
  rather than read as its top-level rate.  The top-level figure is only
  the rate outside the windows.

Noah's stated order falls out of the sort with no provider named as
first.  Using the catalogue's own figures and the peak owner price:

| listing | prompt | completion | sort (p + c) | outcome |
| --- | --- | --- | --- | --- |
| `deepinfra/fp8` now (51% off) | 0.098 | 0.294 | 0.392 | chosen |
| `deepinfra/fp8` at list | 0.200 | 0.600 | 0.800 | dropped behind Cohere |
| `cohere/fp8` | 0.150 | 0.500 | 0.650 | second, and first when the promo ends |

All three are under DeepSeek's peak rate, so none is filtered by price;
the promo ending changes only which survivor is cheapest.

`demo/openrouter-pinning/demo.sh` prints these decisions, plus the two
pinned-session refusals below, from the live catalogue or offline from a
stock one.

### 4. A pinned session: revalidated on every dispatch, never moved

Selection happens for a new session only.  A pinned session runs
`harness-openrouter--pin-refusal` before every dispatch, and again at
the moment the body is built (`harness-openrouter--dispatch`), so a
policy edited, an owner price expired or an endpoint's evidence that
lapsed in between stops the request instead of slipping through.  The
checks are, in order:

1. the policy is still complete and valid;
2. the request's model is the policy's exact model;
3. the pin's endpoint key is still on the allowlist, and its slug,
   provider, tier and quantization still match that entry;
4. the owner price is still inside its `:max-age`;
5. the price the pin recorded is not over the **current** ceiling — a
   ceiling lowered under a fresh pin stops it;
6. the endpoint still carries its own complete privacy evidence, and
   that evidence is inside its own `:max-age`;
7. the pin's catalogue reading is still inside `:freshness`.  When it is
   not, the catalogue is read again and the pin is rechecked against
   that fresh reading: it must still be exactly listed there, once, at
   no component dearer than the owner price and with no unpriceable
   component.  A refresh that yields an empty list is
   `catalogue-empty` — not "no refresh"; a fetch that fails is
   `catalogue-unavailable`.  Neither dispatches.

A stale reading being refreshed is not a switch: the endpoint stays the
same, and only a failure to re-qualify stops the request.  A refusal
sends nothing and leaves a hint and an `openrouter/route-paused` event.
Nothing is ever reselected: a switch is `harness-openrouter-switch`,
which refuses while the session has a turn at work, verifies the target
endpoint as a new session would (policy, evidence, exact identity in a
fresh catalogue, price under the current ceiling), and records the
route as `switched` with the reason.

A session the policy routes is also guarded from `harness-fallback`, at
both its before-turn and its step-error paths, including budget, quota
and exhaustion: the turn stops with a refusal naming the pin and
`harness-openrouter-switch`, rather than moving to another model.  This
is distinct from a switch by hand, which is the only way the vetted set
changes and never relaxes it.

### 5. Exact prices, no floats

Catalogue prices are decimal strings in USD **per token**; a policy's
owner price is in USD per **million** tokens.  A float has no exact
0.098, so comparing through one puts rounding at the boundary and a
ceiling can end up under the price it was meant to admit.  Every price
here is therefore read as an exact decimal — a numerator over a power of
ten, both exact integers — and every comparison cross-multiplies.  The
owner price's division into per-token prices is exact too, so nothing
is rounded in either direction and a ceiling never grows upward into
accepting a price above it.

Precision is bounded, not guessed at: text longer than 80 characters,
more than 40 fractional places or an exponent larger than 40 is refused
as unreadable, which blocks.  A float is read as the decimal it prints
as, because that is the number the policy's author wrote.  A missing
price stays nil — unknown, never zero, because a zero cache price would
always look cheapest.

### 6. The pin on the wire

For a routed request the body carries a `provider` object with
`only: [SLUG]`, `order: [SLUG]`, `allow_fallbacks: false`,
`require_parameters: true`, `data_collection: "deny"`, `zdr: true` and,
when the policy bounds them, `max_price` with `prompt` and `completion`
in USD per million — and `request` only when the policy's owner price
and the recorded endpoint both carry a per-request fee.  `max_price` is
a second defence at the router, not the only one: it covers prompt and
completion, OpenRouter documents no cache-read cap, so the cache-read
price is compared here and is never assumed to be protected by the wire
field.  A per-request or cache-write component the ceiling does not
cover blocks at selection.

`service_tier: "default"` keeps a priority endpoint off the traffic, and
`session_id` is the harness session id as OpenRouter's sticky hint.  The
hint is not proof of a cache hit — the pin is the `provider` object —
and this document does not claim cache-hit reliability from it.

The pin is stored in the session's `ext` under `:openrouter-route`.
`session/fork` does not copy `ext`, so a fork starts unpinned and
chooses for itself.

### 7. Exact endpoint identity

OpenRouter's documented slug is `provider[/variant][/region][/tier]`,
and a slug without the trailing segments matches **every** endpoint that
shares the prefix (except that dropping the tier never matches a tier
endpoint).  `deepinfra/fp8` would therefore also select a new
`deepinfra/fp8/us` the day one appears, which is a regional variant
joining the vetted set silently.

`harness-openrouter--match-set` applies that matching rule to the fresh
catalogue and `harness-openrouter--matching` accepts only an exact
singleton: one record, whose tag equals the slug and whose provider,
tier and quantization are the vetted ones.  Two records — a new region
or variant — make the identity ambiguous and block.  A slug whose last
segment is a tier name (`priority`, `fast`, `turbo`, `flex`,
`ultrafast`, `highspeed`, `prime`) or whose record carries a
`service_tier` is a tier endpoint and is never picked by a standard
slug.

### 8. Post-response audit

The answer must name the model that was asked for; when it says which
provider served it, that must be the pinned provider; a service tier it
reports must be the default one; when both the pin and the answer name a
region, they must agree; and a routing summary that names a selected
endpoint must agree on provider and model.  With the metadata header
sent, an answer that names no provider is a failure of the required
evidence and is refused rather than assumed to be the pin.  A mismatch
leaves `openrouter/response-mismatch`.

What the API does **not** give is stated rather than assumed: the
streamed answer names no endpoint tag, and the routing summary names a
provider and a model, not a tag.  So a same-provider regional variant
cannot be told from the pinned one by the answer alone.  That is exactly
why the pin refuses an ambiguous slug and sends `only` with the exact
slug plus `allow_fallbacks: false`; the audit is a second check, not
proof of identity.

### 9. Privacy: one requirement, per-endpoint evidence

`:privacy` is what the policy requires; each endpoint's `:evidence` is
what was read about that exact endpoint, with `:source`, `:checked-at`
and `:max-age`.  They are compared field by field, and the honest
statement of what each fact proves is:

| fact | what it establishes | what it does not |
| --- | --- | --- |
| `:no-training t` | the operator says prompts are not used for training | nothing about retention |
| `:zdr-eligible t` | the endpoint is eligible for OpenRouter's ZDR routing | that a ZDR request lands there, or that the account's ZDR mode is on |
| `:safety-retention :excluded` | Safety Retention endpoints are not acceptable to this policy | that OpenRouter's account setting agrees |
| `:retention "zero"` | the operator states no request or response is kept after processing | that a short abuse window does not exist |
| `:regions ("US")` | the operator states processing or hosting there | which country served a given request |

OpenRouter's own documentation says `zdr: true` restricts routing to ZDR
endpoints **and** to Safety Retention endpoints when the account's
privacy settings or guardrails allow them.  So `zdr: true` alone is not
proof of strict zero retention; the policy says separately whether
Safety Retention is acceptable, and an endpoint whose evidence states
the other answer is refused.  None of this changes an account setting:
the policy is a client-side requirement, and a future activation has to
confirm the account's ZDR and Safety Retention modes separately.

The check fails closed in each direction: an endpoint with no evidence,
another host's evidence, an unknown retention class, a class the policy
does not require, an evidence that is undated or uncited, and one past
its own `:max-age` all block that endpoint.  A policy that is complete
stays a valid policy as its evidence ages; the dispatch is where the age
is checked, and the stop names what to recheck.

### 10. Bounded retry and output

A policy's `:retry` names three bounds, and all three are enforced in
this module's own `agent/step-error` filter at priority 45, ahead of
`harness-fallback` (50) and `harness-retry` (60):

- `:max-attempts` counts attempts of the same endpoint in one turn,
  reset when a turn starts.  The attempt that just failed is counted, so
  a policy of one attempt allows no retry at all.
- `:max-seconds` bounds the elapsed time since the turn's first attempt.
- `:max-output-tokens` bounds what a request asks for.  It is applied at
  dispatch, so a request's own `:max-tokens`, or a resumed session's,
  never sends more than the bound, and a request that asks for less
  keeps its smaller figure.  A request that asks for nothing gets the
  bound, because the model's own default output is far larger.

Missing or malformed bounds make the policy invalid, which sends
nothing.  A transient failure (a transport error, a rate limit, a 5xx, a
timeout, a typed transient code) is retried at the same endpoint while
both bounds allow, and stops with the bound that was reached when they
do not.  A typed permanent code stops at once with `:final`, so no
filter after this one — whatever its priority — can retry it.  A
cancelled request is not retried.  Ordinary OpenAI and custom
OpenAI-compatible endpoints never reach this filter.

### 11. Errors: the OpenInference HTTP 400

The reported failure was `Upstream error from OpenInference: Upstream
returned HTTP 400`.  The saved text retained no typed code and no
provider metadata, so **the cause is unproven**.  OpenRouter documents
`error.metadata.error_type`, `provider_name` and `provider_code`, and the
harness had no reader for them.  The module now appends a content-free
suffix to the stop reason (`error_type=`, `provider=`, `provider_code=`,
`generation=`) and stops on a typed code an identical retry cannot pass
\(`invalid_request` among them) instead of retrying the same request
unchanged.  400 is not by itself evidence that an identical retry
succeeds, and this document does not claim it is.

### 12. Cancellation

A dispatch happens in two phases: reading the catalogue, then the
transport.  Both share one mutable state, and the cancel handle marks it
and reaches the transport only when one exists.  So a cancel before the
catalogue resolves, during the transport, or twice, is safe; a callback
that arrives after a cancel sees the flag and emits nothing; and no
completion is dispatched after a cancellation.

## Alternatives considered

- **A branch inside the generic provider.** Rejected: Noah asked for the
  OpenRouter logic to live in its own thing, and a branch would put
  OpenRouter's field names and price policy in the shared transport that
  plain OpenAI and custom endpoints also use.
- **A separate HTTP/streaming stack.** Rejected: duplicate SSE parsing,
  duplicate tool-loop plumbing, two places to fix a transport bug.
- **OpenRouter's own `sort: "price"`.** Rejected: it selects the
  cheapest across every provider in the catalogue — 51 endpoints here,
  including unvetted ones — and may fall back.  The policy's allowlist
  and the owner-price filter are the point.
- **Let OpenRouter choose and only record what it chose.** Rejected:
  that is the silent switch and the cache loss.
- **Rely on `max_price` alone.** Rejected: it covers prompt and
  completion, not cache reads, and a request-level cap is not a vetted
  allowlist.  It is sent as a second defence.
- **Rely on `zdr: true` for retention.** Rejected: OpenRouter documents
  that it can include Safety Retention, so the policy checks the
  retention class and the Safety Retention standing separately.
- **Keep the earlier "preferred order + promo rule" selection.** Replaced
  by Noah's instruction: sort by increasing price and filter at
  DeepSeek's own official price.  The promo-discount reading is gone; the
  catalogue's prices already reflect it.
- **Switch automatically when a pin stops qualifying.** Rejected: a
  switch is cache-cold and is the user's decision.
- **Reuse `harness-retry`'s counters for the policy's bounds.** Rejected:
  the policy's bounds are its own, and a test that changes
  `harness-retry-max-attempts` must not change them.

## What this does not establish

- No paid provider smoke test was run and no live activation was
  performed.  Everything here is offline with a fake HTTP layer.  A mock
  proves the client boundary, not OpenRouter's behaviour.
- No cache-hit rate is claimed.  `session_id` is a hint; only a live run
  can measure hits, and a prompt below the provider's minimum cacheable
  length is not cached at all.
- No geographic or sovereignty compliance is claimed.  What the public
  sources do not publish stays unknown: no per-request country of
  processing is established for either vetted endpoint.
- No claim that OpenRouter's account-level ZDR or Safety Retention mode
  matches the policy.  That is a settings fact, not a client-side one,
  and it is checked before any activation.
- The response audit cannot prove a same-provider regional variant apart;
  see 8.

## Open decisions for Noah

1. **The owner price.** The ceiling is DeepSeek's own published platform
   rate for `DeepSeek-V4.1-Flash-1017`, read from
   <https://api-docs.deepseek.com/quick_start/pricing> on 2026-11-10:
   peak \$0.30 input / \$1.20 output / \$0.006 cache-hit per million;
   off-peak exactly half (off-peak is every hour outside 01:00–04:00 and
   06:00–10:00 UTC on weekdays, weekends and Chinese public holidays
   included).  Which figure caps the policy — peak, or the off-peak rate
   in force at the time of the request?  The module takes one number and
   does not read DeepSeek's clock, so this is **not resolved here**.  The
   conservative choice is the **peak** rate, which never pays more than
   DeepSeek ever charges and still admits both vetted endpoints:

   | endpoint | prompt | completion | cache-read | under peak cap |
   | --- | --- | --- | --- | --- |
   | `deepinfra/fp8` | 0.098 | 0.294 | 0.00294 | yes |
   | `cohere/fp8` | 0.15 | 0.50 | 0.003 | yes |

   Both fit, so the sort decides: DeepInfra is cheaper and wins while its
   promotional rate stands.  If DeepInfra's price rises above DeepSeek's
   peak rate, Cohere is chosen; if both are above it, the session pauses.

2. **Each endpoint's privacy evidence.** The policy requires
   machine-checkable facts, and one endpoint's evidence never covers
   another's.  What the public sources establish, as of 2026-11-10:

   - **DeepInfra** (<https://docs.deepinfra.com/account/data-privacy>):
     input and output are not stored to disk, only held in memory during
     inference; no training on submitted data; no sharing with third
     parties; request content is not logged.  Its own exceptions are
     Google and Anthropic models, which this model is not.  Its
     `bulk inference APIs` may store encrypted data for a short retention
     period, so the policy must stay on the non-bulk path.  **Locations:**
     US facilities in Washington, Utah, Georgia, Oregon and California,
     plus a Toronto, Canada facility — per press coverage, not per a
     published per-region API contract.  There is **no** published
     per-request region selector, so a DeepInfra request cannot be pinned
     to a country.
   - **Cohere** (<https://docs.cohere.com/docs/model-vault/regions>):
     Model Vault offers US, EU and Canada regions, and Zero Data
     Retention means prompts and responses are not retained after a
     request completes.  That region control belongs to **Model Vault**,
     not necessarily to Cohere's OpenRouter endpoint, so a routed request
     cannot be shown to land in the EU or Canada.  Cohere's OpenRouter
     documentation says Cohere serves its own models on OpenRouter and
     forwards requests to the Cohere API; it says nothing about region or
     retention for that path.
   - **OpenRouter** itself sits between the client and both providers,
     and its `zdr` documentation says the per-request flag can include
     Safety Retention endpoints when the account or guardrail allows
     them.  Its account-wide setting, not this policy, is what decides
     that.

   So the values are Noah's to write from his own reading, not this
   document's.  What is established is: no training and no request-content
   logging for DeepInfra; ZDR as a per-request control whose exact
   meaning depends on the account.  What is **not** established: a
   per-request country of processing for either endpoint, and Cohere's
   retention behaviour on the OpenRouter path specifically.  A policy
   whose `:regions` list claims more than that would be claiming
   compliance the evidence does not support.  Anything unproven stays
   unknown, and an unknown blocks the endpoint.

   **What the pages say, quoted.**  Read again on 2026-11-10, so a
   reader can check the policy against them without trusting this
   summary:

   | source | states | does not state |
   | --- | --- | --- |
   | DeepInfra, Data Privacy | input not stored to disk, memory only during inference, deleted after; output sent then deleted; no training and no third-party sharing outside the Google/Anthropic models; request content not logged, only metadata (request ID, cost, sampling parameters); bulk inference may store encrypted data for a short retention period | any per-request region selector, or which country served a request |
   | DeepInfra, Subprocessors (updated 2024-09-06) | Stripe for payments; **AWS and Google Cloud as infrastructure** — so the compute sits on US hyperscalers whatever DeepInfra's own facilities are | a country for a given inference request |
   | Cohere, Model Vault / Regions | region chosen when a vault is created, prompts and responses processed there, region cannot be changed after creation; US, EU and Canada regions; the **Encrypted** vault runs only in the US, with EU and Canada "coming soon"; Zero Data Retention means prompts and responses are not kept after a request completes | that Model Vault's region control extends to Cohere's OpenRouter endpoint |
   | OpenRouter, provider routing | `data_collection: "deny"` and `zdr: true` are per-request controls; `zdr: true` may include Safety Retention endpoints unless the account or guardrail is set to ZDR only; a full slug may carry a region segment (`baseten/fp4/us`) when a provider serves one variant from several regions | which region a request took, that either vetted endpoint has a regional slug for this model, or the account's own ZDR mode |
   | OpenRouter, prompt caching | provider sticky routing follows a cached request; sticky routing is not used when `provider.order` is set; DeepSeek caching is automatic, cache reads at 0.1x input; prompts below a model's minimum cacheable length are not cached | that a given short prompt was cached or reused |

3. **The bounded limits.** Freshness, evidence max-age, retry bounds and
   catalogue TTL are all policy values with no shipped default.  The
   module's own defaults are mechanical only: a 60 s catalogue cache TTL
   and a 20 s fetch timeout.

4. **An activation snippet, written but inactive.** See the
   [inactive configuration example](#inactive-configuration-example)
   below: a complete policy with `:enabled nil`, so loading it changes
   nothing until Noah turns it on after reading the values.

5. **A bounded smoke plan.** For later approval, **not run here**.  It is
   scoped to fit the smallest useful measurement:

   | bound | proposal |
   | --- | --- |
   | requests | 6 completions, 1 catalogue read per turn, no retries |
   | tokens | 1 priming turn of ~4,000 input tokens (over DeepSeek's minimum cacheable length), 3 one-token follow-ups, `max_tokens` 16 |
   | retries | 0: a failed step ends the smoke run and is reported |
   | concurrency | 1 session, 1 request at a time |
   | maximum dollars | ≤ \$0.02 at the peak owner price; stop if it is exceeded |
   | rollback | set `harness-openrouter-routing` to nil and reload the module |

   The steps: (a) with the policy disabled, confirm OpenRouter still
   sends its old body; (b) with the policy enabled for one scratch
   session, send the priming turn and confirm the response names the
   pinned provider, and that the OpenRouter activity log's generation
   names the same one; (c) send three one-token follow-ups and confirm
   each is served by the same provider, reading OpenRouter's own cache
   accounting rather than assuming reuse — a single one-token pair does
   not establish it, which is why the priming turn is long enough to be
   cacheable and the reads are read off the log; (d) confirm the summed
   cost in the activity log is at or under the owner price.  Any step
   that stops instead of answering is evidence the guard works, not a
   failure to hide.

## Inactive configuration example

This is the policy as it would be written for this checkpoint, with
`:enabled nil`: a configured policy that routes nothing and sends
nothing.  The owner price is DeepSeek's peak rate, the conservative
ceiling from open decision 1.  The privacy values are placeholders that
say only what the public sources establish; the `TODO`s mark the values
Noah must set from his own reading before enabling it, and an endpoint
whose evidence is missing or expired blocks that endpoint rather than
guessing.

```elisp
(setq harness-openrouter-routing
      '(:enabled nil                      ; t after reading the TODOs below
        :model "deepseek/deepseek-v4.1-flash-1017"
        :owner-price (:prompt 0.30 :completion 1.20 :cache-read 0.006
                      :source "https://api-docs.deepseek.com/quick_start/pricing"
                      :read-at 0.0        ; the time Noah read that page
                      :max-age 604800)    ; re-read it weekly
        :endpoints ((:key "deepinfra-standard" :slug "deepinfra/fp8"
                     :tag "deepinfra/fp8" :provider "DeepInfra"
                     :host "deepinfra.com" :quantization "fp8"
                     :evidence (:no-training t
                                :retention "zero"
                                :zdr-eligible t
                                :safety-retention :excluded
                                :regions ("US")  ; TODO: only what is established
                                :host "deepinfra.com"
                                :checked-at 0.0  ; TODO: when Noah checked it
                                :source "https://docs.deepinfra.com/account/data-privacy"
                                :max-age 2592000))
                    (:key "cohere-standard" :slug "cohere/fp8"
                     :tag "cohere/fp8" :provider "Cohere"
                     :host "cohere.com" :quantization "fp8"
                     :evidence (:no-training t
                                :retention "zero"
                                :zdr-eligible t
                                :safety-retention :excluded
                                :regions ("US")  ; TODO: Cohere's OpenRouter path
                                :host "cohere.com"
                                :checked-at 0.0  ; TODO: when Noah checked it
                                :source "https://docs.cohere.com/docs/model-vault/regions"
                                :max-age 2592000)))
        :freshness 900                    ; a 15 minute old price is no price
        :privacy (:no-training t
                  :retention "zero"
                  :zdr-eligible t
                  :safety-retention :excluded
                  :regions ("US"))        ; TODO: only what is established
        :retry (:max-attempts 2 :max-seconds 60 :max-output-tokens 4096)))
```

It changes nothing on its own: with `:enabled nil` a request to
`openrouter:deepseek/deepseek-v4.1-flash-1017` stops with `disabled` and
sends no request.

**Rollback is not the same as nil.**  The two states are different and
must not be confused:

- `harness-openrouter-routing` set to **nil** is the legacy
  pass-through: the provider behaves exactly as it did before this
  module had a policy — no `provider` object, no pin, no catalogue
  request — and requests route by OpenRouter's default, across any
  provider it likes.
- A **configured** policy, even one that is complete, is not that: with
  `:enabled nil` it refuses every request and sends nothing.  A
  configured-but-invalid policy refuses too, and says which field is
  missing.

So returning a governed workload to nil hands it back to unrestricted
routing.  To stop a governed session without that, leave the policy
configured and turn `:enabled` off; to return the provider to its old
behaviour deliberately, set the variable to nil and reload.

## Shape of the change

- New: `lisp/modules/harness-provider-openrouter.el` (the dialect, the
  policy, exact prices, catalogue fetch and parse, selection, pin
  storage, per-dispatch revalidation, request fields, stream audit,
  error detail, dispatch, cancellation, switch, bounded retry, the
  fallback guard, module registration).
- New: `lisp/modules/harness-provider-openrouter-test.el`, with
  `harness-provider-openrouter-chain-test.el` and
  `harness-provider-openrouter-output-bound-test.el`.  The suite files
  are split because a suite that starts and stops modules resets the
  bus, which would disturb tests in the same file; the shared fixtures
  are in `harness-provider-openrouter-test-helpers.el`, which defines
  no test.  Each suite runs against a fake HTTP layer; none makes a live
  call.
- Changed: `lisp/modules/harness-provider-openai.el` — the `:dialect`
  hooks, the endpoint-ownership registry, and the removal of every
  OpenRouter branch.  `harness-openai-endpoints` defaults to OpenAI only.
- Changed: `lisp/modules/harness-provider-openai-test.el` — the plain
  OpenAI and custom-endpoint tests keep their old bodies; the OpenRouter
  integration tests now require the new module.
- Changed: `lisp/modules/harness-fallback.el` — the
  `harness-fallback-guard-functions` hook, `harness-fallback-refusal`,
  the `fallback/refused` event, and the guard checks in the switch, the
  before-turn path and the step-error path.
- New: `demo/openrouter-pinning/` — the selector and the pin refusals
  printed from the live catalogue or offline.

Nothing here changes a live configuration, credential, session or model,
and nothing here activates the policy.
