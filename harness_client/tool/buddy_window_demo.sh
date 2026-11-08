#!/usr/bin/env bash
# Try the desktop buddy's own window against a scripted workspace.
#
#   tool/buddy_window_demo.sh
#
# Starts the mock harness with its workspace, then the Linux client.  In the
# client: connect to ws://127.0.0.1:4281/acp, open Workspace, click the
# `Buddy` action, focus another window, and click or drag the card.  The card
# is a window of its own: clicking it does not bring the app forward and does
# not make it disappear.  `HARNESS_BUDDY_WINDOW=off` forces the in-app card
# instead, for a compositor that cannot draw a non-activating window.
#
# The script needs a Linux desktop session.  It stops the mock harness when
# the client exits.
set -euo pipefail
cd "$(dirname "$0")/.."
eval "$(tool/client_toolchain.sh)"
version="$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' .flutter-version | head -n 1)"
sdk="$FLUTTER_VERSIONS_DIR/$version"
port="${MOCK_PORT:-4281}"
log="${TMPDIR:-/tmp}/buddy-window-demo-mock.log"
"$sdk/bin/dart" run tool/mock_harness_server.dart --port "$port" --workspace >"$log" 2>&1 &
mock=$!
stop_mock() {
  kill "$mock" 2>/dev/null || true
  wait "$mock" 2>/dev/null || true
}
trap stop_mock EXIT
for _ in $(seq 1 80); do
  if grep -q "listening on ws://127.0.0.1:$port/acp" "$log" 2>/dev/null; then break; fi
  sleep 0.25
done
echo "Connect the client to ws://127.0.0.1:$port/acp"
"$sdk/bin/flutter" run -d linux
