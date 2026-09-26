#!/usr/bin/env bash
# Regenerate the README media in docs/media/.
#
#   scripts/media.sh              screenshots and the demo video
#   scripts/media.sh shots        screenshots only
#   scripts/media.sh video        demo video (MP4 + GIF) only
#
# Drives the live dev daemon (scripts/dev.sh) and exports frames from Emacs
# itself with `x-export-frames', so no desktop screenshot portal is
# involved.  ffmpeg assembles the video and derives the GIF; it must be on
# PATH.  The daemon's session storage is redirected to a temporary
# directory for the run, so the media never contains real sessions; the
# daemon is restarted afterwards.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="$REPO/scripts/dev.sh"
DEMO="$REPO/scripts/harness-gui-demo.el"
OUT="$REPO/docs/media"
WORK="${TMPDIR:-/tmp}/harness-media"
FRAMES="$WORK/frames"
SESSIONS="$WORK/sessions"
DEMO_PROJECT="${TMPDIR:-/tmp}/acme-api"
PROMPT="What is this project?"

mkdir -p "$OUT" "$WORK"
command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }
"$DEV" status >/dev/null 2>&1 || "$DEV" start >/dev/null

# Session storage is process-global, so the daemon is restarted when the
# run ends and the user's sessions are untouched.
cleanup() {
  "$DEV" restart >/dev/null 2>&1 || true
  rm -rf "$DEMO_PROJECT"
}
trap cleanup EXIT

# A neutral project for the demos: nothing in the media should point at a
# real home directory.
prepare_project() {
  rm -rf "$DEMO_PROJECT"
  mkdir -p "$DEMO_PROJECT/src"
  cp "$REPO/README.md" "$DEMO_PROJECT/README.md"
  printf 'def main():\n    print("hello")\n' > "$DEMO_PROJECT/src/main.py"
  git -C "$DEMO_PROJECT" init -q
  git -C "$DEMO_PROJECT" add -A
  git -C "$DEMO_PROJECT" -c commit.gpgsign=false -c user.name=Acme \
      -c user.email=dev@example.com commit -qm init
}

ev() { "$DEV" eval "$1" | tail -1; }

quiet() { "$DEV" eval "$1" >/dev/null; }

# Redirect session storage and set up the frame for publication.
setup() {
  rm -rf "$SESSIONS"
  mkdir -p "$SESSIONS"
  quiet "(progn
    (setq harness-session-storage-directory \"$SESSIONS\")
    (clrhash harness-session--active)
    (clrhash harness-session--project-ids)
    (menu-bar-mode -1)
    (load-theme (quote modus-vivendi) t)
    t)"
}

reset_ui() {
  quiet '(progn
    (dolist (buffer (buffer-list))
      (when (string-prefix-p "*harness" (buffer-name buffer))
        (ignore-errors (kill-buffer buffer))))
    (clrhash harness-ui-chat--buffers)
    (setq harness-ui-ask--queue nil
          harness-ui-ask--current nil)
    t)'
}

frame_size() { quiet "(progn (set-frame-size (harness-dev-frame) 170 $1) t)"; }

