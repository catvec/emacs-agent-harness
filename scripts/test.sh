#!/usr/bin/env bash
# Run ERT suites, one clean Emacs per file, several files at once.
#   scripts/test.sh                      every test/*-test.el
#   scripts/test.sh FILE... [SELECTOR]   only these files (optionally an ERT selector)
#   scripts/test.sh --changed            only the suites the working tree's changes touch
# Set HARNESS_INTEGRATION=1 to include tests that talk to real models.
# Set HARNESS_TEST_JOBS to how many files run at once (default: CPUs).
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
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

files=()
selector=t
changed=0
args=()
for a in "$@"; do
  case "$a" in
    --changed) changed=1 ;;
    *) args+=("$a") ;;
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
TIMINGS=${HARNESS_TEST_TIMINGS:-$ROOT/scripts/.dev/test-timings}
LOGS=${HARNESS_TEST_LOGS:-$ROOT/scripts/.dev/test-logs}
if ! mkdir -p "$LOGS"; then
  echo "test.sh: cannot make the log directory $LOGS" >&2
  exit 2
fi

# --changed: the suites the working tree's changes touch.  A test file
# runs itself; a module runs the suite named after it and every suite
# that names the module; a test helper, a fixture or harness.el itself
# affects every suite and runs them all.  Whatever is not covered is
# named: the full run is the only check sure to cover it.
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
  run_all=""
  uncovered=()
  for p in "${paths[@]}"; do
    case "$p" in
      test/*-test.el) add_suite "$p" ;;
      test/*)
        run_all="${run_all:+$run_all; }$p is a test helper or fixture, which every suite loads" ;;
      harness.el)
        run_all="${run_all:+$run_all; }harness.el loads every module" ;;
      lisp/*/harness-*.el|lisp/harness-*.el)
        base=$(basename "$p" .el)
        short=${base#harness-}
        [ -f "test/$base-test.el" ] && add_suite "test/$base-test.el"
        while IFS= read -r t; do add_suite "$t"; done < <(grep -lE "harness-$short|'$short" test/*-test.el 2>/dev/null)
        ;;
      *) uncovered+=("$p") ;;
    esac
  done
  if [ -n "$run_all" ]; then
    echo "test.sh --changed: running every suite: $run_all"
    files=(test/harness-*-test.el)
  else
    files=(${suites[@]+"${suites[@]}"})
  fi
  if [ ${#uncovered[@]} -gt 0 ]; then
    echo "test.sh --changed: no suite covers ${uncovered[*]};"
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
[ ${#files[@]} -eq 0 ] && files=(test/harness-*-test.el)

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
    t=$(awk -v k="$(basename "$f")" '$1 == k { print $2 }' "$TIMINGS")
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
  # SIGPIPE back, so the harness processes see it as they really do.
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

if [ -s "$WORK/timings" ]; then
  mkdir -p "$(dirname "$TIMINGS")"
  sort -k1,1 "$WORK/timings" >"$TIMINGS"
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

say ""
say "full logs: $LOGS"
for f in ${failed[@]+"${failed[@]}"}; do
  say "  $(basename "$f" .el) log: $LOGS/$(basename "$f" .el).log"
done
sayf '%s: %d files, %d failed, %ds wall (%d at a time)' \
     "$(basename "$0")" "${#files[@]}" "${#failed[@]}" "$((SECONDS - started))" "$JOBS"
[ "${#failed[@]}" -eq 0 ] || sayf 'failed: %s' "${failed[*]}"
cp "$REPORT" "$LOGS/last-run.txt"
exit $fail
