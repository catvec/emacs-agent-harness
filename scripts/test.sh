#!/usr/bin/env bash
# Run ERT suites, one clean Emacs per file, several files at once.
#   scripts/test.sh                      every suite: a module's beside it, and test/
#   scripts/test.sh FILE... [SELECTOR]   only these files (optionally an ERT selector)
#   scripts/test.sh --changed            only the suites the working tree's changes touch
#   scripts/test.sh --status             check the last run, without running tests
# Set HARNESS_INTEGRATION=1 to include tests that talk to real models.
# Set HARNESS_TEST_JOBS to how many files run at once (default: up to 4).
# Set HARNESS_TEST_TIMEOUT to kill one file after N seconds (default 900).
# Set HARNESS_TEST_TIMINGS to the run-time cache's path (default
# scripts/.dev/test-timings), used to start the slowest suites first.
# Set HARNESS_TEST_LOGS to where the logs go (default
# scripts/.dev/test-logs): a run keeps every suite's whole output in
# <base>.log, ending with a footer naming the suite, its exit status and
# the time, and the run's own lines and summary in last-run.txt.  A run
# whose stdout was piped through grep or tail can therefore be read
# afterwards instead of run again.
# Set HARNESS_TEST_NICE to the CPU niceness of the suites (default 19, 0
# to run at the usual priority) and HARNESS_TEST_IONICE to their I/O class
# (default 3, idle; 0 to run at the usual one).
#
# --changed is for the loop while working: it runs the suites the
# working tree's changes touch.  The full run, with no arguments, is
# what a task runs once before handing its work in.
#
# Every run leaves scripts/.dev/test-stamp.json: full or selected run,
# tested commit, dirty tree and failed suites.  `running' replaces any
# earlier pass before suites start.  --status checks this record and
# succeeds only for a passing full run on the current clean commit.
# It runs no tests: read the saved logs when investigating a failure.
#
# These are the Emacs suites.  The Flutter app in harness_client/ has its own
# check, harness_client/tool/check_build.sh, which builds it; a run here that
# finds the app changed says so at the end, since no suite here would notice
# an app that does not build, and this repository's hand_in (its plugin,
# .harness/plugins/dev/harness-client-check.el) refuses an app change without it.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# A read-only pre-report check.  Use the structured result, not a
# wrapper's exit status (a pipe or `echo' after the run can hide it).
if [ "$#" = 1 ] && [ "$1" = --status ]; then
  python3 - "$ROOT" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
path = root / "scripts/.dev/test-stamp.json"
try:
    stamp = json.loads(path.read_text())
    if not isinstance(stamp, dict) or stamp.get("format") != 1:
        raise ValueError("unrecognized format")
except (OSError, ValueError) as exc:
    print(f"TEST RESULT: UNVERIFIED — cannot read {path}: {exc}")
    sys.exit(1)

print(f"TEST RESULT: {str(stamp.get('result', 'unknown')).upper()} "
      f"({stamp.get('kind', 'unknown')}, {stamp.get('files', '?')} suites, "
      f"{len(stamp.get('failed', []))} failed)")
for suite in stamp.get("failed", []):
    print(f"  FAILED: {suite}")
try:
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    dirty = subprocess.check_output(["git", "status", "--porcelain", "-uall"], cwd=root, text=True).strip()
except subprocess.CalledProcessError:
    print("UNVERIFIED: cannot check the tested commit")
    sys.exit(1)
problems = []
if stamp.get("result") != "pass" or stamp.get("failed"):
    problems.append("the last run did not pass; read its saved logs")
if stamp.get("kind") != "full":
    problems.append("selected suites are not a full run")
if stamp.get("head") != head:
    problems.append("HEAD changed since the run")
if stamp.get("dirty") is not False or dirty:
    problems.append("the tested tree or current tree has uncommitted changes")
for problem in problems:
    print(f"UNVERIFIED: {problem}")
print(f"Saved logs: {stamp.get('logs', 'scripts/.dev/test-logs')}")
sys.exit(bool(problems))
PY
  exit $?
fi

files=()
selector=t
changed=0
full=1
args=()
for a in "$@"; do
  case "$a" in
    --changed) changed=1; full=0 ;;
    *) args+=("$a"); full=0 ;;
  esac
