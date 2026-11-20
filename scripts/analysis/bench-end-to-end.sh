#!/usr/bin/env bash
# What a client actually waits for: connect, reconnect, prompt, stutter.
#   scripts/analysis/bench-end-to-end.sh [LEVELS] [SECONDS]
#
# Unlike the other benches here, this one is not synthetic.  It starts a
# real `emacs --batch' harness server on the production path (its full
# module set, its own state directory, an ephemeral ACP port), connects a
# real ACP client over TCP, drives real turns through the demo provider,
# and measures connect, reconnect, prompt latency and client-side stutter.
#
# It refuses to report anything unless the server loaded its full module
# set and a client is connected, so a fast number cannot come from a
# subset of the tree.
#
# LEVELS is a comma-separated list of concurrent session counts
# (default 1,4,12); SECONDS is how long each level streams (default 15).
# The server's state goes in a temporary directory; nothing in the
# checkout is written.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
levels=${1:-1,4,12}
seconds=${2:-15}

emacs -Q --batch \
  -L "$ROOT" -L "$ROOT/lisp" -L "$ROOT/lisp/modules" \
  --eval "(setq bench-e2e-levels (mapcar #'string-to-number (split-string \"$levels\" \",\")))" \
  --eval "(setq bench-e2e-stream-seconds $seconds)" \
  -l "$ROOT/scripts/analysis/bench-end-to-end.el" \
  --eval '(bench-e2e-run)'
