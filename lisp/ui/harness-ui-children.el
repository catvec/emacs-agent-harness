;;; harness-ui-children.el --- Sub-agents at work or blocked, pinned above the compose box  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session that started sub-agents shows them pinned at the bottom of
;; its chat, beside the todo list and the merge queue, above the compose
;; box: one line per child that is still running, with its name, how
;; long it has been at work and what it is doing now, cut to the room
;; the chat's window leaves so the line never wraps.  It stays there
;; while the child works and goes when it stops, so the user watching the
;; parent session sees its workers without scrolling back to the
;; `spawn_agent' call that started them -- which a background sub-agent
;; outlives anyway.
;;
;; A child that waits for the user -- a permission prompt, a directory it
;; asked for, a question -- is no longer running, and the parent, which
;; waits for its report, would show nothing of it.  It stays in the
;; panel, first, in the blocked face: its name (the link that opens it),
;; "Blocked", the buttons that answer what it waits on -- the ones the
;; session list draws under its row -- and what it asks, so the user
;; sees the whole tree stand still and answers from the parent's chat.
;;
;; Nothing here polls a child.  The harness broadcasts every session's
;; activity (`agent/activity-changed' → `_harness/activity' to every
;; client) and its record (`_harness/session'), and it forwards
;; `agent/turn-started' and `agent/turn-ended' as events; the panel keeps
;; those per child and redraws the parent's chat when a child changes.
;; A child announces its activity up to twice a second, and drawing the
;; panel rebuilds the chat's whole tail, the compose box included, so the
;; requests to draw coalesce: a chat draws its panel at most once a
;; second, and only when the panel's text differs from what it shows.
;; A child's progress is the same text the activity line uses
;; (`harness-chat--activity-text'), falling back to its current todo
;; item until its first activity arrives.  A seed conversation is a
;; sub-agent too, but it is the shared prompt cache, not a worker: its
;; own `:ext' says so (`harness-ui-seed-session-p') and the panel leaves
;; it out.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-pending)

(defvar harness-chat-panel-functions)
(defvar harness-chat-mode-hook)
(defvar harness-ui-session-id)
(defvar harness-compose-redraw-function)
(defvar harness-ui-update-functions)
(defvar harness-ui-event-functions)

(declare-function harness-chat--windows "harness-ui-chat" ())
(declare-function harness-chat--activity-text "harness-ui-chat" (activity))
(declare-function harness-chat--activity-details "harness-ui-chat" (activity))
(declare-function harness-chat--format-elapsed "harness-ui-chat" (seconds))
(declare-function harness-chat--normalise-todos "harness-ui-chat" (todos))

