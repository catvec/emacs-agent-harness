#!/usr/bin/env bash
# Show why a permission prompt is put to the user, drawn by the
# panel's own code.
#
# Offline: it calls the reason builder and the panel's insert
# function with scripted requests, sends no model request,
# sets no permission rule, installs nothing and touches no
# Harness:
#
#   demo/permission-why/demo.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -l demo/permission-why/demo.el \
     --eval "(demo-run)"
