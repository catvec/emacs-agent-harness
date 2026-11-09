#!/usr/bin/env bash
# Run the computer-use demo: a private X display, x11vnc, a noVNC bridge and
# Firefox on a page an agent can see and drive.
#
#   scripts/computer-use-demo.sh start    start it, print its display and VNC endpoints
#   scripts/computer-use-demo.sh status   say whether it runs and where
#   scripts/computer-use-demo.sh stop     stop the processes it started
#
# `start' writes `scripts/.dev/computer-use/state.el', which a harness Emacs
# loads to lend this display as a computer:
#
#   scripts/dev.sh eval '(load-file "scripts/.dev/computer-use/state.el")'
#   scripts/dev.sh eval '(harness-computer-endpoint-refresh #\='harness-ui-request "local")'
#
# The display is an Xvfb; nothing here touches the display you use.  The
# programs it needs are Xvfb, x11vnc, xdotool, wmctrl and openbox, and
# Firefox.  On Arch Linux, when one is missing, it downloads the package from
# the Arch mirror into `scripts/.dev/computer-use/root' and runs it from
# there, so no root is needed; on another system install them first.
#
# Every port and display is private: the RFB server and the noVNC bridge bind
# loopback only, and the bridge needs its token.  The X server takes no
# authentication, as it is reachable only through the loopback socket.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE=${HARNESS_COMPUTER_USE_STATE:-$ROOT/scripts/.dev/computer-use}
PREFIX=${HARNESS_COMPUTER_USE_PREFIX:-$STATE/root}
NAME=${HARNESS_COMPUTER_USE_NAME:-computer-use}
DISPLAY_NUMBER=${HARNESS_COMPUTER_USE_DISPLAY:-:99}
RFB_PORT=${HARNESS_COMPUTER_USE_RFB_PORT:-5901}
WEB_PORT=${HARNESS_COMPUTER_USE_WEB_PORT:-6080}
TOKEN=${HARNESS_COMPUTER_USE_TOKEN:-demo-token}
DEMO_PAGE=${HARNESS_COMPUTER_USE_PAGE:-$ROOT/demo/computer-use/index.html}
WIDTH=${HARNESS_COMPUTER_USE_WIDTH:-1280}
HEIGHT=${HARNESS_COMPUTER_USE_HEIGHT:-800}
PID_FILE=$STATE/pids
STATE_EL=$STATE/state.el
LOG=$STATE/demo.log

mkdir -p "$STATE"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "computer-use-demo: $*" >&2; exit 1; }

# ---- the programs -------------------------------------------------------

package_url() {
  local pkg=$1 filename
  filename=$(curl -fsSL "https://archlinux.org/packages/extra/x86_64/$pkg/json/" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["filename"])') || return 1
  printf 'https://geo.mirror.pkgbuild.com/extra/os/x86_64/%s\n' "$filename"
}

install_package() {
  local pkg=$1 url archive
  url=$(package_url "$pkg") || return 1
  archive="$STATE/pkgs/${url##*/}"
  mkdir -p "$STATE/pkgs"
  [ -f "$archive" ] || curl -fL -o "$archive" "$url"
  bsdtar -xf "$archive" -C "$PREFIX"
}

find_tool() {
  local name=$1 package=${2:-$1}
  if [ -x "$PREFIX/usr/bin/$name" ]; then
    printf '%s\n' "$PREFIX/usr/bin/$name"
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  if [ -f /etc/arch-release ] && command -v bsdtar >/dev/null 2>&1 &&
     command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    mkdir -p "$PREFIX"
    install_package "$package" >/dev/null 2>&1 || true
    # x11vnc's RFB library is a package of its own.
    if [ "$package" = x11vnc ]; then
      install_package libvncserver >/dev/null 2>&1 || true
    fi
    if [ -x "$PREFIX/usr/bin/$name" ]; then
      printf '%s\n' "$PREFIX/usr/bin/$name"
      return 0
    fi
  fi
  return 1
}

needed() {
  local tool
  for tool in Xvfb x11vnc xdotool wmctrl openbox; do
    find_tool "$tool" >/dev/null || die "missing $tool (install it, or let this script fetch it on Arch)"
  done
  command -v firefox >/dev/null 2>&1 || die "missing firefox"
  command -v python3 >/dev/null 2>&1 || die "missing python3"
}

# ---- private display and ports -----------------------------------------

