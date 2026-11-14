;;; bench-acknowledgment.el --- How long the receipt of a request takes  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run it with scripts/analysis/bench-acknowledgment.sh, which compiles
;; the tree first and passes the directory in HARNESS_BENCH_DIR.
;;
;; What it measures, and what it does not:
;;
;;   submission-to-player-start  The time from the prompt's request going
;;                               out (`harness-ui-call-turn') to the
;;                               receipt's player program having started
;;                               and written its first line.  This is the
;;                               harness's own path plus one process
;;                               spawn; it is NOT the time sound reaches a
;;                               speaker.  No audio device is opened here,
;;                               so an audio backend's own startup -- the
;;                               real remainder of "audible" -- is not in
;;                               these numbers.
;;   dispatch                    The time `harness-ui-call-turn' takes to
;;                               return, with the receipt hook installed
;;                               and with it absent.  It is the UI work
;;                               the receipt could add to a request.
;;   priming                     The time the background pass takes to
;;                               generate the phrases from nothing (a
;;                               cache miss): what a cold client pays
;;                               before its first receipt exists.
;;
;; The speech command is a stand-in that writes a WAV at once, so the
;; numbers describe the harness's scheduling and process handling, not a
;; speech model's speed.  A real Kokoro or Piper generates a phrase in
;; the hundreds of milliseconds; that cost is paid once, in the
;; background, and never on a request.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-voice)

(defconst bench-ack--dir (or (getenv "HARNESS_BENCH_DIR")
                             (error "HARNESS_BENCH_DIR is not set"))
  "Where this run keeps its state and its marker file.")

(defconst bench-ack--marker (expand-file-name "player-started.txt" bench-ack--dir)
  "The player writes this file as soon as it starts.")

(defconst bench-ack--player
  (expand-file-name "player.sh" bench-ack--dir)
  "A player that says when it started, then exits.")

(defconst bench-ack--synth
  (list "python3" "-c"
        (concat "import pathlib,sys\n"
                "pathlib.Path(sys.argv[1]).write_bytes(b'RIFF' + b'0' * 76)\n")
        :file)
  "A stand-in speech command: writes a playable WAV, at once.")

(defconst bench-ack--samples-warm 200)
(defconst bench-ack--samples-dispatch 500)
(defconst bench-ack--samples-cold 25)

