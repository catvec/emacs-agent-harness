#!/usr/bin/env bash
# Run ERT suites, one clean Emacs per file, several files at once.
#   scripts/test.sh                      every test/*-test.el
#   scripts/test.sh test/harness-core-test.el [SELECTOR]
# Set HARNESS_INTEGRATION=1 to include tests that talk to real models.
# Set HARNESS_TEST_JOBS to how many files run at once (default: CPUs).
# Set HARNESS_TEST_TIMEOUT to kill one file after N seconds (default 900).
# Set HARNESS_TEST_TIMINGS to the run-time cache's path (default
# scripts/.dev/test-timings), used to start the slowest suites first.
# Set HARNESS_TEST_NICE to the CPU niceness of the suites (default 19, 0
# to run at the usual priority) and HARNESS_TEST_IONICE to their I/O class
# (default 3, idle; 0 to run at the usual one).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
files=()
selector=t
if [ $# -gt 0 ]; then
  for a in "$@"; do
    if [ -f "$a" ]; then files+=("$a"); else selector="$a"; fi
  done
fi
[ ${#files[@]} -eq 0 ] && files=(test/harness-*-test.el)
TIMEOUT=${HARNESS_TEST_TIMEOUT:-900}
JOBS=${HARNESS_TEST_JOBS:-$(nproc 2>/dev/null || echo 4)}
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1
TIMINGS=${HARNESS_TEST_TIMINGS:-$ROOT/scripts/.dev/test-timings}

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
  local f=$1 base start
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
     --eval "(ert-run-tests-batch-and-exit (quote $selector))" >"$WORK/$base.log" 2>&1)
  echo $? >"$WORK/$base.status"
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

fail=0 failed=()
for f in "${files[@]}"; do
  base=$(basename "$f" .el)
  status=$(cat "$WORK/$base.status" 2>/dev/null || echo 1)
  log="$WORK/$base.log"
  if [ "$status" = 0 ]; then
    if [ "${#files[@]}" = 1 ]; then
      echo "== $f"; cat "$log"
    else
      printf 'ok    %-52s %s\n' "$(basename "$f")" \
             "$(grep -E '^Ran [0-9]+ tests' "$log" | tail -1)"
    fi
  else
    fail=1 failed+=("$f")
    if [ "$status" = 124 ]; then echo "== $f"; echo "   killed after ${TIMEOUT}s timeout"; fi
    echo "== $f (exit $status)"
    sed 's/^/   /' "$log"
  fi
done

printf '\n%s: %d files, %d failed, %ds wall (%d at a time)\n' \
       "$(basename "$0")" "${#files[@]}" "${#failed[@]}" "$((SECONDS - started))" "$JOBS"
[ "${#failed[@]}" -eq 0 ] || printf 'failed: %s\n' "${failed[*]}"
exit $fail
