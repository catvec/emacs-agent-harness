;;; harness-ui-voice-live-test.el --- Live voice sidecar regressions  -*- lexical-binding: t; -*-

;;; Commentary:

;; A real compose box and scripted sidecars: no microphone, speaker,
;; model or network.  The sidecar protocol is newline-delimited JSON, and
;; every delegation goes through the ordinary session prompt path.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui-voice)

(defconst harness-ui-voice-live-test--sidecar
  (expand-file-name "test/harness-voice-live-sidecar-test.py" harness-test-root))

(defconst harness-ui-voice-live-test--fixture
  (expand-file-name "scripts/harness-voice-live-fixture" harness-test-root))

(defvar harness-ui-voice-live-test--calls nil
  "Session prompts recorded by the test sidecar.")
(defvar harness-ui-voice-live-test--notifications nil)
(defvar harness-ui-voice-live-test--inbox nil)

(defun harness-ui-voice-live-test--draw ()
  "Redraw the compose host, preserving its draft and insertion offset."
  (harness-compose-capture)
  (let ((inhibit-read-only t) (buffer-undo-list t)
        (offset (and (harness-compose-in-p) (- (point) harness-compose-start))))
    (erase-buffer)
    (insert (propertize "Transcript\n" 'read-only t))
    (harness-compose-insert)
    (when offset (goto-char (min harness-compose-end (+ harness-compose-start offset))))))

(defun harness-ui-voice-live-test--command (mode &optional inbox)
  "Return a sidecar command for MODE, recording events in INBOX."
  (list "python3" "-u" harness-ui-voice-live-test--sidecar
        (or inbox (expand-file-name "inbox.jsonl" harness-state-directory))
        mode))

(defun harness-ui-voice-live-test--events (file)
  "Return the JSON events recorded in FILE, oldest first."
  (let (events)
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-blank-p line)
              (push (json-parse-string line :object-type 'plist
                                       :null-object nil :false-object nil)
                    events)))
          (forward-line 1))))
    (nreverse events)))