(defgroup harness-ui-children nil
  "Sub-agents of a session at work or blocked on you, pinned above its compose box."
  :group 'harness-ui)

(harness-ui-define-icon harness-ui-children-icon "agent" "◇" "sub-agent"
  "A sub-agent of the session.")

(defvar harness-ui-children--activity (make-hash-table :test 'equal)
  "Child session id -> its last activity plist, as `_harness/activity' said.
Kept for every session the UI hears about, so a running child's progress
shows without asking it anything; forgotten when the child stops or is
deleted.")

(defvar harness-ui-children--turn-start (make-hash-table :test 'equal)
  "Child session id -> the float time its running turn started.
Filled from `agent/turn-started' and cleared on `agent/turn-ended'.")

(defvar harness-ui-children--parent (make-hash-table :test 'equal)
  "Child session id -> its parent session id, as last seen.
Kept so a child's deletion, which forgets its record first, can still
redraw the chat of the session that listed it.")

(defvar-local harness-ui-children--timer nil
  "This chat buffer's pending redraw of its sub-agents panel, a timer, or nil.
`harness-ui-children--redraw' sets it, and while it is pending the
requests that come add nothing; `harness-ui-children--flush' clears it.")

(defvar-local harness-ui-children--drawn nil
  "The text of the sub-agents panel this chat buffer drew last, or nil for none.
It has no text properties.  Whatever makes the chat draw its tail
records it (`harness-ui-children--panel'), so the redraw that a child's
update asks for (`harness-ui-children--flush') can tell whether the
panel changed since.")

(defun harness-ui-children--str (value)
  "Return VALUE as a string (a symbol or string), or nil for nil.
`_harness/session' spells `:kind' and `:status' as symbols or strings."
  (when value (if (symbolp value) (symbol-name value) (format "%s" value))))

(defun harness-ui-children--of-session ()
  "Return this session's sub-agents, as cached sessions, newest first.
A sub-agent is a cached session of kind `subagent' whose `:parent-id' is
this buffer's session; a seed conversation does not count, and says so
itself (in its `:ext', `harness-ui-seed-session-p').  This buffer's
session is always a string in a chat, so a nil id (no session) matches
nothing."
  (when (and (stringp harness-ui-session-id) (not (string-empty-p harness-ui-session-id)))
    (let ((sid harness-ui-session-id))
      (cl-remove-if-not
       (lambda (s)
         (and (equal (plist-get s :parent-id) sid)
              (equal (harness-ui-children--str (plist-get s :kind)) "subagent")
              (harness-ui-navigable-session-p s)))
       (harness-ui-sessions)))))

(defun harness-ui-children--waiting-p (child)
  "Non-nil when CHILD, a cached session, waits for the user to answer.
That is a request pending on it, or the status `blocked'
\(`harness-session-waiting-on-user-p')."
  (harness-session-waiting-on-user-p child))

(defun harness-ui-children--running ()
  "Return this session's running sub-agents, newest first, or nil.
A running child is one of this session's sub-agents
\(`harness-ui-children--of-session') whose status is `running' and that
waits for nobody."
  (cl-remove-if-not
   (lambda (s)
     (and (equal (harness-ui-children--str (plist-get s :status)) "running")
          (not (harness-ui-children--waiting-p s))))
   (harness-ui-children--of-session)))

(defun harness-ui-children--waiting ()
  "Return this session's sub-agents that wait for the user, newest first, or nil.
They wait on a permission prompt or a question of their own; each is
blocked, and answered where the user chooses
\(`harness-ui-pending-view-actions')."
  (cl-remove-if-not #'harness-ui-children--waiting-p (harness-ui-children--of-session)))

(defun harness-ui-children--todo (child)
  "Return CHILD's current todo item's text, or nil.
That is the item in progress, else the first not done: the progress a
child reports before its first activity arrives."
  (when-let* ((todos (harness-chat--normalise-todos (plist-get child :todos))))
    (plist-get (or (cl-find "in-progress" todos
                            :key (lambda (td) (plist-get td :status)) :test #'equal)
                   (cl-find-if (lambda (td) (not (equal "done" (plist-get td :status)))) todos))
               :text)))

(defun harness-ui-children--progress (child)
  "Return CHILD's progress text, as one line, or \"\".
The child's activity (`harness-chat--activity-text') is the same text
the activity line uses; before the first activity arrives, the child's
current todo item stands in."
  (let ((activity (gethash (plist-get child :id) harness-ui-children--activity)))
    (if activity
        (string-join
         (delq nil (cons (harness-chat--activity-text activity)
                         (harness-chat--activity-details activity)))
         " \N{U+00B7} ")
      (or (harness-first-line (harness-ui-children--todo child) 60) ""))))

(defun harness-ui-children--elapsed (child)
  "Return how long CHILD has been running, as text, or nil."
  (when-let* ((since (gethash (plist-get child :id) harness-ui-children--turn-start)))
    (harness-chat--format-elapsed (- (float-time) since))))

(defun harness-ui-children--room ()
  "Return how many columns one line of the panel may take in this chat.
That is the body of the narrowest window showing the buffer, 80 when no
window does, less two columns: the running icon is an image a little
wider than the character it stands for, and a line that reaches the
edge of its window wraps."
  (let ((windows (harness-chat--windows)))
    (- (if windows (apply #'min (mapcar #'window-body-width windows)) 80) 2)))

(defun harness-ui-children--line (child)
  "Return the panel's line for CHILD, a running sub-agent.
The name is the one shared session link (`harness-ui-session-link'), so
a click opens the child; the elapsed time and the progress follow, dim.
It is one screen line, so the compose box below never jumps as the line
comes and goes: the progress is cut to the room the chat's window leaves
\(`harness-ui-children--room') and left out where there is hardly any."
  (let* ((id (plist-get child :id))
         (name (or (plist-get child :name) id))
         (progress (string-trim (harness-ui-children--progress child)))
         (elapsed (harness-ui-children--elapsed child))
         (head (concat "   "
                       (propertize (harness-ui-icon 'harness-icon-running)
                                   'face 'harness-status-running-face)
                       " "
                       (harness-ui-session-link id (harness-truncate-end name 24)
                                                (format "Open the session %s" name))
                       (if elapsed
                           (concat "  " (propertize elapsed 'face 'harness-dim-face))
                         "")))
         (room (min 60 (- (harness-ui-children--room) (string-width head) 2))))
    (concat head
            (when (and (not (string-empty-p progress)) (>= room 8))
              (concat "  " (propertize (truncate-string-to-width progress room nil nil "…")
                                       'face 'harness-dim-face)))
            "\n")))

(defun harness-ui-children--waiting-line (child)
  "Return the panel's line for CHILD, a sub-agent that waits for you.
The name is the session link, as a running child's.  \"Blocked\" follows
in the blocked face, its tooltip saying what the child waits on, then
the buttons that answer it -- the ones the session list draws under the
child's row (`harness-ui-pending-view-actions') -- and what it asks, cut
to the room left (`harness-ui-pending-subject').  It is one screen line
as a running child's is, so the buttons and what is asked are left out
where the window has no room for them, the name still opening the
session, and a child whose request this Emacs has not heard of yet shows
neither."
  (let* ((id (plist-get child :id))
         (name (or (plist-get child :name) id))
         (request (harness-ui-pending-first id))
         (buttons (mapconcat (lambda (action)
                               (harness-ui-action-button (nth 0 action) (nth 1 action)
                                                         :help (nth 2 action)))
                             (harness-ui-pending-view-actions id) " "))
         (head (concat "   "
                       (propertize (harness-ui-icon 'harness-icon-blocked)
                                   'face 'harness-status-blocked-face)
                       " "
                       (harness-ui-session-link id (harness-truncate-end name 24)
                                                (format "Open the session %s" name))
                       "  "
                       (propertize "Blocked" 'face 'harness-status-blocked-face
                                   'help-echo (or (harness-ui-pending-summary child) "Request pending"))))
         (room (- (harness-ui-children--room) (string-width head) 2))
         (buttons (and (not (string-empty-p buttons)) (<= (+ 2 (string-width buttons)) room) buttons))
         (room (min 60 (if buttons (- room 2 (string-width buttons)) room))))
    (concat head
            (and buttons (concat "  " buttons))
            (when (and request (>= room 8))
              (concat "  " (harness-ui-pending-subject request room)))
            "\n")))

(defun harness-ui-children--counts (running waiting)
  "Return the panel's counts for RUNNING and WAITING children, as text.
\"2 running\", \"1 blocked\" or both, joined by a dot; the blocked count
wears the blocked face."
  (string-join
   (delq nil (list (and running (format "%d running" (length running)))
                   (and waiting (propertize (format "%d blocked" (length waiting))
                                            'face 'harness-status-blocked-face))))
   " \N{U+00B7} "))

(defun harness-ui-children--render ()
  "Return the panel of this session's sub-agents at work, or nil.
The children that wait for you come first (`harness-ui-children--waiting-line'),
then the running ones (`harness-ui-children--line').  A session with no
running and no waiting sub-agent shows nothing.  This only builds the
text; `harness-ui-children--panel' is what the chat draws."
  (let ((waiting (harness-ui-children--waiting))
        (running (harness-ui-children--running)))
    (when (or waiting running)
      (concat
       (propertize (concat (harness-ui-icon 'harness-ui-children-icon) " Sub-agents  ")
                   'face 'harness-label-face)
       (let ((counts (harness-ui-children--counts running waiting)))
         ;; The label's face under the counts, the blocked one over its own.
         (add-face-text-property 0 (length counts) 'harness-label-face t counts)
         counts)
       "\n"
       (string-join (append (mapcar #'harness-ui-children--waiting-line waiting)
                            (mapcar #'harness-ui-children--line running))
                    "")
       "\n"))))

(defun harness-ui-children--plain (text)
  "Return TEXT, a panel from `harness-ui-children--render', without properties.
nil, no panel, stays nil."
  (and text (substring-no-properties text)))

(defun harness-ui-children--panel ()
  "Return the panel of this session's running sub-agents, or nil.
On `harness-chat-panel-functions'.  A session with no running
sub-agent shows nothing.  The text drawn is recorded in
`harness-ui-children--drawn', for the redraws that a child's update asks
for (`harness-ui-children--flush') to compare with."
  (let ((text (harness-ui-children--render)))
    (setq harness-ui-children--drawn (harness-ui-children--plain text))
    text))

;;;; Redraw and events

(defun harness-ui-children--chat-buffer (sid)
  "Return the live chat buffer showing session SID, or nil.
Another view of the session, such as its access view, is no chat
\(`harness-ui-chat-of-p')."
  (cl-find-if (lambda (buffer) (harness-ui-chat-of-p buffer sid)) (buffer-list)))

(defconst harness-ui-children--redraw-delay 1.0
  "Seconds a chat waits to draw its sub-agents panel after a child changed.
Children report up to twice a second each, and drawing the panel
rebuilds the chat's whole tail, the compose box included, so a chat
draws its panel at most once a second: the requests that come in the
meantime share the one drawing (`harness-ui-children--redraw').")

(defun harness-ui-children--flush (buffer)
  "Draw the tail of chat BUFFER again if its sub-agents panel changed.
The timer `harness-ui-children--redraw' set calls it.  A dead BUFFER
gets nothing.  Otherwise the buffer's timer is spent, and its
`harness-compose-redraw-function' runs only when the panel's text now
differs from the text drawn there last (`harness-ui-children--drawn'):
a child reports far more often than its line changes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp harness-ui-children--timer)
        (cancel-timer harness-ui-children--timer))
      (setq harness-ui-children--timer nil)
      (unless (equal (harness-ui-children--plain (harness-ui-children--render))
                     harness-ui-children--drawn)
        (when (functionp harness-compose-redraw-function)
          (funcall harness-compose-redraw-function))))))

(defun harness-ui-children--redraw (child-id)
  "Ask for a redraw of the chat that lists CHILD-ID as a sub-agent.
That is the chat of the child's parent: its record's `:parent-id', or
the one remembered in `harness-ui-children--parent' once the child's
record is gone.  It draws `harness-ui-children--redraw-delay' later
\(`harness-ui-children--flush'), once for all the requests until then."
  (when-let* ((parent (or (plist-get (and (stringp child-id) (harness-ui-session child-id)) :parent-id)
                          (gethash child-id harness-ui-children--parent)))
              (buffer (and (stringp parent) (not (string-empty-p parent))
                           (harness-ui-children--chat-buffer parent))))
    (with-current-buffer buffer
      (unless (and (timerp harness-ui-children--timer)
                   (memq harness-ui-children--timer timer-list))
        (setq harness-ui-children--timer
              (run-with-timer harness-ui-children--redraw-delay nil
                              #'harness-ui-children--flush buffer))))))

(defun harness-ui-children--on-update (sid update)
  "Follow session UPDATE of SID so the panel stays current.
Activity is kept per session, and an update of either a child's activity
or its record asks for a redraw of the chat of its parent
\(`harness-ui-children--redraw').  A child that stopped running has its
activity forgotten."
  (let ((kind (plist-get update :sessionUpdate)))
    (cond
     ((equal kind "_harness/activity")
      (let ((activity (plist-get update :activity)))
        (if activity
            (puthash sid activity harness-ui-children--activity)
          (remhash sid harness-ui-children--activity)))
      (harness-ui-children--redraw sid))
     ((equal kind "_harness/session")
      (when-let* ((parent (plist-get (harness-ui-session sid) :parent-id)))
        (puthash sid parent harness-ui-children--parent))
      (unless (equal (harness-ui-children--str (plist-get (harness-ui-session sid) :status)) "running")
        (remhash sid harness-ui-children--activity))
      (harness-ui-children--redraw sid))
     ((equal kind "_harness/session_deleted")
      (remhash sid harness-ui-children--activity)
      (remhash sid harness-ui-children--turn-start)
      (harness-ui-children--redraw sid)
      (remhash sid harness-ui-children--parent)))))

(defun harness-ui-children--on-event (event args)
  "Follow EVENT with ARGS, so the panel shows how long a child has run.
`agent/turn-started' and `agent/turn-ended' carry the child's id first;
the turn's start feeds the elapsed time and its end asks for a redraw
of the panel."
  (when (member event '("agent/turn-started" "agent/turn-ended"))
    (when-let* ((sid (car args)))
      (if (equal event "agent/turn-started")
          (puthash sid (float-time) harness-ui-children--turn-start)
        (remhash sid harness-ui-children--turn-start))
      (harness-ui-children--redraw sid))))

(defun harness-ui-children--setup ()
  "Put the running-sub-agents panel in this chat buffer, before the others."
  (add-hook 'harness-chat-panel-functions #'harness-ui-children--panel t))

(defun harness-ui-children--init ()
  "Add the panel to every chat buffer and follow children as they run."
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-children--setup))
  (add-hook 'harness-ui-update-functions #'harness-ui-children--on-update)
  (add-hook 'harness-ui-event-functions #'harness-ui-children--on-event))

(harness-ui-children--init)

(harness-define-module 'ui-children
  :doc "Sub-agents of a session at work or blocked on you, pinned above its compose box: name, progress and elapsed time, and for a blocked one what it asks, with the buttons that answer it."
  :requires '(ui ui-chat)
  :init #'harness-ui-children--init)

(provide 'harness-ui-children)
;;; harness-ui-children.el ends here
