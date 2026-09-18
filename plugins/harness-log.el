;;; harness-log.el --- Mirror the *Messages* log to a file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A harness *plugin*, not a harness module: it changes nothing in the
;; harness core.  It ships in the distribution's `plugins/' directory and is
;; loaded by default (`harness-bundled-plugins-directory'), which is the
;; point: the harness core stays small, and a feature that can be expressed
;; through the plugin API is distributed as a plugin.
;;
;; Why the *Messages* buffer and not advice on `message': Emacs reports
;; errors from process filters and sentinels from C, by calling `Fmessage'
;; directly, so Lisp advice on the `message' function never sees them, and
;; `debug-on-error' does not turn them into a backtrace either.  The one
;; place a swallowed filter error, a sentinel error, a timer error and an
;; ordinary `message' all meet is *Messages*, which is not readable from
;; outside Emacs.  This plugin copies it to a file.
;;
;; Two things never reach *Messages*: a failed request and an aborted run.
;; The agent puts those on the message and the UI renders them in the
;; transcript, so the plugin also listens on `harness-request-failed-hook'
;; and `harness-run-aborted-hook' and writes those lines itself.
;;
;; This is what the Elisp manual suggests: raise `message-log-max' so the
;; buffer is complete, then write it out to a log file.
;; See (elisp) Logging Messages in *Messages*.
;;
;; Loaded automatically by `harness-setup'.  `M-x harness-log-open' follows
;; the file, and `M-x harness-reload-plugins' reloads it after an edit.

;;; Code:

(require 'cl-lib)
(require 'harness)

;; Defined in C; the compiler does not know it, and a plain `defvar' here
;; would make `unload-feature' unbind it, which would be very rude.
(eval-when-compile (defvar unload-function-defs-list))

(defcustom harness-log-file
  (expand-file-name "agent-harness/harness.log" user-emacs-directory)
  "File this plugin appends the *Messages* log to.
Nil disables the plugin without unloading it."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'harness)

(defcustom harness-log-interval 1.0
  "Seconds between flushes of *Messages* to `harness-log-file'.
A repeating timer, so the flush never blocks a run and a hard crash costs at
most this many seconds of log."
  :type 'number
  :group 'harness)

(defcustom harness-log-rotate-size (* 4 1024 1024)
  "Rotate the log once it is larger than this many bytes.
Rotation renames the file to `harness-log-file.1', replacing any previous
one.  Nil never rotates."
  :type '(choice (const :tag "Never" nil) integer)
  :group 'harness)

(defvar harness-log--marker nil
  "Marker for how much of *Messages* has already been written.")

(defvar harness-log--timer nil
  "The repeating flush timer.")

(defun harness-log--rotate ()
  "Move the log aside when it has passed `harness-log-rotate-size'."
  (when (and harness-log-rotate-size
             (file-readable-p harness-log-file)
             (> (file-attribute-size (file-attributes harness-log-file))
                harness-log-rotate-size))
    (ignore-errors
      (rename-file harness-log-file (concat harness-log-file ".1") t))))

(defun harness-log--write (text)
  "Append TEXT to `harness-log-file', rotating first when it is due.
A logging failure must never break the run it is logging."
  (when (and harness-log-file text (not (string-empty-p text)))
    (let ((coding-system-for-write 'utf-8-unix)
          (write-region-inhibit-fsync t))
      (harness-log--rotate)
      (ignore-errors (write-region text nil harness-log-file t 'silent)))))

(defun harness-log--request-failed (session message)
  "Log the failed request for SESSION with MESSAGE.
This is the case `*Messages*` alone cannot see: a request error is put on
the message and rendered in the transcript, not passed to `message'."
  (harness-log--write
   (format "[error] harness request failed for %s: %s\n"
           (or (harness-session-name session) (harness-session-id session))
           (or (harness-message-error message) "unknown error"))))

(defun harness-log--run-aborted (session)
  "Log that SESSION's run was aborted."
  (harness-log--write
   (format "[abort] harness run aborted for %s\n"
           (or (harness-session-name session) (harness-session-id session)))))

(defun harness-log--flush ()
  "Append everything *Messages* has gained since the last flush."
  (when harness-log-file
    (with-current-buffer (messages-buffer)
      (save-restriction
        (widen)
        (let* ((previous (and harness-log--marker
                              (eq (marker-buffer harness-log--marker) (current-buffer))
                              (marker-position harness-log--marker)))
               (start (or previous (point-min))))
          (when (< start (point-max))
            (harness-log--write (buffer-substring-no-properties start (point-max)))
            (if (and harness-log--marker (markerp harness-log--marker))
                (set-marker harness-log--marker (point-max) (current-buffer))
              (setq harness-log--marker (copy-marker (point-max))))))))))

(defun harness-log-unload-function ()
  "Undo what loading this file did, before `unload-feature' undoes the rest.
Cancels the timer, and keeps the customization variables out of
`unload-function-defs-list' so a reload does not reset the user's settings."
  (when harness-log--timer
    (cancel-timer harness-log--timer)
    (setq harness-log--timer nil))
  (harness-log--flush)
  (remove-hook 'kill-emacs-hook #'harness-log--flush)
  (remove-hook 'harness-request-failed-hook #'harness-log--request-failed)
  (remove-hook 'harness-run-aborted-hook #'harness-log--run-aborted)
  (setq unload-function-defs-list
        (cl-remove-if (lambda (entry)
                        (memq (if (consp entry) (car entry) entry)
                              '(harness-log-file harness-log-interval
                                harness-log-rotate-size harness-log--marker
                                harness-log--timer)))
                      unload-function-defs-list))
  nil)

(defun harness-log-enable ()
  "Start mirroring the *Messages* buffer to `harness-log-file'."
  (interactive)
  ;; The manual's own recipe: keep the buffer complete, then persist it.
  (setq message-log-max t)
  (harness-log--flush)
  (when harness-log--timer (cancel-timer harness-log--timer))
  (setq harness-log--timer
        (run-with-timer harness-log-interval harness-log-interval
                        #'harness-log--flush))
  ;; A timer can be up to `harness-log-interval' behind when Emacs exits.
  (add-hook 'kill-emacs-hook #'harness-log--flush)
  ;; Request failures and aborts do not go through `message', so they need
  ;; their own path into the log.
  (add-hook 'harness-request-failed-hook #'harness-log--request-failed)
  (add-hook 'harness-run-aborted-hook #'harness-log--run-aborted)
  (when harness-log-file
    (message "harness-log: writing to %s" harness-log-file)))

(defun harness-log-disable ()
  "Stop mirroring the *Messages* buffer."
  (interactive)
  (when harness-log--timer
    (cancel-timer harness-log--timer)
    (setq harness-log--timer nil))
  (remove-hook 'kill-emacs-hook #'harness-log--flush)
  (remove-hook 'harness-request-failed-hook #'harness-log--request-failed)
  (remove-hook 'harness-run-aborted-hook #'harness-log--run-aborted)
  (harness-log--flush))

(defun harness-log-truncate ()
  "Empty `harness-log-file' and start the next flush from now."
  (interactive)
  (when harness-log-file
    (with-temp-file harness-log-file)
    (with-current-buffer (messages-buffer)
      (set-marker (or harness-log--marker (setq harness-log--marker (make-marker)))
                  (point-max)))))

(defun harness-log-open ()
  "Show the log file, following new lines as they are written."
  (interactive)
  (unless harness-log-file (user-error "harness-log is disabled"))
  (find-file-other-window harness-log-file)
  (auto-revert-tail-mode 1)
  (goto-char (point-max)))

(harness-log-enable)

(provide 'harness-log)
;;; harness-log.el ends here
