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
#
# The daemon loads every module (`harness-enabled-modules' t), so that
# every feature can be tried; HARNESS_DEV_MODULES=default starts it with
# the harness's defaults instead, the core only.
#
# The daemon's socket is in the checkout, scripts/.dev/run/SOCKET, so a
# command the harness runs in its sandbox (the bash tool) reaches a
# daemon the harness started outside it: the sandbox shows the checkout
# but not $XDG_RUNTIME_DIR, where Emacs puts its sockets by default.  A
# Unix socket's name holds 107 bytes at most, too few for the path of a
# task's worktree, so both ends name the socket through /proc/PID/cwd,
# PID being a process that works in the checkout: the daemon itself
# (harness-dev.el) and this script, for emacsclient.
#
# HARNESS_DEV_SOCKET is the daemon's emacsclient socket: a name, or the
# path of the socket's file.  HARNESS_DEV_SOCKET_DIR puts a socket given
# by name in that directory instead of the checkout's scripts/.dev/run;
# harness-v3 is the name when unset.  The harness's open_harness gives a name and a directory, and links the socket into
# the agent's temporary directory, where its sandboxed shell reaches it:
# it lists the commands to run with that link as HARNESS_DEV_SOCKET.
# HARNESS_DEV_STATE is the daemon's state directory (default
# scripts/.dev/state-NAME, NAME being the socket's name).
#
# In the harness's sandbox (HARNESS_SANDBOX is set there) an Emacs this
# script starts ends with the command that started it: `start' warns,
# and starts it all the same, for a command that starts, drives and
# stops it in one go.  For one that stays, call the open_harness tool.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SELF="$ROOT/scripts/$(basename "$0")"
SOCKET=${HARNESS_DEV_SOCKET:-harness-v3}
case "$SOCKET" in
  /*) ;;
  # Relative to here, not to $ROOT, where `start' runs the daemon.
  */*) SOCKET="$PWD/$SOCKET" ;;
  *) [ -n "${HARNESS_DEV_SOCKET_DIR:-}" ] && SOCKET="${HARNESS_DEV_SOCKET_DIR%/}/$SOCKET" ;;
esac
NAME=${SOCKET##*/}
DEVDIR="$ROOT/scripts/.dev"
export HARNESS_DEV_STATE=${HARNESS_DEV_STATE:-$DEVDIR/state-$NAME}
mkdir -p "$DEVDIR"

# This script works in the checkout, through which it names the socket;
# emacsclient runs where the caller is, which the daemon takes for the
# default-directory of what it evaluates.  A socket named with a slash
# is the caller's own, used as given.
HERE=$PWD
cd "$ROOT" || exit 1
case $SOCKET in
  */*) SOCKPATH=$SOCKET ;;
  *) if [ -d "/proc/$$/cwd" ]; then SOCKPATH="/proc/$$/cwd/scripts/.dev/run/$SOCKET"
     else SOCKPATH="$DEVDIR/run/$SOCKET"; fi ;;
esac

# Bound each command, and probe an existing daemon more quickly.  A probe
# timeout means it may be busy, not that it is safe to start another one.
DEV_TIMEOUT=${HARNESS_DEV_TIMEOUT:-60}
DEV_PROBE_TIMEOUT=${HARNESS_DEV_PROBE_TIMEOUT:-5}
# A socket's address holds about a hundred bytes (104 on macOS, 108 on
# Linux), which the path of a socket in a session's temporary directory
# can pass: emacsclient then connects from that directory, by a relative
# name.  It sends its working directory along, which becomes
# default-directory for --eval, so `shot' makes its PATH absolute first.
ec() {
  local s=$SOCKPATH
  # With no socket in the checkout, look where Emacs puts sockets by
  # default: a daemon an older dev.sh started has its socket there.
  case $SOCKET in */*) ;; *) [ -S "$DEVDIR/run/$SOCKET" ] || s=$SOCKET ;; esac
  case $SOCKET in
    */*) if [ ${#SOCKET} -gt 100 ]; then
           (cd "${SOCKET%/*}" && exec timeout "$DEV_TIMEOUT" emacsclient -a false -s "./$NAME" "$@")
           return
         fi ;;
  esac
  (cd "$HERE" && timeout "$DEV_TIMEOUT" emacsclient -a false -s "$s" "$@")
}
alive() { DEV_TIMEOUT=$DEV_PROBE_TIMEOUT ec --eval t >/dev/null 2>&1; }
not_responding() {
  echo "daemon $SOCKET did not respond within ${DEV_PROBE_TIMEOUT}s; it may be busy or stuck. Cancel its operation in its frame (C-g). If open_harness opened it, explicitly call open_harness with restart=true; otherwise stop this daemon manually before retrying (unsaved work in the instance will be lost)." >&2
}

cmd=${1:-status}; shift || true
case "$cmd" in
  start)
    if alive; then
      echo "daemon $SOCKET already running"
    else
      status=$?
      if [ "$status" -eq 124 ]; then not_responding; exit 1; fi
      if [ -n "${HARNESS_SANDBOX:-}" ]; then
        echo "dev.sh: warning: in the harness sandbox ($HARNESS_SANDBOX) this Emacs ends with the command that started it; for one that stays, call the open_harness tool and drive it with the commands it lists" >&2
      fi
      # Started in the checkout, which the daemon names its socket through.
      (cd "$ROOT" && emacs -Q --daemon="$SOCKET" -l "$ROOT/scripts/harness-dev.el" >"$DEVDIR/daemon.log" 2>&1)
      started=0
      for _ in $(seq 1 50); do
        if alive; then started=1; break; else status=$?; fi
        if [ "$status" -eq 124 ]; then not_responding; exit 1; fi
        sleep 0.2
      done
      [ "$started" = 1 ] || { echo "daemon failed to start"; cat "$DEVDIR/daemon.log"; exit 1; }
    fi
    if ec --eval '(progn (harness-dev-frame) t)' >/dev/null; then
      echo "daemon $SOCKET up, frame ready"
    else
      status=$?
      echo "daemon $SOCKET could not create its frame (exit $status); see $DEVDIR/daemon.log" >&2
      exit "$status"
    fi ;;
  stop)
    if alive; then
      if ec --eval '(kill-emacs)' >/dev/null; then echo "stopped"; else
        status=$?; echo "daemon $SOCKET could not be stopped (exit $status)" >&2; exit "$status"
      fi
    else
      status=$?
      if [ "$status" -eq 124 ]; then not_responding; exit 1; fi
      echo "not running"
    fi ;;
  restart) "$SELF" stop && { sleep 0.5; "$SELF" start; } ;;
  status)
    if alive; then echo "running"; else
      status=$?
      if [ "$status" -eq 124 ]; then not_responding; else echo "not running"; fi
      exit 1
    fi ;;
  eval) ec --eval "$*" ;;
  # An Elisp string: only \ and " are escaped.  The shell's quoting of
  # printf %q would not do, as Lisp drops the backslash before a space.
  keys) ec --eval "(harness-dev-keys \"$(printf '%s' "$*" | sed 's/[\\"]/\\&/g')\")" ;;
  shot) out=${1:-$DEVDIR/shot.png}
        case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
        ec --eval "(harness-dev-shot \"$out\")" >/dev/null && echo "$out" ;;
  show) ec --eval "(harness-dev-show \"$1\")" ;;
  errors) ec --eval '(harness-dev-errors)' | sed 's/^"//;s/"$//' | sed 's/\\n/\n/g;s/\\"/"/g' ;;
  reload) ec --eval '(harness-reload)' ;;
  *) echo "unknown command: $cmd"; exit 2 ;;
esac
