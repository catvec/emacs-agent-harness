;;; harness-ui-sessions.el --- The session list -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A `tabulated-list-mode' browser over the harness sessions: name, status,
;; model, tokens, cost and age, scoped to the current project or all
;; projects, with child sessions shown under their parent.  Everything is
;; read and changed through ACP.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'harness-core)
(require 'harness-ui)

(defgroup harness-ui-sessions nil
  "Harness session list."
  :group 'harness-ui)

(defcustom harness-ui-sessions-scope 'project
  "Whether the list shows `project' sessions or `all' sessions."
  :type '(choice (const project) (const all)))

(defvar harness-ui-sessions--sessions nil
  "Last session infos fetched from the harness.")

(defvar harness-ui-sessions--tree nil
  "Rows (info . depth) currently displayed.")

(defvar harness-ui-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'harness-ui-sessions-open)
    (define-key map (kbd "f") #'harness-ui-sessions-fork)
    (define-key map (kbd "r") #'harness-ui-sessions-rename)
    (define-key map (kbd "d") #'harness-ui-sessions-delete)
    (define-key map (kbd "n") #'harness-ui-chat-new)
    (define-key map (kbd "s") #'harness-ui-sessions-toggle-scope)
    (define-key map (kbd "g") #'harness-ui-sessions-refresh)
    (define-key map (kbd "?") #'harness-ui-describe)
    map)
  "Keymap for `harness-ui-sessions-mode'.")

(define-derived-mode harness-ui-sessions-mode tabulated-list-mode "Harness-Sessions"
  "Major mode for the harness session list."
  :group 'harness-ui-sessions
  (setq tabulated-list-format
        [("" 3 nil)
         ("Name" 40 t)
         ("Status" 10 t)
         ("Model" 22 t)
         ("Tokens" 12 t)
         ("Cost" 8 t)
         ("Updated" 12 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key '("Updated" . t))
  (add-hook 'tabulated-list-revert-hook #'harness-ui-sessions-refresh nil t)
  (tabulated-list-init-header))

(defun harness-ui-sessions--info-list ()
  "Return the session infos matching the current scope."
  (let ((project (or (project-current)
                     (and (bound-and-true-p default-directory)
                          (project-current nil default-directory)))))
    (harness-deferred-then
     (harness-ui-request "session/list"
                         (append (list :mcpServers [])
                                 (when (and (eq harness-ui-sessions-scope 'project) project)
                                   (list :cwd (file-name-as-directory
                                               (expand-file-name (project-root project)))))))
     (lambda (result)
       (setq harness-ui-sessions--sessions
             (mapcar (lambda (session)
                       (let ((meta (plist-get (plist-get session :_meta) :harness)))
                         (append (list :sessionId (plist-get session :sessionId)
                                       :cwd (plist-get session :cwd)
                                       :title (plist-get session :title)
                                       :updatedAt (plist-get session :updatedAt))
                                 (when meta
                                   (list :status (plist-get meta :status)
                                         :model (plist-get meta :model)
                                         :usage (plist-get meta :usage)
                                         :cost (plist-get meta :cost)
                                         :unread (plist-get meta :unread)
                                         :parentId (plist-get meta :parentId)
                                         :mode (plist-get meta :mode)
                                         :permissionMode (plist-get meta :permissionMode))))))
                     (append (plist-get result :sessions) nil)))
       harness-ui-sessions--sessions))))

(defun harness-ui-sessions--tree-rows (sessions)
  "Order SESSIONS as a tree of (INFO . DEPTH)."
  (let ((by-parent (make-hash-table :test #'equal))
        (ids (make-hash-table :test #'equal))
        (rows nil))
    (dolist (session sessions)
      (puthash (plist-get session :sessionId) t ids))
    (dolist (session sessions)
      (let ((parent (plist-get session :parentId)))
        (when (and parent (gethash parent ids))
          (push session (gethash parent by-parent)))))
    (cl-labels ((emit (session depth)
                  (push (cons session depth) rows)
                  (dolist (child (reverse (gethash (plist-get session :sessionId)
                                                   by-parent)))
                    (emit child (1+ depth)))))
      (dolist (session sessions)
        (let ((parent (plist-get session :parentId)))
          (unless (and parent (gethash parent ids))
            (emit session 0)))))
    (nreverse rows)))

(defun harness-ui-sessions-refresh ()
  "Refresh the session list."
  (interactive)
  (harness-deferred-then
   (harness-ui-sessions--info-list)
   (lambda (_sessions)
     (let* ((buffer (get-buffer "*harness-sessions*")))
       (with-current-buffer (or buffer (current-buffer))
         (setq-local harness-ui-sessions--tree
                     (harness-ui-sessions--tree-rows harness-ui-sessions--sessions))
         (setq tabulated-list-entries
               (mapcar #'harness-ui-sessions--entry harness-ui-sessions--tree))
         (tabulated-list-print t))))))

(defun harness-ui-sessions--entry (row)
  "Build a tabulated entry for ROW, an (INFO . DEPTH) pair."
  (let* ((info (car row))
         (depth (cdr row))
         (id (or (plist-get info :sessionId) ""))
         (title (or (plist-get info :title) "(untitled)"))
         (status (or (plist-get info :status) "idle"))
         (usage (plist-get info :usage))
         (cost (plist-get info :cost))
         (indent (make-string (* 2 depth) ?\s))
         (buttons (concat
                   (propertize "▸" 'keymap (harness-ui-sessions--action-map #'harness-ui-sessions-open)
                               'mouse-face 'highlight)
                   " "
                   (propertize "⎇" 'keymap (harness-ui-sessions--action-map #'harness-ui-sessions-fork)
                               'mouse-face 'highlight)
                   " "
                   (propertize "✎" 'keymap (harness-ui-sessions--action-map #'harness-ui-sessions-rename)
                               'mouse-face 'highlight)
                   " "
                   (propertize "✗" 'keymap (harness-ui-sessions--action-map #'harness-ui-sessions-delete)
                               'mouse-face 'highlight))))
    (list id
          (vector buttons
                  (propertize (concat indent title)
                              'face (pcase status
                                      ("running" 'success)
                                      ("blocked" 'error)
                                      (_ 'default)))
                  (propertize status 'face (pcase status
                                             ("running" 'success)
                                             ("blocked" 'error)
                                             (_ 'shadow)))
                  (or (plist-get info :model) "—")
                  (if usage
                      (format "%d/%d"
                              (or (plist-get usage :input) 0)
                              (or (plist-get usage :output) 0))
                    "—")
                  (if cost (format "$%.3f" (or (plist-get cost :amount) 0)) "—")
                  (or (plist-get info :updatedAt) "—")))))

(defun harness-ui-sessions--action-map (command)
  "Return a keymap invoking COMMAND on the session on this line."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1]
                (lambda ()
                  (interactive)
                  (harness-ui-sessions--call-on-entry command)))
    map))

(defun harness-ui-sessions--session-at-point ()
  "Return the session id of the line at point."
  (tabulated-list-get-id))

(defun harness-ui-sessions--call-on-entry (command)
  "Invoke COMMAND for the entry at point."
  (when (harness-ui-sessions--session-at-point)
    (funcall command)))

;;;###autoload
(defun harness-ui-sessions (&optional scope)
  "Show the session list.
SCOPE may be `project' or `all'."
  (interactive)
  (when scope
    (setq harness-ui-sessions-scope scope))
  (let ((buffer (get-buffer-create "*harness-sessions*")))
    (with-current-buffer buffer
      (harness-ui-sessions-mode))
    (display-buffer buffer)
    (harness-ui-sessions-refresh)
    buffer))

(defun harness-ui-sessions-open ()
  "Open the session at point in a chat buffer."
  (interactive)
  (when-let* ((session-id (harness-ui-sessions--session-at-point)))
    (harness-ui-chat-open session-id)))

(defun harness-ui-sessions-fork ()
  "Fork the session at point."
  (interactive)
  (when-let* ((session-id (harness-ui-sessions--session-at-point)))
    (harness-deferred-then
     (harness-ui-request "_harness/session/fork" (list :sessionId session-id))
     (lambda (result)
       (when-let* ((new-id (plist-get result :sessionId)))
         (message "Forked to %s" new-id)
         (harness-ui-sessions-refresh))))))

(defun harness-ui-sessions-rename ()
  "Rename the session at point."
  (interactive)
  (when-let* ((session-id (harness-ui-sessions--session-at-point)))
    (let ((title (read-string "New name: ")))
      (harness-deferred-then
       (harness-ui-request "_harness/session/rename"
                           (list :sessionId session-id :title title))
       (lambda (_result) (harness-ui-sessions-refresh))))))

(defun harness-ui-sessions-delete ()
  "Delete the session at point, after confirmation."
  (interactive)
  (when-let* ((session-id (harness-ui-sessions--session-at-point)))
    (when (yes-or-no-p (format "Delete session %s? " session-id))
      (harness-deferred-then
       (harness-ui-request "session/delete" (list :sessionId session-id))
       (lambda (_result)
         (harness-ui-sessions-refresh)
         (message "Deleted %s" session-id))))))

(defun harness-ui-sessions-toggle-scope ()
  "Switch between project sessions and all sessions."
  (interactive)
  (setq harness-ui-sessions-scope
        (if (eq harness-ui-sessions-scope 'project) 'all 'project))
  (message "Showing %s sessions" harness-ui-sessions-scope)
  (harness-ui-sessions-refresh))

(harness-module-define 'harness-ui-sessions
  :version harness-version
  :description "Session list with tree, filters and actions."
  :requires '((harness-core "0.1.0")
              (harness-ui "0.1.0")
              (harness-ui-chat "0.1.0"))
  :provides '(harness-ui-sessions)
  :setup (lambda () nil))

(provide 'harness-ui-sessions)
;;; harness-ui-sessions.el ends here
