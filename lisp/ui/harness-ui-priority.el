;;; harness-ui-priority.el --- A session's priority: the header segment and its keys  -*- lexical-binding: t; -*-

;;; Commentary:

;; The priority plugin keeps a priority for every session -- low, medium
;; (the default) or high -- and the harness serves the work of a high
;; session before a low one's: the tool slots, above all, give the slots
;; of a busy machine to the calls of the highest priority session
;; waiting.  A task has no priority of its own: a task's priority is its
;; session's, and every task has a session from the moment it is
;; submitted, so this is where a task's priority is set and shown too.
;;
;; A chat whose session's priority is not the default shows it in the
;; header line, just before the session's name: an arrow up for high, an
;; arrow down for low, each in its face
;; (`harness-priority-high-face', `harness-priority-low-face', dim), and
;; nothing where the priority is medium, which goes without saying.  The
;; arrow is the one thing that shows a priority -- the session list's
;; Priority column and a board's cards show the same arrow, made by
;; `harness-ui-priority-arrow' -- and a click on it asks for that
;; session's priority (`harness-ui-priority-click').
;;
;; The harness keys: + raises the priority of the session in front of
;; you and - lowers it, one level at a time
;; (`harness-priority-raise', `harness-priority-lower'), with C-u on
;; either asking for a level instead; y (`harness-set-priority') asks for
;; the level of that session and Y (`harness-set-priority-all') gives
;; every current session and task of every project one.  p stays the
;; permission mode (`harness-set-permission-mode').  Under a task board
;; the session in front of you is the session of the task at point, so
;; the same keys set a task's priority; the board's own + and - do too.
;;
;; The header, the session list's Priority column and the boards follow
;; the harness: a priority the harness announces (`session/ext-changed',
;; of the priority) has the session cache fetched again, and the chat
;; buffer redraws its header from it.  A task board's card is a task's,
;; so the keys there act on the task's session, waiting or working.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat-header-functions)
(defvar harness-ui-event-functions)

(declare-function harness-chat--session "harness-ui-chat")
(declare-function harness-chat--segment "harness-ui-chat")

(defconst harness-ui-priority-levels '("low" "medium" "high")
  "The priorities a session may have, lowest first, as the harness sends them.")

(defconst harness-ui-priority-default "medium"
  "The priority a session has when it has none of its own.")

(defconst harness-ui-priority--parent-depth 10
  "How many parents up the session cache a priority is looked for.
A session with none of its own takes its parent's (the priority
plugin's rule); a cycle of `:parent-id's, which nothing should make, is
cut off there.")

(defface harness-priority-high-face '((t :inherit warning))
  "The priority segment of a session whose priority is high."
  :group 'harness-ui)

(defface harness-priority-low-face '((t :inherit harness-dim-face :slant italic))
  "The priority segment of a session whose priority is low."
  :group 'harness-ui)

;; The arrows, in one place, for the chat header, the session list and
;; the boards: the character where a display can draw it, a caret where
;; it cannot.
(define-icon harness-icon-priority-high nil
  `((symbol ,(string #x2191)) (text "^"))
  "A session of high priority: an arrow up." :version "29.1")

(define-icon harness-icon-priority-low nil
  `((symbol ,(string #x2193)) (text "v"))
  "A session of low priority: an arrow down." :version "29.1")

(defun harness-ui-priority-arrow-help (level)
  "Return what the arrow of priority LEVEL says on hover."
  (format "%s priority: %s (mouse-1: change the priority)"
          (capitalize level)
          (if (equal level "high")
              "the harness serves this session's commands before lower ones'"
            "the harness serves higher priority sessions' commands before it")))

(defconst harness-ui-priority-arrow-property 'harness-priority-session
  "Text property an arrow carries: the session whose priority it shows.
`harness-ui-priority-click' reads it, so a click acts on the session of
the arrow clicked, wherever that arrow is.")

(defun harness-ui-priority-click (&optional event)
  "Ask through a menu, and set, the priority of the session EVENT clicked.
The arrow carries its session id in `harness-ui-priority-arrow-property',
so a click acts on the session of the arrow clicked -- a chat's, a
session list row's, a board card's -- not on the one in front of you,
and shows the levels it may be given as a menu at the click
\(`harness-ui-priority--ask').  Without an id, as on the arrow of a
record that has no session, `harness-set-priority' falls back on the
item at point."
  (interactive (list last-nonmenu-event))
  (let* ((posn (and (mouse-event-p event) (event-start event)))
         (point (and posn (posn-point posn)))
         (id (and (integer-or-marker-p point)
                  (get-text-property point harness-ui-priority-arrow-property))))
    (when (and posn (window-live-p (posn-window posn)))
      (select-window (posn-window posn)))
    (harness-set-priority id nil event)))

(defvar harness-ui-priority-arrow-map (harness-ui-mouse-keymap #'harness-ui-priority-click)
  "Keymap of a priority arrow: a click asks for that session's priority.")

(defun harness-ui-priority-arrow (level &optional session)
  "Return the arrow for priority LEVEL, or \"\" for the default, medium.
Up for high and down for low, in `harness-priority-high-face' or
`harness-priority-low-face' (dim): the one arrow a chat's header line,
the session list's Priority column and a board's cards all show, so a
priority reads the same everywhere (see
`harness-ui-priority-arrow-help' for what it says on hover).  SESSION,
the id of the session the arrow belongs to, is carried so that a click
on the arrow asks for that session's priority
\(`harness-ui-priority-click')."
  (when (and level (not (equal level harness-ui-priority-default)))
    (propertize (harness-ui-icon (if (equal level "high")
                                     'harness-icon-priority-high
                                   'harness-icon-priority-low))
                'face (if (equal level "high") 'harness-priority-high-face
                        'harness-priority-low-face)
                'help-echo (harness-ui-priority-arrow-help level)
                'mouse-face 'highlight
                'keymap harness-ui-priority-arrow-map
                harness-ui-priority-arrow-property session)))

(defun harness-ui-priority--of (session)
  "Return SESSION's own priority, a string, or nil when it has none.
A priority the harness has not sent, or one this UI does not know, is nil."
  (let ((value (plist-get (plist-get session :ext) :priority)))
    (when value
      (let ((name (if (symbolp value) (symbol-name value) (format "%s" value))))
        (and (member name harness-ui-priority-levels) name)))))

(defun harness-ui-priority-level-of (session &optional depth)
  "Return SESSION's priority as a level, the default when it names none.
A session with none of its own takes its parent's, as the priority
plugin reads it, so this is the level the harness serves the session's
work at; the parents are looked up in the UI's session cache, and DEPTH
cuts a cycle of them off (`harness-ui-priority--parent-depth')."
  (or (harness-ui-priority--of session)
      (let ((parent (plist-get session :parent-id)))
        (and parent
             (< (or depth 0) harness-ui-priority--parent-depth)
             (when-let* ((plist (harness-ui-session parent)))
               (harness-ui-priority-level-of plist (1+ (or depth 0))))))
      harness-ui-priority-default))

(defun harness-ui-priority--header ()
  "Return the priority segment of this chat's header line, or nil.
It is `harness-ui-priority-arrow' for the session's priority, drawn
beside the session's name: up for high, down for low.  A session at the
default (`harness-ui-priority-default') shows nothing, and so does one
whose priority the harness has not sent.  Clicking the arrow asks for
that session's priority."
  (let* ((session (harness-chat--session))
         (level (harness-ui-priority--of session)))
    (when-let* ((arrow (harness-ui-priority-arrow level (plist-get session :id))))
      (concat arrow " "))))

(defun harness-ui-priority--failed (err)
  "Say why the priority could not be set, given the failure ERR.
A harness without the priority module does not know the method, which
is said plainly rather than as a failure."
  (unless (harness-ui-connection-replaced-p err)
    (let ((text (harness-error-message err)))
      (if (string-match-p "[Mm]ethod not found\\|No such harness method" text)
          (message "Priority is not available (the priority module is not loaded)")
        (message "Harness: setting the priority failed: %s" text))))
  nil)

(defun harness-ui-priority--no-session ()
  "Say that a priority is a session's, as the target at point is not one.
The board's new-task settings, and a chat whose session the harness has
not sent, are what a setting command finds instead."
  (message "Priority is a session's: point at a task or a session (the board's + and - set a task's)"))

(defun harness-ui-priority--session-id (target)
  "Return the session id TARGET names, or nil.
TARGET is what `harness-ui--setting-target' gives: a session id, or the
settings of work that has no session yet, which gets a priority when it
is submitted."
  (and (stringp target) target))

(defun harness-ui-priority--target ()
  "Return the session the priority commands act on, or nil.
That is the session at point in a view -- the chat's session, the
session list's row, and on a task board the session of the task at
point, a waiting task's included -- else what `harness-ui--setting-target'
gives, a session id or the settings of work that has no session yet."
  (or (harness-ui-session-at-point t)
      (harness-ui-priority--session-id (harness-ui--setting-target nil))))

(defun harness-ui-priority--set (session-id level &optional done)
  "Give session SESSION-ID priority LEVEL, then call DONE with the level.
LEVEL is one of `harness-ui-priority-levels'; the request goes to
`_harness/priority/set'.  The harness announces the change like any
other (`session/ext-changed', and the session itself), so the header,
the session list and whoever follows it show the new level without this
asking again."
  (harness-ui-call "_harness/priority/set"
                   (list :sessionId session-id :priority level)
                   (lambda (result)
                     (funcall (or done #'ignore) (or result level)))
                   #'harness-ui-priority--failed))

(defun harness-ui-priority--menu-items (current)
  "Return the entries of the priority menu, the level CURRENT greyed out.
The levels come highest first, as the harness serves them, so the menu
says both what the priority is now and what it may become."
  (mapcar (lambda (level)
            (vector level (capitalize level) (not (equal level current))))
          (reverse harness-ui-priority-levels)))

(defun harness-ui-priority--menu (session event)
  "Pop up the levels at EVENT, the ones SESSION may be given, or return nil.
The level the session is at now is greyed out; nil when nothing was
chosen, or when this display cannot pop a menu up."
  (when (and event (display-popup-menus-p))
    (let ((choice (popup-menu
                   (cons "Priority"
                         (harness-ui-priority--menu-items
                          (and session (harness-ui-priority-level-of session))))
                   event)))
      (and choice (car (member choice harness-ui-priority-levels))))))

(defun harness-ui-priority--choose (prompt &optional current)
  "Read one of `harness-ui-priority-levels' with PROMPT, highest first.
CURRENT, the level in force, is what an empty answer takes; the levels
are offered highest first, as the harness serves them, the one place the
order and the prompt are known."
  (let ((choices (reverse harness-ui-priority-levels)))
    (car (member (completing-read
                  prompt
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity)
                                   (cycle-sort-function . identity))
                      (complete-with-action action choices string pred)))
                  nil t nil nil current)
                 harness-ui-priority-levels))))

(defun harness-ui-priority--ask (prompt session &optional event)
  "Ask for a priority, offering the level of SESSION, and return it.
PROMPT is what the prompt line says; an answer that names no level is
returned as it is, for the caller to refuse.  With EVENT -- a click on
an arrow (`harness-ui-priority-click') -- the possible levels are a menu
at the click instead, and nothing chosen changes nothing."
  (if (and event (display-popup-menus-p))
      (harness-ui-priority--menu session event)
    (harness-ui-priority--choose prompt (and session (harness-ui-priority-level-of session)))))

;;;###autoload
(defun harness-priority-shift-session (session-id step &optional done)
  "Give session SESSION-ID the priority STEP levels above its own.
STEP is 1 to raise and -1 to lower, and the level it reaches is set with
`_harness/priority/set'; a step past low or high only says which level
the session is at already, and a session the harness has not sent says
so.  DONE, when non-nil, is called with the new level; by default it is
said as raised or lowered.  This is what the harness keys, and the
session list's keys, share."
  (let ((session (harness-ui-session session-id)))
    (if (null session)
        (message "Priority: the harness has not sent this session yet")
      (let* ((level (harness-ui-priority-level-of session))
             (rank (cl-position level harness-ui-priority-levels :test #'equal))
             (next (nth (+ rank step) harness-ui-priority-levels)))
        (if (or (null next) (< (+ rank step) 0))
            (message "Priority is %s already" level)
          (harness-ui-priority--set
           session-id next
           (or done (lambda (level)
                      (message "Priority %s to %s" (if (> step 0) "raised" "lowered") level)))))))))

;;;###autoload
(defun harness-set-priority (&optional session-id level event)
  "Set the priority of SESSION-ID to LEVEL; ask for LEVEL when not given.
A priority is low, medium (the default) or high, and is always a
session's: it orders the queues the session's work waits in, the tool
slots above all, which serve the calls of a high session before a low
one's.  A task's priority is its session's, so on a task board the
command sets the priority of the session of the task at point, waiting
or working -- the same thing the board's own + and - set.  EVENT, a
click on an arrow (`harness-ui-priority-click'), asks through a menu at
the click instead of the minibuffer.  The chat header, the session list
and the boards show the priority as an arrow when it is not the
default."
  (interactive)
  (let ((target (or session-id (harness-ui-priority--target))))
    (cond
     ((not (harness-ui-priority--session-id target))
      (harness-ui-priority--no-session))
     ((null (harness-ui-session target))
      (message "Priority: the harness has not sent this session yet"))
     (t
      (let ((level (or level
                       (harness-ui-priority--ask "Priority: " (harness-ui-session target) event))))
        (cond ((null level) nil)
              ((not (member level harness-ui-priority-levels))
               (message "Priority is low, medium or high, not %S" level))
              (t (harness-ui-priority--set target level (lambda (level) (message "Priority: %s" level))))))))))

(defun harness-ui-priority--shift (step)
  "Move the priority of the session in front of you STEP levels.
STEP is 1 or -1; a target that is not a session only says so."
  (let ((target (harness-ui-priority--target)))
    (if (harness-ui-priority--session-id target)
        (harness-priority-shift-session target step)
      (harness-ui-priority--no-session))))

;;;###autoload
(defun harness-priority-raise (&optional ask)
  "Raise the priority of the session in front of you one level.
That is low to medium, or medium to high: the higher a session's
priority, the sooner the harness serves its commands.  Under a task
board it raises the priority of the task at point, a task's priority
being its session's.  With a prefix argument, ASK for the level instead
\(`harness-set-priority')."
  (interactive "P")
  (if ask (call-interactively #'harness-set-priority) (harness-ui-priority--shift 1)))

;;;###autoload
(defun harness-priority-lower (&optional ask)
  "Lower the priority of the session in front of you one level.
That is high to medium, or medium to low.  Under a task board it lowers
the priority of the task at point, a task's priority being its
session's.  With a prefix argument, ASK for the level instead
\(`harness-set-priority')."
  (interactive "P")
  (if ask (call-interactively #'harness-set-priority) (harness-ui-priority--shift -1)))

;;;###autoload
(defun harness-set-priority-all (&optional level)
  "Give every current session and task of every project the priority LEVEL.
It asks for LEVEL when not given.  Every active session (idle, running
or blocked) of every project changes, and the session of every current
task, a closed one included -- a task's priority is its session's,
whatever its session's status -- through `_harness/priority/set-all'.
A session already carrying that level is left alone, and it reports how
many changed.  A priority is a session's, so nothing of a task's own
changes."
  (interactive)
  (let ((level (or level (harness-ui-priority--ask "Priority for every session and task: " nil))))
    (if (not (member level harness-ui-priority-levels))
        (message "Priority is low, medium or high, not %S" level)
      (harness-ui-call "_harness/priority/set-all"
                       (list :priority level :filter (harness-ui--everything-filter))
                       (lambda (changed)
                         (harness-ui-refresh-sessions)
                         (message (if changed
                                      (format "Priority → %s for %s"
                                              level (harness-ui--count (length changed) "session"))
                                    (format "Every current session and task is at %s already" level))))
                       #'harness-ui-priority--failed))))

(defun harness-ui-priority--key-name (key)
  "Return KEY, a keyword or a string as the wire carries it, as a name.
`:priority' and \":priority\" both read \"priority\"."
  (when key
    (string-remove-prefix ":" (downcase (if (keywordp key) (symbol-name key) (format "%s" key))))))

(defun harness-ui-priority--on-event (event args)
  "Fetch the session cache again when EVENT changed a session's priority.
ARGS are the event's arguments; of `session/ext-changed' they are (ID
KEY VALUE).  A change of any other setting is none of this module's
business, and is left for whoever made it."
  (when (and (equal event "session/ext-changed")
             (equal "priority" (harness-ui-priority--key-name (cadr args))))
    (harness-ui-refresh-sessions)))

;;;; Module

(defconst harness-ui-priority--keys
  '(("+" . harness-priority-raise) ("-" . harness-priority-lower)
    ("y" . harness-set-priority) ("Y" . harness-set-priority-all))
  "The harness keys this module binds, as (KEY . COMMAND).
`p' is not one of them: it is the permission mode
\(`harness-set-permission-mode').")

(defun harness-ui-priority--init ()
  "Show the priority segment in chat headers and bind the priority keys.
Idempotent: the hooks are added only once, and the keys are set as the
module asks for them."
  (add-hook 'harness-chat-header-functions #'harness-ui-priority--header)
  (add-hook 'harness-ui-event-functions #'harness-ui-priority--on-event)
  (dolist (key harness-ui-priority--keys)
    (define-key harness-ui-map (kbd (car key)) (cdr key))))

(defun harness-ui-priority--shutdown ()
  "Take the priority segment out of chat headers and unbind its keys.
A key another module bound in the meantime is left as it is."
  (remove-hook 'harness-chat-header-functions #'harness-ui-priority--header)
  (remove-hook 'harness-ui-event-functions #'harness-ui-priority--on-event)
  (dolist (key harness-ui-priority--keys)
    (when (eq (lookup-key harness-ui-map (kbd (car key))) (cdr key))
      (define-key harness-ui-map (kbd (car key)) nil))))

(harness-define-module 'ui-priority
  :doc "A session's priority: the chat header's segment, the keys that raise, lower and set it, and the bulk command."
  :requires '(ui ui-chat)
  :init #'harness-ui-priority--init
  :shutdown #'harness-ui-priority--shutdown)

(provide 'harness-ui-priority)
;;; harness-ui-priority.el ends here
