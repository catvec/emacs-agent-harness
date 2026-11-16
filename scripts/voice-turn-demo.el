;;; voice-turn-demo.el --- Scripted voice turn completion walkthrough -*- lexical-binding: t; -*-

;; Loaded only in the development harness by scripts/voice-turn-demo.sh.
;; All speech events below are scripted.  The normal live handlers, route,
;; pending-turn guard and session/prompt path are real; no microphone,
;; speech service or paid model is involved.

(require 'harness-ui-voice)

(defvar harness-voice-turn-demo--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
(defvar harness-voice-turn-demo--buffer nil)
(defvar harness-voice-turn-demo--frame nil)
(defvar harness-voice-turn-demo--sequence 0)
(defvar harness-voice-turn-demo--error nil)
(defvar harness-voice-turn-demo--first-step 'hold
  "The scripted step the call runs as soon as its sidecar listens.")

(defun harness-voice-turn-demo--ready (buffer attempt)
  "Start scripted voice in BUFFER once its compose box is ready.
ATTEMPT bounds the asynchronous setup wait."
  (when (and (buffer-live-p buffer) (frame-live-p harness-voice-turn-demo--frame))
    (with-selected-frame harness-voice-turn-demo--frame
      (with-current-buffer buffer
        (cond
         ((not (harness-compose-live-p))
          (if (< attempt 100)
              (run-at-time 0.1 nil #'harness-voice-turn-demo--ready buffer (1+ attempt))
            (setq harness-voice-turn-demo--error "Demo compose unavailable")))
         (t
          (setq harness-voice-turn-demo--buffer buffer
                harness-voice-turn-demo--sequence 0)
          (harness-voice-live-start)
          (if harness-voice-turn-demo--first-step
              (run-at-time 0.1 nil #'harness-voice-turn-demo--first 0)
            ;; A quiet start begins with one typed exchange, so that the
            ;; submitted fragment has an earlier message to be rewound to
            ;; and the walkthrough shows the recovery, not only its
            ;; fallback.
            (harness-voice-turn-demo--seed buffer 0))))))))

(defun harness-voice-turn-demo--first (attempt)
  "Inject the first pause cue once the sidecar is ready, bounded by ATTEMPT."
  (cond
   ((eq harness-voice-live--state 'listening)
    (when harness-voice-turn-demo--first-step
      (harness-voice-turn-demo-step harness-voice-turn-demo--first-step))
    (harness-voice-turn-demo-show))
   ((< attempt 100)
    (run-at-time 0.1 nil #'harness-voice-turn-demo--first (1+ attempt)))
   (t (setq harness-voice-turn-demo--error "Demo sidecar unavailable"))))

(defun harness-voice-turn-demo--seed (buffer attempt)
  "Give the call of BUFFER one typed exchange to hang the fragment on.
ATTEMPT bounds the wait for the session's turn to end."
  (when (and (buffer-live-p buffer) (frame-live-p harness-voice-turn-demo--frame))
    (with-selected-frame harness-voice-turn-demo--frame
      (with-current-buffer buffer
        (if (not (eq harness-voice-live--state 'listening))
            (when (< attempt 100)
              (run-at-time 0.1 nil #'harness-voice-turn-demo--seed buffer (1+ attempt)))
          (harness-ui-call-turn
           harness-ui-session-id "session/prompt"
           (list :sessionId harness-ui-session-id
                 :prompt (list (list :type "text"
                                     :text "One line of context for the walkthrough.")))
           (lambda (_) (harness-voice-turn-demo-show))
           (lambda (error) (setq harness-voice-turn-demo--error error))))))))

(defun harness-voice-turn-demo-start (&optional first-step)
  "Open a fresh scripted voice call in a dedicated development harness.
FIRST-STEP is the step the call runs once its sidecar listens: `hold' by
default, or nil to start with nothing said, as the premature-submission
walkthrough does."
  (unless (boundp 'harness-dev-root)
    (user-error "Development harness required"))
  (harness-voice-live-stop)
  (setq harness-voice-turn-demo--first-step (if (equal first-step "") nil
                                              (or first-step 'hold))
        harness-voice-turn-demo--error nil
        harness-voice-turn-demo--frame (harness-dev-frame)
        harness-voice-provider 'custom
        harness-voice-live-command
        (list "python3" (expand-file-name "scripts/harness-voice-live-fixture"
                                          harness-voice-turn-demo--root)))
  (harness-ui-call
   "session/new"
   (list :cwd harness-voice-turn-demo--root
         :_harness (list :model "demo:scripted" :name "Voice turn completion"
                         :permissionMode "auto" :nonInteractive t))
   (lambda (result)
     (harness-ui-refresh-sessions
      (lambda (_)
        (let ((buffer (harness-ui-display-session (plist-get result :sessionId) 'full
                                                   harness-voice-turn-demo--frame)))
          (harness-voice-turn-demo--ready buffer 0)))))
   (lambda (error) (setq harness-voice-turn-demo--error error)))
  'starting)

(defun harness-voice-turn-demo-step (step)
  "Feed scripted STEP through the live voice event handlers.
STEP is `hold', `more', `cut', `recover', `ordinary', `truncated',
`early', `go-on', `early-more', `early-tool', or `early-off'.  The
`early' steps exercise the premature-submission recovery: a transcript
is submitted, the person goes on inside the window, and the turn is
taken back -- or, with `early-tool', the history is kept because the
turn ran a tool."
  (unless (and (buffer-live-p harness-voice-turn-demo--buffer)
               (harness-voice-live--active-p))
    (user-error "Demo call unavailable"))
  (when (memq step '(early early-more early-tool early-off))
    (setq harness-voice-live-recovery-window
          (unless (eq step 'early-off) 0.6)
          ;; The fragment must actually be submitted before the person
          ;; goes on, or the ordinary turn-completion grace would simply
          ;; join the two and there would be nothing to take back.
          harness-voice-live-turn-grace 0.15))
  (let* ((text (pcase step
                 ('hold "Please document the parser, hold on.")
                 ('more "Include its error cases.")
                 ('cut "And add an example for the")
                 ('recover "Go on.")
                 ('ordinary "Please run the tests.")
                 ('truncated "That sentence looks complete.")
                 ('early "Please document the parser")
                 ('go-on "in file.py")
                 ('early-more "and its error cases")
                 ('early-tool "Please read the parser, tools")
                 ('early-off "Please run the tests")
                 (_ (user-error "Unknown demo step"))))
         (uid (cl-incf harness-voice-turn-demo--sequence))
         (segment (format "u-%s" uid)))
    ;; Simulate a capture/transcription, not just a call to the submit helper.
    (with-selected-frame harness-voice-turn-demo--frame
      (with-current-buffer harness-voice-turn-demo--buffer
        (dolist (event
               (list (list :event "speech" :active t :utterance uid :reason "onset")
                     (list :event "segment" :state "accepted" :id segment :seconds 2.1)
                     (list :event "hearing" :utterance uid)
                     (list :event "speech" :active nil :utterance uid :reason "hangover")
                     (list :event "transcribing" :utterance uid)
                     (list :event "user_delta" :text text :final t :utterance uid)
                     (list :event "segment" :state "transcribed" :id segment)
                     (list :event "delegation" :id (format "demo-%s" uid)
                           :text text :utterance uid :truncated (eq step 'truncated))))
          (harness-voice-live--handle event))))
    (when (eq step 'early)
      ;; The cancelled turn acknowledges the cancellation at once: the
      ;; demonstration does not wait for a scripted model to end it.
      (harness-voice-live--finish-turn "cancelled"))
    (when (memq step '(early early-tool))
      ;; The person goes on while the answer is still fresh: the same
      ;; scripted speech, 0.5 s later, inside the window.  With
      ;; `early-tool' the turn is left to run its own tool calls first, so
      ;; the history the recovery reads holds them and the rewind is
      ;; refused for the reason a real one would be.
      (run-at-time 0.5 nil (lambda () (harness-voice-turn-demo-step 'go-on))))
    (when (eq step 'early-more)
      (run-at-time 0.5 nil (lambda () (harness-voice-turn-demo-step 'go-on))))
    (harness-voice-turn-demo-show)
    step))

(defun harness-voice-turn-demo-show ()
  "Show the real target chat and audio transcript side by side."
  (when (and (buffer-live-p harness-voice-turn-demo--buffer)
             (frame-live-p harness-voice-turn-demo--frame))
    (with-selected-frame harness-voice-turn-demo--frame
      (switch-to-buffer harness-voice-turn-demo--buffer)
      (delete-other-windows)
      (when (buffer-live-p harness-voice-live--transcript)
        (let ((window (split-window-right)))
          (set-window-buffer window harness-voice-live--transcript)
          (with-current-buffer harness-voice-live--transcript
            (harness-voice-live--pipeline-draw)
            (set-window-point window (point-max)))))
      (goto-char (point-max))
      (harness-voice--refresh))))

(defun harness-voice-turn-demo-state ()
  "Return the real call state and committed voice messages for the walkthrough."
  (list :state harness-voice-live--state
        :stage harness-voice-live--stage
        :setup-error harness-voice-turn-demo--error
        :pending (and (bound-and-true-p harness-voice-live--pending)
                      (harness-voice-live--pending-text))
        :reason (and (bound-and-true-p harness-voice-live--pending)
                     (harness-voice-live--pending-reason))
        :recovery (and (bound-and-true-p harness-voice-live--recovery)
                       (harness-voice-recovery-evidence
                        harness-voice-live--recovery))
        :sent (mapcar (lambda (turn) (plist-get turn :sent))
                      (seq-filter (lambda (turn) (eq (plist-get turn :speaker) 'user))
                                  (harness-voice-conversation-turns
                                   harness-voice-live--conversation)))))

(provide 'voice-turn-demo)
;;; voice-turn-demo.el ends here
