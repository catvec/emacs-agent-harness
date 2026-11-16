#!/usr/bin/env bash
# Scripted, microphone-free voice turn completion in the development harness.
#
#   scripts/voice-turn-demo.sh             hosted demo, trailing “hold on”
#
# With open_harness (HARNESS_DEV_SOCKET as reported), or the hosted demo above:
#   scripts/voice-turn-demo.sh start       fresh call, trailing “hold on”
#   scripts/voice-turn-demo.sh more        continuation, one combined request
#   scripts/voice-turn-demo.sh cut         likely fragment, no automatic send
#   scripts/voice-turn-demo.sh recover     “Go on”, releases the held fragment
#   scripts/voice-turn-demo.sh truncated   complete text, real hard-cut metadata
#   scripts/voice-turn-demo.sh ordinary    normal ending, 1.2-second grace
#   scripts/voice-turn-demo.sh early       submitted fragment, then resumed speech
#   scripts/voice-turn-demo.sh go-on       the continuation that takes it back
#   scripts/voice-turn-demo.sh early-more  a second pause in the same thought
#   scripts/voice-turn-demo.sh early-tool  a turn that ran a tool: history kept
#   scripts/voice-turn-demo.sh early-off   the recovery window off
#   scripts/voice-turn-demo.sh state       actual stage and committed messages
#   scripts/voice-turn-demo.sh end         clean stop
#
# HARNESS_DEV_SOCKET selects the instance open_harness names.  This script
# never records audio or calls a paid provider; its session uses demo:scripted.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export HARNESS_DEV_SOCKET=${HARNESS_DEV_SOCKET:-harness-voice-turn-demo}
case "${1:-demo}" in
  demo)
    # Keep the sandbox alive for the daemon and its frame. Other demo steps
    # use this named socket; Ctrl-C/runner stop tears the instance down too.
    scripts/dev.sh start
    trap 'if [ -n "${sleep_pid:-}" ]; then kill "$sleep_pid" 2>/dev/null || true; fi; scripts/dev.sh stop >/dev/null 2>&1 || true' EXIT
    trap 'exit 0' INT TERM
    "$ROOT/scripts/voice-turn-demo.sh" start
    printf '%s\n' 'Voice turn completion · scripted speech' \
      "Socket: $HARNESS_DEV_SOCKET" \
      'Steps: more, cut, recover, truncated, ordinary, early, go-on, early-more, early-tool, state, end'
    while true; do sleep 3600 & sleep_pid=$!; wait "$sleep_pid" || true; done
    ;;
  start|reset)
    exec scripts/dev.sh eval '(progn (load (expand-file-name "scripts/voice-turn-demo.el" harness-dev-root) nil t) (harness-voice-turn-demo-start))'
    ;;
  start-quiet)
    # A fresh call with nothing said: the premature-submission walkthrough.
    exec scripts/dev.sh eval '(progn (load (expand-file-name "scripts/voice-turn-demo.el" harness-dev-root) nil t) (harness-voice-turn-demo-start ""))'
    ;;
  more|cut|recover|truncated|ordinary|hold|early|go-on|early-more|early-tool|early-off)
    exec scripts/dev.sh eval "(harness-voice-turn-demo-step '$1)"
    ;;
  state) exec scripts/dev.sh eval '(harness-voice-turn-demo-state)' ;;
  show) exec scripts/dev.sh eval '(harness-voice-turn-demo-show)' ;;
  end) exec scripts/dev.sh eval '(harness-voice-live-stop)' ;;
  -h|--help) printf '%s\n' 'Voice turn completion · scripted speech' 'Commands: start, more, cut, recover, truncated, ordinary, hold, early, go-on, early-more, early-tool, early-off, state, show, end' ;;
  *) printf 'Unknown demo command: %s\n' "$1" >&2; exit 2 ;;
esac
