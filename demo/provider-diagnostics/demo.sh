#!/usr/bin/env bash
# Show the provider diagnostics lines the harness writes for four attempts.
#
#   demo/provider-diagnostics/demo.sh
#
# Offline: the real OpenAI-compatible completion path runs against a
# fake HTTP layer, so nothing is sent anywhere and no credential is
# read.  Four attempts in one synthetic session:
#
#   1. a first request                      -> prefix=first
#   2. the same request again               -> prefix=identical
#   3. one appended message                 -> prefix=appended
#   4. the same conversation, changed tool  -> prefix=diverged at the
#      schema                                 tool-schema checkpoint
#
# The last line of the run is the leak check: no prompt marker, no tool
# description, no key and no API key appears in any line.
#
# README.md beside this script says what each field means.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
exec emacs -Q --batch \
  -L lisp -L lisp/modules -L lisp/ui -L demo/provider-diagnostics \
  -l demo/provider-diagnostics/demo.el \
  --eval '(provider-diagnostics-demo-run)'
