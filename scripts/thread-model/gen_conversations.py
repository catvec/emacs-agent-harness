#!/usr/bin/env python3
"""Write conversations for the thread model, and the cases cut from them.

Two kinds of conversation go in:

* the **log** conversations, read in place from the harness's own store
  (`dataset.read_store`), which are the authorized source and never leave
  it;
* **synthetic** ones, written here, which give the set the coverage a
  single person's logs cannot: a conversation that changes subject
  midstream, an adjacent topic that shares its words, a short reply that
  continues anything, a local reference ("the second one"), a switch the
  person announces and one they do not.

The synthetic ones are written by a model from the scenario families
below, not typed by hand, so the set can be regenerated and grown.  Each
request asks for one conversation as JSON: a title, a task, and the
messages in order, each marked with the subject it belongs to -- two
adjacent messages with different subjects are a switch at the second --
and whether the message is a short reply or a local reference.  The
labels are then cut by `dataset.cases_of', which reads those marks, so a
conversation's subjects are data the model wrote and the label is the
rule applied to them, not a second opinion about the same text.

Nothing here touches the network unless asked: `--synthetic` runs the
generator against a completion endpoint, and the committed set is made
once and read afterwards.  The generator reads its key from the
environment and never writes it anywhere.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from schema import Message  # noqa: E402
from dataset import Conversation  # noqa: E402

OPENROUTER = "https://openrouter.ai/api/v1/chat/completions"
DEFAULT_MODEL = "deepseek/deepseek-v4.1-flash-1017"

# Scenario families: the shape of the work, not its subject.  A family is
# a kind of person with a kind of job, so the conversations the model
# writes are the ones a workspace really holds: one thread about a
# kitchen, one about a tax return, one about a failing test.
FAMILIES = [
    ("home renovation",
     "a person planning work on a house: rooms, materials, contractors, budget, measurements"),
    ("a small business's paperwork",
     "an owner handling invoices, a tax return, a supplier, a customer's complaint"),
    ("software maintenance",
     "a developer fixing a failing test, then a release, then a dependency, in one workspace"),
    ("academic writing",
     "an author on a paper's structure, its figures, a reviewer's comment, a deadline"),
    ("travel planning",
     "a person planning a trip: flights, a hotel, a visa, what to pack, a budget"),
    ("a garden over a season",
     "a gardener on soil, planting, watering, pests, and what to do before winter"),
    ("a bicycle restoration",
     "a mechanic on a frame, wheels, brakes, paint and the cost of parts"),
    ("a family's weekly logistics",
     "a parent on school runs, a dentist appointment, a birthday, and who drives when"),
    ("a data analysis",
     "an analyst on a dataset's columns, a query, a chart, an outlier and what to report"),
    ("a conference talk",
     "a speaker on the outline, the slides, the demo, the time limit and the questions"),
]

SYSTEM = """You write realistic conversations between a person and a helpful \
assistant in a persistent workspace. Each conversation is one thread of \
talk, the way a real person's are: mostly one subject, sometimes a \
change partway through.

Write JSON only, no prose and no code fence, in this shape:

{"conversations": [{"title": "a few words naming the thread",
                    "task": "the workspace's own name, one short phrase",
                    "messages": [{"role": "user" or "assistant",
                                  "text": "what was said",
                                  "subject": "a short slug for the subject this message is about"},
                                 ...]},
                   ...]}

