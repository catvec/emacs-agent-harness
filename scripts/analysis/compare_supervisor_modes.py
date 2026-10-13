#!/usr/bin/env python3
"""Compare fixed supervisor-mode tasks with single-session tasks.

The question: has supervisor mode made tasks slower and more expensive than the
old one-session-per-task way?  Everything here is arithmetic on the two CSV
files that scripts/analysis/extract_usage_data.py writes (tasks.csv and
sessions.csv).  No model is asked to judge or estimate anything, and nothing is
fetched from a network.

What it does:
  1. puts every task in one group (see "Classification");
  2. finds each task's sub-agents: the sessions of kind subagent or fork that
     descend from the task's own session through parent_id, transitively;
  3. totals each task's tokens and cost over its own session and those
     sub-agents, and writes classified_tasks.csv (one row per task) and
     subagents.csv (one row per sub-agent session) next to the inputs;
  4. computes per-group statistics with the `statistics` module and rewrites
     the Markdown report (default
     docs/analysis/supervisor-mode-vs-single-session-2026-10-12.md).

Classification (cutoffs below; Unix epoch seconds compared as plain numbers):
  plan-mode       the task carries the Plan-mode flag (the `plan` column)
  A               supervisor flag on, task created at or after the cache/cost fix
  excluded-buggy  supervisor flag on, task created before the fix
  B               supervisor flag off or absent (single-session, the old way)
The supervisor flag is the task session's own (`supervisor` in sessions.csv);
when the session has none, the task's explicit setting (`supervisor` in
tasks.csv) is used.  Only tasks in state `done` enter any statistic; the others
are counted as still in flight.

classified_tasks.csv has one row per task: its group and why, whether it is in
the comparison (done, and in A or B), usage_status, the task totals (total_*),
the top-level session's own figures (top_*), the sub-agents' combined figures
(sub_*), and recorded_* (what usage was recorded, a lower bound when the task is
incomplete).  subagents.csv has one row per sub-agent session.  A figure that is
not known is written "unknown", never 0.  Both hold ids and are not committed.

Usage that was never recorded is not zero: a session that took model turns yet
has no tokens and no cost in either source is `missing`, and a task with a
missing session has `incomplete` usage.  Incomplete tasks stay out of the token
and cost statistics (their figures are `unknown` in the CSVs) and stay in the
duration and sub-agent statistics.

Privacy: only ids, flags, enum values, timestamps and numbers are read or
written.  The Markdown report holds aggregates and methodology, no ids; the
script refuses to write it if anything id- or path-shaped slipped in.

Python 3 standard library only.

Usage:
    python3 -I scripts/analysis/compare_supervisor_modes.py
    python3 -I scripts/analysis/compare_supervisor_modes.py --in-dir DIR --out FILE
    python3 -I scripts/analysis/compare_supervisor_modes.py --self-test

Exit status: 0 done; 1 the self-test failed; 2 an input is missing or
unreadable, or a usage error.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import datetime as dt
import importlib.util
import math
import os
import re
import statistics
import sys
import tempfile
from collections import Counter, defaultdict, deque
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_IN_DIR = REPO_ROOT / "scripts" / ".dev" / "usage-analysis"
DEFAULT_OUT = REPO_ROOT / "docs" / "analysis" / "supervisor-mode-vs-single-session-2026-10-12.md"
EXTRACTOR = REPO_ROOT / "scripts" / "analysis" / "extract_usage_data.py"


def iso_epoch(text):
    """An ISO-8601 instant with a UTC offset as Unix epoch seconds (a float)."""
    when = dt.datetime.fromisoformat(text)
    if when.tzinfo is None:
        raise ValueError(f"{text!r} has no UTC offset")
    return when.timestamp()


# --------------------------------------------------------------------------
# Cutoffs.  Written with their UTC offset, converted to epoch seconds once.

# 73f987b "Add supervisor mode: ..." -- supervisor mode did not exist before it.
SUPERVISOR_INTRODUCED_ISO = "2026-10-08T15:24:17-04:00"

# 0803841 "Fix supervisor cache cost and planning efficiency", landing 7be8ce2
# "supervisor: start workers fresh by default, refuse forks of long
# conversations".  Before it a worker inherited (forked) the whole supervisor
# conversation: the cache/cost bug the user already knows about.
SUPERVISOR_FIX_ISO = "2026-10-11T23:55:53-04:00"

# b0a013d "Add Plan mode for tasks: a strong model plans read-only, a medium
# model works" -- a different mechanism from supervisor mode.
PLAN_MODE_INTRODUCED_ISO = "2026-10-11T21:48:45-04:00"

SUPERVISOR_INTRODUCED = iso_epoch(SUPERVISOR_INTRODUCED_ISO)
SUPERVISOR_FIX = iso_epoch(SUPERVISOR_FIX_ISO)
PLAN_MODE_INTRODUCED = iso_epoch(PLAN_MODE_INTRODUCED_ISO)

GROUP_A = "A"
GROUP_B = "B"
EXCLUDED_BUGGY = "excluded-buggy"
PLAN_MODE = "plan-mode"
GROUPS = (GROUP_A, GROUP_B, EXCLUDED_BUGGY, PLAN_MODE)
GROUP_TITLES = {
    GROUP_A: "A: fixed supervisor mode",
    GROUP_B: "B: single-session (the old way)",
    EXCLUDED_BUGGY: "Excluded: old buggy supervisor mode",
    PLAN_MODE: "Set aside: Plan mode",
}

WORKER_KINDS = ("subagent", "fork")   # a sub-agent is a session of one of these kinds
TERMINAL_STATE = "done"               # a task enters a statistic only in this state
SMALL_N = 30                          # below this a group is called small in the report
LIST_TASKS_UP_TO = 10                 # a group with at most this many done tasks is listed task by task
UNKNOWN = "unknown"                   # written to the CSVs for a figure that is not known
USAGE_FIELDS = ("input", "output", "cache_read", "cache_write", "cost", "list_cost")
TOKEN_FIELDS = ("input", "output", "cache_read", "cache_write")
BILLING_VALUES = ("api", "subscription", "extra-usage")

# Columns read from the inputs.  Anything else in them is ignored.  The
# self-test checks that each is a column extract_usage_data.py writes.
TASK_REQUIRED = ("id", "session", "created", "state")
TASK_OPTIONAL = ("started", "finished", "outcome", "model", "supervisor", "plan")
SESSION_REQUIRED = ("id", "kind", "parent_id", "created", "updated")
SESSION_OPTIONAL = ("model", "supervisor", "billing", "turns", "compactions", "forked",
                    "input", "output", "cache_read", "cache_write", "cost", "list_cost",
                    "ledger_input", "ledger_output", "ledger_cache_read", "ledger_cache_write",
                    "ledger_cost", "ledger_list_cost", "ledger_calls")

_KINDS5 = ("input", "output", "cache_read", "cache_write", "tokens")
TASK_OUT_COLUMNS = (
    ["task_id", "top_session_id", "group", "group_reason", "in_comparison", "state", "outcome",
     "supervisor_flag", "flag_source", "plan_flag", "model",
     "created", "started", "finished", "duration_s", "work_duration_s",
     "n_subagents", "n_forked_subagents", "n_other_descendants",
     "usage_status", "sessions_usage_missing"]
    + ["total_" + k for k in _KINDS5] + ["total_cost", "total_list_cost",
                                        "recorded_tokens", "recorded_cost", "recorded_list_cost"]
    + ["top_" + k for k in _KINDS5] + ["top_cost", "top_list_cost", "top_duration_s", "top_compactions"]
    + ["sub_" + k for k in _KINDS5] + ["sub_cost", "sub_list_cost", "sub_compactions",
                                      "sessions_api", "sessions_subscription", "sessions_extra_usage",
                                      "sessions_billing_none", "sessions_billing_other",
                                      "workers_created_after_finish"])

SUB_OUT_COLUMNS = [
    "task_id", "group", "in_comparison", "session_id", "parent_id", "depth", "kind", "forked",
    "model", "created", "updated", "duration_s", "created_after_task_finished",
    "updated_after_task_finished", "usage_status",
    "input", "output", "cache_read", "cache_write", "tokens", "cost", "list_cost",
    "billing", "turns", "compactions"]

# Columns whose empty value is written as "unknown": the figure exists but is
# not known (a session whose usage was never recorded, an uncounted compaction).
UNKNOWN_COLUMNS = frozenset(
    ["total_" + k for k in _KINDS5] + ["total_cost", "total_list_cost"]
    + ["top_" + k for k in _KINDS5] + ["top_cost", "top_list_cost", "top_compactions"]
    + ["sub_" + k for k in _KINDS5] + ["sub_cost", "sub_list_cost", "sub_compactions"]
    + ["input", "output", "cache_read", "cache_write", "tokens", "cost", "list_cost", "compactions"])


class InputError(Exception):
    """An input file is missing or does not have the columns this script needs."""


# --------------------------------------------------------------------------
# Reading the CSVs

def to_float(text):
    """A finite float, or None for blank, "unknown" or unparseable text."""
    if text is None:
        return None
    text = str(text).strip()
    if not text:
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    return number if math.isfinite(number) else None


def to_int(text):
    number = to_float(text)
    return None if number is None else int(round(number))


def to_flag(text):
    """True for "true", False for "false", None for anything else (absent)."""
    text = (text or "").strip().lower()
    return True if text == "true" else False if text == "false" else None


def clean_id(text):
    """An id, or None when blank or not a plain token (a placeholder such as <other>)."""
    text = (text or "").strip()
    return text if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]*", text) else None


def read_table(path, required, label):
    """Return (rows, header) of the CSV at PATH, checking the REQUIRED columns."""
    if not path.is_file():
        raise InputError(f"{label}: {path} not found")
    try:
        with open(path, newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            header = reader.fieldnames or []
            missing = [c for c in required if c not in header]
            if missing:
                raise InputError(f"{label}: {path} lacks the column(s) {', '.join(missing)}")
            return list(reader), header
    except OSError as err:
        raise InputError(f"{label}: cannot read {path}: {err.strerror or err}") from err


class Usage:
    """A session's resolved usage: tokens, billed cost, list cost; or missing."""

    __slots__ = ("input", "output", "cache_read", "cache_write", "cost", "list_cost", "missing")

    @property
    def tokens(self):
        return self.input + self.output + self.cache_read + self.cache_write


def read_usage(row, quality):
    """Resolve a session row's usage from its own record and from the usage ledger.

    Per field the larger of the two is used (the ledger is higher for a few old
    sessions and never lower).  A blank list cost is the cost, as the harness
    itself reads it (harness-usage-list-cost).  A session that took model turns
    yet has no tokens and no cost anywhere is `missing`: its usage was never
    recorded, which is not the same as zero.
    """
    usage = Usage()
    differs = False
    for key in USAGE_FIELDS:
        record = to_float(row.get(key))
        ledger = to_float(row.get("ledger_" + key))
        if key == "list_cost" and record is None:
            record = to_float(row.get("cost"))
        have = [v for v in (record, ledger) if v is not None]
        value = max(have) if have else 0.0
        if (key != "list_cost" and record is not None and ledger is not None
                and abs(record - ledger) > 1e-9 * max(1.0, abs(record))):
            differs = True
        setattr(usage, key, int(round(value)) if key in TOKEN_FIELDS else float(value))
    if differs:
        quality["ledger_differs"] += 1
    turns = to_float(row.get("turns"))
    usage.missing = bool(turns and turns > 0 and usage.tokens == 0
                         and usage.cost == 0 and usage.list_cost == 0)
    return usage


