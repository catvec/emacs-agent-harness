;;; harness-ui-children-test.el --- Tests for the running-sub-agents panel  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session's chat pins its running sub-agents above the compose box,
;; beside the todo list and the merge queue: one line per running child
;; with its name (a session link), its progress and how long it has run.
;; Nothing here asks a child anything: the panel reads the session cache
;; and the activity the harness broadcasts for every session.  A chat
;; draws the panel at most once a second, and only when its text changed:
;; the updates of the children share one timer per chat, which no test
;; waits for -- the tests call the flush themselves.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-ui--sessions)
(defvar harness-ui-session-id)
(defvar harness-ui-children--activity)
(defvar harness-ui-children--turn-start)
(defvar harness-ui-children--parent)
(defvar harness-ui-children--timer)
(defvar harness-ui-children--drawn)
(defvar harness-ui-children--redraw-delay)
(defvar harness-compose-redraw-function)

(defmacro harness-ui-children-test-with (&rest body)
  "Load the UI and its children module with a fresh session cache.
Binds `parent' (the id of the session whose panel is drawn)."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(ui ui-compose ui-markdown ui-popout ui-chat ui-children))
         (harness-test-load-module m)))
     (clrhash harness-ui--sessions)
     (clrhash harness-ui-children--activity)
     (clrhash harness-ui-children--turn-start)
     (clrhash harness-ui-children--parent)
     (let ((parent "p"))
       (harness-ui-cache-session (list :id "p" :name "main" :kind "main" :status "running"))
       (progn ,@body))))

(defun harness-ui-children-test--cache (id kind status name &optional parent-id todos)
  "Cache session ID in the UI, a sub-agent by default.
KIND and STATUS are strings as they come over ACP; PARENT-ID is the
`:parent-id'; TODOS is a wire list of (:text :status)."
  (harness-ui-cache-session
   (append (list :id id :kind kind :status status :name name :parent-id parent-id)
           (and todos (list :todos todos)))))

(defun harness-ui-children-test--text (text)
  "Return TEXT, a string, without properties."
  (and (stringp text) (substring-no-properties text)))

(defun harness-ui-children-test--at (text needle)
  "Return the position of NEEDLE in TEXT, or nil."
  (string-match-p (regexp-quote needle) text))

