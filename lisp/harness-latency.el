;;; harness-latency.el --- Bounded, content-free latency evidence -*- lexical-binding: t; -*-

;;; Commentary:

;; Slow completions identify a boundary, not the instruction that blocked.
;; A one-second watchdog also samples the actual stack when a slow boundary
;; yields (e.g. in process-send-string).  CPU-bound Lisp cannot be sampled by
;; a Lisp timer: its completion and the subsequent event-loop gap say so,
;; rather than pretending that the timer caught its inner stack.  Automatic
;; redisplay has no after hook; its gap is deliberately labelled separately
;; from an explicit redisplay or layout measurement.
;;
;; Records contain function names and timing/GC counters only, never arguments,
;; buffers, paths, RPC bodies or user text.  A bounded queue is flushed once a
;; second to a small rotating file, without harness-log or its ACP forwarding.

;;; Code:

(require 'cl-lib)
(require 'harness-core)

(defvar harness-state-directory)

(defcustom harness-latency-enabled t
  "Non-nil records slow harness boundaries and event-loop gaps.
Records are content-free metadata in latency-PID.log under
`harness-state-directory', with one previous file (.1).  See
`harness-latency-install' and `harness-latency-uninstall'."
  :type 'boolean :group 'harness)

(defcustom harness-latency-threshold 0.25
  "Seconds past which a harness boundary gets a latency record.
This is an observation threshold, not a timeout or a performance promise."
  :type 'number :group 'harness)

(defconst harness-latency--capacity 64 "Most unflushed latency records.")
(defconst harness-latency--max-bytes (* 256 1024) "Maximum file size before rotation.")
(defconst harness-latency--interval 1 "Seconds between watchdog ticks and flushes.")

(defvar harness-latency--installed nil)
(defvar harness-latency--timer nil)
(defvar harness-latency--records nil)
(defvar harness-latency--dropped 0)
(defvar harness-latency--active nil "Dynamic stack of active boundary records.")
(defvar harness-latency--busy nil "Non-nil inside the recorder itself.")
(defvar harness-latency--last-tick nil)
(defvar harness-latency--redisplay nil)
(defvar harness-latency--gc-elapsed 0)
(defvar harness-latency--tick-gc 0)
(defvar harness-latency--tick-gcs 0)
(defvar harness-latency--advices nil)
(defvar harness-latency--syncing nil "Non-nil while advice installation loads libraries.")
(defvar harness-latency--extra-targets nil "Timing boundaries registered by their owning modules.")

(defconst harness-latency--targets
  '((harness-log . log)
    (harness-server--log-line . rpc-filter)
    (harness-acp--server-filter . rpc-filter)
    (harness-acp--conn-filter . rpc-filter)
    (harness-acp--poll . rpc-poll)
    (harness-acp--drain . rpc-slice)
    (harness-acp--conn-receive . rpc-handler)
    (harness-acp--conn-dispatch . rpc-handler)
    (harness--promise-dispatch . promise)
    (harness-ui--dispatch . ui-handler)
    (harness-chat--on-update . ui-handler)
    (harness-chat--on-event . ui-handler)
    (harness-chat--render-nodes . render)
    (harness-chat--render-block . render)
    (harness-chat--render-tail . render)
    (harness-chat--render-due . render)
    (harness-chat--pin-waiting . layout)
    (harness-ui-markdown-render . render)
    (harness-ui-tasks--render . render)
    (harness-ui-sessions--print . render)
    (harness-chat--header . render)
    (harness-snapshot-slice . snapshot)
    (harness-ui-text-height . layout)
    (harness-compose--follow . layout)
    (harness-compose-pad-window . layout))
  "Named boundaries timed without retaining their arguments.")

(defun harness-latency--name (function)
  "Return a bounded name for FUNCTION without printing a closure's contents."
  (if (symbolp function)
      (let ((name (symbol-name function)))
        (if (> (length name) 160) (substring name 0 160) name))
    "anonymous"))

(defun harness-latency--stack ()
  "Return at most 32 function names on the current stack, with no arguments."
  (let (frames)
    (catch 'full
      (mapbacktrace
       (lambda (_evaluated function _args _flags)
         (push (harness-latency--name function) frames)
         (when (>= (length frames) 32) (throw 'full nil)))))
    (nreverse frames)))

(defun harness-latency--record (record)
  "Queue RECORD without logging, recursion or an unbounded backlog."
  (condition-case nil
      (let ((harness-latency--busy t))
        (push (append (list :at (float-time) :pid (emacs-pid)) record)
              harness-latency--records)
        (when (> (length harness-latency--records) harness-latency--capacity)
          (setcdr (nthcdr (1- harness-latency--capacity) harness-latency--records) nil)
          (cl-incf harness-latency--dropped)))
    (error nil)))

(defun harness-latency-call (category name function &rest args)
  "Call FUNCTION with ARGS, timing CATEGORY and NAME when installed.
Return its value and preserve its non-local exits.  NAME is a function
symbol or an anonymous closure; no argument or return value is kept."
  (if (or (not harness-latency-enabled) (not harness-latency--installed)
          harness-latency--busy (not (eq (current-thread) main-thread)))
      (apply function args)
    (let* ((start (float-time))
           (gc-start gc-elapsed)
           (gcs-start gcs-done)
           ;; Small fixed-size scope; avoid copying the function name or
           ;; allocating a plist on every fast call in a busy UI.
           (scope (vector category (harness-latency--name name) start))
           (harness-latency--active (cons scope harness-latency--active)))
      (unwind-protect (apply function args)
        (ignore-errors
          (let ((harness-latency--busy t)
                (seconds (- (float-time) start)))
            (when (>= seconds harness-latency-threshold)
              (harness-latency--record
               (list :kind 'completed :category category
                     :operation (aref scope 1) :seconds seconds
                     :gc-seconds (- gc-elapsed gc-start) :gcs (- gcs-done gcs-start)
                     :stack (harness-latency--stack))))))))))

(defun harness-latency-redisplay (&optional force)
  "Redisplay with FORCE, recording the explicit display cost.
Keep the display primitive unadvised: no native-trampoline loading in
the frame/display path.  Automatic redisplay is observed separately
through the watchdog's redisplay gap."
  (harness-latency-call 'redisplay 'redisplay #'redisplay force))

(defun harness-latency--advise (symbol category function &rest args)
  "Time FUNCTION with ARGS as SYMBOL in CATEGORY."
  (apply #'harness-latency-call category symbol function args))

(defun harness-latency-register-target (symbol category)
  "Register SYMBOL as a timing boundary in CATEGORY, owned by its module.
Optional modules register their own entry points rather than making
the recorder depend on their names or implementation."
  (setf (alist-get symbol harness-latency--extra-targets) category)
  (harness-latency--sync))

(defun harness-latency--sync (&rest _ignored)
  "Instrument named boundaries that have been loaded, once each."
  (when (and harness-latency--installed (not harness-latency--syncing))
    (let ((harness-latency--syncing t)
          (harness-latency--busy t))
      (dolist (target (append harness-latency--targets harness-latency--extra-targets))
        (when (fboundp (car target))
          (let ((advice (or (alist-get (car target) harness-latency--advices)
                            (setf (alist-get (car target) harness-latency--advices)
                                  (apply-partially #'harness-latency--advise
                                                   (car target) (cdr target))))))
            (unless (advice-member-p advice (car target))
              (advice-add (car target) :around advice))))))))

(defun harness-latency--before-redisplay (&rest _windows)
  "Remember the start of automatic redisplay, without treating a gap as its cost."
  (when (and harness-latency-enabled (not harness-latency--busy))
    (setq harness-latency--redisplay (float-time))))

(defun harness-latency--after-gc ()
  "Record a slow collection, including the stack that triggered it."
  (ignore-errors
    (let ((seconds (- gc-elapsed harness-latency--gc-elapsed)))
      (setq harness-latency--gc-elapsed gc-elapsed)
      (when (and harness-latency-enabled (not harness-latency--busy)
                 (eq (current-thread) main-thread)
                 (>= seconds harness-latency-threshold))
        (let ((harness-latency--busy t))
          (harness-latency--record
           (list :kind 'gc :seconds seconds :gcs gcs-done
                 :stack (harness-latency--stack))))))))

(defun harness-latency-file ()
  "Return this Emacs's latency file, or nil without a local state directory."
  (when (and (boundp 'harness-state-directory) (stringp harness-state-directory)
             (not (file-remote-p harness-state-directory)))
    (expand-file-name (format "latency-%d.log" (emacs-pid)) harness-state-directory)))

(defun harness-latency-flush ()
  "Flush the bounded queue to this Emacs's rotating local file.
Never signal or log a write failure.  Failed writes keep the bounded
queue for the next tick; they never forward diagnostics over ACP."
  (when (and harness-latency--records (not harness-latency--busy))
    (let ((harness-latency--busy t))
      (condition-case nil
          (when-let* ((file (harness-latency-file)))
            (let* ((records (reverse harness-latency--records))
                   (print-length 100) (print-level 8)
                   (text (concat (and (> harness-latency--dropped 0)
                                      (format "(:kind dropped :count %d)\n" harness-latency--dropped))
                                 (mapconcat #'prin1-to-string records "\n") "\n"))
                   (coding-system-for-write 'utf-8-unix)
                   (write-region-inhibit-fsync t))
              (make-directory (file-name-directory file) t)
              (when (> (+ (or (file-attribute-size (file-attributes file)) 0)
                          (string-bytes text)) harness-latency--max-bytes)
                (when (file-exists-p file) (rename-file file (concat file ".1") t)))
              (write-region text nil file t 'silent)
              (set-file-modes file #o600)
              (setq harness-latency--records nil harness-latency--dropped 0)))
        (error nil)))))

(defun harness-latency--tick ()
  "Observe loop gaps and yielding slow boundaries, then flush diagnostics."
  (unless harness-latency--busy
    (ignore-errors
      (let ((now (float-time))
            (gc-seconds (- gc-elapsed harness-latency--tick-gc))
            (gcs (- gcs-done harness-latency--tick-gcs)))
        (let ((harness-latency--busy t))
          (when harness-latency-enabled
            (when (and harness-latency--last-tick
                       (> (- now harness-latency--last-tick) (* 2 harness-latency--interval)))
              (harness-latency--record
               (list :kind 'loop-gap :seconds (- now harness-latency--last-tick)
                     :gc-seconds gc-seconds :gcs gcs
                     :since-redisplay (and harness-latency--redisplay
                                          (- now harness-latency--redisplay))
                     :stack (harness-latency--stack))))
            (when (>= gc-seconds harness-latency-threshold)
              (harness-latency--record
               (list :kind 'gc-window :seconds gc-seconds :gcs gcs)))
            (when-let* ((scope (car harness-latency--active)))
              (when (>= (- now (aref scope 2)) harness-latency-threshold)
                (harness-latency--record
                 (list :kind 'sample :category (aref scope 0)
                       :operation (aref scope 1)
                       :seconds (- now (aref scope 2))
                       :stack (harness-latency--stack)))))))
        (setq harness-latency--last-tick now
              harness-latency--tick-gc gc-elapsed harness-latency--tick-gcs gcs-done)
        (harness-latency-flush)))))

(defun harness-latency-install ()
  "Install lightweight boundary timing and the latency watchdog, once.
CPU-bound work is identified on completion, not preempted.  A gap
without a named boundary remains unassigned; wall time also includes
host scheduling, suspension and other packages in the same Emacs."
  (when (and harness-latency-enabled (not harness-latency--installed))
    (setq harness-latency--installed t
          harness-latency--last-tick (float-time)
          harness-latency--gc-elapsed gc-elapsed
          harness-latency--tick-gc gc-elapsed harness-latency--tick-gcs gcs-done)
    (add-hook 'after-load-functions #'harness-latency--sync)
    (add-hook 'post-gc-hook #'harness-latency--after-gc)
    (add-hook 'kill-emacs-hook #'harness-latency-flush)
    (add-hook 'pre-redisplay-functions #'harness-latency--before-redisplay)
    (harness-latency--sync)
    (setq harness-latency--timer
          (run-at-time harness-latency--interval harness-latency--interval
                       #'harness-latency--tick))))

(defun harness-latency-uninstall ()
  "Remove this recorder's timer, hooks and advice, and flush its last records."
  (when (timerp harness-latency--timer) (cancel-timer harness-latency--timer))
  (setq harness-latency--timer nil harness-latency--installed nil)
  (remove-hook 'after-load-functions #'harness-latency--sync)
  (remove-hook 'post-gc-hook #'harness-latency--after-gc)
  (remove-hook 'kill-emacs-hook #'harness-latency-flush)
  (remove-hook 'pre-redisplay-functions #'harness-latency--before-redisplay)
  (dolist (entry harness-latency--advices) (advice-remove (car entry) (cdr entry)))
  (harness-latency-flush))

(provide 'harness-latency)
;;; harness-latency.el ends here