class Session:
    __slots__ = ("id", "kind", "parent", "created", "updated", "model", "flag", "forked",
                 "billing", "usage", "turns", "compactions")


def load_sessions(rows, quality):
    sessions = {}
    for row in rows:
        sid = clean_id(row.get("id"))
        if sid is None:
            quality["session_rows_without_id"] += 1
            continue
        if sid in sessions:
            quality["duplicate_session_ids"] += 1
            continue
        s = Session()
        s.id = sid
        s.kind = (row.get("kind") or "").strip() or "main"
        s.parent = clean_id(row.get("parent_id"))
        s.created = to_float(row.get("created"))
        s.updated = to_float(row.get("updated"))
        s.model = (row.get("model") or "").strip()
        s.flag = to_flag(row.get("supervisor"))
        s.forked = to_flag(row.get("forked")) is True
        s.billing = (row.get("billing") or "").strip()
        s.usage = read_usage(row, quality)
        s.turns = to_int(row.get("turns"))
        s.compactions = to_int(row.get("compactions"))
        sessions[sid] = s
    return sessions


class Task:
    __slots__ = ("id", "session_id", "created", "started", "finished", "state", "outcome",
                 "model", "plan", "setting")


def load_tasks(rows):
    tasks, seen = [], set()
    for row in rows:
        tid = clean_id(row.get("id"))
        if tid is None:
            raise InputError("tasks.csv: a row has no usable id")
        if tid in seen:
            raise InputError(f"tasks.csv: duplicate task id {tid}")
        seen.add(tid)
        t = Task()
        t.id = tid
        t.session_id = clean_id(row.get("session"))
        t.created = to_float(row.get("created"))
        if t.created is None:
            raise InputError(f"tasks.csv: task {tid} has no created time")
        t.started = to_float(row.get("started"))
        t.finished = to_float(row.get("finished"))
        t.state = (row.get("state") or "").strip()
        t.outcome = (row.get("outcome") or "").strip()
        t.model = (row.get("model") or "").strip()
        t.plan = to_flag(row.get("plan")) is True
        t.setting = to_flag(row.get("supervisor"))
        tasks.append(t)
    return tasks


# --------------------------------------------------------------------------
# Classification and aggregation

def supervisor_flag(task, top):
    """The flag that governed the task: (True|False|None, "session"|"task"|"none").

    The task session's own flag decides.  The task's explicit setting is the
    fallback, for a session that carries none.
    """
    if top is not None and top.flag is not None:
        return top.flag, "session"
    if task.setting is not None:
        return task.setting, "task"
    return None, "none"


def classify(task, flag):
    """Return (group, reason) for TASK whose supervisor flag is FLAG."""
    if task.plan:
        return PLAN_MODE, "plan flag set"
    if flag is True:
        if task.created >= SUPERVISOR_FIX:
            return GROUP_A, "supervisor on, created at or after the fix"
        return EXCLUDED_BUGGY, "supervisor on, created before the fix"
    if flag is False:
        return GROUP_B, "supervisor off"
    return GROUP_B, "no supervisor flag"


def child_index(sessions):
    """parent id -> the sessions naming it as their parent, oldest first."""
    children = defaultdict(list)
    for s in sessions.values():
        if s.parent:
            children[s.parent].append(s)
    for kids in children.values():
        kids.sort(key=lambda s: (s.created if s.created is not None else 0.0, s.id))
    return children


def descendants(top_id, children):
    """Sessions descended from TOP_ID through parent ids, as (session, depth), nearest first."""
    seen = {top_id}
    found = []
    queue = deque([(top_id, 0)])
    while queue:
        current, depth = queue.popleft()
        for child in children.get(current, ()):
            if child.id in seen:
                continue
            seen.add(child.id)
            found.append((child, depth + 1))
            queue.append((child.id, depth + 1))
    return found


class Totals:
    """Usage summed over several sessions."""

    def __init__(self):
        self.input = self.output = self.cache_read = self.cache_write = 0
        self.cost = self.list_cost = 0.0
        self.sessions = self.missing = 0

    def add(self, usage):
        self.sessions += 1
        self.missing += 1 if usage.missing else 0
        self.input += usage.input
        self.output += usage.output
        self.cache_read += usage.cache_read
        self.cache_write += usage.cache_write
        self.cost += usage.cost
        self.list_cost += usage.list_cost

    @property
    def tokens(self):
        return self.input + self.output + self.cache_read + self.cache_write


def span(start, end):
    """Seconds from START to END, None when either is missing or END is earlier."""
    if start is None or end is None or end < start:
        return None
    return end - start


def totals_cells(prefix, totals, known):
    """The token and cost cells of TOTALS under PREFIX; None when not KNOWN."""
    cells = {f"{prefix}_{k}": (getattr(totals, k) if known else None) for k in TOKEN_FIELDS}
    cells[f"{prefix}_tokens"] = totals.tokens if known else None
    cells[f"{prefix}_cost"] = totals.cost if known else None
    cells[f"{prefix}_list_cost"] = totals.list_cost if known else None
    return cells


def analyse(tasks, sessions, quality):
    """Classify every task and total its usage.  Return (task rows, sub-agent rows)."""
    children = child_index(sessions)
    task_rows, sub_rows = [], []
    for task in sorted(tasks, key=lambda t: (t.created, t.id)):
        top = sessions.get(task.session_id) if task.session_id else None
        if top is None:
            quality["task_without_session"] += 1
        flag, flag_source = supervisor_flag(task, top)
        group, reason = classify(task, flag)
        if flag is True and task.created < SUPERVISOR_INTRODUCED:
            quality["flag_before_mode_existed"] += 1
        if task.plan and task.created < PLAN_MODE_INTRODUCED:
            quality["plan_before_plan_mode_existed"] += 1
        if top is not None and top.flag is not None and task.setting is not None and top.flag != task.setting:
            quality["setting_differs_from_flag"] += 1

        found = descendants(top.id, children) if top is not None else []
        workers = [(s, d) for s, d in found if s.kind in WORKER_KINDS]
        others = [s for s, _ in found if s.kind not in WORKER_KINDS]

        top_totals, sub_totals, all_totals = Totals(), Totals(), Totals()
        if top is not None:
            top_totals.add(top.usage)
            all_totals.add(top.usage)
        for s, _ in workers:
            sub_totals.add(s.usage)
            all_totals.add(s.usage)
        top_known = top is not None and not top.usage.missing
        sub_known = sub_totals.missing == 0
        complete = top_known and sub_known

        in_comparison = task.state == TERMINAL_STATE and group in (GROUP_A, GROUP_B)
        known_compactions = [s.compactions for s, _ in workers if s.compactions is not None]
        sub_compactions = sum(known_compactions) if len(known_compactions) == len(workers) else None
        billing = Counter()
        for s in ([top] if top is not None else []) + [s for s, _ in workers]:
            billing[s.billing if s.billing in BILLING_VALUES else ("other" if s.billing else "")] += 1
        after_finish = sum(1 for s, _ in workers
                           if task.finished is not None and s.created is not None and s.created > task.finished)

        row = {
            "task_id": task.id,
            "top_session_id": top.id if top is not None else None,
            "group": group,
            "group_reason": reason,
            "in_comparison": in_comparison,
            "state": task.state,
            "outcome": task.outcome,
            "supervisor_flag": {True: "on", False: "off", None: "absent"}[flag],
            "flag_source": flag_source,
            "plan_flag": task.plan,
            "model": top.model if top is not None else "",
            "created": task.created,
            "started": task.started,
            "finished": task.finished,
            "duration_s": span(task.created, task.finished),
            "work_duration_s": span(task.started, task.finished),
            "n_subagents": len(workers),
            "n_forked_subagents": sum(1 for s, _ in workers if s.forked),
            "n_other_descendants": len(others),
            "usage_status": "complete" if complete else "incomplete",
            "sessions_usage_missing": all_totals.missing + (0 if top is not None else 1),
            "recorded_tokens": all_totals.tokens,
            "recorded_cost": all_totals.cost,
            "recorded_list_cost": all_totals.list_cost,
            "top_duration_s": span(top.created, task.finished) if top is not None else None,
            "top_compactions": top.compactions if top is not None else None,
            "sub_compactions": sub_compactions,
            "sessions_api": billing["api"],
            "sessions_subscription": billing["subscription"],
            "sessions_extra_usage": billing["extra-usage"],
            "sessions_billing_none": billing[""],
            "sessions_billing_other": billing["other"],
            "workers_created_after_finish": after_finish,
            # kept for the statistics, never written to a CSV
            "_workers": workers,
            "_others": others,
            "_top": top,
            "_task": task,
        }
        row.update(totals_cells("total", all_totals, complete))
        row.update(totals_cells("top", top_totals, top_known))
        row.update(totals_cells("sub", sub_totals, sub_known))
        task_rows.append(row)

        for s, depth in workers:
            known = not s.usage.missing
            sub_rows.append({
                "task_id": task.id,
                "group": group,
                "in_comparison": in_comparison,
                "session_id": s.id,
                "parent_id": s.parent,
                "depth": depth,
                "kind": s.kind,
                "forked": s.forked,
                "model": s.model,
                "created": s.created,
                "updated": s.updated,
                "duration_s": span(s.created, s.updated),
                "created_after_task_finished": (task.finished is not None and s.created is not None
                                                and s.created > task.finished),
                "updated_after_task_finished": (task.finished is not None and s.updated is not None
                                                and s.updated > task.finished),
                "usage_status": "recorded" if known else "missing",
                "input": s.usage.input if known else None,
                "output": s.usage.output if known else None,
                "cache_read": s.usage.cache_read if known else None,
                "cache_write": s.usage.cache_write if known else None,
                "tokens": s.usage.tokens if known else None,
                "cost": s.usage.cost if known else None,
                "list_cost": s.usage.list_cost if known else None,
                "billing": s.billing,
                "turns": s.turns,
                "compactions": s.compactions,
            })
    return task_rows, sub_rows


# --------------------------------------------------------------------------
# CSV output

def csv_cell(column, value):
    if value is None:
        return UNKNOWN if column in UNKNOWN_COLUMNS else ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return repr(value)
    return str(value)


@contextlib.contextmanager
def private_umask():
    old = os.umask(0o077)
    try:
        yield
    finally:
        os.umask(old)


def write_csv(path, columns, rows):
    """Write ROWS (dicts) to PATH atomically and owner-only: the files hold ids."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    try:
        with private_umask():
            with open(tmp, "w", newline="", encoding="utf-8") as handle:
                writer = csv.writer(handle, lineterminator="\n")
                writer.writerow(columns)
                for row in rows:
                    writer.writerow([csv_cell(c, row.get(c)) for c in columns])
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


def write_text(path, text):
    """Write the report atomically (it is committed, so with the ordinary umask)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


# --------------------------------------------------------------------------
# Statistics

def describe(values):
    """n, mean, median, sample stdev and sum of the non-None VALUES."""
    vals = [v for v in values if v is not None]
    n = len(vals)
    if not n:
        return {"n": 0, "mean": None, "median": None, "stdev": None, "sum": None}
    return {
        "n": n,
        "mean": statistics.fmean(vals),
        "median": statistics.median(vals),
        "stdev": statistics.stdev(vals) if n >= 2 else None,
        "sum": math.fsum(vals),
    }


def ratio(a, b):
    """A / B, None when either is missing or B is zero."""
    if a is None or b is None or b == 0:
        return None
    return a / b


