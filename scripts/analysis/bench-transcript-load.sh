#!/usr/bin/env bash
# What reading a transcript costs, measured in a batch Emacs.
#   scripts/analysis/bench-transcript-load.sh
# It compiles a copy of the checkout under scripts/.dev/bench-transcript,
# never the checkout itself, and measures synthetic sessions: the full and
# the lean session listing, the standard replay and the harness's nodes
# alone, and finding session ids in a long message.  No real transcript is
# read and nothing is written outside the copy and a temporary state
# directory.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
dir=scripts/.dev/bench-transcript
rm -rf "$dir"
mkdir -p "$dir"
cp -r lisp harness.el "$dir"/
files=("$dir"/lisp/*.el "$dir"/lisp/modules/*.el "$dir"/lisp/ui/*.el)
lp=(-L "$dir" -L "$dir/lisp" -L "$dir/lisp/modules" -L "$dir/lisp/ui" -L "$ROOT/test")
for v in "$dir"/lisp/vendor/*/; do [ -d "$v" ] && lp+=(-L "${v%/}"); done
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
emacs -Q --batch "${lp[@]}" -l test/harness-test-helpers.el \
  -l scripts/analysis/bench-transcript-load.el
