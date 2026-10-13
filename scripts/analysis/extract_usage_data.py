#!/usr/bin/env python3
"""Extract the harness's own usage, session and task history into CSV files.

Reads (never writes) a harness state directory and writes plain CSVs that a
later step can analyse with the standard library alone:

    usage_rows.csv    one row per model call (the `usage` table of usage.db)
    sessions.csv      one row per session record (sessions/<id>.json), plus
                      counts taken from its transcript (sessions/<id>.nodes.jsonl)
    plan_steps.csv    one row per supervisor plan step (workers a supervisor
                      session started), from the session records
    tasks.csv         one row per task of the task board
    manifest.json     counts, sources read, lines skipped
    data_dictionary.md  what every column means (written on every run)

Privacy: only ids, flags, enum values, timestamps and numbers are written.  A
task's title and prompt, a session's name, plan text and results, and every
word of a transcript are never copied: records are parsed, a fixed list of
fields is picked out, the rest is dropped.  Any value that should be an
enum or an id but is not token-like is replaced with `<other>` rather than
written.  Output files are created owner-only (umask 077).

The state directory is opened read-only: usage.db through SQLite's
`mode=ro`, everything else with plain reads.  The harness is normally still
running, so a transcript line that does not parse (the last one may be
half written) is skipped, as `store/read-all` skips corrupt lines.

Python 3 standard library only.  No network.

Usage:
    scripts/analysis/extract_usage_data.py                 # real state dir
    scripts/analysis/extract_usage_data.py --state-dir DIR --out-dir DIR
    scripts/analysis/extract_usage_data.py --only tasks --task-store .git/harness/tasks.json
    scripts/analysis/extract_usage_data.py --self-test     # synthetic fixture, no real data
    scripts/analysis/extract_usage_data.py --make-fixture DIR   # leave that fixture in DIR

Exit status: 0 done; 1 a selected part had no source to read or could not be
read (its files are not written, and the manifest says why); 2 usage error or
the state directory cannot be read.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import datetime as dt
import io
import json
import os
import re
import sqlite3
import sys
import tempfile
from collections import Counter
from pathlib import Path

SCRIPT_VERSION = 1

DEFAULT_STATE_DIR = "~/.emacs.d/.local/cache/harness/"
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT_DIR = REPO_ROOT / "scripts" / ".dev" / "usage-analysis"

OTHER = "<other>"

# --------------------------------------------------------------------------
# Column lists (kept in step with DATA_DICTIONARY below).

USAGE_COLUMNS = [
    "id", "ts", "session", "project", "model", "input", "output",
    "cache_read", "cache_write", "cost", "turn", "list_cost", "billing",
]

SESSION_COLUMNS = [
    "session_id", "kind", "parent_id",
    "supervisor", "supervisor_judge_pending", "supervisor_write_up", "seed",
    "model", "thinking", "permission_mode", "non_interactive", "project", "status",
    "created", "updated", "last_message",
    "usage_input", "usage_output", "usage_cache_read", "usage_cache_write",
    "usage_cost", "usage_list_cost", "usage_turns", "usage_context",
    "plans", "plan_steps",
    "has_nodes_file", "nodes_bytes", "nodes", "user_nodes", "assistant_nodes",
    "tool_calls", "compactions", "compaction_input_tokens",
    "first_node_ts", "last_node_ts", "bad_node_lines", "inherited_node_lines",
]

PLAN_STEP_COLUMNS = [
    "session_id", "plan_index", "plan_id", "plan_created", "fork_tokens",
    "step_index", "step_id", "tier", "context", "model", "worker_model",
    "thinking", "state", "worker_session_id", "attempts", "model_fallback",
    "after_count", "previous_session_id", "previous_attempt",
]

TASK_COLUMNS = [
    "task_id", "session_id", "project", "store", "state", "outcome",
    "created", "started", "finished", "refined", "merge_queued", "report_at",
    "verified_at", "reopened", "returned", "sent_back", "return_reason",
    "supervisor_setting", "plan", "backlog", "main_tree", "adopted",
    "non_interactive", "model", "thinking", "permission_mode", "priority",
    "merged", "verified", "archived", "cannot_continue", "no_merge",
    "merge_attempts",
    "session_found", "session_kind", "session_supervisor", "session_created",
]

SECTIONS = ("usage", "sessions", "tasks")
OUTPUT_FILES = {
    "usage": ("usage_rows.csv",),
    "sessions": ("sessions.csv", "plan_steps.csv"),
    "tasks": ("tasks.csv",),
}

# --------------------------------------------------------------------------
# Value cleaning.  Everything written goes through one of these.

_TOKEN = re.compile(r"^[A-Za-z0-9_.:@+/=\[\]-]{1,160}$")
_sanitized = Counter()  # field kind -> how many values were replaced by OTHER


def tok(value, what="token"):
    """An id or enum: written as it is when token-like, else `<other>`."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str) and _TOKEN.match(value):
        return value
    _sanitized[what] += 1
    return OTHER


def pth(value):
    """A directory path (a project root): any single-line text up to 512 chars."""
    if value is None:
        return ""
    if isinstance(value, str) and len(value) <= 512 and not re.search(r"[\x00-\x1f\x7f]", value):
        return value
    _sanitized["path"] += 1
    return OTHER


def num(value):
    """A number (timestamp, count, tokens, cost): blank when null or not a number."""
    if value is None or isinstance(value, bool):
        return ""
    if isinstance(value, (int, float)):
        return repr(value)
    return ""


def flag(value):
    """A JSON boolean: `true`, `false`, or blank for null/absent."""
    if value is True:
        return "true"
    if value is False:
        return "false"
    return ""


def truthy(value):
    """`true` when the harness's `harness-json-true-p` would say so, else blank."""
    return "" if value is None or value is False else "true"


def tri(value):
    """The supervisor setting the way `harness-supervisor--value` reads it.

    Absent or null: no setting (blank).  `false`: an explicit hands-on
    (`false`).  Anything else: supervising (`true`).
    """
    if value is None:
        return ""
    if value is False:
        return "false"
    return "true"


def as_dict(value):
    return value if isinstance(value, dict) else {}


def as_list(value):
    return value if isinstance(value, list) else []


@contextlib.contextmanager
def csv_out(path: Path, header):
    """A csv writer on PATH, replaced atomically when the block succeeds."""
    tmp = path.with_name(path.name + ".tmp")
    try:
        with open(tmp, "w", newline="", encoding="utf-8") as fh:
            writer = csv.writer(fh, lineterminator="\n")
            writer.writerow(header)
            yield writer
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


class SourceError(Exception):
    """A part cannot be extracted: its source is missing or unreadable."""


def say(args, message):
    if not args.quiet:
        print(message, file=sys.stderr)


# --------------------------------------------------------------------------
# usage.db

