#!/usr/bin/env bash
# Regenerate the README screenshots in docs/media.
#
#   scripts/media.sh               every picture
#   scripts/media.sh chat tasks    only these (the names are in harness-media-shots)
#
# Runs scripts/harness-media.el in a fresh `emacs -Q': the harness of
# this checkout, isolated in a throwaway HOME with a demo project and
# scripted agents, so no real session, path or model call appears.  The
# pictures are exported by Emacs itself (`x-export-frames') from a
# private display, so nothing shows on yours: Xvfb when it is installed,
# else a headless kwin_wayland with a rootful Xwayland (KDE), else
# $DISPLAY, where a frame then shows while the run lasts.
#
# Environment:
#   HARNESS_MEDIA_OUT      where the pictures go (default docs/media)
#   HARNESS_MEDIA_DUMPS    also write each picture's text there, to review it
#   HARNESS_MEDIA_WORK     scratch directory (default scripts/.dev/media)
#   HARNESS_MEDIA_DISPLAY  use this X display rather than a private one
#   HARNESS_MEDIA_RUNTIME  where the private display's sockets go
#                          (default $XDG_RUNTIME_DIR, else /tmp)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${HARNESS_MEDIA_WORK:-$ROOT/scripts/.dev/media}
export HARNESS_MEDIA_OUT=${HARNESS_MEDIA_OUT:-$ROOT/docs/media}
export HARNESS_MEDIA_SHOTS="$*"
WIDTH=1920 HEIGHT=1200

command -v emacs >/dev/null || { echo "media: emacs is not on PATH" >&2; exit 1; }
command -v git >/dev/null || { echo "media: git is not on PATH" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"

pids=()
runtime=
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [ -n "$runtime" ]; then rm -rf "$runtime"; fi
}
trap cleanup EXIT

# Wait up to 10 seconds for the test to succeed.
await() {
  for _ in $(seq 100); do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  return 1
}

start_xvfb() {
  command -v Xvfb >/dev/null || return 1
  Xvfb -displayfd 3 -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp \
       3>"$WORK/display" 2>"$WORK/xvfb.log" &
  pids+=($!)
  await test -s "$WORK/display" || return 1
  display=":$(head -n1 "$WORK/display")"
}

# kwin_wayland renders to memory with --virtual.  Its own Xwayland needs
# /tmp/.X11-unix, so a rootful Xwayland of ours listens on a socket in
# a private runtime directory instead, and DISPLAY names that socket.
start_kwin() {
  command -v kwin_wayland >/dev/null && command -v Xwayland >/dev/null && command -v python3 >/dev/null || return 1
  runtime=$(mktemp -d "${HARNESS_MEDIA_RUNTIME:-${XDG_RUNTIME_DIR:-/tmp}}/harness-media.XXXXXX") || return 1
  chmod 700 "$runtime"
  env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$runtime" \
      kwin_wayland --virtual --width "$WIDTH" --height "$HEIGHT" --socket wayland-media \
                   --no-lockscreen --no-global-shortcuts >"$WORK/kwin.log" 2>&1 &
  pids+=($!)
  await test -S "$runtime/wayland-media" || return 1
  # GLX and GPU buffers are off: they crash some drivers headless, and
  # the pictures do not need them.
  env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY=wayland-media \
      python3 -c '
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(64)
os.set_inheritable(s.fileno(), True)
os.execvp("Xwayland", ["Xwayland", ":99", "-listenfd", str(s.fileno())] + sys.argv[2:])
' "$runtime/X0" -geometry "${WIDTH}x${HEIGHT}" -noreset -shm -extension GLX >"$WORK/xwayland.log" 2>&1 &
  pids+=($!)
  await test -S "$runtime/X0" || return 1
  sleep 1
  display=$runtime/X0
}

display=${HARNESS_MEDIA_DISPLAY:-}
if [ -z "$display" ]; then
  if start_xvfb; then echo "media: drawing on Xvfb $display"
  elif start_kwin; then echo "media: drawing on a headless kwin_wayland"
  elif [ -n "${DISPLAY:-}" ]; then
    display=$DISPLAY
    echo "media: no Xvfb or kwin_wayland; drawing on $display, where a frame shows meanwhile"
  else
    echo "media: no display: install Xvfb, or set HARNESS_MEDIA_DISPLAY" >&2
    exit 1
  fi
fi

# A HOME of its own: the demo project and the harness state live there,
# so paths read ~/src/acme-api and nothing touches the real ones.
home=$WORK/home
mkdir -p "$home/.emacs.d"
cat >"$home/.gitconfig" <<'EOF'
[user]
	name = Sam Rivera
	email = sam@acme.example
[init]
	defaultBranch = main
[commit]
	gpgsign = false
EOF

status=0
env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_STATE_HOME -u WAYLAND_DISPLAY \
    HOME="$home" DISPLAY="$display" GDK_SCALE=1 GDK_DPI_SCALE=1 \
    timeout 900 emacs -Q -l "$ROOT/scripts/harness-media.el" -f harness-media-main \
    2> >(tee "$WORK/emacs.log" | grep --line-buffered '^media: ' >&2) || status=$?

if [ "$status" -ne 0 ]; then
  echo "media: failed (status $status); the last lines Emacs printed:" >&2
  tail -n 20 "$WORK/emacs.log" >&2
  exit "$status"
fi
echo "media: pictures in $HARNESS_MEDIA_OUT"
