#!/usr/bin/env python3
"""Read the output of `flutter test --reporter json` and say what failed.

    report_flutter_tests.py JSON_FILE
        a report for a person: the counts, then each failing test with its error

    report_flutter_tests.py --failures JSON_FILE
        one line per failing test, sorted: "test/FILE.dart :: NAME" (what
        check_build.sh compares between two runs)

Exit status: 0 when every test passed and the run finished, 1 when a test
failed, 2 when the file cannot be read, 3 when the run did not finish (the
output stops before the final result: a crash, a kill, a timeout).

A file that cannot be loaded (a compile error in it or in what it imports) is a
failing test too, named "loading test/FILE.dart": the reporter marks it hidden
when it passes and shows it when it does not, and either way a run that cannot
load a file has not run its tests.
"""

from __future__ import annotations

import json
import os
import sys

# Lines of an error to show in the report; the log keeps the whole stream.
ERROR_LINES = 12


def relative_test_path(path: str) -> str:
    """test/NAME.dart for an absolute path (or a file: URL) into a test/ directory."""
    if path.startswith("file://"):
        path = path[len("file://"):]
    parts = path.replace(os.sep, "/").split("/")
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "test":
            return "/".join(parts[i:])
    return path


def read_events(path: str):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                yield json.loads(line)
            except ValueError:
                continue


def summarize(path: str) -> dict:
    """Return {"tests": N, "passed": N, "skipped": N, "failed": {id: (label, errors)},
    "finished": bool, "success": bool}."""
    suites: dict[int, str] = {}
    tests: dict[int, tuple[str, int]] = {}
    errors: dict[int, list[str]] = {}
    exceptions: dict[int, str] = {}
    results: dict[int, dict] = {}
    finished = False
    success = False
    for event in read_events(path):
        kind = event.get("type")
        if kind == "suite":
            suite = event["suite"]
            suites[suite["id"]] = relative_test_path(suite.get("path") or "")
        elif kind == "testStart":
            test = event["test"]
            tests[test["id"]] = (test.get("name") or "", test.get("suiteID", -1))
        elif kind == "error":
            errors.setdefault(event["testID"], []).append(event.get("error") or "")
        elif kind == "print":
            # The framework prints the exception a widget test hit, then fails
            # the test with "Test failed. See exception logs above."
            message = event.get("message") or ""
            if "EXCEPTION CAUGHT" in message:
                exceptions.setdefault(event["testID"], message)
        elif kind == "testDone":
            results[event["testID"]] = event
        elif kind == "done":
            finished = True
            success = bool(event.get("success"))
    failed = {}
    passed = skipped = counted = 0
    for test_id, done in results.items():
        name, suite_id = tests.get(test_id, ("?", -1))
        path = suites.get(suite_id, "?")
        ok = done.get("result") == "success"
        if done.get("hidden") and ok:
            continue  # a file that loaded, a group's set-up: not a test
        counted += 1
        if ok:
            if done.get("skipped"):
                skipped += 1
            else:
                passed += 1
            continue
        if name.startswith("loading "):
            label = "loading " + relative_test_path(name[len("loading "):])
        else:
            label = f"{path} :: {name}"
        shown = list(errors.get(test_id, []))
        if test_id in exceptions:
            shown.append(exceptions[test_id])
        failed[test_id] = (label, shown)
    return {"tests": counted, "passed": passed, "skipped": skipped,
            "failed": failed, "finished": finished, "success": success}


def failure_labels(summary: dict) -> list[str]:
    return sorted({label for label, _ in summary["failed"].values()})


def report(summary: dict) -> str:
    lines = [f"{summary['tests']} tests: {summary['passed']} passed, "
             f"{len(summary['failed'])} failed, {summary['skipped']} skipped"]
    if not summary["finished"]:
        lines.append("the run did not finish (no final result in the output)")
    for label, errors in sorted(summary["failed"].values()):
        lines.append("")
        lines.append(f"FAILED {label}")
        # The exception the framework printed says more than the error that
        # follows it ("Test failed. See exception logs above."), so it is first.
        shown = [e.strip() for e in errors if e.strip()]
        shown.sort(key=lambda e: "EXCEPTION CAUGHT" not in e)
        text = "\n".join(shown)
        for line in text.splitlines()[:ERROR_LINES]:
            lines.append("    " + line)
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    if any(arg in ("-h", "--help") for arg in argv):
        print(__doc__.strip())
        return 0
    only_failures = "--failures" in argv
    args = [arg for arg in argv if not arg.startswith("-")]
    if len(args) != 1 or any(a.startswith("-") and a != "--failures" for a in argv):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        summary = summarize(args[0])
    except OSError as error:
        print(f"report_flutter_tests: cannot read {args[0]}: {error}", file=sys.stderr)
        return 2
    if only_failures:
        for label in failure_labels(summary):
            print(label)
    else:
        print(report(summary))
    if not summary["finished"]:
        return 3
    return 0 if summary["success"] and not summary["failed"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
