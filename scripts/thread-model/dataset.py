"""Read authorized conversation logs into cases, and keep them honest.

The primary source is the harness's own session store: one JSONL log per
session under `harness-state-directory/sessions/ID.nodes.jsonl', holding
the user and assistant nodes of a conversation in order (`session/append'
writes them; `harness-insights--own-nodes' reads them the same way).
Nothing here reaches the network, and nothing writes to the store.

## What a log becomes

A session log is a conversation.  Walking it in time order gives the
messages of one thread of talk: the user's messages and the assistant's
replies, with the hints, tool calls and results left out.  Every user
message after the first few is one decision:

    context  the messages before it, oldest first
    message  the message itself
    label    `continue' when it is the next message of the same topic,
             `switch' when the conversation changed subject there

The label is *not* the session id.  A log is one conversation, and one
conversation may change subject: the topic change is what the label is
about, so the reader looks for it.

## Where a switch comes from

Three sources, in order of how much they can be trusted:

1. a **spliced** message: the message was really written in another
   conversation, so it does not continue this one, whatever it says;
2. an **in-conversation** switch: the same conversation, but the person
   said so ("separate question", "different topic") or the message is
   about something the thread has not been about at all.  This is the
   hard negative, and the one that has to be reviewed rather than
   trusted: the cues catch the announced switches, and the unannounced
   ones are `uncertain' unless a reviewer said otherwise;
3. a **new thread**: the workspace's own record of which thread a message
   went to (`workspaces/ID.timeline.jsonl'), when one is available.  A
   message the person moved to another thread by hand is a switch that
   was *corrected*, and the correction is the label -- the manual
   reassignment is the user's overriding answer, not a suggestion.

## Leakage

The rules are in `split_of' and `group_key', and they are the reason this
module is separate from the schema:

* a split is by conversation, never by case.  Two messages of one
  conversation never sit on two sides of the line, because the second
  one's context holds the first;
* near duplicates are grouped *across* conversations before the split:
  two conversations about the same subject, or a synthetic variant of a
  log conversation, are one group, and a group is never split;
* a case's context is cut to the messages before it, and a case whose
  label came from a later event (a reassignment, a curated page) is
  dropped when that event is after the decision's own timestamp.

The set this module writes names every source it read and the count from
each, so a training run's provenance is a file rather than a claim.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass, field
from typing import Any, Iterable

from schema import Case, Message

# A decision needs some context to be about: a message with nothing
# before it is not a continuation of anything.
MIN_CONTEXT = 2

# The cues that announce a change of subject in the person's own words.
# They are the same family as the workspace router's own cues
# (`harness-workspace--topic-cues'), because the model must agree with
# the router about what an announced switch sounds like.
SWITCH_CUES = (
    "new topic", "different topic", "another topic", "change the subject",
    "change of subject", "change topic", "different subject", "unrelated",
    "separate thread", "separate question", "start over", "new thread",
    "on another note", "off topic", "switching topics", "switch topics",
    "new question", "different question", "another question",
    "let's switch", "lets switch", "move on to", "moving on to",
    "new conversation", "fresh start", "by the way",
)

# The words that tie a message to the one before it, whatever the
# subject: a short reply of these is a continuation the text cannot
# settle, and it is labelled uncertain rather than guessed.
CONTINUATION_WORDS = frozenset((
    "ok", "okay", "yes", "no", "sure", "thanks", "thank", "great", "good",
    "fine", "and", "then", "also", "again", "more", "next", "but", "so",
    "that", "this", "it", "those", "these", "what", "why", "how", "where",
    "when", "do", "does", "did", "can", "could", "would", "should",
    "please", "continue", "go", "ahead", "same", "other", "one", "now",
))

STOP_WORDS = frozenset((
    "a", "about", "after", "again", "against", "all", "also", "am", "an",
    "and", "any", "are", "as", "at", "be", "because", "been", "before",
    "being", "below", "between", "both", "but", "by", "can", "could", "did",
    "do", "does", "doing", "done", "down", "during", "each", "few", "for",
    "from", "further", "get", "got", "had", "has", "have", "having", "he",
    "her", "here", "hers", "him", "his", "how", "i", "if", "in", "into",
    "is", "it", "its", "just", "let", "lets", "like", "me", "more", "most",
    "my", "no", "nor", "not", "now", "of", "off", "on", "once", "only",
    "or", "other", "our", "ours", "out", "over", "own", "please", "same",
    "she", "should", "so", "some", "such", "than", "that", "the", "their",
    "theirs", "them", "then", "there", "these", "they", "this", "those",
    "through", "to", "too", "under", "until", "up", "very", "was", "we",
    "were", "what", "when", "where", "which", "while", "who", "whom", "why",
    "will", "with", "would", "you", "your", "yours",
))

WORD = re.compile(r"[a-z0-9][a-z0-9'_-]+")


def content_words(text: str) -> set[str]:
    """Return the words of TEXT that say something about its subject."""
    return {w for w in WORD.findall((text or "").lower())
            if len(w) >= 3 and w not in STOP_WORDS}


def is_short_reply(text: str) -> bool:
    """Non-nil when TEXT is only the words that tie it to the one before it."""
    words = [w for w in WORD.findall((text or "").lower())]
    return bool(words) and len(words) <= 6 and all(w in CONTINUATION_WORDS
                                                   for w in words)


def announces_switch(text: str) -> bool:
    """Non-nil when TEXT says in its own words that the subject changed.

    The cue is matched as whole words with any punctuation around it, so
    "Separate question: the roof" and "separate question — the roof" are
    the same announcement.  A cue inside a longer word ("unrelatedness")
    is not one.
    """
    low = " ".join((text or "").lower().split())
    for cue in SWITCH_CUES:
        if re.search(r"(?<![a-z0-9])" + re.escape(cue) + r"(?![a-z0-9])", low):
            return True
    return False


def case_words(case: Case) -> set[str]:
    """Return the words a near-duplicate test compares CASE on.

    The message and the thread's title: two cases whose messages and
    titles hold the same words are the same text seen twice, and one of
    them must not train the model that is scored on the other.
    """
    return content_words(case.message.text) | content_words(case.title)


def near_duplicate_p(a: Case, b: Case, threshold: float = 0.6) -> bool:
    """Non-nil when A and B are the same text with a word or two changed.

    The measure is the Jaccard overlap of their content words: two
    messages that share most of their words are one message written
    twice, and a model trained on one is scored on the other.  A
    threshold rather than equality, because a regenerated set writes the
    same conversation with a word changed.

    A splice is never a near duplicate of anything but its own source
    material.  It is a real message put in a context it does not belong
    to, so its text is another conversation's -- and comparing it by its
    words would chain every splice through the message it reuses into
    one giant group, which is how a whole set's negatives end up on one
    side of the split.
    """
    if a.slice == "spliced" or b.slice == "spliced":
        return False
    words_a, words_b = case_words(a), case_words(b)
    if not words_a or not words_b:
        return False
    return len(words_a & words_b) / len(words_a | words_b) >= threshold


def groups(cases: list[Case], threshold: float = 0.6) -> dict[str, str]:
    """Return each case's id mapped to the id of its near-duplicate group.

    The groups are the connected components of the near-duplicate
    relation: a case is in a group with every case it duplicates, and
    with everything those duplicate.  A synthetic variant that names its
    source (`origin') is in its source's group whatever its words are,
    because a paraphrase of a log conversation is the same subject and
    must not be split from it.

    A union-find, because the relation is not transitive by nature -- A
    resembles B, B resembles C, and A need not resemble C -- and a chain
    of paraphrases is one group all the same.
    """
    parent: dict[str, str] = {}

    def find(x: str) -> str:
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a: str, b: str) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for case in cases:
        find(case.id)
    for i, a in enumerate(cases):
        for b in cases[i + 1:]:
            if near_duplicate_p(a, b, threshold):
                union(a.id, b.id)
    # A synthetic variant joins its source's group.  A splice does not:
    # its `origin' is the conversation the message was taken from, not
    # the one it was written for, and joining it there would chain every
    # splice into the group of every conversation it borrows a message
    # from.
    by_conversation = {case.conversation: case.id for case in cases}
    for case in cases:
        if (case.slice != "spliced" and case.origin
                and case.origin != case.conversation):
            source = by_conversation.get(case.origin)
            if source:
                union(source, case.id)
    # A splice reuses a message of its source conversation and sits in
    # its host's context.  It is its own group -- a distinct decision --
    # so it never chains with other splices: joining it to its host or
    # its source would merge every splice into one group through the
    # conversations they share, which is how a whole set's negatives end
    # up on one side of the split.  `near_duplicate_p' already refuses to
    # pair one with anything, so there is nothing to join.
    return {case.id: find(case.id) for case in cases}


def split_of_group(group: str, train: float = 0.7, val: float = 0.15) -> str:
    """Return "train", "val" or "test" for a near-duplicate GROUP.

    The group, not the case and not the conversation alone: a hash of the
    group's own id keeps a group on one side for good however often the
    set is regenerated, and keeps two cases that are the same text
    together.
    """
    digest = hashlib.sha256(group.encode()).hexdigest()
    share = int(digest[:8], 16) / 0xFFFFFFFF
    if share < train:
        return "train"
    if share < train + val:
        return "val"
    return "test"


def stratified_split(groups_of: dict[str, str], labels: dict[str, int],
                     train: float = 0.7, val: float = 0.15) -> dict[str, str]:
    """Return each group's split, keeping both labels in every split.

    A hash alone is not enough here.  A workspace conversation is mostly
    continuations, and the switches are few and come in bunches (the
    splices of one set, the subject changes of a handful of
    conversations): hashing the groups can put every switch in `train'
    and leave a held-out split with nothing to measure but `continue'.
    The evaluation would then report a high accuracy that says nothing.

    So the groups are walked in a hash order -- stable, so a regenerated
    set lands the same way -- and each goes to the split that is furthest
    below its share of *both* what it holds: cases, and switches.  Every
    group stays whole; only the choice of side changes.

    A set with no switch at all is split by size alone, and the report
    says so: there is nothing to stratify on.
    """
    weights: dict[str, list[float]] = {}
    for case_id, group in groups_of.items():
        slot = weights.setdefault(group, [0.0, 0.0])
        slot[0] += 1.0
        slot[1] += 1.0 if labels.get(case_id, 1) == 0 else 0.0
    total = [sum(w[0] for w in weights.values()), sum(w[1] for w in weights.values())]
    targets = {"train": train, "val": val, "test": max(0.0, 1.0 - train - val)}
    filled = {name: [0.0, 0.0] for name in targets}
    order = sorted(weights, key=lambda g: hashlib.sha256(g.encode()).hexdigest())
    out: dict[str, str] = {}
    for group in order:
        cases, switches = weights[group]
        # The deficit is measured in cases first, and in switches when
        # the two disagree: a group of switches goes where switches are
        # short before it goes where cases are short.
        def deficit(name: str) -> float:
            want_cases = targets[name] * total[0]
            want_switches = targets[name] * total[1]
            short_cases = (want_cases - filled[name][0]) / max(1.0, total[0])
            short_switches = ((want_switches - filled[name][1]) / max(1.0, total[1])
                              if total[1] else 0.0)
            return short_cases + 2.0 * short_switches

        name = max(targets, key=deficit)
        out[group] = name
        filled[name][0] += cases
        filled[name][1] += switches
    return out


def split_of(case: Case, train: float = 0.7, val: float = 0.15) -> str:
    """Return the split of CASE read on its own, as `split_of_group' does.

    A caller with one case in hand -- a test, a probe -- gets the same
    answer the set would give it if it were alone in its group.  The set
    itself is split by `stratified_split', which is what keeps two near
    duplicates together and both labels in every split.
    """
    return split_of_group(case.id, train, val)


@dataclass
class Conversation:
    """One conversation read from a log, or written for the set."""

    id: str
    messages: list[Message] = field(default_factory=list)
    title: str = ""
    task: str = ""
    source: str = "log"
    # Which thread the workspace filed each message under, by index, when
    # the workspace timeline says so.
    threads: dict[int, str] = field(default_factory=dict)
    # The knowledge blocks that existed when each message was sent, by
    # index: what a decision at that message could have retrieved.
    knowledge: dict[int, list[str]] = field(default_factory=dict)
    # The subject each message was written under, by index, when the
    # conversation records one.  Only a synthetic conversation does: it
    # is how the generator says where it changed subject, and the label
    # rule reads it.  A log conversation records none and is labelled by
    # its own cues instead.
    subjects: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "title": self.title, "task": self.task,
                "source": self.source,
                "messages": [m.to_dict() for m in self.messages],
                "threads": {str(k): v for k, v in self.threads.items()},
                "knowledge": {str(k): v for k, v in self.knowledge.items()},
                "subjects": list(self.subjects)}

    @staticmethod
    def from_dict(d: dict[str, Any]) -> "Conversation":
        return Conversation(
            id=str(d["id"]),
            messages=[Message.from_dict(m) for m in d.get("messages") or []],
            title=str(d.get("title") or ""),
            task=str(d.get("task") or ""),
            source=str(d.get("source") or "log"),
            threads={int(k): str(v) for k, v in (d.get("threads") or {}).items()},
            knowledge={int(k): [str(x) for x in v]
                       for k, v in (d.get("knowledge") or {}).items()},
            subjects=[str(s) for s in d.get("subjects") or []])


