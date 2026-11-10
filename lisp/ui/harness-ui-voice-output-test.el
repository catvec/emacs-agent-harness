;;; harness-ui-voice-output-test.el --- Output voice page and auditions  -*- lexical-binding: t; -*-

;;; Commentary:

;; The output voice page over recorded service answers: the voices a
;; harness's speech service reports, the parameters it declares, the
;; draft that an audition speaks, and the saved configuration that
;; speaks replies.  No service, player or microphone is started: the
;; ACP call is a function in these tests, and the player is a program
;; that ends at once, so the states are the page's own.  The audio the
;; page plays is scripted here, which is what the WAV bytes say; that a
;; real service answers with a real WAV is `harness-speech-test.el's
;; and the live check's business.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-ui-voice-output)
(require 'harness-ui-voice-providers)

(defconst harness-voice-output-test--catalogue
  (list :state "running"
        :service "Kokoro"
        :voices-url "http://127.0.0.1:8880/v1/audio/voices"
        :voices-count 3
        :voices (vector
                 (list :id "af_heart"
                       :label "American English · female · af_heart"
                       :language "American English" :gender "female")
                 (list :id "bm_george"
                       :label "British English · male · bm_george"
                       :language "British English" :gender "male")
                 (list :id "custom_voice"
                       :label "custom_voice" :language nil :gender nil))
        :parameters (vector
                     (list :key "speed" :label "Speed" :unit "×"
                           :min 0.25 :max 4.0 :default 1.0
                           :doc "How fast the voice speaks, as a multiple of its own pace.")
                     (list :key "volume_multiplier" :label "Volume" :unit "×"
                           :min 0.0 :max 10.0 :default 1.0
                           :doc "How loud the reply is, as a multiple of the service's own level."))
        :supported t)
  "A recorded `speech/voices' answer in Kokoro's shape.
The state is the string ACP carries; the page reads it as a symbol.")

(defvar harness-voice-output-test--respond nil
  "How `harness-ui-call' answers in one page's test, or nil for the fixture.")

(defvar harness-voice-output-test--calls nil
  "The calls a page's test made, newest first, as (METHOD . PARAMS).")

