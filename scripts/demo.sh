#!/usr/bin/env bash
# Drive a complete demo conversation in the live GUI and screenshot it.
#
#   scripts/demo.sh [THEME] [OUTPUT]
#
# Loads the demo provider, creates a session, sends a prompt, answers the
# approval panel, scrolls to the top of the transcript and captures the
# frame.  Run scripts/dev.sh start first (or this restarts the daemon if
# it is not running).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEME="${1:-}"
OUT="${2:-$REPO/scripts/.dev/demo.png}"
DEV="$REPO/scripts/dev.sh"

"$DEV" status >/dev/null 2>&1 || "$DEV" start >/dev/null

"$DEV" eval '(progn (setq debug-on-error nil) (harness-start) (condition-case nil (harness-reload) (error nil)) t)' >/dev/null
"$DEV" eval '(progn (dolist (b (buffer-list)) (when (string-prefix-p "*harness" (buffer-name b)) (kill-buffer b))) (clrhash harness-ui-chat--buffers) t)' >/dev/null
"$DEV" eval "(progn (load \"$REPO/scripts/harness-gui-demo.el\" nil t) (harness-gui-demo-install) t)" >/dev/null
# `harness-gui-demo-install` already sends the opening prompt.
sleep 3
"$DEV" eval '(harness-ui-ask-answer "allow-once") t' >/dev/null
sleep 2.5
if [[ -n "$THEME" ]]; then
  "$DEV" eval "(progn (load-theme '$THEME t) t)" >/dev/null
fi
"$DEV" eval '(let* ((id (symbol-value (quote harness-ui-current-session)))
                    (b (gethash id harness-ui-chat--buffers))
                    (w (get-buffer-window b t)))
               (with-current-buffer b (harness-ui-chat-rebuild))
               (when w (with-selected-window w (goto-char (point-min)) (set-window-start w (point-min))))
               t)' >/dev/null
sleep 0.5
"$DEV" shot "$OUT" >/dev/null
echo "$OUT"
