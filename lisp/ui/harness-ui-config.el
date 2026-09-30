;;; harness-ui-config.el --- Model, thinking and mode controls -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; Configuration controls implemented as ACP session config options:
;; the model switcher (searchable over every provider), the thinking
;; level, the permission mode and the session mode (plan/code).  Each
;; command changes the session and shows the harness' complete new state.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'harness-core)
(require 'harness-ui)

(defgroup harness-ui-config nil
  "Harness configuration."
  :group 'harness-ui)

(defun harness-ui-config--session ()
  "Return the session configuration commands should act on."
  (or (bound-and-true-p harness-ui-current-session)
      (user-error "No harness session here; open a chat buffer first")))

(defun harness-ui-config--options (session-id)
  "Return a deferred of SESSION-ID's config options."
  (harness-deferred-then
   (harness-ui-request "_harness/agent/configuration" (list :sessionId session-id))
   (lambda (result) (append (plist-get result :configOptions) nil))))

(defun harness-ui-config--option (session-id option-id)
  "Return a deferred of SESSION-ID's OPTION-ID."
  (harness-deferred-then
   (harness-ui-config--options session-id)
   (lambda (options)
     (or (seq-find (lambda (option) (equal (plist-get option :id) option-id)) options)
         (user-error "The harness offers no %s option" option-id)))))

(defun harness-ui-config-set-option (session-id option-id value)
  "Set OPTION-ID to VALUE on SESSION-ID and report the new state."
  (harness-deferred-then
   (harness-ui-request "session/set_config_option"
                       (list :sessionId session-id :configId option-id :value value))
   (lambda (_result)
     (harness-deferred-then
      (harness-ui-request "_harness/session/info" (list :sessionId session-id))
      (lambda (info)
        (message "%s is now %s"
                 option-id
                 (pcase option-id
                   ("model" (plist-get info :model))
                   ("thinking" (plist-get info :thinking))
                   ("permission" (plist-get info :permissionMode))
                   ("mode" (plist-get info :mode))
                   (_ value)))
        info)))))

(defun harness-ui-config--candidate-label (candidate)
  "Display label for one configuration value CANDIDATE."
  (or (plist-get candidate :name)
      (plist-get candidate :value)
      (format "%s" candidate)))

(defun harness-ui-config--choose (option)
  "Prompt for one of OPTION's values.
Returns the chosen value plist, or nil when the user quits.
Completion candidates are the values' names; each carries its
description as an annotation so the selector explains itself."
  (let* ((values (append (plist-get option :options) nil))
         (candidates (mapcar (lambda (candidate)
                               (cons (harness-ui-config--candidate-label candidate)
                                     candidate))
                             values))
         (descriptions (let ((table (make-hash-table :test #'equal)))
                         (dolist (candidate values)
                           (when-let* ((description (plist-get candidate :description)))
                             (puthash (harness-ui-config--candidate-label candidate)
                                      description table)))
                         table))
         (current (plist-get option :currentValue))
         (default (or (seq-find (lambda (candidate)
                                  (equal (plist-get candidate :value) current))
                                values)
                      (car values))))
    (cdr (assoc (completing-read
                 (format "%s: " (or (plist-get option :name) (plist-get option :id)))
                 (lambda (string predicate action)
                   (if (eq action 'metadata)
                       (list 'metadata
                             (cons 'category 'harness-config-value)
                             (cons 'annotation-function
                                   (lambda (candidate)
                                     (when-let* ((description (gethash candidate descriptions)))
                                       (concat "  " (propertize description
                                                                 'face 'completions-annotations))))))
                     (complete-with-action action candidates string predicate)))
                 nil t nil nil
                 (and default (harness-ui-config--candidate-label default)))
                candidates))))

(defun harness-ui-config--configure (option-id)
  "Prompt for and set OPTION-ID."
  (let* ((session-id (harness-ui-config--session)))
    (harness-deferred-then
     (harness-ui-config--option session-id option-id)
     (lambda (option)
       (when-let* ((choice (harness-ui-config--choose option)))
         (harness-ui-config-set-option session-id option-id
                                       (plist-get choice :value)))))))

;;;###autoload
(defun harness-ui-switch-model ()
  "Switch the current session's model."
  (interactive)
  (harness-ui-config--configure "model"))

;;;###autoload
(defun harness-ui-set-thinking ()
  "Set the current session's thinking level."
  (interactive)
  (harness-ui-config--configure "thinking"))

;;;###autoload
(defun harness-ui-set-permission-mode ()
  "Set the current session's permission mode."
  (interactive)
  (harness-ui-config--configure "permission"))

;;;###autoload
(defun harness-ui-set-session-mode ()
  "Set the current session's mode (plan or code)."
  (interactive)
  (harness-ui-config--configure "mode"))

(defun harness-ui-config-setup ()
  "Set up the configuration controls."
  nil)

(harness-module-define 'harness-ui-config
  :version harness-version
  :description "Model, thinking, permission and mode controls."
  :requires '((harness-core "0.1.0")
              (harness-ui "0.1.0"))
  :provides '(harness-ui-config)
  :setup #'harness-ui-config-setup)

(provide 'harness-ui-config)
;;; harness-ui-config.el ends here