(defvar harness-voice-output-test--saved nil
  "The choices a page's test saved, newest first, as (OPTION . VALUE).
`harness-voice--save-choice' is replaced here: the test reads the option
and the value it would have written, and the custom file is not touched.")

(defmacro harness-voice-output-test-with (&rest body)
  "Run BODY on an output voice page with the local service selected.
The page keeps a recorded catalogue, and `harness-ui-call' answers
through `harness-voice-output-test--respond', which a test sets to
decide when and whether an answer comes.  The player is `true', so a
preview plays nothing and ends at once."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let ((harness-voice-provider 'unmute)
           (harness-voice-unmute-voice "af_heart")
           (harness-voice-unmute-parameters nil)
           (harness-voice-chatgpt-voice nil)
           (harness-voice-pipeline-status '(:state "running" :detail "2 of 2 services"))
           (harness-voice-output-audition-timeout 5)
           (harness-ui-event-functions nil)
           (harness-ui-redraw-hook nil)
           (harness-voice-output--audition-generation 0)
           (harness-voice-output-test--respond nil)
           (harness-voice-output-test--calls nil)
           (harness-voice-output-test--saved nil)
           ;; "Saved" means this client's custom file holds it; one test's
           ;; save is not another's, so the intent starts empty here.
           (harness-voice-unmute-voice-saved (put 'harness-voice-unmute-voice
                                                  'saved-value nil))
           (harness-voice-unmute-parameters-saved
            (put 'harness-voice-unmute-parameters 'saved-value nil))
           (harness-voice-chatgpt-voice-saved (put 'harness-voice-chatgpt-voice
                                                   'saved-value nil)))
       (cl-letf (((symbol-function 'harness-ui-call)
                  (lambda (method params callback &optional error)
                    (push (cons method params) harness-voice-output-test--calls)
                    (if harness-voice-output-test--respond
                        (funcall harness-voice-output-test--respond
                                 method params callback error)
                      (funcall callback (copy-tree harness-voice-output-test--catalogue)))))
                 ((symbol-function 'harness-voice-output--audition-player)
                  (lambda () '("true" "audition.wav")))
                 ((symbol-function 'harness-voice--save-choice)
                  (lambda (symbol value)
                    (push (cons symbol value) harness-voice-output-test--saved)
                    (set symbol value)
                    (put symbol 'saved-value (list value))
                    value)))
         (with-temp-buffer
           (harness-voice-output-mode)
           (setq harness-voice-output--catalogue
                 (copy-tree harness-voice-output-test--catalogue))
           (harness-voice-output--render)
           ,@body)))))

(defun harness-voice-output-test--text ()
  "Return the page's text without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun harness-voice-output-test--respond-with (respond)
  "Make `harness-ui-call' in these tests answer through RESPOND.
RESPOND is called with (METHOD PARAMS CALLBACK ERROR); it decides when
and whether to answer, which is how a late answer is made to come."
  (setq harness-voice-output-test--respond respond))

(defun harness-voice-output-test--saved-value (option)
  "Return the value the page last saved in OPTION, or nil."
  (cdr (assq option harness-voice-output-test--saved)))

(defun harness-voice-output-test--voice-rows ()
  "Return the page's voice rows, one string each."
  (cl-remove-if-not (lambda (line) (string-match-p "\\`  [●○] " line))
                    (split-string (harness-voice-output-test--text) "\n")))

;;;; What the page shows

(ert-deftest harness-voice-output-capability-follows-the-provider ()
  "Each provider says honestly what can be chosen and auditioned."
  (let ((harness-voice-providers (make-hash-table :test 'eq)))
    (harness-define-voice-provider 'unmute :label "Local pipeline" :capability 'live)
    (harness-define-voice-provider 'chatgpt :label "ChatGPT Live" :capability 'live)
    (harness-define-voice-provider 'fixture :label "Scripted fixture" :capability 'live)
    (harness-define-voice-provider 'custom :label "Custom sidecar" :capability 'live)
    (harness-define-voice-provider 'wav :label "WAV dictation" :capability 'wav)
    (let ((harness-voice-provider 'unmute))
      (should (eq 'service (plist-get (harness-voice-output-capability) :kind)))
      (should (plist-get (harness-voice-output-capability) :audition))
      (should (eq 'harness-voice-unmute-voice
                  (plist-get (harness-voice-output-capability) :voice-option))))
    (let ((harness-voice-provider 'chatgpt))
      ;; A server-defined voice: the client has no catalogue to audition,
      ;; and says so rather than inventing a list for an endpoint.
      (should (eq 'provider (plist-get (harness-voice-output-capability) :kind)))
      (should-not (plist-get (harness-voice-output-capability) :audition))
      (should (eq 'harness-voice-chatgpt-voice
                  (plist-get (harness-voice-output-capability) :voice-option))))
    (dolist (case '((fixture . "Scripted fixture · no catalogue")
                    (custom . "Sidecar voice · no catalogue")
                    (wav . "Device voice · no catalogue")))
      (let ((harness-voice-provider (car case)))
        (should (eq 'none (plist-get (harness-voice-output-capability) :kind)))
        (should-not (plist-get (harness-voice-output-capability) :audition))
        (should (equal (cdr case)
                       (plist-get (harness-voice-output-capability) :reason)))))
    (let ((harness-voice-provider 'no-such-provider))
      (should (eq 'none (plist-get (harness-voice-output-capability) :kind)))
      (should (equal "Unknown voice provider"
                     (plist-get (harness-voice-output-capability) :reason))))))

(ert-deftest harness-voice-output-page-renders-exactly ()
  "The whole page, as rendered, is exactly this text.
Every heading, row, state and button of a service with a catalogue is
checked here as one string, so a change to any of them is a change to
the copy a person reads."
  (harness-voice-output-test-with
    (should (equal (concat
                    "  Output voice\n"
                    "\n"
                    "  Provider  Local pipeline\n"
                    "\n"
                    "  Voices\n"
                    "  ● American English · female · af_heart  selected\n"
                    "  ○ British English · male · bm_george\n"
                    "  ○ custom_voice\n"
                    "\n"
                    "  Parameters\n"
                    "  Speed    − 1.00× +  0.25–4.00 · default 1.00\n"
                    "  Volume   − 1.00× +  0.00–10.00 · default 1.00\n"
                    "\n"
                    "  Effective American English · female · af_heart · default\n"
                    "\n"
                    "  Idle\n"
                    "\n"
                    "  [Audition]  [Save]  [Revert]  [Refresh]\n")
                   (harness-voice-output-test--text)))
    ;; A fresh page has nothing unsaved, no failure and no notice.
    (should-not (string-match-p "Unsaved changes" (harness-voice-output-test--text)))
    (should-not (string-match-p "Failed" (harness-voice-output-test--text)))))

(ert-deftest harness-voice-output-page-says-why-there-is-no-list ()
  "A stopped service, a missing route and a failed request read honestly.
Each says why in one noun-phrase row and offers nothing invented to
choose."
  (harness-voice-output-test-with
    (dolist (case '(("stopped" "Local voice pipeline · stopped")
                    ("unsupported" "Voice list unsupported")
                    ("failed" "Voice list unavailable · HTTP 404")))
      (setq harness-voice-output--catalogue
            (list :state (car case) :voices (vector) :parameters (vector)
                  :reason (cadr case)))
      (harness-voice-output--render)
      (let ((text (harness-voice-output-test--text)))
        (should (string-match-p
                 (concat "  Voices\n  " (regexp-quote (cadr case)) "\n")
                 text))
        ;; The saved voice still speaks next; what is missing is the list.
        (should-not (harness-voice-output-test--voice-rows))
        ;; Nothing invented to choose, and no parameter control either.
        (should (string-match-p "  Parameters\n  No parameters declared\n" text))
        (should-not (string-match-p "Speed" text))))))

(ert-deftest harness-voice-output-no-parameters-are-not-offered ()
  "A service that declares nothing offers no parameter row.
That is a service of your own: nothing here can vouch for what it takes,
so no control pretends it can be set, and speech sends none."
  (harness-voice-output-test-with
    (setq harness-voice-output--catalogue
          (list :state "running" :voices (vector) :parameters (vector)
                :voices-count 0))
    (harness-voice-output--render)
    (let ((text (harness-voice-output-test--text)))
      (should (string-match-p "  Voices\n  No voices\n" text))
      (should (string-match-p "  Parameters\n  No parameters declared\n" text))
      (should-not (string-match-p "Speed" text))
      (should-not (string-match-p "Volume" text)))))

(ert-deftest harness-voice-output-page-loading ()
  "Before an answer the page says it is loading, and offers no list."
  (harness-voice-output-test-with
    (setq harness-voice-output--catalogue nil)
    (harness-voice-output--render)
    (let ((text (harness-voice-output-test--text)))
      (should (string-match-p "  Voices\n  Loading voices\n" text))
      (should (string-match-p "  Parameters\n  Loading parameters\n" text))
      (should-not (harness-voice-output-test--voice-rows)))))

(ert-deftest harness-voice-output-provider-without-a-catalogue ()
  "A provider whose voice the client cannot list says so, and offers no audition.
ChatGPT Live keeps a provider-managed voice; the scripted fixture and the
device voice have no voice to choose at all."
  (harness-voice-output-test-with
    (let ((harness-voice-provider 'chatgpt)
          (harness-voice-chatgpt-voice "marin"))
      (harness-voice-output--render)
      (let ((text (harness-voice-output-test--text)))
        (should (string-match-p "  Provider  ChatGPT Live\n" text))
        (should (string-match-p "  Voice     marin\n" text))
        (should (string-match-p
                 "  Provider-managed voice · audition unavailable\n" text))
        (should-not (string-match-p "\\[Audition\\]" text))))
    (let ((harness-voice-provider 'fixture))
      (harness-voice-output--render)
      (let ((text (harness-voice-output-test--text)))
        (should (string-match-p "  Scripted fixture · no catalogue\n" text))
        (should-not (string-match-p "\\[Audition\\]" text))
        (should-not (string-match-p "\\[Save\\]" text))))
    (let ((harness-voice-provider 'wav))
      (harness-voice-output--render)
      (let ((text (harness-voice-output-test--text)))
        (should (string-match-p "  Device voice · no catalogue\n" text))
        (should-not (string-match-p "\\[Audition\\]" text))))))

;;;; Selecting, drafting, unsaved state

(ert-deftest harness-voice-output-select-is-a-draft-until-saved ()
  "Choosing a voice drafts it; the saved voice and its row do not change.
The page says `Unsaved changes' while they differ, and Revert drops it."
  (harness-voice-output-test-with
    (harness-voice-output-select-voice "bm_george")
    (let ((text (harness-voice-output-test--text)))
      (should (string-match-p "  ● British English · male · bm_george  selected\n"
                              text))
      (should (string-match-p "  ○ American English · female · af_heart\n" text))
      ;; Effective, which is what speaks, still names the saved voice.
      (should (string-match-p "  Effective American English · female · af_heart · default\n"
                              text))
      (should (string-match-p "\\[Audition\\]  \\[Save\\]  \\[Revert\\]  \\[Refresh\\]  Unsaved changes"
                              text)))
    ;; Nothing was saved by choosing.
    (should (equal "af_heart" harness-voice-unmute-voice))
    (should-not harness-voice-output-test--saved)
    (harness-voice-output-revert)
    (let ((text (harness-voice-output-test--text)))
      (should-not (string-match-p "Unsaved changes" text))
      (should (string-match-p "  ● American English · female · af_heart  selected\n"
                              text)))))

(ert-deftest harness-voice-output-save-keeps-the-voice-and-parameters ()
  "Save writes the drafted voice and parameter, then they are effective.
A value left at its default is not saved, so a request carries only what
was changed."
  (harness-voice-output-test-with
    (harness-voice-output-select-voice "bm_george")
    (harness-voice-output-adjust "speed" 0.5)
    (harness-voice-output-save-and-close)
    (should (equal "bm_george" harness-voice-unmute-voice))
    (should (equal '(("speed" . 1.5)) harness-voice-unmute-parameters))
    ;; Both reached the client's own option, not a harness setting.
    (should (equal "bm_george"
                   (harness-voice-output-test--saved-value
                    'harness-voice-unmute-voice)))
    (should (equal '(("speed" . 1.5))
                   (harness-voice-output-test--saved-value
                    'harness-voice-unmute-parameters)))
    (let ((text (harness-voice-output-test--text)))
      (should (string-match-p
               "  Effective British English · male · bm_george · Speed 1.50× · saved\n"
               text))
      (should-not (string-match-p "Unsaved changes" text)))))

(ert-deftest harness-voice-output-adjust-stays-in-the-declared-range ()
  "A parameter stops at the service's own bounds, never past them."
  (harness-voice-output-test-with
    (harness-voice-output-adjust "speed" 10)
    (should (= 4.0 (harness-voice-output-parameter-effective "speed")))
    (harness-voice-output-adjust "speed" -100)
    (should (= 0.25 (harness-voice-output-parameter-effective "speed")))
    ;; A key the service does not declare is refused, not invented.
    (should-error (harness-voice-output-adjust "pitch" 0.1) :type 'user-error)
    (should (equal "Parameter unsupported · pitch"
                   (error-message-string
                    (should-error (harness-voice-output-adjust "pitch" 0.1)
                                  :type 'user-error))))))

(ert-deftest harness-voice-output-validation-refuses-what-is-unsupported ()
  "The page's own words name the value and the range it must be in."
  (harness-voice-output-test-with
    (should-not (harness-voice-output-validate "af_heart" '(("speed" . 1.5))))
    (should (equal "Speed · 5.00 outside 0.25–4.00"
                   (harness-voice-output-validate "af_heart" '(("speed" . 5.0)))))
    (should (equal "Speed · not a number"
                   (harness-voice-output-validate "af_heart" '(("speed" . "fast")))))
    (should (equal "Parameter unsupported · pitch"
                   (harness-voice-output-validate "af_heart" '(("pitch" . 1.0)))))
    ;; A voice the service did not report is a warning, not a refusal.
    (should-not (harness-voice-output-validate "alloy" nil))
    ;; A voice spread over two lines is refused: it would be one line.
    (should (equal "Voice · one line"
                   (harness-voice-output-validate "a\nb" nil)))
    ;; The provider that has no voice refuses a save of anything.
    (let ((harness-voice-provider 'fixture))
      (should (equal "Output voice unsupported"
                     (harness-voice-output-validate "x" nil))))))

(ert-deftest harness-voice-output-save-refuses-an-invalid-draft ()
  "A refused save changes nothing and says why, in the page's own row."
  (harness-voice-output-test-with
    (harness-voice-output-set-parameter "speed" 9.0)
    (should-error (harness-voice-output-save-and-close) :type 'user-error)
    (should (equal "af_heart" harness-voice-unmute-voice))
    (should-not harness-voice-unmute-parameters)
    (should-not harness-voice-output-test--saved)
    (let ((text (harness-voice-output-test--text)))
      (should (string-match-p "  Speed · 9.00 outside 0.25–4.00\n" text))
      (should (string-match-p "  Unsaved changes" text)))))

(ert-deftest harness-voice-output-saved-parameters-of-another-service ()
  "A parameter from another service is set aside, never sent to this one."
  (harness-voice-output-test-with
    (setq harness-voice-unmute-parameters '(("pitch" . 1.2) ("speed" . 0.8)))
    (should (equal '(("speed" . 0.8)) (harness-voice-output-saved-parameters)))
    (should (equal '("pitch") (harness-voice-output--set-aside-parameters)))
    (harness-voice-output--render)
    (let ((text (harness-voice-output-test--text)))
      (should (string-match-p "  Set aside · pitch\n" text))
      ;; The value that does apply is the one that speaks.
      (should (string-match-p
               "  Effective American English · female · af_heart · Speed 0.80× · default\n"
               text)))))

;;;; The audition

(ert-deftest harness-voice-output-audition-sends-the-unsaved-draft ()
  "An audition asks for the drafted voice and values, and saves nothing."
  (harness-voice-output-test-with
    (harness-voice-output-test--respond-with
     (lambda (_method _params callback _error)
       (funcall callback (list :audio (base64-encode-string "RIFF0000" t)
                               :mime "audio/wav"))))
    (harness-voice-output-select-voice "bm_george")
    (harness-voice-output-adjust "speed" 0.25)
    (let ((audition (harness-voice-output-audition)))
      (should audition)
      (should (equal "_harness/speech/synthesize"
                     (caar harness-voice-output-test--calls)))
      (let ((params (cdar harness-voice-output-test--calls)))
        (should (equal "bm_george" (plist-get params :voice)))
        (should (equal '(("speed" . 1.25))
                       (let (out)
                         (cl-loop for (k v) on (plist-get params :params) by #'cddr
                                  do (push (cons (substring (symbol-name k) 1) v) out))
                         (nreverse out))))
        ;; The whole audition text is one short sentence, and no prompt is sent.
        (should (equal harness-voice-output-audition-text (plist-get params :text)))
        (should (equal '("_harness/speech/synthesize")
                       (mapcar #'car harness-voice-output-test--calls)))))
    ;; Nothing was saved by the preview.
    (should (equal "af_heart" harness-voice-unmute-voice))
    (should-not harness-voice-unmute-parameters)
    (should-not harness-voice-output-test--saved)))

(ert-deftest harness-voice-output-audition-takes-its-audio-with-it ()
  "A preview that has played leaves no WAV behind.
The player reads its file to the end; the page does not keep the audio
of a preview nobody is listening to any more, and [Stop] takes it away
before the player has finished."
  (harness-voice-output-test-with
    (let ((answer nil))
      (harness-voice-output-test--respond-with
       (lambda (_method _params callback _error) (setq answer callback)))
      (let ((preview (harness-voice-output-audition)))
        (should (file-directory-p (harness-voice-output--preview-dir preview)))
        (funcall answer (list :audio (base64-encode-string "RIFFwav" t)
                              :mime "audio/wav"))
        ;; `true' ends at once, and its sentinel is what clears the audio.
        (harness-test-wait (lambda () (null (harness-voice-output--preview-dir
                                             preview)))
                           5 "the preview's audio to go")
        (should-not (harness-voice-output--preview-dir preview))
        (should (memq (harness-voice-output--preview-state preview)
                      '(playing stopped)))))))

(ert-deftest harness-voice-output-audition-states ()
  "An audition is Loading, then Playing; [Stop] is Stopped; Retry follows a failure."
  (harness-voice-output-test-with
    (let ((respond nil))
      (harness-voice-output-test--respond-with
       (lambda (_method _params callback _error)
         (setq respond callback)))
      (let ((preview (harness-voice-output-audition)))
        (should (eq 'loading (harness-voice-output--preview-state preview)))
        (should (string-match-p "  Loading · American English · female · af_heart\n"
                                (harness-voice-output-test--text)))
        (should (string-match-p "\\[Stop\\]" (harness-voice-output-test--text)))
        (should-not (string-match-p "\\[Audition\\]" (harness-voice-output-test--text))))
      ;; The answer starts the player; `true' ends at once.
      (funcall respond (list :audio (base64-encode-string "RIFFwav" t)
                             :mime "audio/wav"))
      (should (memq (harness-voice-output--preview-state
                     harness-voice-output--audition)
                    '(playing stopped)))
      (harness-voice-output-stop)
      (let ((text (harness-voice-output-test--text)))
        (should (string-match-p
                 "  Stopped · American English · female · af_heart\n" text))
        (should (string-match-p "\\[Audition\\]" text))))))

(ert-deftest harness-voice-output-audition-stop-and-failure ()
  "Stop discards the audio; a failure is one row and offers Retry."
  (harness-voice-output-test-with
    (harness-voice-output-test--respond-with
     (lambda (_method _params _callback _error) nil))
    (let* ((preview (harness-voice-output-audition))
           (dir (harness-voice-output--preview-dir preview)))
      (should (file-directory-p dir))
      (harness-voice-output-stop)
      (should (eq 'stopped (harness-voice-output--preview-state preview)))
      (should-not (file-exists-p dir))
      (should (string-match-p
               "  Stopped · American English · female · af_heart\n"
               (harness-voice-output-test--text))))
    (harness-voice-output-test--respond-with
     (lambda (_method _params _callback error)
       (funcall error '(:message "Local voice pipeline · HTTP 500"))))
    (let ((preview (harness-voice-output-audition)))
      (should (eq 'failed (harness-voice-output--preview-state preview))))
    (let ((text (harness-voice-output-test--text)))
      (should (string-match-p "  Failed · American English · female · af_heart\n" text))
      ;; The harness's one-line reason, as the page shows it.
      (should (string-match-p "  Local voice pipeline · HTTP 500\n" text))
      (should (string-match-p "\\[Retry\\]" text)))))

(ert-deftest harness-voice-output-audition-no-audio-is-a-failure ()
  "An answer without audio fails in the page's words, and offers Retry."
  (harness-voice-output-test-with
    (harness-voice-output-test--respond-with
     (lambda (_method _params callback _error)
       (funcall callback (list :mime "audio/wav"))))
    (harness-voice-output-audition)
    (should (equal "Audition · no audio" harness-voice-output--error))
    (let ((text (harness-voice-output-test--text)))
      (should (string-match-p
               "  Failed · American English · female · af_heart\n" text))
      (should (string-match-p "  Audition · no audio\n" text))
      (should (string-match-p "\\[Retry\\]" text)))))

(ert-deftest harness-voice-output-audition-stale-answer-never-plays ()
  "A late answer from an audition that was replaced cannot change the page.
The newer choice is the only one that plays."
  (harness-voice-output-test-with
    (let ((calls nil))
      (harness-voice-output-test--respond-with
       (lambda (_method params callback _error)
         (push (cons (plist-get params :voice) callback) calls)))
      (harness-voice-output-select-voice "af_heart")
      (let ((first (harness-voice-output-audition)))
        (harness-voice-output-select-voice "bm_george")
        ;; Choosing another voice cancelled the first audition.
        (should (eq 'idle (harness-voice-output--preview-state first)))
        (let ((second (harness-voice-output-audition)))
          (should (eq 'loading (harness-voice-output--preview-state second)))
          ;; The first answer arrives after the second was asked for.
          (funcall (cdr (assoc "af_heart" calls))
                   (list :audio (base64-encode-string "RIFFold" t) :mime "audio/wav"))
          (should (eq 'loading (harness-voice-output--preview-state second)))
          (should-not (harness-voice-output--preview-process second))
          ;; The second answer plays its own voice.
          (funcall (cdr (assoc "bm_george" calls))
                   (list :audio (base64-encode-string "RIFFnew" t) :mime "audio/wav"))
          (should (eq 'playing (harness-voice-output--preview-state second)))
          (should (equal "bm_george"
                         (harness-voice-output--preview-voice second)))))
      (harness-voice-output-stop))))

(ert-deftest harness-voice-output-audition-cancelled-by-a-value-change ()
  "Changing a parameter cancels the audition of the value it replaced."
  (harness-voice-output-test-with
    (harness-voice-output-test--respond-with
     (lambda (_method _params _callback _error) nil))
    (let ((preview (harness-voice-output-audition)))
      (should (eq 'loading (harness-voice-output--preview-state preview)))
      (harness-voice-output-adjust "speed" 0.1)
      (should (eq 'idle (harness-voice-output--preview-state preview)))
      (should (eq 'idle (harness-voice-output-state))))
    (should (equal "af_heart" harness-voice-unmute-voice))))

(ert-deftest harness-voice-output-audition-timeout ()
  "An audition with no answer fails at the page's own deadline."
  (harness-voice-output-test-with
    (harness-voice-output-test--respond-with
     (lambda (_method _params _callback _error) nil))
    (let ((preview (harness-voice-output-audition)))
      (harness-voice-output--timeout preview)
      (should (eq 'failed (harness-voice-output--preview-state preview)))
      (should (equal "Audition · timeout" harness-voice-output--error))
      (let ((text (harness-voice-output-test--text)))
        (should (string-match-p
                 "  Failed · American English · female · af_heart\n" text))
        (should (string-match-p "\\[Retry\\]" text))))))

(ert-deftest harness-voice-output-audition-needs-a-service-to-ask ()
  "A pipeline with no address behind it refuses, before a request.
One that runs, one still starting, one nobody has checked yet, and one
reported down whose address is configured are all asked: the request is
what says whether a voice can be spoken, and the service's own answer
is the honest one.  Refusing because the harness's own pipeline is down
would refuse a service of your own that answers perfectly well."
  (harness-voice-output-test-with
    (setq harness-voice-pipeline-status '(:state "stopped" :detail "Stopped"
                                          :tts-url nil))
    (harness-voice-output--render)
    (should-not (string-match-p "\\[Audition\\]"
                                (harness-voice-output-test--text)))
    (should (equal "Audition unavailable · local voice pipeline stopped"
                   (error-message-string
                    (should-error (harness-voice-output-audition) :type 'user-error))))
    (should-not harness-voice-output-test--calls)
    ;; The same pipeline, with an address: asked.
    (dolist (status '((:state "stopped" :tts-url "http://127.0.0.1:8880/v1/audio/speech")
                      (:state "starting" :tts-url nil)
                      (:state "running" :tts-url nil)
                      nil))
      (setq harness-voice-pipeline-status status)
      (should (harness-voice-output--audition-available-p
               (harness-voice-output-capability))))))

(ert-deftest harness-voice-output-audition-refused-by-an-unknown-provider ()
  "A provider with no service behind it offers no audition, and says why."
  (harness-voice-output-test-with
    (let ((harness-voice-provider 'fixture))
      (should (equal "Scripted fixture · no catalogue"
                     (error-message-string
                      (should-error (harness-voice-output-audition)
                                    :type 'user-error)))))
    (let ((harness-voice-provider 'chatgpt))
      (should (equal "Audition unavailable · provider-managed voice"
                     (error-message-string
                      (should-error (harness-voice-output-audition)
                                    :type 'user-error)))))
    (should-not harness-voice-output-test--calls)))

(ert-deftest harness-voice-output-audition-refuses-an-invalid-draft ()
  "A draft outside the service's range is named instead of sent."
  (harness-voice-output-test-with
    (harness-voice-output-set-parameter "speed" 9.0)
    (should (equal "Speed · 9.00 outside 0.25–4.00"
                   (error-message-string
                    (should-error (harness-voice-output-audition)
                                  :type 'user-error))))
    (should-not harness-voice-output-test--calls)))

;;;; The saved configuration and its precedence

(ert-deftest harness-voice-output-saved-voice-and-its-source ()
  "An empty voice is the service's default; a set one is the client's.
A value the policy sets is named as the policy's, before the saved one."
  (let ((harness-voice-providers (make-hash-table :test 'eq)))
    (harness-define-voice-provider 'unmute :label "Local pipeline" :capability 'live)
    (let ((harness-voice-provider 'unmute)
          (harness-voice-unmute-voice ""))
      (should (equal '(:value nil :source default)
                     (harness-voice-output-saved-voice))))
    ;; The value in force is the one the page names, whatever wrote it.
    (let ((harness-voice-provider 'unmute)
          (harness-voice-unmute-voice "bf_emma"))
      (put 'harness-voice-unmute-voice 'saved-value '("bf_emma"))
      (unwind-protect
          (should (equal '(:value "bf_emma" :source saved)
                         (harness-voice-output-saved-voice)))
        (put 'harness-voice-unmute-voice 'saved-value nil)))
    (let ((harness-voice-provider 'wav))
      (should (equal '(:value nil :source default)
                     (harness-voice-output-saved-voice))))))

(ert-deftest harness-voice-output-unlisted-voice-is-noted-not-replaced ()
  "A saved voice the service no longer reports is kept and marked.
It is not silently switched, since a service of your own may know it."
  (harness-voice-output-test-with
    (setq harness-voice-unmute-voice "af_old")
    (harness-voice-output--note-unlisted-voice)
    (harness-voice-output--render)
    (should (equal "Not in list · af_old" harness-voice-output--notice))
    (let ((text (harness-voice-output-test--text)))
      (should (string-match-p "  Not in list · af_old\n" text))
      ;; The voice in force is still the one that was saved.
      (should (string-match-p "  Effective af_old · default\n" text)))
    (should (equal "af_old" harness-voice-unmute-voice))
    (should (equal '(:value "af_old" :source default)
                   (harness-voice-output-saved-voice)))
    ;; A service that lists nothing reports no voice, so nothing is
    ;; called missing; neither is a voice when the service answered.
    (setq harness-voice-output--catalogue
          (list :state "unsupported" :voices (vector) :parameters (vector)
                :reason "Voice list unsupported"))
    (harness-voice-output--note-unlisted-voice)
    (should-not harness-voice-output--notice)))

(ert-deftest harness-voice-output-live-session-restarts-on-save ()
  "Saving a voice ends a running live session, whose sidecar held the old one."
  (let ((harness-voice-providers (make-hash-table :test 'eq))
        (stopped 0))
    (harness-define-voice-provider 'unmute :label "Local pipeline" :capability 'live)
    (let ((harness-voice-provider 'unmute))
      (cl-letf (((symbol-function 'harness-voice-live--active-p) (lambda () t))
                ((symbol-function 'harness-voice-live-stop) (lambda () (cl-incf stopped)))
                ((symbol-function 'harness-voice--save-choice)
                 (lambda (_symbol _value) nil)))
        (harness-voice-output--restart-live-session)
        (should (= 1 stopped))))
    ;; No session running is not a restart, and no error.
    (let ((harness-voice-provider 'unmute))
      (cl-letf (((symbol-function 'harness-voice-live--active-p) (lambda () nil))
                ((symbol-function 'harness-voice-live-stop)
                 (lambda () (ert-fail "stopped an inactive session"))))
        (harness-voice-output--restart-live-session)))))

;;;; Following the service and the connection

(ert-deftest harness-voice-output-catalogue-is-dropped-when-speech-moves ()
  "A moved pipeline drops the list, stops the preview, and asks again."
  (harness-voice-output-test-with
    (let ((asked 0) (harness-ui-event-functions nil))
      (cl-letf (((symbol-function 'harness-voice-output-fetch)
                 (lambda (&optional _) (cl-incf asked))))
        (harness-voice-output--init)
        (should (memq #'harness-voice-output--on-event harness-ui-event-functions))
        (should (memq #'harness-voice-output--on-redraw harness-ui-redraw-hook))
        (let ((buffer (current-buffer)))
          (harness-voice-output--on-event "speech/changed" nil)
          (should (eq buffer (current-buffer)))
          (with-current-buffer buffer
            (should-not harness-voice-output--catalogue)
            (should (= 1 asked))))
        (harness-voice-output--on-event "config/changed" '(harness-model))
        (should (= 1 asked))))))

(ert-deftest harness-voice-output-stale-catalogue-answer-is-ignored ()
  "An answer about the service that ran before a restart is not drawn."
  (harness-voice-output-test-with
    (let ((respond nil)
          (generation harness-voice-output--catalogue-generation))
      (harness-voice-output-test--respond-with
       (lambda (_method _params callback _error)
         (setq respond callback)))
      (setq harness-voice-output--catalogue nil)
      (harness-voice-output-fetch)
      ;; The pipeline moves before the answer comes back.
      (setq harness-voice-output--catalogue-generation (1+ generation))
      (funcall respond (list :state "running" :voices (vector) :parameters (vector)))
      (should-not harness-voice-output--catalogue))))

(ert-deftest harness-voice-output-fetch-refresh-asks-the-service ()
  "Refresh asks for the service's own answer, not the minute-old one."
  (harness-voice-output-test-with
    (harness-voice-output-refresh)
    (should (equal '_harness/speech/voices
                   (intern (caar harness-voice-output-test--calls))))
    (should (equal t (plist-get (cdar harness-voice-output-test--calls) :refresh)))
    (should (eq 'running (harness-voice-output--catalogue-state)))
    ;; And the page draws the service's own order and names.
    (should (equal '("af_heart" "bm_george" "custom_voice")
                   (mapcar (lambda (v) (plist-get v :id))
                           (harness-voice-output--catalogue-voices))))))

(ert-deftest harness-voice-output-failed-catalogue-is-shown-not-hidden ()
  "A request that fails says why in the page, in one row."
  (harness-voice-output-test-with
    (setq harness-voice-output--catalogue nil)
    (harness-voice-output-test--respond-with
     (lambda (_method _params _callback error)
       (funcall error '(:message "HTTP 401"))))
    (harness-voice-output-fetch)
    (let ((text (harness-voice-output-test--text)))
      (should (string-match-p "  Voice list unavailable · HTTP 401\n" text))
      ;; Asking again is what a failure is for, so Refresh stays.
      (should (string-match-p "\\[Refresh\\]" text)))))

(ert-deftest harness-voice-output-provider-change-cancels-and-redraws ()
  "Selecting another provider drops the old draft, preview and catalogue."
  (harness-voice-output-test-with
    (let ((harness-voice-providers (make-hash-table :test 'eq)))
      (harness-define-voice-provider 'unmute :label "Local pipeline" :capability 'live)
      (harness-define-voice-provider 'chatgpt :label "ChatGPT Live" :capability 'live)
      (harness-voice-output-test--respond-with
       (lambda (_method _params _callback _error) nil))
      (harness-voice-output-select-voice "bm_george")
      (let ((preview (harness-voice-output-audition)))
        (let ((harness-voice-provider 'chatgpt))
          (harness-voice-output--provider-changed)
          (should (eq 'idle (harness-voice-output--preview-state preview)))
          (should-not harness-voice-output--draft-voice)
          (should-not harness-voice-output--catalogue)
          (let ((text (harness-voice-output-test--text)))
            (should (string-match-p "  Provider  ChatGPT Live\n" text))
            (should-not (string-match-p "af_heart" text))))))))

;;;; The commands and the keys

(ert-deftest harness-voice-output-keys-and-menu ()
  "Every key the page teaches is bound, and the menu names the commands."
  (dolist (case '((?a . harness-voice-output-audition)
                  (?s . harness-voice-output-stop)
                  (?S . harness-voice-output-save-and-close)
                  (?r . harness-voice-output-revert)
                  (?g . harness-voice-output-refresh)
                  (?q . harness-voice-output-quit)))
    (should (eq (cdr case) (lookup-key harness-voice-output-mode-map
                                       (vector (car case))))))
  (let* ((menu (get 'harness-voice-output-mode 'harness-menu-group))
         (groups (cdr menu)))
    (should menu)
    (should (equal "Output voice" (car menu)))
    (dolist (command '(harness-voice-output-audition harness-voice-output-stop
                       harness-voice-output-save-and-close
                       harness-voice-output-revert harness-voice-output-refresh))
      (should (cl-some (lambda (entry)
                         (and (listp entry) (equal 3 (length entry))
                              (eq command (nth 2 entry))))
                       (cl-loop for column in groups
                                append (cdr (append column nil))))))))

(ert-deftest harness-voice-output-closing-stops-the-preview ()
  "Killing the page stops its player, and leaves no audio behind."
  (harness-voice-output-test-with
    (harness-voice-output-test--respond-with
     (lambda (_method _params _callback _error) nil))
    (let* ((preview (harness-voice-output-audition))
           (dir (harness-voice-output--preview-dir preview)))
      (should (file-directory-p dir))
      ;; No window shows this buffer in the test, so closing is its own
      ;; command: it stops the preview and takes the audio with it.
      (harness-voice-output--dispose)
      (should-not (file-exists-p dir))
      (should (eq 'idle (harness-voice-output--preview-state preview))))
    (should (equal "af_heart" harness-voice-unmute-voice))))

(ert-deftest harness-voice-output-answer-lands-in-its-own-page ()
  "A connection delivers its answer in whatever buffer is current then.
Every value of the page is buffer-local, so an answer must select the
page that asked: one drawn from another buffer's answer would show
`Loading voices' for ever, and a preview would act on the wrong page."
  (harness-voice-output-test-with
    (let ((page (current-buffer))
          (answer nil)
          (synthesize nil))
      (harness-voice-output-test--respond-with
       (lambda (method _params callback _error)
         (if (equal method "_harness/speech/voices")
             (setq answer callback)
           (setq synthesize callback))))
      ;; The page asks from a clean catalogue, as opening it does.
      (setq harness-voice-output--catalogue nil)
      (harness-voice-output-fetch t)
      (should (eq page (current-buffer)))
      ;; The answer arrives with another buffer current, as a socket's does.
      (with-temp-buffer
        (rename-buffer "*a buffer the answer arrives in*")
        (funcall answer (copy-tree harness-voice-output-test--catalogue))
        (should-not harness-voice-output--catalogue))
      (with-current-buffer page
        (should (eq 'running (harness-voice-output--catalogue-state)))
        (should (= 3 (plist-get harness-voice-output--catalogue
                                :voices-count))))
      ;; A preview's answer belongs to its page too.
      (let ((preview (harness-voice-output-audition)))
        (with-temp-buffer
          (rename-buffer "*another buffer the answer arrives in*")
          (funcall synthesize (list :audio (base64-encode-string "RIFFwav" t)
                                    :mime "audio/wav")))
        (should (memq (harness-voice-output--preview-state preview)
                      '(playing stopped))))
      (harness-voice-output-stop))))

(ert-deftest harness-voice-output-answer-for-a-gone-page-changes-nothing ()
  "An answer asked for by a page that is gone is dropped.
A page reopening under the same name must not take in the answer the
one before it asked for."
  (harness-voice-output-test-with
    (let ((answer nil))
      (harness-voice-output-test--respond-with
       (lambda (_method _params callback _error)
         (setq answer callback)))
      (with-temp-buffer
        (rename-buffer "*harness voice output*")
        (harness-voice-output-mode)
        (harness-voice-output-fetch t)
        (kill-buffer))
      (should-not (get-buffer "*harness voice output*"))
      ;; The answer comes for a page nobody has any more.
      (funcall answer (list :state "stopped" :voices (vector) :parameters (vector)
                            :reason "Local voice pipeline · stopped"))
      (should (eq 'running (harness-voice-output--catalogue-state))))))

(provide 'harness-ui-voice-output-test)
;;; harness-ui-voice-output-test.el ends here
