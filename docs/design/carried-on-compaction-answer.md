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

The first fix was a latch: the answer stood, per session, while the
conversation could still be sent, and the question came back only when
the conversation changed. That stopped the repeated asking in the
reported case, but it kept two limits the user then asked against: the
answer stopped at the window, and there was no lasting answer at all.
The user's words: "make sure that the user can always carry on without
these nags. there is nothing worse then working on something and then
an auto compact happens and makes your session into an idiot."

So the question has an "always" now, and carrying on is always a
choice, past the window too.

## The decision

An answer to carry on stands, per session, until the conversation
changes:

- The question is not put again at the next steps of the turn, nor
  before the next turn, nor at the turns after it, past the model's
  window as well as within it. A provider that cannot send the
  conversation says so; the harness does not take the choice away.
- The question comes back once a boundary has found the context under
  the limit: a compaction, a cut or a conversation given back has made
  it another conversation, and the next question about it is a new one.
- Any other answer (a kind, later, a dismissal) forgets the earlier
  carry-on, as the session's end does.
- The capital of Continuation answers "always carry on": it saves
  `harness-compaction-carry-on`, and every session that would wait for
  the user then carries on without the question. It is a setting, shown
  and turned off in Settings, not a per-process latch; a session that
  never waits for the user does not take it, so unattended work still
  compacts rather than failing on an overgrown context.
- Carrying on is the default choice of the question: a careless RET or
  Space carries on, rather than compacting the conversation.

The per-session answer is a table, `harness-compaction--carried-on`,
like the state of a mid-turn compaction and the one-turn hold a
reverted conversation gets: it is not kept across a restart, and a
restart asks once more. The lasting answer is the setting, saved. The
hint says what was chosen and why; nothing in the transcript changes.

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
- **Keep the latch and no lasting answer.** Rejected by the user: it
  still nags, and it still stops at the window. The question exists so
  the user can keep working; "always carry on" is that answer made
  lasting.
- **Let "always carry on" apply to unattended sessions too.** Rejected:
  a task has nobody to notice a provider refusing an over-window
  request, and its work must not stall. It applies only where someone
  can be asked (`harness-compaction--carry-on-always-p`).
- **Persist the per-session answer in the session record**, so a restart
  keeps it. The answer is a convenience for a conversation that changed
  under the user's eyes; the lasting choice is the setting, and the two
  neighbours of this table (the mid-turn state and the reverted
  conversation's hold) are not persisted either.

## The shape of the change

- `harness-compaction--carried-on`: session id -> `t` while the answer
  stands, with `harness-compaction--carried-on-p` (has the answer) and
  `harness-compaction--note-answer` (carry on sets it, anything else
  forgets it).
- `harness-compaction-carry-on`: the lasting answer, saved by the
  capital of Continuation (`harness-compaction--save-carry-on`), and
  `harness-compaction--carry-on-always-p`, which lets a session that
  would wait for the user go on unasked.
- `harness-compaction--asked-before-turn` and
  `harness-compaction--asked-before-step` record every answer as it
  arrives.
- `harness-compaction--before-turn`: while the answer stands, or the
  lasting one does, the message goes on unasked; a turn whose context is
  under the limit forgets the per-session answer.
- `harness-compaction--before-step`: the same at step boundaries, past
  the window too.
- `harness-compaction--on-deleted` forgets it with the session.
- The module commentary and `docs/architecture.md` say what stands and
  for how long.
- Tests in `lisp/modules/harness-compaction-test.el`: a six-step turn
  and the turn after it ask once; past the window the answer stands;
  under the limit the answer is forgotten and the next approach asks
  again; a step past the window asks at once without an answer; "always
  carry on" saves the setting and stops the asking in a session that
  waits for the user, while an unattended session still compacts. The
  first
  fails without the latch (the boundary before the fifth step asks
  again), the last without the bypass.

## Verification

The compaction suite, then the whole suite on the committed tree. The
reported session is the evidence that the old behaviour was the
problem: its transcript has the carry-on hint at ~365k followed, three
steps later, by the question at ~368k.
