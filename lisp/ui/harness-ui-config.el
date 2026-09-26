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

(defun harness-ui-config--choose (option)
  "Prompt for one of OPTION's values, searchable."
  (let* ((values (append (plist-get option :options) nil))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (category . harness-config-value))
                    (complete-with-action action values string predicate))))
         (current (plist-get option :currentValue))
         (default (or (seq-find (lambda (value)
                                  (equal (plist-get value :value) current))
                                values)
                      (car values))))
    (completing-read
     (format "%s: " (or (plist-get option :name) (plist-get option :id)))
     table nil t nil nil
     (plist-get default :name)
     nil)))

(defun harness-ui-config--configure (option-id)
  "Prompt for and set OPTION-ID."
  (let* ((session-id (harness-ui-config--session)))
    (harness-deferred-then
     (harness-ui-config--option session-id option-id)
     (lambda (option)
       (let* ((values (append (plist-get option :options) nil))
              (choice (harness-ui-config--choose option))
              (value (or (seq-find (lambda (candidate)
                                     (equal (plist-get candidate :name) choice))
                                   values)
                         (seq-find (lambda (candidate)
                                     (equal (plist-get candidate :value) choice))
                                   values))))
         (when value
           (harness-ui-config-set-option session-id option-id
                                         (plist-get value :value))))))))

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
