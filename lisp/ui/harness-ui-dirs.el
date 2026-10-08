;;; harness-ui-dirs.el --- Directory access of a session  -*- lexical-binding: t; -*-

;;; Commentary:

;; A `tabulated-list-mode' buffer of the directories a session may
;; touch (see `permission/dirs'): its cwd and worktree, its own
;; temporary directory, the configured `harness-allowed-directories',
;; the directories granted at runtime (to the session, or until its turn
;; ends) and the tool output directory.  `a' grants another directory
;; to the session (with a prefix argument: to every session), `k'
;; revokes the grant at point, `m' moves the session to another working
;; directory (`harness-move-session'), `g' refreshes.  The list follows
;; grants made from permission prompts elsewhere, and moves.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar-local harness-ui-dirs--entries nil
  "The (:dir :source :revocable) plists last fetched for this buffer.")

(defun harness-ui-dirs--buffer-name (sid)
  "Return the name of the directory buffer for session SID."
  (format "*harness dirs: %s*"
          (if-let* ((s (harness-ui-session sid))) (harness-ui-session-label s) (substring sid 0 8))))

(defun harness-ui-dirs--describe (source)
  "Return a human label for directory SOURCE."
  (pcase (format "%s" source)
    ("cwd" "working directory")
    ("worktree" "worktree")
    ("tmp" "temporary directory")
    ("config" "configured")
    ("session" "granted to session")
    ("turn" "granted for this turn")
    ("outputs" "tool outputs")
    (s s)))

