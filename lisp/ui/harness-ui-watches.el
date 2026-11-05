;;; harness-ui-watches.el --- Event watches, pinned above the compose box  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session that watches events (`watch_events', tools-events) shows
;; its watches pinned at the bottom of its chat, beside the running
;; sub-agents and the todo list, above the compose box: one line per
;; watch still live, with the kinds of event it watches, what it
;; narrows them to and what it has seen so far -- the events that came,
;; the decisions its classifier made, the events still waiting.  The
;; line goes when the watch ends.  Its prompt, the instructions the
;; classifier reads, follows dim, cut to the room the chat's window
;; leaves, so the line never wraps and the compose box below never
;; jumps as the panel comes and goes.
;;
;; The watches live in the harness, in the process the UI talks to, so
;; the panel asks for them (`event-watch/list') and keeps the answer
;; per session.  It asks when it is first drawn, and again when the
;; harness says a watch changed: `event-watch/changed' is forwarded as
;; `_harness/event' like the other events, and names the session whose
;; watch changed.  Drawing the panel rebuilds the chat's whole tail,
;; compose box included, and a watch changes on every event it sees, so
;; a chat asks and draws at most once in a while: the changes that come
;; meanwhile share one fetch and one drawing, and a drawing that would
;; show the same text as the last is left out (see
;; `harness-ui-watches--draw-now').

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

(declare-function harness-chat--windows "harness-ui-chat" ())
(declare-function harness-ui-chat-of-p "harness-ui" (buffer &optional session-id))

(defgroup harness-ui-watches nil
  "Event watches of a session, pinned above its compose box."
  :group 'harness-ui)

(harness-ui-define-icon harness-ui-watches-icon "watch" "◉" "watch"
  "An event watch.")

(defconst harness-ui-watches--fetch-delay 0.2
  "Seconds a chat waits before it asks for its watches again.
A watch changes on every event it sees and every decision it makes;
the requests that come meanwhile share one question.")

(defconst harness-ui-watches--draw-delay 0.1
  "Seconds a chat waits before it draws its watches again.
Drawing the tail redraws the compose box with it, so the drawings that
a burst of changes asks for share one.")

(defvar harness-ui-watches--cache (make-hash-table :test 'equal)
  "Session id -> the event watches of it the UI last heard of.
Each is a plist as `event-watch/list' returns it.")

(defvar-local harness-ui-watches--drawn nil
  "The text of the event-watch panel this chat buffer drew last, or nil for none.
It has no text properties.  Whatever makes the chat draw its tail
records it (`harness-ui-watches--panel'), so a drawing asked for by a
change can tell whether the panel changed since.")

(defvar-local harness-ui-watches--timer nil
  "This chat buffer's pending question for its watches, a timer, or nil.")
(defvar-local harness-ui-watches--draw-timer nil
  "This chat buffer's pending drawing of its watch panel, a timer, or nil.")
(defvar-local harness-ui-watches--fetching nil
  "Non-nil while this chat buffer waits for its watches.")
(defvar-local harness-ui-watches--pending nil
  "Non-nil when this chat buffer wants another answer once the one in flight comes.")
(defvar-local harness-ui-watches--fetched nil
  "Non-nil once this chat buffer has had its watches and could draw them.")

(defun harness-ui-watches--str (value)
  "Return VALUE, a symbol or a string, as a string."
  (cond ((null value) "")
        ((symbolp value) (symbol-name value))
        (t (format "%s" value))))

(defun harness-ui-watches--room ()
  "Return how many columns one line of the panel may take in this chat.
That is the body of the narrowest window showing the buffer, 80 when no
window does, less two columns, so a line never reaches the edge of its
window and wraps."
  (let ((windows (harness-chat--windows)))
    (- (if windows (apply #'min (mapcar #'window-body-width windows)) 80) 2)))

(defun harness-ui-watches--scope (watch)
  "Return what WATCH narrows its events to, in a few words."
  (let ((target (plist-get watch :target))
        (task (plist-get watch :task)))
    (cond
     ((and (stringp target) (equal target harness-ui-session-id)) "this session")
     ((stringp target) (harness-ui-session-name target))
     ((stringp task) (format "task %s" task))
     ((plist-get watch :all-projects) "every project")
     (t "this project"))))

(defun harness-ui-watches--counts (watch)
  "Return what WATCH has seen so far, in a few words."
  (let ((seen (or (plist-get watch :seen) 0))
        (decisions (or (plist-get watch :decisions) 0))
        (queued (or (plist-get watch :queued) 0)))
    (concat (format "%d %s" seen (if (= seen 1) "event" "events"))
            " · "
            (format "%d %s" decisions (if (= decisions 1) "decision" "decisions"))
            (if (> queued 0) (format " · %d waiting" queued) ""))))

(defun harness-ui-watches--line (watch)
  "Return the panel's line for WATCH, an event watch.
The kinds of event it watches, what it narrows them to and what it has
seen, one screen line, with its prompt dim after them, cut to the room
the chat's window leaves; its tooltip names the actions it may take and
the full prompt."
  (let* ((events (mapcar #'harness-ui-watches--str (plist-get watch :events)))
         (kinds (string-join events ", "))
         (head (concat "   "
                       (propertize (harness-ui-icon 'harness-ui-watches-icon)
                                   'face 'harness-label-face)
                       " "
                       (propertize kinds 'face 'default)
                       (propertize (concat "  ·  " (harness-ui-watches--scope watch)
                                           "  ·  " (harness-ui-watches--counts watch))
                                   'face 'harness-dim-face)))
         (room (min 60 (- (harness-ui-watches--room) (string-width head) 2)))
         (prompt (string-trim (or (plist-get watch :prompt) "")))
         (line (concat head
                       (when (and (not (string-empty-p prompt)) (>= room 8))
                         (concat "   " (propertize (truncate-string-to-width prompt room nil nil "…")
                                                   'face 'harness-dim-face)))
                       "\n")))
    (propertize line 'help-echo
                (string-join
                 (delq nil
                       (list (if (plist-get watch :prompt)
                                 (format "What it looks for: %s" (plist-get watch :prompt))
                               nil)
                             (when-let* ((actions (plist-get watch :actions)))
                               (format "Actions: %s" (string-join actions ", ")))
                             (when-let* ((timeout (plist-get watch :timeout)))
                               (format "Ends after %ss" timeout))
                             (when (plist-get watch :once)
                               "Ends after its first decision")))
                 "; "))))

(defun harness-ui-watches--render ()
  "Return the panel of this session's event watches, or nil.
A session that watches nothing shows nothing.  This only builds the
text; `harness-ui-watches--panel' is what the chat draws."
  (when (and (stringp harness-ui-session-id)
             (not (string-empty-p harness-ui-session-id)))
    (when-let* ((watches (gethash harness-ui-session-id harness-ui-watches--cache)))
      (when watches
        (concat
         (propertize (concat (harness-ui-icon 'harness-ui-watches-icon)
                             (format " Event watches  %d live" (length watches)))
                     'face 'harness-label-face)
         "\n"
         (mapconcat #'harness-ui-watches--line watches "")
         "\n")))))

(defun harness-ui-watches--plain (text)
  "Return TEXT, a panel from `harness-ui-watches--render', without properties.
nil, no panel, stays nil."
  (and text (substring-no-properties text)))

(defun harness-ui-watches--panel ()
  "Return the panel of this session's event watches, or nil.
On `harness-chat-panel-functions'.  The first time it is drawn it asks
the harness for the watches, and keeps what it drew in
`harness-ui-watches--drawn', for the drawings a change asks for to
compare with."
  (unless harness-ui-watches--fetched
    (harness-ui-watches--fetch (current-buffer)))
  (let ((text (harness-ui-watches--render)))
    (setq harness-ui-watches--drawn (harness-ui-watches--plain text))
    text))

;;;; Asking the harness

(defun harness-ui-watches--chat-buffer (sid)
  "Return the live chat buffer showing session SID, or nil.
Another view of the session, such as its access view, is no chat."
  (when (and (stringp sid) (not (string-empty-p sid)))
    (cl-find-if (lambda (buffer) (harness-ui-chat-of-p buffer sid)) (buffer-list))))

(defun harness-ui-watches--fetch (buffer)
  "Ask the harness for the event watches of BUFFER's session.
A question already in flight is not asked again: BUFFER marks that it
wants another answer once that one comes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (stringp harness-ui-session-id)
                 (not (string-empty-p harness-ui-session-id)))
        (if (or harness-ui-watches--fetching harness-ui-watches--pending)
            (setq harness-ui-watches--pending t)
          (setq harness-ui-watches--fetching t)
          (let ((sid harness-ui-session-id)
                (buf (current-buffer)))
            (harness-ui-call
             "_harness/event-watch/list" (list :session-id sid)
             (lambda (watches)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq harness-ui-watches--fetching nil
                         harness-ui-watches--fetched t)
                   (when (equal harness-ui-session-id sid)
                     (puthash sid (append watches nil) harness-ui-watches--cache)
                     (if harness-ui-watches--pending
                         (progn
                           (setq harness-ui-watches--pending nil)
                           (harness-ui-watches--fetch buf))
                       (harness-ui-watches--draw buf))))))
             (lambda (_err)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq harness-ui-watches--fetching nil
                         harness-ui-watches--pending nil)))))))))))

