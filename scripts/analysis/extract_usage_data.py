#!/usr/bin/env python3
"""Turn the raw task and session dumps of the usage analysis into two CSV files.

This script is an ordinary, re-runnable converter.  It reads two local JSON
Lines files and writes ``tasks.csv`` and ``sessions.csv``:

    --tasks-raw     (default scripts/.dev/usage-analysis/raw/tasks_raw.jsonl)
    --sessions-raw  (default scripts/.dev/usage-analysis/raw/sessions_raw.jsonl)
    --out-dir       (default scripts/.dev/usage-analysis/)

HOW THE RAW FILES ARE MADE -- READ THIS FIRST
---------------------------------------------
The harness state directory (~/.emacs.d/.local/cache/harness/) is not visible
to ``bash`` or to any script run from it, and a non-interactive agent session
can never be granted that directory.  So the two raw files cannot be produced
by this script (or any other script run from the sandbox) reading that
directory.  An agent gathers them first, with tools that can see it:

* tasks_raw.jsonl: this project's task store is inside the working tree
  (.git/harness/tasks.json), so ``--gather-tasks`` below does it directly.
* sessions_raw.jsonl: one JSON object per session of every task of the
  project and of every session descended from a task's session through
  ``parent-id`` (any kind; the kind is recorded, and only ``subagent`` and
  ``fork`` sessions are workers).  A session record is ONE long JSON line
  (the supervisor plans in ``ext`` make it tens of kilobytes), and the grep
  tool shows only the first ~400 characters of a line, so ``parent-id``,
  ``created`` and ``usage`` cannot be read with grep, and read_file output is
  cut at ~45 000 characters.  The records are therefore read through the
  harness's own API, which the ``emacs_eval`` tool allows
  (``(harness-call 'session/list)``, ``'task/list``, and
  ``'usage/summary :group-by 'session`` for the usage ledger), picking a fixed
  list of fields.  ``--print-gather-recipe`` prints the Elisp that was run,
  with the output path, the project directory and the two compaction-count
  strings left for you to fill in.  Compaction counts come from ``grep``
  over sessions/<id>.nodes.jsonl (the recipe's header says how).  Nothing
  but ids, enum-like strings, flags, timestamps and numbers goes into a
  raw file.

Run ``--self-test`` to check the converter against a synthetic fixture.

PRIVACY: only ids, enum-like strings (kind, status, model id, billing),
flags, timestamps and numbers are written.  A task's prompt, a task's or a
session's name, working directories, worktree and branch names belong in
neither the raw files nor the CSVs: rows are rebuilt from a fixed list of
fields, unknown fields are dropped (their names are reported, never their
values), and a string that should be an id or an enum but does not look
like one is replaced by ``<other>``.  Output files are created owner-only.

CSV FORMAT: timestamps are Unix epoch seconds (floats, as recorded); booleans
are ``true``/``false``; an empty cell is "absent / unknown / null", never 0.

tasks.csv columns:
    id, session, created, started, finished, state, outcome, merged, model,
    non_interactive, supervisor, plan
  ``supervisor`` is the raw ``supervisor`` key of the task record.  It is
  written only when a task is submitted with an explicit setting, so empty
  means "took the default when it started"; the authoritative flag is the
  task session's ``supervisor`` in sessions.csv.  ``plan`` is the raw ``plan``
  key of Plan mode (commit b0a013d); it is empty for every task of this
  project's store.

sessions.csv columns (the first 18 are the contract, the rest are extras):
    id, kind, parent_id, created, updated, status, model, non_interactive,
    supervisor, input, output, cache_read, cache_write, cost, list_cost,
    billing, turns, compactions,
    forked, ledger_input, ledger_output, ledger_cache_read,
    ledger_cache_write, ledger_cost, ledger_list_cost, ledger_calls
  ``supervisor`` is the session's ``ext.supervisor``: true, false (explicit
  hands-on) or empty (the session is not governed: sub-agents, side
  conversations, sessions older than the module).  input..turns are the
  cumulative totals the session record carries; ``list_cost`` is empty when
  the record has none (older sessions).  ``compactions`` is the number of
  compactions that session itself made: harness ``compaction`` nodes plus
  "Context compacted by Claude Code" hints, each counted only in the session
  that created the node (a fork's log starts with copies of its parent's
  nodes).  ``forked`` is true when the session started as a fork of its
  parent's conversation.  The ``ledger_*`` columns are the totals of the
  usage ledger (usage.db) for the session; they exist because the session
  record and the ledger disagree for some sessions (see the analysis report).
  Rows of kind ``internal`` are the records of the harness's own model calls
  (permission judge, naming ...).  The harness prunes them over time, so
  their totals are not comparable between tasks; only ``subagent`` and
  ``fork`` rows are workers.

Python 3 standard library only.  No network.

Exit status: 0 done; 1 an input file is missing or unreadable, or --strict
found an integrity problem; 2 usage error.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import sys
import tempfile
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT_DIR = REPO_ROOT / "scripts" / ".dev" / "usage-analysis"
DEFAULT_TASKS_RAW = DEFAULT_OUT_DIR / "raw" / "tasks_raw.jsonl"
DEFAULT_SESSIONS_RAW = DEFAULT_OUT_DIR / "raw" / "sessions_raw.jsonl"
DEFAULT_TASK_STORE = REPO_ROOT / ".git" / "harness" / "tasks.json"

OTHER = "<other>"

# Raw task keys that are kept, in column order, and the columns they become.
TASK_KEYS = ["id", "session", "created", "started", "finished", "state",
             "outcome", "merged", "model", "non-interactive", "supervisor", "plan"]
TASK_COLUMNS = [k.replace("-", "_") for k in TASK_KEYS]

USAGE_KEYS = ["input", "output", "cache-read", "cache-write", "cost", "list-cost",
              "billing", "turns"]
LEDGER_KEYS = ["input", "output", "cache-read", "cache-write", "cost", "list-cost", "calls"]
SESSION_TOP_KEYS = ["id", "kind", "parent-id", "forked", "created", "updated", "status",
                    "model", "non-interactive", "supervisor", "usage", "ledger",
                    "compactions-harness", "compactions-cli"]
SESSION_COLUMNS = (
    ["id", "kind", "parent_id", "created", "updated", "status", "model", "non_interactive",
     "supervisor", "input", "output", "cache_read", "cache_write", "cost", "list_cost",
     "billing", "turns", "compactions"]
    + ["forked"]
    + ["ledger_" + k.replace("-", "_") for k in LEDGER_KEYS])

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TASK_ID_RE = re.compile(r"^t-[0-9a-z]{4,16}$")
ENUM_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._+-]{0,63}$")


class InputError(Exception):
    """A raw file is missing, unreadable or not JSON Lines."""


# --------------------------------------------------------------------------
# Value hygiene.  Every value that reaches a CSV goes through one of these.

def clean_str(value, regex) -> str:
    """Return VALUE if it is a string matching REGEX, '' if None, else OTHER."""
    if value is None:
        return ""
    if isinstance(value, str) and regex.match(value):
        return value
    return OTHER


def clean_num(value) -> str:
    """Return a number as text, '' for None, OTHER for anything else."""
    if value is None:
        return ""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return OTHER
    if isinstance(value, float) and not math.isfinite(value):
        return OTHER
    return repr(value)


def clean_bool(value) -> str:
    """Return 'true' or 'false' for a bool, '' for None, OTHER otherwise."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return OTHER


