;;; harness-speech-test.el --- Tests for the local speech service  -*- lexical-binding: t; -*-

;;; Commentary:

;; The speech module (lisp/modules/harness-speech.el) owns the local
;; voice pipeline: the harness process starts it, stops it and reports
;; it, and clients share it over ACP for transcription and synthesis.
;; Nothing here needs whisper.cpp, Kokoro, docker or a microphone: the
;; bundled fixture (test/harness-speech-service.py) serves the two
;; routes the pipeline serves, and the stack is a stub state, so the
;; tests are about what the module does with either.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-speech)
(require 'harness-stacks)

(defvar harness-compose-stacks)
(defvar harness-stacks--states)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-acp--clients)
(defvar harness-acp-test-messages)

(defconst harness-speech-test--fixture
  (expand-file-name "test/harness-speech-service.py" harness-test-root)
  "The stand-in speech service the tests run as the harness's child.")

(defun harness-speech-test--python ()
  "Return the python3 the fixture runs on, or skip the test."
  (or (executable-find "python3") (ert-skip "Python 3 unavailable")))

(defun harness-speech-test--port ()
  "Return a free loopback TCP port."
  (let* ((server (make-network-process :name "harness-speech-test-port"
                                       :server t :host "127.0.0.1" :service t
                                       :family 'ipv4 :noquery t))
         (port (process-contact server :service)))
    (delete-process server)
    (if (consp port) (cdr port) port)))

(defun harness-speech-test--wav ()
  "Return a base64 WAV of a tenth of a second of silence."
  (let ((samples 3200))
    (base64-encode-string
     (concat "RIFF" (let ((n (+ 36 (* 2 samples))))
                      (unibyte-string (logand n 255) (logand (ash n -8) 255)
                                      (logand (ash n -16) 255) (logand (ash n -24) 255)))
             "WAVEfmt " (unibyte-string 16 0 0 0 1 0 1 0 128 62 0 0 0 125 0 0 2 0 16 0)
             "data" (let ((n (* 2 samples)))
                      (unibyte-string (logand n 255) (logand (ash n -8) 255)
                                      (logand (ash n -16) 255) (logand (ash n -24) 255)))
             (make-string (* 2 samples) 0))
     t)))

(defmacro harness-speech-test-with (bindings &rest body)
  "Run BODY with the speech module loaded, and BINDINGS inside it.
The pipeline runs the fixture on two free ports, which is how a test
sees the commands a user configures.  The stack is a stub, so nothing
asks a container runtime for anything."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config container-runtime stacks speech))
       (harness-test-load-module m))
     (let* ((harness-speech-test--stt-port (harness-speech-test--port))
            (harness-speech-test--tts-port (harness-speech-test--port))
            (harness-speech-local-stt-command
             (list (or (executable-find "python3") "python3")
                   harness-speech-test--fixture "--stt-only"
                   "--port" (number-to-string harness-speech-test--stt-port)))
            (harness-speech-local-tts-command
             (list (or (executable-find "python3") "python3")
                   harness-speech-test--fixture "--tts-only"
                   "--port" (number-to-string harness-speech-test--tts-port)))
            (harness-speech-local-stt-url
             (format "http://127.0.0.1:%d/inference" harness-speech-test--stt-port))
            (harness-speech-local-tts-url
             (format "http://127.0.0.1:%d/v1/audio/speech" harness-speech-test--tts-port))
            (harness-speech-local-startup-timeout 20)
            (harness-speech-request-timeout 20)
            (harness-speech-autostart nil))
       ;; BINDINGS come after the defaults, so a test may set the
       ;; commands, the URLs or the timeouts itself.
       (let ,bindings
         (unwind-protect
             (progn ,@body)
           (harness-speech--stop-all))))))

