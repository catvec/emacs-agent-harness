# One pool per provider account: shared admission and cooldown

## What was wrong

Two facts, from two places, that turned out to be about the same thing.

**The 429s did not end.**  A session pinned to DeepInfra was getting
`HTTP 429: Provider returned error (provider=DeepInfra)` on its steps,
each followed by `trying again in 1 s (1 of 3)` and then again at 2 s.
Every one of those was a *per-request* decision: `harness-retry` read
the failure, drew a backoff, waited it out and sent that one request
again.  Nothing in the harness knew how much work it had in flight
against the DeepInfra account.  A recap, a permission verdict, a
session name, another task's step and a cache warmer were all in flight
against the same account, and each of them met the same limit on its own
clock and came back at its own moment.  A provider that had just said
"slow down" got a fresh request from every direction a second later.

**The unexplained hand-in stop, separately.**  The investigation this
task began with reconstructed the stop of task `t-e2mdkyz2` and found no
provider failure in it: its last assistant message was a text-only
reply that promised a hand-in, the turn ended `end-turn` normally, and
the working phase recorded that as a reply to the user (`outcome
conversing`, session `blocked`, task `active`) -- the designed
consequence of a model that wrote prose instead of calling `hand_in`.
No 429, no disconnect, no cancellation, no permission prompt.  That
evidence stands and is not re-attributed here.  What this change
addresses is the *other* half of what the field showed: the 429s that
the same task's later runs met repeatedly, and that made every step of
a review take three times as long as it should.

## What the change decides

**A rate limit belongs to the account, so the harness keeps one pool per
account.**  `harness-admission` sits at `provider/complete`, the funnel
every request of the harness passes through: a turn's step, the retry of
one, a one-off call (`harness-small-ask`), a cache warmer.  A pool has
requests in flight and requests waiting.  When the provider says it is
rate limiting, the pool stops letting work in; when the provider says it
is ready, the pool lets work back in.  The state is the harness
process's, so every session, one-off call and warmer of one server
shares it -- which is the whole point, because they are one account's
traffic.

**A wait the provider names is never shortened.**  `Retry-After` is read
in both forms HTTP allows: a number of seconds, and an HTTP-date (read as
how long from now it names, and 0 when it has passed).  The pool rests
exactly that long.  `harness-admission-max-delay` caps only the
harness's own guess, never the provider's word: sending before a
`Retry-After` has elapsed is a request that will be refused again, so
there is nothing to gain by shortening it.  A provider that says an hour
gets an hour, and the request waiting for it is told so and can give up.

**A wait the harness guesses is bounded and jittered.**  A 429 that
names no wait rests the pool for `harness-admission-delay` doubling per
consecutive limit, spread by `harness-admission-jitter`, capped at
`harness-admission-max-delay`.  That is a guess, so it has a ceiling; a
`Retry-After` is not, so it has none.

**A second limit never opens the pool early.**  Two requests in flight
together can both meet the limit, each with its own `Retry-After`; the
pool keeps the later of the two ends.  The shorter answer cannot open
the pool for everybody.

**Recovery is gradual, and in the order that matters.**  Coming out of a
rest with work still waiting, the pool releases one request per
`harness-admission-release-spacing`, not the burst that caused the
limit.  The order is a turn before a one-off call, a one-off call before
a cache warmer, first come first served within each.  A warmer exists to
save money later; it must never make a person wait.  A pool that is not
recovering releases everything at once, with no queue and no spacing.

