#!/usr/bin/env bash
# Offline, isolated before/after log storm; all output retained, no user's Emacs.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
OUT=${1:-$(mktemp -d "${TMPDIR:-/tmp}/harness-freeze-benchmark.XXXXXX")}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
# Task base: already includes the October receive slicing and November log caps.
git show dd59e2a:lisp/harness-core.el > "$OUT/before-core.el"
cp lisp/harness-core.el "$OUT/after-core.el"
for phase in before after; do
  emacs -Q --batch -L lisp --eval \
    "(unless (byte-compile-file \"$OUT/$phase-core.el\") (kill-emacs 1))" \
    > "$OUT/$phase-compile.log" 2>&1
  emacs -Q --batch -L lisp -l "$OUT/$phase-core.elc" \
    -l demo/ui-freezes/log-benchmark.el > "$OUT/$phase.log" 2>&1
  printf '\n%s\n' "$phase"
  cat "$OUT/$phase.log"
done
printf '\nComplete logs: %s\n' "$OUT"
