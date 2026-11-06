;;; harness-ui-voice-live.el --- Live voice sidecar transport  -*- lexical-binding: t; -*-

;;; Commentary:

;; The live half of `ui-voice': a sidecar process owns the microphone,
;; the speaker and the speech model, while Emacs owns the conversation
;; state, the agent session and every permission decision.  The sidecar
;; speaks newline-delimited JSON on stdin and stdout: one object per
;; line, UTF-8, diagnostics on stderr.  Nothing but control text crosses
;; the pipe.  Audio stays in the sidecar.
;;
;; Sidecar to Emacs: ready, listening, speaking, user_delta,
;; assistant_delta, backchannel, delegation, interrupted, error, closed.
;; Emacs to sidecar: start, context, mute, interrupt, stop, commentary,
;; thinking, delegate_result.
;;
;; A delegation becomes a prompt in the current chat, through the normal
;; `session/prompt' path.  Assistant text streams back as speakable
;; commentary; the turn's full text is the delegate result.  Permissions
;; and questions stay on screen: the sidecar may say that approval is
;; needed, never approve anything.  Interruption stops playback only;
;; cancelling the agent turn is a separate command.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)

(declare-function harness-voice--adopt "harness-ui-voice")
(declare-function harness-voice--button "harness-ui-voice")
(declare-function harness-voice--context "harness-ui-voice")
(declare-function harness-voice--refresh "harness-ui-voice")
(declare-function harness-voice "harness-ui-voice")
(declare-function harness-voice-mode "harness-ui-voice")
(declare-function harness-voice-setup "harness-ui-voice-providers")
(declare-function harness-voice--speech-text "harness-ui-voice")
(defvar harness-voice-mode)
(defvar harness-voice--controls)
(defvar harness-voice--enabled)
(defvar harness-voice--owner)
(defvar harness-voice-live-command)
(declare-function harness-voice-live-p "harness-ui-voice-providers")
(declare-function harness-voice-provider-command "harness-ui-voice-providers")
(declare-function harness-voice-provider-label "harness-ui-voice-providers")
(declare-function harness-voice-dictate "harness-ui-voice")
(declare-function harness-voice-interrupt "harness-ui-voice")
(defvar harness-voice-provider)
(defvar harness-voice-live-startup-timeout)

(defconst harness-voice-live--protocol 1
  "Protocol version this client speaks.")

(defconst harness-voice-live--stop-timeout 3
  "Seconds to wait for a sidecar to close before killing it.")

