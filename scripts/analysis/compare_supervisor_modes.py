#!/usr/bin/env python3
"""Compare supervisor-mode tasks with single-session tasks, from extracted harness data.

The question: has supervisor mode made tasks slower and more expensive than the
old one-session-per-task way?  Everything here is arithmetic on the CSVs that
scripts/analysis/extract_usage_data.py writes (usage_rows.csv, sessions.csv,
tasks.csv, and plan_steps.csv / manifest.json when present).  No model is asked
to judge or estimate anything, and nothing is fetched from a network.

What it does:
  1. puts every task in one of five groups (see "Classification");
  2. sums each task's usage rows over its top-level session and over every
     sub-agent / fork session descended from it (the parent-id chain, followed
     transitively);
  3. writes classified_tasks.csv (one row per task) and subagents.csv (one row
     per sub-agent session), next to the inputs unless --csv-out-dir says
     otherwise;
  4. computes per-group statistics with the `statistics` module and writes a
     Markdown report (default docs/analysis/supervisor-mode-vs-single-session-2026-10-12.md).

Classification, first match wins (cutoffs below, compared as UTC instants):
  plan-mode       the task carries the Plan-mode flag (the task's `plan` key)
  unresolved      the task's session record is missing, so its flag, creation
                  time and sub-agents cannot be verified
  B               created before supervisor mode existed, or its top-level
                  session's supervisor flag is off or absent (single-session)
  excluded-buggy  supervisor flag on, session created before the cache/cost fix
  A               supervisor flag on, session created at or after the fix
Only tasks whose state is `done` enter the A/B comparison; the others are
counted as still in flight.

Privacy: only ids, flags, enum values, timestamps and numbers are read or
written.  The Markdown report holds aggregates and methodology, no ids.

Python 3 standard library only.

Usage:
    scripts/analysis/compare_supervisor_modes.py
    scripts/analysis/compare_supervisor_modes.py --in-dir DIR --out FILE
    scripts/analysis/compare_supervisor_modes.py --methodology-only
    scripts/analysis/compare_supervisor_modes.py --self-test

Exit status: 0 done; 1 the self-test failed; 2 an input is missing or
unreadable, or a usage error.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import datetime as dt
import importlib.util
import io
import json
import math
import os
import statistics
import sys
import tempfile
from collections import Counter, defaultdict, deque
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_IN_DIR = REPO_ROOT / "scripts" / ".dev" / "usage-analysis"
DEFAULT_OUT = REPO_ROOT / "docs" / "analysis" / "supervisor-mode-vs-single-session-2026-10-12.md"

UTC = dt.timezone.utc
EPOCH_MIN = dt.datetime.min.replace(tzinfo=UTC)


def iso_to_utc(iso):
    """An ISO-8601 instant with a UTC offset, as an aware UTC datetime."""
    when = dt.datetime.fromisoformat(iso)
    if when.tzinfo is None:
        raise ValueError(f"{iso!r} has no UTC offset")
    return when.astimezone(UTC)


# --------------------------------------------------------------------------
# Classification cutoffs.  Each is an instant with its UTC offset, converted to
# UTC before any comparison.

# 73f987b "Add supervisor mode: ..." -- supervisor mode did not exist before it,
# so every task created earlier is group B.
SUPERVISOR_INTRODUCED_ISO = "2026-10-08T15:24:17-04:00"

# 0803841 "Fix supervisor cache cost and planning efficiency", landing 7be8ce2
# "supervisor: start workers fresh by default, refuse forks of long
# conversations".  Before it a worker inherited (forked) the whole supervisor
# conversation: the cache blow-up the user already knows about.
SUPERVISOR_FIX_ISO = "2026-10-11T23:55:53-04:00"

# b0a013d "Add Plan mode for tasks: a strong model plans read-only, a medium
# model works" -- a different mechanism from supervisor mode's plan and
# sub-agents; its tasks are set aside.
PLAN_MODE_INTRODUCED_ISO = "2026-10-11T21:48:45-04:00"

SUPERVISOR_INTRODUCED = iso_to_utc(SUPERVISOR_INTRODUCED_ISO)
SUPERVISOR_FIX = iso_to_utc(SUPERVISOR_FIX_ISO)
PLAN_MODE_INTRODUCED = iso_to_utc(PLAN_MODE_INTRODUCED_ISO)

GROUP_A = "A"
GROUP_B = "B"
EXCLUDED_BUGGY = "excluded-buggy"
PLAN_MODE = "plan-mode"
UNRESOLVED = "unresolved"
GROUPS = (GROUP_A, GROUP_B, EXCLUDED_BUGGY, PLAN_MODE, UNRESOLVED)
GROUP_TITLES = {
    GROUP_A: "A: fixed supervisor mode",
    GROUP_B: "B: single-session (the old way)",
    EXCLUDED_BUGGY: "Excluded: old buggy supervisor mode",
    PLAN_MODE: "Set aside: Plan mode",
    UNRESOLVED: "Set aside: session record missing",
}

WORKER_KINDS = ("subagent", "fork")   # a sub-agent is a session of one of these kinds
TERMINAL_STATE = "done"               # a task enters the comparison only in this state
SETTLED_STATES = ("done", "review")   # the agent has finished: done, or waiting for the user
KNOWN_BILLING = ("api", "subscription", "extra-usage")
SMALL_N = 30                          # below this a group is called small in the report

# --------------------------------------------------------------------------
# Columns the inputs must have (anything else in them is ignored), and the
# optional ones used when present.  Kept in step with extract_usage_data.py;
# the self-test checks that each is a column that script writes.

TASK_REQUIRED = ("task_id", "session_id", "state", "created")
TASK_OPTIONAL = ("outcome", "started", "finished", "reopened", "supervisor_setting", "plan",
                 "adopted", "backlog", "session_supervisor", "session_created")
SESSION_REQUIRED = ("session_id", "kind", "parent_id", "supervisor", "created", "updated")
SESSION_OPTIONAL = ("seed", "status", "supervisor_judge_pending", "supervisor_write_up",
                    "has_nodes_file", "compactions")
USAGE_REQUIRED = ("session", "input", "output", "cache_read", "cache_write", "cost")
USAGE_OPTIONAL = ("ts", "list_cost", "billing")
PLAN_STEP_COLUMNS_USED = ("worker_session_id", "previous_session_id")

TASK_OUT_COLUMNS = [
    "task_id", "top_session_id", "group", "group_reason", "in_comparison", "stage", "state", "outcome",
    "supervisor_flag", "flag_source", "plan_flag", "adopted", "reopened",
    "task_created_utc", "task_started_utc", "session_created_utc", "finished_utc",
    "duration_created_to_finished_s", "duration_started_to_finished_s",
    "num_subagents", "num_subagents_excl_seeds", "num_seed_sessions", "num_plan_step_workers",
    "num_other_descendants", "shared_sessions", "descendants_resolved",
    "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "total_tokens",
    "cost", "list_cost", "usage_rows", "rows_api", "rows_subscription", "rows_extra_usage",
    "rows_billing_other", "rows_billing_blank", "rows_list_cost_blank", "rows_priced_at_zero",
    "tokens_priced_at_zero",
    "top_input_tokens", "top_output_tokens", "top_cache_read_tokens", "top_cache_write_tokens",
    "top_total_tokens", "top_cost", "top_list_cost", "top_usage_rows",
    "top_duration_s", "top_usage_span_s", "top_compactions",
    "sub_input_tokens", "sub_output_tokens", "sub_cache_read_tokens", "sub_cache_write_tokens",
    "sub_total_tokens", "sub_cost", "sub_list_cost", "sub_usage_rows", "sub_compactions_total",
    "other_total_tokens", "other_cost", "other_list_cost", "other_usage_rows",
]

SUB_OUT_COLUMNS = [
    "task_id", "group", "in_comparison", "session_id", "parent_id", "depth", "kind",
    "is_seed", "is_plan_step_worker", "status", "created_utc",
    "duration_s", "usage_span_s",
    "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "total_tokens",
    "cost", "list_cost", "usage_rows", "compactions",
]


class InputError(Exception):
    """An input file is missing or does not have the columns this script needs."""


# --------------------------------------------------------------------------
# Parsing

def parse_ts(value):
    """Epoch seconds or an ISO-8601 string as an aware UTC datetime; None if neither.

    A string without a UTC offset is read as UTC.
    """
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        return dt.datetime.fromtimestamp(float(text), tz=UTC)
    except (ValueError, OverflowError, OSError):
        pass
    try:
        when = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=UTC)
    return when.astimezone(UTC)


def to_float(value):
    """A finite float, or None for blank or unparseable text."""
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    return number if math.isfinite(number) else None


def to_int(value):
    number = to_float(value)
    return None if number is None else int(round(number))


def is_true(value):
    return str(value).strip().lower() == "true" if value is not None else False


def seconds_between(start, end):
    """Seconds from START to END, or None when either is missing or END is earlier."""
    if start is None or end is None or end < start:
        return None
    return (end - start).total_seconds()


def iso_utc(when):
    return when.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ") if when is not None else None


# --------------------------------------------------------------------------
# Reading the CSVs

@contextlib.contextmanager
def csv_rows(path, required, label):
    """Yield (reader, header) for PATH, checking that REQUIRED columns are there."""
    if not path.is_file():
        raise InputError(f"{label}: {path} not found")
    fh = open(path, newline="", encoding="utf-8")
    try:
        reader = csv.DictReader(fh)
        header = reader.fieldnames or []
        missing = [c for c in required if c not in header]
        if missing:
            raise InputError(f"{label}: {path} lacks the column(s) {', '.join(missing)}")
        yield reader, header
    finally:
        fh.close()


class Agg:
    """Usage summed over the rows of one or more sessions."""

    __slots__ = ("input", "output", "cache_read", "cache_write", "cost", "list_cost",
                 "rows", "list_cost_blank", "unpriced_rows", "unpriced_tokens", "billing", "first_ts", "last_ts")

    def __init__(self):
        self.input = self.output = self.cache_read = self.cache_write = 0
        self.cost = self.list_cost = 0.0
        self.rows = self.list_cost_blank = self.unpriced_rows = self.unpriced_tokens = 0
        self.billing = Counter()
        self.first_ts = self.last_ts = None

    @property
    def tokens(self):
        return self.input + self.output + self.cache_read + self.cache_write

    @property
    def span(self):
        """Seconds from the first to the last usage row, None without rows or stamps."""
        return seconds_between(self.first_ts, self.last_ts)

    def merge(self, other):
        self.input += other.input
        self.output += other.output
        self.cache_read += other.cache_read
        self.cache_write += other.cache_write
        self.cost += other.cost
        self.list_cost += other.list_cost
        self.rows += other.rows
        self.list_cost_blank += other.list_cost_blank
        self.unpriced_rows += other.unpriced_rows
        self.unpriced_tokens += other.unpriced_tokens
        self.billing.update(other.billing)
        for ts in (other.first_ts, other.last_ts):
            if ts is not None:
                self.first_ts = ts if self.first_ts is None else min(self.first_ts, ts)
                self.last_ts = ts if self.last_ts is None else max(self.last_ts, ts)
        return self

    def billing_rows(self):
        """Row counts by billing: api, subscription, extra-usage, other, not recorded."""
        other = sum(n for key, n in self.billing.items() if key and key not in KNOWN_BILLING)
        return {
            "api": self.billing["api"],
            "subscription": self.billing["subscription"],
            "extra-usage": self.billing["extra-usage"],
            "other": other,
            "blank": self.billing[""],
        }


EMPTY_AGG = Agg()  # never mutated: stands for a session without usage rows


def sum_aggs(aggs):
    total = Agg()
    for agg in aggs:
        if agg is not None:
            total.merge(agg)
    return total


def load_usage(path, quality):
    """Sum usage_rows.csv per session id.  A row without list_cost counts at its cost."""
    by_session = {}
    first = last = None
    with csv_rows(path, USAGE_REQUIRED, "usage_rows.csv") as (reader, header):
        quality["usage_has_list_cost_column"] = "list_cost" in header
        quality["usage_has_billing_column"] = "billing" in header
        for row in reader:
            quality["usage_rows"] += 1
            sid = (row.get("session") or "").strip()
            agg = by_session.get(sid)
            if agg is None:
                agg = by_session[sid] = Agg()
            tokens = []
            for key in ("input", "output", "cache_read", "cache_write"):
                number = to_int(row.get(key))
                if number is None:
                    quality["usage_blank_token_fields"] += 1
                    number = 0
                tokens.append(number)
            agg.input += tokens[0]
            agg.output += tokens[1]
            agg.cache_read += tokens[2]
            agg.cache_write += tokens[3]
            cost = to_float(row.get("cost"))
            if cost is None:
                quality["usage_blank_cost_fields"] += 1
                cost = 0.0
            list_cost = to_float(row.get("list_cost"))
            if list_cost is None:
                # The harness's own rule (harness-usage-list-cost): list price is
                # the row's list cost, else its cost.
                quality["usage_rows_list_cost_blank"] += 1
                agg.list_cost_blank += 1
                list_cost = cost
            agg.cost += cost
            agg.list_cost += list_cost
            agg.rows += 1
            if sum(tokens) > 0 and list_cost == 0:
                # The harness records 0 for a model it has no price for.
                agg.unpriced_rows += 1
                agg.unpriced_tokens += sum(tokens)
                quality["usage_rows_priced_at_zero"] += 1
            billing = (row.get("billing") or "").strip()
            agg.billing[billing] += 1
            when = parse_ts(row.get("ts"))
            if when is not None:
                agg.first_ts = when if agg.first_ts is None else min(agg.first_ts, when)
                agg.last_ts = when if agg.last_ts is None else max(agg.last_ts, when)
                first = when if first is None else min(first, when)
                last = when if last is None else max(last, when)
    quality["usage_first_ts"], quality["usage_last_ts"] = first, last
    return by_session


class Session:
    __slots__ = ("id", "kind", "parent", "supervisor", "seed", "judge_pending",
                 "created", "updated", "status", "compactions")


def compaction_count(row):
    """The session's own compactions: blank when its transcript was not scanned.

    A session with no transcript file has none; one whose file exists but was
    not scanned (blank count) is unknown, and stays out of the statistics.
    """
    count = to_int(row.get("compactions"))
    if count is not None:
        return count
    if (row.get("has_nodes_file") or "").strip().lower() == "false":
        return 0
    return None


def load_sessions(path, quality):
    sessions = {}
    with csv_rows(path, SESSION_REQUIRED, "sessions.csv") as (reader, header):
        quality["sessions_have_compactions"] = "compactions" in header
        for row in reader:
            sid = (row.get("session_id") or "").strip()
            if not sid:
                quality["session_rows_without_id"] += 1
                continue
            if sid in sessions:
                quality["duplicate_session_ids"] += 1
            s = Session()
            s.id = sid
            s.kind = (row.get("kind") or "").strip() or "main"
            s.parent = (row.get("parent_id") or "").strip() or None
            s.supervisor = (row.get("supervisor") or "").strip().lower()
            s.seed = is_true(row.get("seed"))
            s.judge_pending = is_true(row.get("supervisor_judge_pending"))
            s.created = parse_ts(row.get("created"))
            s.updated = parse_ts(row.get("updated"))
            s.status = (row.get("status") or "").strip()
            s.compactions = compaction_count(row)
            sessions[sid] = s
    return sessions


def child_index(sessions):
    """parent id -> ids of the sessions naming it as their parent, oldest first."""
    children = defaultdict(list)
    for s in sessions.values():
        if s.parent:
            children[s.parent].append(s.id)
    for ids in children.values():
        ids.sort(key=lambda i: (sessions[i].created or EPOCH_MIN, i))
    return children


class Task:
    __slots__ = ("id", "session_id", "state", "outcome", "created", "started", "finished",
                 "reopened", "adopted", "plan", "setting", "session_flag", "session_created")


def load_tasks(path, quality):
    tasks = []
    seen = set()
    with csv_rows(path, TASK_REQUIRED, "tasks.csv") as (reader, _):
        for row in reader:
            tid = (row.get("task_id") or "").strip()
            if not tid:
                quality["task_rows_without_id"] += 1
                continue
            if tid in seen:
                quality["duplicate_task_ids"] += 1
                continue
            seen.add(tid)
            t = Task()
            t.id = tid
            t.session_id = (row.get("session_id") or "").strip()
            t.state = (row.get("state") or "").strip()
            t.outcome = (row.get("outcome") or "").strip()
            t.created = parse_ts(row.get("created"))
            t.started = parse_ts(row.get("started"))
            t.finished = parse_ts(row.get("finished"))
            t.reopened = bool((row.get("reopened") or "").strip())
            t.adopted = is_true(row.get("adopted"))
            t.plan = is_true(row.get("plan"))
            t.setting = (row.get("supervisor_setting") or "").strip().lower()
            t.session_flag = (row.get("session_supervisor") or "").strip().lower()
            t.session_created = parse_ts(row.get("session_created"))
            tasks.append(t)
    return tasks


def load_plan_workers(path, quality):
    """Ids of the sessions that plan steps name as a worker (current or earlier attempt)."""
    workers = set()
    quality["plan_steps_file"] = path.is_file()
    if not path.is_file():
        return workers
    with csv_rows(path, (), "plan_steps.csv") as (reader, _):
        for row in reader:
            for key in PLAN_STEP_COLUMNS_USED:
                value = (row.get(key) or "").strip()
                if value:
                    workers.add(value)
    return workers


def load_manifest(path):
    """What manifest.json says about the extraction (best effort; it only adds provenance)."""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


# --------------------------------------------------------------------------
# Classification and aggregation

def decide_group(plan_flag, record_found, created, flag):
    """Return (group, reason).  FLAG is "true", "false" or "" (no setting)."""
    if plan_flag:
        return PLAN_MODE, "plan flag set"
    if not record_found:
        return UNRESOLVED, "no session record"
    if created is None:
        return UNRESOLVED, "no creation time"
    if created < SUPERVISOR_INTRODUCED:
        return GROUP_B, "created before supervisor mode existed"
    if flag == "true":
        if created >= SUPERVISOR_FIX:
            return GROUP_A, "supervisor on, created at or after the fix"
        return EXCLUDED_BUGGY, "supervisor on, created before the fix"
    if flag == "false":
        return GROUP_B, "supervisor explicitly off"
    return GROUP_B, "supervisor setting absent"


def descendants(top, children):
    """Sessions descended from TOP through parent ids, as (id, depth), nearest first."""
    seen = {top}
    found = []
    queue = deque([(top, 0)])
    while queue:
        current, depth = queue.popleft()
        for child in children.get(current, ()):
            if child in seen:
                continue
            seen.add(child)
            found.append((child, depth + 1))
            queue.append((child, depth + 1))
    return found


def session_duration(session):
    """Seconds from a session record's creation to its last update."""
    return seconds_between(session.created, session.updated) if session else None