def _read_jsonl(path: str) -> list[dict[str, Any]]:
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue          # a torn last line is not a failure
                if isinstance(rec, dict):
                    out.append(rec)
    except OSError:
        return []
    return out


def _node_text(node: dict[str, Any]) -> str:
    """Return the text of NODE: its `:content', or the text of its blocks."""
    content = node.get("content")
    if isinstance(content, str):
        return content
    blocks = node.get("blocks") or []
    parts = []
    for block in blocks if isinstance(blocks, list) else []:
        if isinstance(block, dict):
            text = block.get("text")
            if isinstance(text, str):
                parts.append(text)
    return "\n".join(parts)


def _sender_kind(node: dict[str, Any]) -> str:
    """Return the kind of sender a node names, as the harness records it."""
    sender = node.get("from")
    if isinstance(sender, dict):
        return str(sender.get("kind") or "")
    return ""


def read_conversation(path: str, session_id: str = "") -> Conversation | None:
    """Return the conversation a session node log holds, or nil.

    Only the user and assistant nodes are read, in time order, and a node
    the harness wrote itself (`:meta' `:workspace-brief', an internal
    prompt) is left out: it is the harness talking to itself, not the
    person talking to the thread.  An update line merges into the node it
    names, as `harness-insights--own-nodes' does.
    """
    records = _read_jsonl(path)
    if not records:
        return None
    nodes: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for rec in records:
        node_id = rec.get("id")
        if not isinstance(node_id, str):
            continue
        if rec.get("_op") == "update":
            old = nodes.get(node_id)
            if old is not None:
                merged = dict(old)
                merged.update({k: v for k, v in rec.items() if k != "_op"})
                nodes[node_id] = merged
        elif node_id not in nodes:
            order.append(node_id)
            nodes[node_id] = rec
    conversation = Conversation(
        id=session_id or os.path.basename(path).split(".")[0])
    for node_id in order:
        node = nodes[node_id]
        kind = str(node.get("kind") or "")
        if kind not in ("user", "assistant"):
            continue
        meta = node.get("meta") if isinstance(node.get("meta"), dict) else {}
        if meta.get("workspace-brief") or meta.get("internal"):
            continue
        if _sender_kind(node) in ("system", "queue"):
            continue
        text = _node_text(node).strip()
        if not text:
            continue
        conversation.messages.append(
            Message(role=kind, text=text, at=float(node.get("ts") or 0.0),
                    author=_author(node)))
    if len(conversation.messages) < MIN_CONTEXT + 1:
        return None
    return conversation


