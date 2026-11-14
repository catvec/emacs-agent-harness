;;; harness-voice-lipread-test.el --- Webcam lip reading's own suite  -*- lexical-binding: t; -*-

;;; Commentary:

;; The lip-reading voice provider, from its registry entry to the words
;; it shows: no camera, no model file, no network.  The sidecar's and
;; the library's decisions are Python (`test/harness-voice-lipread-test.py')
;; and this suite runs them inside the repository's own test run, then
;; holds the Elisp half to the protocol and to the exact copy.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-ui-voice)
(require 'harness-ui-voice-lipread)

(defconst harness-voice-lipread-test--suite
  (expand-file-name "test/harness-voice-lipread-test.py" harness-test-root))

(defconst harness-voice-lipread-test--script
  (expand-file-name "scripts/harness-voice-live-lipread" harness-test-root))

(defconst harness-voice-lipread-test--setup
  (expand-file-name "scripts/harness-voice-lipread-setup" harness-test-root))

(defmacro harness-voice-lipread-test--with-model (&rest body)
  "Run BODY with a model directory whose files all exist."
  (declare (indent 0))
  `(let ((dir (make-temp-file "harness-lipread-" t)))
     (unwind-protect
         (progn
           (dolist (name harness-voice-lipread--model-files)
             (write-region "" nil (expand-file-name name dir)))
           (let ((harness-voice-lipread-model-dir dir))
             ,@body))
       (delete-directory dir t))))

(ert-deftest harness-voice-lipread-python-suite ()
  "Run the lip-reading decisions and lifecycle tests."
  (skip-unless (executable-find "python3"))
  (let ((buffer (generate-new-buffer " *lipread tests*"))
        (default-directory (file-name-as-directory harness-test-root)))
    (unwind-protect
        (let ((status (call-process (executable-find "python3") nil buffer nil
                                    harness-voice-lipread-test--suite)))
          (with-current-buffer buffer
            (unless (eq status 0)
              (ert-fail (format "lip-reading tests exited %s:\n%s"
                                status (buffer-string))))))
      (kill-buffer buffer))))

(ert-deftest harness-voice-lipread-sidecar-self-test ()
  "The sidecar checks its own lifecycle without a camera or a model."
  (skip-unless (executable-find "python3"))
  (let ((dir (make-temp-file "harness-lipread-" t)))
    (unwind-protect
        (with-temp-buffer
          (let ((status (call-process "python3" nil t nil harness-voice-lipread-test--script
                                      "--self-test" "--model-dir" dir)))
            (should (eql 0 status))
            (should (string-match-p "self-test ok" (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest harness-voice-lipread-provider-registration ()
  "The provider is live, camera-based, and its command is an argv list."
  (should (eq 'live (harness-voice-provider-capability 'lipread)))
  (should (harness-voice-provider-camera-p 'lipread))
  (should (equal "Webcam lip reading" (harness-voice-provider-label 'lipread)))
  (dolist (id '(chatgpt unmute fixture custom wav))
    (should-not (harness-voice-provider-camera-p id)))
  (should (string-match-p "Local webcam lip reading"
                          (plist-get (harness-voice-provider-get 'lipread) :doc))))

(ert-deftest harness-voice-lipread-command-is-argv ()
  "The command names the device, the model and the grant, and no shell."
  (harness-voice-lipread-test--with-model
    (let* ((harness-voice-lipread--granted nil)
           (harness-voice-lipread-device "2")
           (harness-voice-lipread-python "/opt/lipread/bin/python")
           (harness-voice-lipread-min-confidence 0.82)
           (command (harness-voice-lipread-command)))
      (should (cl-every #'stringp command))
      ;; The interpreter is a setting: the runtime lives wherever the
      ;; person installed it, not necessarily in the system Python.
      (should (equal "/opt/lipread/bin/python" (car command)))
      (should (string-suffix-p "harness-voice-live-lipread" (cadr command)))
      (should (equal "2" (cadr (member "--device" command))))
      (should (equal "0.82" (cadr (member "--min-confidence" command))))
      (should (equal (expand-file-name harness-voice-lipread-model-dir)
                     (cadr (member "--model-dir" command))))
      ;; No grant, no consent flag: a sidecar started any other way opens
      ;; no device.
      (should-not (member "--camera-consent" command))
      (let ((harness-voice-lipread--granted t))
        (should (member "--camera-consent" (harness-voice-lipread-command))))
      ;; A local speech server is used when there is one, and never a
      ;; hosted one.
      (cl-letf (((symbol-function 'harness-voice-unmute--tts-url)
                 (lambda () "http://127.0.0.1:8880/v1/audio/speech")))
        (should (equal "http://127.0.0.1:8880/v1/audio/speech"
                       (cadr (member "--tts-url" (harness-voice-lipread-command))))))
      (cl-letf (((symbol-function 'harness-voice-unmute--tts-url)
                 (lambda () (user-error "Local voice pipeline · stopped"))))
        (should-not (member "--tts-url" (harness-voice-lipread-command))))
      ;; A recording is named as the source, and needs no consent: the
      ;; person chose the file, not the camera.
      (let ((harness-voice-lipread-source "/tmp/a-face-recording.mp4"))
        (should (equal "/tmp/a-face-recording.mp4"
                       (cadr (member "--source" (harness-voice-lipread-command)))))
        (should-not (member "--camera-consent" (harness-voice-lipread-command)))))))

(ert-deftest harness-voice-lipread-needs-the-model-files ()
  "A missing file is the provider's one-line reason, named by file."
  (let ((dir (make-temp-file "harness-lipread-" t)))
    (unwind-protect
        (let ((harness-voice-lipread-model-dir dir))
          (let ((harness-voice-provider 'lipread))
            (should (equal "Model unavailable · lipread_ctc.int8.onnx"
                           (harness-voice-provider-unavailable-reason))))
          (write-region "" nil (expand-file-name "lipread_ctc.int8.onnx" dir))
          (should (equal "Model unavailable · tokens.json"
                         (harness-voice-lipread-need))))
      (delete-directory dir t)))
  (harness-voice-lipread-test--with-model
    (should-not (harness-voice-lipread-need))
    (let ((harness-voice-provider 'lipread))
      (should-not (harness-voice-provider-unavailable-reason)))))

(ert-deftest harness-voice-lipread-refuses-a-start-without-the-model ()
  "Starting without the model is a user error, not an open camera."
  (let ((dir (make-temp-file "harness-lipread-" t))
        (harness-voice-lipread--granted t))
    (unwind-protect
        (let ((harness-voice-lipread-model-dir dir))
          (should (equal "Lip-reading model unavailable · lipread_ctc.int8.onnx"
                         (error-message-string
                          (should-error (harness-voice-lipread--prepare)
                                        :type 'user-error)))))
      (delete-directory dir t))))

(ert-deftest harness-voice-lipread-a-recording-needs-no-camera-grant ()
  "A file source starts without a grant, and a missing file is named."
  (harness-voice-lipread-test--with-model
    (let ((harness-voice-lipread--granted nil)
          (harness-voice-lipread-source (make-temp-file "harness-lipread-source" nil ".mp4")))
      (unwind-protect
          (progn
            (should (harness-voice-lipread--prepare))
            (should-not harness-voice-lipread--granted))
        (delete-file harness-voice-lipread-source)))
    (let ((harness-voice-lipread--granted nil)
          (harness-voice-lipread-source "/nonexistent/harness-recording.mp4"))
      (should (equal "Lip-reading source unavailable · harness-recording.mp4"
                     (error-message-string
                      (should-error (harness-voice-lipread--prepare)
                                    :type 'user-error)))))))

(ert-deftest harness-voice-lipread-refuses-a-start-without-a-grant ()
  "A declined camera is a user error with no sidecar and no device."
  (harness-voice-lipread-test--with-model
    (let ((harness-voice-lipread--granted nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (should (equal "Camera permission · declined"
                       (error-message-string
                        (should-error (harness-voice-lipread--prepare)
                                      :type 'user-error)))))
      (should-not harness-voice-lipread--granted)
      (should-not (member "--camera-consent" (harness-voice-lipread-command))))))

(ert-deftest harness-voice-lipread-grant-is-per-session ()
  "A grant is asked for, held for this session, and dropped when it ends."
  (harness-voice-lipread-test--with-model
    (let ((harness-voice-lipread--granted nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'harness-voice-setup--refresh) #'ignore))
        (should (harness-voice-lipread--prepare))
        (should harness-voice-lipread--granted)
        (should (member "--camera-consent" (harness-voice-lipread-command))))
      (cl-letf (((symbol-function 'harness-voice-setup--refresh) #'ignore))
        (harness-voice-lipread--stopped))
      (should-not harness-voice-lipread--granted)
      (should-not harness-voice-live--camera))))

(ert-deftest harness-voice-lipread-revoke-drops-the-grant ()
  "Revoking ends the grant and the camera state with it."
  (let ((harness-voice-lipread--granted t)
        (harness-voice-live--camera '(:event "camera" :state "live")))
    (cl-letf (((symbol-function 'harness-voice-setup--refresh) #'ignore))
      (harness-voice-lipread-revoke))
    (should-not harness-voice-lipread--granted)
    (should-not harness-voice-live--camera)))

(ert-deftest harness-voice-lipread-camera-labels ()
  "Every camera state and face count has exact words."
  (let ((harness-voice-lipread--granted nil)
        (harness-voice-live--camera nil))
    (should (equal "off" (harness-voice-lipread-camera-label))))
  (let ((harness-voice-lipread--granted t)
        (harness-voice-live--camera nil))
    (should (equal "granted" (harness-voice-lipread-camera-label))))
  (dolist (case '((1 . "live · 1 face")
                  (0 . "live · no face")
                  (2 . "live · 2 faces")
                  (nil . "live · no frame")))
    (let ((harness-voice-lipread--granted t)
          (harness-voice-live--camera (list :event "camera" :state "live"
                                            :faces (car case))))
      (should (equal (cdr case) (harness-voice-lipread-camera-label))))))

(ert-deftest harness-voice-lipread-control-labels ()
  "The controls' camera words are nouns, for every state."
  (dolist (case '((("live" . 1) . "Camera · live · 1 face")
                  (("live" . 0) . "Camera · live · no face")
                  (("live" . 3) . "Camera · live · 3 faces")
                  (("opening" . nil) . "Camera · opening")
                  (("paused" . nil) . "Camera · paused")
                  (("denied" . nil) . "Camera · denied")
                  (("failed" . nil) . "Camera · failed")))
    (let ((harness-voice-live--camera (list :state (car (car case))
                                            :faces (cdr (car case)))))
      (should (equal (cdr case)
                     (substring-no-properties (harness-voice-live--camera-label)))))))

(ert-deftest harness-voice-lipread-setup-line-copy ()
  "The setup list's camera line is exact, with and without a grant."
  (harness-voice-lipread-test--with-model
    (let ((harness-voice-providers (make-hash-table :test 'eq))
          (harness-voice-provider 'lipread)
          (harness-voice-lipread--granted nil)
          (harness-voice-live--camera nil)
          (harness-ui-media-audio-backend nil))
      (harness-define-voice-provider 'lipread
        :label "Webcam lip reading" :capability 'live :camera t
        :command #'harness-voice-lipread-command)
      (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
                 (lambda (&optional _) '(pipewire "PipeWire" "pw-record" "pw-play"))))
        (with-temp-buffer
          (harness-voice-setup--insert)
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p
                     "^Camera  0 · off  \\[Grant\\]  Model · ready$" text)))))
      (setq harness-voice-lipread--granted t)
      (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
                 (lambda (&optional _) '(pipewire "PipeWire" "pw-record" "pw-play"))))
        (with-temp-buffer
          (harness-voice-setup--insert)
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p
                     "^Camera  0 · granted  \\[Revoke\\]$" text))))))))

(ert-deftest harness-voice-lipread-setup-names-a-missing-model ()
  "A model that is not installed is on the camera line, by file."
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'lipread)
        (harness-voice-lipread--granted nil)
        (harness-voice-live--camera nil)
        (harness-voice-lipread-model-dir
         (expand-file-name "no-such-lipread-models" harness-test-root)))
    (harness-define-voice-provider 'lipread
      :label "Webcam lip reading" :capability 'live :camera t
      :command #'harness-voice-lipread-command)
    (cl-letf (((symbol-function 'harness-ui-media-audio-backend)
               (lambda (&optional _) '(pipewire "PipeWire" "pw-record" "pw-play"))))
      (with-temp-buffer
        (harness-voice-setup--insert)
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p
                   "^Camera  0 · off  \\[Grant\\]  Model · missing lipread_ctc.int8.onnx$"
                   text)))))))

(ert-deftest harness-voice-lipread-uncertain-caption-is-marked ()
  "An unsure reading is shown as uncertain and never enters the request."
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'lipread)
        (harness-voice-live--session "s-1")
        (harness-voice-live--transcript nil)
        (harness-voice-live--section nil)
        (harness-voice-live--speaker nil)
        (harness-voice-live--heard "")
        (harness-voice-live--conversation (harness-voice-conversation-create))
        (harness-voice-live--process nil)
        (harness-voice-live--delegations nil)
        (harness-voice-live--delegation nil)
        (harness-voice-live--buffer nil)
        (harness-voice-live--pipeline (harness-voice-pipeline-create 'off)))
    (harness-define-voice-provider 'lipread :label "Webcam" :capability 'live :camera t)
    (unwind-protect
        (progn
          (harness-voice-live--handle
           '(:event "user_delta" :text "the second one" :final t :certainty "unsure"))
          (with-current-buffer harness-voice-live--transcript
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "^Uncertain · [0-9:]+$" text))
              (should (string-match-p "  the second one · not sent$" text))))
          ;; Nothing was heard, no request was queued, and the voice
          ;; conversation has no user turn.
          (should (equal "" harness-voice-live--heard))
          (should-not harness-voice-live--delegations)
          (should-not (cl-find 'user (harness-voice-conversation-turns
                                      harness-voice-live--conversation)
                               :key (lambda (turn) (plist-get turn :speaker)))))
      (when (buffer-live-p harness-voice-live--transcript)
        (kill-buffer harness-voice-live--transcript)))))

(ert-deftest harness-voice-lipread-likely-caption-says-so ()
  "A likely reading is captioned with its own word, and is heard."
  (let ((harness-voice-live--transcript nil)
        (harness-voice-live--section nil)
        (harness-voice-live--speaker nil)
        (harness-voice-live--heard "")
        (harness-voice-live--stage nil))
    (unwind-protect
        (progn
          (harness-voice-live--handle
           '(:event "user_delta" :text "add a docstring" :final t :certainty "likely"))
          (with-current-buffer harness-voice-live--transcript
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "^You · likely · [0-9:]+$" text))
              (should (string-match-p "  add a docstring" text))))
          (should (equal "add a docstring" harness-voice-live--heard)))
      (when (buffer-live-p harness-voice-live--transcript)
        (kill-buffer harness-voice-live--transcript)))))

(ert-deftest harness-voice-lipread-camera-event-drives-the-controls ()
  "A camera event sets the controls' state, and `ended' clears it."
  (let ((harness-voice-live--camera nil))
    (harness-voice-live--handle
     '(:event "camera" :state "live" :device "0" :faces 1 :fps 24.6))
    (should (equal "live" (plist-get harness-voice-live--camera :state)))
    (should (equal "Camera · live · 1 face"
                   (substring-no-properties (harness-voice-live--camera-label))))
    (harness-voice-live--handle '(:event "camera" :state "ended"))
    (should-not harness-voice-live--camera)))

(ert-deftest harness-voice-lipread-prepare-runs-before-the-process ()
  "A provider's prepare hook refuses a start before a process exists."
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'camera-voice)
        (ran nil))
    (harness-define-voice-provider 'camera-voice
      :label "Camera voice" :capability 'live :camera t
      :command '("true")
      :prepare (lambda () (setq ran t))
      :stopped (lambda () (setq ran 'stopped)))
    (harness-voice-live--prepare)
    (should (eq t ran))
    (harness-voice-live--stopped)
    (should (eq 'stopped ran)))
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'refusing-voice))
    (harness-define-voice-provider 'refusing-voice
      :label "Refusing voice" :capability 'live :command '("true")
      :prepare (lambda () (user-error "Camera permission · declined")))
    (should (equal "Camera permission · declined"
                   (error-message-string
                    (should-error (harness-voice-live--prepare) :type 'user-error))))))

(ert-deftest harness-voice-lipread-setup-script-states-its-licence ()
  "The one script that installs the model states the terms before it does."
  (skip-unless (executable-find "python3"))
  (let ((dir (make-temp-file "harness-lipread-" t)))
    (unwind-protect
        (with-temp-buffer
          (call-process "python3" nil t nil harness-voice-lipread-test--setup
                        "--check" "--model-dir" dir)
          (let ((text (buffer-string)))
            (should (string-match-p "research and non-commercial" text))
            (should (string-match-p "Apache-2.0" text))
            (should (string-match-p "Missing\\|missing" text))
            (should (string-match-p "lipread_ctc.int8.onnx" text))))
      (delete-directory dir t))))

(ert-deftest harness-voice-lipread-scripts-are-executable ()
  "The sidecar and the setup script run as programs."
  (should (file-executable-p harness-voice-lipread-test--script))
  (should (file-executable-p harness-voice-lipread-test--setup))
  (should (file-executable-p (expand-file-name
                              "scripts/harness_voice_lipread.py"
                              harness-test-root))))

(provide 'harness-voice-lipread-test)
;;; harness-voice-lipread-test.el ends here
