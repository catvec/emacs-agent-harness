;;; harness-dev.el --- Development helpers for driving a live harness -*- lexical-binding: t; -*-

;; This file is loaded by the `harness-dev' daemon started from
;; scripts/dev.sh.  It gives the agent (and humans) a stable handle on the
;; live Emacs instance:
;;
;;   - a real GUI frame to look at and screenshot,
;;   - `harness-dev-keys' to drive it with real keyboard input,
;;   - `harness-dev-load' to (re)load the harness from disk,
;;   - error capture into *Messages* and a log file.
;;
;; It is development tooling, not part of the harness.

;; Automation drives this Emacs with synthetic keys; an unbound key would
;; ring the bell at the human.  Never make noise in the dev daemon.
(setq ring-bell-function #'ignore)

;;; Code:

(require 'subr-x)
(require 'seq)

(defvar harness-dev--repo
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root of the harness checkout being developed.")

(defvar harness-dev-log-file
  (expand-file-name "scripts/.dev/emacs.log" harness-dev--repo))

(defun harness-dev-add-load-path ()
  "Put the checkout's lisp directories on `load-path'."
  (interactive)
  (dolist (dir (list "" "lisp" "lisp/modules" "lisp/tools" "lisp/transports" "lisp/ui"))
    (let ((full (expand-file-name dir harness-dev--repo)))
      (when (file-directory-p full)
        (add-to-list 'load-path full)))))

(defun harness-dev-load ()
  "Load (or reload) the harness entry point from the checkout."
  (interactive)
  (harness-dev-add-load-path)
  (let ((entry (expand-file-name "harness.el" harness-dev--repo)))
    (if (file-exists-p entry)
        (load entry nil nil 'nomessage)
      (message "harness-dev: no harness.el in %s yet" harness-dev--repo))))

;;; Frames and screenshots

(defun harness-dev-frame ()
  "Return a GUI frame for the harness, creating one if needed."
  (or (seq-find (lambda (f) (memq (framep f) '(x pgtk)))
                (frame-list))
      (make-frame '((name . "harness")
                    (width . 180)
                    (height . 50)))))

(defun harness-dev-focus ()
  "Focus the harness GUI frame."
  (interactive)
  (let ((frame (harness-dev-frame)))
    (x-focus-frame frame)
    (select-frame-set-input-focus frame)
    frame))

(defun harness-dev-window-id ()
  "Return the X window id of the harness GUI frame."
  (interactive)
  (let* ((frame (harness-dev-focus))
         (id (frame-parameter frame 'window-id)))
    (format "0x%x" (if (integerp id) id (string-to-number id)))))

(defun harness-dev-keys (keys &optional buffer)
  "Send KEYS (a `kbd' string) to the harness frame.
With BUFFER, select that buffer in the frame first."
  (interactive "sKeys: ")
  (let* ((frame (harness-dev-focus))
         (window (frame-selected-window frame)))
    (with-selected-window window
      (when buffer
        (set-window-buffer window (get-buffer buffer)))
      (execute-kbd-macro (kbd keys) 1))))

(defun harness-dev-click (pos)
  "Click `mouse-1' at POS.
POS is a position list as returned by `event-start', e.g. from
`(posn-at-point)'."
  (interactive (list (posn-at-point)))
  (let ((frame (harness-dev-focus)))
    (with-selected-window (frame-selected-window frame)
      (mouse-set-point (event-start (list 'mouse-1 pos))))))

;;; Error capture

(defun harness-dev-toggle-debug (&optional on)
  "Turn `debug-on-error' ON (or off when nil)."
  (interactive "p")
  (setq debug-on-error (if on (> on 0) (not debug-on-error)))
  debug-on-error)

(defun harness-dev-load-safely ()
  "Like `harness-dev-load' but report errors without killing the daemon."
  (interactive)
  (condition-case err
      (harness-dev-load)
    (error (message "harness-dev: load failed: %S" err))))

(defun harness-dev-errors ()
  "Return the tail of *Messages* and recent warnings."
  (interactive)
  (with-current-buffer (get-buffer-create "*Messages*")
    (buffer-substring-no-properties
     (max (point-min) (- (point-max) 4000))
     (point-max))))

(provide 'harness-dev)
;;; harness-dev.el ends here