display_free() {
  local number=${1#:}
  [ ! -e "/tmp/.X11-unix/X$number" ]
}

port_free() {
  ! python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

pick_display() {
  local n=${1#:}
  while ! display_free ":$n"; do n=$((n + 1)); done
  printf ':%d\n' "$n"
}

pick_port() {
  local port=$1
  while ! port_free "$port"; do port=$((port + 1)); done
  printf '%d\n' "$port"
}

wait_socket() {
  local number=${1#:} tries=${2:-100}
  for _ in $(seq 1 "$tries"); do
    [ -S "/tmp/.X11-unix/X$number" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_port() {
  local port=$1 tries=${2:-100}
  for _ in $(seq 1 "$tries"); do
    if python3 - "$port" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
    then return 0; fi
    sleep 0.1
  done
  return 1
}

# ---- start and stop ----------------------------------------------------

start() {
  needed
  if [ -f "$PID_FILE" ] && kill -0 "$(head -n 1 "$PID_FILE")" 2>/dev/null; then
    say "computer-use-demo: already running; use stop first"
    status
    return 0
  fi
  DISPLAY_NUMBER=$(pick_display "$DISPLAY_NUMBER")
  RFB_PORT=$(pick_port "$RFB_PORT")
  WEB_PORT=$(pick_port "$WEB_PORT")
  local xvfb x11vnc xdotool wmctrl openbox firefox profile
  xvfb=$(find_tool Xvfb)
  x11vnc=$(find_tool x11vnc)
  xdotool=$(find_tool xdotool)
  wmctrl=$(find_tool wmctrl)
  openbox=$(find_tool openbox)
  firefox=$(command -v firefox)
  profile=$STATE/firefox-profile${DISPLAY_NUMBER#:}
  mkdir -p "$profile" "$STATE/openbox"
  : > "$LOG"
  : > "$PID_FILE"
  export LD_LIBRARY_PATH="$PREFIX/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export XDG_DATA_DIRS="$PREFIX/usr/share:/usr/share"
  export XDG_CONFIG_HOME="$STATE/openbox"
  unset WAYLAND_DISPLAY XDG_SESSION_TYPE DBUS_SESSION_BUS_ADDRESS
  export DISPLAY=$DISPLAY_NUMBER

  setsid nohup "$xvfb" "$DISPLAY_NUMBER" -screen 0 "${WIDTH}x${HEIGHT}x24" \
    -nolisten tcp -ac -extension GLX </dev/null >>"$LOG" 2>&1 &
  echo $! >> "$PID_FILE"
  wait_socket "$DISPLAY_NUMBER" || die "the X display did not start (see $LOG)"

  setsid nohup "$openbox" --replace </dev/null >>"$LOG" 2>&1 &
  echo $! >> "$PID_FILE"

  setsid nohup "$firefox" --no-remote --profile "$profile" --kiosk \
    "file://$DEMO_PAGE" </dev/null >>"$LOG" 2>&1 &
  echo $! >> "$PID_FILE"

  setsid nohup "$x11vnc" -display "$DISPLAY_NUMBER" -localhost -forever \
    -shared -nopw -rfbport "$RFB_PORT" </dev/null >>"$LOG" 2>&1 &
  echo $! >> "$PID_FILE"
  wait_port "$RFB_PORT" || die "x11vnc did not listen (see $LOG)"

  setsid nohup python3 "$ROOT/scripts/workspace-box/websockify.py" \
    --listen "127.0.0.1:$WEB_PORT" --target "127.0.0.1:$RFB_PORT" \
    --token "$TOKEN" --web-root "$ROOT/scripts/workspace-box/novnc" \
    </dev/null >>"$LOG" 2>&1 &
  echo $! >> "$PID_FILE"
  wait_port "$WEB_PORT" || die "the noVNC bridge did not listen (see $LOG)"

  local url="http://127.0.0.1:$WEB_PORT/vnc_lite.html?path=websockify%3Ftoken%3D$TOKEN&autoconnect=1"
  local socket="ws://127.0.0.1:$WEB_PORT/websockify?token=$TOKEN"
  cat > "$STATE_EL" <<ELISP
;;; state.el --- the computer-use demo's display, as a harness Emacs lends it  -*- lexical-binding: t; -*-
(setq harness-computer-endpoint-display "$DISPLAY_NUMBER"
      harness-computer-endpoint-vnc-url "$url"
      harness-computer-endpoint-vnc-socket "$socket")
(add-to-list 'exec-path "$PREFIX/usr/bin")
(setenv "PATH" (concat "$PREFIX/usr/bin:" (getenv "PATH")))
(setenv "LD_LIBRARY_PATH" (concat "$PREFIX/usr/lib:" (or (getenv "LD_LIBRARY_PATH") "")))
(provide 'computer-use-demo-state)
;;; state.el ends here
ELISP
  cat > "$STATE/summary" <<SUMMARY
display=$DISPLAY_NUMBER
rfb=127.0.0.1:$RFB_PORT
web=127.0.0.1:$WEB_PORT
url=$url
socket=$socket
page=file://$DEMO_PAGE
token=$TOKEN
SUMMARY
  say "COMPUTER-USE DISPLAY $DISPLAY_NUMBER"
  say "VNC PAGE     $url"
  say "VNC SOCKET   $socket"
  say "RFB          127.0.0.1:$RFB_PORT"
  say "STATE        $STATE_EL"
  say "LOG          $LOG"
}

stop() {
  if [ ! -f "$PID_FILE" ]; then
    say "computer-use-demo: not running"
    return 0
  fi
  local pid
  while read -r pid; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done < <(tac "$PID_FILE")
  sleep 0.4
  while read -r pid; do
    [ -n "$pid" ] || continue
    kill -9 "$pid" 2>/dev/null || true
  done < <(tac "$PID_FILE")
  rm -f "$PID_FILE"
  say "computer-use-demo: stopped"
}

status() {
  if [ -f "$PID_FILE" ] && kill -0 "$(head -n 1 "$PID_FILE")" 2>/dev/null; then
    say "computer-use-demo: running"
    cat "$STATE/summary" 2>/dev/null || true
  else
    say "computer-use-demo: stopped"
  fi
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//' ;;
  *) say "usage: $0 start|stop|status" >&2; exit 64 ;;
esac