def read_jsonl(path: Path) -> list:
    """Return the objects of the JSON Lines file PATH."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as err:
        raise InputError(f"cannot read {path}: {err.strerror or err}") from err
    rows = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as err:
            raise InputError(f"{path}:{number}: not JSON: {err.msg}") from err
        if not isinstance(obj, dict):
            raise InputError(f"{path}:{number}: not a JSON object")
        rows.append(obj)
    return rows


def write_csv(path: Path, header: list, rows: list) -> None:
    """Write ROWS (lists of cells) to PATH, owner-only."""
    old = os.umask(0o077)
    try:
        with open(path, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, lineterminator="\n")
            writer.writerow(header)
            writer.writerows(rows)
    finally:
        os.umask(old)


class Report:
    """Collects what was dropped or replaced, to say it once at the end."""

    def __init__(self) -> None:
        self.dropped_keys: Counter = Counter()
        self.warnings: list = []

    def note_unknown(self, where: str, record: dict, known) -> None:
        for key in record:
            if key not in known:
                self.dropped_keys[f"{where}.{key}"] += 1

    def warn(self, message: str) -> None:
        self.warnings.append(message)


# --------------------------------------------------------------------------
# Tasks.

def gather_tasks(store: Path, out: Path) -> int:
    """Write the whitelisted fields of every task of STORE to OUT; return the count.

    STORE is a project's task store (.git/harness/tasks.json): an object with
    a "tasks" array, or a bare array.  A key a task does not carry is left
    out of its line, so absent stays distinguishable from null.
    """
    try:
        data = json.loads(store.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as err:
        raise InputError(f"cannot read the task store {store}: {err}") from err
    tasks = data.get("tasks") if isinstance(data, dict) else data
    if not isinstance(tasks, list):
        raise InputError(f"{store}: no task list")
    lines = []
    for task in tasks:
        lines.append(json.dumps({k: task[k] for k in TASK_KEYS if k in task},
                                separators=(",", ":"), sort_keys=False))
    out.parent.mkdir(parents=True, exist_ok=True)
    old = os.umask(0o077)
    try:
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    finally:
        os.umask(old)
    have_sup = sum(1 for t in tasks if "supervisor" in t)
    have_plan = sum(1 for t in tasks if "plan" in t)
    print(f"{len(lines)} tasks -> {out}  ('supervisor' key on {have_sup}, 'plan' key on {have_plan})")
    return len(lines)


def task_row(task: dict, report: Report) -> list:
    report.note_unknown("tasks_raw", task, TASK_KEYS)
    return [
        clean_str(task.get("id"), TASK_ID_RE),
        clean_str(task.get("session"), UUID_RE),
        clean_num(task.get("created")),
        clean_num(task.get("started")),
        clean_num(task.get("finished")),
        clean_str(task.get("state"), ENUM_RE),
        clean_str(task.get("outcome"), ENUM_RE),
        clean_bool(task.get("merged")),
        clean_str(task.get("model"), ENUM_RE),
        clean_bool(task.get("non-interactive")),
        clean_bool(task.get("supervisor")),
        clean_bool(task.get("plan")),
    ]


# --------------------------------------------------------------------------
# Sessions.

def compactions(session: dict) -> str:
    """Return the session's own compaction count as text, '' when unknown."""
    parts = [session.get("compactions-harness"), session.get("compactions-cli")]
    if any(p is None for p in parts):
        return ""
    if not all(isinstance(p, int) and not isinstance(p, bool) and p >= 0 for p in parts):
        return OTHER
    return str(sum(parts))


