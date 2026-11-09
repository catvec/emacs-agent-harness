#!/usr/bin/env bash
# Watch who writes a workspace note, with no scribe: each turn costs one
# provider request (the agent's), a turn that settles nothing leaves the
# page empty, and a turn that decides something writes its note with the
# provenance the knowledge graph keeps.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
  -l test/harness-test-helpers.el -l scripts/notes-demo.el \
  -l lisp/modules/harness-workspace-test.el -f notes-demo-main "$@"
exit 0
