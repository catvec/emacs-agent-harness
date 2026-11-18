# Recovering a turn from an OpenRouter stall

## What happened

Task `t-...` (session `ce162d7d`) worked through a busy afternoon on a
16-core machine at load 10–12.  Its first turn ended with these hints, in
this order:

    [hint] No progress for 39 minutes (waiting for the model): the turn may be stuck. The user was notified.
    [hint] OpenRouter: network error: request timed out after 600s; trying again in 1 s (1 of 3)
    [hint] Error: request timed out after 600s
    [hint] OpenRouter routing paused (catalogue-unavailable): the endpoint catalogue could not be read: HTTP 200: request timed out after 20s
    [hint] Error: OpenRouter routing paused: the endpoint catalogue could not be read: HTTP 200: request timed out after 20s

Nothing was wrong with the task.  A model request hit the 600 s HTTP
watchdog, the retry timed out too, and the *catalogue* read that the
retry needed then stalled under the same load.  The turn ended `error`.

Three things followed from that, and each is a defect of its own:

1. **The judge could not get a verdict.**  In the next turn, a plain
   `bash` call was denied:

       Denied: the auto-mode judge gave no verdict (it failed: OpenRouter
       routing paused: the endpoint catalogue could not be read: the
       endpoint catalogue was still being read after 5s), and with the
       user away nobody could approve the call

   The judge is a one-off call (`:ephemeral`).  It waits at most
   `harness-openrouter-catalogue-ephemeral-wait` (5 s) for a catalogue
   reading it does not have, and past that it is refused with
   `catalogue-unavailable`.  The chain reads a refusal as *no verdict*,
   and a non-interactive session denies a call with no verdict.  So for
   as long as the catalogue read stalled, every tool call that needed the
   judge was denied: the session could not work at all.

2. **The task was stranded.**  `harness-tasks--on-turn-ended` had one
   branch for a turn that ended `error`: leave the task `active` with
   `:outcome 'error`.  No live turn, no retry, no timer, and nothing said
   to the user.  The only recovery was a manual `task/retry`.

3. **The reason was not recorded.**  The same branch set `:outcome` and
   nothing else: the error text lived in the session's transcript hint
   and nowhere the board or `task/retry` could show.  Four tasks stranded
   the night before could not be diagnosed afterwards for exactly this
   reason.

## What this decides

### 1. A one-off call rides its session's pin

The judge decides a call the session it is made for is *about to send*,
on the endpoint that session is already pinned to.  So its own answer may
go to the same place: a request that names `:pin-from` (the session it is
made for) is answered from that session's pin when the catalogue cannot be
read at all, rather than refused.

This is not a widening.  Every check the pin's own record can answer is
still made, by the same function that checks a step's dispatch
(`harness-openrouter--pin-refusal` with its new UNREAD argument):

- the policy still allows the pin's provider (`--pin-allowed`);
- the price the pin recorded is still inside the policy's limits
  (`--recorded-over`), so a maximum lowered under a pin stops the judge
  too;
- the pin is of this policy's model, and it records a reading at all.

The one check a missing reading cannot make is *how old that reading is*.
It is not made, and it is not pretended to be: the dispatch emits
`openrouter/catalogue-unread` and leaves a hint on the session naming the
endpoint the call went to.  Nothing is stored -- a one-off call pins
nothing -- and no read is started.

Without a pin the call is refused exactly as before, which is the
reported behaviour for a session that has not been pinned yet.  The
permission chain is untouched: the judge's own verdict still decides the
call, and a call the judge would deny is still denied.  Only the path
"no verdict because a bookkeeping read was slow" is gone.

**Alternatives considered.**

- *Wait longer for the reading.*  The judge's whole budget is 30 s
  (`harness-perms--auto-timeout`) and the catalogue's own watchdog fires
  at the fetch timeout plus 5 s (25 s), so a judge that waited would
  still spend its budget on bookkeeping -- and a catalogue read that
  stalls for 600 s, as this one did, is not waited out by any bound.
- *Fall back to the last admissible reading marked stale.*  That is what
  `--reading-for` already does when a reading exists but its refresh
  failed.  The reported stall is the case where the *first* read never
  returned, so there is no reading to mark.
- *Answer the judge's call without the catalogue at all.*  With no pin
  there is no endpoint to send it to; choosing one is the policy's
  decision for a session, and a one-off call has no session of its own.

### 2. A transient stall parks the task and tries again, bounded