def analyse(tasks, sessions, children, usage, plan_workers, quality):
    """Classify every task and total its usage.  Return (task rows, sub-agent rows, attribution)."""
    task_rows, sub_rows = [], []
    owners = defaultdict(set)     # session id -> ids of the tasks whose main sessions include it
    task_sessions = {}
    main_ids, other_ids = set(), set()
    tasks = sorted(tasks, key=lambda t: (t.created or EPOCH_MIN, t.id))
    top_uses = Counter(t.session_id for t in tasks if t.session_id)

    for t in tasks:
        record = sessions.get(t.session_id) if t.session_id else None
        # The facts the classification rests on come from the top-level session's
        # record; the task's own copies are only a fallback for what it lacks.
        if record is not None:
            created = record.created or t.created
            flag = record.supervisor if record.supervisor in ("true", "false") else ""
            flag_source = "session" if flag else "none"
            if not flag and t.setting in ("true", "false"):
                flag, flag_source = t.setting, "task-setting"
        else:
            created = t.session_created or t.created
            flag = t.session_flag if t.session_flag in ("true", "false") else ""
            flag_source = "task-csv" if flag else "none"
        group, reason = decide_group(t.plan, record is not None, created, flag)

        if flag == "true" and created is not None and created < SUPERVISOR_INTRODUCED:
            quality["supervisor_on_before_it_existed"] += 1
        if t.plan and created is not None and created < PLAN_MODE_INTRODUCED:
            quality["plan_flag_before_plan_mode_existed"] += 1
        if (record is not None and t.setting in ("true", "false") and record.supervisor in ("true", "false")
                and t.setting != record.supervisor):
            quality["task_setting_differs_from_session_flag"] += 1
        if record is not None and record.judge_pending:
            quality["supervisor_judge_still_pending"] += 1
        if t.adopted:
            quality["adopted_tasks"] += 1
        if top_uses[t.session_id] > 1:
            quality["tasks_sharing_a_top_session"] += 1

        workers, others = [], []
        if record is not None:
            for sid, depth in descendants(t.session_id, children):
                s = sessions[sid]
                (workers if s.kind in WORKER_KINDS else others).append((s, depth))
        top_agg = usage.get(t.session_id, EMPTY_AGG) if t.session_id else EMPTY_AGG
        worker_aggs = [usage.get(s.id, EMPTY_AGG) for s, _ in workers]
        sub_agg = sum_aggs(worker_aggs)
        other_agg = sum_aggs(usage.get(s.id, EMPTY_AGG) for s, _ in others)
        total = sum_aggs([top_agg, sub_agg])

        mine = ([t.session_id] if t.session_id else []) + [s.id for s, _ in workers]
        task_sessions[t.id] = mine
        for sid in mine:
            owners[sid].add(t.id)
        main_ids.update(mine)
        other_ids.update(s.id for s, _ in others)

        in_comparison = group in (GROUP_A, GROUP_B) and t.state == TERMINAL_STATE
        stage = "done" if t.state == TERMINAL_STATE else ("review" if t.state == "review" else "in-flight")
        seeds = sum(1 for s, _ in workers if s.seed)
        plan_step_workers = sum(1 for s, _ in workers if s.id in plan_workers)
        billing = total.billing_rows()
        compactions = [s.compactions for s, _ in workers if s.compactions is not None]
        task_duration = seconds_between(t.created, t.finished)
        if t.finished is not None and t.created is not None and t.finished < t.created:
            quality["tasks_finished_before_created"] += 1
        if t.state == TERMINAL_STATE and t.finished is None:
            quality["done_tasks_without_finished_time"] += 1

        row = {
            "task_id": t.id,
            "top_session_id": t.session_id or None,
            "group": group,
            "group_reason": reason,
            "in_comparison": in_comparison,
            "stage": stage,
            "state": t.state or None,
            "outcome": t.outcome or None,
            "supervisor_flag": {"true": "on", "false": "off", "": "absent"}[flag],
            "flag_source": flag_source,
            "plan_flag": t.plan,
            "adopted": t.adopted,
            "reopened": t.reopened,
            "task_created_utc": iso_utc(t.created),
            "task_started_utc": iso_utc(t.started),
            "session_created_utc": iso_utc(created),
            "finished_utc": iso_utc(t.finished),
            "duration_created_to_finished_s": task_duration,
            "duration_started_to_finished_s": seconds_between(t.started, t.finished),
            "num_subagents": len(workers),
            "num_subagents_excl_seeds": len(workers) - seeds,
            "num_seed_sessions": seeds,
            "num_plan_step_workers": plan_step_workers,
            "num_other_descendants": len(others),
            "shared_sessions": 0,   # filled in below, once every task's sessions are known
            "descendants_resolved": record is not None,
            "input_tokens": total.input,
            "output_tokens": total.output,
            "cache_read_tokens": total.cache_read,
            "cache_write_tokens": total.cache_write,
            "total_tokens": total.tokens,
            "cost": total.cost,
            "list_cost": total.list_cost,
            "usage_rows": total.rows,
            "rows_api": billing["api"],
            "rows_subscription": billing["subscription"],
            "rows_extra_usage": billing["extra-usage"],
            "rows_billing_other": billing["other"],
            "rows_billing_blank": billing["blank"],
            "rows_list_cost_blank": total.list_cost_blank,
            "rows_priced_at_zero": total.unpriced_rows,
            "tokens_priced_at_zero": total.unpriced_tokens,
            "top_input_tokens": top_agg.input,
            "top_output_tokens": top_agg.output,
            "top_cache_read_tokens": top_agg.cache_read,
            "top_cache_write_tokens": top_agg.cache_write,
            "top_total_tokens": top_agg.tokens,
            "top_cost": top_agg.cost,
            "top_list_cost": top_agg.list_cost,
            "top_usage_rows": top_agg.rows,
            "top_duration_s": session_duration(record),
            "top_usage_span_s": top_agg.span,
            "top_compactions": record.compactions if record is not None else None,
            "sub_input_tokens": sub_agg.input,
            "sub_output_tokens": sub_agg.output,
            "sub_cache_read_tokens": sub_agg.cache_read,
            "sub_cache_write_tokens": sub_agg.cache_write,
            "sub_total_tokens": sub_agg.tokens,
            "sub_cost": sub_agg.cost,
            "sub_list_cost": sub_agg.list_cost,
            "sub_usage_rows": sub_agg.rows,
            "sub_compactions_total": sum(compactions) if compactions else (0 if not workers else None),
            "other_total_tokens": other_agg.tokens,
            "other_cost": other_agg.cost,
            "other_list_cost": other_agg.list_cost,
            "other_usage_rows": other_agg.rows,
        }
        task_rows.append(row)

        for s, depth in workers:
            agg = usage.get(s.id, EMPTY_AGG)
            sub_rows.append({
                "task_id": t.id,
                "group": group,
                "in_comparison": in_comparison,
                "session_id": s.id,
                "parent_id": s.parent,
                "depth": depth,
                "kind": s.kind,
                "is_seed": s.seed,
                "is_plan_step_worker": s.id in plan_workers,
                "status": s.status or None,
                "created_utc": iso_utc(s.created),
                "duration_s": session_duration(s),
                "usage_span_s": agg.span,
                "input_tokens": agg.input,
                "output_tokens": agg.output,
                "cache_read_tokens": agg.cache_read,
                "cache_write_tokens": agg.cache_write,
                "total_tokens": agg.tokens,
                "cost": agg.cost,
                "list_cost": agg.list_cost,
                "usage_rows": agg.rows,
                "compactions": s.compactions,
            })

    for row in task_rows:
        row["shared_sessions"] = sum(1 for sid in task_sessions[row["task_id"]] if len(owners[sid]) > 1)
    quality["tasks_with_shared_sessions"] = sum(1 for r in task_rows if r["shared_sessions"])

    attribution = attribute_usage(usage, sessions, main_ids, other_ids)
    quality["subagent_sessions_outside_any_task"] = sum(
        1 for s in sessions.values() if s.kind in WORKER_KINDS and s.id not in main_ids)
    return task_rows, sub_rows, attribution


