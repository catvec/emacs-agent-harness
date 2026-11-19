# Price-aware OpenRouter endpoint pinning

## Health-aware routing update

New sessions use the configured `:providers` order among healthy,
price-qualified candidates (`DeepInfra`, then `Cohere` in the existing
policy). `:prefer` can explicitly override that order within the allowlist.
Numeric nonzero endpoint status excludes that candidate; it does not
explain why the endpoint is unhealthy. In particular, `-2` is not treated
as proof of an outage. The [endpoint API reference](https://openrouter.ai/docs/api/api-reference/endpoints/list-endpoints)
does not establish that meaning. A missing status remains legacy-compatible, not proof of good health.
Malformed health, unknown identity,
model mismatch and unreadable prices still fail closed, including when
another endpoint looks healthy.

A preliminary pin is not a send. Substantive dispatch evidence is saved
synchronously before transport, separately from ancillary calls. Unknown
legacy evidence is not assumed unsent. Concurrent, interrupted and partial
requests cannot move endpoints automatically; retries retain their original
request authority. An orphaned in-flight marker is not silently cleared.
`session/recover-openrouter-send` requires an idle session, exact token and
proof its local owning process exited; it records recovery and permits only
a deliberate same-pin retry, never automatic movement.

Existing sent sessions only reselect with explicit policy permission:
` :cold-failover (:enabled t :max-input-cost "0.10")` (USD per cold input).
The bound is an example, not an activated setting. Cache model and endpoint
must match, and expiry is conservatively extended from the latest send by
the cache TTL, measured from terminal activity rather than request start. This is recorded as **estimated expiry**, not proof of a
server eviction. The unchanged full wire body's UTF-8 bytes bound ordinary
text input tokens; multimodal input is refused. No compaction, truncation,
model change or replay reset is performed. All original privacy/price
checks remain, and the transition records old endpoint, reason, expiry,
cost bound and time. A warm/unknown cache or uncertain prior send blocks.

This update supersedes the historical cheapest-only and manual-switch-only
selection descriptions below. No configuration or live activation occurs
by applying the source change.

This document is the design for `harness-provider-openrouter.el`: a
provider module that owns everything OpenRouter-specific, and an
opt-in policy that chooses one exact endpoint for one exact model per
session and keeps every request of that session on it.  It ships
**disabled**: `harness-openrouter-routing` is nil by default, and a
configured policy that is not `:enabled` sends nothing at all.

No live activation is part of this change.  The example's maximum
price is now decided (0.15 / 0.60 / 0.003 USD per million, prompt,
completion and cache-read); the freshness bound stays Noah's to set, and
how often and how long a failed request is tried again is not this
policy's at all — it is the shared retry layer's, one setting for every
provider.  Every provider's price is read from OpenRouter's API at the
time of the decision — no price of a provider is written into the
policy.

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
Later, on how the rule is configured: *"here's a list of approved
providers. Here's like my max cost I'm willing to spend on them. And
then it should read in the prices always from the API. There should be
no manual price setting from these providers."*

Three constraints sharpen that into something safe to ship:

- A wrong provider is worse than a stopped session.  Unknown, stale or
  malformed prices must **block**, never fall through to the next
  provider.  Falling through is the silent switch the policy exists to
  prevent.
- A switch starts a cache-cold conversation.  So a switch is the
  user's decision, never the router's.
- The policy is configuration, not a research ledger.  It names who may
  serve the model and what may be spent; it does not restate anyone's
  price list.

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
plus the policy, and it owns no retry machinery of its own: the shared
retry layer (`harness-retry`) decodes, bounds, waits and repeats every
provider's failures, and the policy says only that this provider
authorises and counts each of its own sends (see 10).

Ownership: `harness-openai-claim-endpoint` records that this module
registers `openrouter`, so the generic module's
`harness-openai--register-all` skips it.  OpenRouter is no longer in
`harness-openai-endpoints`'s default and no longer in the generic
key-needed host list; the dialect's `:key-needed` flag replaces that.

### 2. The policy: a short plist

`harness-openrouter-routing`, nil by default:

```elisp
'(:enabled t
  :model "deepseek/deepseek-v4.1-flash-1017"
  :providers ("DeepInfra" "Cohere")
  :max-price (:prompt 0.15 :completion 0.60 :cache-read 0.003)
  :freshness 900)
```

| Key | Meaning |
| --- | --- |
| `:enabled` | `t` to route. A configured policy without it sends nothing. |
| `:model` | the exact checkpoint. Only `openrouter:MODEL` is routed by it. |
| `:providers` | the providers allowed to serve it, by the name the catalogue gives them. The allowlist, not a priority: their order decides nothing. |
| `:max-price` | the most the policy is willing to pay, per component, in USD per million tokens. |
| `:freshness` | seconds a catalogue reading may be old at dispatch. |

There is nothing else in it.  How often a failed request is tried again
and how long it may take is the shared retry layer's
(`harness-retry-max-attempts`, `harness-retry-max-seconds`, see 10), the
same for every provider; what a request asks a model to write is the
request's own `:max-tokens`, optionally bounded for all providers by
`harness-provider-max-output-tokens` (see 10.1).  Neither belongs to a
routing policy, and an older policy that still carries a `:retry` key is
valid and simply has it ignored.

That is the whole schema.  There is no per-endpoint entry, no evidence
record, no source URL or timestamp to maintain, and no price of any
provider: `:max-price` is a **spending limit**, and every price it is
compared with comes from OpenRouter's catalogue read at the time of the
decision.  Where the limits come from is the operator's business — a
comment in `config.el` can say, for example, which published list they
were chosen from, and the harness never reads that.

### 3. Selection: filter, then cheapest

Selection is a filter and a sort, and nothing else:

1. Candidates are the endpoints of the policy's providers.  An endpoint
   of any other provider is never considered, however cheap the
   catalogue says it is — that is what "only allowed providers" means
   mechanically.
2. Each provider must resolve to **exactly one standard endpoint** of
   this model.  A second record of the same provider — a new region, a
   variant — makes the identity ambiguous, and ambiguity blocks; it
   never joins the allowed set silently.  A tier endpoint (`flex`,
   `priority`) is not the standard endpoint the provider's name buys,
   and a provider listed only at a tier endpoint does not resolve.
3. A candidate is dropped when its fresh catalogue listing is dearer
   than `:max-price` in **any** component (prompt, completion,
   cache-read).  `:max-price` is the most the policy pays per component.
   A listing that prices a component the limits cannot bound (a cache
   write, a per-request fee, an image) blocks rather than being dropped:
   the limits do not cover what it would charge.
4. The cheapest survivor is chosen.  The sort key is
   `prompt + completion` per token (one input and one output token in
   the same unit, so the ordering needs no guess at the traffic's mix),
   then cache-read, then the provider name so the order is total.
5. A candidate whose listing **cannot be read** — absent, ambiguous,
   another model, a missing or malformed price, a price that varies by
   the time of the week, a stale reading, an endpoint the catalogue
   marks unavailable — blocks the whole decision rather than being
   dropped.  "Cannot read this price" is not "this price is too high",
   and dropping it would quietly choose the next provider.

**Why the live catalogue forced the last two rules.**  The listing for
this checkpoint, read on 2026-11-10, has both shapes in it:

- DeepInfra's `deepinfra/fp8` shows `prompt 0.098`, `completion 0.294`,
  `cache-read 0.00294` per million with `discount: 0.51`.  The listed
  figure is already the discounted, promotional rate: at the 51%
  discount those are 0.2, 0.6 and 0.006 list.  So the promo needs no
  promo-specific code — the catalogue's own figure is what the filter
  and the sort read, and when the discount ends the listing shows the
  list rate and the same rule reads that instead.
- Two entries for this model price by the clock, with `pricing
  .overrides`: DeepSeek's own endpoint (peak and off-peak, and off-peak
  at weekends) and Alibaba's.  Neither is allowed, but the shape is not
  exotic, so a windowed listing is refused as unreadable rather than
  read as its top-level rate.  The top-level figure is only the rate
  outside the windows.

The provider list is an allowlist only: nothing is named first, and the
example has to read as *cheapest of the two that fit*, not as *DeepInfra
unless it fails*.  Using the catalogue's own figures and the example
limits (0.15 / 0.60 / 0.003 USD per million for prompt, completion and
cache-read):

| listing | prompt | completion | cache-read | outcome |
| --- | --- | --- | --- | --- |
| `deepinfra/fp8` now (51% off) | 0.098 | 0.294 | 0.00294 | inside; sort 0.392; **chosen** |
| `cohere/fp8` | 0.150 | 0.500 | 0.003 | inside (prompt and cache-read exactly at the limit); sort 0.650 |
| `deepinfra/fp8` at list | 0.200 | 0.600 | 0.006 | **dropped**: prompt and cache-read over the limit, completion exactly at it |

Two things follow, and both are properties of the limits rather than of
the list.  While DeepInfra's 51% promo is listed it is the cheaper
survivor, so a new session pins it.  Once the discount ends the listed
rate is over the example limits in two components, so it is not a
candidate at all and the same rule pins Cohere — the second provider by
price, not by position in the list, with no promo code and no priority
order anywhere in the rule.  A price exactly equal to a limit is inside
it, which is why Cohere survives at 0.15 and 0.003.

`demo/openrouter-pinning/demo.sh` prints these decisions, plus the two
pinned-session refusals below, from the live catalogue or offline from a
stock one.

### 4. A pinned session: revalidated on every dispatch, never moved

Selection happens for a new session only.  A pinned session runs
`harness-openrouter--pin-refusal` before every dispatch, and again at
the moment the body is built (`harness-openrouter--dispatch`), so a
policy edited or a price that moved in between stops the request instead
of slipping through.  The checks are, in order:

1. the policy is still complete and valid;
2. the pin's provider is still in `:providers`, and the pin still names
   the model the policy is for;
3. the price the pin recorded is not over the **current** limits — a
   limit lowered under a fresh pin stops it;
4. the pin's catalogue reading is still inside `:freshness`.  When it is
   not, the catalogue is read again and the pin is rechecked against
   that fresh reading: its provider must still resolve to exactly one
   standard endpoint of this model, that endpoint must be the pinned tag
   at the pinned tier, and its current prices must be inside the limits
   with no unpriceable component.  A refresh that yields an empty list
   is `catalogue-empty` — not "no refresh"; a fetch that fails is
   `catalogue-unavailable`.  A fetch that fails while the last
   reading is still inside `:freshness` does not stop the session: it
   runs on that reading and says it did (section 5.1).  A reading outside
   the bound, or no reading at all, still stops it.

   A `catalogue-unavailable` pause names what actually failed, because
   that is the reason the session stopped: the HTTP status and the
   message the provider's body carries (`HTTP 503: upstream
   unavailable`), or the transport's own failure when the request never
   reached the server.  The fetch rejects with
   `harness-http-request-json`'s tagged tuple — `(http-error STATUS
   BODY)` — which is no defined error type, so it is read through
   `harness-error-message` and passed on with `harness-resignal`:
   signalling the tuple as it stands would signal its car and replace
   the whole failure with "Invalid error symbol: http-error".

A stale reading being refreshed is not a switch: the endpoint stays the
same, and only a failure to re-qualify stops the request.  A refusal
sends nothing and leaves a hint and an `openrouter/route-paused` event.
Nothing is ever reselected: a switch is `harness-openrouter-switch`,
given one of the policy's provider names, which refuses while the
session has a turn at work, refuses a provider the policy does not name,
verifies the target as a new session would (exactly one standard
endpoint in a fresh catalogue, price inside the limits), and records the
route as `switched` with the reason.

**The policy is read again at dispatch, and the request is built from
that reading.**  A dispatch has two phases — reading the catalogue,
then sending — and the catalogue may take a moment to answer, so the
policy that chose the endpoint is not necessarily the policy in force
when the answer arrives.  The whole check therefore runs again
immediately before the body is built, against the configured policy as
it is **then**, and the checked policy is the only one the body, its
`provider` restrictions, its `service_tier`, its `max_price`, its
`session_id` and its headers are built from.  A policy that changed
while a request was in flight in any way that decides a request —
disabled, removed, made invalid, pointed at another model, narrowed to
other providers, or given lower limits — refuses that request with
`policy-changed` (`disabled` / `policy-invalid` when that is what it
became) and sends nothing.  It does not send the old request under the
vanished policy, and it does not quietly choose again under the new one:
that would be a fallback to a provider the request's own policy never
authorised.  The next request of the session is prepared afresh under
the new policy, which is then the policy that decides.  A replacement
equal in every field that decides a request is not a change, and
neither is a rewrite of a field this module does not read.

This covers a new session's first pin, a pinned session's refreshed
reading, and the synchronous path, which has the same window between
its checks and the body being built.

A session the policy routes is also guarded from `harness-fallback`, at
both its before-turn and its step-error paths, including budget, quota
and exhaustion: the turn stops with a refusal naming the pin and
`harness-openrouter-switch`, rather than moving to another model.  At
the step-error path the guard is given the failed step's `done` event,
which carries the request's own record of what authorised it — so a
policy disabled or removed while the request was in flight cannot be
read as permission to send it elsewhere.  This is distinct from a switch
by hand, which is the only way the allowed set changes and never relaxes
it.

### 5. Exact prices, no floats

Catalogue prices are decimal strings in USD **per token**; a policy's
`:max-price` is in USD per **million** tokens.  A float has no exact
0.098, so comparing through one puts rounding at the boundary and a
limit can end up under the price it was meant to admit.  Every price
here is therefore read as an exact decimal — a numerator over a power of
ten, both exact integers — and every comparison cross-multiplies.  The
limits' division into per-token prices is exact too, so nothing is
rounded in either direction and a limit never grows upward into
accepting a price above it.

Precision is bounded, not guessed at: text longer than 80 characters,
more than 40 fractional places or an exponent larger than 40 is refused
as unreadable, which blocks.  A float is read as the decimal it prints
as, because that is the number the policy's author wrote.  A missing
price stays nil — unknown, never zero, because a zero cache price would
always look cheapest.

### 5.1 One shared reading per model, refreshed about every 15 minutes

The endpoint catalogue is read once per model, not once per session.  The
reading -- its `:at` and its endpoint records -- is held in one table keyed
by model id (`harness-openrouter--catalogue`), and every session of that
model is answered from it:

- a reading younger than `harness-openrouter-catalogue-ttl` (**900 s**,
  fifteen minutes) answers a new session, a pinned session's
  revalidation, a hand switch and the harness's own small calls -- the
  permission judge above all -- without a request of their own;
- a read that is already in flight is shared by every caller
  (`harness-openrouter--fetching`), so a burst of sessions *and* judges
  costs one request, not one each;
- a reading that settles replaces the previous one, and a failed read
  leaves the previous one in place.

**Nothing a session does forces a read.**  The interval is the whole
refresh policy for ordinary lookups: no session path passes a refresh
flag, and `harness-openrouter--catalogue`'s REFRESH argument is the
*explicit invalidation* path only.  What forces one is
`harness-openrouter-catalogue-invalidate` (section 5.2), which a person
calls when they know a price changed.

**What sharing does not do is widen the freshness bound.**  The
operator's `:freshness` is the tolerance for an old price, and a reading
outside it is never used, however recently it was read.  The interval is
a fetch-saving window; `:freshness` is the price-safety bound, and the
two are separate on purpose.  A reading can be *fresh enough to reuse*
(inside the interval) and still be *too old to decide from* when the
policy's bound is shorter than the interval -- the policy is always asked
separately.  A policy with a bound longer than the interval reuses
readings for as long as its own bound allows, and the interval only
decides when the catalogue is next read.

**Served while revalidating.**  A reading past the interval is not a
reason to make a caller wait.  When the reading is still inside
`:freshness`:

- the caller is answered at once from it, marked `:revalidating`, and the
  shared read that brings it up to date is started *behind* the caller;
- a step of a turn and a one-off judge are treated alike here: both are
  answered from the reading in hand, and a judge starts no read of its
  own, so a judge never spends its budget on the catalogue;
- a step's dispatch says the price was not re-read for it -- an
  `openrouter/catalogue-revalidating` event and a hint naming the age of
  the reading used.  A judge starts no read, so it is not told one is
  running: it is simply answered from the reading, and says nothing.  The
  pin records the reading's own `:at`, so the next dispatch measures
  freshness from the read that produced it.

**Stale-while-revalidate.**  When that background read fails, the last
reading stays in place and the next lookup is answered from it, marked
`:stale`, while the failure episode is live:

- while the reading is still inside `:freshness`, the session runs on it
  and the dispatch says so -- an `openrouter/catalogue-degraded` event and
  a hint naming the failed refresh and the age of the reading used;
- when the reading is outside `:freshness`, or there is no reading at
  all, what happens next depends on what failed (see *An outage is waited
  out* below).  There is no invented reading and no extended bound.

**An outage is waited out; a refusal is not.**  A read that failed
*transiently* -- a connection that never opened, a transfer that stalled
(this is the watchdog's `HTTP 200: request timed out after 20s`, the
failure that stopped nine tasks on 2026-11-17), a 408, 425, 429 or 5xx, a
2xx that was not JSON -- says nothing about the request, the model or the
operator's policy.  So a step of a turn with no reading its policy admits
waits for the episode's own re-reads, bounded by
`harness-openrouter-catalogue-wait` (**180 s**):

- every waiting step joins one wait per model
  (`harness-openrouter--catalogue-waiters`), and the episode's re-read is
  what settles it, so a burst of sessions during an outage costs one read
  and one wait, never one each;
- the reading that settles is what the step then sends on, checked
  against the whole policy as any dispatch is: the pin, the allowlist, the
  recorded price, the freshness bound and the privacy fields.  Waiting
  widens nothing and decides nothing by itself;
- the wait is bounded, and a step still waiting at the bound ends with
  `catalogue-unavailable` and "still unavailable after N s of retrying" --
  fail-closed, with the episode's burst and heartbeat carrying on for the
  next turn;
- a cancelled turn stops waiting at once and sends nothing when a reading
  arrives (`harness-openrouter--catalogue-wait-abandon`), so a cancelled step
  holds no timer and leaves no waiter behind;
- a *refusal* -- a 401, a 403, a 404, a catalogue whose body is an `error`
  object or names no endpoints -- is the catalogue's answer about what was
  asked, and reading again would get it again, so it is never waited for:
  the step ends at once with what the catalogue said;
- a one-off call (`:ephemeral`, the permission judge above all) never
  waits here: it keeps its own short bound
  (`harness-openrouter-catalogue-ephemeral-wait`) and is refused as it was,
  which is a call with no verdict and never a permission.

**A task waits in its queue rather than among the failures.**  Task mode
asks `openrouter/catalogue-hold` the same way it asks `fallback/blocked`
for quota: while the catalogue is *out* -- a transient failure with no
reading inside `:freshness` -- a task whose turn stops is parked, back in
the pending queue with `:return-reason catalogue`, its slot free for the
task behind it and its session, branch and worktree kept.  A reading that
settles starts it again by priority and within the limit
(`openrouter/catalogue-recovered`), told by
`harness-tasks--catalogue-message` why it waited.  A pause stays a pause:
a reading coming back is not the user's resume.  A refusal is not a hold,
so a refused catalogue waits where a failure of the work waits -- in front
of a person, with the status and the message.

**An outage costs one read, not one per caller.**  While a failure
episode is live, an ordinary lookup never adds a read: it is answered
from the reading in hand, or, with nothing inside the bound, from the
failure already found -- or, for a step, from the wait that failure
started.  The episode's own re-reads are the only reads.

**The re-reads are a burst, then a heartbeat.**  A failed read schedules
another in the background: the first
`harness-openrouter-catalogue-retry-attempts` (5) double from
`catalogue-retry-delay` (5 s) to `catalogue-retry-max-delay` (300 s), and
after the burst one slow probe continues at 300 s until a read settles.
A long outage therefore heals itself instead of staying broken until a
person asks, and one request per 300 s is what keeps that probe from
being a storm.  Every attempt of the episode is counted, the probes
included; a read that settles ends the episode and cancels the pending
timer; the timers are cancelled on module shutdown.  The re-reads never
choose, send or answer a session.

**What the sharing does not prove.**  A reused reading is a reading, not
a statement about the price now.  Cached metadata is not evidence that a
provider's current rate is unchanged: it says what the catalogue said at
`:at`, and `:freshness` is the operator's statement of how old a price may
be for a decision.  The wire `max_price` covers prompt and completion
only (section 6), so a reused reading's cache-read price is compared here
and is never assumed to be protected at the router.  No guarantee that a
price is current is made anywhere in this document, and none is implied
by the reuse: the freshness bound is the guarantee, and it is the
operator's to set.

**Status.**  `harness-openrouter-catalogue-status` reports what the
catalogue is -- `absent`, `fresh`, `revalidating` (past the interval, a
fresh one being read), `stale` (an older reading whose refresh failed) or
`expired` (outside the policy's `:freshness`) -- with the reading's age,
its endpoint count, the shared interval, the last failure's text, the
attempts spent, when the next re-read is due and whether a dispatch may
decide from the reading now (`:reading`, `none`/`usable`/`expired`).  It
reports the catalogue, not a decision: whether a reading may be decided
from is `:freshness`, always.

**A one-off call does not spend its budget on the catalogue.**  The
harness's own small calls -- the permission judge above all -- have a
budget that is about the answer they ask for, and a catalogue read that
stalls can outlast it: the transport's watchdog fires at the fetch
timeout plus 5 s (25 s by default), while `harness-perms--auto-timeout'
gives a judge 30 s for the whole call.  A judge that spent that budget
waiting for a catalogue would report no verdict for a reason that was
never about the call it was asked to decide -- and a non-interactive
session denies a call with no verdict, which is how a stalled catalogue
read became a denied tool call.

So a request that carries `:ephemeral' (which `harness-small-ask' keeps
as the caller wrote it) waits at most
`harness-openrouter-catalogue-ephemeral-wait' (5 s) for a reading it
does not already have, and starts no background read of its own.  Past
that it ends with `catalogue-unavailable' and "the endpoint catalogue was
still being read", the read carries on for the next caller, and the
permission chain treats the refusal as it treats any judge that could not
answer: the call stays undecided, and is asked of the user -- or denied
when nobody is there.  Nothing is allowed by the timeout.  A step of a
turn is not `:ephemeral' and waits for its reading as it always did.

**The watchdog's wording is not an HTTP rejection.**  A request that
prints `request timed out after 20s` was ended by the harness's own
watchdog (`harness-http--timed-out`, scheduled at the timeout plus 5 s),
not refused by the server.  When the response had already begun, the
transport reports it as `HTTP 200: request timed out after 20s` -- the
status is the last one received, and the text is the watchdog's.  It is
read as what it is: the transfer stalled, and the catalogue was not read.
A direct, unauthenticated `GET` of
`https://openrouter.ai/api/v1/models/deepseek/deepseek-v4.1-flash-1017/endpoints`
answering 200 with about 55 KB in about 0.1 s proves only that the
endpoint was publicly reachable at that moment; it says nothing about an
earlier attempt, an authenticated one, or one made from another host or
network.