def column(rows, key):
    return [r[key] for r in rows]


# The per-task statistics of the report: (label, row key, subset, kind).
# subset "all" is every done task of the group, "complete" the done tasks
# whose usage is complete; kind picks the number format.
TASK_METRICS = [
    ("Total tokens", "total_tokens", "complete", "tokens"),
    ("Input tokens", "total_input", "complete", "tokens"),
    ("Output tokens", "total_output", "complete", "tokens"),
    ("Cache-read tokens", "total_cache_read", "complete", "tokens"),
    ("Cache-write tokens", "total_cache_write", "complete", "tokens"),
    ("Billed cost", "total_cost", "complete", "usd"),
    ("List cost", "total_list_cost", "complete", "usd"),
    ("Task duration, created to finished", "duration_s", "all", "dur"),
    ("Task duration, started to finished", "work_duration_s", "all", "dur"),
    ("Sub-agents", "n_subagents", "all", "count"),
]
TOP_METRICS = [
    ("Total tokens", "top_tokens", "complete", "tokens"),
    ("Billed cost", "top_cost", "complete", "usd"),
    ("List cost", "top_list_cost", "complete", "usd"),
    ("Duration, session created to task finished", "top_duration_s", "all", "dur"),
    ("Compactions", "top_compactions", "all", "count"),
]
SUB_COMBINED_METRICS = [
    ("Total tokens", "sub_tokens", "complete", "tokens"),
    ("Billed cost", "sub_cost", "complete", "usd"),
    ("List cost", "sub_list_cost", "complete", "usd"),
    ("Compactions", "sub_compactions", "all", "count"),
]
SESSION_METRICS = [
    ("Total tokens", "tokens", "tokens"),
    ("Billed cost", "cost", "usd"),
    ("List cost", "list_cost", "usd"),
    ("Duration, updated minus created (upper bound)", "duration_s", "dur"),
    ("Compactions", "compactions", "count"),
]


def group_metrics(rows, specs):
    """{key: describe(values)} over the done tasks in ROWS, each metric over its own subset."""
    out = {}
    for _, key, subset, _ in specs:
        chosen = [r for r in rows if subset == "all" or r["usage_status"] == "complete"]
        out[key] = describe(column(chosen, key))
    return out


def compare_groups(task_rows):
    """Group counts, and statistics for groups A and B, from the classified task rows."""
    result = {"groups": {}}
    for g in GROUPS:
        members = [r for r in task_rows if r["group"] == g]
        done = [r for r in members if r["state"] == TERMINAL_STATE]
        complete = [r for r in done if r["usage_status"] == "complete"]
        states = Counter(r["state"] or "(none)" for r in members if r["state"] != TERMINAL_STATE)
        result["groups"][g] = {
            "tasks": len(members),
            "done": done,
            "n_done": len(done),
            "n_complete": len(complete),
            "n_incomplete": len(done) - len(complete),
            "in_flight": sum(states.values()),
            "in_flight_states": states,
            "total_cost": math.fsum(r["recorded_cost"] for r in done),
            "total_list_cost": math.fsum(r["recorded_list_cost"] for r in done),
            "total_cost_complete": math.fsum(r["total_cost"] for r in complete),
            "total_list_cost_complete": math.fsum(r["total_list_cost"] for r in complete),
        }
    for g in (GROUP_A, GROUP_B):
        info = result["groups"][g]
        done = info["done"]
        info["task"] = group_metrics(done, TASK_METRICS)
        info["top"] = group_metrics(done, TOP_METRICS)
        info["sub"] = group_metrics(done, SUB_COMBINED_METRICS)
        info["zero_subagents"] = sum(1 for r in done if r["n_subagents"] == 0)
        info["top_compactions_unknown"] = sum(1 for r in done if r["top_compactions"] is None)
        info["billing"] = Counter()
        for r in done:
            for key, label in (("sessions_api", "api"), ("sessions_subscription", "subscription"),
                               ("sessions_extra_usage", "extra-usage"),
                               ("sessions_billing_none", "not recorded"),
                               ("sessions_billing_other", "other")):
                info["billing"][label] += r[key]
        info["models"] = Counter(r["model"] or "(none)" for r in done)
        info["created_min"] = min((r["created"] for r in done), default=None)
        info["created_max"] = max((r["created"] for r in done), default=None)
        workers = [w for r in done for w, _ in r["_workers"]]
        info["n_workers"] = len(workers)
        info["workers_forked"] = sum(1 for w in workers if w.forked)
        info["workers_after_finish"] = sum(r["workers_created_after_finish"] for r in done)
        info["other_sessions"] = sum(r["n_other_descendants"] for r in done)
        info["other_list_cost"] = math.fsum(o.usage.list_cost for r in done for o in r["_others"])
    return result


def add_session_stats(result, sub_rows):
    """Add the statistics over sub-agent sessions (rows of done A and B tasks) to RESULT."""
    for g in (GROUP_A, GROUP_B):
        rows = [r for r in sub_rows if r["group"] == g and r["in_comparison"]]
        result["groups"][g]["session_rows"] = rows
        result["groups"][g]["sessions"] = {key: describe(column(rows, key)) for _, key, _ in SESSION_METRICS}


def strata_of_b(result):
    """Descriptive subsets of group B, for context (not a controlled comparison)."""
    done = result["groups"][GROUP_B]["done"]

    def line(key, label, rows):
        complete = [r for r in rows if r["usage_status"] == "complete"]
        cost = describe(column(complete, "total_list_cost"))
        return {"key": key, "label": label, "n": len(rows), "n_complete": len(complete),
                "mean": cost["mean"], "median": cost["median"],
                "duration_median": describe(column(rows, "duration_s"))["median"]}

    strata = [
        line("all", "all of B", done),
        line("before", "created before supervisor mode existed",
             [r for r in done if r["created"] < SUPERVISOR_INTRODUCED]),
        line("since", "created since", [r for r in done if r["created"] >= SUPERVISOR_INTRODUCED]),
        line("fix", "created since the fix (group A's period)", [r for r in done if r["created"] >= SUPERVISOR_FIX]),
        line("zero", "0 sub-agents", [r for r in done if r["n_subagents"] == 0]),
        line("few", "1 to 4 sub-agents", [r for r in done if 1 <= r["n_subagents"] <= 4]),
        line("many", "5 or more sub-agents", [r for r in done if r["n_subagents"] >= 5]),
    ]
    a_models = sorted({r["model"] for r in result["groups"][GROUP_A]["done"] if r["model"]})
    if a_models:
        strata.append(line("a_model", "own session on " + " or ".join(a_models) + " (the model group A used)",
                           [r for r in done if r["model"] in a_models]))
    return strata


def started_variant(task_rows):
    """What group A would hold if the fix cutoff were applied to the task's start time.

    Returns (moved, variant): the done tasks the creation-time rule calls
    excluded-buggy that started at or after the fix, and the done group-A
    tasks plus those.
    """
    moved = [r for r in task_rows
             if r["group"] == EXCLUDED_BUGGY and r["state"] == TERMINAL_STATE
             and r["_task"].started is not None and r["_task"].started >= SUPERVISOR_FIX]
    a_now = [r for r in task_rows if r["group"] == GROUP_A and r["state"] == TERMINAL_STATE]
    return moved, a_now + moved


# --------------------------------------------------------------------------
# Formatting

NA = "n/a"


def f_tokens(x):
    return NA if x is None else f"{x:,.0f}"


def f_usd(x):
    if x is None:
        return NA
    ax = abs(x)
    if ax == 0 or ax >= 1:
        return f"${x:,.2f}"
    if ax >= 0.01:
        return f"${x:,.3f}"
    return f"${x:,.4f}"


def f_dur(x):
    """Seconds as H:MM:SS (hours not capped)."""
    if x is None:
        return NA
    whole = int(round(x))
    hours, rest = divmod(whole, 3600)
    minutes, seconds = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{seconds:02d}"


def f_count(x):
    """A count, or a median of counts: no decimals when it is whole."""
    if x is None:
        return NA
    return f"{x:,.0f}" if float(x).is_integer() else f"{x:,.2f}"


def f_mean_count(x):
    return NA if x is None else f"{x:,.2f}"


def f_ratio(x):
    return NA if x is None else f"{x:.2f}x"


def f_when(epoch):
    """An epoch instant as UTC text."""
    if epoch is None:
        return NA
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def f_day(epoch):
    if epoch is None:
        return NA
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%d")


def f_range(first, last):
    """Two epoch instants as a UTC date range ("2026-10-01 to 2026-10-11", or one date)."""
    lo, hi = f_day(first), f_day(last)
    return lo if lo == hi else f"{lo} to {hi}"


FORMATS = {"tokens": f_tokens, "usd": f_usd, "dur": f_dur, "count": f_count}


def fmt(kind, value, mean=False):
    """VALUE as text for KIND; MEAN picks two decimals for a count that is a mean."""
    if kind == "count" and mean:
        return f_mean_count(value)
    return FORMATS[kind](value)


def md_table(headers, rows, aligns=None):
    aligns = aligns or ["l"] + ["r"] * (len(headers) - 1)
    sep = ["---:" if a == "r" else ":---" for a in aligns]
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(sep) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(str(c) for c in row) + " |")
    return lines


def plural(n, one, many=None):
    return f"{n} {one if n == 1 else (many or one + 's')}"


# --------------------------------------------------------------------------
# The report

GENERATED_MARK = "<!-- generated by scripts/analysis/compare_supervisor_modes.py; do not edit by hand -->"
REPRODUCE = (
    "python3 -I scripts/analysis/extract_usage_data.py --gather-tasks   # task store -> raw/tasks_raw.jsonl",
    "python3 -I scripts/analysis/extract_usage_data.py --print-gather-recipe",
    "#   ^ the Elisp an agent runs in the live harness to make raw/sessions_raw.jsonl",
    "python3 -I scripts/analysis/extract_usage_data.py                  # raw/ -> tasks.csv, sessions.csv",
    "python3 -I scripts/analysis/compare_supervisor_modes.py            # CSVs -> classified_tasks.csv, subagents.csv, this file",
)

PRIVATE_PATTERNS = (
    re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"),   # a session id
    re.compile(r"\bt-[0-9a-z]{8}\b"),                                                   # a task id
    re.compile(r"/home/|/Users/|\.worktrees|\.git/harness"),                            # a path
)


class Context:
    """Everything the report needs."""

    def __init__(self, task_rows, sub_rows, sessions, result, quality, n_task_rows, n_session_rows):
        self.task_rows = task_rows
        self.sub_rows = sub_rows
        self.sessions = sessions
        self.result = result
        self.quality = quality
        self.n_task_rows = n_task_rows
        self.n_session_rows = n_session_rows
        self.groups = result["groups"]
        self.a = result["groups"][GROUP_A]
        self.b = result["groups"][GROUP_B]
        self.snapshot = max((s.updated for s in sessions.values() if s.updated is not None), default=None)
        self.strata = strata_of_b(result)
        self.moved, self.a_variant = started_variant(task_rows)


def stat_cells(d, kind):
    return [str(d["n"]), fmt(kind, d["mean"], mean=True), fmt(kind, d["median"]),
            fmt(kind, d["stdev"], mean=True)]


