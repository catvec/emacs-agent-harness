#!/usr/bin/env bash
# Run ERT suites, one clean Emacs per file, several files at once.
#   scripts/test.sh                      every test/*-test.el
#   scripts/test.sh test/harness-core-test.el [SELECTOR]
# Set HARNESS_INTEGRATION=1 to include tests that talk to real models.
# Set HARNESS_TEST_JOBS to how many files run at once (default: CPUs).
# Set HARNESS_TEST_TIMEOUT to kill one file after N seconds (default 900).
# Set HARNESS_TEST_TIMINGS to the run-time cache's path (default
# scripts/.dev/test-timings), used to start the slowest suites first.
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
  timeout "$TIMEOUT" emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
    -l test/harness-test-helpers.el -l "$f" \
    --eval "(ert-run-tests-batch-and-exit (quote $selector))" >"$WORK/$base.log" 2>&1
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
