# A compaction answers the cold cache it made

## The problem

Noah's report: "if a compaction happens then a stale cache warning
shouldn't show bc we basically already choose one of the options.
Compacting compaction results again wouldn't help."

The cold-cache gate (`harness-cowboy.el`) asks what goes first when a
message meets a session whose prompt cache lapsed.  A compaction is one
of its answers: the conversation is replaced by a summary, a transcript
note or nothing, so the message sends what stands in for it.  The gate
then asked again as soon as *that* conversation's own cache lapsed --
minutes later, while the conversation was still exactly the compaction's
result.  The cache panel (`harness-ui-cache.el`) offered the same four
rows at the same moment.  Every answer on offer compacted the summary of
a summary, which saves what the first compaction saved.

Two things made it worse than a nuisance.  The panel's rows and the
gate's question are the *same* list, so a user who answered once was
asked to answer again in a different place; and a task session, which
nobody is watching, took the default unasked and compacted its own
summary a second time, losing the detail the first summary kept.

## What the investigation found

The warning did not, in fact, survive the compaction itself.  A probe of
a real session showed `:cache` nil immediately after a compaction, and
the turn after it stamping a fresh cache: there is no path by which the
question outlives the compaction that answers it.  `compaction/compact`
with `:idle t` refuses while a turn runs ("session running · compact
after the turn"), and a queued or interrupt compaction cancels the
turn, which dismisses a pending question.  So the earlier design note
in `harness-cowboy.el` was right about the immediate case.

What was wrong was the *late* case.  Once the fresh cache of the
compaction's own result lapsed -- five minutes for Claude, hours for
DeepSeek -- the gate found a cold cache again and asked about a
conversation that was still the compaction's result.  A probe printed
the two compactions: `Compaction · ~3.0k tokens · transcript` followed
by `Compaction · ~430 tokens · transcript`.  That is the report.

## The decision

A compaction resolves what goes first **for the conversation it made,
until that conversation has grown back to the size the compaction
replaced**.  That size is the node's own `:meta` `:input-tokens`: the
number of tokens the compaction was worth making for.  Below it, the
answer stands and nothing asks; at or above it, the conversation is a
new situation and the question is a real one again.

One rule, three readers, and no new state to keep in step:

- `harness-compaction-settled` is the rule, in the compaction module
  that owns what a compaction means.
- The gate reads it through `harness-cowboy--settled-p`, and lets a
  cold message go through unasked.
- The cache panel reads it through `harness-ui-cache--settled-p`, and
  draws nothing.

Cache reporting is untouched.  `harness-cowboy-cold-p` goes on reading
the lapse, `:cache` goes on saying when the cache expired, and the
header's cache rate is unaffected: resolving a decision is not evidence
that a prompt is cached, and nothing here claims warmth.  The panel and
the question are about what goes first, which is what was decided.

Failed, cancelled and reverted compactions settle nothing.  A failed
compaction appends no node, so there is no `:input-tokens` to stand on;
a dismissed question leaves the message held; a reverted compaction is
not in force (`harness-node-compaction-in-force-p`), so the
conversation is the one before it and the old question is open again.

## The shape of the change

**The answer is carried, not derived.**  The first version computed it
in `harness-session-plist` from `session/nodes` on every record read.
Probing that found a regression worth recording: 3.2 ms per record read
on a 2000-node session, and `session/list` loading every session's node
log -- 34.5 ms for three sessions, with all their nodes pulled into
memory.  The session module's own commentary says node logs are loaded
lazily so listing a thousand sessions stays instant, and this broke
that.

So the record carries the answer:

- A new slot on the session struct, `compaction`, saved with the record
  and announced like any other change.
- `session/set-compaction` sets it; the compaction module calls it when
  it makes a compaction (`harness-compaction--finish`), when one is
  reverted or restored (`harness-compaction--toggle`), and the session
  module calls it when a node or a head goes that could have named it
  (`session/discard-nodes`, `session/set-head`).
- `harness-session--compaction` compares that against the record's
  `:usage :context`, which the record already carries, so the derived
  `:compaction` key stays O(1) and a listing loads no node log.  After
  the change: 0.01 ms per read, 0.1 ms for `session/list`, no node logs
  loaded.

A record written before the slot existed has no answer, and the
conversation may well start at a compaction.  The cold-cache gate
reads it once, for a record that has none -- that is the only place
where the answer matters enough to pay for a transcript walk -- and
keeps it with the record (`harness-cowboy--settled-p').

An earlier version read every saved session once at the module's
start.  That was dropped: it walks every session's node log at startup
for a case the gate already covers lazily, and a cost paid by every
harness start is worse than one paid by the first cold cache of a
session compacted before the key existed.

The UI reads the record only.  That is a requirement, not a
simplification: a UI on another machine holds the session record and
nothing else, so a panel that called `session/nodes` to decide whether
to draw would fail there.  The UI test suite caught exactly that when
the first version of the panel helper did call the harness.

**No Flutter change.**  The app has no cache panel; its cold-cache card
is the *question* (`harness_client/lib/src/ui/widgets/interaction_card.dart`,
`Cold prompt cache`), which the harness now simply asks less often.
The behaviour is consistent because there is only one gate.

## Alternatives considered

- **Remember the answer in a table, keyed by session id.**  Rejected:
  a table is process state, so a restart would ask again -- which is the
  bug, one restart later -- and it does not reach a UI on another
  machine.
- **Never ask after a compaction until the conversation is compacted
  again.**  Rejected: a conversation that grows back to what was
  replaced has earned a new question; refusing to ask it would send a
  huge context uncached or compact too late.
- **Compare against the context the compaction left instead of what it
  replaced.**  Rejected: that threshold is a few hundred tokens, so the
  very next turn would cross it and ask again -- the same bug with a
  different number.
- **Stamp the cache warm after a compaction**, so the gate finds it
  warm.  Rejected outright: it is a lie.  A compaction leaves nothing
  cached, and the first request after it writes a new cache.
- **Suppress the warning only in the UI**, leaving the gate to ask.
  Rejected: a task session is never asked, so it would still compact its
  own summary unasked.  The gate is where the decision is.
- **Keep deriving the answer in `harness-session-plist`.**  Rejected on
  the measurements above.

## Tests

- `harness-cowboy-a-compaction-answers-the-next-lapse`: the compaction's
  own result goes cold; no question, one compaction, the turn ends, and
  the cache is stamped by the turn's own request.
- `harness-cowboy-a-settled-session-says-so-on-its-record`: the record
  carries the compaction, says nothing once the conversation grows back,
  nothing when reverted, and the compaction again when restored.
- `harness-cowboy-a-settled-record-survives-a-restart`: the answer is
  read from the saved record without the node log being loaded; a record
  without it is read once by the upgrade, and the gate finds it even
  with nothing on the record.
- `harness-cowboy-a-compaction-that-failed-answers-nothing`: a failed
  compaction leaves the question as it was.
- `harness-cowboy-a-queued-message-meets-the-settled-answer`: a message
  queued behind the turn meets the answer, not a question.
- The six existing cowboy tests that assumed a re-ask after a compaction
  now assert the answer stands at `:context 430`, and that a
  conversation grown back to `:context 3600` asks again.
- `harness-ui-cache-panel-stays-away-once-a-compaction-settled-it`: no
  state and no panel for a settled record, the lapse still reported, the
  exact banner strings for a grown-back conversation, and a record
  without the key reading as before.
- `harness-session-reload-upgrades-old-records` gained the sixth slot.

## Evidence

The probes are in the task's evidence: the before/after record cost, the
`session/list` node-log measurement, the end-to-end gate probe (no
question, one compaction), and the restart walk.

`docs/evidence/compaction-cold-cache/cache-panel-after-a-compaction.png`
is the panel itself, as `harness-ui-cache--banner` draws it for a session
a compaction settled: nothing for the settled conversation, the four rows
again once it grows back past what the compaction replaced, and the
expiry still reported in both.

`demo/compaction-cold-cache/demo.sh` runs the same cases as a program:
the real gate, the real panel and the real record against real sessions.
