;;; harness-mode-line.el --- Status line and global indicator -*- lexical-binding: t; -*-

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

;; Two pieces of chrome:
;;
;; - `harness-mode-line-mode' replaces a conversation buffer's mode line with
;;   a harness-specific one: status, model, tokens and cost.
;; - `harness-mode-line-global-mode' adds a short indicator to
;;   `global-mode-string' showing how many sessions are blocked on the user,
;;   so a session waiting for an approval is visible from any buffer.
;;
;; Both are `:eval' constructs that read live session structs; neither touches
;; the filesystem or formats more than a handful of numbers, because the mode
;; line is redisplayed constantly.
;;
;; See DESIGN.md section 9.2.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-session)
(require 'harness-queue)
(require 'harness-faces)

(declare-function harness-conversation-session "harness-ui-conversation" (&optional buffer))

(defcustom harness-mode-line-show-cost t
  "Whether the model line shows tokens and cost."
  :type 'boolean
  :group 'harness-ui)

(defcustom harness-mode-line-global t
  "Whether the global indicator is added when the global mode is enabled."
  :type 'boolean
  :group 'harness-ui)

(defconst harness-mode-line--global-construct
  '(:eval (harness-mode-line-global-string))
  "Element added to `global-mode-string'.")

(defvar-local harness-mode-line--original nil
  "The buffer's `mode-line-format' before `harness-mode-line-mode'.")

(defun harness-mode-line-string (&optional session)
  "Return the mode line text for SESSION, or the current buffer's session."
  (let ((session (or session
                     (when (fboundp 'harness-conversation-session)
                       (harness-conversation-session)))))
    (if (null session)
        ""
      (let ((status (harness-session-status session)))
        (concat
         (propertize (format " %s " (harness-status-glyph status))
                     'face (harness-status-face status))
         (propertize (harness-session-status-string session) 'face (harness-status-face status))
         " "
         (propertize (or (harness-session-model session) "no model") 'face 'bold)
         (when harness-mode-line-show-cost
           (propertize (format " %s" (harness-usage-format
                                      (harness-session-usage-total session)))
                       'face 'harness-cost))
         (when (harness-session-approvals session)
           (propertize (format " ⚠%d" (length (harness-session-approvals session)))
                       'face 'harness-approval))
         (when (harness-session-queue session)
           (propertize (format " ✎%d" (harness-queue-length session))
                       'face 'harness-queue))
         " ")))))

(defun harness-mode-line-blocked-count ()
  "Return how many live sessions are waiting for the user."
  (let ((count 0))
    (maphash (lambda (_id session)
               (when (harness-session-blocked-p session)
                 (setq count (1+ count))))
             harness--sessions)
    count))

(defun harness-mode-line-active-count ()
  "Return how many live sessions are busy."
  (let ((count 0))
    (maphash (lambda (_id session)
               (when (harness-session-active-p session)
                 (setq count (1+ count))))
             harness--sessions)
    count))

(defun harness-mode-line-global-string ()
  "Return the global indicator: blocked sessions first, then active ones."
  (let ((blocked (harness-mode-line-blocked-count))
        (active (harness-mode-line-active-count)))
    (cond
     ((> blocked 0)
      (propertize (format " ⚠%d blocked " blocked) 'face 'harness-status-blocked))
     ((> active 0)
      (propertize (format " ◐%d " active) 'face 'harness-status-active))
     (t ""))))

(define-minor-mode harness-mode-line-mode
  "Show harness status, model, tokens and cost in the mode line."
  :lighter nil
  :group 'harness-ui
  (if harness-mode-line-mode
      (progn
        (unless harness-mode-line--original
          (setq harness-mode-line--original mode-line-format))
        (setq mode-line-format
              '("%e" mode-line-front-space
                (:eval (harness-mode-line-string))
                mode-line-end-spaces)))
    (when harness-mode-line--original
      (setq mode-line-format harness-mode-line--original)
      (setq harness-mode-line--original nil))))

(define-minor-mode harness-mode-line-global-mode
  "Show the number of blocked or busy harness sessions in every mode line."
  :global t
  :lighter nil
  :group 'harness-ui
  (if harness-mode-line-global-mode
      (when (and harness-mode-line-global
                 (not (member harness-mode-line--global-construct global-mode-string)))
        (setq global-mode-string
              (append global-mode-string (list harness-mode-line--global-construct))))
    (setq global-mode-string
          (remove harness-mode-line--global-construct global-mode-string))))

(provide 'harness-mode-line)
;;; harness-mode-line.el ends here
