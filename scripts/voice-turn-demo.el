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
          (run-at-time 0.1 nil #'harness-voice-turn-demo--first 0)))))))

(defun harness-voice-turn-demo--first (attempt)
  "Inject the first pause cue once the sidecar is ready, bounded by ATTEMPT."
  (cond
   ((eq harness-voice-live--state 'listening)
    (harness-voice-turn-demo-step 'hold)
    (harness-voice-turn-demo-show))
   ((< attempt 100)
    (run-at-time 0.1 nil #'harness-voice-turn-demo--first (1+ attempt)))
   (t (setq harness-voice-turn-demo--error "Demo sidecar unavailable"))))

(defun harness-voice-turn-demo-start ()
  "Open a fresh scripted voice call in a dedicated development harness."
  (unless (boundp 'harness-dev-root)
    (user-error "Development harness required"))
  (harness-voice-live-stop)
  (setq harness-voice-turn-demo--error nil
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
STEP is `hold', `more', `cut', `recover', `ordinary', or `truncated'."
  (unless (and (buffer-live-p harness-voice-turn-demo--buffer)
               (harness-voice-live--active-p))
    (user-error "Demo call unavailable"))
  (let* ((text (pcase step
                 ('hold "Please document the parser, hold on.")
                 ('more "Include its error cases.")
                 ('cut "And add an example for the")
                 ('recover "Go on.")
                 ('ordinary "Please run the tests.")
                 ('truncated "That sentence looks complete.")
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
        :sent (mapcar (lambda (turn) (plist-get turn :sent))
                      (seq-filter (lambda (turn) (eq (plist-get turn :speaker) 'user))
                                  (harness-voice-conversation-turns
                                   harness-voice-live--conversation)))))

(provide 'voice-turn-demo)
;;; voice-turn-demo.el ends here
