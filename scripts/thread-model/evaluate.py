#!/usr/bin/env python3
"""Does the model's number mean what it says?

The question is not "is the model accurate".  The router already has a
word-overlap rule that is local, instant and free (`harness-workspace--route`),
and the model is only worth its latency if it is *better*, and only safe
to read as a probability if it is *calibrated*.  So this reports, on the
held-out cases only:

  calibration      a reliability table, the expected calibration error,
                   the Brier score and the log loss, with the base rate
                   beside them.  A model that answers the base rate for
                   everything is well ranked and badly calibrated, and
                   these are the numbers that say so.
  threshold        for each candidate threshold, how many messages it
                   would route by the model, how many it gets wrong, and
                   which way: a wrong switch starts or moves a thread the
                   person did not want moved, a missed switch leaves a
                   new subject in the old thread.
  slices           the same numbers per kind of case -- ordinary,
                   in-conversation switch, spliced, adjacent, short
                   reply, local reference, ambiguous -- because a model
                   that is good on ordinary messages and useless on the
                   hard ones is not good enough for a router.
  baselines        on the identical held-out cases, and with the same
                   decision-time information: the workspace's own
                   word-overlap rule, a majority guess, and a
                   graph-only reading that asks only whether a graph
                   block matches the message.  The model has to beat
                   them to be worth a subprocess.
  degraded         the same cases with their graph blocks removed, their
                   context cut short, and the message truncated, to say
                   what the model does when what it reads is missing or
                   malformed.

The threshold and every other choice are made on `val'; `test` is read
once, and the numbers in the report are its own.  Nothing here tunes on
the test split, and the report says which split each table is from.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dataset import content_words  # noqa: E402
from schema import LABELS  # noqa: E402

# The arithmetic a reflex has whatever it is deciding lives once, in
# scripts/system-1/common.py, and this decision imports it: the same
# ranking, the same losses, the same temperature fit.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "system-1"))
import common  # noqa: E402

auc = common.auc
log_loss = common.log_loss
brier = common.brier
fit_temperature = common.fit_temperature
apply_temperature = common.apply_temperature
reliability = common.reliability

# The thresholds the report weighs.  The router's own rule decides at
# 0.2 word overlap; the model's number is a probability, so the
# candidates span the range a probability is read in.
THRESHOLDS = (0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95)

# How many bins the reliability table has.  Ten is what a reliability
# plot draws; fewer hides the middle, more is empty at the ends.
BINS = 10


def load(path: str) -> list[dict]:
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def predict(model, tokenizer, texts, batch=32, max_tokens=384, threads=8):
    """Return the model's P(continue) for each of TEXTS."""
    import torch

    torch.set_num_threads(threads)
    model.eval()
    out = []
    with torch.no_grad():
        for i in range(0, len(texts), batch):
            enc = tokenizer(texts[i:i + batch], truncation=True,
                            max_length=max_tokens, padding=True,
                            return_tensors="pt")
            logits = model(**enc).logits.squeeze(-1).float()
            out.extend(torch.sigmoid(logits).tolist())
    return out








def readings(probs, labels) -> dict:
    """Return the ranking and probability numbers for PROBS against LABELS.

    An AUC is undefined when a slice holds one label only -- every case
    in it is a switch, say -- and it is reported as null rather than as a
    number computed from nothing.  The count and the base rate say why.
    """
    probs = np.array(probs, dtype=float)
    labels = np.array(labels, dtype=float)
    predicted = (probs >= 0.5).astype(int)
    ranking = auc(probs, labels)
    return {
        "n": int(len(probs)),
        "accuracy": round(float((predicted == labels).mean()), 4) if len(probs) else None,
        "auc": (round(ranking, 4) if ranking == ranking else None),
        "brier": round(brier(probs, labels), 4) if len(probs) else None,
        "log-loss": round(log_loss(probs, labels), 4) if len(probs) else None,
        "base-rate": round(float(labels.mean()), 4) if len(probs) else None,
        "mean-said": round(float(probs.mean()), 4) if len(probs) else None,
    }


def threshold_table(probs, labels, thresholds=THRESHOLDS) -> list[dict]:
    """Return what each threshold would decide, and how often wrongly.

    Above the threshold the message continues; below one minus it the
    message does not; between the two the model abstains and the router
    keeps its own rule.  A wrong switch is a message the model moved (or
    would have started a thread for) that really continued, and a missed
    switch is the other way.
    """
    probs = np.array(probs, dtype=float)
    labels = np.array(labels, dtype=float)
    out = []
    for trust in thresholds:
        continue_mask = probs >= trust
        switch_mask = probs <= 1.0 - trust
        decided = continue_mask | switch_mask
        wrong_switch = int((switch_mask & (labels == 1)).sum())
        missed_switch = int((continue_mask & (labels == 0)).sum())
        out.append({
            "trust": trust,
            "decided": int(decided.sum()),
            "share": round(float(decided.mean()), 4) if len(probs) else 0.0,
            "wrong-switch": wrong_switch,
            "missed-switch": missed_switch,
            "wrong": wrong_switch + missed_switch,
            "accuracy-on-decided": (round(float((labels[decided] ==
                                                 (continue_mask[decided])).mean()), 4)
                                    if decided.any() else None),
        })
    return out


