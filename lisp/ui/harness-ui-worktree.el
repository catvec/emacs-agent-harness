;;; harness-ui-worktree.el --- Worktree manager -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A management buffer for git worktrees: list them with their branch and
;; HEAD, open (or create) a session in one, create a new worktree with a
;; fresh branch, and remove worktrees that are no longer needed.  All
;; work goes through ACP (`_harness/worktree/...').

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'harness-core)
(require 'harness-ui)
(require 'harness-ui-chat)

(defgroup harness-ui-worktree nil
  "Harness worktree manager."
  :group 'harness-ui)

(defvar-local harness-ui-worktree--directory nil
  "Repository directory this buffer lists.")

(defvar harness-ui-worktree-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'harness-ui-worktree-open-session)
    (define-key map (kbd "c") #'harness-ui-worktree-create)
    (define-key map (kbd "n") #'harness-ui-worktree-new-session)
    (define-key map (kbd "d") #'harness-ui-worktree-remove)
    (define-key map (kbd "g") #'harness-ui-worktree-refresh)
    (define-key map (kbd "?") #'harness-ui-describe)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `harness-ui-worktree-mode'.")

(define-derived-mode harness-ui-worktree-mode tabulated-list-mode "Harness-Worktrees"
  "Major mode for the worktree manager."
  :group 'harness-ui-worktree
  (setq tabulated-list-format [("Path" 44 t)
                               ("Branch" 28 t)
                               ("HEAD" 9 t)
                               ("Sessions" 8 t)])
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'harness-ui-worktree-refresh nil t))

;;; Data

(defun harness-ui-worktree--session-counts (infos)
  "Map of session cwd -> number of sessions, from INFOS."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (info infos)
      (when-let* ((cwd (plist-get info :cwd)))
        (puthash (file-name-as-directory (expand-file-name cwd))
                 (1+ (or (gethash (file-name-as-directory (expand-file-name cwd)) counts) 0))
                 counts)))
    counts))

(defun harness-ui-worktree--entries (worktrees infos)
  "Tabulated entries for WORKTREES, annotating session counts from INFOS."
  (let ((counts (harness-ui-worktree--session-counts infos))
        (main (car worktrees)))
    (mapcar
     (lambda (worktree)
       (let* ((path (plist-get worktree :path))
              (key (file-name-as-directory (expand-file-name path)))
              (sessions (or (gethash key counts) 0)))
         (list key
               (vector (if (equal path (plist-get main :path))
                           (propertize path 'face 'bold)
                         path)
                       (or (plist-get worktree :branch)
                           (and (plist-get worktree :detached) "(detached)")
                           "-")
                       (substring (or (plist-get worktree :head) "") 0
                                  (min 8 (length (or (plist-get worktree :head) ""))))
                       (number-to-string sessions)))))
     worktrees)))

(defun harness-ui-worktree--worktrees ()
  "Worktrees of the buffer's repository."
  (let ((deferred (harness-ui-request "_harness/worktree/list"
                                      (list :directory harness-ui-worktree--directory))))
    deferred))

(defun harness-ui-worktree-refresh ()
  "Reload the worktree list."
  (interactive)
  (let ((buffer (current-buffer)))
    (harness-deferred-then
     (harness-deferred-all
      (list (harness-ui-worktree--worktrees)
            (harness-ui-request "_harness/session/infos" (list))))
     (lambda (values)
       (let ((worktrees (append (plist-get (nth 0 values) :worktrees) nil))
             (infos (append (nth 1 values) nil)))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq tabulated-list-entries
                   (harness-ui-worktree--entries worktrees infos))
             (let ((inhibit-read-only t))
               (tabulated-list-print t))))))
     (lambda (error)
       (message "Worktrees unavailable: %S" error)))))

(defun harness-ui-worktree--path-at-point ()
  "Worktree path of the entry at point."
  (tabulated-list-get-id))

;;; Commands

