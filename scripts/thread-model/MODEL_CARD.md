# Thread-continuation model

A small encoder that reads an incoming workspace message with the thread
it arrived in and answers one number: the probability that the message
continues that thread. The workspace router (`harness-workspace--route`)
asks it only where its own word rule cannot separate the message, and
reads the number with a trust threshold of its own
(`harness-thread-model-trust`).

**The shipped model is unproven.** `evaluate.py` writes a verdict beside
its numbers, and this one is `unproven`: on the held-out cases the model
does not rank better than the word rule it would refine, it is less
accurate than guessing the majority class, and at the shipped threshold
it abstains on every case. It is committed as infrastructure -- the
schema, the dataset, the trainer, the evaluation and the Emacs module
work, and the numbers below say what the model itself is worth -- not as
a routing improvement. Read [Verdict](#verdict) before enabling it.

## Base

`sentence-transformers/all-MiniLM-L6-v2` — 22.7M parameters, Apache-2.0,
a 512-token window, and the standard `AutoModelForSequenceClassification`
fine-tuning path. The same base as the tool-call classifier
(`scripts/system-one/`), and for the same reason: a routing decision is
made while the person is typing, so the smallest encoder that reads the
window is the right one. `train.py` and `predict.py` are this decision's
own, not a copy of the classifier's: the schema, the label rule and the
calibration step differ, and the two are meant to stay separable.

## What it reads

One rendered text (`schema.render_case`), in this order:

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

Every part is optional and the renderer is total: a thread with no title
renders `(untitled)`, no context writes no `Thread so far:`, no graph
writes no `Knowledge:`. The message is last and set apart, because it is
what the answer is about.

## The label

`continue` — the message is part of the current thread's topic, as the
person meant it. `switch` — it is not: the topic changed, or the message
belongs to a different subject altogether.

The label is about the topic of the conversation, never about which
conversation a log filed the message under. A conversation that changes
subject midstream is a `switch` at that message; a message spliced in
from another conversation is a `switch` even when the words match. The
complement of `continue` is **not** a choice of another thread — the
model says "not this one" and the router decides where else it goes.

## Data

445 cases from 68 conversations, all synthetic (`data/conversations.jsonl`,
written by `gen_conversations.py` over 10 scenario families), plus the
splices cut from them. `data/set.json` is the provenance file.

| | cases | continue | switch |
| --- | --- | --- | --- |
| train | 313 | 210 | 103 |
| val | 62 | 39 | 23 |
| test | 70 | 48 | 22 |

**The log half is written but was not run here.** `dataset.read_store`
reads `sessions/*.nodes.jsonl` and `workspaces/*.json` in place, and
`build_set.py --state-directory` uses it; the tests hold it to a fixture
log. This session's sandbox has no user store to read, so every committed
case is synthetic. On a machine with authorized logs the same pipeline
runs on them, and the provenance file names the directory it read.

**Leakage rules, in code.** Splits are by near-duplicate group
(`dataset.groups`), computed over the whole set before any case is
assigned: two cases whose content words overlap by 0.6 or more are one
group, a synthetic variant joins its source's group, and a splice is its
own group so a set's negatives do not collapse into one. `build_set.py`
refuses a set where a group is on two sides. The split is stratified on
the label as well as the size, because a hash alone put every switch in
train on the first attempt and left the test split with nothing but
continuations to measure.

**Ambiguity.** A case may carry `uncertain`, and then it trains with half
weight and is reported in its own slice. No committed case is uncertain:
the generator's own subject record settles them, and the cases where it
does not were not labelled rather than guessed.

## Verdict

Held-out split, 70 cases, after temperature scaling fitted on `val`:

| reading | model | word-overlap rule | graph only | majority |
| --- | --- | --- | --- | --- |
| AUC | 0.681 | **0.712** | 0.500 | — |
| accuracy | 0.429 | 0.443 | 0.314 | **0.686** |
| Brier | 0.250 | 0.545 | 0.686 | 0.216 |

- **It does not beat the word rule.** The router's own word-overlap
  score ranks these cases better (AUC 0.712 against 0.681) on the same
  cases and the same information.
- **It is worse than guessing.** Accuracy 0.429 against the base rate of
  0.686: on this set the model is wrong more often than "always
  continue".
- **It is badly calibrated.** ECE 0.186 after temperature scaling, and
  the fit ran to the top of its range (T = 64), which means the head's
  probabilities carry little more than the ranking does.
- **The threshold decides nothing.** The largest trust with no wrong
  switch on `val` is 0.95, and no held-out case reaches it: the reflex
  would abstain on every message.

The one thing it does better: on the 17 spliced cases (a real message in
a foreign context) it gets 16 of 17 right, where the word rule gets most
of them wrong. That is the hard negative the data was built to include,
and one slice of 17 is not a reason to ship.

## Why the numbers are weak

The set is 445 cases, which is small for a fine-tune of a 22M-parameter
encoder, and it is synthetic: the generator writes the same family of
subject change over and over, so the test split is a variation on the
training split rather than a new population. The model that would be
worth shipping needs the authorized log half (`--state-directory`), which
is where the real distribution of a person's messages lives. The
evaluation's verdict is a reading of this data, not a claim that the
approach cannot work.

## Threshold

`harness-thread-model-trust` is 0.9 by default: at or above it the
message continues, at or below one minus it the message does not, and
between them the router keeps its own rule. `evaluate.py` reports, for
each candidate value, how many cases it would decide and how many it
gets wrong, in both directions — a wrong switch moves a message the
person did not move, a missed switch leaves a new subject in the old
thread.

The threshold is chosen on `val` as the largest trust whose wrong
switches stay within `--max-wrong-switch` (2 by default). It is not
tuned on `test`.

## Degraded inputs

The same held-out cases with one part missing or malformed:

| input | AUC | accuracy |
| --- | --- | --- |
| as written | 0.681 | 0.429 |
| no graph blocks | 0.681 | 0.429 |
| no thread context | 0.666 | 0.414 |
| no title | 0.671 | 0.429 |
| message truncated | 0.613 | 0.429 |
| empty text | 0.500 | 0.314 |

A missing graph changes nothing (the committed cases carry no knowledge
blocks, so this row is the same model on the same text). Removing the
context costs 0.015 AUC, removing the title 0.010, truncating the message
0.068. An empty text is the model's prior, at chance.

## Latency

Measured on this machine, 8 threads, CPU only:

| | |
| --- | --- |
| load the weights (cold) | 2.46 s |
| one decision (warm, 384-token window) | 5.9 ms median, 7.8 ms p90 |

The module keeps the predictor warm (`predict.py`, a JSON-lines server)
and bounds the wait with `harness-thread-model-timeout` (2 s): a call
that takes longer is left to the router's own rule, which is why a slow
model is the same as no model.

## What it does not do

- It never overrides an explicit signal: a named thread, a bound thread,
  `/new`, a message that says continue and a message the person moved by
  hand all decide before the model is asked.
- It never names another thread. "Does not continue this one" is the
  whole of its negative answer.
- It never runs with no model: `harness-thread-model-available-p` is
  false, the router asks nothing, and the workspace behaves as it did.
- It does not touch the manual reassignment (`workspace/reassign`), which
  stays the person's overriding answer about a message already sent.