def choose_threshold(probs, labels, thresholds=THRESHOLDS,
                     max_wrong_switch: int = 0) -> float:
    """Return the trust value to ship, chosen on the validation split.

    The choice is the model's own policy, not the router's: a wrong
    switch costs more than a missed one, because it moves a message the
    person did not move, so the rule is "the largest coverage whose wrong
    switches are no more than the budget", and the budget comes from what
    a person will tolerate.  A threshold that decides nothing is never
    chosen: it would pay for a subprocess and use none of it.
    """
    table = threshold_table(probs, labels, thresholds)
    usable = [row for row in table
              if row["wrong-switch"] <= max_wrong_switch and row["decided"] > 0]
    if not usable:
        return float(max(thresholds))
    return float(max(row["trust"] for row in usable))


# ---- Baselines, on the same cases and the same information ----------------

def words_of(text: str) -> set[str]:
    """Return the content words of TEXT."""
    return content_words(text)


def parse_case(text: str) -> dict:
    """Return the parts of a rendered case, as `schema.render_case' wrote it.

    The evaluator reads the rendered text, not the case object, so a
    baseline sees exactly what the model sees and nothing a caller would
    not have.
    """
    out = {"task": "", "title": "", "context": [], "knowledge": [], "message": ""}
    section = None
    for line in text.splitlines():
        if line.startswith("Task: "):
            out["task"] = line[len("Task: "):]
        elif line.startswith("Current thread: "):
            out["title"] = line[len("Current thread: "):]
        elif line == "Thread so far:":
            section = "context"
        elif line == "Knowledge:":
            section = "knowledge"
        elif line.startswith("Sender: "):
            section = None
        elif line == "Message to place:":
            section = "message"
        elif section == "context" and line.startswith("- "):
            out["context"].append(line[2:])
        elif section == "knowledge" and line.startswith("- "):
            out["knowledge"].append(line[2:])
        elif section == "message" and line.startswith("- "):
            out["message"] = line[2:]
    return out


def word_overlap_rule(text: str, threshold: float = 0.2) -> float:
    """Return the workspace router's own reading of TEXT, as a score.

    This is `harness-workspace--route-score' in miniature: the share of
    the message's content words the current thread holds, a word in the
    title worth three times one in a message.  It is the rule the model
    has to beat, computed from the same rendered text the model reads.
    """
    case = parse_case(text)
    message = words_of(case["message"])
    if not message:
        return 0.0
    thread = words_of(" ".join(case["context"]))
    title = words_of(case["title"])
    held = 0.0
    for word in message:
        if word in title:
            held += 3.0
        elif word in thread:
            held += 1.0
    return min(1.0, held / (3.0 * len(message)))


def graph_only_rule(text: str) -> float:
    """Return a graph-only reading of TEXT: does a block match the message?

    The brief is explicit that graph retrieval is an input and not the
    whole rule, so this is the baseline that says what the graph alone
    would do.  It is the share of the message's content words the
    retrieved blocks hold: a message whose subject the graph already has
    is read as continuing.
    """
    case = parse_case(text)
    message = words_of(case["message"])
    if not message:
        return 0.0
    blocks = words_of(" ".join(case["knowledge"]))
    if not blocks:
        return 0.0
    return len(message & blocks) / len(message)


def baseline_readings(rows: list[dict], rule, threshold: float) -> dict:
    """Return a baseline's readings, read as a probability of continuing.

    The rule's score is its own share, from 0 to 1; it is compared the
    way the router compares it, at its threshold, so the two rules are
    read on the same footing.
    """
    probs = [rule(row["text"]) for row in rows]
    labels = [row["label"] for row in rows]
    predicted = [1 if p >= threshold else 0 for p in probs]
    return {
        "n": len(rows),
        "accuracy": round(float(np.mean([p == l for p, l in
                                         zip(predicted, labels)])), 4),
        "auc": round(auc(probs, labels), 4),
        "brier": round(brier(probs, labels), 4),
        "log-loss": round(log_loss(probs, labels), 4),
        "threshold": threshold,
    }