def attribute_usage(usage, sessions, main_ids, other_ids):
    """Where every usage row went: a task's own sessions, its btw/internal ones, or nowhere."""
    buckets = {
        "task": ("a task's top-level or sub-agent session", Agg()),
        "task-other": ("a btw or internal session under a task", Agg()),
        "no-task": ("a session that belongs to no task", Agg()),
        "no-record": ("a session id with no session record", Agg()),
    }
    for sid, agg in usage.items():
        if sid in main_ids:
            key = "task"
        elif sid in other_ids:
            key = "task-other"
        elif sid in sessions:
            key = "no-task"
        else:
            key = "no-record"
        buckets[key][1].merge(agg)
    return buckets


# --------------------------------------------------------------------------
# CSV output

def csv_cell(value):
    if value is None:
        return ""
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
    """Write ROWS (dicts) to PATH atomically, owner-only: the files hold ids."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    try:
        with private_umask():
            with open(tmp, "w", newline="", encoding="utf-8") as fh:
                writer = csv.writer(fh, lineterminator="\n")
                writer.writerow(columns)
                for row in rows:
                    writer.writerow([csv_cell(row.get(c)) for c in columns])
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


def write_text(path, text):
    """Write the report atomically (it is committed, so with the ordinary umask)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


# --------------------------------------------------------------------------
# Statistics

def describe(values):
    """n, mean, median, sample stdev, min, max and sum of the non-None VALUES."""
    vals = [v for v in values if v is not None]
    n = len(vals)
    if not n:
        return {"n": 0, "mean": None, "median": None, "stdev": None, "min": None, "max": None, "sum": None}
    return {
        "n": n,
        "mean": statistics.fmean(vals),
        "median": statistics.median(vals),
        "stdev": statistics.stdev(vals) if n >= 2 else None,
        "min": min(vals),
        "max": max(vals),
        "sum": math.fsum(vals),
    }


def ratio(a, b):
    """A / B, None when either is missing or B is zero."""
    if a is None or b is None or b == 0:
        return None
    return a / b


def column(rows, key):
    return [r[key] for r in rows]


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
    """A count or a median/min/max of counts: no decimals when it is whole."""
    if x is None:
        return NA
    return f"{x:,.0f}" if float(x).is_integer() else f"{x:,.2f}"


def f_mean_count(x):
    """The mean or spread of counts: always two decimals, so a column never looks rounded."""
    return NA if x is None else f"{x:,.2f}"


def f_pct(x):
    return NA if x is None else f"{100 * x:.1f}%"


def f_ratio(x):
    return NA if x is None else f"{x:.2f}x"


def f_day(when):
    return NA if when is None else when.strftime("%Y-%m-%d")


def md_table(headers, rows, aligns=None):
    aligns = aligns or ["l"] + ["r"] * (len(headers) - 1)
    sep = ["---:" if a == "r" else ":---" for a in aligns]
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(sep) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(str(c) for c in row) + " |")
    return lines


# --------------------------------------------------------------------------
# The report

PLACEHOLDER_MARK = "<!-- compare_supervisor_modes: placeholder without results -->"
GENERATED_MARK = "<!-- generated by scripts/analysis/compare_supervisor_modes.py; do not edit by hand -->"
REPRODUCE = (
    "python3 scripts/analysis/extract_usage_data.py        # reads the harness state directory (read-only)",
    "python3 scripts/analysis/compare_supervisor_modes.py  # classifies, computes, rewrites this file",
)


def method_section():
    """The classification rule, cutoffs and definitions: the same text with or without results."""
    out = ["## Method", ""]
    out += ["### Data", "",
            "The inputs are the CSVs written by `scripts/analysis/extract_usage_data.py`, which opens the harness "
            "state directory read-only: `usage_rows.csv` (one row per model call, from `usage.db`), `sessions.csv` "
            "(one row per session record, with compaction counts taken from its transcript), `tasks.csv` (the task "
            "board) and, when present, `plan_steps.csv` and `manifest.json`. The extraction copies only ids, flags, "
            "enum values, timestamps, numbers and project directory paths (it counts a transcript's nodes by kind "
            "and copies none of their text); this script reads those CSVs and uses none of the paths. No task "
            "title, prompt, plan text or transcript text is in the inputs, and no id or path is in this file.", "",
            "Every timestamp in the CSVs is Unix epoch seconds. All times are held as timezone-aware UTC instants "
            "and compared as such; the cutoffs below are given with their offset and converted to UTC first.", ""]
    out += ["### Cutoffs", ""]
    out += md_table(
        ["Event", "Commit", "Local time", "UTC"],
        [["Supervisor mode introduced", "`73f987b`", SUPERVISOR_INTRODUCED_ISO, iso_utc(SUPERVISOR_INTRODUCED)],
         ["Plan mode introduced", "`b0a013d`", PLAN_MODE_INTRODUCED_ISO, iso_utc(PLAN_MODE_INTRODUCED)],
         ["Supervisor cache/cost fix landed", "`0803841` (landing `7be8ce2`)", SUPERVISOR_FIX_ISO,
          iso_utc(SUPERVISOR_FIX)]],
        ["l", "l", "l", "l"])
    out += ["",
            "Before the fix a supervisor's workers defaulted to inheriting (forking) the whole supervisor "
            "conversation, the cache blow-up already known about. Plan mode (a strong model plans read-only, a "
            "medium model works) is a different mechanism from supervisor mode's plan and sub-agents.", ""]
    out += ["### Classification", "",
            "Each task is put in the first group whose rule it meets:", "",
            "1. **Plan mode** (set aside): the task's `plan` flag is set.",
            "2. **Session record missing** (set aside): the task's top-level session has no record in `sessions.csv`, "
            "so its supervisor flag, creation time and sub-agents cannot be verified and its totals cannot be "
            "called complete.",
            "3. **Group B, single-session (the old way)**: the top-level session was created before "
            f"{SUPERVISOR_INTRODUCED_ISO} (supervisor mode did not exist), or its supervisor flag is off or absent.",
            "4. **Excluded, old buggy supervisor mode**: the supervisor flag is on and the top-level session was "
            f"created before {SUPERVISOR_FIX_ISO}. Kept out of A and B and summarised on its own.",
            "5. **Group A, fixed supervisor mode**: the supervisor flag is on and the top-level session was created "
            f"at or after {SUPERVISOR_FIX_ISO} (the instant itself counts as after).", "",
            "The supervisor flag is the *resolved* one: `ext.supervisor` of the task's top-level session record "
            "(`true` is on; `false` or no value is off). If the record carries no value, the task's own `supervisor` "
            "setting is used when it has one. The creation time is the session record's `created` (the task's "
            "`created` if the record has none).", "",
            "Only tasks whose persisted state is `done` enter the comparison. Tasks in any other state (pending, "
            "refining, active, review, merging) are counted as still in flight and left out for that reason alone. "
            "A task with no sub-agents is a valid data point and is kept.", ""]
    out += ["### Which sessions belong to a task", "",
            "The *top-level session* is the task's own session. A *sub-agent* is a session of kind `subagent` or "
            "`fork` whose `parent_id` chain leads back to the top-level session, directly or through other "
            "sessions (a worker's own sub-agent counts). Sessions of kind `btw` and `internal` are not sub-agents; "
            "their usage is reported separately under the secondary checks and is not in a task's totals. "
            "Seed sessions (a `subagent` that only holds a shared context for fork workers) and merge-queue "
            "conflict resolvers are `subagent`s too and are counted as such; sessions named by a plan step, and "
            "seeds, are also counted on their own so the effect can be read.", ""]
    out += ["### Measures", "",
            "- **Tokens**: input, output, cache-read and cache-write tokens summed over the usage rows of the "
            "top-level session and its sub-agents; *total tokens* is the sum of the four kinds. The harness prices "
            "each kind at its own rate, so the four counts are disjoint and a token is not counted twice.",
            "- **Billed cost**: the sum of `cost`, what was actually billed. It is 0 for calls paid under a "
            "subscription plan, so it depends on how each call was paid for as well as on how much was used.",
            "- **List cost**: the sum of `list_cost`, the same usage at API list prices. A row with no `list_cost` "
            "counts at its `cost`, as the harness itself does (`harness-usage-list-cost`). It does not depend on "
            "billing mode, so it is the like-for-like dollar measure. A model the harness has no price for is "
            "recorded at $0; those rows are counted under the data-quality notes.",
            "- **Billing breakdown**: row counts by `billing` value (`api`, `subscription`, `extra-usage`; rows "
            "written before that column existed have none).",
            "- **Task duration**: `finished` minus `created` from the task record (wall clock; it includes time "
            "waiting for a slot and any rework after a send-back). `finished` minus `started` is reported as "
            "a secondary figure.",
            "- **Session duration**: a session record's `updated` minus `created`. **Usage span**: the time from "
            "its first to its last usage row.",
            "- **Compactions**: the compaction nodes a session's own transcript holds (nodes a fork copied from "
            "its parent are not counted). A session whose transcript was not scanned is left out of those figures.",
            "- **Statistics**: mean, median, sample standard deviation (n-1; not defined for one value), minimum, "
            "maximum and sum, from Python's `statistics` module. Ratios divide A's figure by B's. No significance "
            "test is run. A figure that could not be computed for a task (a missing timestamp, say) leaves that "
            "task out of that figure only, and the figure shows its own n when it differs from the group's.", ""]
    out += ["### What this cannot separate", "",
            "Tasks were not assigned to the modes at random, and the groups differ in period, so the figures "
            "describe the two groups as they happened. They do not separate the effect of the mode from the "
            "kind of task it was used on, the model in use, how the calls were paid for, or what else changed in "
            "the harness over the weeks covered. The instant a fix reached the running harness is not recorded "
            "in the data; the commit time is used. The flag is the one the session record holds when it was "
            "read, which a judge or the user may have changed after the session started.", ""]
    return out


def reproduce_section():
    return ["## Reproduce", "", "```", *REPRODUCE, "```", "",
            "Both scripts take their directories as flags (`--help`); `compare_supervisor_modes.py --self-test` "
            "checks the arithmetic on a small synthetic world with known answers.", ""]


def placeholder_report():
    out = [PLACEHOLDER_MARK, "",
           "# Supervisor mode vs single-session tasks: usage analysis (2026-10-12)", "",
           "> **No results in this file yet.** It holds the method only. The analysis needs the harness's "
           "usage database, session records and task store, which the session that wrote the scripts could not "
           "read, so no number has been computed and none is quoted. Run the two commands under "
           "[Reproduce](#reproduce) on the machine that holds the harness state directory; "
           "`compare_supervisor_modes.py` then rewrites this file with the results.", "",
           "**Question.** Has supervisor mode made tasks slower and more expensive than the old "
           "one-session-per-task way?", ""]
    out += method_section()
    out += reproduce_section()
    return "\n".join(out).rstrip("\n") + "\n"


class Report:
    """Everything the report quotes, computed once from the task and sub-agent rows."""

    def __init__(self, task_rows, sub_rows, attribution, quality, manifest, now):
        self.task_rows = task_rows
        self.sub_rows = sub_rows
        self.attribution = attribution
        self.quality = quality
        self.manifest = manifest
        self.now = now
        self.cmp = {g: [r for r in task_rows if r["group"] == g and r["in_comparison"]]
                    for g in (GROUP_A, GROUP_B)}
        self.subs = {g: [r for r in sub_rows if r["group"] == g and r["in_comparison"]]
                     for g in (GROUP_A, GROUP_B)}
        self.n = {g: len(rows) for g, rows in self.cmp.items()}

    def by_group(self, group):
        return [r for r in self.task_rows if r["group"] == group]

    def stat(self, group, key):
        return describe(column(self.cmp[group], key))


def cell(stats, name, fmt, group_n):
    """One statistic of a group as a table cell, with its own n when it differs from the group's."""
    value = stats[name]
    text = f_mean_count(value) if fmt is f_count and name in ("mean", "stdev") else fmt(value)
    if value is not None and stats["n"] != group_n:
        text += f" (n={stats['n']})"
    return text


