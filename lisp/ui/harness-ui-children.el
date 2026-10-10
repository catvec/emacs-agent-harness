;;; harness-ui-children.el --- Running sub-agents, pinned above the compose box  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session that started sub-agents shows them pinned at the bottom of
;; its chat, beside the todo list and the merge queue, above the compose
;; box: one line per child that is still running, with its name, how
;; long it has been at work and what it is doing now.  It stays there
;; while the child works and goes when it stops, so the user watching the
;; parent session sees its workers without scrolling back to the
;; `spawn_agent' call that started them -- which a background sub-agent
;; outlives anyway.
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

(defvar harness-chat-panel-functions)
(defvar harness-chat-mode-hook)
(defvar harness-ui-session-id)
(defvar harness-compose-redraw-function)
(defvar harness-ui-update-functions)
(defvar harness-ui-event-functions)

(declare-function harness-chat--activity-text "harness-ui-chat" (activity))
(declare-function harness-chat--activity-details "harness-ui-chat" (activity))
(declare-function harness-chat--format-elapsed "harness-ui-chat" (seconds))
(declare-function harness-chat--normalise-todos "harness-ui-chat" (todos))

(defgroup harness-ui-children nil
  "Running sub-agents of a session, pinned above its compose box."
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

(defun harness-ui-children--running ()
  "Return this session's running sub-agents, newest first, or nil.
A running child is a cached session of kind `subagent' whose
`:parent-id' is this buffer's session and whose status is `running'; a
seed conversation does not count, and says so itself (in its `:ext',
`harness-ui-seed-session-p').  This buffer's session is always a
string in a chat, so a nil id (no session) matches nothing."
  (when (and (stringp harness-ui-session-id) (not (string-empty-p harness-ui-session-id)))
    (let ((sid harness-ui-session-id))
      (cl-remove-if-not
       (lambda (s)
         (and (equal (plist-get s :parent-id) sid)
              (equal (harness-ui-children--str (plist-get s :kind)) "subagent")
              (equal (harness-ui-children--str (plist-get s :status)) "running")
              (harness-ui-navigable-session-p s)))
       (harness-ui-sessions)))))

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

(defun harness-ui-children--line (child)
  "Return the panel's line for CHILD, a running sub-agent.
The name is the one shared session link (`harness-ui-session-link'), so
a click opens the child; the progress and elapsed time follow, dim."
  (let* ((id (plist-get child :id))
         (name (or (plist-get child :name) id))
         (progress (harness-ui-children--progress child))
         (elapsed (harness-ui-children--elapsed child)))
    (concat "   "
            (propertize (harness-ui-icon 'harness-icon-running)
                        'face 'harness-status-running-face)
            " "
            (harness-ui-session-link id (harness-truncate-end name 24)
                                     (format "Open the session %s" name))
            (if elapsed
                (concat "  " (propertize elapsed 'face 'harness-dim-face))
              "")
            (unless (string-empty-p progress)
              (concat "  " (propertize (harness-truncate-end (string-trim progress) 60)
                                       'face 'harness-dim-face)))
            "\n")))

(defun harness-ui-children--render ()
  "Return the panel of this session's running sub-agents, or nil.
A session with no running sub-agent shows nothing.  This only builds
the text; `harness-ui-children--panel' is what the chat draws."
  (when-let* ((children (harness-ui-children--running)))
    (concat
     (propertize (concat (harness-ui-icon 'harness-ui-children-icon)
                         (format " Sub-agents  %d running" (length children)))
                 'face 'harness-label-face)
     "\n"
     (string-join (mapcar #'harness-ui-children--line children) "")
     "\n")))

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
  "Return the live chat buffer showing session SID, or nil."
  (cl-find-if (lambda (buffer)
                (equal (buffer-local-value 'harness-ui-session-id buffer) sid))
              (buffer-list)))

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
  :doc "Running sub-agents of a session, pinned above its compose box: name, progress and elapsed time."
  :requires '(ui ui-chat)
  :init #'harness-ui-children--init)

(provide 'harness-ui-children)
;;; harness-ui-children.el ends here
