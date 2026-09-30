#!/usr/bin/env bash
# Run ERT suites, one clean Emacs per file.
#   scripts/test.sh                      every test/*-test.el
#   scripts/test.sh test/harness-core-test.el [SELECTOR]
# Set HARNESS_INTEGRATION=1 to include tests that talk to real models.
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
fail=0
for f in "${files[@]}"; do
  echo "== $f"
  emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
    -l test/harness-test-helpers.el -l "$f" \
    --eval "(ert-run-tests-batch-and-exit (quote $selector))" || fail=1
done
exit $fail
