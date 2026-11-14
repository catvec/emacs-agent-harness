#!/usr/bin/env bash
# How long the harness takes to start the spoken receipt of an accepted
# request, and what that path adds to sending the request.
#
#   scripts/analysis/bench-acknowledgment.sh
#
# The measurement runs in a batch Emacs that loads this checkout (nothing
# in the user's Emacs), in a directory of its own under scripts/.dev/.
# What it prints, and what it does not, is stated in bench-acknowledgment.el
# and docs/analysis/spoken-acknowledgment-2026-11-09.md.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
out=scripts/.dev/bench-acknowledgment
rm -rf "$out"
mkdir -p "$out"
export HARNESS_BENCH_DIR="$out"
lp=(-L lisp -L lisp/modules -L lisp/ui -L .)
for v in lisp/vendor/*/; do [ -d "$v" ] && lp+=(-L "${v%/}"); done
exec emacs -Q --batch "${lp[@]}" -l scripts/analysis/bench-acknowledgment.el
