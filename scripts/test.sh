#!/usr/bin/env bash
# Run the ERT suites.  Each test file gets a fresh, clean Emacs so module
# registries cannot leak between files.
#
#   scripts/test.sh              run everything
#   scripts/test.sh test/foo-test.el ...
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMACS="${EMACS:-emacs}"

load_args=(-L "$REPO/lisp" -L "$REPO/lisp/modules" -L "$REPO/lisp/transports"
           -L "$REPO/lisp/tools" -L "$REPO/lisp/ui" -L "$REPO/test")

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  shopt -s nullglob
  files=("$REPO"/test/*-test.el)
fi

status=0
for file in "${files[@]}"; do
  printf '== %s\n' "$(basename "$file")"
  if ! "$EMACS" -Q --batch "${load_args[@]}" -l ert -l "$file" \
       --eval '(ert-run-tests-batch-and-exit t)'; then
    status=1
  fi
done
exit "$status"