# Show BUFFER alone in the frame, so tables have the whole width.
full_frame() {
  quiet "(progn
    (let ((window (get-buffer-window \"$1\" t)))
      (when window
        (delete-other-windows window)
        (select-window window)))
    t)"
}

demo() {
  quiet "(progn
    (load \"$DEMO\" nil t)
    (let ((default-directory \"$DEMO_PROJECT/\")) ($1))
    t)"
}

session_id() { ev '(symbol-value (quote harness-ui-current-session))' | tr -d '"'; }

rename_session() {
  quiet "(harness-service-call \"session\" (quote rename) :session-id \"$1\" :title \"$2\")"
}

# Mark SESSION's title as settled, so auto-naming will not replace it.
hold_title() {
  quiet "(let ((state (harness-agent--state \"$1\")))
           (when state (setf (harness-agent-state-named state) t)))
         t"
}

# Wait until EXPRESSION evaluates to t in the daemon.
wait_until() {
  local expression="$1" tries="${2:-100}"
  for _ in $(seq 1 "$tries"); do
    [[ "$(ev "$expression")" == "t" ]] && return 0
    sleep 0.2
  done
}

# Return t while any chat shows the auto-naming hint.
hint_busy() {
  ev '(seq-some (lambda (b)
                  (with-current-buffer b
                    (and (string-prefix-p "*harness:" (buffer-name))
                         (save-excursion
                           (goto-char (point-min))
                           (search-forward "Naming this conversation" nil t)))))
                (buffer-list))'
}

# Naming starts after the last turn and retires its hint when it finishes;
# wait for the hint to come and go before capturing.
wait_naming() {
  local busy
  for _ in $(seq 1 25); do
    [[ "$(hint_busy)" != "nil" ]] && break
    sleep 0.2
  done
  for _ in $(seq 1 100); do
    [[ "$(hint_busy)" == "nil" ]] && return 0
    sleep 0.2
  done
}

scroll_chat_top() {
  quiet '(let* ((id (symbol-value (quote harness-ui-current-session)))
                (buffer (gethash id harness-ui-chat--buffers))
                (window (get-buffer-window buffer t)))
           (with-current-buffer buffer (harness-ui-chat-rebuild))
           (when window
             (with-selected-window window
               (goto-char (point-min))
               (set-window-start window (point-min))))
           t)'
}

shot() { ev "(harness-dev-export-frame \"$OUT/$1.png\")"; }

