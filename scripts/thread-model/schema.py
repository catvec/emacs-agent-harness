"""What a thread decision is, what it reads, and what its number means.

The decision is one question about one incoming message:

    does this message belong to the thread the person is writing in?

The answer is one probability, `p_continue': the probability that the
message continues the current thread.  Its complement is *not* a choice
of another thread.  A message that does not continue this one may belong
to an older thread or to no thread yet, and which of those it is is a
different decision, made from the threads themselves by the workspace's
router (`harness-workspace--route').  The model says "not this thread"
and stops there; nothing here pretends to know where else the message
goes.

## The label

    continue  the message is part of the current thread's topic, as the
              person writing it meant it
    switch    it is not: the topic changed, or the message belongs to a
              different subject altogether

The label is about *the topic of the stretch of conversation*, not
about who wrote what or which conversation a log happened to file the
message under.  A conversation's id is sampling metadata: it says where
the text came from, never what the label is.  Two consequences the data
must honour:

* a conversation that changes subject midstream is a *switch* at that
  message, even though it is the same conversation;
* a message spliced into a conversation from another one is a *switch*,
  even when the two conversations share words.

## Uncertainty

Some messages are genuinely neither: "ok", "and then?", "what about
that one?" continue whatever is happening, and "let's do the other
thing" is a switch that names nothing.  A label of `continue' or
`switch' on such a message is a claim the text does not support, so a
case may carry `uncertain: true' and, when it does, the training loss
down-weights it and the evaluation reports it as its own slice instead
of counting it as an ordinary error.  The model is not asked to be
confident about what the label itself cannot settle.

## What the model reads

One rendered text, and nothing else: the same discipline the tool-call
classifier uses, so a training run and an inference call read one shape.

    Task: <the workspace's name, when there is one>
    Current thread: <its title>
    Thread so far:
    - user: <an earlier message of the thread>
    - assistant: <an earlier reply>
    Knowledge:
    - <a graph block found at decision time, when any>
    Message to place:
    - <the incoming message>

Three rules about that text:

* Every part of it is what was available *at the moment of the
  decision*.  The thread so far is the messages before the incoming one;
  the knowledge lines are the search results that existed then.  A
  message that came after it, a page curated later, or the answer the
  label was taken from never appears.
* A missing part is missing, not filled in: a thread with no summary
  writes no summary line, a workspace with no graph writes no knowledge
  lines.  The renderer is total -- any of these may be None or empty --
  so a malformed or partial context still renders, and the model's
  reading of a degraded input is measurable (`missing_graph' and
  `missing_context' in the evaluation).
* The message to place is set apart and last, because it is the thing
  the answer is about; everything before it is context.  Without the
  separation a model trained on the whole text averages the messages
  and answers about the stretch, not about the message.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

# The two labels, in the order the head is trained: index 0 is
# `continue'.  `LABELS[1]` is the complement, and it is deliberately not
# called "another thread" -- see the module docstring.
LABELS = ("continue", "switch")

# The decision's name, shared by the artifact, the request and the
# module that consumes it (`harness-thread-model.el').
DECISION = "thread-continuation"

# The schema version of the features and of the artifact.  A model whose
# artifact says another version is not read by this code.
SCHEMA_VERSION = 1

# What the model reads, named as the artifact names it.  A request that
# does not carry exactly these features is refused by the decision
# provider contract rather than silently filled in.
FEATURES = ("message", "thread-title", "thread-context", "knowledge", "sender")

# How much of each part is rendered, in characters.  A 512-token window
# holds about 2000 characters of English; the budget keeps the whole
# rendering inside it with room for the message.
CONTEXT_MESSAGES = 6
CONTEXT_CHARS = 700
KNOWLEDGE_BLOCKS = 3
KNOWLEDGE_CHARS = 300
MESSAGE_CHARS = 1200

# Roles a message may have.  `assistant' and `user' are the two the
# workspace records; `system' is a note the harness itself wrote into the
# timeline, and it is context, never the message being placed.
ROLES = ("user", "assistant", "system")


def _one_line(text: Any, limit: int) -> str:
    """Return TEXT as one line of at most LIMIT characters."""
    if text is None:
        return ""
    text = " ".join(str(text).split())
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "\u2026"
    return text


@dataclass
class Message:
    """One message of a conversation, as the decision sees it."""

    role: str
    text: str
    at: float = 0.0          # seconds since the epoch, when known
    author: str = ""         # who sent it: a person, a profile, an agent

    def to_dict(self) -> dict[str, Any]:
        return {"role": self.role, "text": self.text, "at": self.at,
                "author": self.author}

    @staticmethod
    def from_dict(d: dict[str, Any]) -> "Message":
        return Message(role=str(d.get("role") or "user"),
                       text=str(d.get("text") or ""),
                       at=float(d.get("at") or 0.0),
                       author=str(d.get("author") or ""))

    def valid(self) -> tuple[bool, str]:
        if self.role not in ROLES:
            return False, f"role {self.role!r} is not one of {ROLES}"
        if not str(self.text).strip():
            return False, "empty message"
        return True, ""


@dataclass
class Case:
    """One decision: a message, the thread it arrived in, and its label.

    `label' is 1 for `continue' and 0 for `switch'.  `uncertain' says the
    text does not settle it (see the module docstring): such a case is
    trained with less weight and reported in its own slice.  `slice'
    names the kind of case -- `ordinary', `adjacent', `in-conversation',
    `spliced', `short-reply', `local-reference', `ambiguous' -- so the
    evaluation can say where the model does well and where it does not.
    `conversation' is the id of the conversation the message really
    belongs to, used for the split and never as the label.
    """

    id: str
    conversation: str
    current: str                  # the conversation the thread came from
    label: int
    message: Message
    context: list[Message] = field(default_factory=list)
    title: str = ""
    task: str = ""
    knowledge: list[str] = field(default_factory=list)
    slice: str = "ordinary"
    uncertain: bool = False
    # Which conversation the incoming message was really written in, when
    # that is not the current one (a spliced case).  Sampling metadata,
    # never the label.
    origin: str = ""
    # Where the label came from: "log" for a real conversation, "synthetic"
    # for one written for the set, "review" for a human reading of an
    # ambiguous case.
    source: str = "log"

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "conversation": self.conversation,
                "current": self.current, "label": self.label,
                "message": self.message.to_dict(),
                "context": [m.to_dict() for m in self.context],
                "title": self.title, "task": self.task,
                "knowledge": list(self.knowledge), "slice": self.slice,
                "uncertain": self.uncertain, "origin": self.origin,
                "source": self.source}

    @staticmethod
    def from_dict(d: dict[str, Any]) -> "Case":
        return Case(id=str(d["id"]),
                    conversation=str(d.get("conversation") or ""),
                    current=str(d.get("current") or ""),
                    label=int(d["label"]),
                    message=Message.from_dict(d.get("message") or {}),
                    context=[Message.from_dict(m) for m in d.get("context") or []],
                    title=str(d.get("title") or ""),
                    task=str(d.get("task") or ""),
                    knowledge=[str(k) for k in d.get("knowledge") or []],
                    slice=str(d.get("slice") or "ordinary"),
                    uncertain=bool(d.get("uncertain") or False),
                    origin=str(d.get("origin") or ""),
                    source=str(d.get("source") or "log"))

    def valid(self) -> tuple[bool, str]:
        if self.label not in (0, 1):
            return False, "label must be 0 or 1"
        if not self.conversation.strip():
            return False, "no conversation id"
        ok, why = self.message.valid()
        if not ok:
            return False, f"message: {why}"
        for m in self.context:
            ok, why = m.valid()
            if not ok:
                return False, f"context: {why}"
        if self.uncertain and self.slice != "ambiguous":
            # An uncertain case is an ambiguous one; a case that is both
            # labelled confidently and marked uncertain would be counted
            # in two slices with two readings.
            return False, "an uncertain case is in the ambiguous slice"
        return True, ""

    @property
    def label_name(self) -> str:
        """Return the label's name: 1 is `continue', 0 is `switch'."""
        return LABELS[0] if self.label == 1 else LABELS[1]


def render_case(case: Case, context_messages: int = CONTEXT_MESSAGES,
                context_chars: int = CONTEXT_CHARS,
                knowledge_blocks: int = KNOWLEDGE_BLOCKS,
                knowledge_chars: int = KNOWLEDGE_CHARS,
                message_chars: int = MESSAGE_CHARS) -> str:
    """Render CASE as the one text the model reads.

    Total in every argument: a case with no title, no context and no
    knowledge renders to a well-formed text with those lines left out.
    The order is fixed, so a training run and an inference call agree
    without sharing a template that could drift.
    """
    lines: list[str] = []
    task = _one_line(case.task, 200)
    if task:
        lines.append(f"Task: {task}")
    title = _one_line(case.title, 200)
    lines.append(f"Current thread: {title}" if title else "Current thread: (untitled)")
    recent = [m for m in case.context if m.role in ("user", "assistant")]
    recent = recent[-context_messages:] if context_messages > 0 else []
    if recent:
        lines.append("Thread so far:")
        for m in recent:
            lines.append(f"- {m.role}: {_one_line(m.text, context_chars)}")
    knowledge = [_one_line(k, knowledge_chars)
                 for k in case.knowledge[:knowledge_blocks] if _one_line(k, 10)]
    if knowledge:
        lines.append("Knowledge:")
        for block in knowledge:
            lines.append(f"- {block}")
    sender = _one_line(case.message.author, 60)
    if sender:
        lines.append(f"Sender: {sender}")
    lines.append("Message to place:")
    lines.append(f"- {_one_line(case.message.text, message_chars)}")
    return "\n".join(lines)


def render_features(case: Case) -> dict[str, Any]:
    """Return CASE's features as the decision-provider request spells them.

    The features are the five the artifact declares, rendered once here
    so that a request made by the Emacs module and a request made by the
    evaluator are the same five strings.  `message' is the rendered text
    the model reads; the others are the parts it is made of, which is
    what the artifact's agreement check compares.
    """
    return {
        "message": render_case(case),
        "thread-title": case.title,
        "thread-context": len(case.context),
        "knowledge": len(case.knowledge),
        "sender": case.message.author,
    }


def read_jsonl(path: str) -> list[Case]:
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(Case.from_dict(json.loads(line)))
    return out


def write_jsonl(path: str, cases: list[Case]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for case in cases:
            f.write(json.dumps(case.to_dict(), ensure_ascii=False,
                               sort_keys=True) + "\n")