(defvar harness-voice-live--process nil "The sidecar process, or nil.")
(defvar harness-voice-live--buffer nil "The compose buffer that owns the session.")
(defvar harness-voice-live--session nil "The session id delegations go to.")
(defvar harness-voice-live--stderr nil "Buffer holding the sidecar's stderr.")
(defvar harness-voice-live--tail "" "Unparsed stdout after the last newline.")
(defvar harness-voice-live--timer nil "Startup or stop timer, or nil.")
(defvar harness-voice-live--state nil
  "Session state.
One of nil, `starting', `listening', `speaking', `interrupted',
`ending' or `failed'.")
(defvar harness-voice-live--error nil "Failure text shown in the controls.")
(defvar harness-voice-live--muted nil "Non-nil while the sidecar microphone is muted.")
(defvar harness-voice-live--working nil "Non-nil while an agent turn runs.")
(defvar harness-voice-live--turn-active nil "Non-nil while assistant text is followed.")
(defvar harness-voice-live--closing nil "Non-nil when this client ended the session.")
(defvar harness-voice-live--delegation nil "The running delegation, a plist, or nil.")
(defvar harness-voice-live--delegations nil "Delegations waiting for the running turn.")
(defvar harness-voice-live--nodes nil "Node id -> text and streamed offset.")
(defvar harness-voice-live--order nil "Node ids in the order their text arrived.")
(defvar harness-voice-live--heard ""
  "User transcript since the last delegation, for a delegation without text.")
(defvar harness-voice-live--transcript nil "The live caption buffer, or nil.")
(defvar harness-voice-live--speaker nil "Speaker of the caption line being written.")
(defvar harness-voice-live--section nil "Section of the transcript being written.")
(defvar harness-voice-live--stage nil
  "What the session is doing now.
One of nil, `listening', `hearing', `transcribing', `thinking',
`speaking', `muted' or `failed'.  The stage is what the controls, the
stage line and the timer read; the state is what the sidecar reported.")
(defvar harness-voice-live--stage-since nil "Time the current stage began.")
(defvar harness-voice-live--stage-timer nil "Timer animating an active stage.")
(defvar harness-voice-live--stage-frame 0 "Frame of the busy indicator.")
(defconst harness-voice-live--spinner
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Braille frames of the busy indicator.
A frame every fifth of a second is the oldest trick there is to make a
wait look alive, and it costs one character.")
(defvar-local harness-voice--live-context nil
  "Voice request context captured where this chat was opened.")

;;;; Status and controls

(defun harness-voice-live--active-p ()
  "Non-nil while a sidecar session runs."
  (and (processp harness-voice-live--process)
       (process-live-p harness-voice-live--process)))

(defun harness-voice-live--microphone-on-p ()
  "Non-nil while the sidecar microphone is open."
  (and (harness-voice-live--active-p)
       (not harness-voice-live--muted)
       (memq harness-voice-live--state '(listening speaking))))

(defun harness-voice-live--elapsed ()
  "Return the seconds the current stage has taken, or nil.
A stage under a third of a second reports nothing: an elapsed time that
flickers in and out is noise, and a wait that short needs no clock."
  (when (and harness-voice-live--stage-since
             (memq harness-voice-live--stage
                   '(hearing transcribing thinking)))
    (let ((seconds (- (float-time) harness-voice-live--stage-since)))
      (and (>= seconds 0.3) seconds))))

(defun harness-voice-live--stage-name ()
  "Return the word for the current stage, or nil."
  (pcase harness-voice-live--stage
    ('listening "Listening")
    ('hearing "Hearing you")
    ('transcribing "Transcribing")
    ('thinking "Working")
    ('speaking "Speaking")
    ('muted "Muted")
    ('failed "Failed")))

(defun harness-voice-live--busy-p ()
  "Non-nil while the current stage should animate.
Speaking has its own mark: the reply is arriving, not waited for."
  (memq harness-voice-live--stage '(hearing transcribing thinking)))

(defun harness-voice-live--stage-glyph ()
  "Return the indicator of the current stage: a spinner or a dot."
  (cond
   ((and (harness-voice-live--busy-p) harness-voice-live--stage-timer)
    (aref harness-voice-live--spinner
          (mod harness-voice-live--stage-frame (length harness-voice-live--spinner))))
   ((eq harness-voice-live--stage 'speaking) "▷")
   ((eq harness-voice-live--stage 'muted) "⊘")
   ((eq harness-voice-live--stage 'failed) "✕")
   (t "●")))

(defun harness-voice-live--stage-text ()
  "Return the stage line: indicator, word and elapsed time."
  (let ((name (harness-voice-live--stage-name))
        (elapsed (harness-voice-live--elapsed)))
    (when name
      (concat (harness-voice-live--stage-glyph) " " name
              (when elapsed (format " · %.1fs" elapsed))))))

(defun harness-voice-live--tick ()
  "Advance the busy indicator and redraw the stage line and controls."
  (when (harness-voice-live--busy-p)
    (setq harness-voice-live--stage-frame (1+ harness-voice-live--stage-frame))
    (harness-voice-live--stage-redraw)
    (harness-voice-live--refresh)))

(defun harness-voice-live--stage-set (stage)
  "Make STAGE the current one, animating it while it is active."
  (unless (eq stage harness-voice-live--stage)
    (setq harness-voice-live--stage stage
          harness-voice-live--stage-since (and stage (float-time))
          harness-voice-live--stage-frame 0)
    (when (timerp harness-voice-live--stage-timer)
      (cancel-timer harness-voice-live--stage-timer)
      (setq harness-voice-live--stage-timer nil))
    (when (harness-voice-live--busy-p)
      (setq harness-voice-live--stage-timer
            (run-at-time 0.2 0.2 #'harness-voice-live--tick)))
    (harness-voice-live--stage-redraw)
    (harness-voice-live--refresh)))

(defun harness-voice-live--status ()
  "Return the exact live status copy."
  (concat
   "Live"
   (cond
    ((eq harness-voice-live--state 'failed) " · Failed")
    ((eq harness-voice-live--state 'starting) " · Starting")
    ((eq harness-voice-live--state 'ending) " · Ending")
    ((eq harness-voice-live--state 'interrupted) " · Interrupted")
    ((memq harness-voice-live--stage '(hearing transcribing thinking))
     (concat " · " (harness-voice-live--stage-name)
             (let ((elapsed (harness-voice-live--elapsed)))
               (when elapsed (format " · %.1fs" elapsed)))))
    ((eq harness-voice-live--state 'speaking) " · Speaking")
    ((eq harness-voice-live--stage 'speaking) " · Speaking")
    (harness-voice-live--working " · Working")
    ((and harness-voice-live--muted (harness-voice-live--active-p)) " · Muted")
    ((or (eq harness-voice-live--state 'listening)
         (eq harness-voice-live--stage 'listening)) " · Listening")
    ((null harness-voice-live--state) " · Off")
    (t ""))))

(defun harness-voice-live--refresh ()
  "Refresh the owner's controls and the mode line."
  (if (buffer-live-p harness-voice-live--buffer)
      (with-current-buffer harness-voice-live--buffer
        (harness-voice--refresh))
    (force-mode-line-update t)))

(defun harness-voice-live--release-others ()
  "End a live session owned by a different compose buffer."
  (when (and (harness-voice-live--active-p)
             (not (eq harness-voice-live--buffer (current-buffer))))
    (harness-voice-live--reset)))

(defun harness-voice-live--face ()
  "Return the face for the live status."
  (cond ((eq harness-voice-live--state 'failed) 'harness-failure-face)
        ((harness-voice-live--microphone-on-p) 'harness-caution-face)
        (t 'harness-label-face)))

(defun harness-voice-live--controls ()
  "Return fitted live voice controls for a compose box, or nil."
  (when (and harness-voice--enabled (harness-voice-live-p))
    (let ((active (harness-voice-live--active-p))
          (items nil))
      (if (not harness-voice--controls)
          (setq items (list (list (harness-voice--button
                                   "Voice" #'harness-voice "Voice controls · C-c h v"))))
        (setq items
              (list
               (list (propertize (harness-voice-live--status)
                                 'face (harness-voice-live--face)
                                 'help-echo (or harness-voice-live--error "Live voice status"))
                     100 nil)
               (list (if active
                         (harness-voice--button "End" #'harness-voice-live-stop
                                                "Live session · end")
                       (harness-voice--button "Start" #'harness-voice-live--start-here
                                              "Live voice · sidecar session"))
                     95 nil)
               (and active
                    (list (harness-voice--button "Interrupt C-c V" #'harness-voice-live-interrupt
                                                 "Playback · interruption") 90 nil))
               (and harness-voice-live--error
                    (list (propertize harness-voice-live--error 'face 'harness-failure-face
                                      'help-echo harness-voice-live--error) 85 nil))
               (and active harness-voice-live--working
                    (list (harness-voice--button "Cancel work" #'harness-voice-live-cancel
                                                 "Agent turn · cancellation") 80 nil))
               (and active
                    (list (harness-voice--button
                           (if harness-voice-live--muted "Unmute C-c v" "Mute C-c v")
                           #'harness-voice-live-mute "Microphone · live session") 70 nil))
               (list (harness-voice--button "Transcript" #'harness-voice-live-transcript
                                            "Live transcript") 60 nil)
               (list (harness-voice--button "Setup" #'harness-voice-setup
                                            "Voice settings") 50 nil))))
      (harness-ui-settings-line
       (list items) (max 1 (- (/ (harness-compose--room) (frame-char-width)) 3))))))

;;;; Sidecar process

(defun harness-voice-live--command ()
  "Return the validated sidecar argv list, or signal.
The command belongs to the selected provider: the GPT-Live adapter, the
local pipeline, the fixture or a custom sidecar."
  (harness-voice-provider-command))

(defun harness-voice-live--json (object)
  "Return OBJECT as one JSON line."
  (concat (json-serialize object :false-object :false :null-object :null)
          "\n"))

(defun harness-voice-live--send (object)
  "Send OBJECT to the sidecar, when its process still runs."
  (when (harness-voice-live--active-p)
    (condition-case err
        (progn
          (process-send-string harness-voice-live--process
                               (harness-voice-live--json object))
          t)
      (error
       (harness-voice-live--fail (format "Live voice send failure · %s"
                                         (error-message-string err)))
       nil))))

(defun harness-voice-live--stderr-tail ()
  "Return the last line or two of sidecar stderr on one line."
  (when (buffer-live-p harness-voice-live--stderr)
    (with-current-buffer harness-voice-live--stderr
      (let ((text (string-trim (buffer-substring-no-properties
                                (point-min) (point-max)))))
        (unless (string-empty-p text)
          (let ((start (max 0 (- (length text) 300))))
            (harness-ui-one-line (substring text start))))))))

(defun harness-voice-live--dispose ()
  "Kill the sidecar and its buffers without reporting a failure."
  (when (timerp harness-voice-live--timer)
    (cancel-timer harness-voice-live--timer))
  (when (timerp harness-voice-live--stage-timer)
    (cancel-timer harness-voice-live--stage-timer))
  (setq harness-voice-live--timer nil
        harness-voice-live--stage-timer nil
        harness-voice-live--stage nil
        harness-voice-live--stage-since nil)
  (let ((process harness-voice-live--process))
    (setq harness-voice-live--process nil
          harness-voice-live--tail "")
    (when (processp process)
      (ignore-errors (set-process-sentinel process #'ignore))
      (when (process-live-p process) (delete-process process))))
  (when (buffer-live-p harness-voice-live--stderr)
    (kill-buffer harness-voice-live--stderr))
  (setq harness-voice-live--stderr nil))

(defun harness-voice-live--clear-turn ()
  "Forget the turn in flight and every delegation."
  (setq harness-voice-live--working nil
        harness-voice-live--turn-active nil
        harness-voice-live--delegation nil
        harness-voice-live--delegations nil
        harness-voice-live--nodes nil
        harness-voice-live--order nil
        harness-voice-live--heard ""))

(defun harness-voice-live--fail (detail)
  "Fail the live session visibly with DETAIL."
  (let ((text (harness-ui-one-line detail)))
    (harness-voice-live--dispose)
    (setq harness-voice-live--state 'failed
          harness-voice-live--error text
          harness-voice-live--closing nil)
    (harness-voice-live--stage-set 'failed)
    (harness-voice-live--clear-turn)
    (harness-voice-live--refresh)))

(defun harness-voice-live--startup-timeout ()
  "Fail a sidecar that never became ready."
  (when (and (harness-voice-live--active-p)
             (eq harness-voice-live--state 'starting))
    (harness-voice-live--fail "Live voice startup timeout")))

(defun harness-voice-live--stop-timeout ()
  "Kill a sidecar that did not close when asked."
  (when (harness-voice-live--active-p)
    (harness-voice-live--dispose)
    (setq harness-voice-live--state nil
          harness-voice-live--closing nil)
    (harness-voice-live--refresh)))

(defun harness-voice-live--finished (process _status)
  "Handle sidecar PROCESS exiting on its own or after a stop."
  (when (eq process harness-voice-live--process)
    (let ((tail (harness-voice-live--stderr-tail))
          (closing harness-voice-live--closing)
          (state harness-voice-live--state))
      (when (timerp harness-voice-live--timer)
        (cancel-timer harness-voice-live--timer))
      (setq harness-voice-live--timer nil
            harness-voice-live--process nil
            harness-voice-live--tail "")
      (when (buffer-live-p harness-voice-live--stderr)
        (kill-buffer harness-voice-live--stderr))
      (setq harness-voice-live--stderr nil
            harness-voice-live--closing nil)
      (harness-voice-live--clear-turn)
      (cond
       (closing
        (setq harness-voice-live--state nil))
       ((eq state 'failed) nil)
       (t
        (setq harness-voice-live--state 'failed
              harness-voice-live--error
              (if tail (format "Live voice ended · %s" tail)
                "Live voice ended"))))
      (harness-voice-live--refresh))))

(defun harness-voice-live--filter (process chunk)
  "Read JSON lines from sidecar PROCESS out of CHUNK."
  (when (eq process harness-voice-live--process)
    (setq harness-voice-live--tail (concat harness-voice-live--tail chunk))
    (let ((tail harness-voice-live--tail)
          (start 0))
      (while (and (eq process harness-voice-live--process)
                  (string-match "\n" tail start))
        (let ((line (substring tail start (match-beginning 0))))
          (setq start (match-end 0))
          (unless (string-blank-p line)
            (condition-case _err
                (let ((event (json-parse-string line :object-type 'plist
                                                :null-object nil :false-object nil)))
                  (when (listp event)
                    (harness-voice-live--handle event)))
              (error
               (harness-voice-live--fail "Live voice protocol error"))))))
      (when (eq process harness-voice-live--process)
        (setq harness-voice-live--tail (substring tail start))))))

(defun harness-voice-live--start-timer (seconds function)
  "Run FUNCTION once after SECONDS, replacing the current timer."
  (when (timerp harness-voice-live--timer)
    (cancel-timer harness-voice-live--timer))
  (setq harness-voice-live--timer (run-at-time seconds nil function)))

;;;; Live transcript

(defconst harness-voice-live--transcript-rule
  (propertize (make-string 58 ?─) 'face 'harness-dim-face)
  "The rule under the transcript's stage line.")

(defvar harness-voice-live--transcript-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "C-c v") #'harness-voice-dictate)
    (define-key map (kbd "C-c V") #'harness-voice-interrupt)
    map)
  "Key map of the live voice transcript.")

(define-derived-mode harness-voice-live-transcript-mode special-mode "Voice transcript"
  "Mode of the live voice transcript.
The stage line at the top says what the session is doing now; the
sections below say what you said, what the coding agent did and what
the voice said back.  `C-c v' dictates or mutes, `C-c V' interrupts
and `q' closes the buffer."
  (setq-local mode-line-format '(" Voice transcript")))

(defun harness-voice-live--transcript-buffer ()
  "Return the live transcript buffer, making it when needed."
  (unless (buffer-live-p harness-voice-live--transcript)
    (let ((buffer (get-buffer-create "*harness voice*")))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (harness-voice-live-transcript-mode)
          (insert harness-voice-live--transcript-rule "\n")
          (setq-local header-line-format
                      '(:eval (concat " " (or (harness-voice-live--stage-text) "○ Off")
                                      "   Voice · "
                                      (if (fboundp 'harness-voice-provider-label)
                                          (harness-voice-provider-label harness-voice-provider)
                                        "live")))))
        (setq buffer-read-only t))
      (setq harness-voice-live--section nil
            harness-voice-live--transcript buffer))
    (harness-voice-live--stage-redraw))
  harness-voice-live--transcript)

(defun harness-voice-live--stage-redraw ()
  "Redraw the transcript's stage line, when the buffer shows one."
  (when (buffer-live-p harness-voice-live--transcript)
    (with-current-buffer harness-voice-live--transcript
      (force-mode-line-update t))))

(defun harness-voice-live--transcript-insert (text &optional face)
  "Insert TEXT at the end of the live transcript, in FACE."
  (when (and (stringp text) (not (string-empty-p text)))
    (let ((buffer (harness-voice-live--transcript-buffer)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (start (point-max)))
          (goto-char (point-max))
          (insert (if face (propertize text 'face face) text))
          (goto-char (point-max))
          (dolist (window (get-buffer-window-list buffer t))
            (set-window-point window (point-max)))
          start)))))

(defun harness-voice-live--transcript-section (section title)
  "Begin SECTION of the transcript, headed TITLE, when it is a new one.
Return non-nil when a heading was written."
  (prog1 (not (eq section harness-voice-live--section))
    (unless (eq section harness-voice-live--section)
      (let ((buffer (harness-voice-live--transcript-buffer)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert "\n"
                    (propertize title
                                'face (pcase section
                                        ('user 'harness-user-label-face)
                                        ('work 'harness-label-face)
                                        (_ 'harness-agent-label-face)))
                    (propertize (format " · %s" (format-time-string "%H:%M"))
                                'face 'harness-dim-face)
                    "\n")
            (dolist (window (get-buffer-window-list buffer t))
              (set-window-point window (point-max)))))))
    (setq harness-voice-live--section section)))

(defun harness-voice-live--transcript-text (section title text &optional face)
  "Write TEXT into SECTION, headed TITLE, in FACE."
  (harness-voice-live--transcript-section section title)
  (let ((buffer (harness-voice-live--transcript-buffer))
        (start nil))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (when (bolp) (insert "  "))
        (setq start (point))
        (insert (if face (propertize text 'face face) text))))
    start))

(defun harness-voice-live--caption (speaker text &optional final)
  "Show SPEAKER's TEXT, ending the caption line with FINAL."
  (unless (string-empty-p text)
    (unless (equal harness-voice-live--speaker speaker)
      (when harness-voice-live--speaker
        (harness-voice-live--transcript-insert "\n"))
      (setq harness-voice-live--speaker speaker))
    (if (equal speaker "You")
        (harness-voice-live--transcript-text 'user "You" text)
      (harness-voice-live--transcript-text 'agent "Voice" text 'harness-agent-face)))
  (when final
    (when harness-voice-live--speaker
      (harness-voice-live--transcript-insert "\n"))
    (setq harness-voice-live--speaker nil
          harness-voice-live--section nil)))

(defun harness-voice-live--backchannel (text)
  "Show a backchannel TEXT in the transcript."
  (harness-voice-live--transcript-section 'agent "Voice")
  (harness-voice-live--transcript-insert
   (concat "  " (if (string-empty-p text) "mm-hmm" text) "\n")
   'harness-thinking-face))

(defun harness-voice-live--transcript-tool (title)
  "Show a coding-agent tool call TITLE in the transcript.
A long subject is clipped: the point is what kind of work is happening,
not the whole path."
  (when (> (length title) 72)
    (setq title (concat (substring title 0 71) "…")))
  (harness-voice-live--transcript-section 'work "Coding agent")
  (harness-voice-live--transcript-insert
   (concat "  ▸ " title "\n")
   'harness-tool-title-face))

;;;###autoload
(defun harness-voice-live-transcript ()
  "Show the live transcript."
  (interactive)
  (unless (buffer-live-p harness-voice-live--transcript)
    (user-error "Live transcript unavailable"))
  (pop-to-buffer harness-voice-live--transcript)
  (goto-char (point-max)))

;;;; Speaking the agent's reply

(defun harness-voice-live--speak (text)
  "Send speakable TEXT to the sidecar as commentary."
  (let ((speech (harness-voice--speech-text text)))
    (while (and (not (string-empty-p speech)) (harness-voice-live--active-p))
      (let ((piece (if (> (length speech) 1200) (substring speech 0 1200) speech)))
        (harness-voice-live--send (list :event "commentary" :text piece))
        (setq speech (if (> (length speech) 1200) (substring speech 1200) ""))))))

(defun harness-voice-live--open-fence (text)
  "Return the position of an unclosed code fence in TEXT, or nil."
  (let ((position 0) (open nil))
    (while (string-match "```\\|~~~" text position)
      (setq position (match-end 0)
            open (if open nil (match-beginning 0))))
    open))