def figure_line(label, key, kind, ta, tb, with_ratios=True):
    """One bullet of the bottom line: the A and B figure for KEY, with each n."""
    da, db = ta[key], tb[key]
    b_text = f"B mean {fmt(kind, db['mean'], mean=True)}, median {fmt(kind, db['median'])} (n={db['n']})"
    if da["n"] == 0:
        return f"- **{label}.** No A task has this figure. {b_text}."
    if da["n"] <= 2:
        a_text = f"A {fmt(kind, da['mean'], mean=True)} (n={da['n']})"
    else:
        a_text = f"A mean {fmt(kind, da['mean'], mean=True)}, median {fmt(kind, da['median'])} (n={da['n']})"
    text = f"- **{label}.** {a_text}; {b_text}."
    if with_ratios:
        text += (f" A is {f_ratio(ratio(da['mean'], db['mean']))} B's mean and "
                 f"{f_ratio(ratio(da['median'], db['median']))} B's median.")
    return text


def bottom_line(ctx):
    a, b = ctx.a, ctx.b
    n_a, n_b = a["n_done"], b["n_done"]
    out = ["## Bottom line", ""]
    if n_a == 0:
        return out + [f"No task has been done under fixed supervisor mode, so there is nothing to compare: "
                      f"group A has n = 0 done tasks against n = {n_b} for group B (single-session).", ""]
    small = n_a < SMALL_N
    out += [f"**{'The data cannot answer the question yet.' if small else 'Result.'}** "
            f"Group A (fixed supervisor mode) has n = {n_a} done tasks, {a['n_complete']} of them with a complete "
            f"usage record; group B (single-session) has n = {n_b}, {b['n_complete']} with a complete usage record.", ""]
    if small:
        hours = None if ctx.snapshot is None else (ctx.snapshot - SUPERVISOR_FIX) / 3600
        age = "" if hours is None else \
            f" The fix landed about {hours:.0f} hours before the newest record in the data was written."
        out += [f"Caveat: group A has only n = {n_a} done tasks, and this report calls any group under {SMALL_N} "
                f"small. Its figures describe those tasks one by one; they estimate nothing about supervisor mode "
                f"in general.{age}", ""]
    out += ["What the numbers show, A against B, with each group's n beside the figure"
            + (" (with two values the mean and the median are the same number, so A's is given once):"
               if n_a == 2 else ":"), ""]
    ta, tb = a["task"], b["task"]
    out.append(figure_line("List cost per task (cost at API list prices)", "total_list_cost", "usd", ta, tb))
    out.append(figure_line("Billed cost per task", "total_cost", "usd", ta, tb, with_ratios=False)
               + " What was actually charged depends on how each call was paid for (a subscription charges nothing "
                 "per call), so billed cost is not a like-for-like measure.")
    out.append(figure_line("Tokens per task", "total_tokens", "tokens", ta, tb))
    out.append(figure_line("Wall-clock time, created to finished", "duration_s", "dur", ta, tb))
    out.append(figure_line("Wall-clock time, started to finished", "work_duration_s", "dur", ta, tb))
    out.append(figure_line("Sub-agents per task", "n_subagents", "count", ta, tb, with_ratios=False)
               + f" {a['zero_subagents']} of {n_a} A tasks and {b['zero_subagents']} of {n_b} B tasks had none.")
    for r in a["done"]:
        if r["usage_status"] == "incomplete" and len(a["done"]) <= LIST_TASKS_UP_TO:
            k = r["sessions_usage_missing"]
            out.append(f"- An A task with incomplete usage: {k} of its {r['n_subagents'] + 1} sessions (its own and "
                       f"its sub-agents') {'has' if k == 1 else 'have'} no usage record. The usage recorded for the rest "
                       f"is {f_usd(r['recorded_list_cost'])} at list price and {f_tokens(r['recorded_tokens'])} tokens, "
                       "a lower bound for that task. It is left out of the cost and token figures above.")
    out.append("")
    out += ["Why these figures are not a like-for-like comparison:", ""]
    why = []
    if a["n_incomplete"] or b["n_incomplete"]:
        why.append(f"- Usage was never recorded for some sessions: {a['n_incomplete']} of {n_a} A tasks and "
                   f"{b['n_incomplete']} of {n_b} B tasks have no complete cost or token figure and are left out of "
                   "the cost and token statistics (they are not counted as zero). Duration and sub-agent figures "
                   "use every done task.")
    before = next((x for x in ctx.strata if x["key"] == "before"), None)
    since = next((x for x in ctx.strata if x["key"] == "since"), None)
    if before and since and before["median"] is not None and since["median"] is not None:
        why.append(f"- B is not one population. Its list cost per task has median {f_usd(before['median'])} "
                   f"(n={before['n_complete']}) for tasks created before supervisor mode existed and "
                   f"{f_usd(since['median'])} (n={since['n_complete']}) for those created since; the models differ "
                   "too (see \"Who ran these tasks\").")
    since_fix = next((x for x in ctx.strata if x["key"] == "fix"), None)
    many = next((x for x in ctx.strata if x["key"] == "many"), None)
    same_model = next((x for x in ctx.strata if x["key"] == "a_model"), None)
    if since_fix and since_fix["n"] == 0:
        why.append(f"- No done B task was created since the fix, so A has no single-session tasks from its own "
                   f"period to be set against (the {tb['n_subagents']['n']} done B tasks were created "
                   f"{f_range(b['created_min'], b['created_max'])} UTC, A's on "
                   f"{f_range(a['created_min'], a['created_max'])}).")
    if many and many["median"] is not None and ta["n_subagents"]["mean"] is not None:
        why.append(f"- Supervisor mode delegates, so A tasks have more sub-agents (mean "
                   f"{f_mean_count(ta['n_subagents']['mean'])}, n={ta['n_subagents']['n']}) than B tasks (mean "
                   f"{f_mean_count(tb['n_subagents']['mean'])}, n={tb['n_subagents']['n']}). The B tasks with 5 or "
                   f"more sub-agents had a list cost "
                   f"per task of median {f_usd(many['median'])}, mean {f_usd(many['mean'])} "
                   f"(n={many['n_complete']} with complete usage, of {many['n']}).")
    if same_model and same_model["median"] is not None:
        why.append(f"- Cost depends on the model. B tasks whose own session ran on the model A used had a list cost "
                   f"per task of mean {f_usd(same_model['mean'])}, median {f_usd(same_model['median'])} "
                   f"(n={same_model['n_complete']} with complete usage, of {same_model['n']}).")
    why.append("- Which tasks got supervisor mode was not random: a setting or a model's reading of the first "
               "message chose it for each. Nothing here separates the effect of the mode from the kind of task it "
               "was used on, the model, or how the calls were paid for.")
    return out + why + [""]


def counts_section(ctx):
    out = ["## Counts", ""]
    rows = []
    for g in GROUPS:
        i = ctx.groups[g]
        states = ", ".join(f"{k} {v}" for k, v in sorted(i["in_flight_states"].items()))
        rows.append([GROUP_TITLES[g], i["tasks"], i["n_done"], i["n_complete"], i["n_incomplete"],
                     f"{i['in_flight']} ({states})" if i["in_flight"] else "0"])
    rows.append(["**All tasks**", len(ctx.task_rows), sum(ctx.groups[g]["n_done"] for g in GROUPS),
                 sum(ctx.groups[g]["n_complete"] for g in GROUPS),
                 sum(ctx.groups[g]["n_incomplete"] for g in GROUPS),
                 sum(ctx.groups[g]["in_flight"] for g in GROUPS)])
    out += md_table(["Group", "Tasks", "Done", "Done, usage complete", "Done, usage incomplete",
                     "Not done: in flight, left out"], rows)
    out += ["",
            "Only done tasks enter a statistic. A done task has *complete* usage when its own session and every "
            "sub-agent session has a usage record (see Measures); an *incomplete* one is left out of the token and "
            "cost statistics and kept in the duration and sub-agent statistics. "
            f"The input held {ctx.n_task_rows} tasks and {ctx.n_session_rows} sessions.", ""]
    return out


def results_section(ctx):
    a, b = ctx.a, ctx.b
    out = ["## Results: done tasks, A against B", "",
           f"Group A: fixed supervisor mode, n = {a['n_done']} done tasks. Group B: single-session (the old way), "
           f"n = {b['n_done']}. Each row shows its own n: the token and cost rows use the tasks with complete "
           "usage, the duration, sub-agent and compaction rows every done task. `n/a` means not defined (a "
           "standard deviation needs two values).", ""]
    headers = ["", "A n", "A mean", "A median", "A stdev", "B n", "B mean", "B median", "B stdev"]

    def block(title, specs, a_stats, b_stats):
        rows = [[label] + stat_cells(a_stats[key], kind) + stat_cells(b_stats[key], kind)
                for label, key, _, kind in specs]
        return [f"### {title}", ""] + md_table([title.split(" (")[0].split(" alone")[0]] + headers[1:], rows) + [""]

    out += block("Per task (own session plus all sub-agents)", TASK_METRICS, a["task"], b["task"])
    out += block("The top-level session alone", TOP_METRICS, a["top"], b["top"])
    out += block("All sub-agents of a task combined", SUB_COMBINED_METRICS, a["sub"], b["sub"])
    rows = [
        ["Tasks with exactly 0 sub-agents", f"{a['zero_subagents']} of {a['n_done']}",
         f"{b['zero_subagents']} of {b['n_done']}"],
        ["Top-level compaction count unknown", f"{a['top_compactions_unknown']} of {a['n_done']}",
         f"{b['top_compactions_unknown']} of {b['n_done']}"],
        ["Grand sum of billed cost, tasks with complete usage", f_usd(a["total_cost_complete"]) + f" (n={a['n_complete']})",
         f_usd(b["total_cost_complete"]) + f" (n={b['n_complete']})"],
        ["Grand sum of list cost, tasks with complete usage", f_usd(a["total_list_cost_complete"]) + f" (n={a['n_complete']})",
         f_usd(b["total_list_cost_complete"]) + f" (n={b['n_complete']})"],
        ["Recorded billed cost, all done tasks (a lower bound)", f_usd(a["total_cost"]) + f" (n={a['n_done']})",
         f_usd(b["total_cost"]) + f" (n={b['n_done']})"],
        ["Recorded list cost, all done tasks (a lower bound)", f_usd(a["total_list_cost"]) + f" (n={a['n_done']})",
         f_usd(b["total_list_cost"]) + f" (n={b['n_done']})"],
    ]
    out += ["### Counts and sums", ""] + md_table(["", "A", "B"], rows) + [""]
    billing_rows = [[label, a["billing"][label], b["billing"][label]]
                    for label in ("subscription", "api", "extra-usage", "not recorded", "other")]
    out += ["### Sessions by how they were billed", "",
            "Sessions (a task's own session plus its sub-agents) of the done tasks, by the billing mode of the "
            "session record. A `subscription` session is charged nothing per call, an `api` session its list cost; "
            "\"not recorded\" is a session with no billing mode.", ""]
    out += md_table(["Billing", "A sessions", "B sessions"], billing_rows) + [""]
    return out


def a_tasks_section(ctx):
    """Group A task by task, when there are few enough to list."""
    done = ctx.a["done"]
    if not 0 < len(done) <= LIST_TASKS_UP_TO:
        return []
    out = ["### Group A, task by task", "",
           "Every done A task, oldest first (no ids). `at least` marks a total built from the usage that was "
           "recorded when some session's was not.", ""]
    rows = []
    for k, r in enumerate(done, 1):
        complete = r["usage_status"] == "complete"
        lead = "" if complete else "at least "
        rows.append([k, f_when(r["created"]), r["model"] or "-", r["n_subagents"],
                     "complete" if complete else f"incomplete ({r['sessions_usage_missing']} session without usage)",
                     lead + f_tokens(r["recorded_tokens"]), lead + f_usd(r["recorded_list_cost"]),
                     f_usd(r["recorded_cost"]), f_dur(r["duration_s"]), f_dur(r["work_duration_s"])])
    out += md_table(["A task", "Created (UTC)", "Model", "Sub-agents", "Usage", "Tokens", "List cost",
                     "Billed cost", "Created to finished", "Started to finished"], rows,
                    ["r", "l", "l", "r", "l", "r", "r", "r", "r", "r"])
    out.append("")
    return out


