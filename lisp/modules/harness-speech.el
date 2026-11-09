;;; harness-speech.el --- The local speech service the harness runs for its clients  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Speech to text and text to speech are services, not capabilities of
;; a keyboard: whisper.cpp and Kokoro are large, they want a machine
;; with a CPU to spare, and a phone has neither the room for the models
;; nor a place to run them.  So the local voice pipeline is the harness
;; server's, not a client's, and every client shares the one pipeline
;; over the network, as docs/computers.md says a program that offers an
;; API other processes share runs next to the server.
;;
;; This module owns it.  The harness process starts the pipeline and
;; stops it; a client asks for its state and for speech, never for a
;; program to run on itself:
;;
;;   `harness-speech-local-stt-command'  a program the harness runs for
;;   `harness-speech-local-tts-command'  speech to text and text to
;;                                       speech, serving at the URL
;;                                       beside it (`...-stt-url',
;;                                       `...-tts-url'); they are child
;;                                       processes of the harness and
;;                                       end with it.
;;
;; With no commands the bundled `voice-local' compose stack runs
;; instead -- whisper.cpp and Kokoro in containers, published on
;; loopback only -- and the URLs are the ones the runtime gave it.
;;
;; Clients reach the pipeline over ACP:
;;
;;   `speech/status'      what runs, where, with which voice and model,
;;                        and the one line a client shows when it
;;                        cannot be used
;;   `speech/start'       start it; the answer is the state as it is
;;   `speech/stop'        stop it
;;   `speech/transcribe'  {audio: BASE64 WAV} -> (:text TEXT)
;;   `speech/synthesize'  {text: TEXT} -> (:audio BASE64 WAV)
;;
;; The last two are the sharing: a client sends its audio on the
;; connection it already has, the harness posts it to the service on
;; its own loopback, and the answer comes back the same way.  Nothing
;; is published to the network for that, and a phone needs no
;; whisper.cpp.  A client on this machine may use the URLs
;; `speech/status' reports instead, which is what the Emacs live voice
;; sidecar does.  `speech/changed' carries the state whenever it moves.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-stacks)

(defgroup harness-speech nil
  "The local speech service the harness runs for its clients."
  :group 'harness)

(defvar harness-directory)

(defconst harness-speech-local-stack 'voice-local
  "The compose stack the bundled local pipeline runs in.")

(defconst harness-speech-local-service-host "127.0.0.1"
  "The host the bundled pipeline is published on: loopback alone.
The services answer no authentication, so they are not put on a
network; a client elsewhere asks the harness for speech over ACP
instead (`speech/transcribe', `speech/synthesize').")

(defcustom harness-speech-local-stt-command nil
  "Command the harness runs for speech to text, or nil for its stack.
An argv list, never a shell snippet, and a child process of the harness
server: it ends with the harness.  It must serve the OpenAI-compatible
route `harness-speech-local-stt-url' names, which is required with it.
whisper.cpp's server is the shape the bundled stack runs:

  (\"whisper-server\" \"-m\" \"/models/ggml-base.en.bin\"
   \"--host\" \"127.0.0.1\" \"--port\" \"8080\")

This is the harness server's configuration, not a client's, and not a
safe directory-local option."
  :type '(choice (const :tag "The bundled stack" nil) (repeat string))
  :group 'harness-speech)

(defcustom harness-speech-local-stt-url nil
  "URL the speech-to-text command serves, or nil for the stack.
Such as \"http://127.0.0.1:8080/inference\".  Required with
`harness-speech-local-stt-command'."
  :type '(choice (const :tag "The bundled stack" nil) string)
  :group 'harness-speech)

(defcustom harness-speech-local-tts-command nil
  "Command the harness runs for text to speech, or nil for its stack.
An argv list, never a shell snippet, and a child process of the harness
server: it ends with the harness.  It must serve the OpenAI-compatible
route `harness-speech-local-tts-url' names, which is required with it.
A Piper server or Kokoro-FastAPI is the shape the bundled stack runs."
  :type '(choice (const :tag "The bundled stack" nil) (repeat string))
  :group 'harness-speech)

(defcustom harness-speech-local-tts-url nil
  "URL the text-to-speech command serves, or nil for the stack.
Such as \"http://127.0.0.1:8880/v1/audio/speech\".  Required with
`harness-speech-local-tts-command'."
  :type '(choice (const :tag "The bundled stack" nil) string)
  :group 'harness-speech)

(defcustom harness-speech-local-voice "af_heart"
  "The voice the local pipeline speaks with.
The bundled stack's Kokoro service warms it at startup, and clients ask
the service for it (see `speech/status').  A service of your own may
know another, such as a Piper voice or OpenAI's \"alloy\"."
  :type 'string
  :group 'harness-speech)

(defcustom harness-speech-local-whisper "ggml-base.en.bin"
  "The whisper.cpp model file the bundled stack transcribes with.
`ggml-tiny.en.bin' (75 MB) is quickest, `ggml-small.en.bin' (466 MB)
the most accurate of the English models.  A model that is not in the
stack's volume yet is downloaded on the first start."
  :type 'string
  :group 'harness-speech)

(defcustom harness-speech-local-startup-timeout 120
  "Seconds a started pipeline gets to answer before it reads as failed.
A first start downloads a model and loads it, which takes a while."
  :type 'number
  :group 'harness-speech)

(defcustom harness-speech-request-timeout 120
  "Seconds one transcription or synthesis request may take."
  :type 'number
  :group 'harness-speech)

(defcustom harness-speech-autostart nil
  "Non-nil starts the local pipeline with the harness.
It starts after the modules are up, so a start that fails does not stop
the harness; `speech/changed' says how it went."
  :type 'boolean
  :group 'harness-speech)

;;;; State

(defvar harness-speech--status nil
  "The last status plist of the local pipeline, or nil before the first ask.")

(defvar harness-speech--processes nil
  "Role -> process of the commands the harness runs for the pipeline.")

(defvar harness-speech--started-at nil
  "When the last start began, as `float-time', or nil.")

(defvar harness-speech--watch-timer nil
  "Timer that follows a start until the pipeline answers, or nil.")

(defvar harness-speech--watch-deadline nil
  "When the wait for a started pipeline ends, as `float-time'.")

(defun harness-speech--url-parts (url)
  "Return (HOST . PORT) of URL, or nil when it names no TCP endpoint."
  (when (and (stringp url) (not (string-empty-p url)))
    (let ((rest (replace-regexp-in-string
                 "\\`\\(https?\\|tcp\\)://" "" (string-trim url))))
      (setq rest (car (split-string rest "[/?#]")))
      (when (string-match "\\`\\(\\[[^]]*\\]\\|[^:]*\\):\\([0-9]+\\)\\'" rest)
        (cons (string-remove-prefix "[" (string-remove-suffix "]" (match-string 1 rest)))
              (string-to-number (match-string 2 rest)))))))

(defconst harness-speech--state-words
  '((running . "running") (starting . "starting") (stopped . "stopped")
    (error . "failed"))
  "The words a client shows for the pipeline's state.")

(defun harness-speech--word (state)
  "Return the word for pipeline STATE."
  (or (cdr (assq state harness-speech--state-words)) "unknown"))

(defun harness-speech--backend ()
  "Return how the local pipeline runs: `command' or `stack'.
Commands of your own win when both are configured; a half configuration
falls back to the stack, which needs nothing typed."
  (if (and (consp harness-speech-local-stt-command)
           (consp harness-speech-local-tts-command))
      'command
    'stack))

(defun harness-speech--command-configured-p ()
  "Non-nil when one of the command settings is set without the other.
A half configuration is a mistake worth naming: the stack would run
instead, and the reason says so rather than leaving it unexplained."
  (let ((stt (consp harness-speech-local-stt-command))
        (tts (consp harness-speech-local-tts-command)))
    (and (or stt tts) (not (and stt tts)))))

(defun harness-speech--urls-required-p ()
  "Non-nil when the commands are set but the URLs beside them are not."
  (and (eq (harness-speech--backend) 'command)
       (or (not (and (stringp harness-speech-local-stt-url)
                     (not (string-empty-p harness-speech-local-stt-url))))
           (not (and (stringp harness-speech-local-tts-url)
                     (not (string-empty-p harness-speech-local-tts-url)))))))

(defun harness-speech--endpoint (service path)
  "Return the running stack's URL for SERVICE/PATH, or nil."
  (and (eq (harness-speech--backend) 'stack)
       (harness-compose-stack-endpoint harness-speech-local-stack service path)))

(defun harness-speech--stt-url ()
  "Return the URL speech to text answers at, or nil."
  (if (eq (harness-speech--backend) 'command)
      (and (stringp harness-speech-local-stt-url)
           (not (string-empty-p harness-speech-local-stt-url))
           harness-speech-local-stt-url)
    (harness-speech--endpoint 'whisper "inference")))

(defun harness-speech--tts-url ()
  "Return the URL text to speech answers at, or nil."
  (if (eq (harness-speech--backend) 'command)
      (and (stringp harness-speech-local-tts-url)
           (not (string-empty-p harness-speech-local-tts-url))
           harness-speech-local-tts-url)
    (harness-speech--endpoint 'tts "v1/audio/speech")))

(defun harness-speech--process (role)
  "Return the live process of ROLE, or nil."
  (let ((process (cdr (assq role harness-speech--processes))))
    (and (processp process) (process-live-p process) process)))

(defun harness-speech--command-state ()
  "Return (:state STATE :detail DETAIL) for the commands the harness runs."
  (let* ((stt (harness-speech--process 'stt))
         (tts (harness-speech--process 'tts))
         (live (cl-count-if #'identity (list stt tts))))
    (cond
     ((harness-speech--urls-required-p)
      (list :state 'error :detail "Speech URLs unset"))
     ;; Both alive while the wait runs reads as starting, and once it
     ;; ends as running; one alive alone is the other having exited.
     ((and stt tts (not harness-speech--watch-timer))
      (list :state 'running :detail "2 of 2 programs"))
     ((and stt tts)
      (list :state 'starting :detail (format "%d of 2 programs" live)))
     (t (list :state (if (or stt tts) 'error 'stopped)
              :detail (cond ((or stt tts)
                             (format "%s exited"
                                     (if stt "Text to speech" "Speech to text")))
                            (t "Stopped")))))))

(defun harness-speech--stack-state ()
  "Return (:state STATE :detail DETAIL) for the bundled compose stack."
  (if (harness-speech--command-configured-p)
      (list :state 'error :detail "Both speech commands needed")
    (let* ((record (harness-compose-stack-status harness-speech-local-stack))
           (state (plist-get record :state))
           (detail (or (plist-get record :detail) "Local voice pipeline")))
      (list :state (cond ((eq state 'running) 'running)
                         ((eq state 'starting) 'starting)
                         ((eq state 'stopped) 'stopped)
                         (t 'error))
            :detail detail))))

(defun harness-speech--reason (state detail)
  "Return the one line to show for pipeline STATE and DETAIL, or nil.
Nothing is said of a running pipeline: a client shows that it runs."
  (pcase state
    ('running nil)
    ('error (format "Local voice pipeline · %s · %s" (harness-speech--word state) detail))
    (_ (format "Local voice pipeline · %s" (harness-speech--word state)))))

(defun harness-speech--describe (state detail)
  "Return the status plist of the pipeline, in STATE with DETAIL."
  (let ((status (list :state (symbol-name state)
                      :detail detail
                      :backend (symbol-name (harness-speech--backend))
                      :stt-url (harness-speech--stt-url)
                      :tts-url (harness-speech--tts-url)
                      :voice harness-speech-local-voice
                      :model (and (eq (harness-speech--backend) 'stack)
                                  harness-speech-local-whisper)
                      :local t
                      :reason (harness-speech--reason state detail)
                      :updated (float-time))))
    (setq harness-speech--status status)
    status))

(defun harness-speech--remember (state detail)
  "Remember and emit the pipeline's status in STATE with DETAIL."
  (let ((status (harness-speech--describe state detail)))
    (harness-emit 'speech/changed status)
    status))

(defun harness-speech--known-state ()
  "Return the last state of the pipeline as a symbol, asking when unknown."
  (or (and harness-speech--status
           (intern-soft (plist-get harness-speech--status :state)))
      (let ((status (harness-speech-local-status)))
        (intern-soft (plist-get status :state)))))

;;;; Starting and stopping

(defun harness-speech--request-argv (command)
  "Return COMMAND as an argv list, or signal when it is not one."
  (unless (and (consp command) (stringp (car command)) (cl-every #'stringp command))
    (error "Speech command unset"))
  (unless (executable-find (car command))
    (error "Speech program unavailable · %s" (car command)))
  command)

(defun harness-speech--run-command (role command)
  "Start COMMAND as ROLE, a child process of the harness; return it."
  (let* ((argv (harness-speech--request-argv command))
         (buffer (get-buffer-create (format " *harness speech %s*" (symbol-name role)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer)))
    (let ((process (make-process
                    :name (format "harness-speech-%s" (symbol-name role))
                    :command argv :connection-type 'pipe :coding 'utf-8-unix
                    :noquery t :buffer buffer
                    :sentinel #'harness-speech--sentinel)))
      (set-process-query-on-exit-flag process nil)
      (setq harness-speech--processes
            (cons (cons role process)
                  (assq-delete-all role harness-speech--processes)))
      process)))

(defun harness-speech--sentinel (process _event)
  "Note that PROCESS, a pipeline program, ended."
  (when (memq (process-status process) '(exit signal))
    (let ((status (plist-get (or harness-speech--status (harness-speech-local-status)) :state)))
      ;; A stop kills both programs; only a death on its own reads as a
      ;; failure, and the state says which program went.  The wait for a
      ;; start ends with it: nothing is still coming.
      (unless (equal status "stopped")
        (harness-speech--cancel-watch)
        (setq harness-speech--started-at nil)
        (let ((state (harness-speech--command-state)))
          (harness-speech--remember (plist-get state :state)
                                    (plist-get state :detail)))))))

(defun harness-speech--kill-command (role)
  "Stop the process of ROLE, waiting a moment for it to end."
  (let ((process (cdr (assq role harness-speech--processes))))
    (setq harness-speech--processes (assq-delete-all role harness-speech--processes))
    (when (processp process)
      (when (process-live-p process)
        (ignore-errors (signal-process process 'SIGTERM)))
      (let ((deadline (+ (float-time) 3)))
        (while (and (process-live-p process) (< (float-time) deadline))
          (accept-process-output process 0.05)))
      (when (process-live-p process)
        (delete-process process))
      process)))

(defun harness-speech--cancel-watch ()
  "Stop following a start."
  (when (timerp harness-speech--watch-timer)
    (cancel-timer harness-speech--watch-timer))
  (setq harness-speech--watch-timer nil
        harness-speech--watch-deadline nil))

(defun harness-speech--url-answers-p (url)
  "Return non-nil when URL answers a TCP connection now."
  (pcase-let ((`(,host . ,port) (harness-speech--url-parts url)))
    (and (stringp host) (not (string-empty-p host)) port (> port 0)
         (let ((process (ignore-errors
                          (make-network-process :name "harness-speech-probe"
                                                :host host :service port
                                                :nowait t :noquery t
                                                :coding 'binary))))
           (when process
             (unwind-protect
                 (let ((deadline (+ (float-time) 0.5)) open)
                   (while (and (not open) (< (float-time) deadline))
                     (accept-process-output process 0.02)
                     (setq open (memq (process-status process) '(open run))))
                   (and open t))
               (ignore-errors (delete-process process))))))))

(defun harness-speech--watch ()
  "Follow a start: report running once the services run, or failed.
The timer stops itself; a pipeline that takes its time to load a model
reads as starting until its deadline.  A command first reads as a
process, so a program that dies ends the wait at once instead of
keeping it until the deadline."
  (let ((command (eq (harness-speech--backend) 'command))
        (stt (harness-speech--process 'stt))
        (tts (harness-speech--process 'tts)))
    (cond
     ((null harness-speech--started-at)
      (harness-speech--cancel-watch))
     ((and command (not (and stt tts)))
      (harness-speech--cancel-watch)
      (harness-speech--remember
       'error
       (format "%s exited" (if stt "Text to speech" "Speech to text"))))
     ((and (harness-speech--url-answers-p (harness-speech--stt-url))
           (harness-speech--url-answers-p (harness-speech--tts-url)))
      (harness-speech--cancel-watch)
      (harness-speech--remember 'running
                                (if command "2 of 2 programs" "2 of 2 services")))
     ((and harness-speech--watch-deadline
           (> (float-time) harness-speech--watch-deadline))
      (harness-speech--cancel-watch)
      (harness-speech--remember
       'error
       (format "No answer in %d s" (round harness-speech-local-startup-timeout))))
     (t (harness-speech--remember 'starting "Starting")))))

(defun harness-speech--start-watch ()
  "Start following a start until it settles."
  (harness-speech--cancel-watch)
  (setq harness-speech--started-at (float-time)
        harness-speech--watch-deadline
        (+ (float-time) harness-speech-local-startup-timeout))
  (setq harness-speech--watch-timer
        (run-at-time 0.5 0.5
                     (lambda ()
                       (when harness-speech--started-at
                         (harness-speech--watch))))))

(defun harness-speech--require-urls ()
  "Signal when the commands are set but their URLs are not."
  (when (harness-speech--urls-required-p)
    (error "Speech URLs unset")))

(defun harness-speech-local-start (&optional callback)
  "Start the local pipeline; CALLBACK gets its status plist.
The answer is `starting' at once, and `speech/changed' says how it
went.  A pipeline that already runs is left as it is."
  (interactive)
  (harness-speech--cancel-watch)
  (let ((status
         (if (eq (harness-speech--backend) 'command)
             (progn
               (harness-speech--require-urls)
               ;; Both commands are checked before either runs: a start
               ;; that cannot finish leaves no program behind.
               (let ((pairs `((stt . ,harness-speech-local-stt-command)
                              (tts . ,harness-speech-local-tts-command))))
                 (dolist (pair pairs)
                   (harness-speech--request-argv (cdr pair)))
                 (dolist (pair pairs)
                   (unless (harness-speech--process (car pair))
                     (harness-speech--run-command (car pair) (cdr pair)))))
               (harness-speech--start-watch)
               (harness-speech--remember 'starting "Starting"))
           (progn
             (harness-speech--start-watch)
             (harness-speech--remember 'starting "Starting")
             (harness-compose-stack-up
              harness-speech-local-stack
              (lambda (state)
                ;; A runtime that cannot start the stack says so at once;
                ;; otherwise what the services do is the watch's.
                (when harness-speech--started-at
                  (if (eq (plist-get state :state) 'error)
                      (progn (harness-speech--cancel-watch)
                             (harness-speech--remember
                              'error (or (plist-get state :detail) "Start failed")))
                    (harness-speech--remember 'starting "Starting")))))
             harness-speech--status))))
    (when callback (funcall callback status))
    status))

(defun harness-speech-local-stop (&optional callback)
  "Stop the local pipeline; CALLBACK gets its status plist."
  (interactive)
  (harness-speech--cancel-watch)
  (setq harness-speech--started-at nil)
  (if (eq (harness-speech--backend) 'command)
      (let ((status (progn (harness-speech--kill-command 'stt)
                           (harness-speech--kill-command 'tts)
                           (harness-speech--remember 'stopped "Stopped"))))
        (when callback (funcall callback status))
        status)
    (let ((status (harness-speech--remember 'stopped "Stopped")))
      (harness-compose-stack-down
       harness-speech-local-stack
       (lambda (_state)
         ;; Whatever the runtime says, a stop the user asked for reads
         ;; as stopped rather than as a failure.
         (harness-speech--remember 'stopped "Stopped")))
      (when callback (funcall callback status))
      status)))

(defun harness-speech-local-status ()
  "Return the status plist of the local pipeline, asked fresh."
  (let* ((record (if (eq (harness-speech--backend) 'command)
                     (harness-speech--command-state)
                   (harness-speech--stack-state)))
         (status (harness-speech--describe (plist-get record :state)
                                           (plist-get record :detail))))
    (when (eq (plist-get record :state) 'stopped)
      (setq harness-speech--started-at nil))
    status))

(defun harness-speech-running-p ()
  "Non-nil when the local pipeline runs."
  (eq (harness-speech--known-state) 'running))

;;;; Speech

(defun harness-speech--multipart (boundary fields file)
  "Return a multipart/form-data body with BOUNDARY, FIELDS and FILE.
FIELDS is an alist of names to values; FILE is (NAME FILENAME MIME DATA)
with DATA the bytes.  The body is unibyte, as the bytes are."
  (let ((parts nil))
    (dolist (field fields)
      (push (encode-coding-string
             (format "--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                     boundary (car field) (cdr field))
             'utf-8 t)
            parts))
    (push (concat (encode-coding-string
                   (format (concat "--%s\r\nContent-Disposition: form-data;"
                                   " name=\"%s\"; filename=\"%s\"\r\n"
                                   "Content-Type: %s\r\n\r\n")
                           boundary (nth 0 file) (nth 1 file) (nth 2 file))
                   'utf-8 t)
                  (if (multibyte-string-p (nth 3 file))
                      (encode-coding-string (nth 3 file) 'binary t)
                    (nth 3 file))
                  (encode-coding-string "\r\n" 'utf-8 t))
          parts)
    (push (encode-coding-string (format "--%s--\r\n" boundary) 'utf-8 t) parts)
    (apply #'concat (nreverse parts))))

(defun harness-speech--decode-audio (audio)
  "Return the bytes of AUDIO, a base64 WAV, or signal."
  (unless (and (stringp audio) (not (string-empty-p audio)))
    (error "Speech audio unset"))
  (condition-case nil
      (base64-decode-string audio)
    (error (error "Speech audio unreadable"))))

(defun harness-speech--http (url &rest args)
  "Request URL with ARGS and return a promise of (STATUS HEADERS BODY).
A transport or HTTP failure rejects with a `harness-error' whose text
is the one line a client shows."
  (harness-with-promise (resolve reject)
    (apply #'harness-http-request url
           :timeout harness-speech-request-timeout
           :callback (lambda (status headers body err)
                       (cond
                        (err (funcall reject
                                      (list 'error
                                            (format "Local voice pipeline · %s"
                                                    (if (stringp (cadr err))
                                                        (cadr err) err)))))
                        ((not (and status (>= status 200) (< status 300)))
                         (funcall reject
                                  (list 'error
                                        (format "Local voice pipeline · HTTP %s" status))))
                        (t (funcall resolve (list status headers body)))))
           args)))

(defun harness-speech--json-body (body)
  "Return BODY, an HTTP response, parsed as JSON, or nil."
  (when (and (stringp body) (not (string-empty-p body)))
    (condition-case nil
        (if (multibyte-string-p body)
            (json-parse-string body :object-type 'plist :null-object nil
                               :false-object nil)
          (json-parse-string (decode-coding-string body 'utf-8 t)
                             :object-type 'plist :null-object nil :false-object nil))
      (error nil))))

(defun harness-speech-transcribe (audio &optional format language)
  "Transcribe AUDIO, a base64 WAV, with the local pipeline.
FORMAT names the audio's container (a WAV when nil) and LANGUAGE the
words' language, when the service takes one.  Return a promise of
\(:text TEXT)."
  (let ((url (harness-speech--stt-url)))
    (unless url
      (error "Local voice pipeline · stopped"))
    (let* ((data (harness-speech--decode-audio audio))
           (ext (or (and (stringp format) (not (string-empty-p format)) format) "wav"))
           (boundary (format "harness-%s" (harness-short-id 24)))
           (fields (append '(("model" . "whisper-1")
                             ("response_format" . "json"))
                           (when (and (stringp language) (not (string-empty-p language)))
                             (list (cons "language" language)))))
           (body (harness-speech--multipart
                  boundary fields
                  (list "file" (format "utterance.%s" ext) "audio/wav" data))))
      (harness-then
       (harness-speech--http url :method "POST" :body body :binary t
                             :headers (list (cons "Content-Type"
                                                  (format "multipart/form-data; boundary=%s"
                                                          boundary))))
       (lambda (response)
         (let* ((parsed (harness-speech--json-body (nth 2 response)))
                (text (and parsed (plist-get parsed :text))))
           (list :text (if (stringp text) (string-trim text) ""))))
       (lambda (err)
         (signal (car err) (cdr err)))))))

(defun harness-speech-synthesize (text &optional voice)
  "Speak TEXT with the local pipeline, in VOICE or its own.
Return a promise of (:audio BASE64 :mime \"audio/wav\")."
  (let ((url (harness-speech--tts-url)))
    (unless url
      (error "Local voice pipeline · stopped"))
    (unless (and (stringp text) (not (string-empty-p (string-trim text))))
      (error "Speech text unset"))
    (let ((payload (list :model "tts-1"
                         :voice (or (and (stringp voice) (not (string-empty-p voice)) voice)
                                    harness-speech-local-voice)
                         :input (string-trim text)
                         :response_format "wav")))
      (harness-then
       (harness-speech--http url :method "POST"
                             :headers '(("Content-Type" . "application/json"))
                             :json payload :binary t)
       (lambda (response)
         (let ((body (nth 2 response)))
           (unless (and (stringp body) (> (length body) 4)
                        (string-prefix-p "RIFF" body))
             (error "Local voice pipeline · no audio"))
           (list :audio (base64-encode-string body t) :mime "audio/wav")))
       (lambda (err)
         (signal (car err) (cdr err)))))))

;;;; Methods

(harness-defmethod speech/status ()
  "Return the local pipeline's status plist.
It holds `:state' (running, starting, stopped or error), `:detail' (a
one-line explanation), `:backend' (stack or command), `:stt-url' and
`:tts-url' (where the services answer, for a client that may reach
them), `:voice', `:model', `:local' and `:reason' (the one line a
client shows when it cannot be used, or nil)."
  (harness-speech-local-status))

(harness-defmethod speech/start ()
  "Start the local pipeline and return its status; `speech/changed' follows."
  (harness-speech-local-start))

(harness-defmethod speech/stop ()
  "Stop the local pipeline and return its status; `speech/changed' follows."
  (harness-speech-local-stop))

(harness-defmethod speech/transcribe (audio &optional format language)
  "Transcribe AUDIO, a base64 WAV, and return a promise of (:text TEXT).
FORMAT names the container and LANGUAGE the words' language; both are
optional.  The audio goes to the pipeline on the harness's machine, so
a client needs no speech model of its own."
  (harness-speech-transcribe audio format language))

(harness-defmethod speech/synthesize (text &optional voice)
  "Speak TEXT and return a promise of (:audio BASE64 :mime \"audio/wav\").
VOICE names the voice, the pipeline's own when nil."
  (harness-speech-synthesize text voice))

(harness-declare-event 'speech/changed
  "The local speech pipeline's state moved; the argument is its status plist.")

;;;; Module

(defun harness-speech--stop-all ()
  "Stop everything this module runs, without asking any runtime."
  (harness-speech--cancel-watch)
  (setq harness-speech--started-at nil)
  (dolist (role '(stt tts))
    (harness-speech--kill-command role))
  (dolist (buffer (list (get-buffer " *harness speech stt*")
                        (get-buffer " *harness speech tts*")))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(defun harness-speech--stt-model-record ()
  "Return the client's record of the selected speech model, or nil.
The registry lives in `harness-ui-voice-providers', which a client loads;
the harness server may not, so this asks for it by name and falls back to
the server's own whisper setting when it is absent."
  (when (and (fboundp 'harness-voice-stt-model-resolved)
             (boundp 'harness-voice-stt-model))
    (harness-voice-stt-model-resolved)))

(defun harness-speech--stt-profile ()
  "Return the compose profile of the selected speech model, or nil."
  (plist-get (harness-speech--stt-model-record) :profile))

(defun harness-speech--stack-env ()
  "Return the stack environment that loads the selected speech model.
A model registered by the client names its own environment (the whisper
file, or Parakeet's model directory and feature width); without one, the
server's `harness-speech-local-whisper' is what the stack loads."
  (let ((env (plist-get (harness-speech--stt-model-record) :env)))
    (append (copy-sequence env)
            (unless (assoc "WHISPER_MODEL" env)
              (list (cons "WHISPER_MODEL" harness-speech-local-whisper)))
            (list (cons "HARNESS_TTS_VOICE" harness-speech-local-voice)))))

(defun harness-speech--init ()
  "Wire the local pipeline: its stack, its autostart and its exit."
  (harness-define-compose-stack
    harness-speech-local-stack
    :label "Local voice pipeline"
    :doc "whisper.cpp or Parakeet for speech to text and Kokoro for text to speech, on loopback."
    :directory (expand-file-name "scripts/stacks/voice-local" harness-directory)
    :project "voice-local"
    :network "voice"
    :endpoints '((whisper 8080) (parakeet 8081) (tts 8880))
    ;; One speech model runs beside Kokoro: the client's choice names the
    ;; profile, and stopping enables both engines' profiles to remove them.
    :profiles (lambda () (list (or (harness-speech--stt-profile) "whisper")))
    :all-profiles '("whisper" "parakeet")
    :env #'harness-speech--stack-env)
  (add-hook 'kill-emacs-hook #'harness-speech--stop-all)
  (when harness-speech-autostart
    (harness-run-soon #'harness-speech-local-start)))

(harness-define-module 'speech
  :doc "The local speech service the harness runs for its clients: the whisper.cpp and Kokoro pipeline as the harness server's child, its state and endpoints, and transcription and synthesis over ACP so a phone needs no speech model."
  :requires '(stacks)
  :init #'harness-speech--init)

(provide 'harness-speech)
;;; harness-speech.el ends here
