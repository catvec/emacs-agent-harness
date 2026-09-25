;;; harness-ui-model.el --- Model selection -*- lexical-binding: t; -*-

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

;; Choosing a model is a `completing-read' with the stats as an annotation, so
;; the price and context window are visible while choosing, plus a browseable
;; list for the whole catalogue.  Both read `harness-model-search' and
;; `harness-model-stats', which are the single source of truth for what is
;; configured and what a provider reported.
;;
;; See DESIGN.md sections 5.3 and 9.2.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'harness-core)
(require 'harness-session)
(require 'harness-provider)
(require 'harness-faces)

(declare-function harness-conversation-session "harness-ui-conversation" (&optional buffer))
(declare-function harness-model-menu "harness-ui-menu" ())

(defcustom harness-model-buffer-display-action
  '(display-buffer-same-window)
  "`display-buffer' action for the model list."
  :type '(repeat sexp)
  :group 'harness-ui)

(defvar harness-model-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'harness-model-use)
    (define-key map (kbd "m") #'harness-model-use)
    (define-key map (kbd "R") #'harness-model-refresh)
    (define-key map (kbd "g") #'revert-buffer)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'harness-model-menu)
    map)
  "Keymap for `harness-model-mode'.")

(define-derived-mode harness-model-mode tabulated-list-mode "Harness-Models"
  "Major mode listing every known model with its price and context window.

\\[harness-model-use] selects the model for the session this list was opened
from, \\[harness-model-refresh] asks the providers for their catalogue, and
\\[harness-model-menu] lists every command."
  (setq tabulated-list-format
        [("Model" 34 t)
         ("Provider" 14 t)
         ("Context" 10 t)
         ("In/Mtok" 10 t)
         ("Out/Mtok" 10 t)
         ("Source" 11 t)])
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'harness-model--refresh-data nil t)
  (tabulated-list-init-header))

(defvar-local harness-model--session nil
  "Session the model list was opened from, or nil.")

(defun harness-model--refresh-data ()
  "Rebuild the model list from the model registry."
  (setq tabulated-list-entries
        (mapcar
         (lambda (stats)
           (list (harness-model-stats-id stats)
                 (vector
                  (propertize (harness-model-stats-id stats) 'face 'bold)
                  (propertize (format "%s" (harness-model-stats-provider stats))
                              'face 'harness-muted)
                  (propertize (or (and (harness-model-stats-context-window stats)
                                       (harness-format-count
                                        (harness-model-stats-context-window stats)))
                                  "?")
                              'face 'harness-muted)
                  (harness-format-cost (harness-model-stats-price-in stats))
                  (harness-format-cost (harness-model-stats-price-out stats))
                  (propertize (format "%s" (harness-model-stats-source stats))
                              'face 'harness-muted))))
         (harness-model-search))))

(defun harness-list-models (&optional session)
  "Show every known model."
  (interactive)
  (let ((buffer (get-buffer-create "*Harness Models*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-model-mode)
        (harness-model-mode))
      (setq harness-model--session session)
      (revert-buffer))
    (display-buffer buffer harness-model-buffer-display-action)))

(defun harness-model-refresh ()
  "Ask every provider for its model list, then rebuild this buffer."
  (interactive)
  (harness-refresh-models
   (lambda (count)
     (message "Discovered %d models" count)
     (dolist (buffer (buffer-list))
       (with-current-buffer buffer
         (when (derived-mode-p 'harness-model-mode)
           (ignore-errors (revert-buffer))))))))

(defun harness-model-use ()
  "Use the model on this line for the session the list was opened from."
  (interactive)
  (let ((model (tabulated-list-get-id)))
    (unless model (user-error "No model on this line"))
    (if harness-model--session
        (harness-model-apply harness-model--session model)
      (harness-select-model))))

(defun harness-model-apply (session model)
  "Set SESSION's model to MODEL, along with the provider that serves it."
  (let ((provider (harness-model-provider-for session model)))
    (harness-session-set-model session model)
    (when provider
      (harness-session-set-provider session provider))
    (message "%s now uses %s"
             (harness-session-name session)
             (harness-model-stats-describe (harness-model-stats provider model)))
    model))

(defun harness-model--target-session ()
  "Return the session to change: the current one, or the user's choice."
  (or (when (fboundp 'harness-conversation-session)
        (harness-conversation-session))
      (harness-session--read-session "Model for")))

(defun harness-select-model (&optional session)
  "Choose the model for SESSION, or for the current conversation buffer."
  (interactive)
  (let* ((session (or session (harness-model--target-session)))
         (models (harness-model-search)))
    (unless session (user-error "No session to change"))
    (when (and (null models)
               (yes-or-no-p "No models configured. Ask providers for theirs? "))
      (harness-refresh-models)
      (setq models (harness-model-search)))
    (unless models (user-error "No models available; set `harness-models'"))
    (let* ((choices (mapcar (lambda (stats)
                              (cons (format "%s  %s"
                                            (harness-model-stats-id stats)
                                            (harness-model-stats-describe stats))
                                    stats))
                            models))
           (current (harness-session-model session))
           (default (car (cl-find-if (lambda (choice)
                                       (equal (harness-model-stats-id (cdr choice))
                                              current))
                                     choices)))
           (answer (completing-read
                    (format "Model for %s: " (harness-session-name session))
                    choices nil t nil nil default)))
      (when-let* ((stats (cdr (assoc answer choices))))
        (harness-session-set-model session (harness-model-stats-id stats))
        (harness-session-set-provider session (harness-model-stats-provider stats))
        (message "%s now uses %s" (harness-session-name session)
                 (harness-model-stats-describe stats))
        stats))))

(defun harness-model-describe-current (&optional session)
  "Return a one-line description of SESSION's model."
  (let* ((session (or session (and (fboundp 'harness-conversation-session)
                                   (harness-conversation-session))))
         (model (and session (harness-session-model session)))
         (provider (and session (harness-session-provider session))))
    (if (null model)
        "no model selected"
      (harness-model-stats-describe (harness-model-stats provider model)))))

(provide 'harness-ui-model)
;;; harness-ui-model.el ends here
