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
    (should (string-suffix-p "harness-voice-live-unmute" (cadr command))))
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
        (harness-voice-provider 'second))
    (harness-define-voice-provider 'first
      :label "First voice" :capability 'wav)
    (harness-define-voice-provider 'second
      :label "Second voice" :capability 'live
      :needs '((env "HARNESS_TEST_VOICE_UNSET")))
    (harness-define-voice-provider 'third
      :label "Third voice" :capability 'live)
    (setenv "HARNESS_TEST_VOICE_UNSET" nil)
    (with-temp-buffer
      (harness-voice-setup--insert)
      (should (equal (concat "Voice providers\n"
                             "\n"
                             "  ○ First voice  WAV  ready\n"
                             "  ● Second voice  live  selected"
                             " · Environment variable · HARNESS_TEST_VOICE_UNSET\n"
                             "  ○ Third voice  live  ready\n"
                             "\n"
                             "Effort  [Low] [Medium] [High]\n"
                             "\n"
                             "[Voice settings]\n")
                     (buffer-substring-no-properties (point-min) (point-max)))))))

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

(ert-deftest harness-ui-voice-providers-setup-stack-line ()
  "An open setup list shows the provider's stack without redrawing forever.
The stack state is asked for while the list is drawn, and its answer
used to be reported back straight into another redraw."
  (skip-unless (featurep 'harness-stacks))
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (harness-voice-provider 'local)
        (harness-stacks--stacks (make-hash-table :test 'eq))
        (harness-stacks--states (make-hash-table :test 'eq))
        (harness-container-runtimes (make-hash-table :test 'eq)))
    (harness-define-voice-provider 'local :label "Local voice" :capability 'live
                                   :command '("true") :stack 'test-local)
    (harness-define-compose-stack 'test-local
      :label "Test voice"
      :directory temporary-file-directory
      :project "test-local"
      :network "voice")
    (let ((buffer (get-buffer-create "*harness voice setup*")))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (harness-voice-setup-mode)
              (harness-voice-setup--insert))
            (display-buffer buffer)
            (harness-voice-select-provider 'local)
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p
                         "Local voice stack  ✕ failed  \\[Start\\]" text)))))
        (kill-buffer buffer)))))

(ert-deftest harness-ui-voice-providers-effort-fragments ()
  "An effort picks the provider's fragment and the local whisper model."
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
  (let ((harness-voice-effort 'low))
    (should (equal "ggml-tiny.en.bin" (harness-voice-whisper-model))))
  (let ((harness-voice-effort 'medium))
    (should (equal "ggml-base.en.bin" (harness-voice-whisper-model))))
  (let ((harness-voice-effort 'high))
    (should (equal "ggml-small.en.bin" (harness-voice-whisper-model)))))

(ert-deftest harness-ui-voice-providers-local-stack ()
  "The local provider points at the bundled compose stack and its effort."
  (skip-unless (featurep 'harness-stacks))
  (should (eq 'voice-local (plist-get (harness-voice-provider-get 'unmute) :stack)))
  (let ((stack (harness-compose-stack-get 'voice-local)))
    (should stack)
    (should (equal "voice-local" (plist-get stack :project)))
    (should (equal '(8080) (cdr (assq 'whisper (plist-get stack :endpoints)))))
    (should (equal '(8000) (cdr (assq 'unmute (plist-get stack :endpoints)))))
    (should (equal '("unmute") (plist-get stack :profiles)))
    (dolist (case '((low . "ggml-tiny.en.bin") (medium . "ggml-base.en.bin")
                    (high . "ggml-small.en.bin")))
      (let ((harness-voice-effort (car case)))
        (should (equal (cdr case)
                       (cdr (assoc "WHISPER_MODEL"
                                   (funcall (plist-get stack :env))))))))))

(ert-deftest harness-ui-voice-providers-local-stack-urls ()
  "The local provider reads its endpoints from the running stack."
  (skip-unless (featurep 'harness-stacks))
  (let ((harness-voice-unmute-stt-url nil)
        (harness-voice-unmute-tts-url nil)
        (calls nil))
    (cl-letf (((symbol-function 'harness-compose-stack-endpoint)
               (lambda (id service path)
                 (push (list id service path) calls)
                 (format "http://127.0.0.1:32768/%s" path))))
      (let ((command (harness-voice-unmute-command)))
        (should (equal "http://127.0.0.1:32768/v1/audio/transcriptions"
                       (cadr (member "--stt-url" command))))
        (should (equal "http://127.0.0.1:32768/v1/audio/speech"
                       (cadr (member "--tts-url" command))))
        (should (equal '((voice-local unmute "v1/audio/transcriptions")
                         (voice-local unmute "v1/audio/speech"))
                       (nreverse calls))))
      (should-not (harness-voice-unmute-need)))
    ;; A configured URL works without a stack.
    (let ((harness-voice-unmute-stt-url "http://127.0.0.1:9000/stt")
          (harness-voice-unmute-tts-url "http://127.0.0.1:9000/tts"))
      (cl-letf (((symbol-function 'harness-compose-stack-endpoint)
                 (lambda (&rest _) nil)))
        (should-not (harness-voice-unmute-need))
        (should (equal "http://127.0.0.1:9000/stt"
                       (cadr (member "--stt-url" (harness-voice-unmute-command)))))))
    ;; With neither, the sidecar would get nil arguments: say what is missing.
    (let ((harness-voice-unmute-stt-url nil)
          (harness-voice-unmute-tts-url nil))
      (cl-letf (((symbol-function 'harness-compose-stack-endpoint)
                 (lambda (&rest _) nil)))
        (should (equal "Local voice stack · not running" (harness-voice-unmute-need)))
        (should (equal "Local voice stack unavailable · speech to text"
                       (error-message-string
                        (should-error (harness-voice-unmute-command)
                                      :type 'user-error))))))))

(provide 'harness-ui-voice-providers-test)
;;; harness-ui-voice-providers-test.el ends here