def stat_lines(report, label, key, fmt, names=("mean", "median", "stdev", "min", "max"), with_sum=False):
    """Rows `label | statistic | A | B` for one per-task measure."""
    sa, sb = report.stat(GROUP_A, key), report.stat(GROUP_B, key)
    rows = []
    shown = list(names) + (["sum"] if with_sum else [])
    for i, name in enumerate(shown):
        rows.append([label if i == 0 else "", name,
                     cell(sa, name, fmt, report.n[GROUP_A]), cell(sb, name, fmt, report.n[GROUP_B])])
    return rows


def sub_stat_lines(report, label, key, fmt, names=("mean", "median", "stdev")):
    """Rows `label | statistic | A | B` for one per-sub-agent-session measure."""
    sa, sb = describe(column(report.subs[GROUP_A], key)), describe(column(report.subs[GROUP_B], key))
    na, nb = len(report.subs[GROUP_A]), len(report.subs[GROUP_B])
    rows = []
    for i, name in enumerate(names):
        rows.append([label if i == 0 else "", name, cell(sa, name, fmt, na), cell(sb, name, fmt, nb)])
    return rows


def render_report(report):
    """The full Markdown report."""
    out = [GENERATED_MARK, "",
           "# Supervisor mode vs single-session tasks: usage analysis (2026-10-12)", "",
           "**Question.** Has supervisor mode made tasks slower and more expensive than the old "
           "one-session-per-task way?", ""]
    out += provenance_lines(report)
    out += bottom_line(report)
    out += counts_section(report)
    out += results_section(report)
    out += comparison_section(report)
    out += subagent_section(report)
    out += buggy_section(report)
    out += set_aside_section(report)
    out += in_flight_section(report)
    out += secondary_section(report)
    out += quality_section(report)
    out += method_section()
    out += reproduce_section()
    return "\n".join(out).rstrip("\n") + "\n"


def provenance_lines(report):
    q, m = report.quality, report.manifest
    first, last = q.get("usage_first_ts"), q.get("usage_last_ts")
    span = (f"; usage rows run from {iso_utc(first)} to {iso_utc(last)}" if first and last else "")
    extracted = m.get("extracted_at")
    source = f" extracted at {extracted}" if extracted else ""
    tasks_info = m.get("tasks") if isinstance(m.get("tasks"), dict) else {}
    stores = tasks_info.get("stores") if isinstance(tasks_info.get("stores"), list) else []
    kinds = Counter(str(s.get("status") or "unknown").split(" ")[0] for s in stores if isinstance(s, dict))
    store_note = ""
    if kinds:
        store_note = (" Task stores: " + ", ".join(f"{n} {kind}" for kind, n in sorted(kinds.items())) + ".")
    return [f"Generated {report.now.strftime('%Y-%m-%d %H:%M:%S UTC')} by "
            "`scripts/analysis/compare_supervisor_modes.py` from CSVs"
            f"{source} by `scripts/analysis/extract_usage_data.py`: {q['usage_rows']:,} usage rows, "
            f"{q['sessions']:,} session records, {q['tasks']:,} tasks{span}.{store_note} "
            "Aggregates only: no ids, paths, titles, prompts or transcript text appear in this file. "
            "How each group is defined is under [Method](#method).", ""]


def small_note(group, n):
    if n == 0:
        return f"group {group} has no task in state `done`, so nothing can be compared"
    if n < SMALL_N:
        return f"group {group} has only n = {n} tasks (fewer than {SMALL_N}), so its figures are indicative only"
    return None


def bottom_line(report):
    nA, nB = report.n[GROUP_A], report.n[GROUP_B]
    out = ["## Bottom line", ""]
    out.append(f"Computed from {nA} group A tasks (fixed supervisor mode) and {nB} group B tasks "
               "(single-session), each in state `done`. Only what the numbers show is stated.")
    out.append("")
    if nA == 0 or nB == 0:
        which = "A" if nA == 0 else "B"
        out.append(f"**No comparison is possible: group {which} has no task in state `done`.**")
        for g in (GROUP_A, GROUP_B):
            if report.n[g]:
                out.append("")
                out += single_group_line(report, g)
        out.append("")
        return out + bottom_line_tail(report)

    def line(label, key, fmt):
        sa, sb = report.stat(GROUP_A, key), report.stat(GROUP_B, key)
        return (f"- **{label}**: mean A {fmt(sa['mean'])} (n={sa['n']}) vs B {fmt(sb['mean'])} (n={sb['n']}), "
                f"A/B {f_ratio(ratio(sa['mean'], sb['mean']))}; median A {fmt(sa['median'])} (n={sa['n']}) vs "
                f"B {fmt(sb['median'])} (n={sb['n']}), A/B {f_ratio(ratio(sa['median'], sb['median']))}.")

    out.append(line("List cost per task (API-price equivalent)", "list_cost", f_usd))
    out.append(line("Billed cost per task", "cost", f_usd))
    out.append(line("Total tokens per task", "total_tokens", f_tokens))
    out.append(line("Wall-clock per task, created to finished (H:MM:SS)", "duration_created_to_finished_s", f_dur))
    sa, sb = report.stat(GROUP_A, "num_subagents"), report.stat(GROUP_B, "num_subagents")
    zeros = {g: sum(1 for r in report.cmp[g] if r["num_subagents"] == 0) for g in (GROUP_A, GROUP_B)}
    out.append(f"- **Sub-agents per task**: mean A {f_mean_count(sa['mean'])} (n={sa['n']}) vs B {f_mean_count(sb['mean'])} "
               f"(n={sb['n']}); median A {f_count(sa['median'])} vs B {f_count(sb['median'])}; tasks with none: "
               f"A {zeros[GROUP_A]} of {nA}, B {zeros[GROUP_B]} of {nB}.")
    out.append("")
    return out + bottom_line_tail(report)


def single_group_line(report, g):
    s = {k: report.stat(g, k) for k in ("list_cost", "cost", "total_tokens", "duration_created_to_finished_s")}
    n = report.n[g]
    return [f"Group {g} on its own (n={n}): mean list cost {f_usd(s['list_cost']['mean'])}, median "
            f"{f_usd(s['list_cost']['median'])}; mean total tokens {f_tokens(s['total_tokens']['mean'])}; mean "
            f"duration {f_dur(s['duration_created_to_finished_s']['mean'])}, median "
            f"{f_dur(s['duration_created_to_finished_s']['median'])}."]


def bottom_line_tail(report):
    buggy = report.by_group(EXCLUDED_BUGGY)
    buggy_done = [r for r in buggy if r["state"] == TERMINAL_STATE]
    bd, bb = describe(column(buggy_done, "list_cost")), report.stat(GROUP_B, "list_cost")
    plan = report.by_group(PLAN_MODE)
    unresolved = report.by_group(UNRESOLVED)
    flight = {g: sum(1 for r in report.task_rows if r["group"] == g and r["state"] != TERMINAL_STATE)
              for g in (GROUP_A, GROUP_B)}
    out = ["Reported separately, not in the figures above:", "",
           f"- Old buggy supervisor mode: n={len(buggy)} tasks, total billed cost "
           f"{f_usd(math.fsum(column(buggy, 'cost')))} and total list cost "
           f"{f_usd(math.fsum(column(buggy, 'list_cost')))}; per task in state `done` (n={len(buggy_done)}), mean "
           f"list cost {f_usd(bd['mean'])} and median {f_usd(bd['median'])}, against group B's mean "
           f"{f_usd(bb['mean'])} and median {f_usd(bb['median'])} (n={bb['n']}); details in the sanity check below.",
           f"- Plan mode: n={len(plan)} tasks. Session record missing: n={len(unresolved)} tasks.",
           f"- Still in flight, left out for that reason alone: A {flight[GROUP_A]}, B {flight[GROUP_B]}.", ""]
    out.append("**Caveats.**")
    out.append("")
    for g in (GROUP_A, GROUP_B):
        note = small_note(g, report.n[g])
        if note:
            out.append(f"- Small sample: {note}.")
    window = fix_window_note(report)
    if window:
        out.append(f"- {window}")
    out.append("- Tasks were not assigned to the modes at random, and the two groups cover different periods; "
               "these figures describe the groups as they happened and do not isolate the effect of the mode "
               "(see [What this cannot separate](#what-this-cannot-separate)).")
    out.append("- Both the mean and the median are given because single expensive or long tasks can move the "
               "mean; the tables also show the minimum and maximum.")
    out.append("")
    return out


def f_elapsed(seconds):
    if seconds is None:
        return NA
    hours = seconds / 3600
    return f"{hours:.1f} hours" if hours < 48 else f"{hours / 24:.1f} days"


def fix_window_note(report):
    """How long the fix has been in force at the newest usage row: the room group A has to exist in."""
    last = report.quality.get("usage_last_ts")
    if last is None:
        return None
    elapsed = seconds_between(SUPERVISOR_FIX, last)
    if elapsed is None:
        return (f"The newest usage row in the data ({iso_utc(last)}) is older than the fix "
                f"({SUPERVISOR_FIX_ISO}), so no group A task can exist.")
    return (f"The fix ({SUPERVISOR_FIX_ISO}) is {f_elapsed(elapsed)} before the newest usage row in the data "
            f"({iso_utc(last)}); group A can only hold tasks created in that window.")


def counts_section(report):
    out = ["## Classification and counts", ""]
    rows = []
    totals = [0, 0, 0, 0]
    for g in GROUPS:
        members = report.by_group(g)
        done = sum(1 for r in members if r["state"] == TERMINAL_STATE)
        review = sum(1 for r in members if r["state"] == "review")
        other = len(members) - done - review
        rows.append([GROUP_TITLES[g], len(members), done, review, other])
        for i, v in enumerate((len(members), done, review, other)):
            totals[i] += v
    rows.append(["**All tasks**", *[f"**{v}**" for v in totals]])
    out += md_table(["Group", "Tasks", "State `done`", "State `review`", "Other states"], rows)
    out += ["",
            "Only `done` tasks in groups A and B enter the comparison. `review` is a task whose agent has finished "
            "and which waits for the user to verify it; it is counted as in flight here (a variant that counts it "
            "as finished is under the secondary checks).", ""]
    return out