A turn that ends `error` on a failure the shared retry layer reads as
transient -- a connection that failed, a rate limit, a provider's process
that died, or one of the catalogue's own refusals -- is no verdict on the
task.  Nothing about its work was judged, and the next attempt usually
answers.  Such a task is parked like a quota hold (`harness-tasks--park`)
with a `stalled` hold of its own, and the queue starts it again after a
doubling wait.

The bounds are the retry module's, read in one place as a step's are:
`harness-retry-max-attempts` (how many tries) and
`harness-retry-max-seconds` (measured from the first stalled turn,
`:retry-since`).  The waits are new options of the tasks module --
`harness-tasks-stall-retry-delay` (15 s) doubling to
`harness-tasks-stall-retry-max-delay` (300 s) -- because a task's wait is
the queue's business, not one request's.  `harness-tasks-stall-retries`
turns the whole thing off, for the old behaviour.

A failure no identical request would get past (a refusal, a login, a
malformed request) is not one of these: it stops the task in needs-input
as it always did, so a genuinely broken task does not burn its bound in
retries.

The hold is the task's own record (`:retry-at`, `:retry-attempts`,
`:retry-since`, `:stall`), not a table, so it survives a restart and the
existing hold timer (`--arm-hold-timer`) starts the task when it passes.
No new timer, no new event, no new table.

**Alternatives considered.**

- *Retry inside the turn*, as a step is retried.  That is what already
  happened, twice, and it is what ran out: the step retry's bound was
  spent before the catalogue stalled.  A turn-level retry of the same
  request would spend the same bound again for the same stall.
- *Mark the task needs-input at once and notify.*  That is honest but it
  is not recovery: the reported stall was infrastructure, and the work
  would have carried on by itself a minute later.  The bound means a real
  outage still stops for the user, with the reason on the card.
- *Retry forever.*  Rejected: a provider that is really down would keep a
  slot busy for ever, and the reported incident was a stall, not an
  outage.

### 3. The reason is recorded durably

Three places now hold what ended a turn, each for a different reader:

- the agent writes `:last-turn` on the session's runtime when the turn
  ends -- `:reason`, `:error`, the failure's `:kind` and when -- before
  `agent/turn-ended` is emitted, so a subscriber (the tasks module) can
  read it;
- the tasks module leaves a hint on the session, `turn ended: error —
  <first line of the error>`, so the transcript answers the question on
  its own;
- the task records the error itself (`:error`), so the card and
  `task/retry`'s prompt name it.

The first line only: a provider's answer can be long, and a hint is not
the place for it.

## The shape of the change

- `lisp/modules/harness-provider-openrouter.el`: `--pin-refusal`'s UNREAD
  argument; `--pin-from` and `--complete-unread`; the fallback in
  `--complete-pinned` and `--complete-new`; the `openrouter/catalogue-unread`
  event.
- `lisp/modules/harness-perms.el`: `:pin-from` on the judge's and the
  summary's request.
- `lisp/modules/harness-agent.el`: `:last-turn` on the session's runtime
  at `--end`.
- `lisp/modules/harness-tasks.el`: the `stalled` hold and its helpers
  (`--stall-hold`, `--stall-delay`, `--stall-bound`, `--stall-try`,
  `--stall-exhausted-hint`, `--turn-end`, `--turn-end-reason`,
  `--transient-turn-p`, `--turn-end-hint`, `--say`); the new branch in
  `--on-turn-ended`; `--compute-hold`; `--return-reason` and `--opening`;
  `--on-turn-started`'s clearing of the retry state; the options
  `harness-tasks-stall-retries`, `harness-tasks-stall-retry-delay`,
  `harness-tasks-stall-retry-max-delay` and `harness-tasks--stall-message`.
- `lisp/ui/harness-ui-tasks.el`: the `stalled` label for a return reason,
  and the hold text (which already renders `stalled · retry 05:12`).
- Tests: `harness-provider-openrouter-test.el` (three: the judge rides
  the pin, no pin still refuses, a pin the policy refuses is not ridden);
  `harness-tasks-test.el` (five: the stall retry, its bound, a permanent
  failure is not retried, the transcript hint, the retry off).

## What this does not do

- It does not touch the transport's 600 s timeout or the catalogue's
  20 s one.  A 600 s request timeout under load is a separate question,
  and shortening it changes what a slow model may take.
- It does not retry the *catalogue* read for a step: that is the retry
  layer's and the background re-read's, as before.
- It does not make a denied call allowed.  A judge that gives no verdict
  still denies in a non-interactive session; only the reason it gives no
  verdict is no longer a stalled bookkeeping read when a pin is known.