def majority_reading(rows: list[dict]) -> dict:
    """Return what guessing the majority class on every case reads."""
    labels = np.array([row["label"] for row in rows], dtype=float)
    rate = float(labels.mean())
    probs = np.full(len(rows), rate)
    return {"n": len(rows), "base-rate": round(rate, 4),
            "accuracy": round(max(rate, 1 - rate), 4),
            "brier": round(brier(probs, labels), 4),
            "log-loss": round(log_loss(probs, labels), 4)}


# ---- Degraded inputs ------------------------------------------------------

def degraded(text: str, how: str) -> str:
    """Return TEXT as it looks when one part of it is missing or malformed."""
    lines = text.splitlines()
    if how == "no-graph":
        out, skipping = [], False
        for line in lines:
            if line == "Knowledge:":
                skipping = True
                continue
            if skipping and line.startswith("- "):
                continue
            skipping = False
            out.append(line)
        return "\n".join(out)
    if how == "no-context":
        out, skipping = [], False
        for line in lines:
            if line == "Thread so far:":
                skipping = True
                continue
            if skipping and line.startswith("- "):
                continue
            skipping = False
            out.append(line)
        return "\n".join(out)
    if how == "no-title":
        return "\n".join("Current thread: (untitled)" if line.startswith("Current thread: ")
                         else line for line in lines)
    if how == "truncated-message":
        return re.sub(r"(Message to place:\n- ).*", r"\1", text, flags=re.S)
    if how == "empty":
        return ""
    return text


def main() -> int:
    ap = argparse.ArgumentParser(description="Evaluate the thread model.")
    ap.add_argument("--cases", default="data/cases.jsonl")
    ap.add_argument("--model", default="model")
    ap.add_argument("--out", default="data/report.json")
    ap.add_argument("--split", default="test")
    ap.add_argument("--choose-on", default="val")
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--max-tokens", type=int, default=384)
    ap.add_argument("--max-wrong-switch", type=int, default=2,
                    help="wrong switches the shipped threshold may make on val")
    args = ap.parse_args()

    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    rows = load(args.cases)
    by_split = {name: [r for r in rows if r["split"] == name]
                for name in ("train", "val", "test")}
    for name, group in by_split.items():
        print(f"{name}: {len(group)}", file=sys.stderr)
    if not by_split[args.split]:
        print(f"the {args.split} split is empty", file=sys.stderr)
        return 2

    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model)

    probs_by_split = {}
    for name, group in by_split.items():
        if not group:
            continue
        probs_by_split[name] = predict(model, tokenizer, [r["text"] for r in group],
                                       args.batch, args.max_tokens, args.threads)

    val = by_split[args.choose_on]
    # The temperature is fitted on the validation split and applied to
    # both: a caller reads the number as a probability, and the fit is
    # one parameter measured where a tuning decision belongs.
    temperature = fit_temperature(probs_by_split[args.choose_on],
                                  [r["label"] for r in val]) if val else 1.0
    print(f"temperature fitted on {args.choose_on}: {temperature}", file=sys.stderr)
    calibrated = {name: apply_temperature(values, temperature)
                  for name, values in probs_by_split.items()}
    # The predictor reads the same temperature, so a live reading is the
    # one this report measured rather than the head's raw number.
    _write_calibration(os.path.join(args.model, "calibration.json"),
                       {"temperature": temperature,
                        "fitted-on": args.choose_on,
                        "cases": len(val),
                        "method": ("temperature scaling: one parameter, "
                                   "grid search over 0.25..64 on the "
                                   "validation split's log loss")})
    chosen = choose_threshold(calibrated[args.choose_on],
                              [r["label"] for r in val],
                              max_wrong_switch=args.max_wrong_switch)
    print(f"threshold chosen on {args.choose_on}: {chosen}", file=sys.stderr)

    held = by_split[args.split]
    probs = calibrated[args.split]
    raw = probs_by_split[args.split]
    labels = [r["label"] for r in held]
    report: dict = {
        "split": args.split,
        "chosen-on": args.choose_on,
        "temperature": temperature,
        "threshold": chosen,
        "model": {"dir": args.model,
                  "training": _read_json(os.path.join(args.model, "training.json"))},
        "counts": {name: len(group) for name, group in by_split.items()},
        "readings": readings(probs, labels),
        "calibration": reliability(probs, labels),
        # What the head said before the temperature, so the report shows
        # what the fit did rather than only its result.
        "uncalibrated": {"readings": readings(raw, labels),
                         "calibration": reliability(raw, labels)},
        "thresholds": threshold_table(probs, labels),
    }

    # The same readings on the validation split, so the report says
    # whether the held-out numbers are a surprise.
    if args.choose_on != args.split and val:
        val_probs = calibrated[args.choose_on]
        val_labels = [r["label"] for r in val]
        report["validation"] = {
            "readings": readings(val_probs, val_labels),
            "calibration": reliability(val_probs, val_labels),
            "thresholds": threshold_table(val_probs, val_labels),
        }

    slices = {}
    for name in sorted({r["slice"] for r in held}):
        group = [i for i, r in enumerate(held) if r["slice"] == name]
        slices[name] = {
            "n": len(group),
            "readings": readings([probs[i] for i in group],
                                 [labels[i] for i in group]),
            "at-threshold": _at_threshold([probs[i] for i in group],
                                          [labels[i] for i in group], chosen),
        }
    report["slices"] = slices

    # Baselines, on the identical cases.
    report["baselines"] = {
        "word-overlap": baseline_readings(held, word_overlap_rule, 0.2),
        "graph-only": baseline_readings(held, graph_only_rule, 0.5),
        "majority": majority_reading(held),
    }

    # What a degraded input does to the same cases.
    report["degraded"] = {}
    for how in ("no-graph", "no-context", "no-title", "truncated-message", "empty"):
        texts = [degraded(r["text"], how) for r in held]
        degraded_probs = predict(model, tokenizer, texts, args.batch,
                                 args.max_tokens, args.threads)
        report["degraded"][how] = {
            "readings": readings(degraded_probs, labels),
            "at-threshold": _at_threshold(degraded_probs, labels, chosen),
        }

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    answer = verdict(report)
    report["verdict"] = answer
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    print(json.dumps({"verdict": answer, "readings": report["readings"],
                      "threshold": chosen,
                      "calibration-ece": report["calibration"]["ece"],
                      "baselines": {k: {"accuracy": v.get("accuracy"),
                                        "auc": v.get("auc")}
                                    for k, v in report["baselines"].items()}},
                     indent=1), file=sys.stderr)
    print(f"-> {args.out}", file=sys.stderr)
    return 0