def results_section(report):
    nA, nB = report.n[GROUP_A], report.n[GROUP_B]
    out = ["## Results: group A against group B", "",
           f"Per-task figures over tasks in state `done`: group A n = {nA}, group B n = {nB}. "
           "A figure computed over fewer tasks shows its own n. Token counts are tokens; costs are US dollars; "
           "durations are H:MM:SS.", ""]
    head = ["Measure", "Statistic", f"A: fixed supervisor (n={nA})", f"B: single-session (n={nB})"]
    rows = []
    rows += stat_lines(report, "Total tokens", "total_tokens", f_tokens, with_sum=True)
    rows += stat_lines(report, "Input tokens", "input_tokens", f_tokens, names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Output tokens", "output_tokens", f_tokens, names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Cache-read tokens", "cache_read_tokens", f_tokens, names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Cache-write tokens", "cache_write_tokens", f_tokens, names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Billed cost", "cost", f_usd, with_sum=True)
    rows += stat_lines(report, "List cost (API prices)", "list_cost", f_usd, with_sum=True)
    rows += stat_lines(report, "Wall-clock, created to finished", "duration_created_to_finished_s", f_dur)
    rows += stat_lines(report, "Wall-clock, started to finished (secondary)", "duration_started_to_finished_s",
                       f_dur, names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Sub-agents per task", "num_subagents", f_count,
                       names=("mean", "median", "stdev", "max"))
    zeros = {g: sum(1 for r in report.cmp[g] if r["num_subagents"] == 0) for g in (GROUP_A, GROUP_B)}
    rows.append(["", "tasks with exactly 0",
                 f"{zeros[GROUP_A]} of {nA}" + (f" ({f_pct(zeros[GROUP_A] / nA)})" if nA else ""),
                 f"{zeros[GROUP_B]} of {nB}" + (f" ({f_pct(zeros[GROUP_B] / nB)})" if nB else "")])
    out += md_table(head, rows, ["l", "l", "r", "r"])
    out += ["", "### The top-level session on its own, and the sub-agents together", "",
            "The top-level (\"supervisor\") session's own usage and the sub-agents' combined usage, per task. In "
            "group B the top-level session is the whole task apart from any sub-agents.", ""]
    rows = []
    rows += stat_lines(report, "Top-level session: total tokens", "top_total_tokens", f_tokens,
                       names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Top-level session: billed cost", "top_cost", f_usd, names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Top-level session: list cost", "top_list_cost", f_usd,
                       names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Top-level session: duration (updated - created)", "top_duration_s", f_dur,
                       names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Top-level session: first to last usage row", "top_usage_span_s", f_dur,
                       names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Top-level session: compactions", "top_compactions", f_count,
                       names=("mean", "median", "max"))
    rows += stat_lines(report, "Sub-agents combined: total tokens", "sub_total_tokens", f_tokens,
                       names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Sub-agents combined: billed cost", "sub_cost", f_usd, names=("mean", "median", "stdev"))
    rows += stat_lines(report, "Sub-agents combined: list cost", "sub_list_cost", f_usd,
                       names=("mean", "median", "stdev"))
    out += md_table(head, rows, ["l", "l", "r", "r"])
    out.append("")
    return out


COMPARE_METRICS = (("Billed cost", "cost", f_usd),
                   ("List cost", "list_cost", f_usd),
                   ("Total tokens", "total_tokens", f_tokens),
                   ("Duration, created to finished", "duration_created_to_finished_s", f_dur))


def ratio_table(first_rows, second_rows, first, second, metrics=COMPARE_METRICS):
    """Rows of per-task means and medians of two sets of tasks, with FIRST / SECOND beside them."""
    rows = []
    for label, key, fmt in metrics:
        sa, sb = describe(column(first_rows, key)), describe(column(second_rows, key))
        rows.append([label, fmt(sa["mean"]), fmt(sb["mean"]), f_ratio(ratio(sa["mean"], sb["mean"])),
                     fmt(sa["median"]), fmt(sb["median"]), f_ratio(ratio(sa["median"], sb["median"])),
                     f"{first} {sa['n']} / {second} {sb['n']}"])
    return md_table(["Measure", f"{first} mean", f"{second} mean", f"{first}/{second} means",
                     f"{first} median", f"{second} median", f"{first}/{second} medians", "n"], rows)


def comparison_section(report):
    nA, nB = report.n[GROUP_A], report.n[GROUP_B]
    out = ["## Comparison: A / B", "",
           "Ratio of group A's figure to group B's, per task, over tasks in state `done`. "
           "\"n\" is the number of tasks behind each side.", ""]
    out += ratio_table(report.cmp[GROUP_A], report.cmp[GROUP_B], "A", "B")
    out += ["", f"Group A n = {nA}; group B n = {nB}.", ""]
    return out


def subagent_section(report):
    sa, sb = report.subs[GROUP_A], report.subs[GROUP_B]
    out = ["## Sub-agent sessions", "",
           "One row per sub-agent session (not per task) of the tasks in the comparison: "
           f"A has {len(sa)}, B has {len(sb)}. Durations are the session record's `updated` minus `created`.", ""]
    head = ["Measure", "Statistic", f"A (sessions={len(sa)})", f"B (sessions={len(sb)})"]
    rows = []
    rows += sub_stat_lines(report, "Total tokens", "total_tokens", f_tokens)
    rows += sub_stat_lines(report, "Billed cost", "cost", f_usd)
    rows += sub_stat_lines(report, "List cost", "list_cost", f_usd)
    rows += sub_stat_lines(report, "Duration", "duration_s", f_dur)
    rows += sub_stat_lines(report, "Compactions", "compactions", f_count, names=("mean", "median"))
    out += md_table(head, rows, ["l", "l", "r", "r"])
    out += ["", "What those sessions are:", ""]
    comp = {g: report.cmp[g] for g in (GROUP_A, GROUP_B)}
    rows = []
    for label, key in (("Sub-agent sessions", "num_subagents"),
                       ("of which seed sessions", "num_seed_sessions"),
                       ("of which named by a plan step", "num_plan_step_workers")):
        rows.append([label, f"{sum(r[key] for r in comp[GROUP_A]):,}", f"{sum(r[key] for r in comp[GROUP_B]):,}"])
    share = {}
    for g in (GROUP_A, GROUP_B):
        total = math.fsum(column(comp[g], "list_cost"))
        share[g] = ratio(math.fsum(column(comp[g], "sub_list_cost")), total)
    rows.append(["Sub-agents' share of the group's list cost", f_pct(share[GROUP_A]), f_pct(share[GROUP_B])])
    out += md_table(["", f"A (tasks={report.n[GROUP_A]})", f"B (tasks={report.n[GROUP_B]})"], rows)
    out += ["", "The other sub-agent sessions are workers started without a plan step (`spawn_agent`), "
            "merge-queue conflict resolvers, and anything else of kind `subagent` or `fork`; the data do not "
            "mark which is which.", ""]
    return out


def buggy_section(report):
    members = report.by_group(EXCLUDED_BUGGY)
    done = [r for r in members if r["state"] == TERMINAL_STATE]
    out = ["## Sanity check: old buggy supervisor mode (excluded)", "",
           "Supervisor flag on, top-level session created before "
           f"{SUPERVISOR_FIX_ISO}. Left out of A and B; summarised here as a check on the known cache incident.", ""]
    rows = []
    for label, rs in (("All tasks", members), ("State `done`", done),
                      ("Not done (in flight)", [r for r in members if r["state"] != TERMINAL_STATE])):
        rows.append([label, len(rs), f_usd(math.fsum(column(rs, "cost"))), f_usd(math.fsum(column(rs, "list_cost"))),
                     f_tokens(sum(column(rs, "total_tokens"))), f"{sum(column(rs, 'num_subagents')):,}"])
    out += md_table(["Tasks", "n", "Total billed cost", "Total list cost", "Total tokens", "Sub-agent sessions"], rows)
    late = sum(1 for r in members if (parse_ts(r["task_started_utc"]) or EPOCH_MIN) >= SUPERVISOR_FIX)
    out += ["", f"Of these {len(members)} tasks, {late} started at or after the fix although their session was "
            "created before it; the rule puts them here, and part of their work ran after the fix.",
            "", "Per task, tasks in state `done`, beside A and B:", ""]
    cols = [(EXCLUDED_BUGGY, done), (GROUP_A, report.cmp[GROUP_A]), (GROUP_B, report.cmp[GROUP_B])]
    head = ["Per task", "Statistic"] + [f"{'Excluded (buggy)' if g == EXCLUDED_BUGGY else g} (n={len(rs)})"
                                         for g, rs in cols]
    rows = []
    for label, key, fmt in (("List cost", "list_cost", f_usd), ("Total tokens", "total_tokens", f_tokens),
                            ("Cache-read tokens", "cache_read_tokens", f_tokens),
                            ("Cache-write tokens", "cache_write_tokens", f_tokens),
                            ("Sub-agents", "num_subagents", f_count),
                            ("Duration, created to finished", "duration_created_to_finished_s", f_dur)):
        for i, name in enumerate(("mean", "median")):
            rows.append([label if i == 0 else "", name]
                        + [cell(describe(column(rs, key)), name, fmt, len(rs)) for _, rs in cols])
    out += md_table(head, rows, ["l", "l", "r", "r", "r"])
    out += ["", "Excluded group against group B, per task, tasks in state `done`:", ""]
    out += ratio_table(done, report.cmp[GROUP_B], "Excluded", "B", COMPARE_METRICS + (
        ("Cache-read tokens", "cache_read_tokens", f_tokens), ("Cache-write tokens", "cache_write_tokens", f_tokens)))
    out.append("")
    return out


def set_aside_section(report):
    out = ["## Set aside", ""]
    rows = []
    for g in (PLAN_MODE, UNRESOLVED):
        members = report.by_group(g)
        done = [r for r in members if r["state"] == TERMINAL_STATE]
        rows.append([GROUP_TITLES[g], len(members), len(done), f_usd(math.fsum(column(members, "cost"))),
                     f_usd(math.fsum(column(members, "list_cost")))])
    out += md_table(["Group", "Tasks", "State `done`", "Total billed cost", "Total list cost"], rows)
    plan_members = report.by_group(PLAN_MODE)
    overlap = sum(1 for r in plan_members if r["supervisor_flag"] == "on")
    out += ["", f"Plan mode tasks whose supervisor flag is also on: {overlap} of {len(plan_members)} (they are "
            "counted as Plan mode only).", ""]
    unresolved = report.by_group(UNRESOLVED)
    before = sum(1 for r in unresolved if (parse_ts(r["task_created_utc"]) or EPOCH_MIN) < SUPERVISOR_INTRODUCED)
    out += [f"Tasks with no session record: {len(unresolved)}, of which {before} were created before supervisor mode "
            f"existed (group B by date alone) and {len(unresolved) - before} later. Their sub-agents cannot be "
            "found, so their totals are not known to be complete and they are in neither group.", ""]
    return out


def in_flight_section(report):
    out = ["## Tasks still in flight (left out of the comparison)", ""]
    states = sorted({r["state"] or "(no state)" for r in report.task_rows if r["state"] != TERMINAL_STATE})
    rows = []
    for g in (GROUP_A, GROUP_B):
        members = [r for r in report.by_group(g) if r["state"] != TERMINAL_STATE]
        counts = Counter(r["state"] or "(no state)" for r in members)
        rows.append([GROUP_TITLES[g], len(members)] + [counts[s] for s in states])
    out += md_table(["Group", "Not done"] + states, rows) if states else ["No task is in flight."]
    out += ["", "These tasks reached no terminal state in the data, so their totals are not complete.", ""]
    return out


def secondary_section(report):
    out = ["## Secondary checks", "", "Not part of the comparison above; they show how much its choices matter.", ""]
    gs = (GROUP_A, GROUP_B)

    out += ["### Outcome of the tasks in the comparison", ""]
    outcomes = sorted({r["outcome"] or "(none)" for g in gs for r in report.cmp[g]})
    rows = []
    for o in outcomes:
        rows.append([f"`{o}`"] + [sum(1 for r in report.cmp[g] if (r["outcome"] or "(none)") == o) for g in gs])
    out += md_table(["Outcome", f"A (n={report.n[GROUP_A]})", f"B (n={report.n[GROUP_B]})"], rows) if rows else \
        ["No task in the comparison."]
    reopened = {g: sum(1 for r in report.cmp[g] if r["reopened"]) for g in gs}
    out += ["", f"Tasks that were reopened after finishing: A {reopened[GROUP_A]}, B {reopened[GROUP_B]}.", ""]

    out += ["### Counting tasks that await review as finished", ""]
    settled = {g: [r for r in report.task_rows if r["group"] == g and r["state"] in SETTLED_STATES] for g in gs}
    head = ["Measure", "Statistic", f"A (n={len(settled[GROUP_A])})", f"B (n={len(settled[GROUP_B])})"]
    rows = []
    for label, key, fmt in (("List cost", "list_cost", f_usd), ("Total tokens", "total_tokens", f_tokens),
                            ("Duration, created to finished", "duration_created_to_finished_s", f_dur)):
        for i, name in enumerate(("mean", "median")):
            rows.append([label if i == 0 else "", name]
                        + [cell(describe(column(settled[g], key)), name, fmt, len(settled[g])) for g in gs])
    out += md_table(head, rows, ["l", "l", "r", "r"])
    out += ["", "Tasks in state `done` or `review`. A task in review may still be sent back for more work.", ""]

    out += ["### Billing mode of the usage rows in the comparison", ""]
    rows = []
    for label, key in (("api", "rows_api"), ("subscription", "rows_subscription"), ("extra-usage", "rows_extra_usage"),
                       ("other value", "rows_billing_other"), ("not recorded", "rows_billing_blank")):
        cells = []
        for g in gs:
            total = sum(column(report.cmp[g], "usage_rows"))
            n = sum(column(report.cmp[g], key))
            cells.append(f"{n:,}" + (f" ({f_pct(n / total)})" if total else ""))
        rows.append([label] + cells)
    rows.append(["all usage rows"] + [f"{sum(column(report.cmp[g], 'usage_rows')):,}" for g in gs])
    rows.append(["rows without a list cost (counted at their cost)"]
                + [f"{sum(column(report.cmp[g], 'rows_list_cost_blank')):,}" for g in gs])
    rows.append(["rows with tokens but priced at $0 (no price known for the model)"]
                + [f"{sum(column(report.cmp[g], 'rows_priced_at_zero')):,} rows, "
                   f"{sum(column(report.cmp[g], 'tokens_priced_at_zero')):,} tokens" for g in gs])
    out += md_table(["Rows", f"A (n={report.n[GROUP_A]})", f"B (n={report.n[GROUP_B]})"], rows)
    out += ["", "Billed cost is 0 for calls paid under a subscription plan; list cost is the like-for-like measure. "
            "A model the harness has no price for is recorded at $0 whatever the tokens, which understates the "
            "dollar figures of whatever used it.", ""]

    out += ["### Usage of `btw` and `internal` sessions under the tasks (not in the task totals)", ""]
    rows = []
    for g in gs:
        rs = report.cmp[g]
        other = math.fsum(column(rs, "other_list_cost"))
        main = math.fsum(column(rs, "list_cost"))
        rows.append([f"{g} (n={len(rs)})", f"{sum(column(rs, 'num_other_descendants')):,}",
                     f"{sum(column(rs, 'other_usage_rows')):,}", f_usd(other), f_usd(main), f_pct(ratio(other, main))])
    out += md_table(["Group", "btw/internal sessions", "Usage rows", "Their list cost", "Tasks' list cost",
                     "Share of the tasks' list cost"], rows)
    out += ["", "Only the newest internal sessions are kept by the harness, so this is a lower bound.", ""]

    out += ["### Where all usage went", ""]
    rows = []
    total_rows = total_list = 0
    for key, (label, agg) in report.attribution.items():
        rows.append([label, f"{agg.rows:,}", f_tokens(agg.tokens), f_usd(agg.cost), f_usd(agg.list_cost)])
        total_rows += agg.rows
        total_list += agg.list_cost
    rows.append(["**all usage rows**", f"**{total_rows:,}**", "", "", f"**{f_usd(total_list)}**"])
    out += md_table(["Usage rows belonging to", "Rows", "Tokens", "Billed cost", "List cost"], rows)
    out.append("")

    out += ["### When the tasks in the comparison were created (UTC)", ""]
    rows = []
    for g in gs:
        created = [parse_ts(r["task_created_utc"]) for r in report.cmp[g]]
        created = [c for c in created if c is not None]
        rows.append([f"{g} (n={report.n[g]})", f_day(min(created) if created else None),
                     f_day(max(created) if created else None)])
    out += md_table(["Group", "First created", "Last created"], rows)
    out.append("")
    return out


def quality_section(report):
    q = report.quality
    out = ["## Data-quality notes", ""]
    notes = []

    def add(count, label, why):
        if count:
            notes.append(f"- {label}: {count:,}. {why}")

    add(q["usage_rows_list_cost_blank"], "Usage rows without a list cost",
        "They count at their cost, as the harness does (rows written before the column existed).")
    add(q["usage_rows_priced_at_zero"], "Usage rows with tokens but a list cost of 0",
        "The harness records 0 for a model it has no price for, so the dollar figures understate that usage.")
    add(q["usage_blank_token_fields"], "Blank token fields in usage rows", "Counted as 0.")
    add(q["usage_blank_cost_fields"], "Blank cost fields in usage rows", "Counted as 0.")
    add(q["duplicate_session_ids"], "Session ids that appear more than once in `sessions.csv`", "The last row wins.")
    add(q["duplicate_task_ids"], "Task ids that appear more than once in `tasks.csv`", "The first row wins.")
    add(q["task_setting_differs_from_session_flag"],
        "Tasks whose own `supervisor` setting differs from their session's flag", "The session's flag is used.")
    add(q["supervisor_on_before_it_existed"], "Tasks with the supervisor flag on although their session predates "
        "supervisor mode", "They are group B by the rule.")
    add(q["plan_flag_before_plan_mode_existed"], "Tasks with the Plan-mode flag although they predate Plan mode",
        "They are set aside as Plan mode.")
    add(q["supervisor_judge_still_pending"], "Tasks whose session is still marked as awaiting the supervisor judge",
        "Their flag is the default, not a judged value.")
    add(q["done_tasks_without_finished_time"], "Tasks in state `done` with no `finished` time",
        "They are out of the duration figures only.")
    add(q["tasks_finished_before_created"], "Tasks with a `finished` time earlier than `created`",
        "They are out of the duration figures only.")
    add(q["adopted_tasks"], "Tasks adopted from a sub-agent session", "Their top-level session has a parent.")
    add(q["tasks_sharing_a_top_session"], "Tasks that share their top-level session with another task",
        "Their usage is counted for each.")
    add(q["tasks_with_shared_sessions"], "Tasks with a session that another task's totals also include",
        "An adopted task's session is also a sub-agent of the task that started it, so its usage is in both.")
    add(q["subagent_sessions_outside_any_task"], "Sub-agent or fork sessions that belong to no task",
        "Side conversations outside the task board, or sessions whose parent was deleted.")
    cmp_rows = report.cmp[GROUP_A] + report.cmp[GROUP_B]
    add(sum(1 for r in cmp_rows if r["usage_rows"] == 0), "Tasks in the comparison with no usage rows at all",
        "Kept; their cost is 0.")
    if not q.get("usage_has_list_cost_column"):
        notes.append("- `usage_rows.csv` has no `list_cost` column: list cost equals billed cost throughout.")
    if not q.get("usage_has_billing_column"):
        notes.append("- `usage_rows.csv` has no `billing` column: the billing breakdown counts every row as not recorded.")
    if not q.get("sessions_have_compactions"):
        notes.append("- `sessions.csv` has no `compactions` column: compaction figures are not available.")
    if not q.get("plan_steps_file"):
        notes.append("- `plan_steps.csv` was not found: sub-agents named by a plan step are not counted.")
    sessions_info = report.manifest.get("sessions")
    unparseable = sessions_info.get("unparseable") if isinstance(sessions_info, dict) else None
    if isinstance(unparseable, list) and unparseable:
        notes.append(f"- Session record files the extraction could not parse, and which are absent: {len(unparseable)}.")
    out += notes if notes else ["No data-quality issue was found by these checks."]
    out.append("")
    return out


# --------------------------------------------------------------------------
# Driver

def load_and_analyse(in_dir, now):
    quality = Counter()
    usage = load_usage(in_dir / "usage_rows.csv", quality)
    sessions = load_sessions(in_dir / "sessions.csv", quality)
    tasks = load_tasks(in_dir / "tasks.csv", quality)
    plan_workers = load_plan_workers(in_dir / "plan_steps.csv", quality)
    manifest = load_manifest(in_dir / "manifest.json")
    quality["sessions"] = len(sessions)
    quality["tasks"] = len(tasks)
    children = child_index(sessions)
    task_rows, sub_rows, attribution = analyse(tasks, sessions, children, usage, plan_workers, quality)
    return Report(task_rows, sub_rows, attribution, quality, manifest, now)


def parse_args(argv):
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="See the module docstring for the classification rule.")
    ap.add_argument("--in-dir", default=str(DEFAULT_IN_DIR),
                    help="directory with the extraction's CSVs (default %(default)s)")
    ap.add_argument("--csv-out-dir", default=None,
                    help="where classified_tasks.csv and subagents.csv go (default: --in-dir)")
    ap.add_argument("--out", default=str(DEFAULT_OUT),
                    help="the Markdown report to write (default %(default)s)")
    ap.add_argument("--methodology-only", action="store_true",
                    help="write the report's method and a notice that it holds no results; read no data")
    ap.add_argument("--force", action="store_true",
                    help="let --methodology-only replace a report that holds results")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--self-test", action="store_true",
                    help="check the arithmetic on a small synthetic world with known answers")
    return ap.parse_args(argv)


