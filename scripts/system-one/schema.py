"""What a workflow is, and how one tool call is rendered for the model.

A workflow is a short, realistic stretch of an agent's work on one
scenario: the task the user gave it, and the ordered calls it makes.  It
is labelled good or bad as a whole, not call by call: the same `rm -rf`
is ordinary in one workflow and destructive in another, and the point of
a window of calls is that it holds the reason one way or the other.

The label means: would a careful reviewer, seeing only this stretch of
work in this project, say the agent was doing the job safely?  Bad
workflows are not \"a dangerous word appears\"; they are the calls that
break the user's work, leak what must not leave the machine, reach
outside what the user gave the agent, or take a destructive step nothing
in the task asked for.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

# The tools a workflow may use.  These are the harness's own tool names
# where one exists, so the text the classifier reads looks like the text
# the permission chain renders.
TOOL_KINDS = ("read", "edit", "search", "bash", "net", "git", "web", "meta")

MAX_CALLS = 14
MIN_CALLS = 2


@dataclass
class Call:
    """One tool call: its name, its arguments."""

    tool: str
    kind: str
    args: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {"tool": self.tool, "kind": self.kind, "args": self.args}

    @staticmethod
    def from_dict(d: dict[str, Any]) -> "Call":
        return Call(tool=str(d.get("tool", "")),
                    kind=str(d.get("kind", "")),
                    args=d.get("args") or {})


@dataclass
class Workflow:
    """A labelled stretch of an agent's work."""

    id: str
    scenario: str
    task: str
    label: int                      # 1 good, 0 bad
    calls: list[Call]
    reason: str                     # why the label, in one sentence
    risk: str = ""                  # bad ones: the harm, in a few words
    harm: list[int] = field(default_factory=list)   # 0-based positions of the
                                                    # calls that do the harm
    source: str = "llm"

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "scenario": self.scenario, "task": self.task,
                "label": self.label, "reason": self.reason, "risk": self.risk,
                "source": self.source,
                "harm": self.harm,
                "calls": [c.to_dict() for c in self.calls]}

    @staticmethod
    def from_dict(d: dict[str, Any]) -> "Workflow":
        return Workflow(id=str(d["id"]), scenario=str(d.get("scenario", "")),
                        task=str(d.get("task", "")), label=int(d["label"]),
                        calls=[Call.from_dict(c) for c in d.get("calls", [])],
                        reason=str(d.get("reason", "")), risk=str(d.get("risk", "")),
                        harm=[int(h) for h in d.get("harm") or []],
                        source=str(d.get("source", "llm")))

    def valid(self) -> tuple[bool, str]:
        if self.label not in (0, 1):
            return False, "label must be 0 or 1"
        if not self.task.strip():
            return False, "no task"
        if not (MIN_CALLS <= len(self.calls) <= MAX_CALLS):
            return False, f"{len(self.calls)} calls, want {MIN_CALLS}..{MAX_CALLS}"
        for c in self.calls:
            if not c.tool.strip():
                return False, "a call has no tool"
            if not isinstance(c.args, dict):
                return False, f"{c.tool}: args is not an object"
        return True, ""


def render_args(args: dict[str, Any], limit: int = 300) -> str:
    """Render a call's arguments as one line, cut at LIMIT characters."""
    parts = []
    for key, value in args.items():
        if isinstance(value, str):
            text = value
        else:
            text = json.dumps(value, ensure_ascii=False)
        text = " ".join(text.split())
        if len(text) > limit:
            text = text[:limit] + "..."
        parts.append(f"{key}={text}")
    return " ".join(parts)


def render_call(call: Call, limit: int = 300) -> str:
    """Render one call as the classifier reads it."""
    args = render_args(call.args, limit)
    return f"{call.tool}({args})" if args else f"{call.tool}()"


def render_decision(workflow: Workflow, context: list[Call], call: Call,
                    limit: int = 300) -> str:
    """Render the decision the classifier makes: CALL, given CONTEXT.

    The call being decided is set apart from the ones before it, because
    they are not the same kind of thing: the context is already done and
    cannot be changed, and the call is what the answer is about.  Without
    the separation a window of five calls reads as five equal candidates,
    and a model trained on it learns to average them -- which is why a
    longer window scored worse than a single call until the call was
    marked.
    """
    lines = [f"Task: {' '.join(workflow.task.split())}"]
    if context:
        lines.append("Earlier calls in this turn:")
        for c in context:
            lines.append(f"- {render_call(c, limit)}")
    lines.append("Call to decide:")
    lines.append(f"- {render_call(call, limit)}")
    return "\n".join(lines)


def render_window(workflow: Workflow, calls: list[Call], limit: int = 300) -> str:
    """Render a window of CALLS of WORKFLOW as the classifier's input text.

    The project's task comes first, because the same command means
    different things in different jobs, then the calls in the order they
    were made.  Nothing says how many calls the window holds or where it
    was cut from: a classifier that learned "the last one is the call"
    from a marker would not survive the real stream.
    """
    lines = [f"Task: {' '.join(workflow.task.split())}"]
    for call in calls:
        lines.append(f"- {render_call(call, limit)}")
    return "\n".join(lines)


def read_jsonl(path: str) -> list[Workflow]:
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(Workflow.from_dict(json.loads(line)))
    return out


def write_jsonl(path: str, workflows: list[Workflow]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for w in workflows:
            f.write(json.dumps(w.to_dict(), ensure_ascii=False, sort_keys=True) + "\n")
