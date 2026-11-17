# A System 1 model for live workspace threading

Design note, November 2026. The decision is one question about one
incoming message: *does it continue the thread the person is writing
in?* The model is
[lisp/modules/harness-thread-model.el](../lisp/modules/harness-thread-model.el);
its training, evaluation and serving code is
[scripts/thread-model/](../scripts/thread-model/); its numbers are in
[the model card](../scripts/thread-model/MODEL_CARD.md).

**This work ships the model as unproven and leaves it off by default.**
On its held-out cases it does not rank better than the word rule it would
refine. The rest of this note says what was built, what the numbers are,
and what it would take to turn it on — because the wiring is the part
that is done, and the honesty about the numbers is the part that makes it
usable.

## The problem

`harness-workspace--route` places a message by its words. Each thread is
a small document — its title, its summary, its last messages — and a
message is ranked against them as a query is ranked against documents. A
thread that holds enough of the message's words keeps it; a message with
three content words no thread holds starts a new one; everything else
stays where the person was writing.

That rule is local, instant and free, and it is right about most
messages. It is wrong in two ways that matter:

- **A message that shares a word with its thread continues it**, even
  when the person changed subject: "the tax colour is still undecided"
  stays in the taxes thread when the kitchen thread is what is open, and
  a message about the *plumbing* of a kitchen whose thread is about its
  *tiles* shares "kitchen", "sink" and "cabinet" and is read as the same
  job.
- **A message that shares no words with the thread it belongs to starts
  a new one**: "and the second one?" after a list of three quotes.

Neither is a word problem. Both are questions about what the message is
*about*, which is what a small model that reads the message with the
thread can answer.

## What decides, and what does not

The model answers **one number**: P(the message continues the current
thread). Its complement is *not* a choice of another thread. A message
that does not continue this one may belong to an older thread or to no
thread yet, and which of those it is stays with the router, which has the
threads themselves. A model asked to name another thread would be
answering a question its input does not contain.

Two settings, not one, because the two mistakes cost differently:

- a wrong **switch** moves a message the person did not move, or starts a
  thread for a subject that had one;
- a missed switch leaves a new subject in the old thread, where the
  person can still move it.

One threshold cannot be both. So `harness-thread-model-trust` is read at
both ends: at or above it the message continues, at or below one minus it
it does not, and between them the model says nothing and the router keeps
its own rule. The number is not a boolean because a boolean cannot say
how sure the model is, and the threshold is the whole design.

## Where it sits

The model is asked **only where the word rule does not settle it**
(`harness-workspace--route-close-call-p`): the current thread holds some
of the message but not clearly enough, and no other thread holds it much
better. A message the current thread clearly holds, and one it holds
nothing of, are decided by the words alone and never reach the model.
That is what makes it a reflex in front of an ambiguous call rather than
a second opinion about every message.

**Explicit signals win, always.** A thread the person named, a client
that bound the thread, `/new`, a message that says `/continue` and a
thread the person picked all decide in `harness-workspace--route` before
the final branch that consults the model. The manual reassignment
(`workspace/reassign`) is the person's answer about a message already
sent, and nothing here touches it.

**A failure is no reading.** A model with no weights, a predictor that
died, a call past its timeout, an error inside the reading: each leaves
the router exactly where it would have been, and the message is placed by
the words. A routing decision is not a place to lose a message because a
subprocess fell over.

## What the model reads

One rendered text (`schema.render_case`), and nothing else, so a
training run and an inference call read one shape:

```
Task: <the workspace's name>
Current thread: <the thread's title>
Thread so far:
- user: <an earlier message>
- assistant: <an earlier reply>
Knowledge:
- <a graph block available at decision time>
Message to place:
- <the incoming message>
```

Three rules about it:

- **Decision-time information only.** The thread so far is the messages
  *before* the incoming one; the knowledge lines are the search results
  that existed then. A later message, a page curated afterwards, and the
  answer the label was taken from never appear.
- **A missing part is missing, not filled in.** The renderer is total: no
  title writes `(untitled)`, no context writes no `Thread so far:`, no
  graph writes no `Knowledge:`. A malformed or partial context still
  renders, and what the model does with it is measured.
- **The message is last and set apart.** Everything before it is context;
  without the separation a model trained on the whole text averages the
  messages and answers about the stretch, not about the message.

## The label

`continue` — the message is part of the current thread's topic, as the
person meant it. `switch` — it is not.

The label is about the *topic of the conversation*, never about which
conversation a log filed the message under. The source conversation id is
sampling metadata: it says where the text came from, never what the label
is. Two consequences the data honours:

- a conversation that changes subject midstream is a `switch` at that
  message, even though it is the same conversation;
- a message spliced in from another conversation is a `switch`, even when
  the two conversations share words.

Where the text cannot settle it — "ok", "and then?", "the other one" — a
case may carry `uncertain`, trains with half weight, and is reported in
its own slice rather than counted as an ordinary error. No committed case
is uncertain: the generator's own subject record settles them, and the
cases it did not settle were left out rather than guessed.

## Data and leakage

