;;; harness-ui-tasks.el --- Task mode: a kanban of one-session tasks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Task mode manages sessions by the task each one completes (see the
;; `tasks' module).  Its buffer is a small kanban for the current
;; project, one section per column, most urgent first:
;;
;;   Requires your input   blocked on a permission or question, or stopped
;;   In progress           working, with its current todo and progress
;;   Pending               waiting for a slot; editable, startable
;;   Completed             finished; reply to reopen, archive to hide
;;
;; and a compose box at the bottom: describe a task, C-c C-c submits it
;; and it gets a session of its own.  The same box edits a pending task
;; (e) or replies to a task's session (m) without leaving the board.
;; RET or a click on a task opens its session in full.
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
(require 'harness-ui)

(defgroup harness-ui-tasks nil
  "Task mode." :group 'harness-ui)


(defcustom harness-ui-tasks-tick 15
  "Seconds between refreshes of the elapsed times on visible boards."
  :type 'number :group 'harness-ui-tasks)

(defface harness-task-title-face '((t :inherit bold))
  "Task titles." :group 'harness-ui-tasks)
(defface harness-task-section-face '((t :inherit (harness-label-face) :height 1.05))
  "Column headings." :group 'harness-ui-tasks)
(defface harness-task-attention-face '((t :inherit harness-status-blocked-face))
  "Why a task needs the user." :group 'harness-ui-tasks)
(defface harness-task-done-face '((t :inherit success))
  "The completed mark." :group 'harness-ui-tasks)

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
(defvar-local harness-ui-tasks--loading t)
(defvar-local harness-ui-tasks--error nil "Last failure, shown above the compose box.")
(defvar-local harness-ui-tasks--show-archived nil)
(defvar-local harness-ui-tasks--folded nil "Columns whose section is folded.")
(defvar-local harness-ui-tasks--submitting nil "Prompts sent but not yet acknowledged.")
(defvar-local harness-ui-tasks--target nil
  "What the compose box does: nil (new task), (edit . ID) or (reply . ID).")
(defvar-local harness-ui-tasks--list-end nil "Marker: end of the board, start of the tail.")
(defvar-local harness-ui-tasks--compose-start nil)
(defvar-local harness-ui-tasks--compose-end nil)
(defvar-local harness-ui-tasks--placeholder nil "Overlay showing the compose hint.")

(defun harness-ui-tasks--buffers ()
  "Return every live board buffer."
  (cl-remove-if-not (lambda (b) (eq (buffer-local-value 'major-mode b) 'harness-ui-tasks-mode))
                    (buffer-list)))

(defun harness-ui-tasks--find (id)
  "Return task ID of this board."
  (cl-find id harness-ui-tasks--tasks :key (lambda (task) (plist-get task :id)) :test #'equal))

(defun harness-ui-tasks--column (task)
  "Return TASK's column as a symbol."
  (intern (or (plist-get task :column)
              (pcase (plist-get task :state) ("pending" "pending") ("done" "done") (_ "active")))))

(defun harness-ui-tasks--archived-p (task)
  (harness-json-true-p (plist-get task :archived)))

(defun harness-ui-tasks--visible ()
  "Return the tasks shown, as an alist COLUMN -> tasks in display order."
  (let ((groups (mapcar (lambda (c) (list (car c))) harness-ui-tasks--columns)))
    (dolist (task harness-ui-tasks--tasks)
      (unless (and (harness-ui-tasks--archived-p task) (not harness-ui-tasks--show-archived))
        (push task (cdr (assq (harness-ui-tasks--column task) groups)))))
    (dolist (g groups groups)
      (setcdr g (sort (cdr g)
                      (if (eq (car g) 'done)
                          (lambda (a b) (> (or (plist-get a :finished) 0) (or (plist-get b :finished) 0)))
                        (lambda (a b) (< (or (plist-get a :created) 0) (or (plist-get b :created) 0)))))))))

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
  "Describe the first pending request of SESSION."
  (when-let* ((item (car (plist-get session :pending))))
    (let ((payload (plist-get item :payload)))
      (if (equal (plist-get item :kind) "question")
          (format "asks: %s" (or (plist-get payload :question) "a question"))
        (format "wants to run %s" (or (plist-get payload :title) (plist-get payload :tool) "a tool"))))))

(defun harness-ui-tasks--icon (task column session)
  (pcase column
    ('pending (propertize (harness-ui-icon 'harness-icon-task-pending) 'face 'harness-dim-face))
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
                       (if (equal (plist-get task :outcome) "merge-failed")
                           (format "could not merge into %s: %s" (harness-ui-tasks--base task)
                                   (or (plist-get task :error) "?"))
                         (format "stopped: %s%s" (or (plist-get task :outcome) "?")
                                 (if (plist-get task :error) (concat " — " (plist-get task :error)) ""))))
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
      ('pending (propertize (format "#%d in line%s" position
                                    (if (string-match-p "\n" (plist-get task :prompt))
                                        (concat " · " (harness-first-line
                                                       (cadr (split-string (plist-get task :prompt) "\n" t)) 70))
                                      ""))
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
                        ('pending (format "queued %s" (harness-relative-time (plist-get task :created))))
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
  "Return (LABEL COMMAND KEY) for the actions that apply to TASK, primary first."
  (let ((column (harness-ui-tasks--column task)))
    (append
     (pcase column
       ('pending '(("Start now" harness-ui-tasks-start "s") ("Edit" harness-ui-tasks-edit "e")
                   ("Drop" harness-ui-tasks-cancel "k")))
       ('needs-input
        (pcase (plist-get (harness-ui-tasks--pending task) :kind)
          ("permission" '(("Allow" harness-ui-tasks-allow "y") ("Deny" harness-ui-tasks-deny "n")
                          ("Open" harness-ui-tasks-open "RET") ("Stop" harness-ui-tasks-cancel "k")))
          ("question" '(("Answer" harness-ui-tasks-reply "m") ("Open" harness-ui-tasks-open "RET")
                        ("Stop" harness-ui-tasks-cancel "k")))
          (_ (if (equal (plist-get task :outcome) "merge-failed")
                 '(("Retry merge" harness-ui-tasks-merge "M") ("Reply" harness-ui-tasks-reply "m")
                   ("Open" harness-ui-tasks-open "RET") ("Mark done" harness-ui-tasks-complete "d"))
               '(("Open" harness-ui-tasks-open "RET") ("Reply" harness-ui-tasks-reply "m")
                 ("Mark done" harness-ui-tasks-complete "d"))))))
       ('active '(("Open" harness-ui-tasks-open "RET") ("Steer" harness-ui-tasks-reply "m")
                  ("Stop" harness-ui-tasks-cancel "k")))
       ('done (if (harness-ui-tasks--archived-p task)
                  '(("Unarchive" harness-ui-tasks-archive "x") ("Open" harness-ui-tasks-open "RET"))
                '(("Archive" harness-ui-tasks-archive "x") ("Reply" harness-ui-tasks-reply "m")
                  ("Open" harness-ui-tasks-open "RET")))))
     '(("Delete…" harness-ui-tasks-delete "D")))))

(defun harness-ui-tasks--button (label action help)
  "Return a button string LABEL running ACTION (no arguments)."
  (buttonize label (lambda (_) (funcall action)) nil help))

(defun harness-ui-tasks--pending (task)
  "Return the first pending request of TASK's session, or nil."
  (car (plist-get (harness-ui-tasks--session task) :pending)))

(defun harness-ui-tasks--card-buttons (task)
  "Buttons for TASK's two most useful actions besides opening it.
A question's options come first, so it can be answered in one click."
  (let* ((id (plist-get task :id))
         (pending (and (eq (harness-ui-tasks--column task) 'needs-input) (harness-ui-tasks--pending task)))
         (options (and (equal (plist-get pending :kind) "question")
                       (plist-get (plist-get pending :payload) :options))))
    (string-join
     (append
      (mapcar (lambda (option)
                (harness-ui-tasks--button (format "[%s]" option)
                                          (lambda () (harness-ui-tasks--answer task option))
                                          "Answer with this option"))
              (take 3 options))
      (mapcar (lambda (a)
                (harness-ui-tasks--button
                 (format "[%s]" (car a))
                 (lambda () (harness-ui-tasks--with-task id (call-interactively (nth 1 a))))
                 (format "%s (%s)" (car a) (nth 2 a))))
              (take (if options 1 2) (cl-remove 'harness-ui-tasks-open (harness-ui-tasks--actions task) :key #'cadr))))
     " ")))

;;;; Rendering

(defun harness-ui-tasks--insert-card (task column position)
  (let* ((start (point))
         (session (harness-ui-tasks--session task))
         (meta (harness-ui-tasks--meta task column session))
         (detail (harness-ui-tasks--detail task column session position))
         (buttons (harness-ui-tasks--card-buttons task)))
    (insert "  " (harness-ui-tasks--icon task column session) " "
            (propertize (harness-ui-tasks--title task)
                        'face (if (eq column 'done) 'default 'harness-task-title-face)
                        'mouse-face 'highlight
                        'help-echo "mouse-1: open the session · mouse-3: actions")
            (propertize " " 'display `(space :align-to (- right ,(1+ (string-width meta)))))
            meta "\n"
            "    " (or detail "")
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
                                         "Archive every completed task (X)")))
        (insert (propertize " " 'display `(space :align-to (- right ,(1+ (string-width b))))) b)))
    (insert "\n")
    (put-text-property start (point) 'harness-task-section column)
    (unless folded
      (when (eq column 'pending)
        (dolist (text (reverse harness-ui-tasks--submitting))
          (insert (propertize (format "  %s %s  submitting…\n"
                                      (harness-ui-icon 'harness-icon-task-pending)
                                      (harness-first-line text 60))
                              'face 'harness-dim-face))))
      (if (and (null tasks) (not (and (eq column 'pending) harness-ui-tasks--submitting)))
          (insert (propertize (pcase column
                                ('needs-input "    nothing needs you\n")
                                ('active "    nothing working\n")
                                ('pending "    no tasks waiting\n")
                                (_ "    none yet\n"))
                              'face 'harness-dim-face))
        (cl-loop for task in tasks for i from 1
                 do (harness-ui-tasks--insert-card task column i))))
    (insert "\n")))

(defun harness-ui-tasks--insert-board ()
  (cond
   ((and harness-ui-tasks--loading (null harness-ui-tasks--tasks))
    (insert (propertize "\n  loading tasks…\n" 'face 'harness-dim-face)))
   (t
    (insert "\n")
    (let ((groups (harness-ui-tasks--visible)))
      (if (and (null harness-ui-tasks--tasks) (null harness-ui-tasks--submitting))
          (insert (propertize "  No tasks yet.  Describe one below and press C-c C-c:\n  it gets a session of its own and works on it while you do something else.\n\n"
                              'face 'harness-dim-face))
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
    (force-mode-line-update)))

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
    (_ (concat "New task"
               (let ((s harness-ui-tasks--settings))
                 (if s (propertize
                        (format "   %sruns %s%s · %s at a time"
                                (if (harness-json-true-p (plist-get s :worktrees))
                                    "own worktree, merged when done · " "")
                                (or (plist-get s :permission-mode) "in the default mode")
                                (if (harness-json-true-p (plist-get s :non-interactive)) ", non-interactive" "")
                                (or (plist-get s :max-running) "any number"))
                        'face 'harness-dim-face)
                   ""))))))

(defun harness-ui-tasks--render-tail (&optional text)
  "Draw the error line, the compose label and the compose box.
TEXT replaces the compose contents; without it they are kept."
  (let* ((inhibit-read-only t)
         (buffer-undo-list t)
         (text (or text (harness-ui-tasks--compose-text)))
         (in-compose (harness-ui-tasks--in-compose-p))
         (offset (and in-compose (- (point) harness-ui-tasks--compose-start)))
         (list-end (marker-position harness-ui-tasks--list-end))
         ;; Windows whose point is in the tail go back to the same spot of the box.
         (windows (mapcar (lambda (w)
                            (let ((p (window-point w)))
                              (cons w (and harness-ui-tasks--compose-start (>= p list-end)
                                           (max 0 (- p harness-ui-tasks--compose-start))))))
                          (get-buffer-window-list nil nil t))))
    (when harness-ui-tasks--placeholder (delete-overlay harness-ui-tasks--placeholder))
    (save-excursion
      (delete-region list-end (point-max))
      (goto-char list-end)
      (let ((start (point)))
        (when harness-ui-tasks--error
          (insert (propertize (concat "  " harness-ui-tasks--error "\n") 'face 'harness-tool-error-face)))
        (let ((label (concat " " (harness-ui-tasks--compose-label))))
          ;; Appended, so the dim settings note keeps its own face.
          (add-face-text-property 0 (length label) 'harness-label-face t label)
          (insert label))
        (when harness-ui-tasks--target
          (insert "  " (harness-ui-tasks--button "[cancel]" #'harness-ui-tasks-compose-reset
                                                 "Back to a new task (C-c C-k)")))
        (insert "\n")
        (let ((label (point)))
          (insert (propertize "❯ "
                              'face '(harness-dim-face harness-compose-face)
                              'help-echo "C-c C-c submits · RET newline · C-c C-k resets"))
          (put-text-property start (point) 'read-only t)
          (put-text-property (1- (point)) (point) 'rear-nonsticky t)
          (setq harness-ui-tasks--compose-start (copy-marker (point)))
          (insert text)
          (let ((end (point)))
            (insert (propertize "\n" 'read-only t))
            (setq harness-ui-tasks--compose-end (copy-marker end t)))
          (let ((ov (make-overlay label (point) nil t t)))
            (overlay-put ov 'face 'harness-compose-face)
            (overlay-put ov 'harness-ui-tasks t)))
        (setq harness-ui-tasks--placeholder (make-overlay (1- (point)) (point)))
        (harness-ui-tasks--update-placeholder)))
    (set-marker harness-ui-tasks--list-end list-end)
    (pcase-dolist (`(,w . ,off) windows)
      (when (and off (window-live-p w))
        (set-window-point w (min (+ harness-ui-tasks--compose-start off) harness-ui-tasks--compose-end))))
    (set-buffer-modified-p nil)
    (when offset (goto-char (min (+ harness-ui-tasks--compose-start offset) harness-ui-tasks--compose-end)))))

(defun harness-ui-tasks--update-placeholder ()
  (when (and harness-ui-tasks--placeholder (overlay-buffer harness-ui-tasks--placeholder))
    (overlay-put harness-ui-tasks--placeholder 'before-string
                 (and (= harness-ui-tasks--compose-start harness-ui-tasks--compose-end)
                      (propertize (pcase harness-ui-tasks--target
                                    (`(edit . ,_) "the new prompt…  C-c C-c saves")
                                    (`(reply . ,_) "a message for this task's session…  C-c C-c sends")
                                    (`(answer . ,_) "your answer…  C-c C-c answers")
                                    (_ "Describe a task…  C-c C-c submits · RET newline"))
                                  'face 'harness-dim-face 'cursor t)))))

(defun harness-ui-tasks--compose-text ()
  (if (and harness-ui-tasks--compose-start (marker-buffer harness-ui-tasks--compose-start))
      (buffer-substring-no-properties harness-ui-tasks--compose-start harness-ui-tasks--compose-end)
    ""))

(defun harness-ui-tasks--in-compose-p ()
  (and harness-ui-tasks--compose-start (marker-buffer harness-ui-tasks--compose-start)
       (>= (point) harness-ui-tasks--compose-start) (<= (point) harness-ui-tasks--compose-end)))

(defun harness-ui-tasks--set-compose (text target)
  "Put TEXT in the compose box for TARGET and move there."
  (setq harness-ui-tasks--target target)
  (harness-ui-tasks--render-tail text)
  (goto-char harness-ui-tasks--compose-end)
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
     (format "  %s %d working  %s %d pending  %s %d done"
             (harness-ui-icon 'harness-icon-running) (alist-get 'active counts)
             (harness-ui-icon 'harness-icon-task-pending) (alist-get 'pending counts)
             (harness-ui-icon 'harness-icon-task-done) (alist-get 'done counts))
     "   "
     (harness-ui-tasks--segment "[New task]" #'harness-ui-tasks-compose "Describe a new task (a)")
     " "
     (harness-ui-tasks--segment (if harness-ui-tasks--show-archived "[Hide archived]" "[Show archived]")
                                #'harness-ui-tasks-toggle-archived "Show or hide archived tasks (A)")
     " "
     (harness-ui-tasks--segment "[Refresh]" #'harness-ui-tasks-refresh "Reload the board (g)")
     (if harness-ui-tasks--loading (propertize "  loading…" 'face 'harness-dim-face) ""))))

;;;; Data

(defun harness-ui-tasks--fail (buffer what err)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq harness-ui-tasks--loading nil
            harness-ui-tasks--error (format "%s failed: %s" what (harness-error-message err)))
      (harness-ui-tasks--render)
      (harness-ui-tasks--render-tail))))

(defun harness-ui-tasks--fetch (buffer)
  "Load BUFFER's project root, tasks and settings from the harness."
  (with-current-buffer buffer
    (setq harness-ui-tasks--loading t)
    (let ((dir harness-ui-tasks--dir))
      (harness-ui-call "_harness/task/settings" (list :cwd dir)
                       (lambda (s) (when (buffer-live-p buffer)
                                     (with-current-buffer buffer
                                       (setq harness-ui-tasks--settings s)
                                       (when (and harness-ui-tasks--compose-start (null harness-ui-tasks--target))
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
       (lambda (e) (harness-ui-tasks--fail buffer "Finding the project" e))))))

(defun harness-ui-tasks--schedule-render (buffer)
  (harness-debounce (list 'harness-ui-tasks buffer) 0.1
                    (lambda () (when (buffer-live-p buffer)
                                 (with-current-buffer buffer (harness-ui-tasks--render))))))

(defun harness-ui-tasks--on-event (event args)
  "Follow `task/changed' and `task/deleted' on every board."
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
  (define-key map (kbd "y") #'harness-ui-tasks-allow)
  (define-key map (kbd "n") #'harness-ui-tasks-deny)
  (define-key map (kbd "k") #'harness-ui-tasks-cancel)
  (define-key map (kbd "d") #'harness-ui-tasks-complete)
  (define-key map (kbd "M") #'harness-ui-tasks-merge)
  (define-key map (kbd "x") #'harness-ui-tasks-archive)
  (define-key map (kbd "X") #'harness-ui-tasks-archive-done)
  (define-key map (kbd "D") #'harness-ui-tasks-delete)
  (define-key map (kbd "A") #'harness-ui-tasks-toggle-archived)
  (define-key map (kbd "g") #'harness-ui-tasks-refresh)
  (define-key map (kbd "q") #'quit-window)
  (define-key map (kbd "?") #'harness-menu))

(defvar harness-ui-tasks-mode-map
  ;; No `special-mode-map' parent: its letters would eat typing in the compose box.
  (let ((map (make-sparse-keymap))) (set-keymap-parent map (make-sparse-keymap)) map)
  "Keymap of `harness-ui-tasks-mode'.")

(let ((map harness-ui-tasks-mode-map))
  (define-key map (kbd "C-c C-c") #'harness-ui-tasks-submit)
  (define-key map (kbd "C-c C-k") #'harness-ui-tasks-compose-reset)
  (define-key map (kbd "C-c C-n") #'harness-ui-tasks-next)
  (define-key map (kbd "C-c C-p") #'harness-ui-tasks-previous))

(define-derived-mode harness-ui-tasks-mode special-mode "Tasks"
  "Major mode of the task board: a kanban of tasks above a compose box.
\\{harness-ui-tasks-board-map}"
  (setq buffer-read-only nil)
  (setq-local truncate-lines t
              header-line-format '(:eval (harness-ui-tasks--header)))
  (add-hook 'post-command-hook #'harness-ui-tasks--update-placeholder nil t))

(defun harness-ui-tasks--buffer-name (dir)
  (format "*harness tasks: %s*" (file-name-nondirectory (directory-file-name dir))))

(defun harness-ui-tasks--local-root (dir)
  "Guess DIR's project root in this Emacs, for naming the buffer only."
  (or (ignore-errors (when-let* ((pr (project-current nil dir))) (project-root pr)))
      dir))

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
              harness-ui-tasks--dir root)
        (harness-ui-tasks--render)
        (harness-ui-tasks--render-tail "")
        (goto-char harness-ui-tasks--compose-end))
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
    (harness-ui-call "_harness/session/resume" (list :id sid)
                     (lambda (_) (funcall open sid)))))

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
           (mapcar (lambda (a) (vector (format "%s  (%s)" (car a) (nth 2 a)) (nth 1 a) t))
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
    (goto-char harness-ui-tasks--compose-end)))

(defun harness-ui-tasks-compose-reset ()
  "Empty the compose box and make it describe a new task again."
  (interactive)
  (harness-ui-tasks--set-compose "" nil))

(defun harness-ui-tasks-submit ()
  "Submit the compose box: a new task, an edited prompt or a message."
  (interactive)
  (let ((text (string-trim (harness-ui-tasks--compose-text)))
        (target harness-ui-tasks--target)
        (buffer (current-buffer)))
    (when (string-empty-p text) (user-error "Describe the task first"))
    (setq harness-ui-tasks--error nil)
    (pcase target
      (`(edit . ,id)
       (harness-ui-tasks--request-then "_harness/task/update" (list :id id :prompt text) "Editing the task")
       (message "Task updated"))
      (`(reply . ,id)
       (harness-ui-tasks--request-then "_harness/task/prompt" (list :id id :text text) "Sending the message")
       (message "Sent to the task's session"))
      (`(answer . ,id) (harness-ui-tasks--answer (harness-ui-tasks--find id) text))
      (_
       (push text harness-ui-tasks--submitting)
       (harness-ui-tasks--render)
       (harness-ui-call
        "_harness/task/submit" (list :cwd harness-ui-tasks--dir :prompt text)
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
              (when (string-empty-p (string-trim (harness-ui-tasks--compose-text)))
                (harness-ui-tasks--render-tail text))
              (harness-ui-tasks--fail buffer "Submitting the task" e)))))))
    (harness-ui-tasks--set-compose "" nil)))

(defun harness-ui-tasks-start ()
  "Start the pending task at point now, even when every slot is busy."
  (interactive)
  (harness-ui-tasks--request-then "_harness/task/start" (list :id (plist-get (harness-ui-tasks--task) :id))
                                  "Starting the task"))

(defun harness-ui-tasks-edit ()
  "Edit the prompt of the pending task at point in the compose box."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (unless (equal (plist-get task :state) "pending") (user-error "Only pending tasks can be edited"))
    (harness-ui-tasks--set-compose (plist-get task :prompt) (cons 'edit (plist-get task :id)))))

(defun harness-ui-tasks-reply ()
  "Write a message to the session of the task at point."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (unless (plist-get task :session) (user-error "This task has not started yet"))
    (harness-ui-tasks--set-compose
     "" (cons (if (equal (plist-get (harness-ui-tasks--pending task) :kind) "question") 'answer 'reply)
              (plist-get task :id)))))

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
  "Stop the task at point, or drop it when it is still pending."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (when (or (not (equal (plist-get task :state) "pending"))
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
