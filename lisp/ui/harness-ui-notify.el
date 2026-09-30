;;; harness-ui-notify.el --- Global session notifier in the mode line  -*- lexical-binding: t; -*-

;;; Commentary:

;; A small segment in every mode line (through `global-mode-string')
;; showing how many sessions need the user, are working, or are idle.
;; It is visible from any buffer as long as one session is active
;; anywhere in this Emacs, so a user hopping between projects sees
;; when they are needed.  Clicking it opens the session list, or jumps
;; straight to a blocked session when there is exactly one.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defgroup harness-ui-notify nil
  "Mode line notifier for sessions." :group 'harness-ui)

(defcustom harness-ui-notify-show-idle t
  "Whether idle sessions are counted in the notifier."
  :type 'boolean :group 'harness-ui-notify)

(defface harness-notify-blocked-face '((t :inherit (harness-status-blocked-face mode-line-emphasis)))
  "Blocked count in the mode line." :group 'harness-ui-notify)
(defface harness-notify-running-face '((t :inherit harness-status-running-face))
  "Running count in the mode line." :group 'harness-ui-notify)
(defface harness-notify-idle-face '((t :inherit harness-status-idle-face))
  "Idle count in the mode line." :group 'harness-ui-notify)
(defface harness-notify-flash-face '((t :inherit harness-notify-blocked-face :inverse-video t))
  "Brief highlight when a session becomes blocked." :group 'harness-ui-notify)

(defvar harness-ui-notify--string "" "Current mode line text.")
(defvar harness-ui-notify--last-blocked 0)
(defvar harness-ui-notify--flash-timer nil)
(defvar harness-ui-notify--flashing nil)

(defconst harness-ui-notify--construct '(:eval harness-ui-notify--string))

(defun harness-ui-notify--counts ()
  "Return (BLOCKED RUNNING IDLE) over active sessions."
  (let ((blocked 0) (running 0) (idle 0))
    (dolist (s (harness-ui-sessions))
      (pcase (plist-get s :status)
        ("blocked" (cl-incf blocked))
        ("running" (cl-incf running))
        ("idle" (cl-incf idle))))
    (list blocked running idle)))

(defun harness-ui-notify--jump-blocked ()
  "Open the single blocked session, or the session list."
  (interactive)
  (let ((blocked (harness-ui-sessions (lambda (s) (equal (plist-get s :status) "blocked")))))
    (cond ((and (= 1 (length blocked)) harness-ui-open-session-function)
           (harness-ui-display-session (plist-get (car blocked) :id)))
          ((fboundp 'harness-sessions) (call-interactively 'harness-sessions))
          (t (call-interactively #'harness-switch-session)))))

(defun harness-ui-notify--segment (count icon face help)
  (when (> count 0)
    (propertize (format " %s%d" (harness-ui-icon icon) count)
                'face (if (and harness-ui-notify--flashing (eq face 'harness-notify-blocked-face))
                          'harness-notify-flash-face face)
                'help-echo help
                'mouse-face 'mode-line-highlight
                'local-map (harness-ui-mouse-keymap #'harness-ui-notify--jump-blocked))))

(defun harness-ui-notify-refresh ()
  "Recompute the notifier text and redraw mode lines."
  (pcase-let ((`(,blocked ,running ,idle) (harness-ui-notify--counts)))
    (when (> blocked harness-ui-notify--last-blocked)
      (harness-ui-notify--flash))
    (setq harness-ui-notify--last-blocked blocked)
    (setq harness-ui-notify--string
          (if (and (zerop blocked) (zerop running) (or (zerop idle) (not harness-ui-notify-show-idle)))
              ""
            (concat
             (propertize " harness" 'face 'harness-dim-face
                         'help-echo "Agent harness sessions: click for the list"
                         'mouse-face 'mode-line-highlight
                         'local-map (harness-ui-mouse-keymap #'harness-ui-notify--jump-blocked))
             (harness-ui-notify--segment blocked 'harness-icon-blocked 'harness-notify-blocked-face
                                         "Sessions waiting for you (mouse-1: open)")
             (harness-ui-notify--segment running 'harness-icon-running 'harness-notify-running-face
                                         "Sessions working")
             (and harness-ui-notify-show-idle
                  (harness-ui-notify--segment idle 'harness-icon-idle 'harness-notify-idle-face
                                              "Idle sessions waiting for direction"))
             " ")))
    (force-mode-line-update t)))

(defun harness-ui-notify--flash ()
  (setq harness-ui-notify--flashing t)
  (when harness-ui-notify--flash-timer (cancel-timer harness-ui-notify--flash-timer))
  (setq harness-ui-notify--flash-timer
        (run-at-time 1.5 nil (lambda ()
                               (setq harness-ui-notify--flashing nil)
                               (harness-ui-notify-refresh)))))

(defun harness-ui-notify--on-sessions-changed ()
  (harness-debounce 'harness-ui-notify 0.1 #'harness-ui-notify-refresh))

;;;###autoload
(define-minor-mode harness-notify-mode
  "Show blocked, running and idle session counts in every mode line."
  :global t :group 'harness-ui-notify
  (if harness-notify-mode
      (progn
        (unless (member harness-ui-notify--construct global-mode-string)
          (setq global-mode-string
                (append (if (stringp global-mode-string) (list global-mode-string) global-mode-string)
                        (list harness-ui-notify--construct))))
        (add-hook 'harness-ui-sessions-changed-hook #'harness-ui-notify--on-sessions-changed)
        (harness-ui-notify-refresh))
    (setq global-mode-string (delete harness-ui-notify--construct global-mode-string))
    (remove-hook 'harness-ui-sessions-changed-hook #'harness-ui-notify--on-sessions-changed)
    (setq harness-ui-notify--string "")
    (force-mode-line-update t)))

(defun harness-ui-notify--init ()
  (harness-notify-mode 1))

(harness-define-module 'ui-notify
  :doc "Mode line notifier with blocked/running/idle counts."
  :requires '(ui)
  :init #'harness-ui-notify--init
  :shutdown (lambda () (harness-notify-mode -1)))

(provide 'harness-ui-notify)
;;; harness-ui-notify.el ends here
