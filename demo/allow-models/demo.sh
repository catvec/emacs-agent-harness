#!/usr/bin/env bash
# Show a provider narrowing itself with `:allow-models'.
#
# Offline and credential-free: every provider the demo registers is made
# up, so no request leaves the machine and no policy is installed.  It
# calls the provider calls a client makes -- `provider/models',
# `provider/model', `provider/tier-model', `provider/complete' -- so what
# it prints is what a picker, a tier and a request see.
#
#   demo/allow-models/demo.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -l demo/allow-models/demo.el \
     --eval "(demo-run)"
