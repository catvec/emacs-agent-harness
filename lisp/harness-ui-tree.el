;;; harness-ui-tree.el --- Message tree view -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;; URL: https://github.com/noahhuppert/emacs-agent-harness

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The tree view is `outline-mode' doing what it is for: every message is a
;; heading, so TAB and S-TAB fold, and the structure of a long run -- which
;; tools ran, what the model was thinking, what the answer was -- is visible
;; at a glance.
;;
;; It renders from the session struct and never reads a file, and it truncates
;; aggressively because it is a navigation view: `RET' jumps to the full text
;; in the conversation buffer.
;;
;; See DESIGN.md section 9.2.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'outline)
(require 'harness-core)
(require 'harness-session)
(require 'harness-tools)
(require 'harness-faces)

(declare-function harness-conversation-display-message "harness-ui-conversation"
                  (session message))
(declare-function harness-conversation-session "harness-ui-conversation" (&optional buffer))
(declare-function harness-tree-menu "harness-ui-menu" ())

(defcustom harness-tree-display-action
  '(display-buffer-in-side-window (side . right) (window-width . 0.35))
  "`display-buffer' action for the tree view."
  :type '(repeat sexp)
  :group 'harness-ui)

(defcustom harness-tree-body-lines 4
  "Lines of a message body shown under its heading."
  :type 'integer
  :group 'harness-ui)

(defcustom harness-tree-show-tool-output t
  "Whether tool output is shown in the tree, folded."
  :type 'boolean
  :group 'harness-ui)

(defconst harness-tree-max-output-lines 20
  "Hard limit on tool output lines rendered in the tree.")

(defvar-local harness-tree--session nil
  "Session this tree shows.")

(defvar-local harness-tree--show-output nil
  "Whether tool output is expanded in this buffer.")

(defun harness-tree-level ()
  "Return the outline level of the heading at point."
  (cond
   ((looking-at-p "◆") 1)
   ((looking-at-p "▸") 2)
   (t 1)))

(defvar harness-tree-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map outline-mode-map)
    (define-key map (kbd "RET") #'harness-tree-goto-message)
    (define-key map (kbd "TAB") #'outline-toggle-children)
    (define-key map (kbd "<backtab>") #'outline-cycle)
    (define-key map (kbd "g") #'harness-tree-refresh)
    (define-key map (kbd "t") #'harness-tree-toggle-output)
    (define-key map (kbd "n") #'harness-tree-next)
    (define-key map (kbd "p") #'harness-tree-previous)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'harness-tree-menu)
    map)
  "Keymap for `harness-tree-mode'.")

(define-derived-mode harness-tree-mode outline-mode "Harness-Tree"
  "Major mode for the message tree of a session.

Each message is a heading, so \\[outline-toggle-children] folds it.
\\[harness-tree-goto-message] jumps to the same message in the conversation
buffer and \\[harness-tree-refresh] re-renders.  \\[harness-tree-menu] lists
every command."
  (setq-local outline-regexp "^\\(?:◆\\|▸\\|●\\)")
  (setq-local outline-level #'harness-tree-level)
  (setq-local truncate-lines nil)
  (setq-local buffer-read-only t)
  (setq-local header-line-format
              '(:eval (format " Tree: %s — RET jumps, TAB folds, t toggles tool output"
                              (if harness-tree--session
                                  (harness-session-name harness-tree--session)
                                "?")))))

(defun harness-tree--insert (text &rest properties)
  "Insert read-only TEXT with PROPERTIES."
  (let ((start (point)))
    (insert (if properties (apply #'propertize text properties) text))
    (put-text-property start (point) 'read-only t)))

(defun harness-tree-buffer (session)
  "Return SESSION's tree buffer, creating and rendering it if needed."
  (let ((buffer (get-buffer-create (format "*Harness Tree: %s*"
                                           (harness-session-name session)))))
    (with-current-buffer buffer
      (unless (eq harness-tree--session session)
        (harness-tree-mode)
        (setq harness-tree--session session)
        (setq harness-tree--show-output harness-tree-show-tool-output)
        (harness-tree-render)))
    buffer))

(defun harness-tree (&optional session)
  "Show the message tree for SESSION."
  (interactive)
  (let ((session (or session
                     (when (fboundp 'harness-conversation-session)
                       (harness-conversation-session))
                     (harness-session--read-session "Tree of"))))
    (unless session (user-error "No session to show"))
    (display-buffer (harness-tree-buffer session) harness-tree-display-action)))

(defun harness-tree-refresh (&optional session)
  "Re-render the tree."
  (interactive)
  (let ((session (or session harness-tree--session)))
    (unless session (user-error "This is not a tree buffer"))
    (harness-tree-render session)))

(defun harness-tree-render (&optional session)
  "Render SESSION's tree into the current buffer."
  (let ((session (or session harness-tree--session))
        (inhibit-read-only t))
    (unless session (user-error "No session to render"))
    (erase-buffer)
    (harness-tree--insert-summary session)
    (harness-tree--insert-todos session)
    (dolist (message (harness-session-messages session))
      (harness-tree--insert-message session message))
    (goto-char (point-min))
    (when (fboundp 'outline-hide-sublevels)
      (ignore-errors (outline-hide-sublevels 1)))))

(defun harness-tree--insert-summary (session)
  "Insert the session summary for SESSION."
  (let ((usage (harness-session-usage-total session)))
    (harness-tree--insert
     (format "%s  %s\n"
             (harness-session-name session)
             (harness-session-status-string session))
     'face 'bold)
    (harness-tree--insert
     (format "  project %s\n  model   %s\n  tokens  %s\n\n"
             (or (harness-session-project-name session) "?")
             (or (harness-session-model session) "no model")
             (harness-usage-format usage))
     'face 'harness-muted)))

(defun harness-tree--insert-todos (session)
  "Insert SESSION's task list when it has one."
  (when-let* ((todos (harness-session-todos session)))
    (harness-tree--insert "◆ Tasks\n" 'face 'harness-role-tool)
    (dolist (todo todos)
      (let* ((status (harness-plist-or-alist-get :status todo))
             (marker (pcase status
                       ('completed "[x]")
                       ('in_progress "[~]")
                       (_ "[ ]")))
             (face (pcase status
                     ('completed 'harness-todo-completed)
                     ('in_progress 'harness-todo-in-progress)
                     (_ 'harness-todo-pending))))
        (harness-tree--insert (format "  %s %s\n" marker
                                      (harness-plist-or-alist-get :text todo))
                              'face face)))
    (insert "\n")))

(defun harness-tree--insert-message (_session message)
  "Insert MESSAGE as a heading with a body."
  (let* ((role (harness-message-role message))
         (face (pcase role
                 ('user 'harness-role-user)
                 ('assistant 'harness-role-assistant)
                 ('system 'harness-role-system)
                 ('tool 'harness-role-tool)
                 (_ 'harness-muted)))
         (label (pcase role
                  ('user "You")
                  ('assistant "Assistant")
                  ('system "System")
                  ('tool (format "Tool: %s" (or (harness-message-tool-name message) "?")))
                  (_ (capitalize (symbol-name role)))))
         (marker (if (eq role 'tool) "▸" "●")))
    (harness-tree--insert
     (format "%s <msg-%s> %s  %s\n"
             marker (harness-message-id message) label
             (harness-tree--message-meta message))
     'face face
     'harness-message message)
    (when-let* ((thinking (harness-message-thinking message)))
      (harness-tree--insert "  ▸ thinking…\n" 'face 'harness-thinking)
      (harness-tree--insert (harness-tree--indent thinking 4) 'face 'harness-thinking))
    (let ((content (harness-message-content message)))
      (when (and content (not (string-empty-p content)))
        (harness-tree--insert (harness-tree--indent
                               (harness-tree--truncate-lines
                                content harness-tree-body-lines)
                               2)
                              'face 'harness-message-body)))
    (when (harness-message-error message)
      (harness-tree--insert (harness-tree--indent (harness-message-error message) 2)
                            'face 'harness-error))
    (dolist (call (harness-message-tool-calls message))
      (harness-tree--insert-tool-call call))
    (insert "\n")))

(defun harness-tree--message-meta (message)
  "Return MESSAGE's metadata string."
  (string-join
   (delq nil
         (list (harness-format-time (harness-message-timestamp message))
               (when-let* ((duration (harness-message-duration message)))
                 (format "%.1fs" duration))
               (when-let* ((usage (harness-message-usage message)))
                 (harness-usage-format usage))))
   " · "))

(defun harness-tree--insert-tool-call (call)
  "Insert CALL as a level two heading with optional output."
  (harness-tree--insert
   (format "  ▸ %s  %s\n"
           (harness-tool-call-summary call)
           (harness-tree--tool-status call))
   'face 'harness-role-tool
   'harness-tool-call call)
  (when (and harness-tree--show-output (harness-tool-call-result call))
    (harness-tree--insert
     (harness-tree--indent
      (harness-tree--truncate-lines (harness-tool-call-result call)
                                    harness-tree-max-output-lines)
      6)
     'face 'harness-tool-output))
  (when (harness-tool-call-error call)
    (harness-tree--insert (harness-tree--indent (harness-tool-call-error call) 6)
                          'face 'harness-error)))

(defun harness-tree--tool-status (call)
  "Return a readable status for CALL."
  (pcase (harness-tool-call-status call)
    ('ok "✔")
    ('error "✖")
    ('denied "denied")
    ('aborted "aborted")
    ('running "running")
    ('awaiting-approval "waiting for you")
    (_ (format "%s" (harness-tool-call-status call)))))

(defun harness-tree--truncate-lines (text lines)
  "Return TEXT limited to LINES lines, with a note when truncated."
  (let ((split (split-string (or text "") "\n")))
    (if (<= (length split) lines)
        (or text "")
      (concat (string-join (seq-take split lines) "\n")
              (format "\n… %d more lines" (- (length split) lines))))))

(defun harness-tree--indent (text spaces)
  "Return TEXT with every line indented by SPACES."
  (let ((prefix (make-string spaces ?\s)))
    (concat (replace-regexp-in-string "^" prefix text) "\n")))

(defun harness-tree-goto-message ()
  "Open the message at point in the conversation buffer."
  (interactive)
  (let ((message (or (get-text-property (point) 'harness-message)
                     (save-excursion
                       (outline-back-to-heading t)
                       (get-text-property (point) 'harness-message)))))
    (unless message (user-error "No message here"))
    (unless (fboundp 'harness-conversation-display-message)
      (user-error "The conversation view is not available"))
    (harness-conversation-display-message harness-tree--session message)))

(defun harness-tree-toggle-output ()
  "Show or hide tool output in this tree."
  (interactive)
  (setq harness-tree--show-output (not harness-tree--show-output))
  (harness-tree-render)
  (message "Tool output %s" (if harness-tree--show-output "shown" "hidden")))

(defun harness-tree-next ()
  "Move to the next message heading."
  (interactive)
  (outline-next-heading))

(defun harness-tree-previous ()
  "Move to the previous message heading."
  (interactive)
  (outline-previous-heading))

(defun harness-tree--on-session-updated (session &rest _)
  "Refresh SESSION's tree buffer when it is visible."
  (when-let* ((buffer (get-buffer (format "*Harness Tree: %s*"
                                          (harness-session-name session)))))
    (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
      (with-current-buffer buffer
        (when (eq harness-tree--session session)
          (ignore-errors (harness-tree-render session)))))))

(add-hook 'harness-run-finished-hook #'harness-tree--on-session-updated)
(add-hook 'harness-after-reload-hook
          (lambda ()
            (dolist (buffer (buffer-list))
              (with-current-buffer buffer
                (when (and (derived-mode-p 'harness-tree-mode) harness-tree--session)
                  (ignore-errors (harness-tree-render)))))))

(provide 'harness-ui-tree)
;;; harness-ui-tree.el ends here
