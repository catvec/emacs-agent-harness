;;; harness-ui-sessions.el --- Session list  -*- lexical-binding: t; -*-

;;; Commentary:

;; A `tabulated-list-mode' buffer of sessions: status, name, kind,
;; model, permission mode, context, output rate (tokens per second,
;; dimmed once the session is idle), cost, age and project.  Child
;; sessions (forks, BTW conversations, sub-agents) are indented under
;; their parents.  Scoped to the current project by default; `a'
;; toggles all projects; `b' shows only the sessions waiting for you;
;; `/' filters fuzzily; column headers sort.
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

(declare-function harness-ui-popout-try-at-point "harness-ui-popout")

(defgroup harness-ui-sessions nil
  "The session list." :group 'harness-ui)

(defconst harness-ui-sessions--buffer-name "*harness sessions*"
  "Name of the session list buffer.")

(defvar-local harness-ui-sessions--project nil
  "Main checkout the list is scoped to, or nil for all projects.")
(defvar-local harness-ui-sessions--filter "" "Fuzzy filter text.")
(defvar-local harness-ui-sessions--show-inactive t)
(defvar-local harness-ui-sessions--blocked-only nil
  "Non-nil when the list shows only the sessions waiting for you.
That is the blocked ones: the mode line's notifier opens the list so.")
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

(defun harness-ui-sessions--matches-p (s)
  "Non-nil when session S belongs in the list: scope, status and filter.
The filter matches what the list shows of S: its name or task title,
model, status, kind and permission mode."
  (and (or (null harness-ui-sessions--project)
           (equal (harness-ui-sessions--main-root (plist-get s :project))
                  harness-ui-sessions--project))
       (or harness-ui-sessions--show-inactive
           (not (equal (plist-get s :status) "inactive")))
       (or (not harness-ui-sessions--blocked-only)
           (equal (plist-get s :status) "blocked"))
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
           (or (harness-ui-format-rate s t) "")
           (harness-ui-format-spend s)
           (harness-relative-time (or (plist-get s :updated) 0))
           (propertize (file-name-nondirectory (directory-file-name (or (plist-get s :project) ""))) 'face 'harness-dim-face)))))

