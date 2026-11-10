#!/usr/bin/env bash
# Show what the price-aware OpenRouter policy decides, and why.
#
# Offline except for one read-only GET of OpenRouter's public endpoint
# listing, which needs no credential.  No completion request is sent, no
# policy is installed, and no Harness is touched: the script calls the
# selector directly.
#
#   demo/openrouter-pinning/demo.sh
#
# Set HARNESS_DEMO_OFFLINE=1 to skip the GET and show the stock cases
# only.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -l demo/openrouter-pinning/demo.el \
     --eval "(demo-run)"
