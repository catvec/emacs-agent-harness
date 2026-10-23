#!/usr/bin/env python3
"""Tests of the app's build check: tool/check_build.sh, the toolchain it builds
with (client_toolchain.sh, install_flutter.sh --sdk-only) and the report of the
app's tests (report_flutter_tests.py).

    python3 tool/test_check_build.py

No Flutter, Java or Android SDK is needed, and nothing is downloaded: the check
runs in a throwaway git repository against a fake flutter that fails the way the
real one did (a tree that does not analyze, a lock file that is out of date, a
plugin's classes lost when a build is made over an older one).
"""

import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(TOOL_DIR))

# The environment the scripts run in: git knows no user's settings.
CLEAN_ENV = dict(os.environ,
                 GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
                 GIT_TERMINAL_PROMPT="0")
for name in ("FLUTTER", "HARNESS_CLIENT_BASE", "HARNESS_CLIENT_CHECK_NO_TOOLCHAIN",
             "HARNESS_CLIENT_TOOLCHAIN", "FLUTTER_VERSIONS_DIR", "JAVA_HOME",
             "ANDROID_HOME", "ANDROID_SDK_ROOT"):
    CLEAN_ENV.pop(name, None)


def write(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)


def read(path):
    with open(path) as f:
        return f.read()


# --- the test report ----------------------------------------------------------

def json_stream(tests, finished=True, root="/work/app"):
    """The JSON stream of `flutter test --reporter json` for TESTS, a list of
    (file, name, outcome) with outcome "ok", "fail" (an assertion) or "widget"
    (an exception the framework printed, then "Test failed. See exception logs
    above."); a file named "!broken_test.dart" does not load."""
    events = [{"protocolVersion": "0.1.1", "runnerVersion": None, "pid": 3,
               "type": "start", "time": 0}]
    suites = {}
    next_id = [1]

    def new_id():
        next_id[0] += 1
        return next_id[0]

    for file, name, outcome in tests:
        broken = file.startswith("!")
        file = file.lstrip("!")
        path = f"{root}/test/{file}"
        if path not in suites:
            suites[path] = len(suites)
            events.append({"suite": {"id": suites[path], "platform": "vm", "path": path},
                           "type": "suite", "time": 1})
            load = new_id()
            events.append({"test": {"id": load, "name": "loading " + path,
                                    "suiteID": suites[path], "groupIDs": [],
                                    "metadata": {"skip": False, "skipReason": None},
                                    "line": None, "column": None, "url": None},
                           "type": "testStart", "time": 2})
            if broken:
                events.append({"testID": load, "error": "Failed to load: Compilation failed "
                               "lib/main.dart:3:1: Error: Undefined name 'theme'.",
                               "stackTrace": "", "isFailure": False, "type": "error", "time": 3})
                events.append({"testID": load, "result": "error", "skipped": False,
                               "hidden": False, "type": "testDone", "time": 4})
                continue
            events.append({"testID": load, "result": "success", "skipped": False,
                           "hidden": True, "type": "testDone", "time": 3})
        tid = new_id()
        events.append({"test": {"id": tid, "name": name, "suiteID": suites[path],
                                "groupIDs": [], "metadata": {"skip": False, "skipReason": None},
                                "line": 10, "column": 3, "url": f"file://{path}"},
                       "type": "testStart", "time": 5})
        if outcome == "widget":
            events.append({"testID": tid, "messageType": "print", "type": "print", "time": 6,
                           "message": "══╡ EXCEPTION CAUGHT BY RENDERING LIBRARY ╞═══\n"
                                      "A RenderFlex overflowed by 26 pixels on the right.\n"})
        if outcome in ("fail", "widget"):
            error = ("Expected: 'a'\n  Actual: 'b'\n" if outcome == "fail"
                     else "Test failed. See exception logs above.\n")
            events.append({"testID": tid, "error": error, "stackTrace": "", "isFailure": True,
                           "type": "error", "time": 7})
        events.append({"testID": tid, "result": "success" if outcome == "ok" else "failure",
                       "skipped": False, "hidden": False, "type": "testDone", "time": 8})
    if finished:
        failed = any(outcome != "ok" or file.startswith("!") for file, _, outcome in tests)
        events.append({"success": not failed, "type": "done", "time": 9})
    # pub's own chatter comes first in the real stream, and is no JSON.
    return "Resolving dependencies...\nGot dependencies!\n" + "\n".join(
        json.dumps(e) for e in events) + "\n"


class ReportFlutterTestsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harness-report-test-")
        self.script = os.path.join(TOOL_DIR, "report_flutter_tests.py")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def report(self, text, *args):
        path = os.path.join(self.tmp, "test.json")
        write(path, text)
        return subprocess.run(["python3", "-I", self.script, *args, path],
                              capture_output=True, text=True, timeout=30)

    def test_a_run_that_passes(self):
        result = self.report(json_stream([("a_test.dart", "one", "ok"),
                                          ("b_test.dart", "two", "ok")]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "2 tests: 2 passed, 0 failed, 0 skipped")

    def test_failing_tests_are_named_by_file_and_sorted(self):
        stream = json_stream([("b_test.dart", "beta", "fail"), ("a_test.dart", "alpha", "fail"),
                              ("a_test.dart", "fine", "ok")])
        result = self.report(stream)
        self.assertEqual(result.returncode, 1)
        self.assertIn("3 tests: 1 passed, 2 failed, 0 skipped", result.stdout)
        self.assertIn("FAILED test/a_test.dart :: alpha", result.stdout)
        self.assertIn("Expected: 'a'", result.stdout)
        names = self.report(stream, "--failures")
        self.assertEqual(names.returncode, 1)
        self.assertEqual(names.stdout.splitlines(),
                         ["test/a_test.dart :: alpha", "test/b_test.dart :: beta"])

    def test_the_exception_a_widget_test_printed_is_in_the_report(self):
        result = self.report(json_stream([("w_test.dart", "lays out", "widget")]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("RenderFlex overflowed by 26 pixels", result.stdout)
        # The framework's own message comes after what it says.
        self.assertLess(result.stdout.index("EXCEPTION CAUGHT"),
                        result.stdout.index("See exception logs above"))

    def test_a_file_that_does_not_load_is_a_failure(self):
        result = self.report(json_stream([("!broken_test.dart", "never run", "ok"),
                                          ("a_test.dart", "fine", "ok")]), "--failures")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines(), ["loading test/broken_test.dart"])

    def test_a_run_that_did_not_finish_is_not_a_pass(self):
        result = self.report(json_stream([("a_test.dart", "one", "ok")], finished=False))
        self.assertEqual(result.returncode, 3)
        self.assertIn("the run did not finish", result.stdout)

    def test_a_missing_file_and_bad_options(self):
        missing = subprocess.run(["python3", "-I", self.script, os.path.join(self.tmp, "none")],
                                 capture_output=True, text=True, timeout=30)
        self.assertEqual(missing.returncode, 2)
        self.assertIn("cannot read", missing.stderr)
        bad = subprocess.run(["python3", "-I", self.script, "--nope", "x"],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(bad.returncode, 2)
        helped = subprocess.run(["python3", "-I", self.script, "--help"],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(helped.returncode, 0)
        self.assertIn("flutter test --reporter json", helped.stdout)


# --- the check ------------------------------------------------------------------

# A flutter that logs what it is asked, in which directory, and fails the ways
# the real one has failed, as the files of the tree it is run in say:
#   PUB_GET_FAILS   pubspec.lock does not agree with pubspec.yaml
#   ANALYZE_FAILS   an analyzer error
#   FAILING_TESTS   the names of the tests that fail, one a line
#   BUILD_FAILS     the build fails
# and, with FAKE_STALE_BUG set, as a Kotlin build over an older one does: a
# lock file that changed since the last build in the directory loses a plugin's
# classes and the build stops with "cannot find symbol".
FAKE_FLUTTER = r'''#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
cwd = os.getcwd()
with open(os.environ["FAKE_FLUTTER_LOG"], "a") as log:
    log.write(json.dumps({"cwd": cwd, "args": args}) + "\n")


def text(name, default=None):
    try:
        with open(name) as f:
            return f.read()
    except FileNotFoundError:
        return default


if args[:2] == ["pub", "get"]:
    if os.path.exists("PUB_GET_FAILS"):
        print("Because app depends on x any which doesn't match any versions, "
              "version solving failed.")
        sys.exit(1)
elif args[:1] == ["analyze"]:
    if os.path.exists("ANALYZE_FAILS"):
        print("  error • Undefined name 'theme' • lib/main.dart:1:1 • undefined_identifier")
        sys.exit(1)
    print("No issues found!")
elif args[:1] == ["test"]:
    failing = [line for line in (text("FAILING_TESTS", "")).splitlines() if line]
    path = cwd + "/test/main_test.dart"
    events = [
        {"protocolVersion": "0.1.1", "runnerVersion": None, "pid": 3, "type": "start", "time": 0},
        {"suite": {"id": 0, "platform": "vm", "path": path}, "type": "suite", "time": 1},
        {"test": {"id": 1, "name": "loading " + path, "suiteID": 0, "groupIDs": [],
                  "metadata": {"skip": False, "skipReason": None}, "line": None,
                  "column": None, "url": None}, "type": "testStart", "time": 2},
        {"testID": 1, "result": "success", "skipped": False, "hidden": True,
         "type": "testDone", "time": 3},
    ]
    for number, name in enumerate(["adds"] + failing, start=2):
        events.append({"test": {"id": number, "name": name, "suiteID": 0, "groupIDs": [],
                                "metadata": {"skip": False, "skipReason": None}, "line": 1,
                                "column": 1, "url": "file://" + path}, "type": "testStart", "time": 4})
        if name in failing:
            events.append({"testID": number, "error": "Expected: 1\n  Actual: 2\n",
                           "stackTrace": "", "isFailure": True, "type": "error", "time": 5})
        events.append({"testID": number, "result": "failure" if name in failing else "success",
                       "skipped": False, "hidden": False, "type": "testDone", "time": 6})
    events.append({"success": not failing, "type": "done", "time": 7})
    print("Resolving dependencies...")
    for event in events:
        print(json.dumps(event))
    sys.exit(1 if failing else 0)
elif args[:2] == ["build", "apk"]:
    if os.path.exists("BUILD_FAILS"):
        print("FAILURE: Build failed with an exception.")
        sys.exit(1)
    lock = text("pubspec.lock", "")
    before = text("build/last-lock")
    if os.environ.get("FAKE_STALE_BUG") and before is not None and before != lock:
        print("GeneratedPluginRegistrant.java:34: error: cannot find symbol")
        print("  symbol:   class SharedPreferencesPlugin")
        sys.exit(1)
    os.makedirs("build/app/outputs/flutter-apk", exist_ok=True)
    with open("build/last-lock", "w") as f:
        f.write(lock)
    with open("build/app/outputs/flutter-apk/app-release.apk", "w") as f:
        f.write("an apk of " + lock)
else:
    sys.exit(2)
'''

APP_FILES = {
    "lib/main.dart": "void main() {}\n",
    "test/main_test.dart": "void main() {}\n",
    "assets/icon.txt": "icon\n",
    "pubspec.yaml": "name: app\n",
    "pubspec.lock": "packages: {}\n",
    "analysis_options.yaml": "include: x\n",
    ".flutter-version": "3.47.7\n",
    "android/gradle.properties": "kotlin.incremental=false\n",
    "README.md": "the app\n",
}


class CheckFixture(unittest.TestCase):
    """A repository with the app on main and the branch `task` out, and the
    check copied into it, to be run against a fake flutter."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harness-check-build-test-")
        self.repo = os.path.join(self.tmp, "repo")
        self.client = os.path.join(self.repo, "harness_client")
        self.out = os.path.join(self.tmp, "out")
        os.makedirs(os.path.join(self.client, "tool"))
        for name in ("check_build.sh", "report_flutter_tests.py"):
            shutil.copy2(os.path.join(TOOL_DIR, name), os.path.join(self.client, "tool", name))
        self.script = os.path.join(self.client, "tool", "check_build.sh")
        self.flutter = os.path.join(self.tmp, "flutter")
        write(self.flutter, FAKE_FLUTTER, 0o755)
        self.flutter_log = os.path.join(self.tmp, "flutter.log")
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Check Test")
        self.git("config", "user.email", "check@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.commit("base", dict(APP_FILES, **{"../notes.txt": "notes\n"}))
        self.git("checkout", "-q", "-b", "task")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, env=CLEAN_ENV, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, message, files):
        """Write FILES (path in harness_client, or "../path" in the repository, to
        text; None deletes the file) and commit everything."""
        for path, text in files.items():
            full = os.path.normpath(os.path.join(self.client, path))
            if text is None:
                os.unlink(full)
            else:
                write(full, text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def run_check(self, *args, **env):
        environment = dict(CLEAN_ENV, FLUTTER=self.flutter, FAKE_FLUTTER_LOG=self.flutter_log,
                           HARNESS_CLIENT_STEP_TIMEOUT="120")
        environment.update(env)
        return subprocess.run([self.script, "--no-toolchain", "--out", self.out, *args],
                              cwd=self.repo, env=environment, capture_output=True, text=True,
                              timeout=120, stdin=subprocess.DEVNULL)

    def calls(self):
        """(directory relative to the check's work directory, arguments) of every call."""
        try:
            lines = read(self.flutter_log).splitlines()
        except FileNotFoundError:
            return []
        work = os.path.join(os.path.realpath(self.out), "work") + os.sep
        found = []
        for line in lines:
            call = json.loads(line)
            found.append((os.path.realpath(call["cwd"]).replace(work, "", 1), " ".join(call["args"])))
        return found

    def stamp(self):
        return json.loads(read(os.path.join(self.out, "stamp.json")))

    def output(self, result):
        return result.stdout + result.stderr


class CheckBuildTest(CheckFixture):
    def test_a_passing_check_builds_the_committed_tree_in_a_copy_and_stamps_it(self):
        head = self.commit("ui", {"lib/main.dart": "void main() { run(); }\n"})
        result = self.run_check()
        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertIn("PASSED", result.stdout)
        # In order, each in the copy and none in the repository.
        self.assertEqual(self.calls(), [
            ("head/harness_client", "pub get --enforce-lockfile"),
            ("head/harness_client", "analyze"),
            ("head/harness_client", "test --reporter json"),
            ("head/harness_client", "build apk --release"),
        ])
        stamp = self.stamp()
        self.assertEqual(stamp["result"], "pass")
        self.assertEqual(stamp["head"], head)
        self.assertEqual(stamp["base"], self.git("rev-parse", "main"))
        self.assertEqual(stamp["steps"], ["pub-get", "analyze", "test", "build"])
        self.assertEqual(stamp["known_test_failures"], 0)
        self.assertEqual(len(stamp["apk_sha256"]), 64)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertFalse(os.path.exists(os.path.join(self.client, "build")))
        # The whole output of every step is kept.
        logs = sorted(os.listdir(os.path.join(self.out, "logs")))
        self.assertEqual([name for name in logs if name.endswith(".log")],
                         ["01-pub-get.log", "02-analyze.log", "03-test.log", "04-build.log"])
        self.assertIn("No issues found!", read(os.path.join(self.out, "logs", "02-analyze.log")))
        # The copies are thrown away once it passed.
        self.assertFalse(os.path.exists(os.path.join(self.out, "work")))

    def test_what_is_not_committed_is_not_in_the_check_but_is_said(self):
        self.commit("ui", {"lib/main.dart": "void main() { run(); }\n"})
        write(os.path.join(self.client, "lib", "main.dart"), "void main() { broken(\n")
        result = self.run_check("--keep")
        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertIn("changes that are not committed", result.stdout)
        self.assertIn("lib/main.dart", result.stdout)
        self.assertEqual(read(os.path.join(self.out, "work", "head", "harness_client", "lib",
                                           "main.dart")), "void main() { run(); }\n")

    def test_status_says_whether_the_stamp_covers_the_app_as_committed(self):
        self.commit("ui", {"lib/main.dart": "void main() { run(); }\n"})
        before = self.run_check("--status")
        self.assertEqual(before.returncode, 1)
        self.assertIn("there is no stamp", before.stdout)
        self.assertEqual(self.run_check().returncode, 0)
        self.assertEqual(self.run_check("--status").returncode, 0)
        # Docs, evidence and the tools are not the app.
        self.commit("docs", {"README.md": "more\n", "verification/build.txt": "built\n",
                             "tool/other.sh": "#!/bin/sh\n"})
        self.assertEqual(self.run_check("--status").returncode, 0)
        # The app is: committed after the check ...
        self.commit("more ui", {"lib/other.dart": "int x = 1;\n"})
        changed = self.run_check("--status")
        self.assertEqual(changed.returncode, 1)
        self.assertIn("the app changed after the check passed", changed.stdout)
        self.assertIn("lib/other.dart", changed.stdout)
        # ... and a stamp comes back with a check of the new commit.
        self.assertEqual(self.run_check().returncode, 0)
        self.assertEqual(self.run_check("--status").returncode, 0)
        # ... or not yet committed.
        write(os.path.join(self.client, "lib", "main.dart"), "void main() {}\n")
        dirty = self.run_check("--status")
        self.assertEqual(dirty.returncode, 1)
        self.assertIn("changes that are not committed", dirty.stdout)

    def test_a_stamp_that_does_not_say_pass_covers_nothing(self):
        os.makedirs(self.out)
        head = self.git("rev-parse", "HEAD")
        write(os.path.join(self.out, "stamp.json"),
              json.dumps({"result": "fail", "head": head}))
        result = self.run_check("--status")
        self.assertEqual(result.returncode, 1)
        self.assertIn('the stamp says "fail"', result.stdout)
        write(os.path.join(self.out, "stamp.json"),
              json.dumps({"result": "pass", "head": "0" * 40}))
        self.assertIn("a commit this repository does not have",
                      self.run_check("--status").stdout)

    def test_a_step_that_fails_stops_the_check_and_leaves_no_stamp(self):
        for marker, step, saw in (
                ("PUB_GET_FAILS", "pub-get", "version solving failed"),
                ("ANALYZE_FAILS", "analyze", "Undefined name 'theme'"),
                ("BUILD_FAILS", "build", "Build failed with an exception")):
            with self.subTest(step=step):
                shutil.rmtree(self.out, ignore_errors=True)
                os.unlink(self.flutter_log) if os.path.exists(self.flutter_log) else None
                self.commit(step, {marker: "yes\n"})
                result = self.run_check()
                self.assertEqual(result.returncode, 1, self.output(result))
                self.assertIn(f"FAIL {step}", result.stdout)
                self.assertIn(saw, result.stdout)
                self.assertIn("FAILED", result.stdout)
                self.assertFalse(os.path.exists(os.path.join(self.out, "stamp.json")))
                # Nothing after the step that failed ran.
                order = ["pub get --enforce-lockfile", "analyze", "test --reporter json",
                         "build apk --release"]
                ran = [args for _, args in self.calls()]
                self.assertEqual(ran, order[:order.index(
                    {"pub-get": "pub get --enforce-lockfile", "analyze": "analyze",
                     "build": "build apk --release"}[step]) + 1])
                self.commit("mended " + step, {marker: None})

    def test_a_failure_the_base_already_had_is_listed_not_held_against_the_branch(self):
        # main is red: a test fails there and fails here.
        self.git("checkout", "-q", "main")
        self.commit("red main", {"FAILING_TESTS": "lays out\n"})
        self.git("checkout", "-q", "task")
        self.git("merge", "-q", "--no-edit", "main")
        self.commit("ui", {"lib/main.dart": "void main() { run(); }\n"})
        result = self.run_check()
        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertIn("all 1 failing tests already fail at", result.stdout)
        self.assertEqual(self.stamp()["known_test_failures"], 1)
        # The base's tests were run too, to tell.
        self.assertEqual(
            [args for where, args in self.calls() if where.startswith("base/")],
            ["pub get", "test --reporter json"])
        self.assertIn("test/main_test.dart :: lays out",
                      read(os.path.join(self.out, "logs", "03-test.log")))

    def test_a_test_that_fails_here_and_not_at_the_base_fails_the_check(self):
        self.git("checkout", "-q", "main")
        self.commit("red main", {"FAILING_TESTS": "lays out\n"})
        self.git("checkout", "-q", "task")
        self.git("merge", "-q", "--no-edit", "main")
        self.commit("ui", {"FAILING_TESTS": "lays out\nwraps\n"})
        result = self.run_check()
        self.assertEqual(result.returncode, 1, self.output(result))
        self.assertIn("1 test(s) fail here that passed at", result.stdout)
        self.assertIn("test/main_test.dart :: wraps", result.stdout)
        self.assertNotIn("PASSED", result.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.out, "stamp.json")))
        # build never ran
        self.assertNotIn("build apk --release", [args for _, args in self.calls()])

    def test_a_failing_test_with_no_base_to_compare_with_fails_the_check(self):
        self.git("branch", "-m", "main", "trunk")  # no main, no master: no base
        self.git("checkout", "-q", "-b", "task2")
        self.commit("red", {"FAILING_TESTS": "lays out\n"})
        result = self.run_check()
        self.assertEqual(result.returncode, 1, self.output(result))
        self.assertIn("FAIL test", result.stdout)
        self.assertIn("lays out", result.stdout)

    def test_a_base_can_be_named(self):
        self.git("branch", "-m", "main", "trunk")
        self.git("checkout", "-q", "-b", "task2")
        self.commit("ui", {"lib/main.dart": "void main() { run(); }\n"})
        result = self.run_check("--base", "trunk")
        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertEqual(self.stamp()["base"], self.git("rev-parse", "trunk"))
        bad = self.run_check("--base", "nonesuch")
        self.assertEqual(bad.returncode, 0, self.output(bad))
        self.assertEqual(self.stamp()["base"], "")

    def test_the_build_over_the_base_is_made_when_dependencies_change(self):
        self.commit("deps", {"pubspec.lock": "packages: {a: 2}\n"})
        result = self.run_check()
        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertEqual(self.calls()[-2:], [
            ("upgrade/harness_client", "build apk --release"),
            ("upgrade/harness_client", "build apk --release"),
        ])
        self.assertEqual(self.stamp()["steps"],
                         ["pub-get", "analyze", "test", "build", "upgrade-from", "upgrade"])

    def test_the_build_over_the_base_catches_what_a_clean_build_cannot(self):
        # The failure that started this: a plugin upgraded over an older build
        # loses classes.  The build from scratch is fine.
        self.commit("deps", {"pubspec.lock": "packages: {a: 2}\n"})
        result = self.run_check(FAKE_STALE_BUG="1")
        self.assertEqual(result.returncode, 1, self.output(result))
        self.assertIn("ok   build", result.stdout)
        self.assertIn("ok   upgrade-from", result.stdout)
        self.assertIn("FAIL upgrade", result.stdout)
        self.assertIn("cannot find symbol", result.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.out, "stamp.json")))
        # Skipped on request, the same tree passes.
        again = self.run_check("--no-upgrade", FAKE_STALE_BUG="1")
        self.assertEqual(again.returncode, 0, self.output(again))
        self.assertIn("skip upgrade", again.stdout)

    def test_a_base_that_does_not_build_is_not_held_against_the_branch(self):
        # main is broken, and the branch mends it while it raises a dependency.
        self.git("checkout", "-q", "main")
        self.commit("main breaks", {"BUILD_FAILS": "yes\n"})
        self.git("checkout", "-q", "task")
        self.git("merge", "-q", "--no-edit", "main")
        self.commit("mend it", {"BUILD_FAILS": None, "pubspec.lock": "packages: {a: 2}\n"})
        result = self.run_check(FAKE_STALE_BUG="1")
        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertIn("FAIL upgrade-from", result.stdout)
        self.assertIn("does not build either", result.stdout)
        self.assertIn("PASSED", result.stdout)
        self.assertEqual(self.stamp()["steps"], ["pub-get", "analyze", "test", "build"])

    def test_the_head_is_built_over_the_base_with_the_files_it_deleted_gone(self):
        self.commit("deps", {"pubspec.lock": "packages: {a: 2}\n", "android/old.gradle": "x\n"})
        self.git("checkout", "-q", "main")
        self.git("merge", "-q", "--ff-only", "task")
        self.git("checkout", "-q", "-b", "task3")
        self.commit("drop", {"android/old.gradle": None, "pubspec.lock": "packages: {a: 3}\n"})
        result = self.run_check("--keep")
        self.assertEqual(result.returncode, 0, self.output(result))
        upgrade = os.path.join(self.out, "work", "upgrade", "harness_client")
        self.assertFalse(os.path.exists(os.path.join(upgrade, "android", "old.gradle")))
        self.assertEqual(read(os.path.join(upgrade, "pubspec.lock")), "packages: {a: 3}\n")

    def test_no_build_over_the_base_when_only_the_code_changed(self):
        self.commit("ui", {"lib/main.dart": "void main() { run(); }\n"})
        result = self.run_check()
        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertIn("skip upgrade", result.stdout)
        self.assertIn("as they were at", result.stdout)
        self.assertNotIn("upgrade-from", self.stamp()["steps"])
        self.assertEqual(len([c for c in self.calls() if c[1] == "build apk --release"]), 1)

    def test_the_tools_own_tests_run_when_the_tools_changed(self):
        write(os.path.join(self.client, "tool", "test_qr_tools.py"),
              "import sys\nprint('tool tests ran')\nsys.exit(0)\n")
        self.commit("tool", {"tool/test_qr_tools.py": read(
            os.path.join(self.client, "tool", "test_qr_tools.py"))})
        result = self.run_check()
        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertIn("ok   tool-test_qr_tools", result.stdout)
        self.assertIn("tool tests ran", read(os.path.join(self.out, "logs", "05-tool-test_qr_tools.log")))
        self.assertIn("tool-test_qr_tools", self.stamp()["steps"])
        # A failure of theirs fails the check.
        self.commit("break", {"tool/test_qr_tools.py": "import sys\nprint('a tool is broken')\nsys.exit(1)\n"})
        broken = self.run_check()
        self.assertEqual(broken.returncode, 1, self.output(broken))
        self.assertIn("a tool is broken", broken.stdout)

    def test_the_tools_tests_are_left_alone_when_the_tools_did_not_change(self):
        self.commit("ui", {"lib/main.dart": "void main() { run(); }\n"})
        result = self.run_check()
        self.assertIn("skip tool-tests", result.stdout)

    def test_quick_checks_the_working_tree_and_leaves_no_stamp(self):
        write(os.path.join(self.client, "lib", "main.dart"), "void main() { uncommitted(); }\n")
        write(os.path.join(self.client, "lib", "new.dart"), "int z = 3;\n")
        result = self.run_check("--quick", "--keep")
        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertIn("nothing was built, no stamp written", result.stdout)
        self.assertEqual([args for _, args in self.calls()],
                         ["pub get --enforce-lockfile", "analyze", "test --reporter json"])
        tree = os.path.join(self.out, "work", "quick", "harness_client")
        self.assertIn("uncommitted", read(os.path.join(tree, "lib", "main.dart")))
        self.assertTrue(os.path.exists(os.path.join(tree, "lib", "new.dart")))
        self.assertFalse(os.path.exists(os.path.join(self.out, "stamp.json")))

    def test_changed_says_whether_the_branch_touched_the_app(self):
        self.assertEqual(self.run_check("--changed").returncode, 1)
        # Not the app: docs, the tools, other parts of the repository.
        self.commit("docs", {"README.md": "more\n", "tool/other.sh": "#!/bin/sh\n",
                             "../notes.txt": "more notes\n"})
        self.assertEqual(self.run_check("--changed").returncode, 1)
        # The app, committed ...
        self.commit("ui", {"lib/main.dart": "void main() { run(); }\n"})
        self.assertEqual(self.run_check("--changed").returncode, 0)
        # ... and, with nothing committed, in the working tree: edited or new.
        self.git("checkout", "-q", "main")
        self.assertEqual(self.run_check("--changed").returncode, 1)
        write(os.path.join(self.client, "lib", "main.dart"), "void main() { edited(); }\n")
        self.assertEqual(self.run_check("--changed").returncode, 0)
        self.git("checkout", "--", "harness_client/lib/main.dart")
        write(os.path.join(self.client, "assets", "new.txt"), "new\n")
        self.assertEqual(self.run_check("--changed").returncode, 0)
        self.assertEqual(self.calls(), [])  # nothing was run

    def test_help_and_bad_options(self):
        helped = subprocess.run([self.script, "--help"], capture_output=True, text=True, timeout=30)
        self.assertEqual(helped.returncode, 0)
        self.assertIn("Prove that the Flutter app builds", helped.stdout)
        self.assertIn("--accept-android-licenses", helped.stdout)
        bad = subprocess.run([self.script, "--nope"], capture_output=True, text=True, timeout=30)
        self.assertEqual(bad.returncode, 2)
        self.assertIn("unknown option", bad.stderr)

    def test_a_missing_toolchain_is_exit_3_and_checks_nothing(self):
        # Without --no-toolchain the script asks client_toolchain.sh, which is
        # not there to answer.
        result = subprocess.run([self.script, "--out", self.out], cwd=self.repo, env=CLEAN_ENV,
                                capture_output=True, text=True, timeout=60)
        self.assertIn(result.returncode, (3, 127), self.output(result))
        self.assertFalse(os.path.exists(os.path.join(self.out, "stamp.json")))


# --- the toolchain ----------------------------------------------------------------

FAKE_SDKMANAGER = r'''#!/usr/bin/env bash
# Accepts the licences, and "installs" a package by making its directory.
sdk=""; licences=0; packages=()
for arg in "$@"; do
  case "$arg" in
    --sdk_root=*) sdk="${arg#--sdk_root=}" ;;
    --licenses) licences=1 ;;
    *) packages+=("$arg") ;;
  esac
done
echo "$*" >> "$FAKE_SDKMANAGER_LOG"
if [ "$licences" = 1 ]; then
  head -n 1 >/dev/null   # the real one reads answers until it has what it asked for
  mkdir -p "$sdk/licenses" && echo accepted > "$sdk/licenses/android-sdk-license"
  exit 0
fi
for p in "${packages[@]}"; do
  case "$p" in
    platforms\;*) mkdir -p "$sdk/platforms/${p#platforms;}" ;;
    build-tools\;*) mkdir -p "$sdk/build-tools/${p#build-tools;}" ;;
    ndk\;*) mkdir -p "$sdk/ndk/${p#ndk;}" ;;
    cmake\;*) mkdir -p "$sdk/cmake/${p#cmake;}" ;;
    platform-tools) mkdir -p "$sdk/platform-tools" ;;
  esac
done
'''


class ToolchainTest(unittest.TestCase):
    """client_toolchain.sh against fake JDKs, SDKs and Flutter directories, and a
    curl that never connects: it must find what is there, and install nothing
    when it need not."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harness-toolchain-test-")
        self.client = os.path.join(self.tmp, "repo", "harness_client")
        os.makedirs(os.path.join(self.client, "android"))
        os.makedirs(os.path.join(self.client, "tool"))
        for name in ("client_toolchain.sh", "install_flutter.sh", "flutter"):
            shutil.copy2(os.path.join(TOOL_DIR, name), os.path.join(self.client, "tool", name))
        self.script = os.path.join(self.client, "tool", "client_toolchain.sh")
        write(os.path.join(self.client, ".flutter-version"), "3.47.7\n")
        write(os.path.join(self.client, "android", "gradle.properties"), textwrap.dedent("""\
            org.gradle.jvmargs=-Xmx8G
            harness.ndkVersion=30.0.14904198
            harness.buildToolsVersion=36.1.0
            harness.compileSdk=36
            harness.cmakeVersion=4.1.2
            """))
        self.cache = os.path.join(self.tmp, "cache")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        # A curl that fails at once and says it was asked.
        self.bin = os.path.join(self.tmp, "bin")
        self.curl_log = os.path.join(self.tmp, "curl.log")
        write(os.path.join(self.bin, "curl"),
              f'#!/bin/sh\necho "$*" >> {self.curl_log}\nexit 22\n', 0o755)
        self.sdkmanager_log = os.path.join(self.tmp, "sdkmanager.log")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def make_flutter(self):
        versions = os.path.join(self.tmp, "flutter-versions")
        write(os.path.join(versions, "3.47.7", "bin", "flutter"),
              "#!/bin/sh\necho Flutter 3.47.7\n", 0o755)
        return versions

    def make_jdk(self, version_line, name="jdk"):
        home = os.path.join(self.tmp, name)
        for tool in ("java", "javac"):
            write(os.path.join(home, "bin", tool),
                  f"#!/bin/sh\necho '{version_line}' >&2\necho 'OpenJDK Runtime' >&2\n", 0o755)
        return home

    def make_sdk(self, name="sdk", licences=True):
        sdk = os.path.join(self.tmp, name)
        for part in ("platforms/android-36", "build-tools/36.1.0", "ndk/30.0.14904198",
                     "cmake/4.1.2", "platform-tools"):
            os.makedirs(os.path.join(sdk, part))
        if licences:
            write(os.path.join(sdk, "licenses", "android-sdk-license"), "accepted\n")
        return sdk

    def run_toolchain(self, *args, **env):
        environment = dict(CLEAN_ENV, HOME=self.home, HARNESS_CLIENT_TOOLCHAIN=self.cache,
                           HARNESS_CLIENT_NO_SYSTEM_TOOLS="1",
                           PATH=self.bin + os.pathsep + os.environ["PATH"],
                           FAKE_SDKMANAGER_LOG=self.sdkmanager_log)
        environment.update(env)
        return subprocess.run([self.script, *args], capture_output=True, text=True, timeout=60,
                              env=environment, stdin=subprocess.DEVNULL)

    def exports(self, result):
        found = {}
        for line in result.stdout.splitlines():
            if line.startswith("export "):
                key, _, value = line[len("export "):].partition("=")
                found[key] = value
        return found

    def test_what_the_machine_has_is_used_and_nothing_is_downloaded(self):
        versions, jdk, sdk = self.make_flutter(), self.make_jdk('openjdk version "21.0.13" 2026-10-20 LTS'), self.make_sdk()
        result = self.run_toolchain(FLUTTER_VERSIONS_DIR=versions, JAVA_HOME=jdk, ANDROID_HOME=sdk)
        self.assertEqual(result.returncode, 0, result.stderr)
        exports = self.exports(result)
        self.assertEqual(exports["FLUTTER_VERSIONS_DIR"], versions)
        self.assertEqual(exports["JAVA_HOME"], jdk)
        self.assertEqual(exports["ANDROID_HOME"], sdk)
        self.assertEqual(exports["ANDROID_SDK_ROOT"], sdk)
        # Pub's and Gradle's caches are the toolchain's own, never the person's.
        self.assertEqual(exports["PUB_CACHE"], os.path.join(self.cache, "pub-cache"))
        self.assertEqual(exports["GRADLE_USER_HOME"], os.path.join(self.cache, "gradle-home"))
        self.assertTrue(exports["PATH"].startswith(os.path.join(jdk, "bin") + ":"))
        self.assertFalse(os.path.exists(self.curl_log))
        self.assertIn("Android SDK: " + sdk, result.stderr)

    def test_a_shell_can_use_what_it_prints(self):
        versions, jdk, sdk = self.make_flutter(), self.make_jdk('openjdk version "17.0.9" 2023-10-17'), self.make_sdk()
        # A path with a space in it, as a home directory can have.
        spaced = os.path.join(self.tmp, "a b")
        os.rename(sdk, spaced)
        result = self.run_toolchain(FLUTTER_VERSIONS_DIR=versions, JAVA_HOME=jdk, ANDROID_HOME=spaced)
        self.assertEqual(result.returncode, 0, result.stderr)
        shell = subprocess.run(["bash", "-c", result.stdout + '\nprintf "%s" "$ANDROID_HOME"'],
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(shell.stdout, spaced)

    def test_only_a_jdk_the_build_supports_is_used(self):
        versions, sdk = self.make_flutter(), self.make_sdk()
        for line, usable in (('openjdk version "1.8.0_392"', False), ('openjdk version "11.0.2" 2019-01-15', False),
                             ('openjdk version "17" 2021-09-14', True), ('openjdk version "17.0.9" 2023-10-17', True),
                             ('openjdk version "21.0.13" 2026-10-20 LTS', True),
                             ('openjdk version "22.0.1" 2024-04-16', False),
                             ('openjdk version "27" 2026-09-15', False)):
            with self.subTest(version=line):
                jdk = self.make_jdk(line)
                if os.path.exists(self.curl_log):
                    os.unlink(self.curl_log)
                result = self.run_toolchain(FLUTTER_VERSIONS_DIR=versions, JAVA_HOME=jdk, ANDROID_HOME=sdk)
                if usable:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.exports(result)["JAVA_HOME"], jdk)
                else:
                    # It goes to the JDK it installs, and cannot download it here.
                    self.assertEqual(result.returncode, 3, result.stderr)
                    self.assertIn("could not download", result.stderr)
                    self.assertIn("OpenJDK21U", read(self.curl_log))
                shutil.rmtree(jdk)

    def test_an_sdk_without_a_component_is_not_used(self):
        versions, jdk = self.make_flutter(), self.make_jdk('openjdk version "21.0.13"')
        sdk = self.make_sdk()
        shutil.rmtree(os.path.join(sdk, "ndk"))
        result = self.run_toolchain(FLUTTER_VERSIONS_DIR=versions, JAVA_HOME=jdk, ANDROID_HOME=sdk)
        # The one it would install is not there either, and it cannot download one.
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("could not download", result.stderr)
        self.assertIn("commandlinetools", read(self.curl_log))

    def test_the_licences_are_accepted_only_when_asked_for(self):
        versions, jdk = self.make_flutter(), self.make_jdk('openjdk version "21.0.13"')
        # The command-line tools are in the cache already; the SDK has nothing.
        manager = os.path.join(self.cache, "android-sdk", "cmdline-tools", "latest", "bin", "sdkmanager")
        write(manager, FAKE_SDKMANAGER, 0o755)
        refused = self.run_toolchain(FLUTTER_VERSIONS_DIR=versions, JAVA_HOME=jdk)
        self.assertEqual(refused.returncode, 3, refused.stderr)
        self.assertIn("licences are not accepted", refused.stderr)
        self.assertIn("--accept-android-licenses", refused.stderr)
        self.assertFalse(os.path.exists(self.sdkmanager_log))
        accepted = self.run_toolchain("--accept-android-licenses",
                                      FLUTTER_VERSIONS_DIR=versions, JAVA_HOME=jdk)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        sdk = os.path.join(self.cache, "android-sdk")
        self.assertEqual(self.exports(accepted)["ANDROID_HOME"], sdk)
        calls = read(self.sdkmanager_log).splitlines()
        self.assertEqual(calls[0], f"--sdk_root={sdk} --licenses")
        self.assertIn("platforms;android-36", calls[1])
        self.assertIn("build-tools;36.1.0", calls[1])
        self.assertIn("ndk;30.0.14904198", calls[1])
        self.assertIn("cmake;4.1.2", calls[1])
        # Found, the second time: nothing is asked of the manager again.
        os.unlink(self.sdkmanager_log)
        again = self.run_toolchain(FLUTTER_VERSIONS_DIR=versions, JAVA_HOME=jdk)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertFalse(os.path.exists(self.sdkmanager_log))

    def test_the_licences_can_be_accepted_through_the_environment(self):
        versions, jdk = self.make_flutter(), self.make_jdk('openjdk version "21.0.13"')
        write(os.path.join(self.cache, "android-sdk", "cmdline-tools", "latest", "bin", "sdkmanager"),
              FAKE_SDKMANAGER, 0o755)
        result = self.run_toolchain(FLUTTER_VERSIONS_DIR=versions, JAVA_HOME=jdk,
                                    HARNESS_CLIENT_ACCEPT_ANDROID_LICENSES="1")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_missing_flutter_is_installed_by_the_flutter_installer_into_the_cache(self):
        jdk, sdk = self.make_jdk('openjdk version "21.0.13"'), self.make_sdk()
        # install_flutter.sh needs a download this test cannot make: the curl
        # fails, and so does the script, naming what it could not install.
        result = self.run_toolchain(JAVA_HOME=jdk, ANDROID_HOME=sdk)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("installing Flutter 3.47.7 under " + os.path.join(self.cache, "flutter-versions"),
                      result.stderr)
        self.assertIn("could not install Flutter 3.47.7", result.stderr)

    def test_bad_options_and_help(self):
        bad = self.run_toolchain("--nope")
        self.assertEqual(bad.returncode, 2)
        self.assertIn("unknown option", bad.stderr)
        helped = self.run_toolchain("--help")
        self.assertEqual(helped.returncode, 0)
        self.assertIn("Find, or install, what a build of the Android app needs", helped.stdout)

    def test_the_versions_come_from_the_project(self):
        write(os.path.join(self.client, "android", "gradle.properties"),
              "harness.ndkVersion=28.2.13676358\nharness.buildToolsVersion=36.0.0\n"
              "harness.compileSdk=35\nharness.cmakeVersion=3.22.1\n")
        versions, jdk = self.make_flutter(), self.make_jdk('openjdk version "21.0.13"')
        sdk = os.path.join(self.tmp, "sdk35")
        for part in ("platforms/android-35", "build-tools/36.0.0", "ndk/28.2.13676358", "cmake/3.22.1"):
            os.makedirs(os.path.join(sdk, part))
        result = self.run_toolchain(FLUTTER_VERSIONS_DIR=versions, JAVA_HOME=jdk, ANDROID_HOME=sdk)
        self.assertEqual(result.returncode, 0, result.stderr)
        os.unlink(os.path.join(self.client, "android", "gradle.properties"))
        write(os.path.join(self.client, "android", "gradle.properties"), "org.gradle.daemon=false\n")
        missing = self.run_toolchain(FLUTTER_VERSIONS_DIR=versions, JAVA_HOME=jdk, ANDROID_HOME=sdk)
        self.assertEqual(missing.returncode, 3)
        self.assertIn("does not set harness.compileSdk", missing.stderr)


class InstallFlutterTest(unittest.TestCase):
    """install_flutter.sh --sdk-only installs the SDK and no launcher."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harness-install-flutter-test-")
        self.client = os.path.join(self.tmp, "harness_client")
        os.makedirs(os.path.join(self.client, "tool"))
        for name in ("install_flutter.sh", "flutter"):
            shutil.copy2(os.path.join(TOOL_DIR, name), os.path.join(self.client, "tool", name))
        write(os.path.join(self.client, ".flutter-version"), "3.47.7\n")
        self.versions = os.path.join(self.tmp, "versions")
        write(os.path.join(self.versions, "3.47.7", "bin", "flutter"),
              "#!/bin/sh\necho Flutter 3.47.7\n", 0o755)
        self.wrapper = os.path.join(self.tmp, "bin", "flutter")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_install(self, *args):
        return subprocess.run([os.path.join(self.client, "tool", "install_flutter.sh"), *args],
                              capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
                              env=dict(CLEAN_ENV, FLUTTER_VERSIONS_DIR=self.versions,
                                       FLUTTER_WRAPPER=self.wrapper, HOME=self.tmp))

    def test_sdk_only_leaves_the_launcher_alone(self):
        result = self.run_install("--sdk-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Flutter 3.47.7", result.stdout)
        self.assertFalse(os.path.exists(self.wrapper))

    def test_without_it_the_launcher_is_installed(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.access(self.wrapper, os.X_OK))
        self.assertIn("Installed " + self.wrapper, result.stdout)

    def test_bad_options_and_help(self):
        bad = self.run_install("--nope")
        self.assertEqual(bad.returncode, 2)
        self.assertIn("unknown option", bad.stderr)
        helped = self.run_install("--help")
        self.assertEqual(helped.returncode, 0)
        self.assertIn("--sdk-only", helped.stdout)


# --- the lists that must agree -----------------------------------------------------

class ConsistencyTest(unittest.TestCase):
    def test_the_check_names_the_tests_of_the_tools_that_exist(self):
        script = read(os.path.join(TOOL_DIR, "check_build.sh"))
        import re
        match = re.search(r"^tool_tests=\((.*)\)$", script, re.MULTILINE)
        self.assertIsNotNone(match)
        for name in match.group(1).split():
            self.assertTrue(os.path.isfile(os.path.join(TOOL_DIR, name)), name)

    def test_the_pinned_android_components_are_the_ones_the_build_uses(self):
        properties = read(os.path.join(os.path.dirname(TOOL_DIR), "android", "gradle.properties"))
        for key in ("harness.ndkVersion", "harness.buildToolsVersion", "harness.compileSdk",
                    "harness.cmakeVersion"):
            self.assertRegex(properties, rf"(?m)^{key}=\S+$")


if __name__ == "__main__":
    unittest.main(verbosity=2)
