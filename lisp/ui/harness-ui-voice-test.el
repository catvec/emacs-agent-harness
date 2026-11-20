;;; harness-ui-voice-test.el --- Client-side voice regressions  -*- lexical-binding: t; -*-

;;; Commentary:

;; A real compose box and fake local speech processes: no microphone,
;; speakers, model or network.  Dictation stays a draft; only new assistant
;; text in the selected session can be spoken, once, until interrupted.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui-voice)

(defconst harness-ui-voice-test--recorder
  "import pathlib,signal,sys,time\nsignal.signal(signal.SIGINT, lambda *_: sys.exit(0))\npathlib.Path(sys.argv[1]).write_bytes(b'RIFF'+b'0'*76)\nwhile True: time.sleep(0.02)\n"
  "A recorder whose WAV appears after its SIGINT handler is ready.")

(defvar harness-ui-voice-test--notifications nil)

(defun harness-ui-voice-test--draw ()
  "Redraw the compose host, preserving its draft and insertion offset."
  (harness-compose-capture)
  (let ((inhibit-read-only t) (buffer-undo-list t)
        (offset (and (harness-compose-in-p) (- (point) harness-compose-start))))
    (erase-buffer)
    (insert (propertize "Transcript\n" 'read-only t))
    (harness-compose-insert)
    (when offset (goto-char (min harness-compose-end (+ harness-compose-start offset))))))

(defmacro harness-ui-voice-test-with (&rest body)
  "Run BODY in an isolated compose host with local fake speech commands."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let ((harness-voice--enabled t) (harness-voice--owner nil) (harness-voice--job nil)
           (harness-voice--release-mode nil) (harness-ui-media--recorder nil)
           (harness-compose-controls-functions nil) (harness-voice-process-timeout 5)
           (harness-voice-recording-limit 5)
           (harness-voice-transcribe-command '("python3" "-c" "print('héllo')" :file))
           (harness-voice-pipeline-status '(:state "running" :detail "2 of 2 services"))
           (harness-ui-voice-test--notifications nil) (global-mode-string nil)
           (default-directory dir) (buf (generate-new-buffer " *voice compose test*")))
       (unwind-protect
           (save-window-excursion
             (set-window-buffer (selected-window) buf)
             (with-current-buffer buf
               (setq-local harness-ui-session-id "voice-session")
               (use-local-map harness-compose-map)
               (harness-compose-setup :project (lambda () dir) :redraw #'harness-ui-voice-test--draw)
               (harness-ui-voice-test--draw)
               (cl-letf (((symbol-function 'harness-ui-notify)
                          (lambda (method params)
                            (push (cons method params) harness-ui-voice-test--notifications)))
                         ((symbol-function 'harness-ui-media--recorder-command)
                          (lambda (file)
                            (list "python3" "-u" "-c" harness-ui-voice-test--recorder file))))
                 ,@body)))
         (harness-voice--abort)
         (when (buffer-live-p buf) (kill-buffer buf))
         (when-let* ((recovery (get-buffer "*harness-voice-transcript*"))) (kill-buffer recovery))))))

(defun harness-ui-voice-test--record ()
  "Start the fake recorder and wait until its signal handler is ready."
  (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
  (harness-voice-hold)
  (should (eq harness-voice--state 'listening))
  (let ((file (expand-file-name "audio.wav" (harness-voice--job-dir harness-voice--job))))
    (harness-test-wait (lambda () (file-exists-p file)) 3 "fake microphone startup")))

(defun harness-ui-voice-test--chunk (text &optional id sid)
  "Deliver assistant TEXT for ID and SID, defaulting to this test's node/session."
  (harness-voice--on-update
   (or sid "voice-session")
   (list :sessionUpdate "agent_message_chunk" :_harness (list :nodeId (or id "n-voice"))
         :content (list :type "text" :text text))))

(defun harness-ui-voice-test--node (text &optional kind id)
  "Announce a node containing TEXT of KIND and ID."
  (harness-voice--on-update "voice-session"
                          (list :sessionUpdate "_harness/node"
                                :node (list :id (or id "n-voice") :kind (or kind "assistant") :content text))))

(ert-deftest harness-ui-voice-dictation-preserves-offset-attachments-and-draft ()
  "Recording transcribes into the captured box, without sending a prompt."
  (harness-ui-voice-test-with
    (harness-compose-set "alpha omega")
    (setq harness-compose-attachments '((:path "note.txt" :mime "text/plain")))
    (goto-char (+ harness-compose-start 5))
    (harness-ui-voice-test--record)
    (let ((job harness-voice--job))
      (should (= (file-modes (harness-voice--job-dir job)) #o700))
      (harness-voice-release)
      (harness-test-wait (lambda () (null harness-voice--job)) 5 "transcription")
      (should (equal (harness-compose-text) "alpha héllo omega"))
      (should (equal harness-compose-attachments '((:path "note.txt" :mime "text/plain"))))
      (should-not (file-exists-p (harness-voice--job-dir job)))
      (should-not harness-voice--release-mode)
      (should-not harness-ui-voice-test--notifications)
      (should (eq harness-voice--state 'ready)))))

(ert-deftest harness-ui-voice-dictation-survives-compose-redraw ()
  "A host redraw is not a new draft or transcription target."
  (harness-ui-voice-test-with
    (harness-compose-set "before after")
    (goto-char (+ harness-compose-start 6))
    (harness-ui-voice-test--record)
    (let ((generation harness-compose-generation))
      (harness-ui-voice-test--draw)
      (should (= generation harness-compose-generation)))
    (harness-voice-release)
    (harness-test-wait (lambda () (null harness-voice--job)) 5 "redrawn draft")
    (should (equal (harness-compose-text) "before héllo after"))))

(ert-deftest harness-ui-voice-dictation-never-overwrites-a-new-draft ()
  "Editing, same-text replacement, clearing and session replacement recover safely."
  (dolist (change '(edit same clear session))
    (harness-ui-voice-test-with
      (harness-compose-set "original")
      (goto-char harness-compose-end)
      (harness-ui-voice-test--record)
      (pcase change
        ('edit (insert " changed")) ('same (harness-compose-set "original"))
        ('clear (harness-compose-clear)) ('session (setq harness-ui-session-id "different-session")))
      (let ((draft (harness-compose-text)))
        (harness-voice-release)
        (harness-test-wait (lambda () (null harness-voice--job)) 5 "safe recovery")
        (should (equal draft (harness-compose-text)))
        (should (eq harness-voice--state 'failed))
        (should (equal harness-voice--error "Draft changed · *harness-voice-transcript*"))
        (should (equal (with-current-buffer "*harness-voice-transcript*" (buffer-string)) "héllo\n\n"))))))

(ert-deftest harness-ui-voice-cancel-kills-audio-and-invalidates-sentinel ()
  "A late callback cannot insert after interruption, even from another buffer."
  (harness-ui-voice-test-with
    (harness-compose-set "draft")
    (setq harness-voice-mode t)
    (harness-ui-voice-test--record)
    (let* ((job harness-voice--job) (process (harness-voice--job-process job))
           (sentinel (process-sentinel process)) (private (harness-voice--job-dir job)))
      (with-temp-buffer (harness-voice-interrupt))
      (should-not harness-voice--job)
      (should-not (process-live-p process))
      (should-not (file-exists-p private))
      (should-not harness-voice--release-mode)
      (funcall sentinel process "late exit")
      (should (equal (harness-compose-text) "draft"))
      (should (equal (car harness-ui-voice-test--notifications)
                     '("session/cancel" :sessionId "voice-session"))))))

(ert-deftest harness-ui-voice-buffer-death-stops-the-microphone ()
  "Killing the owner removes audio, timers and global release capture."
  (harness-ui-voice-test-with
    (harness-ui-voice-test--record)
    (let* ((job harness-voice--job) (private (harness-voice--job-dir job))
           (process (harness-voice--job-process job)))
      (kill-buffer buf)
      (should-not harness-voice--owner)
      (should-not harness-voice--job)
      (should-not (process-live-p process))
      (should-not (file-exists-p private))
      (should-not harness-voice--release-mode))))

(ert-deftest harness-ui-voice-empty-and-failed-transcription-are-visible ()
  "A failed or empty recognizer never sends or destroys the draft."
  (dolist (script '("pass" "import sys; sys.stderr.write('decoder unavailable'); sys.exit(7)"))
    (harness-ui-voice-test-with
      (setq harness-voice-transcribe-command (list "python3" "-c" script :file))
      (harness-compose-set "kept")
      (harness-ui-voice-test--record)
      (let ((private (harness-voice--job-dir harness-voice--job)))
        (harness-voice-release)
        (harness-test-wait (lambda () (null harness-voice--job)) 5 "recognizer failure")
        (should (eq harness-voice--state 'failed))
        (should (equal (harness-compose-text) "kept"))
        (should-not (file-exists-p private))
        (should-not harness-ui-voice-test--notifications)
        (if (equal script "pass") (should (equal harness-voice--error "Empty transcription"))
          (should (string-match-p "Voice transcribing failed · decoder unavailable" harness-voice--error)))))))

(ert-deftest harness-ui-voice-transcription-timeout-cleans-up ()
  "A recognizer that hangs is stopped by the bounded process timer."
  (harness-ui-voice-test-with
    (setq harness-voice-process-timeout 0.2
          harness-voice-transcribe-command '("python3" "-c" "import time; time.sleep(30)" :file))
    (harness-ui-voice-test--record)
    (let ((private (harness-voice--job-dir harness-voice--job)))
      (harness-voice-release)
      (harness-test-wait (lambda () (null harness-voice--job)) 5 "recognizer timeout")
      (should (eq harness-voice--state 'failed))
      (should (equal harness-voice--error "Voice process timeout"))
      (should-not (file-exists-p private)))))

(ert-deftest harness-ui-voice-unconfigured-service-keeps-the-microphone-off ()
  "Configuration is validated before any recorder process exists.
A client with no commands of its own uses the harness's pipeline; a
pipeline that is not running is refused before the microphone is on."
  (harness-ui-voice-test-with
    (setq harness-voice-transcribe-command nil)
    (let ((harness-voice-pipeline-status '(:state "stopped" :reason "Local voice pipeline · stopped")))
      (harness-voice-dictate)
      (should-not harness-voice--job)
      (should-not harness-voice--release-mode)
      (should (eq harness-voice--state 'failed))
      (should (equal harness-voice--error "Local voice pipeline · stopped")))
    ;; A harness that never answered is not a running pipeline either.
    (let ((harness-voice-pipeline-status nil))
      (harness-voice-dictate)
      (should-not harness-voice--job)
      (should (equal harness-voice--error "Local voice pipeline · not checked")))))

(ert-deftest harness-ui-voice-streams-sentences-once-and-ignores-other-content ()
  "Announcements, chunks and rewritten finals produce no duplicate speech."
  (harness-ui-voice-test-with
    (setq harness-voice-mode t harness-voice--owner buf)
    (cl-letf (((symbol-function 'harness-voice--speak-next) #'ignore))
      (harness-voice--on-event "agent/turn-started" '("voice-session"))
      (harness-ui-voice-test--node "Hello. ")
      (harness-ui-voice-test--chunk "Hello. ")
      (should (equal harness-voice--queue '("Hello.")))
      (harness-voice--on-update "voice-session" '(:sessionUpdate "agent_thought_chunk" :content (:text "reasoning")))
      (harness-ui-voice-test--node "tool output" "tool-result" "tool-node")
      (harness-ui-voice-test--chunk "Other session. " "other" "other-session")
      (harness-ui-voice-test--chunk "[the result](harness:call/last)")
      (harness-ui-voice-test--node "Hello. [the result](harness:session/a/call/node-123)")
      (harness-ui-voice-test--node "Hello. [the result](harness:session/a/call/node-123)")
      (harness-voice--on-event "agent/turn-ended" '("voice-session" "end-turn"))
      (should (equal harness-voice--queue '("Hello." "the result")))
      (should-not harness-voice--turn-active)
      (should (= (hash-table-count harness-voice--streams) 1)))))

(ert-deftest harness-ui-voice-announcement-only-reply-flushes-once ()
  "Providers without text chunks still get one spoken final reply."
  (harness-ui-voice-test-with
    (setq harness-voice-mode t harness-voice--owner buf)
    (cl-letf (((symbol-function 'harness-voice--speak-next) #'ignore))
      (harness-voice--on-event "agent/turn-started" '("voice-session"))
      (harness-ui-voice-test--node "Partial")
      (harness-ui-voice-test--node "Final response")
      (should-not harness-voice--queue)
      (harness-voice--on-event "agent/turn-ended" '("voice-session" "end-turn"))
      (harness-voice--on-event "agent/turn-ended" '("voice-session" "end-turn"))
      (should (equal harness-voice--queue '("Final response"))))))

(ert-deftest harness-ui-voice-interruption-mutes-late-updates ()
  "Old chunks and finals cannot restart readback after a barge-in."
  (harness-ui-voice-test-with
    (setq harness-voice-mode t harness-voice--owner buf)
    (cl-letf (((symbol-function 'harness-voice--speak-next) #'ignore))
      (harness-voice--on-event "agent/turn-started" '("voice-session"))
      (harness-ui-voice-test--chunk "First. ")
      (harness-voice-interrupt)
      (harness-ui-voice-test--chunk "Stale. ")
      (harness-ui-voice-test--node "First. Stale. Final.")
      (harness-voice--on-event "agent/turn-ended" '("voice-session" "cancelled"))
      (should-not harness-voice--queue)
      (should-not harness-voice--turn-active)
      (should (= (hash-table-count harness-voice--streams) 0)))))

(ert-deftest harness-ui-voice-speech-text-skips-code-and-link-destinations ()
  "Speech keeps link labels but excludes fenced code and markup."
  (should (equal (harness-voice--speech-text
                  "## Result\n**Done**; [details](https://example.test/private).\n```python\nsecret = 'not spoken'\n```\nNext.")
                 "Result Done; details. Next."))
  (should (equal (harness-voice--speech-text "Ready.\n```elisp\nunfinished") "Ready.")))

(ert-deftest harness-ui-voice-spoken-process-pipeline-and-cancellation ()
  "Synthesis and external playback are asynchronous and cancellable."
  (harness-ui-voice-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-mode t harness-voice--owner buf
          harness-voice-synthesize-command
          '("python3" "-c" "import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b'RIFF'+b'0'*76); sys.stdin.read()" :file)
          harness-voice-player-command '("python3" "-c" "import time; time.sleep(30)" :file)
          harness-voice--queue '("Ready."))
    (harness-voice--speak-next)
    (should (eq harness-voice--state 'synthesizing))
    (harness-test-wait (lambda () (eq harness-voice--state 'speaking)) 5 "external playback")
    (let ((private (harness-voice--job-dir harness-voice--job))
          (process (harness-voice--job-process harness-voice--job)))
      (harness-voice-interrupt)
      (should-not harness-voice--job)
      (should-not (process-live-p process))
      (should-not (file-exists-p private))
      (should (eq harness-voice--state 'ready)))))

(ert-deftest harness-ui-voice-status-copy-controls-and-bindings ()
  "States explicitly label microphone power, with exact labels and tooltips."
  (harness-ui-voice-test-with
    (pcase-dolist (`(,state ,copy)
                  '((ready "Voice ready · Microphone off") (listening "Listening · Microphone on")
                    (transcribing "Transcribing · Microphone off") (thinking "Thinking · Microphone off")
                    (synthesizing "Synthesizing · Microphone off") (speaking "Speaking · Microphone off")
                    (failed "Voice failed · Microphone off")))
      (setq harness-voice--state state)
      (should (equal copy (harness-voice--status))))
    (setq harness-voice--state 'ready harness-voice--controls t)
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 500)))
      (let ((line (harness-voice--controls)))
        (should (equal (substring-no-properties line)
                       " Voice ready · Microphone off · [Dictate C-c v] · [Interrupt C-c V] · [Hold to talk] · [Spoken replies] · [Setup]"))
        (dolist (spec '(("[Dictate C-c v]" "Dictation · C-c v") ("[Interrupt C-c V]" "Speech and turn interruption · C-c V")
                        ("[Hold to talk]" "Dictation · mouse press and release")
                        ("[Spoken replies]" "Spoken replies · current chat") ("[Setup]" "Voice settings")))
          (let ((at (string-search (car spec) line)))
            (should at) (should (equal (get-text-property at 'help-echo line) (cadr spec)))))
        (let* ((at (string-search "[Hold to talk]" line)) (map (get-text-property at 'keymap line)))
          (should (eq (lookup-key map [down-mouse-1]) #'harness-voice-hold))
          (should (eq (lookup-key map [mouse-1]) #'harness-voice-release)))))
    (should (eq (lookup-key harness-voice--release-mode-map [drag-mouse-1]) #'harness-voice-release))
    (should (eq (lookup-key harness-voice--release-mode-map [remap keyboard-quit]) #'harness-voice-interrupt))))

(ert-deftest harness-ui-voice-controls-are-not-editable-draft-text ()
  "Controls are separate from the editable box and survive redraw."
  (harness-ui-voice-test-with
    (let ((harness-compose-controls-functions '(harness-voice--controls)))
      (harness-compose-set "draft")
      (harness-ui-voice-test--draw)
      (should (equal (harness-compose-text) "draft"))
      (goto-char (point-min)) (search-forward "[Voice]")
      (should (get-text-property (1- (point)) 'read-only))
      (should (< (point) harness-compose-start))
      (should-not (get-text-property harness-compose-start 'read-only))
      (harness-ui-voice-test--draw)
      (should (equal (harness-compose-text) "draft")))))

(ert-deftest harness-ui-voice-controls-boundary-stays-before-the-box ()
  "Tail-head insertion preserves the controls and draft, with or without controls."
  (dolist (controls '(nil (harness-voice--controls)))
    (harness-ui-voice-test-with
      (let ((harness-compose-controls-functions controls))
        (harness-compose-set "draft")
        (harness-ui-voice-test--draw)
        (let* ((boundary harness-compose-controls-start)
               (start (save-excursion (goto-char (point-min)) (forward-line 1) (point)))
               (suffix (buffer-substring-no-properties start (point-max))))
          ;; Construction must not let the marker drift through the prompt
          ;; and draft.  With no controls it is exactly the prompt's start.
          (should (= boundary start))
          (should (< boundary harness-compose-start))
          (if controls
              (should (< boundary (overlay-start harness-compose-overlay)))
            (should (= boundary (overlay-start harness-compose-overlay))))
          (let ((inhibit-read-only t))
            (goto-char boundary)
            (insert "Updated tail head\n"))
          ;; Once built, front insertion is outside the whole controls+box
          ;; region, so a subsequent partial redraw can stop at this marker.
          (should (= boundary (+ start (length "Updated tail head\n"))))
          (should (equal suffix (buffer-substring-no-properties boundary (point-max))))
          (should (< boundary harness-compose-start))
          (should (equal (harness-compose-text) "draft")))))))

(ert-deftest harness-ui-voice-init-and-shutdown-are-idempotent ()
  "Optional voice leaves no hooks, bindings, mode-line entries or active audio."
  (harness-ui-voice-test-with
    (let ((harness-ui-update-functions nil) (harness-ui-event-functions nil)
          (harness-ui-redraw-hook nil) (harness-ui-media-recording-blocked-p-functions nil)
          (kill-emacs-hook nil))
      (unwind-protect
          (progn
            (harness-voice--init) (harness-voice--init)
            (should (= (cl-count #'harness-voice--on-update harness-ui-update-functions) 1))
            (should (= (cl-count #'harness-voice--controls harness-compose-controls-functions) 1))
            (should (= (cl-count harness-voice--mode-line global-mode-string :test #'equal) 1))
            (should (eq (lookup-key harness-ui-views-map (kbd "v")) #'harness-voice))
            (should (eq (lookup-key harness-compose-map (kbd "C-c v")) #'harness-voice-dictate))
            (should (eq (lookup-key harness-compose-map (kbd "C-c V")) #'harness-voice-interrupt))
            (harness-ui-voice-test--record)
            (let ((private (harness-voice--job-dir harness-voice--job)))
              (harness-voice--shutdown) (should-not (file-exists-p private)))
            (harness-voice--shutdown)
            (should-not harness-voice--enabled) (should-not harness-voice--owner) (should-not harness-voice--job)
            (should-not harness-ui-update-functions) (should-not harness-ui-event-functions)
            (should-not harness-ui-redraw-hook) (should-not harness-ui-media-recording-blocked-p-functions)
            (should-not harness-compose-controls-functions) (should-not global-mode-string)
            (should-not (lookup-key harness-ui-views-map (kbd "v")))
            (should-not (lookup-key harness-compose-map (kbd "C-c v"))))
        (harness-voice--shutdown)))))

(ert-deftest harness-ui-voice-quick-chat-context-is-only-the-origin ()
  "Quick chat names its file/line and looks up no other session."
  (harness-ui-voice-test-with
    (let ((buffer-file-name (expand-file-name "file.py" dir))
          (lookups 0))
      (cl-letf (((symbol-function 'harness-files-project-root) (lambda (_) dir))
                ((symbol-function 'harness-ui-sessions)
                 (lambda (&optional _) (setq lookups (1+ lookups)) nil)))
        (should (equal (format "Voice request context: file.py:%d\n\n"
                               (line-number-at-pos))
                       (harness-voice--context)))
        (should (= 0 lookups))))))

(ert-deftest harness-ui-voice-mouse-validation-and-control-copy ()
  "Mouse validation is inline too; every alternate control has exact copy."
  (harness-ui-voice-test-with
    (cl-letf (((symbol-function 'harness-compose--room) (lambda () (* 500 (frame-char-width)))))
      (should (equal " [Voice]" (substring-no-properties (harness-voice--controls))))
      (setq harness-voice--controls t harness-voice--state 'listening harness-voice-mode t)
      (should (equal (concat " Listening · Microphone on · [Transcribe C-c v] · [Interrupt C-c V]"
                             " · [Talking · release] · [Voice off] · [Setup]")
                     (substring-no-properties (harness-voice--controls))))
      ;; With no commands of its own and no running pipeline, the
      ;; controls say what to start rather than opening the microphone.
      (setq harness-voice-transcribe-command nil)
      (let ((harness-voice-pipeline-status '(:state "stopped" :reason "Local voice pipeline · stopped")))
        (harness-voice-hold)
        (should-not harness-voice--job)
        (should-not harness-voice--release-mode)
        (should (equal "Local voice pipeline · stopped" harness-voice--error))
        (let* ((line (harness-voice--controls))
               (at (string-search "Voice failed" line)))
          (should (equal (concat " Voice failed · Microphone off · [Dictate C-c v] · [Interrupt C-c V]"
                                 " · Local voice pipeline · stopped · [Hold to talk]"
                                 " · [Voice off] · [Setup]")
                         (substring-no-properties line)))
          (should (equal "Local voice pipeline · stopped" (get-text-property at 'help-echo line))))))))

(ert-deftest harness-ui-voice-dictation-uses-the-harness-pipeline ()
  "A client with no command of its own transcribes with the harness.
The audio goes over ACP (`_harness/speech/transcribe'), so the client
needs no whisper.cpp: the harness server runs the pipeline."
  (harness-ui-voice-test-with
    (setq harness-voice-transcribe-command nil)
    (let ((calls nil))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params callback &optional _error)
                   (push (cons method params) calls)
                   (funcall callback '(:text "spoken into the harness")))))
        (harness-ui-voice-test--record)
        (harness-voice-release)
        (harness-test-wait (lambda () (null harness-voice--job)) 5 "pipeline transcription")
        (should (equal "spoken into the harness" (harness-compose-text)))
        (should (eq harness-voice--state 'ready))
        (should (equal "_harness/speech/transcribe" (caar calls)))
        ;; The audio went as base64 WAV, never as a path.
        (let ((audio (plist-get (cdar calls) :audio)))
          (should (stringp audio))
          (should (string-prefix-p "RIFF" (base64-decode-string audio))))))))

(ert-deftest harness-ui-voice-spoken-replies-use-the-harness-pipeline ()
  "A client with no command of its own speaks with the harness.
It asks for the audio over ACP and plays the WAV that comes back with
this machine's player, so the speaker stays local."
  (harness-ui-voice-test-with
    (setq harness-voice-synthesize-command nil
          harness-voice-mode t)
    (let ((calls nil) (played nil))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params callback &optional _error)
                   (push (cons method params) calls)
                   (funcall callback (list :audio (base64-encode-string
                                                   (concat "RIFF" (make-string 60 ?0)) t)
                                           :mime "audio/wav"))))
                ((symbol-function 'harness-voice--player)
                 (lambda (_file) '("true" "audio.wav")))
                ((symbol-function 'harness-voice--new-job)
                 (lambda ()
                   (setq harness-voice--job
                         (harness-voice--make-job :buffer (current-buffer)
                                                 :session harness-ui-session-id
                                                 :dir (make-temp-file "harness-voice-test-" t)))
                   harness-voice--job))
                ((symbol-function 'harness-voice--run)
                 (lambda (job phase command &optional input)
                   (push (list phase command) played)
                   (setf (harness-voice--job-phase job) phase))))
        (harness-voice--set-state 'synthesizing)
        (setq harness-voice--queue (list "Spoken by the harness"))
        (harness-voice--speak-next)
        (harness-test-wait (lambda () calls) 3 "the harness's audio")
        (should (equal "_harness/speech/synthesize" (caar calls)))
        (should (equal "Spoken by the harness" (plist-get (cdar calls) :text)))
        ;; The player is this machine's; only the speech crossed the wire.
        (should (equal '(speaking ("true" "audio.wav")) (car played)))))))

(ert-deftest harness-ui-voice-recording-cap-transcribes-the-utterance ()
  "The recording cap acts as a release, unlike a speech-process timeout."
  (harness-ui-voice-test-with
    (harness-ui-voice-test--record)
    (harness-voice--timeout harness-voice--job)
    (harness-test-wait (lambda () (null harness-voice--job)) 5 "capped recording")
    (should (equal "héllo" (harness-compose-text)))
    (should (eq harness-voice--state 'ready))
    (should-not harness-voice--release-mode)
    (should-not harness-ui-voice-test--notifications)))

(ert-deftest harness-ui-voice-a-command-that-exits-first-keeps-its-result ()
  "A command reaped before its input is written is not an error.
A transcriber can exit before the EOF reaches it; the write then
raised `Process ... not running', which replaced the result the
sentinel produced with that message."
  (harness-ui-voice-test-with
    (let ((job (harness-voice--new-job)) signalled)
      (cl-letf* ((real (symbol-function 'make-process))
                 ((symbol-function 'make-process)
                  (lambda (&rest args)
                    ;; The child is reaped before `harness-voice--run' returns.
                    (let ((process (apply real (plist-put args :sentinel #'ignore))))
                      (while (process-live-p process) (accept-process-output process 0.01))
                      process))))
        (condition-case err (harness-voice--run job 'transcribing '("true") "words")
          (error (setq signalled (error-message-string err)))))
      (should-not signalled)
      (should (eq job harness-voice--job)))))

(ert-deftest harness-ui-voice-new-empty-compose-target-recovers-the-transcript ()
  "An empty new reply is not the empty task draft captured by the recorder."
  (harness-ui-voice-test-with
    (harness-ui-voice-test--record)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (harness-compose-insert ""))
    (harness-voice-release)
    (harness-test-wait (lambda () (null harness-voice--job)) 5 "empty replacement")
    (should (equal "" (harness-compose-text)))
    (should (equal "Draft changed · *harness-voice-transcript*" harness-voice--error))
    (should (equal "héllo\n\n" (with-current-buffer "*harness-voice-transcript*" (buffer-string))))))

(ert-deftest harness-ui-voice-model-redraw-preserves-audio-but-reconnect-discards-it ()
  "Routine catalogue redraws leave dictation intact; a new connection cannot."
  (harness-ui-voice-test-with
    (let* ((harness-ui-connection (list 'original))
           (harness-voice--connection harness-ui-connection))
      (harness-ui-voice-test--record)
      (let* ((job harness-voice--job) (private (harness-voice--job-dir job)))
        (harness-voice--redraw)
        (should (eq job harness-voice--job))
        (should (eq harness-voice--state 'listening))
        (setq harness-ui-connection (list 'replacement))
        (harness-voice--redraw)
        (should-not harness-voice--job)
        (should-not (file-exists-p private))
        (should (eq harness-voice--state 'ready))
        (should (eq harness-ui-connection harness-voice--connection))))))

(ert-deftest harness-ui-voice-redaction-removes-audio-queues-and-recovery ()
  "Session redaction cannot leave old speech or recoverable private text."
  (harness-ui-voice-test-with
    (harness-ui-voice-test--record)
    (setq harness-voice-mode t harness-voice--turn-active t
          harness-voice--queue '("private speech")
          harness-voice--streams (make-hash-table :test 'equal))
    (puthash "private-node" '(:text "private speech") harness-voice--streams)
    (with-current-buffer (get-buffer-create "*harness-voice-transcript*") (insert "private transcript"))
    (let ((private (harness-voice--job-dir harness-voice--job)))
      (harness-voice--on-event "session/redacted" '("voice-session"))
      (should-not harness-voice--job)
      (should-not (file-exists-p private))
      (should-not harness-voice--queue)
      (should-not harness-voice--turn-active)
      (should (= 0 (hash-table-count harness-voice--streams)))
      (should-not (get-buffer "*harness-voice-transcript*")))))

(ert-deftest harness-ui-voice-empty-synthesis-is-a-visible-failure ()
  "An adapter's successful exit without audio cannot reach the player."
  (harness-ui-voice-test-with
    (setq harness-voice-mode t harness-voice--owner buf
          harness-voice-synthesize-command '("python3" "-c" "import sys; sys.stdin.read()" :file)
          harness-voice-player-command '("python3" "-c" "pass" :file)
          harness-voice--queue '("Ready."))
    (harness-voice--speak-next)
    (let ((private (harness-voice--job-dir harness-voice--job)))
      (harness-test-wait (lambda () (null harness-voice--job)) 5 "empty speech")
      (should-not (file-exists-p private))
      (should (eq harness-voice--state 'failed))
      (should (equal "Empty speech audio" harness-voice--error)))))

(ert-deftest harness-ui-voice-validation-copy-and-exclusive-microphone ()
  "Validation has exact noun-phrase copy, before recording or playback."
  (harness-ui-voice-test-with
    (should (equal "Speech command unset"
                   (error-message-string (should-error (harness-voice--command '("python3") "audio.wav")))))
    ;; A client with no command of its own is ready when the harness
    ;; pipeline runs, and refused, naming it, when it does not.
    (let ((harness-voice-transcribe-command nil)
          (harness-voice-pipeline-status '(:state "running" :detail "2 of 2 services")))
      (should-not (harness-voice--transcriber-error))
      (should (harness-voice--pipeline-transcribes-p)))
    (let ((harness-voice-transcribe-command nil)
          (harness-voice-pipeline-status '(:state "stopped" :reason "Local voice pipeline · stopped")))
      (should (equal "Local voice pipeline · stopped" (harness-voice--transcriber-error))))
    (should (equal "Voice executable unavailable · harness-no-such-executable"
                   (error-message-string
                    (should-error (harness-voice--command '("harness-no-such-executable" :file) "audio.wav")))))
    (let ((harness-voice-player-command nil))
      (cl-letf (((symbol-function 'harness-ui-media--player-program) (lambda () nil)))
        (should (equal "Voice player unavailable · mpv, pw-play, ffplay or paplay"
                       (error-message-string (should-error (harness-voice--player "audio.wav")))))))
    (should (equal "Spoken replies unavailable · Chat required"
                   (error-message-string (should-error (harness-voice-mode 1)))))
    (should-not harness-voice-mode)
    (cl-letf (((symbol-function 'harness-ui-media--recorder-command) (lambda (_) nil)))
      (harness-voice-hold)
      (should-not harness-voice--job)
      (should (equal "Voice recorder unavailable · pw-record, parec, arecord or ffmpeg"
                     harness-voice--error)))
    (harness-ui-voice-test--record)
    (let ((harness-ui-media-recording-blocked-p-functions '(harness-voice--recording-p)))
      (should (equal "Microphone unavailable · Voice active"
                     (error-message-string (should-error (harness-record-audio))))))))

(ert-deftest harness-ui-voice-microphone-indicator-waits-for-recorder-exit ()
  "A slow recorder cannot keep capturing behind a microphone-off label."
  (harness-ui-voice-test-with
    (harness-ui-voice-test--record)
    (cl-letf (((symbol-function 'interrupt-process) (lambda (&rest _) nil)))
      (harness-voice-release)
      (should (harness-voice--recording-p))
      (should (harness-voice--job-stopping harness-voice--job))
      (should (equal "Listening · Microphone on" (harness-voice--status)))
      (harness-voice-interrupt)
      (should-not harness-voice--job)
      (should (equal "Voice ready · Microphone off" (harness-voice--status))))))

(ert-deftest harness-ui-voice-live-mode-requires-a-session-route-and-compose ()
  "A live session needs both its nonempty id and an actual compose box."
  (dolist (session '(nil "" 7 "voice-session"))
    (harness-ui-voice-test-with
      (let ((harness-voice-provider 'custom)
            (harness-voice-live--process nil)
            (harness-voice-live--buffer nil))
        (setq harness-ui-session-id session)
        (if (equal session "voice-session")
            (progn
              (harness-voice-mode 1)
              (should harness-voice-mode)
              (should (eq harness-voice--owner buf)))
          (should (equal "Live voice compose unavailable"
                         (error-message-string
                          (should-error (harness-voice-mode 1) :type 'user-error))))
          (should-not harness-voice-mode)
          (should-not harness-voice--owner))
        ;; A remembered session without its box is not a live target,
        ;; even in a buffer whose major mode names a chat.
        (setq harness-ui-session-id "voice-session"
              major-mode 'harness-chat-mode)
        (harness-compose-hide)
        (should (equal "Live voice compose unavailable"
                       (error-message-string
                        (should-error (harness-voice-mode 1) :type 'user-error))))
        (should-not harness-voice-mode)))))

;;;; The receipt of an accepted request (WAV capability)

;; A real player process would need a speaker, which no test machine has:
;; these start one and read what it was asked to play, so what is checked
;; is the path -- the phrase chosen, the file generated before the
;; request, the cancellation -- and never that a speaker was heard.

(defvar harness-ui-voice-test--played nil
  "The files the receipt's player was started on, oldest first.")

(defun harness-ui-voice-test--prime (&rest phrases)
  "Write a playable WAV for each of PHRASES into the acknowledgment cache."
  (dolist (phrase phrases)
    (let ((file (harness-voice--acknowledgment-file phrase)))
      (make-directory (file-name-directory file) t)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert "RIFF" (make-string 120 0))
        (write-region (point-min) (point-max) file nil 'silent)))))

(defun harness-ui-voice-test--ack-now ()
  "Run the receipt's zero-delay timer now, as redisplay would."
  (sit-for 0.01))

(defmacro harness-ui-voice-test-with-ack (&rest body)
  "Run BODY in a compose host whose receipt player only records its start."
  (declare (indent 0))
  `(harness-ui-voice-test-with
     (setq harness-voice-mode t harness-voice--owner buf
           harness-voice-acknowledgment t
           harness-voice-live-acknowledgment t
           harness-ui-voice-test--played nil
           harness-voice--acknowledgment-last nil
           harness-voice--acknowledgment-process nil
           harness-voice--acknowledgment-timer nil)
     (harness-ui-voice-test--prime "On it" "Hmm, thinking" "Right")
     (add-hook 'harness-ui-turn-accepted-functions #'harness-voice--acknowledge)
     (cl-letf (((symbol-function 'harness-voice--player)
                (lambda (file)
                  (push file harness-ui-voice-test--played)
                  ;; A player that stays up, as a real one does while it
                  ;; sounds the phrase, so interruption can be seen.
                  (list "sleep" "5"))))
       ,@body
       (remove-hook 'harness-ui-turn-accepted-functions #'harness-voice--acknowledge)
       (harness-voice--acknowledgment-stop))))

(ert-deftest harness-ui-voice-acknowledgment-plays-one-generated-phrase ()
  "An accepted prompt starts one already-generated phrase, and asks for nothing."
  (harness-ui-voice-test-with-ack
    (let ((synthesized nil))
      (cl-letf (((symbol-function 'harness-voice--acknowledgment-synthesize)
                 (lambda (phrase _file _done &optional _failed)
                   (push phrase synthesized))))
        (harness-voice--acknowledge "voice-session" "session/prompt" '(:sessionId "voice-session" :prompt nil))
        ;; The request's own call starts no player.
        (should-not harness-ui-voice-test--played)
        (harness-ui-voice-test--ack-now)
        (should-not synthesized)
        (should (= 1 (length harness-ui-voice-test--played)))
        (should (member harness-voice--acknowledgment-last
                        harness-voice-acknowledgment-phrases))
        (should (file-exists-p (car harness-ui-voice-test--played)))))))

(ert-deftest harness-ui-voice-acknowledgment-variety-and-repeat-suppression ()
  "Phrases vary, and the same one never plays twice in a row."
  (harness-ui-voice-test-with-ack
    (let ((heard nil))
      (dotimes (_ 6)
        (harness-voice--acknowledgment-stop)
        (harness-voice--acknowledge "voice-session" "session/prompt" '(:sessionId "voice-session" :prompt nil))
        (harness-ui-voice-test--ack-now)
        (push harness-voice--acknowledgment-last heard))
      (setq heard (nreverse heard))
      (should (= 6 (length heard)))
      (should (> (length (delete-dups (copy-sequence heard))) 1))
      (cl-loop for (a b) on heard
               while b
               do (should-not (equal a b))))))

(ert-deftest harness-ui-voice-acknowledgment-off-muted-and-unsent ()
  "Off, another session and a non-prompt send nothing."
  (harness-ui-voice-test-with-ack
    (let ((harness-voice-acknowledgment nil))
      (should (equal "acknowledgment off"
                     (harness-voice--acknowledgment-blocked-p)))
      (harness-voice--acknowledge "voice-session" "session/prompt" '(:sessionId "voice-session" :prompt nil))
      (harness-ui-voice-test--ack-now)
      (should-not harness-voice--acknowledgment-process))
    (let ((harness-voice-mode nil))
      (harness-voice--acknowledge "voice-session" "session/prompt" '(:sessionId "voice-session" :prompt nil))
      (harness-ui-voice-test--ack-now)
      (should-not harness-voice--acknowledgment-process))
    (setq harness-voice-mode t)
    ;; Another session's prompt is not this box's receipt.
    (harness-voice--acknowledge "another-session" "session/prompt" '(:sessionId "another-session" :prompt nil))
    (harness-ui-voice-test--ack-now)
    (should-not harness-voice--acknowledgment-process)
    ;; Sending the queue is not a new request.
    (harness-voice--acknowledge "voice-session" "_harness/agent/send-queue" '(:session-id "voice-session" :qids nil))
    (harness-ui-voice-test--ack-now)
    (should-not harness-voice--acknowledgment-process)
    (should-not (harness-voice--acknowledgment-playing-p))
    (should-not harness-ui-voice-test--played)))

(ert-deftest harness-ui-voice-acknowledgment-yields-to-speech-and-interrupt ()
  "A reply that is starting, a queue or an interruption drops the receipt."
  (harness-ui-voice-test-with-ack
    (let ((harness-voice--queue '("A reply.")))
      (harness-voice--acknowledge "voice-session" "session/prompt" '(:sessionId "voice-session" :prompt nil))
      (harness-ui-voice-test--ack-now)
      (should-not harness-voice--acknowledgment-process)
      (should-not harness-voice--acknowledgment-timer))
    (setq harness-voice--queue nil)
    (harness-voice--acknowledge "voice-session" "session/prompt" '(:sessionId "voice-session" :prompt nil))
    (harness-ui-voice-test--ack-now)
    (should (harness-voice--acknowledgment-playing-p))
    (should harness-voice--acknowledgment-timer)
    ;; C-c V silences it now, and nothing sends it again.
    (harness-voice-interrupt)
    (should-not (harness-voice--acknowledgment-playing-p))
    (should-not harness-voice--acknowledgment-timer)))

(ert-deftest harness-ui-voice-acknowledgment-drops-a-finished-turn ()
  "A turn that ended before the receipt started is not acknowledged."
  (harness-ui-voice-test-with-ack
    (let ((answer (harness-make-promise)))
      (cl-letf (((symbol-function 'harness-ui-request) (lambda (&rest _) answer)))
        (harness-ui-call-turn "voice-session" "session/prompt"
                              '(:sessionId "voice-session" :prompt nil) #'ignore)
        (should harness-voice--acknowledgment-pending)
        ;; The answer came back first: nothing is left to acknowledge.
        (harness-resolve answer '(:stopReason "end_turn"))
        (harness-ui-voice-test--ack-now)
        (should-not (harness-voice--acknowledgment-playing-p))
        (should-not harness-voice--acknowledgment-pending)))
    (harness-voice--acknowledgment-stop)))

(ert-deftest harness-ui-voice-acknowledgment-drops-a-stale-one ()
  "A receipt whose session, owner, connection or turn changed never plays."
  (harness-ui-voice-test-with-ack
    (let ((harness-ui-session-id "first-session"))
      (harness-voice--acknowledge "first-session" "session/prompt" '(:sessionId "first-session" :prompt nil))
      (should harness-voice--acknowledgment-pending)
      ;; The box now asks another conversation: the receipt is stale.
      (setq harness-ui-session-id "second-session")
      (harness-ui-voice-test--ack-now)
      (should-not (harness-voice--acknowledgment-playing-p))
      (should-not harness-voice--acknowledgment-pending))
    (setq harness-ui-session-id "voice-session")
    (harness-voice--acknowledge "voice-session" "session/prompt" '(:sessionId "voice-session" :prompt nil))
    (harness-voice--reset)
    (harness-ui-voice-test--ack-now)
    (should-not (harness-voice--acknowledgment-playing-p))
    (harness-voice--acknowledge "voice-session" "session/prompt" '(:sessionId "voice-session" :prompt nil))
    (harness-voice-interrupt)
    (harness-ui-voice-test--ack-now)
    (should-not (harness-voice--acknowledgment-playing-p))))

(ert-deftest harness-ui-voice-acknowledgment-never-fails-the-request ()
  "A player that cannot start leaves the prompt sent and the error silent."
  (harness-ui-voice-test-with-ack
    (let ((asked nil))
      (cl-letf (((symbol-function 'harness-voice--player)
                 (lambda (_file) (setq asked t) (error "Voice player unavailable")))
                ((symbol-function 'harness-ui-request)
                 (lambda (&rest _) (harness-make-promise))))
        (harness-ui-call-turn "voice-session" "session/prompt"
                              '(:sessionId "voice-session" :prompt nil) #'ignore)
        (harness-ui-voice-test--ack-now)
        (should asked)
        (should-not harness-voice--acknowledgment-process)
        (should-not harness-voice--acknowledgment-timer)
        (should-not harness-voice--error)))))

(ert-deftest harness-ui-voice-acknowledgment-ungenerated-phrase-is-silent ()
  "With no phrase generated the request is heard in silence, then primed."
  (harness-ui-voice-test-with
    (setq harness-voice-mode t harness-voice--owner buf
          harness-voice--acknowledgment-process nil)
    (let ((prime nil))
      (cl-letf (((symbol-function 'harness-voice-acknowledge-prime)
                 (lambda (&optional _) (setq prime t)))
                ((symbol-function 'harness-voice--player)
                 (lambda (file) (list "true" file))))
        (harness-voice--acknowledge "voice-session" "session/prompt" '(:sessionId "voice-session" :prompt nil))
        (harness-ui-voice-test--ack-now)
        (should prime)
        (should-not harness-voice--acknowledgment-process)))))

(ert-deftest harness-ui-voice-acknowledgment-prime-generates-each-phrase-once ()
  "The bank is generated in the background, one phrase after another."
  (harness-ui-voice-test-with
    (let ((asked nil))
      (cl-letf (((symbol-function 'harness-voice--acknowledgment-synthesize)
                 (lambda (phrase file done &optional _failed)
                   (push phrase asked)
                   (harness-ui-voice-test--prime phrase)
                   (funcall done file))))
        (harness-voice-acknowledge-prime)
        (should (equal harness-voice-acknowledgment-phrases (nreverse asked)))
        (should-not harness-voice--acknowledgment-priming)
        ;; Generated phrases are not asked for again.
        (setq asked nil)
        (harness-voice-acknowledge-prime)
        (should-not asked)))))

(ert-deftest harness-ui-voice-acknowledgment-a-failed-phrase-does-not-stop-the-pass ()
  "One phrase that cannot be generated leaves the others generated, and no flag stuck."
  (harness-ui-voice-test-with
    (let ((asked nil))
      (cl-letf (((symbol-function 'harness-voice--acknowledgment-synthesize)
                 (lambda (phrase file done &optional failed)
                   (push phrase asked)
                   (if (equal phrase "Hmm, thinking")
                       (funcall failed)
                     (harness-ui-voice-test--prime phrase)
                     (funcall done file)))))
        (harness-voice-acknowledge-prime)
        (should (equal harness-voice-acknowledgment-phrases (nreverse asked)))
        (should-not harness-voice--acknowledgment-priming)
        (should-not (file-exists-p (harness-voice--acknowledgment-file "Hmm, thinking")))
        (should (file-exists-p (harness-voice--acknowledgment-file "Right")))
        ;; A later pass tries only what is still missing.
        (setq asked nil)
        (harness-voice-acknowledge-prime)
        (should (equal '("Hmm, thinking") asked))
        (should-not harness-voice--acknowledgment-priming)))))

(ert-deftest harness-ui-voice-acknowledgment-phrase-bank-copy ()
  "The default bank is receipts, never a claim about the work."
  (dolist (phrase harness-voice-acknowledgment-phrases)
    (should (stringp phrase))
    (should (<= (length phrase) 24))
    (should-not (string-match-p "[.!?]" phrase)))
  (should (equal '("On it" "Hmm, thinking" "Right")
                 harness-voice-acknowledgment-phrases)))

(ert-deftest harness-ui-voice-acknowledgment-setting-copy ()
  "The switch is in the voice group, with the exact line Customize shows.
A setting's description is the one place prose is allowed, and Customize
shows its first sentence: these are pinned so the page cannot drift."
  (dolist (setting '(harness-voice-acknowledgment
                     harness-voice-live-acknowledgment
                     harness-voice-acknowledgment-phrases
                     harness-voice-acknowledgment-voice
                     harness-voice-acknowledgment-timeout))
    (should (assq setting (get 'harness-voice 'custom-group))))
  (let ((shown (lambda (setting)
                 (car (split-string
                       (documentation-property setting 'variable-documentation)
                       "\n")))))
    (should (equal "Whether an accepted request gets one short spoken receipt."
                   (funcall shown 'harness-voice-acknowledgment)))
    ;; Emacs renders the docstring's quote as a curly one; the page
    ;; shows exactly this.
    (should (equal "Whether a live voice request gets the sidecar’s short spoken receipt."
                   (funcall shown 'harness-voice-live-acknowledgment)))
    (should (equal "Phrases the WAV capability may play as a request receipt."
                   (funcall shown 'harness-voice-acknowledgment-phrases)))
    (should (equal "Voice the WAV capability generates its receipts in."
                   (funcall shown 'harness-voice-acknowledgment-voice)))
    (should (equal "Maximum seconds one receipt plays before its player is stopped."
                   (funcall shown 'harness-voice-acknowledgment-timeout)))
    ;; One sentence each: the rest is in the docstring's body, where the
    ;; settings page keeps its help.
    (dolist (setting '(harness-voice-acknowledgment
                       harness-voice-live-acknowledgment
                       harness-voice-acknowledgment-phrases
                       harness-voice-acknowledgment-voice
                       harness-voice-acknowledgment-timeout))
      (should (= 1 (length (split-string (funcall shown setting) "\\." t))))))
  ;; On by default, and on for each capability.
  (should (eq t (default-value 'harness-voice-acknowledgment)))
  (should (eq t (default-value 'harness-voice-live-acknowledgment))))

(provide 'harness-ui-voice-test)
;;; harness-ui-voice-test.el ends here