(defun harness-ui-watches--request (sid)
  "Ask for the watches of session SID again, once the changes settle."
  (when-let* ((buffer (harness-ui-watches--chat-buffer sid)))
    (with-current-buffer buffer
      (unless (and (timerp harness-ui-watches--timer)
                   (memq harness-ui-watches--timer timer-list))
        (setq harness-ui-watches--timer
              (run-at-time harness-ui-watches--fetch-delay nil
                           #'harness-ui-watches--flush buffer))))))

(defun harness-ui-watches--flush (buffer)
  "Ask for the watches of BUFFER's session, its changes having settled.
The timer `harness-ui-watches--request' set calls it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp harness-ui-watches--timer)
        (cancel-timer harness-ui-watches--timer))
      (setq harness-ui-watches--timer nil)
      (harness-ui-watches--fetch buffer))))

;;;; Drawing

(defun harness-ui-watches--draw (buffer)
  "Ask for the tail of chat BUFFER to be drawn again, once, shortly."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless (and (timerp harness-ui-watches--draw-timer)
                   (memq harness-ui-watches--draw-timer timer-list))
        (setq harness-ui-watches--draw-timer
              (run-at-time harness-ui-watches--draw-delay nil
                           #'harness-ui-watches--draw-now buffer))))))

(defun harness-ui-watches--draw-now (buffer)
  "Draw the tail of chat BUFFER again if its event-watch panel changed.
A timer `harness-ui-watches--draw' set calls it; a panel that reads the
same as the one drawn there last is left alone."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq harness-ui-watches--draw-timer nil)
      (unless (equal (harness-ui-watches--plain (harness-ui-watches--render))
                     harness-ui-watches--drawn)
        (when (functionp harness-compose-redraw-function)
          (funcall harness-compose-redraw-function))))))

;;;; Events

(defun harness-ui-watches--on-event (event args)
  "Follow EVENT with ARGS: `event-watch/changed' names the session it changed."
  (when (equal event "event-watch/changed")
    (let ((sid (car args)))
      (when (and (stringp sid) (not (string-empty-p sid)))
        (harness-ui-watches--request sid)))))

(defun harness-ui-watches--on-update (sid update)
  "Follow session UPDATE of SID, a watcher's or a session gone.
A session that has just arrived asks for its watches once: a chat
opened before the harness knew of it drew no panel."
  (let ((kind (plist-get update :sessionUpdate)))
    (cond
     ((equal kind "_harness/session_deleted")
      (remhash sid harness-ui-watches--cache))
     ((equal kind "_harness/session")
      (when-let* ((buffer (harness-ui-watches--chat-buffer sid)))
        (with-current-buffer buffer
          (unless (or harness-ui-watches--fetched harness-ui-watches--fetching
                      (and (timerp harness-ui-watches--timer)
                           (memq harness-ui-watches--timer timer-list)))
            (harness-ui-watches--fetch buffer))))))))

;;;; Setup

(defun harness-ui-watches--setup ()
  "Put the event-watch panel in this chat buffer, beside the others."
  (add-hook 'harness-chat-panel-functions #'harness-ui-watches--panel t))

(defun harness-ui-watches--init ()
  "Add the panel to every chat buffer and follow the watches as they change."
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-watches--setup))
  (add-hook 'harness-ui-update-functions #'harness-ui-watches--on-update)
  (add-hook 'harness-ui-event-functions #'harness-ui-watches--on-event))

(harness-ui-watches--init)

(harness-define-module 'ui-watches
  :doc "Event watches of a session, pinned above its compose box: what each watches and what it has seen."
  :requires '(ui ui-chat)
  :init #'harness-ui-watches--init)

(provide 'harness-ui-watches)
;;; harness-ui-watches.el ends here
