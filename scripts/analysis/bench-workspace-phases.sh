#!/usr/bin/env bash
# Where a client's first workspace list waits, in phases.
#   scripts/analysis/bench-workspace-phases.sh [WORKSPACES [THREADS]]
#
# Starts a throwaway harness on a state directory of its own, seeds it with
# WORKSPACES workspaces of THREADS threads (default 3 and 8, and 0 0 for an
# empty one), and runs scripts/analysis/bench-workspace-phases.el against it
# with a fresh client.  Nothing of the person's own harness is used or
# touched: the server reads HARNESS_SERVER_CONFIG in a temporary directory,
# and its ACP token is that directory's.
#
# The state is seeded with `workspace/create' and `workspace/update' over
# ACP, so the records are the ones the harness writes itself, not fixtures
# of a shape the bench guessed.
#
# What the numbers mean, and what they do not: see the header of
# bench-workspace-phases.el.  They are one machine's, at the moment of the
# run, and establish where a client's time goes rather than what any one
# person's cold start cost.
#
# The last line, `server start', is from exec of the harness to its
# listening line: the one phase a client cannot see, and the largest on a
# cold machine.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
WORKSPACES=${1:-3}
THREADS=${2:-8}

STATE=$(mktemp -d "${TMPDIR:-/tmp}/bench-workspace-XXXXXX")
cleanup() {
  [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
  wait "${pid:-}" 2>/dev/null || true
  rm -rf "$STATE"
}
trap cleanup EXIT

export HARNESS_SERVER_CONFIG="$STATE/config.el"
printf '(setq harness-state-directory "%s")\n(setq harness-enabled-modules t)\n' "$STATE" \
  > "$HARNESS_SERVER_CONFIG"
unset HARNESS_SERVER_PARENT

start=$(date +%s.%N)
"$ROOT/scripts/harness-server" > "$STATE/server.log" 2>&1 &
pid=$!
for _ in $(seq 1 6000); do
  grep -q "HARNESS-ACP-ADDRESS " "$STATE/server.log" 2>/dev/null && break
  sleep 0.01
done
end=$(date +%s.%N)
if ! grep -q "HARNESS-ACP-ADDRESS " "$STATE/server.log"; then
  echo "the harness did not listen; its log:" >&2
  cat "$STATE/server.log" >&2
  exit 1
fi
address=$(grep -m1 "HARNESS-ACP-ADDRESS " "$STATE/server.log" | awk '{print $2}')
token=$(tr -d '\n' < "$STATE/acp-token" 2>/dev/null || true)

seed() {
  BENCH_ROOT="$ROOT" BENCH_ADDRESS="$address" BENCH_TOKEN="$token" \
    BENCH_WORKSPACES="$WORKSPACES" BENCH_THREADS="$THREADS" \
    emacs -Q --batch -l "$ROOT/scripts/analysis/bench-workspace-seed.el" 2>&1 \
    | grep -v '^debug-early' || true
}

echo "== $WORKSPACES workspaces of $THREADS threads =="
seed
BENCH_ROOT="$ROOT" BENCH_ADDRESS="$address" BENCH_TOKEN="$token" \
  emacs -Q --batch -l "$ROOT/scripts/analysis/bench-workspace-phases.el" 2>&1 \
  | grep -v '^debug-early' || true
python3 -c "print('%-14s %8.3fs' % ('server start', $end - $start))"