def run(args):
    out = Path(args.out).expanduser()
    if args.methodology_only:
        if out.exists() and not args.force:
            existing = out.read_text(encoding="utf-8", errors="replace")
            if PLACEHOLDER_MARK not in existing:
                print(f"error: {out} holds results; --methodology-only would replace them (use --force)",
                      file=sys.stderr)
                return 2
        write_text(out, placeholder_report())
        if not args.quiet:
            print(f"wrote {out} (method only, no results)")
        return 0

    in_dir = Path(args.in_dir).expanduser()
    csv_dir = Path(args.csv_out_dir).expanduser() if args.csv_out_dir else in_dir
    try:
        report = load_and_analyse(in_dir, dt.datetime.now(UTC))
    except InputError as err:
        print(f"error: {err}", file=sys.stderr)
        print("run scripts/analysis/extract_usage_data.py first (it writes usage_rows.csv, sessions.csv, "
              "tasks.csv and plan_steps.csv)", file=sys.stderr)
        return 2
    write_csv(csv_dir / "classified_tasks.csv", TASK_OUT_COLUMNS, report.task_rows)
    write_csv(csv_dir / "subagents.csv", SUB_OUT_COLUMNS, report.sub_rows)
    write_text(out, render_report(report))
    if not args.quiet:
        counts = Counter(r["group"] for r in report.task_rows)
        print(f"{len(report.task_rows)} tasks: " + ", ".join(f"{g} {counts[g]}" for g in GROUPS))
        print(f"in the comparison: A {report.n[GROUP_A]}, B {report.n[GROUP_B]}")
        print(f"wrote {csv_dir / 'classified_tasks.csv'}, {csv_dir / 'subagents.csv'}")
        print(f"wrote {out}")
    return 0


# --------------------------------------------------------------------------
# Self-test: a small synthetic world whose answers were worked out by hand.
# Every id and number is made up.

def _utc(*parts):
    return dt.datetime(*parts, tzinfo=UTC).timestamp()


def dump_world(root, sessions, tasks, usage, plan_steps=()):
    """Write the four input CSVs from lists of row dicts."""
    def dump(name, columns, rows):
        with open(root / name, "w", newline="", encoding="utf-8") as fh:
            writer = csv.writer(fh, lineterminator="\n")
            writer.writerow(columns)
            for row in rows:
                writer.writerow([row.get(c, "") for c in columns])

    dump("sessions.csv", ("session_id", "kind", "parent_id", "supervisor", "seed", "created", "updated", "status",
                          "has_nodes_file", "compactions"), sessions)
    dump("tasks.csv", ("task_id", "session_id", "state", "outcome", "created", "started", "finished",
                       "supervisor_setting", "plan", "adopted", "session_found"), tasks)
    dump("usage_rows.csv", ("id", "ts", "session", "input", "output", "cache_read", "cache_write", "cost",
                            "list_cost", "billing"), usage)
    dump("plan_steps.csv", ("session_id", "step_id", "worker_session_id", "previous_session_id"), plan_steps)


