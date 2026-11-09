#!/usr/bin/env bash
# Show the local voice pipeline running on the harness server.
#
# Two Emacsen, as a real harness server and a real client:
#
#   1. the *server* loads the harness in batch, starts the `command'
#      backend of the `speech' module with the bundled fixture
#      (test/harness-speech-service.py) as its own child, and listens on
#      a loopback ACP port;
#   2. the *client* connects over TCP -- a phone or another machine would
#      the same way -- and asks `_harness/speech/status',
#      `_harness/speech/transcribe' and `_harness/speech/synthesize'.
#
# Nothing here runs whisper.cpp or Kokoro: the fixture serves whisper.cpp's
# `/inference' and Kokoro's `/v1/audio/speech', so the demo shows the shape
# of the pipeline and the sharing, not a model.  The client has no speech
# program of its own: its Emacs only has to reach the port.
#
#   demo/voice-pipeline/demo.sh
# The README beside this script says what it shows.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIXTURE="$ROOT/test/harness-speech-service.py"
STATE=$(mktemp -d)
cleanup() {
  rm -rf "$STATE"
  if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  return 0
}
trap cleanup EXIT

command -v python3 >/dev/null || { echo "python3 unavailable"; exit 2; }

port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

STT=$(port); TTS=$(port); ACP=$(port)

echo "== harness server: starting the pipeline as its child"
emacs -Q --batch -L "$ROOT/lisp" -L "$ROOT/lisp/modules" -L "$ROOT" \
  -l "$ROOT/demo/voice-pipeline/server.el" \
  --eval "(harness-voice-pipeline-demo-server \"$STATE\" \"$FIXTURE\" $STT $TTS $ACP)" \
  >"$STATE/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the listener, then connect.
for _ in $(seq 1 100); do
  grep -q "LISTENING $ACP" "$STATE/server.log" 2>/dev/null && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "server stopped:"; cat "$STATE/server.log"; exit 1; }
  sleep 0.1
done
grep -q "LISTENING $ACP" "$STATE/server.log" || { echo "no listener:"; cat "$STATE/server.log"; exit 1; }
sed -n 's/^STARTED /   /p' "$STATE/server.log"

echo
echo "== a client, with no speech program of its own, over TCP ACP"
emacs -Q --batch -L "$ROOT/lisp" -L "$ROOT/lisp/modules" -L "$ROOT" \
  -l "$ROOT/demo/voice-pipeline/client.el" \
  --eval "(harness-voice-pipeline-demo-client \"$STATE/token\" $ACP)" 2>&1 \
  | sed -n 's/^RESULT /   /p'

echo
echo "== the programs are the harness's children, and stop with it"
for _ in $(seq 1 50); do
  grep -q '^CHILDREN ' "$STATE/server.log" 2>/dev/null && break
  sleep 0.1
done
sed -n 's/^CHILDREN /   /p' "$STATE/server.log"
echo "   stop"
emacs -Q --batch -L "$ROOT/lisp" -L "$ROOT/lisp/modules" -L "$ROOT" \
  -l "$ROOT/demo/voice-pipeline/client.el" \
  --eval "(harness-voice-pipeline-demo-stop \"$STATE/token\" $ACP)" 2>&1 \
  | sed -n 's/^RESULT /   /p'
for _ in $(seq 1 50); do
  grep -q '^STOPPED ' "$STATE/server.log" 2>/dev/null && break
  sleep 0.1
done
sed -n 's/^STOPPED /   /p' "$STATE/server.log"
wait "$SERVER_PID" 2>/dev/null || true
exit 0
