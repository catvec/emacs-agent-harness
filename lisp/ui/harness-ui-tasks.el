;;; harness-ui-tasks.el --- Task mode: a kanban of one-session tasks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Task mode manages sessions by the task each one completes (see the
;; `tasks' module).  Its buffer is a small kanban for the current
;; project, one section per column, most urgent first:
;;
;;   Requires your input   blocked on a permission or question, or stopped
;;   Ready for review      finished, waiting for you: verify it (v), which
;;                         merges it, or send it back with feedback (R)
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
;; feedback that sends a task back from review (R); C-g leaves such a
;; box for a new task again, the question still waiting.
;; RET or a click on a task opens its session in full.  b or [BTW] asks
;; about the tasks in a BTW side conversation over the board, whose agent
;; answers with the task and session tools (`task/btw').
;;
;; Everything comes over ACP (`_harness/task/…' plus the session cache),
;; so the board works against a remote harness too.  The list region is
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

(defgroup harness-ui-tasks nil
  "Task mode." :group 'harness-ui)


(defcustom harness-ui-tasks-tick 15
  "Seconds between refreshes of the elapsed times on visible boards."
  :type 'number :group 'harness-ui-tasks)

(defcustom harness-ui-tasks-refine-by-default nil
  "When non-nil, new boards refine tasks for the backlog, not submit them.
Either way the toggle above the compose box switches it per board."
  :type 'boolean :group 'harness-ui-tasks)

(defcustom harness-ui-tasks-notify-review t
  "When non-nil, say in the echo area when a task waits for your review."
  :type 'boolean :group 'harness-ui-tasks)

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
(harness-ui-define-icon harness-icon-message "message" "→" "msg"
  "A message to the session of an existing task.")

(defconst harness-ui-tasks--columns
  '((needs-input "Requires your input") (review "Ready for review") (active "In progress")
    (pending "Pending") (done "Completed"))
  "Columns in display order: (COLUMN HEADING).")

;;;; Buffer state

(defvar harness-ui-tasks-board-map)
(defvar harness-ui-btw-start-function)
(defvar harness-ui-btw-about)
(declare-function harness-btw "harness-ui-btw")

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
(defvar-local harness-ui-tasks--submitting nil "Prompts sent but not yet acknowledged.")
(defvar-local harness-ui-tasks--target nil
  "What the compose box does: nil for a new task, else (KIND . ID).
KIND is edit, reply, answer, refine (feedback on a backlog task's
write-up) or reject (feedback that sends a task back from review).")
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
              (pcase (plist-get task :state)
                ("pending" "pending") ("review" "review") ("done" "done") (_ "active")))))

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

(defun harness-ui-tasks--completed (task)
  "When TASK was completed: verified, else finished, else 0."
  (or (plist-get task :verified-at) (plist-get task :finished) 0))

(defun harness-ui-tasks--visible ()
  "Return the tasks shown, as an alist COLUMN -> tasks in display order.
In progress is newest first by when each task started, review by when
it finished and completed by when it was completed, so a task arriving
in any of them shows at the top; the other columns are oldest first,
pending in the order its tasks start."
  (let ((groups (mapcar (lambda (c) (list (car c))) harness-ui-tasks--columns)))
    (dolist (task harness-ui-tasks--tasks)
      (unless (and (harness-ui-tasks--archived-p task) (not harness-ui-tasks--show-archived))
        (push task (cdr (assq (harness-ui-tasks--column task) groups)))))
    (dolist (g groups groups)
      (setcdr g (sort (cdr g)
                      (pcase (car g)
                        ('active (lambda (a b) (> (harness-ui-tasks--started a) (harness-ui-tasks--started b))))
                        ('review (lambda (a b) (> (or (plist-get a :finished) 0) (or (plist-get b :finished) 0))))
                        ('done (lambda (a b) (> (harness-ui-tasks--completed a) (harness-ui-tasks--completed b))))
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
    ('review (propertize (harness-ui-icon 'harness-icon-task-review) 'face 'harness-task-review-face))
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
                (list (and todos (not (memq column '(done review))) (format "%d/%d" (nth 0 todos) (nth 1 todos)))
                      (pcase column
                        ('pending (cond ((harness-ui-tasks--refining-p task) nil)
                                        ((plist-get task :refined)
                                         (format "refined %s" (harness-relative-time (plist-get task :refined))))
                                        ((harness-ui-tasks--backlog-p task)
                                         (format "added %s" (harness-relative-time (plist-get task :created))))
                                        (t (format "queued %s" (harness-relative-time (plist-get task :created))))))
                        ('review (and (plist-get task :finished)
                                      (format "ready %s" (harness-relative-time (plist-get task :finished)))))
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
       ('review (if (harness-ui-tasks--archived-p task)
                    '(("Unarchive" harness-ui-tasks-archive) ("Verify" harness-ui-tasks-verify)
                      ("Open" harness-ui-tasks-open))
                  '(("Verify" harness-ui-tasks-verify) ("Send back" harness-ui-tasks-reject)
                    ("Open" harness-ui-tasks-open) ("Reply" harness-ui-tasks-reply)
                    ("Archive" harness-ui-tasks-archive))))
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
  "Return the first pending request of TASK's session, or nil."
  (car (plist-get (harness-ui-tasks--session task) :pending)))

(defun harness-ui-tasks--card-buttons (task)
  "Buttons for TASK's two most useful actions besides opening it."
  (let ((id (plist-get task :id)))
    (mapconcat (lambda (a)
                 (harness-ui-tasks--button
                  (format "[%s]" (car a))
                  (lambda () (harness-ui-tasks--with-task id (call-interactively (nth 1 a))))
                  (car a) (nth 1 a)))
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
      (if (and (null tasks) (not (and (eq column 'pending) harness-ui-tasks--submitting)))
          (insert (propertize (pcase column
                                ('needs-input "    nothing needs you\n")
                                ('review "    nothing to review\n")
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

(defun harness-ui-tasks--render ()
  "Redraw the board region, leaving the compose box alone.
Point and every window showing the board stay where they were: on the
same line of the same task, on the same button (`harness-ui-tasks--anchor')."
  (when (harness-ui-tasks--board-p (current-buffer))
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (places (harness-ui-tasks--places)))
      (unless harness-ui-tasks--list-end
        (setq harness-ui-tasks--list-end (copy-marker (point-min) t)))
      (save-excursion
        (delete-region (point-min) harness-ui-tasks--list-end)
        (goto-char (point-min))
        (harness-ui-tasks--insert-board)
        (put-text-property (point-min) (point) 'read-only t)
        (put-text-property (point-min) (point) 'keymap harness-ui-tasks-board-map)
        (harness-ui-tasks--compose-buttons-keymap (point-min) (point)))
      (harness-ui-tasks--restore places)
      (harness-ui-tasks--focus-card)
      (set-buffer-modified-p nil)
      (force-mode-line-update))))

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
  "A button LABEL running the session setting COMMAND on the new-task settings."
  (propertize (harness-ui-tasks--button label (lambda () (call-interactively command)) help command)
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
               (harness-ui-non-interactive-label (plist-get new :non-interactive))
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
      (let ((line (harness-ui-tasks--new-settings-line)))
        (unless (string-empty-p line)
          (harness-ui-tasks--insert-tail-line 'settings (harness-ui-tasks--fit line room)))))
    (let ((start (point)))
      ;; The bar only when there is a line to carry it.
      (when (and messaging harness-compose-attachments) (insert bar))
      (harness-compose-insert-attachments)
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
    (`(refine . ,_) (concat "What should change in the write-up" harness-ui-tasks--ellipsis))
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

(defun harness-ui-tasks--header ()
  (let* ((counts (mapcar (lambda (g) (cons (car g) (length (cdr g)))) (harness-ui-tasks--visible)))
         (needs (alist-get 'needs-input counts))
         (review (alist-get 'review counts)))
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
     (if (> review 0)
         (propertize (format "  %s %d to review" (harness-ui-icon 'harness-icon-task-review) review)
                     'face 'harness-task-review-face)
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
    ("task/review"
     (when harness-ui-tasks-notify-review
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

;; The board's keys in the harness menu: its letters behind `.', the
;; compose box's chords as they are.
(put 'harness-ui-tasks-mode 'harness-menu-group
     '("Task board"
       ["Task at point"
        (". RET" "Open its session" harness-ui-tasks-open)
        (". o" "Open in position" harness-ui-tasks-open-other)
        (". s" "Start now" harness-ui-tasks-start)
        (". e" "Edit prompt" harness-ui-tasks-edit)
        (". m" "Message session" harness-ui-tasks-reply)
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
        (". I" "Adopt a session" harness-ui-tasks-adopt)
        (". X" "Archive completed" harness-ui-tasks-archive-done)
        (". A" "Show archived" harness-ui-tasks-toggle-archived)
        (". g" "Refresh" harness-ui-tasks-refresh)]
       ["Compose box"
        ("C-c C-c" "Submit" harness-ui-tasks-submit)
        ("C-c C-t" "Submit or Refine" harness-ui-tasks-toggle-refine)
        ("C-c C-k" "Clear" harness-ui-tasks-compose-reset)
        ("C-c C-a" "Attach file" harness-compose-add-attachment)
        ("C-c C-v" "Attach clipboard" harness-compose-attach-clipboard)]))

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

(defun harness-ui-tasks--review-task ()
  "Return the task at point, which has to wait for your review."
  (let ((task (harness-ui-tasks--task)))
    (unless (equal (plist-get task :state) "review")
      (user-error "This task is not waiting for your review"))
    task))

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
