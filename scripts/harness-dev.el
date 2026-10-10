;;; harness-dev.el --- Live development harness for the harness  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by scripts/dev.sh into a dedicated `emacs -Q' daemon.  It
;; loads the checkout, starts the harness, turns on auto reload, and
;; provides the functions the dev loop drives over emacsclient: opening
;; a frame that never steals focus, sending real key sequences,
;; exporting screenshots, and collecting errors.
;;
;; A daemon the harness opened (the `open_harness' tool, the board's
;; Open harness) has HARNESS_DEV_OWNER set to the harness process that
;; opened it.  The daemon exits once that process is gone, so a harness
;; that quits or crashes leaves no Emacs behind.  One started by hand
;; has no owner and runs until it is stopped.

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

(defvar harness-dev-owner nil
  "The harness process that opened this daemon, as (PID . START), or nil.
From HARNESS_DEV_OWNER.  START is when that process started, in
seconds, so that a process that gets the same PID later does not pass
for it.")

(defvar harness-dev-owner-interval 10
  "Seconds between two checks that the owner still runs.")

(defvar harness-tasks-store-in-repository)

(defun harness-dev--process-start (pid)
  "Return when process PID started, in seconds since the epoch, or nil."
  (let* ((default-directory "/")
         (start (alist-get 'start (ignore-errors (process-attributes pid)))))
    (and start (float-time start))))

(defun harness-dev-owner-alive-p ()
  "Non-nil while the harness process that opened this daemon runs."
  (let ((pid (car harness-dev-owner))
        (start (cdr harness-dev-owner)))
    (and (condition-case nil (eq 0 (signal-process pid 0)) (error nil))
         ;; The start time is computed from the uptime, so two readings
         ;; of the same process differ by a little.
         (let ((now (and start (harness-dev--process-start pid))))
           (or (null start) (null now) (< (abs (- now start)) 2))))))

(defun harness-dev-watch-owner ()
  "Exit once the harness process named by HARNESS_DEV_OWNER is gone.
Nothing else would stop a daemon whose harness quit or crashed.
Without HARNESS_DEV_OWNER, as when started by hand, do nothing."
  (let ((owner (getenv "HARNESS_DEV_OWNER")))
    (when (and owner (string-match-p "\\`[0-9]+\\'" owner))
      (let ((pid (string-to-number owner)))
        (setq harness-dev-owner (cons pid (harness-dev--process-start pid)))
        (run-with-timer harness-dev-owner-interval harness-dev-owner-interval
                        (lambda ()
                          (unless (harness-dev-owner-alive-p)
                            (kill-emacs))))))))

(defun harness-dev-load ()
  "Load the checkout and start the harness."
  (add-to-list 'load-path harness-dev-root)
  (setq harness-state-directory
        (file-name-as-directory
         (or (getenv "HARNESS_DEV_STATE")
             (expand-file-name "scripts/.dev/state/" harness-dev-root))))
  ;; Its tasks stay in that state directory too: the daemon never writes
  ;; into a repository's .git, where the real harness keeps its task
  ;; boards.  Set it to t to try repository stores, in a scratch repository.
  (setq harness-tasks-store-in-repository nil)
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

;; Watch the owner first: should loading the harness fail, the daemon
;; still goes once its owner does.
(harness-dev-watch-owner)
(harness-dev-load)

(provide 'harness-dev)
;;; harness-dev.el ends here
