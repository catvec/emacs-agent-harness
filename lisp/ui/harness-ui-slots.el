;;; harness-ui-slots.el --- The task slots page  -*- lexical-binding: t; -*-

;;; Commentary:

;; A page for the task slots of a project: how many tasks may work at
;; once (`harness-tasks-max-running'), who holds each slot and at which
;; priority, who waits for one and for how long, and how long tasks
;; waited lately.  `harness-slots' opens it; the harness answers it with
;; `task/slots', which counts the slots the way the scheduler does (a
;; task's sub-agents, forks and the merge queue take none).  These are
;; the task slots, not the tool slots that give a busy machine's tool
;; calls out by priority.
;;
;; The page reads, top to bottom (this one is 100 columns wide):
;;
;;   Task slots  my-project   3 of 4 in use · 1 free · 4 waiting   [Set limit]
;;
;;   In use
;;      Name                          Status    At work  Priority        Context         Cost Last msg
;;    ‖  Add secret redaction tools   blocked     1h18m  ↓                                Max 12m ago
;;      [Answer…]  has a question for you · Should the tool redact files in place?
;;    ►  Fix stuck model responses…   running       41m  ↑            52.0k/200k          Max just now
;;    ►  Plan task board polish       running        2m              9.1k/200k          Max 1m ago
;;      1 free
;;
;;   Queue · 4 waiting
;;     priority    waiting   longest   average
;;     ↑ high            2     1h05m     1h01m
;;       medium          1       12m       12m
;;     ↓ low             1        3m        3m
;;
;;   Next in line
;;     1. ↑ Plan session list rework                                   1h05m
;;     2. ↑ Plan compose box feature bundle · sent back                  58m
;;     ...
;;
;;   Waited for a slot · last 7 days
;;     priority    started   average   longest
;;     ↑ high            2        6m       12m
;;     ...
;;
;; The tasks at work are listed as the session list lists sessions, not
;; drawn on their own: a row for each, the longest at work first, in the
;; list's columns -- the status icon, Name, Status, Priority, Context,
;; Cost and Last msg, each the list's own cell
;; (`harness-ui-sessions-column') laid out by its own row printer
;; (`harness-ui-sessions-insert-entry') -- and At work, how long the task
;; has held its slot, which only the slots know.  So a priority arrow
;; and a context figure are buttons here as they are there, and a task
;; blocked on a request has, as in the list, the line saying what it
;; waits on under its row, with the buttons that answer it.  A task that
;; waits on its workers, was sent back from review or holds a slot past
;; the limit (a limit lowered below the tasks at work) has a line saying
;; so.  A line under the rows counts the free slots.  A window too
;; narrow for the table leaves out the last message, the cost, the
;; context and the priority, one at a time, before it cuts the names
;; (`harness-ui-slots--give-up').  A click or RET on a task's name opens
;; its session, the way a click on a card of the task board does; TAB and
;; S-TAB go from row to row, SPC pops out what the task waits on and y
;; and n answer a permission request, as in the list.  The
;; first line's [Set limit] is the board's "N at a time" button
;; (`harness-ui-tasks-set-max-running').
;;
;; Where things sit is told with `(space :align-to COLUMN)', never by
;; counting characters: an arrow or an icon is drawn a little wider or
;; narrower than the letters around it in some fonts, and would move a
;; column that came after it.
;;
;; The page is a function of what the harness said, the width of its
;; window and the time (`harness-ui-slots--page'), so a redraw whose text
;; would be the same as what is drawn is skipped
;; (`harness-ui-slots--render') and point stays on the same row or line.
;;
;; It stays current without a timer of its own and without asking more
;; than it must:
;;
;;   - it asks the harness again after the events the task board follows
;;     (`harness-ui-tasks--refresh-events', a task's change or deletion,
;;     a change of priority), once for a burst of them
;;     (`harness-ui-slots--refetch-delay'), and
;;     only while a window shows it: a hidden page is only marked stale,
;;     and asks once when it shows again;
;;   - its times, and the figures of the sessions in its rows, run on the
;;     board's clock (`harness-ui-tasks-tick-hook', every
;;     `harness-ui-tasks--tick-interval' seconds), drawn from the answer
;;     it has, asking the harness for nothing; a request a task waits
;;     on, which comes or is answered, draws it again at once
;;     (`harness-ui-pending-changed-hook');
;;   - either way, a redraw that would draw the same text is skipped.
;;
;; S on a task board opens the page for the board's project, and C-c h Q
;; ("Task slots", Q, in the harness menu) for the current one's.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
;; The priority arrow, which every view makes the same way.
(require 'harness-ui-priority)
;; The board: its limit button, its events and its clock, and the
;; project of the board the page is opened from.
(require 'harness-ui-tasks)
;; The session list's columns, cells and rows: the tasks at work are
;; listed with them.  Only its code is used; the list's own module need
;; not run.
(require 'harness-ui-sessions)

(defgroup harness-ui-slots nil
  "The task slots page." :group 'harness-ui)

(defface harness-slots-heading-face '((t :inherit bold))
  "The page's heading and the headings of its sections." :group 'harness-ui-slots)

(defface harness-slots-header-face '((t :inherit (bold shadow)))
  "The header row of the tables of the page." :group 'harness-ui-slots)

(defconst harness-ui-slots--buffer-name "*harness slots*"
  "Name of the task slots page.")

(defconst harness-ui-slots--padding 1
  "Columns left of every row of the table of the slots in use.")

(defconst harness-ui-slots--columns '("" "Name" "Status" "At work" "Priority" "Context" "Cost" "Last msg")
  "The columns of the table of the slots in use, left to right.
All but At work, which only the slots know, are the session list's own
\(`harness-ui-sessions-column'): a session reads here as it does there,
down to the buttons of its priority and of its context window.")

(defconst harness-ui-slots--give-up '("Last msg" "Cost" "Context" "Priority")
  "The columns a window too narrow for the table leaves out, the first first.")

(defconst harness-ui-slots--name-width 40
  "Columns the Name column is wide at most: a longer title is cut.")

(defconst harness-ui-slots--name-min-width 16
  "Columns the Name column keeps before a narrow window loses other columns.")

(defconst harness-ui-slots--priorities '("high" "medium" "low")
  "The priorities the page counts waits by, highest first.")

(defconst harness-ui-slots--next-count 5
  "How many tasks the page lists as next in line.")

(defconst harness-ui-slots--table-ends '(22 32 42)
  "The columns where the numbers of the page's tables end, right-aligned.")

(defvar harness-ui-slots-row-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'harness-ui-slots-mouse-open)
    (define-key map [mouse-2] #'harness-ui-slots-mouse-open)
    (define-key map (kbd "RET") #'harness-ui-slots-open)
    map)
  "Keys on the name of a task in a slot: a click or RET opens its session.
They are on the name's text itself, so they hold wherever the page's own
keys are shadowed (an evil state's, say).")

(defvar-local harness-ui-slots--dir nil
  "The directory the page was opened for: the harness finds its project from it.")

(defvar-local harness-ui-slots--data nil
  "What `task/slots' last answered, a plist, or nil before the first answer.")

(defvar-local harness-ui-slots--loading nil
  "Non-nil while the first answer is awaited.")

(defvar-local harness-ui-slots--error nil
  "Why the last request for the slots failed, a string, or nil.")

(defvar-local harness-ui-slots--generation 0
  "Counts the requests; an answer to an earlier one than the last is dropped.")

(defvar-local harness-ui-slots--drawn nil
  "The text the buffer shows, to see whether drawing again would change it.")

(defvar-local harness-ui-slots--stale nil
  "Non-nil when events came while no window showed the page.
It asks the harness again as soon as one does.")

;;;; Small pieces

(defun harness-ui-slots--duration (seconds)
  "Format SECONDS of work or waiting coarsely, as the board does: 40s, 12m, 2h05m."
  (let ((seconds (max 0 (or seconds 0))))
    (cond ((< seconds 60) (format "%ds" (truncate seconds)))
          ((< seconds 3600) (format "%dm" (truncate (/ seconds 60))))
          (t (format "%dh%02dm" (truncate (/ seconds 3600)) (truncate (/ (mod seconds 3600) 60)))))))

(defun harness-ui-slots--priority (value)
  "Return the priority VALUE names: \"high\", \"low\", else the default, \"medium\"."
  (let ((name (format "%s" value)))
    (if (member name '("high" "low")) name "medium")))

(defun harness-ui-slots--limit (data)
  "Return how many slots DATA, an answer of `task/slots', says there are.
A number, or nil without a limit."
  (let ((limit (plist-get data :limit)))
    (and (numberp limit) (max 0 (floor limit)))))

(defun harness-ui-slots--number (value)
  "Return VALUE when it is a number, else 0."
  (if (numberp value) value 0))

(defun harness-ui-slots--fit (string room)
  "Return STRING shortened to ROOM columns, with an ellipsis, as the board does.
A newline or a tab in it is a space."
  (let ((string (replace-regexp-in-string "[\n\r\t]+" " " (or string ""))))
    (if (< room 1) "" (truncate-string-to-width string room nil nil "…"))))

(defun harness-ui-slots--to (column &rest props)
  "Return a stretch of space that ends at COLUMN, with PROPS.
Whatever comes before it is drawn, and whatever it measures, what comes
after starts at COLUMN (when the text before leaves room for it)."
  (apply #'propertize " " 'display `(space :align-to ,column) props))

(defun harness-ui-slots--right (text end &optional face)
  "Return TEXT, in FACE, right-aligned so that it ends at column END."
  (concat (harness-ui-slots--to (- end (string-width text)))
          (if face (propertize text 'face face) text)))

(defun harness-ui-slots--with (string props)
  "Return a copy of STRING with the text properties PROPS added."
  (let ((string (copy-sequence string)))
    (when props (add-text-properties 0 (length string) props string))
    string))

(defun harness-ui-slots--dim (string)
  "Return STRING in the dim face."
  (propertize string 'face 'harness-dim-face))

(defun harness-ui-slots--plain-arrow (priority)
  "Return PRIORITY's arrow, or nil for medium, without the click on it.
Queued tasks are listed without their sessions, so their arrows ask for
nothing; the hover says the level."
  (when-let* ((arrow (harness-ui-priority-arrow priority)))
    (unless (string-empty-p arrow)
      (let ((arrow (copy-sequence arrow)))
        (remove-text-properties 0 (length arrow)
                                (list 'keymap nil 'mouse-face nil harness-ui-priority-arrow-property nil)
                                arrow)
        (put-text-property 0 (length arrow) 'help-echo
                           (format "%s priority" (capitalize priority)) arrow)
        arrow))))

(defun harness-ui-slots--since (entry)
  "Return when ENTRY, a holder or a queued task, began: a float time, else 0."
  (harness-ui-slots--number (plist-get entry :since)))

(defun harness-ui-slots--waited (entry now)
  "Return for how many seconds ENTRY has waited as of NOW; 0 if it says nothing."
  (let ((since (plist-get entry :since)))
    (if (numberp since) (max 0 (- now since)) 0)))

;;;; The numbers: holders, waits

(defun harness-ui-slots--holders (data)
  "Return the tasks at work in DATA's slots, as plists, the longest at work first.
Each has `:index' (its place in that order), `:holder' (its entry of
`task/slots'), `:session' (`harness-ui-slots--session') and `:over',
non-nil when the limit was lowered under the tasks at work and its slot
is one of those past it: the tasks that began last."
  (let* ((limit (harness-ui-slots--limit data))
         (holders (sort (copy-sequence (plist-get data :holders))
                        (lambda (a b) (< (harness-ui-slots--since a) (harness-ui-slots--since b)))))
         (index 0))
    (mapcar (lambda (holder)
              (let ((over (and limit (>= index limit) t)))
                (prog1 (list :index index :holder holder :over over
                             :session (harness-ui-slots--session holder over))
                  (cl-incf index))))
            holders)))

(defun harness-ui-slots--free (data)
  "Return how many of DATA's slots are free, or nil without a limit."
  (when-let* ((limit (harness-ui-slots--limit data)))
    (max 0 (- limit (length (plist-get data :holders))))))

(defun harness-ui-slots--stats (seconds)
  "Return (COUNT LONGEST AVERAGE) of the list SECONDS, or nil when it is empty."
  (when seconds
    (list (length seconds) (apply #'max seconds)
          (/ (apply #'+ seconds) (float (length seconds))))))

(defun harness-ui-slots--queue-stats (data now)
  "Return the waits in DATA's queue, by priority, as of NOW.
An alist of PRIORITY and (COUNT LONGEST AVERAGE), the waits in seconds:
each is NOW less when the task began waiting.  A priority nobody waits
at has nil."
  (mapcar (lambda (priority)
            (cons priority
                  (harness-ui-slots--stats
                   (cl-loop for entry in (plist-get data :queue)
                            when (equal (harness-ui-slots--priority (plist-get entry :priority)) priority)
                            collect (harness-ui-slots--waited entry now)))))
          harness-ui-slots--priorities))

(defun harness-ui-slots--wait-stats (data)
  "Return the waits DATA recorded, by priority.
An alist of PRIORITY and (COUNT LONGEST AVERAGE), the waits in seconds:
how long tasks waited before they started, in the days `task/slots'
reports.  A priority with none has nil."
  (mapcar (lambda (priority)
            (cons priority
                  (harness-ui-slots--stats
                   (cl-loop for wait in (plist-get data :waits)
                            when (equal (harness-ui-slots--priority (plist-get wait :priority)) priority)
                            collect (max 0 (harness-ui-slots--number (plist-get wait :seconds)))))))
          harness-ui-slots--priorities))

;;;; The first line

(defun harness-ui-slots--project-name (data dir)
  "Return the name of the project of DATA, else of DIR, for the page's first line."
  (let ((root (or (plist-get data :project) dir)))
    (and (stringp root) (not (string-empty-p root))
         (file-name-nondirectory (directory-file-name root)))))

(defun harness-ui-slots--summary (data)
  "Return the counts of DATA's slots as a list of strings, for the first line."
  (let* ((limit (harness-ui-slots--limit data))
         (used (length (plist-get data :holders)))
         (waiting (length (plist-get data :queue)))
         (parts
          (cond
           ((null limit)
            (list (format "%d in use" used) "no limit"))
           ((zerop limit)
            (list (propertize "limit 0: nothing starts by itself" 'face 'warning)
                  (and (> used 0) (format "%d still at work" used))))
           (t (list (format "%d of %d in use" used limit)
                    (format "%d free" (max 0 (- limit used)))
                    (and (> used limit)
                         (propertize (format "%d over the limit" (- used limit)) 'face 'warning)))))))
    (delq nil (append parts
                      (and (or limit (> waiting 0)) (list (format "%d waiting" waiting)))
                      (and (harness-json-true-p (plist-get data :suspended))
                           (list (propertize "queue suspended" 'face 'warning)))))))

(defun harness-ui-slots--first-line (data dir)
  "Return the first line of the page: its heading, the project and DATA's counts.
DIR names the project until DATA does.  Once DATA says what the limit
is, the line ends with the [Set limit] button, the board's \"N at a
time\"."
  (concat " " (propertize "Task slots" 'face 'harness-slots-heading-face)
          (when-let* ((name (harness-ui-slots--project-name data dir)))
            (concat "  " name))
          (when data
            (concat "   " (harness-ui-slots--dim (string-join (harness-ui-slots--summary data) " · "))))
          (when data
            (concat "   " (harness-ui-action-button
                           "[Set limit]" #'harness-ui-slots-set-limit
                           :help "How many of a project's tasks work at once, for every project (l)")))
          "\n"))

;;;; The slots in use

;; The tasks at work are listed as the session list lists sessions, not
;; drawn on their own: the same columns and cells, laid out by the same
;; code (`harness-ui-sessions-insert-entry'), so a status, a priority
;; arrow, a context figure and a blocked session's [Allow] and [Deny]
;; are the ones of the list, and its clicks do the same.  What only the
;; slots know goes in a column of their own, At work, and on a line
;; under the row (`harness-ui-slots--notes').

(defun harness-ui-slots--session (holder over)
  "Return the session of HOLDER's task as the table draws it, a plist.
HOLDER is an entry of `task/slots' :holders.  The session is the one the
UI has cached under its `:session' -- none while its task starts --
with what `task/slots' says of the slot in front of it: the task's title
for its name, the slot's state for its status, its priority, `:since'
\(when its work began) and `:sent-back'.  OVER, non-nil for a slot past
the limit, is `:over', and `:cached' says that the UI knew the session,
for the figures of one it does not know would read as zeros."
  (let* ((id (plist-get holder :session))
         (id (and (stringp id) (not (string-empty-p id)) id))
         (cached (and id (harness-ui-session id))))
    (append (list :id id
                  :name (let ((title (plist-get holder :title)))
                          (and (stringp title) (replace-regexp-in-string "[\n\r\t]+" " " title)))
                  :status (format "%s" (plist-get holder :state))
                  :ext (list :priority (harness-ui-slots--priority (plist-get holder :priority)))
                  :since (plist-get holder :since)
                  :sent-back (plist-get holder :sent-back)
                  :over over
                  :cached (and cached t))
            cached)))

(defun harness-ui-slots--work-column (now)
  "Return the At work column: how long each task has held its slot, as of NOW.
It is empty while the task starts."
  (list :name "At work" :width 7 :right-align t :pad-right 2
        :cell (lambda (session _depth)
                (let ((since (plist-get session :since)))
                  (if (and (numberp since) (not (equal (plist-get session :status) "starting")))
                      (harness-ui-slots--duration (- now since))
                    "")))))

(defun harness-ui-slots--column-specs (now)
  "Return the specs of the columns of `harness-ui-slots--columns', as of NOW.
Those of the session list are its own, but for the figures of a session
the UI does not know, which stay empty."
  (mapcar (lambda (name)
            (cond ((equal name "At work") (harness-ui-slots--work-column now))
                  ((member name '("Context" "Cost" "Last msg"))
                   (let* ((column (copy-sequence (harness-ui-sessions-column name)))
                          (cell (plist-get column :cell)))
                     ;; A gap between the cost, which ends at its column's edge,
                     ;; and the last message that follows.
                     (when (equal name "Cost") (setq column (plist-put column :pad-right 2)))
                     (plist-put column :cell
                                (lambda (session depth)
                                  (if (plist-get session :cached) (funcall cell session depth) "")))))
                  (t (harness-ui-sessions-column name))))
          harness-ui-slots--columns))

(defun harness-ui-slots--column-named (columns name)
  "Return the index of the column NAME among COLUMNS, specs, or nil."
  (cl-position name columns :key (lambda (column) (plist-get column :name)) :test #'equal))

(defun harness-ui-slots--layout (sessions width now)
  "Return (COLUMNS . FORMAT) for the table of SESSIONS in a window WIDTH wide.
COLUMNS are the specs of `harness-ui-slots--columns' as of NOW and
FORMAT theirs as `harness-ui-sessions-format' makes it.  The Name column
is as wide as the longest name (`harness-ui-slots--name-width' at most)
or as the room leaves; where that is less than
`harness-ui-slots--name-min-width', the columns of
`harness-ui-slots--give-up' are left out, one at a time."
  (let* ((columns (harness-ui-slots--column-specs now))
         (longest (apply #'max 0 (mapcar (lambda (session) (string-width (or (plist-get session :name) "")))
                                         sessions)))
         (wanted (max 8 (min longest harness-ui-slots--name-width))))
    (cl-flet ((room ()
                ;; What the others leave of WIDTH, one column spare.
                (- width 1 harness-ui-slots--padding
                   (cl-loop for column in columns
                            unless (equal (plist-get column :name) "Name")
                            sum (+ (plist-get column :width) (or (plist-get column :pad-right) 1))))))
      (while-let ((name (and (< (room) harness-ui-slots--name-min-width)
                             (cl-find-if (lambda (name) (harness-ui-slots--column-named columns name))
                                         harness-ui-slots--give-up))))
        (setq columns (cl-remove name columns :key (lambda (column) (plist-get column :name))
                                 :test #'equal)))
      (cons columns (harness-ui-sessions-format columns (list (cons "Name" (max 8 (min wanted (room))))))))))

(defun harness-ui-slots--name-help (session)
  "Return the tooltip of the name in SESSION's row.
It is the task's title, and what a click does."
  (harness-ui-one-line
   (format "%s · %s" (harness-ui-slots--fit (plist-get session :name) 200)
           (if (plist-get session :id)
               "mouse-1, RET: open its session"
             "its session has not started yet"))))

(defun harness-ui-slots--name-cell (cell session index)
  "Return CELL, the Name cell of SESSION's row, as the link to its session.
It is highlighted under the mouse, says what a click does and has the
keys that open the session (`harness-ui-slots-row-map').  Its first
character marks the row's place among the others, INDEX
\(`harness-slot-top'), where TAB goes."
  (let ((cell (copy-sequence cell)))
    (when (> (length cell) 0)
      (add-text-properties 0 (length cell)
                           (list 'mouse-face 'highlight 'pointer 'hand 'keymap harness-ui-slots-row-map
                                 'help-echo (harness-ui-slots--name-help session))
                           cell)
      (put-text-property 0 1 'harness-slot-top index cell))
    cell))

(defun harness-ui-slots--notes (session indent)
  "Return the line under SESSION's row for what the row cannot say, or \"\".
It starts INDENT columns in.  The task waits on its workers (its turn
ended, but left work running, which holds the slot too), was sent back
from review, or has a slot past the limit."
  (let ((notes (delq nil
                     (list (and (plist-get session :over) (propertize "over the limit" 'face 'warning))
                           (and (equal (plist-get session :status) "waiting")
                                (harness-ui-slots--dim "waits on its workers"))
                           (and (harness-json-true-p (plist-get session :sent-back))
                                (harness-ui-slots--dim "sent back"))))))
    (if notes
        (concat (make-string indent ?\s) (string-join notes (harness-ui-slots--dim " · ")) "\n")
      "")))

(defun harness-ui-slots--row (row columns format width)
  "Return the text of ROW, one of `harness-ui-slots--holders', as a table row.
It is drawn in COLUMNS, of which FORMAT is the format, for a window
WIDTH columns wide.  Every line of it -- the row, the line of what a
blocked task waits on and the notes -- carries the task's keys:
`harness-slot-key' to be found again after a redraw, `harness-slot-task'
and `harness-slot-session'."
  (let* ((holder (plist-get row :holder))
         (session (plist-get row :session))
         (cells (harness-ui-sessions-cells columns session))
         (name (harness-ui-slots--column-named columns "Name"))
         (indent (+ harness-ui-slots--padding
                    (cl-loop for spec across format
                             until (equal (car spec) "Name")
                             sum (+ (nth 1 spec) (or (plist-get (nthcdr 3 spec) :pad-right) 1)))))
         (id (plist-get holder :id)))
    (aset cells name (harness-ui-slots--name-cell (aref cells name) session (plist-get row :index)))
    (harness-ui-slots--with
     (with-temp-buffer
       (harness-ui-sessions-insert-entry session cells format harness-ui-slots--padding indent width)
       (insert (harness-ui-slots--notes session indent))
       (buffer-string))
     (append (list 'harness-slot-key (concat "task:" (format "%s" id))
                   'harness-slot-index (plist-get row :index)
                   'harness-slot-task id)
             (and (plist-get session :id) (list 'harness-slot-session (plist-get session :id)))))))

(defun harness-ui-slots--holders-section (data width now)
  "Return the section of the slots in use of DATA, drawn for WIDTH columns at NOW.
The tasks at work, longest first, as a table of the session list's
columns, then how many slots are free."
  (let ((rows (harness-ui-slots--holders data))
        (free (harness-ui-slots--free data)))
    (concat
     (harness-ui-slots--heading "In use")
     (if (null rows)
         (concat "   " (harness-ui-slots--dim "nothing holds a slot") "\n")
       (pcase-let ((`(,columns . ,format)
                    (harness-ui-slots--layout (mapcar (lambda (row) (plist-get row :session)) rows) width now)))
         (concat (harness-ui-sessions-header-row format harness-ui-slots--padding 'harness-slots-header-face)
                 (mapconcat (lambda (row) (harness-ui-slots--row row columns format width)) rows ""))))
     (if (and free (> free 0))
         (concat "   " (harness-ui-slots--dim (format "%d free" free)) "\n")
       ""))))

;;;; Tables

(defun harness-ui-slots--heading (title &rest notes)
  "Return the heading line of a section: TITLE, then NOTES, dim, after it.
Each of NOTES, a string (or nil, which is left out), follows a \" · \"."
  (concat " " (propertize title 'face 'harness-slots-heading-face)
          (mapconcat (lambda (note) (harness-ui-slots--dim (concat " · " note))) (delq nil notes) "")
          "\n"))

(defun harness-ui-slots--priority-label (priority)
  "Return the label of a row for PRIORITY: its arrow at column 3, the word at 5."
  (let ((arrow (harness-ui-slots--plain-arrow priority)))
    (concat "   " (or arrow "") (harness-ui-slots--to 5)
            (pcase priority
              ("high" (propertize priority 'face 'harness-priority-high-face))
              ("low" (propertize priority 'face 'harness-priority-low-face))
              (_ priority)))))

(defun harness-ui-slots--table (labels stats)
  "Return a table: a header row of LABELS (three), a row for each priority.
STATS maps a priority to (COUNT LONGEST AVERAGE) in the order the
columns come in, or to nil, which shows as dashes.  Durations are
formatted here; each column ends where `harness-ui-slots--table-ends'
says."
  (concat
   "   " (harness-ui-slots--with "priority" '(face harness-slots-header-face))
   (mapconcat #'identity
              (cl-mapcar (lambda (label end) (harness-ui-slots--right label end 'harness-slots-header-face))
                         labels harness-ui-slots--table-ends)
              "")
   "\n"
   (mapconcat
    (lambda (priority)
      (let ((cells (cdr (assoc priority stats))))
        (concat (harness-ui-slots--priority-label priority)
                (mapconcat #'identity
                           (cl-mapcar (lambda (cell end)
                                        (harness-ui-slots--right cell end (and (equal cell "–") 'harness-dim-face)))
                                      (if cells
                                          (list (format "%d" (nth 0 cells))
                                                (harness-ui-slots--duration (nth 1 cells))
                                                (harness-ui-slots--duration (nth 2 cells)))
                                        '("–" "–" "–"))
                                      harness-ui-slots--table-ends)
                           "")
                "\n")))
    harness-ui-slots--priorities "")))

(defun harness-ui-slots--queue-section (data now)
  "Return the section of DATA's queue: how many wait, and the waits by priority.
The longest wait so far and the average one, by priority, as of NOW."
  (let ((waiting (length (plist-get data :queue))))
    (concat
     (apply #'harness-ui-slots--heading "Queue" (format "%d waiting" waiting)
            (and (harness-json-true-p (plist-get data :suspended))
                 (list (propertize "suspended" 'face 'warning))))
     (harness-ui-slots--table
      '("waiting" "longest" "average")
      (harness-ui-slots--queue-stats data now)))))

(defun harness-ui-slots--reason (reason)
  "Return why a queued task leads its line, from REASON as the harness says it."
  (pcase (and reason (format "%s" reason))
    ("sent-back" "sent back")
    ("preempted" "pre-empted")
    ("returned" "returned")
    (_ nil)))

(defun harness-ui-slots--next-section (data width now)
  "Return the section of the first tasks in DATA's queue, in the order they start.
Each line has its place in line, its priority's arrow, its title and, at
the right, how long it has waited as of NOW; WIDTH decides how far the
titles go."
  (let* ((queue (plist-get data :queue))
         (end (max 40 (min 72 (- width 2))))
         (wait-room 7))
    (concat
     (harness-ui-slots--heading "Next in line")
     (if (null queue)
         (concat "   " (harness-ui-slots--dim "nobody waits for a slot") "\n")
       (concat
        (cl-loop for entry in (seq-take queue harness-ui-slots--next-count)
                 for place from 1
                 concat
                 (let* ((priority (harness-ui-slots--priority (plist-get entry :priority)))
                        (note (harness-ui-slots--reason (plist-get entry :reason)))
                        (room (- end 8 1 wait-room))
                        (title (harness-ui-slots--fit (plist-get entry :title)
                                                      (if note (max 8 (- room 3 (length note))) room))))
                   ;; A row is found again after a redraw by its task.
                   (concat
                    (harness-ui-slots--with
                     (concat "   " (harness-ui-slots--dim (format "%d." place))
                             (harness-ui-slots--to 6) (or (harness-ui-slots--plain-arrow priority) "")
                             (harness-ui-slots--to 8)
                             (propertize title 'face 'harness-task-title-face)
                             (if note (concat (harness-ui-slots--dim " · ") (harness-ui-slots--dim note)) "")
                             (harness-ui-slots--right
                              (harness-ui-slots--duration (harness-ui-slots--waited entry now))
                              end))
                     (list 'harness-slot-key (concat "queue:" (format "%s" (plist-get entry :id)))))
                    "\n")))
        (when (> (length queue) harness-ui-slots--next-count)
          (concat "   " (harness-ui-slots--dim (format "… and %d more" (- (length queue) harness-ui-slots--next-count)))
                  "\n")))))))

(defun harness-ui-slots--waits-section (data)
  "Return the section of the waits DATA recorded, by priority.
How many tasks started, and their average and longest wait, over the
days DATA says."
  (let* ((days (plist-get data :days))
         (days (and (numberp days) (> days 0) (max 1 (round days)))))
    (concat
     (harness-ui-slots--heading "Waited for a slot"
                                (cond ((null days) nil)
                                      ((= days 1) "last day")
                                      (t (format "last %d days" days))))
     (harness-ui-slots--table
      '("started" "average" "longest")
      (mapcar (lambda (cell)
                ;; The stats come as (COUNT LONGEST AVERAGE); this table reads
                ;; its columns as started, average, longest.
                (cons (car cell)
                      (and (cdr cell) (list (nth 0 (cdr cell)) (nth 2 (cdr cell)) (nth 1 (cdr cell))))))
              (harness-ui-slots--wait-stats data))))))

;;;; The page

(defun harness-ui-slots--text (data width now &optional dir error)
  "Return the page for DATA, an answer of `task/slots', as text.
It is drawn for a window WIDTH columns wide at the time NOW (a float
time).  DIR is the directory the page was opened for, which names the
project until the harness says; ERROR, a string, says that asking again
failed, and the page shows the last answer all the same."
  (concat
   (harness-ui-slots--first-line data dir)
   (when error
     (concat " " (propertize (format "Could not refresh: %s" error) 'face 'error) "\n"))
   "\n"
   (harness-ui-slots--holders-section data width now)
   "\n"
   (harness-ui-slots--queue-section data now)
   "\n"
   (harness-ui-slots--next-section data width now)
   "\n"
   (harness-ui-slots--waits-section data)))

(defun harness-ui-slots--page (width now)
  "Return the text of the page in the current buffer.
It is for a window WIDTH columns wide at the time NOW: the text of the
last answer (`harness-ui-slots--text'), or a note that the first is
awaited, or why it did not come."
  (cond
   (harness-ui-slots--data
    (harness-ui-slots--text harness-ui-slots--data width now harness-ui-slots--dir harness-ui-slots--error))
   (t
    (concat (harness-ui-slots--first-line nil harness-ui-slots--dir)
            "\n "
            (if (and harness-ui-slots--error (not harness-ui-slots--loading))
                (propertize (format "Could not load the task slots: %s" harness-ui-slots--error) 'face 'error)
              (harness-ui-slots--dim "loading…"))
            "\n"))))

(defun harness-ui-slots--width ()
  "Return the width the page is drawn for: its widest window, or 100 when hidden."
  (let ((windows (get-buffer-window-list nil nil t)))
    (if windows (apply #'max (mapcar #'window-body-width windows)) 100)))

;;;; Drawing, and keeping the places

;; A redraw keeps point where it was, and each window's point and start:
;; on the row or the line it was on, found again by what the text says.
;; A task in a slot or in the queue is found by its key
;; (`harness-slot-key'), the line it was on counted from the key's first
;; line, and the place on it from where the key's text starts there;
;; anything else by its line.

(defun harness-ui-slots--key-at (pos)
  "Return the key of the row at POS, or just before it (at a line's end)."
  (or (get-text-property pos 'harness-slot-key)
      (and (> pos (point-min)) (get-text-property (1- pos) 'harness-slot-key))))

(defun harness-ui-slots--first-pos (key)
  "Return where KEY's text first appears in the buffer, or nil."
  (let ((pos (point-min)) found)
    (while (and (not found) (< pos (point-max)))
      (if (equal (get-text-property pos 'harness-slot-key) key)
          (setq found pos)
        (setq pos (or (next-single-property-change pos 'harness-slot-key) (point-max)))))
    found))

(defun harness-ui-slots--run-start (key from to)
  "Return where KEY's text starts between FROM and TO, a line, or nil."
  (let ((pos from) found)
    (while (and (not found) (< pos to))
      (if (equal (get-text-property pos 'harness-slot-key) key)
          (setq found pos)
        (setq pos (or (next-single-property-change pos 'harness-slot-key nil to) to))))
    found))

(defun harness-ui-slots--anchor (pos)
  "Describe where POS is, to find the place again after a redraw.
It is (KEY LINES OFFSET LINE): the key of the row, the lines from its
first to POS's, the offset from where its text starts on POS's line, and
the line number; KEY, LINES and OFFSET's base are nil on a line that
belongs to no row, where OFFSET is the column."
  (save-excursion
    (goto-char pos)
    (let* ((key (harness-ui-slots--key-at pos))
           (first (and key (harness-ui-slots--first-pos key)))
           (line (line-number-at-pos pos))
           (bol (line-beginning-position)))
      (if first
          (list key (- line (line-number-at-pos first))
                (- pos (or (harness-ui-slots--run-start key bol (line-end-position)) bol))
                line)
        (list nil nil (- pos bol) line)))))

(defun harness-ui-slots--place (anchor)
  "Return the position ANCHOR names in the page now.
ANCHOR is from `harness-ui-slots--anchor': the same row where it is
still there, else the same line."
  (pcase-let ((`(,key ,lines ,offset ,line) anchor))
    (save-excursion
      (let ((first (and key (harness-ui-slots--first-pos key))))
        (if first
            (progn (goto-char first)
                   (forward-line lines)
                   (let ((bol (line-beginning-position)) (eol (line-end-position)))
                     (min eol (+ offset (or (harness-ui-slots--run-start key bol eol) bol)))))
          (goto-char (point-min))
          (forward-line (1- line))
          (min (line-end-position) (+ (line-beginning-position) offset)))))))

(defun harness-ui-slots--line-start (line)
  "Return where line number LINE starts, or the last line's start."
  (save-excursion (goto-char (point-min)) (forward-line (1- line)) (line-beginning-position)))

(defun harness-ui-slots--places ()
  "Return where point and each window showing the buffer are, to restore them."
  (list (harness-ui-slots--anchor (point))
        (mapcar (lambda (window)
                  (list window (line-number-at-pos (window-start window))
                        (harness-ui-slots--anchor (window-point window))))
                (get-buffer-window-list nil nil t))))

(defun harness-ui-slots--restore (places)
  "Put point and the windows back where PLACES had them.
PLACES is from `harness-ui-slots--places'."
  (pcase-let ((`(,anchor ,windows) places))
    (goto-char (harness-ui-slots--place anchor))
    (pcase-dolist (`(,window ,start ,at) windows)
      (when (window-live-p window)
        (set-window-start window (harness-ui-slots--line-start start) t)
        (set-window-point window (harness-ui-slots--place at))))))

(defun harness-ui-slots--draw (text)
  "Replace the buffer's text with TEXT, keeping point and the windows in place."
  (let ((inhibit-read-only t)
        (places (harness-ui-slots--places)))
    (erase-buffer)
    (insert text)
    (set-buffer-modified-p nil)
    (harness-ui-slots--restore places)))

(defun harness-ui-slots--render (&optional force)
  "Draw the page again when what it says now differs from what is drawn.
FORCE draws it anyway.  The page is `harness-ui-slots--page' for the
width of the buffer's windows and the time now, so this is cheap to ask
for as often as the times on it change.  Return non-nil when it drew."
  (when (derived-mode-p 'harness-ui-slots-mode)
    (let ((text (harness-ui-slots--page (harness-ui-slots--width) (float-time))))
      (when (or force (not (equal-including-properties text harness-ui-slots--drawn)))
        (setq harness-ui-slots--drawn text)
        (harness-ui-slots--draw text)
        t))))

(defun harness-ui-slots--on-resize ()
  "Draw the page again soon for the window it is in, once for a burst of changes.
On `window-configuration-change-hook' in the page's buffer."
  (let ((buffer (current-buffer)))
    (harness-debounce (list 'harness-ui-slots-resize buffer) 0.1
                      (lambda ()
                        (when (buffer-live-p buffer)
                          (with-current-buffer buffer (harness-ui-slots--render)))))))

;;;; Asking the harness

(defun harness-ui-slots--fetch (dir callback on-error)
  "Ask the harness how the task slots of DIR's project are used.
CALLBACK is called with the answer, a plist (see `task/slots'), or
ON-ERROR with why it failed."
  (harness-ui-call "_harness/task/slots" (list :cwd dir) callback on-error))

(defun harness-ui-slots--load (buffer)
  "Ask for the slots again for BUFFER's page, and draw them when they come.
An answer to an earlier request than the last is dropped, so a slow one
never replaces a newer.  A failure keeps the last answer on the page and
says why above it."
  (with-current-buffer buffer
    (let ((generation (cl-incf harness-ui-slots--generation)))
      ;; Whatever it missed while hidden, this answer has.
      (setq harness-ui-slots--stale nil)
      (harness-ui-view-drawn)
      (unless harness-ui-slots--data (setq harness-ui-slots--loading t))
      (harness-ui-slots--fetch
       harness-ui-slots--dir
       (lambda (data)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= generation harness-ui-slots--generation)
               (setq harness-ui-slots--data data
                     harness-ui-slots--loading nil
                     harness-ui-slots--error nil)
               (harness-ui-slots--render)))))
       (lambda (err)
         (when (and (buffer-live-p buffer) (not (harness-ui-connection-replaced-p err)))
           (with-current-buffer buffer
             (when (= generation harness-ui-slots--generation)
               (setq harness-ui-slots--loading nil
                     harness-ui-slots--error (harness-error-message err))
               (harness-ui-slots--render)))))))))

(defvar harness-ui-slots--refetch-delay 0.5
  "Seconds `harness-ui-slots--refetch-soon' waits for more calls before it asks.")

(defun harness-ui-slots--refetch-soon (buffer &optional delay)
  "Ask for BUFFER's slots again in DELAY seconds, once for a burst of calls.
DELAY defaults to `harness-ui-slots--refetch-delay'."
  (harness-debounce (list 'harness-ui-slots buffer) (or delay harness-ui-slots--refetch-delay)
                    (lambda ()
                      (when (buffer-live-p buffer) (harness-ui-slots--load buffer)))))

;;;; Keeping up

;; What moves a task in or out of a slot comes as one of the events the
;; task board follows; a page a window shows asks again once a burst of
;; them settles, a hidden one only notes that it missed some.  Its times
;; run on the board's clock, from the answer it has.

(defun harness-ui-slots--shown-p (buffer)
  "Non-nil when a window shows BUFFER, on any frame."
  (get-buffer-window buffer t))

(defun harness-ui-slots--event-p (event args)
  "Non-nil when EVENT with ARGS may change who holds a slot or waits for one.
Those are the events after which the task board reloads
\(`harness-ui-tasks--refresh-events'): a turn's start or end, a
session's status, the queue's switch, the limit (`config/changed') and
the merge queue's steps; a task's change or deletion, which the board
takes as they come; and a change of a session's priority, which is its
task's, and orders the queue."
  (or (member event '("task/changed" "task/deleted"))
      (member event harness-ui-tasks--refresh-events)
      (and (equal event "session/ext-changed")
           (member (format "%s" (cadr args)) '(":priority" "priority")))))

(defun harness-ui-slots--follow (buffer)
  "Have the page BUFFER catch up with an event.
Shown, it asks the harness again soon, once for a burst of events;
hidden, it is marked stale, to ask when it shows again."
  (if (harness-ui-view-follow-p buffer)
      (harness-ui-slots--refetch-soon buffer)
    (with-current-buffer buffer (setq harness-ui-slots--stale t))))

(defun harness-ui-slots--on-event (event args)
  "Have every page catch up with EVENT, with ARGS, when it may change their slots.
On `harness-ui-event-functions'."
  (when (harness-ui-slots--event-p event args)
    (mapc #'harness-ui-slots--follow (harness-ui-slots--buffers))))

(defun harness-ui-slots--on-window-change (window)
  "Ask again for the page WINDOW shows now, when it missed events while hidden.
On `window-buffer-change-functions' in the page's buffer.  The times on
it are drawn anew by `harness-ui-slots--on-resize' as it shows."
  (let ((buffer (window-buffer window)))
    (when (and (buffer-live-p buffer)
               (buffer-local-value 'harness-ui-slots--stale buffer))
      ;; The catch-up is on its way: the mark of a suspended view is not due.
      (harness-ui-view-drawn buffer)
      (harness-ui-slots--refetch-soon buffer 0.1))))

(defconst harness-ui-slots--pending-delay 0.15
  "Seconds `harness-ui-slots--on-pending' waits for more changes before it draws.")

(defun harness-ui-slots--on-pending (_session-id)
  "Draw every page a window shows again soon, for what its tasks wait on.
On `harness-ui-pending-changed-hook': a request a blocked task waits on
came, or was answered, which its row says under it, a little before the
harness says that task is blocked no longer.  Once for a burst, and
nothing is asked of the harness."
  (when (harness-ui-slots--buffers)
    (harness-debounce 'harness-ui-slots-pending harness-ui-slots--pending-delay
                      #'harness-ui-slots--on-tick)))

(defun harness-ui-slots--on-tick ()
  "Draw every page a window shows again, for the times on it.
On `harness-ui-tasks-tick-hook', the task boards' clock.  It asks the
harness for nothing: the times run from the last answer, and a page
whose text reads the same is left alone (`harness-ui-slots--render')."
  (dolist (buffer (harness-ui-slots--buffers))
    (when (harness-ui-slots--shown-p buffer)
      (with-current-buffer buffer (harness-ui-slots--render)))))

;;;; Mode and commands

(defvar harness-ui-slots-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'harness-ui-slots-refresh)
    (define-key map (kbd "q") #'harness-ui-quit-view)
    (define-key map (kbd "C-c C-z") #'harness-ui-bury)
    (define-key map (kbd "RET") #'harness-ui-slots-open)
    (define-key map [mouse-1] #'harness-ui-slots-mouse-open)
    ;; Not n and p: on the lines of a task that waits on a permission
    ;; request, n denies it, as in the session list and on the board.
    (define-key map (kbd "TAB") #'harness-ui-slots-next-row)
    (define-key map (kbd "<backtab>") #'harness-ui-slots-previous-row)
    ;; What the task at point waits on, as in the session list.
    (define-key map (kbd "SPC") #'harness-ui-sessions-requests)
    (define-key map (kbd "l") #'harness-ui-slots-set-limit)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-slots-mode'.")

(define-derived-mode harness-ui-slots-mode special-mode "Slots"
  "Major mode of the task slots page.
\\<harness-ui-slots-mode-map>\\[harness-ui-slots-open] opens the session of the task in the row at point;
\\[harness-ui-slots-next-row] and \\[harness-ui-slots-previous-row] go from row to row;
\\[harness-ui-sessions-requests] pops out what the task at point waits on, and y and n
answer a permission request on its line, as in the session list;
\\[harness-ui-slots-set-limit] sets how many tasks may work at once;
\\[harness-ui-slots-refresh] asks the harness again."
  ;; The first line may wrap in a narrow window: at a space, not in a word.
  (setq truncate-lines nil
        word-wrap t)
  (buffer-disable-undo)
  ;; The session at point is the one of the row there, for the commands
  ;; that act on it (the popout of what it waits on, a priority, y and n).
  (setq-local harness-ui-session-at-point-function #'harness-ui-slots--session-at-point)
  (add-hook 'window-configuration-change-hook #'harness-ui-slots--on-resize nil t)
  ;; Shown again after events it missed, it asks again.
  (add-hook 'window-buffer-change-functions #'harness-ui-slots--on-window-change nil t)
  ;; Says [Suspended: resume] if a window shows it before it did.
  (harness-ui-view-adopt (lambda () (harness-ui-slots--load (current-buffer)))))

;; The page's keys in the harness menu, behind `.'.
(put 'harness-ui-slots-mode 'harness-menu-group
     '("Task slots"
       ["Task at point"
        (". RET" "Open its session" harness-ui-slots-open)
        (". SPC" "View what it waits on" harness-ui-sessions-requests)
        (". TAB" "Next task" harness-ui-slots-next-row)]
       ["Page"
        (". l" "Set how many tasks work at once" harness-ui-slots-set-limit)
        (". g" "Refresh" harness-ui-slots-refresh)]))

(defun harness-ui-slots--session-at-point ()
  "Return the id of the session of the task in the row at point, or nil."
  (and (derived-mode-p 'harness-ui-slots-mode)
       (get-text-property (point) 'harness-slot-session)))

(defun harness-ui-slots--default-dir ()
  "Return the directory a new page is opened for.
That is the directory of the task board it is opened from, else the
project the current directory is in."
  (or harness-ui-tasks--dir (harness-ui--default-directory)))

;;;###autoload
(defun harness-slots (&optional dir)
  "Show how the task slots of DIR's project are used.
The tasks that hold the slots, as the session list lists sessions: their
status, priority, context and cost, and for how long each has worked.
Then the queue of tasks waiting for a slot by priority, who is next in
line, and how long tasks waited lately.  DIR defaults to the project of
the task board this is
run from, else of the current directory.  See
`harness-ui-slots-mode' for the keys."
  (interactive)
  (let ((dir (file-name-as-directory (expand-file-name (or dir (harness-ui-slots--default-dir)))))
        (buffer (get-buffer-create harness-ui-slots--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-slots-mode) (harness-ui-slots-mode))
      ;; Another project's page does not show while this one's comes.
      (unless (equal dir harness-ui-slots--dir)
        (setq harness-ui-slots--dir dir
              harness-ui-slots--data nil
              harness-ui-slots--error nil))
      (setq harness-ui-slots--loading (null harness-ui-slots--data))
      (harness-ui-slots--render t))
    (harness-ui-display-view buffer)
    (harness-ui-slots--load buffer)
    buffer))

(defun harness-ui-slots-refresh ()
  "Ask the harness for the slots again."
  (interactive)
  (harness-ui-slots--load (current-buffer)))

(defun harness-ui-slots-open (&optional position)
  "Open the session of the task in the row at point, in POSITION.
By default it takes the page's own position, replacing the page, as the
session of a card of the task board does."
  (interactive)
  (let ((session (get-text-property (point) 'harness-slot-session)))
    (cond
     (session (funcall (harness-ui-session-opener position) session))
     ((get-text-property (point) 'harness-slot-task)
      (user-error "This task has not started its session yet"))
     (t (user-error "No task in a slot here")))))

(defun harness-ui-slots-mouse-open (event)
  "Open the session of the task in the row EVENT, a click, is on."
  (interactive "e")
  (mouse-set-point event)
  (when (get-text-property (point) 'harness-slot-index)
    (harness-ui-slots-open)))

(defun harness-ui-slots--row-starts ()
  "Return where the names of the rows start as (INDEX . POSITION), by index."
  (let ((pos (point-min)) starts)
    (while (setq pos (next-single-property-change pos 'harness-slot-top))
      (when-let* ((index (get-text-property pos 'harness-slot-top)))
        (push (cons index pos) starts)))
    (sort starts (lambda (a b) (< (car a) (car b))))))

(defun harness-ui-slots--move-row (step)
  "Move point to the name of the row STEP rows on (back when negative).
From outside any row it goes to the next one below, or above for a
negative STEP.  It wraps around."
  (let* ((starts (or (harness-ui-slots--row-starts) (user-error "No slots in use here")))
         (current (get-text-property (point) 'harness-slot-index))
         (target (if current
                     (nth (mod (+ (or (cl-position current starts :key #'car) 0) step) (length starts))
                          starts)
                   (if (> step 0)
                       (or (cl-find-if (lambda (s) (> (cdr s) (point))) starts) (car starts))
                     (or (cl-find-if (lambda (s) (< (cdr s) (point))) starts :from-end t)
                         (car (last starts)))))))
    (goto-char (cdr target))))

(defun harness-ui-slots-next-row ()
  "Move to the next task in a slot."
  (interactive)
  (harness-ui-slots--move-row 1))

(defun harness-ui-slots-previous-row ()
  "Move to the previous task in a slot."
  (interactive)
  (harness-ui-slots--move-row -1))

(defun harness-ui-slots-set-limit ()
  "Ask how many tasks of a project may work at once, and set it.
It is the task board's \"N at a time\" button
\(`harness-ui-tasks-set-max-running'): the limit is saved for every
project and across restarts.  The page shows the new limit when the
harness has it, a moment after."
  (interactive)
  (let ((buffer (current-buffer)))
    (harness-ui-tasks-set-max-running
     (harness-ui-tasks--read-max-running (harness-ui-slots--limit harness-ui-slots--data)))
    (harness-ui-slots--refetch-soon buffer)))

;;;; Module

(defun harness-ui-slots--buffers ()
  "Return every live task slots page."
  (cl-remove-if-not (lambda (buffer) (eq (buffer-local-value 'major-mode buffer) 'harness-ui-slots-mode))
                    (buffer-list)))

(defun harness-ui-slots--redraw-all ()
  "Draw every page again, and have it catch up, as after a reload or reconnect.
Events may have gone by meanwhile: a page a window shows asks the
harness again, a hidden one when it shows (`harness-ui-slots--follow')."
  (dolist (buffer (harness-ui-slots--buffers))
    (with-current-buffer buffer (harness-ui-slots--render t))
    (harness-ui-slots--follow buffer)))

(defun harness-ui-slots--init ()
  "Wire the task slots page into the UI.
Every page follows the harness's events, the requests the tasks in its
rows wait on and the task boards' clock, and
`harness-slots' is Q (the queue) in `harness-ui-map', as in the menu."
  (add-hook 'harness-ui-redraw-hook #'harness-ui-slots--redraw-all)
  (add-hook 'harness-ui-event-functions #'harness-ui-slots--on-event)
  (add-hook 'harness-ui-pending-changed-hook #'harness-ui-slots--on-pending)
  (add-hook 'harness-ui-tasks-tick-hook #'harness-ui-slots--on-tick)
  (define-key harness-ui-map (kbd "Q") #'harness-slots))

(defun harness-ui-slots--shutdown ()
  "Stop following the events, the requests and the clock; take the key back."
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-slots--redraw-all)
  (remove-hook 'harness-ui-event-functions #'harness-ui-slots--on-event)
  (remove-hook 'harness-ui-pending-changed-hook #'harness-ui-slots--on-pending)
  (remove-hook 'harness-ui-tasks-tick-hook #'harness-ui-slots--on-tick)
  (when (eq (lookup-key harness-ui-map (kbd "Q")) #'harness-slots)
    (define-key harness-ui-map (kbd "Q") nil)))

(harness-define-module 'ui-slots
  :doc "The task slots page: the tasks that hold slots as the session list lists sessions, the queue and its waits by priority."
  :requires '(ui ui-tasks)
  :init #'harness-ui-slots--init
  :shutdown #'harness-ui-slots--shutdown)

(provide 'harness-ui-slots)
;;; harness-ui-slots.el ends here