(defun harness-voice-live--drain-node (id final)
  "Send new sentences of node ID, flushing the rest with FINAL."
  (let* ((entry (gethash id harness-voice-live--nodes))
         (text (or (plist-get entry :text) ""))
         (offset (or (plist-get entry :sent) 0))
         (fence (harness-voice-live--open-fence text))
         (limit (or fence (length text)))
         (scan offset)
         end)
    (while (and (< scan limit)
                (setq end (and (string-match "[.!?][ \t\n]+\\|\n\n" text scan)
                               (match-end 0)))
                (<= end limit))
      (harness-voice-live--speak (substring text scan end))
      (setq scan end))
    (when final
      (when (> (length text) scan)
        (harness-voice-live--speak (substring text scan)))
      (setq scan (length text)))
    (puthash id (plist-put entry :sent scan) harness-voice-live--nodes)))

(defun harness-voice-live--add-chunk (id text)
  "Add streamed TEXT to node ID and speak its new sentences."
  (let ((entry (gethash id harness-voice-live--nodes)))
    (unless entry
      (push id harness-voice-live--order)
      (setq entry (list :text "" :sent 0)))
    ;; A live node announcement can already hold the first delta.  The
    ;; chunks accumulate instead, so never count the announcement twice.
    (unless (plist-get entry :chunked)
      (setq entry (list :text "" :sent 0)))
    (puthash id (plist-put (plist-put entry :text (concat (plist-get entry :text) text))
                           :chunked t)
             harness-voice-live--nodes))
  (harness-voice-live--drain-node id nil))

