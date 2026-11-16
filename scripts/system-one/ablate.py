#!/usr/bin/env python3
"""What is the classifier reading?  A check on its own answer.

A window is the task plus the calls.  If the model reads the task text
to tell a bad workflow from a good one -- the generated tasks of bad
workflows may share a phrasing -- it would look accurate here and fail
in a session, where the task is the user's own words.  So the same
model is scored three ways on the same held-out windows:

  full        the window as it is rendered for the model
  calls only  the task line removed
  task only   the calls removed, which is the shortcut, if it is one

A model that reads the calls loses little when the task goes, and a
model that reads the task loses everything when the calls go.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from evaluate import auc, load, predict, table  # noqa: E402

from transformers import AutoModelForSequenceClassification, AutoTokenizer  # noqa: E402


def variants(text: str) -> dict[str, str]:
    """Return the three readings of the window TEXT."""
    lines = text.splitlines()
    task = [l for l in lines if l.startswith("Task: ")]
    calls = [l for l in lines if not l.startswith("Task: ")]
    return {"full": text,
            "calls_only": "\n".join(calls),
            "task_only": "\n".join(task)}


def main() -> int:
    ap = argparse.ArgumentParser(description="Ablate the task text from the window.")
    ap.add_argument("--windows", default="data/windows.jsonl")
    ap.add_argument("--model", default="model")
    ap.add_argument("--split", default="test")
    ap.add_argument("--out", default="ablation.json")
    ap.add_argument("--threads", type=int, default=8)
    args = ap.parse_args()

    rows = [r for r in load(args.windows) if r["split"] == args.split]
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model)
    labels = [r["label"] for r in rows]

    report = {"model": args.model, "split": args.split, "windows": len(rows), "views": {}}
    for view in ("full", "calls_only", "task_only"):
        texts = [variants(r["text"])[view] for r in rows]
        probs = predict(model, tokenizer, texts, threads=args.threads)
        report["views"][view] = table(probs, labels)
        report["views"][view]["by_size"] = {}
        for size in sorted({r["size"] for r in rows}):
            group = [(p, r) for p, r in zip(probs, rows) if r["size"] == size]
            report["views"][view]["by_size"][str(size)] = table(
                [p for p, _ in group], [r["label"] for _, r in group])
        print(f"{view:>12} acc {report['views'][view]['accuracy']:.3f} "
              f"auc {report['views'][view]['auc']:.3f}", file=sys.stderr)

    with open(args.out, "w") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
