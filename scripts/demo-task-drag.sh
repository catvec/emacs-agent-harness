#!/usr/bin/env bash
# Serve the client's task board in a browser, connected to the preview harness.
#
#   scripts/demo-task-drag.sh              build if needed, then serve
#   scripts/demo-task-drag.sh --rebuild    build the web app again first
#
# The app is the Flutter client of this checkout, built for the web into
# harness_client/build/web.  The preview harness is
# harness_client/tool/mock_harness_server.dart, which speaks ACP with
# deterministic tasks and needs no Emacs, no account and no network.  The page
# at the end of this script opens with the harness already connected, so the
# task board is there: carry a task card with a long press and leave it on
# another column (or, in a narrow window, on a stage's section) to move the
# task.  A narrow window puts what waits on the person in a lane above the
# stages, and shows every priority at once in them.
#
# Ctrl-C stops the app's server and the preview harness.
#
# Environment:
#   WEB_PORT   the port the app is served on (default 8090)
#   ACP_PORT   the port the preview harness listens on (default 4277)
#   DEMO_LOGS  where the servers' logs go (default scripts/.dev/demo)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLIENT=$ROOT/harness_client
LOGS=${DEMO_LOGS:-$ROOT/scripts/.dev/demo}
WEB_PORT=${WEB_PORT:-8090}
ACP_PORT=${ACP_PORT:-4277}

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

rebuild=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild) rebuild=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "demo-task-drag: unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

case "$WEB_PORT$ACP_PORT" in
  *[!0-9]*) echo "demo-task-drag: WEB_PORT and ACP_PORT must be numbers" >&2; exit 2 ;;
esac

command -v python3 >/dev/null || { echo "demo-task-drag: python3 is not on PATH" >&2; exit 1; }
command -v curl >/dev/null || { echo "demo-task-drag: curl is not on PATH" >&2; exit 1; }

mkdir -p "$LOGS"
cd "$CLIENT"
# The Flutter SDK and pub cache this checkout is built with, as check_build.sh
# finds them; a machine that has them already uses its own.
eval "$(tool/client_toolchain.sh)"

stale=0
if [ ! -f build/web/index.html ]; then
  stale=1
elif [ "$rebuild" = 1 ] || [ -n "$(find lib pubspec.yaml -newer build/web/main.dart.js -print -quit 2>/dev/null)" ]; then
  stale=1
fi
if [ "$stale" = 1 ]; then
  echo "demo-task-drag: building the web app (about a minute) ..."
  tool/flutter build web --release
fi

# The page that opens the board with the harness already remembered: the
# client keeps the server's address and its own choice to reconnect in the
# browser's storage, under the `flutter.` prefix the preferences plugin uses.
cat > build/web/demo.html <<HTML
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>Harness | Tasks</title>
<!-- Written by scripts/demo-task-drag.sh; not part of the app's build. -->
<script>
localStorage.setItem('flutter.address', JSON.stringify('ws://127.0.0.1:$ACP_PORT/acp'));
localStorage.setItem('flutter.token', JSON.stringify(''));
localStorage.setItem('flutter.reconnectOnLaunch', 'true');
localStorage.setItem('flutter.rememberConnection', 'true');
location.replace('./?theme=dark');
</script>
</html>
HTML

pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM

dart="$FLUTTER_VERSIONS_DIR/$(cat .flutter-version)/bin/dart"
"$dart" run tool/mock_harness_server.dart --port "$ACP_PORT" --task-sessions \
  > "$LOGS/mock-harness.log" 2>&1 &
pids+=($!)
python3 -m http.server "$WEB_PORT" --bind 127.0.0.1 --directory build/web \
  > "$LOGS/web.log" 2>&1 &
pids+=($!)

ready=0
for _ in $(seq 1 120); do
  if grep -q "listening on" "$LOGS/mock-harness.log" &&
     curl -sf -o /dev/null "http://127.0.0.1:$WEB_PORT/demo.html"; then
    ready=1
    break
  fi
  sleep 0.25
done
if [ "$ready" != 1 ]; then
  echo "demo-task-drag: the servers did not come up on ports $WEB_PORT and $ACP_PORT" >&2
  echo "--- preview harness ---" >&2; cat "$LOGS/mock-harness.log" >&2
  echo "--- web ---" >&2; cat "$LOGS/web.log" >&2
  exit 1
fi

cat <<TEXT
demo-task-drag: http://127.0.0.1:$WEB_PORT/demo.html
  The task board, connected to the preview harness on ws://127.0.0.1:$ACP_PORT/acp.
  Long-press a task card and drop it on another column to move the task.
  Logs: $LOGS
TEXT
wait
