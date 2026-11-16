#!/usr/bin/env python3
"""Does a window of tool calls carry its workflow's label?

That is the experiment.  The classifier is trained on windows of
several sizes, and this reports, per size and on the held-out workflows
only, how often the model's reading matches the label the workflow was
written with.  The question is not "is the model accurate" but "at what
window size does the signal exist": a single call is what the judge sees
today, and a window of three or five is what the classifier gets that
the judge does not.

Three readings are reported for every size:

  accuracy, precision, recall, F1, AUC   the usual, with "good" as the
                                         positive class
  the confusion table                    what it gets wrong, and which
                                         way: a false "unsafe" stops an
                                         unattended task, a false "safe"
                                         lets harm through
  the last-window split                  windows that end at the
                                         workflow's last call, which is
                                         what a live session decides, kept
                                         apart from windows cut from the
                                         middle

The trust threshold comes from the same numbers: the plugin decides a
call only when the model is at least THRESHOLD sure, and leaves it to
the judge and the user otherwise.  The report gives, for each candidate
threshold, how many windows it decides and how many of those it decides
wrongly, so the threshold in the module is a reading of the data rather
than a guess.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np
import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

BASE = "sentence-transformers/all-MiniLM-L6-v2"


def load(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def predict(model, tokenizer, texts, batch=64, max_tokens=256, threads=8):
    torch.set_num_threads(threads)
    model.eval()
    out = []
    with torch.no_grad():
        for i in range(0, len(texts), batch):
            enc = tokenizer(texts[i:i + batch], truncation=True, max_length=max_tokens,
                            padding=True, return_tensors="pt")
            logits = model(**enc).logits.squeeze(-1).float()
            out.extend(torch.sigmoid(logits).tolist())
    return out


def auc(probs, labels):
    """Return the area under the ROC curve, by rank, ties sharing a rank."""
    order = np.argsort(probs, kind="mergesort")
    ranks = np.empty(len(probs), dtype=float)
    sorted_probs = np.array(probs)[order]
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and sorted_probs[j + 1] == sorted_probs[i]:
            j += 1
        ranks[order[i:j + 1]] = (i + j) / 2.0 + 1
        i = j + 1
    labels = np.array(labels)
    positive = labels >= 0.5
    n_pos, n_neg = positive.sum(), (~positive).sum()
    if n_pos == 0 or n_neg == 0:
        return float("nan")
    return float((ranks[positive].sum() - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg))


def table(probs, labels, threshold=0.5):
    """Return the counts and scores of PROBS read at THRESHOLD."""
    probs, labels = np.array(probs), np.array(labels)
    safe = probs >= threshold          # the model says the window is safe work
    good = labels >= 0.5
    tp = int((safe & good).sum())
    tn = int((~safe & ~good).sum())
    fp = int((safe & ~good).sum())     # harm let through
    fn = int((~safe & good).sum())     # good work stopped
    n = len(labels)
    precision = tp / (tp + fp) if tp + fp else float("nan")
    recall = tp / (tp + fn) if tp + fn else float("nan")
    return {"n": n, "tp": tp, "tn": tn, "fp": fp, "fn": fn,
            "accuracy": round((tp + tn) / n, 4) if n else None,
            "precision": round(precision, 4) if precision == precision else None,
            "recall": round(recall, 4) if recall == recall else None,
            "f1": round(2 * precision * recall / (precision + recall), 4)
            if precision == precision and recall == recall and precision + recall else None,
            "auc": round(auc(probs, labels), 4)}


def thresholds(probs, labels, values):
    """Return what the model would decide at each of VALUES.

    "decided" is the share of windows the plugin would settle itself; the
    rest go on to the judge.  "wrong" is the share of all windows it would
    settle wrongly, which is what a trust setting buys and pays for.
    """
    probs, labels = np.array(probs), np.array(labels)
    good = labels >= 0.5
    out = []
    for t in values:
        safe = probs >= t
        unsafe = probs <= 1 - t
        decided = safe | unsafe
        right = (safe & good) | (unsafe & ~good)
        out.append({"threshold": t,
                    "decided": round(float(decided.mean()), 4),
                    "right": round(float(right.mean()), 4),
                    "wrong": round(float((decided & ~right).mean()), 4),
                    "let_through": round(float((safe & ~good).mean()), 4),
                    "stopped": round(float((unsafe & good).mean()), 4)})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Measure the classifier per window size.")
    ap.add_argument("--windows", default="data/windows.jsonl")
    ap.add_argument("--model", default="model")
    ap.add_argument("--split", default="test")
    ap.add_argument("--out", default="report.json")
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--thresholds", default="0.5,0.6,0.7,0.8,0.9,0.95,0.99")
    args = ap.parse_args()

    rows = [r for r in load(args.windows) if r["split"] == args.split]
    if not rows:
        raise SystemExit(f"no windows in split {args.split}")
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model)
    probs = predict(model, tokenizer, [r["text"] for r in rows],
                    max_tokens=args.max_tokens, threads=args.threads)
    for row, p in zip(rows, probs):
        row["prob"] = p

    report = {"model": args.model, "split": args.split, "windows": len(rows),
              "by_size": {}, "overall": table(probs, [r["label"] for r in rows]),
              "thresholds": {}}
    values = [float(t) for t in args.thresholds.split(",")]
    for size in sorted({r["size"] for r in rows}):
        group = [r for r in rows if r["size"] == size]
        report["by_size"][str(size)] = {
            "all": table([r["prob"] for r in group], [r["label"] for r in group]),
            "at_end": table([r["prob"] for r in group if r["at_end"]],
                            [r["label"] for r in group if r["at_end"]]),
            "mid": table([r["prob"] for r in group if not r["at_end"]],
                         [r["label"] for r in group if not r["at_end"]]),
            "thresholds": thresholds([r["prob"] for r in group],
                                     [r["label"] for r in group], values)}
        report["thresholds"][str(size)] = report["by_size"][str(size)]["thresholds"]

    # The window size the plugin uses: the smallest whose AUC is within
    # a point of the best, since every extra call costs latency and
    # context and a size that buys nothing buys nothing.
    aucs = {s: report["by_size"][s]["all"]["auc"] for s in report["by_size"]}
    best = max(aucs.values())
    chosen = min((int(s) for s in aucs if aucs[s] >= best - 0.01), default=min(aucs))
    report["chosen_size"] = chosen
    report["chosen"] = report["by_size"][str(chosen)]

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    with open(os.path.splitext(args.out)[0] + ".jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")

    print(f"{args.split}: {len(rows)} windows, model {args.model}", file=sys.stderr)
    print(f"{'size':>5} {'n':>5} {'acc':>6} {'prec':>6} {'rec':>6} {'f1':>6} {'auc':>6} "
          f"{'at_end acc':>10} {'at_end auc':>10}", file=sys.stderr)
    for size in sorted(report["by_size"], key=int):
        a = report["by_size"][size]["all"]
        e = report["by_size"][size]["at_end"]
        print(f"{size:>5} {a['n']:>5} {a['accuracy']:>6.3f} {str(a['precision']):>6} "
              f"{str(a['recall']):>6} {str(a['f1']):>6} {a['auc']:>6.3f} "
              f"{str(e['accuracy']):>10} {str(e['auc']):>10}", file=sys.stderr)
    print(f"chosen window size: {chosen}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
