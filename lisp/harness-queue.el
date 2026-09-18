;;; harness-queue.el --- Queued messages and their editor -*- lexical-binding: t; -*-

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

;; Submitting while a session is busy enqueues the message instead of dropping
;; it.  The queue is part of the session, so it is persisted and survives a
;; restart, and it has a real editor: `harness-queue-mode' is a text buffer
;; with one message per section, separated by form feeds so that parsing on
;; commit is trivial.
;;
;; See DESIGN.md section 11.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-session)

(defcustom harness-queue-display-action
  '(display-buffer-at-bottom (window-height . 0.3))
  "`display-buffer' action used for the queue editor."
  :type '(repeat sexp)
  :group 'harness-ui)

(defconst harness-queue-separator "\f"
  "Separator between queued messages in the editor, one per section.")

(defvar harness-queue-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'harness-queue-commit)
    (define-key map (kbd "C-c C-k") #'harness-queue-cancel)
    (define-key map (kbd "C-c C-d") #'harness-queue-delete-section-at-point)
    (define-key map (kbd "C-c C-n") #'harness-queue-next)
    (define-key map (kbd "C-c C-p") #'harness-queue-previous)
    map)
  "Keymap for `harness-queue-mode'.")

(defvar-local harness-queue--session nil
  "Session whose queue this buffer edits.")

(defvar-local harness-queue--original nil
  "Text of the buffer when it was created, to detect unsaved edits.")

(define-derived-mode harness-queue-mode text-mode "Harness-Queue"
  "Major mode for editing a session's queued messages.

Each message is one section, separated by a form feed.  \\[harness-queue-commit]
saves, \\[harness-queue-cancel] discards, and \\[harness-queue-delete-section-at-point]
removes the message under point."
  (setq-local buffer-read-only nil)
  (setq-local header-line-format
              '(:eval (format " Queued messages for %s — %s"
                              (if harness-queue--session
                                  (harness-session-name harness-queue--session)
                                "?")
                              (harness-key-hints
                               (list "save" #'harness-queue-commit harness-queue-mode-map)
                               (list "discard" #'harness-queue-cancel harness-queue-mode-map)
                               (list "delete" #'harness-queue-delete-section-at-point
                                     harness-queue-mode-map))))))


;;; The queue

(defun harness-queue-add (session text)
  "Append TEXT to SESSION's queue and return the queued message."
  (let ((queued (harness-queued-message-create text)))
    (setf (harness-session-queue session)
          (append (harness-session-queue session) (list queued)))
    (harness-session-save-state session)
    (harness-session-notify session 'queue)
    queued))

(defun harness-queue-pop (session)
  "Remove and return SESSION's oldest queued message, or nil."
  (let ((queue (harness-session-queue session)))
    (when queue
      (setf (harness-session-queue session) (cdr queue))
      (harness-session-notify session 'queue)
      (car queue))))

(defun harness-queue-remove (session queued)
  "Remove QUEUED from SESSION's queue."
  (setf (harness-session-queue session)
        (delq queued (harness-session-queue session)))
  (harness-session-save-state session)
  (harness-session-notify session 'queue))

(defun harness-queue-clear (session)
  "Remove every queued message from SESSION."
  (interactive (list (harness-session--read-session "Clear queue of")))
  (setf (harness-session-queue session) nil)
  (harness-session-save-state session)
  (harness-session-notify session 'queue))

(defun harness-queue-length (session)
  "Return how many messages SESSION has queued."
  (length (harness-session-queue session)))

(defun harness-queue-text (session)
  "Return SESSION's queued messages as one editable string."
  (string-join (mapcar #'harness-queued-message-text (harness-session-queue session))
               harness-queue-separator))

(defun harness-queue-replace (session text)
  "Replace SESSION's queue with the sections in TEXT."
  (let ((sections (split-string text harness-queue-separator))
        (existing (make-hash-table :test #'equal))
        (index 0))
    (dolist (queued (harness-session-queue session))
      (puthash (number-to-string index) queued existing)
      (setq index (1+ index)))
    (setf (harness-session-queue session)
          (delq nil
                (cl-loop for section in sections
                         for position from 0
                         when (not (string-empty-p (string-trim section)))
                         collect (let ((old (gethash (number-to-string position) existing)))
                                   (if old
                                       (progn (setf (harness-queued-message-text old)
                                                    (string-trim section))
                                              old)
                                     (harness-queued-message-create
                                      (string-trim section)))))))
    (harness-session-save-state session)
    (harness-session-notify session 'queue)
    (harness-session-queue session)))


;;; The editor

(defun harness-queue-edit (&optional session)
  "Open an editor for SESSION's queued messages."
  (interactive (list (or (harness-session--read-session "Edit queue of")
                         (user-error "No live sessions"))))
  (let* ((buffer (get-buffer-create (format "*Harness Queue: %s*"
                                            (harness-session-name session)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (harness-queue-mode)
        (setq harness-queue--session session)
        (insert (string-join
                 (mapcar #'harness-queued-message-text (harness-session-queue session))
                 (concat "\n" harness-queue-separator "\n")))
        (setq harness-queue--original (buffer-string))
        (goto-char (point-min))))
    (display-buffer buffer harness-queue-display-action)
    buffer))

(defun harness-queue-commit ()
  "Save the buffer's contents back into the session's queue."
  (interactive)
  (unless harness-queue--session (user-error "Not a queue buffer"))
  (let ((text (buffer-string)))
    (harness-queue-replace harness-queue--session
                           (replace-regexp-in-string
                            (concat "\n?" harness-queue-separator "\n?")
                            harness-queue-separator text))
    (setq harness-queue--original text)
    (message "Saved %d queued message%s"
             (harness-queue-length harness-queue--session)
             (if (= (harness-queue-length harness-queue--session) 1) "" "s"))))

(defun harness-queue-cancel ()
  "Discard edits and bury the queue buffer."
  (interactive)
  (when (and harness-queue--original
             (not (equal harness-queue--original (buffer-string)))
             (not (yes-or-no-p "Discard queue edits? ")))
    (user-error "Aborted"))
  (bury-buffer))

(defun harness-queue-delete-section-at-point ()
  "Delete the queued message section containing point."
  (interactive)
  (let ((start (save-excursion
                 (if (re-search-backward (concat "^" harness-queue-separator "$") nil t)
                     (progn (forward-line 1) (point))
                   (point-min))))
        (end (save-excursion
               (if (re-search-forward (concat "^" harness-queue-separator "$") nil t)
                   (progn (beginning-of-line) (point))
                 (point-max)))))
    (delete-region start end)
    ;; Tidy up the separators left behind by removing a middle section.
    (cond
     ((looking-at-p "\n\f") (delete-char 1))
     ((and (> (point) (point-min)) (eq (char-before) ?\n)
           (looking-at-p "\f")) (delete-char -1)))))

(defun harness-queue-next ()
  "Move to the next queued message."
  (interactive)
  (let ((point (point)))
    (when (re-search-forward (concat "^" harness-queue-separator "$") nil t)
      (forward-line 1))
    (when (= point (point)) (goto-char (point-max)))))

(defun harness-queue-previous ()
  "Move to the previous queued message."
  (interactive)
  (forward-line -1)
  (when (re-search-backward (concat "^" harness-queue-separator "$") nil t)
    (forward-line 1)))

(provide 'harness-queue)
;;; harness-queue.el ends here
