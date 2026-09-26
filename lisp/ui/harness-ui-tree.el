;;; harness-ui-tree.el --- Conversation tree -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A navigable view of the conversation graph: sessions as a tree
;; (forks and subagents under their parents) and, for an expanded session,
;; its transcript entries with the fork point marked.  Indentation and
;; faces do the drawing; every line is a button.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'harness-core)
(require 'harness-ui)

(defgroup harness-ui-tree nil
  "Conversation tree."
  :group 'harness-ui)

(defface harness-ui-tree-session-face
  '((t :inherit bold))
  "Face for session nodes.")

(defface harness-ui-tree-entry-face
  '((t :inherit default))
  "Face for transcript entry nodes.")

(defface harness-ui-tree-fork-face
  '((t :inherit warning))
  "Face marking a fork point.")

(defvar harness-ui-tree--entries (make-hash-table :test #'equal)
  "Session id -> transcript entries.")

(defvar harness-ui-tree--expanded (make-hash-table :test #'equal)
  "Session id -> non-nil when its entries are shown.")

(defvar harness-ui-tree-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "TAB") #'harness-ui-tree-toggle)
    (define-key map (kbd "RET") #'harness-ui-tree-open)
    (define-key map (kbd "g") #'harness-ui-tree-refresh)
    map)
  "Keymap for `harness-ui-tree-mode'.")

(define-derived-mode harness-ui-tree-mode special-mode "Harness-Tree"
  "Major mode for the conversation tree.")

(defun harness-ui-tree--insert-button (label callback &rest props)
  "Insert LABEL as a button calling CALLBACK."
  (let ((start (point)))
    (insert-text-button label
                        'action (lambda (_button) (funcall callback))
                        'follow-link t
                        'mouse-face 'highlight
                        'help-echo (or (plist-get props :help-echo) label))
    (add-face-text-property start (point) (or (plist-get props :face) 'default))
    (add-text-properties start (point) '(read-only t rear-nonsticky t))))

(defun harness-ui-tree--entry-summary (entry)
  "One-line summary of transcript ENTRY."
  (let* ((kind (plist-get entry :sessionUpdate))
         (content (plist-get entry :content))
         (text (cond
                ((and (listp content) (plist-get content :text)) (plist-get content :text))
                ((vectorp content)
                 (mapconcat (lambda (block)
                              (or (plist-get (plist-get block :content) :text)
                                  (plist-get block :text) ""))
                            (append content nil) " "))
                (t ""))))
    (format "%-22s %s"
            (or kind "")
            (truncate-string-to-width (string-replace "\n" " " text) 80 nil nil "…"))))

(defun harness-ui-tree-render ()
  "Render the whole tree in the current buffer."
  (let ((inhibit-read-only t)
        (sessions harness-ui-sessions--sessions))
    (erase-buffer)
    (insert (propertize "Conversation tree\n" 'face 'harness-ui-header-face))
    (dolist (session sessions)
      (let* ((id (plist-get session :sessionId))
             (depth (if (plist-get session :parentId) 1 0))
             (indent (make-string (* 2 depth) ?\s))
             (title (or (plist-get session :title) "(untitled)")))
        (insert (propertize indent 'face 'default))
        (harness-ui-tree--insert-button
         (concat (if (gethash id harness-ui-tree--expanded) "▾ " "▸ ")
                 title
                 (format " [%s]" (or (plist-get session :status) "idle")))
         (lambda () (harness-ui-tree-toggle-session id))
         :face 'harness-ui-tree-session-face
         :help-echo "Show or hide this conversation")
        (insert "\n")
        (when (gethash id harness-ui-tree--expanded)
          (dolist (entry (gethash id harness-ui-tree--entries))
            (insert (propertize (concat indent "    ") 'face 'default))
            (harness-ui-tree--insert-button
             (harness-ui-tree--entry-summary entry)
             (lambda () (harness-ui-chat-open id))
             :face 'harness-ui-tree-entry-face
             :help-echo "Open this session")
            (insert "\n")))))
    (goto-char (point-min))))

(defun harness-ui-tree--fetch-entries (session-id)
  "Fetch and cache SESSION-ID's entries."
  (harness-deferred-then
   (harness-ui-request "_harness/session/entries" (list :sessionId session-id))
   (lambda (result)
     (puthash session-id (append (plist-get result :entries) nil)
              harness-ui-tree--entries)
     (when-let* ((buffer (get-buffer "*harness-tree*")))
       (with-current-buffer buffer
         (harness-ui-tree-render))))))

(defun harness-ui-tree-toggle-session (session-id)
  "Expand or collapse SESSION-ID."
  (if (gethash session-id harness-ui-tree--expanded)
      (progn
        (remhash session-id harness-ui-tree--expanded)
        (harness-ui-tree-render))
    (puthash session-id t harness-ui-tree--expanded)
    (if (gethash session-id harness-ui-tree--entries)
        (harness-ui-tree-render)
      (harness-ui-tree--fetch-entries session-id))))

(defun harness-ui-tree-toggle ()
  "Toggle the session on this line."
  (interactive)
  (when-let* ((session-id (get-text-property (point) 'harness-ui-tree-session)))
    (harness-ui-tree-toggle-session session-id)))

(defun harness-ui-tree-open ()
  "Open the session on this line."
  (interactive)
  (when-let* ((session-id (get-text-property (point) 'harness-ui-tree-session)))
    (harness-ui-chat-open session-id)))

(defun harness-ui-tree-refresh ()
  "Refresh the tree from the session list."
  (interactive)
  (harness-deferred-then
   (harness-ui-request "session/list" (list :mcpServers []))
   (lambda (result)
     (setq harness-ui-sessions--sessions
           (mapcar (lambda (session)
                     (let ((meta (plist-get (plist-get session :_meta) :harness)))
                       (append (list :sessionId (plist-get session :sessionId)
                                     :title (plist-get session :title)
                                     :cwd (plist-get session :cwd))
                               (when meta
                                 (list :status (plist-get meta :status)
                                       :parentId (plist-get meta :parentId))))))
                   (append (plist-get result :sessions) nil)))
     (harness-ui-tree-render))))

;;;###autoload
(defun harness-ui-tree ()
  "Show the conversation tree."
  (interactive)
  (let ((buffer (get-buffer-create "*harness-tree*")))
    (with-current-buffer buffer
      (harness-ui-tree-mode)
      (harness-ui-tree-refresh))
    (display-buffer buffer)
    buffer))

(harness-module-define 'harness-ui-tree
  :version harness-version
  :description "Conversation tree over sessions and transcripts."
  :requires '((harness-core "0.1.0")
              (harness-ui "0.1.0")
              (harness-ui-chat "0.1.0")
              (harness-ui-sessions "0.1.0"))
  :provides '(harness-ui-tree)
  :setup (lambda () nil))

(provide 'harness-ui-tree)
;;; harness-ui-tree.el ends here
