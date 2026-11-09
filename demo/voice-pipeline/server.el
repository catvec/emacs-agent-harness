;;; server.el --- A headless harness whose pipeline is the demo's  -*- lexical-binding: t; -*-

;;; Commentary:

;; The server half of the voice pipeline demo: start a harness in batch,
;; point its `speech' module at the bundled fixture as its `command'
;; backend, start the pipeline, and listen for an ACP client on loopback.
;; The client (client.el) then uses the pipeline over that connection.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)
(require 'harness-speech)
(require 'harness-acp)

(defun harness-voice-pipeline-demo--say (fmt &rest args)
  "Print FMT with ARGS on stdout, as the demo script reads it."
  (princ (apply #'format fmt args))
  (terpri)
  (flush-standard-output))

(defun harness-voice-pipeline-demo-server (state fixture stt tts acp)
  "Run a harness in BATCH whose local pipeline is FIXTURE.
STATE is a private directory for the harness's files, STT and TTS the
ports the fixture serves on, and ACP the port to listen on.  It stays
up until the demo stops it."
  (setq harness-directory
        (file-name-as-directory (or (getenv "HARNESS_DEMO_ROOT") default-directory))
        harness-state-directory (file-name-as-directory state)
        harness-speech-local-stt-command
        (list "python3" fixture "--stt-only" "--port" (number-to-string stt))
        harness-speech-local-tts-command
        (list "python3" fixture "--tts-only" "--port" (number-to-string tts))
        harness-speech-local-stt-url (format "http://127.0.0.1:%d/inference" stt)
        harness-speech-local-tts-url (format "http://127.0.0.1:%d/v1/audio/speech" tts)
        harness-speech-local-startup-timeout 20
        harness-speech-autostart nil
        harness-acp-port acp
        harness-acp-host "127.0.0.1")
  (harness-speech--init)
  (let ((status (harness-call 'speech/start)))
    (harness-voice-pipeline-demo--say "STARTED %s · %s"
                                      (plist-get status :state)
                                      (plist-get status :backend)))
  (harness-call 'acp/start :port acp)
  (harness-voice-pipeline-demo--say "LISTENING %d" acp)
  (with-temp-file (expand-file-name "token" harness-state-directory)
    (insert harness-acp-token))
  ;; Let the pipeline come up before the client looks, so the demo is
  ;; about the sharing rather than a race with a start.  The watch turns
  ;; `starting' into `running' once both services answer, so it is the
  ;; remembered state that is waited for.
  (harness-speech--cancel-watch)
  ;; A batch Emacs runs no timers on its own, so the demo asks the
  ;; watch itself, the way its timer would.
  (let ((deadline (+ (float-time) 25)))
    (while (and (not (equal "running" (plist-get harness-speech--status :state)))
                (< (float-time) deadline))
      (condition-case nil (harness-speech--watch) (error nil))
      (accept-process-output nil 0.05)
      (sleep-for 0.05)))
  (harness-voice-pipeline-demo--say "PIPELINE %s · %s"
                                    (plist-get (harness-speech-local-status) :state)
                                    (plist-get (harness-speech-local-status) :detail))
  (harness-voice-pipeline-demo--say
   "CHILDREN %s"
   (mapconcat (lambda (role)
                (format "%s pid %s" role
                        (if-let* ((process (harness-speech--process role)))
                            (number-to-string (process-id process))
                          "none")))
              '(stt tts) ", "))
  ;; Serve until the client stops the pipeline.
  (let ((deadline (+ (float-time) 120)))
    (while (and (harness-speech-running-p) (< (float-time) deadline))
      (accept-process-output nil 0.05)
      (sleep-for 0.05)))
  (harness-voice-pipeline-demo--say "STOPPED %s"
                                    (if (harness-speech--process 'stt) "programs live" "programs ended"))
  (harness-speech--stop-all)
  (ignore-errors (harness-call 'acp/stop)))

(provide 'server)
;;; server.el ends here