### 5.2 Explicit invalidation is separate from every ordinary lookup

`harness-openrouter-catalogue-invalidate` is the one path that forces a
read.  It drops the model's shared reading, so nothing is decided from
it, bumps a per-model generation, and starts a read at once rather than
waiting for the interval to pass.  It is what a person asks for when they
know a price changed.  With no MODEL it uses the configured policy's.

Three things make it an invalidation and not a retry storm:

- **It does not reset the bound.**  The read it starts is the next
  attempt of the failure episode already running, and keeps the attempts
  it has spent, so the background re-reads stay bounded by
  `harness-openrouter-catalogue-retry-attempts` however often a person
  calls it.
- **A slow read cannot undo it.**  A read that began before the bump
  answers its own callers and is *not* stored over the reading the
  invalidation asked for; the generation is compared when the read
  settles.
- **It cancels a pending retry**, so the timer and the invalidation do not
  both read.

It returns a promise of the reading, which rejects with what failed.  A
catalogue that stays unreachable leaves the episode's burst and heartbeat
running; nothing about the invalidation makes that unbounded.


### 6. The pin on the wire

For a routed request the body carries a `provider` object with
`only: [TAG]`, `order: [TAG]`, `allow_fallbacks: false`,
`require_parameters: true`, `data_collection: "deny"`, `zdr: true` and,
from the policy, `max_price` with `prompt` and `completion` in USD per
million.  `max_price` is a second defence at the router, not the only
one: it covers prompt and completion, OpenRouter documents no cache-read
cap, so the cache-read price is compared here and is never assumed to be
protected by the wire field.  A per-request or cache-write component no
limit covers blocks at selection.

