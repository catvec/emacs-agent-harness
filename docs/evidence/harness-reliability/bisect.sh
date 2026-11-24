#!/usr/bin/env bash
# Run from the historical checkout; this script and its .el files stay outside it.
set -u
mode=${1:?Usage: bisect.sh hydration|routing}
evidence_dir=$(cd "$(dirname "$0")" && pwd)
case "$mode" in
  hydration) repro=restart-repro.el; failure='FAILED.*quality-restart' ;;
  routing)
    # Before durable send ownership existed there was no marker to strand.
    rg -q '^\(defun harness-openrouter--tracked-complete' lisp/modules/harness-provider-openrouter.el || exit 0
    repro=routing-repro.el; failure='terminal save failed' ;;
  *) exit 125 ;;
esac
log=${HARNESS_BISECT_LOG:-/tmp/harness-reliability-bisect-last.log}
emacs -Q --batch -L . -L lisp -L lisp/modules -L lisp/ui -L test \
  -l "$evidence_dir/$repro" >"$log" 2>&1
result=$?
# Dependency/API failures are untestable revisions, never evidence of this bug.
if [ "$result" -ne 0 ] && ! rg -q "$failure" "$log"; then exit 125; fi
exit "$result"
