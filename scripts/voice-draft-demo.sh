#!/usr/bin/env bash
# Scripted, microphone-free dictation into a compose draft, in the dev harness.
#
#   scripts/voice-draft-demo.sh            hosted demo: the board's box dictated into
#
# With open_harness (HARNESS_DEV_SOCKET as reported), or the hosted demo above:
#   scripts/voice-draft-demo.sh start      open the board and start the call
#   scripts/voice-draft-demo.sh state      route, state, box text and controls
#   scripts/voice-draft-demo.sh show       show the board's box again
#   scripts/voice-draft-demo.sh submit     submit the draft as a task
#   scripts/voice-draft-demo.sh switch     make the same box a search box
#   scripts/voice-draft-demo.sh restore    give it its new-task purpose back
#   scripts/voice-draft-demo.sh submit-reset  submit, and show the next draft
#   scripts/voice-draft-demo.sh end        end the call
#
# The sidecar is the bundled `fixture' provider: it sends a transcript, a
# delegation and a reply from a script.  Nothing records audio, and no paid
# provider is called.  The delegation is routed by the real live transport to
# the board's real compose box, where it becomes the draft -- the reported
# failure was that this box said `Voice · no session' and could not start.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export HARNESS_DEV_SOCKET=${HARNESS_DEV_SOCKET:-harness-voice-draft-demo}
case "${1:-demo}" in
  demo)
    # Keep the sandbox alive for the daemon and its frame.  Other steps use
    # this named socket; Ctrl-C or the runner's stop tears the instance down.
    scripts/dev.sh start
    trap 'if [ -n "${sleep_pid:-}" ]; then kill "$sleep_pid" 2>/dev/null || true; fi; scripts/dev.sh stop >/dev/null 2>&1 || true' EXIT
    trap 'exit 0' INT TERM
    "$ROOT/scripts/voice-draft-demo.sh" start
    printf '%s\n' 'Voice dictation into the task board · scripted sidecar' \
      "Socket: $HARNESS_DEV_SOCKET" \
      'Steps: state, show, submit, submit-reset, switch, restore, end'
    while true; do sleep 3600 & sleep_pid=$!; wait "$sleep_pid" || true; done
    ;;
  start)
    exec scripts/dev.sh eval '(progn (load (expand-file-name "scripts/voice-draft-demo.el" harness-dev-root) nil t) (harness-voice-draft-demo-start))'
    ;;
  state) exec scripts/dev.sh eval '(harness-voice-draft-demo-state)' ;;
  show) exec scripts/dev.sh eval '(harness-voice-draft-demo-show)' ;;
  submit) exec scripts/dev.sh eval '(harness-voice-draft-demo-submit)' ;;
  switch) exec scripts/dev.sh eval '(harness-voice-draft-demo-switch)' ;;
  restore) exec scripts/dev.sh eval '(harness-voice-draft-demo-restore)' ;;
  submit-reset) exec scripts/dev.sh eval '(harness-voice-draft-demo-submit-reset)' ;;
  end) exec scripts/dev.sh eval '(harness-voice-draft-demo-end)' ;;
  -h|--help) printf '%s\n' 'Voice dictation into the task board · scripted sidecar' \
               'Commands: start, state, show, submit, submit-reset, switch, restore, end' ;;
  *) printf 'Unknown demo command: %s\n' "$1" >&2; exit 2 ;;
esac
exit 0
