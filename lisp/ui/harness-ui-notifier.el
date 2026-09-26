;;; harness-ui-notifier.el --- Mode-line session indicator -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A small always-visible indicator of sessions that need the user:
;; blocked (waiting for a decision) first, then running, then idle with
;; unread output.  It listens to the harness' session status extension and
;; is clickable, opening the session list.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-ui)

(defgroup harness-ui-notifier nil
  "Session status indicator."
  :group 'harness-ui)

(defface harness-ui-notifier-blocked
  '((t :inherit error :weight bold))
  "Face for blocked sessions in the notifier.")

(defface harness-ui-notifier-running
  '((t :inherit success))
  "Face for running sessions in the notifier.")

(defface harness-ui-notifier-idle
  '((t :inherit shadow))
  "Face for idle sessions in the notifier.")

(defvar harness-ui-notifier--sessions (make-hash-table :test #'equal)
  "Session id -> status plist, per `harness-ui-session-status'.")

(defun harness-ui-notifier-counts ()
  "Return (BLOCKED RUNNING IDLE-UNREAD) counts."
  (let ((blocked 0) (running 0) (idle 0))
    (maphash (lambda (_id status)
               (pcase (plist-get status :status)
                 ("blocked" (cl-incf blocked))
                 ("running" (cl-incf running))
                 ("idle" (when (> (or (plist-get status :unread) 0) 0)
                           (cl-incf idle)))))
             harness-ui-notifier--sessions)
    (list blocked running idle)))

(defun harness-ui-notifier-string ()
  "Build the mode-line indicator string, or nil when nothing needs attention."
  (pcase-let ((`(,blocked ,running ,idle) (harness-ui-notifier-counts)))
    (when (> (+ blocked running idle) 0)
      (let ((map (make-sparse-keymap)))
        (define-key map [mode-line mouse-1]
                    (lambda (_event) (interactive) (harness-ui-sessions 'all)))
        (propertize
         (concat
          " "
          (string-join
           (delq nil
                 (list (when (> blocked 0)
                         (propertize (format "●%d" blocked)
                                     'face 'harness-ui-notifier-blocked
                                     'help-echo (format "%d session(s) need you" blocked)))
                       (when (> running 0)
                         (propertize (format "◐%d" running)
                                     'face 'harness-ui-notifier-running
                                     'help-echo (format "%d session(s) running" running)))
                       (when (> idle 0)
                         (propertize (format "○%d" idle)
                                     'face 'harness-ui-notifier-idle
                                     'help-echo (format "%d session(s) with unread output" idle)))))
           " "))
         'keymap map
         'mouse-face 'highlight)))))

(defun harness-ui-notifier--on-status (payload)
  "Record PAYLOAD's status and update the indicator."
  (let ((status (plist-get payload :status)))
    (puthash (plist-get status :sessionId) status harness-ui-notifier--sessions)
    (force-mode-line-update t)))

(defun harness-ui-notifier--on-sessions-changed (_payload)
  "Update the mode line when the session list changed."
  (force-mode-line-update t))

(define-minor-mode harness-ui-notifier-global-mode
  "Show how many harness sessions need attention in the mode line."
  :global t
  :group 'harness-ui-notifier
  (if harness-ui-notifier-global-mode
      (add-to-list 'global-mode-string '(:eval (harness-ui-notifier-string)) t)
    (setq global-mode-string
          (remove '(:eval (harness-ui-notifier-string)) global-mode-string)))
  (force-mode-line-update t))

(defun harness-ui-notifier-setup ()
  "Set up the notifier."
  (harness-on 'harness-ui-session-status #'harness-ui-notifier--on-status
              :module 'harness-ui-notifier)
  (harness-on 'harness-ui-sessions-changed #'harness-ui-notifier--on-sessions-changed
              :module 'harness-ui-notifier)
  (harness-ui-notifier-global-mode 1))

(defun harness-ui-notifier-teardown ()
  "Tear down the notifier."
  (harness-ui-notifier-global-mode -1)
  (clrhash harness-ui-notifier--sessions))

(harness-module-define 'harness-ui-notifier
  :version harness-version
  :description "Mode-line indicator for sessions that need the user."
  :requires '((harness-core "0.1.0")
              (harness-ui "0.1.0"))
  :provides '(harness-ui-notifier)
  :setup #'harness-ui-notifier-setup
  :teardown #'harness-ui-notifier-teardown)

(provide 'harness-ui-notifier)
;;; harness-ui-notifier.el ends here