The decision to come back gradually is the pool's, taken in one place
(`harness-admission--pump'), not the timer's: a request arriving, a
request finishing, a cancel, a timer and a transport replay all decide
it the same way, from whether a rest has ended with work still waiting
and whether the spacing after the last piece has passed.  A request that
arrives in the instant a rest ends is therefore spaced like the ones
that waited; a timer that has not run yet cannot let a burst out.

**The caller's callback sees the pool as it is.**  A terminal callback
is an ordinary place to start the next request from, and the harness's
own callers do.  So the pool is told how the request ended *before* the
callback runs, and the place is given back after it, in an unwind: a
callback that starts another request finds the pool already closed for a
limit this one met, and a callback that signals still frees the place
exactly once.

**A reload does not drop the queue.**  `harness-module-start` runs a
module's init again on every reload; the pools are only cleared on the
first start, so a request waiting out a rate limit is not silently
forgotten.

**Pools are independent, and a provider says what a pool is.**  A
request's identity is a pair: an *account*, which is what a rate limit
belongs to, and a *pool*, a slice of it.  The method
`provider/admission-identity` answers it, so a provider that knows its
own accounts answers in its own module; `harness-admission-pool-functions`
is the generic hook, and the last resort is the provider of the request's
model, whose pool is its own account.  OpenRouter answers `openrouter`
for the account and the exact upstream endpoint the session is pinned to
for the pool (`openrouter/deepinfra/fp8`, `openrouter/cohere/fp8`), so
DeepInfra's bad minute does not stop work bound for Cohere.  An identity
is built only from names the provider publishes; no key, token or other
credential is ever part of one, so nothing secret can be read out of a
hint or an event.

**A limit reaches as far as the provider says it does.**  A failure may
carry `:limit-scope`: `pool` for one endpoint's limit, `account` for one
the whole account shares.  Only a provider that can tell the two apart
says so.  OpenRouter answers from the failure's own fields: a 429 that
names the upstream endpoint that declined (`error.metadata.provider_name`)
is that endpoint's, and one that names none is OpenRouter's own limit on
the key that sent it, which rests every pool of the account.  An
account's rest is kept on the account, so a pool of an endpoint first
used afterwards inherits it rather than slipping past it.  An ordinary
provider's whole account is one pool, so the two are the same thing
there and nothing changes for it.

**A replay is a send.**  `harness-http` replays a request of which
nothing reached the caller yet -- a reset, an empty reply, a refused
host -- inside the admitted request, without going back through
`provider/complete`.  That replay asks the pool before it goes
(`:gate`, answered by `provider/transport-gate`): it waits out a
cooldown another request established meanwhile, or is refused when the
pool will not open inside what this request may wait.  The first attempt
is never gated -- it is the caller's, already admitted -- so nothing is
counted twice, no retry budget is spent on waiting, and no promise is
awaited, so a gate cannot deadlock a transport or duplicate a terminal
event.  A request that was not admitted has no gate and keeps the
transport's retries exactly as they were.

**Cancellation and a ceiling on waiting.**  A request that waits can be
stopped through the `:cancel` of the handle the caller was given:
nothing is sent for it, the caller gets the `done` with `:stop-reason
cancelled` any provider gives, and the pool has its place back.  A
request that waits longer than `harness-admission-max-wait` ends with a
`:rate-limit` failure naming the pool and the wait still owed, which
`harness-retry` and `harness-fallback` read like any other rate limit --
rather than holding a turn for an hour behind a pool.  A transport
replay is held to the same bound, and is refused up front when the pool
will not open before it.

**What the bound does and does not promise.**  `harness-admission-max-wait`
(30 s by default) is a ceiling on how long one request is held; it is
not a promise that a task keeps running through any cooldown.  A rest
longer than the bound ends the request with a rate limit that carries
the wait still owed.  What happens next is `harness-retry`'s, and its
own bounds are tighter than an hour: a wait is capped at
`harness-retry-max-delay` (30 s by default), a request may make
`harness-retry-max-attempts` more sends, and `harness-retry-max-seconds`
bounds one request's whole life when a provider counts its sends
(OpenRouter does).  So a provider that closes an account for longer
than those bounds does not keep a turn running: the turn ends with the
rate limit, and the next message tries again.  That is deliberate -- a
harness that sat for an hour on a closed account would be a harness that
looked hung -- and it is what the `:retry-after` on the failure is for:
the next attempt is not made into a pool still known to be closed.

**What is observable.**  `admission/state` returns every pool: what is
in flight, what waits, when the pool opens again, how many limits in a
row.  `admission/waiting` and `admission/cooldown` are bus events, and a
session whose request waits is left a hint saying which provider, how
long, and how many wait.

## Why here, and not in OpenRouter

This is generic orchestration and it stays outside every provider.
`harness-retry` already owns *whether* a failed request is sent again,
how many times and how long to wait; `harness-http` owns whether a
transport may replay a request no one saw.  This module owns only *when*
a request that is about to be sent may go, and it is the only place that
sees every request of the harness at once.

It never changes what is sent.  The request reaches the provider
untouched, so OpenRouter's pin, its approved provider list, its privacy
fields and its price limits are checked by the module that owns them, at
the send, exactly as before.  A request that waited is the same request,
sent later -- not a re-selected one, and not an unauthorised one.

## Alternatives considered

- **A shared cooldown only (a timestamp every caller reads).**  Simpler,
  but it does not limit how much goes out when the cooldown ends: every
  waiter would fire in the same instant, which is the thundering herd
  again.  The release spacing is the part that matters.
- **A global limit on concurrent requests.**  Rejected: a rate limit on
  DeepInfra says nothing about Claude or a local model, and one global
  gate would make an ordinary provider's requests wait behind another
  provider's bad minute.  Pools are per account; a concurrency bound is
  an option (`harness-admission-max-concurrent`), not the design.
- **Put it in `harness-http`.**  Rejected: the HTTP layer does not know
  which account a request is for, cannot tell a turn from a warmer, and
  is below the point where a request's model is known.  It also cannot
  hold a request that has not been authorised yet without changing what
  gets sent.
- **Put it in the OpenRouter provider.**  Rejected, on the same grounds
  the retry layer was moved out of it: a policy for one provider is not
  a policy for the harness, and the account-level limit is not
  OpenRouter's concept.
- **Have `harness-small` and the warmer keep their own cooldowns.**
  Rejected: three places would decide the same question with three sets
  of numbers, which is exactly the duplication that was removed from
  `harness-retry`.
- **Treat the limit as a failure and let the retry layer handle it.**
  That is what the harness did, and it is why the 429s did not end: the
  retry layer sees one request and cannot know the account is closed.
  The two layers are complementary: the pool decides when work may go,
  the retry layer decides whether a request that failed is worth
  repeating.

## What stays as it was

- `harness-retry`'s bounds, its wait and its request-local budget are
  unchanged; the pool adds a gate before a send and nothing after it.
- A request whose model names no provider has no pool and is sent
  untouched.  With `harness-admission` nil, every request is sent
  untouched.
- `harness-http-retry-after` still reads only the delay-seconds form for
  the transport's own replays; the new
  `harness-http-retry-after-seconds` reads both forms, and the OpenAI
  transport uses it so that a dated `Retry-After` reaches the pool and
  the retry layer as the wait it names.
- No routing configuration, credential or task queue is touched.

## How it is verified

`lisp/modules/harness-admission-test.el`, 29 tests, all passing:

- an open pool sends at once, with no queue and nothing left behind --
  and with `harness-admission` nil two requests are both sent even after
  the first met a 429;
- a 429 holds the next request of the same account, and the pool's state
  says how long it rests and who waits;
- a `Retry-After` in seconds is waited as asked, however long
  (`max-delay` is 0.2 s and the provider says 3600 s), and so is a
  `Retry-After` given as an HTTP-date;
- a second limit never shortens the first, and a longer one moves the
  rest further out;
- pools are independent, and a provider can name its own pool
  (`harness-admission-pool-functions`) so one endpoint's limit does not
  hold another's;
- a recovering pool releases one request per spacing -- four requests
  that waited take at least three spacings -- and in the order turn,
  one-off call, warmer; first come first served within a rank;
- a waiting request can be cancelled before it is sent (nothing goes,
  the caller gets `cancelled`, the pool is free), and a request in flight
  that is cancelled frees its place at once;
- a request waits at most `harness-admission-max-wait`, then fails with
  `:rate-limit` and the wait still owed as `:retry-after`;
- `provider/complete` goes through the pool, so a turn and a one-off
  call are held by the same limit, and a model that names no provider is
  sent as it was;
- a reload of the module keeps the requests that wait, and
  `harness-admission-max-concurrent` holds a pool to that many in flight;
- `admission/state` reports every pool, and a waiting session is left a
  hint saying which provider and how long;
- over a real wire (a local HTTP server, the real OpenAI transport): one
  session's 429 with a `Retry-After` holds a second session's step and a
  cache warmer, and all three go once the pool opens;
- a limit the provider says is the account's (`:limit-scope` `account`)
  rests every pool of that account, including one first used afterwards,
  and another account's work is untouched;
- the method `provider/admission-identity` is asked before the generic
  hook, so a provider with its own account model answers in its own
  module, and no key or token is ever part of an identity;
- a terminal callback that starts another request finds the pool already
  closed, and a callback that signals still frees the place exactly once;
- a recovering pool spaces a request that arrives in the instant a rest
  ends, so the spacing does not depend on the timer having run, while a
  queue that forms after the recovered one has gone is let in at once;
- over a real wire, a transport replay of a request that meets another
  request's cooldown waits it out and then goes once, and one that would
  wait past `harness-admission-max-wait` is refused and sends nothing.

The OpenRouter suites carry the provider's own half of it.  The unit
suite adds four: two pinned sessions are two pools of the account
`openrouter`; a repeat belongs to the endpoint it was authorised for,
not to a pin chosen since; a 429 that names the upstream endpoint is
that endpoint's limit; and one that names none is the account's.  The
transport suite (18 tests, real local wire) adds two end-to-end ones,
each with two sessions pinned to the catalogue's two upstream endpoints:
one where the first meets a 429 naming DeepInfra -- its pool rests and
the second, pinned to Cohere, is sent at once and answers, each POST
carrying its own endpoint's restriction -- and one where the 429 names
no upstream endpoint, so the account's rest holds the Cohere session
too, and it goes when the rest is over.

The suites this touches pass unchanged: `harness-retry` 21,
`harness-small` 12, `harness-http` 19, `harness-provider` 42 alone,
`harness-provider-openai` 55 plus 2 live skips,
`harness-provider-responses` 54, `harness-cache-warm` 37, `harness-acp`
67, and the three OpenRouter suites 89 / 18 / 10.

Two failures are *not* this change, and both reproduce on `main`'s
tree with this change stashed:

- `harness-provider-test`'s `policy-keeps-requests-to-models-allowed`
  fails when that file is run together with `harness-cache-warm-test`
  (79 tests, 78 expected), at the same assertion and with the same
  numbers; it passes alone.
- `harness-skills-scan-test`'s `bounds-what-it-lists` fails on this
  machine, alone and in the full run, because it lists files in the
  order the filesystem returns them and then bounds that list.  The
  failure is in `main`'s own copy of the test, unchanged by this work.

The full run is `scripts/test.sh`: 219 files, 1 failed -- the
skills-scan test above -- in 317 s.  `scripts/lint.sh` exits 0, with no
warning from any file this change touches.  Two more suites fail only
when several run together and pass alone (`harness-provider-openai`'s
`registers-default-endpoints` and `harness-provider-responses`'
`status-says-why-it-is-not-usable`), on this tree as on `main`; neither
is touched by this change.

## The shape of the change

- `lisp/modules/harness-admission.el` (new): the identities, the
  pools and the accounts, the queue, the rest, the release, the state and
  the events, plus the `provider/admit` method `provider/complete` calls
  and the `provider/transport-gate` a transport asks before a replay.
- `lisp/modules/harness-provider-openrouter.el`: answers
  `provider/admission-identity` with the account `openrouter` and the
  pinned endpoint as the pool, and `:limit-scope` from the failure's own
  fields -- one endpoint's limit, or the account's.
- `lisp/harness-http.el`: a request may carry a `:gate`, asked before
  every replay it decides on its own (never the first attempt), answering
  go, wait, or refuse; `harness-http-retry-after-seconds` reads both
  forms of `Retry-After`, while `harness-http-retry-after` keeps reading
  only the seconds form for the transport's own replays.
- `lisp/modules/harness-provider.el`: `provider/complete` sends through
  `harness-provider--send`, which asks `provider/admit` when
  `harness-admission` is on and sends the request itself when it is not
  (or when no module answers).  A harness without the module sends
  exactly what it always sent.
- `lisp/harness-http.el`: `harness-http-retry-after-seconds` reads both
  forms of `Retry-After`; `harness-http-retry-after` keeps reading only
  the seconds form for the transport's own replays.
- `lisp/modules/harness-provider-openai.el`: the stream records the
  `Retry-After` with the date form read, so the pool and the retry layer
  see the wait the provider named; the request carries its gate, and the
  dialect's `:limit-scope` hook says how far a limit reaches.
- `lisp/modules/harness-provider-responses.el` and
  `lisp/modules/harness-provider-bedrock.el`: their transport replays
  carry the request's gate, so an ordinary provider's replay cannot go
  into another request's cooldown.
- `harness.el`: `admission` joins `harness-core-modules`, so every
  harness has it.
