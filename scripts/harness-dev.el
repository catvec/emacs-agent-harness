;;; harness-dev.el --- Live development harness for the harness  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by scripts/dev.sh into a dedicated `emacs -Q' daemon.  It
;; loads the checkout, starts the harness, turns on auto reload, and
;; provides the functions the dev loop drives over emacsclient: opening
;; a frame that never steals focus, sending real key sequences,
;; exporting screenshots, and collecting errors.

;;; Code:

(setq ring-bell-function #'ignore
      visible-bell nil
      load-prefer-newer t
      native-comp-jit-compilation nil
      inhibit-startup-screen t
      confirm-kill-processes nil
      debug-on-error nil
      frame-inhibit-implied-resize t)

(defvar harness-dev-root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

(defvar harness-dev-frame nil)

(defun harness-dev-load ()
  "Load the checkout and start the harness."
  (add-to-list 'load-path harness-dev-root)
  (setq harness-state-directory
        (file-name-as-directory
         (or (getenv "HARNESS_DEV_STATE")
             (expand-file-name "scripts/.dev/state/" harness-dev-root))))
  (require 'harness)
  (harness-start)
  (harness-auto-reload-mode 1))

(defun harness-dev-frame ()
  "Return the dev frame, creating a GUI frame that does not take focus."
  (unless (and harness-dev-frame (frame-live-p harness-dev-frame))
    (setq harness-dev-frame
          (make-frame `((window-system . x)
                        (display . ,(or (getenv "DISPLAY") ":0"))
                        (name . "harness-dev")
                        (width . 140) (height . 46)
                        (no-focus-on-map . t)
                        (no-accept-focus . nil)
                        (minibuffer . t))))
    (with-selected-frame harness-dev-frame
      (lower-frame harness-dev-frame)
      (switch-to-buffer "*scratch*")))
  harness-dev-frame)

(defun harness-dev-focus ()
  "Raise and focus the dev frame deliberately."
  (interactive)
  (let ((f (harness-dev-frame)))
    (raise-frame f) (select-frame-set-input-focus f)))

(defun harness-dev-keys (keys)
  "Run KEYS (a `kbd' string) as a real key sequence in the dev frame."
  (let ((frame (harness-dev-frame)))
    (with-selected-frame frame
      (with-selected-window (frame-selected-window frame)
        (let ((inhibit-quit nil))
          (execute-kbd-macro (kbd keys)))
        (redisplay t)
        (format "%s in %s" keys (buffer-name))))))

(defun harness-dev-shot (path)
  "Export the dev frame as a PNG to PATH and return PATH."
  (let ((frame (harness-dev-frame)))
    (with-selected-frame frame (redisplay t))
    (let ((data (x-export-frames frame 'png))
          (coding-system-for-write 'binary))
      (with-temp-file path (set-buffer-multibyte nil) (insert data)))
    path))

(defun harness-dev-errors (&optional n)
  "Return the last N lines of *Messages* and the harness log errors."
  (let ((n (or n 40)))
    (concat
     "== *Messages* ==\n"
     (with-current-buffer (messages-buffer)
       (save-excursion
         (goto-char (point-max))
         (forward-line (- n))
         (buffer-substring-no-properties (point) (point-max))))
     "\n== harness log (warn+) ==\n"
     (if (get-buffer "*harness-log*")
         (with-current-buffer "*harness-log*"
           (let ((lines (split-string (buffer-string) "\n" t)))
             (string-join (last (cl-remove-if-not (lambda (l) (string-match-p " \\(WARN\\|ERROR\\) " l)) lines) n) "\n")))
       "(no log buffer)"))))

(defun harness-dev-show (buffer-name)
  "Display BUFFER-NAME in the dev frame's selected window."
  (with-selected-frame (harness-dev-frame)
    (switch-to-buffer buffer-name)
    (redisplay t)
    (buffer-name)))

(harness-dev-load)

(provide 'harness-dev)
;;; harness-dev.el ends here
