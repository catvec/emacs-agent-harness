#!/bin/sh
# Byte-compile the harness and run the ERT suite.
#
# Usage: scripts/test.sh
#
# Set ERT_SELECTOR to run a subset, e.g.
#     ERT_SELECTOR='"harness-http"'
# Compilation warnings are errors: a warning here almost always means a real
# bug (unbound variable, wrong arity, obsolete API).
set -eu

cd "$(dirname "$0")/.."

EMACS="${EMACS:-emacs}"
SELECTOR="${ERT_SELECTOR:-t}"

echo "== byte-compiling =="
"$EMACS" -Q --batch -L . -L lisp -L test \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile lisp/*.el harness.el test/*.el

echo "== running tests =="
ERT_SELECTOR="$SELECTOR" "$EMACS" -Q --batch -L . -L lisp -L test \
  -l harness-test-runner \
  --eval '(ert-run-tests-batch-and-exit (car (read-from-string (or (getenv "ERT_SELECTOR") "t"))))'