def comparison_section(ctx):
    a, b = ctx.a["task"], ctx.b["task"]
    out = ["## Comparison: A against B", "",
           "Ratio is A divided by B. When a group is this small the ratio sets one or two tasks against a "
           "population; it is shown because the question asks for it, not as an estimate.", ""]
    rows = []
    for label, key, kind in (("Billed cost", "total_cost", "usd"), ("List cost", "total_list_cost", "usd"),
                             ("Total tokens", "total_tokens", "tokens"),
                             ("Duration, created to finished", "duration_s", "dur"),
                             ("Duration, started to finished", "work_duration_s", "dur")):
        da, db = a[key], b[key]
        rows.append([label, fmt(kind, da["mean"]), fmt(kind, db["mean"]), f_ratio(ratio(da["mean"], db["mean"])),
                     fmt(kind, da["median"]), fmt(kind, db["median"]),
                     f_ratio(ratio(da["median"], db["median"])), f"{da['n']} / {db['n']}"])
    out += md_table(["Per task", "A mean", "B mean", "A/B", "A median", "B median", "A/B", "n (A / B)"], rows)
    out += ["", "Billed cost is 0 for usage a subscription paid for, so its ratio compares how calls were paid for, "
                "not how much was used; list cost is the like-for-like dollar figure.", ""]
    return out


def sessions_section(ctx):
    a, b = ctx.a, ctx.b
    out = ["## Sub-agent sessions", "",
           f"One observation per sub-agent session of a done task (n counts sessions, not tasks): "
           f"{a['n_workers']} in group A, {b['n_workers']} in group B. {a['workers_forked']} of A's and "
           f"{b['workers_forked']} of B's started as a fork of their parent's conversation. The duration is the "
           "session record's `updated` minus `created`, an upper bound on its working time: `updated` also "
           "moves when the harness closes or reloads sessions (see Measures).", ""]
    rows = []
    for label, key, kind in SESSION_METRICS:
        da, db = a["sessions"][key], b["sessions"][key]
        rows.append([label, da["n"], fmt(kind, da["mean"], mean=True), fmt(kind, da["median"]),
                     db["n"], fmt(kind, db["mean"], mean=True), fmt(kind, db["median"])])
    out += md_table(["Per sub-agent session", "A n", "A mean", "A median", "B n", "B mean", "B median"], rows)
    out.append("")
    return out


def mix_section(ctx):
    out = ["## Who ran these tasks", "",
           "The two groups differ in model, period and billing, which move cost and tokens whatever the mode. "
           "A model is the one recorded on the session when it was read.", ""]
    rows = []
    for g in (GROUP_A, GROUP_B):
        i = ctx.groups[g]
        models = ", ".join(f"{k} {v}" for k, v in sorted(i["models"].items(), key=lambda kv: (-kv[1], kv[0])))
        sub_models = Counter(r["model"] or "(none)" for r in i["session_rows"])
        sub_text = ", ".join(f"{k} {v}" for k, v in sorted(sub_models.items(), key=lambda kv: (-kv[1], kv[0])))
        rows.append([GROUP_TITLES[g], i["n_done"], f_range(i["created_min"], i["created_max"]),
                     models or "-", sub_text or "-"])
    out += md_table(["Group", "Done tasks", "Created (UTC)", "Model of the task's own session",
                     "Model of the sub-agent sessions"], rows, ["l", "r", "l", "l", "l"])
    out += ["",
            "Group B cut by period and by number of sub-agents (descriptive subsets, not a controlled comparison). "
            "List cost is per task over the tasks with complete usage.", ""]
    rows = [[s["label"], s["n"], s["n_complete"], f_usd(s["mean"]), f_usd(s["median"]), f_dur(s["duration_median"])]
            for s in ctx.strata]
    out += md_table(["Group B subset", "Done tasks", "Usage complete", "List cost mean", "List cost median",
                     "Median duration, created to finished"], rows)
    out.append("")
    return out


def excluded_section(ctx):
    i = ctx.groups[EXCLUDED_BUGGY]
    complete = [r for r in i["done"] if r["usage_status"] == "complete"]
    cost = describe(column(complete, "total_cost"))
    list_cost = describe(column(complete, "total_list_cost"))
    out = ["## Excluded: old buggy supervisor mode", "",
           "Tasks with the supervisor flag on that were created before the fix. Kept out of A and B; shown as a "
           "sanity check against the cache and cost incident already known about.", ""]
    rows = [
        ["Tasks (all states)", i["tasks"]],
        ["Done", i["n_done"]],
        ["Done with complete usage", i["n_complete"]],
        ["Billed cost, all done tasks (recorded; a lower bound)", f_usd(i["total_cost"])],
        ["List cost, all done tasks (recorded; a lower bound)", f_usd(i["total_list_cost"])],
        ["Billed cost, tasks with complete usage", f"{f_usd(cost['sum'])} (n={cost['n']})"],
        ["List cost, tasks with complete usage", f"{f_usd(list_cost['sum'])} (n={list_cost['n']})"],
        ["List cost per task, tasks with complete usage: mean / median",
         f"{f_usd(list_cost['mean'])} / {f_usd(list_cost['median'])} (n={list_cost['n']})"],
    ]
    out += md_table(["Excluded group", "Value"], rows, ["l", "r"]) + [""]
    return out


def plan_section(ctx):
    i = ctx.groups[PLAN_MODE]
    out = ["## Set aside: Plan mode", "",
           f"n = {i['tasks']} tasks carry the Plan-mode flag ({i['n_done']} done).", ""]
    if i["tasks"] == 0:
        out += [f"The `plan` column is empty for all {len(ctx.task_rows)} tasks of the input, so nothing is set "
                "aside. A task with the flag would be counted here and kept out of A and B; the self-test "
                "exercises that rule.", ""]
    return out


def in_flight_section(ctx):
    out = ["## Not done: in flight, left out", ""]
    rows = []
    for g in GROUPS:
        for state, n in sorted(ctx.groups[g]["in_flight_states"].items()):
            rows.append([GROUP_TITLES[g], state, n])
    if not rows:
        return out + ["Every task is done.", ""]
    out += md_table(["Group", "State", "Tasks"], rows, ["l", "l", "r"])
    out += ["",
            "A task that is not `done` has incomplete totals, so it is in no statistic. `pending` also covers "
            "backlog tasks that were written up and have not started, and `review` a task whose agent finished "
            "and which waits for the user to verify it.", ""]
    return out


def quality_section(ctx):
    q, a, b = ctx.quality, ctx.a, ctx.b
    out = ["## Data quality, limits and a sensitivity check", ""]
    items = []
    sessions = list(ctx.sessions.values())
    missing = [s for s in sessions if s.usage.missing]
    if missing:
        by_kind = Counter(s.kind for s in missing)
        kinds = ", ".join(f"{v} of kind {k}" for k, v in sorted(by_kind.items()))
        by_model = Counter(r["model"] or "(none)" for r in ctx.task_rows
                           if r["state"] == TERMINAL_STATE and r["group"] in (GROUP_A, GROUP_B)
                           and r["usage_status"] == "incomplete")
        models = ", ".join(f"{k} {v}" for k, v in sorted(by_model.items(), key=lambda kv: (-kv[1], kv[0])))
        items.append(f"**Usage never recorded.** {len(missing)} of the {len(sessions)} sessions took model turns "
                     f"but have no tokens and no cost in the session record or the usage ledger ({kinds}). Their "
                     "tasks are *incomplete*: not counted as zero, left out of the token and cost statistics. "
                     f"Among the done A and B tasks the incomplete ones are {a['n_incomplete']} of {a['n_done']} (A) "
                     f"and {b['n_incomplete']} of {b['n_done']} (B), by the model of their own session: "
                     f"{models or '-'}. The cost and token figures therefore come from the tasks whose usage was "
                     "recorded and may not represent the others.")
    n = q.get("ledger_differs", 0)
    if n:
        items.append(f"**Ledger and record disagree.** For {n} older sessions the usage ledger holds more than the "
                     "session record. The larger figure is used; the ledger was never the lower one.")
    flagged = [r["_task"] for r in ctx.task_rows
               if r["supervisor_flag"] == "on" and r["created"] < SUPERVISOR_INTRODUCED]
    if flagged:
        across = all(t.started is not None and t.finished is not None
                     and t.started < SUPERVISOR_INTRODUCED <= t.finished for t in flagged)
        items.append(f"**Flag before the mode existed.** {plural(len(flagged), 'task')} carries the supervisor flag "
                     "on although it was created before supervisor mode existed"
                     + (" (it ran from before the mode was introduced until after)" if across else "")
                     + ". It is classified by its flag, so it sits in the excluded group, not in B.")
    n = q.get("setting_differs_from_flag", 0)
    if n:
        items.append(f"**Setting and flag differ.** {plural(n, 'task')} was submitted with an explicit supervisor "
                     "setting that its session's flag contradicts. The session's flag is the one used.")
    sources = Counter(r["flag_source"] for r in ctx.task_rows)
    items.append("**Where the flag came from.** The task's session for "
                 f"{sources['session']} tasks, the task's own setting for {sources['task']} (the session had none), "
                 f"neither for {sources['none']} (counted as off).")
    n = q.get("task_without_session", 0)
    if n:
        items.append(f"**Session record missing.** {plural(n, 'task')} has no session record; it has no sub-agents "
                     "and incomplete usage.")
    items.append(f"**Work after the task finished.** A session's totals cover everything it did, including turns "
                 f"after the task's `finished` instant. {a['workers_after_finish']} of A's {a['n_workers']} and "
                 f"{b['workers_after_finish']} of B's {b['n_workers']} sub-agents were created after their task "
                 "finished; they are counted in the task they descend from.")
    items.append(f"**Side conversations and internal sessions.** {a['other_sessions'] + b['other_sessions']} sessions "
                 "of kind `btw` or `internal` descend from the done A and B tasks (list cost "
                 f"{f_usd(a['other_list_cost'] + b['other_list_cost'])}). They are not sub-agents and are in no total. "
                 "The harness prunes `internal` sessions over time, so they are not comparable between tasks.")
    late_a = sum(1 for r in a["session_rows"] if r["updated_after_task_finished"])
    late_b = sum(1 for r in b["session_rows"] if r["updated_after_task_finished"])
    items.append("**Duration of a sub-agent.** A session record has no end time, and its `updated` also moves when "
                 "the harness closes or reloads sessions, so `updated` minus `created` is an upper bound on the "
                 f"working time. {late_a} of A's {a['n_workers']} and {late_b} of B's {b['n_workers']} sub-agent "
                 "records were written after their task finished.")
    items.append("**Scope.** Only this project's tasks are in the data. Other projects keep their task stores in "
                 "their own repositories, and reaching them needs a directory grant that only an interactive "
                 "session can be given; the session that gathered this data could not, so tasks from other "
                 "projects are in neither group.")
    items.append(f"**Snapshot.** The newest session record in the input was written {f_when(ctx.snapshot)}. "
                 "Anything after that is not here, and tasks still running then are in flight.")
    out += [f"- {x}" for x in items] + [""]

    moved, variant = ctx.moved, ctx.a_variant
    out += ["### Sensitivity: the fix cutoff applied to the start time", "",
            "A task written up for the backlog is *created* when it is written up and *started* later, possibly days "
            "later, and its supervisor flag is set when it starts. The rule above uses the creation time, as "
            "specified. Applying the fix cutoff to the start time instead would move "
            f"{plural(len(moved), 'done task')} from the excluded group to A, making n(A) = {len(variant)}.", ""]
    if moved:
        rows = []
        for label, rs in (("A by creation time (the rule above)", [r for r in variant if r not in moved]),
                          ("A by start time", variant)):
            comp = [r for r in rs if r["usage_status"] == "complete"]
            lc = describe(column(comp, "total_list_cost"))
            tk = describe(column(comp, "total_tokens"))
            rows.append([label, len(rs), len(comp), f_usd(lc["mean"]), f_usd(lc["median"]), f_tokens(tk["median"]),
                         f_dur(describe(column(rs, "duration_s"))["median"]),
                         f_dur(describe(column(rs, "work_duration_s"))["median"])])
        out += md_table(["Group A defined", "Done", "Usage complete", "List cost mean", "List cost median",
                         "Tokens median", "Median created to finished", "Median started to finished"], rows)
        out += ["", "A task that waited for its start has the wait in its created-to-finished time; "
                    "started-to-finished is the time it was worked on.", ""]
    return out


