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

;; Development loads the checkout's source, never a stale `.elc' or
;; native-compiled `.eln' cache entry next to it.  Without this, `load'
;; prefers the compiled file even when the editable source is newer, and
;; edits appear to have no effect.
(setq load-prefer-newer t)

;; Background native compilation of the checkout's files keeps inline
;; expansions from older definitions alive, which surfaces as confusing
;; wrong-number-of-arguments errors while reloading.  The dev daemon runs
;; interpreted source on purpose.
(setq native-comp-jit-compilation nil
      native-comp-deferred-compilation nil)

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
  "Load the harness entry point and start it."
  (interactive)
  (harness-dev-add-load-path)
  (let ((entry (expand-file-name "harness.el" harness-dev--repo)))
    (if (file-exists-p entry)
        (progn
          (load entry nil nil 'nomessage)
          (when (fboundp 'harness-start)
            (harness-start)))
      (message "harness-dev: no harness.el in %s yet" harness-dev--repo))))

;;; Frames and screenshots
;;
;; Automation must never steal the user's focus.  The harness frame is
;; created with `no-focus-on-map' and `skip-taskbar' and lowered; the
;; helpers below select it only inside Emacs, so captures and synthetic
;; keys work while the user keeps typing in their own window.
;; `harness-dev-focus' is the explicit, human-facing way to raise it.

(defun harness-dev-frame ()
  "Return a harness GUI frame, creating one if needed.
A new frame does not take focus when it appears and is lowered, so
automation never interrupts the user or sits in front of their work.
The frame is selected inside Emacs (not focused), so server evals and
asynchronous callbacks display buffers in it."
  (let ((frame (or (seq-find (lambda (frame) (memq (framep frame) '(x pgtk)))
                             (frame-list))
                   ;; A daemon has no graphical selected frame, so
                   ;; `make-frame' would try the terminal it was started
                   ;; from; name the display instead.
                   (let* ((display (if (featurep 'pgtk)
                                       (getenv "WAYLAND_DISPLAY")
                                     (getenv "DISPLAY")))
                          (parameters '((name . "harness")
                                        (width . 180)
                                        (height . 50)
                                        (no-focus-on-map . t)
                                        (skip-taskbar . t)))
                          (frame (if display
                                     (make-frame-on-display display parameters)
                                   (make-frame parameters))))
                     (lower-frame frame)
                     frame))))
    (unless (eq frame (selected-frame))
      (select-frame frame))
    frame))

(defun harness-dev-focus ()
  "Raise and focus the harness GUI frame.
This is for humans; automation uses `harness-dev-frame', which never
steals focus."
  (interactive)
  (let ((frame (harness-dev-frame)))
    (x-focus-frame frame)
    (select-frame-set-input-focus frame)
    frame))

(defun harness-dev-window-id ()
  "Return the X window id of the harness GUI frame."
  (interactive)
  (let* ((frame (harness-dev-frame))
         (id (frame-parameter frame 'window-id)))
    (format "0x%x" (if (integerp id) id (string-to-number id)))))

(defun harness-dev--kbd (keys)
  "Turn KEYS into a key sequence.
A single character is taken literally (so " " is the space key, which
`kbd' would drop); anything longer is read like `kbd'."
  (if (= (length keys) 1)
      (string-to-vector keys)
    (kbd keys)))

(defun harness-dev-keys (keys &optional buffer)
  "Send KEYS (a `kbd' string) to the harness frame.
With BUFFER, select that buffer in the frame first.  Keyboard macros
run inside Emacs, so the frame is not focused and the user's typing is
not interrupted."
  (interactive "sKeys: ")
  (let* ((frame (harness-dev-frame))
         (window (frame-selected-window frame)))
    (with-selected-frame frame
      (with-selected-window window
        (when buffer
          (set-window-buffer window (get-buffer buffer)))
        (execute-kbd-macro (harness-dev--kbd keys) 1)))))

