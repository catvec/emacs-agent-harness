#!/usr/bin/env bash
# Show a live voice call surviving a reply the speech service cannot say.
#
# The real local sidecar (`scripts/harness-voice-live-unmute') runs in a
# real Emacs compose box, recording and playing through two fake
# programs that stand in for pw-record and pw-play, and talking to a stub
# speech service that answers the way the bundled pipeline does: a WAV
# for text it has phonemes for, and HTTP 200 with an EMPTY BODY for text
# it has none for, which is what Kokoro answers an emoji with.
#
# Two runs:
#
#   1. the agent's reply ends in an emoji.  The piece after the last full
#      stop has nothing to say, so Emacs never sends it at all.
#   2. the agent's reply is a normal sentence, and the stub refuses it
#      (`--refuse`), as Kokoro refuses a script it has no phonemes for.
#      The sidecar reports `notice', and the call goes on.
#
# Before the fix the empty body made the sidecar send `error' and Emacs
# ended the call in both runs, with "Live voice failed · Local speech ·
# no audio returned".
#
#   demo/voice-live-notice/demo.sh
# The README beside this script says what it shows.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STATE=$(mktemp -d)
PIDS=""
cleanup() {
  for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$STATE"
  return 0
}
trap cleanup EXIT

command -v python3 >/dev/null || { echo "python3 unavailable"; exit 2; }

port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

# The sound server, as far as the sidecar can tell: a recorder that says
# one sentence and then keeps the room quiet, and a player that drains
# what it is given.
BIN="$STATE/bin"; mkdir -p "$BIN"
cat >"$BIN/pw-record" <<'PY'
#!/usr/bin/env python3
import struct, sys, time
rate = 16000
tone = b"".join(struct.pack("<h", int(9000 * ((i // 40) % 2 * 2 - 1)))
                for i in range(int(rate * 1.2)))
silence = b"\x00\x00" * int(rate * 3)
sys.stdout.buffer.write(tone + silence)
sys.stdout.buffer.flush()
while True:
    sys.stdout.buffer.write(b"\x00\x00" * 320)
    sys.stdout.buffer.flush()
    time.sleep(0.02)
PY
cat >"$BIN/pw-play" <<'PY'
#!/usr/bin/env python3
import sys
while True:
    data = sys.stdin.buffer.read1(4096)
    if not data:
        break
PY
chmod +x "$BIN/pw-record" "$BIN/pw-play"

run() {                              # MODE · REFUSE
  local mode="$1" refuse="${2:-}"
  local stt tts
  stt=$(port); tts=$(port)
  python3 "$ROOT/demo/voice-live-notice/speech_service.py" "$stt" >"$STATE/stt-$mode.log" 2>&1 &
  PIDS="$PIDS $!"
  if [ -n "$refuse" ]; then
    python3 "$ROOT/demo/voice-live-notice/speech_service.py" "$tts" --refuse "$refuse" \
      >"$STATE/tts-$mode.log" 2>&1 &
  else
    python3 "$ROOT/demo/voice-live-notice/speech_service.py" "$tts" >"$STATE/tts-$mode.log" 2>&1 &
  fi
  PIDS="$PIDS $!"
  for _ in $(seq 1 100); do
    [ -s "$STATE/stt-$mode.log" ] && [ -s "$STATE/tts-$mode.log" ] && break
    sleep 0.05
  done
  echo "   stt http://127.0.0.1:$stt/inference"
  echo "   tts http://127.0.0.1:$tts/v1/audio/speech${refuse:+ · refusing \"$refuse\"}"
  PATH="$BIN:$PATH" HARNESS_DEMO_STATE="$STATE/client-$mode" \
    emacs -Q --batch -L "$ROOT/lisp" -L "$ROOT/lisp/modules" -L "$ROOT/lisp/ui" \
    -l "$ROOT/demo/voice-live-notice/client.el" \
    --eval "(harness-voice-live-notice-demo-run
              \"$ROOT\"
              \"http://127.0.0.1:$stt/inference\"
              \"http://127.0.0.1:$tts/v1/audio/speech\"
              \"$mode\")" 2>&1 \
    | sed -n 's/^/   /p'
}

echo "== stub speech service, answering like the bundled pipeline"
echo "   words get a WAV · an emoji or a refused script gets an empty body"
echo
echo "== 1 · a reply that ends in an emoji"
run emoji
echo
echo "== 2 · a reply the speech service refuses"
run refused "Nothing changed"
exit 0
