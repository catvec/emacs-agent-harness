#!/usr/bin/env bash
# Show a slot-change note that stays one line, however long its stretch.
#
# Offline: it calls the module's note writer and the chat's renderer
# with a session record and a block it makes, sends no model request,
# starts no harness, installs nothing and runs no tool:
#
#   demo/slot-note-one-line/demo.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -l demo/slot-note-one-line/demo.el \
     --eval "(demo-run)"
