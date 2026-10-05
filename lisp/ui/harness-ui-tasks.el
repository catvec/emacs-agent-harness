;;; harness-ui-tasks.el --- Task mode: a kanban of one-session tasks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Task mode manages sessions by the task each one completes (see the
;; `tasks' module).  Its buffer is a small kanban for the current
;; project, one section per column, most urgent first:
;;
;;   Requires your input   blocked on a permission or question, stopped,
;;                         or refused by its write-up as a duplicate:
;;                         drop it, or have it written up all the same
;;   Ready for review      finished, waiting for you: verify it (v), which
;;                         merges it, or send it back with feedback (R)
;;   Merging               in the merge queue, in the order it takes them:
;;                         queued, merging, or resolving the conflicts
;;   In progress           working, with its current todo and progress
;;   Pending               waiting for a slot, or in the backlog (refined,
;;                         waiting for you); editable, startable
;;   Completed             finished and verified; reply to reopen,
;;                         archive to hide
;;
;; and a compose box at the bottom: describe a task, C-c C-c submits it
;; and it gets a session of its own.  A toggle above the box (C-c C-t)
;; switches between Submit, which starts the task, and Refine (backlog
;; refinement, once called grooming), which has an agent write the task
;; up and leaves it in Pending until you start it: jot things down now,
;; pick them up later, even after a restart.  The same box edits a
;; pending task (e), replies to a task's session (m) -- for a backlog
;; task that is feedback on its write-up (r) -- without leaving the
;; board, answers a task's question (m or [Answer]) and takes the
;; feedback that sends a task back from review (R, or m: any message to
;; a task in review sends it back); C-g leaves such a box for a new task
;; again, the question still waiting.
;; RET or a click on a task opens its session in full.  b or [BTW] asks
;; about the tasks in a BTW side conversation over the board, whose agent
;; answers with the task and session tools (`task/btw').  / or [Search]
;; finds tasks, or acts on them, from a line in words that a cheap model
;; reads with the board; the board then shows only the tasks it is about
;; (harness-ui-tasks-search.el, through `harness-ui-tasks-filter').
;;
;; Review can be turned off (V, or the [Review: on] switch in the header
;; line): finished tasks then merge and complete by themselves, and Ready
;; for review shows only while tasks from before still wait there.  The
;; switch is the harness option `harness-tasks-require-verification', so
;; it holds for every board and across restarts.
;;
;; Everything comes over ACP (`_harness/task/…', `_harness/config/set'
;; for the Review switch, plus the session cache), so the board works
;; against a remote harness too.  The list region is
;; redrawn as a whole when anything changes -- a board holds tens of
;; tasks, not a transcript -- while the compose box is never touched.
;; Point and every window showing the board stay where they were through
;; it all: on the same line of the same card, on the same button.  A
;; click on a button pushes it, however long the click takes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'text-property-search)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-pending)

(defgroup harness-ui-tasks nil
  "Task mode." :group 'harness-ui)


(defconst harness-ui-tasks--tick-interval 15
  "Seconds between refreshes of the elapsed times on visible boards.")

(defcustom harness-ui-tasks-refine-by-default nil
  "When non-nil, new boards refine tasks for the backlog, not submit them.
Either way the toggle above the compose box switches it per board."
  :type 'boolean :group 'harness-ui-tasks)

(defconst harness-ui-tasks--notify-review t
  "When non-nil, say in the echo area when a task waits for your review.")

(defface harness-task-title-face '((t :inherit bold))
  "Task titles." :group 'harness-ui-tasks)
(defface harness-task-section-face '((t :inherit (harness-label-face) :height 1.05))
  "Column headings." :group 'harness-ui-tasks)
(defface harness-task-attention-face '((t :inherit harness-status-blocked-face))
  "Why a task needs the user." :group 'harness-ui-tasks)
(defface harness-task-done-face '((t :inherit success))
  "The completed mark." :group 'harness-ui-tasks)
(defface harness-task-review-face '((t :inherit success :weight bold))
  "Tasks waiting for your review: their mark, heading and count." :group 'harness-ui-tasks)
(defface harness-task-review-off-face '((t :inherit warning))
  "The Review switch while finished tasks merge without your review." :group 'harness-ui-tasks)
(defface harness-task-merging-face '((t :inherit harness-dim-face))
  "The mark of a task waiting in the merge queue." :group 'harness-ui-tasks)
(defface harness-task-choice-face '((t :inherit bold))
  "The Submit / Refine toggle, which shows the current mode." :group 'harness-ui-tasks)

(define-icon harness-icon-task-pending nil
  '((symbol "◌") (text "wait"))
  "Pending task." :version "29.1")
(define-icon harness-icon-task-done nil
  '((symbol "✓") (text "done"))
  "Completed task." :version "29.1")
(define-icon harness-icon-task-stopped nil
  '((symbol "■") (text "stop"))
  "Stopped task." :version "29.1")
(define-icon harness-icon-task-review nil
  `((symbol ,(string #x2691)) (text "review"))
  "Task waiting for your review: a flag." :version "29.1")
(define-icon harness-icon-task-merging nil
  `((symbol ,(string #x21a3)) (text "merge"))
  "Task in the merge queue: an arrow feeding into a line." :version "29.1")
(harness-ui-define-icon harness-icon-message "message" "→" "msg"
  "A message to the session of an existing task.")

(defconst harness-ui-tasks--columns
  '((needs-input "Requires your input" t) (review "Ready for review") (merging "Merging" t)
    (active "In progress") (pending "Pending") (done "Completed"))
  "Columns in display order: (COLUMN HEADING &optional SUBTITLE-SHOWN).
SUBTITLE-SHOWN is non-nil when the cards of the column show their
recap subtitle by default; elsewhere a card is one line until you
show it (see `harness-ui-tasks-toggle-subtitle').")

;;;; Buffer state

(defvar harness-ui-tasks-board-map)
(defvar harness-ui-btw-start-function)
(defvar harness-ui-btw-about)
(declare-function harness-btw "harness-ui-btw")
(declare-function harness-ui-popout-at-point "harness-ui-popout")
(declare-function harness-ui-popout-try-at-point "harness-ui-popout")

(defmacro harness-ui-tasks--with-task (id &rest body)
  "Run BODY with point on task ID's card.
Point already on the card stays where it is: on the button pushed, say,
rather than going up to the card's first line."
  (declare (indent 1))
  (let ((key (make-symbol "id")))
    `(let ((,key ,id))
       (unless (equal (get-text-property (point) 'harness-task-id) ,key)
         (let ((match (save-excursion (goto-char (point-min))
                                      (text-property-search-forward 'harness-task-id ,key #'equal))))
           (when match (goto-char (prop-match-beginning match)))))
       ,@body)))


(defvar-local harness-ui-tasks--dir nil "Directory the board was opened for.")
(defvar-local harness-ui-tasks--project nil "Project root reported by the harness.")
(defvar-local harness-ui-tasks--tasks nil "Task plists (wire shape).")
(defvar-local harness-ui-tasks--settings nil "What `task/settings' returned.")
(defvar-local harness-ui-tasks--new nil
  "Settings the next submitted task starts with: a plist of `:model',
`:thinking', `:permission-mode' and `:non-interactive', seeded from the
harness's task defaults and changed with the usual session commands.")
(defvar-local harness-ui-tasks--loading t)
(defvar-local harness-ui-tasks--error nil "Last failure, shown above the compose box.")
(defvar-local harness-ui-tasks--show-archived nil)
(defvar-local harness-ui-tasks--folded nil "Columns whose section is folded.")
(defvar-local harness-ui-tasks--subtitles nil
  "Alist of task id -> whether your choice shows its recap subtitle.
Only cards you toggled are in it; the rest follow their column
\(see `harness-ui-tasks--columns').")
(defvar-local harness-ui-tasks--expanded nil
  "Columns whose section shows every task, whatever the window holds.
The board fits its window by capping the least urgent sections; a
section opened with its \"… N more  [Show all]\" line is left whole.")
(defvar-local harness-ui-tasks--submitting nil "Prompts sent but not yet acknowledged.")
(defvar-local harness-ui-tasks--target nil
  "What the compose box does: nil for a new task, else (KIND . ID).
KIND is edit, reply, answer, refine (feedback on a backlog task's
write-up) or reject (feedback that sends a task back from review).")
(defvar-local harness-ui-tasks--refine nil
  "Non-nil when new tasks are refined for the backlog, not submitted.")
(defvar-local harness-ui-tasks--bulk nil
  "Non-nil when the setting buttons change every current task at once.")
(defvar-local harness-ui-tasks--list-end nil "Marker: end of the board, start of the tail.")

(defvar-local harness-ui-tasks-filter nil
  "When non-nil, the board shows some of its tasks only, and says so.
A plist: `:show', a function of a task, non-nil for those shown --
archived ones too, whatever [Archived] says; `:banner', a function
returning the text drawn above the columns, whole lines; `:clear', a
function that drops the filter, which C-g on the board calls (see
`harness-ui-tasks-compose-quit').  The columns without a task to show
are left out.  The board's search sets it (`harness-ui-tasks-search').")

(defvar harness-ui-tasks-header-functions nil
  "Functions returning a segment of a board's header line, or nil.
Each is called in the board's buffer as the header line is drawn; the
segments show before [BTW], in order.")

(defun harness-ui-tasks--board-p (buffer)
  "Non-nil when BUFFER is a live task board.
Window hooks and timers hand over whatever buffer a window shows by the
time they run -- a session that replaced the board, say -- so every way
into the board's drawing and loading checks this first."
  (and (buffer-live-p buffer) (eq (buffer-local-value 'major-mode buffer) 'harness-ui-tasks-mode)))

(defun harness-ui-tasks--buffers ()
  "Return every live board buffer."
  (cl-remove-if-not #'harness-ui-tasks--board-p (buffer-list)))

(defun harness-ui-tasks--find (id)
  "Return task ID of this board."
  (cl-find id harness-ui-tasks--tasks :key (lambda (task) (plist-get task :id)) :test #'equal))

(defun harness-ui-tasks--merge-queue-p (task)
  "Non-nil when TASK holds a place in the merge queue.
That is queued, merging, or its session resolving the merge's conflicts;
the task record says so through `:merge-status' as soon as it changes."
  (and (plist-get task :merge-status) t))

(defun harness-ui-tasks--merge-queued (task)
  "When TASK joined the merge queue, else 0."
  (or (plist-get task :merge-queued) 0))

(defun harness-ui-tasks--column (task)
  "Return TASK's column as a symbol."
  (intern (or (plist-get task :column)
              (cond ((harness-ui-tasks--merge-queue-p task) "merging")
                    (t (pcase (plist-get task :state)
                         ("pending" "pending") ("review" "review") ("merging" "merging") ("done" "done")
                         (_ "active")))))))

(defun harness-ui-tasks--archived-p (task)
  (harness-json-true-p (plist-get task :archived)))

(defun harness-ui-tasks--backlog-p (task)
  "Non-nil when TASK is in the backlog: it starts only when you start it."
  (harness-json-true-p (plist-get task :backlog)))

(defun harness-ui-tasks--refining-p (task)
  "Non-nil while an agent writes TASK up, or after its write-up stopped."
  (equal (plist-get task :state) "refining"))

(defun harness-ui-tasks--unstarted-p (task)
  "Non-nil when TASK has not started: queued, in the backlog or being written up."
  (member (plist-get task :state) '("pending" "refining")))

(defun harness-ui-tasks--writing-p (task)
  "Non-nil while an agent writes TASK up: refining and not stopped.
The task record says so as soon as it changes, unlike the session cache."
  (and (harness-ui-tasks--refining-p task) (null (plist-get task :outcome))))

(defun harness-ui-tasks--review-p ()
  "Non-nil when finished tasks wait for your review before they merge.
That is the harness's `task/settings' as last fetched: review is on, as
it is by default, until they say it is off."
  (not (eq (plist-get harness-ui-tasks--settings :require-verification) :false)))

(defun harness-ui-tasks--duplicate-p (task)
  "Non-nil when TASK's write-up refused it as a duplicate of another task."
  (and (harness-ui-tasks--refining-p task) (equal (plist-get task :outcome) "duplicate")))

(defun harness-ui-tasks--started (task)
  "When TASK started, else when it was submitted, else 0."
  (or (plist-get task :started) (plist-get task :created) 0))

(defun harness-ui-tasks--completed (task)
  "When TASK was completed: verified, else finished, else 0."
  (or (plist-get task :verified-at) (plist-get task :finished) 0))

(defun harness-ui-tasks--visible (&optional filtered)
  "Return the tasks shown, as an alist COLUMN -> tasks in display order.
In progress is newest first by when each task started, review by when
it finished and completed by when it was completed, so a task arriving
in any of them shows at the top; merging is the queue's own order, from
when each branch joined it; the other columns are oldest first, pending
in the order its tasks start.  With FILTERED, only the tasks
`harness-ui-tasks-filter' shows, when there is one, archived or not."
  (let ((groups (mapcar (lambda (c) (list (car c))) harness-ui-tasks--columns))
        (show (and filtered (plist-get harness-ui-tasks-filter :show))))
    (dolist (task harness-ui-tasks--tasks)
      (when (if show
                (funcall show task)
              (not (and (harness-ui-tasks--archived-p task) (not harness-ui-tasks--show-archived))))
        (push task (cdr (assq (harness-ui-tasks--column task) groups)))))
    (dolist (g groups groups)
      (setcdr g (sort (cdr g)
                      (pcase (car g)
                        ('active (lambda (a b) (> (harness-ui-tasks--started a) (harness-ui-tasks--started b))))
                        ('review (lambda (a b) (> (or (plist-get a :finished) 0) (or (plist-get b :finished) 0))))
                        ('merging (lambda (a b) (< (harness-ui-tasks--merge-queued a)
                                                   (harness-ui-tasks--merge-queued b))))
                        ('done (lambda (a b) (> (harness-ui-tasks--completed a) (harness-ui-tasks--completed b))))
                        (_ (lambda (a b) (< (or (plist-get a :created) 0) (or (plist-get b :created) 0))))))))))

;;;; What a card says

(defun harness-ui-tasks--session (task)
  (and (plist-get task :session) (harness-ui-session (plist-get task :session))))

(defun harness-ui-tasks--title (task)
  "The session's name once it has one, else the prompt's first line.
The session list names a task's session the same way."
  (harness-ui-task-title task))

(defun harness-ui-tasks--todos (session)
  "Return (DONE TOTAL CURRENT-TEXT) for SESSION's todo list, or nil."
  (let ((todos (plist-get session :todos)))
    (when todos
      (list (cl-count "done" todos :key (lambda (td) (plist-get td :status)) :test #'equal)
            (length todos)
            (plist-get (cl-find "in-progress" todos :key (lambda (td) (plist-get td :status)) :test #'equal)
                       :text)))))

(defun harness-ui-tasks--request (session)
  "Say what kind of input the first pending request of SESSION needs.
Only the kind: the full request is shown by `harness-ui-tasks-requests',
or read in the session."
  (harness-ui-pending-summary session))

(defun harness-ui-tasks--wide-icon-p (icon)
  "Non-nil when ICON is drawn as an image, which is about two columns wide.
Terminals fall back to a one-column symbol, which needs no extra room."
  (and (> (length icon) 0)
       (eq 'image (car-safe (get-text-property 0 'display icon)))))

(defun harness-ui-tasks--mark-nudge (icon)
  "Pixels to move a wide ICON left so it centres on the one-column grid.
The icon is an image with its ink centred, about a column wider than the
stopped square it stands next to; half that extra width puts the two
marks on the same centre."
  (let ((nudge (/ (- (string-pixel-width icon) (frame-char-width)) 2)))
    (and (> nudge 0) nudge)))

(defun harness-ui-tasks--pad (pixels)
  "A space PIXELS pixels wide, an absolute pixel specification."
  (propertize " " 'display (list 'space :width (list pixels))))

(defun harness-ui-tasks--merge-status (task)
  "TASK's merge status as a string: \"queued\", \"merging\" or \"conflict\"."
  (let ((status (plist-get task :merge-status)))
    (and status (format "%s" status))))

(defun harness-ui-tasks--icon (task column session)
  (pcase column
    ('pending (cond ((harness-ui-tasks--refining-p task) (harness-ui-status-icon "running"))
                    ((harness-ui-tasks--backlog-p task)
                     (propertize (harness-ui-icon 'harness-icon-agent) 'face 'harness-dim-face))
                    (t (propertize (harness-ui-icon 'harness-icon-task-pending) 'face 'harness-dim-face))))
    ('done (propertize (harness-ui-icon 'harness-icon-task-done) 'face 'harness-task-done-face))
    ('review (propertize (harness-ui-icon 'harness-icon-task-review) 'face 'harness-task-review-face))
    ('merging (if (equal (harness-ui-tasks--merge-status task) "queued")
                  (propertize (harness-ui-icon 'harness-icon-task-merging) 'face 'harness-task-merging-face)
                (harness-ui-status-icon "running")))
    ('needs-input (if (plist-get session :pending)
                      (harness-ui-status-icon "blocked")
                    (propertize (harness-ui-icon 'harness-icon-task-stopped) 'face 'harness-task-attention-face)))
    (_ (if (plist-get task :session) (harness-ui-status-icon "running")
         (harness-ui-status-icon "idle")))))

(defun harness-ui-tasks--detail (task column session position)
  "The second line of TASK's card."
  (let ((todos (harness-ui-tasks--todos session))
        (named (not (harness-string-blank-p (plist-get session :name)))))
    (pcase column
      ('needs-input
       (propertize (or (harness-ui-tasks--request session)
                       (pcase (plist-get task :outcome)
                         ("merge-failed" (format "could not merge into %s: %s" (harness-ui-tasks--base task)
                                                 (or (plist-get task :error) "?")))
                         ("adopted" "waiting for your next message")
                         ((and "interrupted" (guard (harness-ui-tasks--refining-p task)))
                          "a restart interrupted its write-up: retry it, or edit it by hand")
                         ((guard (harness-ui-tasks--duplicate-p task)) (harness-ui-tasks--duplicate-detail task))
                         (outcome (format "%s: %s%s"
                                          (if (harness-ui-tasks--refining-p task) "write-up stopped" "stopped")
                                          (or outcome "?")
                                          (if (plist-get task :error) (concat " — " (plist-get task :error)) "")))))
                   'face 'harness-task-attention-face))
      ('merging
       (propertize (pcase (harness-ui-tasks--merge-status task)
                     ("merging" (format "merging into %s…" (harness-ui-tasks--base task)))
                     ("conflict" (let ((files (take 3 (plist-get task :conflicts))))
                                  (if files
                                      (format "resolving merge conflicts in %s" (string-join files ", "))
                                    "resolving merge conflicts")))
                     (_ (format "queued to merge into %s" (harness-ui-tasks--base task))))
                   'face 'harness-dim-face))
      ('active (propertize (or (nth 2 todos)
                               (cond (named (harness-first-line (plist-get task :prompt) 90))
                                     ((equal (plist-get session :status) "running") "working…")
                                     (t "starting…")))
                           'face 'harness-dim-face))
      ('pending (propertize (harness-ui-tasks--pending-detail task position todos)
                            'face 'harness-dim-face))
      ('review (propertize (harness-ui-tasks--review-detail task named) 'face 'harness-dim-face))
      ('done (propertize (let ((took (and (plist-get task :started) (plist-get task :finished)
                                          (format "took %s" (harness-ui-tasks--elapsed
                                                             (- (plist-get task :finished) (plist-get task :started)))))))
                           (string-join
                            (delq nil (list (and named (harness-first-line (plist-get task :prompt) 70))
                                            (and (harness-json-true-p (plist-get task :merged))
                                                 (format "merged into %s" (harness-ui-tasks--base task)))
                                            took))
                            " · "))
                         'face 'harness-dim-face)))))

(defun harness-ui-tasks--duplicate-detail (task)
  "The second line of TASK's card once its write-up refused it as a duplicate.
It names the task TASK duplicates, by its title when it is on the board,
then says why, in the words of the agent that refused it."
  (let* ((of (plist-get task :duplicate-of))
         (original (and of (harness-ui-tasks--find of)))
         (why (plist-get task :error)))
    (concat (cond (original (concat "duplicate of " (harness-ui-tasks--quote (harness-ui-tasks--title original))))
                  (of (format "duplicate of %s" of))
                  (t "refused as a duplicate"))
            (if (harness-string-blank-p why)
                ""
              (concat " — " (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " why)))))))

(defun harness-ui-tasks--body-line (task)
  "The first line of TASK's prompt after its first, shortened; nil if none.
For a write-up that is the start of its body, under the title, read as
plain text: no list, heading or emphasis markers."
  (when-let* ((line (cadr (split-string (or (plist-get task :prompt) "") "\n" t "[ \t]+")))
              (plain (string-trim
                      (replace-regexp-in-string
                       "\\*\\*\\|__\\|`" ""
                       (replace-regexp-in-string "\\`\\(?:#+\\|[-*+]\\|[0-9]+[.)]\\)[ \t]+" "" line))))
              ((not (string-empty-p plain))))
    (harness-first-line plain 70)))

(defconst harness-ui-tasks--dot (string #xb7)
  "The middle dot that separates the facts on a card.")

(defconst harness-ui-tasks--ellipsis (string #x2026)
  "The ellipsis of a hint or a pending state.")

(defun harness-ui-tasks--quote (text)
  "TEXT between curly double quotes, as the compose labels name a task."
  (concat (string #x201c) text (string #x201d)))

;;;; The subtitle

;; A card's second line is its subtitle: the recap a short model call
;; wrote (`harness-tasks-recap').  It is folded away on most cards -- you
;; see one line per task -- except where it matters most, on a task that
;; needs your input or one whose branch holds a place in the merge
;; queue, and on the cards you show it on yourself.

(defun harness-ui-tasks--subtitle-shown-p (task)
  "Non-nil when TASK's card shows its subtitle now.
Your own choice for the task wins over its column's default."
  (let ((choice (assoc (plist-get task :id) harness-ui-tasks--subtitles)))
    (if choice (cdr choice)
      (nth 2 (assq (harness-ui-tasks--column task) harness-ui-tasks--columns)))))

(defun harness-ui-tasks--set-subtitle (id shown)
  "Show or hide the subtitle of task ID from now on, whatever its column."
  (setq harness-ui-tasks--subtitles
        (cons (cons id shown) (assoc-delete-all id harness-ui-tasks--subtitles))))

(defun harness-ui-tasks--subtitle (task column session position room)
  "The text under TASK's title, at most ROOM columns wide: its recap,
else the old detail line.  In the needs-input and merging columns the
detail stays after the recap, since those cards show their subtitle by
default and the recap must not hide what the task waits for, or where
its branch stands."
  (let* ((recap (plist-get task :recap))
         (recap (and (stringp recap) (not (harness-string-blank-p recap)) (string-trim recap)))
         (detail (harness-ui-tasks--detail task column session position))
         (sep (concat " " harness-ui-tasks--dot " ")))
    (cond
     ((null recap) (harness-ui-tasks--fit (or detail "") room))
     ((and (memq column '(needs-input merging)) detail)
      (harness-ui-tasks--fit
       (concat (harness-ui-tasks--fit (propertize recap 'face 'harness-dim-face)
                                      (- room (string-width detail) (string-width sep)))
               sep detail)
       room))
     (t (harness-ui-tasks--fit (propertize recap 'face 'harness-dim-face) room)))))

(defun harness-ui-tasks--pending-detail (task position todos)
  "The second line of pending TASK's card: what it waits for.
POSITION is its place in line among queued tasks; TODOS its session's."
  (let ((body (harness-ui-tasks--body-line task))
        (sep (concat " " harness-ui-tasks--dot " ")))
    (cond
     ((harness-ui-tasks--refining-p task)
      (or (nth 2 todos) (concat "an agent is writing it up" harness-ui-tasks--ellipsis)))
     ((harness-ui-tasks--backlog-p task)
      (concat (if (plist-get task :refined) "refined, start it when ready" "on hold")
              (if body (concat sep body) "")))
     (t (format "#%d in line%s" (or position 1) (if body (concat sep body) ""))))))

(defun harness-ui-tasks--took (task)
  "How long TASK worked until it finished, as \"took 12m\"; nil if unknown."
  (let ((started (plist-get task :started))
        (finished (plist-get task :finished)))
    (and started finished (format "took %s" (harness-ui-tasks--elapsed (- finished started))))))

(defun harness-ui-tasks--times (n)
  "N as a number of times: once, twice, 3 times."
  (pcase n (1 "once") (2 "twice") (_ (format "%d times" n))))

(defun harness-ui-tasks--review-detail (task named)
  "The second line of TASK's card in review: what verifying it does.
NAMED is non-nil when its session has a name, which then is the
card's title, so the prompt shows here."
  (let ((rounds (length (plist-get task :feedback))))
    (string-join
     (delq nil (list (and named (harness-first-line (plist-get task :prompt) 70))
                     (cond ((harness-json-true-p (plist-get task :merged))
                            (format "merged into %s" (harness-ui-tasks--base task)))
                           ((plist-get task :worktree)
                            (format "merges into %s once verified" (harness-ui-tasks--base task))))
                     (harness-ui-tasks--took task)
                     (and (> rounds 0) (format "sent back %s" (harness-ui-tasks--times rounds)))))
     (concat " " harness-ui-tasks--dot " "))))

(defun harness-ui-tasks--base (task)
  "The branch TASK merges into."
  (or (plist-get task :base) "main"))

(defun harness-ui-tasks--meta (task column session)
  "The right-aligned facts of TASK's card."
  (let* ((todos (harness-ui-tasks--todos session))
         (started (plist-get task :started))
         (usage (plist-get session :usage))
         (parts
          (delq nil
                (list (and (harness-json-true-p (plist-get task :main-tree)) "main tree")
                      (and todos (not (memq column '(done review merging)))
                           (format "%d/%d" (nth 0 todos) (nth 1 todos)))
                      (pcase column
                        ('pending (cond ((harness-ui-tasks--refining-p task) nil)
                                        ((plist-get task :refined)
                                         (format "refined %s" (harness-relative-time (plist-get task :refined))))
                                        ((harness-ui-tasks--backlog-p task)
                                         (format "added %s" (harness-relative-time (plist-get task :created))))
                                        (t (format "queued %s" (harness-relative-time (plist-get task :created))))))
                        ('review (and (plist-get task :finished)
                                      (format "ready %s" (harness-relative-time (plist-get task :finished)))))
                        ('merging (let ((queued (harness-ui-tasks--merge-queued task)))
                                    (and (> queued 0)
                                         (format "queued %s" (harness-relative-time queued)))))
                        ('done (let ((completed (harness-ui-tasks--completed task)))
                                 (and (> completed 0) (format "done %s" (harness-relative-time completed)))))
                        (_ (and started (harness-ui-tasks--elapsed (- (float-time) started)))))
                      (and session (> (harness-usage-list-cost usage) 0)
                           (harness-ui-format-spend session))))))
    (propertize (string-join parts " · ") 'face 'harness-dim-face)))

(defun harness-ui-tasks--elapsed (seconds)
  "Format SECONDS of work coarsely: 40s, 12m, 2h05m."
  (cond ((< seconds 60) (format "%ds" (truncate seconds)))
        ((< seconds 3600) (format "%dm" (truncate (/ seconds 60))))
        (t (format "%dh%02dm" (truncate (/ seconds 3600)) (truncate (/ (mod seconds 3600) 60))))))

;;;; Actions (shared by keys, buttons and the context menu)

(defun harness-ui-tasks--actions (task)
  "Return (LABEL COMMAND) for the actions that apply to TASK, primary first."
  (let ((column (harness-ui-tasks--column task)))
    (append
     (pcase column
       ('pending
        (cond
         ((harness-ui-tasks--refining-p task)
          '(("Open" harness-ui-tasks-open) ("Steer" harness-ui-tasks-reply)
            ("Stop" harness-ui-tasks-cancel)))
         ((plist-get task :session)
          '(("Start now" harness-ui-tasks-start) ("Edit" harness-ui-tasks-edit)
            ("Open" harness-ui-tasks-open) ("Refine" harness-ui-tasks-refine)
            ("Drop" harness-ui-tasks-cancel)))
         (t '(("Start now" harness-ui-tasks-start) ("Edit" harness-ui-tasks-edit)
              ("Refine" harness-ui-tasks-refine) ("Drop" harness-ui-tasks-cancel)))))
       ('needs-input
        (pcase (plist-get (harness-ui-tasks--pending task) :kind)
          ("permission" '(("Allow" harness-ui-tasks-allow) ("Deny" harness-ui-tasks-deny)
                          ("Request…" harness-ui-tasks-requests)
                          ("Open" harness-ui-tasks-open) ("Stop" harness-ui-tasks-cancel)))
          ("question" '(("Answer…" harness-ui-tasks-requests) ("Reply" harness-ui-tasks-reply)
                        ("Open" harness-ui-tasks-open)
                        ("Stop" harness-ui-tasks-cancel)))
          ;; The agent found the board has it already: you decide.
          ((guard (harness-ui-tasks--duplicate-p task))
           '(("Drop" harness-ui-tasks-cancel) ("Write it up" harness-ui-tasks-refine)
             ("Reply" harness-ui-tasks-reply) ("Edit" harness-ui-tasks-edit)
             ("Start now" harness-ui-tasks-start) ("Open" harness-ui-tasks-open)))
          ((guard (harness-ui-tasks--refining-p task))
           '(("Retry" harness-ui-tasks-refine) ("Edit" harness-ui-tasks-edit)
             ("Start now" harness-ui-tasks-start) ("Open" harness-ui-tasks-open)
             ("Drop" harness-ui-tasks-cancel)))
          (_ (if (equal (plist-get task :outcome) "merge-failed")
                 '(("Retry merge" harness-ui-tasks-merge) ("Reply" harness-ui-tasks-reply)
                   ("Open" harness-ui-tasks-open) ("Mark done" harness-ui-tasks-complete))
               '(("Open" harness-ui-tasks-open) ("Reply" harness-ui-tasks-reply)
                 ("Mark done" harness-ui-tasks-complete))))))
       ('active '(("Open" harness-ui-tasks-open) ("Steer" harness-ui-tasks-reply)
                  ("Stop" harness-ui-tasks-cancel)))
       ;; In the queue there is nothing to do but watch; a conflict is
       ;; resolved by its own session, which can be stopped, and a task
       ;; waiting for the queue's turn can be steered like a working one.
       ('merging (if (equal (plist-get (harness-ui-tasks--session task) :status) "running")
                     '(("Open" harness-ui-tasks-open) ("Stop" harness-ui-tasks-cancel))
                   '(("Open" harness-ui-tasks-open) ("Reply" harness-ui-tasks-reply)
                     ("Stop" harness-ui-tasks-cancel))))
       ('review (if (harness-ui-tasks--archived-p task)
                    '(("Unarchive" harness-ui-tasks-archive) ("Verify" harness-ui-tasks-verify)
                      ("Open" harness-ui-tasks-open))
                  ;; No Reply: a message to a task in review sends it back.
                  (append
                   '(("Verify" harness-ui-tasks-verify) ("Send back" harness-ui-tasks-reject)
                     ("Open" harness-ui-tasks-open))
                   (and (harness-ui-tasks--open-harness-p task)
                        '(("Open harness" harness-ui-tasks-open-harness)))
                   '(("Archive" harness-ui-tasks-archive)))))
       ('done (if (harness-ui-tasks--archived-p task)
                  '(("Unarchive" harness-ui-tasks-archive) ("Open" harness-ui-tasks-open))
                '(("Archive" harness-ui-tasks-archive) ("Reply" harness-ui-tasks-reply)
                  ("Open" harness-ui-tasks-open)))))
     ;; Before it starts a task runs with the settings it was submitted
     ;; with, not its write-up session's, so those are not offered.
     (when (and (plist-get task :session) (not (harness-ui-tasks--unstarted-p task)))
       '(("Model…" harness-set-model) ("Permission mode…" harness-set-permission-mode)
         ("Thinking…" harness-set-thinking) ("Non-interactive" harness-toggle-non-interactive)))
     '(("Delete…" harness-ui-tasks-delete)))))

(defvar harness-ui-tasks-button-map (make-sparse-keymap)
  "Keys on the buttons of a task board.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-ui-tasks-button-map))
  (set-keymap-parent map button-map)
  ;; Any click pushes a button.  A quick one would anyway: with
  ;; `mouse-1-click-follows-link', `mouse-1' turns into `mouse-2' when
  ;; Emacs reads the release soon enough after the press -- by the clock,
  ;; so a busy Emacs makes a quick click slow.  On the board a slow one
  ;; would reach the board's own `mouse-1' and open the task's session.
  (define-key map [mouse-1] #'push-button)
  ;; A double click pushes it once.  The second click would otherwise
  ;; run as a single one, a `mouse-1' on the board: open the session.
  (define-key map [double-mouse-1] #'ignore)
  (define-key map [triple-mouse-1] #'ignore))

(defun harness-ui-tasks--button (label action help &optional id)
  "Return a button string LABEL running ACTION (no arguments).
HELP is its tooltip.  ID names it for redraws, which keep point on the
same button (see `harness-ui-tasks--anchor'); it defaults to LABEL, so
a button whose label changes, a setting's value say, needs one."
  (propertize (buttonize label (lambda (_) (funcall action)) nil help)
              'keymap harness-ui-tasks-button-map
              'harness-task-button (or id label)))

(defun harness-ui-tasks--pending (task)
  "Return the request TASK's session waits on, or nil.
The pending module knows it as soon as it arrives; the session cache
may lag, so it is asked first."
  (or (car (harness-ui-pending-items (plist-get task :session)))
      (car (plist-get (harness-ui-tasks--session task) :pending))))

(defun harness-ui-tasks--card-buttons (task)
  "Buttons for TASK's two most useful actions besides opening it.
A task that handed a report in (`hand_in') gets a [Report] button too:
its final message and evidence, in a popout.  One whose turn ended
without it gets [No report] there instead, which pops out what the
harness recorded for it: that nothing was handed in, and the session's
last message (`harness-tasks--missing-report')."
  (let ((id (plist-get task :id))
        (missing (harness-json-true-p (plist-get (plist-get task :report) :missing))))
    (concat
     (mapconcat (lambda (a)
                  (harness-ui-tasks--button
                   (format "[%s]" (car a))
                   (lambda () (harness-ui-tasks--with-task id (call-interactively (nth 1 a))))
                   (car a) (nth 1 a)))
                (take 2 (cl-remove 'harness-ui-tasks-open (harness-ui-tasks--actions task) :key #'cadr))
                " ")
     (when (and (plist-get task :report) (fboundp 'harness-ui-report-popout))
       (concat " " (harness-ui-tasks--button
                     (if missing "[No report]" "[Report]")
                     (lambda () (harness-ui-report-popout task))
                     (if missing
                         "It handed no report in: no summary, no evidence; see what its session said last"
                       "What it handed in: the final message and the evidence")
                     "report")))
     (when (harness-ui-tasks--open-harness-p task)
       (concat " " (harness-ui-tasks--button
                    "[Open harness]"
                    (lambda () (harness-ui-tasks--with-task id (harness-ui-tasks-open-harness)))
                    "Open an Emacs running the harness from this task's worktree" "open-harness"))))))

(defun harness-ui-tasks--subtitle-button (task shown)
  "The chevron that shows or hides TASK's recap subtitle.
SHOWN is whether the subtitle shows now."
  (let ((id (plist-get task :id)))
    (harness-ui-tasks--button
     (propertize (harness-ui-icon (if shown 'harness-icon-expanded 'harness-icon-collapsed))
                 'face 'harness-dim-face)
     (lambda () (harness-ui-tasks--with-task id (harness-ui-tasks-toggle-subtitle)))
     (if shown "Hide the recap" "Show the recap")
     (concat "subtitle:" id))))

;;;; Rendering

(defun harness-ui-tasks--width ()
  "Width the board is drawn for: its widest window, or 100 when hidden."
  (let ((windows (get-buffer-window-list nil nil t)))
    (if windows (apply #'max (mapcar #'window-body-width windows)) 100)))

;;; Fitting the board to the window

;; The board sits above the compose box, which stays at the bottom of
;; the window.  A board taller than the room it has would push the box
;; off the bottom, where the box's padding and scrolling would then
;; fight over the window (see `harness-compose--follow').  So the board
;; is drawn to fit: the least urgent sections cap their lists first,
;; each saying how many tasks it holds back, and a section you expanded
;; keeps its whole list until folded again.

(defun harness-ui-tasks--window ()
  "Return the window the board should be drawn for.
The selected one while it shows the board, else its first visible
window, if any."
  (or (and (eq (window-buffer (selected-window)) (current-buffer)) (selected-window))
      (car (get-buffer-window-list nil nil t))))

(defun harness-ui-tasks--tail-key (window)
  "Return what the lines below the board say in WINDOW.
Their height is what the board must leave room for, and the caps depend
on it: a box that grew a line or a new attachment changes what fits."
  (when (and window harness-ui-tasks--list-end
             (< (marker-position harness-ui-tasks--list-end) (point-max)))
    ;; Without the padding: it fills the room that is left, and counting
    ;; it would make the caps depend on the board they were sized for, a
    ;; loop.  The next redisplay sizes it again.
    (harness-compose-repad window)
    (list (harness-ui-text-height window (marker-position harness-ui-tasks--list-end)
                                  (point-max) (window-body-height window t))
          (buffer-substring-no-properties (marker-position harness-ui-tasks--list-end) (point-max)))))

(defun harness-ui-tasks--fit (string room)
  "STRING shortened to ROOM columns (at least 12), keeping its properties."
  (let ((room (max 12 room)))
    (if (<= (string-width string) room)
        string
      (concat (truncate-string-to-width string (1- room)) "…"))))

(defconst harness-ui-tasks--min-title-room 24
  "Title columns a one-line card keeps before its facts are left out.
On a narrow board the buttons stay and the facts wait for a wider
window or for the card to be shown, so the title is not squeezed to
nothing.")

(defconst harness-ui-tasks--collapse-min-width 48
  "Board width below which cards keep their second line.
A one-line card shares its line with its buttons, and below this width
the title would be left with nothing; there cards stay two lines,
whatever the columns or your own toggles say.")

(defun harness-ui-tasks--more-line (n column)
  "The line saying a section holds back N more tasks of COLUMN.
It takes the place of the cards it hides; its [Show all] button opens
them, and a section already open gets [Show fewer] instead."
  (let ((start (point)))
    (insert (if (> n 0)
                (concat (propertize (format "    %s %d more" harness-ui-tasks--ellipsis n)
                                    'face 'harness-dim-face)
                        "  ")
              "    ")
            (if (memq column harness-ui-tasks--expanded)
                (harness-ui-tasks--button "[Show fewer]" #'harness-ui-tasks-show-fewer
                                          "Let the section fit the window again")
              (harness-ui-tasks--button "[Show all]" #'harness-ui-tasks-show-all
                                        "Show every task of this section, however tall it is"))
            "\n")
    ;; The line belongs to its column, so its buttons know which one they open.
    (put-text-property start (point) 'harness-task-more column)))

(defun harness-ui-tasks-show-all ()
  "Show every task of the section at point, however tall it makes the board."
  (interactive)
  (when-let* ((column (or (get-text-property (point) 'harness-task-section)
                          (get-text-property (point) 'harness-task-more))))
    (setq harness-ui-tasks--expanded (cons column harness-ui-tasks--expanded))
    (harness-ui-tasks--render t)
    (message "Showing every task of this section")))

(defun harness-ui-tasks-show-fewer ()
  "Let the section at point fit the window again."
  (interactive)
  (when-let* ((column (or (get-text-property (point) 'harness-task-section)
                          (get-text-property (point) 'harness-task-more))))
    (setq harness-ui-tasks--expanded (delq column harness-ui-tasks--expanded))
    (harness-ui-tasks--render t)))

(defconst harness-ui-tasks--cap-min-lines 24
  "Fewest lines of room a window must have before sections are capped.
Below that, a board of headings and notes alone helps nobody: the board
is drawn whole, scrolls under the reader, and the compose box keeps its
place at the bottom of the window (`harness-compose--follow').")

(defconst harness-ui-tasks--cap-order '(done pending active review needs-input)
  "Columns the board caps, least urgent first.
A cap hides part of a column's list, so the ones that need you are
capped last, and only ever after everything below them.")

(defun harness-ui-tasks--cappable-p (groups)
  "Non-nil when some section of GROUPS may have its list capped."
  (cl-some (lambda (c)
             (and (not (memq (car c) harness-ui-tasks--folded))
                  (not (memq (car c) harness-ui-tasks--expanded))
                  (cdr (assq (car c) groups))))
           harness-ui-tasks--columns))

(defun harness-ui-tasks--empty-caps ()
  "Return every column's cap with nothing held back: (COLUMN SHOW . MORE)."
  (mapcar (lambda (c) (cons (car c) (cons nil 0))) harness-ui-tasks--columns))

(defun harness-ui-tasks--cap-cards (caps groups n)
  "Hold back N more cards in CAPS, least urgent section first.
CAPS is the alist of (COLUMN SHOW . MORE) from
`harness-ui-tasks--empty-caps'; GROUPS the tasks shown.  A section that
is folded keeps its cap; one you expanded is left whole.  Return CAPS,
and non-nil when it held a card back."
  (let ((left n) (dropped nil))
    (dolist (column harness-ui-tasks--cap-order caps)
      (when (> left 0)
        (let* ((cap (cdr (assq column caps)))
               (total (length (cdr (assq column groups))))
               (show (if (null (car cap)) total (car cap))))
          (unless (or (memq column harness-ui-tasks--folded)
                      (memq column harness-ui-tasks--expanded))
            (let ((drop (min left show)))
              (when (> drop 0)
                (setcdr (assq column caps) (cons (- show drop) (+ (cdr cap) drop)))
                (setq dropped t)
                (cl-decf left drop)))))))
    dropped))

(defun harness-ui-tasks--fits-p (window)
  "Non-nil when the whole buffer fits WINDOW, board and compose box both.
Measuring to the end of the buffer counts the box and the lines above
it exactly, wrapping and all, and `harness-ui-text-height' is exact at
the limit, so this answers \"would the box stay in the window?\" without
needing the height of text that overflows."
  (let ((body (window-body-height window t)))
    (<= (harness-ui-text-height window (point-min) (point-max) body) body)))

(defun harness-ui-tasks--draw-board (caps)
  "Draw the board region with CAPS, from the start of the buffer.
CAPS is the alist `harness-ui-tasks--cap-cards' makes, or nil for
everything.  Point is left at the end of the board."
  (delete-region (point-min) harness-ui-tasks--list-end)
  (goto-char (point-min))
  (harness-ui-tasks--insert-board caps))

(defun harness-ui-tasks--fit-board ()
  "Draw the board, holding back the least urgent cards until the box fits.
The board region is drawn whole first and the whole buffer measured
through `harness-ui-tasks--fits-p'; when the compose box would not stay
in the window, the fewest cards that must be held back are found by
bisection -- a card takes a line or two, and which sections give way
depends on the wrapping in that window in a way only a drawing answers
-- each capped section getting the line that says how many it holds and
its [Show all].  Nothing is capped without a window, when the window has
no room to speak of, or when everything is folded away or expanded: the
board then scrolls, and the box keeps its place at the bottom of the
window."
  (let* ((window (harness-ui-tasks--window))
         (line (and window (frame-char-height (window-frame window))))
         (body (and window (window-body-height window t)))
         (groups (harness-ui-tasks--visible))
         (empty (harness-ui-tasks--empty-caps)))
    (cond
     ((or (null window) (null line) (null body)
          (< body (* line harness-ui-tasks--cap-min-lines))
          (not (harness-ui-tasks--cappable-p groups)))
      (harness-ui-tasks--draw-board nil)
      nil)
     (t
      (harness-ui-tasks--draw-board empty)
      (if (harness-ui-tasks--fits-p window)
          empty
        (let* ((total (cl-loop for c in harness-ui-tasks--columns
                               sum (length (cdr (assq (car c) groups)))))
               (lo 0) (hi total))
          (while (< lo hi)
            (let* ((mid (/ (+ lo hi) 2))
                   (caps (harness-ui-tasks--empty-caps)))
              (harness-ui-tasks--cap-cards caps groups mid)
              (harness-ui-tasks--draw-board caps)
              (if (harness-ui-tasks--fits-p window)
                  (setq hi mid)
                (setq lo (1+ mid)))))
          (let ((caps (harness-ui-tasks--empty-caps)))
            (when (> hi 0) (harness-ui-tasks--cap-cards caps groups hi))
            (harness-ui-tasks--draw-board caps)
            caps)))))))

(defun harness-ui-tasks--insert-card (task column position)
  (let* ((start (point))
         (session (harness-ui-tasks--session task))
         (width (harness-ui-tasks--width))
         (narrow (< width harness-ui-tasks--collapse-min-width))
         (meta (let ((meta (harness-ui-tasks--meta task column session)))
                 ;; Shown with [Archived] or found by a search: it says so.
                 (if (harness-ui-tasks--archived-p task)
                     (concat (propertize "archived" 'face 'harness-dim-face)
                             (if (string-empty-p meta) "" (propertize " · " 'face 'harness-dim-face))
                             meta)
                   meta)))
         (buttons (harness-ui-tasks--card-buttons task))
         (shown (or (harness-ui-tasks--subtitle-shown-p task) narrow))
         (chevron (if narrow "" (harness-ui-tasks--subtitle-button task shown)))
         (icon (harness-ui-tasks--icon task column session))
         ;; The blocked mark is an image about a column wider than the
         ;; one-column stopped square, with its ink centred in it: move
         ;; it half that extra width left, so the two marks share a
         ;; centre, and pad the same width after it, so the row keeps
         ;; its columns.  A terminal's one-column pause symbol needs
         ;; none of this.
         (pause (and (eq column 'needs-input)
                     (plist-get session :pending)
                     (harness-ui-tasks--wide-icon-p icon)))
         (nudge (and pause (harness-ui-tasks--mark-nudge icon)))
         (left (concat (cond ((not nudge)
                              (concat "  " (if (string-empty-p chevron) "" (concat chevron " "))))
                             ((string-empty-p chevron)
                              (concat " " (harness-ui-tasks--pad (- (frame-char-width) nudge))))
                             (t (concat "  " chevron
                                        (harness-ui-tasks--pad (- (frame-char-width) nudge)))))
                       icon
                       (if nudge (harness-ui-tasks--pad (+ (frame-char-width) nudge)) " ")))
         (subtitle (and shown (harness-ui-tasks--subtitle task column session position
                                                          (- width (string-width buttons) 8))))
         ;; A one-line card carries the buttons beside the facts.  When
         ;; the facts would squeeze the title, a narrow board keeps the
         ;; title and the buttons and lets the facts wait for a wider
         ;; window or for the card to be opened.
         (right (if subtitle meta (concat meta "  " buttons)))
         (right (if (and (not subtitle)
                         (< (- width (string-width right) (string-width left) 3)
                            harness-ui-tasks--min-title-room))
                    buttons
                  right))
         (room (- width (string-width right) (string-width left) 3)))
    (insert left
            (propertize (harness-ui-tasks--fit (harness-ui-tasks--title task) room)
                        'face (if (eq column 'done) 'default 'harness-task-title-face)
                        'mouse-face 'highlight
                        'help-echo "Open the session")
            (propertize " " 'display `(space :align-to (- right ,(1+ (string-width right)))))
            right "\n")
    (when subtitle
      (insert "      " subtitle
              (propertize " " 'display `(space :align-to (- right ,(1+ (string-width buttons)))))
              buttons "\n"))
    (put-text-property start (point) 'harness-task-id (plist-get task :id))))

(defun harness-ui-tasks--insert-section (column heading tasks &optional cap)
  "Draw one column: HEADING, its TASKS and, with CAP (SHOW . MORE), the cap.
SHOW of the tasks are drawn, in order, and its line says how many MORE
the window is too small for."
  (let ((folded (memq column harness-ui-tasks--folded))
        (start (point)))
    (insert (propertize (harness-ui-icon (if folded 'harness-icon-collapsed 'harness-icon-expanded))
                        'face 'harness-dim-face)
            " " (propertize heading 'face (pcase (and tasks column)
                                            ('needs-input '(harness-task-attention-face harness-task-section-face))
                                            ('review '(harness-task-review-face harness-task-section-face))
                                            (_ 'harness-task-section-face)))
            (propertize (format "  %d" (length tasks)) 'face 'harness-dim-face))
    (when (and (eq column 'done) tasks (not folded))
      (let ((b (harness-ui-tasks--button "[Archive all]" #'harness-ui-tasks-archive-done
                                         "Archive every completed task" 'harness-ui-tasks-archive-done)))
        (insert (propertize " " 'display `(space :align-to (- right ,(1+ (string-width b))))) b)))
    (insert "\n")
    (put-text-property start (point) 'harness-task-section column)
    (unless folded
      (when (eq column 'pending)
        (dolist (text (reverse harness-ui-tasks--submitting))
          (insert (propertize (format "  %s %s  submitting…\n"
                                      (harness-ui-icon 'harness-icon-task-pending)
                                      ;; Fitted, like the cards: the buffer wraps.
                                      (harness-ui-tasks--fit
                                       (harness-first-line text 60)
                                       (- (harness-ui-tasks--width) 17
                                          (string-width (harness-ui-icon 'harness-icon-task-pending)))))
                              'face 'harness-dim-face))))
      (let ((shown (if cap (car cap) nil))
            (more (if cap (cdr cap) 0)))
        (cond
         ((and (null tasks) (not (and (eq column 'pending) harness-ui-tasks--submitting)))
          (insert (propertize (pcase column
                                ('needs-input "    nothing needs you\n")
                                ('review "    nothing to review\n")
                                ('merging "    the merge queue is empty\n")
                                ('active "    nothing working\n")
                                ('pending "    no tasks waiting\n")
                                (_ "    none yet\n"))
                              'face 'harness-dim-face)))
         (t
          ;; Only queued tasks have a place in line; the backlog waits for you.
          (let ((queued 0))
            (dolist (task (if shown (seq-take tasks shown) tasks))
              (harness-ui-tasks--insert-card
               task column (and (eq column 'pending) (not (harness-ui-tasks--backlog-p task))
                                (cl-incf queued)))))))
        ;; The line for a section the window is too small for, or one open
        ;; past the room the window has, which folds it back.
        (when (or (> more 0) (memq column harness-ui-tasks--expanded))
          (harness-ui-tasks--more-line more column)))
      (insert "\n"))))

(defun harness-ui-tasks--insert-board (&optional caps)
  "Draw the board region, with CAPS from `harness-ui-tasks--fit-board'.
CAPS is the alist of (COLUMN SHOW . MORE), or nil to draw everything."
  (cond
   ((and harness-ui-tasks--loading (null harness-ui-tasks--tasks))
    (insert (propertize "\n  loading tasks…\n" 'face 'harness-dim-face)))
   (t
    (insert "\n")
    (let* ((filter harness-ui-tasks-filter)
           (groups (harness-ui-tasks--visible t)))
      ;; A filter says what it shows, above the columns that hold it.
      (when filter
        (insert (or (ignore-errors (funcall (plist-get filter :banner))) "")))
      (if (and (null harness-ui-tasks--tasks) (null harness-ui-tasks--submitting) (null filter))
          (insert (propertize "  No tasks yet.  Describe one below: it gets a session of its own\n  and works on it while you do something else.\n\n"
                              'face 'harness-dim-face 'wrap-prefix "  "))
        (dolist (c harness-ui-tasks--columns)
          (let ((tasks (cdr (assq (car c) groups))))
            ;; With review off nothing comes to review: the column shows
            ;; only while tasks from before still wait there.
            (unless (or (and (eq (car c) 'review) (null tasks) (not (harness-ui-tasks--review-p)))
                        (and filter (null tasks)))
              (harness-ui-tasks--insert-section (car c) (cadr c) tasks
                                                (cdr (assq (car c) caps)))))))))))
;;;; Point across redraws

;; The board is drawn again whenever a task or a session changes and on
;; every tick of the clock, the lines above the box on every reload.
;; Point and the windows showing the board stay where they were all the
;; same: on the same line of the same card -- its buttons are on the
;; second -- and on the same button, or a key pressed there would land
;; somewhere else.

(defconst harness-ui-tasks--line-keys '(harness-task-id harness-task-section harness-task-tail)
  "Text properties naming what the lines of a board belong to.
A task's card, a column's heading, or one of the lines above the box.")

(defun harness-ui-tasks--line-key (pos)
  "Return (PROPERTY . VALUE) naming what the text at POS belongs to, or nil."
  (cl-loop for prop in harness-ui-tasks--line-keys
           for value = (get-text-property pos prop)
           when value return (cons prop value)))

(defun harness-ui-tasks--key-start (key)
  "Return where the text KEY names starts, or nil when there is none.
KEY is a (PROPERTY . VALUE) from `harness-ui-tasks--line-key'."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward (car key) (cdr key) #'equal)))
      (prop-match-beginning match))))

(defun harness-ui-tasks--box-start ()
  "Where the compose box's line starts, prompt included; nil before it is drawn."
  (and (harness-compose-live-p) harness-compose-overlay
       (eq (overlay-buffer harness-compose-overlay) (current-buffer))
       (overlay-start harness-compose-overlay)))

(defun harness-ui-tasks--button-at (pos)
  "Return (ID START END) of the button at POS, or nil.
ID is what `harness-ui-tasks--button' named it, else its label."
  (when (get-text-property pos 'button)
    (let* ((id (get-text-property pos 'harness-task-button))
           (prop (if id 'harness-task-button 'button))
           (start (or (previous-single-property-change (1+ pos) prop) (point-min)))
           (end (or (next-single-property-change pos prop) (point-max))))
      (list (or id (buffer-substring-no-properties start end)) start end))))

(defun harness-ui-tasks--find-button (id from to)
  "Return (ID START END) of the button named ID between FROM and TO, or nil."
  (let ((pos from) found)
    (while (and (not found) (< pos to))
      (let ((button (harness-ui-tasks--button-at pos)))
        (if (and button (equal (car button) id))
            (setq found button)
          (setq pos (if button (nth 2 button) (or (next-single-property-change pos 'button nil to) to))))))
    found))

(defun harness-ui-tasks--aligned-p (pos)
  "Non-nil when POS is right of an :align-to space on its line.
What is there is aligned to the window's right edge: a card's facts or
buttons."
  (let ((bol (save-excursion (goto-char pos) (line-beginning-position))))
    (cl-loop for p from (1- pos) downto bol
             thereis (eq (car-safe (get-text-property p 'display)) 'space))))

(defun harness-ui-tasks--anchor (pos)
  "Return where POS is on the board in terms a redraw keeps; nil before one.
In the compose box, its prompt included, that is (box . OFFSET) from the
box's start, and after the box (eob).  Anywhere else it is
\(KEY LINE COLUMN BUTTON POS):

KEY names the card, heading or line above the box POS is on, else the
nearest one above it (nil above them all), as `harness-ui-tasks--line-key'
does, and LINE counts the lines from KEY's first one down to POS's: a
card has two, its buttons on the second.

COLUMN is POS's place on its line: (start . N) characters in, or
\(end . N) from the end right of an :align-to space, where the text
aligned to the right edge stays when the text on its left changes length.

BUTTON is (ID . OFFSET) when POS is on a button: ID as
`harness-ui-tasks--button-at' returns it, OFFSET into the button.

POS itself places what KEY no longer finds: a task gone."
  (when harness-ui-tasks--list-end
    (let ((box (harness-ui-tasks--box-start)))
      (cond
       ((and box (> pos harness-compose-end)) (list 'eob))
       ((and box (>= pos box)) (cons 'box (- pos harness-compose-start)))
       (t
        (save-excursion
          (goto-char pos)
          (let* ((bol (line-beginning-position))
                 (column (if (harness-ui-tasks--aligned-p pos)
                             (cons 'end (- (line-end-position) pos))
                           (cons 'start (- pos bol))))
                 (button (when-let* ((b (harness-ui-tasks--button-at pos)))
                           (cons (car b) (- pos (nth 1 b)))))
                 (line 0)
                 key)
            (goto-char bol)
            ;; Up to the nearest line that belongs to something...
            (while (and (null (setq key (harness-ui-tasks--line-key (point)))) (not (bobp)))
              (forward-line -1)
              (cl-incf line))
            ;; ...and up to its first line.
            (while (and key (not (bobp)) (equal key (harness-ui-tasks--line-key (1- (point)))))
              (forward-line -1)
              (cl-incf line))
            (list key line column button pos))))))))

(defun harness-ui-tasks--anchor-position (anchor)
  "Return the position ANCHOR, from `harness-ui-tasks--anchor', is at now.
On the line ANCHOR names, at its column, or on its button wherever that
moved on the line; never on another button, where a key would do
something else, but at the start of the line instead."
  (let ((board-end (max (point-min) (1- harness-ui-tasks--list-end)))
        (box (harness-ui-tasks--box-start)))
    (pcase anchor
      ('(eob) (point-max))
      (`(box . ,offset)
       (if box (max box (min (+ harness-compose-start offset) harness-compose-end)) (point-max)))
      (`(,key ,line ,column ,button ,pos)
       (let ((start (if key (harness-ui-tasks--key-start key) (point-min))))
         (cond
          ;; A line above the box gone, the error say: the first one left.
          ((and (null start) (eq (car key) 'harness-task-tail))
           (marker-position harness-ui-tasks--list-end))
          ;; A task gone: about where it was, on the board.
          ((null start) (min pos board-end))
          (t
           (save-excursion
             (goto-char start)
             (forward-line line)
             ;; A card that shrank: back to the last line that is still its
             ;; own.  A line just past KEY -- the blank after a column -- is
             ;; where point was and stays.
             (let ((mine (lambda ()
                           (let ((k (harness-ui-tasks--line-key (line-beginning-position))))
                             (or (null k) (equal k key))))))
               (while (and (> (point) start) (not (funcall mine)))
                 (forward-line -1)))
             ;; A line counted from the board stays on the board.
             (when (and (< start harness-ui-tasks--list-end) (>= (point) harness-ui-tasks--list-end))
               (goto-char board-end)
               (forward-line 0))
             (let* ((bol (point))
                    (eol (line-end-position))
                    (at (pcase column
                          (`(end . ,n) (max bol (- eol n)))
                          (`(,_ . ,n) (min eol (+ bol n)))))
                    (same (and button (harness-ui-tasks--find-button (car button) bol eol))))
               (cond
                (same (min (+ (nth 1 same) (cdr button)) (1- (nth 2 same))))
                ((harness-ui-tasks--button-at at) bol)
                (t at)))))))))))

(defun harness-ui-tasks--places ()
  "Return where point and each window showing the board are, as anchors.
`harness-ui-tasks--restore' puts them back there after a redraw."
  (cons (harness-ui-tasks--anchor (point))
        (mapcar (lambda (w) (list w (harness-ui-tasks--anchor (window-start w))
                                  (harness-ui-tasks--anchor (window-point w))))
                (get-buffer-window-list nil nil t))))

(defun harness-ui-tasks--restore (places)
  "Put point and the windows back at PLACES, from `harness-ui-tasks--places'."
  (when (car places) (goto-char (harness-ui-tasks--anchor-position (car places))))
  (pcase-dolist (`(,w ,start ,pt) (cdr places))
    (when (and (window-live-p w) (eq (window-buffer w) (current-buffer)))
      (when pt (set-window-point w (harness-ui-tasks--anchor-position pt)))
      (when start (set-window-start w (harness-ui-tasks--anchor-position start) t)))))

(defvar-local harness-ui-tasks--drawn-key nil
  "What the board region was last drawn as, for `harness-ui-tasks--render'.")

(defun harness-ui-tasks--render (&optional force)
  "Redraw the board region, leaving the compose box alone.
Point and every window showing the board stay where they were: on the
same line of the same task, on the same button (`harness-ui-tasks--anchor').
A redraw that would draw the same board is skipped -- the tick runs
every `harness-ui-tasks-tick' seconds -- unless FORCE, which expansion,
folding and the like pass: the caps depend on the window, not the
board, so what was skipped is only skipped while both are unchanged."
  (when (and (harness-ui-tasks--board-p (current-buffer))
             (or force
                 (not (equal (harness-ui-tasks--board-key)
                             (buffer-local-value 'harness-ui-tasks--drawn-key (current-buffer))))))
    (setq harness-ui-tasks--drawn-key (harness-ui-tasks--board-key))
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (places (harness-ui-tasks--places)))
      (unless harness-ui-tasks--list-end
        (setq harness-ui-tasks--list-end (copy-marker (point-min) t)))
      (save-excursion
        (harness-ui-tasks--fit-board)
        (put-text-property (point-min) (point) 'read-only t)
        (put-text-property (point-min) (point) 'keymap harness-ui-tasks-board-map)
        (harness-ui-tasks--compose-buttons-keymap (point-min) (point)))
      (harness-ui-tasks--restore places)
      (harness-ui-tasks--focus-card)
      (set-buffer-modified-p nil)
      (force-mode-line-update)
      ;; The bulk banner counts the tasks, so it follows the board.
      (when harness-ui-tasks--bulk (harness-ui-tasks--render-tail)))))

(defun harness-ui-tasks--board-key ()
  "Return what the board region's drawing depends on.
The tasks and their sessions (their status, todos and cost feed the
cards), the clock, the caps the window allows, and the state a card
cannot show: which column is folded, which is expanded, which tasks
are submitting, which cards you folded their recap on, and whether
finished work waits for your review."
  (list harness-ui-tasks--tasks
        (mapcar (lambda (session)
                  (list (plist-get session :id) (plist-get session :name) (plist-get session :status)
                        (plist-get session :todos) (plist-get session :pending) (plist-get session :usage)))
                (harness-ui-sessions))
        (truncate (float-time) 5)
        (harness-ui-tasks--window)
        (and (harness-ui-tasks--window) (window-body-height (harness-ui-tasks--window) t))
        (harness-ui-tasks--tail-key (harness-ui-tasks--window))
        harness-ui-tasks--folded
        harness-ui-tasks--expanded
        harness-ui-tasks--submitting
        harness-ui-tasks--subtitles
        harness-ui-tasks--settings
        harness-ui-tasks--show-archived
        harness-ui-tasks--loading))

(defvar-local harness-ui-tasks--focus nil
  "(ID . TIME): the task whose card point goes to once the board shows it.
A clicked notification asks for it, maybe before the board has loaded;
the request lapses after `harness-ui-tasks--focus-timeout' seconds.")

(defconst harness-ui-tasks--focus-timeout 10
  "Seconds a board waits to show the card a notification asked for.")

(defun harness-ui-tasks--focus-card ()
  "Put point on the card `harness-ui-tasks--focus' asks for, once it shows."
  (when harness-ui-tasks--focus
    (if (> (- (float-time) (cdr harness-ui-tasks--focus)) harness-ui-tasks--focus-timeout)
        (setq harness-ui-tasks--focus nil)
      (when-let* ((match (save-excursion
                           (goto-char (point-min))
                           (text-property-search-forward 'harness-task-id (car harness-ui-tasks--focus)
                                                         #'equal))))
        (setq harness-ui-tasks--focus nil)
        (goto-char (prop-match-beginning match))
        (dolist (w (get-buffer-window-list (current-buffer) nil t))
          (set-window-point w (point)))))))

(defun harness-ui-tasks--on-notification (notification)
  "Open the board on the task NOTIFICATION, a clicked notification, is about.
On `harness-ui-notification-functions': non-nil when it was a task's."
  (let ((id (plist-get notification :task))
        (project (plist-get notification :project)))
    (when (and (stringp id) (stringp project) (not (string-empty-p project)))
      (let ((board (harness-tasks project)))
        (when (buffer-live-p board)
          (with-current-buffer board
            (setq harness-ui-tasks--focus (cons id (float-time)))
            (harness-ui-tasks--focus-card))))
      t)))

(add-hook 'harness-ui-notification-functions #'harness-ui-tasks--on-notification)

(defun harness-ui-tasks--compose-buttons-keymap (start end)
  "Let buttons between START and END keep their own keymap over the board's."
  (let ((pos start))
    (while (< pos end)
      (let ((next (or (next-single-property-change pos 'button nil end) end)))
        (when (get-text-property pos 'button)
          (put-text-property pos next 'keymap (make-composed-keymap (list harness-ui-tasks-button-map
                                                                          harness-ui-tasks-board-map))))
        (setq pos next)))))

(defun harness-ui-tasks--messaging-p ()
  "Non-nil when the compose box sends to the session of an existing task.
That is a message, an answer, feedback on a write-up or feedback that
sends a task back from review: anything but composing a task, new or
edited."
  (memq (car harness-ui-tasks--target) '(reply answer refine reject)))

(defun harness-ui-tasks--compose-label ()
  (pcase harness-ui-tasks--target
    (`(edit . ,id) (format "Edit pending task “%s”"
                           (harness-first-line (plist-get (harness-ui-tasks--find id) :prompt) 50)))
    (`(reply . ,id) (format "Message to session “%s”"
                            (let ((task (harness-ui-tasks--find id))) (if task (harness-ui-tasks--title task) id))))
    (`(answer . ,id) (format "Answer the session's question “%s”"
                             (harness-first-line
                              (or (plist-get (plist-get (harness-ui-tasks--pending (harness-ui-tasks--find id)) :payload)
                                             :question)
                                  "the question")
                              60)))
    (`(refine . ,id) (concat "Refine "
                             (harness-ui-tasks--quote
                              (let ((task (harness-ui-tasks--find id))) (if task (harness-ui-tasks--title task) id)))
                             " with feedback"))
    (`(reject . ,id) (concat "Send back "
                             (harness-ui-tasks--quote
                              (let ((task (harness-ui-tasks--find id))) (if task (harness-ui-tasks--title task) id)))
                             " with feedback"))
    (_ "New task")))

(defun harness-ui-tasks--setting-button (label command help)
  "A button LABEL running the session setting COMMAND on the board's target.
The target is the new-task settings, the task at point, or every current
task in bulk mode (see `harness-ui-tasks--setting-target')."
  (propertize (harness-ui-tasks--button label (lambda () (call-interactively command)) help command)
              'face 'harness-dim-face))

(defconst harness-ui-tasks--bulk-columns '(active pending needs-input)
  "Columns the bulk editor reaches: running, pending and blocked tasks.
Review, done and archived tasks are history and are left alone.")

(defun harness-ui-tasks--bulk-tasks ()
  "Return the tasks a bulk update on this board would reach."
  (cl-remove-if-not (lambda (task)
                      (and (not (harness-ui-tasks--archived-p task))
                           (memq (harness-ui-tasks--column task) harness-ui-tasks--bulk-columns)))
                    harness-ui-tasks--tasks))

(defun harness-ui-tasks--bulk-common (tasks key)
  "Return TASKS' common value for KEY, or nil when they differ."
  (let ((values (mapcar (lambda (task) (plist-get task key)) tasks)))
    (and values (cl-every (lambda (v) (equal v (car values))) values) (car values))))

(defun harness-ui-tasks--bulk-values ()
  "Return the values the bulk-edited tasks agree on, for the setting commands."
  (let ((tasks (harness-ui-tasks--bulk-tasks)))
    (list :model (harness-ui-tasks--bulk-common tasks :model)
          :thinking (harness-ui-tasks--bulk-common tasks :thinking)
          :permission-mode (harness-ui-tasks--bulk-common tasks :permission-mode)
          :non-interactive (harness-ui-tasks--bulk-common tasks :non-interactive))))

(defun harness-ui-tasks--set-bulk (key value)
  "Apply KEY VALUE to every current task on this board.
The new-task settings take it too, so a task submitted next matches."
  (setq harness-ui-tasks--new (plist-put (copy-sequence harness-ui-tasks--new) key value))
  (let ((ids (mapcar (lambda (task) (plist-get task :id)) (harness-ui-tasks--bulk-tasks))))
    (harness-ui-call "_harness/task/set-all"
                     (list :settings (list key (if (and (eq key :non-interactive) (not value)) :false value))
                           :filter (list :ids ids :cwd harness-ui-tasks--dir))
                     (lambda (_) (harness-ui-tasks--render-tail))
                     (lambda (e) (message "Bulk update failed: %s" (harness-error-message e))))))

(defun harness-ui-tasks-toggle-bulk ()
  "Switch bulk editing of the current tasks on or off.
While on, the model, effort, permission-mode and non-interactive buttons
change every running, pending or blocked task, not just the new task or
the one at point.  Review, done and archived tasks are history and are
left alone."
  (interactive)
  (setq harness-ui-tasks--bulk (not harness-ui-tasks--bulk))
  (harness-ui-tasks--render-tail)
  (force-mode-line-update)
  (let ((n (length (harness-ui-tasks--bulk-tasks))))
    (message (if harness-ui-tasks--bulk
                 (format "Bulk editing %d current task%s: the settings below change all of them"
                         n (if (= 1 n) "" "s"))
               "Bulk editing off"))))

(defun harness-ui-tasks--bulk-banner ()
  "The conspicuous line that says bulk editing is on."
  (let ((n (length (harness-ui-tasks--bulk-tasks))))
    (propertize
     (format "EDITING %d CURRENT TASK%s (running, pending, blocked) — the settings below change all of them"
             n (if (= 1 n) "" "S"))
     'face 'harness-task-attention-face)))

(defun harness-ui-tasks--new-settings-line ()
  "The settings line: each setting as a button.
In bulk mode the values are the current tasks' and the buttons change
them all; otherwise they are the new task's."
  (let* ((bulk harness-ui-tasks--bulk)
         (values (if bulk (harness-ui-tasks--bulk-values) harness-ui-tasks--new))
         (s harness-ui-tasks--settings)
         (scope (if bulk "current tasks" "new tasks"))
         (main-tree (and (not bulk) (harness-json-true-p (plist-get harness-ui-tasks--new :main-tree)))))
    (if (null s)
        ""
      (concat
       " "
       (mapconcat
        #'identity
        (delq nil
              (list (harness-ui-tasks--setting-button
                     (harness-ui-model-label (plist-get values :model))
                     #'harness-set-model (format "Model of %s" scope))
                    (harness-ui-tasks--setting-button
                     (if-let* ((m (plist-get values :permission-mode))) (harness-ui-permission-mode-label m) "default mode")
                     #'harness-set-permission-mode (format "Permission mode of %s" scope))
                    (harness-ui-tasks--setting-button
                     (harness-ui-thinking-label (plist-get values :thinking))
                     #'harness-set-thinking (format "Thinking level of %s" scope))
                    (harness-ui-tasks--setting-button
                     (harness-ui-non-interactive-label (plist-get values :non-interactive))
                     #'harness-toggle-non-interactive (format "Non-interactive mode of %s" scope))
                    ;; A task that starts cannot change where it works, so
                    ;; this one is only about the next task, never bulk.
                    (and (harness-json-true-p (plist-get s :worktrees))
                         (harness-ui-tasks--setting-button
                          (if main-tree "main tree" "own worktree")
                          #'harness-ui-tasks-toggle-main-tree
                          "Where the next task works: its own worktree and branch, or the project's main tree, where nothing merges"))))
        (propertize " · " 'face 'harness-dim-face))
       (if bulk
           (propertize "   new tasks keep their own settings" 'face 'harness-dim-face)
         (let ((notes (if harness-ui-tasks--refine
                          (list "an agent writes it up; you start it")
                        (delq nil (list (and (plist-get s :max-running)
                                             (format "%s at a time" (plist-get s :max-running))))))))
           (if notes
               (propertize (concat "   " (string-join notes " · ")) 'face 'harness-dim-face)
             "")))))))

(defun harness-ui-tasks--set-new (key value)
  "Set the new-task setting KEY to VALUE and show it."
  (setq harness-ui-tasks--new (plist-put (copy-sequence harness-ui-tasks--new) key value))
  (harness-ui-tasks--render-tail))

(defun harness-ui-tasks--setting-target ()
  "Where the session setting commands apply on the board.
In bulk mode, every current task; else the session of the started task
at point, else the new-task settings.  A backlog task's session only
writes it up, with settings of its own, so it counts as not started."
  (if (and harness-ui-tasks--bulk (harness-ui-tasks--bulk-tasks))
      (let ((n (length (harness-ui-tasks--bulk-tasks))))
        (list (harness-ui-tasks--bulk-values) #'harness-ui-tasks--set-bulk
              (format "for %d task%s" n (if (= 1 n) "" "s"))))
    (let ((task (and (not (harness-compose-in-p)) (harness-ui-tasks--task t))))
      (if (and task (plist-get task :session) (not (harness-ui-tasks--unstarted-p task)))
          (plist-get task :session)
        (list harness-ui-tasks--new #'harness-ui-tasks--set-new)))))

(defun harness-ui-tasks--insert-tail-head ()
  "Insert the error line, the compose label, the settings and the attachments.
Each line is fitted to the window, like the board's: the buffer wraps
for the compose box, so a longer line would take two.  A new task's
label carries the Submit / Refine toggle, which the label makes room
for.  A box that sends to a session wears its message colours here too,
the label, bar and band around it, so what submitting will do is plain
before a key is pressed."
  (let* ((room (1- (harness-ui-tasks--width)))
         (messaging (harness-ui-tasks--messaging-p))
         (band (and messaging 'harness-compose-message-face))
         (bar (if messaging
                  (harness-compose-bar 'harness-compose-message-accent-face 'harness-compose-message-face)
                " ")))
    (when harness-ui-tasks--error
      (harness-ui-tasks--insert-tail-line
       'error (harness-ui-tasks--fit (propertize (concat "  " harness-ui-tasks--error)
                                                 'face 'harness-tool-error-face)
                                     room)
       band))
    (let* ((cancel (if harness-ui-tasks--target
                       (concat "  " (harness-ui-tasks--button
                                     "[cancel]" #'harness-ui-tasks-compose-reset
                                     (if (eq (car harness-ui-tasks--target) 'answer)
                                         "Back to a new task (C-g); the question stays waiting"
                                       "Back to a new task (C-g)")
                                     'harness-ui-tasks-compose-reset))
                     ""))
           (toggle (if harness-ui-tasks--target "" (concat "   " (harness-ui-tasks--mode-toggle))))
           (icon (if messaging (concat (harness-ui-icon 'harness-icon-message) " ") ""))
           (body (concat icon (harness-ui-tasks--compose-label)))
           (label (harness-ui-tasks--fit (concat bar body)
                                         (- room (string-width cancel) (string-width toggle)))))
      ;; The bar, the icon and the label each keep their own look: the
      ;; band behind them all, the accent on bar and icon, the label face
      ;; on the text.
      (let ((head (if messaging (+ (length bar) (length icon)) 0)))
        (add-face-text-property head (length label) 'harness-label-face t label)
        (when messaging
          (add-face-text-property (length bar) (length label) 'harness-compose-message-accent-face t label)))
      ;; Fitted again as a whole: the label shrinks to a minimum, the toggle not.
      (harness-ui-tasks--insert-tail-line 'label (harness-ui-tasks--fit (concat label toggle cancel) room)
                                          band))
    (unless harness-ui-tasks--target
      (when harness-ui-tasks--bulk
        (harness-ui-tasks--insert-tail-line
         'bulk (harness-ui-tasks--fit (harness-ui-tasks--bulk-banner) room)))
      (let ((line (harness-ui-tasks--new-settings-line)))
        (unless (string-empty-p line)
          (harness-ui-tasks--insert-tail-line 'settings (harness-ui-tasks--fit line room)))))
    (let ((start (point)))
      ;; The bar down every attachment's line.
      (harness-compose-insert-attachments (and messaging bar))
      (put-text-property start (point) 'harness-task-tail 'attachments)
      (when band (add-face-text-property start (point) band t)))))

(defun harness-ui-tasks--insert-tail-line (key text &optional band)
  "Insert TEXT as a line above the compose box, named KEY for redraws.
A redraw keeps point on the line of the same KEY (`harness-ui-tasks--anchor').
BAND, when given, is a face put behind the whole line, its final newline
included, so the line's background reaches the window's edge like the
compose box's."
  (let ((start (point)))
    (insert text "\n")
    (put-text-property start (point) 'harness-task-tail key)
    (when band (add-face-text-property start (point) band t))))

(defun harness-ui-tasks--refit-tail ()
  "Fit the lines between the board and the compose box to the window again.
The box itself is left alone, so typing or completing in it carries on,
and point on those lines stays there."
  (when (and (harness-ui-tasks--board-p (current-buffer)) harness-ui-tasks--list-end
             harness-compose-overlay (eq (overlay-buffer harness-compose-overlay) (current-buffer)))
    (let ((inhibit-read-only t)
          (buffer-undo-list t)
          (list-end (marker-position harness-ui-tasks--list-end))
          (places (harness-ui-tasks--places)))
      (save-excursion
        (delete-region list-end (overlay-start harness-compose-overlay))
        (goto-char list-end)
        (harness-ui-tasks--insert-tail-head)
        (put-text-property list-end (point) 'read-only t))
      (set-marker harness-ui-tasks--list-end list-end)
      (harness-ui-tasks--restore places)
      (set-buffer-modified-p nil))))

(defun harness-ui-tasks--mode-toggle ()
  "The Submit / Refine toggle above the compose box: the current mode.
One button, showing only the mode new tasks get, with the icon their
cards get: running for Submit, the agent's for Refine.  A click switches
to the other mode, as `harness-ui-tasks-toggle-refine' does."
  (let ((keys (substitute-command-keys "\\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-toggle-refine]")))
    (pcase-let ((`(,icon ,label ,help ,other)
                 (if harness-ui-tasks--refine
                     '(harness-icon-agent "Refine"
                       "Refine: an agent writes the task up, then it waits in Pending until you start it"
                       "Submit")
                   '(harness-icon-running "Submit" "Submit: the task starts at once" "Refine"))))
      (propertize
       (harness-ui-tasks--button
        (concat (harness-ui-icon icon) " " label)
        (lambda () (harness-ui-tasks--set-refine (not harness-ui-tasks--refine)))
        (format "%s (click or %s to switch to %s)" help keys other)
        'harness-ui-tasks-toggle-refine)
       'face 'harness-task-choice-face))))

(defun harness-ui-tasks--set-refine (refine)
  "Refine new tasks from the compose box when REFINE, else submit them."
  (setq harness-ui-tasks--refine (and refine t))
  (harness-ui-tasks--render-tail)
  (message (if refine
               "Refine: an agent writes each new task up; it waits in Pending until you start it"
             "Submit: each new task starts at once")))

(defun harness-ui-tasks-toggle-refine (&optional arg)
  "Switch the compose box between submitting new tasks and refining them.
Submit starts a task at once.  Refine (backlog refinement, once called
grooming) has an agent write it up first -- briefly, reading the code
but changing nothing -- and the task then waits in Pending, across
restarts, until you start it (\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-start]).  With a prefix ARG, refine
when it is positive and submit otherwise."
  (interactive "P")
  (harness-ui-tasks--set-refine (if arg (> (prefix-numeric-value arg) 0) (not harness-ui-tasks--refine))))

(defun harness-ui-tasks--set-main-tree (main-tree)
  "Make new tasks work in the main tree when MAIN-TREE, else in a worktree.
A task that needs the main tree works in the project's checkout itself:
no worktree, no branch, and nothing merges -- for work that has to
touch the checkout, such as cleaning up uncommitted changes."
  (harness-ui-tasks--set-new :main-tree (if main-tree t :false))
  (message (if main-tree
               "Main tree: the next task works in the project's checkout, with nothing to merge"
             "Worktree: the next task gets its own branch and merges back when done")))

(defun harness-ui-tasks-toggle-main-tree (&optional arg)
  "Switch the next task between its own worktree and the main tree.
In the main tree (see `harness-ui-tasks--set-main-tree') the task works
in the project's own checkout, so it can touch it directly; a backlog
task (Refine) keeps the choice for when it starts.  With a prefix ARG,
the main tree when it is positive and a worktree otherwise."
  (interactive "P")
  (harness-ui-tasks--set-main-tree
   (if arg (> (prefix-numeric-value arg) 0)
     (not (harness-json-true-p (plist-get harness-ui-tasks--new :main-tree))))))

(defun harness-ui-tasks--render-tail (&optional text)
  "Draw the error line, the compose label, the attachments and the compose box.
TEXT replaces the compose contents; without it they are kept.  Point and
the windows showing the board stay where they were: at the same spot of
the box, or on the same line above it (`harness-ui-tasks--anchor')."
  (when (harness-ui-tasks--board-p (current-buffer))
    (harness-compose-capture)
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (list-end (marker-position harness-ui-tasks--list-end))
           (places (harness-ui-tasks--places)))
      (save-excursion
        (delete-region list-end (point-max))
        (goto-char list-end)
        (harness-ui-tasks--insert-tail-head)
        (put-text-property list-end (point) 'read-only t)
        (if (harness-ui-tasks--messaging-p)
            ;; A message to a session, not a task being composed: the box's
            ;; own colours say so, with the band and bar around it.
            (harness-compose-insert text nil :face 'harness-compose-message-face
                                    :accent 'harness-compose-message-accent-face)
          (harness-compose-insert text)))
      (set-marker harness-ui-tasks--list-end list-end)
      (harness-ui-tasks--restore places)
      (set-buffer-modified-p nil))))

(defun harness-ui-tasks--placeholder ()
  "Return the hint for the empty compose box."
  (pcase harness-ui-tasks--target
    (`(refine . ,id) (concat (if (harness-ui-tasks--duplicate-p (harness-ui-tasks--find id))
                                 "What makes it another task than the one it duplicates"
                               "What should change in the write-up")
                             harness-ui-tasks--ellipsis))
    (`(reject . ,_) (concat "What should change in the work" harness-ui-tasks--ellipsis))
    ((guard (and (null harness-ui-tasks--target) harness-ui-tasks--refine))
     (concat "Jot a task down: an agent writes it up for later" harness-ui-tasks--ellipsis))
    (`(edit . ,_) "New prompt…")
    (`(reply . ,_) "Message…")
    (`(answer . ,_) "Answer…")
    (_ "Describe a task…")))

(defun harness-ui-tasks--set-compose (text target)
  "Put TEXT in the compose box for TARGET and move there."
  (setq harness-ui-tasks--target target)
  (harness-ui-tasks--render-tail text)
  (goto-char harness-compose-end)
  (dolist (w (get-buffer-window-list nil nil t)) (set-window-point w (point))))

;;;; Header line

(defun harness-ui-tasks--segment (text command help)
  (propertize text 'mouse-face 'mode-line-highlight 'help-echo help
              'keymap (harness-ui-mouse-keymap command)))

(defun harness-ui-tasks--review-help (window _object _pos)
  "The tooltip of the Review switch in WINDOW's header line.
It says what the switch does now and how to turn it.  A `help-echo'
function, so the keymaps are searched on hover, not on every redisplay
of the header line."
  (with-current-buffer (if (window-live-p window) (window-buffer window) (current-buffer))
    (let ((keys (substitute-command-keys
                 "\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-toggle-review]" t)))
      (if (harness-ui-tasks--review-p)
          (format "Review is on: finished tasks wait in Ready for review until you verify them, which merges them, or send them back.  Click or %s to turn it off, for every project: finished tasks then merge and complete by themselves."
                  keys)
        (format "Review is off: finished tasks merge and complete by themselves, without waiting for you to verify them.  Click or %s to turn it on again, for every project."
                keys)))))

(defun harness-ui-tasks--review-segment ()
  "The header's Review switch: whether finished tasks wait for your review.
A click turns it the other way (`harness-ui-tasks-toggle-review').  Off,
it stands out: work then merges without anyone looking at it."
  (harness-ui-tasks--segment (if (harness-ui-tasks--review-p)
                                 "[Review: on]"
                               (propertize "[Review: off]" 'face 'harness-task-review-off-face))
                             #'harness-ui-tasks-toggle-review #'harness-ui-tasks--review-help))

(defun harness-ui-tasks--header (&optional width)
  "Return the header line, fitted to WIDTH, its window's by default.
In a window too narrow for all of it, [Add session] goes first, then
the counts of completed, merging, pending and working tasks and the
bulk-edit segment; the project's name shortens after those, then the
other modules' segments (`harness-ui-tasks-header-functions', the
search's [Search]) and [BTW] and [Archived].  What needs you, what
waits for your review, the Review switch, [Refresh] and a board still
loading stay longest.  WIDTH is as `harness-ui-fit-header' takes it."
  (let* ((counts (mapcar (lambda (g) (cons (car g) (length (cdr g)))) (harness-ui-tasks--visible)))
         (needs (alist-get 'needs-input counts))
         (review (alist-get 'review counts))
         (name (if harness-ui-tasks--project
                   (file-name-nondirectory (directory-file-name harness-ui-tasks--project))
                 (abbreviate-file-name (or harness-ui-tasks--dir ""))))
         (n (length (harness-ui-tasks--bulk-tasks)))
         (bulk (harness-ui-tasks--segment
                (if harness-ui-tasks--bulk
                    (format "[Bulk: editing %d task%s]" n (if (= 1 n) "" "s"))
                  (format "[Bulk edit: %d task%s]" n (if (= 1 n) "" "s")))
                #'harness-ui-tasks-toggle-bulk
                "Bulk edit: apply the model, effort, permission mode and interactivity to every running, pending and blocked task"))
         (sep "   ")
         (gap (lambda () (prog1 sep (setq sep "  ")))))
    (harness-ui-fit-header
     (list
      (concat " " (propertize "Tasks" 'face 'bold))
      (list (concat " " (propertize name 'face 'harness-dim-face))
            50 (concat " " (propertize (harness-truncate-end name 6) 'face 'harness-dim-face)))
      (and (> needs 0)
           (list (concat (funcall gap)
                         (propertize (format "%s %d need you" (harness-ui-icon 'harness-icon-blocked) needs)
                                     'face 'harness-status-blocked-face))
                 90))
      (and (> review 0)
           (list (concat (funcall gap)
                         (propertize (format "%s %d to review" (harness-ui-icon 'harness-icon-task-review) review)
                                     'face 'harness-task-review-face))
                 88))
      (list (format "%s%s %d" (funcall gap) (harness-ui-icon 'harness-icon-running) (alist-get 'active counts)) 45)
      (list (format "%s%s %d" (funcall gap) (harness-ui-icon 'harness-icon-task-merging) (alist-get 'merging counts))
            42)
      (list (format "%s%s %d" (funcall gap) (harness-ui-icon 'harness-icon-task-pending) (alist-get 'pending counts))
            40)
      (list (format "%s%s %d" (funcall gap) (harness-ui-icon 'harness-icon-task-done) (alist-get 'done counts)) 25)
      (list (concat (funcall gap)
                    (if harness-ui-tasks--bulk (propertize bulk 'face 'harness-task-attention-face) bulk))
            (if harness-ui-tasks--bulk 82 30))
      ;; Shown once the harness said how it is, so it never shows the wrong way.
      (and harness-ui-tasks--settings (list (concat (funcall gap) (harness-ui-tasks--review-segment)) 70))
      ;; Other modules' segments, the search's say.
      (let ((segments (delq nil (mapcar (lambda (fn) (ignore-errors (funcall fn)))
                                        harness-ui-tasks-header-functions))))
        (and segments (list (concat (funcall gap) (mapconcat #'identity segments " ")) 65)))
      (list (concat (funcall gap) (harness-ui-tasks--segment "[BTW]" #'harness-ui-tasks-btw
                                                              "Ask about the tasks in a side conversation"))
            60)
      (list (concat " " (harness-ui-tasks--segment "[Add session]" #'harness-ui-tasks-adopt
                                                   "Make an ongoing session of this project a task"))
            20)
      ;; Showing archived tasks is not the usual board: that stays longer.
      (list (concat " " (harness-ui-tasks--segment (if harness-ui-tasks--show-archived "[Hide archived]" "[Archived]")
                                                   #'harness-ui-tasks-toggle-archived "Show or hide archived tasks"))
            (if harness-ui-tasks--show-archived 75 55))
      (list (concat " " (harness-ui-tasks--segment "[Refresh]" #'harness-ui-tasks-refresh "Reload the board")) 80)
      (and harness-ui-tasks--loading (list (propertize "  loading…" 'face 'harness-dim-face) 85)))
     width)))

;;;; Data

(defun harness-ui-tasks--fail (buffer what err)
  (when (harness-ui-tasks--board-p buffer)
    (with-current-buffer buffer
      (setq harness-ui-tasks--loading nil
            harness-ui-tasks--error (format "%s failed: %s" what (harness-error-message err)))
      (harness-ui-tasks--render)
      (harness-ui-tasks--render-tail))))

(defun harness-ui-tasks--fetch (buffer &optional quiet)
  "Load BUFFER's project root, tasks and settings from the harness.
QUIET refreshes in the background, without the loading indicator."
  (when (harness-ui-tasks--board-p buffer)
    (with-current-buffer buffer
      (unless quiet (setq harness-ui-tasks--loading t))
      (let ((dir harness-ui-tasks--dir))
        (harness-ui-call "_harness/task/settings" (list :cwd dir)
                         (lambda (s) (when (buffer-live-p buffer)
                                       (with-current-buffer buffer
                                         (let ((review (harness-ui-tasks--review-p)))
                                           (setq harness-ui-tasks--settings s)
                                           ;; The Review switch decides whether the board
                                           ;; shows Ready for review when it is empty.
                                           (unless (eq review (harness-ui-tasks--review-p))
                                             (harness-ui-tasks--render)))
                                         ;; The header shows the switch.
                                         (force-mode-line-update)
                                         (unless harness-ui-tasks--new
                                           (setq harness-ui-tasks--new
                                                 (list :model (plist-get s :model)
                                                       :thinking (plist-get s :thinking)
                                                       :permission-mode (plist-get s :permission-mode)
                                                       :non-interactive (harness-json-true-p
                                                                         (plist-get s :non-interactive)))))
                                         (when (and (harness-compose-live-p) (null harness-ui-tasks--target))
                                           (harness-ui-tasks--render-tail)))))
                         #'ignore)
        (harness-ui-call
         "_harness/project/root" (list :cwd dir)
         (lambda (root)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (setq harness-ui-tasks--project root)))
           (harness-ui-call
            "_harness/task/list" (list :cwd dir)
            (lambda (tasks)
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (setq harness-ui-tasks--tasks tasks
                        harness-ui-tasks--loading nil)
                  (harness-ui-tasks--render))))
            (lambda (e) (harness-ui-tasks--fail buffer "Loading tasks" e))))
         (lambda (e) (harness-ui-tasks--fail buffer "Finding the project" e)))))))

(defun harness-ui-tasks--schedule-render (buffer)
  (harness-debounce (list 'harness-ui-tasks buffer) 0.1
                    (lambda () (when (harness-ui-tasks--board-p buffer)
                                 (with-current-buffer buffer (harness-ui-tasks--render))))))

(defconst harness-ui-tasks--refresh-events
  '("merge/queued" "merge/started" "merge/conflict" "merge/finished"
    "agent/turn-started" "agent/turn-ended" "session/status" "session/pending-changed"
    "session/created" "session/deleted" "worktree/created" "worktree/removed"
    "harness/reloaded" "config/changed")
  "Events after which every board quietly reloads its tasks.
`task/changed' and `task/deleted' update a board directly; these catch
anything that moves a task without one, so a board never drifts.")

(defun harness-ui-tasks--refresh-soon (buffer)
  "Reload BUFFER's tasks in the background, once a burst of events settles."
  (harness-debounce (list 'harness-ui-tasks-refresh buffer) 0.3
                    (lambda () (when (harness-ui-tasks--board-p buffer) (harness-ui-tasks--fetch buffer t)))))

(defun harness-ui-tasks--on-window-change (window)
  "Reload the board shown in WINDOW, which may have missed events while hidden."
  (when (harness-ui-tasks--board-p (window-buffer window))
    (harness-ui-tasks--refresh-soon (window-buffer window))))

(defun harness-ui-tasks--on-resize (window)
  "Redraw the board in WINDOW so its cards and tail fit the new width."
  (let ((buffer (window-buffer window)))
    (when (harness-ui-tasks--board-p buffer)
      (harness-ui-tasks--schedule-render buffer)
      (harness-debounce (list 'harness-ui-tasks-refit buffer) 0.1
                        (lambda () (when (harness-ui-tasks--board-p buffer)
                                     (with-current-buffer buffer (harness-ui-tasks--refit-tail))))))))

(defun harness-ui-tasks--on-event (event args)
  "Follow task events on every board; reload them after related events."
  (when (member event harness-ui-tasks--refresh-events)
    (mapc #'harness-ui-tasks--refresh-soon (harness-ui-tasks--buffers)))
  (pcase event
    ("task/changed"
     (let ((task (car args)))
       (dolist (b (harness-ui-tasks--buffers))
         (with-current-buffer b
           (when (equal (plist-get task :project) harness-ui-tasks--project)
             (setq harness-ui-tasks--tasks
                   (cons task (cl-remove (plist-get task :id) harness-ui-tasks--tasks
                                         :key (lambda (x) (plist-get x :id)) :test #'equal)))
             (harness-ui-tasks--schedule-render b))))))
    ("task/review"
     (when harness-ui-tasks--notify-review
       (message "Task %s is ready for your review"
                (harness-ui-tasks--quote (harness-ui-tasks--title (car args))))))
    ("task/deleted"
     (let ((id (car args)))
       (dolist (b (harness-ui-tasks--buffers))
         (with-current-buffer b
           (when (harness-ui-tasks--find id)
             (setq harness-ui-tasks--tasks
                   (cl-remove id harness-ui-tasks--tasks :key (lambda (x) (plist-get x :id)) :test #'equal))
             (when (equal (cdr harness-ui-tasks--target) id) (harness-ui-tasks-compose-reset))
             (harness-ui-tasks--schedule-render b))))))))

(defun harness-ui-tasks--on-sessions-changed ()
  "Session names, statuses, todos and costs feed the cards."
  (dolist (b (harness-ui-tasks--buffers))
    (when (buffer-local-value 'harness-ui-tasks--tasks b)
      (harness-ui-tasks--schedule-render b))))

(defun harness-ui-tasks--on-redraw ()
  "Reload every board after a reload or reconnect."
  (mapc #'harness-ui-tasks--fetch (harness-ui-tasks--buffers)))

(defvar harness-ui-tasks--timer nil "Refreshes elapsed times on visible boards.")

(defun harness-ui-tasks--tick ()
  (dolist (b (harness-ui-tasks--buffers))
    (when (get-buffer-window b t)
      (with-current-buffer b (harness-ui-tasks--render)))))

;;;; Mode

(defvar harness-ui-tasks-board-map (make-sparse-keymap)
  "Keys on the board (outside the compose box).")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-ui-tasks-board-map))
  (define-key map (kbd "RET") #'harness-ui-tasks-open)
  (define-key map (kbd "o") #'harness-ui-tasks-open-other)
  (define-key map [mouse-1] #'harness-ui-tasks-mouse-open)
  (define-key map [mouse-3] #'harness-ui-tasks-context-menu)
  (define-key map (kbd "TAB") #'harness-ui-tasks-tab)
  (define-key map (kbd "<backtab>") #'harness-ui-tasks-previous)
  (define-key map (kbd "a") #'harness-ui-tasks-compose)
  (define-key map (kbd "s") #'harness-ui-tasks-start)
  (define-key map (kbd "e") #'harness-ui-tasks-edit)
  (define-key map (kbd "m") #'harness-ui-tasks-reply)
  (define-key map (kbd "SPC") #'harness-ui-tasks-requests)
  (define-key map (kbd "r") #'harness-ui-tasks-refine)
  (define-key map (kbd "y") #'harness-ui-tasks-allow)
  (define-key map (kbd "n") #'harness-ui-tasks-deny)
  (define-key map (kbd "k") #'harness-ui-tasks-cancel)
  (define-key map (kbd "d") #'harness-ui-tasks-complete)
  (define-key map (kbd "v") #'harness-ui-tasks-verify)
  (define-key map (kbd "R") #'harness-ui-tasks-reject)
  (define-key map (kbd "M") #'harness-ui-tasks-merge)
  (define-key map (kbd "x") #'harness-ui-tasks-archive)
  (define-key map (kbd "X") #'harness-ui-tasks-archive-done)
  (define-key map (kbd "D") #'harness-ui-tasks-delete)
  (define-key map (kbd "A") #'harness-ui-tasks-toggle-archived)
  (define-key map (kbd "V") #'harness-ui-tasks-toggle-review)
  (define-key map (kbd "B") #'harness-ui-tasks-toggle-bulk)
  (define-key map (kbd "I") #'harness-ui-tasks-adopt)
  (define-key map (kbd "b") #'harness-ui-tasks-btw)
  (define-key map (kbd "/") #'harness-ui-tasks-search)
  (define-key map (kbd "g") #'harness-ui-tasks-refresh)
  (define-key map (kbd "q") #'quit-window)
  (define-key map (kbd "?") #'harness-menu))

(defvar harness-ui-tasks-mode-map
  ;; No `special-mode-map' parent: its letters would eat typing in the compose box.
  (let ((map (make-sparse-keymap))) (set-keymap-parent map (make-sparse-keymap)) map)
  "Keymap of `harness-ui-tasks-mode'.")

(let ((map harness-ui-tasks-mode-map))
  ;; The compose box's keys (RET newline, C-c C-a, C-y pasting images).
  (set-keymap-parent map harness-compose-map)
  (define-key map (kbd "C-c C-c") #'harness-ui-tasks-submit)
  (define-key map (kbd "C-c C-k") #'harness-ui-tasks-compose-reset)
  (define-key map (kbd "C-c C-t") #'harness-ui-tasks-toggle-refine)
  ;; C-g, as a remapping: completion popups (corfu, company) keep their
  ;; C-g, and with no box to leave it falls back to the global one.
  (define-key map [remap keyboard-quit] #'harness-ui-tasks-compose-quit)
  (define-key map (kbd "C-c C-n") #'harness-ui-tasks-next)
  (define-key map (kbd "C-c C-p") #'harness-ui-tasks-previous))

(define-derived-mode harness-ui-tasks-mode special-mode "Tasks"
  "Major mode of the task board: a kanban of tasks above a compose box.
\\{harness-ui-tasks-board-map}"
  (setq buffer-read-only nil)
  ;; Lines wrap, for the compose box (`harness-compose-setup'): the board
  ;; fits its lines to the window instead of relying on truncation.
  (setq-local header-line-format '(:eval (harness-ui-tasks--header)))
  (add-hook 'window-buffer-change-functions #'harness-ui-tasks--on-window-change nil t)
  (add-hook 'window-size-change-functions #'harness-ui-tasks--on-resize nil t)
  (setq harness-ui-setting-target-function #'harness-ui-tasks--setting-target)
  ;; What the session at point waits on (the popout), from the card at point.
  (setq-local harness-ui-session-at-point-function
              (lambda ()
                (and (harness-ui-tasks--board-p (current-buffer))
                     (plist-get (harness-ui-tasks--task t) :session))))
  ;; A BTW over the board (b, [BTW], or the usual BTW command) asks about its tasks.
  (setq-local harness-ui-btw-start-function #'harness-ui-tasks--start-btw
              harness-ui-btw-about "the tasks")
  (harness-compose-setup :project (lambda () harness-ui-tasks--dir)
                         :placeholder #'harness-ui-tasks--placeholder
                         :redraw #'harness-ui-tasks--render-tail
                         ;; The board stays at the top; the gap opens between it and the box.
                         :bottom (lambda () (marker-position harness-ui-tasks--list-end))))

;; The board's keys in the harness menu: its letters behind `.', the
;; compose box's chords as they are.
(put 'harness-ui-tasks-mode 'harness-menu-group
     '("Task board"
       ["Task at point"
        (". RET" "Open its session" harness-ui-tasks-open)
        (". o" "Open in position" harness-ui-tasks-open-other)
        (". TAB" "Fold the section or the recap" harness-ui-tasks-tab)
        (". s" "Start now" harness-ui-tasks-start)
        (". e" "Edit prompt" harness-ui-tasks-edit)
        (". m" "Message session" harness-ui-tasks-reply)
        (". SPC" "View what point needs" harness-ui-tasks-requests)
        (". r" "Refine" harness-ui-tasks-refine)
        (". y" "Allow tool call" harness-ui-tasks-allow)
        (". n" "Deny tool call" harness-ui-tasks-deny)]
       ["Finish"
        (". k" "Stop or drop" harness-ui-tasks-cancel)
        (". v" "Verify (accept)" harness-ui-tasks-verify)
        (". R" "Send back with feedback" harness-ui-tasks-reject)
        (". d" "Mark completed" harness-ui-tasks-complete)
        (". M" "Merge again" harness-ui-tasks-merge)
        (". x" "Archive or restore" harness-ui-tasks-archive)
        (". D" "Delete" harness-ui-tasks-delete)]
       ["Board"
        (". a" "New task" harness-ui-tasks-compose)
        (". /" "Search, or act in words" harness-ui-tasks-search)
        (". I" "Adopt a session" harness-ui-tasks-adopt)
        (". X" "Archive completed" harness-ui-tasks-archive-done)
        (". A" "Show archived" harness-ui-tasks-toggle-archived)
        (". V" "Review on or off" harness-ui-tasks-toggle-review)
        (". B" "Bulk edit current tasks" harness-ui-tasks-toggle-bulk)
        (". g" "Refresh" harness-ui-tasks-refresh)]
       ["Compose box"
        ("C-c C-c" "Submit" harness-ui-tasks-submit)
        ("C-c C-t" "Submit or Refine" harness-ui-tasks-toggle-refine)
        ("C-c C-k" "Clear" harness-ui-tasks-compose-reset)
        ("C-c C-a" "Attach file" harness-compose-add-attachment)
        ("C-y" "Paste; an image attaches" harness-compose-yank)]))

(defun harness-ui-tasks--buffer-name (dir)
  (format "*harness tasks: %s*" (file-name-nondirectory (directory-file-name dir))))

(defun harness-ui-tasks--local-root (dir)
  "Guess DIR's project root in this Emacs, for naming the buffer only.
From a task's worktree it is the main checkout, so the board opened
there is the project's."
  (harness-files-main-root dir))

(defun harness-ui-tasks--board-of-session (session-id)
  "Return the open board listing the task SESSION-ID works on, or nil."
  (and session-id
       (cl-find-if (lambda (board)
                     (cl-find session-id (buffer-local-value 'harness-ui-tasks--tasks board)
                              :key (lambda (task) (plist-get task :session)) :test #'equal))
                   (harness-ui-tasks--buffers))))

(declare-function project-root "project")

;;;###autoload
(defun harness-tasks (&optional directory position)
  "Show the task board of DIRECTORY's project (the current one by default).
Task mode runs one session per task: submit tasks from the compose box
at the bottom and follow them from pending to completed.

Without DIRECTORY, in the buffer of a task's session it is the open
board that lists the task, whatever directory the session works in:
from a session opened on a board, the board's key leads back to it.

The board takes a position like a session does (`harness-ui-positions')
and replaces whatever is shown there; opening a task's session from it
puts the session in the same position.  POSITION defaults to the one the
board had last, then to `harness-ui-default-position'; with a prefix
argument it is read."
  (interactive (list nil (and current-prefix-arg (harness-ui-read-position))))
  (let* ((own (and (null directory) (harness-ui-tasks--board-of-session harness-ui-session-id)))
         (root (unless own
                 (file-name-as-directory
                  (expand-file-name (harness-ui-tasks--local-root
                                     (file-name-as-directory
                                      (expand-file-name (or directory default-directory))))))))
         (buf (or own (get-buffer-create (harness-ui-tasks--buffer-name root)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-tasks-mode)
        (harness-ui-tasks-mode)
        (setq default-directory root
              harness-ui-tasks--dir root
              harness-ui-tasks--refine harness-ui-tasks-refine-by-default)
        (harness-ui-tasks--render)
        (harness-ui-tasks--render-tail "")
        (goto-char harness-compose-end)
        (harness-compose-fetch-completions))
      (harness-ui-tasks--fetch buf))
    (harness-ui-refresh-sessions)
    (harness-ui-display-view buf position)))

;;;; Commands

(defun harness-ui-tasks--task (&optional noerror)
  "Return the task at point."
  (or (let ((id (get-text-property (point) 'harness-task-id)))
        (and id (harness-ui-tasks--find id)))
      (unless noerror (user-error "No task here"))))

(defun harness-ui-tasks--request-then (method params what &optional callback)
  "Call METHOD with PARAMS; failures show in the buffer as WHAT failing."
  (let ((buffer (current-buffer)))
    (setq harness-ui-tasks--error nil)
    (harness-ui-call method params (or callback #'ignore)
                     (lambda (e) (harness-ui-tasks--fail buffer what e)))))

(defun harness-ui-tasks-open (&optional position)
  "Open the session of the task at point in POSITION.
By default it takes the board's own position, replacing the board."
  (interactive)
  (let* ((task (harness-ui-tasks--task))
         (sid (plist-get task :session))
         (open (harness-ui-session-opener position)))
    (unless sid (user-error "This task has not started yet; s starts it now"))
    (funcall open sid)))

(defun harness-ui-tasks-open-other ()
  "Open the session of the task at point in a position read from the user."
  (interactive)
  (harness-ui-tasks-open (harness-ui-read-position)))

(defun harness-ui-tasks-mouse-open (event)
  "Open the task clicked in EVENT, or toggle the clicked section."
  (interactive "e")
  (mouse-set-point event)
  (if (get-text-property (point) 'harness-task-section)
      (harness-ui-tasks-tab)
    (when (harness-ui-tasks--task t) (harness-ui-tasks-open))))

(defun harness-ui-tasks-context-menu (event)
  "Pop up the actions of the task clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (when-let* ((task (harness-ui-tasks--task t)))
    (popup-menu
     (cons (harness-ui-tasks--title task)
           (mapcar (lambda (a) (vector (car a) (nth 1 a) t))
                   (harness-ui-tasks--actions task)))
     event)))

(defun harness-ui-tasks-toggle-subtitle ()
  "Show or hide the recap subtitle of the task card at point.
A card's column decides by default -- folded in pending, in progress
and ready for review, shown when a task requires your input -- and your
choice for a card stays with it, whatever column it moves to."
  (interactive)
  (let ((id (get-text-property (point) 'harness-task-id)))
    (unless id (user-error "Point is not on a task card"))
    (let ((task (harness-ui-tasks--find id)))
      (harness-ui-tasks--set-subtitle id (not (harness-ui-tasks--subtitle-shown-p task)))
      (harness-ui-tasks--render)
      ;; A card that shrank keeps point on itself, not on the line below.
      (when-let* ((start (harness-ui-tasks--key-start (cons 'harness-task-id id))))
        (goto-char start)
        (skip-chars-forward " ")))))

(defun harness-ui-tasks-tab ()
  "Fold the section or card at point, or move to the next task.
A heading folds its column; a card shows or hides its recap subtitle."
  (interactive)
  (cond
   ((get-text-property (point) 'harness-task-section)
    (let ((column (get-text-property (point) 'harness-task-section)))
      (setq harness-ui-tasks--folded
            (if (memq column harness-ui-tasks--folded)
                (delq column harness-ui-tasks--folded)
              (cons column harness-ui-tasks--folded)))
      (harness-ui-tasks--render)))
   ((get-text-property (point) 'harness-task-id)
    (harness-ui-tasks-toggle-subtitle))
   (t (harness-ui-tasks-next))))

(defun harness-ui-tasks--move (forward)
  (let ((here (get-text-property (point) 'harness-task-id))
        (pos (point)))
    (while (and (if forward (< pos (point-max)) (> pos (point-min)))
                (let ((id (get-text-property pos 'harness-task-id)))
                  (or (null id) (equal id here))))
      (setq pos (if forward (1+ pos) (1- pos))))
    (let ((id (get-text-property pos 'harness-task-id)))
      (if (null id)
          (message "No more tasks")
        (unless forward
          (while (and (> pos (point-min)) (equal (get-text-property (1- pos) 'harness-task-id) id))
            (setq pos (1- pos))))
        (goto-char pos)
        (skip-chars-forward " ")))))

(defun harness-ui-tasks-next ()
  "Move to the next task."
  (interactive)
  (harness-ui-tasks--move t))

(defun harness-ui-tasks-previous ()
  "Move to the previous task."
  (interactive)
  (harness-ui-tasks--move nil))

(defun harness-ui-tasks-compose ()
  "Move to the compose box to describe a new task."
  (interactive)
  (if harness-ui-tasks--target
      (harness-ui-tasks--set-compose "" nil)
    (goto-char harness-compose-end)))

(defun harness-ui-tasks-compose-reset ()
  "Empty the compose box and make it describe a new task again."
  (interactive)
  (setq harness-compose-attachments nil)
  (harness-ui-tasks--set-compose "" nil))

(defun harness-ui-tasks-compose-quit ()
  "Leave the answer, message or edit box, or show every task again.
On the board \\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-compose-quit] runs this.  Leaving is what
`harness-ui-tasks-compose-reset' does: the box describes a new task
again.  A question it was answering is not cancelled: it stays waiting
on its task, whose card's [Answer] comes back to it.  With no such box
to leave, a board showing some tasks only (`harness-ui-tasks-filter',
a search's) shows them all again.  With an active region, completion in
progress, an open minibuffer or nothing of the sort, this quits the
usual way instead."
  (interactive)
  (cond
   ((or (region-active-p) completion-in-region-mode (active-minibuffer-window))
    (harness-ui-tasks--keyboard-quit))
   (harness-ui-tasks--target
    (let ((answering (eq (car harness-ui-tasks--target) 'answer)))
      (harness-ui-tasks-compose-reset)
      (message (if answering "The question is still waiting" "Back to a new task"))))
   ((plist-get harness-ui-tasks-filter :clear)
    (funcall (plist-get harness-ui-tasks-filter :clear))
    (message "Showing every task"))
   (t (harness-ui-tasks--keyboard-quit))))

(defun harness-ui-tasks--keyboard-quit ()
  "Quit the usual way, which the board's own remapping hides.
That is `keyboard-quit', or what the global map remaps it to (Doom's
`doom/escape', say)."
  (let ((command (or (command-remapping 'keyboard-quit nil (current-global-map)) #'keyboard-quit)))
    (setq this-command command)
    (call-interactively command)))

(defun harness-ui-tasks-submit ()
  "Submit the compose box: a new task, an edited prompt, a message or an answer.
A new task starts, or with the toggle on Refine goes to the backlog
\(see `harness-ui-tasks-toggle-refine').  /skill references are expanded
and attachments go along, as in a chat."
  (interactive)
  (pcase-let* ((`(,text . ,atts) (harness-compose-take))
               (target harness-ui-tasks--target)
               (refine harness-ui-tasks--refine)
               (buffer (current-buffer)))
    (when (and (eq (car target) 'answer) atts)
      (user-error "Answers cannot carry attachments"))
    (setq harness-ui-tasks--error nil
          harness-compose-attachments nil)
    (harness-ui-tasks--set-compose "" nil)
    (if (eq (car target) 'answer)
        (harness-ui-tasks--answer (harness-ui-tasks--find (cdr target)) text)
      (unless target
        (push text harness-ui-tasks--submitting)
        (harness-ui-tasks--render))
      (harness-compose-with-expanded-text
       text
       (lambda (expanded)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (harness-ui-tasks--send target text expanded atts refine))))))))

(defun harness-ui-tasks--new-opts ()
  "The new-task settings as `task/submit' options (unset ones are left out)."
  (let ((new harness-ui-tasks--new))
    (append (cl-loop for k in '(:model :thinking :permission-mode)
                     when (plist-get new k) append (list k (plist-get new k)))
            (and new (list :non-interactive (if (harness-json-true-p (plist-get new :non-interactive)) t :false)))
            (and (harness-json-true-p (plist-get new :main-tree)) (list :main-tree t)))))

(defun harness-ui-tasks--send (target text expanded atts &optional refine)
  "Send EXPANDED (typed as TEXT) with attachments ATTS for compose TARGET.
A new task is refined for the backlog when REFINE is non-nil."
  (let ((buffer (current-buffer)))
    (pcase target
      (`(edit . ,id)
       (harness-ui-tasks--request-then "_harness/task/update" (list :id id :prompt expanded :attachments atts)
                                       "Editing the task")
       (message "Task updated"))
      (`(reply . ,id)
       (harness-ui-tasks--request-then "_harness/task/prompt" (list :id id :text expanded :attachments atts)
                                       "Sending the message")
       (message "Sent to the task's session"))
      (`(refine . ,id)
       (harness-ui-tasks--request-then "_harness/task/prompt" (list :id id :text expanded :attachments atts)
                                       "Sending the feedback")
       (message "Sent: the task is being written up again"))
      (`(reject . ,id)
       (harness-ui-tasks--request-then "_harness/task/reject" (list :id id :feedback expanded :attachments atts)
                                       "Sending the task back")
       (message "Sent back: its session works on your feedback"))
      (_
       (harness-ui-call
        "_harness/task/submit" (list :cwd harness-ui-tasks--dir :prompt expanded
                                     :opts (append (list :attachments atts)
                                                   (and refine (list :refine t))
                                                   (harness-ui-tasks--new-opts)))
        (lambda (task)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (setq harness-ui-tasks--submitting (delete text harness-ui-tasks--submitting))
              (unless (harness-ui-tasks--find (plist-get task :id))
                (push task harness-ui-tasks--tasks))
              (harness-ui-tasks--render))))
        (lambda (e)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (setq harness-ui-tasks--submitting (delete text harness-ui-tasks--submitting))
              (harness-ui-tasks--render)
              ;; Give the text back unless something new was typed meanwhile.
              (when (and (string-empty-p (string-trim (harness-compose-text))) (null harness-compose-attachments))
                (setq harness-compose-attachments atts)
                (harness-ui-tasks--render-tail text))
              (harness-ui-tasks--fail buffer "Submitting the task" e)))))))))

(defun harness-ui-tasks-start ()
  "Start the pending task at point now, even when every slot is busy."
  (interactive)
  (harness-ui-tasks--request-then "_harness/task/start" (list :id (plist-get (harness-ui-tasks--task) :id))
                                  "Starting the task"))

(defun harness-ui-tasks-edit ()
  "Edit the prompt of the pending task at point in the compose box.
That is a backlog task's write-up too; one whose write-up stopped can
be written by hand this way."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (unless (harness-ui-tasks--unstarted-p task) (user-error "Only tasks that have not started can be edited"))
    (when (harness-ui-tasks--writing-p task) (user-error "An agent is writing it up; wait for it or stop it (k)"))
    (setq harness-compose-attachments (plist-get task :attachments))
    (harness-ui-tasks--set-compose (plist-get task :prompt) (cons 'edit (plist-get task :id)))))

(defun harness-ui-tasks-reply ()
  "Write a message to the session of the task at point.
For a backlog task, or one whose write-up stopped or refused it as a
duplicate, that is feedback on its write-up, which is written again (see
`harness-ui-tasks-refine').  For a task waiting for your review it is
the feedback that sends it back, as any message to its session is (see
`harness-ui-tasks-reject')."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (unless (plist-get task :session) (user-error "This task has not started yet"))
    (harness-ui-tasks--set-compose
     "" (cons (cond ((equal (plist-get (harness-ui-tasks--pending task) :kind) "question") 'answer)
                    ((equal (plist-get task :state) "review") 'reject)
                    ((or (equal (plist-get task :state) "pending")
                         (and (harness-ui-tasks--refining-p task) (not (harness-ui-tasks--writing-p task))))
                     'refine)
                    (t 'reply))
              (plist-get task :id)))))

(defun harness-ui-tasks-refine ()
  "Have an agent write the task at point up for the backlog.
A queued task is written up and then waits for you to start it.  For a
backlog task the compose box takes your feedback, and the write-up is
done again with it.  A write-up that stopped is retried, and a task
whose write-up refused it as a duplicate is written up all the same."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (cond
     ((not (harness-ui-tasks--unstarted-p task))
      (user-error "This task has started; only tasks that have not can be refined"))
     ((harness-ui-tasks--writing-p task) (user-error "An agent is writing it up already"))
     ((and (equal (plist-get task :state) "pending") (plist-get task :session))
      (harness-ui-tasks--set-compose "" (cons 'refine (plist-get task :id))))
     (t (harness-ui-tasks--request-then "_harness/task/refine" (list :id (plist-get task :id))
                                        "Refining the task")
        (message "An agent is writing the task up")))))

(defun harness-ui-tasks-requests ()
  "Pop out what the task at point needs, to read and act on it.
That is the permission prompt or question its session waits on, shown in
full -- buttons, keys and diagrams -- and answered there; the board's
compose box takes a typed answer too (m).  A task that handed work in
shows its report instead, through the shared
`harness-ui-popout-at-point-functions'.  The card offers the request as
[Answer…] / [Request…]; SPC does this."
  (interactive)
  (let* ((task (harness-ui-tasks--task))
         (sid (plist-get task :session)))
    (unless sid (user-error "This task has not started yet"))
    (unless (fboundp 'harness-ui-popout-at-point)
      (user-error "The popout module is not loaded"))
    ;; The request is the pending module's and a report the review module's;
    ;; both register with the shared hook, which knows the task at point.
    (unless (harness-ui-popout-try-at-point)
      (user-error "This task is not waiting on anything"))))

(defun harness-ui-tasks--answer (task answer)
  "Answer the question TASK's session is waiting on with ANSWER."
  (let ((pending (harness-ui-tasks--pending task)))
    (unless (equal (plist-get pending :kind) "question") (user-error "No question is waiting"))
    (harness-ui-tasks--request-then "_harness/question/answer"
                                    (list :session-id (plist-get task :session) :pid (plist-get pending :id)
                                          :answer answer)
                                    "Answering")
    (message "Answered: %s" answer)))

(defun harness-ui-tasks--permission (option)
  "Answer the permission request of the task at point with OPTION."
  (let* ((task (harness-ui-tasks--task))
         (pending (harness-ui-tasks--pending task)))
    (unless (equal (plist-get pending :kind) "permission") (user-error "No permission request is waiting"))
    (harness-ui-tasks--request-then "_harness/permission/answer"
                                    (list :session-id (plist-get task :session) :pending-id (plist-get pending :id)
                                          :answer option)
                                    "Answering the permission request")
    (message (if (equal option "allow-once") "Allowed" "Denied"))))

(defun harness-ui-tasks-allow ()
  "Allow the tool call the task at point is waiting on."
  (interactive)
  (harness-ui-tasks--permission "allow-once"))

(defun harness-ui-tasks-deny ()
  "Deny the tool call the task at point is waiting on."
  (interactive)
  (harness-ui-tasks--permission "deny-once"))

(defun harness-ui-tasks-cancel ()
  "Stop the task at point, or drop it when it is still pending.
An agent writing a task up stops; once stopped, the task is dropped,
and with a backlog task the session that wrote it up."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (when (or (not (or (equal (plist-get task :state) "pending")
                       (and (harness-ui-tasks--refining-p task) (not (harness-ui-tasks--writing-p task)))))
              (y-or-n-p (format "Drop pending task “%s”? " (harness-ui-tasks--title task))))
      (harness-ui-tasks--request-then "_harness/task/cancel" (list :id (plist-get task :id)) "Stopping the task"))))

(defun harness-ui-tasks-merge ()
  "Send the branch of the task at point through the merge queue again."
  (interactive)
  (harness-ui-tasks--request-then "_harness/task/merge" (list :id (plist-get (harness-ui-tasks--task) :id))
                                  "Queueing the merge"))

(defun harness-ui-tasks-complete ()
  "Mark the task at point completed."
  (interactive)
  (harness-ui-tasks--request-then "_harness/task/complete" (list :id (plist-get (harness-ui-tasks--task) :id))
                                  "Completing the task"))

(defun harness-ui-tasks--review-task ()
  "Return the task at point, which has to wait for your review."
  (let ((task (harness-ui-tasks--task)))
    (unless (equal (plist-get task :state) "review")
      (user-error "This task is not waiting for your review"))
    task))

(defun harness-ui-tasks--open-harness-p (task)
  "Non-nil when TASK's worktree can be run as a harness of its own.
That is a card waiting for review whose worktree holds harness.el and
the live development loop scripts/dev.sh side by side: the work it
handed in can then be tried live before verifying it."
  (and (equal (plist-get task :state) "review")
       (not (harness-ui-tasks--archived-p task))
       (let ((dir (plist-get task :worktree)))
         (and (stringp dir)
              (file-exists-p (expand-file-name "harness.el" dir))
              (file-exists-p (expand-file-name "scripts/dev.sh" dir))))))

(defun harness-ui-tasks-verify ()
  "Accept the work of the task at point, which waits for your review.
In a git project its branch then goes through the merge queue, and the
task is completed once merged; otherwise it is completed at once."
  (interactive)
  (let ((task (harness-ui-tasks--review-task)))
    (harness-ui-tasks--request-then "_harness/task/verify" (list :id (plist-get task :id))
                                    "Verifying the task")
    (message (if (and (plist-get task :worktree) (not (harness-json-true-p (plist-get task :merged))))
                 "Verified: merging it"
               "Verified"))))

(defun harness-ui-tasks-reject (&optional feedback)
  "Send the task at point back from review with feedback.
The compose box takes the feedback, which \\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-submit] sends to the task's
session: it works on the task again, in its own worktree, and the task
comes back for your review once that is done.  With a prefix argument
the feedback is read in the minibuffer instead; from Lisp, FEEDBACK is
sent at once."
  (interactive (list (and current-prefix-arg
                          (progn (harness-ui-tasks--review-task) (read-string "Feedback: ")))))
  (let ((task (harness-ui-tasks--review-task)))
    (cond
     ((null feedback) (harness-ui-tasks--set-compose "" (cons 'reject (plist-get task :id))))
     ((harness-string-blank-p feedback) (user-error "Sending a task back needs feedback"))
     (t (harness-ui-tasks--request-then "_harness/task/reject" (list :id (plist-get task :id) :feedback feedback)
                                        "Sending the task back")
        (message "Sent back: its session works on your feedback")))))

(defun harness-ui-tasks-open-harness ()
  "Open an Emacs running the harness from the task's worktree."
  (interactive)
  (let* ((task (harness-ui-tasks--review-task))
         (dir (plist-get task :worktree)))
    (unless (harness-ui-tasks--open-harness-p task)
      (user-error "This task's worktree is not a checkout of the harness"))
    (harness-ui-tasks--request-then
     "_harness/harness-dev/open" (list :path dir :focus t)
     "Opening the worktree harness"
     (lambda (info)
       (message "Harness from %s is open in Emacs (socket %s)"
                (abbreviate-file-name dir) (plist-get info :socket))))))

(defun harness-ui-tasks--count-tasks (n)
  "N tasks in words: \"task\" for one, \"3 tasks\" for more."
  (if (= n 1) "task" (format "%d tasks" n)))

(defun harness-ui-tasks--show-review (on)
  "Show review as ON (non-nil) or off on this board, as the harness has it now.
Its `config/changed' brings every board the settings again shortly;
this one does not wait for them."
  (when harness-ui-tasks--settings
    (setq harness-ui-tasks--settings
          (plist-put (copy-sequence harness-ui-tasks--settings) :require-verification (if on t :false)))
    (harness-ui-tasks--render)
    (harness-ui-tasks--refit-tail)))

(defun harness-ui-tasks-toggle-review (&optional arg)
  "Turn the review of finished tasks off, or back on.
With review on, a task whose work is finished waits in Ready for review
until you verify it (\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-verify]), which merges it, or send it back
\(\\[harness-ui-tasks-reject]).  With review off it needs nobody: its branch merges as soon
as it is finished, and the task is done.  The board then shows no Ready
for review column, unless tasks still wait there.  Turning review off
while tasks of this board wait for it offers to verify them too.

The switch is the harness option `harness-tasks-require-verification',
saved as the settings page saves it: for every project, and across
restarts.  With a prefix ARG, turn review on when ARG is positive and
off otherwise."
  (interactive "P")
  (let* ((buffer (current-buffer))
         (on (if arg (> (prefix-numeric-value arg) 0) (not (harness-ui-tasks--review-p))))
         (waiting (and (not on)
                       (cl-remove-if-not (lambda (task) (and (equal (plist-get task :state) "review")
                                                             (not (harness-ui-tasks--archived-p task))))
                                         harness-ui-tasks--tasks)))
         (verify (and waiting
                      (y-or-n-p (format "Verify the %s waiting for your review too? "
                                        (harness-ui-tasks--count-tasks (length waiting)))))))
    (harness-ui-tasks--request-then
     "_harness/config/set"
     (list :key "harness-tasks-require-verification" :value (if on "t" "nil") :printed t
           :scope "global" :cwd harness-ui-tasks--dir)
     (if on "Turning review on" "Turning review off")
     (lambda (_)
       (when (harness-ui-tasks--board-p buffer)
         (with-current-buffer buffer
           (harness-ui-tasks--show-review on)
           (when verify
             (dolist (task waiting)
               (harness-ui-tasks--request-then "_harness/task/verify" (list :id (plist-get task :id))
                                               "Verifying the task")))))
       (message "%s"
                (cond (on "Review on: finished tasks wait for you to verify them, in every project")
                      (verify (format "Review off: finished tasks merge and complete by themselves, in every project; verifying the %s that waited"
                                      (harness-ui-tasks--count-tasks (length waiting))))
                      (t "Review off: finished tasks merge and complete by themselves, in every project")))))))

(defun harness-ui-tasks-archive ()
  "Archive the task at point, completed or in review, or restore it when archived."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (harness-ui-tasks--request-then "_harness/task/archive"
                                    (list :id (plist-get task :id) :restore (harness-ui-tasks--archived-p task))
                                    "Archiving the task")))

(defun harness-ui-tasks-archive-done ()
  "Archive every completed task of this project."
  (interactive)
  (harness-ui-tasks--request-then "_harness/task/archive-done" (list :cwd harness-ui-tasks--dir)
                                  "Archiving completed tasks"
                                  (lambda (n) (message "Archived %s task%s" n (if (eql n 1) "" "s")))))

(defun harness-ui-tasks-delete ()
  "Delete the task at point, and its session when confirmed."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (when (y-or-n-p (format "Delete task “%s”? " (harness-ui-tasks--title task)))
      (harness-ui-tasks--request-then
       "_harness/task/delete"
       (list :id (plist-get task :id)
             :delete-session (and (plist-get task :session) (y-or-n-p "Delete its session too? ")))
       "Deleting the task"))))

(defun harness-ui-tasks-adopt ()
  "Make an ongoing session of this project a task, chosen with completion."
  (interactive)
  (let ((buffer (current-buffer)))
    (harness-ui-call
     "_harness/task/adoptable" (list :cwd harness-ui-tasks--dir)
     (lambda (sessions)
       (if (null sessions)
           (message "Every ongoing session of this project is already a task")
         (dolist (s sessions) (harness-ui-cache-session s))
         (let* ((ids (mapcar (lambda (s) (plist-get s :id)) sessions))
                (session (harness-ui-read-session "Make a task of: "
                                                  (lambda (s) (member (plist-get s :id) ids)))))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (harness-ui-tasks--request-then "_harness/task/adopt" (list :session-id (plist-get session :id))
                                               "Adding the session"))))))
     (lambda (e) (harness-ui-tasks--fail buffer "Listing sessions" e)))))

(defun harness-ui-tasks-btw ()
  "Ask about the tasks in a BTW side conversation over the board.
It opens blank, for a question written in its compose box.  Its agent
answers with the task and session tools: what a task is doing, how far
along it is, what it changed, why it is stuck."
  (interactive)
  (unless (fboundp 'harness-btw) (user-error "The BTW module is not loaded"))
  (harness-btw))

(declare-function harness-tasks-search "harness-ui-tasks-search")

(defun harness-ui-tasks-search ()
  "Find tasks on the board, or act on them, by saying so in words.
A line read in the minibuffer -- a question (\"did I have a task about
the question button?\") or an order (\"restart the errored tasks\") --
goes with the board to a quick, cheap model; the board then shows the
tasks it is about and says what was done.  See `harness-tasks-search'."
  (interactive)
  (unless (fboundp 'harness-tasks-search)
    (user-error "The task search module (ui-tasks-search) is not loaded"))
  (call-interactively #'harness-tasks-search))

(defun harness-ui-tasks--start-btw (name)
  "Start a conversation NAME about the board's tasks; return a promise of it.
Every call starts a new session (`task/btw'), never an earlier one.
The BTW module calls this (`harness-ui-btw-start-function') to open a
BTW over the board; a failure shows on the board too."
  (setq harness-ui-tasks--error nil)
  (let ((buffer (current-buffer))
        (promise (harness-ui-request "_harness/task/btw" (list :cwd harness-ui-tasks--dir :name name))))
    (harness-then promise #'ignore (lambda (e) (harness-ui-tasks--fail buffer "Starting a BTW" e)))
    promise))

(defun harness-ui-tasks-toggle-archived ()
  "Show or hide archived tasks."
  (interactive)
  (setq harness-ui-tasks--show-archived (not harness-ui-tasks--show-archived))
  (harness-ui-tasks--render))

(defun harness-ui-tasks-refresh ()
  "Reload the board from the harness."
  (interactive)
  (setq harness-ui-tasks--error nil)
  (harness-ui-tasks--render-tail)
  (harness-ui-tasks--fetch (current-buffer))
  (harness-ui-refresh-sessions))

;;;; Module

(defun harness-ui-tasks--init ()
  (add-hook 'harness-ui-event-functions #'harness-ui-tasks--on-event)
  (add-hook 'harness-ui-sessions-changed-hook #'harness-ui-tasks--on-sessions-changed)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-tasks--on-redraw)
  (when (timerp harness-ui-tasks--timer) (cancel-timer harness-ui-tasks--timer))
  (setq harness-ui-tasks--timer (run-with-timer harness-ui-tasks--tick-interval harness-ui-tasks--tick-interval #'harness-ui-tasks--tick))
  (define-key harness-ui-map (kbd "a") #'harness-tasks))

(defun harness-ui-tasks--shutdown ()
  (when (timerp harness-ui-tasks--timer) (cancel-timer harness-ui-tasks--timer))
  (setq harness-ui-tasks--timer nil))

(harness-define-module 'ui-tasks
  :doc "Task mode: a kanban of one-session tasks with a compose box."
  :requires '(ui)
  :init #'harness-ui-tasks--init
  :shutdown #'harness-ui-tasks--shutdown)

(provide 'harness-ui-tasks)
;;; harness-ui-tasks.el ends here