def verdict(report: dict) -> dict:
    """Return whether the model is worth shipping, and why.

    Three questions, answered from the report's own numbers:

    * does it rank better than the rule it would replace?  The word
      overlap baseline is the router's own rule, read on the identical
      cases; an AUC no better than its own means the model has learned
      nothing the words do not already say;
    * does it beat guessing the majority?  A model below the base rate
      is worse than no model at all;
    * does the shipped threshold decide anything?  A threshold that
      abstains on every case pays for a subprocess and uses none of it.

    The answer is one of `ship', `do-not-ship' and `unproven', with the
    numbers that decided it.  This is the honest half of the evaluation:
    a model that is not better should say so in its own report rather
    than in a footnote.
    """
    model = report.get("readings") or {}
    baselines = report.get("baselines") or {}
    words = baselines.get("word-overlap") or {}
    majority = baselines.get("majority") or {}
    threshold = report.get("threshold")
    decided = 0
    for row in report.get("thresholds") or []:
        if row.get("trust") == threshold:
            decided = row.get("decided") or 0
    reasons = []
    if model.get("auc") is not None and words.get("auc") is not None:
        if model["auc"] <= words["auc"]:
            reasons.append(f"AUC {model['auc']} is not above the word rule's "
                           f"{words['auc']}")
    if model.get("accuracy") is not None and majority.get("accuracy") is not None:
        if model["accuracy"] < majority["accuracy"]:
            reasons.append(f"accuracy {model['accuracy']} is below guessing the "
                           f"majority ({majority['accuracy']})")
    if not decided:
        reasons.append(f"the threshold {threshold} decides no case")
    if not reasons:
        return {"answer": "ship", "reasons": [],
                "numbers": {"auc": model.get("auc"), "words-auc": words.get("auc"),
                            "accuracy": model.get("accuracy"),
                            "majority": majority.get("accuracy"),
                            "decided": decided}}
    # `unproven' is for a set too small or too one-sided to tell; a
    # model that is measurably worse is `do-not-ship' whatever its size.
    small = (model.get("n") or 0) < 200
    return {"answer": "unproven" if small else "do-not-ship",
            "reasons": reasons,
            "numbers": {"auc": model.get("auc"), "words-auc": words.get("auc"),
                        "accuracy": model.get("accuracy"),
                        "majority": majority.get("accuracy"),
                        "decided": decided, "n": model.get("n")}}


def _at_threshold(probs, labels, trust: float) -> dict:
    """Return what the router would do with PROBS at TRUST, and how often wrongly."""
    table = threshold_table(probs, labels, (trust,))
    return table[0] if table else {}


def _read_json(path: str):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_calibration(path: str, calibration: dict) -> None:
    """Write CALIBRATION beside the model, where the predictor reads it."""
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(calibration, f, indent=1, sort_keys=True)
    except OSError as err:
        print(f"  cannot write {path}: {err}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
