#!/usr/bin/env bash
# Drive a live GUI Emacs running the harness.
#
#   scripts/dev.sh start        start the daemon + GUI frame
#   scripts/dev.sh stop         stop it
#   scripts/dev.sh restart      stop + start
#   scripts/dev.sh eval EXPR    evaluate an expression in it
#   scripts/dev.sh keys KEYS    send a kbd string (e.g. 'C-c h c')
#   scripts/dev.sh shot [FILE]  screenshot the harness frame (default .dev/shot.png)
#   scripts/dev.sh errors       show recent *Messages* output
#   scripts/dev.sh status       is it running?
#
# Everything runs against the daemon named `harness-dev'.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="$REPO/scripts/.dev"
SOCK="harness-dev"
EMACS="${EMACS:-emacs}"

mkdir -p "$DEV_DIR"

ec() { emacsclient -s "$SOCK" "$@"; }

# Always pick up the latest dev helpers, then evaluate the expression.
ec_eval() {
  emacsclient -s "$SOCK" \
    --eval "(progn (load \"$REPO/scripts/harness-dev.el\" nil nil 'nomessage) nil)" \
    --eval "$1"
}

start() {
  if status >/dev/null 2>&1; then
    echo "harness-dev already running"
    return 0
  fi
  echo "starting harness-dev..."
  "$EMACS" -Q --daemon="$SOCK" \
           --load "$REPO/scripts/harness-dev.el" \
           --eval '(progn (harness-dev-toggle-debug 1)
                          (harness-dev-load-safely)
                          (when (fboundp (quote harness-auto-reload-mode))
                            (harness-auto-reload-mode 1)))' \
           >"$DEV_DIR/daemon.out" 2>&1 &
  for _ in $(seq 1 100); do
    if ec --eval 't' >/dev/null 2>&1; then
      # Open a real GUI frame through emacsclient so the display is the
      # client's, then make sure it is focused.
      emacsclient -s "$SOCK" -c -n >/dev/null 2>&1 || true
      sleep 0.3
      ec --eval '(harness-dev-focus)' >/dev/null 2>&1 || true
      echo "ready (sock: $SOCK)"
      return 0
    fi
    sleep 0.2
  done
  echo "failed to start; see $DEV_DIR/daemon.out" >&2
  cat "$DEV_DIR/daemon.out" >&2 || true
  return 1
}

stop() {
  if ec --eval '(save-buffers-kill-emacs t)' >/dev/null 2>&1; then
    echo "stopped"
  else
    echo "not running"
  fi
}

restart() { stop || true; sleep 0.5; start; }

status() {
  ec --eval 't' >/dev/null 2>&1
}

eval_expr() {
  ec_eval "$1"
}

keys() {
  ec_eval "(harness-dev-keys \"$1\")" >/dev/null
}

shot() {
  local out="${1:-$DEV_DIR/shot.png}"
  mkdir -p "$(dirname "$out")"
  ec_eval '(harness-dev-focus)' >/dev/null 2>&1 || true
  sleep 0.3
  if command -v spectacle >/dev/null 2>&1; then
    # Wayland/KDE: scrot sees only black under Xwayland, the portal does not.
    spectacle -b -n -a -o "$out" >/dev/null 2>&1
  else
    local wid
    wid="$(ec_eval '(harness-dev-window-id)' 2>/dev/null | tail -n1 | tr -d '"' || true)"
    if [[ "$wid" =~ ^0x[0-9a-fA-F]+$ ]]; then
      scrot -z -o -w "$wid" "$out"
    else
      scrot -z -o -u "$out"
    fi
  fi
  echo "$out"
}

errors() { ec_eval '(harness-dev-errors)'; }

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  restart) restart ;;
  eval)    shift; eval_expr "$*" ;;
  keys)    shift; keys "$*" ;;
  shot)    shift; shot "${1:-}" ;;
  errors)  errors ;;
  status)  if status; then echo running; else echo stopped; exit 1; fi ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