def _author(node: dict[str, Any]) -> str:
    """Return who sent NODE, as far as the log says."""
    sender = node.get("from")
    if isinstance(sender, dict):
        return str(sender.get("name") or sender.get("kind") or "")
    return ""


def cases_of(conversation: Conversation, context_messages: int = 6,
             knowledge_blocks: int = 3) -> list[Case]:
    """Return the decisions CONVERSATION holds, one per user message.

    A message is labelled by what it does to the thread, not by which
    conversation it is in.  In order of what settles it:

    * the workspace filed the message under another thread than the one
      the messages before it were in -- the person moved it, and that
      correction is the label (`reassigned');
    * the conversation records its subjects and this message starts a new
      one -- a synthetic conversation's own record (`in-conversation');
    * the person announced the change in their words (`in-conversation');
    * the message is only the words that tie it to the one before it, so
      the text cannot settle it -- labelled `continue' with
      `uncertain' nil, in the `short-reply' slice, because a short reply
      in a thread continues it and the evaluation reports the slice on
      its own (`short-reply');
    * otherwise it continues (`ordinary', or `local-reference' when it
      repeats the words of the message before it).

    The context of a case is the messages before it and nothing later.
    """
    out: list[Case] = []
    messages = conversation.messages
    subjects = conversation.subjects if len(conversation.subjects) == len(messages) else []
    for i, message in enumerate(messages):
        if message.role != "user":
            continue
        context = messages[:i]
        if len([m for m in context if m.role in ("user", "assistant")]) < MIN_CONTEXT:
            continue
        moved = bool(conversation.threads.get(i)
                     and conversation.threads.get(i - 1)
                     and conversation.threads[i] != conversation.threads[i - 1])
        new_subject = bool(subjects and i > 0 and subjects[i] and subjects[i - 1]
                           and subjects[i] != subjects[i - 1])
        announced = announces_switch(message.text)
        short = is_short_reply(message.text)
        if moved:
            label, slice_name, uncertain = 0, "reassigned", False
        elif new_subject or announced:
            label, slice_name, uncertain = 0, "in-conversation", False
        elif short:
            label, slice_name, uncertain = 1, "short-reply", False
        else:
            label, uncertain, slice_name = 1, False, "ordinary"
            recent = " ".join(m.text for m in context[-2:])
            if content_words(message.text) & content_words(recent):
                slice_name = "local-reference"
        out.append(Case(
            id=f"{conversation.id}-{i:04d}",
            conversation=conversation.id,
            current=conversation.id,
            label=label,
            message=message,
            context=context[-context_messages:],
            title=conversation.title,
            task=conversation.task,
            knowledge=list(conversation.knowledge.get(i) or [])[:knowledge_blocks],
            slice=slice_name,
            uncertain=uncertain,
            source=conversation.source))
    return out


