;;; harness-ui-sessions.el --- Session browser -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; Author: the emacs-agent-harness authors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;; URL: https://git.sr.ht/~catvec/emacs-agent-harness

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

;; A `tabulated-list-mode' browser over the live sessions and the session
;; files on disk, so a session from a previous Emacs is one keystroke away.
;;
;; Blocked sessions sort first, which is the point of the buffer: it is how a
;; user notices that a run is waiting for an approval while they are working
;; elsewhere.  Filtering by status or project is one command each, and content
;; search reuses the SQLite index rather than reading transcripts.
;;
;; Entry generation does no I/O beyond the cached session headers, and the
;; buffer is only rebuilt when it is visible AND the events that change what it
;; shows happen (a run finishing, an approval appearing, a session being
;; created or removed) -- never on every streamed token.
;;
;; See DESIGN.md section 9.2.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'tabulated-list)
(require 'harness-core)
(require 'harness-session)
(require 'harness-perms)
(require 'harness-agent)
(require 'harness-ui-conversation)
(require 'harness-faces)

(declare-function harness-new-session "harness" (&optional name))
(declare-function harness-select-model "harness-ui-model" (&optional session))

(defcustom harness-sessions-display-action
  '(display-buffer-same-window)
  "`display-buffer' action for the session browser."
  :type '(repeat sexp)
  :group 'harness-ui)

(defcustom harness-sessions-default-filter 'all
  "Which sessions the browser shows by default."
  :type '(choice (const :tag "All sessions" all)
                 (const :tag "Blocked on the user" blocked)
                 (const :tag "Busy" active)
                 (const :tag "Idle" idle)
                 (const :tag "This project" project))
  :group 'harness-ui)

