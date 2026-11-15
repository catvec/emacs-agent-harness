#!/usr/bin/env bash
# Show how the endpoint catalogue is shared, and what a failed
# refresh does, offline: the catalogue transport is a fake, no
# completion is sent, no policy is installed and no Harness is
# touched.
#
#   demo/openrouter-catalogue-sharing/demo.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -L lisp -L lisp/modules -L test \
     -l demo/openrouter-catalogue-sharing/demo.el \
     --eval "(demo-run)"
