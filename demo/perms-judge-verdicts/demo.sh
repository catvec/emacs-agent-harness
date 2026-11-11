#!/usr/bin/env bash
# Show how the permission judge's reply is read, corrected and gated.
#
# Offline: it calls the reader and the retry directly with scripted
# replies, sends no model request, installs nothing and touches no
# Harness:
#
#   demo/perms-judge-verdicts/demo.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -l demo/perms-judge-verdicts/demo.el \
     --eval "(demo-run)"