def method_section(ctx):
    out = ["## Method", ""]
    no_fork_kind = not any(s.kind == "fork" for s in ctx.sessions.values())
    out += ["### Data", "",
            "The inputs are `tasks.csv` (the task board of this project) and `sessions.csv` (every session of those "
            "tasks and every session descended from them), written by `scripts/analysis/extract_usage_data.py` from "
            "a dump of the harness's task store and session records. They hold ids, flags, enum values, timestamps "
            "(Unix epoch seconds) and numbers, and no title, prompt, name, path or transcript text; neither does "
            "this file. Times are compared as epoch seconds: the cutoffs are written with their UTC offset and "
            "converted first.", ""]
    out += ["### Cutoffs", ""]
    out += md_table(
        ["Event", "Commit", "Local time", "UTC"],
        [["Supervisor mode introduced", "`73f987b`", SUPERVISOR_INTRODUCED_ISO, f_when(SUPERVISOR_INTRODUCED)],
         ["Plan mode introduced", "`b0a013d`", PLAN_MODE_INTRODUCED_ISO, f_when(PLAN_MODE_INTRODUCED)],
         ["Supervisor cache/cost fix landed", "`0803841` (landing `7be8ce2`)", SUPERVISOR_FIX_ISO,
          f_when(SUPERVISOR_FIX)]], ["l", "l", "l", "l"])
    out += ["",
            "Before the fix a supervisor's workers defaulted to inheriting (forking) the whole supervisor "
            "conversation, the cache and cost blow-up already known about. Plan mode (a strong model plans "
            "read-only, a medium model works) is a different mechanism from supervisor mode.", ""]
    out += ["### Classification", "",
            "Each task goes to the first group whose rule it meets:", "",
            "1. **Plan mode** (set aside): the task's `plan` flag is set.",
            f"2. **Group A, fixed supervisor mode**: the supervisor flag is on and the task's `created` is at or "
            f"after {SUPERVISOR_FIX_ISO} (the instant itself counts as after).",
            f"3. **Excluded, old buggy supervisor mode**: the supervisor flag is on and the task's `created` is "
            f"before {SUPERVISOR_FIX_ISO}. Kept out of A and B and summarised on its own.",
            "4. **Group B, single-session (the old way)**: the supervisor flag is off or absent. A task created "
            f"before {SUPERVISOR_INTRODUCED_ISO}, when supervisor mode did not exist, normally has no flag and falls "
            "here.", "",
            "The supervisor flag is the task session's own switch (`ext.supervisor` of its record: true supervises, "
            "false works hands-on). A session with no value counts as off. When the session has no value, the "
            "task's own explicit `supervisor` setting is used if it has one. Only tasks whose state is `done` "
            "enter a statistic; any other state is counted as in flight and left out for that reason alone. A "
            "task with no sub-agents is a valid data point and is kept.", ""]
    out += ["### Which sessions belong to a task", "",
            "The *top-level session* is the task's own session. A *sub-agent* is a session of kind `subagent` or "
            "`fork` whose `parent_id` chain leads back to the top-level session, directly or through other "
            "sessions (including through a side conversation of kind `btw`). "
            + ("The data has no session of kind `fork`: a worker started as a fork of its parent's conversation is "
               "a `subagent` with `forked` true. " if no_fork_kind else "")
            + "Sessions of kind `btw` (side conversations) and `internal` (the harness's own model calls) are not "
              "sub-agents and are in no total. Group B is defined by the flag, not by the absence of sub-agents: a "
              f"hands-on session can start them too, and {ctx.b['n_done'] - ctx.b['zero_subagents']} of B's "
              f"{ctx.b['n_done']} done tasks have at least one.", ""]
    out += ["### Measures", "",
            "- **Session usage**: tokens (input, output, cache-read, cache-write) and costs come from two sources, "
            "the session record's cumulative totals and the usage ledger (`usage.db`), taking the larger per field "
            "(they agree except for a few old sessions, where the ledger is higher). A blank list cost is the "
            "billed cost, as the harness itself reads it.",
            "- **Missing usage**: a session that took model turns but has no tokens and no cost in either source "
            "has not had its usage recorded, which is not zero. A task is *complete* when neither its own session "
            "nor any sub-agent is missing. An *incomplete* task is left out of the token and cost statistics and "
            "written as `unknown` in the CSV, never as 0.",
            "- **Tokens**: the four kinds are disjoint (the harness prices each at its own rate); total tokens is "
            "their sum over the task's own session and all its sub-agents.",
            "- **Billed cost**: what was charged. It is 0 for sessions paid by a subscription plan, so it depends on "
            "how calls were paid for as well as on how much was used.",
            "- **List cost**: the same usage at API list prices. It does not depend on the billing mode, so it is "
            "the like-for-like dollar figure, though it still depends on which model's price list applies.",
            "- **Task duration**: `finished` minus `created` of the task record (wall clock; it includes the wait "
            "for a slot and, for a backlog task, the time before it was started). `finished` minus `started` is "
            "shown beside it.",
            "- **Top-level session duration**: the task's `finished` minus the session's `created`. The session "
            "record's `updated` is not used: it also moves when the harness closes or reloads sessions, and most "
            "sessions in the data were written long after their task ended.",
            "- **Sub-agent duration**: the session record's `updated` minus `created`, an upper bound on its working "
            "time for the same reason. The record has no end time.",
            "- **Compactions**: the compactions a session itself made, from its transcript: harness `compaction` "
            "nodes plus \"Context compacted by Claude Code\" notes, each counted for the session that created it (a "
            "fork's log starts with copies of its parent's nodes). A count that was not obtained would be "
            "`unknown`, not 0.",
            "- **Statistics**: mean, median and sample standard deviation (n-1; undefined for one value) from "
            "Python's `statistics` module; sums with `math.fsum`. Ratios divide A's figure by B's. No significance "
            "test is run, and none would mean anything at these sizes. A figure that is not known for a task "
            "leaves that task out of that figure only, and the row shows its own n.", ""]
    out += ["### What this cannot separate", "",
            "Tasks were not assigned to the modes at random, and the groups differ in period, so the figures "
            "describe the two groups as they happened. They do not separate the effect of the mode from the kind of "
            "task it was used on, the model in use, how the calls were paid for, or what else changed in the "
            "harness over the days covered. The instant the fix reached the running harness is not recorded; the "
            "commit time is used. The flag is the one the session record held when it was read, which a judge or "
            "the user may have changed after the session started.", ""]
    return out


def reproduce_section():
    return ["## Reproduce", "", "```", *REPRODUCE, "```", "",
            "`compare_supervisor_modes.py --help` lists the directory flags; `--self-test` checks the arithmetic on "
            "a small synthetic world with known answers.", ""]


def render_report(ctx):
    out = [GENERATED_MARK, "",
           "# Supervisor mode vs single-session tasks: usage analysis (2026-10-12)", "",
           "**Question.** Has supervisor mode made tasks slower and more expensive than the old "
           "one-session-per-task way?", "",
           f"**Data.** {ctx.n_task_rows} tasks of this project and {ctx.n_session_rows} sessions, as of the newest "
           f"session record ({f_when(ctx.snapshot)}). Every number below is arithmetic on those two tables; the "
           "method, cutoffs and limits are at the end.", ""]
    out += bottom_line(ctx)
    out += counts_section(ctx)
    out += results_section(ctx)
    out += a_tasks_section(ctx)
    out += comparison_section(ctx)
    out += sessions_section(ctx)
    out += mix_section(ctx)
    out += excluded_section(ctx)
    out += plan_section(ctx)
    out += in_flight_section(ctx)
    out += quality_section(ctx)
    out += method_section(ctx)
    out += reproduce_section()
    text = "\n".join(out).rstrip("\n") + "\n"
    for pattern in PRIVATE_PATTERNS:
        if pattern.search(text):
            raise AssertionError(f"the report would contain private-looking text: {pattern.pattern!r}")
    return text


# --------------------------------------------------------------------------
# Running

def build(in_dir):
    """Read the CSVs of IN_DIR and compute everything.  Return a Context."""
    quality = Counter()
    task_input, _ = read_table(in_dir / "tasks.csv", TASK_REQUIRED, "tasks.csv")
    session_input, _ = read_table(in_dir / "sessions.csv", SESSION_REQUIRED, "sessions.csv")
    sessions = load_sessions(session_input, quality)
    tasks = load_tasks(task_input)
    task_rows, sub_rows = analyse(tasks, sessions, quality)
    result = compare_groups(task_rows)
    add_session_stats(result, sub_rows)
    return Context(task_rows, sub_rows, sessions, result, quality, len(task_input), len(session_input))


def run(args):
    ctx = build(args.in_dir)
    csv_dir = args.csv_out_dir or args.in_dir
    write_csv(csv_dir / "classified_tasks.csv", TASK_OUT_COLUMNS, ctx.task_rows)
    write_csv(csv_dir / "subagents.csv", SUB_OUT_COLUMNS, ctx.sub_rows)
    write_text(args.out, render_report(ctx))
    print(f"classified_tasks.csv  {len(ctx.task_rows):5d} rows  {csv_dir / 'classified_tasks.csv'}")
    print(f"subagents.csv         {len(ctx.sub_rows):5d} rows  {csv_dir / 'subagents.csv'}")
    print(f"report                {args.out}")
    for g in GROUPS:
        i = ctx.groups[g]
        print(f"{GROUP_TITLES[g]:42s} tasks {i['tasks']:4d}  done {i['n_done']:4d}  "
              f"usage complete {i['n_complete']:4d}  in flight {i['in_flight']:3d}")
    return 0


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Compare fixed supervisor-mode tasks with single-session tasks.")
    parser.add_argument("--in-dir", type=Path, default=DEFAULT_IN_DIR,
                        help="directory with tasks.csv and sessions.csv (default: scripts/.dev/usage-analysis)")
    parser.add_argument("--csv-out-dir", type=Path, default=None,
                        help="where classified_tasks.csv and subagents.csv go (default: --in-dir)")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the Markdown report to write")
    parser.add_argument("--self-test", action="store_true",
                        help="check the arithmetic on a small synthetic world and exit")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.self_test:
        return self_test()
    try:
        return run(args)
    except InputError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2