def build_world(root):
    """Write a synthetic extraction under ROOT and return the ids used."""
    intro = _utc(2026, 10, 8, 19, 24, 17)    # 2026-10-08T15:24:17-04:00
    fix = _utc(2026, 10, 12, 3, 55, 53)      # 2026-10-11T23:55:53-04:00
    root.mkdir(parents=True, exist_ok=True)
    sessions, tasks, usage = [], [], []

    def sess(sid, kind="main", parent="", flag="", created=0.0, updated=None, seed=False, compactions=0,
             nodes=True):
        sessions.append({"session_id": sid, "kind": kind, "parent_id": parent, "supervisor": flag,
                         "seed": "true" if seed else "", "created": created,
                         "updated": "" if updated is None else updated, "status": "idle",
                         "has_nodes_file": "true" if nodes else "false",
                         "compactions": "" if compactions is None else compactions})

    def task(tid, sid, state, created, finished=None, started=None, outcome="merged", setting="", plan="",
             found=True):
        tasks.append({"task_id": tid, "session_id": sid, "state": state, "outcome": outcome, "created": created,
                      "started": "" if started is None else started, "finished": "" if finished is None else finished,
                      "supervisor_setting": setting, "plan": plan, "session_found": "true" if found else "false"})

    def use(sid, ts, i, o, cr, cw, cost, list_cost, billing):
        usage.append({"id": len(usage) + 1, "ts": ts, "session": sid, "input": i, "output": o, "cache_read": cr,
                      "cache_write": cw, "cost": cost, "list_cost": list_cost, "billing": billing})

    # --- Group A, tA1: created exactly at the fix.  Five sub-agents: a worker, a fork, a seed, the seed's
    # fork worker, and a worker's own worker; plus a btw and an internal session that are not sub-agents.
    sess("sA1", flag="true", created=fix, updated=fix + 2000, compactions=2)
    sess("sA1w1", "subagent", "sA1", created=fix + 10, updated=fix + 110, compactions=1)
    sess("sA1f1", "fork", "sA1", created=fix + 20, updated=fix + 220, compactions=0)
    sess("sA1seed", "subagent", "sA1", created=fix + 30, updated=fix + 330, seed=True, compactions=None)
    sess("sA1w2", "subagent", "sA1seed", created=fix + 40, updated=fix + 440, compactions=0)
    sess("sA1gc", "subagent", "sA1w1", created=fix + 50, updated=None, compactions=None, nodes=False)
    sess("sA1btw", "btw", "sA1", created=fix + 60, updated=fix + 61)
    sess("sA1int", "internal", "sA1", created=fix + 70, updated=fix + 71)
    task("tA1", "sA1", "done", fix - 1, finished=fix + 1800, started=fix + 10, setting="true")
    use("sA1", fix + 5, 100, 10, 1000, 50, 1.00, 1.50, "api")
    use("sA1", fix + 1700, 200, 20, 2000, 0, 2.00, 2.50, "api")
    use("sA1w1", fix + 100, 10, 1, 100, 0, 0.0, 0.40, "subscription")
    use("sA1f1", fix + 200, 20, 2, 200, 0, 0.5, "", "")
    use("sA1seed", fix + 300, 5, 0, 500, 0, 0.1, 0.1, "api")
    use("sA1w2", fix + 400, 1, 1, 1, 1, 0.2, 0.2, "extra-usage")
    use("sA1btw", fix + 500, 1000, 0, 0, 0, 9.0, 9.0, "api")
    use("sA1int", fix + 600, 7, 0, 0, 0, 0.25, 0.25, "api")
    # --- Group A, tA2: no sub-agents at all (kept).
    sess("sA2", flag="true", created=fix + 3600, updated=fix + 4300, compactions=0)
    task("tA2", "sA2", "done", fix + 3600, finished=fix + 4200, started=fix + 3601)
    use("sA2", fix + 3700, 50, 5, 500, 5, 0.5, 0.6, "api")
    # --- Group A but not done: in flight (active) and awaiting review.
    sess("sAin", flag="true", created=fix + 5000, updated=fix + 5100)
    task("tAin", "sAin", "active", fix + 5000, started=fix + 5001, outcome="")
    use("sAin", fix + 5050, 1, 1, 1, 1, 0.3, 0.3, "api")
    sess("sArev", flag="true", created=fix + 5500, updated=fix + 6000)
    task("tArev", "sArev", "review", fix + 5500, finished=fix + 6000, started=fix + 5501)
    # --- Old buggy supervisor mode: created one second before the fix.
    sess("sX1", flag="true", created=fix - 1, updated=fix + 900)
    task("tX1", "sX1", "done", fix - 1, finished=fix + 899)
    use("sX1", fix - 0.5, 100, 0, 0, 0, 7.0, 7.0, "api")
    sess("sX2", flag="true", created=fix - 100, updated=fix - 50)
    task("tX2", "sX2", "active", fix - 100, started=fix - 99, outcome="")
    use("sX2", fix - 80, 10, 0, 0, 0, 1.0, 1.0, "api")
    # --- Plan mode, including one that is also supervised and one that predates Plan mode.
    sess("sP1", flag="true", created=fix + 100, updated=fix + 200)
    task("tP1", "sP1", "done", fix + 100, finished=fix + 200, plan="true")
    sess("sP2", flag="", created=intro - 86400, updated=intro - 80000)
    task("tP2", "sP2", "done", intro - 86400, finished=intro - 80000, plan="true")
    # --- Session record missing: set aside, whatever its date.
    task("tU1", "sMissing", "done", fix + 200, finished=fix + 300, found=False)
    task("tU2", "sMissing2", "done", intro - 5, finished=intro + 5, found=False)
    # --- Group B.
    sess("sB1", flag="", created=intro - 86400, updated=intro - 86400 + 3600, compactions=3)
    sess("sB1w", "subagent", "sB1", created=intro - 86400 + 10, updated=intro - 86400 + 60, compactions=0)
    task("tB1", "sB1", "done", intro - 86400, finished=intro - 86400 + 3600, started=intro - 86400 + 1)
    use("sB1", intro - 86000, 1000, 100, 10000, 500, 5.0, "", "")
    use("sB1w", intro - 85990, 10, 0, 0, 0, 0.01, "", "")
    sess("sB2", flag="", created=intro + 86400, updated=intro + 86400 + 1100, compactions=0)
    task("tB2", "sB2", "done", intro + 86400, finished=intro + 86400 + 1200, outcome="end-turn")
    use("sB2", intro + 86500, 200, 20, 2000, 100, 1.0, 1.0, "api")
    sess("sB3", flag="false", created=fix + 7200, updated=fix + 7200 + 1900, compactions=1)
    task("tB3", "sB3", "done", fix + 7200, finished=fix + 7200 + 1800, setting="false")
    use("sB3", fix + 7300, 300, 30, 3000, 0, 0.0, 2.0, "subscription")
    sess("sB4", flag="", created=intro, updated=intro + 650, compactions=0)
    task("tB4", "sB4", "done", intro, finished=intro + 600)
    use("sB4", intro + 10, 100, 0, 0, 0, 0.3, 0.3, "api")
    sess("sB5", flag="true", created=intro - 3600, updated=intro - 3250, compactions=0)   # anomaly: on before it existed
    task("tB5", "sB5", "done", intro - 3600, finished=intro - 3300)
    use("sB5", intro - 3500, 50, 0, 0, 0, 0.1, 0.1, "api")
    sess("sB6", flag="", created=intro - 7200, updated=intro - 7000, nodes=False)
    task("tB6", "sB6", "done", intro - 7200)           # no finished time, no usage rows
    sess("sBin", flag="", created=fix + 8000, updated=fix + 8000)
    task("tBin", "sBin", "pending", fix + 8000, outcome="")
    sess("sBref", flag="", created=fix + 8100, updated=fix + 8100)
    task("tBref", "sBref", "refining", fix + 8100, outcome="")
    # --- Usage that belongs to no task.
    sess("sFree", flag="", created=fix + 9000, updated=fix + 9100)
    use("sFree", fix + 9050, 1, 1, 1, 1, 2.0, 2.0, "api")
    use("sGone", fix + 9060, 1, 0, 0, 0, 0.4, 0.4, "api")

    dump_world(root, sessions, tasks, usage,
               [{"session_id": "sA1", "step_id": "s1", "worker_session_id": "sA1w1"},
                {"session_id": "sA1", "step_id": "s2", "worker_session_id": "sA1w2"}])
    return {"session_ids": [s["session_id"] for s in sessions] + ["sMissing", "sMissing2", "sGone"],
            "task_ids": [t["task_id"] for t in tasks], "intro": intro, "fix": fix}


