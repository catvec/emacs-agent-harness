;;; harness-priority.el --- Priorities for sessions, and their one vocabulary  -*- lexical-binding: t; -*-

;;; Commentary:

;; Some work is more urgent than other work, and the harness has more
;; than one queue to put it in: a task board holds a project's tasks
;; back while it runs as many at once as the user allows, and the tool
;; slots (see the tool-slots module) hold back the calls of the tools
;; that start processes while a machine is busy.  Both order their queue
;; by the same thing, the priority of the session the work belongs to:
;; low, medium (the default) or high.
;;
;; A priority is the session's, whatever the session is: a plain chat
;; can have one, not only a task's session.  It lives in the session's
;; `:ext' (`session/set-ext') under `:priority', as the level's name, so
;; it is stored with the record and comes back after a restart.  A
;; session that has none of its own takes its parent's (`:parent-id') --
;; the sub-agents and forks working for a task work at the task's
;; priority -- and the default when nothing up the chain has one.
;;
;; This module is the one place that knows the levels, how a level is
;; written and what is above what; everything else asks it.  Tasks keep
;; their own priority in their record -- a task has one before it has a
;; session -- and give it to their session, so the rest of the harness
;; sees the same priority they queue by.
;;
;; Clients reach it over ACP as `_harness/priority/get {sessionId}',
;; `.../rank {sessionId}' and `.../set {sessionId, priority}'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defconst harness-priority-levels '(low medium high)
  "The priorities a session may have, lowest first; medium is the default.")

(defconst harness-priority-default 'medium
  "The priority of a session that has none of its own, or of no session at all.")

(defconst harness-priority-ext-key :priority
  "The `:ext' key under which a session keeps its priority.
Its value is the level's name (a string), which the store keeps as it is.")

(defconst harness-priority--parent-depth 10
  "How many parents up the chain a priority is looked for.
A cycle of `:parent-id's, which nothing should make, is cut off there.")

;;;; The levels

(defun harness-priority-read (value)
  "Return VALUE as one of `harness-priority-levels', or signal.
VALUE is a symbol or a string in any case, \"med\" meaning medium, so a
priority can come from JSON, a tool, a board command or a person.  nil
is the default, `harness-priority-default'."
  (let* ((name (downcase (string-trim (cond ((null value) (symbol-name harness-priority-default))
                                            ((symbolp value) (symbol-name value))
                                            ((stringp value) value)
                                            (t (format "%s" value))))))
         (level (intern (if (equal name "med") "medium" name))))
    (or (car (memq level harness-priority-levels))
        (error "Unknown priority %s; it is %s"
               value (harness-priority-levels-text)))))

(defun harness-priority-levels-text ()
  "Return the levels as a sentence reads them: \"low, medium or high\"."
  (let ((names (mapcar #'symbol-name harness-priority-levels)))
    (format "%s or %s" (string-join (butlast names) ", ") (car (last names)))))

(defun harness-priority-known (value)
  "Return VALUE as one of `harness-priority-levels', or nil.
Unlike `harness-priority-read' this never signals: a value that names
no level -- a stored priority a later version does not know, say -- is
nil, for the caller to fall back on."
  (car (memq (or (and (symbolp value) value)
                 (and (stringp value) (intern (downcase (string-trim value)))))
             harness-priority-levels)))

(defun harness-priority-level (value)
  "Return the level VALUE stands for: one of `harness-priority-levels'.
nil, or a name no level has, is the default
\(`harness-priority-default'): this reads a stored priority, where a
missing or a stale one is no error."
  (or (harness-priority-known value) harness-priority-default))

(defun harness-priority-rank (value)
  "Return the place of VALUE among `harness-priority-levels': 0 is the lowest."
  (cl-position (harness-priority-level value) harness-priority-levels))

(defun harness-priority-above-p (a b)
  "Non-nil when priority A is above priority B.
A and B are levels, or anything `harness-priority-level' reads; the
default when they name none."
  (> (harness-priority-rank a) (harness-priority-rank b)))

;;;; A session's priority

(defun harness-priority-of-ext (ext)
  "Return the priority EXT, a session's `:ext' plist, keeps, or nil.
nil means the session has none of its own and takes its parent's."
  (let ((value (and (consp ext) (plist-get ext harness-priority-ext-key))))
    (and value (harness-priority-known (format "%s" value)))))

(defun harness-priority-ext (priority)
  "Return the `session/create' `:ext' that gives a session PRIORITY.
PRIORITY is a level, or whatever `harness-priority-read' reads."
  (list harness-priority-ext-key (symbol-name (harness-priority-read priority))))

(defun harness-priority-session (session &optional depth)
  "Return the priority of SESSION (a session plist), a level symbol.
That is its own `:ext' `:priority'; a session that has none of its own
takes its parent's (`:parent-id'), and one whose chain up has none
either is `harness-priority-default'.  DEPTH cuts off a cycle of
parents (`harness-priority--parent-depth')."
  (or (harness-priority-of-ext (plist-get session :ext))
      (let ((parent (plist-get session :parent-id)))
        (and parent
             (< (or depth 0) harness-priority--parent-depth)
             (harness-method-exists-p 'session/get)
             (let ((plist (condition-case nil (harness-call 'session/get parent) (error nil))))
               (and plist (harness-priority-session plist (1+ (or depth 0)))))))
      harness-priority-default))

(defun harness-priority-of (session-id)
  "Return the priority of session SESSION-ID, a level symbol.
The session's own (`harness-priority-session'), or its parent's;
`harness-priority-default' without SESSION-ID, without the session, or
without the sessions module."
  (if (and session-id (harness-method-exists-p 'session/get))
      (let ((session (condition-case nil (harness-call 'session/get session-id) (error nil))))
        (if session (harness-priority-session session) harness-priority-default))
    harness-priority-default))

(defun harness-priority-set-session (session-id priority &optional hint)
  "Give session SESSION-ID priority PRIORITY; return the level.
PRIORITY is a level, or whatever `harness-priority-read' reads (it
signals on a name no level has); HINT, a string, is added to the
session's transcript as a hint, as `session/set-ext' does.  The
priority orders the queues the session waits in (see the tool-slots
module): the higher it is, the sooner its calls and its commands go."
  (unless (harness-method-exists-p 'session/set-ext)
    (error "The sessions module is not loaded, so a session has no priority"))
  (let ((level (harness-priority-read priority)))
    (harness-call 'session/set-ext session-id harness-priority-ext-key
                  (symbol-name level) hint)
    level))

;;;; Methods

(harness-defmethod priority/get (session-id)
  "Return the priority of session SESSION-ID, as \"low\", \"medium\" or \"high\".
A session that has none of its own says its parent's, and one whose
chain up has none either says `harness-priority-default'."
  (symbol-name (harness-priority-of session-id)))

(harness-defmethod priority/rank (session-id)
  "Return the place of session SESSION-ID's priority among the levels: 0 is low.
For callers that order something by priority without knowing the
levels, such as the tool slots."
  (harness-priority-rank (harness-priority-of session-id)))

(harness-defmethod priority/set (session-id priority)
  "Give session SESSION-ID priority PRIORITY; return it as a level's name.
PRIORITY is a level, or a symbol or a string naming one in any case
\(\"med\" meaning medium); a name no level has is refused.  The
priority is the session's own from then on (see `priority/get'), and
orders the queues its work waits in."
  (symbol-name (harness-priority-set-session session-id priority)))

(harness-define-module 'priority
  :doc "Session priority: low, medium or high, and the one vocabulary for it.")

(provide 'harness-priority)
;;; harness-priority.el ends here