(defun harness-ui-dirs--entry (e)
  "Return the tabulated list entry for directory plist E."
  (let ((revocable (harness-json-true-p (plist-get e :revocable))))
    (list (plist-get e :dir)
          (vector (propertize (abbreviate-file-name (plist-get e :dir))
                              'face (if revocable 'default 'harness-dim-face))
                  (propertize (harness-ui-dirs--describe (plist-get e :source)) 'face 'harness-dim-face)
                  (cond (revocable (propertize "k to revoke" 'face 'harness-hint-face))
                        ((equal (format "%s" (plist-get e :source)) "cwd")
                         (propertize "m to move" 'face 'harness-hint-face))
                        (t ""))))))

(defconst harness-ui-dirs--min-width 50
  "Narrowest the Directory column gets.")

(defun harness-ui-dirs--fit-columns ()
  "Make the Directory column as wide as its longest entry.
A session's own temporary directory alone is longer than most paths, so
a fixed width would push its source out of line with the others."
  (let ((width (apply #'max harness-ui-dirs--min-width
                      (mapcar (lambda (e) (string-width (aref (cadr e) 0))) tabulated-list-entries))))
    (unless (eql width (cadr (aref tabulated-list-format 0)))
      (setq tabulated-list-format (copy-sequence tabulated-list-format))
      (aset tabulated-list-format 0 (list "Directory" width t))
      (tabulated-list-init-header))))

(defun harness-ui-dirs--render ()
  "Redraw the current buffer from `harness-ui-dirs--entries'."
  (setq tabulated-list-entries (mapcar #'harness-ui-dirs--entry harness-ui-dirs--entries))
  (harness-ui-dirs--fit-columns)
  (tabulated-list-print t))

(defun harness-ui-dirs--refresh (&optional buffer)
  "Fetch the directories of BUFFER's session and redraw.
BUFFER defaults to the current buffer."
  (let ((buf (or buffer (current-buffer))))
    (with-current-buffer buf
      (harness-ui-call "_harness/permission/dirs" (list :session-id harness-ui-session-id)
                       (lambda (entries)
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (setq harness-ui-dirs--entries entries)
                             (harness-ui-dirs--render))))))))

(defvar harness-ui-dirs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'harness-ui-dirs-add)
    (define-key map (kbd "+") #'harness-ui-dirs-add)
    (define-key map (kbd "k") #'harness-ui-dirs-revoke)
    (define-key map (kbd "d") #'harness-ui-dirs-revoke)
    (define-key map (kbd "g") #'harness-ui-dirs-reload)
    (define-key map (kbd "RET") #'harness-ui-dirs-visit)
    map)
  "Keymap of `harness-ui-dirs-mode'.")

;; At top level, not in the `defvar', so a reload binds it in a running
;; Emacs too.
(define-key harness-ui-dirs-mode-map (kbd "m") #'harness-ui-dirs-move)

(define-derived-mode harness-ui-dirs-mode tabulated-list-mode "Dirs"
  "Major mode listing the directories a harness session may touch.
\\{harness-ui-dirs-mode-map}"
  (setq tabulated-list-format
        (vector (list "Directory" harness-ui-dirs--min-width t)
                (list "Source" 22 t)
                (list "" 12 nil)))
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

;; The list's keys in the harness menu, behind `.'.
(put 'harness-ui-dirs-mode 'harness-menu-group
     '("Directory access"
       ["Directories"
        (". a" "Allow a directory" harness-ui-dirs-add)
        (". k" "Revoke at point" harness-ui-dirs-revoke)
        (". m" "Move the session to another directory" harness-ui-dirs-move)
        (". RET" "Open in Dired" harness-ui-dirs-visit)
        (". g" "Reload" harness-ui-dirs-reload)]))

;;;###autoload
(defun harness-directories (&optional session-id)
  "Show and manage the directories SESSION-ID may access."
  (interactive)
  (let* ((sid (or session-id (harness-ui-current-session-id)))
         (buf (get-buffer-create (harness-ui-dirs--buffer-name sid))))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-dirs-mode) (harness-ui-dirs-mode))
      (setq harness-ui-session-id sid)
      (harness-ui-dirs--refresh))
    (pop-to-buffer buf)))

(defun harness-ui-dirs--session-dir ()
  "Return the directory to start reading a new grant from.
For a remote session nil, so that no TRAMP connection is opened."
  (let ((s (harness-ui-session harness-ui-session-id)))
    (unless (plist-get s :host) (plist-get s :cwd))))

(defun harness-ui-dirs-add (dir &optional always)
  "Grant the session of this buffer access to DIR.
With a prefix argument ALWAYS, add DIR to `harness-allowed-directories'
so every session may access it."
  (interactive
   (let* ((always current-prefix-arg)
          (prompt (if always "Always allow directory: " "Allow directory for this session: "))
          (start (harness-ui-dirs--session-dir)))
     (list (if start (read-directory-name prompt start nil t) (read-string prompt))
           always)))
  (let ((sid (or harness-ui-session-id (harness-ui-current-session-id))))
    (harness-ui-call "_harness/permission/allow-dir"
                     (append (list :session-id sid :dir dir) (and always (list :scope "always")))
                     (lambda (_)
                       (message "Allowed %s%s" (abbreviate-file-name dir) (if always " for every session" ""))
                       (harness-ui-dirs--refresh-session sid)))))

(defun harness-ui-dirs-revoke ()
  "Revoke the directory grant at point."
  (interactive)
  (let* ((dir (or (tabulated-list-get-id) (user-error "No directory at point")))
         (e (cl-find dir harness-ui-dirs--entries :key (lambda (x) (plist-get x :dir)) :test #'equal))
         (sid harness-ui-session-id))
    (unless (harness-json-true-p (plist-get e :revocable))
      (user-error "%s comes from the %s and cannot be revoked here"
                  (abbreviate-file-name dir) (harness-ui-dirs--describe (plist-get e :source))))
    (when (y-or-n-p (format "Revoke access to %s%s? " (abbreviate-file-name dir)
                            (if (equal (format "%s" (plist-get e :source)) "config") " for every session" "")))
      (harness-ui-call "_harness/permission/revoke-dir" (list :session-id sid :dir dir)
                       (lambda (_)
                         (message "Revoked %s" (abbreviate-file-name dir))
                         (harness-ui-dirs--refresh-session sid))))))

(defun harness-ui-dirs-move (directory &optional keep-old)
  "Move the session of this buffer to the working directory DIRECTORY.
With a prefix argument KEEP-OLD its old working directory stays
allowed to it.  See `harness-move-session'."
  (interactive (list (harness-ui-read-move-directory (harness-ui-session harness-ui-session-id))
                     current-prefix-arg))
  (harness-move-session directory harness-ui-session-id keep-old))

(defun harness-ui-dirs-reload ()
  "Fetch the directories again."
  (interactive)
  (harness-ui-dirs--refresh))

(defun harness-ui-dirs-visit ()
  "Open the directory at point in Dired."
  (interactive)
  (when-let* ((dir (tabulated-list-get-id)))
    (dired-other-window dir)))

(defun harness-ui-dirs--refresh-session (sid)
  "Refresh the directory buffer of session SID, when one exists.
A config grant reaches every session, so with SID nil refresh them all."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'harness-ui-dirs-mode)
                 (or (null sid) (equal harness-ui-session-id sid)))
        (harness-ui-dirs--refresh buf)))))

(defun harness-ui-dirs--on-event (event args)
  "Refresh directory buffers after a grant changed (EVENT from the harness).
A grant may change the configured directories of every session, so all
open directory buffers are refreshed.  A session that moved (ARGS is
\(ID OLD-CWD NEW-CWD)) has another working directory: its buffer is."
  (cond
   ((member event '("permission/dir-allowed" "permission/dir-revoked" "config/changed"))
    (harness-ui-dirs--refresh-session nil))
   ((equal event "session/moved")
    (harness-ui-dirs--refresh-session (car args)))))

(defun harness-ui-dirs--init ()
  "Wire the directory buffers into the UI.
Granting or revoking a directory, or changing the config, refreshes
them, and a session that moves refreshes its own; d in
`harness-ui-map' runs `harness-directories'."
  (add-hook 'harness-ui-event-functions #'harness-ui-dirs--on-event)
  (define-key harness-ui-map (kbd "d") #'harness-directories))

(harness-define-module 'ui-dirs
  :doc "Directory access buffer of a session."
  :requires '(ui)
  :init #'harness-ui-dirs--init)

(provide 'harness-ui-dirs)
;;; harness-ui-dirs.el ends here