def extract_usage(state_dir: Path, out_dir: Path, args, manifest):
    """Dump the `usage` table (SQLite, opened read-only) to usage_rows.csv."""
    db_path = state_dir / "usage.db"
    jsonl_path = state_dir / "usage" / "records.jsonl"
    info = manifest["usage"] = {"source": None, "rows": 0}
    if not db_path.is_file() and not jsonl_path.is_file():
        info["error"] = f"no usage.db and no usage/records.jsonl in {state_dir}"
        return False
    try:
        return _dump_usage(db_path, jsonl_path, out_dir, args, info)
    except (SourceError, sqlite3.Error, OSError) as err:
        info["error"] = f"cannot read usage: {err}"
        return False


def _dump_usage(db_path: Path, jsonl_path: Path, out_dir: Path, args, info):
    """Write usage_rows.csv from the database (and the JSONL log when asked or alone)."""
    sessions, billing = set(), Counter()
    total = {"cost": 0.0, "list_cost": 0.0}
    bounds = [None, None]

    def tally(row):
        """Count ROW (a sequence in USAGE_COLUMNS order) into the manifest figures."""
        r = dict(zip(USAGE_COLUMNS, row))
        info["rows"] += 1
        sessions.add(r["session"])
        billing[r["billing"] if r["billing"] is not None else ""] += 1
        for key in total:
            if isinstance(r[key], (int, float)):
                total[key] += r[key]
        ts = r["ts"]
        if isinstance(ts, (int, float)):
            bounds[0] = ts if bounds[0] is None else min(bounds[0], ts)
            bounds[1] = ts if bounds[1] is None else max(bounds[1], ts)

    with csv_out(out_dir / "usage_rows.csv", USAGE_COLUMNS) as writer:
        if db_path.is_file():
            info["source"] = "usage.db"
            con = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
            try:
                con.execute("PRAGMA query_only = ON")
                have = [r[1] for r in con.execute("PRAGMA table_info(usage)")]
                if not have:
                    raise SourceError("usage.db has no usage table")
                info["missing_columns"] = [c for c in USAGE_COLUMNS if c not in have]
                select = ", ".join(c if c in have else f"NULL AS {c}" for c in USAGE_COLUMNS)
                for row in con.execute(f"SELECT {select} FROM usage ORDER BY ts, id"):
                    tally(row)
                    writer.writerow(["" if v is None else v for v in row])
            finally:
                con.close()
        if jsonl_path.is_file() and (args.include_jsonl_usage or not db_path.is_file()):
            info["source"] = "usage/records.jsonl" if not db_path.is_file() else "usage.db + usage/records.jsonl"
            bad = 0
            with open(jsonl_path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if not line.strip():
                        continue
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        bad += 1
                        continue
                    if not isinstance(rec, dict):
                        bad += 1
                        continue
                    rid = rec.get("id")
                    row = [
                        f"jsonl:{rid}" if rid is not None else "",
                        rec.get("ts"), rec.get("session"), rec.get("project"),
                        rec.get("model"), rec.get("input"), rec.get("output"),
                        rec.get("cache-read"), rec.get("cache-write"), rec.get("cost"),
                        rec.get("turn"), rec.get("list-cost"), rec.get("billing"),
                    ]
                    tally(row)
                    writer.writerow(["" if v is None else v for v in row])
            info["jsonl_bad_lines"] = bad
        elif jsonl_path.is_file():
            with open(jsonl_path, encoding="utf-8", errors="replace") as fh:
                info["jsonl_rows_not_included"] = sum(1 for line in fh if line.strip())

    info["distinct_sessions"] = len(sessions)
    info["sum_cost"] = round(total["cost"], 6)
    info["sum_list_cost"] = round(total["list_cost"], 6)
    info["first_ts"], info["last_ts"] = bounds
    info["rows_by_billing"] = dict(sorted(billing.items()))
    return True


# --------------------------------------------------------------------------
# sessions

def scan_nodes(path: Path, session_id: str):
    """Replay a transcript the way the harness loads it and count what the
    session itself wrote.

    Lines marked `_op: delete` drop a node, `_op: update` lines amend one, and
    a fork copies its parent's nodes into its own log with the parent's
    `session` value: those inherited nodes are not the session's own and are
    not counted (a fork would otherwise carry every compaction of its parent).
    Only `kind`, `ts`, `id`, `session`, `_op` and a compaction's
    `meta.input-tokens` are looked at.  Lines that do not parse are counted
    and skipped.
    """
    own = {}  # node id -> (kind, ts, input tokens)
    bad = inherited = 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh):
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                bad += 1
                continue
            if not isinstance(rec, dict):
                bad += 1
                continue
            nid = rec.get("id")
            op = rec.get("_op")
            if op == "delete":
                own.pop(nid, None)
                continue
            if op == "update":
                if nid in own and isinstance(rec.get("kind"), str):
                    own[nid] = (rec["kind"],) + own[nid][1:]
                continue
            if rec.get("session") not in (None, session_id):
                inherited += 1
                continue
            kind = rec.get("kind")
            meta = rec.get("meta")
            tokens = meta.get("input-tokens") if isinstance(meta, dict) else None
            own[nid if nid is not None else ("line", n)] = (
                kind if isinstance(kind, str) else "",
                rec.get("ts"),
                tokens if isinstance(tokens, (int, float)) and not isinstance(tokens, bool) else None,
            )
    kinds = Counter(k for k, _, _ in own.values())
    stamps = [ts for _, ts, _ in own.values() if isinstance(ts, (int, float)) and not isinstance(ts, bool)]
    return {
        "nodes": len(own),
        "user_nodes": kinds["user"],
        "assistant_nodes": kinds["assistant"],
        "tool_calls": kinds["tool-call"],
        "compactions": kinds["compaction"],
        "compaction_input_tokens": sum(t for k, _, t in own.values() if k == "compaction" and t is not None),
        "first_node_ts": min(stamps) if stamps else None,
        "last_node_ts": max(stamps) if stamps else None,
        "bad_node_lines": bad,
        "inherited_node_lines": inherited,
        "kinds": dict(kinds),
    }


