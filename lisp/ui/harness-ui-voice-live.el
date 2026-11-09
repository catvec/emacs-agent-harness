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
;; A delegation becomes a distilled request in the current chat, through
;; the normal `session/prompt' path; the raw words stay in the voice
;; conversation and the transcript, and a request that points at an
;; earlier voice turn carries the last few turns with it.  Assistant text
;; streams back as speakable commentary; the turn's full text is the
;; delegate result.  Permissions and questions stay on screen: the
;; sidecar may say that approval is needed, never approve anything.
;; Interruption stops playback only; cancelling the agent turn is a
;; separate command.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-voice-conversation)
(require 'harness-ui-voice-pipeline)

(declare-function harness-voice--adopt "harness-ui-voice")
(declare-function harness-voice--button "harness-ui-voice")
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
(defvar harness-voice-live--conversation (harness-voice-conversation-create)
  "The voice conversation of the current call.
It keeps the raw words and the distilled request of every user
utterance, and what the voice actually spoke.  It is cleared when the
call ends, so a new call starts empty while the chat keeps its own
history.")
(defvar harness-voice-live--speech-active nil
  "Non-nil while the sidecar hears a person speaking right now.")
(defvar harness-voice-live--held nil
  "Assistant text held while speech owns the floor.
Each item is a plist of :id, :text and :turn, newest first.  It is
reported with the next transcript and never spoken after a real
utterance ends.")
(defvar harness-voice-live--held-timer nil
  "Timer that releases held text after a false trigger, or nil.")
(defvar harness-voice-live--turn-id nil
  "Id of the delegation whose output is arriving now.")
(defvar harness-voice-live--seen (make-hash-table :test 'equal)
  "Utterance keys already delivered to the session.")
(defvar harness-voice-live--held-seq 0
  "Counter for held pieces that came without an id.")

(defcustom harness-voice-live-motion t
  "Whether the voice controls animate.
Waiting for speech, a transcript or a turn is drawn as a spinner while
this is non-nil.  nil keeps the stage's glyph still; the stage's word
and every fact of the pipeline stay the same, in the header line, the
strip and its summary, so nothing is lost without the motion."
  :type 'boolean
  :group 'harness-voice)

(defcustom harness-voice-live-pending-release-delay 1.5
  "Seconds to keep held output after a speech trigger with no utterance.

A tap on the microphone can cross the onset threshold without becoming
words.  Cancellation of such a trigger is reported as listening, and the
held reply is released after this delay.  A real utterance sends
transcribing instead, which cancels the timer; its reply becomes pending
context and is never replayed blindly."
  :type 'number
  :group 'harness-voice)
(defvar harness-voice-live--transcript nil "The live caption buffer, or nil.")
(defvar harness-voice-live--speaker nil "Speaker of the caption line being written.")
(defvar harness-voice-live--section nil "Section of the transcript being written.")
(defvar harness-voice-live--stage nil
  "What the session is doing now.
One of nil, `listening', `hearing', `transcribing', `holding', `thinking',
`speaking', `muted' or `failed'.  The stage is what the controls, the
stage line and the timer read; the state is what the sidecar reported.")
(defvar harness-voice-live--stage-since nil "Time the current stage began.")
(defvar harness-voice-live--stage-timer nil "Timer animating an active stage.")
(defvar harness-voice-live--stage-frame 0 "Frame of the busy indicator.")
(defvar harness-voice-live--pipeline (harness-voice-pipeline-create 'off)
  "The pipeline this session draws: the level, the bursts, the turn, the speaker.")
(defvar harness-voice-live--pipeline-timer nil
  "Timer coalescing the pipeline's redraws, or nil.")
(defvar harness-voice-live--pipeline-stale-timer nil
  "Timer that redraws the meter when its last level goes stale, or nil.")
(defvar harness-voice-live--pipeline-controls-at nil
  "Time the compose line was last redrawn for a level, or nil.")
(defvar harness-voice-live--utterance nil
  "The segment id the captions now arriving belong to, or nil.")
(defvar harness-voice-live--utterance-done nil
  "The segment id whose captions are final and wait for their turn, or nil.")
(defvar harness-voice-live--caption-seq 0
  "Counter for captions that arrive without an utterance id.")
(defvar harness-voice-live--reply-seq 0
  "Counter for playback that arrives without a reply id.")
(defconst harness-voice-live--spinner
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Braille frames of the busy indicator.
A frame every fifth of a second is the oldest trick there is to make a
wait look alive, and it costs one character.")

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
    ('holding "Holding reply")
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
   ((and (harness-voice-live--busy-p) harness-voice-live--stage-timer
         harness-voice-live-motion)
    (aref harness-voice-live--spinner
          (mod harness-voice-live--stage-frame (length harness-voice-live--spinner))))
   ((eq harness-voice-live--stage 'speaking) "▷")
   ((eq harness-voice-live--stage 'holding) "‖")
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
    ((eq harness-voice-live--stage 'holding) " · Holding reply")
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
      (let ((room (max 1 (- (/ (harness-compose--room) (frame-char-width)) 3))))
        (concat (harness-ui-settings-line (list items) room)
                ;; The pipeline is a line of its own under the controls:
                ;; one settings line cannot fit both, and the strip must
                ;; stay readable at a narrow width.
                (when (and active (> room 20))
                  (concat "\n" (harness-voice-pipeline-compact-line
                                harness-voice-live--pipeline room))))))))

;; The rule closes the pipeline block, above the transcript it belongs to.
(defconst harness-voice-live--transcript-rule
  (propertize (make-string 58 ?─) 'face 'harness-dim-face)
  "The rule under the transcript's stage line.")

;;;; The pipeline

(defvar-local harness-voice-live--pipeline-end nil
  "Marker at the end of the pipeline block in the transcript buffer.")
(defvar-local harness-voice-live--pipeline-details nil
  "Non-nil when the transcript shows every marker of the pipeline.")

(defun harness-voice-live--pipeline-generation ()
  "Return the generation of the pipeline this session feeds."
  (harness-voice-pipeline-generation harness-voice-live--pipeline))

(defun harness-voice-live--pipeline-bump (capture)
  "Begin a new pipeline, with the microphone in CAPTURE state."
  (harness-voice-pipeline-bump harness-voice-live--pipeline capture)
  (setq harness-voice-live--utterance nil
        harness-voice-live--utterance-done nil
        harness-voice-live--caption-seq 0
        harness-voice-live--reply-seq 0
        harness-voice-live--pipeline-controls-at nil)
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-touch (&optional controls)
  "Note that the pipeline changed.
The strip is redrawn once the current events are handled, and only
while a window shows it.  CONTROLS also refreshes the compose box's
line, at most four times a second: levels arrive ten times a second,
which is the meter's rate, not the transcript's."
  (when (buffer-live-p harness-voice-live--transcript)
    (unless (timerp harness-voice-live--pipeline-timer)
      (setq harness-voice-live--pipeline-timer
            (run-at-time 0.1 nil #'harness-voice-live--pipeline-redraw))))
  (when controls
    (let ((now (float-time)))
      (when (or (null harness-voice-live--pipeline-controls-at)
                (>= (- now harness-voice-live--pipeline-controls-at) 0.25))
        (setq harness-voice-live--pipeline-controls-at now)
        (harness-voice-live--refresh)))))

(defun harness-voice-live--pipeline-redraw ()
  "Redraw the pipeline strip now, when a window shows it."
  (setq harness-voice-live--pipeline-timer nil)
  (when (buffer-live-p harness-voice-live--transcript)
    (with-current-buffer harness-voice-live--transcript
      (when (get-buffer-window (current-buffer) t)
        (harness-voice-live--pipeline-draw)))))

(defun harness-voice-live-pipeline-details ()
  "Show or hide every marker of the voice pipeline."
  (interactive)
  (let ((buffer (if (buffer-live-p harness-voice-live--transcript)
                    harness-voice-live--transcript
                  (current-buffer))))
    (with-current-buffer buffer
      (setq harness-voice-live--pipeline-details
            (not harness-voice-live--pipeline-details))
      (harness-voice-live--pipeline-draw))))

(defun harness-voice-live--pipeline-block (width)
  "Return the pipeline block's lines for a window WIDTH wide."
  (append
   (harness-voice-pipeline-block harness-voice-live--pipeline width)
   (list (harness-ui-action-button
          (if harness-voice-live--pipeline-details "[Hide details]" "[Pipeline details]")
          #'harness-voice-live-pipeline-details
          :help "Pipeline details"))
   (when harness-voice-live--pipeline-details
     (append (list "")
             (list (propertize "Pipeline details" 'face 'harness-label-face))
             (harness-voice-pipeline-details harness-voice-live--pipeline)))
   (list harness-voice-live--transcript-rule)))

(defun harness-voice-live--pipeline-draw ()
  "Draw the pipeline block at the top of the transcript buffer."
  (when (buffer-live-p harness-voice-live--transcript)
    (with-current-buffer harness-voice-live--transcript
      (let* ((inhibit-read-only t)
             (buffer-undo-list t)
             (window (get-buffer-window (current-buffer) t))
             (width (if window (window-width window) harness-voice-pipeline-width))
             (end (and (markerp harness-voice-live--pipeline-end)
                       (marker-position harness-voice-live--pipeline-end))))
        (save-excursion
          (goto-char (point-min))
          (delete-region (point-min) (or end (point-min)))
          (insert (string-join (harness-voice-live--pipeline-block width) "\n") "\n")
          (unless (markerp harness-voice-live--pipeline-end)
            (setq-local harness-voice-live--pipeline-end (copy-marker (point))))
          (set-marker harness-voice-live--pipeline-end (point))
          (force-mode-line-update t))))))

(defun harness-voice-live--pipeline-level (level)
  "Record the capture path's LEVEL, and stop claiming it when it goes stale."
  (when (numberp level)
    (harness-voice-pipeline-set-level harness-voice-live--pipeline level nil
                                      (harness-voice-live--pipeline-generation))
    (harness-voice-live--pipeline-touch t)
    (when (timerp harness-voice-live--pipeline-stale-timer)
      (cancel-timer harness-voice-live--pipeline-stale-timer))
    (setq harness-voice-live--pipeline-stale-timer
          (run-at-time (+ harness-voice-pipeline-level-timeout 0.05) nil
                       #'harness-voice-live--pipeline-stale))))

(defun harness-voice-live--pipeline-stale ()
  "Redraw after a level stopped arriving: the meter says it has no data."
  (setq harness-voice-live--pipeline-stale-timer nil)
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-speech (active)
  "Record whether the speech gate hears speech now, ACTIVE."
  (harness-voice-pipeline-set-gate harness-voice-live--pipeline (and active t)
                                   (harness-voice-live--pipeline-generation))
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-reason (reason)
  "Return REASON as the symbol the pipeline names."
  (and (stringp reason)
       (not (string-empty-p reason))
       (intern (replace-regexp-in-string "[ \t]+" "-" (string-trim reason)))))

(defun harness-voice-live--pipeline-segment (event)
  "Record one sidecar `segment' EVENT: a burst's own decision."
  (let ((id (plist-get event :id))
        (state (plist-get event :state)))
    (when (stringp id)
      (let ((stage (pcase state
                     ("accepted" 'accepted)
                     ("transcribing" 'transcribing)
                     ("transcribed" 'transcribed)
                     ("in-turn" 'in-turn)
                     ("answered" 'answered)
                     ("dropped" 'dropped)
                     ("failed" 'failed))))
        (when stage
          (harness-voice-pipeline-segment
           harness-voice-live--pipeline id stage
           (list :seconds (plist-get event :seconds)
                 :reason (harness-voice-live--pipeline-reason (plist-get event :reason))
                 :text (plist-get event :text)
                 :generation (harness-voice-live--pipeline-generation)))
          (cond
           ((eq stage 'transcribing)
            (setq harness-voice-live--utterance id
                  harness-voice-live--utterance-done nil))
           ;; A final caption waits for its turn; a stale one names a
           ;; segment the next delegation is not about, so it is ignored.
           ((memq stage '(transcribed dropped failed))
            (when (equal id harness-voice-live--utterance)
              (setq harness-voice-live--utterance nil)
              (when (eq stage 'transcribed)
                (setq harness-voice-live--utterance-done id)))))
          (harness-voice-live--pipeline-touch t))))))

(defun harness-voice-live--pipeline-caption (text final)
  "Record the provider's caption TEXT, FINAL when it is the last.
The provider's transcript is its own segment (`v-N') when the sidecar
sent no utterance id: it is the unit a caption arrived in, not a claim
that one burst of the gate became one transcript."
  (when (and (stringp text) (not (string-empty-p text)))
    (unless harness-voice-live--utterance
      (cl-incf harness-voice-live--caption-seq)
      (setq harness-voice-live--utterance
            (format "v-%d" harness-voice-live--caption-seq)
            harness-voice-live--utterance-done nil))
    (harness-voice-pipeline-segment
     harness-voice-live--pipeline harness-voice-live--utterance
     (if final 'transcribed 'transcribing)
     (list :text text :generation (harness-voice-live--pipeline-generation)))
    (when final
      (setq harness-voice-live--utterance-done harness-voice-live--utterance
            harness-voice-live--utterance nil))
    (harness-voice-live--pipeline-touch t)))

(defun harness-voice-live--pipeline-turn-sent (id)
  "Record that turn ID was handed to the session."
  (let* ((segment (or harness-voice-live--utterance harness-voice-live--utterance-done))
         (generation (harness-voice-live--pipeline-generation)))
    (harness-voice-pipeline-turn harness-voice-live--pipeline id 'working
                                 (list :segment segment :generation generation))
    (when segment
      (harness-voice-pipeline-segment harness-voice-live--pipeline segment 'in-turn
                                      (list :generation generation))
      (when (equal segment harness-voice-live--utterance-done)
        (setq harness-voice-live--utterance-done nil)))
    (harness-voice-live--pipeline-touch t)))

(defun harness-voice-live--pipeline-turn-queued (id)
  "Record that turn ID waits behind the running turn."
  (harness-voice-pipeline-turn harness-voice-live--pipeline id 'queued
                               (list :segment (or harness-voice-live--utterance
                                                  harness-voice-live--utterance-done)
                                     :generation (harness-voice-live--pipeline-generation)))
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-turn-ended (state &optional detail)
  "Record that the turn in flight ended in STATE, with DETAIL."
  (when harness-voice-live--turn-id
    (harness-voice-pipeline-turn
     harness-voice-live--pipeline harness-voice-live--turn-id state
     (list :detail detail :generation (harness-voice-live--pipeline-generation)))
    (harness-voice-live--pipeline-touch t)))

(defun harness-voice-live--pipeline-reply-id (piece)
  "Return the reply id a speakable PIECE belongs to.
A streamed answer is named by its node, `n-3:120' by its node and
offset; a whole held result is one piece of its own."
  (let ((piece (or piece "")))
    (if (string-prefix-p "result:" piece)
        piece
      (car (split-string piece ":")))))

(defun harness-voice-live--pipeline-reply-ready (id text)
  "Record that reply ID is ready to be spoken, with TEXT as its words."
  (when (and (stringp id) (not (string-empty-p id)))
    (let ((generation (harness-voice-live--pipeline-generation)))
      (harness-voice-pipeline-reply harness-voice-live--pipeline id 'ready
                                    (list :text (and text (string-trim text))
                                          :turn harness-voice-live--turn-id
                                          :generation generation))
      (when harness-voice-live--turn-id
        (harness-voice-pipeline-turn
         harness-voice-live--pipeline harness-voice-live--turn-id 'replied
         (list :reply id :generation generation)))
      (harness-voice-live--pipeline-touch t))))

(defun harness-voice-live--pipeline-reply-held (piece)
  "Record that the reply of speakable PIECE is held for turn-taking."
  (harness-voice-pipeline-reply
   harness-voice-live--pipeline (harness-voice-live--pipeline-reply-id piece) 'held
   (list :generation (harness-voice-live--pipeline-generation)))
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-reply-handed (piece)
  "Record that the reply of speakable PIECE was handed to the provider."
  (harness-voice-pipeline-reply
   harness-voice-live--pipeline (harness-voice-live--pipeline-reply-id piece) 'handed
   (list :generation (harness-voice-live--pipeline-generation)))
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-playback (state)
  "Record the provider's playback STATE: speaking, listening or interrupted."
  (let* ((pipeline harness-voice-live--pipeline)
         (generation (harness-voice-live--pipeline-generation))
         (replies (harness-voice-pipeline-replies pipeline)))
    (pcase state
      ('speaking
       (let ((reply (cl-find-if (lambda (reply)
                                  (memq (plist-get reply :stage) '(handed ready)))
                                replies)))
         (unless reply
           ;; The provider reported playback the UI did not hand it a piece
           ;; of: a reply of its own, named so it is not mistaken for one.
           (cl-incf harness-voice-live--reply-seq)
           (let ((id (format "voice-%d" harness-voice-live--reply-seq)))
             (harness-voice-pipeline-reply pipeline id 'ready (list :generation generation))
             (setq reply (cl-find id (harness-voice-pipeline-replies pipeline)
                                  :key (lambda (item) (plist-get item :id)) :test #'equal))))
         (when reply
           (harness-voice-pipeline-reply pipeline (plist-get reply :id) 'speaking
                                         (list :generation generation)))))
      ('listening
       (dolist (reply replies)
         (when (eq (plist-get reply :stage) 'speaking)
           (harness-voice-pipeline-reply pipeline (plist-get reply :id) 'spoken
                                         (list :generation generation)))))
      ('interrupted
       (harness-voice-pipeline-finish-replies pipeline 'interrupted "interrupted"
                                             generation)))
    (harness-voice-live--pipeline-touch t)))

(defun harness-voice-live--pipeline-muted (muted)
  "Record that the microphone is MUTED, or open again."
  (harness-voice-pipeline-set-capture harness-voice-live--pipeline
                                      (if muted 'muted 'live)
                                      nil (harness-voice-live--pipeline-generation))
  (when muted
    (harness-voice-pipeline-finish-replies harness-voice-live--pipeline 'dropped "muted"
                                           (harness-voice-live--pipeline-generation)))
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-end (capture &optional problem)
  "Record that the session stopped with the microphone in CAPTURE.
PROBLEM is the sidecar's own words about a failure.  The markers stay as
the last true picture; what could still be heard is dropped with the
reason it ended."
  (let ((generation (harness-voice-live--pipeline-generation)))
    (harness-voice-pipeline-set-capture harness-voice-live--pipeline capture problem
                                        generation)
    (harness-voice-pipeline-clear-level harness-voice-live--pipeline generation)
    (harness-voice-pipeline-finish-replies harness-voice-live--pipeline 'dropped "ended"
                                           generation)
    (harness-voice-live--pipeline-touch t)))

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
  (harness-voice-conversation-clear harness-voice-live--conversation)
  (when (timerp harness-voice-live--timer)
    (cancel-timer harness-voice-live--timer))
  (when (timerp harness-voice-live--stage-timer)
    (cancel-timer harness-voice-live--stage-timer))
  (when (timerp harness-voice-live--pipeline-timer)
    (cancel-timer harness-voice-live--pipeline-timer))
  (when (timerp harness-voice-live--pipeline-stale-timer)
    (cancel-timer harness-voice-live--pipeline-stale-timer))
  (setq harness-voice-live--timer nil
        harness-voice-live--pipeline-timer nil
        harness-voice-live--pipeline-stale-timer nil
        harness-voice-live--stage-timer nil
        harness-voice-live--stage nil
        harness-voice-live--stage-since nil)
  (harness-voice-live--clear-gate)
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

(defun harness-voice-live--clear-gate ()
  "Forget speech, held output and the release timer."
  (when (timerp harness-voice-live--held-timer)
    (cancel-timer harness-voice-live--held-timer))
  (setq harness-voice-live--held-timer nil
        harness-voice-live--speech-active nil
        harness-voice-live--held nil
        harness-voice-live--turn-id nil))

(defun harness-voice-live--holding-output-p ()
  "Non-nil while assistant text must not be sent to the sidecar."
  (or harness-voice-live--speech-active
      harness-voice-live--held
      (memq harness-voice-live--stage '(hearing transcribing holding))))

(defun harness-voice-live--cancel-held-timer ()
  "Cancel a pending false-trigger release."
  (when (timerp harness-voice-live--held-timer)
    (cancel-timer harness-voice-live--held-timer))
  (setq harness-voice-live--held-timer nil))

(defun harness-voice-live--schedule-held-release ()
  "Release held text after `harness-voice-live-pending-release-delay'.
Only a trigger that produced no utterance schedules this; a real
utterance sends transcribing first, which cancels it."
  (harness-voice-live--cancel-held-timer)
  (when (and harness-voice-live--held
             (not harness-voice-live--speech-active))
    (setq harness-voice-live--held-timer
          (run-at-time harness-voice-live-pending-release-delay nil
                       #'harness-voice-live--release-held))))

(defun harness-voice-live--hold (id text)
  "Hold assistant TEXT with ID until a transcript decides what to do."
  (when (and (stringp text) (not (string-empty-p text)))
    (unless (and id (cl-find id harness-voice-live--held
                             :key (lambda (item) (plist-get item :id))
                             :test #'equal))
      (setq harness-voice-live--held-seq (1+ harness-voice-live--held-seq))
      (harness-voice-live--pipeline-reply-held (or id (format "held-%d" harness-voice-live--held-seq)))
      (push (list :id (or id (format "held-%d" harness-voice-live--held-seq))
                  :text text
                  :turn harness-voice-live--turn-id)
            harness-voice-live--held)
      (when (> (length harness-voice-live--held) 40)
        (setq harness-voice-live--held (seq-take harness-voice-live--held 40))))
    (harness-voice-live--stage-set 'holding)))

(defun harness-voice-live--release-held ()
  "Send held output now; only a false trigger or an explicit resume does."
  (harness-voice-live--cancel-held-timer)
  (let ((items (reverse harness-voice-live--held)))
    (setq harness-voice-live--held nil)
    (dolist (item items)
      (when (harness-voice-live--active-p)
        (harness-voice-live--pipeline-reply-handed (plist-get item :id))
        (harness-voice-live--send
         (list :event "commentary"
               :id (plist-get item :id)
               :text (plist-get item :text)))
        (harness-voice-conversation-say
         harness-voice-live--conversation (plist-get item :text) 'commentary)))
    (unless harness-voice-live--speech-active
      (harness-voice-live--stage-set
       (cond ((not (harness-voice-live--active-p)) nil)
             (harness-voice-live--muted 'muted)
             ((harness-voice-live--holding-output-p) 'holding)
             (t 'listening))))))

(defun harness-voice-live--pending-items (event)
  "Return held output items from EVENT and the client's own held list.
EVENT's `pending' is the sidecar's unspoken queue, already bounded.  The
merge is by id and then by text, so a piece the transport also saw is
reported once."
  (let ((items (append
                (mapcar (lambda (item)
                          (list :id (plist-get item :id)
                                :text (or (plist-get item :text) "")))
                        (append (plist-get event :pending) nil))
                harness-voice-live--held))
        (seen-ids nil)
        (seen-texts nil)
        (result nil))
    (dolist (item items)
      (let ((id (plist-get item :id))
            (text (plist-get item :text)))
        (unless (or (and id (member id seen-ids))
                    (and text (member text seen-texts)))
          (when id (push id seen-ids))
          (when text (push text seen-texts))
          (push item result))))
    (setq harness-voice-live--held nil)
    ;; A full turn result contains the sentence pieces that were held while
    ;; it streamed; keep the larger text, not both.
    (setq result
          (cl-remove-if
           (lambda (item)
             (let ((text (plist-get item :text)))
               (and text
                    (cl-some
                     (lambda (other)
                       (let ((more (plist-get other :text)))
                         (and more
                              (> (length more) (length text))
                              (string-match-p (regexp-quote text) more))))
                     result))))
           result))
    (nreverse result)))

(defun harness-voice-live--pending-context (items)
  "Return the explicit pending-update context for ITEMS, or nil."
  (when items
    (concat "<voice-turn-context>\n"
            "assistant_output: held (not spoken)\n"
            "held_output:\n"
            (mapconcat (lambda (item)
                         (concat "- " (plist-get item :text) "\n"))
                       items "")
            "decision: answer the new speech; fold the held output in only "
            "if it is still relevant; do not assume it was heard.\n"
            "</voice-turn-context>\n")))

(defun harness-voice-live--delegate-key (event)
  "Return the exact-once key of delegation EVENT."
  (or (plist-get event :utterance)
      (plist-get event :id)
      (plist-get event :text)))

(defun harness-voice-live--delegate-seen-p (event)
  "Return non-nil when EVENT's utterance already reached the session."
  (let ((key (harness-voice-live--delegate-key event)))
    (when key
      (if (gethash key harness-voice-live--seen)
          t
        (puthash key t harness-voice-live--seen)
        nil))))

(defun harness-voice-live--fail (detail)
  "Fail the live session visibly with DETAIL."
  (let ((text (harness-ui-one-line detail)))
    (harness-voice-live--pipeline-end 'failed text)
    (harness-voice-live--dispose)
    (setq harness-voice-live--state 'failed
          harness-voice-live--error text
          harness-voice-live--closing nil)
    (harness-voice-live--stage-set 'failed)
    (harness-voice-live--clear-gate)
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
    (harness-voice-live--clear-gate)
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
      (harness-voice-live--clear-gate)
      (harness-voice-live--clear-turn)
      (cond
       (closing
        (setq harness-voice-live--state nil))
       ((eq state 'failed) nil)
       (t
        (setq harness-voice-live--state 'failed
              harness-voice-live--error
              (if tail (format "Live voice ended · %s" tail)
                "Live voice ended"))
        (harness-voice-live--pipeline-end
         'disconnected (if tail (format "Live voice ended · %s" tail)
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

(defvar harness-voice-live--transcript-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "C-c v") #'harness-voice-dictate)
    (define-key map (kbd "C-c V") #'harness-voice-interrupt)
    (define-key map (kbd "d") #'harness-voice-live-pipeline-details)
    map)
  "Key map of the live voice transcript.")

(define-derived-mode harness-voice-live-transcript-mode special-mode "Voice transcript"
  "Mode of the live voice transcript.
The stage line at the top says what the session is doing now, and the
pipeline under it says what reached the microphone, what the speech
filter kept and dropped, what was transcribed, and what the speaker is
doing.  The sections below say what you said, what crossed into the
session (`Sent`, or `Not sent` for a burst of mumbles), what the coding
agent did and what the voice said back.  `d' shows every pipeline marker,
`C-c v' dictates or mutes, `C-c V' interrupts and `q' closes the
buffer."
  (setq-local mode-line-format '(" Voice transcript")))

(defun harness-voice-live--transcript-buffer ()
  "Return the live transcript buffer, making it when needed."
  (unless (buffer-live-p harness-voice-live--transcript)
    (let ((buffer (get-buffer-create "*harness voice*")))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (harness-voice-live-transcript-mode)
          (setq-local header-line-format
                      '(:eval (concat " " (or (harness-voice-live--stage-text) "○ Off")
                                      "   Voice · "
                                      (if (fboundp 'harness-voice-provider-label)
                                          (harness-voice-provider-label harness-voice-provider)
                                        "live")))))
        (setq buffer-read-only t))
      (setq harness-voice-live--section nil
            harness-voice-live--transcript buffer)
      (harness-voice-live--pipeline-draw))
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
                                        ('sent 'harness-label-face)
                                        ('not-sent 'harness-caution-face)
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

(defun harness-voice-live--transcript-sent (text)
  "Show what crossed into the session: TEXT, or that nothing did.
TEXT is the distilled request without its context block.  The raw
caption above it stays as it was heard, so the transcript shows the
voice conversation and the session message as the two different
records they are."
  (if text
      (progn
        (harness-voice-live--transcript-section 'sent "Sent")
        (harness-voice-live--transcript-insert
         (concat "  " text "\n") 'harness-dim-face))
    (harness-voice-live--transcript-section 'not-sent "Not sent")
    (harness-voice-live--transcript-insert
     "  no request\n" 'harness-dim-face)))

;;;###autoload
(defun harness-voice-live-transcript ()
  "Show the live transcript."
  (interactive)
  (unless (buffer-live-p harness-voice-live--transcript)
    (user-error "Live transcript unavailable"))
  (pop-to-buffer harness-voice-live--transcript)
  (harness-voice-live--pipeline-draw)
  (goto-char (point-max)))

;;;; Speaking the agent's reply

(defun harness-voice-live--speak (text &optional id)
  "Send speakable TEXT to the sidecar as commentary, or hold it.

ID names the piece so a held one is not reported twice.  While speech is
active, or until a transcript has decided what the held reply means, the
text stays on this side of the pipe: the sidecar never gets a stale
commentary to speak later."
  (let ((speech (harness-voice--speech-text text))
        (part 0))
    (while (and (not (string-empty-p speech)) (harness-voice-live--active-p))
      (let* ((piece (if (> (length speech) 1200)
                        (substring speech 0 1200)
                      speech))
             (piece-id (and id (format "%s:%d" id part))))
        (setq part (1+ part))
        (if (harness-voice-live--holding-output-p)
            (harness-voice-live--hold piece-id piece)
          (harness-voice-live--pipeline-reply-handed piece-id)
          (harness-voice-live--send
           (list :event "commentary" :id piece-id :text piece))
          (harness-voice-conversation-say
           harness-voice-live--conversation piece 'commentary))
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
      (harness-voice-live--speak (substring text scan end)
                                 (format "%s:%d" id scan))
      (setq scan end))
    (when final
      (when (> (length text) scan)
        (harness-voice-live--speak (substring text scan)
                                   (format "%s:%d" id scan)))
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
             harness-voice-live--nodes)
    (harness-voice-live--pipeline-reply-ready id text))
  (harness-voice-live--drain-node id nil))

(defun harness-voice-live--add-node (id text)
  "Remember TEXT of an announced node ID that streamed no chunks."
  (let ((entry (gethash id harness-voice-live--nodes)))
    (cond
     ((and entry (plist-get entry :chunked)) nil)
     (t
      (unless entry (push id harness-voice-live--order))
      (puthash id (list :text (or text "") :sent 0 :announced t)
               harness-voice-live--nodes)
      (harness-voice-live--pipeline-reply-ready id text)))))

(defun harness-voice-live--reply-text ()
  "Return this turn's assistant text in arrival order."
  (mapconcat (lambda (id) (or (plist-get (gethash id harness-voice-live--nodes) :text) ""))
             (reverse harness-voice-live--order) ""))

;;;; Delegation

(defun harness-voice-live--prompt (text &optional pending)
  "Return the agent prompt for delegated TEXT and held PENDING items.
The request is the first thing in the message.  There is no
related-session lookup and no context block added to a transcript: the
session a voice request is made in is the context, and a request that
needs an earlier voice turn carries that turn itself."
  (let ((block (harness-voice-live--pending-context pending)))
    (concat text
            (when block (concat "\n\n" block)))))

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
            harness-voice-live--turn-id id
            harness-voice-live--working t
            harness-voice-live--turn-active t
            harness-voice-live--nodes (make-hash-table :test 'equal)
            harness-voice-live--order nil)
      (harness-voice-live--pipeline-turn-sent id)
      (harness-voice-live--send (list :event "thinking" :text "Agent turn started"))
      (harness-voice-live--stage-set 'thinking)
      (harness-voice-live--refresh)
      (condition-case err
          (harness-ui-call-turn harness-voice-live--session "session/prompt"
                                (list :sessionId harness-voice-live--session
                                      :prompt (list (list :type "text"
                                                          :text (harness-voice-live--prompt
                                                                 text
                                                                 (plist-get job :pending)))))
                                #'ignore
                                (lambda (error)
                                  (harness-voice-live--delegate-error id error)))
        (error
         (harness-voice-live--delegate-error id err))))))

(defun harness-voice-live--delegate-error (id error)
  "Report that delegation ID failed with ERROR."
  (when (and (equal id (plist-get harness-voice-live--delegation :id)))
    (harness-voice-live--pipeline-turn-ended
     'failed (harness-ui-one-line (harness-error-message error)))
    (setq harness-voice-live--delegation nil
          harness-voice-live--turn-id nil
          harness-voice-live--working nil
          harness-voice-live--turn-active nil)
    (harness-voice-live--send
     (list :event "delegate_result" :id id :text ""
           :error t :message (harness-ui-one-line (harness-error-message error))))
    (harness-voice-live--refresh)
    (harness-voice-live--delegate-next)))

(defun harness-voice-live--delegate (event)
  "Start a delegation from EVENT, or queue it behind the running turn.

The utterance key is delivered once.  The transcript is distilled into
a request; the raw words stay in the voice conversation and the
transcript.  A request that points at an earlier voice turn carries the
last few turns as plain context.  Any assistant output held while the
person spoke travels with this prompt as explicit context; it is never
spoken afterwards merely because the transcript arrived.  A burst that
distils to nothing is recorded and answers its delegation without a
session prompt."
  (let* ((id (or (plist-get event :id) (format "d-%s" (float-time))))
         (text (or (plist-get event :text) (plist-get event :prompt) ""))
         (text (if (string-empty-p text) harness-voice-live--heard text)))
    (if (harness-voice-live--delegate-seen-p event)
        (harness-voice-live--refresh)
      (setq harness-voice-live--heard "")
      (harness-voice-live--cancel-held-timer)
      (let* ((conversation harness-voice-live--conversation)
             (distilled (if harness-voice-distill
                            (harness-voice-distilled-text text)
                          (let ((trimmed (string-trim (or text ""))))
                            (unless (string-empty-p trimmed) trimmed)))))
        (cond
         ((null distilled)
          (if (string-empty-p (string-trim (or text "")))
              (harness-voice-live--send
               (list :event "delegate_result" :id id :text ""
                     :error t :message "Live voice delegation empty"))
            ;; Nothing but mumbles: the voice conversation keeps the
            ;; words, the session gets no request, and the sidecar is
            ;; answered so it does not wait for one.
            (harness-voice-conversation-hear conversation text nil nil)
            (let ((segment (or harness-voice-live--utterance-done
                               harness-voice-live--utterance
                               (and (plist-get event :utterance)
                                    (format "u-%s"
                                            (plist-get event :utterance))))))
              (when segment
                (harness-voice-live--pipeline-segment
                 (list :event "segment" :state "dropped" :id segment
                       :reason "no request"))
                (when (equal segment harness-voice-live--utterance-done)
                  (setq harness-voice-live--utterance-done nil))))
            (harness-voice-live--transcript-sent nil)
            (harness-voice-live--send
             (list :event "delegate_result" :id id :text ""))
            (harness-voice-live--stage-set
             (cond ((not (harness-voice-live--active-p)) nil)
                   (harness-voice-live--muted 'muted)
                   ((harness-voice-live--holding-output-p) 'holding)
                   (t 'listening)))
            (when (harness-voice-live--holding-output-p)
              (harness-voice-live--schedule-held-release))
            (harness-voice-live--refresh)))
         (t
          (let* ((request (harness-voice-conversation-request
                           conversation distilled))
                 (turn (harness-voice-conversation-hear
                        conversation text distilled request))
                 (raw (plist-get turn :raw))
                 (pending (harness-voice-live--pending-items event)))
            ;; Show the crossing only when the session did not get
            ;; exactly what was heard: a changed request, or context.
            (unless (and (equal distilled raw)
                         (equal request distilled))
              (harness-voice-live--transcript-sent distilled))
            (setq harness-voice-live--delegations
                  (nconc harness-voice-live--delegations
                         (list (list :id id :text request :pending pending))))
            (when harness-voice-live--delegation
              (harness-voice-live--pipeline-turn-queued id))
            (harness-voice-live--delegate-next))))))))

(defun harness-voice-live--finish-turn (outcome)
  "Finish the agent turn that ended with OUTCOME."
  (let ((cancelled (member outcome '("cancelled" "error" "failed")))
        (delegation harness-voice-live--delegation)
        (text nil))
    (if cancelled
        (progn
          (harness-voice-live--pipeline-turn-ended 'failed (or outcome "cancelled"))
          (setq harness-voice-live--working nil
                harness-voice-live--turn-active nil
                harness-voice-live--delegation nil
                harness-voice-live--nodes nil
                harness-voice-live--order nil)
          (harness-voice-live--clear-gate)
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
      (harness-voice-live--pipeline-turn-ended (if cancelled 'failed 'done))
      (when delegation
        (if (harness-voice-live--holding-output-p)
            (progn
              ;; Keep the full result as context only when no sentence of
              ;; it was already held; otherwise the pieces are the truth.
              (unless (cl-find (plist-get delegation :id) harness-voice-live--held
                               :key (lambda (item) (plist-get item :turn))
                               :test #'equal)
                (harness-voice-live--hold
                 (format "result:%s" (plist-get delegation :id)) text))
              (harness-voice-live--send
               (list :event "delegate_result"
                     :id (plist-get delegation :id) :text text :held t)))
          (harness-voice-live--send
           (list :event "delegate_result"
                 :id (plist-get delegation :id) :text text))
          (harness-voice-conversation-say
           harness-voice-live--conversation text 'result)))
      (setq harness-voice-live--nodes nil
            harness-voice-live--order nil))
    ;; A turn that ends while another delegation waits stays in Working:
    ;; the next turn starts at once.
    (unless (or (eq harness-voice-live--state 'speaking)
                harness-voice-live--delegations)
      (harness-voice-live--stage-set
       (cond ((not (harness-voice-live--active-p)) nil)
             (harness-voice-live--muted 'muted)
             ((harness-voice-live--holding-output-p) 'holding)
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
    ("level"
     (harness-voice-live--pipeline-level (plist-get event :input)))
    ("segment"
     (harness-voice-live--pipeline-segment event))
    ("ready"
     (when (eq harness-voice-live--state 'starting)
       (when (timerp harness-voice-live--timer)
         (cancel-timer harness-voice-live--timer))
       (setq harness-voice-live--timer nil
             harness-voice-live--state 'listening)
       (harness-voice-pipeline-set-capture
        harness-voice-live--pipeline 'live nil
        (harness-voice-live--pipeline-generation))
       (harness-voice-live--stage-set 'listening)
       (harness-voice-live--pipeline-touch t)
       (harness-voice-live--refresh)))
    ("speech"
     (let ((active (plist-get event :active)))
       (harness-voice-live--pipeline-speech active)
       (when (and active (plist-get event :utterance))
         (harness-voice-live--pipeline-segment
          (list :event "segment" :state "accepted"
                :id (format "u-%s" (plist-get event :utterance)))))
       (setq harness-voice-live--speech-active (and active t))
       (harness-voice-live--cancel-held-timer)
       (when active
         (unless (eq harness-voice-live--stage 'thinking)
           (harness-voice-live--stage-set 'hearing)))
       (harness-voice-live--refresh)))
    ("listening"
     (setq harness-voice-live--state 'listening)
     (harness-voice-live--pipeline-playback 'listening)
     (if (and harness-voice-live--held
              (not harness-voice-live--speech-active))
         (progn
           (harness-voice-live--stage-set 'holding)
           (harness-voice-live--schedule-held-release))
       (unless (memq harness-voice-live--stage
                     '(hearing transcribing holding thinking))
         (harness-voice-live--stage-set
          (if harness-voice-live--muted 'muted 'listening))))
     (harness-voice-live--refresh))
    ("hearing"
     (setq harness-voice-live--state 'listening)
     (when (plist-get event :utterance)
       (let ((id (format "u-%s" (plist-get event :utterance))))
         (unless (equal id harness-voice-live--utterance)
           (setq harness-voice-live--utterance nil
                 harness-voice-live--utterance-done nil))
         (harness-voice-live--pipeline-segment
          (list :event "segment" :state "accepted" :id id))
         (setq harness-voice-live--utterance id)))
     (harness-voice-live--stage-set 'hearing)
     (harness-voice-live--refresh))
    ("transcribing"
     (harness-voice-live--cancel-held-timer)
     (setq harness-voice-live--state 'listening)
     (when (plist-get event :utterance)
       (harness-voice-live--pipeline-segment
        (list :event "segment" :state "transcribing"
              :id (format "u-%s" (plist-get event :utterance)))))
     (harness-voice-live--stage-set 'transcribing)
     (harness-voice-live--refresh))
    ("speaking"
     (setq harness-voice-live--state 'speaking)
     (harness-voice-live--pipeline-playback 'speaking)
     (harness-voice-live--stage-set 'speaking)
     (harness-voice-live--refresh))
    ((or "user_delta" "assistant_delta")
     (let ((text (or (plist-get event :text) ""))
           (final (plist-get event :final)))
       (if (equal (plist-get event :event) "user_delta")
           (progn
             (harness-voice-live--pipeline-caption text final)
             (setq harness-voice-live--heard
                   (concat harness-voice-live--heard text))
             (unless (eq harness-voice-live--stage 'transcribing)
               (harness-voice-live--stage-set 'hearing))
             (harness-voice-live--caption "You" text final))
         (progn
           (harness-voice-live--caption "Voice" text final)
           ;; A provider's own speech, outside the agent's turn, is
           ;; voice-only: the session never saw it.  A turn's result is
           ;; recorded when it is handed back, and held text was not
           ;; heard, so neither is a voice turn here.
           (unless (or (harness-voice-live--holding-output-p)
                       harness-voice-live--turn-active)
             (harness-voice-conversation-say
              harness-voice-live--conversation text 'provider nil t))))))
    ("backchannel"
     (let ((text (or (plist-get event :text) "mm-hmm")))
       (harness-voice-live--backchannel text)
       (harness-voice-conversation-say
        harness-voice-live--conversation text 'backchannel)))
    ("delegation"
     (harness-voice-live--cancel-held-timer)
     (harness-voice-live--stage-set 'thinking)
     (harness-voice-live--delegate event))
    ("interrupted"
     (harness-voice-live--cancel-held-timer)
     (setq harness-voice-live--held nil)
     (harness-voice-live--pipeline-playback 'interrupted)
     (setq harness-voice-live--state 'interrupted)
     (harness-voice-live--stage-set
      (cond (harness-voice-live--speech-active 'hearing)
            (harness-voice-live--working 'thinking)
            (t 'listening)))
     (harness-voice-live--refresh))
    ("error"
     (harness-voice-live--pipeline-end
      'failed (format "Live voice failed · %s"
                      (or (plist-get event :message) "sidecar error")))
     (harness-voice-live--fail
      (format "Live voice failed · %s"
              (or (plist-get event :message) "sidecar error"))))
    ("closed"
     (harness-voice-live--pipeline-end 'ended)
     (setq harness-voice-live--closing t)
     (harness-voice-live--dispose)
     (setq harness-voice-live--state nil
           harness-voice-live--closing nil)
     (harness-voice-live--clear-turn)
     (harness-voice-live--refresh))))

;;;; Commands

(defun harness-voice-live--last-frame-p (frame frames)
  "Return non-nil when FRAME is the last of FRAMES that can show the UI.
A graphic frame counts against the other graphic frames; a terminal
frame counts against every frame.  A daemon keeps an unseen terminal
frame after its last graphical window closes, and voice must not hold
the microphone and the speaker for a window nobody can see."
  (let ((graphic (display-graphic-p frame)))
    (null (seq-filter (lambda (other)
                        (and (not (eq other frame))
                             (if graphic (display-graphic-p other) t)))
                      frames))))

(defun harness-voice-live--frame-deleted (frame)
  "End live voice when FRAME was the last frame that could show it.
Closing the Emacs window must stop the sound: the sidecar owns the
microphone and the speaker, and a reply playing on to an empty desktop
cannot be interrupted from the UI that is gone."
  (when (and (harness-voice-live--active-p)
             (harness-voice-live--last-frame-p frame (frame-list)))
    (harness-voice-live-stop)))

(defun harness-voice-live--start-here ()
  "Start live voice, showing validation failures in the controls."
  (interactive)
  (condition-case err
      (harness-voice-live-start)
    (error
     (setq harness-voice--controls t
           harness-voice-live--state 'failed
           harness-voice-live--error (harness-ui-one-line (error-message-string err)))
     ;; The failure can come before the sidecar's buffer is recorded, so
     ;; refresh this compose box directly: otherwise the control still
     ;; reads Off with a Start button that seems to do nothing.
     (harness-voice--refresh))))

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
    (harness-voice-live--pipeline-bump 'connecting)
    (setq harness-voice-live--buffer (current-buffer)
          harness-voice-live--session harness-ui-session-id
          harness-voice-live--stderr stderr
          harness-voice-live--state 'starting
          harness-voice-live--error nil
          harness-voice-live--muted nil
          harness-voice-live--closing nil
          harness-voice-live--tail ""
          harness-voice-live--speaker nil
          harness-voice-live--seen (make-hash-table :test 'equal)
          harness-voice-live--held-seq 0)
    (harness-voice-live--clear-gate)
    (harness-voice-live--clear-turn)
    (when (buffer-live-p harness-voice-live--transcript)
      (with-current-buffer harness-voice-live--transcript
        (let ((inhibit-read-only t)) (erase-buffer))
        (setq-local harness-voice-live--pipeline-end nil))
      (harness-voice-live--pipeline-draw))
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
            (list :event "start" :protocol harness-voice-live--protocol))))
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
      (harness-voice-live--pipeline-end 'ended)
      (harness-voice-live--send (list :event "stop"))
      (harness-voice-live--start-timer harness-voice-live--stop-timeout
                                       #'harness-voice-live--stop-timeout)
      (harness-voice-live--refresh))
     (harness-voice-live--state
      (harness-voice-live--pipeline-end 'ended)
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
  (harness-voice-live--cancel-held-timer)
  (harness-voice-live--pipeline-playback 'interrupted)
  (setq harness-voice-live--held nil
        harness-voice-live--state 'interrupted)
  (harness-voice-live--stage-set
   (cond (harness-voice-live--speech-active 'hearing)
         (harness-voice-live--working 'thinking)
         (t 'listening)))
  (harness-voice-live--refresh))

;;;###autoload
(defun harness-voice-live-mute ()
  "Mute or unmute the live sidecar microphone."
  (interactive)
  (unless (harness-voice-live--active-p)
    (user-error "Live voice inactive"))
  (setq harness-voice-live--muted (not harness-voice-live--muted))
  (harness-voice-live--pipeline-muted harness-voice-live--muted)
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
  (harness-voice-live--clear-gate)
  (when (timerp harness-voice-live--pipeline-timer)
    (cancel-timer harness-voice-live--pipeline-timer))
  (when (timerp harness-voice-live--pipeline-stale-timer)
    (cancel-timer harness-voice-live--pipeline-stale-timer))
  (setq harness-voice-live--pipeline-timer nil
        harness-voice-live--pipeline-stale-timer nil
        harness-voice-live--pipeline (harness-voice-pipeline-create 'off)
        harness-voice-live--utterance nil
        harness-voice-live--utterance-done nil
        harness-voice-live--seen (make-hash-table :test 'equal)
        harness-voice-live--held-seq 0)
  (harness-voice-live--clear-turn)
  (when (buffer-live-p harness-voice-live--transcript)
    (kill-buffer harness-voice-live--transcript))
  (setq harness-voice-live--transcript nil))

(provide 'harness-ui-voice-live)
;;; harness-ui-voice-live.el ends here
