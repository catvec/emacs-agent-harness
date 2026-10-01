;;; harness-ui-tasks.el --- Task mode: a kanban of one-session tasks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Task mode manages sessions by the task each one completes (see the
;; `tasks' module).  Its buffer is a small kanban for the current
;; project, one section per column, most urgent first:
;;
;;   Requires your input   blocked on a permission or question, or stopped
;;   In progress           working, with its current todo and progress
;;   Pending               waiting for a slot, or in the backlog (refined,
;;                         waiting for you); editable, startable
;;   Completed             finished; reply to reopen, archive to hide
;;
;; and a compose box at the bottom: describe a task, C-c C-c submits it
;; and it gets a session of its own.  A toggle above the box (C-c C-t)
;; switches between Submit, which starts the task, and Refine (backlog
;; refinement, once called grooming), which has an agent write the task
;; up and leaves it in Pending until you start it: jot things down now,
;; pick them up later, even after a restart.  The same box edits a
;; pending task (e), replies to a task's session (m) -- for a backlog
;; task that is feedback on its write-up (r) -- without leaving the
;; board, and answers a task's question (m or [Answer]); C-g leaves such
;; a box for a new task again, the question still waiting.
;; RET or a click on a task opens its session in full.  b or [BTW] asks
;; about the tasks in a BTW side conversation over the board, whose agent
;; answers with the task and session tools (`task/btw').
;;
;; Everything comes over ACP (`_harness/task/…' plus the session cache),
;; so the board works against a remote harness too.  The list region is
;; redrawn as a whole when anything changes -- a board holds tens of
;; tasks, not a transcript -- while the compose box is never touched.

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

(defgroup harness-ui-tasks nil
  "Task mode." :group 'harness-ui)


(defcustom harness-ui-tasks-tick 15
  "Seconds between refreshes of the elapsed times on visible boards."
  :type 'number :group 'harness-ui-tasks)

(defcustom harness-ui-tasks-refine-by-default nil
  "When non-nil, new boards refine tasks for the backlog, not submit them.
Either way the toggle above the compose box switches it per board."
  :type 'boolean :group 'harness-ui-tasks)

(defface harness-task-title-face '((t :inherit bold))
  "Task titles." :group 'harness-ui-tasks)
(defface harness-task-section-face '((t :inherit (harness-label-face) :height 1.05))
  "Column headings." :group 'harness-ui-tasks)
(defface harness-task-attention-face '((t :inherit harness-status-blocked-face))
  "Why a task needs the user." :group 'harness-ui-tasks)
(defface harness-task-done-face '((t :inherit success))
  "The completed mark." :group 'harness-ui-tasks)
(defface harness-task-choice-face '((t :inherit bold))
  "The chosen side of the Submit / Refine toggle." :group 'harness-ui-tasks)

(define-icon harness-icon-task-pending nil
  '((symbol "◌") (text "wait"))
  "Pending task." :version "29.1")
(define-icon harness-icon-task-done nil
  '((symbol "✓") (text "done"))
  "Completed task." :version "29.1")
(define-icon harness-icon-task-stopped nil
  '((symbol "■") (text "stop"))
  "Stopped task." :version "29.1")

(defconst harness-ui-tasks--columns
  '((needs-input "Requires your input") (active "In progress")
    (pending "Pending") (done "Completed"))
  "Columns in display order: (COLUMN HEADING).")

;;;; Buffer state

(defvar harness-ui-tasks-board-map)
(defvar harness-ui-btw-start-function)
(defvar harness-ui-btw-about)
(declare-function harness-btw "harness-ui-btw")

(defmacro harness-ui-tasks--with-task (id &rest body)
  "Run BODY with point on task ID's card."
  (declare (indent 1))
  `(let ((match (save-excursion (goto-char (point-min))
                                (text-property-search-forward 'harness-task-id ,id #'equal))))
     (when match (goto-char (prop-match-beginning match)))
     ,@body))


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
(defvar-local harness-ui-tasks--submitting nil "Prompts sent but not yet acknowledged.")
(defvar-local harness-ui-tasks--target nil
  "What the compose box does: nil for a new task, else (KIND . ID).
KIND is edit, reply, answer, or refine: feedback on a backlog task's
write-up.")
(defvar-local harness-ui-tasks--refine nil
  "Non-nil when new tasks are refined for the backlog, not submitted.")
(defvar-local harness-ui-tasks--list-end nil "Marker: end of the board, start of the tail.")

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

(defun harness-ui-tasks--column (task)
  "Return TASK's column as a symbol."
  (intern (or (plist-get task :column)
              (pcase (plist-get task :state) ("pending" "pending") ("done" "done") (_ "active")))))

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

(defun harness-ui-tasks--started (task)
  "When TASK started, else when it was submitted, else 0."
  (or (plist-get task :started) (plist-get task :created) 0))

(defun harness-ui-tasks--visible ()
  "Return the tasks shown, as an alist COLUMN -> tasks in display order.
In progress is newest first by when each task started and completed by
when it finished, so a task arriving in either shows at the top; the
other columns are oldest first, pending in the order its tasks start."
  (let ((groups (mapcar (lambda (c) (list (car c))) harness-ui-tasks--columns)))
    (dolist (task harness-ui-tasks--tasks)
      (unless (and (harness-ui-tasks--archived-p task) (not harness-ui-tasks--show-archived))
        (push task (cdr (assq (harness-ui-tasks--column task) groups)))))
    (dolist (g groups groups)
      (setcdr g (sort (cdr g)
                      (pcase (car g)
                        ('active (lambda (a b) (> (harness-ui-tasks--started a) (harness-ui-tasks--started b))))
                        ('done (lambda (a b) (> (or (plist-get a :finished) 0) (or (plist-get b :finished) 0))))
                        (_ (lambda (a b) (< (or (plist-get a :created) 0) (or (plist-get b :created) 0))))))))))

;;;; What a card says

(defun harness-ui-tasks--session (task)
  (and (plist-get task :session) (harness-ui-session (plist-get task :session))))

(defun harness-ui-tasks--title (task)
  "The session's name once it has one, else the prompt's first line."
  (let ((name (plist-get (harness-ui-tasks--session task) :name)))
    (if (harness-string-blank-p name)
        (harness-first-line (plist-get task :prompt) 72)
      name)))

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
Only the kind: the request itself is read in the session."
  (when-let* ((item (car (plist-get session :pending))))
    (if (equal (plist-get item :kind) "question")
        "has a question for you"
      "needs your permission")))

(defun harness-ui-tasks--icon (task column session)
  (pcase column
    ('pending (cond ((harness-ui-tasks--refining-p task) (harness-ui-status-icon "running"))
                    ((harness-ui-tasks--backlog-p task)
                     (propertize (harness-ui-icon 'harness-icon-agent) 'face 'harness-dim-face))
                    (t (propertize (harness-ui-icon 'harness-icon-task-pending) 'face 'harness-dim-face))))
    ('done (propertize (harness-ui-icon 'harness-icon-task-done) 'face 'harness-task-done-face))
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
                         (outcome (format "%s: %s%s"
                                          (if (harness-ui-tasks--refining-p task) "write-up stopped" "stopped")
                                          (or outcome "?")
                                          (if (plist-get task :error) (concat " — " (plist-get task :error)) "")))))
                   'face 'harness-task-attention-face))
      ((guard (and (equal (plist-get task :state) "merging") (not (equal (plist-get session :status) "running"))))
       (propertize (pcase (plist-get task :merge-status)
                     ("merging" (format "merging into %s…" (harness-ui-tasks--base task)))
                     (_ (format "queued to merge into %s" (harness-ui-tasks--base task))))
                   'face 'harness-dim-face))
      ((guard (equal (plist-get task :merge-status) "conflict"))
       (propertize (format "resolving merge conflicts in %s"
                           (string-join (take 3 (plist-get task :conflicts)) ", "))
                   'face 'harness-dim-face))
      ('active (propertize (or (nth 2 todos)
                               (cond (named (harness-first-line (plist-get task :prompt) 90))
                                     ((equal (plist-get session :status) "running") "working…")
                                     (t "starting…")))
                           'face 'harness-dim-face))
      ('pending (propertize (harness-ui-tasks--pending-detail task position todos)
                            'face 'harness-dim-face))
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

(defun harness-ui-tasks--base (task)
  "The branch TASK merges into."
  (or (plist-get task :base) "main"))

(defun harness-ui-tasks--meta (task column session)
  "The right-aligned facts of TASK's card."
  (let* ((todos (harness-ui-tasks--todos session))
         (started (plist-get task :started))
         (cost (plist-get (plist-get session :usage) :cost))
         (parts
          (delq nil
                (list (and todos (not (eq column 'done)) (format "%d/%d" (nth 0 todos) (nth 1 todos)))
                      (pcase column
                        ('pending (cond ((harness-ui-tasks--refining-p task) nil)
                                        ((plist-get task :refined)
                                         (format "refined %s" (harness-relative-time (plist-get task :refined))))
                                        ((harness-ui-tasks--backlog-p task)
                                         (format "added %s" (harness-relative-time (plist-get task :created))))
                                        (t (format "queued %s" (harness-relative-time (plist-get task :created))))))
                        ('done (and (plist-get task :finished)
                                    (format "done %s" (harness-relative-time (plist-get task :finished)))))
                        (_ (and started (harness-ui-tasks--elapsed (- (float-time) started)))))
                      (and cost (> cost 0) (harness-format-cost cost))))))
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
                          ("Open" harness-ui-tasks-open) ("Stop" harness-ui-tasks-cancel)))
          ("question" '(("Answer" harness-ui-tasks-reply) ("Open" harness-ui-tasks-open)
                        ("Stop" harness-ui-tasks-cancel)))
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

(defun harness-ui-tasks--button (label action help)
  "Return a button string LABEL running ACTION (no arguments)."
  (buttonize label (lambda (_) (funcall action)) nil help))

(defun harness-ui-tasks--pending (task)
  "Return the first pending request of TASK's session, or nil."
  (car (plist-get (harness-ui-tasks--session task) :pending)))

(defun harness-ui-tasks--card-buttons (task)
  "Buttons for TASK's two most useful actions besides opening it."
  (let ((id (plist-get task :id)))
    (mapconcat (lambda (a)
                 (harness-ui-tasks--button
                  (format "[%s]" (car a))
                  (lambda () (harness-ui-tasks--with-task id (call-interactively (nth 1 a))))
                  (car a)))
               (take 2 (cl-remove 'harness-ui-tasks-open (harness-ui-tasks--actions task) :key #'cadr))
               " ")))

;;;; Rendering

(defun harness-ui-tasks--width ()
  "Width the board is drawn for: its widest window, or 100 when hidden."
  (let ((windows (get-buffer-window-list nil nil t)))
    (if windows (apply #'max (mapcar #'window-body-width windows)) 100)))

(defun harness-ui-tasks--fit (string room)
  "STRING shortened to ROOM columns (at least 12), keeping its properties."
  (let ((room (max 12 room)))
    (if (<= (string-width string) room)
        string
      (concat (truncate-string-to-width string (1- room)) "…"))))

(defun harness-ui-tasks--insert-card (task column position)
  (let* ((start (point))
         (session (harness-ui-tasks--session task))
         (width (harness-ui-tasks--width))
         (meta (harness-ui-tasks--meta task column session))
         (buttons (harness-ui-tasks--card-buttons task))
         (detail (harness-ui-tasks--fit (or (harness-ui-tasks--detail task column session position) "")
                                        (- width (string-width buttons) 7))))
    (insert "  " (harness-ui-tasks--icon task column session) " "
            (propertize (harness-ui-tasks--fit (harness-ui-tasks--title task) (- width (string-width meta) 7))
                        'face (if (eq column 'done) 'default 'harness-task-title-face)
                        'mouse-face 'highlight
                        'help-echo "Open the session")
            (propertize " " 'display `(space :align-to (- right ,(1+ (string-width meta)))))
            meta "\n"
            "    " detail
            (propertize " " 'display `(space :align-to (- right ,(1+ (string-width buttons)))))
            buttons "\n")
    (put-text-property start (point) 'harness-task-id (plist-get task :id))))

(defun harness-ui-tasks--insert-section (column heading tasks)
  (let ((folded (memq column harness-ui-tasks--folded))
        (start (point)))
    (insert (propertize (harness-ui-icon (if folded 'harness-icon-collapsed 'harness-icon-expanded))
                        'face 'harness-dim-face)
            " " (propertize heading 'face (if (and (eq column 'needs-input) tasks)
                                             '(harness-task-attention-face harness-task-section-face)
                                           'harness-task-section-face))
            (propertize (format "  %d" (length tasks)) 'face 'harness-dim-face))
    (when (and (eq column 'done) tasks (not folded))
      (let ((b (harness-ui-tasks--button "[Archive all]" #'harness-ui-tasks-archive-done
                                         "Archive every completed task")))
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
      (if (and (null tasks) (not (and (eq column 'pending) harness-ui-tasks--submitting)))
          (insert (propertize (pcase column
                                ('needs-input "    nothing needs you\n")
                                ('active "    nothing working\n")
                                ('pending "    no tasks waiting\n")
                                (_ "    none yet\n"))
                              'face 'harness-dim-face))
        ;; Only queued tasks have a place in line; the backlog waits for you.
        (let ((queued 0))
          (dolist (task tasks)
            (harness-ui-tasks--insert-card
             task column (and (eq column 'pending) (not (harness-ui-tasks--backlog-p task))
                              (cl-incf queued)))))))
    (insert "\n")))

(defun harness-ui-tasks--insert-board ()
  (cond
   ((and harness-ui-tasks--loading (null harness-ui-tasks--tasks))
    (insert (propertize "\n  loading tasks…\n" 'face 'harness-dim-face)))
   (t
    (insert "\n")
    (let ((groups (harness-ui-tasks--visible)))
      (if (and (null harness-ui-tasks--tasks) (null harness-ui-tasks--submitting))
          (insert (propertize "  No tasks yet.  Describe one below: it gets a session of its own\n  and works on it while you do something else.\n\n"
                              'face 'harness-dim-face 'wrap-prefix "  "))
        (dolist (c harness-ui-tasks--columns)
          (harness-ui-tasks--insert-section (car c) (cadr c) (cdr (assq (car c) groups)))))))))

(defun harness-ui-tasks--anchor (pos)
  "Return what POS is on in the board as (KEY COLUMN POS), or nil in the tail.
KEY is a task id or a section symbol; it survives a redraw, POS does not."
  (when (and harness-ui-tasks--list-end (< pos harness-ui-tasks--list-end))
    (let ((key (or (get-text-property pos 'harness-task-id)
                   (get-text-property pos 'harness-task-section))))
      (list key (save-excursion (goto-char pos) (- pos (line-beginning-position))) pos))))

(defun harness-ui-tasks--anchor-position (anchor)
  "Return the position ANCHOR points at after a redraw."
  (let ((match (and (car anchor)
                    (save-excursion
                      (goto-char (point-min))
                      (text-property-search-forward
                       (if (symbolp (car anchor)) 'harness-task-section 'harness-task-id)
                       (car anchor) #'equal)))))
    (if match
        (save-excursion
          (goto-char (prop-match-beginning match))
          (min (+ (point) (nth 1 anchor)) (line-end-position)))
      (min (nth 2 anchor) (max (point-min) (1- harness-ui-tasks--list-end))))))

(defun harness-ui-tasks--render ()
  "Redraw the board region, leaving the compose box alone.
Point and every window showing the board stay on the same task."
  (when (harness-ui-tasks--board-p (current-buffer))
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (own (harness-ui-tasks--anchor (point)))
           (windows (mapcar (lambda (w) (list w (window-start w) (harness-ui-tasks--anchor (window-point w))))
                            (get-buffer-window-list nil nil t))))
      (unless harness-ui-tasks--list-end
        (setq harness-ui-tasks--list-end (copy-marker (point-min) t)))
      (save-excursion
        (delete-region (point-min) harness-ui-tasks--list-end)
        (goto-char (point-min))
        (harness-ui-tasks--insert-board)
        (put-text-property (point-min) (point) 'read-only t)
        (put-text-property (point-min) (point) 'keymap harness-ui-tasks-board-map)
        (harness-ui-tasks--compose-buttons-keymap (point-min) (point)))
      (when own (goto-char (harness-ui-tasks--anchor-position own)))
      (pcase-dolist (`(,w ,start ,anchor) windows)
        (when (window-live-p w)
          (when anchor (set-window-point w (harness-ui-tasks--anchor-position anchor)))
          (set-window-start w (min start (point-max)) t)))
      (set-buffer-modified-p nil)
      (force-mode-line-update))))

(defun harness-ui-tasks--compose-buttons-keymap (start end)
  "Let buttons between START and END keep their own keymap over the board's."
  (let ((pos start))
    (while (< pos end)
      (let ((next (or (next-single-property-change pos 'button nil end) end)))
        (when (get-text-property pos 'button)
          (put-text-property pos next 'keymap (make-composed-keymap (list button-map harness-ui-tasks-board-map))))
        (setq pos next)))))

(defun harness-ui-tasks--compose-label ()
  (pcase harness-ui-tasks--target
    (`(edit . ,id) (format "Edit pending task “%s”"
                           (harness-first-line (plist-get (harness-ui-tasks--find id) :prompt) 50)))
    (`(reply . ,id) (format "Message “%s”"
                            (let ((task (harness-ui-tasks--find id))) (if task (harness-ui-tasks--title task) id))))
    (`(answer . ,id) (format "Answer “%s”"
                             (or (plist-get (plist-get (harness-ui-tasks--pending (harness-ui-tasks--find id)) :payload)
                                            :question)
                                 "the question")))
    (`(refine . ,id) (concat "Refine "
                             (harness-ui-tasks--quote
                              (let ((task (harness-ui-tasks--find id))) (if task (harness-ui-tasks--title task) id)))))
    (_ "New task")))

(defun harness-ui-tasks--setting-button (label command help)
  "A button LABEL running the session setting COMMAND on the new-task settings."
  (propertize (harness-ui-tasks--button label (lambda () (call-interactively command)) help)
              'face 'harness-dim-face))

(defun harness-ui-tasks--new-settings-line ()
  "The new-task settings, each a button changing it, and how tasks run."
  (let ((new harness-ui-tasks--new)
        (s harness-ui-tasks--settings))
    (if (null s)
        ""
      (concat
       " "
       (mapconcat
        #'identity
        (list (harness-ui-tasks--setting-button
               (harness-ui-model-label (plist-get new :model))
               #'harness-set-model "Model of new tasks")
              (harness-ui-tasks--setting-button
               (if-let* ((m (plist-get new :permission-mode))) (harness-ui-permission-mode-label m) "default mode")
               #'harness-set-permission-mode "Permission mode of new tasks")
              (harness-ui-tasks--setting-button
               (harness-ui-thinking-label (plist-get new :thinking))
               #'harness-set-thinking "Thinking level of new tasks")
              (harness-ui-tasks--setting-button
               (if (harness-json-true-p (plist-get new :non-interactive)) "non-interactive" "interactive")
               #'harness-toggle-non-interactive "Non-interactive mode of new tasks"))
        (propertize " · " 'face 'harness-dim-face))
       (let ((notes (if harness-ui-tasks--refine
                        (list "an agent writes it up; you start it")
                      (delq nil (list (and (harness-json-true-p (plist-get s :worktrees))
                                           "own worktree, merged when done")
                                      (and (plist-get s :max-running)
                                           (format "%s at a time" (plist-get s :max-running))))))))
         (if notes
             (propertize (concat "   " (string-join notes " · ")) 'face 'harness-dim-face)
           ""))))))

(defun harness-ui-tasks--set-new (key value)
  "Set the new-task setting KEY to VALUE and show it."
  (setq harness-ui-tasks--new (plist-put (copy-sequence harness-ui-tasks--new) key value))
  (harness-ui-tasks--render-tail))

(defun harness-ui-tasks--setting-target ()
  "Where the session setting commands apply on the board.
The session of the started task at point, else the new-task settings.
A backlog task's session only writes it up, with settings of its own,
so it counts as not started."
  (let ((task (and (not (harness-compose-in-p)) (harness-ui-tasks--task t))))
    (if (and task (plist-get task :session) (not (harness-ui-tasks--unstarted-p task)))
        (plist-get task :session)
      (cons harness-ui-tasks--new #'harness-ui-tasks--set-new))))

(defun harness-ui-tasks--insert-tail-head ()
  "Insert the error line, the compose label, the settings and the attachments.
Each line is fitted to the window, like the board's: the buffer wraps
for the compose box, so a longer line would take two.  A new task's
label carries the Submit / Refine toggle, which the label makes room for."
  (let ((room (1- (harness-ui-tasks--width))))
    (when harness-ui-tasks--error
      (insert (harness-ui-tasks--fit (propertize (concat "  " harness-ui-tasks--error)
                                                 'face 'harness-tool-error-face)
                                     room)
              "\n"))
    (let* ((cancel (if harness-ui-tasks--target
                       (concat "  " (harness-ui-tasks--button
                                     "[cancel]" #'harness-ui-tasks-compose-reset
                                     (if (eq (car harness-ui-tasks--target) 'answer)
                                         "Back to a new task (C-g); the question stays waiting"
                                       "Back to a new task (C-g)")))
                     ""))
           (toggle (if harness-ui-tasks--target "" (concat "   " (harness-ui-tasks--mode-toggle))))
           (label (harness-ui-tasks--fit (concat " " (harness-ui-tasks--compose-label))
                                         (- room (string-width cancel) (string-width toggle)))))
      ;; Appended, so the dim settings note keeps its own face.
      (add-face-text-property 0 (length label) 'harness-label-face t label)
      ;; Fitted again as a whole: the label shrinks to a minimum, the toggle not.
      (insert (harness-ui-tasks--fit (concat label toggle cancel) room) "\n"))
    (unless harness-ui-tasks--target
      (let ((line (harness-ui-tasks--new-settings-line)))
        (unless (string-empty-p line)
          (insert (harness-ui-tasks--fit line room) "\n"))))
    (harness-compose-insert-attachments)))

(defun harness-ui-tasks--refit-tail ()
  "Fit the lines between the board and the compose box to the window again.
The box itself is left alone, so typing or completing in it carries on."
  (when (and (harness-ui-tasks--board-p (current-buffer)) harness-ui-tasks--list-end
             harness-compose-overlay (eq (overlay-buffer harness-compose-overlay) (current-buffer)))
    (let ((inhibit-read-only t)
          (buffer-undo-list t)
          (list-end (marker-position harness-ui-tasks--list-end)))
      (save-excursion
        (delete-region list-end (overlay-start harness-compose-overlay))
        (goto-char list-end)
        (harness-ui-tasks--insert-tail-head)
        (put-text-property list-end (point) 'read-only t))
      (set-marker harness-ui-tasks--list-end list-end)
      (set-buffer-modified-p nil))))

(defun harness-ui-tasks--mode-toggle ()
  "The Submit / Refine toggle above the compose box, a button per side."
  (let ((keys (substitute-command-keys "\\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-toggle-refine]")))
    (cl-flet ((side (label refine help)
                (let ((chosen (eq refine (and harness-ui-tasks--refine t))))
                  (propertize
                   (harness-ui-tasks--button
                    (concat (harness-ui-icon (if chosen 'harness-icon-idle 'harness-icon-inactive)) " " label)
                    (lambda () (harness-ui-tasks--set-refine refine))
                    (format "%s (%s switches)" help keys))
                   'face (if chosen 'harness-task-choice-face 'harness-dim-face)))))
      (concat (side "Submit" nil "Submit: the task starts at once")
              "  "
              (side "Refine" t "Refine: an agent writes the task up, then it waits in Pending until you start it")))))

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

(defun harness-ui-tasks--render-tail (&optional text)
  "Draw the error line, the compose label, the attachments and the compose box.
TEXT replaces the compose contents; without it they are kept."
  (when (harness-ui-tasks--board-p (current-buffer))
    (harness-compose-capture)
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (offset (and (harness-compose-in-p) (- (point) harness-compose-start)))
           (list-end (marker-position harness-ui-tasks--list-end))
           ;; Windows whose point is in the tail go back to the same spot of the box.
           (windows (mapcar (lambda (w)
                              (let ((p (window-point w)))
                                (cons w (and (harness-compose-live-p) (>= p list-end)
                                             (max 0 (- p harness-compose-start))))))
                            (get-buffer-window-list nil nil t))))
      (save-excursion
        (delete-region list-end (point-max))
        (goto-char list-end)
        (harness-ui-tasks--insert-tail-head)
        (put-text-property list-end (point) 'read-only t)
        (harness-compose-insert text))
      (set-marker harness-ui-tasks--list-end list-end)
      (pcase-dolist (`(,w . ,off) windows)
        (when (and off (window-live-p w))
          (set-window-point w (min (+ harness-compose-start off) harness-compose-end))))
      (set-buffer-modified-p nil)
      (when offset (goto-char (min (+ harness-compose-start offset) harness-compose-end))))))

(defun harness-ui-tasks--placeholder ()
  "Return the hint for the empty compose box."
  (pcase harness-ui-tasks--target
    (`(refine . ,_) (concat "What should change in the write-up" harness-ui-tasks--ellipsis))
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

(defun harness-ui-tasks--header ()
  (let* ((counts (mapcar (lambda (g) (cons (car g) (length (cdr g)))) (harness-ui-tasks--visible)))
         (needs (alist-get 'needs-input counts)))
    (concat
     " " (propertize "Tasks" 'face 'bold) " "
     (propertize (if harness-ui-tasks--project
                     (file-name-nondirectory (directory-file-name harness-ui-tasks--project))
                   (abbreviate-file-name (or harness-ui-tasks--dir "")))
                 'face 'harness-dim-face)
     "   "
     (if (> needs 0)
         (propertize (format "%s %d need you" (harness-ui-icon 'harness-icon-blocked) needs)
                     'face 'harness-status-blocked-face)
       "")
     (format "  %s %d  %s %d  %s %d"
             (harness-ui-icon 'harness-icon-running) (alist-get 'active counts)
             (harness-ui-icon 'harness-icon-task-pending) (alist-get 'pending counts)
             (harness-ui-icon 'harness-icon-task-done) (alist-get 'done counts))
     "   "
     (harness-ui-tasks--segment "[BTW]" #'harness-ui-tasks-btw
                                "Ask about the tasks in a side conversation")
     " "
     (harness-ui-tasks--segment "[Add session]" #'harness-ui-tasks-adopt
                                "Make an ongoing session of this project a task")
     " "
     (harness-ui-tasks--segment (if harness-ui-tasks--show-archived "[Hide archived]" "[Archived]")
                                #'harness-ui-tasks-toggle-archived "Show or hide archived tasks")
     " "
     (harness-ui-tasks--segment "[Refresh]" #'harness-ui-tasks-refresh "Reload the board")
     (if harness-ui-tasks--loading (propertize "  loading…" 'face 'harness-dim-face) ""))))

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
                                         (setq harness-ui-tasks--settings s)
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
  (define-key map (kbd "r") #'harness-ui-tasks-refine)
  (define-key map (kbd "y") #'harness-ui-tasks-allow)
  (define-key map (kbd "n") #'harness-ui-tasks-deny)
  (define-key map (kbd "k") #'harness-ui-tasks-cancel)
  (define-key map (kbd "d") #'harness-ui-tasks-complete)
  (define-key map (kbd "M") #'harness-ui-tasks-merge)
  (define-key map (kbd "x") #'harness-ui-tasks-archive)
  (define-key map (kbd "X") #'harness-ui-tasks-archive-done)
  (define-key map (kbd "D") #'harness-ui-tasks-delete)
  (define-key map (kbd "A") #'harness-ui-tasks-toggle-archived)
  (define-key map (kbd "I") #'harness-ui-tasks-adopt)
  (define-key map (kbd "b") #'harness-ui-tasks-btw)
  (define-key map (kbd "g") #'harness-ui-tasks-refresh)
  (define-key map (kbd "q") #'quit-window)
  (define-key map (kbd "?") #'harness-menu))

(defvar harness-ui-tasks-mode-map
  ;; No `special-mode-map' parent: its letters would eat typing in the compose box.
  (let ((map (make-sparse-keymap))) (set-keymap-parent map (make-sparse-keymap)) map)
  "Keymap of `harness-ui-tasks-mode'.")

(let ((map harness-ui-tasks-mode-map))
  ;; The compose box's keys (RET newline, C-c C-a, C-c C-v).
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
  ;; A BTW over the board (b, [BTW], or the usual BTW command) asks about its tasks.
  (setq-local harness-ui-btw-start-function #'harness-ui-tasks--start-btw
              harness-ui-btw-about "the tasks")
  (harness-compose-setup :project (lambda () harness-ui-tasks--dir)
                         :placeholder #'harness-ui-tasks--placeholder
                         :redraw #'harness-ui-tasks--render-tail
                         ;; The board stays at the top; the gap opens between it and the box.
                         :bottom (lambda () (marker-position harness-ui-tasks--list-end))))

(defun harness-ui-tasks--buffer-name (dir)
  (format "*harness tasks: %s*" (file-name-nondirectory (directory-file-name dir))))

(defun harness-ui-tasks--local-root (dir)
  "Guess DIR's project root in this Emacs, for naming the buffer only.
From a task's worktree it is the main checkout, so opening the board from
a task's session comes back to the same board."
  (harness-files-main-root dir))

(declare-function project-root "project")

;;;###autoload
(defun harness-tasks (&optional directory position)
  "Show the task board of DIRECTORY's project (the current one by default).
Task mode runs one session per task: submit tasks from the compose box
at the bottom and follow them from pending to completed.

The board takes a position like a session does (`harness-ui-positions')
and replaces whatever is shown there; opening a task's session from it
puts the session in the same position.  POSITION defaults to the one the
board had last, then to `harness-ui-default-position'; with a prefix
argument it is read."
  (interactive (list default-directory (and current-prefix-arg (harness-ui-read-position))))
  (let* ((dir (file-name-as-directory (expand-file-name (or directory default-directory))))
         (root (file-name-as-directory (expand-file-name (harness-ui-tasks--local-root dir))))
         (buf (get-buffer-create (harness-ui-tasks--buffer-name root))))
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

(defun harness-ui-tasks-tab ()
  "Fold the section at point, or move to the next task."
  (interactive)
  (if-let* ((column (get-text-property (point) 'harness-task-section)))
      (progn (setq harness-ui-tasks--folded
                   (if (memq column harness-ui-tasks--folded)
                       (delq column harness-ui-tasks--folded)
                     (cons column harness-ui-tasks--folded)))
             (harness-ui-tasks--render))
    (harness-ui-tasks-next)))

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
  "Leave the answer, message or edit box; otherwise quit as usual.
On the board \\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-compose-quit] runs this.  Leaving is what
`harness-ui-tasks-compose-reset' does: the box describes a new task
again.  A question it was answering is not cancelled: it stays waiting
on its task, whose card's [Answer] comes back to it.  With an active
region, completion in progress, an open minibuffer or no such box to
leave, this quits the usual way instead."
  (interactive)
  (if (or (null harness-ui-tasks--target) (region-active-p)
          completion-in-region-mode (active-minibuffer-window))
      (harness-ui-tasks--keyboard-quit)
    (let ((answering (eq (car harness-ui-tasks--target) 'answer)))
      (harness-ui-tasks-compose-reset)
      (message (if answering "The question is still waiting" "Back to a new task")))))

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
            (and new (list :non-interactive (if (harness-json-true-p (plist-get new :non-interactive)) t :false))))))

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
For a backlog task that is feedback on its write-up, which is written
again (see `harness-ui-tasks-refine')."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (unless (plist-get task :session) (user-error "This task has not started yet"))
    (harness-ui-tasks--set-compose
     "" (cons (cond ((equal (plist-get (harness-ui-tasks--pending task) :kind) "question") 'answer)
                    ((equal (plist-get task :state) "pending") 'refine)
                    (t 'reply))
              (plist-get task :id)))))

(defun harness-ui-tasks-refine ()
  "Have an agent write the task at point up for the backlog.
A queued task is written up and then waits for you to start it.  For a
backlog task the compose box takes your feedback, and the write-up is
done again with it.  A write-up that stopped is retried."
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

(defun harness-ui-tasks-archive ()
  "Archive the completed task at point, or restore it when archived."
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
Its agent answers with the task and session tools: what a task is
doing, how far along it is, what it changed, why it is stuck."
  (interactive)
  (unless (fboundp 'harness-btw) (user-error "The BTW module is not loaded"))
  (call-interactively #'harness-btw))

(defun harness-ui-tasks--start-btw (name)
  "Start a conversation NAME about the board's tasks; return a promise of it.
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
  (setq harness-ui-tasks--timer (run-with-timer harness-ui-tasks-tick harness-ui-tasks-tick #'harness-ui-tasks--tick))
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
