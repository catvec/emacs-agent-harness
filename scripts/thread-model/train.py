#!/usr/bin/env python3
"""Fine-tune the thread-continuation model on cases of workspace messages.

The base is `sentence-transformers/all-MiniLM-L6-v2', the same encoder the
tool-call classifier uses and for the same reason: 22.7M parameters, a
512-token window, the standard `AutoModelForSequenceClassification'
fine-tuning path, and 23.7 ms to read a 256-token window on this machine's
CPU.  A routing decision is made while the person is typing, so a quarter
of a second per message would be felt; the smallest encoder that reads the
window is the right base for a reflex.

The head is one logit: `sigmoid(logit)` is the probability that the
message continues the current thread.  One number, because the decision is
one question and the router owns the policy: a `continue` bool alone
cannot say how sure the model is, and the threshold that turns the number
into a routing action belongs to the caller (`harness-thread-model-trust`),
not to the weights.

Three things this trainer does that the tool-call one does not need to:

* **uncertain cases are down-weighted, not dropped.**  A message the text
  cannot settle is still a message the model will meet; it teaches the
  shape and contributes less to the gradient.  Dropping it would teach the
  model that ambiguous text never happens.
* **the checkpoint kept is chosen on calibration as well as ranking.**
  The caller reads the number as a probability, so a checkpoint with a
  better AUC and a worse Brier score is not the better model.  The
  selection score is the validation log loss, with the AUC reported
  beside it.
* **the report says what the model is not good at.**  Slices, threshold
  tradeoffs and the baselines are `evaluate.py`'s job, and the numbers it
  writes are the ones the model card quotes.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time

import numpy as np
import torch
from torch.utils.data import DataLoader
from transformers import (AutoModelForSequenceClassification, AutoTokenizer,
                          get_linear_schedule_with_warmup)

# The arithmetic a reflex has whatever it is deciding -- the training
# loader, the ranking, the losses -- lives once in scripts/system-1/.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "system-1"))
import common  # noqa: E402

BASE = "sentence-transformers/all-MiniLM-L6-v2"
MAX_TOKENS = 384

# How much an uncertain case counts in the loss.  Half: it is a real
# example of text the label cannot settle, and a claim about it is a
# weaker claim than one about a message the text does settle.
UNCERTAIN_WEIGHT = 0.5





def evaluate(model, loader):
    """Return (loss, probabilities, labels) over LOADER."""
    model.eval()
    losses, probs, labels = [], [], []
    with torch.no_grad():
        for batch in loader:
            labels_in = batch.pop("labels")
            batch.pop("weights")
            out = model(**batch)
            logits = out.logits.squeeze(-1).float()
            losses.append(torch.nn.functional.binary_cross_entropy_with_logits(
                logits, labels_in).item() * len(labels_in))
            probs.extend(torch.sigmoid(logits).tolist())
            labels.extend(labels_in.tolist())
    return sum(losses) / max(1, len(labels)), probs, labels


def main() -> int:
    ap = argparse.ArgumentParser(description="Fine-tune the thread-continuation model.")
    ap.add_argument("--cases", default="data/cases.jsonl")
    ap.add_argument("--out", default="model")
    ap.add_argument("--base", default=BASE)
    ap.add_argument("--epochs", type=float, default=4.0)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--lr", type=float, default=3e-5)
    ap.add_argument("--warmup", type=float, default=0.06)
    ap.add_argument("--max-tokens", type=int, default=MAX_TOKENS)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--train-limit", type=int, default=0,
                    help="train on at most this many cases, 0 for all")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.set_num_threads(args.threads)

    rows = common.read_jsonl(args.cases)
    splits = {name: [r for r in rows if r["split"] == name]
              for name in ("train", "val", "test")}
    print({k: len(v) for k, v in splits.items()}, file=sys.stderr)
    if not splits["train"] or not splits["val"]:
        print("a split is empty: nothing to train or to select on", file=sys.stderr)
        return 2

    tokenizer = AutoTokenizer.from_pretrained(args.base)
    model = AutoModelForSequenceClassification.from_pretrained(
        args.base, num_labels=1, problem_type="regression")

    train_rows = splits["train"]
    if args.train_limit and len(train_rows) > args.train_limit:
        train_rows = random.Random(args.seed).sample(train_rows, args.train_limit)
    train_ds = common.Cases(train_rows, tokenizer, args.max_tokens)
    val_ds = common.Cases(splits["val"], tokenizer, args.max_tokens)
    test_ds = common.Cases(splits["test"], tokenizer, args.max_tokens) if splits["test"] else None
    positives = sum(1 for r in train_rows if r["label"] == 1)
    negatives = len(train_rows) - positives
    print(f"train: {positives} continue, {negatives} switch", file=sys.stderr)
    if positives == 0 or negatives == 0:
        print("the training split has one class only", file=sys.stderr)
        return 2

    # Balanced sampling: most messages continue their thread, so a head
    # trained on the real ratio answers "continue" for almost everything
    # and looks accurate.  Sampling by class makes the gradient about the
    # messages; the real ratio comes back through the threshold the caller
    # chooses, not through the weights.
    train_weights = [1.0 / (positives if r["label"] == 1 else negatives)
                     for r in train_rows]
    sampler = torch.utils.data.WeightedRandomSampler(
        train_weights, num_samples=len(train_rows), replacement=True)
    train_loader = DataLoader(train_ds, batch_size=args.batch, sampler=sampler,
                              collate_fn=common.collate)
    val_loader = DataLoader(val_ds, batch_size=args.batch, collate_fn=common.collate)
    test_loader = (DataLoader(test_ds, batch_size=args.batch, collate_fn=common.collate)
                   if test_ds is not None else None)

    steps = int(len(train_loader) * args.epochs)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    sched = get_linear_schedule_with_warmup(opt, int(steps * args.warmup), steps)

    best = None
    history = []
    started = time.time()
    for epoch in range(int(args.epochs)):
        model.train()
        running = 0.0
        for i, batch in enumerate(train_loader):
            labels = batch.pop("labels")
            weights = batch.pop("weights")
            out = model(**batch)
            per_case = torch.nn.functional.binary_cross_entropy_with_logits(
                out.logits.squeeze(-1).float(), labels, reduction="none")
            # The batch mean is over the cases' own weights, so an
            # uncertain case moves the gradient by half a case rather
            # than by its absence.
            loss = (per_case * weights).sum() / weights.sum().clamp(min=1e-6)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            sched.step()
            opt.zero_grad()
            running += loss.item()
            if (i + 1) % 25 == 0:
                print(f"  epoch {epoch + 1} step {i + 1}/{len(train_loader)} "
                      f"loss {running / (i + 1):.4f}", file=sys.stderr)
        val_loss, probs, labels = evaluate(model, val_loader)
        entry = {"epoch": epoch + 1, "train_loss": running / len(train_loader),
                 "val_loss": val_loss, "val_auc": common.auc(probs, labels),
                 "val_brier": common.brier(probs, labels),
                 "val_log_loss": common.log_loss(probs, labels)}
        history.append(entry)
        print(f"epoch {epoch + 1}: train {running / len(train_loader):.4f} "
              f"val loss {val_loss:.4f} auc {entry['val_auc']:.4f} "
              f"brier {entry['val_brier']:.4f} ({time.time() - started:.0f}s)",
              file=sys.stderr)
        # The checkpoint kept is the one whose numbers are the best
        # probabilities, not the best ranking: a caller reads the number
        # as P(continue) and its threshold is a probability, so the
        # validation log loss is the score, and the AUC is reported beside
        # it.
        if best is None or entry["val_log_loss"] < best["val_log_loss"]:
            best = entry
            os.makedirs(args.out, exist_ok=True)
            model.save_pretrained(args.out)
            tokenizer.save_pretrained(args.out)
            print(f"  saved to {args.out}", file=sys.stderr)

    model = AutoModelForSequenceClassification.from_pretrained(args.out)
    final = {}
    if test_loader is not None:
        test_loss, probs, labels = evaluate(model, test_loader)
        final = {"loss": test_loss, "auc": common.auc(probs, labels),
                 "brier": common.brier(probs, labels),
                 "log_loss": common.log_loss(probs, labels),
                 "accuracy": float(np.mean((np.array(probs) >= 0.5) ==
                                           (np.array(labels) >= 0.5)))}
        print(f"test: loss {test_loss:.4f} auc {final['auc']:.4f} "
              f"brier {final['brier']:.4f}", file=sys.stderr)

    meta = {"base": args.base, "max_tokens": args.max_tokens, "epochs": args.epochs,
            "batch": args.batch, "lr": args.lr, "seed": args.seed,
            "threads": args.threads, "uncertain-weight": UNCERTAIN_WEIGHT,
            "best": best, "history": history, "test": final,
            "counts": {k: len(v) for k, v in splits.items()},
            "trained_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "seconds": round(time.time() - started)}
    with open(os.path.join(args.out, "training.json"), "w") as f:
        json.dump(meta, f, indent=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
