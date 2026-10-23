#!/usr/bin/env bash
# How much UI-thread time the session list takes, in a batch Emacs.
#   scripts/analysis/bench-sessions.sh VERSION [ENV=VALUE ...]
# VERSION is "baseline" (HEAD, which you extract with
#   mkdir -p scripts/.dev/baseline && git archive HEAD lisp harness.el | tar -x -C scripts/.dev/baseline
# first) or "current" (this working tree, copied).  The sources are compiled
# in a copy under scripts/.dev/VERSION, never in the checkout: a stale .elc
# beside a source would be loaded by the test suites in its place.  The
# variables are those of bench-sessions.el: BENCH_N, BENCH_SHOWN,
# BENCH_SECONDS, BENCH_RATE, BENCH_LIVE, BENCH_INTERNAL, BENCH_PROFILE,
# BENCH_MEM.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
version=$1; shift
dir=scripts/.dev/$version
if [ "$version" = current ]; then
  mkdir -p "$dir"
  rsync -a --delete --include='*/' --include='*.el' --exclude='*' lisp harness.el "$dir"/ 2>/dev/null \
    || { rm -rf "$dir/lisp"; mkdir -p "$dir"; cp -r lisp harness.el "$dir"/; }
fi
files=("$dir"/lisp/*.el "$dir"/lisp/modules/*.el "$dir"/lisp/ui/*.el)
lp=(-L "$dir" -L "$dir/lisp" -L "$dir/lisp/modules" -L "$dir/lisp/ui")
for v in "$dir"/lisp/vendor/*/; do [ -d "$v" ] && lp+=(-L "${v%/}"); done
# Compile what is newer than its .elc.
todo=()
for f in "${files[@]}"; do
  [ -f "${f}c" ] && [ "${f}c" -nt "$f" ] || todo+=("$f")
done
if [ ${#todo[@]} -gt 0 ]; then
  emacs -Q --batch "${lp[@]}" -f batch-byte-compile "${todo[@]}" 2>&1 | grep -v '^Wrote ' || true
fi
for v in "$dir"/lisp/vendor/*/; do
  for f in "$v"*.el; do
    case "$f" in *-test.el) continue ;; esac
    [ -f "${f}c" ] && [ "${f}c" -nt "$f" ] || emacs -Q --batch "${lp[@]}" -f batch-byte-compile "$f" 2>&1 | grep -v '^Wrote ' || true
  done
done
env BENCH_ROOT="$ROOT/$dir" "$@" emacs -Q --batch -l scripts/analysis/bench-sessions.el