`service_tier: "default"` keeps a priority endpoint off the traffic, and
`session_id` is the harness session id as OpenRouter's sticky hint.  The
hint is not proof of a cache hit — the pin is the `provider` object, and
the `only` list is the exact tag the session was pinned to — and this
document does not claim cache-hit reliability from it.

The privacy controls are always on a routed request: `data_collection:
"deny"` rules out training on the prompt, and `zdr: true` restricts
routing to Zero Data Retention endpoints.  Neither is proof on its own:
OpenRouter documents that `zdr: true` can include Safety Retention
endpoints depending on the account's privacy settings or guardrails, so
"ZDR" here means "an endpoint OpenRouter classifies as ZDR-eligible",
not "nothing is ever retained".  That distinction is stated rather than
collapsed, and no account setting is changed by this module or by its
tests.

The pin is stored in the session's `ext` under `:openrouter-route`.
`session/fork` does not copy `ext`, so a fork starts unpinned and
chooses for itself.

### 7. Exact endpoint identity

The pinned identity is the endpoint's catalogue tag, its provider name
and its service tier, all recorded at selection.  Every dispatch
re-resolves the provider to exactly one standard endpoint and requires
the same tag and tier; a second record of the same provider blocks, as
does a tag that changed.

What the answer can prove is less: OpenRouter's streamed answer names
the model, the provider and the service tier, and the routing summary
can name a region and the endpoints that were available, but not the
endpoint tag.  So a same-provider regional variant cannot be told from
the pinned one by the answer alone.  That is exactly why selection
refuses an ambiguous provider, and the audit is a second check, not
proof of identity.