done
set -- ${args[@]+"${args[@]}"}
if [ $# -gt 0 ]; then
  for a in "$@"; do
    if [ -f "$a" ]; then files+=("$a"); else selector="$a"; fi
  done
fi
if [ "$changed" = 1 ] && [ ${#files[@]} -gt 0 ]; then
  echo "test.sh: --changed picks the suites itself; do not name files with it" >&2
  exit 2
fi

TIMEOUT=${HARNESS_TEST_TIMEOUT:-900}
JOBS=${HARNESS_TEST_JOBS:-$(nproc 2>/dev/null || echo 4)}
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1
if [ -z "${HARNESS_TEST_JOBS:-}" ] && [ "$JOBS" -gt 4 ]; then JOBS=4; fi
TIMINGS=${HARNESS_TEST_TIMINGS:-$ROOT/scripts/.dev/test-timings}
LOGS=${HARNESS_TEST_LOGS:-$ROOT/scripts/.dev/test-logs}
STAMP=$ROOT/scripts/.dev/test-stamp.json
if ! mkdir -p "$LOGS"; then
  echo "test.sh: cannot make the log directory $LOGS" >&2
  exit 2
fi

# Write atomically, including for a selected or interrupted run, so a
# later failure cannot leave a previous full pass looking current.
json_escape() {
  local text=$1
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  text=${text//$'\n'/\\n}
  text=${text//$'\r'/\\r}
  text=${text//$'\t'/\\t}
  printf '%s' "$text"
}
write_stamp() {
  local result=$1 failed_json="" f
  for f in ${failed[@]+"${failed[@]}"}; do
    failed_json="${failed_json:+$failed_json, }\"$(json_escape "$f")\""
  done
  mkdir -p "$(dirname "$STAMP")" || return 1
  printf '{\n  "format": 1,\n  "result": "%s",\n  "kind": "%s",\n  "head": "%s",\n  "dirty": %s,\n  "files": %d,\n  "failed": [%s],\n  "logs": "%s",\n  "wall": %d,\n  "finished": "%s"\n}\n' \
    "$result" "$([ "$full" = 1 ] && echo full || echo selected)" "$run_head" "$run_dirty" \
    "${#files[@]}" "$failed_json" "$(json_escape "$LOGS")" "$((SECONDS - started))" \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" >"$STAMP.new" && mv "$STAMP.new" "$STAMP"
}

# Whether the branch has changed what the Flutter app is built from, committed
# since it left main or not, and whether the app's build check has passed for
# it: the check knows which paths those are.  No suite here builds the app.
app_reminder() {
  local check=harness_client/tool/check_build.sh status
  [ -x "$check" ] || return 0
  "$check" --changed >/dev/null 2>&1 || return 0
  if status=$("$check" --status 2>&1); then
    echo "The Flutter app (harness_client/) changed on this branch; ${status#check_build: }."
    return 0
  fi
  echo "The Flutter app (harness_client/) changed on this branch, and no suite here builds it:"
  echo "  ${status%%$'\n'*}"
  echo "  $check --accept-android-licenses   builds it (minutes; hand_in asks for it)"
  echo "  $check --quick                     analyze + test the working tree only"
}

# Where the suites are.  A module's tests live beside it, as
# NAME-test.el next to NAME.el: lisp/, lisp/modules/, lisp/ui/ and this
# repository's plugins.  The suites that test the repository itself --
# its docs, its dev loop, its test runner -- are in test/ (see
# test/harness-test-layout-test.el).  The vendored libraries' tests live
# beside their libraries too, and harness-core-test runs each of them in
# an Emacs that has only its library: they are not run here.
test_suites() {
  local dir
  for dir in lisp lisp/modules lisp/ui test; do
    [ -d "$dir" ] && find "$dir" -maxdepth 1 -name '*-test.el' -print
  done
  for dir in .harness/plugins/*/; do
    [ -d "$dir" ] && find "$dir" -maxdepth 1 -name '*-test.el' -print
  done
  return 0
}

# --changed: the suites the working tree's changes touch.  A test file
# runs itself; a module runs the test beside it, the suites whose names
# begin with it, and every suite that names the module; a test helper,
# a fixture or harness.el itself affects every suite and runs them all;
# a vendored library runs harness-core-test, which runs its suites.
# Whatever is not covered is named: the full run is the only check sure
# to cover it.
if [ "$changed" = 1 ]; then
  paths=()
  while IFS= read -r p; do
    [ -n "$p" ] && paths+=("$p")
  done < <(git status --porcelain -uall 2>/dev/null | sed 's/^...//' | sed 's/.* -> //')
  echo "test.sh --changed: ${#paths[@]} changed path(s)"
  for p in ${paths[@]+"${paths[@]}"}; do echo "  $p"; done
  if [ ${#paths[@]} -eq 0 ]; then
    echo "test.sh --changed: nothing to run (the working tree is clean)"
    echo "The full scripts/test.sh is what a task runs once before handing its work in."
    exit 0
  fi
  suites=()
  add_suite() {
    local s=$1 have
    for have in ${suites[@]+"${suites[@]}"}; do [ "$have" = "$s" ] && return 0; done
    suites+=("$s")
  }
  all_suites=()
  while IFS= read -r f; do all_suites+=("$f"); done < <(test_suites | sort)
  is_suite() {
    local s=$1 t
    for t in ${all_suites[@]+"${all_suites[@]}"}; do [ "$t" = "$s" ] && return 0; done
    return 1
  }
  run_all=""
  uncovered=()
  for p in "${paths[@]}"; do
    if is_suite "$p"; then add_suite "$p"; continue; fi
    case "$p" in
      lisp/vendor/*/*.el)
        add_suite lisp/harness-core-test.el ;;
      test/*)
        run_all="${run_all:+$run_all; }$p is a test helper or fixture, which every suite loads" ;;
      harness.el)
        run_all="${run_all:+$run_all; }harness.el loads every module" ;;
      scripts/test.sh)
        add_suite test/harness-test-runner-test.el ;;
      lisp/*.el|lisp/*/*.el|.harness/plugins/*/*.el)
        dir=${p%/*}
        base=${p##*/}
        base=${base%.el}
        short=${base#harness-}
        found=0
        if [ -f "$dir/$base-test.el" ]; then add_suite "$dir/$base-test.el"; found=1; fi
        while IFS= read -r t; do add_suite "$t"; found=1; done < <(
          find "$dir" -maxdepth 1 -name "$base-*-test.el" -print 2>/dev/null)
        while IFS= read -r t; do add_suite "$t"; found=1; done < <(
          grep -lE "harness-$short|'$short" ${all_suites[@]+"${all_suites[@]}"} 2>/dev/null)
        # A module no suite is named after and no suite names has nothing
        # to run for it: say so, rather than skipping it silently.
        [ "$found" = 1 ] || uncovered+=("$p")
        ;;
      harness_client/*) ;;   # not Emacs Lisp: app_reminder says what covers it
      *) uncovered+=("$p") ;;
    esac
  done
  app_reminder
  if [ -n "$run_all" ]; then
    echo "test.sh --changed: running every suite: $run_all"
    files=(${all_suites[@]+"${all_suites[@]}"})
  else
    files=(${suites[@]+"${suites[@]}"})
  fi
  if [ ${#uncovered[@]} -gt 0 ]; then
    echo "test.sh --changed: no suite covers:"
    printf '  %s\n' "${uncovered[@]}"
    echo "  only the full scripts/test.sh is sure to check it."
  fi
  if [ ${#files[@]} -eq 0 ]; then
    echo "test.sh --changed: nothing to run for ${#paths[@]} changed path(s)"
    echo "The full scripts/test.sh is what a task runs once before handing its work in."
    exit 0
  fi
  echo "test.sh --changed: ${#files[@]} suite(s) to run:"
  printf '  %s\n' "${files[@]}"
fi
if [ ${#files[@]} -eq 0 ]; then
  while IFS= read -r f; do files+=("$f"); done < <(test_suites | sort)
fi

# A test run is background work: it must not fight whatever the user is
# doing -- a game above all -- for the machine.  At nice 19 (and idle
# I/O) the kernel always prefers their programs and the suites use what
# is left, which on an idle machine is everything: a run then takes as
# long as it always did.  A run that is starved for a long time can hit
# HARNESS_TEST_TIMEOUT, which is the price of staying out of the way.
NICE=${HARNESS_TEST_NICE:-19}
IONICE=${HARNESS_TEST_IONICE:-3}
priority=()
case "$NICE" in
  ''|0) ;;
  *[!0-9]*) echo "test.sh: HARNESS_TEST_NICE must be a number, not '$NICE'" >&2 ;;
  *) command -v nice >/dev/null 2>&1 && priority+=(nice -n "$NICE") ;;
esac
case "$IONICE" in
  ''|0) ;;
  [1-3]) command -v ionice >/dev/null 2>&1 && priority+=(ionice -c "$IONICE") ;;
  *) echo "test.sh: HARNESS_TEST_IONICE must be an I/O class (1, 2 or 3), not '$IONICE'" >&2 ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Longest cached run first: with several jobs, the order decides how long
# an idle job waits at the end.  A missing or stale entry just runs early.
ordered() {
  [ -f "$TIMINGS" ] || { printf '%s\n' "${files[@]}"; return; }
  for f in "${files[@]}"; do
    t=$(awk -v k="$(basename "$f" .el)" '$1 == k { print $2 }' "$TIMINGS")
    printf '%s %s\n' "${t:-0}" "$f"
  done | sort -k1,1 -rn | cut -d' ' -f2-
}

run_suite() {
  local f=$1 base start status
  base=$(basename "$f" .el)
  start=$SECONDS
  # SIGPIPE ignored, as the Emacs the UI runs in has it.  A batch Emacs
  # leaves it fatal, so a write racing the death of a harness process
  # (the restart tests kill one) would kill the whole suite (exit 141)
  # where the UI gets an error.  Emacs gives the processes it starts
  # SIGPIPE back, so provider CLIs and MCP servers still see it as they
  # really do; the harness process ignores it itself, as it does in the
  # UI's own spawn (see `harness-server--sigpipe-shell').
  (trap '' PIPE
   timeout "$TIMEOUT" ${priority[@]+"${priority[@]}"} emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
     -l test/harness-test-helpers.el -l "$f" \
     --eval "(ert-run-tests-batch-and-exit (quote $selector))" >"$LOGS/$base.log" 2>&1)
  status=$?
  echo "$status" >"$WORK/$base.status"
  # Stamped, so a log left by an earlier run is recognisable as one.
  printf '\n== %s exit %s %s ==\n' "$f" "$status" \
         "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOGS/$base.log"
  echo "$base $((SECONDS - start + 1))" >>"$WORK/timings"
}

started=$SECONDS
run_head=$(git rev-parse HEAD 2>/dev/null || true)
run_dirty=false
[ -z "$(git status --porcelain -uall 2>/dev/null)" ] || run_dirty=true
failed=()
write_stamp running || exit 2
running=0
for f in $(ordered); do
  if [ "$running" -ge "$JOBS" ]; then
    wait -n 2>/dev/null || true
    running=$((running - 1))
  fi
  run_suite "$f" &
  running=$((running + 1))
done
wait

if [ "$selector" = t ] && [ -s "$WORK/timings" ]; then
  mkdir -p "$(dirname "$TIMINGS")"
  # A targeted run should update its suites without forgetting the rest.
  # An ERT selector is not representative of the whole suite, so do not
  # record those runs at all.
  if [ -f "$TIMINGS" ]; then
    awk 'NR == FNR { time[$1] = $2; next }
         !($1 in time) { print }
         END { for (suite in time) print suite, time[suite] }' \
      "$WORK/timings" "$TIMINGS" | sort -k1,1 >"$WORK/merged-timings"
  else
    sort -k1,1 "$WORK/timings" >"$WORK/merged-timings"
  fi
  cp "$WORK/merged-timings" "$TIMINGS"
fi

REPORT=$WORK/report.txt
: >"$REPORT"
# The lines the run prints, so they survive a pipe: `say' writes them to
# the log directory's last-run.txt as well.
say()  { printf '%s\n' "$*" | tee -a "$REPORT"; }
sayf() { local fmt=$1; shift; printf "$fmt\n" "$@" | tee -a "$REPORT"; }

sayf '== test.sh %s (%d files)' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"

fail=0
failed=()
for f in "${files[@]}"; do
  base=$(basename "$f" .el)
  status=$(cat "$WORK/$base.status" 2>/dev/null || echo 1)
  log="$LOGS/$base.log"
  if [ "$status" = 0 ]; then
    if [ "${#files[@]}" = 1 ]; then
      say "== $f"; cat "$log"
    else
      sayf 'ok    %-52s %s' "$(basename "$f")" \
           "$(grep -E '^Ran [0-9]+ tests' "$log" | tail -1)"
    fi
  else
    fail=1 failed+=("$f")
    if [ "$status" = 124 ]; then say "== $f"; say "   killed after ${TIMEOUT}s timeout"; fi
    sayf '== %s (exit %s); full log: %s' "$f" "$status" "$log"
    sed 's/^/   /' "$log"
  fi
done

# Never attribute tests to a commit made while they ran, or let a
# dirty run become clean merely because its changes were committed.
if [ "$run_head" != "$(git rev-parse HEAD 2>/dev/null || true)" ] ||
   [ -n "$(git status --porcelain -uall 2>/dev/null)" ]; then
  run_dirty=true
fi
write_stamp "$([ "$fail" = 0 ] && echo pass || echo fail)" || fail=1

say ""
say "TEST RESULT: $([ "$fail" = 0 ] && echo PASS || echo FAIL) ($([ "$full" = 1 ] && echo full || echo selected) run)"
say "result record: $STAMP"
say "full logs: $LOGS"
for f in ${failed[@]+"${failed[@]}"}; do
  say "  $(basename "$f" .el) log: $LOGS/$(basename "$f" .el).log"
done
sayf '%s: %d files, %d failed, %ds wall (%d at a time)' \
     "$(basename "$0")" "${#files[@]}" "${#failed[@]}" "$((SECONDS - started))" "$JOBS"
[ "${#failed[@]}" -eq 0 ] || sayf 'failed: %s' "${failed[*]}"
app_reminder | while IFS= read -r line; do say "$line"; done
cp "$REPORT" "$LOGS/last-run.txt"
exit $fail