68 synthetic conversations over 10 scenario families, 445 cases, plus
the splices cut from them. The log half — `dataset.read_store`, which
reads `sessions/*.nodes.jsonl` and `workspaces/*.json` in place — is
written and held to a fixture log by the tests, but was not run here:
this session's sandbox has no user store to read. The provenance file
names every source and how many cases came from each.

The leakage rules are the reason `dataset.py` is separate from the
schema:

- **splits are by near-duplicate group**, computed over the whole set
  before any case is assigned: two cases whose content words overlap by
  0.6 or more are one group, a synthetic variant joins its source's
  group, and a splice is its own group so a set's negatives do not
  collapse into one. `build_set.py` refuses a set where a group is on two
  sides;
- **the split is stratified on the label as well as the size**. A hash
  alone put every switch in train on the first attempt and left the test
  split with nothing but continuations to measure — an accuracy that says
  nothing. Every group stays whole; only the choice of side changes.

## The numbers, and what they say

Held-out split, 70 cases, after temperature scaling fitted on `val`:

| reading | model | word-overlap rule | graph only | majority |
| --- | --- | --- | --- | --- |
| AUC | 0.681 | **0.712** | 0.500 | — |
| accuracy | 0.429 | 0.443 | 0.314 | **0.686** |
| Brier | 0.250 | 0.545 | 0.686 | 0.216 |

`evaluate.py` writes a verdict beside its numbers, and this model's is
`unproven`: it does not rank better than the rule it would refine, it is
less accurate than guessing the majority, and at the shipped threshold it
abstains on every case. The card says so at the top, and the module's
default is off for that reason.

The one place it does better: on the 17 spliced cases it gets 16 right,
where the word rule gets most of them wrong. That is the hard negative
the data was built to include, and one slice of 17 is not a reason to
ship.

Why the numbers are weak: 445 synthetic cases is small for a fine-tune,
and the generator writes the same family of subject change repeatedly, so
the test split is a variation on the training split rather than a new
population. The model that would be worth shipping needs the authorized
log half, which is where the real distribution of a person's messages
lives.

## Latency and failure

On this machine, 8 threads, CPU only: 2.46 s to load the weights, 5.9 ms
median for a warm decision (7.8 ms p90). The module keeps the predictor
warm (`predict.py`, a JSON-lines server) and bounds the wait with
`harness-thread-model-timeout` (2 s), so a slow model is the same as no
model and the words decide.

What the evaluation holds the model to, on the same held-out cases: no
graph blocks, no thread context, no title, a truncated message and an
empty text. Removing the context costs 0.015 AUC and truncating the
message 0.068; an empty text is the model's prior, at chance. The router
routes identically on any of them.

## Alternatives

- **A completion model per message.** It would answer the same question,
  better, for a few hundred milliseconds and a fraction of a cent each,
  on every message the person types. A reflex that costs a network round
  trip is not a reflex, and the point of the exercise is the local one.
- **A second word rule.** Cheaper, and it is what the router already has:
  the measurements above are against exactly that rule, and it wins.
- **A classifier over every thread at once.** It would answer "which
  thread", not "this one or not", and it would have to be retrained every
  time the person adds a thread. The binary question is the one whose
  answer does not change when the workspace does.
- **Thresholding the model's number as a decision, with no abstention.**
  Then every message is moved by a model that is unsure of most of them,
  and the mistakes are the expensive kind. The abstention band is what
  makes the reflex safe to leave wired in.
- **Shipping it on, with the numbers in a footnote.** The wiring is
  correct and the model is not better; turning it on would spend 6 ms a
  message to route worse than the words. The default is off, and the card
  says why.

## What it would take to turn it on

1. Run `build_set.py --state-directory <authorized store>` on real logs,
   which is the half of the data this set does not have.
2. Re-train and re-evaluate: the verdict in `data/report.json` must read
   `ship` — an AUC above the word rule's, an accuracy above the majority
   baseline's, and a threshold that decides something.
3. Set `harness-workspace-thread-model` to t, and watch the wrong-switch
   count in the workspace's own timeline.

Until then the module is infrastructure: the schema, the dataset, the
trainer, the evaluation and the router wiring all work, and the model
they carry is not yet worth its latency.

## The shape of the change

- `scripts/thread-model/schema.py`: the decision's contract — the
  rendered text, the labels, the features, the case.
- `scripts/thread-model/dataset.py`: logs read in place, the label rules,
  near-duplicate grouping, the stratified split, splices.
- `scripts/thread-model/gen_conversations.py`: the synthetic generator.
- `scripts/thread-model/build_set.py`: the set, with its provenance and
  the leakage check.
- `scripts/thread-model/train.py`, `evaluate.py`, `predict.py`: the
  fine-tune (calibration-aware checkpoint choice, uncertain cases
  down-weighted), the evaluation (calibration, thresholds, slices,
  baselines, degraded inputs, the verdict), the warm server.
- `scripts/thread-model/MODEL_CARD.md`, `data/`: the numbers and the set.
- `lisp/modules/harness-thread-model.el`: the predictor, the rendering,
  the threshold, the tool, the status.
- `lisp/modules/harness-workspace.el`: one defcustom, the close-call
  test, and the final branch of `harness-workspace--route`.
- `lisp/modules/harness-thread-model-test.el` and
  `test/harness-thread-model-test.py`: the module's half and the model's
  half, the second run from the first.
