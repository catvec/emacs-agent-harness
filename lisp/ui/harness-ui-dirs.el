;;; harness-ui-dirs.el --- Directory access of a session  -*- lexical-binding: t; -*-

;;; Commentary:

;; A `tabulated-list-mode' buffer of the directories a session may
;; touch (see `permission/dirs'): its cwd and worktree, the configured
;; `harness-allowed-directories', the directories granted at runtime and
;; the tool output directory.  `a' grants another directory to the
;; session (with a prefix argument: to every session), `k' revokes the
;; grant at point, `g' refreshes.  The list follows grants made from
;; permission prompts elsewhere.

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
    ("config" "configured")
    ("session" "granted to session")
    ("outputs" "tool outputs")
    (s s)))

(defun harness-ui-dirs--entry (e)
  "Return the tabulated list entry for directory plist E."
  (let ((revocable (harness-json-true-p (plist-get e :revocable))))
    (list (plist-get e :dir)
          (vector (propertize (abbreviate-file-name (plist-get e :dir))
                              'face (if revocable 'default 'harness-dim-face))
                  (propertize (harness-ui-dirs--describe (plist-get e :source)) 'face 'harness-dim-face)
                  (if revocable (propertize "k to revoke" 'face 'harness-hint-face) "")))))

(defun harness-ui-dirs--render ()
  "Redraw the current buffer from `harness-ui-dirs--entries'."
  (setq tabulated-list-entries (mapcar #'harness-ui-dirs--entry harness-ui-dirs--entries))
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

(define-derived-mode harness-ui-dirs-mode tabulated-list-mode "Dirs"
  "Major mode listing the directories a harness session may touch.
\\{harness-ui-dirs-mode-map}"
  (setq tabulated-list-format
        (vector (list "Directory" 50 t)
                (list "Source" 20 t)
                (list "" 12 nil)))
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

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

(defun harness-ui-dirs--on-event (event _args)
  "Refresh directory buffers after a grant changed (EVENT from the harness).
A grant may change the configured directories of every session, so all
open directory buffers are refreshed."
  (when (member event '("permission/dir-allowed" "permission/dir-revoked" "config/changed"))
    (harness-ui-dirs--refresh-session nil)))

(defun harness-ui-dirs--init ()
  (add-hook 'harness-ui-event-functions #'harness-ui-dirs--on-event)
  (define-key harness-ui-map (kbd "d") #'harness-directories))

(harness-define-module 'ui-dirs
  :doc "Directory access buffer of a session."
  :requires '(ui)
  :init #'harness-ui-dirs--init)

(provide 'harness-ui-dirs)
;;; harness-ui-dirs.el ends here