(defun harness-ui-children-test--mouse1 (text pos)
  "Return the mouse-1 command on TEXT at POS, or nil."
  (when-let* ((map (get-text-property pos 'keymap text)))
    (lookup-key map [mouse-1])))

(defun harness-ui-children-test--undefined-faces (text)
  "Return the face names in TEXT's properties that name no face."
  (let ((pos 0) (bad nil))
    (while (< pos (length text))
      (let ((face (get-text-property pos 'face text)))
        (dolist (f (ensure-list face))
          (unless (or (null f) (keywordp f) (consp f) (facep f))
            (cl-pushnew f bad))))
      (setq pos (or (next-single-property-change pos 'face text) (length text))))
    bad))

(defun harness-ui-children-test--pending (buffer)
  "Return the pending timers that will flush the panel of chat BUFFER."
  (cl-remove-if-not (lambda (timer)
                      (and (eq #'harness-ui-children--flush (timer--function timer))
                           (equal (list buffer) (timer--args timer))))
                    timer-list))

(defmacro harness-ui-children-test-with-chat (spec &rest body)
  "Run BODY with a temp buffer that plays the chat of session `parent'.
SPEC is (CHAT REDRAWS): CHAT is bound to the buffer, REDRAWS to how
many times its tail was drawn, 0 at first.  Drawing the tail draws the
panel as the real chat does (`harness-ui-children--panel'), which
records what it drew.  No timer or buffer outlives BODY."
  (declare (indent 1))
  (let ((chat (car spec)) (redraws (cadr spec)))
    `(let ((,chat (generate-new-buffer " *children chat*"))
           (,redraws 0))
       (unwind-protect
           (progn
             (with-current-buffer ,chat
               (setq-local harness-ui-session-id parent)
               (setq-local harness-compose-redraw-function
                           (lambda () (cl-incf ,redraws) (harness-ui-children--panel))))
             ,@body)
         (mapc #'cancel-timer (harness-ui-children-test--pending ,chat))
         (when (buffer-live-p ,chat) (kill-buffer ,chat))))))

(ert-deftest harness-ui-children-panel-lists-only-running-subagents ()
  "The panel lists this session's running sub-agents, and only those.
An idle child, another session's child and a seed conversation stay out;
each child's name is a clickable session link and its current todo shows
until its first activity arrives."
  (harness-ui-children-test-with
    (harness-ui-children-test--cache "r1" "subagent" "running" "worker-one" parent
                                     (list (list :text "do the first thing" :status "in-progress")
                                           (list :text "done thing" :status "done")))
    (harness-ui-children-test--cache "r2" "subagent" "running" "worker-two" parent)
    (harness-ui-children-test--cache "r3" "subagent" "running" "elsewhere-worker" "q")
    (harness-ui-children-test--cache "i1" "subagent" "idle" "worker-idle" parent)
    ;; A seed is a sub-agent the harness marks as one in its `:ext'; its
    ;; name is beside the point (`harness-ui-seed-session-p').
    (harness-ui-cache-session
     (list :id "seed1" :kind "subagent" :status "running" :parent-id parent
           :name "Shared context for main (demo:scripted)" :ext (list :seed t)))
    (let* ((harness-ui-session-id parent)
           (panel (harness-ui-children--panel))
           (text (harness-ui-children-test--text panel)))
      (should panel)
      (should (string-match-p "Sub-agents  2 running" text))
      (should (string-match-p "worker-one" text))
      (should (string-match-p "worker-two" text))
      ;; The current todo stands in for the child whose activity is unknown.
      (should (string-match-p "do the first thing" text))
      ;; The seed is a seed because its record says so, not its name.
      (should (harness-ui-seed-session-p (harness-ui-session "seed1")))
      ;; Not this session's, not running, and not a seed: they stay out.
      (should-not (string-match-p "elsewhere-worker" text))
      (should-not (string-match-p "worker-idle" text))
      (should-not (string-match-p "Shared context" text))
      ;; The names are the shared session link: keys, hover and pointer.
      (dolist (needle '("worker-one" "worker-two"))
        (let* ((pos (harness-ui-children-test--at panel needle))
               (command (and pos (harness-ui-children-test--mouse1 panel pos))))
          (should pos)
          (should (eq 'highlight (get-text-property pos 'mouse-face panel)))
          (should (eq 'hand (get-text-property pos 'pointer panel)))
          (should (commandp command))))
      ;; Every face the panel wears names a real face.
      (should-not (harness-ui-children-test--undefined-faces panel)))))

(ert-deftest harness-ui-children-panel-shows-activity-progress ()
  "A child's progress is its activity, the activity line's own text."
  (harness-ui-children-test-with
    (harness-ui-children-test--cache "r1" "subagent" "running" "worker-one" parent)
    (puthash "r1" (list :phase "tool" :tool "bash" :title "bash" :detail "still running")
             harness-ui-children--activity)
    (let* ((child (harness-ui-session "r1"))
           (progress (harness-ui-children--progress child)))
      (should (string-match-p "Running bash" progress))
      (should (string-match-p "still running" progress)))
    ;; Without activity, the todo stands in; with neither, nothing.
    (should (equal "" (harness-ui-children--progress (harness-ui-session "r2"))))))

(defun harness-ui-children-test--lines (chat)
  "Return the lines of the panel CHAT draws now, without properties."
  (with-current-buffer chat
    (split-string (harness-ui-children-test--text (harness-ui-children--panel)) "\n" t)))

(ert-deftest harness-ui-children-line-fits-the-window ()
  "A child's line is one screen line, whatever its progress says.
Two chats side by side are not wide, and a line that reaches the edge of
its window wraps its end to the next one, back at the margin, and moves
the compose box below each time it comes or goes: the progress is cut to
the room the name and the time leave, in the narrowest window showing the
chat, and left out where there is none."
  (harness-ui-children-test-with
    (harness-ui-children-test--cache "r1" "subagent" "running" "check suite" parent)
    (puthash "r1" (list :phase "tool" :tool "bash" :title "bash"
                        :detail (concat "run 4 of 40: for i in $(seq 1 40); do printf"
                                        " 'run %s of 40: ' \"$i\"; python3 -m unittest"))
             harness-ui-children--activity)
    (harness-ui-children--on-event "agent/turn-started" '("r1"))
    (harness-ui-children-test-with-chat (chat _redraws)
      ;; In no window, the chat is taken to be 80 columns wide.
      (let ((lines (harness-ui-children-test--lines chat)))
        (should (string-match-p "Sub-agents  1 running" (car lines)))
        (should (string-match-p "check suite  [0-9]+s  Running bash… · run 4 of 40" (cadr lines)))
        (should (< (string-width (cadr lines)) 80)))
      (save-window-excursion
        (delete-other-windows)
        (let* ((wide (selected-window))
               ;; Fifty columns, a divider among them; the other window has
               ;; what the frame has left of its 80.
               (narrow (split-window wide 50 t)))
          (set-window-buffer wide chat)
          (let ((width (window-body-width wide)))
            (should (< width 80))
            (let ((lines (harness-ui-children-test--lines chat)))
              (should (= 2 (length lines)))
              (dolist (line lines)
                (should (< (string-width line) width)))
              ;; Cut at the end, with the mark of it, not left out.
              (should (string-match-p "check suite  [0-9]+s  Running bash.*…\\'" (cadr lines)))))
          ;; Shown in both windows, the narrower decides, and its width
          ;; leaves the progress no room: the name and the time alone.
          (set-window-buffer narrow chat)
          (should (< (window-body-width narrow) (window-body-width wide)))
          (let ((line (cadr (harness-ui-children-test--lines chat))))
            (should (< (string-width line) (window-body-width narrow)))
            (should (string-match-p "check suite  [0-9]+s\\'" line))
            (should-not (string-match-p "Running\\|…" line))))))))

(ert-deftest harness-ui-children-panel-disappears-when-nothing-runs ()
  "A session with no running sub-agent shows no panel."
  (harness-ui-children-test-with
    (harness-ui-children-test--cache "i1" "subagent" "idle" "worker-idle" parent)
    (let ((harness-ui-session-id parent))
      (should-not (harness-ui-children--panel)))))

(ert-deftest harness-ui-children-elapsed-follows-the-turn ()
  "`agent/turn-started' and `agent/turn-ended' bound a child's elapsed time."
  (harness-ui-children-test-with
    (harness-ui-children-test--cache "r1" "subagent" "running" "worker-one" parent)
    (should-not (gethash "r1" harness-ui-children--turn-start))
    (harness-ui-children--on-event "agent/turn-started" '("r1"))
    (should (numberp (gethash "r1" harness-ui-children--turn-start)))
    (should (string-match-p "\\`[0-9]+s\\'" (harness-ui-children--elapsed (harness-ui-session "r1"))))
    (harness-ui-children--on-event "agent/turn-ended" '("r1" "end-turn"))
    (should-not (gethash "r1" harness-ui-children--turn-start))))

(ert-deftest harness-ui-children-on-update-keeps-activity-while-running ()
  "Activity is cached while the child runs and dropped when it stops."
  (harness-ui-children-test-with
    (harness-ui-children-test--cache "r1" "subagent" "running" "worker-one" parent)
    (harness-ui-children--on-update "r1" (list :sessionUpdate "_harness/activity"
                                               :activity '(:phase "tool" :tool "bash")))
    (should (equal '(:phase "tool" :tool "bash")
                   (gethash "r1" harness-ui-children--activity)))
    ;; The turn ends: the activity goes, and so does a record that stops running.
    (harness-ui-children--on-update "r1" (list :sessionUpdate "_harness/activity" :activity nil))
    (should-not (gethash "r1" harness-ui-children--activity))
    (harness-ui-children-test--cache "r1" "subagent" "idle" "worker-one" parent)
    (harness-ui-children--on-update "r1" (list :sessionUpdate "_harness/session"
                                               :session (list :id "r1" :status "idle")))
    (should-not (gethash "r1" harness-ui-children--activity))))

(ert-deftest harness-ui-children-redraws-coalesce-per-chat ()
  "A chat draws its sub-agents panel once for many updates, and only if it changed.
Each update of a child asks for a redraw of its parent's chat
\(`harness-ui-children--redraw'), and drawing means rebuilding the whole
tail, the compose box too.  The requests share one timer per chat, and
when it fires the tail is drawn only if the panel's text is no longer
the one last drawn (`harness-ui-children--flush').  No timer is waited
for: the test flushes itself."
  (harness-ui-children-test-with
    (harness-ui-children-test--cache "r1" "subagent" "running" "worker-one" parent)
    (harness-ui-children-test-with-chat (chat redraws)
      (let* ((update (list :sessionUpdate "_harness/activity"
                           :activity '(:phase "tool" :tool "bash" :title "bash" :detail "compiling")))
             (before (current-time)))
        ;; (a) Five updates at once draw nothing yet, and set one timer.
        (dotimes (_ 5) (harness-ui-children--on-update "r1" update))
        (should (= 0 redraws))
        (let ((timer (buffer-local-value 'harness-ui-children--timer chat)))
          (should (timerp timer))
          (should (equal (list timer) (harness-ui-children-test--pending chat)))
          ;; It is due a second after the first update, not at once
          ;; (`timer-until' counts from the timer to the time given).
          (should (>= (- (timer-until timer before)) harness-ui-children--redraw-delay)))
        ;; Building the panel's text draws nothing: only the chat's own
        ;; tail records what it drew.
        (with-current-buffer chat
          (should (harness-ui-children--render))
          (should-not harness-ui-children--drawn))
        ;; (b) The timer fires: the tail is drawn once, the panel with it.
        (harness-ui-children--flush chat)
        (should (= 1 redraws))
        (should-not (buffer-local-value 'harness-ui-children--timer chat))
        (should-not (harness-ui-children-test--pending chat))
        (let ((drawn (buffer-local-value 'harness-ui-children--drawn chat)))
          (should (string-match-p "Sub-agents  1 running" drawn))
          (should (string-match-p "worker-one  Running bash" drawn))
          (should (string-match-p "compiling" drawn))
          ;; Plain text: properties would make the comparison depend on them.
          (should-not (text-properties-at 0 drawn))
          ;; It is the panel as it reads now.
          (should (equal drawn (with-current-buffer chat
                                 (substring-no-properties (harness-ui-children--render))))))
        ;; (c) The same update again asks again, but the panel reads as drawn.
        (harness-ui-children--on-update "r1" update)
        (should (timerp (buffer-local-value 'harness-ui-children--timer chat)))
        (should (= 1 redraws))
        (harness-ui-children--flush chat)
        (should (= 1 redraws))
        (should-not (buffer-local-value 'harness-ui-children--timer chat))
        ;; (d) The child stops running: the panel goes, and the tail is
        ;; drawn once more to take it away.
        (harness-ui-children-test--cache "r1" "subagent" "idle" "worker-one" parent)
        (harness-ui-children--on-update
         "r1" (list :sessionUpdate "_harness/session" :session (list :id "r1" :status "idle")))
        (should (= 1 redraws))
        (should (timerp (buffer-local-value 'harness-ui-children--timer chat)))
        (harness-ui-children--flush chat)
        (should (= 2 redraws))
        (should-not (buffer-local-value 'harness-ui-children--drawn chat))
        (should-not (buffer-local-value 'harness-ui-children--timer chat))
        ;; Nothing is drawn, nothing is left to take away.
        (harness-ui-children--on-update "r1" update)
        (harness-ui-children--flush chat)
        (should (= 2 redraws))
        ;; (e) A chat killed while its redraw was pending: the timer still
        ;; fires, and the flush neither draws nor signals.
        (harness-ui-children--on-update "r1" update)
        (should (harness-ui-children-test--pending chat))
        (kill-buffer chat)
        (should-not (buffer-live-p chat))
        (should-not (harness-ui-children--flush chat))
        (should (= 2 redraws))))))

(ert-deftest harness-ui-children-no-chat-open-no-timer ()
  "An update of a child whose parent has no chat open sets no timer."
  (harness-ui-children-test-with
    (harness-ui-children-test--cache "r1" "subagent" "running" "worker-one" parent)
    (let ((flushes (lambda () (cl-count #'harness-ui-children--flush timer-list
                                        :key #'timer--function))))
      (harness-ui-children--on-update
       "r1" (list :sessionUpdate "_harness/activity" :activity '(:phase "thinking")))
      (harness-ui-children--on-event "agent/turn-started" '("r1"))
      (should (= 0 (funcall flushes))))))

(ert-deftest harness-ui-children-any-tail-draw-records-the-panel ()
  "A tail drawn for another reason leaves the flush nothing to draw.
The chat rebuilds its tail when its todos change, say, and the panel is
drawn with it (`harness-ui-children--panel' records the text): the
redraw that a child's update asked for then finds the panel as it is on
screen, and a change since that draw is still drawn."
  (harness-ui-children-test-with
    (harness-ui-children-test--cache "r1" "subagent" "running" "worker-one" parent)
    (harness-ui-children-test-with-chat (chat redraws)
      (harness-ui-children--on-update
       "r1" (list :sessionUpdate "_harness/activity" :activity '(:phase "thinking")))
      (should (timerp (buffer-local-value 'harness-ui-children--timer chat)))
      ;; Something else draws the tail first.
      (with-current-buffer chat (funcall harness-compose-redraw-function))
      (should (= 1 redraws))
      (harness-ui-children--flush chat)
      (should (= 1 redraws))
      (should-not (buffer-local-value 'harness-ui-children--timer chat))
      ;; A new activity changes the text: the next flush draws it.
      (harness-ui-children--on-update
       "r1" (list :sessionUpdate "_harness/activity" :activity '(:phase "writing")))
      (harness-ui-children--flush chat)
      (should (= 2 redraws))
      (should (string-match-p "Writing"
                              (buffer-local-value 'harness-ui-children--drawn chat))))))

(provide 'harness-ui-children-test)
;;; harness-ui-children-test.el ends here
