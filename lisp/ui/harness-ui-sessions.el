;;; harness-ui-sessions.el --- Session list  -*- lexical-binding: t; -*-

;;; Commentary:

;; A `tabulated-list-mode' buffer of sessions: status, name, kind,
;; model, thinking level, permission mode, priority, context, output
;; tokens, average output rate (tokens per second over the whole
;; session), cost, when its last message came and project.  Child
;; sessions (forks, BTW conversations, sub-agents) are indented under
;; their parents.  Scoped to the current project by default; `a'
;; toggles all projects; `b' shows only the sessions waiting for you;
;; `/' filters fuzzily; column headers sort.
;;
;; The list is wide, so every cell is small, and a hover says more: the
;; Avg tok/s column is the session's output tokens over the seconds its
;; model spent streaming them, the average of its whole life, and its
;; tooltip names the current rate beside it; the Think column is the
;; session's thinking level, empty on its model's default; the Last msg
;; column is how long ago its last user or assistant message came (the
;; last change of any kind for a session recorded before the harness
;; kept that).  The columns are one spec (`harness-ui-sessions--columns').
;; Mode and Output are left out by default
;; (`harness-ui-sessions-hidden-columns'), and C shows or hides a
;; column in this list only (`harness-ui-sessions-toggle-column');
;; Project shows only when the list covers all projects, as in one
;; project's list it says the same on every row.
;;
;; Sessions are marked as files are in Dired.  m marks the session at
;; point and moves to the next row (a numeric argument marks that many),
;; u unmarks it, DEL moves up and unmarks the row there, U unmarks every
;; session and t inverts the marks of the rows listed.  A marked session
;; has a * where the padding of its row is, and the mode line counts the
;; marks (`harness-ui-sessions--marked').  Marking changes the row in
;; place, so a paused list shows it.  Marks stay through a redraw, g, the
;; filters, a change of scope and the pause: a session the filters hide
;; stays marked, and is acted on with the rest, so U is the way to be
;; rid of marks out of sight.
;;
;; The commands that act on sessions act on every marked session, or on
;; the one at point when none is marked: d deletes them after one
;; question, k cancels the turns of those that run or wait, x
;; deactivates them, M-t makes them tasks, + and - raise and lower their
;; priority and p sets it, asking for the level once.  d, k, x and M-t
;; unmark the sessions they acted on, and leave the mark on one they
;; skipped, as k does a session that is idle; + - and p leave the marks,
;; so several changes can be given to the same sessions.  f, r and M act
;; on one session and refuse while any is marked.  RET, o, SPC, y and n
;; are the session at point's, marked or not.
;;
;; The harness's setting commands act on the same sessions: the model
;; (`harness-set-model'), the thinking level, the permission mode,
;; non-interactive mode and supervisor mode, which the harness prefix
;; keys (C-c h m, T, p, i and V) and the menu run.  In the list they
;; change every marked session, or the session at point when none is
;; marked, as they do in that session's chat; the list says which to them
;; (`harness-ui-sessions--setting-target').  The marked sessions are
;; changed together, and so are the tasks they work on, which keep the
;; setting for their next start.  A model switch that would lose
;; conversations asks once how to hand them over.  The marks stay, so
;; several settings can be given to the same sessions.  The list binds no
;; key to these commands, its m, T, p and i being others, so its menu
;; group does not list them.  The menu's own Session settings column
;; (`harness-menu') lists all but supervisor mode, and runs them here.
;;
;; T lists only the sessions that work on a task, with the sub-agents,
;; forks and BTW conversations under them
;; (`harness-ui-sessions-toggle-tasks-only').  The harness's own model
;; calls -- the permission and session judges, auto-naming and the like
;; -- are sessions of kind internal, which the list leaves out
;; (`harness-ui-sessions-hidden-kinds'); I shows them
;; (`harness-ui-sessions-toggle-internal').  The mode line says which of
;; these two filters are on.
;;
;; The list follows the sessions as they change, a few times a second
;; while a model streams, while a window shows it.  A list no window
;; shows notes what it missed and draws once when a window shows it
;; again (`harness-ui-view-install'): a thousand rows take a good part
;; of a second to draw, and the sessions change much oftener than that.
;; Should a window show it before it caught up, its mode line says
;; [Suspended: resume], as that of every such view does, and a click on
;; it wakes the list (`harness-ui-view-wake').
;; Even a shown list leaves Emacs the time it takes to draw, four times
;; over, between one redraw and the next that follows the sessions by
;; itself (`harness-ui-sessions--cost-factor'), so it never takes more
;; than a fifth of it; and the tooltips of the figures are made when
;; they are hovered, not for every row at every redraw
;; (`harness-ui-session-help-function').  P pauses the following, and so
;; does the [Pause] button in the mode line
;; (`harness-ui-sessions-toggle-pause'): a paused list holds still until
;; it is resumed or reloaded with g, shown or not.  Changes, output
;; rates, token counts and a reload of the UI leave it alone; its own
;; commands -- the filter, the scope, the toggles -- still redraw it,
;; with what changed meanwhile.
;; Every cell starts at the same place on every row, under its header,
;; and the figures -- context, output, rate and cost -- are right-aligned
;; so their ends line up (see "Rows" below for how the rows are printed).
;;
;; The columns, their cells and the rows are not the list buffer's
;; alone.  Another view that lists sessions draws them with the same
;; code, so that a session reads the same wherever it is listed, and
;; draws no rows of its own: the task slots page lists the tasks at work
;; this way.  `harness-ui-sessions-column' is a column of the list,
;; `harness-ui-sessions-format' the format of some columns,
;; `harness-ui-sessions-cells' a session's cells in them,
;; `harness-ui-sessions-insert-entry' its row, with the line saying what
;; it waits on when it is blocked, and `harness-ui-sessions-header-row'
;; the header of a buffer that has no header line.  None of them reads
;; the list's buffer.
;;
;; The Priority column shows the arrow for the level the harness serves
;; the session's work at -- up for high, down for low, the default,
;; medium, left out as it is everywhere else -- and the arrow is a
;; button: a click asks for that session's priority
;; (`harness-ui-priority-arrow').  + and - raise and lower the priority
;; of the session at point, p sets it, and C-u on + or - asks for the
;; level instead (`harness-ui-sessions-raise-priority' and the two
;; beside it); the levels are the priority UI's (`harness-set-priority').
;;
;; M moves the session at point to another working directory, and the
;; list then shows it under that directory's project
;; (`harness-move-session').  M-t makes sessions tasks, shown on their
;; project's task board (`harness-ui-sessions-make-task').
;;
;; RET opens the session at point in its project: the project becomes
;; current first, as switching project does (Doom Emacs's workspaces),
;; and a session showing there already gets its window selected
;; (`harness-ui-visit-session').
;;
;; F gives the list the fullscreen layout: the list stays on the left
;; of the frame and the sessions it opens show beside it, until q on the
;; list ends it (`harness-fullscreen').
;;
;; A blocked session has a line under its row: buttons answering what it
;; waits on, the task board's (`harness-ui-pending-view-actions') --
;; [Allow] and [Deny] for a permission request, which y and n push too,
;; [Answer…] for a question -- and what that is.  SPC pops out what the
;; session at point waits on, so it can be read whole and answered
;; without opening the session (`harness-ui-popout-at-point').  Clicking
;; the mode line's notifier opens the list on the sessions waiting for
;; you, in every project (`harness-sessions-waiting').
;;
;; Other modules may draw something under the rows, as the companion pet
;; does (`harness-ui-sessions-footer-functions').  It follows the last
;; row, whichever column the rows are sorted by, and is no session's: RET
;; and the row commands find none there.
;;
;; A project includes its linked git worktrees: a session there (a
;; task's, a sub-agent's) has the worktree as its `:project', and is
;; listed with the main checkout that worktree belongs to.
;;
;; A session that works on a task is of kind task, and is called by its
;; task's title, as on the board, until it has a name of its own.  A task
;; is named as soon as it is submitted and its session takes that name,
;; but a session made before the name came, or whose task's naming
;; failed, has none for a while: without the title it would read
;; "unnamed".  The list asks the harness for the tasks when it opens, on
;; `g' and after a reload or reconnect (`_harness/task/list'), and
;; follows `task/changed' and `task/deleted' in between.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-files)
(require 'harness-ui-pending)
;; The priority UI knows what a priority is and how it is set; the list
;; shows it and sets it through that, so it offers no vocabulary of its
;; own (`harness-ui-priority-level-of', `harness-set-priority').
(require 'harness-ui-priority)

(declare-function harness-ui-popout-try-at-point "harness-ui-popout")

(defgroup harness-ui-sessions nil
  "The session list." :group 'harness-ui)

(defcustom harness-ui-sessions-hidden-columns '("Mode" "Output")
  "Names of the columns the session list leaves out.
Any of Name, Status, Kind, Model, Think, Mode, Priority, Context,
Output, Avg tok/s, Cost, Last msg and Project; the status icon always
shows.  C in the list shows or hides a column in that list only
\(`harness-ui-sessions-toggle-column').  The Project column shows only
when the list covers all projects, whatever this says: in one
project's list it says the same on every row."
  :type '(repeat string) :group 'harness-ui-sessions)

(defcustom harness-ui-sessions-hidden-kinds '("internal")
  "Kinds of session the session list leaves out unless it shows them.
The harness's own model calls -- the permission and session judges,
auto-naming and the like -- are sessions of kind internal: they come and
go all the time and are not conversations to read.  I in the list shows
the kinds named here, or hides them again
\(`harness-ui-sessions-toggle-internal')."
  :type '(repeat string) :group 'harness-ui-sessions)

(defface harness-ui-sessions-mark-face '((t :inherit (warning bold)))
  "Face of the mark in front of a marked session's row in the session list."
  :group 'harness-ui-sessions)

(defface harness-ui-sessions-paused-face '((t :inherit (warning bold)))
  "Face of the mode line's pause button while the session list is paused."
  :group 'harness-ui-sessions)

(defconst harness-ui-sessions--buffer-name "*harness sessions*"
  "Name of the session list buffer.")

(defvar-local harness-ui-sessions--project nil
  "Main checkout the list is scoped to, or nil for all projects.")
(defvar-local harness-ui-sessions--filter "" "Fuzzy filter text.")
(defvar-local harness-ui-sessions--show-inactive t)
(defvar-local harness-ui-sessions--blocked-only nil
  "Non-nil when the list shows only the sessions waiting for you.
That is the blocked ones: the mode line's notifier opens the list so.")
(defvar-local harness-ui-sessions--tasks-only nil
  "Non-nil when the list shows only the sessions that work on a task.
The sub-agents, forks and BTW conversations of such a session are
listed too, under it (`harness-ui-sessions--on-task-p').")
(defvar-local harness-ui-sessions--show-hidden-kinds nil
  "Non-nil when the list shows the kinds of `harness-ui-sessions-hidden-kinds'.")
(defvar-local harness-ui-sessions--paused nil
  "Non-nil when the list is paused: it holds still instead of following changes.
The sessions that change, their output rates and token counts, the
requests they wait on and a reload of the UI do not redraw it; its own
commands and `g' still do (`harness-ui-sessions-toggle-pause').")
(defvar-local harness-ui-sessions--depths nil
  "Hash table: session id -> how deep its row is indented under its parents.")
(defvar-local harness-ui-sessions--main-roots nil
  "Hash table: session project root -> the main checkout it belongs to.
Which checkout a root belongs to does not change, and the list redraws
on every session change, so each root is resolved once; `g' forgets them.")
(defvar-local harness-ui-sessions--tasks nil
  "Hash table: session id -> the task (wire plist) that session works on.
Nil until the harness has said which tasks there are; a harness without
tasks never does.")
(defvar harness-ui-sessions--hidden-columns nil
  "Names of the columns this list hides, once a column was toggled in it.
`harness-ui-sessions-toggle-column' gives the list its own copy of
`harness-ui-sessions-hidden-columns' to change; it is local to the list
then.  Until it is, the list hides what the option says, even if that
changes (`harness-ui-sessions--hidden-names').")
(defvar-local harness-ui-sessions--marked nil
  "Hash table: id of a session marked in this list -> t.
Made when the list's mode starts, or at the first mark of a list kept
from before marks existed through a reload.  It is kept apart from the
rows, so the marks survive a redraw, `g', the filters, a change of scope
and the pause: a marked session's row starts with a mark
\(`harness-ui-sessions-mark-face') in place of the padding space.  A
session the filters hide stays marked, though no row shows it.  A
refresh drops the ids of sessions the session cache no longer has
\(`harness-ui-sessions--refresh').")

(defun harness-ui-sessions--main-root (root)
  "Return the main checkout session project ROOT belongs to.
A linked git worktree belongs to its main checkout.  A root gone from
disk, like an archived task's worktree, belongs to the project around it.
Remote roots are not looked at.  See `harness-files-owning-checkout'."
  (when root
    (let ((memo (or harness-ui-sessions--main-roots
                    (setq harness-ui-sessions--main-roots (make-hash-table :test 'equal)))))
      (or (gethash root memo)
          (puthash root (harness-files-owning-checkout root) memo)))))

(defun harness-ui-sessions--task (s)
  "Return the task session S works on, or nil."
  (and harness-ui-sessions--tasks
       (gethash (plist-get s :id) harness-ui-sessions--tasks)))

(defun harness-ui-sessions--name (s)
  "Return what the list calls session S, or nil when it has no name.
A task's session is called by its task's title until it is named: the
task's own name, else its prompt's first line."
  (let* ((task (harness-ui-sessions--task s))
         (name (if task (harness-ui-task-title task s) (plist-get s :name))))
    (and (not (harness-string-blank-p name)) name)))

(defun harness-ui-sessions--kind (s)
  "Return the kind the list shows for session S: task for a task's session."
  (if (harness-ui-sessions--task s) "task" (or (plist-get s :kind) "main")))

(defun harness-ui-sessions--hidden-kind-p (s)
  "Non-nil when session S is of a kind the list leaves out unless it shows it.
Those are the kinds of `harness-ui-sessions-hidden-kinds'."
  (and (member (format "%s" (plist-get s :kind)) harness-ui-sessions-hidden-kinds) t))

(defun harness-ui-sessions--on-task-p (s)
  "Non-nil when session S works on a task, or one of its ancestors does.
That makes a task's sub-agents, forks and BTW conversations, however
deep, belong to it.  The parents are looked up in the session cache: a
parent it does not have ends the search, and so does a cycle of them."
  (let ((seen nil) (found nil))
    (while (and s (not found) (not (member (plist-get s :id) seen)))
      (if (harness-ui-sessions--task s)
          (setq found t)
        (push (plist-get s :id) seen)
        (setq s (harness-ui-session (plist-get s :parent-id)))))
    found))

(defun harness-ui-sessions--matches-p (s)
  "Non-nil when session S belongs in the list: scope, status, kind and filter.
The list leaves out the kinds of `harness-ui-sessions-hidden-kinds'
unless it shows them, and while it lists only tasks, the sessions that
are no task's and have no ancestor that is (`harness-ui-sessions--on-task-p').
The filter matches what the list shows of S: its name or task title,
model, status, kind and permission mode."
  (and (or (null harness-ui-sessions--project)
           (equal (harness-ui-sessions--main-root (plist-get s :project))
                  harness-ui-sessions--project))
       (or harness-ui-sessions--show-inactive
           (not (equal (plist-get s :status) "inactive")))
       (or (not harness-ui-sessions--blocked-only)
           (harness-session-waiting-on-user-p s))
       (or harness-ui-sessions--show-hidden-kinds
           (not (harness-ui-sessions--hidden-kind-p s)))
       (or (not harness-ui-sessions--tasks-only)
           (harness-ui-sessions--on-task-p s))
       (or (string-empty-p harness-ui-sessions--filter)
           (harness-fuzzy-score harness-ui-sessions--filter
                                (format "%s %s %s %s %s" (or (harness-ui-sessions--name s) "") (plist-get s :model)
                                        (plist-get s :status) (harness-ui-sessions--kind s)
                                        (plist-get s :permission-mode))))))

(defun harness-ui-sessions--ordered ()
  "Return matching sessions as (DEPTH . SESSION), parents before children."
  (let* ((all (harness-ui-sessions))
         (matching (cl-remove-if-not #'harness-ui-sessions--matches-p all))
         (listed (make-hash-table :test 'equal :size (length matching)))
         (children (make-hash-table :test 'equal))
         (out nil))
    ;; A session hangs under its parent when the parent is listed too; a
    ;; table of the listed ids says so at once, where a search of the
    ;; list for each of a thousand sessions took a tenth of the redraw.
    (dolist (s matching) (puthash (plist-get s :id) t listed))
    (dolist (s matching)
      (let ((pid (plist-get s :parent-id)))
        (if (and pid (gethash pid listed))
            (push s (gethash pid children))
          (push s (gethash :roots children)))))
    (cl-labels ((walk (s depth)
                  (push (cons depth s) out)
                  (dolist (c (sort (copy-sequence (gethash (plist-get s :id) children))
                                   (lambda (a b) (< (or (plist-get a :created) 0) (or (plist-get b :created) 0)))))
                    (walk c (1+ depth)))))
      (dolist (r (sort (copy-sequence (gethash :roots children))
                       (lambda (a b) (> (or (plist-get a :updated) 0) (or (plist-get b :updated) 0)))))
        (walk r 0)))
    (nreverse out)))

(defun harness-ui-sessions--priority (s)
  "Return the priority SESSION S is served at, a level name.
That is the one the harness serves its work at: its own, or its
parent's when it has none of its own (`harness-ui-priority-level-of'),
and medium, the default, for a harness without the priority plugin."
  (harness-ui-priority-level-of s))

(defun harness-ui-sessions--priority-cell (s &optional _depth)
  "Return the Priority cell of session S: its arrow, or nothing.
The arrow `harness-ui-priority-arrow' makes -- up for high, down for
low -- which the chat's header line and a board's cards show too; medium,
the default, goes without saying as it does everywhere, so its cell is
empty.  A click on the arrow asks for that session's priority."
  (or (harness-ui-priority-arrow (harness-ui-sessions--priority s) (plist-get s :id))
      ""))

(defun harness-ui-sessions--priority< (a b)
  "Order entries A and B by their sessions' priorities, lowest first."
  (< (cl-position (harness-ui-sessions--priority (harness-ui-session (car a)))
                  harness-ui-priority-levels :test #'equal)
     (cl-position (harness-ui-sessions--priority (harness-ui-session (car b)))
                  harness-ui-priority-levels :test #'equal)))

(defun harness-ui-sessions--tokens< (key)
  "Return a sorter ordering entries by their sessions' token figure KEY.
KEY is `:context' or `:output', as `harness-ui-session-tokens' gives
them: a running session's grow as its model streams."
  (lambda (a b)
    (< (plist-get (harness-ui-session-tokens (harness-ui-session (car a))) key)
       (plist-get (harness-ui-session-tokens (harness-ui-session (car b))) key))))

(defun harness-ui-sessions--average-rate< (a b)
  "Order entries A and B by their sessions' average output rates, none first."
  (< (or (harness-ui-session-average-rate (harness-ui-session (car a))) -1)
     (or (harness-ui-session-average-rate (harness-ui-session (car b))) -1)))

(defun harness-ui-sessions--spend< (a b)
  "Order entries A and B by what their sessions cost at API prices.
Sessions a plan pays for cost nothing but still sort by how much they used."
  (< (harness-usage-list-cost (plist-get (harness-ui-session (car a)) :usage))
     (harness-usage-list-cost (plist-get (harness-ui-session (car b)) :usage))))

(defun harness-ui-sessions--thinking< (a b)
  "Order entries A and B by their sessions' thinking levels, weakest first.
That is the order of `harness-thinking-level-order'; a session
without a level of its own, which thinks as its model does by default,
or with one the order does not know, sorts first."
  (cl-flet ((rank (entry)
              (or (cl-position (plist-get (harness-ui-session (car entry)) :thinking)
                               harness-thinking-level-order :test #'equal)
                  -1)))
    (< (rank a) (rank b))))

(defun harness-ui-sessions--last-message (s)
  "Return the time session S last had a message, else when it last changed.
That is `:last-message', the time of its latest user or assistant
message.  A record from before the harness kept it has none, and then
the last change of any kind stands in (`:updated'), else 0."
  (or (plist-get s :last-message) (plist-get s :updated) 0))

(defun harness-ui-sessions--last-message< (a b)
  "Order entries A and B by when their sessions last had a message, oldest first."
  (< (harness-ui-sessions--last-message (harness-ui-session (car a)))
     (harness-ui-sessions--last-message (harness-ui-session (car b)))))

(defun harness-ui-sessions--name-cell (s depth)
  "Return the Name cell of session S, indented DEPTH levels under its parents."
  (let ((name (or (harness-ui-sessions--name s) (propertize "unnamed" 'face 'harness-dim-face))))
    (concat (make-string (* 2 depth) ?\s)
            (if (> depth 0) (propertize "↳ " 'face 'harness-dim-face) "")
            (propertize name 'face (if (harness-session-waiting-on-user-p s)
                                       'harness-status-blocked-face
                                     'default)))))

(defun harness-ui-sessions--status-cell (s &optional _depth)
  "Return the Status cell of session S: its status, in its face.
The tooltip says what a blocked session waits on."
  (let ((status (plist-get s :status)))
    (propertize status 'face (harness-ui-status-face status)
                'help-echo (or (harness-ui-sessions--waiting-help s) status))))

(defun harness-ui-sessions--thinking-cell (s &optional _depth)
  "Return the Think cell of session S: its thinking level, as plain text.
It is empty for a session on its model's default.  The tooltip names the
level and the command that changes it, `harness-set-thinking'."
  (let ((level (plist-get s :thinking)))
    (if (and (stringp level) (not (harness-string-blank-p level)))
        (propertize level 'help-echo (format "Thinking level: %s.  M-x harness-set-thinking changes it."
                                             level))
      "")))

(defun harness-ui-sessions--last-message-help (s)
  "Return the tooltip of session S's Last msg cell: the time, and what it is."
  (let ((time (harness-ui-sessions--last-message s)))
    (cond ((plist-get s :last-message)
           (format "Last user or assistant message: %s"
                   (format-time-string "%F %H:%M" time)))
          ((plist-get s :updated)
           (format "No message time is recorded for this session; its last change of any kind: %s"
                   (format-time-string "%F %H:%M" time)))
          (t "No time is recorded for this session"))))

(defun harness-ui-sessions--last-message-cell (s &optional _depth)
  "Return the Last msg cell of session S: how long ago its last message came.
The tooltip gives the time, and says when it is the last change of any
kind instead, which a session recorded before the harness kept the time
of its messages has.  It is made when it is hovered
\(`harness-ui-session-help-function')."
  (propertize (harness-relative-time (harness-ui-sessions--last-message s))
              'help-echo (harness-ui-session-help-function
                          s #'harness-ui-sessions--last-message-help)))

(defconst harness-ui-sessions--columns
  (list (list :name "" :width 2 :sort t :always t
              :cell (lambda (s _depth) (harness-ui-status-icon (plist-get s :status))))
        (list :name "Name" :width 28 :sort t :cell #'harness-ui-sessions--name-cell)
        (list :name "Status" :width 9 :sort t :cell #'harness-ui-sessions--status-cell)
        (list :name "Kind" :width 9 :sort t
              :cell (lambda (s _depth)
                      (let ((kind (harness-ui-sessions--kind s))) (if (equal kind "main") "" kind))))
        (list :name "Model" :width 22 :sort t
              :cell (lambda (s _depth) (harness-ui-model-label (plist-get s :model))))
        (list :name "Think" :width 7 :sort #'harness-ui-sessions--thinking<
              :cell #'harness-ui-sessions--thinking-cell)
        (list :name "Mode" :width 13 :sort t
              :cell (lambda (s _depth)
                      (if-let* ((m (plist-get s :permission-mode))) (harness-ui-permission-mode-label m) "")))
        (list :name "Priority" :width 9 :sort #'harness-ui-sessions--priority<
              :cell #'harness-ui-sessions--priority-cell)
        ;; The tooltips of these four are made when they are hovered, not
        ;; for every row at every redraw (`harness-ui-session-help-function').
        (list :name "Context" :width 13 :sort (harness-ui-sessions--tokens< :context) :right-align t
              :cell (lambda (s _depth) (harness-ui-format-context s t)))
        (list :name "Output" :width 7 :sort (harness-ui-sessions--tokens< :output) :right-align t
              :cell (lambda (s _depth) (or (harness-ui-format-output s t t) "")))
        (list :name "Avg tok/s" :width 9 :sort #'harness-ui-sessions--average-rate< :right-align t
              :cell (lambda (s _depth) (or (harness-ui-format-average-rate s t t) "")))
        (list :name "Cost" :width 12 :sort #'harness-ui-sessions--spend< :right-align t
              :cell (lambda (s _depth) (harness-ui-format-spend s nil nil t)))
        (list :name "Last msg" :width 9 :sort #'harness-ui-sessions--last-message<
              :cell #'harness-ui-sessions--last-message-cell)
        (list :name "Project" :width 30 :sort t :all-projects t
              :cell (lambda (s _depth)
                      (propertize (file-name-nondirectory (directory-file-name (or (plist-get s :project) "")))
                                  'face 'harness-dim-face))))
  "The columns of the session list, in order.
Each is a plist: `:name' and `:width' for the header, `:sort' as in
`tabulated-list-format' (t sorts by the text, else a predicate on
entries), `:right-align' when the cell is aligned to the right, and
`:cell', the function of a session and how deep its row is indented that
returns the cell.  `:always' marks the status icon, which is never
left out, and `:all-projects' the Project column, which shows only when
the list covers all projects.  See `harness-ui-sessions--shown-columns'.")

(defun harness-ui-sessions-column (name)
  "Return the column named NAME of `harness-ui-sessions--columns', or nil.
Another view that lists sessions picks the columns it shows from the
list's own, so a session reads the same in both."
  (cl-find name harness-ui-sessions--columns
           :key (lambda (column) (plist-get column :name)) :test #'equal))

(defun harness-ui-sessions--hidden-names ()
  "Return the names of the columns this list hides.
Those of `harness-ui-sessions-hidden-columns', until a column was shown
or hidden in this list, which then has a list of its own
\(`harness-ui-sessions--hidden-columns')."
  (if (local-variable-p 'harness-ui-sessions--hidden-columns)
      harness-ui-sessions--hidden-columns
    harness-ui-sessions-hidden-columns))

(defun harness-ui-sessions--shown-columns ()
  "Return the columns of `harness-ui-sessions--columns' this list shows now.
The status icon always shows.  The others do unless the list hides them
\(`harness-ui-sessions--hidden-names'), and Project only when the list
covers all projects."
  (let ((hidden (harness-ui-sessions--hidden-names)))
    (cl-remove-if-not
     (lambda (column)
       (or (plist-get column :always)
           (and (not (member (plist-get column :name) hidden))
                (or (null harness-ui-sessions--project)
                    (not (plist-get column :all-projects))))))
     harness-ui-sessions--columns)))

(defun harness-ui-sessions-format (columns &optional widths)
  "Return the `tabulated-list-format' of COLUMNS, a list of column specs.
WIDTHS, an alist of a column's name and a width, gives a column another
width than its spec's; a spec's `:pad-right' is the columns left between
its cells and the next column's, one when it has none.  The session
list builds its own format with this, and so does any view that draws
sessions in the same columns (`harness-ui-sessions-insert-entry')."
  (vconcat (mapcar (lambda (column)
                     (append (list (plist-get column :name)
                                   (or (cdr (assoc (plist-get column :name) widths))
                                       (plist-get column :width))
                                   (plist-get column :sort))
                             (and (plist-get column :right-align) '(:right-align t))
                             (and (plist-get column :pad-right)
                                  (list :pad-right (plist-get column :pad-right)))))
                   columns)))

(defun harness-ui-sessions--format ()
  "Return the `tabulated-list-format' of the columns this list shows now."
  (harness-ui-sessions-format (harness-ui-sessions--shown-columns)))

(defun harness-ui-sessions-cells (columns session &optional depth)
  "Return SESSION's cells in COLUMNS, a vector of strings, one for each.
DEPTH is how deep its name is indented under its parents, 0 by default.
A column is a spec of `harness-ui-sessions--columns', or one of the
caller's own with the same keys: its `:cell' is called with SESSION, a
plist, and DEPTH."
  (vconcat (mapcar (lambda (column) (funcall (plist-get column :cell) session (or depth 0)))
                   columns)))

(defun harness-ui-sessions--entry (depth s &optional columns)
  "Return the entry of session S in `tabulated-list-entries'.
Its cells are those of the columns shown now, in order, or of COLUMNS
when the caller has them (they are the same for every row); its name is
indented DEPTH levels under its parents."
  (list (plist-get s :id)
        (harness-ui-sessions-cells (or columns (harness-ui-sessions--shown-columns)) s depth)))

(defun harness-ui-sessions--show-columns ()
  "Give the list the format of the columns it shows now.
The header follows when that changed the columns.  A sort by a column
that is not shown any more ends, as the rows could not sort by it."
  (let* ((format (harness-ui-sessions--format))
         (sorted (car tabulated-list-sort-key))
         (gone (and sorted (not (cl-find sorted format :key #'car :test #'equal)))))
    (when gone
      (setq tabulated-list-sort-key nil))
    (when (or gone (not (equal format tabulated-list-format)))
      (setq tabulated-list-format format)
      (tabulated-list-init-header))))

(defun harness-ui-sessions--pause-button ()
  "Return the pause button of the list's mode line.
It reads [Pause] while the list follows the sessions, and [Paused: resume],
highlighted, while it holds still.  A click on it pauses or resumes the
list, as P does (`harness-ui-sessions-toggle-pause')."
  (let ((paused harness-ui-sessions--paused))
    (propertize (if paused "[Paused: resume]" "[Pause]")
                'face (and paused 'harness-ui-sessions-paused-face)
                'mouse-face 'mode-line-highlight
                'help-echo (if paused
                               "The list is paused and holds still.  Click or press P to resume it; g reloads it."
                             "Click or press P to pause the list: it holds still until resumed, or reloaded with g.")
                'local-map (harness-ui-mouse-keymap #'harness-ui-sessions-toggle-pause))))

(defun harness-ui-sessions--mode-line ()
  "Return the list's `mode-line-process': the pause button, then what it lists.
The button comes first, as a narrow mode line cuts its end: a list that
holds still must always say so.  What follows is the scope and the
filter, and whether the list hides inactive sessions, shows only those
waiting for you or only those that work on a task, or shows the
internal ones.  Last, while any session is marked, comes how many are."
  (concat " " (harness-ui-sessions--pause-button)
          (format " [%s%s%s%s%s%s]"
                  (if harness-ui-sessions--project "project" "all projects")
                  (if (string-empty-p harness-ui-sessions--filter) "" (format " /%s" harness-ui-sessions--filter))
                  (if harness-ui-sessions--show-inactive "" " active")
                  (if harness-ui-sessions--blocked-only " blocked" "")
                  (if harness-ui-sessions--tasks-only " tasks" "")
                  (if harness-ui-sessions--show-hidden-kinds " +internal" ""))
          (let ((marked (harness-ui-sessions--marked-count)))
            (if (> marked 0) (format " %d marked" marked) ""))))

(defun harness-ui-sessions--refresh ()
  "Compute the columns and rows of the list from the session cache.
The marks of sessions the cache no longer has are dropped
\(`harness-ui-sessions--drop-gone-marks').  The mode line is set too
\(`harness-ui-sessions--mode-line')."
  (harness-ui-sessions--show-columns)
  (harness-ui-sessions--drop-gone-marks)
  (let ((ordered (harness-ui-sessions--ordered)))
    (setq harness-ui-sessions--depths (make-hash-table :test 'equal))
    (dolist (cell ordered)
      (puthash (plist-get (cdr cell) :id) (car cell) harness-ui-sessions--depths))
    (let ((columns (harness-ui-sessions--shown-columns)))
      (setq tabulated-list-entries
            (mapcar (lambda (cell) (harness-ui-sessions--entry (car cell) (cdr cell) columns))
                    ordered))))
  (setq mode-line-process (harness-ui-sessions--mode-line)))

;;;; What a blocked session waits on
;;
;; A blocked session's row has a line under it saying what the session
;; waits on, with the buttons that answer it, the ones the task board
;; offers on a card too (`harness-ui-pending-view-actions'): [Allow] and
;; [Deny] for a permission request, [Answer…] for a question, which pops
;; it out.  On both lines y and n answer a permission request, as on the
;; board, and SPC pops the request out.  With the blocked filter on (b,
;; or the notifier's click), a banner above the rows says how many
;; sessions wait, and its [Show all] turns the filter off.

(defvar harness-ui-sessions-button-map (make-sparse-keymap)
  "Keys on the buttons of the session list.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(set-keymap-parent harness-ui-sessions-button-map (harness-ui-action-map #'harness-ui-action-push))
;; A double click pushes a button once: the second click would answer the
;; next request, or open the session.
(define-key harness-ui-sessions-button-map [double-mouse-1] #'ignore)
(define-key harness-ui-sessions-button-map [triple-mouse-1] #'ignore)

(defvar harness-ui-sessions-permission-map (make-sparse-keymap)
  "Keys on the lines of a session waiting on a permission request.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(define-key harness-ui-sessions-permission-map (kbd "y") #'harness-ui-sessions-allow)
(define-key harness-ui-sessions-permission-map (kbd "n") #'harness-ui-sessions-deny)

(defun harness-ui-sessions--button (label action help)
  "Return a button LABEL of the list running ACTION, with HELP as its tooltip."
  (propertize (harness-ui-action-button label action :help help)
              'keymap harness-ui-sessions-button-map))

(defun harness-ui-sessions-request-line (id r indent &optional width)
  "Return the line under the row of session ID, which waits on request R.
It has the buttons answering R, then says what R is.  It starts INDENT
columns in, which is where the name of the row above it starts.  What R
is takes 80 characters at most, and with WIDTH, the columns a line may
take, what the buttons leave of it (8 at least), so that it does not
wrap in a narrow window."
  (let* ((session (harness-ui-session id))
         (head (concat (make-string indent ?\s)
                       (mapconcat (lambda (a) (harness-ui-sessions--button (nth 0 a) (nth 1 a) (nth 2 a)))
                                  (harness-ui-pending-view-actions id) " ")
                       "  "
                       (propertize (or (harness-ui-pending-summary session) "waits for you")
                                   'face 'harness-status-blocked-face)
                       (propertize " · " 'face 'harness-dim-face))))
    (concat head
            (harness-ui-pending-subject
             r (if width (min 80 (max 8 (- width 1 (string-width head)))) 80))
            "\n")))

(defun harness-ui-sessions--banner ()
  "Return the banner of the blocked filter: how many sessions wait for you."
  (let ((n (length tabulated-list-entries)))
    (concat " " (harness-ui-status-icon "blocked") " "
            (propertize (pcase n
                          (0 "No session waits for you")
                          (1 "1 session waits for you")
                          (_ (format "%d sessions wait for you" n)))
                        'face 'bold)
            (propertize (concat (if harness-ui-sessions--project " in this project" " in any project")
                                (if (string-empty-p harness-ui-sessions--filter) ""
                                  (format " matching /%s" harness-ui-sessions--filter)))
                        'face 'harness-dim-face)
            "  "
            (harness-ui-sessions--button "[Show all]" #'harness-ui-sessions-toggle-blocked
                                         "Show every session again (b)")
            " " (harness-ui-kbd "b")
            "\n")))

;;;; Rows
;;
;; Every cell of a row starts where its column does, whatever the cells
;; before it hold.  `tabulated-list-print-entry' ends a cell with an
;; aligning space only when the cell is shorter than its column, so a
;; name that fills its column -- a long one, cut to fit -- leaves the
;; row's next cell wherever the name's glyphs happen to end, and a glyph
;; that is not one cell wide (an emoji, a CJK character, a check mark in
;; another font) shifts the rest of that row against the header and the
;; rows around it.  The list prints its rows itself: the same row, but
;; each cell ends in one space that aligns to the start of the next
;; column, whether it fills its column or not, and takes the cell's
;; padding with it.  A cell that runs a little over its column, by up to
;; the padding, is therefore pulled back to the column's edge instead of
;; pushing the next cell further; one that runs over by more cannot be,
;; as a space only ever moves what follows it forward.

(defvar harness-ui-sessions--spaces (make-hash-table :test 'eql)
  "The aligning spaces of the rows, by how many they are and the column they reach.")

(defun harness-ui-sessions--space (count align-to)
  "Return COUNT spaces that stretch to column ALIGN-TO.
Every cell of every row ends in one, and the rows of a list have a
handful of different ones, so each is made once: a thousand rows made
thirteen thousand of them at every redraw.  The string is only inserted,
never changed."
  (if (and (integerp count) (integerp align-to) (<= 0 count 99999) (<= 0 align-to 99999))
      (let ((key (+ (* count 100000) align-to)))
        (or (gethash key harness-ui-sessions--spaces)
            (puthash key (propertize (make-string count ?\s) 'display `(space :align-to ,align-to))
                     harness-ui-sessions--spaces)))
    (propertize (make-string count ?\s) 'display `(space :align-to ,align-to))))

(defun harness-ui-sessions--print-cell (format n desc x)
  "Insert cell N of a row at point, from its descriptor DESC, at column X.
FORMAT is the vector of the columns (`harness-ui-sessions-format').
Return the column the next cell starts at.  This is
`tabulated-list-print-col' with two differences.  A cell that is not the
last ends in an aligning space even when it fills its column, and its
padding is part of that space.  And a cell is cut to its own column,
never into the room a right-aligned neighbour leaves, as
`tabulated-list-print-col' lets it: no cell of this list could use that
room."
  (let* ((spec (aref format n))
         (name (nth 0 spec))
         (width (nth 1 spec))
         (props (nthcdr 3 spec))
         (pad-right (or (plist-get props :pad-right) 1))
         (right-align (plist-get props :right-align))
         (label (cond ((stringp desc) desc)
                      ((eq (car desc) 'image) " ")
                      (t (car desc))))
         (label-width (string-width label))
         (last-column (= (1+ n) (length format)))
         (start (point)))
    ;; A cell is cut to its column, with an ellipsis, the last one apart:
    ;; it has the rest of the line.
    (when (and (not last-column) (> label-width width))
      (setq label (truncate-string-to-width label width nil nil t t)
            label-width width))
    (setq label (bidi-string-mark-left-to-right label))
    ;; A right-aligned cell starts after the room its label leaves.
    (when (and right-align (> width label-width))
      (let ((shift (- width label-width)))
        (insert (harness-ui-sessions--space shift (+ x shift)))
        (setq width (- width shift)
              x (+ x shift))))
    ;; A cell with a tooltip of its own keeps it; the others say what they
    ;; are, which is put on the text once it is in the buffer, as the
    ;; label need not be copied for it.
    (cond ((stringp desc)
           (let ((at (point)))
             (insert label)
             (unless (get-text-property 0 'help-echo label)
               (put-text-property at (point) 'help-echo (concat name ": " label)))))
          ((eq (car desc) 'image)
           (insert (propertize " " 'display desc 'help-echo (concat name ": " label))))
          (t (apply #'insert-text-button label (cdr desc))))
    (let ((next-x (+ x pad-right width)))
      ;; The last cell needs nothing after it.  The others end in one
      ;; space, the padding and the room the label leaves in one, that
      ;; stretches up to the next column: nothing at all (zero width) when
      ;; the label already reaches it.
      (unless last-column
        (insert (harness-ui-sessions--space (max 1 (+ pad-right (- width (min width label-width))))
                                            next-x)))
      (put-text-property start (point) 'tabulated-list-column-name name)
      next-x)))

(defun harness-ui-sessions-insert-row (format cells &optional padding)
  "Insert at point the row of CELLS in the columns of FORMAT.
FORMAT is a vector as `harness-ui-sessions-format' makes it and CELLS
one string for each of its columns (`harness-ui-sessions-cells').  The
row starts PADDING columns in, and ends in a newline.  It is what
`tabulated-list-print-entry' inserts, but with the cells of
`harness-ui-sessions--print-cell', so a view that is no
`tabulated-list-mode' buffer draws the session list's rows too."
  (let ((x (max (or padding 0) 0))
        (inhibit-read-only t))
    (when (> x 0)
      (insert (make-string x ?\s)))
    (dotimes (n (length format))
      (setq x (harness-ui-sessions--print-cell format n (aref cells n) x)))
    (insert ?\n)))

(defun harness-ui-sessions-header-row (format &optional padding face)
  "Return the header row of the columns of FORMAT, as a string.
Each label starts, or for a right-aligned column ends, where its cells
do (`harness-ui-sessions-insert-row'), in FACE, and the row starts
PADDING columns in.  It is for a view that shows its rows in a buffer of
its own: the session list has the header line."
  (with-temp-buffer
    (harness-ui-sessions-insert-row
     format (vconcat (mapcar (lambda (spec) (propertize (car spec) 'face face)) format)) padding)
    ;; No tooltip for a label, which says what it is.
    (remove-text-properties (point-min) (point-max) '(help-echo nil tabulated-list-column-name nil))
    (buffer-string)))

(defun harness-ui-sessions-insert-entry (session cells format padding indent &optional width)
  "Insert at point the entry of SESSION: its row of CELLS, and what it waits on.
CELLS are one string for each column of FORMAT, which starts PADDING
columns in (`harness-ui-sessions-insert-row'); a session that is blocked
on a request has the line saying what that is under its row, INDENT
columns in and, with WIDTH, no wider than that many columns
\(`harness-ui-sessions-request-line'), and on both lines y and n answer
a permission request.  This is what the session list draws for a
session, and what any other view that lists sessions in the same
columns draws for one too."
  (let ((start (point))
        (id (plist-get session :id)))
    (harness-ui-sessions-insert-row format cells padding)
    (when-let* ((r (and id (equal (plist-get session :status) "blocked")
                        (harness-ui-pending-first id))))
      (insert (harness-ui-sessions-request-line id r indent width))
      (when (equal (plist-get r :kind) "permission")
        (harness-ui-add-keymap start (point) harness-ui-sessions-permission-map)))))

;;;; The footer
;;
;; A module may draw something under the rows -- the companion pet
;; stands there -- through `harness-ui-sessions-footer-functions'.  The
;; printer puts it after the last row, so it comes back whenever the list
;; is printed, as a column's sort prints it (`tabulated-list-sort' calls
;; `tabulated-list-print', not `harness-ui-sessions--print'); with no row
;; to print after, `harness-ui-sessions--print' puts it there.  It is no
;; session's: its lines carry no `tabulated-list-id'.

(defvar harness-ui-sessions-footer-functions nil
  "Functions drawing something under the rows of the session list.
Each is called without arguments in the list's buffer whenever the list
is printed, and returns a string of whole lines, or nil for nothing.
The strings go in order under the last row, after the line saying what
that session waits on, and show with no row at all too.  They are no
session's: RET and the row commands find none there.  A function cannot
move point, where its lines go: it may measure text in a window, which
takes the window's point.  One that signals an error draws nothing.  The
companion pet sits there this way; when what a function draws changes,
`harness-ui-sessions-redraw' prints the list again.")

(defvar-local harness-ui-sessions--last-id nil
  "The id of the last row of the print under way, which the footer follows.
Found at the print's first row, once a print, rather than at each row.")

;;;; The panel above the rows
;;
;; A question the list asks -- how to carry the conversations of the
;; marked sessions over to a new model, say -- shows above the rows as a
;; panel (harness-ui-carry.el), until it is answered.  It is drawn with
;; the rows, so it comes back whenever the list is printed, and a redraw
;; leaves point on it when point was there.  It is no session's: RET and
;; the row commands find none there.

(defvar harness-ui-sessions-panel-functions nil
  "Functions drawing a panel above the rows of the session list.
Each is called without arguments in the list's buffer whenever the list
is printed, and returns a string of whole lines, or nil for nothing.
The panel of a question the list asks (harness-ui-carry.el) is drawn this
way.  The strings go in order above the first row, before the banner of
the blocked filter, and are no session's: RET and the row commands find
none there.  One that signals an error draws nothing.")

(defun harness-ui-sessions--insert-panels ()
  "Insert at point what `harness-ui-sessions-panel-functions' return, in order.
A string that does not end in a newline gets one, so the panels are
whole lines."
  (run-hook-wrapped 'harness-ui-sessions-panel-functions
                    (lambda (fn)
                      (when-let* ((text (ignore-errors (save-excursion (funcall fn)))))
                        (unless (string-empty-p text)
                          (insert text)
                          (unless (eq (char-before) ?\n) (insert "\n"))))
                      nil)))

(defun harness-ui-sessions--insert-top ()
  "Insert at point what goes above the first row.
That is the panels, then the banner of the blocked filter."
  (harness-ui-sessions--insert-panels)
  (when harness-ui-sessions--blocked-only
    (insert (harness-ui-sessions--banner))))

(defun harness-ui-sessions--place (&optional pos)
  "Return what is at POS, point by default, for a redraw to keep point on.
That is a session's id, `panel' for the panel above the rows, or nil."
  (or (tabulated-list-get-id pos)
      (and (get-text-property (or pos (point)) 'harness-ui-carry-panel) 'panel)))

(defun harness-ui-sessions--insert-footer ()
  "Insert at point what `harness-ui-sessions-footer-functions' return, in order.
A string that does not end in a newline gets one, so the footer is
whole lines."
  (run-hook-wrapped 'harness-ui-sessions-footer-functions
                    (lambda (fn)
                      (when-let* ((text (ignore-errors (save-excursion (funcall fn)))))
                        (unless (string-empty-p text)
                          (insert text)
                          (unless (eq (char-before) ?\n) (insert "\n"))))
                      nil)))

(defun harness-ui-sessions--print-entry (id cols)
  "Print the row of session ID, with the columns COLS, and what it waits on.
This is the list's `tabulated-list-printer'.  The banner of the blocked
filter goes above the first row.  A marked session's row starts with a
mark (`harness-ui-sessions-mark-face') in place of the padding space,
which keeps the row's text properties, `tabulated-list-id' above all.  A
blocked session gets the line of what it waits on under its row
\(`harness-ui-sessions-request-line'), which is the session's too: RET
opens it, SPC pops its request out, and it is not marked.
Under the last row, and its line, goes the footer
\(`harness-ui-sessions-footer-functions')."
  (when (bobp)
    (harness-ui-sessions--insert-top))
  ;; The entries are printed in order, sorted or not, so the first row says
  ;; which is the last.
  (let ((entries (and (listp tabulated-list-entries) tabulated-list-entries)))
    (when (equal id (car (car entries)))
      (setq harness-ui-sessions--last-id (car (car (last entries))))))
  (let ((start (point))
        (depth (or (and harness-ui-sessions--depths (gethash id harness-ui-sessions--depths)) 0)))
    (harness-ui-sessions-insert-entry (harness-ui-session id) cols
                                      tabulated-list-format tabulated-list-padding
                                      (+ tabulated-list-padding 3 (* 2 depth) (if (> depth 0) 2 0)))
    (add-text-properties start (point) (list 'tabulated-list-id id 'tabulated-list-entry cols))
    (when (and harness-ui-sessions--marked (gethash id harness-ui-sessions--marked))
      (save-excursion
        (goto-char start)
        (tabulated-list-put-tag (propertize "*" 'face 'harness-ui-sessions-mark-face)))))
  (when (equal id harness-ui-sessions--last-id)
    (harness-ui-sessions--insert-footer)))

(defun harness-ui-sessions--print ()
  "Print the list.
With no row to show, the printer has none to put the panels and the
banner of the blocked filter above or the footer under: they go in here."
  (tabulated-list-print t)
  (unless tabulated-list-entries
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (harness-ui-sessions--insert-top)
      (harness-ui-sessions--insert-footer)
      (set-buffer-modified-p nil))))

(defun harness-ui-sessions-redraw ()
  "Print the session list again, when it exists, as the sessions are now.
For a module whose `harness-ui-sessions-footer-functions' would draw
something else now.  Each window keeps its point on its session.  A
list no window shows is not printed: it is when a window shows it
\(`harness-ui-view-follow-p'), and the footer is drawn then as well."
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (when (harness-ui-view-follow-p buf)
      (harness-ui-sessions--redraw))))

(defun harness-ui-sessions--position (id)
  "Return where the row of session ID starts, else the first row, else `point-min'.
ID `panel' is the panel above the rows, when there is one
\(`harness-ui-sessions--place')."
  (or (and (eq id 'panel)
           (text-property-not-all (point-min) (point-max) 'harness-ui-carry-panel nil))
      (save-excursion
        (goto-char (point-min))
        (let ((first nil) (found nil))
          (while (and (not found) (not (eobp)))
            (let ((here (tabulated-list-get-id)))
              (cond ((and id (equal here id)) (setq found (point)))
                    ((and here (not first)) (setq first (point)))))
            (forward-line 1))
          (or found first (point-min))))))

(defvar harness-ui-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'harness-ui-sessions-open)
    (define-key map (kbd "o") #'harness-ui-sessions-open-other)
    (define-key map [mouse-1] #'harness-ui-sessions-mouse-open)
    (define-key map (kbd "n") #'harness-new-session)
    (define-key map (kbd "f") #'harness-ui-sessions-fork)
    (define-key map (kbd "d") #'harness-ui-sessions-delete)
    (define-key map (kbd "r") #'harness-ui-sessions-rename)
    (define-key map (kbd "k") #'harness-ui-sessions-cancel)
    (define-key map (kbd "x") #'harness-ui-sessions-deactivate)
    (define-key map (kbd "/") #'harness-ui-sessions-filter)
    (define-key map (kbd "a") #'harness-ui-sessions-toggle-scope)
    (define-key map (kbd "i") #'harness-ui-sessions-toggle-inactive)
    (define-key map (kbd "g") #'harness-ui-sessions-reload)
    (define-key map (kbd "SPC") #'harness-ui-sessions-requests)
    (define-key map (kbd "?") #'harness-menu)
    map))

;; At top level, not in the `defvar', so a reload binds them in a running
;; Emacs too.
(define-key harness-ui-sessions-mode-map (kbd "F") #'harness-fullscreen)
(define-key harness-ui-sessions-mode-map (kbd "q") #'harness-ui-quit-view)
(define-key harness-ui-sessions-mode-map (kbd "C-c C-z") #'harness-ui-bury)
(define-key harness-ui-sessions-mode-map (kbd "b") #'harness-ui-sessions-toggle-blocked)
(define-key harness-ui-sessions-mode-map (kbd "M") #'harness-ui-sessions-move)
(define-key harness-ui-sessions-mode-map (kbd "m") #'harness-ui-sessions-mark)
(define-key harness-ui-sessions-mode-map (kbd "u") #'harness-ui-sessions-unmark)
(define-key harness-ui-sessions-mode-map (kbd "DEL") #'harness-ui-sessions-unmark-backward)
(define-key harness-ui-sessions-mode-map (kbd "U") #'harness-ui-sessions-unmark-all)
(define-key harness-ui-sessions-mode-map (kbd "t") #'harness-ui-sessions-toggle-marks)
(define-key harness-ui-sessions-mode-map (kbd "+") #'harness-ui-sessions-raise-priority)
(define-key harness-ui-sessions-mode-map (kbd "-") #'harness-ui-sessions-lower-priority)
(define-key harness-ui-sessions-mode-map (kbd "p") #'harness-ui-sessions-set-priority)
(define-key harness-ui-sessions-mode-map (kbd "C") #'harness-ui-sessions-toggle-column)
(define-key harness-ui-sessions-mode-map (kbd "M-t") #'harness-ui-sessions-make-task)
(define-key harness-ui-sessions-mode-map (kbd "T") #'harness-ui-sessions-toggle-tasks-only)
(define-key harness-ui-sessions-mode-map (kbd "I") #'harness-ui-sessions-toggle-internal)
(define-key harness-ui-sessions-mode-map (kbd "P") #'harness-ui-sessions-toggle-pause)

(define-derived-mode harness-ui-sessions-mode tabulated-list-mode "Sessions"
  "Major mode listing harness sessions.
Sessions are marked as in Dired, and the commands that act on sessions
act on the marked ones, or on the one at point.  So do the harness's
setting commands, such as `harness-set-model' and
`harness-set-thinking' (`harness-ui-sessions--setting-target')."
  (setq tabulated-list-format (harness-ui-sessions--format))
  (setq tabulated-list-padding 1)
  (setq harness-ui-sessions--marked (make-hash-table :test 'equal))
  ;; Rows, and under a blocked session's what it waits on.
  (setq tabulated-list-printer #'harness-ui-sessions--print-entry)
  ;; What the session at point waits on: the popout, and any other command
  ;; that acts on "the session at point", read it through this.
  (setq-local harness-ui-session-at-point-function
              (lambda () (and (derived-mode-p 'harness-ui-sessions-mode) (tabulated-list-get-id))))
  ;; What the setting commands (model, thinking, ...) change: the marked
  ;; sessions, else the session at point.
  (setq-local harness-ui-setting-target-function #'harness-ui-sessions--setting-target)
  ;; An overview: the list can take the fullscreen layout (F).
  (setq-local harness-ui-overview-function #'harness-ui-sessions--overview-session)
  (add-hook 'tabulated-list-revert-hook #'harness-ui-sessions--refresh nil t)
  ;; Followed only while a window shows it; drawn once when it is shown
  ;; again after the changes it missed (`harness-ui-sessions--following-p').
  (harness-ui-view-install #'harness-ui-sessions--catch-up)
  (tabulated-list-init-header))

;; The list's keys in the harness menu, behind `.'.  The harness's setting
;; commands are not among them: a group lists the keys its buffer has
;; (`harness-ui-menu-registrations-teach-the-buffers-keys' holds every
;; entry to that), and the list binds none to these.  The menu's own
;; Session settings column, above this group, lists most of them and runs
;; them here.
(put 'harness-ui-sessions-mode 'harness-menu-group
     '("Session list"
       ["Session at point, or the marked ones"
        (". RET" "Open, in its project" harness-ui-sessions-open)
        (". o" "Open in position" harness-ui-sessions-open-other)
        (". f" "Fork" harness-ui-sessions-fork)
        (". r" "Rename" harness-ui-sessions-rename)
        (". M" "Move to another directory" harness-ui-sessions-move)
        (". k" "Cancel turn" harness-ui-sessions-cancel)
        (". x" "Deactivate" harness-ui-sessions-deactivate)
        (". SPC" "View what it waits on" harness-ui-sessions-requests)
        (". y" "Allow request" harness-ui-sessions-allow)
        (". n" "Deny request" harness-ui-sessions-deny)
        ("M-t" "Make it a task" harness-ui-sessions-make-task)
        (". +" "Raise priority" harness-ui-sessions-raise-priority)
        (". -" "Lower priority" harness-ui-sessions-lower-priority)
        (". p" "Set priority…" harness-ui-sessions-set-priority)
        (". d" "Delete" harness-ui-sessions-delete)
        (". m" "Mark" harness-ui-sessions-mark)
        (". u" "Unmark" harness-ui-sessions-unmark)
        (". U" "Unmark all" harness-ui-sessions-unmark-all)
        (". t" "Invert marks" harness-ui-sessions-toggle-marks)]
       ["List"
        (". /" "Filter" harness-ui-sessions-filter)
        (". a" "This project or all" harness-ui-sessions-toggle-scope)
        (". b" "Only those waiting for you" harness-ui-sessions-toggle-blocked)
        (". i" "Show or hide inactive" harness-ui-sessions-toggle-inactive)
        (". T" "Only the tasks' sessions" harness-ui-sessions-toggle-tasks-only)
        (". I" "Show or hide internal sessions" harness-ui-sessions-toggle-internal)
        (". P" "Pause or resume live updates" harness-ui-sessions-toggle-pause)
        (". C" "Show or hide a column" harness-ui-sessions-toggle-column)
        (". F" "Fullscreen layout" harness-fullscreen)
        (". g" "Reload" harness-ui-sessions-reload)]))

(defun harness-ui-sessions--overview-session ()
  "Return the session to show beside the list in the fullscreen layout.
That is the session at point, else the most recently updated session
listed, BTW conversations and the kinds of `harness-ui-sessions-hidden-kinds'
aside, even when the list shows them: they are not conversations to read."
  (or (and (derived-mode-p 'harness-ui-sessions-mode) (tabulated-list-get-id))
      (let (best newest)
        (dolist (entry (and (listp tabulated-list-entries) tabulated-list-entries) best)
          (let* ((session (harness-ui-session (car entry)))
                 (updated (or (plist-get session :updated) 0)))
            (when (and session (not (equal (plist-get session :kind) "btw"))
                       (not (harness-ui-sessions--hidden-kind-p session))
                       (or (null best) (> updated newest)))
              (setq best (car entry) newest updated)))))))

(defconst harness-ui-sessions--cost-factor 4
  "How many times as long as a redraw took the list waits to follow again.
A redraw that takes a tenth of a second is followed by at least four
tenths in which Emacs reads its keys and draws its frames, so the list
never takes more than a fifth of Emacs's time however many rows it has
and however fast the sessions change (`harness-ui-sessions--redraw-live').")

(defvar-local harness-ui-sessions--due 0.0
  "The time, as `float-time' has it, before which the list follows no change.
Set by every redraw to its end plus `harness-ui-sessions--cost-factor'
times what it took, wall clock, the collection of garbage it caused
included.")

(defun harness-ui-sessions--redraw ()
  "Redraw the list buffer if it exists, keeping point on the same session.
Each window showing the list keeps its point on its session too; one
whose session is gone goes to the first row.  How long it took sets how
soon the list follows the sessions again (`harness-ui-sessions--due')."
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (let ((id (harness-ui-sessions--place))
            (windows (mapcar (lambda (w) (cons w (harness-ui-sessions--place (window-point w))))
                             (get-buffer-window-list buf nil t)))
            (start (float-time)))
        (harness-ui-sessions--refresh)
        (harness-ui-sessions--print)
        (goto-char (harness-ui-sessions--position id))
        (pcase-dolist (`(,window . ,at) windows)
          (unless (eq window (selected-window))
            (set-window-point window (harness-ui-sessions--position at))))
        (harness-ui-view-drawn)
        (let ((end (float-time)))
          (setq harness-ui-sessions--due
                (+ end (* harness-ui-sessions--cost-factor (- end start)))))))))

;;;; Following the sessions, and pausing that
;;
;; The list redraws by itself as the harness reports changes: sessions,
;; output rates, token figures that grow, requests answered, a reload.
;; Those paths redraw through `harness-ui-sessions--redraw-live', which
;; leaves a paused list as it is, and a list no window shows: it notes
;; what it missed and draws once when a window shows it again
;; (`harness-ui-view-install').  Drawn from timers on the one thread that
;; reads the keys, a list of a thousand rows that nobody looked at took
;; Emacs's time almost whole.  What the user asks of the list -- a filter,
;; a toggle, `g' -- calls `harness-ui-sessions--redraw' and redraws a
;; paused or hidden list too.

(defun harness-ui-sessions--paused-p ()
  "Non-nil when the list exists and is paused.
The flag is the list buffer's own, so it is read there, whichever buffer
is current: the hooks that follow the sessions run in any."
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (buffer-local-value 'harness-ui-sessions--paused buf)))

(defun harness-ui-sessions--following-p ()
  "Non-nil when the list should follow the sessions now.
That is when it exists, is not paused and a window shows it.  A list no
window shows is left as it is and notes that it missed the change
\(`harness-ui-view-follow-p'): `harness-ui-sessions--catch-up' draws it
when a window shows it again.  A paused list holds still, shown or not."
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (and (not (buffer-local-value 'harness-ui-sessions--paused buf))
         (harness-ui-view-follow-p buf))))

(defconst harness-ui-sessions--live-interval 0.5
  "Least seconds between two redraws of the list for growing token figures.")

(defvar harness-ui-sessions--live-timer nil
  "Timer of the redraw the list is waiting for, or nil.
The growing token figures start it (`harness-ui-sessions--on-live'), and
so does a redraw that came before `harness-ui-sessions--due'.")

(defun harness-ui-sessions--catch-up ()
  "Draw the list for what it missed while no window showed it, unless it is paused.
Called when a window shows it again (`harness-ui-view-install').  A
paused list holds still: resuming it draws it."
  (unless harness-ui-sessions--paused
    (harness-ui-sessions--redraw)))

(defun harness-ui-sessions--redraw-live ()
  "Redraw the list for a change that came by itself, if it should follow it.
Not while it is paused or no window shows it
\(`harness-ui-sessions--following-p')."
  (when (harness-ui-sessions--following-p)
    (harness-ui-sessions--redraw)))

(defun harness-ui-sessions--redraw-spaced ()
  "Redraw the list for a change among those that come all the time.
As `harness-ui-sessions--redraw-live', but not before
`harness-ui-sessions--due': a redraw that came too soon after one that
took long waits for a timer, one at a time, and draws everything that
changed meanwhile."
  (when (harness-ui-sessions--following-p)
    (let ((wait (- (buffer-local-value 'harness-ui-sessions--due
                                       (get-buffer harness-ui-sessions--buffer-name))
                   (float-time))))
      (cond ((<= wait 0) (harness-ui-sessions--redraw))
            ((not (timerp harness-ui-sessions--live-timer))
             (setq harness-ui-sessions--live-timer
                   (run-at-time wait nil #'harness-ui-sessions--live-redraw)))))))

(defun harness-ui-sessions--on-changed ()
  "Redraw the list shortly, once for a burst of changes.
A paused list is not redrawn, nor one no window shows
\(`harness-ui-sessions--following-p'), and no redraw is scheduled for
either."
  (when (harness-ui-sessions--following-p)
    (harness-debounce 'harness-ui-sessions 0.15 #'harness-ui-sessions--redraw-spaced)))

(defun harness-ui-sessions--on-rate (_id _rate)
  "Redraw the list, whose average rates name the current output rate on hover.
A paused list is not redrawn, nor one no window shows."
  (when (get-buffer harness-ui-sessions--buffer-name)
    (harness-ui-sessions--on-changed)))

(defun harness-ui-sessions--tokens-shown-p (id)
  "Non-nil when the list shows session ID's token figures as they are.
That is when its Context and Output cells read as they would now, or
the list does not show the session at all.  Only the cells the list
shows count: with both hidden there is nothing to redraw for."
  (with-current-buffer harness-ui-sessions--buffer-name
    (let ((entry (cadr (assoc id (and (listp tabulated-list-entries) tabulated-list-entries))))
          (session (harness-ui-session id)))
      (or (not (and entry session))
          (cl-every (lambda (name)
                      (let ((at (cl-position name tabulated-list-format :key #'car :test #'equal)))
                        (or (null at)
                            (equal (substring-no-properties (aref entry at))
                                   (substring-no-properties
                                    (funcall (plist-get (harness-ui-sessions-column name) :cell)
                                             session 0))))))
                    '("Context" "Output"))))))

(defun harness-ui-sessions--live-redraw ()
  "Redraw the list for the token figures that grew, unless it is paused or hidden.
The timer of `harness-ui-sessions--live-timer' runs this."
  (setq harness-ui-sessions--live-timer nil)
  (harness-ui-sessions--redraw-spaced))

(defun harness-ui-sessions--on-live (id _live)
  "Redraw the list soon if session ID's token figures read otherwise now.
They grow a few times a second while its turn streams; the list redraws
for them at most every `harness-ui-sessions--live-interval' seconds, all
the sessions that grew meanwhile at once.  ID nil, after every session's
figures were fetched again, redraws it as well.  A paused list is not
redrawn, nor one no window shows (`harness-ui-sessions--following-p'),
and no redraw is scheduled for either."
  (when (and (get-buffer harness-ui-sessions--buffer-name)
             (not (timerp harness-ui-sessions--live-timer))
             (harness-ui-sessions--following-p)
             (or (null id) (not (harness-ui-sessions--tokens-shown-p id))))
    (setq harness-ui-sessions--live-timer
          (run-at-time harness-ui-sessions--live-interval nil #'harness-ui-sessions--live-redraw))))

;;;; Tasks

(defun harness-ui-sessions--fetch-tasks (&optional force)
  "Ask the harness for every project's tasks, then redraw the list.
The list keeps those that have a session, by session.  When the request
fails, as on a harness without tasks, the list names no task.  A paused
list keeps them too but is redrawn only when FORCE: the user asked for
the tasks by opening the list or reloading it, where the hook that asks
after a reload or reconnect leaves the list as it is."
  (when (get-buffer harness-ui-sessions--buffer-name)
    (cl-flet ((keep (table)
                (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
                  (with-current-buffer buf (setq harness-ui-sessions--tasks table))
                  (if force
                      (harness-ui-sessions--redraw)
                    (harness-ui-sessions--redraw-live)))))
      (harness-ui-call
       "_harness/task/list" nil
       (lambda (tasks)
         (let ((table (make-hash-table :test 'equal)))
           (dolist (task tasks)
             (when-let* ((sid (plist-get task :session)))
               (puthash sid task table)))
           (keep table)))
       (lambda (_) (keep nil))))))

(defun harness-ui-sessions--forget-task (id)
  "Drop task ID from the list's tasks."
  (when harness-ui-sessions--tasks
    (maphash (lambda (sid task)
               (when (equal (plist-get task :id) id) (remhash sid harness-ui-sessions--tasks)))
             harness-ui-sessions--tasks)))

(defun harness-ui-sessions--on-event (event args)
  "Follow the tasks in the list: `task/changed' (TASK) and `task/deleted' (ID).
EVENT names a harness event and ARGS are its arguments, as
`harness-ui-event-functions' gets them.  A task changes session when it
starts, so it is looked up by its id."
  (when-let* ((buf (and (member event '("task/changed" "task/deleted"))
                        (get-buffer harness-ui-sessions--buffer-name))))
    (with-current-buffer buf
      (pcase event
        ("task/deleted" (harness-ui-sessions--forget-task (car args)))
        (_ (let ((task (car args)))
             (harness-ui-sessions--forget-task (plist-get task :id))
             (when-let* ((sid (plist-get task :session)))
               (puthash sid task (or harness-ui-sessions--tasks
                                     (setq harness-ui-sessions--tasks (make-hash-table :test 'equal)))))))))
    (harness-ui-sessions--on-changed)))

;;;###autoload
(defun harness-sessions (&optional all-projects position blocked-only)
  "Show the session list, scoped to the current project unless ALL-PROJECTS.
The project includes its git worktrees, so its tasks' sessions are
listed, and from a task's worktree the list shows the whole project.
A task's session shows its task's title until it is named.

The list shows in POSITION, by default where it was last
\(`harness-ui-display-view').  In the `fullscreen' position it stays on
the left of the frame and the sessions open beside it (see
`harness-fullscreen'): F on the list starts or ends that layout.

With BLOCKED-ONLY it shows only the sessions waiting for you, as
`harness-sessions-waiting' does; b on the list turns that on or off."
  (interactive "P")
  (let ((project (unless all-projects
                   (harness-files-main-root default-directory)))
        (buf (get-buffer-create harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-sessions-mode) (harness-ui-sessions-mode))
      (setq harness-ui-sessions--project project
            harness-ui-sessions--blocked-only blocked-only)
      (let ((id (tabulated-list-get-id)))
        (harness-ui-sessions--refresh)
        (harness-ui-sessions--print)
        (goto-char (harness-ui-sessions--position id))
        (harness-ui-view-drawn)))
    (harness-ui-refresh-sessions (lambda (_) (harness-ui-sessions--redraw)))
    (harness-ui-sessions--fetch-tasks t)
    (harness-ui-display-view buf position)))

;;;###autoload
(defun harness-sessions-waiting (&optional position)
  "Show the sessions waiting for you, in every project.
That is the session list (`harness-sessions') with only the blocked
sessions in it, as clicking the mode line's notifier shows it.  Under
each, what it waits on, with buttons to answer it right there: [Allow]
and [Deny] for a permission request, [Answer…] for a question.  RET
opens a session in its project (`harness-ui-sessions-open'); b, or the
banner's \[Show all], shows every session again.  The list shows in
POSITION, as `harness-sessions' has it; in a frame with the fullscreen
layout it shows beside the anchor, in the slot, instead of taking the
anchor's place."
  (interactive)
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    ;; Every waiting session, whatever the list was filtered by before.
    (with-current-buffer buf (setq harness-ui-sessions--filter "")))
  (harness-sessions t (or position
                          (and (harness-ui--fullscreen-layout) 'slot))
                    t))

(defun harness-ui-sessions--id ()
  "Return the id of the session on this line, or signal a user error."
  (or (tabulated-list-get-id) (user-error "No session on this line")))

;;;; Marks
;;
;; Sessions are marked as files are in Dired.  The marks are session ids
;; in a table kept apart from the rows (`harness-ui-sessions--marked'),
;; so a redraw, a filter, a change of scope or the pause leaves them as
;; they are, and a marked session the filters hide stays marked.  The
;; helpers below (`harness-ui-sessions--mark' and the others) change the
;; table only.  The commands m, u, DEL, U and t change it and then the
;; rows, in place and the tag of a row at a time
;; (`tabulated-list-put-tag'), with no redraw: a paused list shows a mark
;; as it is made.  The commands that act on sessions ask
;; `harness-ui-sessions--targets' which: the marked ones, or the one at
;; point when none is marked.

(defun harness-ui-sessions--marked-p (id)
  "Return non-nil when session ID is marked in this list.
A session the filters hide can be marked: its mark stays."
  (and harness-ui-sessions--marked (gethash id harness-ui-sessions--marked) t))

(defun harness-ui-sessions--mark (id)
  "Mark session ID in this list, whether or not the list shows it.
This changes the table of marks only; `harness-ui-sessions--show-marks'
shows the change in the rows.  The mark stays through the filters."
  (puthash id t (or harness-ui-sessions--marked
                    (setq harness-ui-sessions--marked (make-hash-table :test 'equal)))))

(defun harness-ui-sessions--unmark (id)
  "Unmark session ID in this list, whether or not the list shows it.
This changes the table of marks only; `harness-ui-sessions--show-marks'
shows the change in the rows."
  (when harness-ui-sessions--marked
    (remhash id harness-ui-sessions--marked)))

(defun harness-ui-sessions--unmark-all ()
  "Unmark every session, those the filters hide too; return how many were marked.
That counts the marked sessions the session cache still has
\(`harness-ui-sessions--marked-ids').  This changes the table of marks
only; `harness-ui-sessions--show-marks' shows the change in the rows."
  (prog1 (length (harness-ui-sessions--marked-ids))
    (when harness-ui-sessions--marked
      (clrhash harness-ui-sessions--marked))))

(defun harness-ui-sessions--marked-ids ()
  "Return the ids of the marked sessions the session cache still has.
The order is fixed, so what acts on them does so the same way each time:
first the sessions the list shows, in the order its rows are listed,
then the marked ones the filters hide, which stay marked, newest first
and by id among those updated at the same time.  Nil when nothing is
marked."
  (when (and harness-ui-sessions--marked
             (> (hash-table-count harness-ui-sessions--marked) 0))
    (let ((listed nil)
          (seen (make-hash-table :test 'equal))
          (hidden nil))
      (dolist (entry (and (listp tabulated-list-entries) tabulated-list-entries))
        (let ((id (car entry)))
          (when (and (gethash id harness-ui-sessions--marked) (harness-ui-session id))
            (puthash id t seen)
            (push id listed))))
      (maphash (lambda (id _)
                 (when (and (not (gethash id seen)) (harness-ui-session id))
                   (push id hidden)))
               harness-ui-sessions--marked)
      (cl-flet ((updated (id) (or (plist-get (harness-ui-session id) :updated) 0)))
        (nconc (nreverse listed)
               (sort hidden (lambda (a b)
                              (if (= (updated a) (updated b))
                                  (string< a b)
                                (> (updated a) (updated b))))))))))

(defun harness-ui-sessions--marked-count ()
  "Return how many sessions are marked, those the filters hide included.
Only sessions the session cache has count, as for
`harness-ui-sessions--marked-ids', but without ordering them."
  (let ((count 0))
    (when harness-ui-sessions--marked
      (maphash (lambda (id _) (when (harness-ui-session id) (cl-incf count)))
               harness-ui-sessions--marked))
    count))

(defun harness-ui-sessions--drop-gone-marks ()
  "Unmark the sessions the session cache no longer has, listed or not.
Their marks would count in the mode line and act on nothing.
`harness-ui-sessions--refresh' does it at each refresh."
  (when harness-ui-sessions--marked
    (let (gone)
      (maphash (lambda (id _) (unless (harness-ui-session id) (push id gone)))
               harness-ui-sessions--marked)
      (dolist (id gone) (remhash id harness-ui-sessions--marked)))))

(defun harness-ui-sessions--targets ()
  "Return the ids of the sessions a command acts on.
Those are the marked sessions (`harness-ui-sessions--marked-ids'), a
marked session the filters hide among them, else the session at point
alone.  With no mark and no session on the line, signal a user error."
  (or (harness-ui-sessions--marked-ids)
      (list (harness-ui-sessions--id))))

(defun harness-ui-sessions--one-id (what)
  "Return the id of the session at point, for the command WHAT names.
WHAT, as \"Fork\", is a command that acts on one session.  While any
session is marked it signals a user error instead: the marks ask for the
marked sessions, and acting on the one at point would ignore them.  U
unmarks them."
  (when-let* ((marked (harness-ui-sessions--marked-ids)))
    (if (cdr marked)
        (user-error "%s acts on one session, but %d are marked: unmark them first (U)"
                    what (length marked))
      (user-error "%s acts on one session, but one is marked: unmark it first (U)" what)))
  (harness-ui-sessions--id))

(defun harness-ui-sessions--label (id)
  "Return what to call session ID in a question or a message.
That is the name the list shows for it, a task's session called by its
task's title, else the start of its id."
  (or (harness-ui-sessions--name (harness-ui-session id))
      (substring id 0 (min 8 (length id)))))

(defun harness-ui-sessions--update-mode-line ()
  "Set the list's mode line again, as marks changed what it counts."
  (setq mode-line-process (harness-ui-sessions--mode-line))
  (force-mode-line-update))

(defun harness-ui-sessions--row-start ()
  "Move point to the start of the row it is on.
A blocked session's row has a second line, saying what the session
waits on, which carries the same id; this goes to the first, which has
the cells and the tag."
  (beginning-of-line)
  (let ((id (tabulated-list-get-id)))
    (while (and id (not (bobp))
                (equal id (tabulated-list-get-id (1- (point)))))
      (forward-line -1))))

(defun harness-ui-sessions--put-tag (marked)
  "Show on the row point is on whether its session is MARKED.
The tag of the row's padding is changed in place, with no redraw, when
it does not say so already.  A row that is not marked is left as a fresh
row is: the mark's face does not stay on the padding."
  (save-excursion
    (harness-ui-sessions--row-start)
    (when (xor marked (eq (char-after) ?*))
      (let ((inhibit-read-only t))
        (tabulated-list-put-tag
         (if marked (propertize "*" 'face 'harness-ui-sessions-mark-face) " "))
        (unless marked
          (remove-text-properties (point) (+ (point) tabulated-list-padding)
                                  '(face nil)))
        (set-buffer-modified-p nil)))))

(defun harness-ui-sessions--show-marks ()
  "Make every row of the list show whether its session is marked.
The rows are changed in place, with no redraw, and the mode line counts
the marks again.  Point stays where it is."
  (save-excursion
    (goto-char (point-min))
    (let ((previous nil))
      (while (not (eobp))
        (let ((id (tabulated-list-get-id)))
          ;; The line under a blocked session's row has the row's id too.
          (when (and id (not (equal id previous)))
            (harness-ui-sessions--put-tag (harness-ui-sessions--marked-p id)))
          (setq previous id))
        (forward-line 1))))
  (harness-ui-sessions--update-mode-line))

(defun harness-ui-sessions--forward-row (column)
  "Move point to COLUMN of the next row; return nil at the last row.
The line under a blocked session's row is the row's own, not the next
row: it carries the same id, which the next row does not.  At the last
row point stays where it is."
  (let ((id (tabulated-list-get-id))
        (start (point)))
    (forward-line 1)
    (while (and (not (eobp)) (equal (tabulated-list-get-id) id))
      (forward-line 1))
    (if (tabulated-list-get-id)
        (progn (move-to-column column) t)
      (goto-char start)
      nil)))

(defun harness-ui-sessions--backward-row (column)
  "Move point to COLUMN of the previous row; return nil at the first row.
At the first row point stays where it is."
  (let ((start (point)))
    (harness-ui-sessions--row-start)
    (if (bobp)
        (progn (goto-char start) nil)
      (forward-line -1)
      (if (tabulated-list-get-id)
          (progn (harness-ui-sessions--row-start) (move-to-column column) t)
        (goto-char start)
        nil))))

(defun harness-ui-sessions--mark-rows (count marked)
  "Mark COUNT rows from the one at point, or with MARKED nil unmark them.
As in Dired, each row is changed and point moves on to the next, so it
ends after the last row changed.  A negative COUNT goes up: point moves
to the row above before each change.  When the rows run out point stays
on the last.  Signal a user error when the line has no session."
  (harness-ui-sessions--id)
  (let ((column (current-column)))
    (cl-flet ((change ()
                (let ((id (tabulated-list-get-id)))
                  (if marked (harness-ui-sessions--mark id) (harness-ui-sessions--unmark id))
                  (harness-ui-sessions--put-tag marked))))
      (if (>= count 0)
          (cl-loop repeat count
                   do (change)
                   while (harness-ui-sessions--forward-row column))
        (cl-loop repeat (- count)
                 while (harness-ui-sessions--backward-row column)
                 do (change)))))
  (harness-ui-sessions--update-mode-line))

(defun harness-ui-sessions-mark (&optional count)
  "Mark the session at point and move to the next row.
With a numeric prefix argument COUNT, mark that many rows; a negative
COUNT marks the rows above point, as Dired does.  The mark shows in
place of the padding space of the row, and the commands that act on
sessions act on every marked one.  A session the filters hide stays
marked; U unmarks all."
  (interactive "p")
  (harness-ui-sessions--mark-rows (or count 1) t))

(defun harness-ui-sessions-unmark (&optional count)
  "Unmark the session at point and move to the next row.
With a numeric prefix argument COUNT, unmark that many rows; a negative
COUNT unmarks the rows above point, as Dired does."
  (interactive "p")
  (harness-ui-sessions--mark-rows (or count 1) nil))

(defun harness-ui-sessions-unmark-backward (&optional count)
  "Move up a row and unmark the session there.
With a numeric prefix argument COUNT unmark that many rows going up."
  (interactive "p")
  (harness-ui-sessions--mark-rows (- (or count 1)) nil))

(defun harness-ui-sessions-unmark-all ()
  "Unmark every session, the ones the filters hide too, and say how many."
  (interactive)
  (let ((unmarked (harness-ui-sessions--unmark-all)))
    (harness-ui-sessions--show-marks)
    (if (zerop unmarked)
        (message "No session was marked")
      (message "Unmarked %s" (harness-ui--count unmarked "session")))))

(defun harness-ui-sessions-toggle-marks ()
  "Invert the marks of the rows the list shows now.
A marked session becomes unmarked and an unmarked one marked.  The marks
of sessions the filters hide stay as they are."
  (interactive)
  (dolist (entry (and (listp tabulated-list-entries) tabulated-list-entries))
    (let ((id (car entry)))
      (when (harness-ui-session id)
        (if (harness-ui-sessions--marked-p id)
            (harness-ui-sessions--unmark id)
          (harness-ui-sessions--mark id)))))
  (harness-ui-sessions--show-marks))

;;;; The harness's setting commands
;;
;; The commands that change a session's settings (`harness-set-model',
;; `harness-set-thinking', `harness-set-permission-mode',
;; `harness-toggle-non-interactive' and `harness-toggle-supervisor') ask
;; the buffer what they change (`harness-ui-setting-target-function'),
;; and the list answers with `harness-ui-sessions--setting-target'.  With
;; no session marked that is the session at point, which they change as
;; they do in its chat, a model switch checking that the conversation is
;; not lost included.  With sessions marked it is (VALUES SET-FN CONTEXT):
;; VALUES holds the settings the marked sessions agree on, which the
;; commands offer as current, SET-FN applies a setting to all of them and
;; CONTEXT names them in the message.  `harness-ui-sessions--set-marked'
;; asks the harness for the sessions first and then, for those that work
;; on a task, for the tasks, so that each task's record keeps the setting
;; for its next start.  The marks stay.

(defconst harness-ui-sessions--setting-keys
  '(:model :thinking :permission-mode :non-interactive :supervisor)
  "The session settings the harness's setting commands change.
`harness-ui-sessions--marked-values' reads each of them from the marked
sessions.")

(defun harness-ui-sessions--setting-value (session key)
  "Return the value of the setting KEY in SESSION, a session plist.
The supervisor mode is the `:supervisor' of the session's `:ext', the
plist the modules keep what they remember about a session in: t while it
supervises, `:false' once that was turned off, and nil for a session the
supervisor module does not govern."
  (if (eq key :supervisor)
      (plist-get (plist-get session :ext) :supervisor)
    (plist-get session key)))

(defun harness-ui-sessions--marked-values (ids)
  "Return the settings the sessions IDS agree on, as a plist.
Each of `harness-ui-sessions--setting-keys' is in it with the value all
those sessions have; a setting on which they differ is left out, as if
it had no value.  The setting commands read it as the current values
\(`harness-ui--setting-get')."
  (let ((sessions (delq nil (mapcar #'harness-ui-session ids)))
        (agreed nil))
    (when sessions
      (dolist (key harness-ui-sessions--setting-keys)
        (let ((common (harness-ui-sessions--setting-value (car sessions) key)))
          (when (cl-every (lambda (s)
                            (harness-setting-equal-p
                             key common (harness-ui-sessions--setting-value s key)))
                          (cdr sessions))
            (setq agreed (append agreed (list key common)))))))
    agreed))

(defun harness-ui-sessions--setting-target ()
  "Return what the harness's setting commands change in this list.
That is the list's `harness-ui-setting-target-function'.  While any
session is marked it is (VALUES SET-FN CONTEXT) for the marked sessions,
those the filters hide too: VALUES holds the settings they agree on
\(`harness-ui-sessions--marked-values'), SET-FN is
`harness-ui-sessions--set-marked' and CONTEXT says \"for the 3 marked
sessions\".  Otherwise it is the id of the session at point, which the
commands change as in its chat, and nil when point is on no session, so
that they ask which."
  (if-let* ((ids (harness-ui-sessions--marked-ids)))
      (list (harness-ui-sessions--marked-values ids)
            #'harness-ui-sessions--set-marked
            (if (cdr ids)
                (format "for the %d marked sessions" (length ids))
              "for the marked session"))
    (tabulated-list-get-id)))

(defun harness-ui-sessions--wire-value (key value)
  "Return VALUE of the setting KEY as a request carries it.
The switches, non-interactive mode and supervisor mode, go as `:false'
when they are off: nil would be no value at all."
  (if (and (memq key '(:non-interactive :supervisor)) (not value))
      :false
    value))

(defun harness-ui-sessions--marked-and-tasks ()
  "Return (IDS . TASKS): the marked sessions, and the tasks they work on.
IDS are those of `harness-ui-sessions--marked-ids'.  TASKS are the ids of
the tasks of the marked sessions that work on one, each once, in the
order of IDS.  Both are read in the list, whichever buffer is current:
the list holds the marks and knows the tasks.  Nil without a list."
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (let ((ids (harness-ui-sessions--marked-ids)))
        (cons ids
              (delete-dups
               (delq nil (mapcar (lambda (id)
                                   (plist-get (harness-ui-sessions--task (harness-ui-session id)) :id))
                                 ids))))))))

(defun harness-ui-sessions--setting-text (key value)
  "Return what the setting KEY becomes with VALUE, as the commands say it.
That is \"Thinking → high\", \"Non-interactive on\" and the like; a model
is shown by its label and a permission mode by its name."
  (pcase key
    (:model (format "Model → %s" (harness-ui-model-label value)))
    (:thinking (format "Thinking → %s" (or value "default")))
    (:permission-mode (format "Permission mode → %s" (harness-ui-permission-mode-label value)))
    (:non-interactive (format "Non-interactive %s" (if (harness-json-true-p value) "on" "off")))
    (:supervisor (if (harness-json-true-p value)
                     "Supervisor mode on"
                   "Supervisor mode off (hands-on)"))
    (_ (format "%s → %s" (string-remove-prefix ":" (symbol-name key)) value))))

(defun harness-ui-sessions--count-ids (result)
  "Return how many ids RESULT, the answer to a request for many, lists."
  (if (listp result) (length result) 0))

(defun harness-ui-sessions--handoff-how (mode)
  "Return how a model switch handed conversations over by MODE, as a clause.
That is the clause `harness-set-model-all' says it with, and nil for the
mode `none', which hands nothing over."
  (pcase mode
    ('compact ", summarising the conversations that need it first")
    ('compact-new ", letting the new model summarise a limited context where needed")
    ('transcript ", handing the transcripts over where needed")))

(defun harness-ui-sessions--set-text (what total sessions tasks &optional how)
  "Return what to say once WHAT, a change of setting, is made.
WHAT is as `harness-ui-sessions--setting-text' words it.  The change
was asked for TOTAL marked sessions; the harness changed SESSIONS of
them, the others having it already, and TASKS of their tasks (both are
counts).  HOW, when non-nil, is a clause on how a model switch handed
conversations over, which follows the sessions."
  (let ((on-sessions (cond ((zerop sessions) nil)
                           ((= sessions total)
                            (format "for %s%s" (harness-ui--count total "session") (or how "")))
                           (t (format "for %d of %s%s" sessions (harness-ui--count total "session")
                                      (or how "")))))
        (on-tasks (and (> tasks 0) (format "(%s)" (harness-ui--count tasks "task")))))
    (if (or on-sessions on-tasks)
        (string-join (delq nil (list what on-sessions on-tasks)) " ")
      (format "%s: nothing to change in the %s" what
              (if (= total 1) "marked session" (format "%d marked sessions" total))))))

(defun harness-ui-sessions--set-failed (what err)
  "Say that the change WHAT failed with the error ERR; return nil.
WHAT is as `harness-ui-sessions--setting-text' words it.  An error of a
connection the UI replaced on purpose is no failure
\(`harness-ui-connection-replaced-p')."
  (unless (harness-ui-connection-replaced-p err)
    (message "%s failed: %s" what (harness-error-message err)))
  nil)

(defun harness-ui-sessions--set-tasks (settings tasks what total changed how)
  "Give the tasks TASKS the SETTINGS, then say how the change WHAT went.
SETTINGS is the plist `_harness/task/set-all' takes; TASKS are the task
ids, which may be of several projects, and the request names no project.
It skips the tasks that are in review, done or archived, and the ones
that have the setting already.  TOTAL is how many sessions were marked
and CHANGED how many of them the harness changed; HOW is a clause on
how a model switch handed conversations over, or nil
\(`harness-ui-sessions--set-text').  With no task there is no request,
and the message says the sessions.  A request that fails says why,
after what the sessions got."
  (if (null tasks)
      (message "%s" (harness-ui-sessions--set-text what total changed 0 how))
    (harness-ui-call
     "_harness/task/set-all" (list :settings settings :filter (list :ids tasks))
     (lambda (done)
       (message "%s" (harness-ui-sessions--set-text
                      what total changed (harness-ui-sessions--count-ids done) how)))
     (lambda (err)
       (unless (harness-ui-connection-replaced-p err)
         (message "%s, but the tasks' settings did not change: %s"
                  (harness-ui-sessions--set-text what total changed 0 how)
                  (harness-error-message err)))
       nil))))

(defun harness-ui-sessions--switch-marked (model ids done failed)
  "Switch the sessions IDS to MODEL, asking first if that loses conversations.
This is `harness-set-model-all' for these sessions, and for them only:
the default model and the settings of the task boards stay as they are.
The harness checks the switch (`_harness/handoff/check-all').  When no
session would lose its conversation, they switch at once
\(`_harness/session/set-all').  Otherwise `harness-ui-switch-function'
asks once, for all of them, how to carry the conversations over -- the
panel of harness-ui-carry.el above the rows of the list -- and the
switch goes by the mode chosen (`_harness/handoff/switch-all'); the
answer `cancel' switches nothing.  A harness that cannot check switches
them as it always did.  DONE is called with the ids of the sessions that
switched and, when the conversations were handed over, the clause that
says how (`harness-ui-sessions--handoff-how'); FAILED is called with the
error of a request that failed."
  (let ((filter (list :ids ids))
        (label (harness-ui-model-label model))
        ;; The question is asked in the list, above the rows.
        (host (get-buffer harness-ui-sessions--buffer-name)))
    (cl-flet ((plain ()
                (harness-ui-call "_harness/session/set-all"
                                 (list :settings (list :model model) :filter filter)
                                 done failed)))
      (harness-ui-call
       "_harness/handoff/check-all" (list :model model :filter filter)
       (lambda (checks)
         (let ((lossy (cl-remove-if-not (lambda (c) (harness-json-true-p (plist-get c :lossy)))
                                        checks)))
           (if (null lossy)
               (plain)
             (funcall harness-ui-switch-function
                      lossy label (length checks) nil host
                      (lambda (mode)
                        (if (eq mode 'cancel)
                            (message "Models unchanged")
                          (harness-ui-call "_harness/handoff/switch-all"
                                           (list :model model :filter filter
                                                 :mode (symbol-name mode))
                                           (lambda (switched)
                                             (funcall done switched
                                                      (harness-ui-sessions--handoff-how mode)))
                                           failed)))))))
       (lambda (_err) (plain) nil)))))

(defun harness-ui-sessions--set-marked (key value)
  "Set the session setting KEY to VALUE on the marked sessions and their tasks.
This is the SET-FN of `harness-ui-sessions--setting-target' for marked
sessions, which the setting commands call.  The marked sessions are read
in the list when this runs, whichever buffer is current, and stay marked.
The harness is asked once for the sessions: `_harness/session/set-all'
with their ids as the filter, and `_harness/supervisor/set-all' for
the supervisor mode; a model goes by `harness-ui-sessions--switch-marked',
which asks first when a conversation would be lost.  A switch that is off
goes as `:false'.  Then, for the marked sessions that work on a task, one
`_harness/task/set-all' sets the same for those tasks of every project,
so each task starts again with it.  One message says how many sessions
and tasks changed, and a request that fails says why."
  (pcase-let ((`(,ids . ,tasks) (harness-ui-sessions--marked-and-tasks)))
    (if (null ids)
        (message "No session is marked")
      (let* ((what (harness-ui-sessions--setting-text key value))
             (wire (harness-ui-sessions--wire-value key value))
             (filter (list :ids ids))
             (failed (lambda (err) (harness-ui-sessions--set-failed what err)))
             (done (lambda (changed &optional how)
                     (harness-ui-sessions--set-tasks
                      (list key wire) tasks what (length ids)
                      (harness-ui-sessions--count-ids changed) how))))
        (pcase key
          (:model (harness-ui-sessions--switch-marked value ids done failed))
          (:supervisor (harness-ui-call "_harness/supervisor/set-all"
                                        (list :on wire :filter filter) done failed))
          (_ (harness-ui-call "_harness/session/set-all"
                              (list :settings (list key wire) :filter filter)
                              done failed)))))))

;;;; The commands on sessions
;;
;; The commands that act on sessions act on every marked session, or on
;; the one at point when none is marked (`harness-ui-sessions--targets').
;; Those that go to the harness send their requests together and finish
;; once, when the last is answered: the sessions acted on are unmarked,
;; the list redrawn and one message said.  f, r and M act on one session
;; and refuse while any is marked (`harness-ui-sessions--one-id').

(defun harness-ui-sessions--unmark-and-redraw (ids)
  "Unmark the sessions IDS, which a command acted on, and redraw the list once.
This works from any buffer, as a request answered does."
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (dolist (id ids) (harness-ui-sessions--unmark id))))
  (harness-ui-sessions--redraw))

(defun harness-ui-sessions--request-each (method key ids on-success done)
  "Send METHOD for each of IDS, as the request (KEY ID), then call DONE once.
ON-SUCCESS, when non-nil, is called with the id of each request the
harness answers, as it is answered.  A request that fails says so in the
echo area, as `harness-ui-call' has it, and is left out.  DONE is called
when the last request is settled, with the ids of those that succeeded,
in the order of IDS."
  (harness-then
   (harness-all
    (mapcar (lambda (id)
              (harness-ui-call method (list key id)
                               (lambda (_)
                                 (when on-success (funcall on-success id))
                                 id)))
            ids))
   (lambda (results) (funcall done (delq nil results)))))

(defun harness-ui-sessions-open (&optional position)
  "Open the session at point, in its project.
The session's project becomes the current one first, as switching
project does (in Doom Emacs, its workspace, as you left it; see
`harness-ui-switch-project-function').  A session shown there already
gets its window selected; any other opens in POSITION, by default
replacing the list, or after a switch where sessions open -- in the
window of a workspace that shows nothing yet, a new one."
  (interactive (list (and current-prefix-arg (harness-ui-read-position))))
  (harness-ui-visit-session (harness-ui-sessions--id) position))

(defun harness-ui-sessions-open-other ()
  "Open the session at point in the other position preset."
  (interactive)
  (harness-ui-sessions-open (harness-ui-read-position)))

(defun harness-ui-sessions-mouse-open (event)
  "Open the session clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-sessions-open))

(defun harness-ui-sessions-fork ()
  "Fork the session at point.
It acts on one session, so it refuses while any session is marked."
  (interactive)
  (harness-fork-session (harness-ui-sessions--one-id "Fork")))

(defun harness-ui-sessions--delete-question (ids)
  "Return the question to ask before deleting the sessions IDS.
One session is named, as `harness-delete-session' names it; several are
counted, with how many of them the list does not show, as the filters
hide marked sessions."
  (if (cdr ids)
      (let ((hidden (cl-count-if-not (lambda (id) (assoc id tabulated-list-entries)) ids)))
        (format "Delete %d marked sessions%s? " (length ids)
                (if (> hidden 0) (format ", %d of them not listed" hidden) "")))
    (format "Delete session %s? " (harness-ui-sessions--label (car ids)))))

(defun harness-ui-sessions-delete ()
  "Delete the marked sessions, else the session at point, after one question.
The question names the session, or counts the marked ones and says how
many of them the list does not show.  Each session goes by
`_harness/session/delete' and leaves the session cache as its request is
answered, as in `harness-delete-session', which is not called here as it
would ask again for each.  Once the last request is answered the sessions
deleted are unmarked, the list is redrawn and one message says how many
went.  A session that could not be deleted says so and keeps its mark."
  (interactive)
  (let ((ids (harness-ui-sessions--targets)))
    (when (yes-or-no-p (harness-ui-sessions--delete-question ids))
      (harness-ui-sessions--request-each
       "_harness/session/delete" :id ids
       #'harness-ui--forget-session
       (lambda (deleted)
         (harness-ui-sessions--unmark-and-redraw deleted)
         (cond ((null deleted))
               ((null (cdr ids)) (message "Session deleted"))
               ((= (length deleted) (length ids))
                (message "Deleted %s" (harness-ui--count (length deleted) "session")))
               (t (message "Deleted %d of %s" (length deleted)
                           (harness-ui--count (length ids) "session")))))))))

(defun harness-ui-sessions-rename (name)
  "Rename the session at point to NAME.
It acts on one session, so it refuses while any session is marked."
  (interactive
   (list (read-string "Name: " (plist-get (harness-ui-session (harness-ui-sessions--one-id "Rename")) :name))))
  (harness-rename-session name (harness-ui-sessions--one-id "Rename")))

(defun harness-ui-sessions-move (directory &optional keep-old)
  "Move the session at point to the working directory DIRECTORY.
It is then listed under DIRECTORY's project.  With a prefix argument
KEEP-OLD its old working directory stays allowed to it.  See
`harness-move-session'.  It acts on one session, so it refuses while any
session is marked."
  (interactive (list (harness-ui-read-move-directory
                      (harness-ui-session (harness-ui-sessions--one-id "Move")))
                     current-prefix-arg))
  (harness-move-session directory (harness-ui-sessions--one-id "Move") keep-old))

(defun harness-ui-sessions--turn-p (id)
  "Return non-nil when session ID has a turn to cancel: it runs or is blocked."
  (and (member (plist-get (harness-ui-session id) :status) '("running" "blocked")) t))

(defun harness-ui-sessions-cancel ()
  "Cancel the running turn of the marked sessions, else of the session at point.
A turn runs in a session that is running or blocked; the others have none
to cancel, are skipped and keep their marks.  The sessions whose turns
were cancelled are unmarked and the list is redrawn once.  With several
sessions a message says how many turns were cancelled, and with one that
has none, that it is not running."
  (interactive)
  (let* ((ids (harness-ui-sessions--targets))
         (running (cl-remove-if-not #'harness-ui-sessions--turn-p ids))
         (skipped (- (length ids) (length running))))
    (dolist (id running) (harness-cancel-turn id))
    ;; Nothing else shows at once: the sessions say they idle when they do.
    (when (cl-some #'harness-ui-sessions--marked-p running)
      (harness-ui-sessions--unmark-and-redraw running))
    (cond ((null running)
           (if (cdr ids)
               (message "None of the %d sessions is running" (length ids))
             (message "%s is not running" (harness-ui-sessions--label (car ids)))))
          ((cdr ids)
           (message "Cancelling %s%s" (harness-ui--count (length running) "turn")
                    (if (> skipped 0) (format "; %d not running" skipped) ""))))))

(defun harness-ui-sessions-set-priority ()
  "Ask for the priority of the marked sessions, else of the session at point.
The level is asked for once.  A priority is the session's -- low, medium
or high -- and orders the queues its work waits in, the tool slots above
all (the priority UI, `harness-set-priority').  Several sessions are
given it by one request (`_harness/priority/set-all' with their ids);
the marks stay, so more can be given to the same sessions."
  (interactive)
  (let* ((ids (harness-ui-sessions--targets))
         (one (null (cdr ids)))
         (level (harness-ui-priority--ask
                 (if one "Priority: " (format "Priority for the %d marked sessions: " (length ids)))
                 (and one (harness-ui-session (car ids))))))
    (cond ((null level))
          ((not (member level harness-ui-priority-levels))
           (message "Priority is low, medium or high, not %S" level))
          (one (harness-set-priority (car ids) level))
          (t (harness-ui-call
              "_harness/priority/set-all" (list :priority level :filter (list :ids ids))
              (lambda (changed)
                (harness-ui-refresh-sessions)
                (message "%s" (if changed
                                  (format "Priority → %s for %s" level
                                          (harness-ui--count (length changed) "session"))
                                (format "The %d marked sessions are at %s already"
                                        (length ids) level))))
              #'harness-ui-priority--failed)))))

(defun harness-ui-sessions--shift-priority (step)
  "Shift the priority of each target STEP levels, 1 to raise and -1 to lower.
Each is `harness-priority-shift-session''s; with several sessions one
message counts the sessions that reached a new level.  The marks stay."
  (let* ((ids (harness-ui-sessions--targets))
         (changed 0))
    (dolist (id ids)
      (if (cdr ids)
          (harness-priority-shift-session
           id step
           (lambda (_level)
             (message "Priority %s for %d of %d sessions" (if (> step 0) "raised" "lowered")
                      (cl-incf changed) (length ids))))
        (harness-priority-shift-session id step)))))

(defun harness-ui-sessions-raise-priority (&optional ask)
  "Raise the priority of the marked sessions, else of the session at point.
That is one level: low to medium, medium to high.  With a prefix
argument, ASK which level instead, once for all of them.  The marks stay."
  (interactive "P")
  (if ask
      (harness-ui-sessions-set-priority)
    (harness-ui-sessions--shift-priority 1)))

(defun harness-ui-sessions-lower-priority (&optional ask)
  "Lower the priority of the marked sessions, else of the session at point.
That is one level: high to medium, medium to low.  With a prefix
argument, ASK which level instead, once for all of them.  The marks stay."
  (interactive "P")
  (if ask
      (harness-ui-sessions-set-priority)
    (harness-ui-sessions--shift-priority -1)))

(defun harness-ui-sessions-make-task ()
  "Make the marked sessions tasks, else the session at point.
They are shown on their projects' task boards.  A session that is a task
already is skipped and keeps its mark; the others go by
`_harness/task/adopt', and once the last request is answered they are
unmarked, the list is redrawn and one message counts them."
  (interactive)
  ;; The board's keys follow `harness-ui-prefix-key'; look them up here,
  ;; in the list buffer, not in whatever buffer is current on the reply.
  (let* ((board (substitute-command-keys "\\[harness-tasks]" t))
         (ids (harness-ui-sessions--targets))
         (new (cl-remove-if (lambda (id) (harness-ui-sessions--task (harness-ui-session id))) ids)))
    (if (null new)
        (message "%s" (if (cdr ids)
                          (format "The %d marked sessions are tasks already" (length ids))
                        (format "%s is a task already" (harness-ui-sessions--label (car ids)))))
      (harness-ui-sessions--request-each
       "_harness/task/adopt" :session-id new nil
       (lambda (added)
         (harness-ui-sessions--unmark-and-redraw added)
         (when added
           (message "%s" (if (cdr ids)
                             (format "Added %s to the task board (%s)%s"
                                     (harness-ui--count (length added) "session") board
                                     (pcase (- (length ids) (length new))
                                       (0 "")
                                       (1 "; 1 was a task already")
                                       (n (format "; %d were tasks already" n))))
                           (format "Added to the task board (%s)" board)))))))))

(defun harness-ui-sessions-deactivate ()
  "Deactivate the marked sessions, else the session at point.
They become inactive, each by `_harness/session/deactivate'.  Once the
last request is answered the sessions deactivated are unmarked, the list
is redrawn and one message says how many."
  (interactive)
  (let ((ids (harness-ui-sessions--targets)))
    (harness-ui-sessions--request-each
     "_harness/session/deactivate" :id ids nil
     (lambda (deactivated)
       (harness-ui-sessions--unmark-and-redraw deactivated)
       (when deactivated
         (message "Deactivated %s" (if (cdr deactivated)
                                       (harness-ui--count (length deactivated) "session")
                                     (harness-ui-sessions--label (car deactivated)))))))))

(defun harness-ui-sessions-filter (text)
  "Filter the list by TEXT (fuzzy over name, model, status, kind, mode).
A task's session matches its task's title and the kind task."
  (interactive (list (read-string "Filter: " harness-ui-sessions--filter)))
  (setq harness-ui-sessions--filter text)
  (harness-ui-sessions--redraw))

(defun harness-ui-sessions-toggle-scope ()
  "Toggle between the current project and all projects."
  (interactive)
  (setq harness-ui-sessions--project
        (if harness-ui-sessions--project nil
          (harness-files-main-root default-directory)))
  (harness-ui-sessions--redraw))

(defun harness-ui-sessions-toggle-inactive ()
  "Show or hide inactive sessions."
  (interactive)
  (setq harness-ui-sessions--show-inactive (not harness-ui-sessions--show-inactive))
  (harness-ui-sessions--redraw))

(defun harness-ui-sessions--read-column ()
  "Ask which column of the list to show or hide, and return its name.
The candidates are all the columns but the status icon, each noted as
shown or hidden in this list now."
  (let ((names (mapcar (lambda (column) (plist-get column :name))
                       (cl-remove-if (lambda (column) (plist-get column :always))
                                     harness-ui-sessions--columns)))
        (shown (mapcar (lambda (column) (plist-get column :name))
                       (harness-ui-sessions--shown-columns))))
    (completing-read
     "Show or hide column: "
     (lambda (string pred action)
       (if (eq action 'metadata)
           `(metadata (display-sort-function . identity)
                      (cycle-sort-function . identity)
                      (annotation-function
                       . ,(lambda (name)
                            (concat "  " (propertize (if (member name shown) "shown" "hidden")
                                                     'face 'completions-annotations)))))
         (complete-with-action action names string pred)))
     nil t)))

(defun harness-ui-sessions-toggle-column (name)
  "Show the column NAME of the list if it is hidden, else hide it.
Interactively it asks which column, noting which are shown now.  The
change is this list's own: from then on it keeps its own hidden columns,
which start as `harness-ui-sessions-hidden-columns' says and leave the
option as it is.  The status icon column cannot be hidden, and the
Project column shows only when the list covers all projects."
  (interactive (list (harness-ui-sessions--read-column)))
  (let ((column (harness-ui-sessions-column name))
        (hidden (harness-ui-sessions--hidden-names)))
    (when (or (null column) (plist-get column :always))
      (user-error "No column to show or hide named \"%s\"" name))
    (setq-local harness-ui-sessions--hidden-columns
                (if (member name hidden) (remove name hidden) (cons name hidden)))
    (harness-ui-sessions--redraw)
    (when (and (plist-get column :all-projects) harness-ui-sessions--project)
      (message "The %s column shows only when the list covers all projects (a)" name))))

(defun harness-ui-sessions-toggle-blocked ()
  "Show only the sessions waiting for you, or every session again.
Those are the blocked sessions, as the mode line's notifier counts
them; a banner above them says so."
  (interactive)
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (setq harness-ui-sessions--blocked-only (not harness-ui-sessions--blocked-only)))
    (harness-ui-sessions--redraw)))

(defun harness-ui-sessions--toggle-flag (variable)
  "Flip VARIABLE, a flag of the list, in the list buffer and redraw the list.
The flag is the buffer's own, so it is set there whichever buffer is
current, as when a command runs from the menu."
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (set variable (not (symbol-value variable))))
    (harness-ui-sessions--redraw)))

(defun harness-ui-sessions-toggle-tasks-only ()
  "Show only the sessions that work on a task, or every session again.
A task's sub-agents, forks and BTW conversations are listed under it
though they work on no task themselves."
  (interactive)
  (harness-ui-sessions--toggle-flag 'harness-ui-sessions--tasks-only))

(defun harness-ui-sessions-toggle-internal ()
  "Show the internal sessions, or hide them again.
Those are the sessions of the kinds `harness-ui-sessions-hidden-kinds'
names, by default the harness's own model calls: the permission and
session judges, auto-naming and the like."
  (interactive)
  (harness-ui-sessions--toggle-flag 'harness-ui-sessions--show-hidden-kinds))

(defun harness-ui-sessions--drop-pending-redraws ()
  "Drop the redraws the list has scheduled for itself, if any.
Those are the one the growing token figures wait for
\(`harness-ui-sessions--live-timer') and the one a burst of changes waits
for, which another `harness-debounce' with the same key replaces."
  (when (timerp harness-ui-sessions--live-timer)
    (cancel-timer harness-ui-sessions--live-timer))
  (setq harness-ui-sessions--live-timer nil)
  (harness-debounce 'harness-ui-sessions 0 #'ignore))

(defun harness-ui-sessions-toggle-pause ()
  "Pause the list's live updates, or resume them.
A paused list holds still: the sessions that change, their output rates
and growing token figures, the requests they wait on and a reload of
the UI leave it alone, and the redraws it had scheduled are dropped.
Its own commands -- the filter, the scope, the toggles -- and `g' still
redraw it.  Resuming redraws it once, with all that changed meanwhile.
The marks and the filters are as they were.  The pause is the list's
own, so this works from any buffer; the mode line's button does the same."
  (interactive)
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (setq harness-ui-sessions--paused (not harness-ui-sessions--paused))
      (if harness-ui-sessions--paused
          (progn (harness-ui-sessions--drop-pending-redraws)
                 ;; Only the button changes: the rows stay as they were.
                 (setq mode-line-process (harness-ui-sessions--mode-line))
                 (force-mode-line-update))
        (harness-ui-sessions--redraw)))))

(defun harness-ui-sessions-allow ()
  "Answer the permission request the session at point waits on with Allow.
That is the [Allow] of the request's panel and of the task board, and
their y (`harness-ui-pending-answer-first-permission'); its tooltip says
what it covers (`harness-ui-pending-answer-help').  It answers for the
session at point (`harness-ui-session-at-point'), so a view that lists
sessions with this list's rows (`harness-ui-sessions-insert-entry') has
the same y."
  (interactive)
  (harness-ui-pending-answer-first-permission
   (or (harness-ui-session-at-point t) (harness-ui-sessions--id)) "allow-once"))

(defun harness-ui-sessions-deny ()
  "Answer the permission request the session at point waits on with Deny.
That is the [Deny] of the request's panel and of the task board, and
their n (`harness-ui-pending-answer-first-permission'), for the session at
point as `harness-ui-sessions-allow' has it."
  (interactive)
  (harness-ui-pending-answer-first-permission
   (or (harness-ui-session-at-point t) (harness-ui-sessions--id)) "deny-once"))

(defun harness-ui-sessions-reload ()
  "Reload sessions and tasks from the harness and resolve their projects again.
A paused list is redrawn by the reload, once the harness has answered,
and stays paused."
  (interactive)
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf (setq harness-ui-sessions--main-roots nil)))
  (harness-ui-refresh-sessions (lambda (_) (harness-ui-sessions--redraw)))
  (harness-ui-sessions--fetch-tasks t))

(defun harness-ui-sessions--waiting-help (session)
  "Return the tooltip of SESSION's status cell, saying what it waits on."
  (when (equal (plist-get session :status) "blocked")
    (if (equal (harness-ui-pending-status session) "question")
        "blocked on a question; SPC shows it, to answer it"
      "blocked on a permission request; y allows it, n denies it, SPC shows it")))

(defun harness-ui-sessions-requests ()
  "Pop out what the session at point waits on.
A session that waits on nothing leaves the key to what it did before
this command existed: SPC scrolls the list."
  (interactive)
  (if (and (fboundp 'harness-ui-popout-try-at-point)
           (harness-ui-popout-try-at-point))
      nil
    ;; Without a window (a test run) there is nothing to scroll.
    (ignore-errors (call-interactively #'scroll-up-command))))

(defun harness-ui-sessions--on-pending (_session-id)
  "Redraw the list, which shows what blocked sessions wait on.
On `harness-ui-pending-changed-hook': a request answered here leaves
the list at once, before its session says it is no longer blocked.  A
paused list is not redrawn."
  (when (get-buffer harness-ui-sessions--buffer-name)
    (harness-ui-sessions--on-changed)))

(defun harness-ui-sessions--init ()
  "Wire the session list into the UI.
The list redraws as sessions, what they wait on, their output rates and
their live token figures change, and follows the tasks, unless it is
paused (`harness-ui-sessions-toggle-pause'); l in `harness-ui-map' opens
it."
  (add-hook 'harness-ui-sessions-changed-hook #'harness-ui-sessions--on-changed)
  (add-hook 'harness-ui-pending-changed-hook #'harness-ui-sessions--on-pending)
  (add-hook 'harness-ui-rate-functions #'harness-ui-sessions--on-rate)
  (add-hook 'harness-ui-live-functions #'harness-ui-sessions--on-live)
  ;; A reload leaves the hook it set before: the plain redraw would not
  ;; hold still for a paused list.
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-sessions--redraw)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-sessions--redraw-live)
  ;; After a reload or reconnect the tasks may be another harness's.
  (add-hook 'harness-ui-redraw-hook #'harness-ui-sessions--fetch-tasks)
  (add-hook 'harness-ui-event-functions #'harness-ui-sessions--on-event)
  ;; A list that exists already, when the harness reloads, was started by
  ;; a mode function that did not know to catch up when shown.
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (when (derived-mode-p 'harness-ui-sessions-mode)
        (harness-ui-view-install #'harness-ui-sessions--catch-up))))
  (define-key harness-ui-map (kbd "l") #'harness-sessions))

(harness-define-module 'ui-sessions
  :doc "Session list buffer."
  :requires '(ui)
  :init #'harness-ui-sessions--init)

(provide 'harness-ui-sessions)
;;; harness-ui-sessions.el ends here
