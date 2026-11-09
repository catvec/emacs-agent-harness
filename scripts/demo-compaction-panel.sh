#!/usr/bin/env bash
# Show the compaction question in this checkout's dev harness.
#
#   scripts/demo-compaction-panel.sh [full|cold|cache]
#
# Starts the dev harness (`scripts/dev.sh', or reuses the one that runs),
# makes a session that shows its panel, and leaves point on it.
#
# `full' (the default) makes a session near its window with a warm
# prompt cache and sends a message, so the question is the one before an
# automatic compaction.  `cold' makes a session whose prompt cache
# lapsed and sends a message, so the question is the one before a
# message to a cold cache.  `cache' makes a session whose prompt cache
# expired and sends nothing, so the cache panel above its compose box
# shows.  The two questions are the same list of five ways, for a
# different reason:
#
#   s  Summary          (no cache when the prompt cache is cold)
#   t  Transcript
#   f  Fresh start
#   c  Continuation     (the default)
#   q  Pause
#
# With point on the panel a key answers; in the compose box press
# C-c . and the key, as the panel's last line says.  The frame stays
# lowered: look at it from the window manager, or take a picture with
# `scripts/dev.sh shot PATH'.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
MODE=${1:-full}
case "$MODE" in
  full|cold|cache) ;;
  *) echo "usage: $0 [full|cold|cache]" >&2; exit 2 ;;
esac
scripts/dev.sh start
# In the checkout, where the dev Emacs reads it whatever the sandbox's /tmp is.
mkdir -p "$ROOT/scripts/.dev"
tmp="$ROOT/scripts/.dev/compaction-demo.$$.el"
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<EL
;;; Make a session whose message meets the compaction question, and show it.

(defvar harness-demo-compaction-panel-buffer nil)

(defun harness-demo-compaction-panel--show (buffer)
  "Put BUFFER in the dev frame with point on its question; non-nil when it is there."
  (with-current-buffer buffer
    (let ((at (or (text-property-not-all (point-min) (point-max)
                                         'harness-ui-compaction-ask-panel nil)
                  (text-property-not-all (point-min) (point-max)
                                         'harness-ui-cowboy-panel nil)
                  (text-property-not-all (point-min) (point-max)
                                         'harness-ui-cache-panel nil))))
      (when at
        (goto-char at)
        (with-selected-frame (harness-dev-frame)
          (set-window-buffer (selected-window) buffer))
        t))))

(defun harness-demo-compaction-panel--watch (buffer)
  "Show BUFFER as soon as its question is drawn."
  (when (and (buffer-live-p buffer)
             (not (harness-demo-compaction-panel--show buffer)))
    (run-at-time 0.2 nil #'harness-demo-compaction-panel--watch buffer)))

(defun harness-demo-compaction-panel--append (sid kind text)
  "Append a node of KIND and TEXT to session SID."
  (harness-ui-call "_harness/session/append"
                   (list :id sid :node (list :kind kind :content text))
                   (lambda (_r) nil) (lambda (e) (message "demo append: %s" e))))

(defun harness-demo-compaction-panel--fill (sid)
  "Give session SID a conversation worth compacting."
  (harness-demo-compaction-panel--append
   sid "user" "GET /orders sends every order in one response, and the mobile app times out on big accounts. How should we paginate it?")
  (harness-demo-compaction-panel--append
   sid "assistant"
   (concat "Two ways fit \`list_orders\` in \`acme/orders.py\`:\n\n"
           "- **Page numbers** (\`?page=2&per_page=50\`): simple, and a client can jump to a page, but an order created while someone reads shifts every page after it.\n"
           "- **A cursor** (\`?after=<id>&limit=50\`): stable while orders arrive, since ids only grow, but no jumping.\n\n"
           "\`ORDERS\` only ever grows, with increasing ids, so a cursor costs one comparison. I would take the cursor."))
  (harness-demo-compaction-panel--append
   sid "user" "Let's sleep on it and pick it up tomorrow.")
  (harness-demo-compaction-panel--append
   sid "assistant" "Sure. Nothing is changed yet: say which when you're back, and I'll implement it with tests."))

(defun harness-demo-compaction-panel--ready (session)
  "Fill SESSION in, give it a cache, and send the message that asks."
  (let ((sid (plist-get session :id)))
    (harness-demo-compaction-panel--fill sid)
    ;; A warm cache near the 8.0k window a full question is made with:
    ;; ~7.5k of 8.0k, the summary read from the prompt cache.  A cold one
    ;; is a cache that lapsed an hour ago: the same question, and the
    ;; summary shown, not offered.  The cache panel is the same lapsed
    ;; cache with no message waiting.
    (harness-ui-call "_harness/session/usage-add"
                     (list :id sid
                           :record (list :input 200 :output 900 :cache-read 7500 :cache-write 200
                                         :context 7500
                                         :cache-at (if (member "$MODE" '("cold" "cache"))
                                                       (- (float-time) 7200)
                                                     (float-time))
                                         :cache-ttl 3600))
                     (lambda (_r) nil) (lambda (e) (message "demo usage: %s" e)))
    (setq harness-demo-compaction-panel-buffer (harness-chat-buffer sid))
    (harness-demo-compaction-panel--watch harness-demo-compaction-panel-buffer)
    (unless (equal "$MODE" "cache")
      (harness-ui-call-turn
       sid "_harness/agent/prompt"
       (list :session-id sid :blocks "Go with the cursor: implement ?after=<id> in the orders endpoint and its test.")
       (lambda (_r) nil) (lambda (e) (message "demo turn: %s" (harness-error-short-message e)))))))

(harness-ui-call "_harness/session/create"
                 (list :cwd (make-temp-file "harness-demo-compaction-" t)
                       :model "demo:scripted" :context-window 8000)
                 #'harness-demo-compaction-panel--ready
                 (lambda (e) (message "demo session: %s" (harness-error-short-message e))))
EL
scripts/dev.sh eval "(load-file \"$tmp\")" >/dev/null
sleep 3
cat <<'TXT'
The panel waits in the dev frame; point is on it.

  s  Summary          (no cache when the prompt cache is cold)
  t  Transcript
  f  Fresh start
  c  Continuation     (the default)
  q  Pause

With point in the compose box, press C-c . KEY instead, as the panel says.
TXT
