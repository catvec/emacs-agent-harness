# shellcheck shell=bash
# A private display for Emacs to draw on, shared by the capture scripts.  Source it, then call
# `display_start WIDTH HEIGHT WORK RUNTIME_BASE`: it sets $display (for Emacs's DISPLAY) and registers
# every process it starts in $pids, which the caller kills in its EXIT trap.
#
# Chosen as scripts/media.sh chooses it: Xvfb when it is installed, else a headless kwin_wayland with a
# rootful Xwayland (KDE), else $DISPLAY, where a frame then shows while the run lasts.

pids=()
runtime=
display=

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
  Xvfb -displayfd 3 -screen 0 "${1}x${2}x24" -nolisten tcp \
       3>"$3/display" 2>"$3/xvfb.log" &
  pids+=($!)
  await test -s "$3/display" || return 1
  display=":$(head -n1 "$3/display")"
}

# kwin_wayland renders to memory with --virtual.  Its own Xwayland needs /tmp/.X11-unix, so a rootful
# Xwayland of ours listens on a socket in a private runtime directory instead, and DISPLAY names that socket.
start_kwin() {
  local width=$1 height=$2 work=$3 base=$4
  command -v kwin_wayland >/dev/null && command -v Xwayland >/dev/null || return 1
  runtime=$(mktemp -d "$base/pc.XXXXXX") || return 1
  chmod 700 "$runtime"
  # The longest socket in it is wayland-media: 14 bytes with the slash.
  if [ $(( ${#runtime} + 14 )) -gt 107 ]; then
    echo "capture: $runtime is too long for a socket path (limit 107 bytes); set PROMO_CAPTURE_RUNTIME to a shorter directory" >&2
    return 1
  fi
  env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$runtime" \
      kwin_wayland --virtual --width "$width" --height "$height" --socket wayland-media \
                   --no-lockscreen --no-global-shortcuts >"$work/kwin.log" 2>&1 &
  pids+=($!)
  await test -S "$runtime/wayland-media" || return 1
  # GLX and GPU buffers are off: they crash some drivers headless, and the pictures do not need them.
  # A display number nobody holds: another capture may be running (Xwayland keeps a lock file in /tmp).
  local number=99
  while [ -e "/tmp/.X$number-lock" ]; do number=$((number + 1)); done
  env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY=wayland-media \
      python3 -I -c '
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(64)
os.set_inheritable(s.fileno(), True)
os.execvp("Xwayland", ["Xwayland", sys.argv[2], "-listenfd", str(s.fileno())] + sys.argv[3:])
' "$runtime/X0" ":$number" -geometry "${width}x${height}" -noreset -shm -extension GLX >"$work/xwayland.log" 2>&1 &
  pids+=($!)
  await test -S "$runtime/X0" || return 1
  sleep 1
  display=$runtime/X0
}

display_start() {
  local width=$1 height=$2 work=$3 base=$4
  display=${PROMO_CAPTURE_DISPLAY:-}
  if [ -n "$display" ]; then return 0; fi
  if start_xvfb "$width" "$height" "$work"; then echo "capture: drawing on Xvfb $display"
  elif start_kwin "$width" "$height" "$work" "$base"; then echo "capture: drawing on a headless kwin_wayland"
  elif [ -n "${DISPLAY:-}" ]; then
    display=$DISPLAY
    echo "capture: no Xvfb or kwin_wayland; drawing on $display, where a frame shows meanwhile"
  else
    echo "capture: no display: install Xvfb, or set PROMO_CAPTURE_DISPLAY" >&2
    return 1
  fi
}

display_stop() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [ -n "$runtime" ]; then rm -rf "$runtime"; fi
}
