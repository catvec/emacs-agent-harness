;;; harness-ui-sessions.el --- Session list  -*- lexical-binding: t; -*-

;;; Commentary:

;; A `tabulated-list-mode' buffer of sessions: status, name, kind,
;; model, permission mode, context, cost, age and project.  Child
;; sessions (forks, BTW conversations, sub-agents) are indented under
;; their parents.  Scoped to the current project by default; `a'
;; toggles all projects; `/' filters fuzzily; column headers sort.
;;
;; SPC pops out what the session at point waits on -- the permission
;; prompt or question blocking it -- so it can be read and answered
;; without opening the session (`harness-ui-popout-at-point').
;;
;; A project includes its linked git worktrees: a session there (a
;; task's, a sub-agent's) has the worktree as its `:project', and is
;; listed with the main checkout that worktree belongs to.
;;
;; A session that works on a task is of kind task, and is called by its
;; task's title, as on the board, until it has a name of its own.  A
;; session is named after its first turn, and a task does its work in
;; that turn, so without the title every task at work would read
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

(declare-function harness-ui-popout-try-at-point "harness-ui-popout")

(defgroup harness-ui-sessions nil
  "The session list." :group 'harness-ui)

(defconst harness-ui-sessions--buffer-name "*harness sessions*"
  "Name of the session list buffer.")

(defvar-local harness-ui-sessions--project nil
  "Main checkout the list is scoped to, or nil for all projects.")
(defvar-local harness-ui-sessions--filter "" "Fuzzy filter text.")
(defvar-local harness-ui-sessions--show-inactive t)
(defvar-local harness-ui-sessions--main-roots nil
  "Hash table: session project root -> the main checkout it belongs to.
Which checkout a root belongs to does not change, and the list redraws
on every session change, so each root is resolved once; `g' forgets them.")
(defvar-local harness-ui-sessions--tasks nil
  "Hash table: session id -> the task (wire plist) that session works on.
Nil until the harness has said which tasks there are; a harness without
tasks never does.")

(defun harness-ui-sessions--main-root (root)
  "Return the main checkout session project ROOT belongs to.
A linked git worktree belongs to its main checkout.  A root gone from
disk, like an archived task's worktree, belongs to the project around it.
Remote roots are not looked at."
  (when root
    (let ((memo (or harness-ui-sessions--main-roots
                    (setq harness-ui-sessions--main-roots (make-hash-table :test 'equal)))))
      (or (gethash root memo)
          (puthash root
                   (cond ((file-remote-p root) root)
                         ((file-directory-p root) (harness-files-main-checkout root))
                         (t (harness-files-main-root root)))
                   memo)))))

(defun harness-ui-sessions--task (s)
  "Return the task session S works on, or nil."
  (and harness-ui-sessions--tasks
       (gethash (plist-get s :id) harness-ui-sessions--tasks)))

(defun harness-ui-sessions--name (s)
  "Return what the list calls session S, or nil when it has no name.
A task's session is called by its task's title until it is named."
  (let* ((task (harness-ui-sessions--task s))
         (name (if task (harness-ui-task-title task s) (plist-get s :name))))
    (and (not (harness-string-blank-p name)) name)))

(defun harness-ui-sessions--kind (s)
  "Return the kind the list shows for session S: task for a task's session."
  (if (harness-ui-sessions--task s) "task" (or (plist-get s :kind) "main")))

(defun harness-ui-sessions--matches-p (s)
  "Non-nil when session S belongs in the list: scope, status and filter.
The filter matches what the list shows of S: its name or task title,
model, status, kind and permission mode."
  (and (or (null harness-ui-sessions--project)
           (equal (harness-ui-sessions--main-root (plist-get s :project))
                  harness-ui-sessions--project))
       (or harness-ui-sessions--show-inactive
           (not (equal (plist-get s :status) "inactive")))
       (or (string-empty-p harness-ui-sessions--filter)
           (harness-fuzzy-score harness-ui-sessions--filter
                                (format "%s %s %s %s %s" (or (harness-ui-sessions--name s) "") (plist-get s :model)
                                        (plist-get s :status) (harness-ui-sessions--kind s)
                                        (plist-get s :permission-mode))))))

(defun harness-ui-sessions--ordered ()
  "Return matching sessions as (DEPTH . SESSION), parents before children."
  (let* ((all (harness-ui-sessions))
         (matching (cl-remove-if-not #'harness-ui-sessions--matches-p all))
         (by-id (make-hash-table :test 'equal))
         (children (make-hash-table :test 'equal))
         (out nil))
    (dolist (s all) (puthash (plist-get s :id) s by-id))
    (dolist (s matching)
      (let ((pid (plist-get s :parent-id)))
        (if (and pid (gethash pid by-id) (cl-member pid matching :key (lambda (x) (plist-get x :id)) :test #'equal))
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

(defun harness-ui-sessions--entry (depth s)
  (let* ((name (or (harness-ui-sessions--name s) (propertize "unnamed" 'face 'harness-dim-face)))
         (status (plist-get s :status))
         (kind (harness-ui-sessions--kind s)))
    (list (plist-get s :id)
          (vector
           (harness-ui-status-icon status)
           (concat (make-string (* 2 depth) ?\s)
                   (if (> depth 0) (propertize "↳ " 'face 'harness-dim-face) "")
                   (propertize name 'face (if (equal status "blocked") 'harness-status-blocked-face 'default)))
           (propertize status 'face (harness-ui-status-face status)
                       'help-echo (or (harness-ui-sessions--waiting-help s) status))
           (if (equal kind "main") "" kind)
           (harness-ui-model-label (plist-get s :model))
           (if-let* ((m (plist-get s :permission-mode))) (harness-ui-permission-mode-label m) "")
           (harness-ui-format-context s)
           (harness-ui-format-spend s)
           (harness-relative-time (or (plist-get s :updated) 0))
           (propertize (file-name-nondirectory (directory-file-name (or (plist-get s :project) ""))) 'face 'harness-dim-face)))))

(defun harness-ui-sessions--refresh ()
  (setq tabulated-list-entries
        (mapcar (lambda (cell) (harness-ui-sessions--entry (car cell) (cdr cell)))
                (harness-ui-sessions--ordered)))
  (setq mode-line-process
        (format " [%s%s%s]"
                (if harness-ui-sessions--project "project" "all projects")
                (if (string-empty-p harness-ui-sessions--filter) "" (format " /%s" harness-ui-sessions--filter))
                (if harness-ui-sessions--show-inactive "" " active"))))

(defun harness-ui-sessions--number< (col)
  (lambda (a b)
    (let ((x (harness-ui-session (car a))) (y (harness-ui-session (car b))))
      (< (or (harness-plist-get-in x col) 0) (or (harness-plist-get-in y col) 0)))))

(defun harness-ui-sessions--spend< (a b)
  "Order entries A and B by what their sessions cost at API prices.
Sessions a plan pays for cost nothing but still sort by how much they used."
  (< (harness-usage-list-cost (plist-get (harness-ui-session (car a)) :usage))
     (harness-usage-list-cost (plist-get (harness-ui-session (car b)) :usage))))

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
    (define-key map (kbd "T") #'harness-ui-sessions-make-task)
    (define-key map (kbd "/") #'harness-ui-sessions-filter)
    (define-key map (kbd "a") #'harness-ui-sessions-toggle-scope)
    (define-key map (kbd "i") #'harness-ui-sessions-toggle-inactive)
    (define-key map (kbd "g") #'harness-ui-sessions-reload)
    (define-key map (kbd "SPC") #'harness-ui-sessions-requests)
    (define-key map (kbd "?") #'harness-menu)
    map))

(define-derived-mode harness-ui-sessions-mode tabulated-list-mode "Sessions"
  "Major mode listing harness sessions."
  (setq tabulated-list-format
        (vector (list "" 2 t)
                (list "Name" 28 t)
                (list "Status" 9 t)
                (list "Kind" 9 t)
                (list "Model" 26 t)
                (list "Mode" 13 t)
                (list "Context" 12 (harness-ui-sessions--number< '(:usage :context)))
                (list "Cost" 10 #'harness-ui-sessions--spend<)
                (list "Updated" 9 (harness-ui-sessions--number< '(:updated)))
                (list "Project" 30 t)))
  (setq tabulated-list-padding 1)
  ;; What the session at point waits on: the popout, and any other command
  ;; that acts on "the session at point", read it through this.
  (setq-local harness-ui-session-at-point-function
              (lambda () (and (derived-mode-p 'harness-ui-sessions-mode) (tabulated-list-get-id))))
  (add-hook 'tabulated-list-revert-hook #'harness-ui-sessions--refresh nil t)
  (tabulated-list-init-header))

;; The list's keys in the harness menu, behind `.'.
(put 'harness-ui-sessions-mode 'harness-menu-group
     '("Session list"
       ["Session at point"
        (". RET" "Open" harness-ui-sessions-open)
        (". o" "Open in position" harness-ui-sessions-open-other)
        (". f" "Fork" harness-ui-sessions-fork)
        (". r" "Rename" harness-ui-sessions-rename)
        (". k" "Cancel turn" harness-ui-sessions-cancel)
        (". x" "Deactivate" harness-ui-sessions-deactivate)
        (". SPC" "View what it waits on" harness-ui-sessions-requests)
        (". T" "Make it a task" harness-ui-sessions-make-task)
        (". d" "Delete" harness-ui-sessions-delete)]
       ["List"
        (". /" "Filter" harness-ui-sessions-filter)
        (". a" "This project or all" harness-ui-sessions-toggle-scope)
        (". i" "Show or hide inactive" harness-ui-sessions-toggle-inactive)
        (". g" "Reload" harness-ui-sessions-reload)]))

(defun harness-ui-sessions--redraw ()
  "Redraw the list buffer if it exists, keeping point on the same session."
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (let ((id (tabulated-list-get-id)))
        (harness-ui-sessions--refresh)
        (tabulated-list-print t)
        (when id
          (goto-char (point-min))
          (while (and (not (eobp)) (not (equal (tabulated-list-get-id) id)))
            (forward-line 1))
          (when (eobp) (goto-char (point-min))))))))

(defun harness-ui-sessions--on-changed ()
  (harness-debounce 'harness-ui-sessions 0.15 #'harness-ui-sessions--redraw))

;;;; Tasks

(defun harness-ui-sessions--fetch-tasks ()
  "Ask the harness for every project's tasks, then redraw the list.
The list keeps those that have a session, by session.  When the request
fails, as on a harness without tasks, the list names no task."
  (when (get-buffer harness-ui-sessions--buffer-name)
    (cl-flet ((keep (table)
                (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
                  (with-current-buffer buf (setq harness-ui-sessions--tasks table))
                  (harness-ui-sessions--redraw))))
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
A task changes session when it starts, so it is looked up by its id."
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
(defun harness-sessions (&optional all-projects)
  "Show the session list, scoped to the current project unless ALL-PROJECTS.
The project includes its git worktrees, so its tasks' sessions are
listed, and from a task's worktree the list shows the whole project.
A task's session shows its task's title until it is named."
  (interactive "P")
  (let ((project (unless all-projects
                   (harness-files-main-root default-directory)))
        (buf (get-buffer-create harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-sessions-mode) (harness-ui-sessions-mode))
      (setq harness-ui-sessions--project project)
      (harness-ui-sessions--refresh)
      (tabulated-list-print t))
    (harness-ui-refresh-sessions (lambda (_) (harness-ui-sessions--redraw)))
    (harness-ui-sessions--fetch-tasks)
    (harness-ui-display-view buf)))

(defun harness-ui-sessions--id ()
  (or (tabulated-list-get-id) (user-error "No session on this line")))

(defun harness-ui-sessions-open (&optional position)
  "Open the session at point in POSITION, by default replacing the list."
  (interactive (list (and current-prefix-arg (harness-ui-read-position))))
  (funcall (harness-ui-session-opener position) (harness-ui-sessions--id)))

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
  "Fork the session at point."
  (interactive)
  (harness-fork-session (harness-ui-sessions--id)))

(defun harness-ui-sessions-delete ()
  "Delete the session at point."
  (interactive)
  (harness-delete-session (harness-ui-sessions--id)))

(defun harness-ui-sessions-rename (name)
  "Rename the session at point to NAME."
  (interactive (list (read-string "Name: " (plist-get (harness-ui-session (harness-ui-sessions--id)) :name))))
  (harness-rename-session name (harness-ui-sessions--id)))

(defun harness-ui-sessions-cancel ()
  "Cancel the running turn of the session at point."
  (interactive)
  (harness-cancel-turn (harness-ui-sessions--id)))

(defun harness-ui-sessions-make-task ()
  "Make the session at point a task, shown on its project's task board."
  (interactive)
  ;; The board's keys follow `harness-ui-prefix-key'; look them up here,
  ;; in the list buffer, not in whatever buffer is current on the reply.
  (let ((board (substitute-command-keys "\\[harness-tasks]" t)))
    (harness-ui-call "_harness/task/adopt" (list :session-id (harness-ui-sessions--id))
                     (lambda (_) (message "Added to the task board (%s)" board)))))

(defun harness-ui-sessions-deactivate ()
  "Mark the session at point inactive."
  (interactive)
  (harness-ui-call "_harness/session/deactivate" (list :id (harness-ui-sessions--id)) #'ignore))

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

(defun harness-ui-sessions-reload ()
  "Reload sessions and tasks from the harness and resolve their projects again."
  (interactive)
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf (setq harness-ui-sessions--main-roots nil)))
  (harness-ui-refresh-sessions (lambda (_) (harness-ui-sessions--redraw)))
  (harness-ui-sessions--fetch-tasks))

(defun harness-ui-sessions--waiting-help (session)
  "Return the tooltip of SESSION's status cell, saying what it waits on."
  (when (equal (plist-get session :status) "blocked")
    (let ((what (harness-ui-pending-status session)))
      (format "%s; SPC shows what it waits on"
              (if (equal what "question") "blocked on a question" "blocked on a permission request")))))

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

(defun harness-ui-sessions--init ()
  (add-hook 'harness-ui-sessions-changed-hook #'harness-ui-sessions--on-changed)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-sessions--redraw)
  ;; After a reload or reconnect the tasks may be another harness's.
  (add-hook 'harness-ui-redraw-hook #'harness-ui-sessions--fetch-tasks)
  (add-hook 'harness-ui-event-functions #'harness-ui-sessions--on-event)
  (define-key harness-ui-map (kbd "l") #'harness-sessions))

(harness-define-module 'ui-sessions
  :doc "Session list buffer."
  :requires '(ui)
  :init #'harness-ui-sessions--init)

(provide 'harness-ui-sessions)
;;; harness-ui-sessions.el ends here
