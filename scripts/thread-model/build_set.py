#!/usr/bin/env python3
"""Build the cases the thread model trains and is measured on.

    python3 dataset.py --conversations data/conversations.jsonl --out data/cases.jsonl

The set is made of four parts, and the report names how many of each:

* **log** conversations, read in place from the harness's own session
  store (`--state-directory`), which is the authorized source.  A log
  conversation is one thread of talk; its decisions are the person's own
  messages, labelled by whether they continue it.
* **synthetic** conversations (`gen_conversations.py`), which bring the
  cases a single person's logs do not have: announced and unannounced
  switches, adjacent subjects, short replies, local references.
* **splices**: a real message put into another conversation's context.
  This is the negative the logs cannot give -- the message is real, the
  context is real, and they are not about the same thing -- and it is
  what a topic switch looks like from the router's side.
* **reviewed** ambiguous cases, when a reviewer labelled them
  (`data/reviewed.jsonl`): the cases the rules refuse to settle, decided
  by a person and marked `uncertain' where they are still unsure.

Then the split.  Every case is put in the group its near-duplicate key
names (`dataset.group_key`), and a group goes to one side: train, val or
test.  The counts are printed per part and per slice, so a set that is
all short replies, or one whose test half is all switches, is visible
before it is trained on.

The set is written as JSONL, one case per line, with the rendered text
the model reads and the fields the evaluation slices on.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dataset as D  # noqa: E402
import gen_conversations as G  # noqa: E402
from schema import render_case  # noqa: E402

# How many splices to cut per conversation.  One splice per conversation
# is enough to give every conversation a negative of its own; more would
# make the set's negatives mostly splices rather than real switches.
SPLICES_PER_CONVERSATION = 2

# The share of a conversation's decisions kept when it is a log.  A long
# log holds hundreds of messages, most of them ordinary continuations;
# keeping all of them would drown the switches.  The cap is per
# conversation, not per split, so no conversation is dropped whole.
MAX_CASES_PER_CONVERSATION = 60


def row_of(case, split: str, group: str) -> dict:
    """Return CASE as one line of the set."""
    return {
        "id": case.id,
        "split": split,
        "group": group,
        "conversation": case.conversation,
        "current": case.current,
        "label": case.label,
        "text": render_case(case),
        "slice": case.slice,
        "uncertain": case.uncertain,
        "source": case.source,
        # An uncertain case moves the gradient by half a case: the text
        # does not settle the label, so the label is a weaker claim about
        # it than about an ordinary one.
        "weight": 1.0 if not case.uncertain else 0.5,
    }


def build(conversations, state_directory: str = "", seed: int = 7,
          splices: bool = True) -> tuple[list[dict], dict]:
    """Return the rows of the set, and what it is made of.

    The split is by near-duplicate group (`dataset.groups'), computed
    over the whole set before any case is assigned: a group is one side
    of the line, and the check at the end refuses a set where that is
    not true.
    """
    rng = random.Random(seed)
    cases = []
    for conversation in conversations:
        cases.extend(D.cases_of(conversation)[:MAX_CASES_PER_CONVERSATION])
    if splices and len(conversations) >= 2:
        for target in conversations:
            others = [c for c in conversations if c.id != target.id]
            for _ in range(SPLICES_PER_CONVERSATION):
                source = rng.choice(others)
                at = rng.randrange(1, max(2, len(target.messages)))
                case = D.splice(source, target, at)
                if case is not None:
                    cases.append(case)
    valid = []
    for case in cases:
        ok, why = case.valid()
        if not ok:
            print(f"  dropped {case.id}: {why}", file=sys.stderr)
            continue
        valid.append(case)
    group_of = D.groups(valid)
    labels = {case.id: case.label for case in valid}
    split_of = D.stratified_split(group_of, labels)
    rows = []
    for case in valid:
        group = group_of[case.id]
        rows.append(row_of(case, split_of[group], group))
    report = D.provenance(conversations, cases, state_directory)
    report["splices"] = sum(1 for r in rows if r["slice"] == "spliced")
    by_split = {}
    for row in rows:
        by_split.setdefault(row["split"], []).append(row)
    report["splits"] = {
        name: {"n": len(group),
               "continue": sum(1 for r in group if r["label"] == 1),
               "switch": sum(1 for r in group if r["label"] == 0),
               "groups": len({r["group"] for r in group})}
        for name, group in sorted(by_split.items())}
    report["by-slice-split"] = {
        name: dict(sorted({s: sum(1 for r in group if r["slice"] == s)
                           for s in {r["slice"] for r in group}}.items()))
        for name, group in sorted(by_split.items())}
    # A group must never be on two sides of the line: that is the whole
    # leakage rule, so it is checked rather than assumed.
    seen: dict[str, str] = {}
    for row in rows:
        other = seen.setdefault(row["group"], row["split"])
        if other != row["split"]:
            raise SystemExit(f"group {row['group']} is in both {other} and "
                             f"{row['split']}")
    return rows, report


def main() -> int:
    ap = argparse.ArgumentParser(description="Build the thread model's cases.")
    ap.add_argument("--conversations", default="data/conversations.jsonl")
    ap.add_argument("--state-directory", default="",
                    help="a harness state directory to read logs from")
    ap.add_argument("--logs", default="",
                    help="extra conversations read from this file, as JSONL")
    ap.add_argument("--out", default="data/cases.jsonl")
    ap.add_argument("--report", default="data/set.json")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--no-splices", action="store_true")
    args = ap.parse_args()

    conversations = []
    if args.conversations and os.path.exists(args.conversations):
        conversations.extend(G.read(args.conversations))
    if args.logs and os.path.exists(args.logs):
        conversations.extend(G.read(args.logs))
    if args.state_directory:
        conversations.extend(D.read_store(args.state_directory))
    if not conversations:
        print("no conversations: nothing to build", file=sys.stderr)
        return 2
    rows, report = build(conversations, args.state_directory, args.seed,
                         splices=not args.no_splices)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    with open(args.report, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    for name, counts in report["splits"].items():
        print(f"{name}: {counts}", file=sys.stderr)
    print(f"-> {args.out}: {len(rows)} cases; {args.report}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