def session_row(session: dict, report: Report) -> list:
    report.note_unknown("sessions_raw", session, SESSION_TOP_KEYS)
    usage = session.get("usage") or {}
    ledger = session.get("ledger") or {}
    if not isinstance(usage, dict) or not isinstance(ledger, dict):
        usage, ledger = {}, {}
    report.note_unknown("sessions_raw.usage", usage, USAGE_KEYS)
    report.note_unknown("sessions_raw.ledger", ledger, LEDGER_KEYS)
    return [
        clean_str(session.get("id"), UUID_RE),
        clean_str(session.get("kind"), ENUM_RE),
        clean_str(session.get("parent-id"), UUID_RE),
        clean_num(session.get("created")),
        clean_num(session.get("updated")),
        clean_str(session.get("status"), ENUM_RE),
        clean_str(session.get("model"), ENUM_RE),
        clean_bool(session.get("non-interactive")),
        clean_bool(session.get("supervisor")),
        clean_num(usage.get("input")),
        clean_num(usage.get("output")),
        clean_num(usage.get("cache-read")),
        clean_num(usage.get("cache-write")),
        clean_num(usage.get("cost")),
        clean_num(usage.get("list-cost")),
        clean_str(usage.get("billing"), ENUM_RE),
        clean_num(usage.get("turns")),
        compactions(session),
        clean_bool(session.get("forked")),
    ] + [clean_num(ledger.get(k)) for k in LEDGER_KEYS]


