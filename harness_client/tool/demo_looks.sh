#!/usr/bin/env bash
# The four looks in a browser, for a review.  Builds the web app once, serves
# it next to the mock harness, and prints a URL for each look.
#
#   tool/demo_looks.sh            serves on 8099, mock harness on 4277
#   PORT=9000 tool/demo_looks.sh  another port
#
# In the app, connect to ws://127.0.0.1:4277/acp to see the sessions; the sign
# in screen alone shows the look's fields, buttons and bars.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
eval "$(tool/client_toolchain.sh)" >/dev/null
dart="$FLUTTER_VERSIONS_DIR/3.47.7/bin/dart"
port="${PORT:-8099}"
if [ ! -f build/web/index.html ]; then
  printf 'building the web app...\n' >&2
  ./tool/flutter build web --release >&2
fi
"$dart" run tool/mock_harness_server.dart --port 4277 >/dev/null 2>&1 &
mock=$!
trap 'kill "$mock" 2>/dev/null || true' EXIT
printf 'Windows  http://127.0.0.1:%s/?platform=windows\n' "$port"
printf 'Linux    http://127.0.0.1:%s/?platform=linux\n' "$port"
printf 'Apple    http://127.0.0.1:%s/?platform=apple\n' "$port"
printf 'Android  http://127.0.0.1:%s/?platform=android\n' "$port"
printf 'mock harness  ws://127.0.0.1:4277/acp\n'
exec python3 -m http.server "$port" --directory build/web
