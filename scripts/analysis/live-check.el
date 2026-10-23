;;; live-check.el --- the session list, hidden and shown, in a live GUI Emacs  -*- lexical-binding: t; -*-

;; Load in the dev harness (open_harness, then
;;   scripts/dev.sh eval '(progn (setenv "LIVE_ROOT" "/path/to/checkout/")
;;                              (load-file "scripts/analysis/live-check.el")
;;                              (live-run) :started)'
;; ); it runs in phases on timers, with real redisplay in the GUI frame (the
;; daemon's own frame, F1, never redisplays), and writes
;; scripts/.dev/live-check-results.txt.  Session churn is injected into the
;; UI's cache as the harness's notifications would: updates, live token
;; counts and the harness's own internal sessions.

(require 'cl-lib)
(require 'harness-ui)
(require 'harness-ui-sessions)

(defvar live-out (expand-file-name "scripts/.dev/live-check-results.txt" (getenv "LIVE_ROOT")))
(defvar live-n 942)
(defvar live-seconds 12)
(defvar live--lines nil)
(defvar live--timers nil)
(defvar live--redraws 0)
(defvar live--stalls nil)
(defvar live--beat-last 0.0)
(defvar live--t0 0.0)
(defvar live--cpu0 0.0)
(defvar live--gc0 0)
(defvar live--ge0 0.0)
(defvar live--ids nil)
(defvar live--running nil)
(defvar live--internal 0)
(defvar live--done nil)

(defun live--say (fmt &rest args)
  (let ((line (apply #'format fmt args)))
    (push line live--lines)
    (write-region (concat (mapconcat #'identity (reverse live--lines) "\n") "\n") nil live-out nil 'silent)))

(defun live--session (i)
  (let* ((id (format "s-%04d" i))
         (project (format "%s.worktrees/task-%02d/" (getenv "LIVE_ROOT") (% (/ i 3) 40)))
         (running (zerop (% i 12))))
    (list :id id :name (format "Session number %d about the thing" i) :project project :cwd project
          :status (if running "running" (if (zerop (% i 7)) "inactive" "idle"))
          :kind (if (zerop (% i 3)) "main" "fork")
          :parent-id (and (> (% i 3) 0) (format "s-%04d" (1- i)))
          :model (if (zerop (% i 2)) "claude:sonnet" "claude:opus")
          :permission-mode "auto" :thinking (and (zerop (% i 5)) "high")
          :context-window 200000 :created (+ 1000.0 i) :updated (+ 1000.0 i)
          :last-message (+ 1000.0 i)
          :usage (list :cost (* 0.37 (% i 11)) :input (* 1000 i) :output (* 90 i)
                       :context (* 100 (% i 1500)) :last-output 50
                       :stream-output (* 80 i) :stream-seconds (+ 3.0 (% i 90))
                       :billing "subscription" :plan "max"))))

(defun live--populate ()
  (setq live--ids nil live--running nil)
  (dotimes (i live-n)
    (let ((s (live--session i)))
      (puthash (plist-get s :id) s harness-ui--sessions)
      (push (plist-get s :id) live--ids)
      (when (equal (plist-get s :status) "running")
        (push (plist-get s :id) live--running)
        (puthash (plist-get s :id) (list :context (+ 5000 i) :output (* 20 i) :estimated 100)
                 harness-ui--live))))
  (run-hooks 'harness-ui-sessions-changed-hook))

(defun live--poisson (rate fn)
  (when (> rate 0)
    (let (self)
      (setq self (lambda ()
                   (funcall fn)
                   (push (run-at-time (- (/ (log (- 1.0 (/ (random 1000000) 1000000.0))) rate)) nil self)
                         live--timers)))
      (push (run-at-time (/ 1.0 rate) nil self) live--timers))))

(defun live--load-on ()
  (let ((sessions (vconcat live--ids)) (running (vconcat live--running)))
    (push (run-at-time 0.05 0.05
                       (lambda ()
                         (let* ((now (float-time)) (late (- now live--beat-last 0.05)))
                           (when (> late 0.02) (push late live--stalls))
                           (setq live--beat-last now))))
          live--timers)
    (live--poisson 6 (lambda ()
                       (let* ((id (aref sessions (random (length sessions))))
                              (s (copy-sequence (harness-ui-session id))))
                         (harness-ui-cache-session (plist-put s :updated (float-time))))))
    (live--poisson 15 (lambda ()
                        (harness-ui--store-live (aref running (random (length running)))
                                                (list :context (+ 5000 (random 90000)) :output (random 9000)
                                                      :estimated (random 300)))))
    (live--poisson 3 (lambda ()
                       (let ((id (format "internal-%d" (cl-incf live--internal))))
                         (harness-ui-cache-session (list :id id :kind "internal" :status "running"
                                                         :project (getenv "LIVE_ROOT") :updated (float-time)))
                         (run-at-time 0.3 nil (lambda () (harness-ui--forget-session id))))))))

(defun live--load-off ()
  (mapc #'cancel-timer live--timers)
  (setq live--timers nil))

(defun live--begin ()
  (setq live--t0 (float-time) live--cpu0 (float-time (get-internal-run-time))
        live--gc0 gcs-done live--ge0 gc-elapsed live--redraws 0 live--stalls nil
        live--beat-last (float-time)))

(defun live--end (label)
  (let* ((wall (- (float-time) live--t0))
         (cpu (- (float-time (get-internal-run-time)) live--cpu0)))
    (live--say "%-34s wall %4.1fs  cpu-busy %3.0f%%  redraws %3d  stalls>20ms %3d  longest %5.0f ms  stalled %5.2fs  gcs %3d (%.2fs)"
               label wall (* 100 (/ cpu wall)) live--redraws (length live--stalls)
               (* 1000 (if live--stalls (apply #'max live--stalls) 0.0))
               (apply #'+ live--stalls) (- gcs-done live--gc0) (- gc-elapsed live--ge0))))

(defun live--list-state ()
  (let ((buf (get-buffer "*harness sessions*")))
    (list :shown (and buf (get-buffer-window buf t) t)
          :stale (and buf (boundp 'harness-ui-view-stale) (buffer-local-value 'harness-ui-view-stale buf))
          :rows (and buf (with-current-buffer buf (length tabulated-list-entries))))))

(defun live--show () (switch-to-buffer (get-buffer "*harness sessions*")))
(defun live--hide () (switch-to-buffer (get-buffer-create "*scratch*")))

(defun live--steps (steps)
  "Run STEPS, a list of (DELAY . FUNCTION), each DELAY seconds after the one before."
  (let ((at 0.0))
    (dolist (step steps)
      (cl-incf at (car step))
      (run-at-time at nil (cdr step)))))

(defvar live--conf nil)

(defun live--gui-frame ()
  (car (cl-remove-if-not (lambda (f) (and (frame-parameter f 'window-system) (frame-visible-p f))) (frame-list))))

(defun live-run ()
  (setq live--lines nil live--done nil)
  ;; The daemon's own frame, F1, never redisplays: drive the GUI frame.
  (select-frame (live--gui-frame))
  (select-window (get-window-with-predicate (lambda (w) (not (window-parameter w 'window-side)))
                                            'nomini (selected-frame)))
  (ignore-errors (delete-other-windows))
  (switch-to-buffer (get-buffer-create "*scratch*"))
  (advice-add 'harness-ui-sessions--redraw :before (lambda () (cl-incf live--redraws)) '((name . live-count)))
  (harness-sessions t)
  (live--steps
   (list
    (cons 2.0 (lambda () (clrhash harness-ui--sessions) (live--populate)
                (live--say "emacs %s, %d sessions, frame %S, list %S" emacs-version live-n
                           (frame-parameter (selected-frame) 'name) (live--list-state))))
    (cons 1.0 #'live--show)
    (cons 1.5 (lambda () (live--say "opened: %S" (live--list-state)) (live--load-on) (live--begin)))
    ;; A: shown.
    (cons live-seconds (lambda () (live--end "A  list shown, sessions churning") (live--load-off) (live--hide)))
    ;; B: hidden.
    (cons 0.5 (lambda () (live--load-on) (live--begin)))
    (cons live-seconds (lambda ()
                         (live--end "B  list hidden, sessions churning")
                         (live--load-off)
                         (live--say "hidden state: %S" (live--list-state))
                         (setq live--redraws 0)
                         (live--show)))
    ;; C: shown again: one catch-up.
    (cons 1.5 (lambda ()
                (live--say "C  shown again: %d redraw(s) after 1.5 s, state %S" live--redraws (live--list-state))
                (setq live--conf (current-window-configuration))
                (live--hide)))
    ;; D: a window configuration restored (a workspace or tab switch).
    (cons 0.3 #'live--load-on)
    (cons 3.0 (lambda ()
                (live--load-off)
                (live--say "D  hidden, 3 s of churn: %S" (live--list-state))
                (setq live--redraws 0)
                (set-window-configuration live--conf)))
    (cons 1.5 (lambda ()
                (live--say "D  window configuration restored: %d redraw(s) after 1.5 s, state %S"
                           live--redraws (live--list-state))
                (advice-remove 'harness-ui-sessions--redraw 'live-count)
                (setq live--done t)
                (live--say "done"))))))

(provide 'live-check)
;;; live-check.el ends here
