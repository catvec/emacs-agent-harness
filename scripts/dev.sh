#!/usr/bin/env bash
# Drive a dedicated GUI Emacs daemon running the harness from this checkout.
#
#   scripts/dev.sh start            start daemon + frame (idempotent)
#   scripts/dev.sh stop | restart
#   scripts/dev.sh status
#   scripts/dev.sh eval EXPR        evaluate elisp, print the result
#   scripts/dev.sh keys "C-c C-h"   send a real key sequence to the frame
#   scripts/dev.sh shot [PATH]      screenshot the frame (default scripts/.dev/shot.png)
#   scripts/dev.sh show BUFFER      display a buffer in the frame
#   scripts/dev.sh errors           recent *Messages* and harness log warnings
#   scripts/dev.sh reload           harness-reload
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOCKET=${HARNESS_DEV_SOCKET:-harness-v3}
DEVDIR="$ROOT/scripts/.dev"
export HARNESS_DEV_STATE=${HARNESS_DEV_STATE:-$DEVDIR/state-$SOCKET}
mkdir -p "$DEVDIR"

# Never let a wedged daemon hang the script (or a caller) forever.
DEV_TIMEOUT=${HARNESS_DEV_TIMEOUT:-60}
ec() { timeout "$DEV_TIMEOUT" emacsclient -s "$SOCKET" "$@"; }
alive() { ec --eval t >/dev/null 2>&1; }

cmd=${1:-status}; shift || true
case "$cmd" in
  start)
    if alive; then echo "daemon $SOCKET already running"; else
      (cd "$ROOT" && emacs -Q --daemon="$SOCKET" -l "$ROOT/scripts/harness-dev.el" >"$DEVDIR/daemon.log" 2>&1)
      for _ in $(seq 1 50); do alive && break; sleep 0.2; done
      alive || { echo "daemon failed to start"; cat "$DEVDIR/daemon.log"; exit 1; }
    fi
    ec --eval '(progn (harness-dev-frame) t)' >/dev/null && echo "daemon $SOCKET up, frame ready" ;;
  stop)
    alive && ec --eval '(kill-emacs)' >/dev/null 2>&1; echo "stopped" ;;
  restart) "$0" stop; sleep 0.5; "$0" start ;;
  status) if alive; then echo "running"; else echo "not running"; exit 1; fi ;;
  eval) ec --eval "$*" ;;
  keys) ec --eval "(harness-dev-keys $(printf '%q' "$*" | sed 's/^/"/;s/$/"/'))" ;;
  shot) out=${1:-$DEVDIR/shot.png}; ec --eval "(harness-dev-shot \"$out\")" >/dev/null && echo "$out" ;;
  show) ec --eval "(harness-dev-show \"$1\")" ;;
  errors) ec --eval '(harness-dev-errors)' | sed 's/^"//;s/"$//' | sed 's/\\n/\n/g;s/\\"/"/g' ;;
  reload) ec --eval '(harness-reload)' ;;
  *) echo "unknown command: $cmd"; exit 2 ;;
esac