(defcustom harness-sessions-refresh-delay 0.2
  "Seconds to coalesce browser refreshes."
  :type 'number
  :group 'harness-ui)

(defvar-local harness-sessions--filter nil
  "Current filter, a symbol from `harness-sessions-default-filter'.")

(defvar-local harness-sessions--search nil
  "Current search query, or nil when not in search mode.")

(defvar-local harness-sessions--search-results nil
  "Results of the current search, a list of plists.")

(defvar harness-sessions--refresh-timer nil
  "Pending refresh timer, or nil.")

(defvar harness-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'harness-sessions-view)
    (define-key map (kbd "o") #'harness-sessions-view)
    (define-key map (kbd "r") #'harness-sessions-resume)
    (define-key map (kbd "d") #'harness-sessions-delete)
    (define-key map (kbd "k") #'harness-sessions-close)
    (define-key map (kbd "a") #'harness-sessions-approve)
    (define-key map (kbd "A") #'harness-sessions-approve-always)
    (define-key map (kbd "D") #'harness-sessions-deny)
    (define-key map (kbd "x") #'harness-sessions-abort)
    (define-key map (kbd "s") #'harness-sessions-search)
    (define-key map (kbd "/") #'harness-sessions-filter)
    (define-key map (kbd "P") #'harness-sessions-filter-project)
    (define-key map (kbd "n") #'harness-sessions-new)
    (define-key map (kbd "m") #'harness-select-model)
    (define-key map (kbd "R") #'harness-sessions-rename)
    (define-key map (kbd "g") #'harness-sessions-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `harness-sessions-mode'.")

(define-derived-mode harness-sessions-mode tabulated-list-mode "Harness-Sessions"
  "Major mode for browsing agent sessions.

\\[harness-sessions-view] opens a conversation,
\\[harness-sessions-search] searches transcripts by content,
\\[harness-sessions-filter] filters by status and
\\[harness-sessions-approve] answers an approval without leaving this buffer."
  (setq tabulated-list-format
        [("" 2 t)
         ("Project" 18 t)
         ("Session" 30 t)
         ("Model" 18 t)
         ("Tokens" 12 t)
         ("Age" 5 t)
         ("Match" 40 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'harness-sessions--refresh-data nil t)
  (setq-local harness-sessions--filter harness-sessions-default-filter)
  (tabulated-list-init-header))

(defun harness-sessions--refresh-data ()
  "Rebuild the browser's data, cheaply."
  (setq tabulated-list-entries
        (if harness-sessions--search
            (harness-sessions--search-entries)
          (harness-sessions--session-entries))))

(defun harness-sessions--session-entries ()
  "Return tabulated entries for every session, live and on disk."
  (let ((seen (make-hash-table :test #'equal))
        (items nil))
    (dolist (session (harness-session-list))
      (puthash (harness-session-id session) t seen)
      (when (harness-sessions--visible-p session nil)
        (push (harness-sessions--item session nil) items)))
    (dolist (record (harness-session-records))
      (unless (gethash (harness-plist-or-alist-get :id record) seen)
        (when (harness-sessions--visible-p nil record)
          (push (harness-sessions--item nil record) items))))
    (mapcar #'harness-sessions--to-entry (harness-sessions--sort items))))

(defun harness-sessions--visible-p (session record)
  "Return non-nil when SESSION or RECORD passes the current filter."
  (let* ((status (if session
                     (harness-session-status session)
                   (harness-session-record-status record)))
         (root (if session
                   (harness-session-cwd session)
                 (harness-plist-or-alist-get :project-root record))))
    (pcase (or harness-sessions--filter 'all)
      ('blocked (harness-status-blocked-p status))
      ('active (harness-status-active-p status))
      ('idle (eq status 'idle))
      ('project (and root
                     (equal (file-name-as-directory (expand-file-name root))
                            (file-name-as-directory
                             (expand-file-name default-directory)))))
      (_ t))))

(defun harness-sessions--item (session record)
  "Return a sortable item for SESSION or RECORD.
The item is (ID STATUS-RANK UPDATED COLUMNS); sorting happens before the
columns are turned into a `tabulated-list' entry, because the displayed age is
a string and sorting on it would be wrong."
  (let* ((id (if session (harness-session-id session)
               (harness-plist-or-alist-get :id record)))
         (status (if session (harness-session-status session)
                   (harness-session-record-status record)))
         (name (if session (harness-session-name session)
                 (or (harness-plist-or-alist-get :name record) "?")))
         (project (if session (harness-session-project-name session)
                    (or (harness-plist-or-alist-get :project-name record) "")))
         (model (if session (harness-session-model session)
                  (or (harness-plist-or-alist-get :model record) "")))
         (usage (if session (harness-session-usage-total session) nil))
         (updated (or (if session (harness-session-updated session)
                        (harness-plist-or-alist-get :mtime record))
                      0))
         (rank (cond ((harness-status-blocked-p status) 0)
                     ((harness-status-active-p status) 1)
                     (t 2))))
    (list id rank updated
          (vector
           (propertize (harness-status-glyph status)
                       'face (harness-status-face status))
           (propertize (format "%s" project) 'face 'harness-muted)
           (propertize (format "%s" name)
                       'face (if (harness-status-blocked-p status)
                                 'harness-approval 'bold))
           (propertize (format "%s" model) 'face 'harness-muted)
           (propertize (if usage (harness-usage-format usage) "") 'face 'harness-cost)
           (harness-format-time updated)
           ""))))

(defun harness-sessions--sort (items)
  "Sort ITEMS by status rank, then by recency."
  (sort items
        (lambda (a b)
          (if (= (nth 1 a) (nth 1 b))
              (> (nth 2 a) (nth 2 b))
            (< (nth 1 a) (nth 1 b))))))

(defun harness-sessions--to-entry (item)
  "Convert an ITEM into a `tabulated-list' entry."
  (list (car item) (nth 3 item)))

(defun harness-sessions--search-entries ()
  "Return tabulated entries for the current search results."
  (mapcar
   (lambda (result)
     (let ((session (harness-session-get
                     (harness-plist-or-alist-get :session-id result))))
       (list (harness-plist-or-alist-get :session-id result)
             (vector
              (propertize "?" 'face 'harness-muted)
              (propertize (format "%s"
                                  (or (and session (harness-session-project-name session))
                                      ""))
                          'face 'harness-muted)
              (propertize (format "%s" (or (harness-plist-or-alist-get :name result) "?"))
                          'face 'bold)
              (propertize (format "%s" (or (harness-plist-or-alist-get :role result) ""))
                          'face 'harness-muted)
              ""
              (harness-format-time (harness-plist-or-alist-get :ts result))
              (propertize (format "%s" (or (harness-plist-or-alist-get :snippet result) ""))
                          'face 'harness-muted)))))
   harness-sessions--search-results))

(defun harness-sessions--session-at-point ()
  "Return the live session on the current line, or nil."
  (harness-session-get (tabulated-list-get-id)))

(defun harness-sessions--record-at-point ()
  "Return the on-disk record for the current line, or nil."
  (let ((id (tabulated-list-get-id)))
    (cl-find-if (lambda (record)
                  (equal (harness-plist-or-alist-get :id record) id))
                (harness-session-records))))

(defun harness-sessions--ensure-session ()
  "Return the live session at point, resuming it from disk if needed."
  (or (harness-sessions--session-at-point)
      (when-let* ((record (harness-sessions--record-at-point)))
        (harness-session-resume (harness-plist-or-alist-get :file record)))))

(defun harness-sessions-refresh ()
  "Rebuild the browser."
  (interactive)
  (revert-buffer))

(defun harness-sessions-view ()
  "Open the conversation for the session at point."
  (interactive)
  (let ((session (harness-sessions--ensure-session)))
    (unless session (user-error "No session on this line"))
    (harness-conversation-open session)))

(defun harness-sessions-resume ()
  "Resume the session at point and open it."
  (interactive)
  (harness-sessions-view))

(defun harness-sessions-new ()
  "Start a new session."
  (interactive)
  (harness-new-session))

(defun harness-sessions-delete ()
  "Delete the session at point."
  (interactive)
  (let ((session (harness-sessions--ensure-session)))
    (unless session (user-error "No session on this line"))
    (harness-session-delete session)
    (harness-sessions-refresh)))

(defun harness-sessions-close ()
  "Close the live session at point, keeping its file."
  (interactive)
  (let ((session (harness-sessions--session-at-point)))
    (unless session (user-error "That session is not live"))
    (harness-session-kill session)
    (harness-sessions-refresh)))

(defun harness-sessions-rename ()
  "Rename the session at point."
  (interactive)
  (let ((session (harness-sessions--ensure-session)))
    (unless session (user-error "No session on this line"))
    (harness-session-rename session
                            (read-string "New name: " (harness-session-name session)))
    (harness-sessions-refresh)))

(defun harness-sessions-abort ()
  "Abort the run of the live session at point."
  (interactive)
  (let ((session (harness-sessions--session-at-point)))
    (unless session (user-error "That session is not live"))
    (harness-agent-abort session)
    (harness-sessions-refresh)))

(defun harness-sessions--approval-at-point ()
  "Return the oldest pending approval of the session at point."
  (when-let* ((session (harness-sessions--session-at-point)))
    (car (harness-approval-pending session))))

(defun harness-sessions-approve ()
  "Allow the pending approval of the session at point."
  (interactive)
  (let ((approval (harness-sessions--approval-at-point)))
    (unless approval (user-error "No pending approval"))
    (harness-perms-resolve approval 'allow)
    (harness-sessions-refresh)))

(defun harness-sessions-approve-always ()
  "Allow and remember the pending approval of the session at point."
  (interactive)
  (let ((approval (harness-sessions--approval-at-point)))
    (unless approval (user-error "No pending approval"))
    (harness-perms-resolve approval 'allow-always)
    (harness-sessions-refresh)))

(defun harness-sessions-deny ()
  "Deny the pending approval of the session at point."
  (interactive)
  (let ((approval (harness-sessions--approval-at-point)))
    (unless approval (user-error "No pending approval"))
    (harness-perms-resolve approval 'deny)
    (harness-sessions-refresh)))

(defun harness-sessions-filter (filter)
  "Show only sessions matching FILTER."
  (interactive
   (list (intern (completing-read "Filter: "
                                  '("all" "blocked" "active" "idle" "project")
                                  nil t))))
  (setq harness-sessions--filter filter
        harness-sessions--search nil
        harness-sessions--search-results nil)
  (harness-sessions-refresh)
  (message "Showing %s sessions" filter))

(defun harness-sessions-filter-project ()
  "Show only sessions belonging to the current project."
  (interactive)
  (setq harness-sessions--filter 'project
        harness-sessions--search nil
        harness-sessions--search-results nil)
  (harness-sessions-refresh)
  (message "Showing sessions for %s" (directory-file-name default-directory)))

(defun harness-sessions-search (query)
  "Search transcripts for QUERY and show the matches in this buffer."
  (interactive "sSearch sessions: ")
  (setq harness-sessions--search query
        harness-sessions--search-results (harness-index-search query 200))
  (harness-sessions-refresh)
  (message "%d match%s for %s"
           (length harness-sessions--search-results)
           (if (= (length harness-sessions--search-results) 1) "" "es")
           query))

(defun harness-sessions--buffer (name)
  "Return an initialised session browser buffer named NAME."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-sessions-mode)
        (harness-sessions-mode)))
    buffer))

(defun harness-list-sessions ()
  "Show all sessions."
  (interactive)
  (let ((buffer (harness-sessions--buffer "*Harness Sessions*")))
    (with-current-buffer buffer
      (setq harness-sessions--search nil
            harness-sessions--search-results nil
            harness-sessions--filter harness-sessions-default-filter)
      (harness-sessions-refresh))
    (display-buffer buffer harness-sessions-display-action)))

(defun harness-list-project-sessions ()
  "Show the sessions of the current project."
  (interactive)
  (harness-list-sessions)
  (with-current-buffer "*Harness Sessions*"
    (harness-sessions-filter-project)))

(defun harness-search-sessions-ui (query)
  "Search transcripts for QUERY and show the results."
  (interactive "sSearch sessions: ")
  (let ((buffer (harness-sessions--buffer "*Harness Search*")))
    (with-current-buffer buffer
      (harness-sessions-search query))
    (display-buffer buffer harness-sessions-display-action)))


;;; Keeping the browser current

(defun harness-sessions--refresh-visible ()
  "Rebuild every session browser that is actually on screen."
  (setq harness-sessions--refresh-timer nil)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'harness-sessions-mode)
                 (get-buffer-window buffer t))
        (ignore-errors (revert-buffer))))))

(defun harness-sessions--schedule-refresh (&rest _)
  "Coalesce a browser refresh."
  (when (timerp harness-sessions--refresh-timer)
    (cancel-timer harness-sessions--refresh-timer))
  (setq harness-sessions--refresh-timer
        (run-at-time harness-sessions-refresh-delay nil
                     #'harness-sessions--refresh-visible)))

;; Only the events that change what the list shows, not every token.
(add-hook 'harness-run-finished-hook #'harness-sessions--schedule-refresh)
(add-hook 'harness-status-changed-hook #'harness-sessions--schedule-refresh)
(add-hook 'harness-approval-added-hook #'harness-sessions--schedule-refresh)
(add-hook 'harness-approval-resolved-hook #'harness-sessions--schedule-refresh)
(add-hook 'harness-session-created-hook #'harness-sessions--schedule-refresh)
(add-hook 'harness-session-deleted-hook #'harness-sessions--schedule-refresh)
(add-hook 'harness-message-added-hook #'harness-sessions--schedule-refresh)
(add-hook 'harness-after-reload-hook #'harness-sessions--schedule-refresh)

(provide 'harness-ui-sessions)
;;; harness-ui-sessions.el ends here