def integrity(tasks: list, sessions: list, report: Report) -> int:
    """Check ids and links; add warnings to REPORT; return the problem count."""
    problems = 0
    for what, rows, col in (("task", tasks, 0), ("session", sessions, 0)):
        ids = [r[col] for r in rows]
        dup = [i for i, n in Counter(ids).items() if n > 1]
        if dup:
            problems += 1
            report.warn(f"{len(dup)} duplicate {what} ids")
        if OTHER in ids or "" in ids:
            problems += 1
            report.warn(f"{what} rows without a well-formed id")
    session_ids = {r[0] for r in sessions}
    missing = [r[1] for r in tasks if r[1] not in session_ids]
    if missing:
        problems += 1
        report.warn(f"{len(missing)} task sessions are not in sessions.csv")
    orphans = [r[2] for r in sessions if r[2] and r[2] not in session_ids]
    if orphans:
        problems += 1
        report.warn(f"{len(orphans)} sessions have a parent-id that is not in sessions.csv")
    return problems


def convert(tasks_raw: Path, sessions_raw: Path, out_dir: Path, strict: bool = False) -> int:
    """Write tasks.csv and sessions.csv to OUT_DIR; return the exit status."""
    report = Report()
    tasks = [task_row(t, report) for t in read_jsonl(tasks_raw)]
    sessions = [session_row(s, report) for s in read_jsonl(sessions_raw)]
    problems = integrity(tasks, sessions, report)
    out_dir.mkdir(parents=True, exist_ok=True)
    write_csv(out_dir / "tasks.csv", TASK_COLUMNS, tasks)
    write_csv(out_dir / "sessions.csv", SESSION_COLUMNS, sessions)
    print(f"tasks.csv     {len(tasks):5d} rows  {out_dir / 'tasks.csv'}")
    print(f"sessions.csv  {len(sessions):5d} rows  {out_dir / 'sessions.csv'}")
    print("task states:  " + ", ".join(f"{k}={v}" for k, v in sorted(Counter(r[5] for r in tasks).items())))
    kinds = Counter(r[1] for r in sessions)
    print("session kinds: " + ", ".join(f"{k}={v}" for k, v in sorted(kinds.items())))
    replaced = sum(1 for row in tasks + sessions for cell in row if cell == OTHER)
    if replaced:
        report.warn(f"{replaced} cells did not look like an id, enum or number and were replaced by {OTHER}")
    if report.dropped_keys:
        names = ", ".join(f"{k} x{n}" for k, n in sorted(report.dropped_keys.items()))
        report.warn(f"dropped fields that are not on the whitelist (names only): {names}")
    for message in report.warnings:
        print(f"warning: {message}", file=sys.stderr)
    return 1 if strict and problems else 0


# --------------------------------------------------------------------------
# The recipe an agent runs to make sessions_raw.jsonl.