(defun harness-ui-worktree-open-session ()
  "Open a session in the worktree at point, creating one if needed."
  (interactive)
  (let* ((path (harness-ui-worktree--path-at-point))
         (deferred (harness-ui-request "_harness/session/infos" (list))))
    (harness-deferred-then
     deferred
     (lambda (infos)
       (let* ((key (file-name-as-directory (expand-file-name path)))
              (existing (seq-find (lambda (info)
                                    (and (plist-get info :cwd)
                                         (equal (file-name-as-directory
                                                 (expand-file-name (plist-get info :cwd)))
                                                key)))
                                  (append infos nil))))
         (if existing
             (harness-ui-chat-open (plist-get existing :sessionId) 'full)
           (harness-ui-worktree--new-session-in path)))))))

(defun harness-ui-worktree-new-session ()
  "Create a session in the worktree at point."
  (interactive)
  (harness-ui-worktree--new-session-in (harness-ui-worktree--path-at-point)))

(defun harness-ui-worktree--new-session-in (path)
  "Create and open a session whose working directory is PATH."
  (harness-deferred-then
   (harness-ui-request "session/new" (list :cwd path :mcpServers []))
   (lambda (result)
     (harness-ui-chat-open (plist-get result :sessionId) 'full))))

(defun harness-ui-worktree-create ()
  "Create a worktree (and a session in it) for a new branch."
  (interactive)
  (let* ((name (read-string "Branch name: "))
         (base (read-string "Base revision (default HEAD): " nil nil "HEAD"))
         (title (read-string (format "Session title (default %s): " name) nil nil name)))
    (when (string-empty-p (string-trim name))
      (user-error "A branch name is needed"))
    (harness-deferred-then
     (harness-ui-request "_harness/worktree/session"
                         (harness-plist-omit-nil
                          (list :repo harness-ui-worktree--directory
                                :name (string-trim name)
                                :base (string-trim base)
                                :title (string-trim title))))
     (lambda (result)
       (harness-ui-worktree-refresh)
       (when-let* ((session-id (plist-get result :sessionId)))
         (harness-ui-chat-open session-id 'full)))
     (lambda (error)
       (message "Could not create the worktree: %s"
                (if (and (listp error) (stringp (cadr error))) (cadr error) error))))))

(defun harness-ui-worktree-remove ()
  "Remove the worktree at point."
  (interactive)
  (let* ((path (harness-ui-worktree--path-at-point))
         (main (save-excursion
                 (goto-char (point-min))
                 (harness-ui-worktree--path-at-point))))
    (when (equal path main)
      (user-error "The main worktree cannot be removed"))
    (when (yes-or-no-p (format "Remove worktree %s? " (abbreviate-file-name path)))
      (harness-deferred-then
       (harness-ui-request "_harness/worktree/remove" (list :path path))
       (lambda (_)
         (message "Removed %s" (abbreviate-file-name path))
         (harness-ui-worktree-refresh))
       (lambda (error)
         (message "Could not remove %s: %s" (abbreviate-file-name path) error))))))

;;;###autoload
(defun harness-ui-worktrees (&optional directory)
  "Open the worktree manager for DIRECTORY (default: the session's repo)."
  (interactive
   (list (or (and (derived-mode-p 'harness-ui-chat-mode)
                  (plist-get harness-ui-chat--info :cwd))
             default-directory)))
  (let ((buffer (get-buffer-create "*harness-worktrees*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-worktree-mode)
        (harness-ui-worktree-mode))
      (setq harness-ui-worktree--directory (file-name-as-directory
                                            (expand-file-name directory)))
      (harness-ui-worktree-refresh))
    (switch-to-buffer buffer)
    buffer))

(defun harness-ui-worktree-setup ()
  "Set up the worktree manager."
  (harness-on 'harness-ui-refresh-functions
              (lambda ()
                (when (get-buffer "*harness-worktrees*")
                  (with-current-buffer "*harness-worktrees*"
                    (harness-ui-worktree-refresh))))
              :module 'harness-ui-worktree))

(defun harness-ui-worktree-teardown ()
  "Tear down the worktree manager."
  (puthash 'harness-ui-refresh-functions
           (seq-remove (lambda (handler)
                         (eq (harness-event-handler-module handler) 'harness-ui-worktree))
                       (gethash 'harness-ui-refresh-functions harness-core--event-handlers))
           harness-core--event-handlers))

(harness-module-define 'harness-ui-worktree
  :version harness-version
  :description "Worktree manager buffer."
  :requires '((harness-core "0.1.0")
              (harness-ui "0.1.0"))
  :provides '(harness-ui-worktree)
  :setup #'harness-ui-worktree-setup
  :teardown #'harness-ui-worktree-teardown)

(provide 'harness-ui-worktree)
;;; harness-ui-worktree.el ends here
