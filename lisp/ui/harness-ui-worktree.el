;;; harness-ui-worktree.el --- Git worktrees  -*- lexical-binding: t; -*-

;;; Commentary:

;; A `tabulated-list-mode' buffer of the git worktrees of the current
;; project: path, branch, head, flags (main, locked, detached,
;; prunable), the working-copy status (clean or dirty, ahead/behind its
;; upstream) fetched per row after the list is shown, and the sessions
;; that live in each worktree.
;;
;; Keys: n create a worktree, d remove (offers --force when git
;; refuses), p prune, s start a session in the worktree at point, f fork
;; the current session into a fresh worktree, m ask for the worktree's
;; session to be merged back into its parent session (the merge queue
;; shows in the mode line), RET open the directory in Dired, g refresh.
;; The mode line carries a clickable segment for every command.
;;
;; Everything goes through ACP (`_harness/worktree/*', `_harness/merge/*',
;; `session/new', `_harness/session/fork').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defgroup harness-ui-worktree nil
  "The worktree list." :group 'harness-ui)

(defcustom harness-ui-worktree-buffer-name "*harness worktrees*"
  "Name of the worktree list buffer."
  :type 'string :group 'harness-ui-worktree)

(defcustom harness-ui-worktree-branch-prefix "harness/"
  "Prefix proposed for the branch of a new worktree."
  :type 'string :group 'harness-ui-worktree)

(defface harness-worktree-main-face '((t :inherit bold))
  "The main worktree." :group 'harness-ui-worktree)
(defface harness-worktree-dirty-face '((t :inherit warning))
  "Worktrees with uncommitted changes." :group 'harness-ui-worktree)
(defface harness-worktree-clean-face '((t :inherit success))
  "Clean worktrees." :group 'harness-ui-worktree)

(defvar-local harness-ui-worktree--root nil "Main repository root shown.")
(defvar-local harness-ui-worktree--worktrees nil "Last worktree list received.")
(defvar-local harness-ui-worktree--status (make-hash-table :test 'equal) "Path -> status plist or `error'.")
(defvar-local harness-ui-worktree--loading nil "Non-nil while the list is being fetched.")
(defvar-local harness-ui-worktree--error nil "Last error message.")
(defvar-local harness-ui-worktree--queue nil "(PARENT-SID . ITEMS) of the merge queue last shown.")

;;;; Helpers

(defun harness-ui-worktree--dir (path)
  "Normalise PATH for comparisons."
  (file-name-as-directory (expand-file-name path)))

(defun harness-ui-worktree--same-p (a b)
  "Non-nil when directories A and B are the same place."
  (and a b (or (string= (harness-ui-worktree--dir a) (harness-ui-worktree--dir b))
               (ignore-errors (string= (file-truename (harness-ui-worktree--dir a))
                                       (file-truename (harness-ui-worktree--dir b)))))))

(defun harness-ui-worktree--sessions-in (path)
  "Return cached sessions living in PATH: by `:worktree', else by `:cwd'."
  (harness-ui-sessions (lambda (s)
                         (let ((wt (plist-get s :worktree)))
                           (if wt (harness-ui-worktree--same-p wt path)
                             (harness-ui-worktree--same-p (plist-get s :cwd) path))))))

(defun harness-ui-worktree--sessions-label (path)
  "Return a short description of the sessions using PATH."
  (let ((sessions (harness-ui-worktree--sessions-in path)))
    (if (null sessions) ""
      (concat
       (mapconcat (lambda (s)
                    (concat (harness-ui-status-icon (plist-get s :status)) " "
                            (harness-truncate-end (or (plist-get s :name)
                                                      (format "unnamed %s" (substring (plist-get s :id) 0 6)))
                                                  22)))
                  (seq-take sessions 3) "  ")
       (if (> (length sessions) 3)
           (propertize (format "  +%d more" (- (length sessions) 3)) 'face 'harness-dim-face)
         "")))))

(defun harness-ui-worktree--flags (wt)
  "Return the flags string of worktree WT."
  (string-join (delq nil (list (and (harness-json-true-p (plist-get wt :main)) (propertize "main" 'face 'harness-worktree-main-face))
                               (and (harness-json-true-p (plist-get wt :bare)) "bare")
                               (and (harness-json-true-p (plist-get wt :locked)) (propertize "locked" 'face 'warning))
                               (and (harness-json-true-p (plist-get wt :detached)) (propertize "detached" 'face 'harness-dim-face))
                               (and (harness-json-true-p (plist-get wt :prunable)) (propertize "prunable" 'face 'error))))
               " "))

(defun harness-ui-worktree--status-label (path)
  "Return the status column for PATH from the cache."
  (let ((st (gethash (harness-ui-worktree--dir path) harness-ui-worktree--status)))
    (cond
     ((null st) (propertize "…" 'face 'harness-dim-face 'help-echo "Fetching git status"))
     ((eq st 'error) (propertize "?" 'face 'harness-dim-face 'help-echo "git status failed"))
     (t (let ((dirty (harness-json-true-p (plist-get st :dirty)))
              (ahead (or (plist-get st :ahead) 0))
              (behind (or (plist-get st :behind) 0)))
          (concat (if dirty (propertize "dirty" 'face 'harness-worktree-dirty-face)
                    (propertize "clean" 'face 'harness-worktree-clean-face))
                  (if (> ahead 0) (format " ↑%d" ahead) "")
                  (if (> behind 0) (format " ↓%d" behind) "")))))))

(defun harness-ui-worktree--path-label (path)
  "Return PATH shortened for the list."
  (let ((rel (and harness-ui-worktree--root
                  (file-relative-name (directory-file-name path) (file-name-directory (directory-file-name harness-ui-worktree--root))))))
    (harness-truncate-middle (if (and rel (not (string-prefix-p ".." rel))) rel
                               (abbreviate-file-name (directory-file-name path)))
                             38)))

(defun harness-ui-worktree--entry (wt)
  "Return the `tabulated-list' entry of worktree WT."
  (let ((path (plist-get wt :path)))
    (list path
          (vector (harness-ui-worktree--path-label path)
                  (or (plist-get wt :branch) (propertize "(detached)" 'face 'harness-dim-face))
                  (propertize (substring (or (plist-get wt :head) "") 0 (min 8 (length (or (plist-get wt :head) ""))))
                              'face 'harness-dim-face)
                  (harness-ui-worktree--flags wt)
                  (harness-ui-worktree--status-label path)
                  (harness-ui-worktree--sessions-label path)))))

;;;; Rendering

(defun harness-ui-worktree--segment (label command help)
  "Return a mode-line segment LABEL running COMMAND with HELP."
  (propertize (format " %s" label)
              'mouse-face 'mode-line-highlight 'help-echo help
              'local-map (harness-ui-mouse-keymap command)))

(defun harness-ui-worktree--mode-line ()
  "Return the `mode-line-process' value with actions and the merge queue."
  (list
   (harness-ui-worktree--segment "[n new]" #'harness-ui-worktree-create "Create a worktree (n)")
   (harness-ui-worktree--segment "[d remove]" #'harness-ui-worktree-remove "Remove the worktree at point (d)")
   (harness-ui-worktree--segment "[p prune]" #'harness-ui-worktree-prune "Prune stale worktree records (p)")
   (harness-ui-worktree--segment "[s session]" #'harness-ui-worktree-new-session "Start a session in the worktree at point (s)")
   (harness-ui-worktree--segment "[f fork]" #'harness-ui-worktree-fork-session "Fork the current session into a new worktree (f)")
   (harness-ui-worktree--segment "[m merge]" #'harness-ui-worktree-merge "Queue the worktree's session for a merge into its parent (m)")
   (harness-ui-worktree--segment "[g]" #'harness-ui-worktree-refresh "Refresh (g)")
   (cond (harness-ui-worktree--loading (propertize " loading…" 'face 'harness-dim-face))
         (harness-ui-worktree--error (propertize (format " error: %s" harness-ui-worktree--error) 'face 'error))
         (t ""))
   (if-let* ((q harness-ui-worktree--queue))
       (propertize (format " merge queue → %s: %s"
                           (harness-truncate-end (or (plist-get (harness-ui-session (car q)) :name) (substring (car q) 0 6)) 16)
                           (if (cdr q)
                               (mapconcat (lambda (i)
                                            (format "%s %s" (plist-get i :position)
                                                    (or (plist-get (harness-ui-session (plist-get i :child)) :name)
                                                        (substring (or (plist-get i :child) "??????") 0 6))))
                                          (cdr q) ", ")
                             "empty"))
                   'face 'harness-queue-face
                   'help-echo "Sessions waiting to merge into the parent, in order")
     "")))

(defun harness-ui-worktree--refresh-entries ()
  "Rebuild `tabulated-list-entries' from the cached worktrees."
  (setq tabulated-list-entries (mapcar #'harness-ui-worktree--entry harness-ui-worktree--worktrees))
  (setq mode-line-process (harness-ui-worktree--mode-line))
  (setq header-line-format nil)
  (tabulated-list-init-header))

(defun harness-ui-worktree--redraw ()
  "Print the list again, keeping point on the same worktree."
  (harness-ui-worktree--refresh-entries)
  (tabulated-list-print t t)
  (when (and (null harness-ui-worktree--worktrees) (= (point-min) (point-max)))
    (let ((inhibit-read-only t))
      (insert (propertize (cond (harness-ui-worktree--loading "Listing worktrees…")
                                (harness-ui-worktree--error (format "Could not list worktrees: %s" harness-ui-worktree--error))
                                (t "No worktrees."))
                          'face (if harness-ui-worktree--error 'error 'harness-dim-face))
              "\n"))))

(defun harness-ui-worktree--fetch-status (buffer path)
  "Fetch the git status of PATH and update its row in BUFFER."
  (harness-ui-call "_harness/worktree/status" (list :path path)
                   (lambda (st)
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (puthash (harness-ui-worktree--dir path) st harness-ui-worktree--status)
                         (harness-ui-worktree--redraw))))
                   (lambda (_e)
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (puthash (harness-ui-worktree--dir path) 'error harness-ui-worktree--status)
                         (harness-ui-worktree--redraw))))))

(defun harness-ui-worktree--load (buffer)
  "Fetch the worktree list for BUFFER's root, then each row's status."
  (with-current-buffer buffer
    (setq harness-ui-worktree--loading t harness-ui-worktree--error nil)
    (harness-ui-worktree--redraw)
    (let ((root harness-ui-worktree--root))
      (harness-ui-call
       "_harness/worktree/list" (list :root root)
       (lambda (worktrees)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq harness-ui-worktree--worktrees worktrees
                   harness-ui-worktree--loading nil)
             (clrhash harness-ui-worktree--status)
             (harness-ui-worktree--redraw)
             (dolist (wt worktrees)
               (unless (harness-json-true-p (plist-get wt :bare))
                 (harness-ui-worktree--fetch-status buffer (plist-get wt :path)))))))
       (lambda (e)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq harness-ui-worktree--loading nil
                   harness-ui-worktree--error (harness-error-message e))
             (harness-ui-worktree--redraw))))))))

;;;; Mode

(defvar harness-ui-worktree-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'harness-ui-worktree-dired)
    (define-key map [mouse-1] #'harness-ui-worktree-mouse-dired)
    (define-key map (kbd "n") #'harness-ui-worktree-create)
    (define-key map (kbd "d") #'harness-ui-worktree-remove)
    (define-key map (kbd "p") #'harness-ui-worktree-prune)
    (define-key map (kbd "s") #'harness-ui-worktree-new-session)
    (define-key map (kbd "f") #'harness-ui-worktree-fork-session)
    (define-key map (kbd "m") #'harness-ui-worktree-merge)
    (define-key map (kbd "g") #'harness-ui-worktree-refresh)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-worktree-mode'.")

(define-derived-mode harness-ui-worktree-mode tabulated-list-mode "Worktrees"
  "Major mode listing the git worktrees of a repository."
  (setq tabulated-list-format
        (vector (list "Path" 40 t)
                (list "Branch" 24 t)
                (list "Head" 9 nil)
                (list "Flags" 14 nil)
                (list "Status" 14 nil)
                (list "Sessions" 40 nil)))
  (setq tabulated-list-padding 1)
  (setq harness-ui-worktree--status (make-hash-table :test 'equal))
  (add-hook 'tabulated-list-revert-hook #'harness-ui-worktree--refresh-entries nil t)
  (tabulated-list-init-header))

;; The list's keys in the harness menu, behind `.'.
(put 'harness-ui-worktree-mode 'harness-menu-group
     '("Worktrees"
       ["Worktree at point"
        (". RET" "Open in Dired" harness-ui-worktree-dired)
        (". s" "New session in it" harness-ui-worktree-new-session)
        (". m" "Merge its session" harness-ui-worktree-merge)
        (". d" "Remove" harness-ui-worktree-remove)]
       ["Repository"
        (". n" "New worktree" harness-ui-worktree-create)
        (". f" "Fork a session into one" harness-ui-worktree-fork-session)
        (". p" "Prune stale records" harness-ui-worktree-prune)
        (". g" "Refresh" harness-ui-worktree-refresh)]))

;;;; Commands

;;;###autoload
(defun harness-worktrees (&optional root)
  "List the git worktrees of the repository at ROOT (default: this project)."
  (interactive)
  (let ((start (expand-file-name (or root (harness-ui--default-directory))))
        (buf (get-buffer-create harness-ui-worktree-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-worktree-mode) (harness-ui-worktree-mode))
      (setq harness-ui-worktree--root (harness-ui-worktree--dir start)
            harness-ui-worktree--loading t)
      (harness-ui-worktree--redraw))
    (harness-ui-display-view buf)
    ;; Resolve to the main repository root so a worktree directory lists its siblings.
    (harness-ui-call "_harness/worktree/root-of" (list :path start)
                     (lambda (main)
                       (with-current-buffer buf (setq harness-ui-worktree--root (harness-ui-worktree--dir main)))
                       (harness-ui-worktree--load buf))
                     (lambda (_e) (harness-ui-worktree--load buf)))))

(defun harness-ui-worktree--path ()
  "Return the worktree path on the current line."
  (or (tabulated-list-get-id) (user-error "No worktree on this line")))

(defun harness-ui-worktree--worktree ()
  "Return the worktree plist on the current line."
  (let ((path (harness-ui-worktree--path)))
    (cl-find path harness-ui-worktree--worktrees :key (lambda (wt) (plist-get wt :path)) :test #'equal)))

(defun harness-ui-worktree-refresh ()
  "Reload the list."
  (interactive)
  (harness-ui-worktree--load (current-buffer)))

(defun harness-ui-worktree-dired ()
  "Open the worktree at point in Dired."
  (interactive)
  (dired (harness-ui-worktree--path)))

(defun harness-ui-worktree-mouse-dired (event)
  "Open the worktree clicked in EVENT in Dired."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-worktree-dired))

(defun harness-ui-worktree--read-branch ()
  "Read a branch name for a new worktree with a generated default."
  (let ((default (concat harness-ui-worktree-branch-prefix (harness-short-id 6))))
    (let ((name (read-string (format "Branch (default %s): " default) nil nil default)))
      (if (string-empty-p name) default name))))

(defun harness-ui-worktree--create (root branch base callback)
  "Create a worktree of ROOT on BRANCH from BASE, then call CALLBACK with it."
  (message "Creating worktree %s…" branch)
  (harness-ui-call "_harness/worktree/create"
                   (append (list :root root :branch branch) (and base (list :base base)))
                   callback))

(defun harness-ui-worktree-create (branch &optional base)
  "Create a worktree on BRANCH (from BASE with a prefix argument)."
  (interactive (list (harness-ui-worktree--read-branch)
                     (and current-prefix-arg (read-string "Base (commit or branch): " nil nil "HEAD"))))
  (let ((buf (current-buffer)))
    (harness-ui-worktree--create harness-ui-worktree--root branch base
                                 (lambda (wt)
                                   (message "Worktree %s at %s" (plist-get wt :branch) (abbreviate-file-name (plist-get wt :path)))
                                   (when (buffer-live-p buf) (harness-ui-worktree--load buf))))))

(defun harness-ui-worktree-remove (&optional force)
  "Remove the worktree at point; with FORCE (prefix) discard local changes.
When git refuses because of local changes, offer to force."
  (interactive "P")
  (let* ((wt (harness-ui-worktree--worktree))
         (path (harness-ui-worktree--path))
         (buf (current-buffer))
         (root harness-ui-worktree--root))
    (when (harness-json-true-p (plist-get wt :main))
      (user-error "The main worktree cannot be removed"))
    (when (yes-or-no-p (format "Remove worktree %s%s? " (abbreviate-file-name path) (if force " (force)" "")))
      (cl-labels ((run (force)
                    (harness-ui-call "_harness/worktree/remove"
                                     (append (list :root root :path path) (and force (list :force t)))
                                     (lambda (_)
                                       (message "Removed %s" (abbreviate-file-name path))
                                       (when (buffer-live-p buf) (harness-ui-worktree--load buf)))
                                     (lambda (e)
                                       (if (and (not force)
                                                (y-or-n-p (format "git: %s.  Remove with --force? " (harness-error-message e))))
                                           (run t)
                                         (message "Remove failed: %s" (harness-error-message e)))))))
        (run force)))))

(defun harness-ui-worktree-prune ()
  "Prune stale worktree records."
  (interactive)
  (let ((buf (current-buffer)))
    (harness-ui-call "_harness/worktree/prune" (list :root harness-ui-worktree--root)
                     (lambda (lines)
                       (message "%s" (if lines (string-join lines "; ") "Nothing to prune"))
                       (when (buffer-live-p buf) (harness-ui-worktree--load buf))))))

(defun harness-ui-worktree-new-session ()
  "Start a new session whose working directory is the worktree at point."
  (interactive)
  (let ((path (harness-ui-worktree--path))
        (buf (current-buffer))
        (open (harness-ui-session-opener)))
    (harness-ui-call "session/new" (list :cwd path :_harness (list :worktree path))
                     (lambda (result)
                       (let ((sid (plist-get result :sessionId)))
                         (harness-ui-refresh-sessions
                          (lambda (_)
                            (when (buffer-live-p buf) (with-current-buffer buf (harness-ui-worktree--redraw)))
                            (if harness-ui-open-session-function
                                (funcall open sid)
                              (message "Session %s started in %s" (substring sid 0 8) (abbreviate-file-name path))))))))))

(defun harness-ui-worktree-fork-session (session-id branch)
  "Fork SESSION-ID into a new worktree on BRANCH."
  (interactive (list (harness-ui-current-session-id) (harness-ui-worktree--read-branch)))
  (let ((buf (current-buffer))
        (root harness-ui-worktree--root)
        ;; From the worktree list the fork replaces it; from a chat it opens beside it.
        (open (harness-ui-session-opener (unless (derived-mode-p 'harness-ui-worktree-mode)
                                           harness-ui-default-position))))
    (harness-ui-worktree--create
     root branch nil
     (lambda (wt)
       (let ((path (plist-get wt :path)))
         (harness-ui-call "_harness/session/fork"
                          (list :id session-id :kind "fork" :cwd path :worktree path :name branch)
                          (lambda (child)
                            (harness-ui-refresh-sessions
                             (lambda (_)
                               (when (buffer-live-p buf) (harness-ui-worktree--load buf))
                               (if harness-ui-open-session-function
                                   (funcall open (plist-get child :id))
                                 (message "Forked into %s" (abbreviate-file-name path))))))))))))

(defun harness-ui-worktree--show-queue (parent-id)
  "Fetch the merge queue of PARENT-ID and show it in the mode line."
  (let ((buf (current-buffer)))
    (harness-ui-call "_harness/merge/queue" (list :parent-id parent-id)
                     (lambda (items)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-worktree--queue (cons parent-id items))
                           (setq mode-line-process (harness-ui-worktree--mode-line))
                           (force-mode-line-update)))))))

(defun harness-ui-worktree-merge ()
  "Queue the session of the worktree at point for a merge into its parent."
  (interactive)
  (let* ((path (harness-ui-worktree--path))
         (sessions (cl-remove-if-not (lambda (s) (plist-get s :parent-id)) (harness-ui-worktree--sessions-in path)))
         (session (pcase (length sessions)
                    (0 (user-error "No forked session lives in %s" (abbreviate-file-name path)))
                    (1 (car sessions))
                    (_ (harness-ui-read-session "Merge which session: "
                                                (lambda (s) (memq s sessions))))))
         (child (plist-get session :id))
         (parent (plist-get session :parent-id)))
    (harness-ui-call "_harness/merge/enqueue" (list :child-id child :parent-id parent)
                     (lambda (position)
                       (message "Queued %s for merging into %s (position %s)"
                                (or (plist-get session :name) (substring child 0 8))
                                (or (plist-get (harness-ui-session parent) :name) (substring parent 0 8))
                                position)
                       (harness-ui-worktree--show-queue parent)))))

;;;; Live refresh

(defun harness-ui-worktree--buffer ()
  "Return the live worktree buffer, or nil."
  (let ((b (get-buffer harness-ui-worktree-buffer-name)))
    (and b (with-current-buffer b (derived-mode-p 'harness-ui-worktree-mode)) b)))

(defun harness-ui-worktree--on-event (event args)
  "Reload after a worktree or merge EVENT with ARGS."
  (when-let* ((buf (harness-ui-worktree--buffer)))
    (cond
     ((string-prefix-p "worktree/" event)
      (harness-debounce 'harness-ui-worktree-reload 0.3 (lambda () (when (buffer-live-p buf) (harness-ui-worktree--load buf)))))
     ((string-prefix-p "merge/" event)
      (with-current-buffer buf
        (when-let* ((parent (or (and harness-ui-worktree--queue (car harness-ui-worktree--queue))
                                (nth 1 args))))
          (harness-ui-worktree--show-queue parent))
        (harness-debounce 'harness-ui-worktree-reload 0.3 (lambda () (when (buffer-live-p buf) (harness-ui-worktree--load buf)))))))))

(defun harness-ui-worktree--on-sessions-changed ()
  "Redraw the sessions column when the session cache changes."
  (when-let* ((buf (harness-ui-worktree--buffer)))
    (harness-debounce 'harness-ui-worktree-sessions 0.2
                      (lambda () (when (buffer-live-p buf) (with-current-buffer buf (harness-ui-worktree--redraw)))))))

(defun harness-ui-worktree--redraw-all ()
  "Rebuild the buffer after a reload or reconnect."
  (when-let* ((buf (harness-ui-worktree--buffer)))
    (harness-ui-worktree--load buf)))

;;;; Module

(defun harness-ui-worktree--init ()
  "Wire the worktree list into the UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-worktree--on-event)
  (add-hook 'harness-ui-sessions-changed-hook #'harness-ui-worktree--on-sessions-changed)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-worktree--redraw-all)
  (define-key harness-ui-map (kbd "w") #'harness-worktrees))

(harness-define-module 'ui-worktree
  :doc "Git worktree list with create, remove, prune, sessions and merges."
  :requires '(ui)
  :init #'harness-ui-worktree--init)

(provide 'harness-ui-worktree)
;;; harness-ui-worktree.el ends here