(defun harness-ui-sessions--refresh ()
  (let ((ordered (harness-ui-sessions--ordered)))
    (setq harness-ui-sessions--depths (make-hash-table :test 'equal))
    (dolist (cell ordered)
      (puthash (plist-get (cdr cell) :id) (car cell) harness-ui-sessions--depths))
    (setq tabulated-list-entries
          (mapcar (lambda (cell) (harness-ui-sessions--entry (car cell) (cdr cell))) ordered)))
  (setq mode-line-process
        (format " [%s%s%s%s]"
                (if harness-ui-sessions--project "project" "all projects")
                (if (string-empty-p harness-ui-sessions--filter) "" (format " /%s" harness-ui-sessions--filter))
                (if harness-ui-sessions--show-inactive "" " active")
                (if harness-ui-sessions--blocked-only " blocked" ""))))

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

(defun harness-ui-sessions--request-line (id r)
  "Return the line under the row of session ID, which waits on request R.
It has the buttons answering R, then says what R is, under the name."
  (let ((depth (or (and harness-ui-sessions--depths (gethash id harness-ui-sessions--depths)) 0))
        (session (harness-ui-session id)))
    (concat (make-string (+ tabulated-list-padding 3 (* 2 depth) (if (> depth 0) 2 0)) ?\s)
            (mapconcat (lambda (a) (harness-ui-sessions--button (nth 0 a) (nth 1 a) (nth 2 a)))
                       (harness-ui-pending-view-actions id) " ")
            "  "
            (propertize (or (harness-ui-pending-summary session) "waits for you")
                        'face 'harness-status-blocked-face)
            (propertize " · " 'face 'harness-dim-face)
            (harness-ui-pending-subject r 80)
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

(defun harness-ui-sessions--print-entry (id cols)
  "Print the row of session ID, with the columns COLS, and what it waits on.
This is the list's `tabulated-list-printer'.  The banner of the blocked
filter goes above the first row, and a blocked session gets the line
of what it waits on under its row (`harness-ui-sessions--request-line'),
which is the session's too: RET opens it, SPC pops its request out."
  (when (and harness-ui-sessions--blocked-only (bobp))
    (insert (harness-ui-sessions--banner)))
  (let ((start (point)))
    (tabulated-list-print-entry id cols)
    (when-let* ((r (and (equal (plist-get (harness-ui-session id) :status) "blocked")
                        (harness-ui-pending-first id))))
      (let ((line (point)))
        (insert (harness-ui-sessions--request-line id r))
        (add-text-properties line (point) (list 'tabulated-list-id id 'tabulated-list-entry cols)))
      (when (equal (plist-get r :kind) "permission")
        (harness-ui-add-keymap start (point) harness-ui-sessions-permission-map)))))

(defun harness-ui-sessions--print ()
  "Print the list, the banner of the blocked filter even with no row to show."
  (tabulated-list-print t)
  (when (and harness-ui-sessions--blocked-only (= (point-min) (point-max)))
    (let ((inhibit-read-only t))
      (insert (harness-ui-sessions--banner))
      (set-buffer-modified-p nil))))

(defun harness-ui-sessions--position (id)
  "Return where the row of session ID starts, else the first row, else `point-min'."
  (save-excursion
    (goto-char (point-min))
    (let ((first nil) (found nil))
      (while (and (not found) (not (eobp)))
        (let ((here (tabulated-list-get-id)))
          (cond ((and id (equal here id)) (setq found (point)))
                ((and here (not first)) (setq first (point)))))
        (forward-line 1))
      (or found first (point-min)))))

(defun harness-ui-sessions--number< (col)
  (lambda (a b)
    (let ((x (harness-ui-session (car a))) (y (harness-ui-session (car b))))
      (< (or (harness-plist-get-in x col) 0) (or (harness-plist-get-in y col) 0)))))

(defun harness-ui-sessions--rate< (a b)
  "Order entries A and B by their sessions' output rates, unmeasured first."
  (< (or (plist-get (harness-ui-session-rate (car a)) :rate) -1)
     (or (plist-get (harness-ui-session-rate (car b)) :rate) -1)))

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

;; At top level, not in the `defvar', so a reload binds them in a running
;; Emacs too.
(define-key harness-ui-sessions-mode-map (kbd "F") #'harness-fullscreen)
(define-key harness-ui-sessions-mode-map (kbd "q") #'harness-ui-quit-view)
(define-key harness-ui-sessions-mode-map (kbd "C-c C-z") #'harness-ui-bury)
(define-key harness-ui-sessions-mode-map (kbd "b") #'harness-ui-sessions-toggle-blocked)

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
                (list "Tok/s" 6 #'harness-ui-sessions--rate< :right-align t)
                (list "Cost" 10 #'harness-ui-sessions--spend<)
                (list "Updated" 9 (harness-ui-sessions--number< '(:updated)))
                (list "Project" 30 t)))
  (setq tabulated-list-padding 1)
  ;; Rows, and under a blocked session's what it waits on.
  (setq tabulated-list-printer #'harness-ui-sessions--print-entry)
  ;; What the session at point waits on: the popout, and any other command
  ;; that acts on "the session at point", read it through this.
  (setq-local harness-ui-session-at-point-function
              (lambda () (and (derived-mode-p 'harness-ui-sessions-mode) (tabulated-list-get-id))))
  ;; An overview: the list can take the fullscreen layout (F).
  (setq-local harness-ui-overview-function #'harness-ui-sessions--overview-session)
  (add-hook 'tabulated-list-revert-hook #'harness-ui-sessions--refresh nil t)
  (tabulated-list-init-header))

;; The list's keys in the harness menu, behind `.'.
(put 'harness-ui-sessions-mode 'harness-menu-group
     '("Session list"
       ["Session at point"
        (". RET" "Open, in its project" harness-ui-sessions-open)
        (". o" "Open in position" harness-ui-sessions-open-other)
        (". f" "Fork" harness-ui-sessions-fork)
        (". r" "Rename" harness-ui-sessions-rename)
        (". k" "Cancel turn" harness-ui-sessions-cancel)
        (". x" "Deactivate" harness-ui-sessions-deactivate)
        (". SPC" "View what it waits on" harness-ui-sessions-requests)
        (". y" "Allow request" harness-ui-sessions-allow)
        (". n" "Deny request" harness-ui-sessions-deny)
        (". T" "Make it a task" harness-ui-sessions-make-task)
        (". d" "Delete" harness-ui-sessions-delete)]
       ["List"
        (". /" "Filter" harness-ui-sessions-filter)
        (". a" "This project or all" harness-ui-sessions-toggle-scope)
        (". b" "Only those waiting for you" harness-ui-sessions-toggle-blocked)
        (". i" "Show or hide inactive" harness-ui-sessions-toggle-inactive)
        (". F" "Fullscreen layout" harness-fullscreen)
        (". g" "Reload" harness-ui-sessions-reload)]))

(defun harness-ui-sessions--overview-session ()
  "Return the session to show beside the list in the fullscreen layout.
That is the session at point, else the most recently updated session
listed, BTW conversations aside."
  (or (and (derived-mode-p 'harness-ui-sessions-mode) (tabulated-list-get-id))
      (let (best newest)
        (dolist (entry (and (listp tabulated-list-entries) tabulated-list-entries) best)
          (let* ((session (harness-ui-session (car entry)))
                 (updated (or (plist-get session :updated) 0)))
            (when (and session (not (equal (plist-get session :kind) "btw"))
                       (or (null best) (> updated newest)))
              (setq best (car entry) newest updated)))))))

(defun harness-ui-sessions--redraw ()
  "Redraw the list buffer if it exists, keeping point on the same session.
Each window showing the list keeps its point on its session too; one
whose session is gone goes to the first row."
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (let ((id (tabulated-list-get-id))
            (windows (mapcar (lambda (w) (cons w (tabulated-list-get-id (window-point w))))
                             (get-buffer-window-list buf nil t))))
        (harness-ui-sessions--refresh)
        (harness-ui-sessions--print)
        (goto-char (harness-ui-sessions--position id))
        (pcase-dolist (`(,window . ,at) windows)
          (unless (eq window (selected-window))
            (set-window-point window (harness-ui-sessions--position at))))))))

(defun harness-ui-sessions--on-changed ()
  (harness-debounce 'harness-ui-sessions 0.15 #'harness-ui-sessions--redraw))

(defun harness-ui-sessions--on-rate (_id _rate)
  "Redraw the list, which shows output rates."
  (when (get-buffer harness-ui-sessions--buffer-name)
    (harness-ui-sessions--on-changed)))

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
        (goto-char (harness-ui-sessions--position id))))
    (harness-ui-refresh-sessions (lambda (_) (harness-ui-sessions--redraw)))
    (harness-ui-sessions--fetch-tasks)
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
POSITION, as `harness-sessions' has it."
  (interactive)
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    ;; Every waiting session, whatever the list was filtered by before.
    (with-current-buffer buf (setq harness-ui-sessions--filter "")))
  (harness-sessions t position t))

(defun harness-ui-sessions--id ()
  (or (tabulated-list-get-id) (user-error "No session on this line")))

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

(defun harness-ui-sessions-toggle-blocked ()
  "Show only the sessions waiting for you, or every session again.
Those are the blocked sessions, as the mode line's notifier counts
them; a banner above them says so."
  (interactive)
  (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name)))
    (with-current-buffer buf
      (setq harness-ui-sessions--blocked-only (not harness-ui-sessions--blocked-only)))
    (harness-ui-sessions--redraw)))

(defun harness-ui-sessions-allow ()
  "Answer the permission request the session at point waits on with Allow.
That is the [Allow] of the request's panel and of the task board, and
their y (`harness-ui-pending-answer-first-permission'); its tooltip says
what it covers (`harness-ui-pending-answer-help')."
  (interactive)
  (harness-ui-pending-answer-first-permission (harness-ui-sessions--id) "allow-once"))

(defun harness-ui-sessions-deny ()
  "Answer the permission request the session at point waits on with Deny.
That is the [Deny] of the request's panel and of the task board, and
their n (`harness-ui-pending-answer-first-permission')."
  (interactive)
  (harness-ui-pending-answer-first-permission (harness-ui-sessions--id) "deny-once"))

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
the list at once, before its session says it is no longer blocked."
  (when (get-buffer harness-ui-sessions--buffer-name)
    (harness-ui-sessions--on-changed)))

(defun harness-ui-sessions--init ()
  (add-hook 'harness-ui-sessions-changed-hook #'harness-ui-sessions--on-changed)
  (add-hook 'harness-ui-pending-changed-hook #'harness-ui-sessions--on-pending)
  (add-hook 'harness-ui-rate-functions #'harness-ui-sessions--on-rate)
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
