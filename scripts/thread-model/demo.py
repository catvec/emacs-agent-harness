#!/usr/bin/env python3
"""Show the thread model's readings, and what the router does with them.

    python3 demo.py                 # the committed model
    python3 demo.py --model DIR     # another one

Each case is a message and the thread it arrived in, written here so the
demo needs no workspace.  For each one the demo prints what the model
says, the reading the router makes of it at the shipped trust, and the
word rule's own score for comparison -- which is the point: on this model
the word rule is usually the better reader, and the demo shows that
rather than claiming otherwise.

`--ablate` prints the same cases with a part of the input missing, which
is what the evaluation measures on the held-out set.

On the committed model every reading is undecided and the word rule gets
two of the four settled cases right, which is the model card's verdict in
one screen rather than a claim about it.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import evaluate as E  # noqa: E402
from schema import Case, Message, render_case  # noqa: E402

# The cases: a message, the thread it arrived in, and what a person would
# say the answer is.  The last column is the honest one, not the label the
# model was trained on.
CASES = [
    {
        "name": "a continuation that shares its words",
        "truth": "continues",
        "title": "Kitchen renovation",
        "context": [("user", "The kitchen tiles are ordered."),
                    ("assistant", "They arrive Thursday.")],
        "message": "Are the kitchen tiles matte or glossy?",
    },
    {
        "name": "a continuation that shares none of its words",
        "truth": "continues",
        "title": "Tax return",
        "context": [("user", "I filed the federal return last week."),
                    ("assistant", "Good. The state one is still open.")],
        "message": "And the second one?",
    },
    {
        "name": "an adjacent subject that shares its words",
        "truth": "switches",
        "title": "Kitchen renovation",
        "context": [("user", "The kitchen tiles are ordered."),
                    ("assistant", "They arrive Thursday.")],
        "message": "The kitchen sink is leaking under the window.",
    },
    {
        "name": "an announced switch",
        "truth": "switches",
        "title": "Kitchen renovation",
        "context": [("user", "The kitchen tiles are ordered."),
                    ("assistant", "They arrive Thursday.")],
        "message": "Different topic: my sister's wedding is in June.",
    },
    {
        "name": "a short reply that continues anything",
        "truth": "ambiguous",
        "title": "Kitchen renovation",
        "context": [("user", "The kitchen tiles are ordered."),
                    ("assistant", "They arrive Thursday.")],
        "message": "ok, do that",
    },
]


def case_of(spec: dict) -> Case:
    """Return the demo case SPEC as a schema case."""
    return Case(
        id=spec["name"], conversation="demo", current="demo", label=1,
        message=Message(role="user", text=spec["message"]),
        context=[Message(role=role, text=text) for role, text in spec["context"]],
        title=spec["title"], task="Home")


def main() -> int:
    ap = argparse.ArgumentParser(description="Show the thread model's readings.")
    ap.add_argument("--model", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "model"))
    ap.add_argument("--trust", type=float, default=0.9)
    ap.add_argument("--ablate", action="store_true",
                    help="also print each case with a part of it missing")
    ap.add_argument("--threads", type=int, default=8)
    args = ap.parse_args()

    if not os.path.exists(os.path.join(args.model, "config.json")):
        print(f"no model in {args.model}: run train.py first, or point "
              f"--model at one", file=sys.stderr)
        return 2

    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model)
    temperature = 1.0
    calibration = os.path.join(args.model, "calibration.json")
    if os.path.exists(calibration):
        import json
        with open(calibration, encoding="utf-8") as f:
            temperature = float(json.load(f).get("temperature") or 1.0)

    texts = [render_case(case_of(spec)) for spec in CASES]
    probs = E.predict(model, tokenizer, texts, threads=args.threads)
    probs = E.apply_temperature(probs, temperature)

    print(f"model {args.model} · temperature {temperature} · trust {args.trust}\n")
    for spec, text, prob in zip(CASES, texts, probs):
        reading = ("continue" if prob >= args.trust
                   else "switch" if prob <= 1 - args.trust else "undecided")
        words = E.word_overlap_rule(text)
        print(f"{spec['name']}")
        print(f"  truth   {spec['truth']}")
        print(f"  model   P(continue) {prob:.3f} → {reading}")
        print(f"  words   {words:.3f} → "
              f"{'continue' if words >= 0.2 else 'switch'}")
        if args.ablate:
            for how in ("no-context", "no-graph", "empty"):
                degraded = E.degraded(text, how)
                value = E.predict(model, tokenizer, [degraded],
                                  threads=args.threads)[0]
                value = E.apply_temperature([value], temperature)[0]
                print(f"  {how:<14} {value:.3f}")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
