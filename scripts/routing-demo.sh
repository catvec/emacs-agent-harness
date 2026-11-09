#!/usr/bin/env bash
# Watch workspace topic routing decide, with no model to place a
# message.  Prints the score of every thread for every message and
# the thread the ranker chose, once with the words alone and once
# with an embedding model stubbed in.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
  -l test/harness-test-helpers.el -l scripts/routing-demo.el \
  -f routing-demo-main "$@"
