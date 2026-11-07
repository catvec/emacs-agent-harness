# A carry-on answer that stands

## The problem

The automatic compaction question asks before a turn and, with
`harness-compaction-mid-turn` on, at the boundaries in the middle of
one. A conversation near its window stays near it: the next steps grow
it by a few thousand tokens and it is still over the limit, so the
question comes again.

That is what happened in the task session "Isolate task /tmp via mount
namespace": the answer to carry on was given at a context of about
365k of the 384k window, and three steps -- a few thousand tokens --
later the panel said "Context nearly full · ~368k of 384k tokens" and
asked again. The mid-turn cooldown
(`harness-compaction--mid-turn-cooldown`, three boundaries after an
answer, then six, twelve and twenty-four) paces a compaction that did
not help, and a boundary at which the question was answered counted as
one of its tries; before a turn, nothing paced it at all. Clicking
carry on again and again costs attention and answers nothing new: the
user already decided to send the near-full conversation uncached, and
the situation did not change.

The question is not one with an "always": every automatic compaction is
the user's to decide, and a lasting default would let the conversation
grow past what the model can be sent. What is wanted is narrower: the
answer stands while it still makes sense, and is not asked again for
the same state.

## The decision

An answer to carry on stands, per session, while the conversation can
still be sent:

- The question is not put again at the next steps of the turn, nor
  before the next turn, nor at the turns after it, while the context is
  within the session's window.
- The question comes back once the context is past the window
  (`harness-compaction--window`): carrying on is then a request the
  model cannot take, and the choices no longer offer it, so the answer
  no longer applies. At a step boundary it comes back at once, not
  after the cooldown, because the next step is the request that cannot
  be sent.
- The question also comes back once a boundary has found the context
  under the limit: a compaction, a cut or a conversation given back has
  made it another conversation, and the next question about it is a new
  one.
- Any other answer (a kind, not now, a dismissal) forgets the earlier
  carry-on, as the session's end does.

The answer is a per-process table, `harness-compaction--carried-on`,
like the state of a mid-turn compaction and the one-turn hold a
reverted conversation gets: it is not kept across a restart, and a
restart asks once more. Nothing in the transcript changes; the hint
already says what was chosen and why.

## Alternatives

- **Ask again after a number of steps**, as the mid-turn cooldown does
  today. That is the behaviour reported: the context has grown by a few
  thousand tokens and the answer is the one already given. Step counts
  are a poor measure of how near the limit the conversation is.
- **Ask again only at the start of the next turn**, letting the answer
  stand for the rest of the turn. It fixes the reported case, but a
  task session's user is then asked again at every follow-up message
  about the same near-full conversation, which is the same complaint at
  a longer interval.
- **A lasting "always carry on" setting**, as the cold-cache question
  offers. It would let conversations grow past the window unasked, and
  the design keeps every automatic compaction the user's decision. The
  latch stops at the window, where carrying on is impossible, and at
  the limit, where the conversation changed.
- **Keep the answer past the window too.** The request would be refused
  by the model or the provider; carrying on is not among the choices
  there for that reason.
- **Persist the answer in the session record**, so a restart keeps it.
  The answer is a convenience for a conversation that changed under the
  user's eyes; the session record carries decisions with lasting
  meaning, and the two neighbours of this table (the mid-turn state and
  the reverted conversation's hold) are not persisted either.

## The shape of the change

- `harness-compaction--carried-on`: session id -> `t` while the answer
  stands, with `harness-compaction--carried-on-p` (has the answer, and
  the context is within the window) and `harness-compaction--note-answer`
  (carry on sets it, anything else forgets it).
- `harness-compaction--asked-before-turn` and
  `harness-compaction--asked-before-step` record every answer as it
  arrives.
- `harness-compaction--before-turn`: while the answer stands, the
  message goes on unasked; a turn whose context is under the limit
  forgets the answer.
- `harness-compaction--before-step`: the same at step boundaries, and
  where the user is asked, a step past the window asks at once rather
  than after the cooldown.
- `harness-compaction--on-deleted` forgets it with the session.
- The module commentary and `docs/architecture.md` say what stands and
  for how long.
- Tests in `test/harness-compaction-test.el`: a six-step turn and the
  turn after it ask once; past the window the question returns without
  carrying on; under the limit the answer is forgotten and the next
  approach asks again; a step past the window asks at once. The first
  fails without the latch (the boundary before the fifth step asks
  again), the last without the bypass.

## Verification

The compaction suite, then the whole suite on the committed tree. The
reported session is the evidence that the old behaviour was the
problem: its transcript has the carry-on hint at ~365k followed, three
steps later, by the question at ~368k.
