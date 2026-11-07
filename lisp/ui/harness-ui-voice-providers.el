;;; harness-ui-voice-providers.el --- Voice providers and capabilities  -*- lexical-binding: t; -*-

;;; Commentary:

;; Voice has two capabilities, and providers that implement them, the
;; way model providers have capabilities of their own:
;;
;;   `wav'   record one utterance, transcribe it into the compose box,
;;           speak reply sentences.  Push-to-talk, text-mediated.
;;   `live'  a sidecar owns the microphone, speaker and speech model and
;;           delegates work to the current chat.  Continuous audio.
;;
;; A provider is a name, a capability, the argv list that runs it and
;; what it needs.  The bundled providers are the WAV dictation, ChatGPT
;; Live (GPT-Live over the API), a local speech pipeline, the
;; scripted fixture and a custom sidecar command.  Programs add their
;; own with `harness-define-voice-provider'.
;;
;;   (harness-define-voice-provider 'my-voice
;;     :label "My voice"
;;     :capability 'live
;;     :doc "A sidecar that speaks the JSON-lines protocol."
;;     :command (lambda () (list "my-sidecar"))
;;     :needs '((executable "my-sidecar")))
;;
;; `harness-voice-provider' names the selected provider, and every
;; command dispatches on `harness-voice-capability', never on the
;; provider's name: a new provider with an existing capability needs no
;; change in the chat, the tools or the permission panels.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-media)
;; The local stack is optional: a client that has no docker keeps the
;; provider, and the setup list says the stack is unavailable.
(require 'harness-stacks nil t)

(declare-function harness-voice--refresh "harness-ui-voice")
(declare-function harness-voice-live--active-p "harness-ui-voice-live")
(declare-function harness-voice-live-stop "harness-ui-voice-live")
(declare-function harness-compose-stack-status "harness-stacks")
(declare-function harness-compose-stack-up "harness-stacks")
(declare-function harness-compose-stack-down "harness-stacks")
(declare-function harness-compose-stack-available-p "harness-stacks")
(declare-function harness-compose-stack-endpoint "harness-stacks")
(declare-function harness-container-runtime-need-reason "harness-container-runtime")
(declare-function harness-define-compose-stack "harness-stacks")

(defvar harness-directory)

(defvar harness-voice-provider)
(defvar harness-voice-effort)
(defvar harness-voice-transcribe-command)
(defvar harness-voice-synthesize-command)

(defgroup harness-voice nil
  "Client-side dictation and spoken replies, with any coding provider."
  :group 'harness-ui)

;;;; Capabilities

(defconst harness-voice-capabilities '(wav live)
  "The voice capabilities a provider can declare.
`wav' records one utterance and transcribes it into the compose box;
`live' keeps a sidecar in charge of the audio path.")

(defun harness-voice-capability-label (capability)
  "Return the short label for CAPABILITY."
  (pcase capability
    ('wav "WAV")
    ('live "live")
    (_ (format "%s" capability))))

;;;; Registry

(defvar harness-voice-providers (make-hash-table :test 'eq)
  "Voice provider id -> plist of :id, :label, :capability, :doc,
:command and :needs.")

(cl-defun harness-define-voice-provider (id &key label capability doc command needs efforts stack)
  "Register voice provider ID.
LABEL names it in the UI, CAPABILITY is `wav' or `live' (`live' when
omitted), DOC explains it, COMMAND is an argv list or a function of no
arguments returning one, and NEEDS is a list of things the provider
needs: `(env NAME)', `(executable NAME)' or a function returning a
one-line reason when it cannot run.  EFFORTS maps `low', `medium' and
`high' to argv fragments this provider adds at that effort.  STACK
names the compose stack this provider needs beside it (see
`harness-define-compose-stack').  Defining ID again replaces it."
  (unless (memq capability harness-voice-capabilities)
    (setq capability 'live))
  (puthash id (list :id id
                    :label (or label (symbol-name id))
                    :capability capability
                    :doc doc
                    :command command
                    :needs needs
                    :efforts efforts
                    :stack stack)
           harness-voice-providers)
  id)

(defun harness-voice-provider-get (id)
  "Return the record of voice provider ID, or nil."
  (and id (gethash id harness-voice-providers)))

(defun harness-voice-provider-capability (id)
  "Return the capability of voice provider ID, or nil."
  (plist-get (harness-voice-provider-get id) :capability))

(defun harness-voice-provider-label (id)
  "Return the label of voice provider ID, or its name."
  (or (plist-get (harness-voice-provider-get id) :label) (format "%s" id)))

(defun harness-voice-provider-ids (&optional capability)
  "Return the registered provider ids, those of CAPABILITY alone when given."
  (let (ids)
    (maphash (lambda (id record)
               (when (or (null capability)
                         (eq (plist-get record :capability) capability))
                 (push id ids)))
             harness-voice-providers)
    (sort ids (lambda (a b) (string< (harness-voice-provider-label a)
                                     (harness-voice-provider-label b))))))

(defun harness-voice-capability ()
  "Return the capability of the selected voice provider.
An unregistered provider falls back to `wav', so a stale setting keeps
the push-to-talk path rather than sending audio somewhere unexpected."
  (or (harness-voice-provider-capability harness-voice-provider) 'wav))

(defun harness-voice-live-p ()
  "Non-nil when the selected provider keeps a sidecar on the audio path."
  (eq (harness-voice-capability) 'live))

;;;; Selection

(defcustom harness-voice-provider 'wav
  "The voice provider this client uses.
A provider is registered with `harness-define-voice-provider'; it
declares a capability, `wav' or `live', and the command that runs it.
The bundled providers are `wav' (local push-to-talk dictation), `chatgpt'
(GPT-Live over the API), `unmute' (a local whisper.cpp and Kokoro
pipeline), `fixture' (the scripted sidecar) and `custom'
(`harness-voice-live-command').
`M-x harness-voice-select-provider' lists them with their capability and
what each still needs.  This is client configuration, not a safe
directory-local option."
  :type '(restricted-sexp :match-alternatives (symbolp))
  :group 'harness-voice)

(defun harness-voice-provider-choice (id)
  "Return the one-line choice text for voice provider ID."
  (let ((record (harness-voice-provider-get id))
        (reason (harness-voice-provider-unavailable-reason id)))
    (format "%s · %s · %s"
            (harness-voice-provider-label id)
            (harness-voice-capability-label (plist-get record :capability))
            (or reason "ready"))))

(defun harness-voice-read-provider ()
  "Read a voice provider, showing its capability and readiness."
  (let* ((choices (mapcar (lambda (id) (cons (harness-voice-provider-choice id) id))
                          (harness-voice-provider-ids)))
         (answer (completing-read "Voice provider: " choices nil t)))
    (cdr (assoc answer choices))))

(defun harness-voice-select-provider (provider)
  "Select voice provider PROVIDER for this client.
A running live session ends first, so the microphone does not move
between two providers."
  (interactive (list (harness-voice-read-provider)))
  (unless (harness-voice-provider-get provider)
    (user-error "Unknown voice provider · %s" provider))
  (when (and (fboundp 'harness-voice-live--active-p)
             (harness-voice-live--active-p))
    (harness-voice-live-stop))
  (setq harness-voice-provider provider)
  (when (fboundp 'harness-voice--refresh)
    (harness-voice--refresh))
  (harness-voice-setup--refresh)
  (message "Voice provider · %s" (harness-voice-provider-label provider))
  provider)

;;;; What a provider needs

(defun harness-voice-need-reason (need)
  "Return why NEED is unmet, or nil when it is met."
  (cond
   ((functionp need) (funcall need))
   ((and (consp need) (eq (car need) 'env))
    (let ((value (getenv (cadr need))))
      (and (or (null value) (string-empty-p value))
           (format "Environment variable · %s" (cadr need)))))
   ((and (consp need) (memq (car need) '(executable command)))
    (and (not (executable-find (cadr need)))
         (format "Executable unavailable · %s" (cadr need))))
   ((and (consp need) (eq (car need) 'file))
    (and (not (file-exists-p (cadr need)))
         (format "File unavailable · %s" (file-name-nondirectory (cadr need)))))
   (t nil)))

(defun harness-voice-provider-unavailable-reason (&optional id)
  "Return a one-line reason why voice provider ID cannot run, or nil."
  (let* ((id (or id harness-voice-provider))
         (record (harness-voice-provider-get id)))
    (cond
     ((null record) (format "Unknown voice provider · %s" id))
     (t (car (delq nil (mapcar #'harness-voice-need-reason
                               (plist-get record :needs))))))))

(defun harness-voice-provider-command (&optional id)
  "Return the argv list that runs voice provider ID, or signal.
The list is checked before anything starts: a live provider with no
command, or one whose program is missing, fails in the controls rather
than opening a process that cannot speak."
  (let* ((id (or id harness-voice-provider))
         (record (harness-voice-provider-get id)))
    (unless record
      (user-error "Unknown voice provider · %s" id))
    (let ((command (plist-get record :command)))
      (when (functionp command)
        (setq command (funcall command)))
      (unless (and (consp command) (stringp (car command))
                   (cl-every #'stringp command))
        (user-error "Voice provider unconfigured · %s" (plist-get record :label)))
      (unless (executable-find (car command))
        (user-error "Voice executable unavailable · %s" (car command)))
      (append (copy-sequence command)
              (harness-voice-effort-fragment id)))))

;;;; Setup

(defvar harness-voice-setup-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "c") (lambda () (interactive) (customize-group 'harness-voice)))
    map)
  "Key map of the voice setup buffer.")

(define-derived-mode harness-voice-setup-mode special-mode "Voice setup"
  "Mode of the voice provider list.
RET on a provider selects it, `c' opens the voice settings and `q'
closes the buffer."
  (setq-local mode-line-format '(" Voice setup")))

(defun harness-voice-setup ()
  "Show the voice providers, their capabilities and the voice settings."
  (interactive)
  (let ((buffer (get-buffer-create "*harness voice setup*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (harness-voice-setup-mode)
        (harness-voice-setup--insert)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defvar harness-voice--setup-redrawing nil
  "Non-nil while the setup list redraws.
A stack question can report its answer straight back, and a redraw
inside a redraw would never end.")

(defun harness-voice-setup--refresh ()
  "Redraw the setup list, when it is on screen."
  (when (and (get-buffer-window "*harness voice setup*")
             (not harness-voice--setup-redrawing))
    (with-current-buffer "*harness voice setup*"
      (let ((harness-voice--setup-redrawing t)
            (inhibit-read-only t))
        (erase-buffer)
        (harness-voice-setup--insert))
      (goto-char (point-min)))))

(defun harness-voice-setup--insert ()
  "Insert the voice provider list into the current buffer.
The buffer is read-only once its mode is on, so this binds that off.
The selected provider's stack is asked for its state first: the
provider rows below read the published ports from it, and a stale
state would keep saying a running service is missing."
  (let ((inhibit-read-only t))
    (when (and (harness-voice--stack-id) (featurep 'harness-stacks))
      (harness-compose-stack-status (harness-voice--stack-id)))
    (insert (propertize "Voice providers" 'face 'harness-label-face) "\n\n")
    (dolist (id (harness-voice-provider-ids))
      (let* ((record (harness-voice-provider-get id))
             (selected (eq id harness-voice-provider))
             (reason (harness-voice-provider-unavailable-reason id)))
        (insert "  "
                (propertize (if selected "●" "○")
                            'face (if selected 'harness-success-face 'harness-label-face))
                " "
                (harness-ui-string-action
                 (propertize (harness-voice-provider-label id)
                             'face (if selected 'harness-label-face 'default)
                             'help-echo (or (plist-get record :doc) "Voice provider"))
                 (lambda () (harness-voice-select-provider id)))
                "  "
                (propertize (harness-voice-capability-label (plist-get record :capability))
                            'face 'harness-label-face)
                "  "
                (propertize (if selected "selected" (or reason "ready"))
                            'face (if (and reason (not selected))
                                      'harness-failure-face
                                    'default)))
        (when (and selected reason)
          ;; The chosen provider still says what it lacks.
          (insert " · " (propertize reason 'face 'harness-failure-face)))
        (insert "\n")))
    (harness-voice--insert-stack)
    (harness-voice--insert-audio)
    (insert "\n"
            (propertize "Effort" 'face 'harness-label-face)
            "  ")
    (dolist (effort '(low medium high))
      (unless (eq effort 'low) (insert " "))
      (insert (if (eq effort harness-voice-effort)
                  (propertize (format "[%s]" (capitalize (symbol-name effort)))
                              'face 'harness-agent-label-face
                              'help-echo "Voice effort · selected")
                (harness-ui-string-action
                 (propertize (format "[%s]" (capitalize (symbol-name effort)))
                             'face 'button 'help-echo "Voice effort")
                 (lambda () (interactive) (harness-voice-select-effort effort))))))
    (insert "\n\n"
            (harness-ui-string-action
             (propertize "[Voice settings]" 'face 'button
                         'help-echo "Voice options")
             (lambda () (customize-group 'harness-voice)))
            "\n")))

(defun harness-voice--audio-line ()
  "Return the setup line naming the backend voice records and plays through.
A live sidecar opens the microphone and the speaker itself, and the WAV
dictation records with the same backend, so the line is what would run
rather than what the selected provider needs.  A side with no backend
at all is named, with the programs that would give it one."
  (let* ((capture (harness-ui-media-audio-backend 'capture))
         (playback (harness-ui-media-audio-backend 'playback))
         (both (harness-ui-media-audio-backend))
         (backends (and capture playback
                        (format "%s + %s" (nth 1 capture) (nth 1 playback)))))
    (cond
     ((null capture)
      (cons (format "Microphone unavailable · %s"
                    (harness-ui-media-audio-programs 'capture))
            'harness-failure-face))
     ((null playback)
      (cons (format "Speaker unavailable · %s"
                    (harness-ui-media-audio-programs 'playback))
            'harness-failure-face))
     (both (cons (format "%s · %s, %s" (nth 1 both) (nth 2 both) (nth 3 both)) nil))
     ;; A backend for each side, none for both: name them both.
     (t (cons (format "%s · %s, %s" backends (nth 2 capture) (nth 3 playback)) nil)))))

(defun harness-voice--insert-audio ()
  "Insert the audio backend line above the effort buttons."
  (let ((line (harness-voice--audio-line)))
    (insert "\n"
            (propertize "Audio" 'face 'harness-label-face)
            "  "
            (propertize (car line) 'face (cdr line)
                        'help-echo "Voice microphone and speaker")
            "\n")))

(defun harness-voice--stack-id ()
  "Return the compose stack of the selected provider, or nil."
  (plist-get (harness-voice-provider-get harness-voice-provider) :stack))

(defun harness-voice--insert-stack ()
  "Insert the local stack line when the selected provider has one.
The setup list asked for the state before its provider rows, so it is
read from the cache here; a redraw inside a redraw would never end."
  (when (and (harness-voice--stack-id) (featurep 'harness-stacks))
    (let* ((id (harness-voice--stack-id))
           (record (or (gethash id harness-stacks--states)
                       (harness-compose-stack-status id)))
           (state (or (plist-get record :state) 'stopped))
           (detail (or (plist-get record :detail) "Local voice stack"))
           (running (eq state 'running)))
      (insert "\n"
              (propertize "Local voice stack" 'face 'harness-label-face)
              "  "
              (propertize (pcase state
                            ('running "● running")
                            ('starting "◐ starting")
                            ('error "✕ failed")
                            (_ "○ stopped"))
                          'face (pcase state
                                  ('running 'harness-success-face)
                                  ('starting 'harness-caution-face)
                                  ('error 'harness-failure-face)
                                  (_ 'harness-dim-face))
                          'help-echo detail)
              "  "
              (if running
                  (harness-ui-string-action
                   (propertize "[Stop]" 'face 'button 'help-echo "Local voice stack · stop")
                   #'harness-voice-stack-down)
                (harness-ui-string-action
                 (propertize "[Start]" 'face 'button 'help-echo "Local voice stack · start")
                 #'harness-voice-stack-up))
              "\n"))))

(defun harness-voice--stack-result (state)
  "Return the one-line echo text for stack STATE.
A failure keeps its detail, so the cause of a failed start is visible
in the echo area instead of only the word `error'."
  (let ((kind (plist-get state :state))
        (detail (plist-get state :detail)))
    (if (and (eq kind 'error) detail (not (string-empty-p detail)))
        (format "%s · %s" kind detail)
      (format "%s" kind))))

(defun harness-voice-stack-up ()
  "Start the selected provider's local compose stack."
  (interactive)
  (let ((id (harness-voice--stack-id)))
    (unless (and id (featurep 'harness-stacks))
      (user-error "Local stack unavailable"))
    (unless (harness-compose-stack-available-p)
      (user-error "%s" (or (harness-container-runtime-need-reason)
                           "Runtime unavailable")))
    (harness-compose-stack-up
     id (lambda (state)
          (message "Local voice stack · %s" (harness-voice--stack-result state))
          (harness-voice-setup--refresh)))))

(defun harness-voice-stack-down ()
  "Stop the selected provider's local compose stack."
  (interactive)
  (let ((id (harness-voice--stack-id)))
    (unless (and id (featurep 'harness-stacks))
      (user-error "Local stack unavailable"))
    (harness-compose-stack-down
     id (lambda (state)
          (message "Local voice stack · %s" (harness-voice--stack-result state))
          (harness-voice-setup--refresh)))))

(defun harness-voice-select-effort (effort)
  "Select voice EFFORT and redraw an open setup list."
  (interactive (list (intern (completing-read "Voice effort: "
                                              '("low" "medium" "high") nil t))))
  (setq harness-voice-effort effort)
  (harness-voice-setup--refresh)
  (message "Voice effort · %s" (capitalize (symbol-name effort)))
  effort)

;;;; The bundled providers

(defcustom harness-voice-effort 'medium
  "How much compute a voice provider may spend.
`low' picks the smallest, most quantized models, for a laptop on
battery; `medium' balances size and quality; `high' picks the largest
models a provider offers.  Providers declare their own fragments (see
`harness-define-voice-provider'), and the local stack picks its
whisper.cpp model from the same setting; a provider that declares no
fragments passes none."
  :type '(choice (const :tag "Low · fastest" low)
                 (const :tag "Medium · balanced" medium)
                 (const :tag "High · best" high))
  :group 'harness-voice)

(defun harness-voice-effort-fragment (&optional provider)
  "Return the argv fragment PROVIDER adds at the current effort."
  (let ((efforts (plist-get (harness-voice-provider-get (or provider harness-voice-provider))
                            :efforts)))
    (cdr (assq harness-voice-effort efforts))))

(defun harness-voice-whisper-model (&optional effort)
  "Return the whisper.cpp model file for EFFORT, or the current one."
  (pcase (or effort harness-voice-effort)
    ('low "ggml-tiny.en.bin")
    ('high "ggml-small.en.bin")
    (_ "ggml-base.en.bin")))

(defcustom harness-voice-live-command nil
  "Command running a custom live voice sidecar.
An argv list, never a shell snippet.  The sidecar reads and writes
newline-delimited JSON on stdin and stdout and keeps all audio itself;
see `docs/voice.md'.  It is the command of the `custom' provider, and
the way to attach a Pipecat, Moshi or other sidecar of one's own.
Nil leaves that provider unconfigured.  The API key belongs in the
sidecar's environment, never in this option.  This is client
configuration, not a safe directory-local option."
  :type '(choice (const :tag "Unconfigured" nil)
                 (repeat string))
  :group 'harness-voice)

(defcustom harness-voice-live-startup-timeout 15
  "Seconds to wait for a live sidecar to report ready."
  :type 'number
  :group 'harness-voice)

(defcustom harness-voice-chatgpt-live-id "gpt-live-1"
  "The GPT-Live model the ChatGPT voice provider starts.
A backend model and its tools are configured on the server; the voice
model is this one."
  :type 'string
  :group 'harness-voice)

(defcustom harness-voice-chatgpt-voice "marin"
  "The GPT-Live voice the ChatGPT provider speaks with."
  :type 'string
  :group 'harness-voice)

(defcustom harness-voice-chatgpt-instructions nil
  "Extra instructions for the ChatGPT voice provider, or nil.
The bundled sidecar already asks for short spoken replies and
delegation of every request that needs files, commands or tools; this
text is appended to that prompt."
  :type '(choice (const :tag "Default" nil) string)
  :group 'harness-voice)

(defcustom harness-voice-unmute-stt-url nil
  "Speech-to-text endpoint the local voice provider posts WAV files to.
Nil uses the running `voice-local' stack's whisper.cpp service, whose
random loopback port needs no copying; set it to point at a service you
run yourself, such as whisper.cpp's `/inference'."
  :type '(choice (const :tag "The local stack" nil) string)
  :group 'harness-voice)

(defcustom harness-voice-unmute-tts-url nil
  "Text-to-speech endpoint the local voice provider posts replies to.
Nil uses the running `voice-local' stack's Kokoro service.  Set it to
point at a text-to-speech service you run yourself, such as a Piper
server with the same OpenAI-compatible shape."
  :type '(choice (const :tag "The local stack" nil) string)
  :group 'harness-voice)

(defcustom harness-voice-unmute-voice "af_heart"
  "The voice name the local provider asks the speech endpoint for.
The bundled stack's Kokoro service warms `af_heart' at startup.  A
different endpoint may name another voice, such as OpenAI's \"alloy\"."
  :type 'string
  :group 'harness-voice)

(defcustom harness-voice-unmute-threshold 0.02
  "Mean sample energy at which the local provider starts an utterance.
Raise it in a noisy room, lower it for a quiet microphone."
  :type 'number
  :group 'harness-voice)

(defun harness-voice--script (name)
  "Return the path of the bundled voice script NAME."
  (expand-file-name name (expand-file-name "scripts" harness-directory)))

(defun harness-voice-chatgpt-command ()
  "Return the argv list running the bundled GPT-Live sidecar."
  (append (list "python3" (harness-voice--script "harness-voice-live-gpt")
                "--model" harness-voice-chatgpt-live-id
                "--voice" harness-voice-chatgpt-voice)
          (when harness-voice-chatgpt-instructions
            (list "--instructions" harness-voice-chatgpt-instructions))))

(defun harness-voice-unmute--endpoint (service path)
  "Return the running voice-local stack's URL for SERVICE/PATH, or nil."
  (and (featurep 'harness-stacks)
       (harness-compose-stack-endpoint 'voice-local service path)))

(defun harness-voice-unmute--stt-url ()
  "Return the local provider's speech-to-text URL, or signal.
The bundled stack's whisper.cpp service answers `/inference'."
  (or harness-voice-unmute-stt-url
      (harness-voice-unmute--endpoint 'whisper "inference")
      (user-error "Local voice stack · not running")))

(defun harness-voice-unmute--tts-url ()
  "Return the local provider's text-to-speech URL, or signal.
The bundled stack's Kokoro service answers the OpenAI speech route."
  (or harness-voice-unmute-tts-url
      (harness-voice-unmute--endpoint 'tts "v1/audio/speech")
      (user-error "Text to speech endpoint unset")))

(defun harness-voice-unmute-need ()
  "Return why the local provider cannot run, or nil.
Speech to text comes from the running stack's whisper.cpp service;
text to speech from `harness-voice-unmute-tts-url' or the stack's
Kokoro service.  The reason is one line, for the setup list."
  (or (unless (or harness-voice-unmute-stt-url
                  (harness-voice-unmute--endpoint 'whisper "inference"))
        "Local voice stack · not running")
      (unless (or harness-voice-unmute-tts-url
                  (harness-voice-unmute--endpoint 'tts "v1/audio/speech"))
        "Text to speech endpoint unset")))

(defun harness-voice-unmute-command ()
  "Return the argv list running the bundled local pipeline sidecar.
Speech to text comes from the running `voice-local' stack's whisper.cpp
service unless `harness-voice-unmute-stt-url' names a service of your
own; text to speech from `harness-voice-unmute-tts-url' or the stack's
Kokoro service."
  (list "python3" (harness-voice--script "harness-voice-live-unmute")
        "--stt-url" (harness-voice-unmute--stt-url)
        "--tts-url" (harness-voice-unmute--tts-url)
        "--voice" harness-voice-unmute-voice
        "--threshold" (number-to-string harness-voice-unmute-threshold)))

(defun harness-voice-fixture-command ()
  "Return the argv list running the scripted fixture sidecar."
  (list "python3" (harness-voice--script "harness-voice-live-fixture") "--demo"))

(defun harness-voice--custom-need ()
  "Return why the custom provider is unconfigured, or nil."
  (unless (and (consp harness-voice-live-command)
               (stringp (car harness-voice-live-command)))
    "Sidecar command unset"))

(defun harness-voice--audio-need ()
  "Return why a live sidecar has no microphone or speaker, or nil.
A sidecar records and plays through the first backend Emacs finds, so
the reason names the programs that would make it work."
  (or (harness-ui-media-audio-missing 'capture)
      (harness-ui-media-audio-missing 'playback)))

(harness-define-voice-provider 'wav
  :label "WAV dictation"
  :capability 'wav
  :doc "Record one utterance, transcribe it into the compose box, and speak reply sentences."
  :needs (list (lambda ()
                 (unless (and (consp harness-voice-transcribe-command)
                              (consp harness-voice-synthesize-command))
                   "Transcription and synthesis commands unset"))))

(harness-define-voice-provider 'chatgpt
  :label "ChatGPT Live"
  :capability 'live
  :doc "GPT-Live over the API: continuous audio, backchannels and delegation to this chat."
  :command #'harness-voice-chatgpt-command
  :needs '((env "OPENAI_API_KEY") harness-voice--audio-need))

(harness-define-voice-provider 'unmute
  :label "Local pipeline"
  :capability 'live
  :doc "Local whisper.cpp and Kokoro speech pipeline · no hosted model, no key."
  :command #'harness-voice-unmute-command
  :needs '(harness-voice--audio-need harness-voice-unmute-need)
  :stack 'voice-local)

(harness-define-voice-provider 'fixture
  :label "Scripted fixture"
  :capability 'live
  :doc "The bundled scripted sidecar: the whole live loop without a microphone, key or model."
  :command #'harness-voice-fixture-command
  :needs '((executable "python3")))

(when (featurep 'harness-stacks)
  ;; whisper.cpp and Kokoro both run on the CPU and have published
  ;; images, so the stack starts them together and the local provider
  ;; needs no endpoint typed by hand.
  (harness-define-compose-stack 'voice-local
    :label "Local voice"
    :doc "whisper.cpp for speech to text and Kokoro for text to speech, on loopback."
    :directory (expand-file-name "scripts/stacks/voice-local" harness-directory)
    :project "voice-local"
    :network "voice"
    :endpoints '((whisper 8080) (tts 8880))
    :env (lambda ()
           (list (cons "WHISPER_MODEL" (harness-voice-whisper-model))))))

(harness-define-voice-provider 'custom
  :label "Custom sidecar"
  :capability 'live
  :doc "Any sidecar that speaks the JSON-lines protocol, from `harness-voice-live-command'."
  :command (lambda () harness-voice-live-command)
  :needs (list #'harness-voice--custom-need))

(provide 'harness-ui-voice-providers)
;;; harness-ui-voice-providers.el ends here
