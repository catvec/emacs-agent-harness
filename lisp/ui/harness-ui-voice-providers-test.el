;;; harness-ui-voice-providers-test.el --- Voice provider registry tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; The voice providers are the shapes voice can take: the WAV
;; dictation, ChatGPT Live, a local pipeline, the scripted fixture and
;; a custom sidecar.  Each declares a capability, a command and what it
;; needs; these tests hold the registry, the selection and the exact
;; copy of the setup list.

;;; Code:

(require 'ert)
(require 'harness-test-helpers)
(require 'harness-ui-voice)
(require 'harness-ui-voice-providers)

(ert-deftest harness-ui-voice-providers-bundled-capabilities ()
  "The bundled providers declare the documented capabilities."
  (should (eq 'wav (harness-voice-provider-capability 'wav)))
  (dolist (id '(chatgpt unmute fixture custom))
    (should (eq 'live (harness-voice-provider-capability id))))
  (should (equal '("ChatGPT Live" "Custom sidecar" "Local pipeline" "Scripted fixture"
                   "WAV dictation")
                 (sort (mapcar #'harness-voice-provider-label
                               '(wav chatgpt custom unmute fixture))
                       #'string<))))

(ert-deftest harness-ui-voice-providers-select-switches-the-capability ()
  "Selecting a provider switches the capability every command reads."
  (let ((harness-voice-provider 'wav))
    (should-not (harness-voice-live-p))
    (should (eq 'wav (harness-voice-capability)))
    (harness-voice-select-provider 'chatgpt)
    (should (eq 'chatgpt harness-voice-provider))
    (should (harness-voice-live-p))
    (should (eq 'live (harness-voice-capability)))
    (harness-voice-select-provider 'wav)
    (should-not (harness-voice-live-p))))

(ert-deftest harness-ui-voice-providers-unknown-falls-back-to-wav ()
  "A provider this client does not know keeps the push-to-talk path."
  (let ((harness-voice-provider 'no-such-voice-provider))
    (should (eq 'wav (harness-voice-capability)))
    (should-not (harness-voice-live-p))))

(ert-deftest harness-ui-voice-providers-reasons ()
  "A provider says what it still needs, in one short line."
  (let ((name "HARNESS_TEST_VOICE_UNSET"))
    (setenv name nil)
    (should (equal (format "Environment variable · %s" name)
                   (harness-voice-need-reason (list 'env name))))
    (should-not (harness-voice-need-reason (list 'env "HOME")))
    (should (equal "Executable unavailable · harness-no-such-executable"
                   (harness-voice-need-reason '(executable "harness-no-such-executable"))))
    (should-not (harness-voice-need-reason '(executable "sh")))
    (should (equal "File unavailable · harness-no-such-file"
                   (harness-voice-need-reason
                    '(file "/nonexistent/harness-no-such-file"))))
    (should (equal "Custom reason" (harness-voice-need-reason (lambda () "Custom reason"))))
    (should-not (harness-voice-need-reason (lambda () nil))))
  (let ((harness-voice-provider 'custom))
    (let ((harness-voice-live-command nil))
      (should (equal "Sidecar command unset"
                     (harness-voice-provider-unavailable-reason))))
    (let ((harness-voice-live-command '("harness-no-such-executable")))
      (should-not (harness-voice-provider-unavailable-reason)))))

(ert-deftest harness-ui-voice-providers-commands-are-argv-lists ()
  "Every bundled command is an argv list, never a shell snippet."
  (let ((harness-voice-unmute-stt-url "http://127.0.0.1:9000/v1/audio/transcriptions")
        (harness-voice-unmute-tts-url "http://127.0.0.1:9000/v1/audio/speech"))
    (dolist (id '(chatgpt unmute fixture))
      (let ((command (plist-get (harness-voice-provider-get id) :command)))
        (setq command (if (functionp command) (funcall command) command))
        (should (consp command))
        (should (stringp (car command)))
        (should (cl-every #'stringp command)))))
  (let ((command (harness-voice-chatgpt-command)))
    (should (member "--model" command))
    (should (equal "gpt-live-1" (cadr (member "--model" command))))
    (should (member "--voice" command))
    (should (equal "marin" (cadr (member "--voice" command))))
    (should (string-suffix-p "harness-voice-live-gpt" (cadr command))))
  (let* ((harness-voice-unmute-stt-url "http://127.0.0.1:9000/v1/audio/transcriptions")
         (harness-voice-unmute-tts-url "http://127.0.0.1:9000/v1/audio/speech")
         (command (harness-voice-unmute-command)))
    (should (equal "http://127.0.0.1:9000/v1/audio/transcriptions"
                   (cadr (member "--stt-url" command))))
    (should (equal "http://127.0.0.1:9000/v1/audio/speech"
                   (cadr (member "--tts-url" command))))
    (should (string-suffix-p "harness-voice-live-unmute" (cadr command)))
    ;; The gate's floor, not a level a quiet interface must reach.
    (should (equal (number-to-string harness-voice-unmute-threshold)
                   (cadr (member "--threshold" command))))
    (should (equal "0.004" (cadr (member "--threshold" command)))))
  (should (equal '("--demo") (last (harness-voice-fixture-command)))))

(ert-deftest harness-ui-voice-providers-command-validation ()
  "A provider whose program is missing fails before a process starts."
  (let ((harness-voice-provider 'chatgpt))
    (let ((harness-voice-chatgpt-live-id "gpt-live-1"))
      ;; python3 is present in the test environment, or the tests skip.
      (unless (executable-find "python3")
        (should-error (harness-voice-provider-command) :type 'user-error))))
  (let ((harness-voice-provider 'custom)
        (harness-voice-live-command nil))
    (should (equal "Voice provider unconfigured · Custom sidecar"
                   (error-message-string (should-error (harness-voice-provider-command))))))
  (let ((harness-voice-provider 'custom)
        (harness-voice-live-command '("harness-no-such-executable")))
    (should (equal "Voice executable unavailable · harness-no-such-executable"
                   (error-message-string (should-error (harness-voice-provider-command))))))
  (let ((harness-voice-provider 'no-such-voice-provider))
    (should (equal "Unknown voice provider · no-such-voice-provider"
                   (error-message-string (should-error (harness-voice-provider-command)))))))

(ert-deftest harness-ui-voice-providers-choice-text ()
  "A choice shows the provider, its capability and its readiness."
  (let* ((harness-voice-providers (make-hash-table :test 'eq)))
    (harness-define-voice-provider 'test-voice
      :label "Test voice" :capability 'live
      :needs '((env "HARNESS_TEST_VOICE_UNSET")))
    (setenv "HARNESS_TEST_VOICE_UNSET" nil)
    (should (equal "Test voice · live · Environment variable · HARNESS_TEST_VOICE_UNSET"
                   (harness-voice-provider-choice 'test-voice)))
    (setenv "HARNESS_TEST_VOICE_UNSET" "1")
    (should (equal "Test voice · live · ready"
                   (harness-voice-provider-choice 'test-voice)))))

(ert-deftest harness-ui-voice-providers-define-replaces ()
  "Defining a provider again replaces its record."
  (let ((harness-voice-providers (make-hash-table :test 'eq)))
    (harness-define-voice-provider 'test-voice :label "One" :capability 'wav)
    (should (eq 'wav (harness-voice-provider-capability 'test-voice)))
    (harness-define-voice-provider 'test-voice :label "Two" :capability 'live)
    (should (eq 'live (harness-voice-provider-capability 'test-voice)))
    (should (equal "Two" (harness-voice-provider-label 'test-voice)))
    (should (equal '(test-voice) (harness-voice-provider-ids)))
    (should (equal '(test-voice) (harness-voice-provider-ids 'live)))
    (should-not (harness-voice-provider-ids 'wav))))

(ert-deftest harness-ui-voice-providers-setup-copy ()
  "The setup list gives each provider's label, capability and state."
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'second)
        (harness-voice-pipeline-status nil))
    (harness-define-voice-provider 'first
      :label "First voice" :capability 'wav)
    (harness-define-voice-provider 'second
      :label "Second voice" :capability 'live
      :needs '((env "HARNESS_TEST_VOICE_UNSET")))
    (harness-define-voice-provider 'third
      :label "Third voice" :capability 'live)
    (setenv "HARNESS_TEST_VOICE_UNSET" nil)
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional _) '(pipewire "PipeWire" "pw-record" "pw-play"))))
      (with-temp-buffer
        (harness-voice-setup--insert)
        (should (equal (concat "Voice providers\n"
                               "\n"
                               "  ○ First voice  WAV  ready\n"
                               "  ● Second voice  live  selected"
                               " · Environment variable · HARNESS_TEST_VOICE_UNSET\n"
                               "  ○ Third voice  live  ready\n"
                               "\n"
                               "Pipeline  ○ not checked  [Start]\n"
                               "\n"
                               "Audio  PipeWire · pw-record, pw-play\n"
                               "\n"
                               "Effort  [Low] [Medium] [High]\n"
                               "\n"
                               "[Voice settings]\n")
                       (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest harness-ui-voice-providers-setup-audio-line ()
  "The setup list names the audio backend, or what an installed one needs."
  (let ((harness-voice-providers (make-hash-table :test 'eq)))
    (harness-define-voice-provider 'voice :label "Voice" :capability 'live
                                   :command '("true"))
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional _) '(pulse "PulseAudio" "parec" "paplay"))))
      (with-temp-buffer
        (harness-voice-setup--insert)
        (should (string-match-p
                 "^Audio  PulseAudio · parec, paplay$"
                 (buffer-substring-no-properties (point-min) (point-max))))))
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional side)
                 (and (eq side 'capture) '(pipewire "PipeWire" "pw-record" "pw-play")))))
      (with-temp-buffer
        (harness-voice-setup--insert)
        (should (string-match-p
                 "^Audio  Speaker unavailable · pw-play, paplay, aplay or ffmpeg$"
                 (buffer-substring-no-properties (point-min) (point-max))))))
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional _) nil)))
      (with-temp-buffer
        (harness-voice-setup--insert)
        (should (string-match-p
                 "^Audio  Microphone unavailable · pw-record, parec, arecord or ffmpeg$"
                 (buffer-substring-no-properties (point-min) (point-max))))))
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional side)
                 (pcase side
                   ('playback '(pulse "PulseAudio" "parec" "paplay"))
                   ('capture '(pipewire "PipeWire" "pw-record" "pw-play"))))))
      (with-temp-buffer
        (harness-voice-setup--insert)
        (should (string-match-p
                 "^Audio  PipeWire \\+ PulseAudio · pw-record, paplay$"
                 (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest harness-ui-voice-providers-needs-audio-side ()
  "A live provider says which side of the audio is missing, or is ready."
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'live-voice))
    (harness-define-voice-provider 'live-voice
      :label "Live voice" :capability 'live :command '("true")
      :needs '(harness-voice--audio-need))
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional side)
                 (and (eq side 'capture) '(pipewire "PipeWire" "pw-record" "pw-play")))))
      (should (equal "Speaker unavailable · pw-play, paplay, aplay or ffmpeg"
                     (harness-voice-provider-unavailable-reason 'live-voice))))
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional _) nil)))
      (should (equal "Microphone unavailable · pw-record, parec, arecord or ffmpeg"
                     (harness-voice-provider-unavailable-reason 'live-voice))))
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional _) '(pipewire "PipeWire" "pw-record" "pw-play"))))
      (should-not (harness-voice-provider-unavailable-reason 'live-voice)))))

(ert-deftest harness-ui-voice-providers-sidecar-self-tests ()
  "Each bundled sidecar checks its own mapping without audio or network."
  (unless (executable-find "python3")
    (ert-skip "Python 3 unavailable"))
  (dolist (script '("harness-voice-live-gpt" "harness-voice-live-unmute"))
    (let ((file (expand-file-name script
                                  (expand-file-name "scripts" harness-test-root))))
      (should (file-exists-p file))
      (with-temp-buffer
        (let ((status (call-process "python3" nil t nil file "--self-test")))
          (should (eql 0 status))
          (should (string-match-p "self-test ok" (buffer-string))))))))

(ert-deftest harness-ui-voice-providers-setup-follows-the-selection ()
  "Selecting a provider redraws an open setup list."
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'first))
    (harness-define-voice-provider 'first :label "First voice" :capability 'wav)
    (harness-define-voice-provider 'second :label "Second voice" :capability 'live)
    (let ((buffer (get-buffer-create "*harness voice setup*")))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (harness-voice-setup-mode)
              (harness-voice-setup--insert))
            (display-buffer buffer)
            (harness-voice-select-provider 'second)
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "● Second voice" text))
                (should (string-match-p "○ First voice" text)))))
        (kill-buffer buffer)))))

(ert-deftest harness-ui-voice-providers-setup-pipeline-line ()
  "The setup list shows the harness's pipeline and its controls.
The state is the one the harness reported, never one this client
worked out: the pipeline is the server's."
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'local))
    (harness-define-voice-provider 'local :label "Local voice" :capability 'live
                                   :command '("true"))
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional _) '(pipewire "PipeWire" "pw-record" "pw-play"))))
      ;; A client that has not been answered yet says so, and offers a start.
      (let ((harness-voice-pipeline-status nil))
        (with-temp-buffer
          (harness-voice-setup--insert)
          (should (string-match-p
                   "^Pipeline  ○ not checked  \\[Start\\]$"
                   (buffer-substring-no-properties (point-min) (point-max))))))
      ;; Every state the harness reports, with its own control.
      (dolist (case '(("running" "● running" "[Stop]")
                      ("stopped" "○ stopped" "[Start]")
                      ("starting" "◐ starting" "[Start]")
                      ("error" "✕ failed" "[Start]")))
        (let ((harness-voice-pipeline-status
               (list :state (nth 0 case) :detail "2 of 2 services")))
          (with-temp-buffer
            (harness-voice-setup--insert)
            (should (string-match-p
                     (format "^Pipeline  %s  \\[%s\\]$"
                             (regexp-quote (nth 1 case))
                             (if (equal (nth 2 case) "[Stop]") "Stop" "Start"))
                     (buffer-substring-no-properties (point-min) (point-max))))))))))

(ert-deftest harness-ui-voice-providers-setup-pipeline-tooltips ()
  "The pipeline line's state carries the harness's detail as its tooltip."
  (let ((harness-voice-pipeline-status
         '(:state "error" :detail "No answer in 120 s")))
    (with-temp-buffer
      (harness-voice--insert-pipeline)
      (let* ((text (buffer-string))
             (pos (1+ (string-match "✕" text))))
        (should (equal "No answer in 120 s"
                       (get-text-property pos 'help-echo text)))))))

(ert-deftest harness-ui-voice-providers-pipeline-watch ()
  "A client follows the harness's pipeline: its status, then its changes.
`speech/changed' reaches every client, so a start from one shows in all."
  (let ((harness-ui-event-functions nil) (asked nil))
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (method params callback &optional _error)
                 (push (list method params) asked)
                 (funcall callback '(:state "starting" :detail "Starting")))))
      (harness-voice-pipeline-watch)
      (should (memq #'harness-voice-pipeline--on-event harness-ui-event-functions))
      (should (equal '(("_harness/speech/status" nil)) asked))
      (should (equal "Starting" (plist-get harness-voice-pipeline-status :detail)))
      (harness-voice-pipeline--on-event
       "speech/changed" '((:state "running" :detail "2 of 2 services")))
      (should (equal "running" (plist-get harness-voice-pipeline-status :state)))
      ;; Another event of the harness changes nothing here.
      (harness-voice-pipeline--on-event "config/changed" '(harness-test))
      (should (equal "running" (plist-get harness-voice-pipeline-status :state))))))

(ert-deftest harness-ui-voice-providers-effort-fragments ()
  "An effort picks the fragment a provider adds."
  (let ((harness-voice-providers (make-hash-table :test 'eq)))
    (harness-define-voice-provider 'effort-test
      :label "Effort voice" :capability 'live :command '("true")
      :efforts '((low "--model" "tiny")
                 (medium "--model" "base")
                 (high "--model" "large")))
    (should-not (harness-voice-effort-fragment 'fixture))
    (dolist (case '((low . "tiny") (medium . "base") (high . "large")))
      (let ((harness-voice-effort (car case)))
        (should (equal (list "--model" (cdr case))
                       (harness-voice-effort-fragment 'effort-test)))
        (should (member (cdr case)
                        (harness-voice-provider-command 'effort-test))))))
  ;; The whisper model is the harness server's choice now
  ;; (`harness-speech-local-whisper'), not this client's.
  (should-not (fboundp 'harness-voice-whisper-model)))

(ert-deftest harness-ui-voice-providers-local-pipeline-command ()
  "The local provider's sidecar reads both URLs from the harness pipeline.
A client names no port of its own: the harness reports where its
services are, and the sidecar is given them."
  (let ((harness-voice-unmute-stt-url nil)
        (harness-voice-unmute-tts-url nil)
        (harness-voice-pipeline-status
         '(:state "running" :detail "2 of 2 services"
           :stt-url "http://127.0.0.1:32768/inference"
           :tts-url "http://127.0.0.1:32770/v1/audio/speech")))
    (should (equal "Local whisper.cpp or Parakeet speech to text and Kokoro text to speech · no hosted model, no key."
                   (plist-get (harness-voice-provider-get 'unmute) :doc)))
    (should-not (plist-get (harness-voice-provider-get 'unmute) :stack))
    (let ((command (harness-voice-unmute-command)))
      (should (equal "http://127.0.0.1:32768/inference"
                     (cadr (member "--stt-url" command))))
      (should (equal "http://127.0.0.1:32770/v1/audio/speech"
                     (cadr (member "--tts-url" command))))
      (should (equal "af_heart" (cadr (member "--voice" command)))))
    (should-not (harness-voice-unmute-need))))

(ert-deftest harness-ui-voice-providers-local-model-command ()
  "A Parakeet model names the speech it wants, but the harness serves it.
The client sends no service or port: the pipeline's own choice decides
which engine runs, and the sidecar reads the one URL it reports."
  (let ((harness-voice-unmute-stt-url nil)
        (harness-voice-unmute-tts-url nil)
        (harness-voice-stt-model 'parakeet-0.6b)
        (harness-voice-pipeline-status
         '(:state "running" :detail "2 of 2 services"
           :model "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
           :stt-url "http://127.0.0.1:32769/inference"
           :tts-url "http://127.0.0.1:32770/v1/audio/speech")))
    (should (equal "Parakeet 0.6B (English)" (harness-voice-stt-model-name)))
    (let ((command (harness-voice-unmute-command)))
      (should (equal "http://127.0.0.1:32769/inference"
                     (cadr (member "--stt-url" command))))
      (should (equal "http://127.0.0.1:32770/v1/audio/speech"
                     (cadr (member "--tts-url" command)))))
    (should-not (harness-voice-unmute-need))))


(ert-deftest harness-ui-voice-providers-local-pipeline-reasons ()
  "The local provider says why it cannot run, in the harness's own words."
  (let ((harness-voice-unmute-stt-url nil)
        (harness-voice-unmute-tts-url nil))
    ;; The harness says the pipeline is stopped: that is the reason.
    (let ((harness-voice-pipeline-status
           '(:state "stopped" :reason "Local voice pipeline · stopped")))
      (should (string-suffix-p " · Local voice pipeline · stopped"
                               (harness-voice-provider-choice 'unmute)))
      (should (equal "Local voice pipeline · stopped"
                     (harness-voice-unmute-need)))
      (should (equal "Local voice pipeline · stopped"
                     (error-message-string
                      (should-error (harness-voice-unmute-command) :type 'user-error)))))
    ;; A client that was never answered has not checked, not a failure.
    (let ((harness-voice-pipeline-status nil))
      (should (equal "Local voice pipeline · not checked" (harness-voice-unmute-need))))
    ;; A failure keeps the harness's detail, as it does everywhere.
    (let ((harness-voice-pipeline-status
           '(:state "error" :reason "Local voice pipeline · failed · No answer in 120 s")))
      (should (equal "Local voice pipeline · failed · No answer in 120 s"
                     (harness-voice-unmute-need))))
    ;; A service of your own needs no pipeline at all.
    (let ((harness-voice-unmute-stt-url "http://127.0.0.1:9000/stt")
          (harness-voice-unmute-tts-url "http://127.0.0.1:9000/tts")
          (harness-voice-pipeline-status nil))
      (should-not (harness-voice-unmute-need))
      (should (equal "http://127.0.0.1:9000/stt"
                     (cadr (member "--stt-url" (harness-voice-unmute-command))))))))

(ert-deftest harness-ui-voice-providers-local-choice-copy ()
  "The selected local provider reads ready only with both speech services."
  (let ((harness-voice-unmute-stt-url nil)
        (harness-voice-unmute-tts-url nil))
    (let* ((harness-voice-pipeline-status
            '(:state "running" :detail "2 of 2 services"
              :stt-url "http://127.0.0.1:32768/inference"
              :tts-url "http://127.0.0.1:32770/v1/audio/speech"))
           (harness-voice-provider 'unmute))
      (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
                 (lambda (&optional _) '(pipewire "PipeWire" "pw-record" "pw-play"))))
        (should (equal "Local pipeline · live · ready"
                       (harness-voice-provider-choice 'unmute)))))
    ;; A pipeline that stopped has no URLs to give, and says so.
    (let* ((harness-voice-pipeline-status
            '(:state "stopped" :reason "Local voice pipeline · stopped"))
           (harness-voice-provider 'unmute))
      (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
                 (lambda (&optional _) '(pipewire "PipeWire" "pw-record" "pw-play"))))
        (should (string-suffix-p " · Local voice pipeline · stopped"
                                 (harness-voice-provider-choice 'unmute)))))))

(ert-deftest harness-ui-voice-providers-pipeline-result-copy ()
  "A failed start keeps its one-line detail in the echo text."
  (should (equal "Local voice pipeline · running"
                 (harness-voice--pipeline-result '(:state "running" :detail "2 of 2 services"))))
  (should (equal "Local voice pipeline · stopped"
                 (harness-voice--pipeline-result '(:state "stopped"))))
  (should (equal "Local voice pipeline · failed · pull access denied for voice-local"
                 (harness-voice--pipeline-result
                  '(:state "error" :detail "pull access denied for voice-local"))))
  (should (equal "Local voice pipeline · failed"
                 (harness-voice--pipeline-result '(:state "error"))))
  ;; A client that was never answered says so rather than reading as stopped.
  (should (equal "Local voice pipeline · not checked"
                 (harness-voice--pipeline-result '(:state "unknown")))))

;;;; Local speech models

(ert-deftest harness-ui-voice-providers-stt-models ()
  "The bundled speech models name their engine, size and stack service."
  (should (equal '("Parakeet 0.6B (English)" "Parakeet 0.6B v3 (multilingual)"
                   "Whisper base (English)" "Whisper small (English)"
                   "Whisper tiny (English)")
                 (mapcar #'harness-voice-stt-model-label
                         (harness-voice-stt-model-ids))))
  (let ((parakeet (harness-voice-stt-model-get 'parakeet-0.6b)))
    (should (equal "Parakeet 0.6B (English)" (plist-get parakeet :label)))
    (should (equal "sherpa-onnx" (plist-get parakeet :engine)))
    (should (equal "650 MB" (plist-get parakeet :size)))
    (should (eq 'parakeet (plist-get parakeet :service)))
    (should (equal "inference" (plist-get parakeet :path)))
    (should (equal "parakeet" (plist-get parakeet :profile)))
    (should (equal '(("PARAKEET_MODEL" . "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8")
                     ("PARAKEET_FEATURE_DIM" . "80"))
                   (plist-get parakeet :env))))
  (should (equal '(("PARAKEET_MODEL" . "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
                   ("PARAKEET_FEATURE_DIM" . "128"))
                 (plist-get (harness-voice-stt-model-get 'parakeet-0.6b-v3) :env)))
  (dolist (case '((whisper-tiny-en . "ggml-tiny.en.bin")
                  (whisper-base-en . "ggml-base.en.bin")
                  (whisper-small-en . "ggml-small.en.bin")))
    (let ((record (harness-voice-stt-model-get (car case))))
      (should (equal "whisper.cpp" (plist-get record :engine)))
      (should (eq 'whisper (plist-get record :service)))
      (should (equal "whisper" (plist-get record :profile)))
      (should (equal (cdr case) (cdr (assoc "WHISPER_MODEL" (plist-get record :env))))))))

(ert-deftest harness-ui-voice-providers-stt-model-selection ()
  "Auto follows the effort level, a chosen model wins, a stale id falls back."
  (let ((harness-voice-stt-model 'auto))
    (dolist (case '((low . whisper-tiny-en) (medium . whisper-base-en)
                    (high . whisper-small-en)))
      (let ((harness-voice-effort (car case)))
        (should (eq (cdr case) (plist-get (harness-voice-stt-model-resolved) :id)))
        (should (equal (harness-voice-stt-model-label (cdr case))
                       (harness-voice-stt-model-name)))
        (should-not (harness-voice-stt-model-chosen-p)))))
  (let ((harness-voice-stt-model 'parakeet-0.6b)
        (harness-voice-effort 'low))
    (should (eq 'parakeet-0.6b (plist-get (harness-voice-stt-model-resolved) :id)))
    (should (harness-voice-stt-model-chosen-p))
    (should (equal "Parakeet 0.6B (English)" (harness-voice-stt-model-name))))
  (let ((harness-voice-stt-model 'no-such-speech-model)
        (harness-voice-effort 'high))
    (should (eq 'whisper-small-en (plist-get (harness-voice-stt-model-resolved) :id))))
  (let ((harness-voice-stt-model nil)
        (harness-voice-effort 'medium))
    (should (eq 'whisper-base-en (plist-get (harness-voice-stt-model-resolved) :id)))))

(ert-deftest harness-ui-voice-providers-stt-model-stack ()
  "The chosen model names the stack's profile, service and environment.
The pipeline is the harness server's, so this client names what the
selected model needs rather than declaring a stack of its own."
  (let ((harness-voice-stt-model 'parakeet-0.6b-v3))
    (should (equal '("parakeet") (harness-voice-stack-profiles)))
    (should (equal '(("PARAKEET_MODEL" . "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
                     ("PARAKEET_FEATURE_DIM" . "128"))
                   (harness-voice-stack-env)))
    (should (eq 'parakeet (plist-get (harness-voice-stt-model-resolved) :service))))
  (let ((harness-voice-stt-model 'whisper-small-en))
    (should (equal '("whisper") (harness-voice-stack-profiles)))
    (should (equal '(("WHISPER_MODEL" . "ggml-small.en.bin"))
                   (harness-voice-stack-env))))
  (let ((harness-voice-stt-model 'auto)
        (harness-voice-effort 'low))
    (should (equal '("whisper") (harness-voice-stack-profiles)))
    (should (equal '(("WHISPER_MODEL" . "ggml-tiny.en.bin"))
                   (harness-voice-stack-env)))))

(ert-deftest harness-ui-voice-providers-stt-model-choice-copy ()
  "A model choice names its engine and download; auto names its effort model."
  (let ((harness-voice-effort 'medium))
    (should (equal "Effort preset · Whisper base (English) · 142 MB"
                   (harness-voice-stt-model-choice 'auto))))
  (should (equal "Parakeet 0.6B (English) · sherpa-onnx · 650 MB"
                 (harness-voice-stt-model-choice 'parakeet-0.6b)))
  (should (equal "Whisper tiny (English) · whisper.cpp · 75 MB"
                 (harness-voice-stt-model-choice 'whisper-tiny-en))))

(ert-deftest harness-ui-voice-providers-stt-model-select ()
  "Selecting a model keeps it, stops a live session and restarts the pipeline."
  (let ((harness-voice-stt-model 'auto)
        (harness-voice-provider 'unmute)
        (harness-voice-effort 'medium)
        (stops 0)
        (restarts nil))
    (cl-letf (((symbol-function 'harness-voice-live--active-p) (lambda () t))
              ((symbol-function 'harness-voice-live-stop) (lambda () (cl-incf stops)))
              ((symbol-function 'harness-voice-setup--refresh) (lambda () nil))
              ((symbol-function 'harness-voice--pipeline-running-p) (lambda () t))
              ((symbol-function 'harness-ui-call)
               (lambda (method _params callback &optional _error)
                 (pcase method
                   ("_harness/speech/stop"
                    (push 'down restarts)
                    (funcall callback '(:state "stopped" :detail "Stopped")))
                   ("_harness/speech/start"
                    (push 'up restarts)
                    (funcall callback '(:state "running" :detail "2 of 2 services")))))))
      ;; A different model stops the session and restarts the pipeline.
      (harness-voice-select-stt-model 'parakeet-0.6b)
      (should (eq 'parakeet-0.6b harness-voice-stt-model))
      (should (= 1 stops))
      (should (equal '(down up) (nreverse restarts)))
      ;; Another model does the same.
      (setq restarts nil)
      (harness-voice-select-stt-model 'whisper-base-en)
      (should (eq 'whisper-base-en harness-voice-stt-model))
      (should (= 2 stops))
      (should (equal '(down up) (nreverse restarts)))
      ;; `auto' at the medium effort resolves to the same model: the
      ;; session still ends, but nothing reloads.
      (setq restarts nil)
      (harness-voice-select-stt-model 'auto)
      (should (eq 'auto harness-voice-stt-model))
      (should (= 3 stops))
      (should-not restarts)
      ;; An unknown model is refused before anything changes.
      (should (equal "Unknown speech model · no-such-model"
                     (error-message-string
                      (should-error (harness-voice-select-stt-model 'no-such-model)
                                    :type 'user-error))))
      (should (eq 'auto harness-voice-stt-model))
      (should (= 3 stops)))))

(ert-deftest harness-ui-voice-providers-stt-model-restart-keeps-the-old-engine ()
  "A stop that fails leaves the pipeline alone instead of starting a second engine."
  (let ((harness-voice-stt-model 'auto)
        (harness-voice-provider 'unmute)
        (harness-voice-effort 'medium)
        (ups 0))
    (cl-letf (((symbol-function 'harness-voice-live--active-p) (lambda () nil))
              ((symbol-function 'harness-voice-setup--refresh) (lambda () nil))
              ((symbol-function 'harness-voice--pipeline-running-p) (lambda () t))
              ((symbol-function 'harness-ui-call)
               (lambda (method _params _callback &optional _error)
                 (when (equal method "_harness/speech/start") (cl-incf ups))
                 (when (equal method "_harness/speech/stop")
                   (funcall _callback '(:state "error" :detail "pull access denied"))))))
      (harness-voice-select-stt-model 'parakeet-0.6b)
      (should (eq 'parakeet-0.6b harness-voice-stt-model))
      (should (zerop ups)))))

(ert-deftest harness-ui-voice-providers-effort-restarts-the-auto-model ()
  "The effort level restarts a running pipeline only when it picks a new model."
  (skip-unless (featurep 'harness-stacks))
  (let ((harness-voice-stt-model 'auto)
        (harness-voice-provider 'unmute)
        (harness-voice-effort 'medium)
        (restarts 0))
    (cl-letf (((symbol-function 'harness-voice-setup--refresh) (lambda () nil))
              ((symbol-function 'harness-voice--restart-pipeline) (lambda () (cl-incf restarts))))
      (harness-voice-select-effort 'high)
      (should (= 1 restarts))
      (should (eq 'high harness-voice-effort))
      ;; A chosen model does not change when the effort level does.
      (setq harness-voice-stt-model 'parakeet-0.6b)
      (harness-voice-select-effort 'low)
      (should (= 1 restarts))
      (should (eq 'low harness-voice-effort)))))

(ert-deftest harness-ui-voice-providers-setup-stt-model-copy ()
  "The setup list names the speech model under the pipeline, with its change control."
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'local)
        (harness-voice-stt-model 'parakeet-0.6b)
        (harness-voice-effort 'medium)
        (harness-voice-pipeline-status
         '(:state "running" :detail "2 of 2 services")))
    (harness-define-voice-provider 'local
      :label "Local pipeline" :capability 'live :command '("true"))
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional _) '(pipewire "PipeWire" "pw-record" "pw-play"))))
      (with-temp-buffer
        (harness-voice-setup--insert)
        (let ((text (buffer-substring-no-properties (point-min) (point-max)))
              (full (buffer-substring (point-min) (point-max))))
          (should (string-match-p
                   "^Speech to text  Parakeet 0.6B (English) · sherpa-onnx · 650 MB  \\[Change\\]$"
                   text))
          (should (string-match-p "^Pipeline  ● running  \\[Stop\\]$" text))
          (should (equal "NVIDIA Parakeet TDT 0.6B, int8 ONNX · English, punctuation and case, fast on CPU."
                         (get-text-property
                          (string-match "Parakeet 0.6B (English)" full)
                          'help-echo full)))
          (should (equal "Speech to text model"
                         (get-text-property
                          (string-match "\\[Change\\]" full) 'help-echo full)))))
      (let ((harness-voice-stt-model 'auto))
        (with-temp-buffer
          (harness-voice-setup--insert)
          (let ((text (buffer-substring-no-properties (point-min) (point-max)))
                (full (buffer-substring (point-min) (point-max))))
            (should (string-match-p
                     "^Speech to text  Effort preset · Whisper base (English) · 142 MB  \\[Change\\]$"
                     text))
            (should (equal "whisper.cpp base.en · the default CPU trade-off."
                           (get-text-property
                            (string-match "Effort preset" full)
                            'help-echo full)))))))))

(ert-deftest harness-ui-voice-providers-stt-model-not-for-wav ()
  "A client the harness never answered has no speech model line."
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'plain)
        (harness-voice-pipeline-status nil))
    (harness-define-voice-provider 'plain
      :label "Plain voice" :capability 'wav :command '("true"))
    (with-temp-buffer
      (harness-voice-setup--insert)
      (should-not (string-match-p "Speech to text"
                                  (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest harness-ui-voice-providers-stt-model-define-replaces ()
  "Defining a speech model again replaces its record."
  (let ((harness-voice-stt-models (make-hash-table :test 'eq)))
    (harness-define-voice-stt-model 'test-model :label "One" :engine "engine")
    (should (equal "One" (harness-voice-stt-model-label 'test-model)))
    (should (equal '(test-model) (harness-voice-stt-model-ids)))
    (harness-define-voice-stt-model 'test-model :label "Two" :engine "other"
                                    :service 'parakeet :profile "parakeet")
    (should (equal "Two" (harness-voice-stt-model-label 'test-model)))
    (should (eq 'parakeet (plist-get (harness-voice-stt-model-get 'test-model) :service)))
    (should (equal "parakeet" (plist-get (harness-voice-stt-model-get 'test-model) :profile)))
    (should (equal "inference" (plist-get (harness-voice-stt-model-get 'test-model) :path)))
    (should-not (harness-voice-stt-model-get 'no-such-model))))

(ert-deftest harness-ui-voice-providers-parakeet-self-test ()
  "The Parakeet server checks its routes without a model or a microphone."
  (unless (executable-find "python3")
    (ert-skip "Python 3 unavailable"))
  (let ((file (expand-file-name "scripts/stacks/voice-local/parakeet/server.py"
                                harness-test-root)))
    (should (file-exists-p file))
    (with-temp-buffer
      (let ((status (call-process "python3" nil t nil "-B" file "--self-test")))
        (should (eql 0 status))
        (should (string-match-p "self-test ok" (buffer-string)))))))

(ert-deftest harness-ui-voice-providers-parakeet-python-suite ()
  "Run the Parakeet server's Python tests, which need no model or network."
  (unless (executable-find "python3")
    (ert-skip "Python 3 unavailable"))
  (let ((buffer (generate-new-buffer " *parakeet tests*"))
        (default-directory (file-name-as-directory harness-test-root)))
    (unwind-protect
        (let ((status (call-process (executable-find "python3") nil buffer nil
                                    "test/harness-voice-parakeet-test.py")))
          (with-current-buffer buffer
            (unless (eql 0 status)
              (ert-fail (format "Parakeet tests exited %s:\n%s"
                                status (buffer-string))))))
      (kill-buffer buffer))))

(provide 'harness-ui-voice-providers-test)
;;; harness-ui-voice-providers-test.el ends here
