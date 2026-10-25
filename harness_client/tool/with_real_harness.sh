#!/usr/bin/env bash
# Run a command against a real harness, started headless with the demo provider.
#
#   tool/with_real_harness.sh COMMAND [ARGUMENT...]
#
# It starts this checkout's harness the way the user's Emacs does, as an
# `emacs --batch' process of its own that serves ACP on a loopback port
# (lisp/harness-server.el), with every module and the demo provider, which
# answers a prompt or a search from its words and needs no account or
# network; waits for its address; runs COMMAND with
#
#   HARNESS_REAL_ADDRESS  the server's address, HOST:PORT (ACP's line framing)
#   HARNESS_REAL_TOKEN    the secret a connection to it signs in with
#   HARNESS_REAL_CWD      a directory to work in, which is no repository
#
# set; and stops the harness when COMMAND ends.  The exit status is COMMAND's.
# The checks that need a real harness skip themselves without
# HARNESS_REAL_ADDRESS, so this is how they run:
#
#   tool/with_real_harness.sh flutter test test/quick_search_real_harness_test.dart
#
# HARNESS_REAL_STATE names a state directory to keep between runs: the harness
# compiles itself into it, which takes about a minute the first time.  When the
# run fails the harness's own log is kept, and its place is said.
set -uo pipefail

if [ $# -eq 0 ]; then
  sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
  exit 64
fi

tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$tool_dir/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/real-harness.XXXXXX")"
state="${HARNESS_REAL_STATE:-$work/state}"
mkdir -p "$state" "$work/project"
keep=
pid=

stop_harness() {
  if [ -n "$pid" ]; then
    # SIGTERM runs the harness's kill hooks.
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  if [ -z "$keep" ]; then rm -rf "$work"; fi
}
trap stop_harness EXIT

# What the user's Emacs forwards to the harness process, by hand: where its
# state is, every module, and the demo provider as the model of everything.
cat > "$work/config.el" <<ELISP
;;; config.el --- forwarded by hand  -*- lexical-binding: t; -*-
(customize-set-variable 'harness-state-directory "$state/")
(customize-set-variable 'harness-enabled-modules t)
(customize-set-variable 'harness-tasks-store-in-repository nil)
(customize-set-variable 'harness-model "demo:scripted")
(customize-set-variable 'harness-tasks-model "demo:scripted")
(customize-set-variable 'harness-tasks-search-model "demo:scripted")
ELISP

# The secret of this one run, as the user's Emacs makes one for its harness.
token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"

HARNESS_SERVER_CONFIG="$work/config.el" HARNESS_SERVER_PARENT="$$" \
  HARNESS_SERVER_TOKEN="$token" \
  emacs --batch -Q -L "$root" -L "$root/lisp" \
  -l "$root/lisp/harness-server.el" -f harness-server-main \
  < /dev/null > /dev/null 2> "$work/harness.log" &
pid=$!

# The first start compiles the harness.
address=
for _ in $(seq 1 1200); do
  address="$(sed -n 's/^HARNESS-ACP-ADDRESS //p' "$work/harness.log" | head -n 1)"
  [ -n "$address" ] && break
  if ! kill -0 "$pid" 2>/dev/null; then
    keep=1
    echo "with_real_harness: the harness stopped before it served; its log is $work/harness.log" >&2
    tail -n 20 "$work/harness.log" >&2
    exit 70
  fi
  sleep 0.5
done
if [ -z "$address" ]; then
  keep=1
  echo "with_real_harness: the harness did not serve in time; its log is $work/harness.log" >&2
  exit 70
fi

export HARNESS_REAL_ADDRESS="$address"
export HARNESS_REAL_TOKEN="$token"
export HARNESS_REAL_CWD="$work/project"
echo "with_real_harness: the harness serves ACP at $address" >&2

"$@"
status=$?
if [ "$status" -ne 0 ]; then
  keep=1
  echo "with_real_harness: the command failed ($status); the harness's log is $work/harness.log" >&2
fi
exit "$status"