# --------------------------------------------------------------------------
# Self-test: a small synthetic world whose answers were worked out by hand.

def _load_extractor():
    """Import extract_usage_data.py by path, leaving no bytecode cache in the repository."""
    spec = importlib.util.spec_from_file_location("extract_usage_data", EXTRACTOR)
    module = importlib.util.module_from_spec(spec)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


def _close(actual, expected, what):
    assert actual is not None and math.isclose(actual, expected, rel_tol=1e-9, abs_tol=1e-9), \
        f"{what}: got {actual!r}, expected {expected!r}"


def _write_world(root):
    """Write tasks.csv and sessions.csv of the synthetic world into ROOT."""
    ext = _load_extractor()
    fix, intro = SUPERVISOR_FIX, SUPERVISOR_INTRODUCED

    def sid(n):
        return "aaaaaaaa-0000-4000-8000-%012d" % n

    sessions = []

    def session(n, kind="main", parent=None, created=0.0, updated=None, flag="", model="claude:opus",
                tokens=(0, 0, 0, 0), cost=0.0, list_cost="", billing="", turns=1, compactions="0",
                forked="false", ledger=None):
        row = dict.fromkeys(ext.SESSION_COLUMNS, "")
        row.update(id=sid(n), kind=kind, parent_id=sid(parent) if parent else "", created=repr(created),
                   updated=repr(created + 100.0 if updated is None else updated), status="inactive",
                   model=model, supervisor=flag, input=tokens[0], output=tokens[1], cache_read=tokens[2],
                   cache_write=tokens[3], cost=repr(cost), list_cost=list_cost, billing=billing,
                   turns=turns, compactions=compactions, forked=forked)
        if ledger:
            row.update({"ledger_input": ledger[0], "ledger_output": ledger[1], "ledger_cache_read": ledger[2],
                        "ledger_cache_write": ledger[3], "ledger_cost": repr(ledger[4]),
                        "ledger_list_cost": repr(ledger[5]), "ledger_calls": ledger[6]})
        sessions.append(row)

    # T1 (group A, created exactly at the fix): a top session, two nested sub-agents, a side conversation
    # with a sub-agent under it, and an internal session.
    session(1, created=fix, updated=fix + 5000, flag="true", tokens=(10, 20, 30, 40), cost=1.0, list_cost="2.0",
            billing="api", turns=3, compactions="1")
    session(2, "subagent", 1, fix + 100, fix + 200, tokens=(1, 2, 3, 4), cost=0.1, list_cost="0.2",
            billing="subscription")
    session(3, "subagent", 2, fix + 150, fix + 260, tokens=(5, 5, 5, 5), cost=0.2, list_cost="0.4", billing="api",
            compactions="2", forked="true")
    session(4, "btw", 1, fix + 120, tokens=(100, 100, 100, 100), cost=9.0, list_cost="9.0", billing="api")
    session(5, "subagent", 4, fix + 130, fix + 230, tokens=(1, 1, 1, 1), cost=0.05, list_cost="0.1")
    session(6, "internal", 3, fix + 160, tokens=(50, 0, 0, 0), cost=0.5, list_cost="0.5", billing="api")
    # T2 (group A through the task's own setting; the session has no flag)
    session(7, created=fix + 100, tokens=(100, 0, 0, 0), cost=0.5, list_cost="1.5", billing="subscription", turns=2)
    # T3 (excluded: flag on, created one second before the fix) and T4 (flag on, created before the mode existed)
    session(8, created=fix - 1, flag="true", tokens=(1000, 0, 0, 0), cost=4.0, list_cost="8.0", billing="api")
    session(9, created=intro - 100, flag="true", tokens=(10, 0, 0, 0), cost=1.0, list_cost="1.0", billing="api")
    # T5 (B; the ledger holds more than the record, and the record has no list cost)
    session(10, created=fix + 50, flag="false", tokens=(10, 10, 10, 10), cost=1.0, billing="api", turns=4,
            ledger=(20, 20, 20, 20, 2.0, 3.0, 5))
    # T6 (B; usage never recorded, compaction count unknown)
    session(11, created=intro - 1000, turns=2, compactions="")
    # T7 (B; one sub-agent has no recorded usage, one does; the top session has no list cost: it is the cost)
    session(12, created=intro - 500, tokens=(40, 0, 0, 0), cost=0.4, list_cost="", billing="api",
            compactions="3")
    session(13, "subagent", 12, intro - 400, tokens=(0, 0, 0, 0), compactions="", forked="true")
    session(14, "subagent", 12, intro - 300, tokens=(8, 0, 0, 0), cost=0.08, list_cost="0.08", billing="api")
    # T8 (B: the session says off, the task setting says on), T9 (A, not done), T10 (B, review), T11 (plan mode)
    session(15, created=fix + 500, flag="false", tokens=(60, 0, 0, 0), cost=0.6, list_cost="0.6", billing="api")
    session(16, created=fix + 10, flag="true", turns=0)
    session(17, created=intro + 10, tokens=(5, 0, 0, 0), cost=0.05, list_cost="0.05", billing="api")
    # a sub-agent with a cost but no tokens did record usage: it is not "missing"
    session(19, "subagent", 17, intro + 20, tokens=(0, 0, 0, 0), cost=0.3, list_cost="0.3", billing="api")
    session(18, created=fix + 5, flag="true", tokens=(7, 0, 0, 0), cost=0.07, list_cost="0.07", billing="api")

    tasks = []

    def task(tid, n, created, started, finished, state="done", setting="", plan=""):
        row = dict.fromkeys(ext.TASK_COLUMNS, "")
        row.update(id=tid, session=sid(n), created=repr(created), started=repr(started) if started else "",
                   finished=repr(finished) if finished else "", state=state, outcome="merged" if state == "done" else "",
                   supervisor=setting, plan=plan)
        tasks.append(row)

    task("t-aaaa0001", 1, fix, fix + 10, fix + 1010)
    task("t-aaaa0002", 7, fix + 100, fix + 110, fix + 400, setting="true")
    task("t-aaaa0003", 8, fix - 1, fix + 4, fix + 50)
    task("t-aaaa0004", 9, intro - 100, intro - 90, intro + 3600)
    task("t-bbbb0001", 10, fix + 50, fix + 60, fix + 260)
    task("t-bbbb0002", 11, intro - 1000, intro - 900, intro - 100)
    task("t-bbbb0003", 12, intro - 500, intro - 450, intro + 500)
    task("t-bbbb0004", 15, fix + 500, None, fix + 900, setting="true")
    task("t-dddd0001", 16, fix + 10, None, None, state="pending")
    task("t-eeee0001", 17, intro + 10, intro + 20, None, state="review")
    task("t-ffff0001", 18, fix + 5, fix + 6, fix + 60, plan="true")

    root.mkdir(parents=True, exist_ok=True)
    for name, columns, rows in (("tasks.csv", ext.TASK_COLUMNS, tasks), ("sessions.csv", ext.SESSION_COLUMNS, sessions)):
        with open(root / name, "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=columns, lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
    return ext


def self_test():
    """Check constants, classification and arithmetic on a synthetic world.  Return the exit status."""
    try:
        _self_test()
    except AssertionError as err:
        print(f"self-test FAILED: {err}", file=sys.stderr)
        return 1
    print("self-test ok")
    return 0


def _self_test():
    # The cutoffs, as epoch seconds (checked against dates worked out by hand).
    assert SUPERVISOR_INTRODUCED == 1791487457.0, SUPERVISOR_INTRODUCED
    assert SUPERVISOR_FIX == 1791777353.0, SUPERVISOR_FIX
    assert PLAN_MODE_INTRODUCED == 1791769725.0, PLAN_MODE_INTRODUCED
    assert SUPERVISOR_INTRODUCED < PLAN_MODE_INTRODUCED < SUPERVISOR_FIX

    # Statistics and formatting helpers.
    d = describe([1, 2, 3, 4, None])
    assert d["n"] == 4 and d["mean"] == 2.5 and d["median"] == 2.5 and d["sum"] == 10
    _close(d["stdev"], statistics.stdev([1, 2, 3, 4]), "stdev")
    assert describe([5])["stdev"] is None and describe([])["mean"] is None
    assert ratio(6, 3) == 2 and ratio(1, 0) is None and ratio(None, 1) is None
    assert f_dur(3661) == "1:01:01" and f_dur(None) == NA and f_usd(0.0005) == "$0.0005"
    assert f_usd(12.345) == "$12.35" and f_tokens(1234567) == "1,234,567" and f_ratio(1.5) == "1.50x"
    assert plural(1, "task") == "1 task" and plural(2, "task") == "2 tasks"
    assert PRIVATE_PATTERNS[0].search("aaaaaaaa-0000-4000-8000-000000000001")
    assert PRIVATE_PATTERNS[1].search("task t-aaaa0001 ran") and PRIVATE_PATTERNS[2].search("in /home/x")

    ext = None
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        ext = _write_world(root / "in")

        # Every column this script reads is one the extractor writes.
        for name in TASK_REQUIRED + TASK_OPTIONAL:
            assert name in ext.TASK_COLUMNS, f"tasks.csv has no column {name}"
        for name in SESSION_REQUIRED + SESSION_OPTIONAL:
            assert name in ext.SESSION_COLUMNS, f"sessions.csv has no column {name}"

        ctx = build(root / "in")
        rows = {r["task_id"]: r for r in ctx.task_rows}
        groups = {tid: r["group"] for tid, r in rows.items()}
        assert groups == {
            "t-aaaa0001": GROUP_A,           # created exactly at the fix counts as after
            "t-aaaa0002": GROUP_A,           # flag from the task's own setting
            "t-aaaa0003": EXCLUDED_BUGGY,    # one second before the fix
            "t-aaaa0004": EXCLUDED_BUGGY,    # flag on although the mode did not exist yet
            "t-bbbb0001": GROUP_B,           # flag off, created after the fix
            "t-bbbb0002": GROUP_B,           # no flag
            "t-bbbb0003": GROUP_B,
            "t-bbbb0004": GROUP_B,           # the session's flag (off) beats the task's setting (on)
            "t-dddd0001": GROUP_A,           # not done
            "t-eeee0001": GROUP_B,           # not done
            "t-ffff0001": PLAN_MODE,         # the plan flag wins over the supervisor flag
        }, groups
        assert rows["t-aaaa0002"]["flag_source"] == "task" and rows["t-aaaa0001"]["flag_source"] == "session"
        assert rows["t-bbbb0002"]["flag_source"] == "none" and rows["t-bbbb0002"]["supervisor_flag"] == "absent"
        assert ctx.quality["ledger_differs"] == 1
        assert ctx.quality["flag_before_mode_existed"] == 1
        assert ctx.quality["setting_differs_from_flag"] == 1

        # T1: descendants are found transitively and through a side conversation; btw and internal are not
        # sub-agents.
        t1 = rows["t-aaaa0001"]
        assert t1["n_subagents"] == 3 and t1["n_forked_subagents"] == 1 and t1["n_other_descendants"] == 2
        assert t1["usage_status"] == "complete"
        assert (t1["total_input"], t1["total_output"], t1["total_cache_read"], t1["total_cache_write"]) == (17, 28, 39, 50)
        assert t1["total_tokens"] == 134
        _close(t1["total_cost"], 1.35, "T1 cost")
        _close(t1["total_list_cost"], 2.7, "T1 list cost")
        assert t1["top_tokens"] == 100 and t1["sub_tokens"] == 34
        _close(t1["top_list_cost"], 2.0, "T1 top list cost")
        _close(t1["sub_list_cost"], 0.7, "T1 sub list cost")
        assert t1["duration_s"] == 1010 and t1["work_duration_s"] == 1000 and t1["top_duration_s"] == 1010
        assert t1["top_compactions"] == 1 and t1["sub_compactions"] == 2
        assert (t1["sessions_api"], t1["sessions_subscription"], t1["sessions_billing_none"]) == (2, 1, 1)

        # T5: the ledger wins where it is higher, and a blank list cost falls back to the cost.
        t5 = rows["t-bbbb0001"]
        assert t5["total_tokens"] == 80 and t5["n_subagents"] == 0
        _close(t5["total_cost"], 2.0, "T5 cost")
        _close(t5["total_list_cost"], 3.0, "T5 list cost")

        # T6 and T7: usage that was never recorded makes a task incomplete; its totals are unknown, not zero.
        t6, t7 = rows["t-bbbb0002"], rows["t-bbbb0003"]
        assert t6["usage_status"] == "incomplete" and t6["total_tokens"] is None and t6["top_tokens"] is None
        assert t6["sub_tokens"] == 0 and t6["top_compactions"] is None
        assert t7["usage_status"] == "incomplete" and t7["total_tokens"] is None
        assert t7["top_tokens"] == 40 and t7["sub_tokens"] is None and t7["recorded_tokens"] == 48
        assert t7["n_subagents"] == 2 and t7["sub_compactions"] is None and t7["sessions_usage_missing"] == 1

        t10 = rows["t-eeee0001"]
        assert t10["usage_status"] == "complete" and t10["n_subagents"] == 1 and t10["total_tokens"] == 5
        _close(t10["sub_cost"], 0.3, "T10 sub cost")

        # Group statistics, worked out by hand.
        a, b = ctx.a, ctx.b
        assert (a["tasks"], a["n_done"], a["n_complete"], a["in_flight"]) == (3, 2, 2, 1)
        assert (b["tasks"], b["n_done"], b["n_complete"], b["n_incomplete"], b["in_flight"]) == (5, 4, 2, 2, 1)
        assert dict(a["in_flight_states"]) == {"pending": 1} and dict(b["in_flight_states"]) == {"review": 1}
        assert (ctx.groups[EXCLUDED_BUGGY]["tasks"], ctx.groups[EXCLUDED_BUGGY]["n_done"]) == (2, 2)
        assert (ctx.groups[PLAN_MODE]["tasks"], ctx.groups[PLAN_MODE]["n_done"]) == (1, 1)
        assert a["task"]["total_tokens"]["mean"] == 117 and a["task"]["total_tokens"]["median"] == 117
        _close(a["task"]["total_tokens"]["stdev"], math.sqrt(578), "A tokens stdev")
        _close(a["task"]["total_cost"]["mean"], 0.925, "A cost mean")
        _close(a["task"]["total_list_cost"]["mean"], 2.1, "A list cost mean")
        _close(a["total_list_cost_complete"], 4.2, "A list cost sum")
        assert a["task"]["duration_s"]["mean"] == 655 and a["task"]["work_duration_s"]["mean"] == 645
        assert a["task"]["n_subagents"]["mean"] == 1.5 and a["zero_subagents"] == 1
        assert a["top"]["top_compactions"]["mean"] == 0.5 and a["sub"]["sub_compactions"]["mean"] == 1.0
        assert dict(a["billing"]) == {"subscription": 2, "api": 2, "extra-usage": 0, "not recorded": 1, "other": 0}
        assert a["n_workers"] == 3 and a["workers_forked"] == 1 and a["other_sessions"] == 2
        _close(a["other_list_cost"], 9.5, "A side-conversation list cost")
        assert a["sessions"]["tokens"]["n"] == 3 and a["sessions"]["tokens"]["median"] == 10
        _close(a["sessions"]["duration_s"]["mean"], 310 / 3, "A sub-agent duration mean")
        _close(a["sessions"]["compactions"]["mean"], 2 / 3, "A sub-agent compactions mean")
        assert b["task"]["total_tokens"]["n"] == 2 and b["task"]["total_tokens"]["mean"] == 70
        _close(b["task"]["total_list_cost"]["mean"], 1.8, "B list cost mean")
        _close(b["task"]["total_cost"]["mean"], 1.3, "B cost mean")
        assert b["task"]["duration_s"]["n"] == 4 and b["task"]["duration_s"]["mean"] == 627.5
        assert b["task"]["duration_s"]["median"] == 650
        assert b["task"]["work_duration_s"]["n"] == 3 and b["task"]["work_duration_s"]["median"] == 800
        assert b["task"]["n_subagents"]["mean"] == 0.5 and b["zero_subagents"] == 3
        assert b["top_compactions_unknown"] == 1 and b["top"]["top_compactions"]["n"] == 3
        _close(b["total_cost"], 3.08, "B recorded cost")
        _close(b["total_list_cost"], 4.08, "B recorded list cost")
        assert b["n_workers"] == 2 and b["sessions"]["tokens"]["n"] == 1 and b["sessions"]["compactions"]["n"] == 1
        excluded = ctx.groups[EXCLUDED_BUGGY]
        _close(excluded["total_cost"], 5.0, "excluded cost")
        _close(excluded["total_list_cost"], 9.0, "excluded list cost")
        moved_ids = [r["task_id"] for r in ctx.moved]
        assert moved_ids == ["t-aaaa0003"] and len(ctx.a_variant) == 3

        # The end-to-end run writes the CSVs and the report.
        out = root / "report.md"
        args = parse_args(["--in-dir", str(root / "in"), "--out", str(out)])
        stdout = sys.stdout
        try:
            sys.stdout = open(os.devnull, "w")
            assert run(args) == 0
            first = out.read_bytes()
            assert run(args) == 0 and out.read_bytes() == first, "the run is not repeatable"
        finally:
            sys.stdout.close()
            sys.stdout = stdout
        with open(root / "in" / "classified_tasks.csv", newline="", encoding="utf-8") as handle:
            written = {r["task_id"]: r for r in csv.DictReader(handle)}
        assert len(written) == 11 and list(next(iter(written.values()))) == TASK_OUT_COLUMNS
        assert written["t-bbbb0002"]["total_tokens"] == UNKNOWN and written["t-bbbb0002"]["top_compactions"] == UNKNOWN
        assert written["t-bbbb0003"]["sub_tokens"] == UNKNOWN and written["t-bbbb0003"]["recorded_tokens"] == "48"
        assert written["t-aaaa0001"]["total_tokens"] == "134" and written["t-aaaa0001"]["in_comparison"] == "true"
        assert written["t-dddd0001"]["in_comparison"] == "false" and written["t-dddd0001"]["finished"] == ""
        assert written["t-ffff0001"]["group"] == PLAN_MODE and written["t-aaaa0003"]["group"] == EXCLUDED_BUGGY
        with open(root / "in" / "subagents.csv", newline="", encoding="utf-8") as handle:
            subs = list(csv.DictReader(handle))
        assert len(subs) == 6 and list(subs[0]) == SUB_OUT_COLUMNS
        missing = [s for s in subs if s["usage_status"] == "missing"]
        assert len(missing) == 1 and missing[0]["tokens"] == UNKNOWN and missing[0]["compactions"] == UNKNOWN
        assert missing[0]["forked"] == "true" and missing[0]["depth"] == "1"
        assert {s["depth"] for s in subs if s["task_id"] == "t-aaaa0001"} == {"1", "2"}
        assert (root / "in" / "classified_tasks.csv").stat().st_mode & 0o777 == 0o600
        text = out.read_text(encoding="utf-8")
        assert text.startswith(GENERATED_MARK) and "The data cannot answer the question yet." in text
        assert "| A: fixed supervisor mode | 3 | 2 | 2 | 0 | 1 (pending 1) |" in text, text
        assert "| B: single-session (the old way) | 5 | 4 | 2 | 2 | 1 (review 1) |" in text
        assert "| Set aside: Plan mode | 1 | 1 | 1 | 0 | 0 |" in text
        assert "### Group A, task by task" in text and "making n(A) = 3" in text
        for pattern in PRIVATE_PATTERNS:
            assert not pattern.search(text), f"the report holds {pattern.pattern}"

        # The model-matched subset of B and the other descriptive subsets.
        by_key = {x["key"]: x for x in ctx.strata}
        assert by_key["all"]["n"] == 4 and by_key["a_model"]["n"] == 4 and by_key["a_model"]["n_complete"] == 2
        assert by_key["before"]["n"] == 2 and by_key["since"]["n"] == 2 and by_key["zero"]["n"] == 3
        assert by_key["fix"]["n"] == 2 and by_key["fix"]["n_complete"] == 2
        assert by_key["few"]["n"] == 1 and by_key["many"]["n"] == 0 and by_key["many"]["median"] is None
        assert "Cost depends on the model." in text

        # A world where one A task has incomplete usage, and one with no A task at all.
        inc = root / "incomplete"
        _write_world(inc)
        with open(inc / "sessions.csv", newline="", encoding="utf-8") as handle:
            table = list(csv.DictReader(handle))
        for row in table:
            if row["id"].endswith("000000000007"):
                row.update(input="0", cost="0.0", list_cost="0.0")
        with open(inc / "sessions.csv", "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(table[0]), lineterminator="\n")
            writer.writeheader()
            writer.writerows(table)
        text = render_report(build(inc))
        assert "n = 2 done tasks, 1 of them with a complete usage record" in text
        assert "An A task with incomplete usage: 1 of its 1 sessions" in text and "at least $" in text
        none = root / "no-a"
        _write_world(none)
        with open(none / "tasks.csv", newline="", encoding="utf-8") as handle:
            table = [r for r in csv.DictReader(handle) if r["supervisor"] != "true" and not r["id"].startswith(
                ("t-aaaa0001", "t-dddd0001"))]
        with open(none / "tasks.csv", "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(table[0]), lineterminator="\n")
            writer.writeheader()
            writer.writerows(table)
        text = render_report(build(none))
        assert "No task has been done under fixed supervisor mode" in text and "n/a" in text

        nofix = root / "no-b-since-the-fix"
        _write_world(nofix)
        with open(nofix / "tasks.csv", newline="", encoding="utf-8") as handle:
            table = [r for r in csv.DictReader(handle) if r["id"] not in ("t-bbbb0001", "t-bbbb0004")]
        with open(nofix / "tasks.csv", "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(table[0]), lineterminator="\n")
            writer.writeheader()
            writer.writerows(table)
        text = render_report(build(nofix))
        assert "No done B task was created since the fix" in text

        # Bad inputs are reported, not guessed at.
        for name, mutate, needle in (
                ("missing file", lambda d: (d / "tasks.csv").unlink(), "not found"),
                ("missing column", lambda d: (d / "sessions.csv").write_text("id,kind\nx,main\n"), "lacks the column"),
                ("duplicate task", lambda d: (d / "tasks.csv").write_text(
                    "id,session,created,state\nt-1,s,1.0,done\nt-1,s,1.0,done\n"), "duplicate task id")):
            bad = root / f"bad-{name.replace(' ', '-')}"
            _write_world(bad)
            mutate(bad)
            try:
                build(bad)
            except InputError as err:
                assert needle in str(err), f"{name}: {err}"
            else:
                raise AssertionError(f"{name}: no InputError")


if __name__ == "__main__":
    sys.exit(main())