### 8. Post-response audit

The answer must name the pinned model -- as itself or by the canonical
slug recorded with the pin, never as another model, see below; when it
says which provider served it, that must be the pinned provider; a
service tier it reports must be the default one; when both the pin and
the answer name a region, they must agree; and a routing summary that
names a selected endpoint must agree on provider and model.  With the
metadata header sent, an answer that names no provider is a failure of
the required evidence and is refused rather than assumed to be the pin.
A mismatch leaves `openrouter/response-mismatch`.

**The model is compared by name, and the API names two of them.**  A
response's own top-level `model` field echoes the request; the routing
summary names the model the request *resolved to*, which OpenRouter
calls the canonical slug.  For an aliased model the two strings differ,
and it is not a corner case: 299 of the 431 models listed on 2026-11-12
have an id that is not their `canonical_slug` (`anthropic/claude-fable-5.2`
resolving to `anthropic/claude-fable-5.2-20261109`), and the session
this was found in was pinned to `deepseek/deepseek-v4.1-flash-1017`,
answered as `deepseek/deepseek-v4.1-flash-20261017`.  Comparing those as
strings refused every answer such a session ever got -- the request
*worked*, and the audit failed it afterwards with "the routing summary
names ... as selected, not the pinned ...".

So the pin records the model's canonical slug *beside* the model it
asked for, and the audit accepts a name that is either the one pinned or
the slug recorded for it, and nothing else.  The slug comes from
OpenRouter's own statement about its own model (`canonical_slug` in its
model record); this module infers no rule of its own about how a slug is
spelled -- no date, edition or suffix is parsed anywhere -- so another
snapshot of the same alias (`...-20260910`, a *different* model with a
different canonical slug) is still a mismatch, and so is an unrelated
model.  The slug is read once per model per process and recorded in the
pin rather than re-resolved on every answer: a listing that changed
under a session must not change what that session's pin allows.  A
record that cannot be read leaves the pin with no slug, which makes the
audit accept only the model it asked for -- strict, and never a reason
to refuse a request every other check allowed.

