#!/usr/bin/env bash
# Watch a session's processes outlive the tool call that started them:
# call 1 starts a server as a job, calls 2 and 3 reach it from their own
# sandboxes, call 4 reads the file it wrote, call 5 stops it and the file
# stays.  Every step is a separate call with its own permission decision.
# Needs bwrap and python3.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
  -l test/harness-test-helpers.el -l scripts/jobs-demo.el \
  -f jobs-demo-main "$@"
exit 0