def splice(source: Conversation, into: Conversation, at: int,
           context_messages: int = 6) -> Case | None:
    """Return the case of a message of SOURCE spliced into INTO at AT.

    This is the negative the logs cannot supply on their own: a real
    message, real context, and the two not from the same conversation.
    It is labelled `switch' because that is what it is -- the message does
    not continue this thread -- and `origin' names the conversation it
    really came from, which is sampling metadata the split uses and the
    label never reads.
    """
    messages = [m for m in source.messages if m.role == "user"]
    if not messages or not into.messages:
        return None
    message = messages[0]
    context = into.messages[:max(0, at)][-context_messages:]
    if len(context) < MIN_CONTEXT:
        return None
    return Case(
        id=f"{into.id}-{at:04d}-spliced-{source.id}",
        conversation=into.id,
        current=into.id,
        label=0,
        message=message,
        context=context,
        title=into.title,
        task=into.task,
        knowledge=list(into.knowledge.get(at) or [])[:3],
        slice="spliced",
        uncertain=False,
        origin=source.id,
        source="spliced")


def read_store(state_directory: str, limit: int = 0) -> list[Conversation]:
    """Return the conversations in a harness state directory.

    Only `sessions/*.nodes.jsonl' is read, and only the nodes a
    conversation's own log holds: this is the authorized source the
    harness already keeps, read here and copied nowhere.  A workspace's
    timeline, when present, says which thread each message went to, and
    that is attached to the conversation.
    """
    directory = os.path.join(state_directory, "sessions")
    out: list[Conversation] = []
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return out
    threads = _workspace_threads(state_directory)
    for name in names:
        if not name.endswith(".nodes.jsonl"):
            continue
        session_id = name[: -len(".nodes.jsonl")]
        conversation = read_conversation(os.path.join(directory, name), session_id)
        if conversation is None:
            continue
        if session_id in threads:
            conversation.threads = threads[session_id]["threads"]
            conversation.title = threads[session_id].get("title") or ""
            conversation.task = threads[session_id].get("task") or ""
        out.append(conversation)
        if limit and len(out) >= limit:
            break
    return out