def load_sessions(state_dir: Path, manifest):
    """Read every sessions/*.json record.  Return {id: record} (fields kept as parsed)."""
    sdir = state_dir / "sessions"
    info = manifest["sessions"] = {"directory": str(sdir), "records": 0, "unparseable": []}
    records = {}
    if not sdir.is_dir():
        info["error"] = f"no sessions directory in {state_dir}"
        return records
    # `store/list` with "\.json\'": names ending in .json, which leaves
    # out <id>.nodes.jsonl.
    for path in sorted(p for p in sdir.iterdir() if p.name.endswith(".json") and p.is_file()):
        stem = path.name[: -len(".json")]
        try:
            with open(path, encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            info["unparseable"].append(stem)
            continue
        if not isinstance(rec, dict):
            info["unparseable"].append(stem)
            continue
        sid = rec.get("id") if isinstance(rec.get("id"), str) else stem
        if sid != stem:
            info["id_differs_from_file_name"] = info.get("id_differs_from_file_name", 0) + 1
        records[sid] = rec
    info["records"] = len(records)
    return records


def session_row(sid, rec, nodes_dir: Path, scan: bool, nodes_info):
    ext = as_dict(rec.get("ext"))
    usage = as_dict(rec.get("usage"))
    plans = [p for p in as_list(ext.get("supervisor-plans")) if isinstance(p, dict)]
    steps = sum(len([s for s in as_list(p.get("steps")) if isinstance(s, dict)]) for p in plans)
    nodes_path = nodes_dir / f"{sid}.nodes.jsonl"
    has_nodes = nodes_path.is_file()
    stats = None
    if has_nodes and scan:
        try:
            stats = scan_nodes(nodes_path, sid)
        except OSError as err:
            nodes_info["unreadable"].append(sid)
            print(f"warning: cannot read {nodes_path.name}: {err}", file=sys.stderr)
    row = {
        "session_id": tok(sid, "id"),
        "kind": tok(rec.get("kind") or "main", "enum"),  # a record without a kind is `main`
        "parent_id": tok(rec.get("parent-id"), "id"),
        "supervisor": tri(ext.get("supervisor")),
        "supervisor_judge_pending": truthy(ext.get("supervisor-judge")),
        "supervisor_write_up": truthy(ext.get("supervisor-write-up")),
        "seed": truthy(ext.get("seed")),
        "model": tok(rec.get("model"), "model"),
        "thinking": tok(rec.get("thinking"), "enum"),
        "permission_mode": tok(rec.get("permission-mode"), "enum"),
        "non_interactive": flag(rec.get("non-interactive")),
        "project": pth(rec.get("project")),
        "status": tok(rec.get("status"), "enum"),
        "created": num(rec.get("created")),
        "updated": num(rec.get("updated")),
        "last_message": num(rec.get("last-message")),
        "usage_input": num(usage.get("input")),
        "usage_output": num(usage.get("output")),
        "usage_cache_read": num(usage.get("cache-read")),
        "usage_cache_write": num(usage.get("cache-write")),
        "usage_cost": num(usage.get("cost")),
        "usage_list_cost": num(usage.get("list-cost")),
        "usage_turns": num(usage.get("turns")),
        "usage_context": num(usage.get("context")),
        "plans": len(plans) if "supervisor-plans" in ext else "",
        "plan_steps": steps if "supervisor-plans" in ext else "",
        "has_nodes_file": "true" if has_nodes else "false",
        "nodes_bytes": nodes_path.stat().st_size if has_nodes else "",
    }
    for key in ("nodes", "user_nodes", "assistant_nodes", "tool_calls", "compactions",
                "compaction_input_tokens", "bad_node_lines", "inherited_node_lines"):
        row[key] = stats[key] if stats else ""
    row["first_node_ts"] = num(stats["first_node_ts"]) if stats else ""
    row["last_node_ts"] = num(stats["last_node_ts"]) if stats else ""
    return row, stats


def plan_step_rows(sid, rec):
    ext = as_dict(rec.get("ext"))
    for pi, plan in enumerate(as_list(ext.get("supervisor-plans"))):
        if not isinstance(plan, dict):
            continue
        for si, step in enumerate(as_list(plan.get("steps"))):
            if not isinstance(step, dict):
                continue
            prev = as_dict(step.get("previous"))
            yield {
                "session_id": tok(sid, "id"),
                "plan_index": pi,
                "plan_id": tok(plan.get("id"), "id"),
                "plan_created": num(plan.get("created")),
                "fork_tokens": num(plan.get("fork-tokens")),
                "step_index": si,
                "step_id": tok(step.get("id"), "id"),
                "tier": tok(step.get("tier"), "enum"),
                "context": tok(step.get("context"), "enum"),
                "model": tok(step.get("model"), "model"),
                "worker_model": tok(step.get("worker-model"), "model"),
                "thinking": tok(step.get("thinking"), "enum"),
                "state": tok(step.get("state"), "enum"),
                "worker_session_id": tok(step.get("session"), "id"),
                "attempts": num(step.get("attempts")),
                "model_fallback": tok(step.get("model-fallback"), "enum"),
                "after_count": len(as_list(step.get("after"))),
                "previous_session_id": tok(prev.get("session"), "id"),
                "previous_attempt": num(prev.get("attempt")),
            }


def extract_sessions(state_dir: Path, out_dir: Path, records, args, manifest):
    """Write sessions.csv and plan_steps.csv from the loaded records."""
    nodes_info = {"scanned": 0, "unreadable": [], "bad_lines": 0, "inherited_lines": 0,
                  "kinds": Counter(), "skipped": bool(args.no_nodes)}
    manifest["nodes"] = nodes_info
    sdir = state_dir / "sessions"
    by_kind, by_sup = Counter(), Counter()
    plan_rows = 0
    ordered = sorted(records.items(), key=lambda kv: (num_or_zero(kv[1].get("created")), kv[0]))
    with csv_out(out_dir / "sessions.csv", SESSION_COLUMNS) as sw, \
         csv_out(out_dir / "plan_steps.csv", PLAN_STEP_COLUMNS) as pw:
        for sid, rec in ordered:
            row, stats = session_row(sid, rec, sdir, not args.no_nodes, nodes_info)
            sw.writerow([row[c] for c in SESSION_COLUMNS])
            by_kind[row["kind"]] += 1
            by_sup[(row["kind"], row["supervisor"] or "none")] += 1
            if stats:
                nodes_info["scanned"] += 1
                nodes_info["bad_lines"] += stats["bad_node_lines"]
                nodes_info["inherited_lines"] += stats["inherited_node_lines"]
                nodes_info["kinds"].update(stats["kinds"])
            for prow in plan_step_rows(sid, rec):
                pw.writerow([prow[c] for c in PLAN_STEP_COLUMNS])
                plan_rows += 1
    nodes_info["kinds"] = dict(sorted(nodes_info["kinds"].items()))
    logs = {p.name[: -len(".nodes.jsonl")] for p in sdir.iterdir() if p.name.endswith(".nodes.jsonl")}
    manifest["sessions"].update({
        "transcripts_without_record": len(logs - set(records)),
        "rows": len(ordered),
        "plan_step_rows": plan_rows,
        "by_kind": dict(sorted(by_kind.items())),
        "supervisor_flag_by_kind": {f"{k}/{s}": n for (k, s), n in sorted(by_sup.items())},
    })
    return True


def num_or_zero(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


# --------------------------------------------------------------------------
# tasks

def norm_dir(path) -> str:
    return os.path.realpath(os.path.expanduser(str(path))).rstrip("/")


def read_task_store(path: Path):
    """Return (owner, records) of a task store file; raises on unreadable JSON.

    A repository store is `{"state-directory": OWNER, "tasks": [...]}`, the
    global store a bare array of records (harness-tasks.el, `--open-store`).
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict):
        return data.get("state-directory"), [r for r in as_list(data.get("tasks")) if isinstance(r, dict)]
    return None, [r for r in as_list(data) if isinstance(r, dict)]


def collect_tasks(state_dir: Path, args, manifest):
    """Read the repository stores (registry + --task-store) and the global store.

    The harness reads repository stores first, then the global one, and the
    first copy of a task id wins; so does this.  A repository store that names
    another state directory that still exists belongs to another harness (a
    test run, say) and is left out unless asked for.
    """
    info = manifest["tasks"] = {"stores": [], "duplicates_ignored": 0}
    tasks, seen = [], set()
    mine = norm_dir(state_dir)

    stores = []  # (label, path, owner-checked)
    registry = state_dir / "task-stores.json"
    if registry.is_file():
        try:
            with open(registry, encoding="utf-8") as fh:
                for p in as_list(json.load(fh)):
                    if isinstance(p, str):
                        stores.append(("repository", Path(p), True))
            info["registry_entries"] = len(stores)
        except (OSError, ValueError):
            info["registry_unreadable"] = True
    else:
        info["registry_entries"] = None
    for p in args.task_store or []:
        stores.append(("explicit", Path(p), False))
    stores.append(("global", state_dir / "tasks.json", False))

    for label, path, check_owner in stores:
        entry = {"kind": label, "path": str(path), "tasks": 0}
        info["stores"].append(entry)
        if not path.is_file():
            entry["status"] = "missing"
            continue
        try:
            owner, records = read_task_store(path)
        except (OSError, ValueError):
            entry["status"] = "unparseable"
            continue
        if check_owner and isinstance(owner, str) and not args.include_foreign_task_stores:
            if norm_dir(owner) != mine and Path(owner).expanduser().is_dir():
                entry["status"] = "foreign (belongs to another state directory)"
                entry["tasks_in_file"] = len(records)
                continue
        entry["status"] = "read"
        for rec in records:
            tid = rec.get("id")
            if not isinstance(tid, str):
                continue
            if tid in seen:
                info["duplicates_ignored"] += 1
                continue
            seen.add(tid)
            tasks.append((label, rec))
            entry["tasks"] += 1
    return tasks


def task_row(label, rec, sessions):
    sid = rec.get("session")
    srec = sessions.get(sid) if isinstance(sid, str) else None
    sext = as_dict(srec.get("ext")) if srec else {}
    return {
        "task_id": tok(rec.get("id"), "id"),
        "session_id": tok(sid, "id"),
        "project": pth(rec.get("project")),
        "store": label,
        "state": tok(rec.get("state"), "enum"),
        "outcome": tok(rec.get("outcome"), "enum"),
        "created": num(rec.get("created")),
        "started": num(rec.get("started")),
        "finished": num(rec.get("finished")),
        "refined": num(rec.get("refined")),
        "merge_queued": num(rec.get("merge-queued")),
        "report_at": num(rec.get("report-at")),
        "verified_at": num(rec.get("verified-at")),
        "reopened": num(rec.get("reopened")),
        "returned": num(rec.get("returned")),
        "sent_back": num(rec.get("sent-back")),
        "return_reason": tok(rec.get("return-reason"), "enum"),
        "supervisor_setting": flag(rec.get("supervisor")) if "supervisor" in rec else "",
        "plan": flag(rec.get("plan")) if "plan" in rec else "",
        "backlog": flag(rec.get("backlog")),
        "main_tree": flag(rec.get("main-tree")),
        "adopted": flag(rec.get("adopted")),
        "non_interactive": flag(rec.get("non-interactive")),
        "model": tok(rec.get("model"), "model"),
        "thinking": tok(rec.get("thinking"), "enum"),
        "permission_mode": tok(rec.get("permission-mode"), "enum"),
        "priority": tok(rec.get("priority"), "enum"),
        "merged": flag(rec.get("merged")),
        "verified": flag(rec.get("verified")),
        "archived": flag(rec.get("archived")),
        "cannot_continue": flag(rec.get("cannot-continue")),
        "no_merge": flag(rec.get("no-merge")),
        "merge_attempts": num(rec.get("merge-attempts")),
        "session_found": "true" if srec is not None else "false",
        "session_kind": tok((srec.get("kind") or "main") if srec else None, "enum"),
        "session_supervisor": tri(sext.get("supervisor")) if srec else "",
        "session_created": num(srec.get("created")) if srec else "",
    }


def extract_tasks(state_dir: Path, out_dir: Path, sessions, args, manifest):
    tasks = collect_tasks(state_dir, args, manifest)
    tasks.sort(key=lambda lr: (num_or_zero(lr[1].get("created")), str(lr[1].get("id"))))
    by_state, by_sup, plan_flag, orphans = Counter(), Counter(), Counter(), 0
    with csv_out(out_dir / "tasks.csv", TASK_COLUMNS) as writer:
        for label, rec in tasks:
            row = task_row(label, rec, sessions)
            writer.writerow([row[c] for c in TASK_COLUMNS])
            by_state[row["state"]] += 1
            by_sup[(row["supervisor_setting"] or "absent", row["session_supervisor"] or "none")] += 1
            plan_flag[row["plan"] or "absent"] += 1
            orphans += row["session_found"] == "false"
    manifest["tasks"].update({
        "rows": len(tasks),
        "by_state": dict(sorted(by_state.items())),
        "task_setting_vs_session_flag": {f"task:{a}/session:{b}": n for (a, b), n in sorted(by_sup.items())},
        "plan_flag": dict(sorted(plan_flag.items())),
        "tasks_whose_session_record_is_missing": orphans,
    })
    return bool(tasks) or any(s["status"] == "read" for s in manifest["tasks"]["stores"])


# --------------------------------------------------------------------------
# data dictionary

def reference_epochs():
    marks = [
        ("supervisor mode added (73f987b)", "2026-10-08T15:24:17-04:00"),
        ("Plan mode added (b0a013d)", "2026-10-11T21:48:45-04:00"),
        ("supervisor cache-cost fix (0803841)", "2026-10-11T23:55:53-04:00"),
    ]
    return [(label, iso, dt.datetime.fromisoformat(iso).timestamp()) for label, iso in marks]


DATA_DICTIONARY = """\
# Data dictionary

Written by `scripts/analysis/extract_usage_data.py` on every run.  Blank cell =
JSON null / SQL NULL / key absent.  All timestamps are Unix epoch seconds (UTC,
float).  `true`/`false` are JSON booleans.  Nothing here is free text: ids, enum
values, flags, timestamps and numbers only.

## usage_rows.csv  (usage.db, table `usage`, one row per model call)

`id` (rowid), `ts`, `session` (session id; the session that made the call),
`project` (project root path), `model` (the session's model when the row was
written, which is not always the model that served the call, e.g. a compaction
summariser), `input`, `output`, `cache_read`, `cache_write` (token counts),
`cost` (what was billed; 0 under a subscription plan), `turn` (the session's
turn counter then), `list_cost` (API list-price equivalent; blank on rows written
before that column existed), `billing` (`api`/`subscription`/`extra-usage`, blank
on old rows).  Rows are ordered by `ts, id`.  A row is written for any session
that exists at that moment, `internal` ones (the calls the harness makes on its
own) and `btw`/`fork`/`subagent` ones included, under that session's own id.
Rows whose `session` has no record in sessions.csv exist: the harness keeps only
the newest 100 `internal` sessions and a deleted session leaves its rows behind,
so that cost cannot be walked up to a task.  If `usage.db` is absent the rows
come from `usage/records.jsonl` (ids prefixed `jsonl:`).

## sessions.csv  (sessions/<id>.json plus counts from <id>.nodes.jsonl)

- `session_id`; `kind` (`main`, `fork`, `subagent`, `btw`, `internal`; a record
  without one is `main`); `parent_id` = the record's `parent-id` (blank for a
  top-level session).  A session's parent is the session it was forked from or
  started for.  A supervisor's worker is a `subagent` whose `parent_id` is the
  supervisor, or, for a fork step that went through a seed, the *seed* (whose
  own `parent_id` is the supervisor): walk the chain.  Merge-queue conflict
  resolvers are `subagent`s of the task session too.
- `supervisor` = `ext.supervisor` of the record: `true` supervising, `false` an
  explicit hands-on, blank = no setting (sub-agents, side conversations,
  sessions older than the module).  This is the *resolved* flag: the judge or
  the user may have changed it after the session started.
  `supervisor_judge_pending` = `ext.supervisor-judge` (the session started
  supervising by default and a model has not yet judged it);
  `supervisor_write_up` = `ext.supervisor-write-up` (a backlog task's write-up
  session, not governed until the task starts); `seed` = `ext.seed` (a
  `subagent` that only holds a shared, cache-warming context for fork workers:
  it costs money but is not a worker).
- `model`, `thinking`, `permission_mode`, `non_interactive`, `project`, `status`
  (`idle`/`running`/`blocked`/`inactive`; `inactive` = closed).  There is no
  separate closed-at time: use `updated` (moves with every change) or
  `last_message` (moves with user/assistant messages only; blank before the
  first one).  `created` is when the record was made.
- `usage_*`: the cumulative usage the record itself carries (`usage` object:
  `input`, `output`, `cache-read`, `cache-write`, `cost`, `list-cost`, `turns`,
  `context`), for cross-checking usage.db.  usage.db is the ground truth.
- `plans`, `plan_steps`: how many supervisor plans / steps the session holds
  (`ext.supervisor-plans`); blank when the key is absent.
- Transcript counts (blank with `--no-nodes` or without a nodes file):
  `has_nodes_file`, `nodes_bytes`; `nodes`, `user_nodes`, `assistant_nodes`,
  `tool_calls` (`kind` = `tool-call`), `compactions`
  (`kind` = `compaction`), `compaction_input_tokens` (sum of the compaction
  nodes' `meta.input-tokens`, the size of what each replaced); `first_node_ts`,
  `last_node_ts` (min/max node `ts`); `bad_node_lines` (lines that did not parse
  and were skipped; 0-1 for a live session); `inherited_node_lines` (nodes a fork
  copied from its parent, which carry the parent's `session` value: *not*
  counted in any column above, so a fork does not inherit its parent's
  compactions).  Counts replay the log as the harness does: `_op: delete` lines
  remove a node.
  Compaction is a node of kind `compaction` (written by
  harness-compaction.el).  There is no counter in the session record.

## plan_steps.csv  (supervisor plans: ext.supervisor-plans)

One row per step of every plan of a session: `session_id` (the supervisor),
`plan_index`, `plan_id`, `plan_created`, `fork_tokens` (conversation size a fork
step would inherit, blank for plans without fork steps), `step_index`, `step_id`,
`tier` (`simple`/`medium`/`hard`), `context` (`fresh`/`fork`), `model` (the tier's
model), `worker_model` (the model the worker was made for), `thinking`, `state`
(`pending`/`running`/`done`/`failed`/`interrupted`/`cancelled`/`superseded`),
`worker_session_id` (the current attempt's worker; join to sessions.csv),
`attempts` (>1 = `retry_step` or a restart), `model_fallback`, `after_count`
(steps it waited for), `previous_session_id`/`previous_attempt` (the attempt
before).  Step titles, prompts, results and errors are not read.

## tasks.csv  (the task board)

Tasks are not in the state directory only.  A git project's tasks live in its
repository store `<git common dir>/harness/tasks.json`, an object
`{"state-directory": OWNER, "tasks": [...]}`; the registry
`<state dir>/task-stores.json` lists those files.  Other projects' tasks live in
the global store `<state dir>/tasks.json` (a bare array).  A store whose
`state-directory` names another existing directory belongs to another harness
and is skipped.  `store` says which kind a row came from (`repository`,
`explicit`, `global`); the first copy of an id wins, repository stores first.

`task_id`, `session_id` (= the task's `session`: its top-level session, made at
submission), `project`, `state` (persisted: `pending`, `refining`, `active`,
`review`, `done`; the board's *column* is derived from it and is not stored; a
task is in the done column when `state` = `done`), `outcome` (e.g. `merged`,
`end-turn`, `cancelled`, `merge-failed`), times: `created` (submission),
`started` (reset to blank when a task returns to pending), `finished`,
`refined` (write-up done), `merge_queued`, `report_at` (hand-in), `verified_at`,
`reopened` (a task in review/done was sent back or continued; `finished` is
cleared and set again by the rework), `returned` (put back in the queue),
`sent_back`; `return_reason`; flags: `supervisor_setting`
(the task's own `supervisor` key: only present when the submitter chose; blank
otherwise, which does *not* mean off), `plan` (Plan mode, the task's `plan` key
from commit b0a013d; blank = never planned), `backlog` (written up first),
`main_tree`, `adopted`, `non_interactive`, `merged`, `verified`, `archived`,
`cannot_continue`, `no_merge`; `model`, `thinking`, `permission_mode`,
`priority`, `merge_attempts`.  Joined from sessions: `session_found`,
`session_kind`, `session_supervisor` (the *resolved* flag, as `supervisor`
above; the one to classify by), `session_created`.

## Reading notes

- Classify a task by `session_supervisor` (the resolved flag of its top-level
  session), not by `supervisor_setting`, which most tasks do not carry.  A task
  is finished when `state` = `done`; `outcome` tells how (`cancelled` is not work
  that completed).
- A task's cost is the usage rows of its session and of every descendant by
  `parent_id`, seeds, merge-queue resolvers and `internal`/`btw` sessions
  included if they are wanted; usage.db has more rows than that tree holds (see
  the orphan note under usage_rows.csv).
- Costs, timestamps and counts are as recorded when the files were read; a
  running session keeps changing them.

## Reference times (epoch seconds, from git)

{reference}

## manifest.json

Counts and sources of the last run (rows per file, task stores read, lines
skipped, flag histograms).  Check it first.
"""


def write_dictionary(out_dir: Path):
    lines = [f"- {label}: {iso} = {epoch:.0f}" for label, iso, epoch in reference_epochs()]
    (out_dir / "data_dictionary.md").write_text(
        DATA_DICTIONARY.replace("{reference}", "\n".join(lines)), encoding="utf-8")


# --------------------------------------------------------------------------
# main

def parse_args(argv):
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="See the module docstring and the data_dictionary.md written next to the CSVs.")
    ap.add_argument("--state-dir", default=DEFAULT_STATE_DIR,
                    help="harness state directory (default %(default)s)")
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR),
                    help="where the CSVs go (default %(default)s; scripts/.dev/ is git-ignored)")
    ap.add_argument("--only", action="append", choices=SECTIONS,
                    help="extract only this part (repeatable); default all")
    ap.add_argument("--task-store", action="append", metavar="FILE",
                    help="an extra repository task store, e.g. REPO/.git/harness/tasks.json (repeatable)")
    ap.add_argument("--include-foreign-task-stores", action="store_true",
                    help="also read repository stores that name another state directory")
    ap.add_argument("--include-jsonl-usage", action="store_true",
                    help="append usage/records.jsonl rows to usage_rows.csv even when usage.db exists")
    ap.add_argument("--no-nodes", action="store_true",
                    help="do not scan transcripts (compaction and node counts stay blank)")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--self-test", action="store_true",
                    help="build a synthetic state directory, extract from it and check the result")
    ap.add_argument("--make-fixture", metavar="DIR",
                    help="write the synthetic state directory the self-test uses into the empty or new DIR, "
                         "to try an analysis script on a state directory of the right shape")
    return ap.parse_args(argv)


def run(args):
    os.umask(0o077)  # the CSVs are private to the user
    state_dir = Path(args.state_dir).expanduser()
    out_dir = Path(args.out_dir).expanduser()
    wanted = set(args.only or SECTIONS)
    manifest = {"script_version": SCRIPT_VERSION, "state_dir": str(state_dir),
                "extracted_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
                "sections": sorted(wanted)}
    failures = []

    needs_state = ("usage" in wanted or "sessions" in wanted
                   or ("tasks" in wanted and not args.task_store))
    if not state_dir.is_dir():
        if needs_state:
            print(f"error: state directory {state_dir} not found or not readable", file=sys.stderr)
            return 2
        say(args, f"warning: state directory {state_dir} not readable; reading only the given task stores")
    out_dir.mkdir(parents=True, exist_ok=True)
    write_dictionary(out_dir)
    # A part that fails must not leave an earlier run's file looking current.
    for section in wanted:
        for name in OUTPUT_FILES[section]:
            (out_dir / name).unlink(missing_ok=True)

    if "usage" in wanted:
        say(args, "usage.db ...")
        if not extract_usage(state_dir, out_dir, args, manifest):
            failures.append("usage")
    # Session records are also what tasks join to, so read them for either.
    records = {}
    if "sessions" in wanted or "tasks" in wanted:
        say(args, "session records ...")
        records = load_sessions(state_dir, manifest)
        if "sessions" not in wanted and "error" in manifest["sessions"]:
            # Only the join of tasks to their sessions is missing, not a failed part.
            manifest["sessions"]["note"] = manifest["sessions"].pop("error") + " (tasks are not joined to sessions)"
    if "sessions" in wanted:
        if records:
            say(args, f"{len(records)} sessions" + ("" if args.no_nodes else ", scanning transcripts ..."))
            extract_sessions(state_dir, out_dir, records, args, manifest)
        else:
            failures.append("sessions")
    if "tasks" in wanted:
        say(args, "tasks ...")
        if not extract_tasks(state_dir, out_dir, records, args, manifest):
            failures.append("tasks")

    manifest["values_replaced_by_other"] = dict(_sanitized)
    manifest["failed_parts"] = failures
    with open(out_dir / "manifest.json", "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")

    if not args.quiet:
        print(f"output directory: {out_dir}")
        for name, key in (("usage_rows.csv", "usage"), ("sessions.csv", "sessions"),
                          ("plan_steps.csv", "sessions"), ("tasks.csv", "tasks")):
            path = out_dir / name
            if key in wanted and path.exists():
                with open(path, encoding="utf-8") as fh:
                    print(f"  {name}: {sum(1 for _ in fh) - 1} rows")
        print("  manifest.json, data_dictionary.md")
    for part in failures:
        print(f"warning: nothing to read for {part}; see manifest.json", file=sys.stderr)
    return 1 if failures else 0


# --------------------------------------------------------------------------
# self test: a synthetic state directory shaped like the real one

def _jsonl(path: Path, lines):
    with open(path, "w", encoding="utf-8") as fh:
        for line in lines:
            fh.write((line if isinstance(line, str) else json.dumps(line)) + "\n")


def _write_json(path: Path, obj):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh)


def _read_json(path: Path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def build_fixture(root: Path):
    """Write a fake harness state directory under ROOT; return its paths.

    Every id and every piece of "private" text is made up.  The text fields
    carry LEAK- markers so the test can prove they never reach an output.
    """
    state = root / "state"
    repo_git = root / "repo" / ".git"
    sessions = state / "sessions"
    sessions.mkdir(parents=True)
    (repo_git / "harness").mkdir(parents=True)

    con = sqlite3.connect(state / "usage.db")
    con.execute("CREATE TABLE usage (id INTEGER PRIMARY KEY, ts REAL, session TEXT, project TEXT, model TEXT, "
                "input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER, cost REAL, turn INTEGER)")
    con.execute("ALTER TABLE usage ADD COLUMN list_cost REAL")  # an old database, migrated
    con.execute("ALTER TABLE usage ADD COLUMN billing TEXT")
    rows = [
        (1000.0, "S-hand", "/p/", "claude:sonnet", 10, 20, 30, 40, 0.5, 1, None, None),   # old row
        (1001.0, "S-sup", "/p/", "claude:opus", 1, 2, 3, 4, 0.25, 1, 0.25, "api"),
        (1002.0, "S-w1", "/p/", "claude:sonnet", 5, 6, 7, 8, 0.0, 1, 0.1, "subscription"),
        (1003.0, "S-gone", "/p/", "claude:haiku", 1, 1, 1, 1, 0.01, 1, 0.01, "api"),    # no record
    ]
    con.executemany("INSERT INTO usage (ts, session, project, model, input, output, cache_read, cache_write, "
                    "cost, turn, list_cost, billing) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    con.commit()
    con.close()

    def put(sid, **fields):
        rec = {"id": sid, "name": f"LEAK-name-{sid}", "kind": "main", "project": "/p/", "cwd": "/p/LEAK-cwd/",
               "model": "claude:sonnet", "permission-mode": "auto", "thinking": None, "non-interactive": False,
               "status": "idle", "parent-id": None, "created": 1000.0, "updated": 1100.0, "ext": None,
               "usage": {"input": 1, "output": 2, "cache-read": 3, "cache-write": 4, "cost": 0.5,
                         "list-cost": 0.5, "context": 99, "turns": 2},
               "last-message": 1090.0}
        rec.update(fields)
        (sessions / f"{sid}.json").write_text(json.dumps(rec), encoding="utf-8")

    plan = {"id": "p1", "title": "LEAK-plan-title", "summary": "LEAK-plan-summary", "created": 1010.0,
            "fork-tokens": 5000, "steps": [
                {"id": "s1", "title": "LEAK-step", "prompt": "LEAK-prompt", "tier": "medium", "context": "fresh",
                 "model": "claude:sonnet", "state": "done", "session": "S-w1", "attempts": 1,
                 "worker-model": "claude:sonnet", "result": "LEAK-result"},
                {"id": "s2", "title": "LEAK-step", "prompt": "LEAK-prompt", "tier": "simple", "context": "fork",
                 "model": "claude:haiku", "state": "done", "session": "S-w2", "attempts": 2, "after": ["s1"],
                 "previous": {"attempt": 1, "session": "S-w2-old", "model": "claude:haiku", "error": "LEAK-error"}}]}
    put("S-sup", created=2000.0, updated=2500.0, ext={"supervisor": True, "supervisor-plans": [plan]},
        usage={"input": 7, "output": 8, "cache-read": 9, "cache-write": 10, "cost": 1.5, "list-cost": 1.5,
               "context": 100, "turns": 5})
    put("S-seed", kind="subagent", **{"parent-id": "S-sup"}, created=2010.0, ext={"seed": True})
    put("S-w1", kind="subagent", **{"parent-id": "S-sup"}, created=2020.0)
    put("S-w2", kind="subagent", **{"parent-id": "S-seed"}, created=2030.0)
    put("S-btw", kind="btw", **{"parent-id": "S-sup"}, created=2040.0)
    put("S-int", kind="internal", **{"parent-id": "S-sup"}, created=2050.0)
    put("S-hand", created=1000.0, ext={"supervisor": False})
    put("S-fork", kind="fork", **{"parent-id": "S-hand"}, created=1500.0, ext={"supervisor": False})
    put("S-old", created=900.0)  # no ext at all: older than the module
    put("S-judge", created=3000.0, ext={"supervisor": True, "supervisor-judge": True})
    (sessions / "broken.json").write_text('{"id": "broken", "name": ', encoding="utf-8")  # unparseable

    def node(nid, kind, session, ts, **more):
        return {"kind": kind, "content": f"LEAK-text-{nid}", "id": nid, "session": session, "ts": ts,
                "parent": None, **more}

    comp = lambda nid, session, ts, tokens: node(  # noqa: E731
        nid, "compaction", session, ts,
        meta={"compaction": "brief", "input-tokens": tokens, "model": "claude:haiku", "context": "LEAK-ctx"})
    _jsonl(sessions / "S-sup.nodes.jsonl", [
        node("n1", "user", "S-sup", 2001.0),
        node("n2", "assistant", "S-sup", 2002.0),
        node("n3", "tool-call", "S-sup", 2003.0),
        comp("n4", "S-sup", 2004.0, 1234),
        comp("n5", "S-sup", 2005.0, 999),                      # discarded below
        {"_op": "delete", "id": "n5"},
        {"_op": "update", "id": "n3", "content": "LEAK-update"},
        "",                                                       # blank line
        '{"kind": "assistant", "content": "LEAK-half-writt',      # the live session's half-written last line
    ])
    _jsonl(sessions / "S-w2.nodes.jsonl", [
        node("n1", "user", "S-sup", 2001.0),                      # copied from the parent: not S-w2's own
        comp("n4", "S-sup", 2004.0, 1234),                        # the parent's compaction, inherited
        node("w2-1", "user", "S-w2", 2031.0),
        comp("w2-2", "S-w2", 2032.0, 777),                        # its own, e.g. a compacted fork
        node("w2-3", "assistant", "S-w2", 2033.0),
    ])

    tasks = [
        {"id": "t-aaaa0001", "project": "/p/", "cwd": "/p/", "prompt": "LEAK-prompt", "name": "LEAK-title",
         "note": "LEAK-note", "state": "done", "outcome": "merged", "created": 1990.0, "started": 2000.0,
         "finished": 2600.0, "merged": True, "verified": True, "verified-at": 2700.0, "session": "S-sup",
         "supervisor": True, "branch": "task/LEAK-branch", "worktree": "/p/.claude/worktrees/LEAK",
         "report": {"summary": "LEAK-report"}, "report-at": 2590.0, "merge-attempts": 1},
        {"id": "t-bbbb0002", "project": "/p/", "state": "done", "outcome": "end-turn", "created": 995.0,
         "started": 1000.0, "finished": 1300.0, "session": "S-hand", "supervisor": False, "archived": True},
        {"id": "t-cccc0003", "project": "/p/", "state": "pending", "created": 3000.0, "session": "S-judge",
         "plan": True, "backlog": True, "refine-model": "LEAK-model name"},
        {"id": "t-dddd0004", "project": "/p/", "state": "active", "created": 3100.0, "started": 3110.0,
         "session": "S-missing", "priority": "high", "feedback": ["LEAK-feedback"]},
    ]
    _write_json(repo_git / "harness" / "tasks.json", {"state-directory": str(state) + "/", "tasks": tasks})
    foreign_state = root / "other-state"
    foreign_state.mkdir()
    foreign = repo_git.parent / "foreign-store.json"
    _write_json(foreign, {"state-directory": str(foreign_state) + "/",
                          "tasks": [{"id": "t-ffff0009", "state": "done", "session": "x", "prompt": "LEAK-foreign"}]})
    _write_json(state / "task-stores.json", [str(repo_git / "harness" / "tasks.json"), str(foreign)])
    _write_json(state / "tasks.json", [
        {"id": "t-gggg0005", "project": "/nogit/", "state": "done", "outcome": "merged", "created": 500.0,
         "session": "S-old", "name": "LEAK-title"},
        {"id": "t-aaaa0001", "project": "/p/", "state": "pending", "created": 1.0, "session": "S-sup"},  # older copy
    ])
    return state


def _read_csv(path: Path):
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def self_test():
    failures = []

    def check(name, got, want):
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    with tempfile.TemporaryDirectory(prefix="extract-selftest-") as tmp:
        root = Path(tmp)
        state = build_fixture(root)
        out = root / "out"
        rc = run(parse_args(["--state-dir", str(state), "--out-dir", str(out), "--quiet"]))
        check("exit status", rc, 0)

        usage = _read_csv(out / "usage_rows.csv")
        check("usage columns", list(usage[0].keys()), USAGE_COLUMNS)
        check("usage rows", len(usage), 4)
        check("old row has blank list_cost/billing", (usage[0]["list_cost"], usage[0]["billing"]), ("", ""))
        check("new row", (usage[1]["session"], usage[1]["list_cost"], usage[1]["billing"]), ("S-sup", "0.25", "api"))

        sess = {r["session_id"]: r for r in _read_csv(out / "sessions.csv")}
        check("session count (broken.json skipped)", len(sess), 10)
        check("supervisor flags",
              {k: sess[k]["supervisor"] for k in ("S-sup", "S-hand", "S-old", "S-w1", "S-judge")},
              {"S-sup": "true", "S-hand": "false", "S-old": "", "S-w1": "", "S-judge": "true"})
        check("judge pending", (sess["S-judge"]["supervisor_judge_pending"], sess["S-sup"]["supervisor_judge_pending"]),
              ("true", ""))
        check("seed mark", (sess["S-seed"]["seed"], sess["S-w1"]["seed"]), ("true", ""))
        check("kind/parent", (sess["S-w2"]["kind"], sess["S-w2"]["parent_id"], sess["S-fork"]["kind"],
                              sess["S-sup"]["parent_id"]), ("subagent", "S-seed", "fork", ""))
        check("plans/steps", (sess["S-sup"]["plans"], sess["S-sup"]["plan_steps"], sess["S-w1"]["plans"]),
              ("1", "2", ""))
        check("S-sup compactions (deleted one not counted)", sess["S-sup"]["compactions"], "1")
        check("S-sup compaction tokens", sess["S-sup"]["compaction_input_tokens"], "1234")
        check("S-sup nodes", (sess["S-sup"]["nodes"], sess["S-sup"]["user_nodes"], sess["S-sup"]["assistant_nodes"],
                              sess["S-sup"]["tool_calls"]), ("4", "1", "1", "1"))
        check("S-sup half-written line skipped", sess["S-sup"]["bad_node_lines"], "1")
        check("fork does not inherit parent's compaction", sess["S-w2"]["compactions"], "1")
        check("fork's own compaction tokens", sess["S-w2"]["compaction_input_tokens"], "777")
        check("fork inherited lines", sess["S-w2"]["inherited_node_lines"], "2")
        check("fork nodes", sess["S-w2"]["nodes"], "3")
        check("node ts range", (sess["S-w2"]["first_node_ts"], sess["S-w2"]["last_node_ts"]), ("2031.0", "2033.0"))
        check("no transcript", (sess["S-hand"]["has_nodes_file"], sess["S-hand"]["compactions"]), ("false", ""))
        check("usage snapshot", (sess["S-sup"]["usage_cost"], sess["S-sup"]["usage_turns"]), ("1.5", "5"))
        check("sessions ordered by created", [r["session_id"] for r in _read_csv(out / "sessions.csv")][:3],
              ["S-old", "S-hand", "S-fork"])

        steps = _read_csv(out / "plan_steps.csv")
        check("plan step rows", len(steps), 2)
        check("plan step 2", (steps[1]["step_id"], steps[1]["context"], steps[1]["worker_session_id"],
                              steps[1]["attempts"], steps[1]["after_count"], steps[1]["previous_session_id"]),
              ("s2", "fork", "S-w2", "2", "1", "S-w2-old"))

        tasks = {r["task_id"]: r for r in _read_csv(out / "tasks.csv")}
        check("tasks (foreign store left out, duplicate id once)", sorted(tasks),
              ["t-aaaa0001", "t-bbbb0002", "t-cccc0003", "t-dddd0004", "t-gggg0005"])
        check("repository copy wins over global", (tasks["t-aaaa0001"]["state"], tasks["t-aaaa0001"]["store"]),
              ("done", "repository"))
        check("global store task", tasks["t-gggg0005"]["store"], "global")
        a = tasks["t-aaaa0001"]
        check("task a", (a["session_id"], a["supervisor_setting"], a["plan"], a["merged"], a["session_supervisor"],
                         a["session_found"], a["session_created"], a["merge_attempts"]),
              ("S-sup", "true", "", "true", "true", "true", "2000.0", "1"))
        check("task b flags", (tasks["t-bbbb0002"]["supervisor_setting"], tasks["t-bbbb0002"]["archived"],
                               tasks["t-bbbb0002"]["session_supervisor"]), ("false", "true", "false"))
        c = tasks["t-cccc0003"]
        check("plan-mode task", (c["plan"], c["backlog"], c["session_supervisor"], c["supervisor_setting"]),
              ("true", "true", "true", ""))
        d = tasks["t-dddd0004"]
        check("task with no session record", (d["session_found"], d["session_supervisor"], d["priority"]),
              ("false", "", "high"))

        manifest = _read_json(out / "manifest.json")
        check("manifest failed parts", manifest["failed_parts"], [])
        mu = manifest["usage"]
        check("manifest usage figures",
              (mu["rows"], mu["distinct_sessions"], round(mu["sum_cost"], 6), round(mu["sum_list_cost"], 6),
               mu["first_ts"], mu["last_ts"], mu["rows_by_billing"]),
              (4, 4, 0.76, 0.36, 1000.0, 1003.0, {"": 1, "api": 2, "subscription": 1}))
        check("manifest unparseable", manifest["sessions"]["unparseable"], ["broken"])
        check("manifest task stores (registry: repository, foreign; then global)",
              [s["status"].split(" ")[0] for s in manifest["tasks"]["stores"]],
              ["read", "foreign", "read"])

        # Privacy: no marker of the fake free text may be in any output.
        leaks = [p.name for p in sorted(out.iterdir()) if "LEAK" in p.read_text(encoding="utf-8")]
        check("no free text in any output", leaks, [])

        # The state directory is only read.
        before = sorted((p.name, p.stat().st_mtime_ns) for p in state.rglob("*") if p.is_file())
        run(parse_args(["--state-dir", str(state), "--out-dir", str(out), "--quiet"]))
        after = sorted((p.name, p.stat().st_mtime_ns) for p in state.rglob("*") if p.is_file())
        check("state directory untouched", before, after)

        # --only tasks with an explicit store and no state directory.
        out2 = root / "out2"
        rc = run(parse_args(["--state-dir", str(root / "nope"), "--out-dir", str(out2), "--only", "tasks",
                             "--task-store", str(root / "repo" / ".git" / "harness" / "tasks.json"), "--quiet"]))
        check("tasks-only exit status", rc, 0)
        t2 = _read_csv(out2 / "tasks.csv")
        check("tasks-only rows", len(t2), 4)
        check("tasks-only has no session join", {r["session_found"] for r in t2}, {"false"})
        check("tasks-only wrote no usage", (out2 / "usage_rows.csv").exists(), False)

        # A missing state directory is a usage error.
        with contextlib.redirect_stderr(io.StringIO()) as err:
            status = run(parse_args(["--state-dir", str(root / "nope"), "--out-dir", str(root / "o3"), "--quiet"]))
        check("missing state dir", (status, "not found or not readable" in err.getvalue()), (2, True))

    if failures:
        print("self-test FAILED:", file=sys.stderr)
        for line in failures:
            print("  " + line, file=sys.stderr)
        return 1
    print("self-test ok")
    return 0


def make_fixture(directory):
    root = Path(directory).expanduser()
    if root.exists() and (not root.is_dir() or any(root.iterdir())):
        print(f"error: {root} exists and is not an empty directory", file=sys.stderr)
        return 2
    root.mkdir(parents=True, exist_ok=True)
    state = build_fixture(root)
    print(f"synthetic state directory (made-up ids and numbers, no real data): {state}")
    print(f"try: {sys.argv[0]} --state-dir {state} --out-dir {root / 'out'}")
    return 0


def main(argv=None):
    args = parse_args(argv)
    if args.self_test:
        return self_test()
    if args.make_fixture:
        return make_fixture(args.make_fixture)
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