GATHER_RECIPE = r''';;; gather_sessions_raw.el --- make sessions_raw.jsonl  -*- lexical-binding: t; -*-
;;
;; Run with the emacs_eval tool (the user's live Emacs; the harness server is
;; reached through `harness-call').  It writes ids, enum strings, flags and
;; numbers only: never `:name', `:cwd', `:worktree', `:project' or a plan.
;;
;; Fill in OUT, PROJECT (the project directory whose task board it is) and the
;; two count strings before running:
;;   HC-STR   "id8:n id8:n ..."  harness `compaction' nodes each session made
;;   CLI-STR  "id8:n id8:n ..."  "Context compacted by Claude Code" hints each
;;                               session made
;; They come from grep over ~/.emacs.d/.local/cache/harness/sessions/*.nodes.jsonl
;; (the grep and read_file tools can read it; bash cannot):
;;  * CLI hints: pattern  ^\{"kind":"hint","content":"Context compacted by Claude Code"
;;    The whole short line is shown, including "session":"<creator>".  Count a
;;    line for the session it names there, NOT for the file it is in: a fork's
;;    node log starts with copies of its parent's nodes (session/fork), so one
;;    node appears in many files.  Chunk the grep by the first character of the
;;    file name (glob 0*.nodes.jsonl ... f*.nodes.jsonl) and check each chunk's
;;    "(N matches)".
;;  * `compaction' nodes: the line is cut at ~400 characters before its
;;    "session" field, so ownership cannot be read.  Instead group the sessions
;;    by fork depth (task session = 0, its sub-agents = 1, theirs = 2 ...): no
;;    session of one depth is an ancestor of another, so within a depth a copy
;;    is never attributed to a session of the same depth.  For each depth run
;;      glob     {id8,id8,...}-*.nodes.jsonl
;;      pattern  ^\{"kind":"compaction".*"session":"(id8|id8|...)-
;;    (depth 0 never has copies, so its pattern may stop at "compaction").
;;    Each match is one node that session made.  Try the pattern on a known
;;    session and on a fork of it first.
;;
;; The usage ledger totals per session (usage.db) come from
;;   (harness-call 'usage/summary :group-by 'session)
(let* ((out "/ABSOLUTE/PATH/TO/REPO/scripts/.dev/usage-analysis/raw/sessions_raw.jsonl")
       (hc-str "")
       (cli-str "")
       (parse (lambda (str)
                (let ((h (make-hash-table :test 'equal)))
                  (dolist (e (split-string str " " t))
                    (let ((p (split-string e ":")))
                      (puthash (car p) (+ (gethash (car p) h 0) (string-to-number (cadr p))) h)))
                  h)))
       (hc (funcall parse hc-str))
       (cli (funcall parse cli-str))
       (project "/ABSOLUTE/PATH/TO/REPO/")
       (sessions (harness-call 'session/list))
       (tasks (harness-call 'task/list project))
       (ledger-rows (harness-call 'usage/summary :group-by 'session))
       (ledger (make-hash-table :test 'equal))
       (by-id (make-hash-table :test 'equal))
       (children (make-hash-table :test 'equal))
       (relevant (make-hash-table :test 'equal))
       (queue nil) (rows nil)
       (tri (lambda (v) (cond ((null v) :null) ((eq v t) t) (t :false))))
       (bill (lambda (b) (cond ((null b) :null) ((stringp b) b) ((symbolp b) (symbol-name b)) (t :null))))
       (num (lambda (v) (if (numberp v) v 0)))
       (numn (lambda (v) (if (numberp v) v :null))))
  (dolist (r ledger-rows) (puthash (plist-get r :key) r ledger))
  (dolist (s sessions)
    (puthash (plist-get s :id) s by-id)
    (when (plist-get s :parent-id)
      (push (plist-get s :id) (gethash (plist-get s :parent-id) children))))
  ;; Every task session, and everything below it through :parent-id.
  (dolist (tk tasks) (puthash (plist-get tk :session) t relevant) (push (plist-get tk :session) queue))
  (while queue
    (let ((cur (pop queue)))
      (dolist (c (gethash cur children))
        (unless (gethash c relevant) (puthash c t relevant) (push c queue)))))
  (maphash
   (lambda (id _)
     (let* ((s (gethash id by-id)) (u (plist-get s :usage)) (l (gethash id ledger))
            (id8 (substring id 0 8))
            (kind (format "%s" (plist-get s :kind)))
            (internal (equal kind "internal"))
            (sup (plist-get (plist-get s :ext) :supervisor)))
       (push (list :id id :kind kind
                   :parent-id (or (plist-get s :parent-id) :null)
                   :forked (if (plist-get s :fork-node) t :false)
                   :created (plist-get s :created) :updated (plist-get s :updated)
                   :status (format "%s" (plist-get s :status))
                   :model (or (plist-get s :model) :null)
                   :non-interactive (funcall tri (plist-get s :non-interactive))
                   :supervisor (funcall tri sup)
                   :usage (list :input (funcall num (plist-get u :input))
                                :output (funcall num (plist-get u :output))
                                :cache-read (funcall num (plist-get u :cache-read))
                                :cache-write (funcall num (plist-get u :cache-write))
                                :cost (funcall num (plist-get u :cost))
                                :list-cost (funcall numn (plist-get u :list-cost))
                                :billing (funcall bill (plist-get u :billing))
                                :turns (funcall num (plist-get u :turns)))
                   :ledger (if l
                               (list :input (funcall num (plist-get l :input))
                                     :output (funcall num (plist-get l :output))
                                     :cache-read (funcall num (plist-get l :cache-read))
                                     :cache-write (funcall num (plist-get l :cache-write))
                                     :cost (funcall num (plist-get l :cost))
                                     :list-cost (funcall num (plist-get l :list-cost))
                                     :calls (funcall num (plist-get l :calls)))
                             :null)
                   ;; An internal session is one model call: it never compacts.
                   :compactions-harness (if internal 0 (gethash id8 hc 0))
                   :compactions-cli (if internal 0 (gethash id8 cli 0)))
             rows)))
   relevant)
  (setq rows (sort rows (lambda (a b)
                          (let ((ca (plist-get a :created)) (cb (plist-get b :created)))
                            (or (< ca cb) (and (= ca cb) (string< (plist-get a :id) (plist-get b :id))))))))
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file out
      (dolist (r rows) (insert (json-serialize r) "\n"))))
  (length rows))
'''


