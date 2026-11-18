# One shared OpenRouter catalogue, refreshed about every 15 minutes

## The problem

The reported failure was a session pausing with

    OpenRouter routing paused (catalogue-unavailable): the endpoint
    catalogue could not be read: Invalid error symbol: http-error

Two faults were behind it, and a third followed from the first two.

**Every caller forced a fetch.**  A new session, a pinned session's
revalidation and the permission judge each read the endpoint catalogue
for themselves, even when the process already held a reading of the same
model.  A momentary failure of that read therefore stopped work that had
nothing to learn: the reading was already in hand.

**A reading past a short TTL made the caller wait.**  The TTL was 60 s,
so almost every new session was past it, and the caller waited for a
fetch that a stalled upstream could hold for the whole of a judge's
budget.  That is how a stalled catalogue became a denied tool call.

**A failed refresh rejected outright.**  Even with a reading inside the
operator's freshness bound in hand, a failed refresh rejected, so an
outage stopped sessions instead of serving them the reading they already
had.

## What this decides

### One reading per model, shared by every caller

The reading lives in `harness-openrouter--catalogue`, keyed by model id,
and it is the process's, not a session's.  `harness-openrouter--fetching`
coalesces concurrent reads, so a burst of sessions *and* judges costs one
request.  Nothing is stored until a read settles, so a read that answers
at once is never stored settled.

### The refresh interval is 900 s, and it is the whole refresh policy

`harness-openrouter-catalogue-ttl` is raised from 60 to **900** seconds.
It is the shared reuse window: a reading inside it answers without a
request at all.  No session path passes a refresh flag any more;
`harness-openrouter--catalogue`'s REFRESH argument is documented as the
*explicit invalidation* path only.

**Alternatives considered.**  A per-session TTL was rejected: it makes
the reading a session's property, which is what caused one fetch per
caller.  A fixed wall-clock refresh timer was rejected: it would read the
catalogue for models nobody is using, and it makes the first caller
after the tick wait anyway.  The interval plus serve-while-revalidating
gives both properties without a background tick.

### The interval is not the price bound

The operator's `:freshness` remains the price-safety bound and is never
widened.  A reading can be *fresh enough to reuse* (inside the interval)
and *too old to decide from* (outside a short `:freshness`) -- the policy
is always asked separately, and a reading outside it is never used.

### Served while revalidating

A reading past the interval but inside `:freshness` is answered at once,
marked `:revalidating`, and the shared read starts *behind* the caller.
A step of a turn gets the `openrouter/catalogue-revalidating` event and a
hint; a judge (`:ephemeral`) starts no read and is not told one is
running, because for it there is none.

**Why not just wait.**  Waiting is what made a stalled read a stalled
judge.  The operator already said the reading is good enough to decide
from, so waiting for a newer one contradicts the policy it is waiting
under.

### Stale-while-revalidate, and one read per outage

When the background read fails, the last reading stays and the next
lookup is answered from it, marked `:stale` with what failed, while the
failure episode is live.  A dispatch on it says so.  Outside
`:freshness`, or with no reading at all, a step of a turn waits for the
episode's own re-reads, bounded by `harness-openrouter-catalogue-wait`
(see *An outage is waited out* in `docs/openrouter-pinning.md`); past
that bound it ends with `catalogue-unavailable`, and nothing is invented.
A refusal -- a 401, a body that is an `error` object -- is never waited
for: it is the catalogue's answer, and reading again would get it again.

While an episode is live an ordinary lookup never adds a read: an outage
costs one failed read, not one per caller.

### Burst, then heartbeat

The first `harness-openrouter-catalogue-retry-attempts` (5) re-reads
double from 5 s to 300 s.  After the burst, one slow probe continues at
300 s until a read settles.  A long outage heals itself instead of
staying broken until a person asks, and one request per 300 s is not a
storm.  Every attempt is counted, probes included.