Rules for each conversation:
- 8 to 16 messages, alternating, starting with the user.
- A message's "subject" is a short slug. Adjacent messages with the same \
subject are one stretch; where the subject changes, the person changed \
topic at that message.
- About half the conversations stay on ONE subject from start to finish: \
the person keeps asking about the same thing in different words. Give \
every message the same subject slug in those.
- About a third change subject ONCE, partway through, and the two \
subjects are ADJACENT: they share words and a setting but are different \
jobs. Examples: a kitchen renovation (tiles, cabinet) that turns into \
the kitchen's plumbing (sink, pipe, water); a paper's structure that \
turns into its figures; a bike's brakes that turn into its wheels. The \
words overlap and the work does not.
- About one in six changes subject to something UNRELATED, announced \
("separate question: ...", "different topic: ...") or not.
- Some user messages are short replies ("ok", "yes, do that", "and the \
other one?") and some refer back ("the second one", "that price", "same \
for the other room"). Give those the same subject slug as the message \
before them.
- Keep it ordinary and concrete: real nouns, real numbers, no marketing \
language. Each message is one to three sentences.
- The assistant answers in the same register, briefly."""


def request_conversations(model: str, family: tuple[str, str], count: int,
                          seed: int, key: str,
                          timeout: float = 240.0) -> list[dict] | None:
    """Ask MODEL for COUNT conversations in FAMILY; return the JSON or nil."""
    name, shape = family
    prompt = (f"Write {count} conversations about {name}: {shape}.\n"
              f"Variation {seed}: make them different subjects, different "
              f"people, and different from the other conversations about "
              f"{name}.")
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": prompt}],
        "max_tokens": 12000,
        "temperature": 0.9,
    }).encode()
    request = urllib.request.Request(
        OPENROUTER, data=body,
        headers={"Authorization": f"Bearer {key}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as answer:
            reply = json.load(answer)
        text = (reply["choices"][0]["message"].get("content") or "").strip()
        if text.startswith("```"):
            text = text.split("\n", 1)[1] if "\n" in text else text
            text = text.rsplit("```", 1)[0]
        parsed = json.loads(text)
        if isinstance(parsed, list):
            return parsed
        if isinstance(parsed, dict) and isinstance(parsed.get("conversations"), list):
            return parsed["conversations"]
        if isinstance(parsed, dict) and isinstance(parsed.get("messages"), list):
            return [parsed]
        return None
    except (urllib.error.URLError, ValueError, KeyError, IndexError) as err:
        print(f"  {name} {seed}: {err}", file=sys.stderr)
        return None


def to_conversation(raw: dict, family: str, index: int) -> Conversation | None:
    """Return RAW as a Conversation, or nil when it is not usable.

    The subjects the model wrote are kept, one per message, in the
    conversation's `subjects': they are where it changed subject, which
    is what the label rule reads.  A message with no subject keeps an
    empty one, and a conversation whose subjects are missing is read by
    its cues instead, like a log conversation.
    """
    messages = raw.get("messages")
    if not isinstance(messages, list) or len(messages) < 4:
        return None
    conversation = Conversation(
        id=f"syn-{family}-{index:03d}",
        title=str(raw.get("title") or family),
        task=str(raw.get("task") or family),
        source="synthetic")
    for item in messages:
        if not isinstance(item, dict):
            return None
        role = str(item.get("role") or "")
        text = str(item.get("text") or "").strip()
        if role not in ("user", "assistant") or not text:
            return None
        conversation.messages.append(Message(role=role, text=text))
        conversation.subjects.append(str(item.get("subject") or "").strip())
    return conversation


def switch_indices(conversation: Conversation) -> set[int]:
    """Return the message indices where CONVERSATION changes subject.

    For a synthetic conversation that is where its own subject record
    changes.  For a log conversation there is no record, and the cues in
    `dataset.cases_of` are the only reading there is.
    """
    subjects = conversation.subjects
    if len(subjects) != len(conversation.messages) or not any(subjects):
        return set()
    out = set()
    for i in range(1, len(subjects)):
        if subjects[i] and subjects[i - 1] and subjects[i] != subjects[i - 1]:
            out.add(i)
    return out


def write(path: str, conversations: list[Conversation]) -> None:
    """Write CONVERSATIONS to PATH, one JSON object per line."""
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for conversation in conversations:
            f.write(json.dumps(conversation.to_dict(), ensure_ascii=False,
                               sort_keys=True) + "\n")


def read(path: str) -> list[Conversation]:
    """Read the conversations in PATH."""
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(Conversation.from_dict(json.loads(line)))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Write conversations for the thread model.")
    ap.add_argument("--out", default="data/conversations.jsonl")
    ap.add_argument("--per-family", type=int, default=3,
                    help="conversations asked for in each request")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--append", action="store_true",
                    help="add to the conversations already in --out")
    ap.add_argument("--sleep", type=float, default=0.0,
                    help="seconds between requests")
    args = ap.parse_args()

    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        print("OPENROUTER_API_KEY is not set", file=sys.stderr)
        return 2
    conversations = read(args.out) if (args.append and os.path.exists(args.out)) else []
    rng = random.Random(args.seed)
    made = 0
    for family in FAMILIES:
        variation = rng.randrange(1, 10 ** 6)
        raws = request_conversations(args.model, family, args.per_family,
                                     variation, key)
        if not raws:
            continue
        for raw in raws:
            conversation = to_conversation(raw, family[0].replace(" ", "-"),
                                           len(conversations))
            if conversation is None:
                print(f"  {family[0]} {variation}: not a usable conversation",
                      file=sys.stderr)
                continue
            conversations.append(conversation)
            made += 1
            print(f"  {conversation.id}: {len(conversation.messages)} messages, "
                  f"{len(switch_indices(conversation))} switch(es)", file=sys.stderr)
        write(args.out, conversations)
        if args.sleep:
            time.sleep(args.sleep)
    write(args.out, conversations)
    print(f"-> {args.out}: {len(conversations)} conversations ({made} new)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