# A handful of named sessions with usage, so the list and report pages
# show real values.
seed_sessions() {
  quiet "(progn
    (dolist (entry (quote ((\"Add rate limiting\" 48210 8120 0.0192 \"code\")
                           (\"Fix login redirect\" 12940 2310 0.0054 \"code\")
                           (\"Write the API guide\" 76400 15800 0.0331 \"code\")
                           (\"Refactor permissions\" 32100 6400 nil \"plan\"))))
      (let* ((title (nth 0 entry))
             (info (harness-service-call \"session\" (quote create)
                                         :cwd \"$DEMO_PROJECT/\"
                                         :title title
                                         :model \"mock/smart\"
                                         :mode (nth 4 entry)))
             (id (plist-get info :sessionId)))
        (when (nth 3 entry)
          (harness-service-call \"session\" (quote add-usage)
                                :session-id id
                                :input (nth 1 entry)
                                :output (nth 2 entry)
                                :context-used (+ (nth 1 entry) (nth 2 entry))
                                :context-size 200000)
          (harness-service-call \"session\" (quote add-cost)
                                :session-id id :amount (nth 3 entry) :currency \"USD\")
          (harness-service-call \"session\" (quote append)
                                :session-id id
                                :entry (list :sessionUpdate \"usage_update\"
                                             :model \"mock/smart\"
                                             :usage (list :input (nth 1 entry)
                                                          :output (nth 2 entry)
                                                          :cache-read 0 :cache-write 0)
                                             :cost (list :amount (nth 3 entry)
                                                         :currency \"USD\"))))))
    t)"
}

shots() {
  setup
  prepare_project

  # Hero: the scripted conversation, finished and scrolled to the top.
  reset_ui
  demo harness-gui-demo-install
  local hero
  hero=$(session_id)
  sleep 3.5
  quiet '(harness-ui-ask-answer "allow-once")'
  sleep 3
  wait_naming
  hold_title "$hero"
  rename_session "$hero" "README walkthrough"
  frame_size 30
  scroll_chat_top
  shot chat

  # Permission panel, while the read of /etc/passwd waits for an answer.
  reset_ui
  demo harness-gui-demo-install
  local blocked
  blocked=$(session_id)
  wait_until '(and harness-ui-ask--current t)'
  hold_title "$blocked"
  rename_session "$blocked" "Read outside the jail"
  frame_size 36
  scroll_chat_top
  shot permissions
  quiet '(harness-ui-ask-answer "allow-once")'
  sleep 2

  # Plan mode: the plan tool renders a styled plan block.
  reset_ui
  demo harness-gui-demo-plan
  sleep 4
  wait_naming
  frame_size 38
  shot plan

  # Session list over the seeded sessions, full frame for the columns.
  seed_sessions
  quiet "(progn
    (let ((default-directory \"$DEMO_PROJECT/\")) (harness-ui-sessions))
    (with-current-buffer \"*harness-sessions*\"
      (setq default-directory \"$DEMO_PROJECT/\")
      (harness-ui-sessions-refresh))
    t)"
  sleep 1
  frame_size 28
  full_frame "*harness-sessions*"
  shot sessions

  # Usage report, full frame.
  quiet '(harness-ui-usage)'
  sleep 1
  frame_size 40
  full_frame "*harness-usage*"
  shot usage

  # Worktree manager, full frame.
  quiet "(harness-ui-worktrees \"$DEMO_PROJECT/\")"
  sleep 1
  frame_size 24
  full_frame "*harness-worktrees*"
  shot worktrees
}

video() {
  setup
  prepare_project
  reset_ui
  demo harness-gui-demo-prepare
  sleep 0.8

  rm -rf "$FRAMES"
  mkdir -p "$FRAMES"
  local started finished frames fps composer i char
  started=$(date +%s.%N)
  ev '(harness-dev-record-start "'"$FRAMES"'" 0.02)' >/dev/null

  # Type the prompt with real keystrokes, verifying the composer took it.
  # A slow first frame can swallow the first keys, so retry rather than
  # record an empty conversation.
  for _ in 1 2 3; do
    composer=$(ev '(let ((b (car (seq-filter (lambda (buf) (string-prefix-p "*harness:" (buffer-name buf))) (buffer-list))))) (and b (with-current-buffer b (harness-ui-chat--compose-text))))')
    [[ "$composer" == "\"$PROMPT\"" ]] && break
    quiet '(let ((b (car (seq-filter (lambda (buf) (string-prefix-p "*harness:" (buffer-name buf))) (buffer-list))))) (when b (with-current-buffer b (harness-ui-chat--replace-compose ""))))'
    for ((i = 0; i < ${#PROMPT}; i++)); do
      char="${PROMPT:i:1}"
      "$DEV" keys "$char" >/dev/null
      sleep 0.05
    done
  done
  if [[ "$composer" != "\"$PROMPT\"" ]]; then
    echo "media: the composer never got the prompt" >&2
    exit 1
  fi
  "$DEV" keys "RET" >/dev/null

  # Wait for the approval panel, let it sit, then answer it in the panel.
  for _ in $(seq 1 80); do
    [[ "$(ev '(and harness-ui-ask--current t)')" == "t" ]] && break
    sleep 0.1
  done
  sleep 1.2
  quiet '(let ((window (get-buffer-window "*harness-approval*" t)))
           (when window (select-window window))
           t)'
  "$DEV" keys "y" >/dev/null

  # Let the final answer stream, then stop.
  sleep 4.5
  frames=$(ev '(harness-dev-record-stop)')
  finished=$(date +%s.%N)
  fps=$(awk -v n="$frames" -v a="$started" -v b="$finished" \
        'BEGIN { if (n > 1) fps = (n - 1) / (b - a); else fps = 1; printf "%.3f", fps }')

  ffmpeg -y -loglevel error -framerate "$fps" -i "$FRAMES/frame-%05d.png" \
         -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart \
         "$OUT/demo.mp4"
  ffmpeg -y -loglevel error -i "$OUT/demo.mp4" \
         -vf "fps=10,scale=960:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer" \
         "$OUT/demo.gif"

  printf '%s frames at %s fps -> %s/demo.{mp4,gif}\n' "$frames" "$fps" "$OUT"
}

case "${1:-all}" in
  shots) shots ;;
  video) video ;;
  all)   shots; video ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
