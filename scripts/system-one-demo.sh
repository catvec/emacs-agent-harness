#!/usr/bin/env bash
# Watch two System One providers answer one request through the provider
# interface -- the System One API (TypeSafe's Jev) over a stub transport,
# and the deterministic fixture in test/fixtures/system-one -- beside
# a model that declares System One and completions at once.  Then the
# refusals, the artifact and a cancellation.  Nothing touches the network.
# See lisp/modules/harness-provider-system-one.el.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
exec emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
  -l test/harness-test-helpers.el -l scripts/system-one-demo.el "$@"
exit 0