(defmacro harness-speech-test-with-stack (&rest body)
  "Run BODY with the bundled compose stack, and its runtime stubbed out."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config container-runtime stacks speech))
       (harness-test-load-module m))
     (let ((harness-speech-local-stt-command nil)
           (harness-speech-local-tts-command nil)
           (harness-speech-local-stt-url nil)
           (harness-speech-local-tts-url nil)
           (harness-stacks--states (make-hash-table :test 'eq))
           (harness-stacks--commands (make-hash-table :test 'eq))
           (harness-speech--status nil))
       ,@body)))

;;;; The stack it declares

(ert-deftest harness-speech-declares-the-voice-stack ()
  "The bundled pipeline's stack is the speech module's, on loopback alone."
  (harness-speech-test-with-stack
    (let ((stack (harness-compose-stack-get 'voice-local)))
      (should stack)
      (should (equal "Local voice pipeline" (plist-get stack :label)))
      (should (equal "voice-local" (plist-get stack :project)))
      (should (equal "voice" (plist-get stack :network)))
      (should (equal '((whisper 8080) (parakeet 8081) (tts 8880))
                     (plist-get stack :endpoints)))
      ;; One speech model runs beside Kokoro: the profiles follow the
      ;; model the client chose, and stopping removes both engines.
      (should (equal '("whisper") (funcall (plist-get stack :profiles))))
      (should (equal '("whisper" "parakeet") (plist-get stack :all-profiles)))
      (should (string-suffix-p "scripts/stacks/voice-local"
                               (plist-get stack :directory)))
      ;; The model and the voice are the server's, and reach the stack
      ;; as its environment.
      (let ((harness-speech-local-whisper "ggml-tiny.en.bin")
            (harness-speech-local-voice "af_heart"))
        (should (equal '(("WHISPER_MODEL" . "ggml-tiny.en.bin")
                         ("HARNESS_TTS_VOICE" . "af_heart"))
                       (funcall (plist-get stack :env))))))))

(ert-deftest harness-speech-backend-commands-win ()
  "Commands of your own win; a half configuration is named, not run."
  (harness-speech-test-with-stack
    (should (eq 'stack (harness-speech--backend)))
    (should-not (harness-speech--command-configured-p))
    (let ((harness-speech-local-stt-command '("whisper-server")))
      (should (eq 'stack (harness-speech--backend)))
      (should (harness-speech--command-configured-p))
      (should (equal "Both speech commands needed"
                     (plist-get (harness-speech--stack-state) :detail))))
    (let ((harness-speech-local-stt-command '("whisper-server"))
          (harness-speech-local-tts-command '("piper")))
      (should (eq 'command (harness-speech--backend)))
      (should-not (harness-speech--command-configured-p)))))

(ert-deftest harness-speech-status-copy ()
  "A status says what runs, and one line for why it cannot be used."
  (harness-speech-test-with-stack
    (let ((status (harness-speech--describe 'running "2 of 2 services")))
      (should (equal "running" (plist-get status :state)))
      (should (equal "stack" (plist-get status :backend)))
      (should (equal "af_heart" (plist-get status :voice)))
      (should (equal "ggml-base.en.bin" (plist-get status :model)))
      (should-not (plist-get status :reason)))
    (dolist (state '((starting "starting") (stopped "stopped")))
      (should (equal (format "Local voice pipeline · %s" (cadr state))
                     (harness-speech--reason (car state) "Starting"))))
    (should (equal "Local voice pipeline · failed · Runtime unavailable"
                   (harness-speech--reason 'error "Runtime unavailable")))))

(ert-deftest harness-speech-stack-state-follows-the-runtime ()
  "The stack's state is the pipeline's, and a stopped one is stopped."
  (harness-speech-test-with-stack
    (cl-letf (((symbol-function 'harness-compose-stack-status)
               (lambda (_id &optional _cb)
                 (list :state 'running :detail "2 of 2 services"
                       :ports '(("whisper" . ((8080 . 41001)))
                                ("tts" . ((8880 . 41002)))))))
              ((symbol-function 'harness-compose-stack-endpoint)
               (lambda (_id service path)
                 (format "http://127.0.0.1:%d/%s"
                         (if (eq service 'whisper) 41001 41002) path))))
      (let ((status (harness-call 'speech/status)))
        (should (equal "running" (plist-get status :state)))
        (should (equal "2 of 2 services" (plist-get status :detail)))
        (should (equal "http://127.0.0.1:41001/inference" (plist-get status :stt-url)))
        (should (equal "http://127.0.0.1:41002/v1/audio/speech"
                       (plist-get status :tts-url)))))
    (cl-letf (((symbol-function 'harness-compose-stack-status)
               (lambda (_id &optional _cb) (list :state 'stopped :detail "Stopped"))))
      (let ((status (harness-call 'speech/status)))
        (should (equal "stopped" (plist-get status :state)))
        (should (equal "Local voice pipeline · stopped" (plist-get status :reason)))
        (should-not (plist-get status :stt-url))))))

(ert-deftest harness-speech-stack-start-failure-is-a-state ()
  "A runtime that cannot start the stack is a failure the client shows."
  (harness-speech-test-with-stack
    (let ((harness-stacks--stacks (make-hash-table :test 'eq)) answer)
      (harness-define-compose-stack 'voice-local
        :label "Local voice pipeline"
        :directory temporary-file-directory)
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () nil))
                ((symbol-function 'harness-container-runtime-need-reason)
                 (lambda () "Runtime unavailable · Docker")))
        (setq answer (harness-call 'speech/start))
        (should (equal "error" (plist-get answer :state)))
        (should (equal "Local voice pipeline · failed · Runtime unavailable · Docker"
                       (plist-get answer :reason)))))))

(ert-deftest harness-speech-stack-failure-names-the-cause-and-the-command ()
  "A failed start names the provider's own reason, its exit status and its command.
Podman's `compose' ends its output with a line that names its provider
and the whole argv and says only that it exited nonzero; the reason is
the provider's line before it.  The pipeline's one line keeps the
reason and the status, and the status plist carries the command, where
it ran and the exit status, so a client can show what actually failed."
  (harness-speech-test-with-stack
    (let ((harness-stacks--stacks (make-hash-table :test 'eq))
          answer)
      (harness-define-compose-stack 'voice-local
        :label "Local voice pipeline"
        :directory "/Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local"
        :project "voice-local"
        :endpoints '((whisper 8080) (parakeet 8081) (tts 8880))
        :profiles (lambda () (list (or (harness-speech--stt-profile) "whisper"))))
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (_argv _env callback &optional _directory)
                   (funcall callback
                            (cons 1 (concat
                                     ">>>> Executing external compose provider \"/opt/homebrew/bin/podman-compose\". <<<<\n"
                                     "\n"
                                     "Error: no image found in manifest list for architecture \"arm64\", variant \"v8\", OS \"linux\"\n"
                                     "Error: executing /opt/homebrew/bin/podman-compose -p voice-local -f /Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local/docker-compose.yml --profile whisper up -d: exit status 1\n"))))))
        (setq answer (harness-call 'speech/start))
        (should (equal "error" (plist-get answer :state)))
        (should (equal (concat "Local voice pipeline · failed · exit 1 · "
                               "Error: no image found in manifest list for architecture "
                               "\"arm64\", variant \"v8\", OS \"linux\"")
                       (plist-get answer :reason)))
        ;; The command the state names is the exact argv that ran, profiles
        ;; and all: the same one the stack would build for its runtime.
        (should (equal (harness-compose-stack--argv
                        (harness-compose-stack-get 'voice-local) "up" "-d")
                       (plist-get answer :command)))
        (should (equal '("docker" "compose" "-p" "voice-local" "-f"
                         "/Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local/docker-compose.yml"
                         "--profile" "whisper" "up" "-d")
                       (plist-get answer :command)))
        (should (equal "/Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local"
                       (plist-get answer :directory)))
        (should (eql 1 (plist-get answer :exit)))
        (should (eq 'voice-local (plist-get answer :log)))
        ;; The whole of it is the log the client asks for, not a line.
        (let ((log (harness-call 'speech/log)))
          (should (string-prefix-p
                   (concat "docker compose -p voice-local -f "
                           "/Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local/docker-compose.yml"
                           " --profile whisper up -d\n")
                   log))
          (should (string-match-p "Exit  1\n" log))
          (should (string-match-p "no image found in manifest list" log)))))))

(ert-deftest harness-speech-stack-stop-says-stopped ()
  "Stopping is a state of its own, whatever the runtime says afterwards."
  (harness-speech-test-with-stack
    (cl-letf (((symbol-function 'harness-compose-stack-down)
               (lambda (_id &optional callback)
                 (let ((state (list :state 'stopped :detail "Stopped")))
                   (when callback (funcall callback state))
                   state))))
      (let ((status (harness-call 'speech/stop)))
        (should (equal "stopped" (plist-get status :state)))
        (should (equal "Local voice pipeline · stopped" (plist-get status :reason)))))))

;;;; The commands it runs

(ert-deftest harness-speech-starts-the-commands-as-children ()
  "Starting the commands runs them as the harness's children and waits.
The pipeline reports starting, then running once both answer, and the
children are the harness process's own."
  (harness-speech-test--python)
  (harness-speech-test-with
      ((events nil))
    (harness-on 'speech/changed (lambda (status) (push (plist-get status :state) events)))
    (let ((status (harness-speech-local-start)))
      (should (equal "starting" (plist-get status :state)))
      (should (equal "command" (plist-get status :backend)))
      (should (harness-speech--process 'stt))
      (should (harness-speech--process 'tts))
      ;; They are children of this Emacs: the harness process runs them.
      (dolist (role '(stt tts))
        (let ((process (cdr (assq role harness-speech--processes))))
          (should (process-live-p process))))
      (harness-test-wait (lambda () (harness-speech-running-p)) 25 "the pipeline running")
      (should (equal "running" (plist-get (harness-speech-local-status) :state)))
      (should (equal "2 of 2 programs" (plist-get (harness-speech-local-status) :detail)))
      (should (member "running" events)))
    (harness-speech-local-stop)
    (should-not (harness-speech--process 'stt))
    (should-not (harness-speech--process 'tts))
    (should (equal "stopped" (plist-get (harness-speech-local-status) :state)))))

(ert-deftest harness-speech-command-death-is-a-failure ()
  "A program that exits on its own reads as a failure, not as running."
  (harness-speech-test--python)
  (harness-speech-test-with
      ((harness-speech-local-tts-command
        (list (or (executable-find "python3") "python3") "-c" "import sys; sys.exit(3)")))
    (let ((harness-speech-local-tts-url "http://127.0.0.1:1/v1/audio/speech"))
      (harness-speech-local-start)
      ;; The program is dead before the wait begins; the wait is for the
      ;; module to have noticed, which the state it remembers then says.
      (harness-test-wait (lambda () (equal "error" (plist-get harness-speech--status :state)))
                         20 "the dead program reported")
      (let ((status (harness-speech-local-status)))
        (should (equal "Text to speech exited" (plist-get status :detail)))
        (should (equal "Local voice pipeline · failed · Text to speech exited"
                       (plist-get status :reason)))))))

(ert-deftest harness-speech-refuses-a-missing-program ()
  "A command whose program is absent is refused before anything runs."
  (harness-speech-test-with
      ((harness-speech-local-tts-command '("harness-no-such-speech-program")))
    (should (equal "Speech program unavailable · harness-no-such-speech-program"
                   (error-message-string
                    (should-error (harness-speech-local-start) :type 'error))))
    (should-not (harness-speech--process 'tts))))

(ert-deftest harness-speech-refuses-urls-unset ()
  "Commands without their URLs say so, rather than watching nothing."
  (harness-speech-test-with
      ((harness-speech-local-stt-url nil))
    (should (equal "Speech URLs unset"
                   (error-message-string
                    (should-error (harness-speech-local-start) :type 'error))))
    ;; A command whose URL is gone has no service to send speech to.
    (should (equal "Local voice pipeline · stopped"
                   (error-message-string
                    (should-error (harness-speech-transcribe (harness-speech-test--wav))
                                  :type 'error))))))

;;;; Speech, shared

(ert-deftest harness-speech-transcribes ()
  "Speech to text posts the audio to the service and returns its words.
The wording of the service is the client's: the client sends base64 and
reads text, and never needs the service's address."
  (harness-speech-test--python)
  (harness-speech-test-with
      ()
    (harness-speech-local-start)
    (harness-test-wait (lambda () (harness-speech-running-p))
                       25 "the pipeline running")
    (let* ((result (harness-test-await
                    (harness-call 'speech/transcribe (harness-speech-test--wav))))
           (text (plist-get result :text)))
      (should (equal "harness speech fixture" text)))
    ;; A language, and the format, reach the service as its form fields.
    (let ((result (harness-test-await
                   (harness-call 'speech/transcribe (harness-speech-test--wav)
                                 "wav" "en"))))
      (should (equal "harness speech fixture" (plist-get result :text))))))

(ert-deftest harness-speech-synthesizes ()
  "Text to speech returns the WAV the service made, as base64."
  (harness-speech-test--python)
  (harness-speech-test-with
      ()
    (harness-speech-local-start)
    (harness-test-wait (lambda () (harness-speech-running-p))
                       25 "the pipeline running")
    (let* ((result (harness-test-await
                    (harness-call 'speech/synthesize "Spoken over the harness")))
           (audio (plist-get result :audio)))
      (should (equal "audio/wav" (plist-get result :mime)))
      (should (stringp audio))
      (let ((bytes (base64-decode-string audio)))
        (should (string-prefix-p "RIFF" bytes))
        (should (> (length bytes) 44))))))

(ert-deftest harness-speech-speech-refused-when-stopped ()
  "Speech is refused while no pipeline runs, in the client's words.
Stopping one that is already stopped is not an error."
  (harness-speech-test-with
      ()
    (should (equal "stopped"
                   (plist-get (harness-call 'speech/stop) :state)))
    (let ((harness-speech-local-stt-url nil)
          (harness-speech-local-tts-url nil)
          (harness-speech-local-stt-command nil)
          (harness-speech-local-tts-command nil))
      (should (equal "Local voice pipeline · stopped"
                     (error-message-string
                      (should-error (harness-call 'speech/transcribe (harness-speech-test--wav))
                                    :type 'error)))))))

(ert-deftest harness-speech-http-failure-is-one-line ()
  "A service that answers an error is one line, not a transport dump."
  (harness-speech-test--python)
  (harness-speech-test-with
      ((port (harness-speech-test--port)))
    (let ((harness-speech-local-tts-url (format "http://127.0.0.1:%d/v1/audio/speech" port))
          (harness-speech-local-tts-command
           (list (or (executable-find "python3") "python3")
                 harness-speech-test--fixture "--tts-only" "--status" "503"
                 "--port" (number-to-string port))))
      (harness-speech-local-start)
      (harness-test-wait
       (lambda () (harness-speech--url-answers-p
                   (format "http://127.0.0.1:%d/v1/audio/speech" port)))
       20 "the service")
      (should (equal "Local voice pipeline · HTTP 503"
                     (error-message-string
                      (should-error
                       (harness-test-await
                        (harness-call 'speech/synthesize "unheard"))
                       :type 'error)))))))

(ert-deftest harness-speech-empty-answers ()
  "Empty audio or text is refused before a request is made."
  (harness-speech-test-with
      ()
    (should (equal "Speech audio unset"
                   (error-message-string
                    (should-error (harness-speech-transcribe "") :type 'error))))
    (should (equal "Speech audio unreadable"
                   (error-message-string
                    (should-error (harness-speech-transcribe "not base64 !!")
                                  :type 'error))))
    (should (equal "Speech text unset"
                   (error-message-string
                    (should-error (harness-speech-synthesize "  ") :type 'error))))))

;;;; Over ACP

(defun harness-speech-test--acp-request (conn method params)
  "Await the result of METHOD with PARAMS over CONN."
  (harness-test-await (harness-acp-request conn method params)))

(ert-deftest harness-speech-acp-methods-are-shared ()
  "A client transcribes and synthesizes over ACP, on the harness's pipeline.
That is the sharing the module is for: the phone sends audio on the
connection it has and gets text back, and never runs a speech model."
  (harness-speech-test--python)
  (harness-speech-test-with
      ()
    (harness-test-load-module 'acp)
    (let ((conn (harness-acp-connect)))
      (unwind-protect
          (progn
            (harness-acp-initialize conn)
            (harness-speech-test--acp-request conn "_harness/speech/start" nil)
            (harness-test-wait (lambda () (harness-speech-running-p))
                               25 "the pipeline running")
            (let ((status (harness-speech-test--acp-request conn "_harness/speech/status" nil)))
              (should (equal "running" (plist-get status :state)))
              (should (equal "2 of 2 programs" (plist-get status :detail))))
            (let ((answer (harness-speech-test--acp-request
                           conn "_harness/speech/transcribe"
                           (list :audio (harness-speech-test--wav)))))
              (should (equal "harness speech fixture" (plist-get answer :text))))
            (let ((answer (harness-speech-test--acp-request
                           conn "_harness/speech/synthesize"
                           (list :text "Over the connection"))))
              (should (string-prefix-p "RIFF"
                                       (base64-decode-string (plist-get answer :audio))))))
        (harness-acp-close conn)))))

(ert-deftest harness-speech-acp-state-moves ()
  "A client that started the pipeline hears its state move.
`speech/changed' is forwarded as `_harness/event', so a setup page on
another machine follows the harness's own pipeline."
  (harness-speech-test--python)
  (harness-speech-test-with
      ()
    (harness-test-load-module 'acp)
    (let ((conn (harness-acp-connect)) (events nil))
      (unwind-protect
          (progn
            (harness-acp-set-handler
             conn (lambda (_method params _respond)
                    (push params events)))
            (harness-acp-initialize conn)
            (harness-speech-test--acp-request conn "_harness/speech/start" nil)
            (harness-test-wait (lambda () (harness-speech-running-p))
                               25 "the pipeline running")
            (harness-test-wait
             (lambda ()
               (cl-some (lambda (p) (and (equal (plist-get p :event) "speech/changed")
                                    (equal "running"
                                           (plist-get (car (plist-get p :args)) :state))))
                        events))
             10 "the running state forwarded"))
        (harness-acp-close conn)))))

;;;; Module

(ert-deftest harness-speech-module-requires-stacks ()
  "The module says what it needs, and declares the event clients follow."
  (let ((module (harness-module-get 'speech)))
    (should module)
    (should (memq 'stacks (harness-module-requires module))))
  (should (assq 'speech/changed (harness-events)))
  (dolist (method '(speech/status speech/start speech/stop speech/transcribe speech/synthesize))
    (should (harness-method-exists-p method))))

(provide 'harness-speech-test)
;;; harness-speech-test.el ends here
