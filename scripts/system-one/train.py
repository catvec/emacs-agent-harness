#!/usr/bin/env python3
"""Fine-tune the system-one classifier on windows of tool calls.

The base is `sentence-transformers/all-MiniLM-L6-v2': 22.7M parameters,
a 512-token window, and a fine-tuning path every transformer trainer
knows.  It was picked on this machine's numbers (see model_card.md):
23.7 ms to classify a 256-token window on 8 CPU threads, against 72.9
ms for distilbert-base and 224.9 ms for ModernBERT-base.  A permission
decision waits on this call, so a model that costs a quarter second per
call would be felt in every session; the smallest one that reads the
window is the right base for a reflex.

The head is one logit: sigmoid(logit) is the probability the window is
safe work.  One number is what the plugin's trust threshold needs -- a
`allow` bool alone cannot say how sure it is, and two heads would let
them disagree.
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
from torch.utils.data import DataLoader, Dataset
from transformers import (AutoModelForSequenceClassification, AutoTokenizer,
                          get_linear_schedule_with_warmup)

BASE = "sentence-transformers/all-MiniLM-L6-v2"
MAX_TOKENS = 256


class Windows(Dataset):
    """The windows of one split, tokenised once."""

    def __init__(self, rows, tokenizer, max_tokens=MAX_TOKENS):
        self.rows = rows
        # Padded per batch, not to MAX_TOKENS: a one-call window is
        # fifty tokens, and padding it to 256 would spend five sixths
        # of the compute on nothing.
        self.enc = tokenizer([r["text"] for r in rows], truncation=True,
                             max_length=max_tokens)

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, i):
        item = {key: torch.tensor(value[i]) for key, value in self.enc.items()}
        item["labels"] = torch.tensor(float(self.rows[i]["label"]))
        return item


def collate(items):
    """Pad ITEMS to the longest window in the batch."""
    length = max(len(item["input_ids"]) for item in items)
    out = {}
    for key in ("input_ids", "attention_mask", "token_type_ids"):
        if key not in items[0]:
            continue
        pad = 1 if key == "attention_mask" else 0
        out[key] = torch.stack([torch.nn.functional.pad(
            item[key], (0, length - len(item[key])), value=pad) for item in items])
    out["labels"] = torch.stack([item["labels"] for item in items])
    return out


def load(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


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


def evaluate(model, loader):
    """Return (loss, probabilities, labels) over LOADER."""
    model.eval()
    losses, probs, labels = [], [], []
    with torch.no_grad():
        for batch in loader:
            labels_in = batch.pop("labels")
            out = model(**batch)
            logits = out.logits.squeeze(-1).float()
            losses.append(torch.nn.functional.binary_cross_entropy_with_logits(
                logits, labels_in).item() * len(labels_in))
            probs.extend(torch.sigmoid(logits).tolist())
            labels.extend(labels_in.tolist())
    return sum(losses) / max(1, len(labels)), probs, labels


def main() -> int:
    ap = argparse.ArgumentParser(description="Fine-tune the system-one classifier.")
    ap.add_argument("--windows", default="data/windows.jsonl")
    ap.add_argument("--out", default="model")
    ap.add_argument("--base", default=BASE)
    ap.add_argument("--epochs", type=float, default=3.0)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--lr", type=float, default=3e-5)
    ap.add_argument("--warmup", type=float, default=0.06)
    ap.add_argument("--max-tokens", type=int, default=MAX_TOKENS)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--pos-weight", type=float, default=1.0,
                    help="loss weight of the safe class")
    ap.add_argument("--train-limit", type=int, default=0,
                    help="train on at most this many windows, 0 for all")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.set_num_threads(args.threads)

    rows = load(args.windows)
    splits = {name: [r for r in rows if r["split"] == name]
              for name in ("train", "val", "test")}
    print({k: len(v) for k, v in splits.items()}, file=sys.stderr)

    tokenizer = AutoTokenizer.from_pretrained(args.base)
    model = AutoModelForSequenceClassification.from_pretrained(
        args.base, num_labels=1, problem_type="regression")

    train_rows = splits["train"]
    if args.train_limit and len(train_rows) > args.train_limit:
        # A 22M-parameter encoder needs thousands of examples, not
        # tens of thousands: the rest is compute spent on a signal
        # the set already carries.
        train_rows = random.Random(args.seed).sample(train_rows, args.train_limit)
    train_ds = Windows(train_rows, tokenizer, args.max_tokens)
    val_ds = Windows(splits["val"], tokenizer, args.max_tokens)
    test_ds = Windows(splits["test"], tokenizer, args.max_tokens)
    positives = sum(1 for r in train_rows if r["label"] == 1)
    negatives = len(train_rows) - positives
    # Balanced sampling: the set is one unsafe window in nine, and a
    # head trained on that ratio answers 0.9 for everything.  Sampling
    # by class makes the gradient about the calls, not the prior; the
    # threshold in the module is where the real ratio comes back.
    #
    # A row's weight is the inverse of its class's count, so the
    # two classes draw equally.  Inverting them -- the majority
    # class weighted higher -- trains the prior harder, and is the
    # bug that made the first model answer 0.98 to every window.
    train_weights = [1.0 / max(1, positives if r["label"] == 1 else negatives)
                     for r in train_rows]
    sampler = torch.utils.data.WeightedRandomSampler(
        train_weights, num_samples=len(train_rows), replacement=True)
    train_loader = DataLoader(train_ds, batch_size=args.batch, sampler=sampler,
                              collate_fn=collate)
    val_loader = DataLoader(val_ds, batch_size=args.batch, collate_fn=collate)
    test_loader = DataLoader(test_ds, batch_size=args.batch, collate_fn=collate)

    steps = int(len(train_loader) * args.epochs)
    # The sampler already balances the two classes, so the loss
    # adds no further weight; a pos_weight on top of it would
    # count the prior twice.
    pos_weight = torch.tensor([args.pos_weight])
    print("pos_weight %.3f" % pos_weight.item(), file=sys.stderr)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    sched = get_linear_schedule_with_warmup(
        opt, int(steps * args.warmup), steps)

    best = None
    history = []
    started = time.time()
    for epoch in range(int(args.epochs)):
        model.train()
        running = 0.0
        for i, batch in enumerate(train_loader):
            labels = batch.pop("labels")
            out = model(**batch)
            loss = torch.nn.functional.binary_cross_entropy_with_logits(
                out.logits.squeeze(-1).float(), labels, pos_weight=pos_weight)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            sched.step()
            opt.zero_grad()
            running += loss.item()
            if (i + 1) % 50 == 0:
                print(f"  epoch {epoch + 1} step {i + 1}/{len(train_loader)} "
                      f"loss {running / (i + 1):.4f}", file=sys.stderr)
        val_loss, probs, labels = evaluate(model, val_loader)
        acc = sum((p >= 0.5) == (l >= 0.5) for p, l in zip(probs, labels)) / len(labels)
        val_auc = auc(probs, labels)
        history.append({"epoch": epoch + 1, "train_loss": running / len(train_loader),
                        "val_loss": val_loss, "val_accuracy": acc,
                        "val_auc": val_auc})
        print(f"epoch {epoch + 1}: train {running / len(train_loader):.4f} "
              f"val {val_loss:.4f} acc {acc:.4f} auc {val_auc:.4f} "
              f"({time.time() - started:.0f}s)", file=sys.stderr)
        # The checkpoint kept is the one that ranks best, not the one
        # with the lowest loss: a head that answers the prior has a
        # falling loss and a ranking at chance, and the loss alone
        # would keep it.
        if best is None or val_auc > best["val_auc"]:
            best = history[-1]
            os.makedirs(args.out, exist_ok=True)
            model.save_pretrained(args.out)
            tokenizer.save_pretrained(args.out)
            print(f"  saved to {args.out}", file=sys.stderr)

    model = AutoModelForSequenceClassification.from_pretrained(args.out)
    test_loss, probs, labels = evaluate(model, DataLoader(test_ds, batch_size=args.batch, collate_fn=collate))
    acc = sum((p >= 0.5) == (l >= 0.5) for p, l in zip(probs, labels)) / len(labels)
    print(f"test: loss {test_loss:.4f} acc {acc:.4f} auc {auc(probs, labels):.4f}",
          file=sys.stderr)

    meta = {"base": args.base, "max_tokens": args.max_tokens, "epochs": args.epochs,
            "batch": args.batch, "lr": args.lr, "seed": args.seed,
            "threads": args.threads, "best": best, "history": history,
            "test": {"loss": test_loss, "accuracy": acc,
                      "auc": auc(probs, labels)},
            "counts": {k: len(v) for k, v in splits.items()},
            "trained_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "seconds": round(time.time() - started)}
    with open(os.path.join(args.out, "training.json"), "w") as f:
        json.dump(meta, f, indent=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