**A pin written before slugs existed is completed, not left to fail.**
The first build that merged this recorded no slug, so the route on every
session pinned by it has none; those sessions are the ones this bug was
found on.  A dispatch of such a pin therefore reads its model's record
once, before sending, records the slug on the pin -- same endpoint, same
policy, same prices, only the evidence made explicit, which is what
`openrouter/route-selected` reports -- and sends the completed route.
The cost is one request, once, per old pin: a pin that already knows its
slug makes no such read, and neither does any later dispatch of one that
was completed.  This belongs at the point the pin is prepared rather
than in the audit: the audit runs on every answer and must stay strict,
and the same rule holds as above -- a record that cannot be read leaves
the pin as it was, accepting only the model it asked for, so an
unreadable record never makes the audit lenient.

The answer's own `model` field is compared the same way, so an answer
that names the resolved slug there too is not refused either.  Comparing
names is not proof of which weights served the request, and this
document does not claim it is.

### 9. Providers, and the geography policy behind them

The allowlist is the operator's authorization policy, and it is
documented here rather than enforced as a data structure.  Noah's
requirement was "not China"; US, Canada and the EU are acceptable.

- **DeepInfra** publishes that it serves all its models, Chinese-origin
  ones included, from US datacenters:
  <https://deepinfra.com/blog/western-open-weight-models-beam-le-chonk>.
