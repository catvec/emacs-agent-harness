#!/usr/bin/env bash
# A development Emacs of its own; never the user's active voice call.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
export HARNESS_DEV_SOCKET=${HARNESS_DEV_SOCKET:-voice-recovery-demo}
scripts/dev.sh start
scripts/dev.sh eval "(load \"$ROOT/demo/voice-recovery/demo.el\" nil t)"
scripts/dev.sh keys 'M-x harness-voice-recovery-demo RET'
printf '%s\n' 'Mock walkthrough: C-c C-n for hold, send, interrupt, new work, cancel.'
