;;; harness-ui-voice.el --- Local dictation and interruptible spoken chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; Optional, client-side speech, independent of the coding provider.
;; Providers declare a capability, `wav' or `live' (see
;; `harness-ui-voice-providers'); every command here dispatches on that
;; capability, and all providers share the chat, tools and permissions.
;;
;; The WAV capability records a private WAV, transcribes it into the
;; current compose box, and speaks new assistant text sentence by
;; sentence.  Each utterance needs a click or key.  Mouse press/release
;; provides hold-to-talk; keyboards generally supply no release event to
;; Emacs, so their command toggles recording instead.
;;
;; The live capability runs a JSON-lines sidecar that owns the
;; microphone, speaker and speech model, while Emacs keeps the captions,
;; the agent turn and every permission decision.  The bundled live
;; providers are ChatGPT Live (GPT-Live over the API), a local whisper.cpp
;; and Kokoro pipeline and a scripted fixture; a sidecar delegation becomes a
;; normal prompt in the chat, and assistant text streams back as
;; commentary.  Audio never crosses the control pipe.
;;
;; Commands are argv lists, never shell snippets.  WAV transcription prints
;; UTF-8 text; synthesis reads UTF-8 text on stdin and writes a WAV.  An
;; external player makes playback cancellable.  All processes run on this
;; UI client, even with a remote harness, and all temporary audio is removed
;; on completion, interruption, failure, buffer death and shutdown.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-media)
(require 'harness-ui-voice-live)

(declare-function transient-append-suffix "transient")
(declare-function transient-remove-suffix "transient")

(require 'harness-ui-voice-providers)

(defcustom harness-voice-transcribe-command nil
  "Command transcribing a WAV into UTF-8 text on stdout.
An argv list, with the symbol `:file' for the input WAV.  No shell is
used.  For a persistent local whisper.cpp server, use for example:
  (\"python3\" \"/path/to/scripts/harness-voice-stt\" :file)
Nil leaves dictation unavailable.  Audio goes only to the service this
command selects; nothing is downloaded or uploaded implicitly.  This is
client configuration, not a safe directory-local option."
  :type '(choice (const :tag "Unconfigured" nil)
                 (repeat (choice string (const :file))))
  :group 'harness-voice)