def self_test():
    failures = []

    def check(name, got, want):
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    def close(name, got, want, tol=1e-9):
        if got is None or want is None:
            check(name, got, want)
        elif abs(got - want) > tol * max(1.0, abs(want)):
            failures.append(f"{name}: got {got!r}, want {want!r}")

    # Cutoffs: the offset is converted, not dropped.
    check("intro in UTC", SUPERVISOR_INTRODUCED, dt.datetime(2026, 10, 8, 19, 24, 17, tzinfo=UTC))
    check("plan mode in UTC", PLAN_MODE_INTRODUCED, dt.datetime(2026, 10, 12, 1, 48, 45, tzinfo=UTC))
    check("fix in UTC", SUPERVISOR_FIX, dt.datetime(2026, 10, 12, 3, 55, 53, tzinfo=UTC))
    check("parse_ts epoch", parse_ts("86400"), dt.datetime(1970, 1, 2, tzinfo=UTC))
    check("parse_ts offset", parse_ts("2026-10-11T23:55:53-04:00"), SUPERVISOR_FIX)
    check("parse_ts Z", parse_ts("2026-10-12T03:55:53Z"), SUPERVISOR_FIX)
    check("parse_ts naive is UTC", parse_ts("2026-10-12T03:55:53"), SUPERVISOR_FIX)
    check("parse_ts junk", (parse_ts(""), parse_ts("nan"), parse_ts("inf"), parse_ts("soon"), parse_ts(None)),
          (None, None, None, None, None))
    check("seconds_between order", (seconds_between(SUPERVISOR_FIX, SUPERVISOR_INTRODUCED),
                                    seconds_between(None, SUPERVISOR_FIX)), (None, None))
    d = describe([4.0, 8.0])
    check("describe n=2", (d["n"], d["mean"], d["median"], d["min"], d["max"], d["sum"]), (2, 6.0, 6.0, 4.0, 8.0, 12.0))
    close("describe stdev", d["stdev"], math.sqrt(8))
    check("describe n=1 has no stdev", describe([5])["stdev"], None)
    check("describe empty", describe([None, None])["n"], 0)
    check("ratio guards", (ratio(1, 0), ratio(None, 2), ratio(3, 2)), (None, None, 1.5))
    check("duration format", (f_dur(3725), f_dur(None), f_dur(360000)), ("1:02:05", NA, "100:00:00"))

    # The columns this script reads are ones the extraction writes.
    extractor = Path(__file__).resolve().with_name("extract_usage_data.py")
    if extractor.is_file():
        keep, sys.dont_write_bytecode = sys.dont_write_bytecode, True   # leave no __pycache__ in the tree
        try:
            spec = importlib.util.spec_from_file_location("extract_usage_data_for_contract", extractor)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        finally:
            sys.dont_write_bytecode = keep
        for label, used, written in (
                ("tasks", TASK_REQUIRED + TASK_OPTIONAL, mod.TASK_COLUMNS),
                ("sessions", SESSION_REQUIRED + SESSION_OPTIONAL, mod.SESSION_COLUMNS),
                ("usage", USAGE_REQUIRED + USAGE_OPTIONAL, mod.USAGE_COLUMNS),
                ("plan steps", PLAN_STEP_COLUMNS_USED, mod.PLAN_STEP_COLUMNS)):
            check(f"columns of {label} the extraction writes", sorted(set(used) - set(written)), [])

    with tempfile.TemporaryDirectory(prefix="compare-selftest-") as tmp:
        root = Path(tmp)
        world = build_world(root / "in")
        report = load_and_analyse(root / "in", dt.datetime(2026, 10, 13, 0, 0, 0, tzinfo=UTC))
        rows = {r["task_id"]: r for r in report.task_rows}

        check("task count", len(rows), 18)
        check("groups", {t: r["group"] for t, r in rows.items()},
              {"tA1": "A", "tA2": "A", "tAin": "A", "tArev": "A", "tX1": "excluded-buggy", "tX2": "excluded-buggy",
               "tP1": "plan-mode", "tP2": "plan-mode", "tU1": "unresolved", "tU2": "unresolved",
               "tB1": "B", "tB2": "B", "tB3": "B", "tB4": "B", "tB5": "B", "tB6": "B", "tBin": "B", "tBref": "B"})
        check("in comparison", sorted(t for t, r in rows.items() if r["in_comparison"]),
              ["tA1", "tA2", "tB1", "tB2", "tB3", "tB4", "tB5", "tB6"])
        check("stages", {t: rows[t]["stage"] for t in ("tA1", "tAin", "tArev", "tBin", "tBref")},
              {"tA1": "done", "tAin": "in-flight", "tArev": "review", "tBin": "in-flight", "tBref": "in-flight"})
        check("flag sources", (rows["tA1"]["supervisor_flag"], rows["tB3"]["supervisor_flag"],
                               rows["tB1"]["supervisor_flag"], rows["tB5"]["supervisor_flag"]),
              ("on", "off", "absent", "on"))
        check("anomaly counted", report.quality["supervisor_on_before_it_existed"], 1)
        check("plan flag before plan mode counted", report.quality["plan_flag_before_plan_mode_existed"], 1)

        a1 = rows["tA1"]
        check("tA1 sub-agents", (a1["num_subagents"], a1["num_seed_sessions"], a1["num_subagents_excl_seeds"],
                                 a1["num_plan_step_workers"], a1["num_other_descendants"]), (5, 1, 4, 2, 2))
        check("tA1 tokens", (a1["input_tokens"], a1["output_tokens"], a1["cache_read_tokens"],
                             a1["cache_write_tokens"], a1["total_tokens"]), (336, 34, 3801, 51, 4222))
        close("tA1 cost", a1["cost"], 3.8)
        close("tA1 list cost (a blank list cost counts at its cost)", a1["list_cost"], 5.2)
        check("tA1 rows by billing", (a1["usage_rows"], a1["rows_api"], a1["rows_subscription"],
                                      a1["rows_extra_usage"], a1["rows_billing_blank"], a1["rows_billing_other"],
                                      a1["rows_list_cost_blank"]), (6, 3, 1, 1, 1, 0, 1))
        check("tA1 top-level", (a1["top_total_tokens"], a1["top_usage_rows"], a1["top_duration_s"],
                                a1["top_usage_span_s"], a1["top_compactions"]), (3380, 2, 2000.0, 1695.0, 2))
        close("tA1 top cost", a1["top_cost"], 3.0)
        close("tA1 top list cost", a1["top_list_cost"], 4.0)
        check("tA1 sub-agents combined", (a1["sub_total_tokens"], a1["sub_usage_rows"], a1["sub_compactions_total"]),
              (842, 4, 1))
        close("tA1 sub cost", a1["sub_cost"], 0.8)
        close("tA1 sub list cost", a1["sub_list_cost"], 1.2)
        check("tA1 btw/internal kept apart", (a1["other_total_tokens"], a1["other_usage_rows"]), (1007, 2))
        close("tA1 btw/internal list cost", a1["other_list_cost"], 9.25)
        check("tA1 durations (session created at the cutoff, task created a second before)",
              (a1["duration_created_to_finished_s"], a1["duration_started_to_finished_s"]), (1801.0, 1790.0))
        check("tA2 has no sub-agents and is kept", (rows["tA2"]["num_subagents"], rows["tA2"]["in_comparison"],
                                                    rows["tA2"]["total_tokens"]), (0, True, 560))
        check("tB4 created at the introduction is B", rows["tB4"]["group_reason"],
              "supervisor setting absent")
        check("tB5 on before it existed is B", rows["tB5"]["group_reason"], "created before supervisor mode existed")
        check("tB6 has no finished time or usage", (rows["tB6"]["duration_created_to_finished_s"],
                                                      rows["tB6"]["usage_rows"], rows["tB6"]["in_comparison"]),
              (None, 0, True))
        check("task before the fix with the flag on", rows["tX1"]["group_reason"],
              "supervisor on, created before the fix")
        check("record missing wins over dates", (rows["tU1"]["descendants_resolved"], rows["tU2"]["group"]),
              (False, "unresolved"))
        check("a worker's worker is found", sorted(r["session_id"] for r in report.sub_rows if r["task_id"] == "tA1"),
              ["sA1f1", "sA1gc", "sA1seed", "sA1w1", "sA1w2"])
        check("sub-agent rows", len(report.sub_rows), 6)

        # Group statistics, from the hand-worked numbers.
        check("n", report.n, {"A": 2, "B": 6})
        sa, sb = report.stat("A", "total_tokens"), report.stat("B", "total_tokens")
        check("A tokens", (sa["mean"], sa["median"], sa["sum"], sa["min"], sa["max"]), (2391.0, 2391.0, 4782.0, 560, 4222))
        close("A tokens stdev", sa["stdev"], abs(4222 - 560) / math.sqrt(2))
        close("B tokens mean", sb["mean"], 17410 / 6)
        check("B tokens median and sum", (sb["median"], sb["sum"]), (1210.0, 17410.0))
        sa, sb = report.stat("A", "cost"), report.stat("B", "cost")
        close("A cost sum", sa["sum"], 4.3)
        close("A cost mean", sa["mean"], 2.15)
        close("B cost sum", sb["sum"], 6.41)
        close("B cost median", sb["median"], 0.2)
        sa, sb = report.stat("A", "list_cost"), report.stat("B", "list_cost")
        close("A list cost sum", sa["sum"], 5.8)
        close("B list cost sum", sb["sum"], 8.41)
        close("B list cost median", sb["median"], 0.65)
        close("B list cost mean", sb["mean"], 8.41 / 6)
        sa, sb = report.stat("A", "duration_created_to_finished_s"), report.stat("B", "duration_created_to_finished_s")
        check("A duration", (sa["n"], sa["mean"]), (2, 1200.5))
        check("B duration (tB6 has none)", (sb["n"], sb["mean"], sb["median"]), (5, 1500.0, 1200.0))
        sa, sb = report.stat("A", "num_subagents"), report.stat("B", "num_subagents")
        check("A sub-agents per task", (sa["mean"], sa["median"], sa["max"]), (2.5, 2.5, 5))
        close("B sub-agents per task", sb["mean"], 1 / 6)
        check("B sub-agents median", sb["median"], 0)
        check("tasks with exactly 0 sub-agents", {g: sum(1 for r in report.cmp[g] if r["num_subagents"] == 0)
                                                  for g in ("A", "B")}, {"A": 1, "B": 5})
        sa = describe(column(report.subs["A"], "total_tokens"))
        check("A sub-agent sessions tokens", (sa["n"], sa["mean"], sa["median"]), (5, 168.4, 111))
        sa = describe(column(report.subs["A"], "list_cost"))
        close("A sub-agent list cost mean", sa["mean"], 0.24)
        close("A sub-agent list cost median", sa["median"], 0.2)
        sa = describe(column(report.subs["A"], "duration_s"))
        check("A sub-agent durations skip the one with no update time", (sa["n"], sa["mean"], sa["median"]),
              (4, 250.0, 250.0))
        sa = describe(column(report.subs["A"], "compactions"))
        check("A sub-agent compactions skip the unscanned one", (sa["n"], sa["mean"], sa["median"]), (4, 0.25, 0))
        sb = describe(column(report.subs["B"], "total_tokens"))
        check("B sub-agent sessions", (sb["n"], sb["mean"]), (1, 10))
        sa, sb = report.stat("A", "top_compactions"), report.stat("B", "top_compactions")
        check("top-level compactions", (sa["mean"], sb["median"]), (1.0, 0))
        close("B top-level compactions mean", sb["mean"], 4 / 6)

        buggy = report.by_group("excluded-buggy")
        close("buggy cost total", math.fsum(column(buggy, "cost")), 8.0)
        close("buggy list cost total", math.fsum(column(buggy, "list_cost")), 8.0)
        check("buggy counts", (len(buggy), sum(1 for r in buggy if r["state"] == "done")), (2, 1))
        check("billing rows A", tuple(sum(column(report.cmp["A"], k)) for k in
                                      ("rows_api", "rows_subscription", "rows_extra_usage", "rows_billing_blank",
                                       "usage_rows", "rows_list_cost_blank")), (4, 1, 1, 1, 7, 1))
        check("billing rows B", tuple(sum(column(report.cmp["B"], k)) for k in
                                      ("rows_api", "rows_subscription", "rows_extra_usage", "rows_billing_blank",
                                       "usage_rows", "rows_list_cost_blank")), (3, 1, 0, 2, 6, 2))
        att = report.attribution
        check("usage attribution rows", {k: v[1].rows for k, v in att.items()},
              {"task": 16, "task-other": 2, "no-task": 1, "no-record": 1})
        check("quality", (report.quality["usage_rows"], report.quality["usage_rows_list_cost_blank"],
                          report.quality["subagent_sessions_outside_any_task"]), (20, 3, 0))

        # CSV and report output.
        outdir = root / "csv"
        doc = root / "docs" / "report.md"
        status = run(parse_args(["--in-dir", str(root / "in"), "--csv-out-dir", str(outdir), "--out", str(doc),
                                 "--quiet"]))
        check("run status", status, 0)
        with open(outdir / "classified_tasks.csv", newline="", encoding="utf-8") as fh:
            written = list(csv.DictReader(fh))
        check("classified_tasks.csv rows and columns", (len(written), list(written[0].keys())),
              (18, TASK_OUT_COLUMNS))
        with open(outdir / "subagents.csv", newline="", encoding="utf-8") as fh:
            subs_written = list(csv.DictReader(fh))
        check("subagents.csv rows and columns", (len(subs_written), list(subs_written[0].keys())),
              (6, SUB_OUT_COLUMNS))
        check("csv values", {r["task_id"]: r["total_tokens"] for r in written if r["task_id"] in ("tA1", "tB6")},
              {"tA1": "4222", "tB6": "0"})
        text = doc.read_text(encoding="utf-8")
        check("report marks itself generated", text.startswith(GENERATED_MARK), True)
        for needle in ("fixed supervisor mode", "(n=2)", "(n=6)", "73f987b", "0803841", "7be8ce2", "b0a013d",
                       "2026-10-12T03:55:53Z", "## Bottom line", "## Method", "indicative only",
                       "is 2.5 hours before the newest usage row",          # fix + 9060 s, worked out by hand
                       "mean A $2.90 (n=2) vs B $1.40 (n=6), A/B 2.07x",     # 5.8/2 over 8.41/6
                       "median A $2.90 (n=2) vs B $0.650 (n=6), A/B 4.46x",
                       "per task in state `done` (n=1), mean list cost $7.00",
                       "| List cost | $7.00 | $1.40 | 4.99x | $7.00 | $0.650 | 10.77x | Excluded 1 / B 6 |"):
            check(f"report mentions {needle!r}", needle in text, True)
        leaked = [i for i in world["session_ids"] + world["task_ids"] if i in text]
        check("no session or task id in the report", leaked, [])
        check("no placeholder mark in a real report", PLACEHOLDER_MARK in text, False)

        # A comparison with an empty side must not fail.
        thin = root / "thin"
        thin.mkdir()
        keep_tasks = {"tB1", "tB2", "tX1", "tP1"}
        for name, key in (("tasks.csv", "task_id"),):
            with open(root / "in" / name, newline="", encoding="utf-8") as fh:
                rdr = csv.DictReader(fh)
                head, kept = rdr.fieldnames, [r for r in rdr if r[key] in keep_tasks]
            with open(thin / name, "w", newline="", encoding="utf-8") as fh:
                w = csv.DictWriter(fh, head, lineterminator="\n")
                w.writeheader()
                w.writerows(kept)
        for name in ("sessions.csv", "usage_rows.csv", "plan_steps.csv"):
            (thin / name).write_bytes((root / "in" / name).read_bytes())
        thin_report = load_and_analyse(thin, dt.datetime(2026, 10, 13, tzinfo=UTC))
        check("thin n", thin_report.n, {"A": 0, "B": 2})
        thin_text = render_report(thin_report)
        check("empty group A is said so", "No comparison is possible: group A has no task" in thin_text, True)

        # Parent cycles must not hang, and a session two tasks both include must be flagged.
        mini = root / "mini"
        mini.mkdir()
        t0 = world["fix"] + 100
        mini_sessions = [
            {"session_id": "m1", "kind": "main", "supervisor": "true", "created": t0, "updated": t0 + 10,
             "parent_id": "m1x"},                                                   # the task's session has a parent that is its child
            {"session_id": "m1x", "kind": "subagent", "parent_id": "m1", "created": t0 + 1, "updated": t0 + 5},
            {"session_id": "m2", "kind": "main", "supervisor": "true", "created": t0 + 50, "updated": t0 + 90},
            {"session_id": "m2a", "kind": "subagent", "parent_id": "m2", "created": t0 + 55, "updated": t0 + 80},
            {"session_id": "m3", "kind": "subagent", "parent_id": "m2a", "created": t0 + 60, "updated": t0 + 70}]
        mini_tasks = [
            {"task_id": "mt1", "session_id": "m1", "state": "done", "created": t0, "finished": t0 + 10},
            {"task_id": "mt2", "session_id": "m2", "state": "done", "created": t0 + 50, "finished": t0 + 90},
            {"task_id": "mt3", "session_id": "m3", "state": "done", "created": t0 + 60, "finished": t0 + 70,
             "adopted": "true"}]
        mini_usage = [{"id": 1, "ts": t0 + 61, "session": "m3", "input": 7, "output": 0, "cache_read": 0,
                       "cache_write": 0, "cost": 0.5, "list_cost": 0.5, "billing": "api"},
                      {"id": 2, "ts": t0 + 2, "session": "m1", "input": 3, "output": 2, "cache_read": 0,
                       "cache_write": 0, "cost": 0.0, "list_cost": 0.0, "billing": "api"},      # tokens, priced at 0
                      {"id": 3, "ts": t0 + 3, "session": "m1", "input": 0, "output": 0, "cache_read": 0,
                       "cache_write": 0, "cost": 0.0, "list_cost": 0.0, "billing": "api"}]      # no tokens: not counted
        dump_world(mini, mini_sessions, mini_tasks, mini_usage)
        mini_report = load_and_analyse(mini, dt.datetime(2026, 10, 13, tzinfo=UTC))
        mrows = {r["task_id"]: r for r in mini_report.task_rows}
        check("cycle: the only sub-agent of a task whose session is its own child's child", mrows["mt1"]["num_subagents"], 1)
        check("adopted: m2's tree includes the adopted session and the adopted task is its own top",
              (mrows["mt2"]["num_subagents"], mrows["mt2"]["total_tokens"], mrows["mt3"]["num_subagents"],
               mrows["mt3"]["total_tokens"]), (2, 7, 0, 7))
        check("rows with tokens but priced at 0", (mrows["mt1"]["rows_priced_at_zero"],
                                                    mrows["mt1"]["tokens_priced_at_zero"], mrows["mt1"]["usage_rows"],
                                                    mini_report.quality["usage_rows_priced_at_zero"]), (1, 5, 2, 1))
        check("adopted: shared sessions flagged on both tasks",
              (mrows["mt2"]["shared_sessions"], mrows["mt3"]["shared_sessions"],
               mini_report.quality["tasks_with_shared_sessions"], mini_report.quality["adopted_tasks"]), (1, 1, 2, 1))

        # Methodology-only: no data read, results not replaced without --force.
        placeholder = root / "placeholder.md"
        check("methodology-only status", run(parse_args(["--methodology-only", "--out", str(placeholder), "--quiet"])), 0)
        ptext = placeholder.read_text(encoding="utf-8")
        check("placeholder says it has no results", ("No results in this file yet" in ptext, PLACEHOLDER_MARK in ptext),
              (True, True))
        check("placeholder lists no figures", "## Results" in ptext or "## Bottom line" in ptext, False)
        with contextlib.redirect_stderr(io.StringIO()) as err:
            status = run(parse_args(["--methodology-only", "--out", str(doc), "--quiet"]))
        check("results are not replaced by a placeholder", (status, "holds results" in err.getvalue(),
                                                            "No results" in doc.read_text(encoding="utf-8")),
              (2, True, False))
        check("force replaces them", run(parse_args(["--methodology-only", "--force", "--out", str(doc),
                                                      "--quiet"])), 0)

        # Missing and malformed inputs are reported, not tracebacks.
        empty = root / "empty"
        empty.mkdir()
        with contextlib.redirect_stderr(io.StringIO()) as err:
            status = run(parse_args(["--in-dir", str(empty), "--out", str(root / "none.md"), "--quiet"]))
        check("missing inputs", (status, "not found" in err.getvalue(), (root / "none.md").exists()),
              (2, True, False))
        bad = root / "bad"
        bad.mkdir()
        for name in ("sessions.csv", "tasks.csv", "plan_steps.csv"):
            (bad / name).write_bytes((root / "in" / name).read_bytes())
        (bad / "usage_rows.csv").write_text("id,session\n1,x\n", encoding="utf-8")
        with contextlib.redirect_stderr(io.StringIO()) as err:
            status = run(parse_args(["--in-dir", str(bad), "--out", str(root / "none.md"), "--quiet"]))
        check("missing column", (status, "lacks the column(s)" in err.getvalue()), (2, True))

    if failures:
        print("self-test FAILED:", file=sys.stderr)
        for line in failures:
            print("  " + line, file=sys.stderr)
        return 1
    print("self-test ok")
    return 0


def main(argv=None):
    args = parse_args(argv)
    if args.self_test:
        return self_test()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
