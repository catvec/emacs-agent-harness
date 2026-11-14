#!/usr/bin/env bash
# Watch the Logseq dream synthesize knowledge on a scratch graph.
#
# It builds a workspace, holds a conversation across two threads, edits a
# page by hand, then dreams.  The judge is stubbed with a fixed answer, so
# the demo shows the pass itself -- what it reads, checks, corrects, writes
# and refuses, and what recovery the graph has -- with no model call and no
# real graph.  Nothing outside a temporary directory is touched.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
  -l test/harness-test-helpers.el -l scripts/dream-demo.el \
  -f dream-demo-main "$@"