(defcustom harness-voice-synthesize-command nil
  "Command reading UTF-8 text on stdin and writing a WAV at `:file'.
An argv list, never a shell command.  For local speech, for example:
  (\"python3\" \"-m\" \"piper\" \"-m\" \"/models/voice.onnx\" \"-f\" :file)
or (\"espeak-ng\" \"-w\" :file \"--stdin\").
Nil leaves spoken replies unavailable; dictation still works.  Only
assistant text is spoken, never thinking or tool output."
  :type '(choice (const :tag "Unconfigured" nil)
                 (repeat (choice string (const :file))))
  :group 'harness-voice)

(defcustom harness-voice-player-command nil
  "Command playing a WAV, with `:file' for its path.
Nil uses the media module's external player (mpv, ffplay or paplay).
Native Emacs playback is deliberately excluded: it cannot be interrupted
reliably.  Commands must stay in the foreground so cancellation stops them."
  :type '(choice (const :tag "Media player" nil)
                 (repeat (choice string (const :file))))
  :group 'harness-voice)

(defcustom harness-voice-process-timeout 60
  "Maximum seconds for one transcription, synthesis or playback command."
  :type 'number :group 'harness-voice)

(defcustom harness-voice-recording-limit 120
  "Maximum seconds of one utterance before automatic transcription."
  :type 'number :group 'harness-voice)

(defvar harness-voice--owner nil "The buffer owning the microphone and speaker.")
(defvar harness-voice--job nil "The current audio job, or nil.")
(defvar harness-voice--enabled nil "Non-nil while the UI module is initialized.")
(defvar harness-voice--connection nil "The UI connection voice last used.")
(defvar-local harness-voice--state 'ready "The voice state of this compose host.")
(defvar-local harness-voice--error nil "Failure data shown in the voice controls.")
(defvar-local harness-voice--queue nil "Assistant sentences awaiting synthesis.")
(defvar-local harness-voice--streams nil "Node id -> streamed text and consumed offset.")
(defvar-local harness-voice--turn-active nil "Non-nil for a new, unmuted voice turn.")
(defvar-local harness-voice--controls nil "Non-nil when this box shows voice controls.")
(defvar harness-voice-mode)

(cl-defstruct (harness-voice--job (:constructor harness-voice--make-job))
  buffer session dir phase process output errors timer base offset generation stopping)

;;;; Status and controls

(defun harness-voice--status ()
  "Return the exact status copy for this buffer."
  (if (harness-voice-live-p)
      (harness-voice-live--status)
    (concat (pcase harness-voice--state
              ('listening "Listening") ('transcribing "Transcribing")
              ('thinking "Thinking") ('synthesizing "Synthesizing")
              ('speaking "Speaking") ('failed "Voice failed") (_ "Voice ready"))
            (if (eq harness-voice--state 'listening)
                " · Microphone on" " · Microphone off"))))

(defun harness-voice--refresh ()
  "Refresh this buffer's controls without rebuilding its transcript."
  (when (and harness-voice--controls (harness-compose-live-p))
    (funcall harness-compose-redraw-function))
  (force-mode-line-update t))

(defun harness-voice--set-state (state &optional error-data)
  "Show STATE and optional ERROR-DATA in this buffer."
  (setq harness-voice--state state
        harness-voice--error (and error-data (harness-ui-one-line error-data)))
  (harness-voice--refresh))

(defun harness-voice--button (label command help)
  "Return a button with LABEL, running COMMAND, with one-line HELP."
  (harness-ui-string-action
   (propertize (concat "[" label "]") 'face 'button 'help-echo help)
   command))

(defun harness-voice--hold-button ()
  "Return the press/release microphone control.
The label carries the gesture and reflects the microphone: it reads
`[Hold to talk]' at rest and `[Talking · release]' while the press is
down, so the control shows the state the user is creating."
  (let* ((recording (and (boundp 'harness-voice--state)
                         (eq harness-voice--state 'listening)))
         (label (if recording "[Talking · release]" "[Hold to talk]")))
    (propertize label
                'face (if recording 'harness-caution-face 'button)
                'mouse-face 'highlight
                'help-echo "Dictation · mouse press and release"
                'keymap (let ((map (make-sparse-keymap)))
                          (define-key map [down-mouse-1] #'harness-voice-hold)
                          (define-key map [mouse-1] #'harness-voice-release)
                          (define-key map [drag-mouse-1] #'harness-voice-release)
                          map))))

(defun harness-voice--controls ()
  "Return fitted voice controls for a compose box, or nil."
  (if (harness-voice-live-p)
      (harness-voice-live--controls)
    (harness-voice--wav-controls)))

(defun harness-voice--wav-controls ()
  "Return fitted WAV voice controls for a compose box, or nil."
  (when harness-voice--enabled
    (let ((items
           (if harness-voice--controls
               (list (list (propertize (harness-voice--status)
                                      'face (if (eq harness-voice--state 'failed)
                                                'harness-failure-face 'harness-label-face)
                                      'help-echo (or harness-voice--error "Voice status")) 100 nil)
                     (list (harness-voice--button
                            (if (eq harness-voice--state 'listening)
                                "Transcribe C-c v" "Dictate C-c v")
                            #'harness-voice-dictate "Dictation · C-c v") 95 nil)
                     (list (harness-voice--button "Interrupt C-c V" #'harness-voice-interrupt
                                                 "Speech and turn interruption · C-c V") 90 nil)
                     (and harness-voice--error
                          (list (propertize harness-voice--error 'face 'harness-failure-face
                                            'help-echo harness-voice--error) 80 nil))
                     (list (harness-voice--hold-button) 70 nil)
                     (list (harness-voice--button (if harness-voice-mode "Voice off" "Spoken replies")
                                                 #'harness-voice-toggle "Spoken replies · current chat") 60 nil)
                     (list (harness-voice--button "Setup" #'harness-voice-setup
                                                 "Voice settings") 50 nil))
             (list (harness-voice--button "Voice" #'harness-voice "Voice controls · C-c h v")))))
      (harness-ui-settings-line
       (list items) (max 1 (- (/ (harness-compose--room) (frame-char-width)) 3))))))

(defun harness-voice--indicator ()
  "Return a global, clickable status while voice owns a buffer."
  (when (buffer-live-p harness-voice--owner)
    (with-current-buffer harness-voice--owner
      (when (or harness-voice-mode harness-voice--job
                (and (harness-voice-live-p)
                     (harness-voice-live--active-p)))
        (propertize (concat "  " (harness-voice--status) "  ")
                    'face (if (harness-voice-live-p)
                              (harness-voice-live--face)
                            (if (eq harness-voice--state 'listening)
                                'harness-caution-face 'harness-label-face))
                    'help-echo "Voice controls"
                    'local-map (harness-ui-mouse-keymap #'harness-voice-show))))))

(defconst harness-voice--mode-line '(:eval (harness-voice--indicator)))

(defun harness-voice-show ()
  "Show the compose box that owns voice."
  (interactive)
  (when (buffer-live-p harness-voice--owner)
    (pop-to-buffer harness-voice--owner)
    (when (harness-compose-live-p) (goto-char harness-compose-end))))

;;;; Process lifetime

(defun harness-voice--command (template file)
  "Expand argv TEMPLATE with FILE, validating it before starting anything."
  (unless (and (consp template) (stringp (car template))
               (cl-every (lambda (x) (or (stringp x) (eq x :file))) template)
               (memq :file template))
    (user-error "Voice command unconfigured · :file argument required"))
  (unless (executable-find (car template))
    (user-error "Voice executable unavailable · %s" (car template)))
  (mapcar (lambda (x) (if (eq x :file) file x)) template))

(defun harness-voice--player (file)
  "Return a cancellable player command for FILE, or signal."
  (if harness-voice-player-command
      (harness-voice--command harness-voice-player-command file)
    (let ((program (harness-ui-media--player-program)))
      (unless program (user-error "Voice player unavailable · mpv, pw-play, ffplay or paplay"))
      (harness-ui-media--player-command program file))))

(defun harness-voice--dispose (job)
  "Kill JOB's resources, disarming its sentinel before deleting audio."
  (when (timerp (harness-voice--job-timer job))
    (cancel-timer (harness-voice--job-timer job)))
  (when-let* ((proc (harness-voice--job-process job)))
    (set-process-sentinel proc #'ignore)
    (when (process-live-p proc) (delete-process proc)))
  (dolist (buffer (list (harness-voice--job-output job) (harness-voice--job-errors job)))
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  (when-let* ((dir (harness-voice--job-dir job)))
    (when (file-directory-p dir) (delete-directory dir t))))

(defun harness-voice--abort ()
  "Invalidate the current job, then stop it and discard its audio."
  (let ((job harness-voice--job))
    (setq harness-voice--job nil)
    (harness-voice--release-mode -1)
    (when job (harness-voice--dispose job))))

(defun harness-voice--fail (job detail)
  "Fail current JOB with DETAIL, visibly, without stale callback effects."
  (when (eq job harness-voice--job)
    (let ((buffer (harness-voice--job-buffer job)))
      (harness-voice--abort)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq harness-voice--queue nil harness-voice--turn-active nil)
          (harness-voice--set-state 'failed (harness-ui-one-line detail)))))))

(defun harness-voice--timeout (job)
  "Stop a hung current JOB."
  (when (eq job harness-voice--job)
    (if (eq (harness-voice--job-phase job) 'recording)
        (with-current-buffer (harness-voice--job-buffer job) (harness-voice-release))
      (harness-voice--fail job "Voice process timeout"))))

(defun harness-voice--run (job phase command &optional input)
  "Run COMMAND for JOB's PHASE, optionally sending UTF-8 INPUT on stdin."
  (when (timerp (harness-voice--job-timer job))
    (cancel-timer (harness-voice--job-timer job)))
  (dolist (buffer (list (harness-voice--job-output job) (harness-voice--job-errors job)))
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  (setf (harness-voice--job-phase job) phase
        (harness-voice--job-output job) (generate-new-buffer " *harness-voice-output*")
        (harness-voice--job-errors job) (generate-new-buffer " *harness-voice-errors*"))
  (let ((default-directory (harness-voice--job-dir job)))
    (setf (harness-voice--job-process job)
          (make-process
           :name "harness-voice" :command command :connection-type 'pipe
           :coding 'utf-8-unix :noquery t
           :buffer (harness-voice--job-output job) :stderr (harness-voice--job-errors job)
           :sentinel (lambda (process _event)
                       (when (and (eq job harness-voice--job)
                                  (memq (process-status process) '(exit signal)))
                         (harness-voice--finished job process))))))
  (setf (harness-voice--job-timer job)
        (run-at-time (if (eq phase 'recording) harness-voice-recording-limit
                       harness-voice-process-timeout) nil #'harness-voice--timeout job))
  (unless (eq phase 'recording)
    (when input (process-send-string (harness-voice--job-process job) input))
    (process-send-eof (harness-voice--job-process job))))

(defun harness-voice--new-job ()
  "Create a private audio job belonging to this buffer."
  (let ((dir (make-temp-file "harness-voice-" t)))
    (set-file-modes dir #o700)
    (setq harness-voice--job
          (harness-voice--make-job :buffer (current-buffer) :session harness-ui-session-id :dir dir))))

(defun harness-voice--adopt ()
  "Give this compose host exclusive ownership of voice."
  (harness-voice-live--release-others)
  (unless (eq harness-voice--owner (current-buffer))
    (when (buffer-live-p harness-voice--owner)
      (with-current-buffer harness-voice--owner
        (when harness-voice-mode (harness-voice-mode -1))
        (setq harness-voice--queue nil harness-voice--turn-active nil)
        (harness-voice--set-state 'ready)))
    (harness-voice--abort)
    (setq harness-voice--owner (current-buffer)))
  (setq harness-voice--controls t)
  (add-hook 'kill-buffer-hook #'harness-voice--on-kill nil t))

(defun harness-voice--on-kill ()
  "Release voice when its owner dies."
  (when (eq harness-voice--owner (current-buffer))
    (harness-voice-live--reset)
    (harness-voice--abort)
    (setq harness-voice--owner nil)))

;;;; Dictation

(defun harness-voice--recover (text)
  "Keep TEXT for manual recovery when its original compose box changed."
  (with-current-buffer (get-buffer-create "*harness-voice-transcript*")
    (goto-char (point-max))
    (insert text "\n\n"))
  (harness-voice--set-state 'failed "Draft changed · *harness-voice-transcript*"))

(defun harness-voice--insert-transcript (job text)
  "Insert TEXT at JOB's captured compose offset, never into a different draft."
  (let ((buffer (harness-voice--job-buffer job)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if (not (and (harness-compose-live-p)
                      (equal harness-ui-session-id (harness-voice--job-session job))
                      (= harness-compose-generation (harness-voice--job-generation job))
                      (equal (harness-compose-text) (harness-voice--job-base job))))
            (harness-voice--recover text)
          (let* ((pos (+ harness-compose-start (harness-voice--job-offset job)))
                 (before (char-before pos)) (after (char-after pos)))
            (goto-char pos)
            ;; Ordinary insertion preserves attachments, reply cards and undo.
            (insert (if (and before (> pos harness-compose-start)
                             (not (memq before '(?\s ?\t ?\n)))) " " "")
                    text
                    (if (and after (< pos harness-compose-end)
                             (not (memq after '(?\s ?\t ?\n ?. ?, ?! ?? ?\; ?:)))) " " "")))
          (harness-compose-capture)
          (harness-compose-update-placeholder)
          (harness-voice--set-state 'ready))))))

(defun harness-voice--finished (job process)
  "Advance the current JOB after PROCESS exits."
  (condition-case err
      (let* ((phase (harness-voice--job-phase job))
             (file (expand-file-name "audio.wav" (harness-voice--job-dir job)))
             (ok (and (eq (process-status process) 'exit) (= (process-exit-status process) 0)))
             (audio (and (file-exists-p file) (> (file-attribute-size (file-attributes file)) 44))))
        (unless (buffer-live-p (harness-voice--job-buffer job))
          (error "Voice compose unavailable"))
        (when (timerp (harness-voice--job-timer job)) (cancel-timer (harness-voice--job-timer job)))
        (with-current-buffer (harness-voice--job-buffer job)
          (cond
           ((and (eq phase 'recording) (harness-voice--job-stopping job) audio)
            (harness-voice--set-state 'transcribing)
            (harness-voice--run job 'transcribing
                                (harness-voice--command harness-voice-transcribe-command file)))
           ((not ok)
            (harness-voice--fail
             job (format "Voice %s failed · %s" phase
                         (with-current-buffer (harness-voice--job-errors job)
                           (string-trim (buffer-substring-no-properties
                                         (point-min) (min (point-max) (+ (point-min) 300))))))))
           ((eq phase 'recording) (harness-voice--fail job "Recorder stopped · No transcription"))
           ((eq phase 'transcribing)
            (let ((text (with-current-buffer (harness-voice--job-output job)
                          (string-trim (buffer-string)))))
              (if (string-empty-p text)
                  (harness-voice--fail job "Empty transcription")
                (setq harness-voice--job nil)
                (harness-voice--dispose job)
                (harness-voice--insert-transcript job text))))
           ((eq phase 'synthesizing)
            (unless audio (error "Empty speech audio"))
            (harness-voice--set-state 'speaking)
            (harness-voice--run job 'speaking (harness-voice--player file)))
           ((eq phase 'speaking)
            (setq harness-voice--job nil)
            (harness-voice--dispose job)
            (harness-voice--speak-next)))))
    (error (harness-voice--fail job (error-message-string err)))))

(defun harness-voice-hold (&optional event)
  "Start dictation on mouse press EVENT, interrupting speech and the turn.
With the live provider, a press starts the live session instead."
  (interactive "e")
  (when event
    (let ((window (posn-window (event-start event))))
      (when (windowp window) (select-window window))))
  (unless (harness-compose-live-p) (user-error "Voice compose unavailable"))
  (if (harness-voice-live-p)
      (unless (harness-voice-live--active-p)
        (condition-case err
            (harness-voice-live-start)
          (error
           (setq harness-voice--controls t
                 harness-voice-live--state 'failed
                 harness-voice-live--error (harness-ui-one-line
                                            (error-message-string err)))
           (harness-voice--refresh))))
    (condition-case err
        (harness-voice--start-recording)
      (error
       (setq harness-voice--controls t)
       (harness-voice--set-state 'failed (error-message-string err))))))

(defun harness-voice--start-recording ()
  "Validate speech commands, then record into this compose box.
The mouse and keyboard entry points both surface validation failures
in the controls, before changing audio ownership or microphone power."
  (when (process-live-p harness-ui-media--recorder)
    (user-error "Audio recording active"))
  ;; Validate transcription before turning on the microphone.
  (harness-voice--command harness-voice-transcribe-command "audio.wav")
  (harness-voice--adopt)
  (harness-voice-interrupt)
  (let* ((job (harness-voice--new-job))
         (file (expand-file-name "audio.wav" (harness-voice--job-dir job))))
    (setf (harness-voice--job-base job) (harness-compose-text)
          (harness-voice--job-generation job) harness-compose-generation
          (harness-voice--job-offset job)
          (if (harness-compose-in-p) (- (point) harness-compose-start)
            (length (harness-compose-text))))
    (condition-case err
        (let ((command (harness-ui-media--recorder-command file)))
          (unless command (user-error "Voice recorder unavailable · pw-record, parec, arecord or ffmpeg"))
          (harness-voice--run job 'recording command)
          (harness-voice--release-mode 1)
          (harness-voice--set-state 'listening))
      (error (harness-voice--fail job (error-message-string err))))))

(defun harness-voice-release (&optional _event)
  "Stop the microphone and transcribe, on mouse release or keyboard toggle.
Live voice is continuous, so a release changes nothing there."
  (interactive)
  (unless (harness-voice-live-p)
    (harness-voice--wav-release)))

(defun harness-voice--wav-release ()
  "Stop the WAV microphone and transcribe the recording."
  (let ((job harness-voice--job))
    (when (and job (eq (harness-voice--job-phase job) 'recording)
               (not (harness-voice--job-stopping job)))
      (harness-voice--release-mode -1)
      (setf (harness-voice--job-stopping job) t)
      (when (timerp (harness-voice--job-timer job)) (cancel-timer (harness-voice--job-timer job)))
      ;; The microphone stays visibly on until the recorder actually exits.
      ;; An unresponsive recorder can take the bounded stop timeout below.
      (condition-case err
          (interrupt-process (harness-voice--job-process job))
        (error (harness-voice--fail job (error-message-string err))))
      (when (and (eq job harness-voice--job) (eq (harness-voice--job-phase job) 'recording))
        (setf (harness-voice--job-timer job)
              (run-at-time 3 nil (lambda () (harness-voice--fail job "Recorder stop timeout"))))))))

(defvar harness-voice--release-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'harness-voice-release)
    (define-key map [drag-mouse-1] #'harness-voice-release)
    (define-key map (kbd "C-c v") #'harness-voice-dictate)
    (define-key map (kbd "C-c V") #'harness-voice-interrupt)
    (define-key map [remap keyboard-quit] #'harness-voice-interrupt)
    map)
  "Release events captured anywhere while the microphone is on.")

(define-minor-mode harness-voice--release-mode
  "Capture mouse release even outside the hold-to-talk button."
  :global t :keymap harness-voice--release-mode-map :group 'harness-voice)

;;;###autoload
(defun harness-voice-dictate ()
  "Toggle dictation, or the live session, without sending anything.
With the live provider this starts a stopped session, or mutes and
unmutes the running one."
  (interactive)
  (if (harness-voice-live-p)
      (if (harness-voice-live--active-p)
          (harness-voice-live-mute)
        (condition-case err
            (harness-voice-live-start)
          (error
           (setq harness-voice--controls t
                 harness-voice-live--state 'failed
                 harness-voice-live--error (harness-ui-one-line
                                            (error-message-string err)))
           (harness-voice--refresh))))
    (if (and harness-voice--job (eq (harness-voice--job-phase harness-voice--job) 'recording))
        (harness-voice-release)
      (condition-case err
          (harness-voice-hold)
        (error
         (setq harness-voice--controls t)
         (harness-voice--set-state 'failed (error-message-string err)))))))

;;;###autoload
(defun harness-voice-interrupt ()
  "Stop speech, discard unfinished dictation, and cancel this voice turn.
With the live provider this stops playback only; the agent turn keeps
running, and `harness-voice-live-cancel' is the separate cancellation.
The next recording can start immediately; late process and provider
updates cannot restart old speech.  Cancellation uses the ordinary ACP
session/cancel path and never answers permissions automatically."
  (interactive)
  (if (harness-voice-live-p)
      (harness-voice-live-interrupt)
    (harness-voice--wav-interrupt)))

(defun harness-voice--wav-interrupt ()
  "Stop WAV speech and cancel its attached voice turn."
  (let ((buffer (if (buffer-live-p harness-voice--owner) harness-voice--owner
                  (and (harness-compose-live-p) (current-buffer)))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq buffer harness-voice--owner) (harness-voice--abort))
        (setq harness-voice--queue nil harness-voice--turn-active nil
              harness-voice--streams (make-hash-table :test 'equal))
        (when (and harness-ui-session-id harness-voice-mode)
          (harness-ui-notify "session/cancel" (list :sessionId harness-ui-session-id)))
        (harness-voice--set-state 'ready)))))

;;;; Spoken assistant text

(defun harness-voice--speech-text (text)
  "Return speakable TEXT, without fenced code, markup or link destinations."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*\\(```+\\|~~~+\\).*\n?" nil t)
      (let ((start (match-beginning 0)) (fence (match-string 1)))
        (if (re-search-forward (concat "^[ \t]*" (regexp-quote fence) ".*\n?") nil t)
            (delete-region start (point))
          (delete-region start (point-max)))))
    (setq text (buffer-string)))
  (setq text (replace-regexp-in-string "!?\\[\\([^]\n]+\\)\\](\\([^)]*\\))" "\\1" text)
        text (replace-regexp-in-string "<[^>]+>" "" text)
        text (replace-regexp-in-string "^[ \t]*[#>*-]+[ \t]*" "" text)
        text (replace-regexp-in-string "[`*_]" "" text))
  (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))

(defun harness-voice--drain (id &optional final)
  "Queue complete sentences from node ID, flushing the rest with FINAL."
  (let* ((entry (gethash id harness-voice--streams))
         (text (or (plist-get entry :text) ""))
         (offset (or (plist-get entry :offset) 0))
         end)
    (while (and (< offset (length text))
                (setq end
                      (cond
                       ;; Never read a partly streamed code block aloud.
                       ((string-match "```\\|~~~" text offset) (and final (length text)))
                       ((string-match "[.!?][ \t\n]+\\|\n\n" text offset) (match-end 0))
                       (final (length text)))))
      (let ((speech (harness-voice--speech-text (substring text offset end))))
        (unless (string-empty-p speech)
          ;; Bound each synthesis request, even for a giant code-heavy reply.
          (while (> (length speech) 1200)
            (setq harness-voice--queue (nconc harness-voice--queue (list (substring speech 0 1200)))
                  speech (substring speech 1200)))
          (setq harness-voice--queue (nconc harness-voice--queue (list speech)))))
      (setq offset end))
    (puthash id (plist-put entry :offset offset) harness-voice--streams)
    (harness-voice--speak-next)))

(defun harness-voice--speak-next ()
  "Speak the next queued sentence, or show the current turn's quiet state."
  (unless harness-voice--job
    (if (and harness-voice-mode harness-voice--queue)
        (let* ((text (pop harness-voice--queue)) (job (harness-voice--new-job))
               (file (expand-file-name "audio.wav" (harness-voice--job-dir job))))
          (condition-case err
              (progn
                (harness-voice--player file) ; Validate playback before synthesis.
                (harness-voice--run job 'synthesizing
                                    (harness-voice--command harness-voice-synthesize-command file)
                                    (concat text "\n"))
                (harness-voice--set-state 'synthesizing))
            (error (harness-voice--fail job (error-message-string err)))))
      (unless (eq harness-voice--state 'failed)
        (harness-voice--set-state (if harness-voice--turn-active 'thinking 'ready))))))

(defun harness-voice--on-update (sid update)
  "Read only new assistant text for voice session SID from UPDATE."
  (if (harness-voice-live-p)
      (harness-voice-live--on-update sid update)
    (harness-voice--wav-update sid update)))

(defun harness-voice--wav-update (sid update)
  "Read WAV reply text for session SID from UPDATE."
  (when (buffer-live-p harness-voice--owner)
    (with-current-buffer harness-voice--owner
      (when (and harness-voice-mode (equal sid harness-ui-session-id))
        (pcase (plist-get update :sessionUpdate)
          ("_harness/session_deleted" (harness-voice-mode -1))
          ((or "agent_message_chunk" "_harness/node")
           (when harness-voice--turn-active
             (let* ((chunk (equal (plist-get update :sessionUpdate) "agent_message_chunk"))
                    (node (plist-get update :node))
                    (id (if chunk (plist-get (plist-get update :_harness) :nodeId) (plist-get node :id)))
                    (text (if chunk (plist-get (plist-get update :content) :text) (plist-get node :content)))
                    (entry (gethash id harness-voice--streams)))
               (when (and id (stringp text) (not (plist-get entry :final))
                          (or chunk (equal (format "%s" (plist-get node :kind)) "assistant")))
                 (cond
                  (chunk
                   ;; A live node announcement can already hold the first
                   ;; delta.  Only chunks accumulate; never count it twice.
                   (setq entry (plist-put entry :chunked t)
                         entry (plist-put entry :text (concat (plist-get entry :text) text))))
                  ((plist-get entry :chunked)
                   ;; The final node can canonicalize links or filter text.
                   ;; Its offsets need not match the chunks already spoken.
                   ;; Flush the raw stream, never a suffix of rewritten text.
                   (setq entry (plist-put entry :final t)))
                  (t (setq entry (plist-put entry :announced text))))
                 (puthash id entry harness-voice--streams)
                 (when (or chunk (plist-get entry :chunked))
                   (harness-voice--drain id (not chunk))))))))))))

(defun harness-voice--on-event (event args)
  "Follow new turns and connection-independent cancellation from EVENT and ARGS."
  (when (or (member event '("harness/reloaded" "secrets/redacted"))
            (and (equal event "session/redacted")
                 (buffer-live-p harness-voice--owner)
                 (equal (car args) (buffer-local-value 'harness-ui-session-id harness-voice--owner))))
    (harness-voice--reset)
    (when (member event '("session/redacted" "secrets/redacted"))
      (when-let* ((buffer (get-buffer "*harness-voice-transcript*")))
        (kill-buffer buffer))))
  (if (harness-voice-live-p)
      (harness-voice-live--on-event event args)
    (harness-voice--wav-event event args)))

(defun harness-voice--wav-event (event args)
  "Follow WAV turn EVENT with ARGS in this buffer."
  (when (buffer-live-p harness-voice--owner)
    (with-current-buffer harness-voice--owner
      (when (and harness-voice-mode (equal (car args) harness-ui-session-id))
        (pcase event
          ("agent/turn-started"
           (setq harness-voice--streams (make-hash-table :test 'equal)
                 harness-voice--turn-active t)
           (unless harness-voice--job (harness-voice--set-state 'thinking)))
          ("agent/turn-ended"
           (when harness-voice--turn-active
             (if (member (cadr args) '("cancelled" "error" "failed"))
                 (progn (harness-voice--abort) (setq harness-voice--queue nil))
               (maphash (lambda (id entry)
                          (unless (plist-get entry :chunked)
                            (puthash id (plist-put entry :text (plist-get entry :announced))
                                     harness-voice--streams))
                          (harness-voice--drain id t))
                        harness-voice--streams))
             (setq harness-voice--turn-active nil)
             (harness-voice--speak-next)))
          ((or "session/head-moved" "session/nodes-removed")
           (harness-voice--abort)
           (setq harness-voice--turn-active nil harness-voice--queue nil)
           (harness-voice--set-state 'ready)))))))

(defun harness-voice--redraw ()
  "Reset audio only for a replaced connection, not a routine model-list redraw."
  (unless (eq harness-voice--connection harness-ui-connection)
    (harness-voice--reset)))

(defun harness-voice--recording-p ()
  "Non-nil while voice owns the microphone, including recorder shutdown."
  (or (and harness-voice--job (eq (harness-voice--job-phase harness-voice--job) 'recording))
      (and (harness-voice-live-p) (harness-voice-live--active-p))))

(defun harness-voice--reset ()
  "Discard audio on UI reload/reconnect; never replay earlier speech."
  (harness-voice-live--reset)
  (harness-voice--abort)
  (setq harness-voice--connection harness-ui-connection)
  (when (buffer-live-p harness-voice--owner)
    (with-current-buffer harness-voice--owner
      (setq harness-voice--turn-active nil harness-voice--queue nil
            harness-voice--streams (make-hash-table :test 'equal))
      (harness-voice--set-state 'ready)
      (harness-voice--refresh))))

;;;; Entry points

;;;###autoload
(define-minor-mode harness-voice-mode
  "Speak new assistant replies in this chat, through configurable commands.
With the WAV provider the microphone stays off until
`harness-voice-dictate' or a mouse press.  With the live provider this
enables the controls; `harness-voice' and the Start control begin the
sidecar session.  Transcription is editable and never sent
automatically.  Enabling another chat gives it exclusive audio
ownership; disabling stops audio, not work."
  :lighter " Voice" :group 'harness-voice
  (if harness-voice-mode
      (if (not (and harness-ui-session-id
                    (or (derived-mode-p 'harness-chat-mode)
                        (and (harness-voice-live-p)
                             (harness-compose-live-p)))))
          (progn
            (setq harness-voice-mode nil)
            (user-error "%s" (if (harness-voice-live-p)
                                 "Live voice compose unavailable"
                               "Spoken replies unavailable · Chat required")))
        (harness-voice--adopt)
        (setq harness-voice--streams (make-hash-table :test 'equal)
              harness-voice--turn-active nil)
        (if (harness-voice-live-p)
            (harness-voice--refresh)
          (harness-voice--set-state 'ready)))
    (if (harness-voice-live-p)
        (when (eq harness-voice--owner (current-buffer))
          (harness-voice-live-stop))
      (when (eq harness-voice--owner (current-buffer)) (harness-voice--abort)))
    (setq harness-voice--turn-active nil harness-voice--queue nil)
    (if (harness-voice-live-p)
        (harness-voice--refresh)
      (harness-voice--set-state 'ready))))

(defun harness-voice-toggle ()
  "Toggle voice in the current chat."
  (interactive)
  (if (harness-voice-live-p)
      (if (harness-voice-live--active-p)
          (harness-voice-live-stop)
        (harness-voice-live--start-here))
    (harness-voice-mode (if harness-voice-mode -1 1))))

(defun harness-voice--context ()
  "Return visible origin context for a quick voice chat, without file contents."
  (let* ((root (harness-files-project-root default-directory))
         (related (cl-remove-if-not
                   (lambda (s) (and (equal (plist-get s :project) root)
                                    (member (plist-get s :status) '("running" "blocked" "idle"))
                                    (not (harness-ui-internal-session-p s))
                                    (harness-ui-navigable-session-p s)))
                   (harness-ui-sessions)))
         (sessions (cl-subseq
                    (sort related (lambda (a b)
                                    (let ((active-a (member (plist-get a :status) '("running" "blocked")))
                                          (active-b (member (plist-get b :status) '("running" "blocked"))))
                                      (if (eq (not active-a) (not active-b))
                                          (> (or (plist-get a :updated) 0) (or (plist-get b :updated) 0))
                                        active-a))))
                    0 (min 8 (length related))))
         (origin (if buffer-file-name
                     (format "%s:%d" (file-relative-name buffer-file-name root) (line-number-at-pos))
                   (buffer-name))))
    (concat "Voice request context: " origin "\n"
            (when sessions
              (concat "Related sessions:\n"
                      (mapconcat (lambda (s) (format "- [%s](harness:session/%s) · %s"
                                                     (or (plist-get s :name) (plist-get s :id))
                                                     (plist-get s :id) (plist-get s :status))) sessions "\n") "\n"))
            "\n")))

;;;###autoload
(defun harness-voice ()
  "Open voice controls here, or a quick voice chat from an ordinary buffer.
The quick chat starts on the configured coding provider, with file and
line and related session links visible in its draft.  No file contents
are sent automatically; live audio stays in the sidecar you configured.
The normal send and tool paths keep threads, questions and permissions
in the existing harness workflow."
  (interactive)
  (if (harness-compose-live-p)
      (progn
        (setq harness-voice--controls t)
        (if (and harness-ui-session-id
                 (or (derived-mode-p 'harness-chat-mode)
                     (and (harness-voice-live-p)
                          (harness-compose-live-p))))
            (progn
              (harness-voice-mode 1)
              (when (and (harness-voice-live-p)
                         (not (harness-voice-live--active-p)))
                (harness-voice-live--start-here)))
          (harness-voice--refresh)))
    (let ((context (harness-voice--context))
          (dir (harness-files-project-root default-directory)))
      (harness-new-session
       dir 'bottom
       (lambda (buffer)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (harness-compose-set context)
             (setq-local harness-voice--live-context context)
             (harness-voice-mode 1)
             (when (harness-voice-live-p)
               (harness-voice-live--start-here))
             (goto-char harness-compose-end))))))))

;;;; Module

(defun harness-voice--claim-key (map key command &optional stale)
  "Bind KEY in MAP to COMMAND unless another command owns it.
A free key, COMMAND itself, or STALE -- a binding older code gave the
key -- is claimed; any other command stays.  A number means the key
sequence runs past the map's bindings, so the key is free."
  (let ((current (lookup-key map (kbd key))))
    (when (or (null current) (numberp current)
              (eq current command) (eq current stale))
      (define-key map (kbd key) command))))

(defun harness-voice--init ()
  "Wire optional voice into compose boxes and the session menu."
  (setq harness-voice--enabled t harness-voice--connection harness-ui-connection)
  (add-hook 'harness-ui-media-recording-blocked-p-functions #'harness-voice--recording-p)
  (add-hook 'harness-compose-controls-functions #'harness-voice--controls)
  (add-hook 'harness-ui-update-functions #'harness-voice--on-update)
  (add-hook 'harness-ui-event-functions #'harness-voice--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-voice--redraw)
  (add-hook 'kill-emacs-hook #'harness-voice--reset)
  (unless (member harness-voice--mode-line global-mode-string)
    (setq global-mode-string (append (if (stringp global-mode-string) (list global-mode-string) global-mode-string)
                                    (list harness-voice--mode-line))))
  ;; v is voice's; the version page moved to U.  An older version
  ;; module may still have left v on `harness-version': take that over,
  ;; but leave any other command the user bound there.
  (harness-voice--claim-key harness-ui-map "v" #'harness-voice 'harness-version)
  (harness-voice--claim-key harness-compose-map "C-c v" #'harness-voice-dictate)
  (harness-voice--claim-key harness-compose-map "C-c V" #'harness-voice-interrupt)
  (ignore-errors (transient-remove-suffix 'harness-session-menu "v"))
  (transient-append-suffix 'harness-session-menu "r" '("v" "Voice chat" harness-voice)))

(defun harness-voice--shutdown ()
  "Stop all client audio and remove the optional module's hooks and keys."
  (harness-voice--reset)
  (when (buffer-live-p harness-voice--owner)
    (with-current-buffer harness-voice--owner (harness-voice-mode -1)))
  (setq harness-voice--enabled nil harness-voice--owner nil)
  (remove-hook 'harness-ui-media-recording-blocked-p-functions #'harness-voice--recording-p)
  (remove-hook 'harness-compose-controls-functions #'harness-voice--controls)
  (remove-hook 'harness-ui-update-functions #'harness-voice--on-update)
  (remove-hook 'harness-ui-event-functions #'harness-voice--on-event)
  (remove-hook 'harness-ui-redraw-hook #'harness-voice--redraw)
  (remove-hook 'kill-emacs-hook #'harness-voice--reset)
  (setq global-mode-string (delete harness-voice--mode-line global-mode-string))
  (dolist (binding `((,harness-ui-map "v" harness-voice)
                     (,harness-compose-map "C-c v" harness-voice-dictate)
                     (,harness-compose-map "C-c V" harness-voice-interrupt)))
    (when (eq (lookup-key (car binding) (kbd (cadr binding))) (caddr binding))
      (define-key (car binding) (kbd (cadr binding)) nil t)))
  (ignore-errors (transient-remove-suffix 'harness-session-menu "v")))

(harness-define-module 'ui-voice
  :doc "WAV dictation or live voice through a provider, with ChatGPT Live, a local pipeline or a sidecar of your own."
  :requires '(ui ui-compose ui-media)
  :init #'harness-voice--init
  :shutdown #'harness-voice--shutdown)

(provide 'harness-ui-voice)
;;; harness-ui-voice.el ends here