(defun harness-ui-voice-live-test--wait-event (file event)
  "Wait until FILE holds an EVENT, and return it."
  (let (found)
    (harness-test-wait
     (lambda ()
       (setq found (cl-find event (harness-ui-voice-live-test--events file)
                            :key (lambda (e) (plist-get e :event)) :test #'equal)))
     5 (format "the %s event" event))
    found))

(defun harness-ui-voice-live-test--file-text (file)
  "Return the text of FILE, or an empty string."
  (if (file-exists-p file)
      (with-temp-buffer (insert-file-contents file) (buffer-string))
    ""))

(defmacro harness-ui-voice-live-test-with (&rest body)
  "Run BODY in an isolated compose host with a live provider."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let ((harness-voice--enabled t) (harness-voice--owner nil) (harness-voice--job nil)
           (harness-voice--controls t) (harness-voice-provider 'custom)
           (harness-voice-live-command nil) (harness-voice-live-startup-timeout 5)
           (harness-voice-live--process nil) (harness-voice-live--buffer nil)
           (harness-voice-live--session nil) (harness-voice-live--stderr nil)
           (harness-voice-live--tail "") (harness-voice-live--timer nil)
           (harness-voice-live--state nil) (harness-voice-live--error nil)
           (harness-voice-live--muted nil) (harness-voice-live--working nil)
           (harness-voice-live--turn-active nil) (harness-voice-live--closing nil)
           (harness-voice-live--delegation nil) (harness-voice-live--delegations nil)
           (harness-voice-live--nodes nil) (harness-voice-live--order nil)
           (harness-voice-live--heard "") (harness-voice-live--transcript nil)
           (harness-voice-live--conversation (harness-voice-conversation-create))
           (harness-voice-live--speech-active nil)
           (harness-voice-live--held nil)
           (harness-voice-live--held-timer nil)
           (harness-voice-live--turn-id nil)
           (harness-voice-live--seen (make-hash-table :test 'equal))
           (harness-voice-live--held-seq 0)
           (harness-voice-live-pending-release-delay 0.15)
           (harness-voice-distill t)
           (harness-voice-conversation-carry-context t)
           (harness-voice-conversation-turns 40)
           (harness-voice-conversation-context-turns 4)
           (harness-voice-conversation-context-chars 700)
           (harness-voice-conversation-turn-chars 240)
           (harness-voice-live--speaker nil) (harness-voice-live--section nil)
           (harness-voice-live--stage nil) (harness-voice-live--stage-since nil)
           (harness-voice-live--stage-timer nil) (harness-voice-live--stage-frame 0)
           (harness-voice-live-motion t)
           (harness-voice-live--pipeline (harness-voice-pipeline-create 'off))
           (harness-voice-live--pipeline-timer nil) (harness-voice-live--pipeline-stale-timer nil)
           (harness-voice-live--pipeline-controls-at nil)
           (harness-voice-live--utterance nil) (harness-voice-live--utterance-done nil)
           (harness-voice-live--caption-seq 0) (harness-voice-live--reply-seq 0)
           (harness-compose-controls-functions nil)
           (harness-ui-voice-live-test--calls nil)
           (harness-ui-voice-live-test--notifications nil)
           (harness-ui-voice-live-test--inbox (expand-file-name "inbox.jsonl" harness-state-directory))
           (default-directory dir) (buf (generate-new-buffer " *live voice test*")))
       (unwind-protect
           (save-window-excursion
             (set-window-buffer (selected-window) buf)
             (with-current-buffer buf
               (setq-local harness-ui-session-id "live-session")
               (use-local-map harness-compose-map)
               (harness-compose-setup :project (lambda () dir)
                                      :redraw #'harness-ui-voice-live-test--draw)
               (harness-ui-voice-live-test--draw)
               (cl-letf (((symbol-function 'harness-ui-notify)
                          (lambda (method &optional params)
                            (push (list method params)
                                  harness-ui-voice-live-test--notifications)))
                         ((symbol-function 'harness-ui-call-turn)
                          (lambda (id method params _callback _on-error)
                            (push (list id method params)
                                  harness-ui-voice-live-test--calls)
                            nil)))
                 ,@body)))
         (harness-voice-live--dispose)
         (when (buffer-live-p harness-voice-live--transcript)
           (kill-buffer harness-voice-live--transcript))
         (when (buffer-live-p buf) (kill-buffer buf))))))

(defun harness-ui-voice-live-test--control-lines ()
  "Return the controls' lines, the settings line first."
  (split-string (substring-no-properties (harness-voice-live--controls)) "\n"))

(defun harness-ui-voice-live-test--transcript ()
  "Return the live transcript text."
  (if (buffer-live-p harness-voice-live--transcript)
      (with-current-buffer harness-voice-live--transcript (buffer-string))
    ""))

(defun harness-ui-voice-live-test--occurrences (needle haystack)
  "Return how many times NEEDLE appears in HAYSTACK."
  (let ((start 0) (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(defun harness-ui-voice-live-test--latest-prompt ()
  "Return the text of the newest session prompt the test saw."
  (let* ((call (car harness-ui-voice-live-test--calls))
         (params (nth 2 call)))
    (plist-get (car (plist-get params :prompt)) :text)))

(defun harness-ui-voice-live-test--chunk (text &optional id)
  "Deliver assistant TEXT for node ID."
  (harness-voice--on-update
   "live-session"
   (list :sessionUpdate "agent_message_chunk" :_harness (list :nodeId (or id "n-live"))
         :content (list :type "text" :text text))))

;;;; Lifecycle

(ert-deftest harness-ui-voice-live-start-listens-and-stops ()
  "Starting the sidecar opens the microphone; stopping closes it."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (should (eq harness-voice-live--state 'starting))
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (should (equal "Live · Listening" (harness-voice-live--status)))
    (should (harness-voice-live--active-p))
    (should (harness-voice-live--microphone-on-p))
    (should (harness-voice--recording-p))
    (should harness-voice-mode)
    (should (eq harness-voice--owner buf))
    (harness-voice-live-stop)
    (should (eq harness-voice-live--state 'ending))
    (harness-test-wait (lambda () (null harness-voice-live--state)) 5 "sidecar closed")
    (should-not (harness-voice-live--active-p))
    (should-not harness-voice-mode)
    (should (harness-ui-voice-live-test--wait-event
             harness-ui-voice-live-test--inbox "stop"))))

(ert-deftest harness-ui-voice-live-mode-disable-stops-the-sidecar ()
  "Turning voice off in the chat ends the live session."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (harness-voice-mode -1)
    (harness-test-wait (lambda () (null harness-voice-live--state)) 5 "mode stop")
    (should-not (harness-voice-live--active-p))
    (should-not harness-voice-mode)))

(ert-deftest harness-ui-voice-live-session-deletion-stops-the-sidecar ()
  "Deleting the chat ends live audio instead of leaving it orphaned."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (harness-voice-live--on-update "live-session"
                                   (list :sessionUpdate "_harness/session_deleted"))
    (should (eq harness-voice-live--state 'ending))
    (harness-test-wait (lambda () (null harness-voice-live--state)) 5 "deletion stop")
    (should-not (harness-voice-live--active-p))))

(ert-deftest harness-ui-voice-live-last-frame-closes-the-session ()
  "Closing the last frame ends live voice; another frame keeps it.
The sidecar owns the microphone and the speaker, so a window closing
must not leave a reply playing to an empty desktop, while closing one
of several frames changes nothing."
  (harness-ui-voice-live-test-with
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (frame) (memq frame '(gui-1 gui-2)))))
      ;; Another graphical frame remains: the last window is still open.
      (should-not (harness-voice-live--last-frame-p 'gui-1 '(gui-1 gui-2 tty)))
      ;; The daemon's unseen terminal frame does not keep the session.
      (should (harness-voice-live--last-frame-p 'gui-1 '(gui-1 tty)))
      ;; A terminal Emacs keeps the session while another frame shows it.
      (should-not (harness-voice-live--last-frame-p 'tty-1 '(tty-1 tty-2)))
      (should (harness-voice-live--last-frame-p 'tty-1 '(tty-1)))
      (let ((stopped 0))
        (cl-letf (((symbol-function 'harness-voice-live--active-p) (lambda () t))
                  ((symbol-function 'harness-voice-live-stop)
                   (lambda () (cl-incf stopped)))
                  ((symbol-function 'frame-list) (lambda () '(gui-1 tty))))
          (harness-voice-live--frame-deleted 'gui-1)
          (should (= 1 stopped))
          (cl-letf (((symbol-function 'frame-list) (lambda () '(gui-1 gui-2 tty))))
            (harness-voice-live--frame-deleted 'gui-1)
            (should (= 1 stopped))))))))

(ert-deftest harness-ui-voice-live-recording-owns-the-microphone ()
  "The WAV recorder cannot run while the sidecar holds the audio device."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (let ((harness-ui-media-recording-blocked-p-functions '(harness-voice--recording-p)))
      (should (equal "Microphone unavailable · Voice active"
                     (error-message-string (should-error (harness-record-audio))))))
    (harness-voice-live-mute)
    (should (harness-voice--recording-p))
    (harness-voice-live-mute)))

;;;; Copy and controls

(ert-deftest harness-ui-voice-live-status-and-controls-copy ()
  "Every live state, control and tooltip has exact copy."
  (harness-ui-voice-live-test-with
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 500))
              ((symbol-function 'harness-compose--room)
               (lambda () (* 500 (frame-char-width)))))
      (cl-letf (((symbol-function 'harness-voice-live--active-p) (lambda () nil)))
        (setq harness-voice-live--state nil)
        (should (equal "Live · Off" (harness-voice-live--status)))
        (should (equal " Live · Off · [Start] · [Transcript] · [Setup]"
                       (substring-no-properties (harness-voice-live--controls))))
        (setq harness-voice-live--state 'failed
              harness-voice-live--error "Live voice failed · sidecar error")
        (should (equal "Live · Failed" (harness-voice-live--status)))
        (should (equal (concat " Live · Failed · [Start] · Live voice failed · sidecar error"
                               " · [Transcript] · [Setup]")
                       (substring-no-properties (harness-voice-live--controls)))))
      (cl-letf (((symbol-function 'harness-voice-live--active-p) (lambda () t)))
        (pcase-dolist (`(,state ,working ,muted ,copy)
                       '((listening nil nil "Live · Listening")
                         (speaking nil nil "Live · Speaking")
                         (listening t nil "Live · Working")
                         (listening nil t "Live · Muted")
                         (interrupted nil nil "Live · Interrupted")
                         (starting nil nil "Live · Starting")
                         (ending nil nil "Live · Ending")))
          (setq harness-voice-live--state state
                harness-voice-live--working working
                harness-voice-live--muted muted
                harness-voice-live--error nil)
          (should (equal copy (harness-voice-live--status))))
        (setq harness-voice-live--state 'listening
              harness-voice-live--working nil
              harness-voice-live--muted nil)
        (let* ((line (harness-voice-live--controls))
               (lines (split-string (substring-no-properties line) "\n")))
          (should (equal (concat " Live · Listening · [End] · [Interrupt C-c V] · [Mute C-c v]"
                                 " · [Transcript] · [Setup]")
                         (nth 0 lines)))
          (should (equal " Pipeline · ···· Level · no data · Speaker · silent"
                         (nth 1 lines)))
          (should (equal 2 (length lines)))
          (setq harness-voice-live--stage 'holding)
          (should (equal "Live · Holding reply" (harness-voice-live--status)))
          (should (equal (concat " Live · Holding reply · [End] · [Interrupt C-c V]"
                                 " · [Mute C-c v] · [Transcript] · [Setup]")
                         (nth 0 (split-string (substring-no-properties
                                               (harness-voice-live--controls))
                                              "\n"))))
          (setq harness-voice-live--stage 'listening)
          (dolist (spec '(("[End]" "Live session · end")
                          ("[Interrupt C-c V]" "Playback · interruption")
                          ("[Mute C-c v]" "Microphone · live session")
                          ("[Transcript]" "Live transcript")
                          ("[Setup]" "Voice settings")))
            (let ((at (string-search (car spec) line)))
              (should at)
              (should (equal (get-text-property at 'help-echo line) (cadr spec))))))
        (setq harness-voice-live--working t)
        (should (equal (concat " Live · Working · [End] · [Interrupt C-c V] · [Cancel work]"
                               " · [Mute C-c v] · [Transcript] · [Setup]")
                       (nth 0 (harness-ui-voice-live-test--control-lines))))
        (setq harness-voice-live--muted t)
        (should (equal (concat " Live · Working · [End] · [Interrupt C-c V] · [Cancel work]"
                               " · [Unmute C-c v] · [Transcript] · [Setup]")
                       (nth 0 (harness-ui-voice-live-test--control-lines))))
        (should (equal " Pipeline · ···· Level · no data · Speaker · silent"
                       (nth 1 (harness-ui-voice-live-test--control-lines))))
        (setq harness-voice-live--working nil harness-voice-live--muted nil)
        (should (equal (concat " Live · Listening · [End] · [Interrupt C-c V] · [Mute C-c v]"
                               " · [Transcript] · [Setup]")
                       (nth 0 (harness-ui-voice-live-test--control-lines))))))))

(ert-deftest harness-ui-voice-live-validation-copy ()
  "A missing command or executable is a visible, exact failure."
  (harness-ui-voice-live-test-with
    (setq harness-voice-live-command nil)
    (should (equal "Voice provider unconfigured · Custom sidecar"
                   (error-message-string (should-error (harness-voice-live-start)))))
    (should-not harness-voice-live--process)
    (setq harness-voice-live-command '("harness-no-such-executable"))
    (should (equal "Voice executable unavailable · harness-no-such-executable"
                   (error-message-string (should-error (harness-voice-live-start)))))
    (should-not harness-voice-live--process)))

(ert-deftest harness-ui-voice-live-start-control-shows-a-preflight-failure ()
  "The Start control redraws with the failure that kept the sidecar down.
The local pipeline builds its command before the sidecar has a buffer,
which used to leave the line reading Off after a rejected Start."
  (harness-ui-voice-live-test-with
    (setq harness-voice-provider 'unmute)
    (setq-local harness-compose-controls-functions (list #'harness-voice--controls))
    (harness-ui-voice-live-test--draw)
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 500))
              ((symbol-function 'harness-compose--room)
               (lambda () (* 500 (frame-char-width))))
              ((symbol-function 'harness-voice-unmute--pipeline-url)
               (lambda (&rest _) nil))
              ((symbol-function 'harness-voice-pipeline-reason)
               (lambda () "Local voice pipeline · stopped")))
      (should (string-search "Live · Off"
                             (buffer-substring-no-properties (point-min) (point-max))))
      (harness-voice-live--start-here)
      (should (eq harness-voice-live--state 'failed))
      (should (equal "Local voice pipeline · stopped"
                     harness-voice-live--error))
      (should (equal (concat " Live · Failed · [Start] · Local voice pipeline"
                             " · stopped · [Transcript] · [Setup]")
                     (substring-no-properties (harness-voice-live--controls))))
      (should (string-search "Live · Failed"
                             (buffer-substring-no-properties (point-min) (point-max))))
      (should-not harness-voice-live--process))))

;;;; Delegation

(ert-deftest harness-ui-voice-live-delegation-round-trip ()
  "A delegation becomes a session prompt; the reply returns to the sidecar."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "delegate"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () harness-ui-voice-live-test--calls) 5 "delegation prompt")
    (let* ((call (car harness-ui-voice-live-test--calls))
           (params (nth 2 call))
           (prompt (plist-get (car (plist-get params :prompt)) :text)))
      (should (equal "live-session" (car call)))
      (should (equal "session/prompt" (cadr call)))
      ;; No related-session lookup and no per-message context block: the
      ;; session a voice request is made in is the context.
      (should (equal "Add a docstring to parse." prompt))
      (should-not (string-search "Voice request context" prompt))
      (should-not (string-search "Related sessions" prompt)))
    (harness-voice--on-event "agent/turn-started" '("live-session"))
    (harness-ui-voice-live-test--chunk "The docstring is ready. ")
    (let ((commentary
           (harness-ui-voice-live-test--wait-event harness-ui-voice-live-test--inbox
                                                    "commentary")))
      (should (equal "The docstring is ready." (plist-get commentary :text))))
    (harness-voice--on-event "agent/turn-ended" '("live-session" "end-turn"))
    (let ((result
           (harness-ui-voice-live-test--wait-event harness-ui-voice-live-test--inbox
                                                    "delegate_result")))
      (should (equal "d-1" (plist-get result :id)))
      (should (equal "The docstring is ready. " (plist-get result :text))))
    (should-not harness-voice-live--working)
    (should-not harness-voice-live--delegation)))

(ert-deftest harness-ui-voice-live-queues-delegations ()
  "A second delegation waits for the turn in flight."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (harness-voice-live--handle (list :event "delegation" :id "d-1" :text "First."))
    (harness-voice-live--handle (list :event "delegation" :id "d-2" :text "Second."))
    (should (= 1 (length harness-ui-voice-live-test--calls)))
    (harness-voice-live--finish-turn "end-turn")
    (should (= 2 (length harness-ui-voice-live-test--calls)))
    (let* ((params (nth 2 (car harness-ui-voice-live-test--calls)))
           (prompt (plist-get (car (plist-get params :prompt)) :text)))
      (should (string-search "Second." prompt)))))

(ert-deftest harness-ui-voice-live-distils-a-delegation ()
  "A mumbly transcript reaches the session as its request, without its noise."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (let ((raw "Uh, add a docstring, um, to the the parser."))
      (harness-voice-live--handle
       (list :event "user_delta" :text raw :final t :utterance 1))
      (harness-voice-live--handle
       (list :event "delegation" :id "d-mumble" :utterance 1 :text raw))
      (let ((prompt (harness-ui-voice-live-test--latest-prompt)))
        (should (string-search "add a docstring to the parser." prompt))
        (should-not (string-search "Uh," prompt))
        (should-not (string-search "um," prompt)))
      (let ((turns (harness-voice-conversation-turns
                    harness-voice-live--conversation)))
        (should (= 1 (length turns)))
        (should (equal raw (plist-get (car turns) :raw)))
        (should (equal "add a docstring to the parser."
                       (plist-get (car turns) :text)))
        (should (equal "add a docstring to the parser."
                       (plist-get (car turns) :sent))))
      (let ((transcript (harness-ui-voice-live-test--transcript)))
        (should (string-search raw transcript))
        (should (string-search "Sent · " transcript))
        (should (string-search "add a docstring to the parser." transcript))))))

(ert-deftest harness-ui-voice-live-distillation-can-be-turned-off ()
  "The option sends the transcript as heard, while the record keeps both."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet")
          harness-voice-distill nil)
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (harness-voice-live--handle
     (list :event "delegation" :id "d-raw" :utterance 1
           :text "Uh, add a docstring, um, to the parser."))
    (should (string-search "Uh, add a docstring, um, to the parser."
                           (harness-ui-voice-live-test--latest-prompt)))
    (let ((transcript (harness-ui-voice-live-test--transcript)))
      (should-not (string-search "Sent ·" transcript)))))

(ert-deftest harness-ui-voice-live-noise-only-delegation-sends-nothing ()
  "A burst of mumbles is recorded, not forwarded, and its sidecar answered."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (harness-voice-live--handle
     (list :event "delegation" :id "d-noise" :utterance 1
           :text "Um, uh, hmm."))
    (should-not harness-ui-voice-live-test--calls)
    (let ((result (harness-ui-voice-live-test--wait-event
                   harness-ui-voice-live-test--inbox "delegate_result")))
      (should (equal "d-noise" (plist-get result :id)))
      (should (equal "" (plist-get result :text)))
      (should-not (plist-get result :error)))
    (let ((turns (harness-voice-conversation-turns
                  harness-voice-live--conversation)))
      (should (= 1 (length turns)))
      (should (equal "Um, uh, hmm." (plist-get (car turns) :raw)))
      (should-not (plist-get (car turns) :text)))
    (let ((segment (harness-voice-pipeline--segment
                    harness-voice-live--pipeline "u-1")))
      (should (eq 'dropped (plist-get segment :stage)))
      (should (eq 'no-request (plist-get segment :reason)))
      (should (equal "no request"
                     (harness-voice-pipeline--drop-label
                      (plist-get segment :reason)))))
    (let ((transcript (harness-ui-voice-live-test--transcript)))
      (should (string-search "Not sent · " transcript))
      (should (string-search "no request" transcript)))))

(ert-deftest harness-ui-voice-live-carries-voice-context-when-needed ()
  "A dependent request carries the voice's own earlier words; a plain one does not."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    ;; The provider's own speech, outside an agent turn: the session
    ;; never saw these words.
    (harness-voice-live--handle
     (list :event "assistant_delta" :final t
           :text "The timer wakes it every 200 ms."))
    (harness-voice-live--handle
     (list :event "delegation" :id "d-ctx" :utterance 1
           :text "Do that instead."))
    (let ((prompt (harness-ui-voice-live-test--latest-prompt)))
      (should (string-search "Do that instead." prompt))
      (should (string-search "Voice conversation before this request:" prompt))
      (should (string-search "Voice: The timer wakes it every 200 ms." prompt)))
    (harness-voice-live--finish-turn "end-turn")
    (harness-voice-live--handle
     (list :event "delegation" :id "d-plain" :utterance 2
           :text "Add a docstring to parse."))
    (let ((prompt (harness-ui-voice-live-test--latest-prompt)))
      (should (string-search "Add a docstring to parse." prompt))
      (should-not (string-search "Voice conversation before this request:"
                                 prompt)))))

(ert-deftest harness-ui-voice-live-conversation-ends-with-the-call ()
  "Ending the call forgets the voice conversation; the chat keeps its history."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (harness-voice-live--handle
     (list :event "delegation" :id "d-1" :utterance 1 :text "Add a test."))
    (should (harness-voice-conversation-turns
             harness-voice-live--conversation))
    (harness-voice-live-stop)
    (harness-test-wait (lambda () (null harness-voice-live--state))
                       5 "the call to end")
    (should-not (harness-voice-conversation-turns
                 harness-voice-live--conversation))))

(ert-deftest harness-ui-voice-live-announcement-only-reply-still-returns ()
  "A provider that only announces a final node still answers the delegation."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (harness-voice-live--handle (list :event "delegation" :id "d-2" :text "Announce it."))
    (harness-voice--on-event "agent/turn-started" '("live-session"))
    (harness-voice--on-update
     "live-session"
     (list :sessionUpdate "_harness/node"
           :node (list :id "n-announced" :kind "assistant"
                       :content "The parser now explains itself.")))
    (harness-voice--on-event "agent/turn-ended" '("live-session" "end-turn"))
    (let ((result
           (harness-ui-voice-live-test--wait-event harness-ui-voice-live-test--inbox
                                                    "delegate_result")))
      (should (equal "The parser now explains itself." (plist-get result :text))))))

;;;; Interruption and controls

(ert-deftest harness-ui-voice-live-interrupt-keeps-the-turn ()
  "Interrupt stops playback only; it never sends session/cancel."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (setq harness-voice-live--working t)
    (harness-voice-live-interrupt)
    (should (eq harness-voice-live--state 'interrupted))
    (should harness-voice-live--working)
    (should-not harness-ui-voice-live-test--notifications)
    (should (harness-ui-voice-live-test--wait-event
             harness-ui-voice-live-test--inbox "interrupt"))
    (harness-voice-live--handle (list :event "listening"))
    (should (equal "Live · Working" (harness-voice-live--status)))))

(ert-deftest harness-ui-voice-live-cancel-is-separate ()
  "Cancel work uses the ordinary session cancellation, not playback."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (harness-voice-live-cancel)
    (should (equal '(("session/cancel" (:sessionId "live-session")))
                   harness-ui-voice-live-test--notifications))
    (should-not (cl-find "interrupt"
                         (harness-ui-voice-live-test--events
                          harness-ui-voice-live-test--inbox)
                         :key (lambda (e) (plist-get e :event)) :test #'equal))
    (should (eq harness-voice-live--state 'listening))))

(ert-deftest harness-ui-voice-live-mute-sends-both-states ()
  "Muting and unmuting are explicit protocol booleans."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (should (harness-ui-voice-live-test--wait-event
             harness-ui-voice-live-test--inbox "start"))
    (harness-voice-live-mute)
    (should harness-voice-live--muted)
    (should (equal "Live · Muted" (harness-voice-live--status)))
    (should (eq 'muted harness-voice-live--stage))
    (harness-test-wait
     (lambda () (string-search "\"on\":false"
                               (harness-ui-voice-live-test--file-text
                                harness-ui-voice-live-test--inbox)))
     5 "the mute event")
    (harness-voice-live-mute)
    (should-not harness-voice-live--muted)
    (should (equal "Live · Listening" (harness-voice-live--status)))
    (should (eq 'listening harness-voice-live--stage))
    (harness-test-wait
     (lambda () (string-search "\"on\":true"
                               (harness-ui-voice-live-test--file-text
                                harness-ui-voice-live-test--inbox)))
     5 "the unmute event")))

;;;; Failures

(ert-deftest harness-ui-voice-live-sidecar-error-is-visible ()
  "A sidecar error is exact, visible and ends the process."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "error"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'failed)) 5 "sidecar error")
    (should (equal "Live voice failed · no key" harness-voice-live--error))
    (should (equal "Live · Failed" (harness-voice-live--status)))
    (should (string-prefix-p "✕ Failed" (harness-voice-live--stage-text)))
    (should-not (harness-voice-live--active-p))))

(ert-deftest harness-ui-voice-live-startup-timeout ()
  "A silent sidecar cannot leave the UI starting forever."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "silent")
          harness-voice-live-startup-timeout 0.2)
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'failed)) 5 "startup timeout")
    (should (equal "Live voice startup timeout" harness-voice-live--error))
    (should-not (harness-voice-live--active-p))))

(ert-deftest harness-ui-voice-live-unexpected-exit-and-bad-json ()
  "An exit without closed, and a line that is not JSON, both fail visibly."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "exit"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'failed)) 5 "sidecar exit")
    (should (string-prefix-p "Live voice ended" harness-voice-live--error))
    (should-not (harness-voice-live--active-p))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "bad"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'failed)) 5 "protocol error")
    (should (equal "Live voice protocol error" harness-voice-live--error))
    (should-not (harness-voice-live--active-p))))

;;;; Captions and speech

(ert-deftest harness-ui-voice-live-transcript-header ()
  "The transcript header keeps the stage and the provider in view."
  (harness-ui-voice-live-test-with
    (setq harness-voice-provider 'fixture)
    (harness-voice-live--transcript-buffer)
    (harness-voice-live--stage-set 'thinking)
    (setq harness-voice-live--stage-since (- (float-time) 1.2))
    (with-current-buffer harness-voice-live--transcript
      ;; `format-mode-line' needs a frame, which batch tests lack; the
      ;; header is one `:eval' form, so evaluate it as a window would.
      (let ((line (eval (cadr header-line-format) t)))
        (should (string-search "Working" line))
        (should (string-search "1.2s" line))
        (should (string-search "Scripted fixture" line))))))

(ert-deftest harness-ui-voice-live-transcript-and-backchannels ()
  "User and agent deltas become the live transcript; tooltips stay clean."
  (harness-ui-voice-live-test-with
    (harness-voice-live--handle (list :event "user_delta" :text "Hello" :final t))
    (harness-voice-live--handle (list :event "assistant_delta" :text "Ready." :final t))
    (harness-voice-live--handle (list :event "backchannel" :text "mm-hmm"))
    (let ((text (harness-ui-voice-live-test--transcript)))
      (should (string-prefix-p "Pipeline\n" text))
      (should (string-search "─" text))
      (should (string-search "You · " text))
      (should (string-search "  Hello" text))
      (should (string-search "Voice · " text))
      (should (string-search "  Ready." text))
      (should (string-search "mm-hmm" text)))
    (harness-voice-live-transcript)
    (should (eq (current-buffer) harness-voice-live--transcript))
    (should (derived-mode-p 'harness-voice-live-transcript-mode))))

(ert-deftest harness-ui-voice-live-stage-line-follows-the-session ()
  "The transcript stage line names every stage the session is in."
  (harness-ui-voice-live-test-with
    (harness-voice-live--transcript-buffer)
    (should-not (harness-voice-live--stage-text))
    (harness-voice-live--handle (list :event "hearing"))
    (should (string-search "Hearing you" (harness-voice-live--stage-text)))
    (harness-voice-live--handle (list :event "transcribing"))
    (should (string-search "Transcribing" (harness-voice-live--stage-text)))
    (harness-voice-live--handle (list :event "delegation" :id "d-9" :text "Do it."))
    (should (string-search "Working" (harness-voice-live--stage-text)))
    (setq harness-voice-live--stage-since (- (float-time) 1.4))
    (harness-voice-live--stage-redraw)
    (should (string-search "1.4s" (harness-voice-live--status)))
    (should (string-search "1.4s" (harness-voice-live--stage-text)))
    (harness-voice-live--handle (list :event "speaking"))
    (should (string-search "Speaking" (harness-voice-live--stage-text)))
    (harness-voice-live--handle (list :event "interrupted"))
    (should (string-search "Listening" (harness-voice-live--stage-text)))))

(ert-deftest harness-ui-voice-live-stage-indicators ()
  "Waiting animates, and each idle stage has its own mark."
  (harness-ui-voice-live-test-with
    (harness-voice-live--transcript-buffer)
    (dolist (case '((hearing . "⠋") (transcribing . "⠋") (thinking . "⠋")))
      (harness-voice-live--stage-set (car case))
      (should (string-prefix-p (cdr case) (harness-voice-live--stage-text)))
      (should (timerp harness-voice-live--stage-timer)))
    (harness-voice-live--stage-set 'speaking)
    (should (string-prefix-p "▷" (harness-voice-live--stage-text)))
    (should-not (timerp harness-voice-live--stage-timer))
    (should-not (string-search "·" (harness-voice-live--stage-text)))
    (harness-voice-live--stage-set 'listening)
    (should (string-prefix-p "●" (harness-voice-live--stage-text)))
    (harness-voice-live--stage-set 'holding)
    (should (string-prefix-p "‖" (harness-voice-live--stage-text)))
    (harness-voice-live--stage-set 'muted)
    (should (string-prefix-p "⊘" (harness-voice-live--stage-text)))
    (harness-voice-live--stage-set 'failed)
    (should (string-prefix-p "✕" (harness-voice-live--stage-text)))
    (harness-voice-live--stage-set nil)
    (should-not (harness-voice-live--stage-text))))

(ert-deftest harness-ui-voice-live-commentary-skips-code ()
  "Streamed commentary keeps prose and drops fenced code."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (let ((harness-voice-live--nodes (make-hash-table :test 'equal))
          (harness-voice-live--order nil))
      (harness-voice-live--add-chunk "n-code" "Before.\n")
      (harness-voice-live--add-chunk "n-code" "```python\nsecret = 1\n```\nAfter.")
      (harness-voice-live--drain-node "n-code" t))
    (harness-test-wait
     (lambda ()
       (equal '("Before." "After.")
              (mapcar (lambda (e) (plist-get e :text))
                      (cl-remove-if-not (lambda (e) (equal (plist-get e :event) "commentary"))
                                        (harness-ui-voice-live-test--events
                                         harness-ui-voice-live-test--inbox)))))
     5 "the speakable commentary")
    (should-not (string-search "secret" (harness-ui-voice-live-test--file-text
                                         harness-ui-voice-live-test--inbox)))))

;;;; Speech gating

(ert-deftest harness-ui-voice-live-holds-output-before-transcript ()
  "Speech holds assistant text; the transcript carries it once as context."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (harness-voice-live--handle (list :event "delegation" :id "d-1"
                                      :text "Do the work." :utterance 1))
    (harness-voice--on-event "agent/turn-started" '("live-session"))
    (harness-voice-live--handle (list :event "speech" :active t :utterance 2))
    (harness-ui-voice-live-test--chunk "The parser is ready. " "n-1")
    (should (eq harness-voice-live--stage 'holding))
    (should (equal "Live · Holding reply" (harness-voice-live--status)))
    (should harness-voice-live--held)
    (should-not (cl-find "commentary"
                         (harness-ui-voice-live-test--events
                          harness-ui-voice-live-test--inbox)
                         :key (lambda (e) (plist-get e :event)) :test #'equal))
    (harness-voice-live--handle (list :event "speech" :active nil :utterance 2))
    (harness-voice--on-event "agent/turn-ended" '("live-session" "end-turn"))
    (harness-voice-live--handle
     (list :event "delegation" :id "d-2" :utterance 2
           :text "Wait, also check the tests."
           :pending (list (list :id "sidecar-1" :text "The sidecar held this."))))
    (should (= 2 (length harness-ui-voice-live-test--calls)))
    (let ((prompt (harness-ui-voice-live-test--latest-prompt)))
      (should (string-search "Wait, also check the tests." prompt))
      (should (string-search "<voice-turn-context>" prompt))
      (should (string-search "The parser is ready." prompt))
      (should (string-search "The sidecar held this." prompt))
      (should (= 1 (harness-ui-voice-live-test--occurrences "The parser is ready." prompt)))
      (should (= 1 (harness-ui-voice-live-test--occurrences "The sidecar held this." prompt))))
    ;; The same utterance arriving twice is not a second prompt.
    (harness-voice-live--handle
     (list :event "delegation" :id "d-2" :utterance 2
           :text "Wait, also check the tests."))
    (should (= 2 (length harness-ui-voice-live-test--calls)))
    ;; A new turn's text is released normally.
    (harness-voice--on-event "agent/turn-ended" '("live-session" "end-turn"))
    (harness-voice--on-event "agent/turn-started" '("live-session"))
    (harness-ui-voice-live-test--chunk "The tests pass. " "n-2")
    (harness-test-wait
     (lambda ()
       (cl-find "commentary"
                (harness-ui-voice-live-test--events
                 harness-ui-voice-live-test--inbox)
                :key (lambda (e) (plist-get e :event)) :test #'equal))
     3 "the released commentary")
    (let ((commentary
           (cl-find "commentary"
                    (harness-ui-voice-live-test--events
                     harness-ui-voice-live-test--inbox)
                    :key (lambda (e) (plist-get e :event)) :test #'equal)))
      (should (equal "The tests pass." (plist-get commentary :text))))))

(ert-deftest harness-ui-voice-live-false-trigger-releases-held-output ()
  "A tap that never becomes words does not hold a reply forever."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (harness-voice-live--handle (list :event "speech" :active t :utterance 1))
    (harness-voice-live--hold "n-1:0" "Still useful.")
    (harness-voice-live--handle (list :event "speech" :active nil :utterance 1))
    (harness-voice-live--handle (list :event "listening" :utterance 1))
    (harness-test-wait
     (lambda ()
       (cl-find "commentary"
                (harness-ui-voice-live-test--events
                 harness-ui-voice-live-test--inbox)
                :key (lambda (e) (plist-get e :event)) :test #'equal))
     3 "the false-trigger release")
    (should-not harness-voice-live--held)))

(ert-deftest harness-ui-voice-live-interrupt-clears-held-output ()
  "An explicit interrupt drops held text; speech still owns the gate."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (harness-voice-live--handle (list :event "speech" :active t :utterance 1))
    (harness-voice-live--hold "n-1:0" "Never mind.")
    (harness-voice-live-interrupt)
    (should-not harness-voice-live--held)
    (should harness-voice-live--speech-active)
    (harness-voice-live--handle (list :event "speech" :active nil :utterance 1))
    (should-not harness-voice-live--speech-active)))

(ert-deftest harness-ui-voice-live-reset-clears-the-gate ()
  "Redaction or a reconnect cannot leave a stale speech gate or held text."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (harness-voice-live--handle (list :event "speech" :active t :utterance 1))
    (harness-voice-live--hold "n-1:0" "Held.")
    (harness-voice-live--handle (list :event "speech" :active nil :utterance 1))
    (harness-voice-live--handle (list :event "listening"))
    (should (timerp harness-voice-live--held-timer))
    (harness-voice-live--reset)
    (should-not harness-voice-live--speech-active)
    (should-not harness-voice-live--held)
    (should-not (timerp harness-voice-live--held-timer))
    (should (= 0 (hash-table-count harness-voice-live--seen)))))

;;;; Redaction

(ert-deftest harness-ui-voice-live-redaction-ends-and-forgets ()
  "Session redaction stops the sidecar and removes the transcript."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (harness-voice-live--handle (list :event "user_delta" :text "private words" :final t))
    (should (string-search "private words" (harness-ui-voice-live-test--transcript)))
    (harness-voice--on-event "session/redacted" '("live-session"))
    (should-not (harness-voice-live--active-p))
    (should-not (buffer-live-p harness-voice-live--transcript))
    (should-not harness-voice-live--state)
    (should-not (get-buffer "*harness voice*"))))

;;;; The pipeline

(defun harness-ui-voice-live-test--pipeline ()
  "Return the live pipeline model."
  harness-voice-live--pipeline)

(defun harness-ui-voice-live-test--strip ()
  "Return the transcript's pipeline block as plain text."
  (harness-voice-live--transcript-buffer)
  (with-current-buffer harness-voice-live--transcript
    (harness-voice-live--pipeline-draw)
    (substring-no-properties
     (buffer-substring-no-properties (point-min)
                                     (marker-position harness-voice-live--pipeline-end)))))

(ert-deftest harness-ui-voice-live-pipeline-follows-the-sidecar ()
  "The sidecar's levels and segments reach the strip, in their own words."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "pipeline"))
    (harness-voice-live-start)
    (harness-test-wait
     (lambda () (equal 1 (harness-voice-pipeline-dropped
                          (harness-ui-voice-live-test--pipeline))))
     5 "the dropped segment")
    (let ((pipeline (harness-ui-voice-live-test--pipeline)))
      (should (equal 1 (harness-voice-pipeline-accepted pipeline)))
      (should (equal 1 (harness-voice-pipeline-dropped pipeline)))
      (should (equal 'transcribed
                     (plist-get (harness-voice-pipeline--segment pipeline "u-1") :stage)))
      (should (equal 'dropped
                     (plist-get (harness-voice-pipeline--segment pipeline "u-2") :stage)))
      (should (equal 'too-short
                     (plist-get (harness-voice-pipeline--segment pipeline "u-2") :reason)))
      (should (harness-voice-pipeline-level-seen pipeline)))
    (let ((strip (harness-ui-voice-live-test--strip)))
      (dolist (word '("Pipeline" "Input" "Filter" "Words" "Turn" "Speaker"
                      "Mic · live" "1 accepted" "1 dropped" "≡ transcribed"))
        (should (string-search word strip)))
      (should (string-search "Level · " strip)))))

(ert-deftest harness-ui-voice-live-pipeline-details-and-motion ()
  "The details toggle lists every marker; motion off keeps every fact."
  (harness-ui-voice-live-test-with
    (let ((pipeline (harness-ui-voice-live-test--pipeline)))
      (harness-voice-live--pipeline-bump 'live)
      (harness-voice-live--pipeline-segment
       (list :event "segment" :state "accepted" :id "u-1" :seconds 1.4))
      (harness-voice-live--pipeline-segment
       (list :event "segment" :state "dropped" :id "u-2" :seconds 0.08
             :reason "too short"))
      (harness-voice-live--pipeline-turn-sent "d-1")
      (let ((strip (harness-ui-voice-live-test--strip)))
        (should (string-search "[Pipeline details]" strip))
        (should-not (string-search "u-2 · dropped" strip)))
      (with-current-buffer harness-voice-live--transcript
        (harness-voice-live-pipeline-details))
      (let ((strip (harness-ui-voice-live-test--strip)))
        (should (string-search "[Hide details]" strip))
        (should (string-search "Pipeline details" strip))
        (should (string-search "u-2 · dropped · 80ms · too short" strip))
        (should (string-search "d-1 · working" strip)))
      (should (equal 'too-short
                     (plist-get (harness-voice-pipeline--segment pipeline "u-2") :reason))))
    ;; The busy stage's spinner is motion; with it off the stage still
    ;; says what it is.
    (harness-voice-live--transcript-buffer)
    (let ((harness-voice-live-motion nil))
      (harness-voice-live--stage-set 'hearing)
      (should (equal "● Hearing you" (harness-voice-live--stage-text))))
    (let ((harness-voice-live-motion t))
      (harness-voice-live--stage-set 'transcribing)
      (should (eq ?⠋ (aref (harness-voice-live--stage-text) 0))))))

(ert-deftest harness-ui-voice-live-pipeline-mute-and-end ()
  "Mute and end close the meter, and keep the markers that really happened."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "pipeline"))
    (harness-voice-live-start)
    (harness-test-wait
     (lambda () (>= (harness-voice-pipeline-accepted
                     (harness-ui-voice-live-test--pipeline))
                    1))
     5 "the kept segment")
    (harness-voice-live-mute)
    (should (eq 'muted (harness-voice-pipeline-capture
                        (harness-ui-voice-live-test--pipeline))))
    (should (equal "Level · no data"
                   (harness-voice-pipeline-level-label
                    (harness-ui-voice-live-test--pipeline))))
    (should (string-search "Mic · muted" (harness-ui-voice-live-test--strip)))
    (harness-voice-live-stop)
    (should (eq 'ended (harness-voice-pipeline-capture
                        (harness-ui-voice-live-test--pipeline))))
    (let ((strip (harness-ui-voice-live-test--strip)))
      (should (string-search "Mic · ended" strip))
      ;; The bursts stay as the last true picture of the session.
      (should (string-search "1 accepted" strip)))))

(ert-deftest harness-ui-voice-live-pipeline-handoff-is-not-playback ()
  "Commentary handed to the sidecar is handed; speaking needs its event."
  (harness-ui-voice-live-test-with
    (harness-voice-live--pipeline-bump 'live)
    (let ((pipeline (harness-ui-voice-live-test--pipeline)))
      (harness-voice-live--pipeline-reply-ready "n-1" "The docstring is in place.")
      (should (equal "Speaker · ready" (harness-voice-pipeline-speaker-label pipeline)))
      (harness-voice-live--pipeline-reply-handed "n-1:0")
      (should (equal "Speaker · handed" (harness-voice-pipeline-speaker-label pipeline)))
      ;; Text generation finishing is not speaking.
      (harness-voice-live--pipeline-playback 'listening)
      (should (equal "Speaker · handed" (harness-voice-pipeline-speaker-label pipeline)))
      (harness-voice-live--pipeline-playback 'speaking)
      (should (equal "Speaker · speaking" (harness-voice-pipeline-speaker-label pipeline)))
      (harness-voice-live--pipeline-playback 'listening)
      (should (equal "Speaker · silent" (harness-voice-pipeline-speaker-label pipeline))))))

(ert-deftest harness-ui-voice-live-pipeline-held-then-released ()
  "Held output is held, not spoken, and is handed when it is released."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (setq harness-voice-live--speech-active t)
    (harness-voice-live--speak "A held sentence." "n-2:0")
    (should (equal "Speaker · held" (harness-voice-pipeline-speaker-label
                                     (harness-ui-voice-live-test--pipeline))))
    (setq harness-voice-live--speech-active nil)
    (harness-voice-live--release-held)
    (should (equal "Speaker · handed" (harness-voice-pipeline-speaker-label
                                       (harness-ui-voice-live-test--pipeline))))))

;;;; The shipped fixture and entry points

(ert-deftest harness-ui-voice-live-shipped-fixture-demo ()
  "The bundled fixture drives a whole delegation and caption round trip."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (list "python3" "-u" harness-ui-voice-live-test--fixture "--demo"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () harness-ui-voice-live-test--calls) 5 "fixture delegation")
    (let* ((params (nth 2 (car harness-ui-voice-live-test--calls)))
           (prompt (plist-get (car (plist-get params :prompt)) :text)))
      (should (string-search "Add a docstring to the parse function" prompt)))
    (harness-voice--on-event "agent/turn-started" '("live-session"))
    (harness-voice--on-event "agent/turn-ended" '("live-session" "end-turn"))
    (harness-test-wait
     (lambda () (string-search "The docstring is in place."
                               (harness-ui-voice-live-test--transcript)))
     5 "the fixture's closing caption")
    (should (equal "Live · Listening" (harness-voice-live--status)))))

(ert-deftest harness-ui-voice-live-entry-points-start-and-mute ()
  "The voice entry point starts live, and dictate toggles its microphone."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "entry point")
    (should harness-voice-mode)
    (harness-voice-dictate)
    (should harness-voice-live--muted)
    (should (equal "Live · Muted" (harness-voice-live--status)))
    (harness-voice-dictate)
    (should-not harness-voice-live--muted)
    (harness-voice-toggle)
    (harness-test-wait (lambda () (null harness-voice-live--state)) 5 "toggle off")
    (should-not (harness-voice-live--active-p))))

(ert-deftest harness-ui-voice-live-pending-keeps-the-full-result ()
  "A held sentence and the full result that contains it are one context line."
  (let ((harness-voice-live--held
         (list (list :id "piece" :text "The parser is ready.")
               (list :id "result:d" :text "The parser is ready. Tests pass.")))
        (harness-voice-live--held-timer nil))
    (let* ((items (harness-voice-live--pending-items (list :pending nil)))
           (context (harness-voice-live--pending-context items)))
      (should (= 1 (length items)))
      (should (equal "The parser is ready. Tests pass."
                     (plist-get (car items) :text)))
      (should (= 1 (cl-count-if (lambda (line) (string-prefix-p "- " line))
                                (split-string context "\n"))))
      (should (string-search "Tests pass." context)))))

(provide 'harness-ui-voice-live-test)
;;; harness-ui-voice-live-test.el ends here
