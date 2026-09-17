;;; harness-faces.el --- Faces and status presentation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai, faces
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

;; Every visual element is a face in the `harness' group, and each one inherits
;; from an existing Emacs face (`font-lock-*', `success', `error', `warning',
;; `shadow', `mode-line-*').  A third-party theme that colours those will
;; colour the harness, and a theme that wants to be specific can override these
;; without the harness knowing about it.
;;
;; Status presentation lives here too, because it should be themeable in the
;; same way: `harness-status-faces' maps a session status to a face and
;; `harness-status-glyphs' maps it to a short string.
;;
;; See DESIGN.md section 12.

;;; Code:

(require 'harness-core)

(defface harness-role-user
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the user's own message headers."
  :group 'harness-faces)

(defface harness-role-assistant
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the assistant's message headers."
  :group 'harness-faces)

(defface harness-role-system
  '((t :inherit shadow :slant italic))
  "Face for system and status notes."
  :group 'harness-faces)

(defface harness-role-tool
  '((t :inherit font-lock-builtin-face :weight bold))
  "Face for tool names and tool headers."
  :group 'harness-faces)

(defface harness-message-body
  '((t :inherit default))
  "Face for message bodies."
  :group 'harness-faces)

(defface harness-thinking
  '((t :inherit shadow :slant italic))
  "Face for reasoning traces."
  :group 'harness-faces)

(defface harness-prompt
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the input prompt."
  :group 'harness-faces)

(defface harness-muted
  '((t :inherit shadow))
  "Face for metadata: timestamps, token counts, durations."
  :group 'harness-faces)

(defface harness-cost
  '((t :inherit font-lock-constant-face))
  "Face for the session cost."
  :group 'harness-faces)

(defface harness-tool-output
  '((t :inherit default))
  "Face for tool output blocks."
  :group 'harness-faces)

(defface harness-tool-status-ok
  '((t :inherit success))
  "Face for a successful tool call."
  :group 'harness-faces)

(defface harness-tool-status-error
  '((t :inherit error))
  "Face for a failed tool call."
  :group 'harness-faces)

(defface harness-tool-status-running
  '((t :inherit warning))
  "Face for a tool call in progress."
  :group 'harness-faces)

(defface harness-tool-status-awaiting
  '((t :inherit warning :weight bold))
  "Face for a tool call waiting for the user."
  :group 'harness-faces)

(defface harness-approval
  '((t :inherit warning :weight bold))
  "Face for approval prompts."
  :group 'harness-faces)

(defface harness-queue
  '((t :inherit font-lock-string-face))
  "Face for queued messages."
  :group 'harness-faces)

(defface harness-error
  '((t :inherit error))
  "Face for errors."
  :group 'harness-faces)

(defface harness-diff-add
  '((t :inherit diff-added))
  "Face for added lines in a rendered diff."
  :group 'harness-faces)

(defface harness-diff-remove
  '((t :inherit diff-removed))
  "Face for removed lines in a rendered diff."
  :group 'harness-faces)

(defface harness-todo-pending
  '((t :inherit default))
  "Face for an unfinished task."
  :group 'harness-faces)

(defface harness-todo-in-progress
  '((t :inherit warning :weight bold))
  "Face for the task in progress."
  :group 'harness-faces)

(defface harness-todo-completed
  '((t :inherit success :strike-through t))
  "Face for a finished task."
  :group 'harness-faces)

(defface harness-status-active
  '((t :inherit mode-line-emphasis :weight bold))
  "Face for a busy session in the mode line."
  :group 'harness-faces)

(defface harness-status-blocked
  '((t :inherit mode-line-buffer-id :weight bold :inverse-video t))
  "Face for a session blocked on the user in the mode line."
  :group 'harness-faces)

(defface harness-status-idle
  '((t :inherit mode-line-inactive))
  "Face for an idle session in the mode line."
  :group 'harness-faces)

(defface harness-status-error
  '((t :inherit error :weight bold))
  "Face for a session that is showing an error."
  :group 'harness-faces)

(defcustom harness-status-glyphs
  '((idle . "○")
    (working . "◐")
    (streaming . "◑")
    (classifying . "◒")
    (awaiting-approval . "!")
    (awaiting-answer . "?")
    (aborted . "×")
    (exited . "·"))
  "Short glyph per session status, shown in the mode line and session list."
  :type '(alist :key-type symbol :value-type string)
  :group 'harness-faces)

(defcustom harness-status-faces
  '((idle . harness-status-idle)
    (working . harness-status-active)
    (streaming . harness-status-active)
    (classifying . harness-status-active)
    (awaiting-approval . harness-status-blocked)
    (awaiting-answer . harness-status-blocked)
    (aborted . harness-status-error)
    (exited . harness-muted))
  "Face per session status."
  :type '(alist :key-type symbol :value-type face)
  :group 'harness-faces)

(defun harness-status-face (status)
  "Return the face for STATUS."
  (or (cdr (assq status harness-status-faces)) 'harness-muted))

(defun harness-status-glyph (status)
  "Return the glyph for STATUS."
  (or (cdr (assq status harness-status-glyphs)) "?"))

(defun harness-status-propertize (status &optional label)
  "Return LABEL (default the status name) propertized for STATUS."
  (propertize (or label (symbol-name status))
              'face (harness-status-face status)))

(defun harness-tool-status-face (status)
  "Return the face for tool call STATUS."
  (pcase status
    ('ok 'harness-tool-status-ok)
    ('error 'harness-tool-status-error)
    ('denied 'harness-tool-status-error)
    ('aborted 'harness-muted)
    ('running 'harness-tool-status-running)
    ('awaiting-approval 'harness-tool-status-awaiting)
    (_ 'harness-muted)))

(provide 'harness-faces)
;;; harness-faces.el ends here
