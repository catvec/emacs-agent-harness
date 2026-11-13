#!/usr/bin/env bash
# Drive a running game from separate tool calls, with the real bwrap:
# call 1 launches it as a job of a session, later calls take screenshots,
# send it input and read what it left, then it is stopped and its
# lifecycle and a permission downgrade are proved.  Every step is a
# separate call with its own permission decision.  Needs bwrap and
# python3 with Pillow.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
  -l test/harness-test-helpers.el -l scripts/jobs-game/demo.el \
  -f jobs-game-demo-main "$@"
exit 0