(defun bench-ack--percentile (values fraction)
  "Return the FRACTION percentile of sorted VALUES."
  (let* ((sorted (sort (copy-sequence values) #'<))
         (index (max 0 (min (1- (length sorted))
                            (round (* fraction (1- (length sorted))))))))
    (nth index sorted)))

(defun bench-ack--summary (label values)
  "Print LABEL with the count, p50, p95 and maximum of VALUES in ms."
  (let ((p50 (bench-ack--percentile values 0.50))
        (p95 (bench-ack--percentile values 0.95))
        (max (bench-ack--percentile values 1.0)))
    (princ (format "%-34s n=%-4d p50 %7.2f ms  p95 %7.2f ms  max %7.2f ms\n"
                   label (length values) p50 p95 max))
    (list :label label :n (length values) :p50 p50 :p95 p95 :max max)))

(defun bench-ack--setup ()
  "Make this Emacs a compose host with the receipt's player instrumented."
  (setq harness-state-directory (file-name-as-directory
                                 (expand-file-name "state/" bench-ack--dir)))
  (make-directory harness-state-directory t)
  (with-temp-file bench-ack--player
    (insert "#!/bin/sh\n"
            (format "date +%%s%%N > %s\n" (shell-quote-argument bench-ack--marker))
            "sleep 0.05\n"))
  (set-file-modes bench-ack--player #o755)
  (let ((buffer (get-buffer-create " *bench compose*")))
    (with-current-buffer buffer
      (setq-local harness-ui-session-id "bench-session")
      (setq harness-voice--enabled t
            harness-voice--owner (current-buffer)
            harness-voice-mode t
            harness-voice--state 'ready
            harness-voice--job nil
            harness-voice--queue nil
            harness-voice-acknowledgment t
            harness-voice-live-acknowledgment t
            harness-voice-acknowledgment-phrases '("On it" "Hmm, thinking" "Right")
            harness-voice-synthesize-command bench-ack--synth
            harness-voice-player-command (list bench-ack--player :file)
            harness-ui-turn-accepted-functions (list #'harness-voice--acknowledge)))
    buffer))

(defun bench-ack--send (sid)
  "Send a prompt to SID, as the chat does, and return how long that took.
The request goes nowhere: the promise is never answered, which is what a
turn that runs looks like to the UI."
  (cl-letf (((symbol-function 'harness-ui-request)
             (lambda (&rest _) (harness-make-promise))))
    (let ((started (float-time)))
      (harness-ui-call-turn sid "session/prompt"
                            (list :sessionId sid
                                  :prompt (list (list :type "text" :text "On it")))
                            #'ignore)
      (* 1000.0 (- (float-time) started)))))

(defun bench-ack--player-started ()
  "Return when the player last started, or nil."
  (when (file-exists-p bench-ack--marker)
    (with-temp-buffer
      (insert-file-contents bench-ack--marker)
      (string-to-number (string-trim (buffer-string))))))

(defun bench-ack--forget-player ()
  "Forget the last start, so the next one is seen."
  (when (file-exists-p bench-ack--marker) (delete-file bench-ack--marker)))

(defun bench-ack--primed-p ()
  "Non-nil when every phrase of the bank is generated."
  (cl-every (lambda (phrase)
              (harness-voice--acknowledgment-ready
               (harness-voice--acknowledgment-file phrase)))
            harness-voice-acknowledgment-phrases))

(defun bench-ack--wait (predicate timeout)
  "Wait for PREDICATE, returning the time it took in seconds, or nil."
  (let ((started (float-time)))
    (while (and (not (funcall predicate))
                (< (- (float-time) started) timeout))
      (accept-process-output nil 0.001))
    (when (funcall predicate) (- (float-time) started))))

(defun bench-ack--warm ()
  "Measure submission to the receipt's player starting, with the bank ready."
  ;; A pass the cold measurement left running is waited for, not restarted.
  (bench-ack--wait (lambda () (not harness-voice--acknowledgment-priming)) 60)
  (harness-voice-acknowledge-prime)
  (bench-ack--wait #'bench-ack--primed-p 60)
  (unless (bench-ack--primed-p)
    (error "The bank was not generated (priming %S, files %S); the warm path cannot be measured"
           harness-voice--acknowledgment-priming
           (ignore-errors (directory-files (harness-voice--acknowledgment-directory) nil "wav$"))))
  (let ((samples nil))
    (dotimes (_ bench-ack--samples-warm)
      (harness-voice--acknowledgment-stop)
      (sit-for 0.002)
      (bench-ack--forget-player)
      (let ((started (float-time)))
        (bench-ack--send "bench-session")
        (let ((waited (bench-ack--wait
                       (lambda ()
                         (let ((at (bench-ack--player-started)))
                           (and at (> (/ at 1000.0) 0))))
                       5)))
          (if (and waited (bench-ack--player-started))
              (push (* 1000.0 (- (float-time) started)) samples)
            (push 999999.0 samples)))))
    (bench-ack--summary "submission-to-player-start (warm)" samples)))

(defun bench-ack--dispatch ()
  "Measure what the receipt adds to `harness-ui-call-turn'."
  (let ((with-hook nil)
        (without-hook nil)
        (slow-hook nil))
    ;; The hook installed, bank ready: the player starts each time.
    (dotimes (_ bench-ack--samples-dispatch)
      (harness-voice--acknowledgment-stop)
      (push (bench-ack--send "bench-session") with-hook))
    ;; No hook at all: the request path alone.
    (let ((harness-ui-turn-accepted-functions nil))
      (dotimes (_ bench-ack--samples-dispatch)
        (push (bench-ack--send "bench-session") without-hook)))
    ;; The hook installed and a phrase missing: every request starts the
    ;; background pass and plays nothing.
    (harness-voice--acknowledgment-stop)
    (dolist (phrase harness-voice-acknowledgment-phrases)
      (ignore-errors (delete-file (harness-voice--acknowledgment-file phrase))))
    (let ((harness-ui-turn-accepted-functions (list #'harness-voice--acknowledge)))
      (dotimes (_ bench-ack--samples-dispatch)
        (harness-voice--acknowledgment-stop)
        (push (bench-ack--send "bench-session") slow-hook)))
    (list (bench-ack--summary "dispatch, receipt hook installed" with-hook)
          (bench-ack--summary "dispatch, no receipt hook" without-hook)
          (bench-ack--summary "dispatch, phrase missing (cold)" slow-hook))))

(defun bench-ack--cold ()
  "Measure a cache miss: the request, and the background pass behind it."
  (let ((samples nil)
        (primed nil)
        (played nil))
    (dotimes (_ bench-ack--samples-cold)
      (harness-voice--acknowledgment-stop)
      (bench-ack--forget-player)
      (push (bench-ack--send "bench-session") samples)
      (when (bench-ack--player-started) (setq played t)))
    (let ((pass (bench-ack--wait #'bench-ack--primed-p 60)))
      (setq primed pass))
    (princ (format "%-34s %s\n" "a receipt played on a cache miss"
                   (if played "YES -- wrong" "no, silence (correct)")))
    (princ (format "%-34s %s\n" "the background pass finished"
                   (if primed (format "%.0f ms after the last request" (* 1000.0 primed))
                     "no")))
    (bench-ack--summary "dispatch on a cache miss" samples)))

(defun bench-ack--main ()
  "Print the whole report and exit; a failure exits nonzero."
  (bench-ack--setup)
  (princ (format "bench-acknowledgment · %s %s · %s\n"
                 (emacs-version) system-configuration
                 (format-time-string "%Y-%m-%dT%H:%M:%S%z")))
  (princ "player: a shell script that marks its start, then exits; \n")
  (princ "speech: a stand-in that writes a WAV at once (no model)\n")
  (princ (format "load average at start: %s\n\n"
                 (string-trim (shell-command-to-string "cut -d' ' -f1-3 /proc/loadavg"))))
  (let* ((cod (bench-ack--cold))
         (dispatch (bench-ack--dispatch))
         (warm (bench-ack--warm)))
    (princ "\n")
    (princ "--- verdict ---\n")
    (let ((warm-p95 (plist-get warm :p95))
          (over (plist-get (nth 0 dispatch) :p95))
          (under (plist-get (nth 1 dispatch) :p95)))
      (princ (format "warm p95 %.2f ms against a 300 ms budget: %s\n"
                     warm-p95 (if (<= warm-p95 300.0) "within" "OVER")))
      (princ (format "dispatch p95 with the hook %.3f ms, without it %.3f ms: "
                     over under))
      (princ (if (<= (- over under) 5.0) "the receipt adds no wait\n"
               "the receipt adds a wait\n"))
      (princ (format "cold: %d requests sent in %.2f ms p95 each, no receipt played\n"
                     (plist-get cod :n) (plist-get cod :p95))))
    (kill-emacs 0)))

(bench-ack--main)

;;; bench-acknowledgment.el ends here