(defun harness-dev-click (pos)
  "Click `mouse-1' at POS.
POS is a position list as returned by `event-start', e.g. from
`(posn-at-point)'.  No pointer motion and no focus change."
  (interactive (list (posn-at-point)))
  (let ((frame (harness-dev-frame)))
    (with-selected-frame frame
      (with-selected-window (frame-selected-window frame)
        (mouse-set-point (event-start (list 'mouse-1 pos)))))))

;;; Error capture

(defun harness-dev-log-backtrace (&rest _args)
  "Record the current backtrace without opening the debugger.
A blocking debugger would freeze the daemon; autonomous work needs the
error captured and the session alive."
  (ignore-errors
    (with-temp-file (expand-file-name "scripts/.dev/last-error.txt" harness-dev--repo)
      (let ((standard-output (current-buffer)))
        (backtrace)))))

(defun harness-dev-toggle-debug (&optional on)
  "Turn `debug-on-error' ON (or off when nil).
Errors are logged to scripts/.dev/last-error.txt instead of opening the
blocking debugger, so the daemon keeps serving requests."
  (interactive "p")
  (setq debug-on-error (if on (> on 0) (not debug-on-error)))
  (when debug-on-error
    (setq debugger #'harness-dev-log-backtrace))
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

;;; Recording

(defun harness-dev-export-frame (file)
  "Write the harness frame as a PNG to FILE and return it.
The echo area is cleared first, so captures do not carry stale
messages.  The frame is not focused or raised."
  (interactive "FWrite frame to: ")
  (let ((frame (harness-dev-frame)))
    (with-selected-frame frame
      (message " ")
      (let ((data (x-export-frames frame 'png)))
        (unless (stringp data)
          (error "harness-dev: this frame cannot be exported (no GUI?)"))
        (with-temp-file file
          (set-buffer-multibyte nil)
          (insert data))
        file))))

(defvar harness-dev--recording nil
  "Active recording state, or nil.
A plist with :frame, :directory, :interval, :index and :timer.")

(defun harness-dev--record-frame (recording)
  "Write one frame for RECORDING and schedule the next."
  (let ((file (format "%s/frame-%05d.png"
                      (plist-get recording :directory)
                      (plist-get recording :index)))
        (frame (plist-get recording :frame))
        (data nil))
    (cl-incf (plist-get recording :index))
    ;; `x-export-frames' returns what was last drawn; without a forced
    ;; redisplay every frame would be the first one.
    (with-selected-frame frame
      (redisplay t)
      (setq data (ignore-errors (x-export-frames frame 'png))))
    (when (and data (stringp data))
      (with-temp-file file
        (set-buffer-multibyte nil)
        (insert data)))
    (when (eq recording harness-dev--recording)
      (setf (plist-get recording :timer)
            (run-at-time (plist-get recording :interval) nil
                         #'harness-dev--record-frame recording)))))

(defun harness-dev-record-start (directory &optional interval)
  "Record the harness frame into PNG files in DIRECTORY.
INTERVAL is the delay between frames in seconds (default 0.05, 20 fps).
Stop with `harness-dev-record-stop' and assemble the frames with e.g.
ffmpeg -framerate 20 -i frame-%05d.png -c:v libx264 demo.mp4."
  (interactive "DRecord into directory: ")
  (harness-dev-record-stop)
  (make-directory directory t)
  (let ((frame (harness-dev-frame)))
    (with-selected-frame frame (message " "))
    (setq harness-dev--recording
          (list :frame frame
                :directory (expand-file-name directory)
                :interval (or interval 0.05)
                :index 0
                :timer nil)))
  (harness-dev--record-frame harness-dev--recording)
  (plist-get harness-dev--recording :index))

(defun harness-dev-record-stop ()
  "Stop the recording started by `harness-dev-record-start'.
Returns the number of frames written."
  (interactive)
  (let ((recording harness-dev--recording))
    (setq harness-dev--recording nil)
    (when (and recording (plist-get recording :timer))
      (cancel-timer (plist-get recording :timer)))
    (or (and recording (plist-get recording :index)) 0)))

(provide 'harness-dev)
;;; harness-dev.el ends here
