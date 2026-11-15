#!/usr/bin/env bash
# Show what a compaction answers, and what still asks.
#
# Runs the real cold-cache gate, the real cache panel and the real
# session record against real sessions, in one batch Emacs.  No model is
# called (the provider is scripted) and no harness is started.
#
#   demo/compaction-cold-cache/demo.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
     -l harness-test-helpers -l demo/compaction-cold-cache/demo.el \
     --eval "(demo-run)"