def _workspace_threads(state_directory: str) -> dict[str, dict[str, Any]]:
    """Return each episode's thread, title and task, from the workspaces.

    The workspace state layer keeps `workspaces/ID.json' (the threads)
    and `workspaces/ID.timeline.jsonl' (which episode each message went
    to).  Reading both is how a message the person reassigned is found;
    without them a conversation is still usable, and the only thing lost
    is the reassignment label.
    """
    out: dict[str, dict[str, Any]] = {}
    directory = os.path.join(state_directory, "workspaces")
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return out
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(directory, name), encoding="utf-8") as f:
                workspace = json.load(f)
        except (OSError, ValueError):
            continue
        titles = {}
        for thread in workspace.get("threads") or []:
            if isinstance(thread, dict):
                titles[thread.get("id")] = thread.get("title") or ""
        timeline = os.path.join(directory, name[: -len(".json")] + ".timeline.jsonl")
        for index, entry in enumerate(_read_jsonl(timeline)):
            episode = entry.get("episode")
            thread = entry.get("thread")
            if not isinstance(episode, str) or not isinstance(thread, str):
                continue
            slot = out.setdefault(episode, {"threads": {}, "title": "",
                                            "task": workspace.get("name") or ""})
            slot["threads"][index] = thread
            if not slot["title"]:
                slot["title"] = titles.get(thread) or ""
    return out


def provenance(conversations: Iterable[Conversation], cases: Iterable[Case],
               state_directory: str = "") -> dict[str, Any]:
    """Return what the set was made of, for the artifact and the model card."""
    conversations = list(conversations)
    cases = list(cases)
    by_source: dict[str, int] = {}
    for case in cases:
        by_source[case.source] = by_source.get(case.source, 0) + 1
    by_slice: dict[str, int] = {}
    for case in cases:
        by_slice[case.slice] = by_slice.get(case.slice, 0) + 1
    return {
        "state-directory": state_directory or None,
        "read": "sessions/*.nodes.jsonl and workspaces/*.json, read in place",
        "conversations": len(conversations),
        "cases": len(cases),
        "by-source": dict(sorted(by_source.items())),
        "by-slice": dict(sorted(by_slice.items())),
        "retention": ("the logs stay where the harness keeps them; this set "
                      "holds only the text a decision reads, and no secret"),
    }