# --------------------------------------------------------------------------
# Self-test.

def self_test() -> int:
    """Run the converter on a synthetic fixture and check the result."""
    sid = ["aaaaaaaa-0000-4000-8000-%012d" % n for n in range(1, 6)]
    tasks = [
        {"id": "t-aaaa1111", "session": sid[0], "created": 1.5, "started": 2.5, "finished": 9.0,
         "state": "done", "outcome": "merged", "merged": True, "model": "claude:opus",
         "non-interactive": True, "supervisor": True,
         # fields that must never reach a CSV
         "prompt": "SECRET PROMPT TEXT", "name": "SECRET NAME", "branch": "task/secret-branch",
         "worktree": "/home/someone/secret"},
        {"id": "t-bbbb2222", "session": sid[3], "created": 3.0, "started": None, "finished": None,
         "state": "pending", "outcome": None, "merged": None, "model": None},
    ]
    sessions = [
        {"id": sid[0], "kind": "main", "parent-id": None, "forked": False, "created": 1.5,
         "updated": 8.0, "status": "inactive", "model": "claude:opus", "non-interactive": True,
         "supervisor": True,
         "usage": {"input": 10, "output": 20, "cache-read": 30, "cache-write": 40, "cost": 0.0,
                   "list-cost": 1.25, "billing": "subscription", "turns": 3},
         "ledger": {"input": 10, "output": 20, "cache-read": 30, "cache-write": 40, "cost": 0.0,
                    "list-cost": 1.25, "calls": 4},
         "compactions-harness": 1, "compactions-cli": 2,
         "name": "SECRET SESSION NAME", "cwd": "/home/someone/secret"},
        {"id": sid[1], "kind": "subagent", "parent-id": sid[0], "forked": True, "created": 2.0,
         "updated": 3.0, "status": "idle", "model": "claude:sonnet", "non-interactive": None,
         "supervisor": None,
         "usage": {"input": 1, "output": 2, "cache-read": 3, "cache-write": 4, "cost": 0.5,
                   "list-cost": None, "billing": None, "turns": 1},
         "ledger": None, "compactions-harness": 0, "compactions-cli": 0},
        {"id": sid[2], "kind": "subagent", "parent-id": sid[1], "forked": False, "created": 2.5,
         "updated": 3.5, "status": "inactive", "model": "/etc/passwd", "non-interactive": False,
         "supervisor": False, "usage": {"input": 0, "output": 0, "cache-read": 0, "cache-write": 0,
                                         "cost": 0.0, "list-cost": 0.0, "billing": "api", "turns": 0},
         "ledger": None, "compactions-harness": None, "compactions-cli": 3},
        {"id": sid[3], "kind": "main", "parent-id": None, "forked": False, "created": 3.0,
         "updated": 3.0, "status": "idle", "model": None, "non-interactive": None,
         "supervisor": None, "usage": {}, "ledger": None,
         "compactions-harness": 0, "compactions-cli": 0},
    ]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "raw").mkdir()
        store = root / "tasks.json"
        store.write_text(json.dumps({"state-directory": "x", "tasks": tasks}), encoding="utf-8")
        assert gather_tasks(store, root / "raw" / "tasks_raw.jsonl") == 2
        raw = (root / "raw" / "tasks_raw.jsonl").read_text(encoding="utf-8")
        for secret in ("SECRET", "secret", "/home/someone"):
            assert secret not in raw, f"gather_tasks kept {secret!r}"
        (root / "raw" / "sessions_raw.jsonl").write_text(
            "\n".join(json.dumps(s) for s in sessions) + "\n\n", encoding="utf-8")
        status = convert(root / "raw" / "tasks_raw.jsonl", root / "raw" / "sessions_raw.jsonl", root / "out")
        assert status == 0
        with open(root / "out" / "tasks.csv", newline="", encoding="utf-8") as handle:
            trows = list(csv.DictReader(handle))
        with open(root / "out" / "sessions.csv", newline="", encoding="utf-8") as handle:
            srows = list(csv.DictReader(handle))
        assert list(trows[0]) == TASK_COLUMNS and list(srows[0]) == SESSION_COLUMNS
        assert len(trows) == 2 and len(srows) == 4
        assert trows[0]["supervisor"] == "true" and trows[0]["plan"] == "" and trows[0]["merged"] == "true"
        assert trows[1]["started"] == "" and trows[1]["supervisor"] == "" and trows[1]["model"] == ""
        assert srows[0]["compactions"] == "3" and srows[0]["list_cost"] == "1.25"
        assert srows[0]["supervisor"] == "true" and srows[0]["ledger_calls"] == "4"
        assert srows[1]["forked"] == "true" and srows[1]["list_cost"] == "" and srows[1]["billing"] == ""
        assert srows[1]["ledger_input"] == "" and srows[1]["supervisor"] == ""
        assert srows[2]["model"] == OTHER, "a path-like model must be replaced"
        assert srows[2]["compactions"] == "", "an unknown part makes the count unknown"
        assert srows[2]["supervisor"] == "false" and srows[2]["non_interactive"] == "false"
        text = (root / "out" / "tasks.csv").read_text() + (root / "out" / "sessions.csv").read_text()
        for secret in ("SECRET", "secret", "/home/someone", "/etc/passwd"):
            assert secret not in text, f"a CSV contains {secret!r}"
        mode = (root / "out" / "tasks.csv").stat().st_mode & 0o777
        assert mode == 0o600, f"CSV mode is {mode:o}"
        # An orphaned parent is reported and fails --strict.
        broken = root / "raw" / "sessions_broken.jsonl"
        orphan = dict(sessions[1], **{"parent-id": "bbbbbbbb-0000-4000-8000-000000000001"})
        broken.write_text(json.dumps(orphan) + "\n")
        assert convert(root / "raw" / "tasks_raw.jsonl", broken, root / "out2", strict=True) == 1
        try:
            read_jsonl(root / "raw" / "missing.jsonl")
        except InputError:
            pass
        else:
            raise AssertionError("a missing file must raise InputError")
    print("self-test ok")
    return 0


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        epilog="The raw files are gathered by an agent first; see the top of this file.")
    parser.add_argument("--tasks-raw", type=Path, default=DEFAULT_TASKS_RAW)
    parser.add_argument("--sessions-raw", type=Path, default=DEFAULT_SESSIONS_RAW)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--gather-tasks", action="store_true",
                        help="write --tasks-raw from the project's task store (--task-store), then stop")
    parser.add_argument("--task-store", type=Path, default=DEFAULT_TASK_STORE)
    parser.add_argument("--print-gather-recipe", action="store_true",
                        help="print the Elisp that makes sessions_raw.jsonl, then stop")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 on a duplicate id, a task without its session, or an orphaned parent")
    parser.add_argument("--self-test", action="store_true", help="check the converter on a synthetic fixture")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    try:
        if args.self_test:
            return self_test()
        if args.print_gather_recipe:
            sys.stdout.write(GATHER_RECIPE)
            return 0
        if args.gather_tasks:
            gather_tasks(args.task_store, args.tasks_raw)
            return 0
        return convert(args.tasks_raw, args.sessions_raw, args.out_dir, args.strict)
    except InputError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
