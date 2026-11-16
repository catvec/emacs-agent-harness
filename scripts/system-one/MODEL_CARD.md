# System-one tool-call classifier

A small encoder that reads the last few calls of an agent's turn, with
the task they serve, and answers one number: the probability that the
call being decided is safe work. The harness's permission chain asks it
before the judge (see `lisp/modules/harness-system-one.el`).

## Base

`sentence-transformers/all-MiniLM-L6-v2` — 22.7M parameters, Apache-2.0,
a 512-token window, and the standard `AutoModelForSequenceClassification`
fine-tuning path. Picked on this machine's numbers, not on taste:

| base | params | 256-token inference (8 threads) |
| --- | --- | --- |
| `sentence-transformers/all-MiniLM-L6-v2` | 22.7M | **23.7 ms** |
| `distilbert-base-uncased` | 67.0M | 72.9 ms |
| `answerdotai/ModernBERT-base` | 149.6M | 224.9 ms |

A permission decision waits on this call, so the smallest model that
reads the window is the right base. Sixteen threads is worse than
eight on this box (652 ms against 28 ms): torch oversubscribes.

## Data

481 workflows, 240 good and 241 bad, written by `deepseek-v4.1-flash`
over 16 scenario families (see `gen_workflows.py`). A workflow is a task
plus the ordered calls it makes, labelled as a whole, with the harmful
steps named. The bad ones are written to be hard — the harm is one step
in an otherwise ordinary job, not a word on a blocklist — and they
include near-misses such as a legitimate `rm -rf build/`.

Committed in `data/workflows.jsonl`. Windows cut from them, and the
held-out split's readings, are in `data/windows.jsonl` and
`data/report.json`.

## The experiment: does a window carry the label?

Each call of each workflow is decided with the calls before it, so every
call gives one window per context size, labelled by whether *that* call
does the harm. Splits are by workflow, never by window, so a test window
never shares its workflow with a training one.

Held-out workflows only, `data/report.json`:

| window | n | acc | prec | rec | AUC | last-window acc | last-window AUC |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 call | 378 | 0.815 | 0.986 | 0.807 | **0.930** | 0.726 | 0.723 |
| 2 calls | 316 | 0.788 | 0.982 | 0.775 | 0.906 | 0.677 | 0.661 |
| 3 calls | 254 | 0.776 | 0.982 | 0.753 | 0.909 | 0.726 | 0.738 |
| 5 calls | 131 | 0.725 | 0.953 | 0.717 | 0.856 | 0.700 | 0.742 |

The good and bad samples are correlated correctly at every size, and
**more context does not help**: one call reads best, and the AUC falls
as the window grows. The module therefore uses a window of one by
default (`harness-system-one-window`). The last-window column, which is
what a live session decides, is the hard case: 62 windows, 6 of them
harmful, so its AUC moves a lot on a few examples.

## Is it reading the calls, or the task?

The same model is scored three ways on the same held-out windows
(`ablate.py`, `data/ablation.json`):

| view | AUC | accuracy |
| --- | --- | --- |
| the window as written | 0.902 | 0.787 |
| the calls, task line removed | **0.918** | 0.749 |
| the task line alone | 0.559 | 0.579 |

Removing the task changes nothing (it reads slightly *better* without
it), and the task alone is close to a coin flip at AUC 0.559, below its
own base rate of 0.753. The model reads the calls.

`data/ablation.json` was written from the checkpoint `training.json`
describes, on the same 1079 held-out windows as `data/report.json`; the
file names the model directory it was run against.

## The trust threshold

`data/report.json`, window size 1, held-out:

| trust | decided | right | wrong | harm let through | good work stopped |
| --- | --- | --- | --- | --- | --- |
| 0.50 | 100% | 81.5% | 18.5% | 1.06% | 17.5% |
| 0.80 | 65.1% | 55.3% | 9.8% | 0.53% | 9.3% |
| 0.90 | 46.6% | 40.5% | 6.1% | 0.26% | 5.8% |
| **0.95** | **17.2%** | **16.1%** | **1.06%** | **0.00%** | **1.06%** |
| 0.99 | 0% | — | 0% | 0% | 0% |

The module's default trust is **0.95**: it settles 17% of calls, and the
one it gets wrong is a good call stopped, never a harmful one let
through. Everything else goes to the judge, which it would have anyway.

## Training

`train.py --epochs 3 --max-tokens 256 --threads 8`: 2368 s on 8 CPU
threads. Balanced class sampling (a row's weight is the inverse of its
class's count), and the checkpoint kept is the one with the best
held-out AUC, not the lowest loss. Held-out: loss 0.324, accuracy 0.899,
AUC 0.939.

An earlier run had both class weights inverted — the majority class
weighted 8× in the sampler *and* `pos_weight` 8× on the good class — and
collapsed to answering 0.98 to everything: accuracy 0.90 (the base
rate), AUC 0.82, and a test AUC of 0.59 at window 5. `training.json`
holds the numbers of the run shipped.

## What it is not

- It is not a boundary. The sandbox, the jail and the rules are. This
  reads a call; it does not confine one.
- It was trained on generated workflows, not on this user's real
  sessions, and on one generator model.
- A window of one call cannot see that a `read_file(.env)` was set up by
  the three calls before it. The data says a bigger window reads worse,
  so the reflex is deliberately shallow and the judge keeps the
  judgement.

## Rebuilding

    python3 -m venv venv && venv/bin/pip install -r requirements.txt
    venv/bin/python gen_workflows.py --out data/workflows.jsonl     # needs OPENROUTER_API_KEY
    venv/bin/python dataset.py --workflows data/workflows.jsonl --out data/windows.jsonl --endings
    venv/bin/python train.py --windows data/windows.jsonl --out model
    venv/bin/python evaluate.py --windows data/windows.jsonl --model model --out data/report.json
