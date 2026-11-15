#!/usr/bin/env bash
# Show what an unreadable OpenRouter catalogue was reported as, and is now.
#
# Offline: the catalogue failure is canned, no completion is sent,
# no policy is installed and no Harness is touched.
#
#   demo/openrouter-catalogue-failure/demo.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -L lisp -L lisp/modules \
     -l demo/openrouter-catalogue-failure/demo.el \
     --eval "(demo-run)"
