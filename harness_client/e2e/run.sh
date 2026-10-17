#!/usr/bin/env bash
# Build the client, start the preview harnesses and a static server, then
# drive every flow in mobile-emulated Chromium and save the screenshots.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
: "${FLUTTER:=flutter}"
: "${DART:=dart}"
PORT=${PORT:-8899}
ACP_PORT=${ACP_PORT:-4277}
STANDARD_PORT=${STANDARD_PORT:-4278}
PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}
export PLAYWRIGHT_BROWSERS_PATH

LOG_DIR=${LOG_DIR:-$ROOT/e2e/.logs}
mkdir -p "$LOG_DIR"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  "$FLUTTER" build web --release --dart-define=E2E=true
fi

"$DART" run tool/mock_harness_server.dart --port "$ACP_PORT" > "$LOG_DIR/mock.log" 2>&1 &
MOCK=$!
"$DART" run tool/mock_harness_server.dart --port "$STANDARD_PORT" --standard > "$LOG_DIR/mock-standard.log" 2>&1 &
MOCK_STANDARD=$!
python3 -m http.server "$PORT" --directory build/web > "$LOG_DIR/web.log" 2>&1 &
WEB=$!
cleanup() {
  kill "$MOCK" "$MOCK_STANDARD" "$WEB" 2>/dev/null || true
}
trap cleanup EXIT

ready=0
for _ in $(seq 1 60); do
  if curl -sf -o /dev/null "http://127.0.0.1:$PORT/"; then ready=1; break; fi
  sleep 0.25
done
if [ "$ready" != 1 ]; then
  echo "web server did not start" >&2
  cat "$LOG_DIR/web.log" >&2
  exit 1
fi
sleep 2

cd e2e
[ -d node_modules ] || npm install --no-audit --no-fund
WEB_URL="http://127.0.0.1:$PORT" \
ACP_URL="ws://127.0.0.1:$ACP_PORT/acp" \
STANDARD_ACP_URL="ws://127.0.0.1:$STANDARD_PORT/acp" \
node run_flows.mjs