- **Cohere's** Trust Center lists its infrastructure as Google Cloud in
  the USA (<https://trustcenter.cohere.com/?format=html>), and its
  privacy policy corroborates US Google Cloud hosting
  (<https://cohere.com/privacy>).  Cohere's Model Vault can be placed in
  US, EU and Canadian regions
  (<https://docs.cohere.com/docs/model-vault/regions>), but that control
  belongs to Model Vault, not to the shared `cohere/fp8` OpenRouter
  endpoint this policy uses: public sources have **not** mapped that
  endpoint's processing, overflow and cache countries.  Model Vault's
  region menu is therefore not evidence about it.
- What the public sources do **not** publish is a per-request country for
  the exact `cohere/fp8` endpoint used for DeepSeek Flash 1017.  Noah
  accepted that as good enough — US, Canadian and EU processing are all
  acceptable to him, and the requirement was never "not China", not
  "US only" ("I'm not gonna sue them. This is Elisp program. It's not a
  contract").  This document records it as an accepted judgement, not an
  established guarantee.
- There is no evidence that this endpoint processes in China.

That is why there is no region field in the policy: the answer is a
short list of providers somebody checked, not a machine-checked
attestation.  The sources are named here so the judgement can be
revisited.

ZDR eligibility is a documented, per-endpoint fact from OpenRouter
itself.  Its public listing at
<https://openrouter.ai/api/v1/endpoints/zdr> classified both exact
default endpoints — `deepinfra/fp8` and `cohere/fp8` for
`deepseek/deepseek-v4.1-flash-1017` — as ZDR with
`safety_retention: false` on 2026-11-10.  The module does not fetch that
listing to gate a request; the request's own `zdr: true` and
`data_collection: "deny"` are what it sends, and the account's privacy
mode is a settings fact to confirm before any activation.

### 10. Retrying is the shared layer's, and this is what it needs

Noah's direction: *"shouldn't some other layer above a provider be
responsible for retrying? … make sure the retry is not provider-specific
and not implemented in [OpenRouter]."*  It was, and it no longer is.

**One owner.**  `harness-retry` (lisp/modules/harness-retry.el) is the
one place a failure is read, bounded, waited out and repeated, for every
provider: its `agent/step-error` filter at priority 60, and the same
functions used by `harness-small` for the harness's own one-off calls.
The numbers are its options, not any provider's:
`harness-retry-max-attempts`, `harness-retry-delay`,
`harness-retry-max-delay`, `harness-retry-jitter` and
`harness-retry-max-seconds`.  A second, provider-owned retry subsystem —
a budget struct, an attempt counter, a time bound, a step-error filter
and its own copy of the backoff — was removed with this revision.  The
module has no `agent/step-error` filter at all.

**What a provider still says.**  A provider that must authorise each of
its sends says so, once, through `harness-retry-policy-functions`.  This
module answers with `(:owner "OpenRouter" :count-sends t)`, and nothing
else: no attempt count, no delay, no deadline.  `:count-sends` means
what it says — the shared layer counts the sends at the dispatch
(`harness-retry-send`) and measures one request from its first send
against `harness-retry-max-seconds` — because a request this policy
governs must be checked again (pin, provider allowlist, recorded price,
fresh catalogue) every time it is sent, which the shared layer cannot do
and does not try to.  A session this policy does not route answers nil,
so it is treated exactly like any other provider's.

**One attempt is one POST.**  An earlier revision enforced the attempt
bound in the `agent/step-error` filter alone, and that was not where
requests were made: the shared transport asked `harness-http-request`
for `:retry t`, so the HTTP layer replayed a failed completion up to
`harness-http-max-retries` (3) times *inside one transport call*, before
any filter saw the failure.  A bound of one attempt therefore produced
as many as four requests, and a replay could be sent after the policy
was disabled, the provider removed or the maximum lowered, because
nothing re-read them inside the transport call.  The measured cost of
that was four POSTs.

Now the shared layer answers how many times the transport may replay a
request (`harness-retry-transport-retries`, asked by
`harness-openai--transport-retry`): 0 for a session whose sends are
counted, which is what this policy's sessions are, and no answer for any
other — so an ordinary provider keeps the transport's own count.  A
governed request is therefore sent once per dispatch, and a retry is a
new dispatch: it is re-authorised, then counted.  Connection resets,
empty replies, DNS and TLS failures and timeouts are one send each.
Plain OpenAI, custom compatible and local endpoints are unchanged, and
so is OpenRouter with no policy configured (see the last two tests in
the wire suite).

**The budget belongs to one request and its retries.**  The state of a
request — how many sends it has made, when its first one started, and
whether the next send repeats it — travels on the request itself
(`harness-retry--request`, `harness-retry--request-key`), and comes back
in its `done` event.  `harness-retry-send` counts a send immediately
before it happens and returns the request carrying the count it made; a
step after a successful one is a new request and starts its own count,
so it is not charged to the previous one.  A recap, a name or a
permission verdict made for the same session is a *different* request
with its own state: it neither spends this one's attempts nor resets its
clock, which a budget keyed by session could not promise.  A failed
request may make its first send and `harness-retry-max-attempts` more
(`harness-retry-max-attempts` 0 is exactly one POST), and the clock
starts at its first send, so a slow attempt's duration counts.

**A small call is bounded like a step.**  The harness's own one-off
calls have no `agent/step-error` to decide their retries, so
`harness-small-ask` calls the same decision (`harness-retry-attempt-plan`)
with the attempt and elapsed time its failed request came back with.
That is what makes a recap's wait count against
`harness-retry-max-seconds` instead of starting a fresh clock, and what
makes its next POST the same request — restricted by what authorised the
one that failed.

**The wait is drawn once, and the value checked is the value waited.**
The reported bug: the provider-owned decision computed a randomised
delay for its time-fit check and computed it again for the wait it
scheduled, so with `harness-retry-delay` 0.9, `harness-retry-jitter`
0.2 and draws of 0 and 999 it admitted a 0.9 s wait under a 1 s bound
and then slept 1.08 s.  `harness-retry-wait-plan` draws once and returns
the delay together with whether that very delay fits; the decision uses
the same value it validated, and a deterministic regression pins it
(`harness-retry-a-jittered-wait-is-checked-as-it-is-spent`, which fails
if the draw happens twice).

**The time bound is checked when the wait is chosen and again when the
retry is sent.**  A retry is scheduled only if its wait can start the
next attempt inside `harness-retry-max-seconds`; a wait longer than what
is left stops the request at once, with the reason, instead of sleeping
first and discovering the expiry at the next send.  With `Retry-After:
3600` and a 1 s bound the turn stops immediately rather than after
`harness-retry-max-delay`.  The bounds are read when the repeat is decided and again at the
send, so a retry that waited through an edit is measured by the
settings in force when it is sent, and refused there if they no longer
allow it.

**A repeat is the request it repeats, under the policy that authorised
it.**  Every send records in the request's own state what checked it —
the policy (`:policy`) and the exact pinned endpoint (`:route`) — and
every later send asks whether that record is still the policy in force
(`harness-openrouter--resend-refusal`, over
`harness-openrouter--policy-change`).  So a policy disabled, removed,
made invalid, narrowed to other providers, given lower limits, or
pointed at another model while a request was in flight refuses the
repeat with `policy-changed`: nothing is re-selected, and nothing is
sent unrestricted.  A policy *removed* while a retry waits is the same
refusal (`harness-openrouter--withdrawn-refusal`), not a fall-through to
the ungoverned pass-through: the repeat is a request that was sent under
the policy, and sending it with no restriction and no count is the
silent widening this module exists to prevent.  The next request the
session starts — a new one — is the plain provider again.

A repeat also goes back to the endpoint recorded for it, not to the
session's pin of the moment: a hand switch between the failed attempt
and its retry starts a fresh request instead of re-pointing the one
already sent, so a conversation is disclosed where it was disclosed or
not at all.

**A governed request is never handed to another host.**  The fallback's
guard is given the failed step's `done` event, which carries the same
record, and refuses a move whenever one is present — whatever a policy
configured *now* says.  A 402 whose request was sent under a policy that
is disabled or removed while it is in flight stops the turn: it does not
travel to the next provider in `harness-fallback-models`, because
disabling a policy is a refusal, not permission to disclose the
request.

**Reading a failure.**  `harness-retry-failure-kind` reads the kind a
provider named, and otherwise the text; a transient kind
(`transport`, `rate-limit`, `process`) is what is retried.  This module
decodes its own typed codes (`error.metadata.error_type`) into those
kinds through the transport's generic `:failure-kind` dialect hook: a
transient code is `transport` or `rate-limit`, and a code in
`harness-openrouter--permanent-types` — `invalid_request` among them —
is `permanent`, which the shared layer ends at once with `:final`, so no
filter after it can retry it.  An ungoverned OpenRouter request answers
nil there and keeps the transport's own reading.  A cancelled request is
not retried, and a turn cancelled while its retry waits sends nothing
when the wait ends.

**How it is proved.**  `harness-provider-openrouter-transport-test.el`
drives the real `harness-http-request` and real curl processes against a
server in the test Emacs, so it counts what goes on the wire rather than
what a mocked HTTP function was called with: `harness-retry-max-attempts`
0 with a reset connection (one POST), a reset and a 503 sharing one
budget of two sends, a typed rejection that is not repeated, a typed
transient code that is, a `Retry-After: 3600` under a 1 s bound (one
POST, no wait), time spent by the first attempt counting against the
bound, six policy edits while a retry waits, a retry that goes back to
its own endpoint after a hand switch, a pin that went stale and dearer,
cancellation during a backoff, and plain OpenAI both with and without a
dialect still retrying as they always did.  It also holds the three
integrated reproductions of a request's own budget and authority: a
recap whose policy is removed or disabled during its wait (one
restricted POST, never one without a `provider` object), a recap under
a 0.1 s elapsed bound (one POST), and a recap in flight beside a step
(each refused on its own).  `harness-provider-openrouter-chain-test.el`
runs a real turn with the fallback loaded and a second provider to send
to, and proves that a 402 whose policy is disabled, removed, narrowed or
lowered mid-request sends nothing to it.  `harness-retry-test.el` holds
the shared bounds, the deterministic jitter regression — including that
a jittered wait past the bound stops the request instead of being slept
— and that a request's state travels with it and is never kept by
session.

### 10.1 What a request asks a model to write

An earlier revision carried `:max-output-tokens` in the policy, with an
example value of 4096.  That value was an arbitrary example, not a
model default, a provider requirement or a decided limit, and it was the
wrong place for it in two ways: it applied only to the one provider a
policy routes, and it silently became a ceiling on ordinary coding tool
calls.

- 4096 was a cap on **each model completion** — not a model default,
  not a context length, not a number of tool calls, and not a
  whole-session allowance.  Ordinary harness steps name no `:max-tokens`
  at all; the generic body sends a limit only when a request supplies
  one, and a direct DeepSeek `:max-output` of 393216 is catalogue
  capability, not a forced request cap.
- DeepSeek's own Chat Completions docs give 8K (non-thinking), 64K
  (thinking) and 128K (`reasoning_effort=max`) as *defaults when the
  limit is omitted*.  They are DeepSeek's defaults, not proof of what
  DeepInfra or Cohere do behind OpenRouter.
- OpenRouter's endpoint catalogue lists `max_completion_tokens` 393216
  for `deepinfra/fp8` and 384000 for `cohere/fp8`, with context length
  1048576.  Those are endpoint **maxima**, not advertised defaults for
  an omitted limit.
- The `max_tokens` budget includes the model's reasoning and the
  arguments it writes for a tool call, which are completion tokens too.
  A 4096 cap can therefore truncate a large tool call as readily as it
  shortens a reply.  Without accumulated calls the step ends at
  `max-tokens`; with a call whose arguments were cut, the harness passes
  the call on with its unparsable arguments as `(:raw …)` rather than
  dropping or inventing it.  Nothing here claims a truncated request is
  safely retried, and nothing retries it: the next step is the model's
  own.

So the policy has no output limit, and an ordinary request is sent
exactly what it asked for — or, if it asked for nothing, no limit at
all, so the endpoint's own default applies, as for every other provider.
A ceiling a user wants for every provider is the request layer's,
`harness-provider-max-output-tokens`, nil by default:
`harness-provider-bound-output` cuts a larger request to it, bounds one
that named nothing, and leaves a smaller request's own figure alone.  A
one-off call that names its own smaller limit (a session's name, a
judge's verdict) keeps it.  Nothing in the policy, the generated module
page or the commented Doom example names an output cap.

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
  cheapest across every provider in the catalogue — 50 endpoints here,
  including ones nobody allowed — and may fall back.  The allowlist and
  the price filter are the point.
- **Let OpenRouter choose and only record what it chose.** Rejected:
  that is the silent switch and the cache loss.
- **Rely on `max_price` alone.** Rejected: it covers prompt and
  completion, not cache reads, and a request-level cap is not an
  allowlist.  It is sent as a second defence.
- **Rely on `zdr: true` for retention.** Rejected as proof: OpenRouter
  documents that it can include Safety Retention, so the distinction is
  stated rather than collapsed into a claim of zero retention.
- **Per-endpoint evidence records with sources and expiry.** Removed at
  Noah's direction: the policy is a short plist of allowed providers and
  a maximum, and the factors behind the allowlist are documentation, not
  a schema he has to maintain.
- **A reference provider or owner price in the policy.** Removed at
  Noah's direction: the policy never restates what a provider charges.
  The API's current price is the only price, and the policy holds only
  the maximum the operator will spend.
- **Switch automatically when a pin stops qualifying.** Rejected: a
  switch is cache-cold and is the user's decision.
- **A retry subsystem of this module's own.** Removed at Noah's
  direction: an attempt budget, an attempt counter, a clock, a
  backoff and an `agent/step-error` filter all lived here, and where a
  failure is bounded, waited out and repeated is the shared retry
  layer's business, not a provider's.  This module now says only that
  its sends are counted, and the shared layer decides the rest.
- **A budget keyed by session, with the policy re-read at each send.**
  The first form of the shared layer's counting put one budget per
  session and asked "does the policy in force allow this send?".  Two
  requests of one session then shared a count and a clock, and a policy
  disabled or removed while a request was in flight read as permission
  to send its repeat elsewhere — or nowhere.  Rejected in favour of the
  request's own state: what a send spent, and what checked it, travel
  with the request, come back in its `done`, and decide its repeat.  A
  policy edited meanwhile refuses the repeat; a fresh request is the one
  that uses the new policy.
- **Re-selecting an endpoint for a repeat.** Rejected: a repeat is the
  request that was already disclosed to one endpoint, and choosing again
  for it would be the silent switch the policy exists to prevent.  The
  recorded endpoint is re-checked (identity, price, catalogue) and used,
  or nothing is sent.
- **A per-session pending flag, with a serial to tell requests apart.**
  Rejected: it is still one mutable cell that a concurrent name or recap
  writes, and the review asked for the smallest request-local design.
  The state travels on the request instead, so two requests of one
  session cannot read, consume or reset each other's.
- **A per-policy output limit.** Rejected: 4096 was an arbitrary example
  that became a real cap on one provider's completions, including the
  arguments of tool calls, and it silently replaced the endpoint's own
  default with a policy's.  What a request asks for is the request's,
  and a ceiling for every provider is the request layer's, off by
  default (see 10.1).

## What this does not establish

- No paid provider smoke test was run and no live activation was
  performed.  Everything here is offline with a fake HTTP layer.  A mock
  proves the client boundary, not OpenRouter's behaviour.
- No cache-hit rate is claimed.  `session_id` is a hint; only a live run
  can measure hits, and a prompt below the provider's minimum cacheable
  length is not cached at all.
- No per-request country of processing is claimed.  DeepInfra publishes
  US datacenters and Cohere's public pages name US Google Cloud
  infrastructure; neither publishes a per-request region for its
  OpenRouter endpoint.
- No claim that OpenRouter's account-level ZDR or Safety Retention mode
  matches the policy.  That is a settings fact, apart from this change,
  and it is checked before any activation.
- The response audit cannot prove a same-provider regional variant apart;
  see 7.
- The demo's own figures are the catalogue's as read on 2026-11-10; a
  later catalogue is the truth.

## Open decisions for Noah

1. **The maximum price.** Decided: 0.15 / 0.60 / 0.003 USD per
   million for prompt, completion and cache-read.  They are a spending
   limit per component, and the module never computes them: it compares
   the API's price with whatever the operator wrote, so the limits are
   the buyer's, not a claim about a provider.  Where the figures come
   from is written once, in the comment in Noah's `config.el`, with the
   page and date they were checked against; the harness does not read
   that, and this document does not restate it.

   What the limits leave:

   | endpoint | prompt | completion | cache-read | inside the example limits |
   | --- | --- | --- | --- | --- |
   | `deepinfra/fp8` while 51% off | 0.098 | 0.294 | 0.00294 | yes — chosen |
   | `cohere/fp8` | 0.15 | 0.50 | 0.003 | yes — prompt and cache-read exactly at the ceiling |
   | `deepinfra/fp8` at list | 0.20 | 0.60 | 0.006 | no — prompt and cache-read over it |

   They are the token rates as configured and nothing else: no fee is
   added to them, and OpenRouter's API remains the only source of what a
   provider charges.

2. **The freshness bound.** A policy value with no shipped default.  The
   module's own defaults are mechanical only: a **900 s** shared refresh
   interval (how long one reading is reused without asking again, for
   every session and every judge together), a 20 s fetch timeout, a 5 s
   wait for a one-off call with no reading at all, and the background
   re-read of a failed catalogue -- a burst of 5 doubling from 5 s to
   300 s, then one 300 s probe until a read settles (section 5.1).  How
   often and how long a failed *request* is tried again is not a policy
   value: it is the shared retry layer's (`harness-retry-max-attempts` 3
   and `harness-retry-max-seconds` nil by default, with
   `harness-retry-delay`, `harness-retry-max-delay` and
   `harness-retry-jitter`), and a bound there applies to every provider.

3. **An activation snippet, written but inactive.** See the
   [inactive configuration example](#inactive-configuration-example)
   below: the form as it sits *commented out* in Noah's `config.el`, so
   loading that file changes nothing.  It says `:enabled t`, because a
   complete policy is the only configured state worth uncommenting:
   `:enabled nil` is not a soft stop but a refusal of every request (see
   [rollback](#rollback-and-the-two-kinds-of-off)).

4. **A bounded smoke plan.** For later approval, **not run here**.  It is
   scoped to fit the smallest useful measurement:

   | bound | proposal |
   | --- | --- |
   | requests | 4 completions: 1 priming turn and 3 one-token follow-ups, 1 catalogue read per turn, no retries |
   | tokens | 1 priming turn of ~4,000 input tokens (over DeepSeek's minimum cacheable length), 3 one-token follow-ups, `max_tokens` 16 |
   | retries | 0: a failed step ends the smoke run and is reported |
   | concurrency | 1 session, 1 request at a time |
   | maximum dollars | ≤ \$0.02 at the example limits; stop if it is exceeded |
   | stop | stop dispatching without widening routing: turn the policy's `:enabled` off (see [rollback](#rollback-and-the-two-kinds-of-off)) |

   The steps: (a) with the form still commented out — the provider as it
   always was — confirm a request to this model is sent the old body;
   (b) with the policy enabled for one scratch session, send the priming
   turn and confirm the response names the pinned provider, and that the
   OpenRouter activity log's generation names the same one; (c) send
   three one-token follow-ups and confirm each is served by the same
   provider, reading OpenRouter's own cache accounting rather than
   assuming reuse — a single one-token pair does not establish it, which
   is why the priming turn is long enough to be cacheable and the reads
   are read off the log; (d) confirm the summed cost in the activity log
   is at or under the limits.  Four completions is what those steps
   send.  Any step that stops instead of answering is evidence the guard
   works, not a failure to hide.

## Inactive configuration example

This is the form as it sits *commented out* in Noah's `config.el`,
shortened to its policy fields: the file is the authority, and this copy
is here so the shape — and the decided limits — are reviewable with the
code.  It is inactive because it is **commented out**, not because of a
value in it: it says `:enabled t`, since a complete policy is the only
configured state worth uncommenting.  The comments that say where the
ceilings come from, and cite the page they were checked against, are in
`config.el` only.

```elisp
;;   harness-openrouter-routing
;;   '(:enabled t                ; nil here refuses; omit the whole form instead
;;     :model "deepseek/deepseek-v4.1-flash-1017"
;;     :providers ("DeepInfra" "Cohere")   ; the allowlist, not an order
;;     :max-price (:prompt 0.15 :completion 0.60 :cache-read 0.003)
;;     :freshness 900)
```

As written, a request to `openrouter:deepseek/deepseek-v4.1-flash-1017`
is what it was before the policy existed.  Uncommented, it pins one
endpoint per session and enforces the limits; nothing here activates it.
The maximum is the buyer's decided ceiling, not a rate any provider
publishes.  Kept at exactly those figures: raising them to clear a fee
would admit a price the decision was meant to exclude.

## Rollback and the two kinds of off

**A policy that is off and a policy that is absent are not the same
thing**, and the difference is the difference between stopping a
governed workload and un-governing it:

- `harness-openrouter-routing` set to **nil** (`(setq harness-openrouter-routing nil)`)
  is the legacy pass-through: the provider behaves exactly as it did
  before this module had a policy — no `provider` object, no pin, no
  catalogue request, no restriction of any kind — and requests route by
  OpenRouter's default, **across any provider it likes**.  It is the
  right rollback for taking the whole feature out.  It is the wrong
  thing to reach for when the point is to stop a governed session: it
  hands that session back to unrestricted routing, which is exactly what
  the policy existed to prevent.
- A **configured** policy with `:enabled nil` refuses every request and
  sends nothing: `disabled`, no pin, no transport call.  That is how a
  governed workload is stopped.  It is not a soft stop, and it is not a
  pause-and-resume posture: while it is set, anything on
  `openrouter:<the policy's model>` stops.  A configured-but-invalid
  policy refuses too, and says which field is missing.
- A request already in flight when the policy is turned off is refused
  at dispatch -- `disabled` -- rather than sent under the vanished policy
  (see [4](#4-a-pinned-session-revalidated-on-every-dispatch-never-moved)).

So the two operations are: **stop** — `:enabled` off, which keeps the
allowlist, the limits and the pin, and refuses; **remove** — the
variable nil, which returns OpenRouter to its previous unrestricted
behaviour.  Choose the first to contain a problem and the second only
when the decision is to stop using the feature.

The [smoke plan](#open-decisions-for-noah)'s stop row uses the first:
turn `:enabled` off, and the scratch session stops without any other
session's routing widening.

## Shape of the change

- New: `lisp/modules/harness-provider-openrouter.el` (the dialect, the
  policy, exact prices, catalogue fetch and parse, selection, pin
  storage, per-dispatch revalidation, request fields, stream audit,
  error decoding, dispatch, cancellation, switch, the retry policy it
  asks the shared layer for, the fallback guard, module registration).
- New: `lisp/modules/harness-provider-openrouter-test.el`, with
  `harness-provider-openrouter-chain-test.el` and
  `harness-provider-openrouter-output-bound-test.el`.  The suite files
  are split because a suite that starts and stops modules resets the
  bus, which would disturb tests in the same file; the shared fixtures
  are in `harness-provider-openrouter-test-helpers.el`, which defines
  no test.  Each suite runs against a fake HTTP layer; none makes a live
  call.
- Changed: `lisp/modules/harness-provider-openai.el` — the `:dialect`
  hooks (including the generic `:failure-kind`), the endpoint-ownership
  registry, the transport-retry count it now asks the shared layer for,
  and the removal of every OpenRouter branch.
  `harness-openai-endpoints` defaults to OpenAI only.
- Changed: `lisp/modules/harness-retry.el` — one retry owner for every
  provider: the policy hook, the send count and clock, the one-draw wait
  plan, the `permanent` kind, and the elapsed bound
  (`harness-retry-max-seconds`).
- Changed: `lisp/modules/harness-provider.el` — the one optional output
  ceiling (`harness-provider-max-output-tokens`, nil by default) and the
  function that applies it at `provider/complete`.
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
