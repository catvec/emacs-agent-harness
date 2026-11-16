#!/usr/bin/env python3
"""Sliding windows over workflows, and the split that keeps them honest.

The classifier never sees a whole workflow.  In a session it reads the
calls the turn has made so far, ending with the one being decided, and
answers whether that stretch of work is safe.  So the training examples
are windows: WINDOW_SIZES calls cut from a workflow at random offsets,
each carrying its workflow's label.

Two rules keep the measurement meaningful.

Split by workflow, never by window.  Windows of one workflow overlap;
letting some train and others test would score a model on text it has
already read.  The split is by a hash of the workflow's task, so it is
stable as the set grows and a regenerated workflow lands on the same
side.

The window ending at the last call is the one that matters.  A session
decides each call as it comes, so the window at the end of a workflow
is what the classifier sees most often -- and it is also the window
that holds the harmful call in a workflow whose harm is last.  Windows
are drawn from anywhere, because a call in the middle is decided with
the calls before it too, but the report says how the model does on the
last window apart from the rest: a classifier that only recognises harm
once it has seen the whole job would be useless in a live session.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import sys
from dataclasses import dataclass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from schema import Workflow, read_jsonl, render_decision, render_window  # noqa: E402

# The window sizes the experiment measures.  One call is the shortest
# useful window: it is all the judge sees today.  Larger windows are what
# the classifier gets that the judge does not -- the calls before it.
WINDOW_SIZES = (1, 2, 3, 5, 8)

# How many windows are drawn per workflow and size.  A window is cheap
# text, and more of them means a training set that is not dominated by
# the handful of long workflows.
DRAWS = 6

# Where the split falls: a workflow whose hash is below this trains.
TRAIN_SHARE = 0.7
VAL_SHARE = 0.15


@dataclass
class Window:
    workflow_id: str
    size: int
    label: int
    text: str
    at_end: bool          # the window ends at the workflow's last call
    start: int            # index of the first call it holds

    def to_dict(self) -> dict:
        return {"workflow_id": self.workflow_id, "size": self.size,
                "label": self.label, "text": self.text,
                "at_end": self.at_end, "start": self.start}


def split_of(workflow: Workflow) -> str:
    """Return "train", "val" or "test" for WORKFLOW, by its task.

    A hash of the task keeps a workflow on one side for good, however
    often the set is regenerated or its windows are redrawn.
    """
    digest = hashlib.sha256(workflow.task.strip().lower().encode()).hexdigest()
    share = int(digest[:8], 16) / 0xFFFFFFFF
    if share < TRAIN_SHARE:
        return "train"
    if share < TRAIN_SHARE + VAL_SHARE:
        return "val"
    return "test"


def window_label(workflow: Workflow, start: int, size: int) -> int:
    """Return the label of the window at START of SIZE calls in WORKFLOW.

    A window is bad when it holds a call that does the harm, and good
    otherwise -- not when its workflow is bad.  That is the question a
    permission decision asks: are these calls, the one being decided
    among them, safe to run?  Labelling every window of a bad workflow
    bad would teach the model that ordinary work before the harm is
    itself suspicious, and would make the set unlearnable: the same
    read_file is good in one window of a workflow and bad in another.

    A bad workflow whose harm the generator did not name falls back to
    its own label, so the model still sees it as bad somewhere.
    """
    if workflow.label == 1:
        return 1
    if not workflow.harm:
        return 0
    return 0 if any(start <= h < start + size for h in workflow.harm) else 1


def windows_of(workflow: Workflow, sizes=WINDOW_SIZES, draws: int = DRAWS,
               rng: random.Random | None = None, limit: int = 300) -> list[Window]:
    """Return the windows drawn from WORKFLOW.

    For each size in SIZES, up to DRAWS windows at random offsets, and
    always the window that ends at the last call.  A size longer than the
    workflow gives only that last window, since there is nothing else to
    cut.
    """
    rng = rng or random.Random()
    calls = workflow.calls
    out: list[Window] = []
    for size in sizes:
        if size > len(calls):
            continue
        starts = set()
        last = len(calls) - size
        starts.add(last)
        for _ in range(draws):
            starts.add(rng.randint(0, last))
        for start in sorted(starts):
            chunk = calls[start:start + size]
            out.append(Window(workflow_id=workflow.id, size=size,
                              label=window_label(workflow, start, size),
                              text=render_window(workflow, chunk, limit),
                              at_end=(start == last), start=start))
    return out


def endings_of(workflow: Workflow, sizes=WINDOW_SIZES,
                limit: int = 300) -> list[Window]:
    """Return the windows the plugin is handed, one per call it decides.

    In a session the classifier is asked about the call at the end of a
    prefix of the turn: the call being decided, with the SIZE-1 calls
    before it as context.  Its label is whether that last call does the
    harm, not whether the workflow is bad, because the decision is about
    that one call.  Every call of every workflow gives one window, so the
    measurement is over calls, which is what a session makes.
    """
    out: list[Window] = []
    for size in sizes:
        for end in range(size - 1, len(workflow.calls)):
            start = end - size + 1
            chunk = workflow.calls[start:end + 1]
            label = window_label(workflow, end, 1)
            out.append(Window(workflow_id=workflow.id, size=size, label=label,
                              text=render_decision(workflow, chunk[:-1], chunk[-1],
                                                   limit),
                              at_end=(end == len(workflow.calls) - 1),
                              start=start))
    return out


def build(workflows: list[Workflow], sizes=WINDOW_SIZES, draws: int = DRAWS,
          seed: int = 7) -> dict[str, list[Window]]:
    """Return the windows of WORKFLOWS, by split name."""
    rng = random.Random(seed)
    out: dict[str, list[Window]] = {"train": [], "val": [], "test": []}
    for w in workflows:
        out[split_of(w)].extend(windows_of(w, sizes, draws, rng))
    return out


def balance(windows: list[Window], seed: int = 7) -> list[Window]:
    """Return WINDOWS with the smaller class cut down to the larger's size.

    A workflow whose harm is in the middle yields windows of both
    readings; a workflow whose harm is last yields good windows before it
    and a bad one at the end.  The set can therefore lean one way, and a
    model trained on it learns the lean instead of the harm.  The cut is
    random, not by position, so the last windows stay represented.
    """
    rng = random.Random(seed)
    good = [w for w in windows if w.label == 1]
    bad = [w for w in windows if w.label == 0]
    n = min(len(good), len(bad))
    out = rng.sample(good, n) + rng.sample(bad, n)
    rng.shuffle(out)
    return out


def stats(windows: list[Window]) -> dict:
    out = {}
    for size in sorted({w.size for w in windows}):
        group = [w for w in windows if w.size == size]
        out[size] = {"n": len(group),
                     "good": sum(1 for w in group if w.label == 1),
                     "bad": sum(1 for w in group if w.label == 0)}
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Cut workflows into sliding windows.")
    ap.add_argument("--workflows", default="data/workflows.jsonl")
    ap.add_argument("--out", default="data/windows.jsonl")
    ap.add_argument("--sizes", default=",".join(str(s) for s in WINDOW_SIZES))
    ap.add_argument("--draws", type=int, default=DRAWS)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--no-balance", action="store_true")
    ap.add_argument("--endings", action="store_true",
                    help="write the prefixes a session is handed, one per call")
    args = ap.parse_args()

    sizes = tuple(int(s) for s in args.sizes.split(",") if s.strip())
    workflows = read_jsonl(args.workflows)
    if args.endings:
        # What a session really asks: the call being decided, with the
        # calls before it, labelled by that call alone.
        splits = {"train": [], "val": [], "test": []}
        for w in workflows:
            splits[split_of(w)].extend(endings_of(w, sizes))
    else:
        splits = build(workflows, sizes, args.draws, args.seed)
    if not args.no_balance:
        splits["train"] = balance(splits["train"], args.seed)
        splits["val"] = balance(splits["val"], args.seed)
        splits["test"] = balance(splits["test"], args.seed)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        for name in ("train", "val", "test"):
            for w in splits[name]:
                row = w.to_dict()
                row["split"] = name
                f.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    for name in ("train", "val", "test"):
        total = len(splits[name])
        good = sum(1 for w in splits[name] if w.label == 1)
        print(f"{name}: {total} windows ({good} good, {total - good} bad)"
              f", by size {stats(splits[name])}", file=sys.stderr)
    print(f"-> {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
