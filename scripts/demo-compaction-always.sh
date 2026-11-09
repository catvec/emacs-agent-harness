#!/usr/bin/env bash
# Show "always" on the compaction question, and turning it off again.
#
#   scripts/demo-compaction-always.sh
#
# Starts the dev harness (`scripts/dev.sh', or reuses the one that runs),
# makes a session near its window with a warm prompt cache, sends a
# message so the question waits before the turn, and leaves point on the
# panel.  The frame stays lowered: look at it from the window manager, or
# take a picture with `scripts/dev.sh shot PATH'.
#
#   T  Transcript file, always   -> the compaction, and the hint
#                                   "... as you chose, from now on without
#                                   asking" with [Turn off]
#   S  Summary, always           -> the same, drawing a summary
#   F  Start afresh, always      -> the same, starting over
#   s  Summary                   -> this compaction only
#   q  Not now                   -> the message waits
#
# [Turn off] on the hint asks what goes first again.  The Session
# settings menu (C-c h o) names the state: "a Auto-compact: always" for
# this session, and "A Auto-compact for all sessions" for every one; a
# click there turns either back to asking.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
scripts/dev.sh start
# In the checkout, where the dev Emacs reads it whatever the sandbox's /tmp is.
mkdir -p "$ROOT/scripts/.dev"
tmp="$ROOT/scripts/.dev/compaction-always-demo.$$.el"
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<'EL'
;;; Make a session near its window and wait on the compaction question.

(defvar harness-demo-always-buffer nil)

(defun harness-demo-always--show (buffer)
  "Put BUFFER in the dev frame with point on its compaction panel; non-nil when it is there."
  (with-current-buffer buffer
    (let ((at (text-property-not-all (point-min) (point-max)
                                     'harness-ui-compaction-ask-panel nil)))
      (when at
        (goto-char at)
        (with-selected-frame (harness-dev-frame)
          (set-window-buffer (frame-selected-window (harness-dev-frame)) buffer))
        t))))

(defun harness-demo-always--watch (buffer)
  "Show BUFFER as soon as its panel is drawn."
  (when (and (buffer-live-p buffer)
             (not (harness-demo-always--show buffer)))
    (run-at-time 0.2 nil #'harness-demo-always--watch buffer)))

(defun harness-demo-always--append (sid kind text)
  "Append a node of KIND and TEXT to session SID."
  (harness-ui-call "_harness/session/append"
                   (list :id sid :node (list :kind kind :content text))
                   (lambda (_r) nil) (lambda (e) (message "demo append: %s" e))))

(defun harness-demo-always--ready (session)
  "Fill SESSION in, add a warm cache near its window, and ask to compact."
  (let ((sid (plist-get session :id)))
    (harness-demo-always--append
     sid "user" "GET /orders sends every order in one response, and the mobile app times out on big accounts. How should we paginate it?")
    (harness-demo-always--append
     sid "assistant"
     (concat "Two ways fit `list_orders` in `acme/orders.py`:\n\n"
             "- **Page numbers** (`?page=2&per_page=50`): simple, and a client can jump to a page, but an order created while someone reads shifts every page after it.\n"
             "- **A cursor** (`?after=<id>&limit=50`): stable while orders arrive, since ids only grow, but no jumping.\n\n"
             "`ORDERS` only ever grows, with increasing ids, so a cursor costs one comparison. I would take the cursor."))
    (harness-demo-always--append
     sid "user" "Let's sleep on it and pick it up tomorrow.")
    (harness-demo-always--append
     sid "assistant" "Sure. Nothing is changed yet: say which when you're back, and I'll implement it with tests.")
    ;; Warm, and near the 8.0k window the session is made with: the
    ;; panel says ~7.5k of 8.0k, and offers the summary read cached.
    (harness-ui-call "_harness/session/usage-add"
                     (list :id sid
                           :record (list :input 200 :output 900 :cache-read 7500 :cache-write 200
                                         :context 7500 :cache-at (float-time) :cache-ttl 3600))
                     (lambda (_r) nil) (lambda (e) (message "demo usage: %s" e)))
    (setq harness-demo-always-buffer (harness-chat-buffer sid))
    (harness-demo-always--watch harness-demo-always-buffer)
    (harness-ui-call-turn
     sid "_harness/agent/prompt"
     (list :session-id sid :blocks "Go with the cursor: implement ?after=<id> in the orders endpoint and its test.")
     (lambda (_r) nil) (lambda (e) (message "demo turn: %s" (harness-error-short-message e))))))

(harness-ui-call "_harness/session/create"
                 (list :cwd (make-temp-file "harness-demo-always-" t)
                       :model "demo:scripted" :context-window 8000)
                 #'harness-demo-always--ready
                 (lambda (e) (message "demo session: %s" (harness-error-short-message e))))
EL
scripts/dev.sh eval "(load-file \"$tmp\")" >/dev/null
sleep 3
cat <<'TXT'
The compaction question waits in the dev frame.

  T  Transcript file, always   -> the compaction, and the hint "... as you
                                  chose, from now on without asking" with
                                  [Turn off]
  S  Summary, always           -> the same, drawing a summary
  F  Start afresh, always      -> the same, starting over
  s  Summary                   -> this compaction only
  q  Not now                   -> the message waits

[Turn off] on the hint asks what goes first again.
C-c h o names the state: "a Auto-compact: always" for this session,
"A Auto-compact for all sessions" for every one.
TXT
exit 0