**Alternative considered.**  Stopping after the burst was the earlier
design, and it leaves a catalogue that was unreachable for an hour broken
for the rest of the process.  Bounding the *rate* rather than the total
is what makes a permanent retry safe.

### A judge rides its session's pin when the catalogue cannot be read

A one-off call waits at most `harness-openrouter-catalogue-ephemeral-wait`
for a reading it does not have, and a refusal is a call with no verdict --
which a non-interactive session denies.  That is how one stalled
catalogue read denied every tool call of a session.

The judge decides a call the session it is made for is about to send, on
the endpoint that session is already pinned to, so it may be answered
from that pin when the catalogue cannot be read at all.  A request names
the session in `:pin-from`, and `harness-openrouter--complete-unread`
sends it there when every check the pin's own record can answer passes:
the policy still allows the provider, still covers the recorded price, and
the pin is of this policy's model.  The age of the reading is the one
check a missing reading cannot make, so it is not made -- and the dispatch
says so, with `openrouter/catalogue-unread` and a hint on the session.
Nothing is stored, and a pin the policy refuses still refuses: the judge
then has no verdict, exactly as it had before.

**Alternatives considered.**  Waiting longer for the reading was rejected:
the judge's whole budget is 30 s and the read's own watchdog fires at 25 s,
so waiting spends the budget on bookkeeping.  Answering the judge's call
without the catalogue at all -- with no pin -- was rejected: choosing an
endpoint is the policy's decision for a session, and a one-off call has no
session of its own to pin.

### Explicit invalidation is a separate API

`harness-openrouter-catalogue-invalidate` drops the reading, bumps a
per-model generation, cancels a pending retry and starts a read now.  It
is the only path that forces one.

- It does not reset the attempt bound: the read it starts is the next
  attempt of the episode already running, so it cannot become a storm.
- A read that began before the bump answers its own callers and is not
  stored over the reading the invalidation asked for (the generation is
  compared when the read settles), so a slow session read cannot undo it.

### What is guaranteed, and what is not

The freshness bound is the guarantee, and it is the operator's.  Sharing
a reading is not evidence that a price is current now: it says what the
catalogue said at `:at`.  The wire `max_price` covers prompt and
completion only, so a reused reading's cache-read price is compared here
and is never assumed to be protected at the router.  No guarantee that a
price is current is made anywhere, and none is implied by the reuse --
this is stated rather than papered over, because a 15-minute reuse window
and a per-call price guarantee cannot both hold.

## The shape of the change

- `lisp/modules/harness-provider-openrouter.el`: the TTL default; the
  invalidation table and command; `harness-openrouter--reading-for`'s
  four-way decision; `--revalidate`; `--reading-due-p`; the retry
  scheduler's burst and heartbeat; `--degraded` for both `:stale` and
  `:revalidating`; the `openrouter/catalogue-revalidating` event; the
  one-off pin fallback (`--pin-from`, `--complete-unread`, and the
  `openrouter/catalogue-unread` event, with `--pin-refusal`'s UNREAD);
  and `harness-openrouter-catalogue-status`'s `:state`, `:ttl` and
  `:reading`.
- `lisp/modules/harness-provider-openrouter-test.el`: the repaired tests
  and the new coverage -- one read for five sessions and three judges, a
  reading inside the interval, serve-while-revalidating, a judge that
  starts no read, coalesced revalidation, burst-then-heartbeat, first
  run with no cache, invalidation, and the price/provider/privacy limits
  on a degraded reading.
- `docs/openrouter-pinning.md` sections 5.1 and 5.2 and the defaults
  paragraph; `docs/modules/provider-openrouter.md` regenerated.
- `demo/openrouter-catalogue-sharing/`: an offline demo of all seven
  cases, with its expected output.

## What this does not do

It does not deploy, merge or change any queue, and it does not touch the
provider-readiness work.  It sends no request to OpenRouter: every test
and the demo run offline against a stub transport.
