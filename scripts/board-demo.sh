#!/usr/bin/env bash
# Draw a board the way an agent and a person do, through the agent's own
# six tools, and print the transcript:
#
#   scripts/board-demo.sh                    # the transcript
#   scripts/board-demo.sh --svg DIR          # and each picture, as SVG
#   scripts/board-demo.sh --png DIR          # and each picture, rendered
#
# The board is built by calling scene.read, grammar.describe, scene.edit,
# patch.preview, patch.commit and history.undo.  The pictures come from the
# board's own renderer, so a person and a model are shown the same drawing.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
  -l scripts/board-demo.el -f board-demo-main "$@"