(defun harness-voice-live--add-node (id text)
  "Remember TEXT of an announced node ID that streamed no chunks."
  (let ((entry (gethash id harness-voice-live--nodes)))
    (cond
     ((and entry (plist-get entry :chunked)) nil)
     (t
      (unless entry (push id harness-voice-live--order))
      (puthash id (list :text (or text "") :sent 0 :announced t)
               harness-voice-live--nodes)))))

(defun harness-voice-live--reply-text ()
  "Return this turn's assistant text in arrival order."
  (mapconcat (lambda (id) (or (plist-get (gethash id harness-voice-live--nodes) :text) ""))
             (reverse harness-voice-live--order) ""))

;;;; Delegation

(defun harness-voice-live--context ()
  "Return the context sent with the session and its delegations."
  (or (and (buffer-live-p harness-voice-live--buffer)
           (buffer-local-value 'harness-voice--live-context harness-voice-live--buffer))
      (and (buffer-live-p harness-voice-live--buffer)
           (with-current-buffer harness-voice-live--buffer
             (harness-voice--context)))
      ""))

(defun harness-voice-live--prompt (text)
  "Return the agent prompt for delegated TEXT."
  (let ((context (or (harness-voice-live--context) "")))
    (if (string-empty-p context) text (concat context "\n" text))))

(defun harness-voice-live--delegate-next ()
  "Send the next delegation to the agent, unless one is running."
  (when (and (null harness-voice-live--delegation)
             harness-voice-live--delegations
             (harness-voice-live--active-p)
             (buffer-live-p harness-voice-live--buffer)
             (equal (buffer-local-value 'harness-ui-session-id harness-voice-live--buffer)
                    harness-voice-live--session))
    (let* ((job (pop harness-voice-live--delegations))
           (id (plist-get job :id))
           (text (plist-get job :text)))
      (setq harness-voice-live--delegation (list :id id)
            harness-voice-live--working t
            harness-voice-live--turn-active t
            harness-voice-live--nodes (make-hash-table :test 'equal)
            harness-voice-live--order nil)
      (harness-voice-live--send (list :event "thinking" :text "Agent turn started"))
      (harness-voice-live--stage-set 'thinking)
      (harness-voice-live--refresh)
      (condition-case err
          (harness-ui-call-turn harness-voice-live--session "session/prompt"
                                (list :sessionId harness-voice-live--session
                                      :prompt (list (list :type "text"
                                                          :text (harness-voice-live--prompt
                                                                 text))))
                                #'ignore
                                (lambda (error)
                                  (harness-voice-live--delegate-error id error)))
        (error
         (harness-voice-live--delegate-error id err))))))

(defun harness-voice-live--delegate-error (id error)
  "Report that delegation ID failed with ERROR."
  (when (and (equal id (plist-get harness-voice-live--delegation :id)))
    (setq harness-voice-live--delegation nil
          harness-voice-live--working nil
          harness-voice-live--turn-active nil)
    (harness-voice-live--send
     (list :event "delegate_result" :id id :text ""
           :error t :message (harness-ui-one-line (harness-error-message error))))
    (harness-voice-live--refresh)
    (harness-voice-live--delegate-next)))

(defun harness-voice-live--delegate (event)
  "Start a delegation from EVENT, or queue it behind the running turn."
  (let* ((id (or (plist-get event :id) (format "d-%s" (float-time))))
         (text (or (plist-get event :text) (plist-get event :prompt) ""))
         (text (if (string-empty-p text) harness-voice-live--heard text)))
    (setq harness-voice-live--heard "")
    (if (string-empty-p text)
        (harness-voice-live--send
         (list :event "delegate_result" :id id :text ""
               :error t :message "Live voice delegation empty"))
      (setq harness-voice-live--delegations
            (nconc harness-voice-live--delegations (list (list :id id :text text))))
      (harness-voice-live--delegate-next))))

(defun harness-voice-live--finish-turn (outcome)
  "Finish the agent turn that ended with OUTCOME."
  (let ((cancelled (member outcome '("cancelled" "error" "failed")))
        (delegation harness-voice-live--delegation)
        (text nil))
    (if cancelled
        (progn
          (setq harness-voice-live--working nil
                harness-voice-live--turn-active nil
                harness-voice-live--delegation nil
                harness-voice-live--nodes nil
                harness-voice-live--order nil)
          (when delegation
            (harness-voice-live--send
             (list :event "delegate_result"
                   :id (plist-get delegation :id) :text ""
                   :error t :message (or outcome "cancelled")))))
      (maphash (lambda (id _entry)
                 (harness-voice-live--drain-node id t))
               (or harness-voice-live--nodes (make-hash-table)))
      (setq text (harness-voice-live--reply-text)
            harness-voice-live--working nil
            harness-voice-live--turn-active nil
            harness-voice-live--delegation nil)
      (when delegation
        (harness-voice-live--send
         (list :event "delegate_result"
               :id (plist-get delegation :id) :text text)))
      (setq harness-voice-live--nodes nil
            harness-voice-live--order nil))
    ;; A turn that ends while another delegation waits stays in Working:
    ;; the next turn starts at once.
    (unless (or (eq harness-voice-live--state 'speaking)
                harness-voice-live--delegations)
      (harness-voice-live--stage-set
       (cond ((not (harness-voice-live--active-p)) nil)
             (harness-voice-live--muted 'muted)
             (t 'listening))))
    (harness-voice-live--refresh)
    (harness-voice-live--delegate-next)))

;;;; Agent updates and events

(defun harness-voice-live--on-update (sid update)
  "Follow live assistant text for session SID from UPDATE."
  (when (and (harness-voice-live-p)
             (harness-voice-live--active-p)
             (equal sid harness-voice-live--session))
    (pcase (plist-get update :sessionUpdate)
      ("_harness/session_deleted" (harness-voice-live-stop))
      ((or "agent_message_chunk" "_harness/node" "tool_call")
       (when harness-voice-live--turn-active
         (pcase (plist-get update :sessionUpdate)
           ("agent_message_chunk"
            (let ((id (plist-get (plist-get update :_harness) :nodeId))
                  (text (plist-get (plist-get update :content) :text)))
              (when (and id (stringp text))
                (harness-voice-live--add-chunk id text))))
           ("_harness/node"
            (let ((node (plist-get update :node)))
              (when (equal (format "%s" (plist-get node :kind)) "assistant")
                (harness-voice-live--add-node (plist-get node :id)
                                              (plist-get node :content)))))
           ("tool_call"
            (when-let* ((title (plist-get update :title)))
              (harness-voice-live--transcript-tool title)
              (harness-voice-live--send
               (list :event "thinking" :text (format "Tool call: %s" title)))))))))))

(defun harness-voice-live--on-event (event args)
  "Follow agent EVENT with ARGS while a live session runs."
  (when (and (harness-voice-live-p)
             (harness-voice-live--active-p)
             (equal (car args) harness-voice-live--session))
    (pcase event
      ("agent/turn-started"
       (unless harness-voice-live--turn-active
         (setq harness-voice-live--nodes (make-hash-table :test 'equal)
               harness-voice-live--order nil))
       (setq harness-voice-live--turn-active t
             harness-voice-live--working t)
       (harness-voice-live--refresh))
      ("agent/turn-ended"
       (harness-voice-live--finish-turn (cadr args)))
      ((or "_harness/session_deleted" "session/deleted")
       (harness-voice-live-stop)))))

;;;; Sidecar events

(defun harness-voice-live--handle (event)
  "Handle one parsed sidecar EVENT."
  (pcase (plist-get event :event)
    ("ready"
     (when (eq harness-voice-live--state 'starting)
       (when (timerp harness-voice-live--timer)
         (cancel-timer harness-voice-live--timer))
       (setq harness-voice-live--timer nil
             harness-voice-live--state 'listening)
       (harness-voice-live--stage-set 'listening)
       (harness-voice-live--refresh)))
    ("listening"
     (setq harness-voice-live--state 'listening)
     (unless (memq harness-voice-live--stage '(hearing transcribing thinking))
       (harness-voice-live--stage-set (if harness-voice-live--muted 'muted 'listening)))
     (harness-voice-live--refresh))
    ("hearing"
     (setq harness-voice-live--state 'listening)
     (harness-voice-live--stage-set 'hearing)
     (harness-voice-live--refresh))
    ("transcribing"
     (setq harness-voice-live--state 'listening)
     (harness-voice-live--stage-set 'transcribing)
     (harness-voice-live--refresh))
    ("speaking"
     (setq harness-voice-live--state 'speaking)
     (harness-voice-live--stage-set 'speaking)
     (harness-voice-live--refresh))
    ((or "user_delta" "assistant_delta")
     (let ((text (or (plist-get event :text) ""))
           (final (plist-get event :final)))
       (if (equal (plist-get event :event) "user_delta")
           (progn
             (setq harness-voice-live--heard
                   (concat harness-voice-live--heard text))
             (unless (eq harness-voice-live--stage 'transcribing)
               (harness-voice-live--stage-set 'hearing))
             (harness-voice-live--caption "You" text final))
         (harness-voice-live--caption "Voice" text final))))
    ("backchannel"
     (harness-voice-live--backchannel (or (plist-get event :text) "mm-hmm")))
    ("delegation"
     (harness-voice-live--stage-set 'thinking)
     (harness-voice-live--delegate event))
    ("interrupted"
     (setq harness-voice-live--state 'interrupted)
     (harness-voice-live--stage-set (if harness-voice-live--working 'thinking 'listening))
     (harness-voice-live--refresh))
    ("error"
     (harness-voice-live--fail
      (format "Live voice failed · %s"
              (or (plist-get event :message) "sidecar error"))))
    ("closed"
     (setq harness-voice-live--closing t)
     (harness-voice-live--dispose)
     (setq harness-voice-live--state nil
           harness-voice-live--closing nil)
     (harness-voice-live--clear-turn)
     (harness-voice-live--refresh))))

;;;; Commands

(defun harness-voice-live--start-here ()
  "Start live voice, showing validation failures in the controls."
  (interactive)
  (condition-case err
      (harness-voice-live-start)
    (error
     (setq harness-voice--controls t
           harness-voice-live--state 'failed
           harness-voice-live--error (harness-ui-one-line (error-message-string err)))
     (harness-voice-live--refresh))))

;;;###autoload
(defun harness-voice-live-start ()
  "Start the live sidecar session for this compose box."
  (interactive)
  (unless (harness-voice-live-p)
    (user-error "Live voice provider unavailable"))
  (unless harness-ui-session-id
    (user-error "Live voice session unavailable"))
  (when (harness-voice-live--active-p)
    (user-error "Live voice active"))
  (unless (harness-compose-live-p)
    (user-error "Live voice compose unavailable"))
  (unless harness-voice-mode (harness-voice-mode 1))
  (let ((command (harness-voice-live--command))
        (stderr (generate-new-buffer " *harness-voice-live-errors*")))
    (harness-voice--adopt)
    (setq harness-voice-live--buffer (current-buffer)
          harness-voice-live--session harness-ui-session-id
          harness-voice-live--stderr stderr
          harness-voice-live--state 'starting
          harness-voice-live--error nil
          harness-voice-live--muted nil
          harness-voice-live--closing nil
          harness-voice-live--tail ""
          harness-voice-live--speaker nil)
    (harness-voice-live--clear-turn)
    (when (buffer-live-p harness-voice-live--transcript)
      (with-current-buffer harness-voice-live--transcript
        (let ((inhibit-read-only t)) (erase-buffer))))
    (condition-case err
        (let ((process
               (make-process
                :name "harness-voice-live" :command command
                :connection-type 'pipe :coding 'utf-8-unix :noquery t
                :buffer nil :stderr stderr
                :filter #'harness-voice-live--filter
                :sentinel #'harness-voice-live--finished)))
          (setq harness-voice-live--process process)
          (harness-voice-live--start-timer harness-voice-live-startup-timeout
                                           #'harness-voice-live--startup-timeout)
          (process-send-string
           process
           (harness-voice-live--json
            (list :event "start" :protocol harness-voice-live--protocol
                  :context (harness-voice-live--context)))))
      (error
       (harness-voice-live--dispose)
       (setq harness-voice-live--state 'failed
             harness-voice-live--error (harness-ui-one-line (error-message-string err)))))
    (harness-voice-live--refresh)))

;;;###autoload
(defun harness-voice-live-stop ()
  "End the live sidecar session."
  (interactive)
  (unless (eq harness-voice-live--state 'ending)
    (cond
     ((harness-voice-live--active-p)
      (setq harness-voice-live--state 'ending
            harness-voice-live--closing t
            harness-voice-live--working nil)
      (harness-voice-live--send (list :event "stop"))
      (harness-voice-live--start-timer harness-voice-live--stop-timeout
                                       #'harness-voice-live--stop-timeout)
      (harness-voice-live--refresh))
     (harness-voice-live--state
      (harness-voice-live--dispose)
      (setq harness-voice-live--state nil
            harness-voice-live--closing nil)
      (harness-voice-live--clear-turn)
      (harness-voice-live--refresh)))
    (let ((buffer harness-voice-live--buffer))
      (when (and (buffer-live-p buffer)
                 (buffer-local-value 'harness-voice-mode buffer))
        (with-current-buffer buffer (harness-voice-mode -1))))))

;;;###autoload
(defun harness-voice-live-toggle ()
  "Start a live session, or end the running one."
  (interactive)
  (if (harness-voice-live--active-p)
      (harness-voice-live-stop)
    (harness-voice-live--start-here)))

;;;###autoload
(defun harness-voice-live-interrupt ()
  "Stop live playback now, without cancelling the agent turn."
  (interactive)
  (unless (harness-voice-live--active-p)
    (user-error "Live voice inactive"))
  (harness-voice-live--send (list :event "interrupt"))
  (setq harness-voice-live--state 'interrupted)
  (harness-voice-live--stage-set (if harness-voice-live--working 'thinking 'listening))
  (harness-voice-live--refresh))

;;;###autoload
(defun harness-voice-live-mute ()
  "Mute or unmute the live sidecar microphone."
  (interactive)
  (unless (harness-voice-live--active-p)
    (user-error "Live voice inactive"))
  (setq harness-voice-live--muted (not harness-voice-live--muted))
  (harness-voice-live--send
   (list :event "mute" :on (if harness-voice-live--muted :false t)))
  (when (memq harness-voice-live--stage '(listening muted))
    (harness-voice-live--stage-set (if harness-voice-live--muted 'muted 'listening)))
  (harness-voice-live--refresh))

;;;###autoload
(defun harness-voice-live-cancel ()
  "Cancel the agent turn without stopping live playback."
  (interactive)
  (unless (and (harness-voice-live--active-p) harness-voice-live--session)
    (user-error "Live voice session unavailable"))
  (harness-ui-notify "session/cancel" (list :sessionId harness-voice-live--session)))

(defun harness-voice-live--reset ()
  "Stop the sidecar and discard its transcripts, on reload or redaction."
  (when (harness-voice-live--active-p)
    (harness-voice-live--dispose))
  (let ((buffer harness-voice-live--buffer))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when harness-voice-mode (setq harness-voice-mode nil)))))
  (setq harness-voice-live--state nil
        harness-voice-live--error nil
        harness-voice-live--muted nil
        harness-voice-live--closing nil
        harness-voice-live--buffer nil
        harness-voice-live--session nil
        harness-voice-live--speaker nil
        harness-voice-live--section nil
        harness-voice-live--stage nil
        harness-voice-live--stage-since nil)
  (harness-voice-live--clear-turn)
  (when (buffer-live-p harness-voice-live--transcript)
    (kill-buffer harness-voice-live--transcript))
  (setq harness-voice-live--transcript nil))

(provide 'harness-ui-voice-live)
;;; harness-ui-voice-live.el ends here
