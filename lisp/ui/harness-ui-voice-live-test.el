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
(defvar harness-ui-voice-live-test--sends nil
  "Other requests sent, as (METHOD PARAMS) pairs, oldest first.")
(defvar harness-ui-voice-live-test--notifications nil)
(defvar harness-ui-voice-live-test--inbox nil)

(defun harness-ui-voice-live-test--box (session &optional thread workspace)
  "Make a compose box of SESSION, on THREAD of WORKSPACE when given.
It is a real compose host in a buffer of its own, which is what a second
chat or a workspace looks like to the live transport."
  (let ((buffer (generate-new-buffer (format " *live voice %s*" session))))
    (with-current-buffer buffer
      (setq-local harness-ui-session-id session)
      (setq-local default-directory default-directory)
      (use-local-map harness-compose-map)
      (harness-compose-setup :project (lambda () default-directory)
                             :redraw #'ignore)
      (when workspace
        (setq-local harness-ui-workspace--id workspace)
        (setq-local harness-ui-workspace--thread thread))
      ;; A compose box exists only once it was drawn: its markers are
      ;; what `harness-compose-live-p' reads.
      (let ((inhibit-read-only t))
        (insert (propertize "Transcript\n" 'read-only t))
        (harness-compose-insert))
      (harness-compose-capture))
    buffer))

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
           (harness-voice-live--notice nil)
           (harness-voice-live--muted nil) (harness-voice-live--working nil)
           (harness-voice-live--turn-active nil) (harness-voice-live--closing nil)
           (harness-voice-live--delegation nil) (harness-voice-live--delegations nil)
           (harness-voice-live--nodes nil) (harness-voice-live--order nil)
           (harness-voice-live--heard "") (harness-voice-live--transcript nil)
           (harness-voice-live--conversation (harness-voice-conversation-create))
           (harness-voice-live--speech-active nil)
           (harness-voice-live--held nil)
           (harness-voice-live--held-timer nil) (harness-voice-live--held-token 0)
           (harness-voice-live--turn-id nil)
           (harness-voice-live--seen (make-hash-table :test 'equal))
           (harness-voice-live--held-seq 0)
           (harness-voice-live--pending nil) (harness-voice-live--pending-timer nil)
           (harness-voice-live--pending-token 0) (harness-voice-live--turn-held nil)
           (harness-voice-live--input-chunks nil) (harness-voice-live--input-seq 0)
           (harness-voice-live--input-anonymous nil)
           (harness-voice-live--caption-hold nil) (harness-voice-live--caption-text "")
           (harness-voice-live--caption-hold-order 0) (harness-voice-live--caption-recovery nil)
           (harness-voice-live--utterance-routes nil)
           ;; Existing transport tests cross the real grace boundary with
           ;; explicit waits.  Deterministic safety tests below use 1.2s.
           (harness-voice-live-turn-grace 0.03)
           (harness-voice-live-pending-release-delay 0.15)
           (harness-voice-conversation-turns 40)
           (harness-voice-live-follow-selection nil)
           (harness-voice-live--route-kind 'session)
           (harness-voice-live--route-workspace nil)
           (harness-voice-live--route-thread nil)
           (harness-voice-live--route-name nil)
           (harness-voice-live--route-generation 0)
           (harness-voice-live--pipeline-timer nil)
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
           (harness-ui-voice-live-test--sends nil)
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
                            nil))
                         ((symbol-function 'harness-ui-call)
                          (lambda (method params _callback &optional _on-error)
                            (setq harness-ui-voice-live-test--sends
                                  (nconc harness-ui-voice-live-test--sends
                                         (list (list method params))))
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

(defun harness-ui-voice-live-test--delegate-after-grace (event)
  "Deliver EVENT, verifying no immediate prompt, then cross real ordinary grace.
Transport tests use this explicitly where their old assertion assumed an
instant send.  Indefinite holds belong in the deterministic tests below."
  (let ((before (length harness-ui-voice-live-test--calls)))
    (harness-voice-live--handle event)
    (when harness-voice-live--pending
      (should (eq 'grace (harness-voice-live--pending-reason)))
      (should (= before (length harness-ui-voice-live-test--calls)))
      (harness-test-wait (lambda () (null harness-voice-live--pending))
                         5 "ordinary voice turn grace"))))

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
        (setq harness-voice-live--buffer (current-buffer)
              harness-voice-live--route-name "Routing test")
        (pcase-dolist (`(,state ,working ,muted ,copy)
                       '((listening nil nil "Live · Listening")
                         (speaking nil nil "Live · Speaking")
                         (listening t nil "Live · Working")
                         (listening nil t "Live · Muted")
                         (interrupted nil nil "Live · Interrupted")
                         (initializing nil nil "Live · Initializing")
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
      ;; The pipeline is stopped, so the call initializes it and says so
      ;; while it comes up, instead of failing before it tries.
      (should (eq harness-voice-live--state 'initializing))
      (should (equal "Live · Initializing" (harness-voice-live--status)))
      (should (string-search "Live · Initializing"
                             (buffer-substring-no-properties (point-min) (point-max))))
      (should-not harness-voice-live--process)
      ;; A pipeline that reports a failure fails the call at once, with
      ;; the harness's own reason, and offers Retry.
      (cl-letf (((symbol-function 'harness-voice-pipeline-state)
                 (lambda () 'failed))
                ((symbol-function 'harness-voice-pipeline-reason)
                 (lambda () "Local voice pipeline · failed · No answer in 120 s")))
        (harness-voice-live--pipeline-tick))
      (should (eq harness-voice-live--state 'failed))
      (should (equal "Local voice pipeline · failed · No answer in 120 s"
                     harness-voice-live--error))
      (should (equal (concat " Live · Failed · [Start] · Local voice pipeline"
                             " · failed · No answer in 120 s · [Transcript] · [Setup]")
                     (substring-no-properties (harness-voice-live--controls))))
      (should-not harness-voice-live--process))))

;;;; Routing

;; One live call, one authoritative target.  The person selects another
;; session or workspace and the next words go there, with the same
;; sidecar, the same microphone and the same speech services; and a
;; transcript or a reply captured for the old target never lands in the
;; new one.  These are the regressions for the reported failure: an
;; indicator that said B while the words went to A.

(defun harness-ui-voice-live-test--routing-copy ()
  "Return the compose box's live status and controls as one text."
  (substring-no-properties (harness-voice-live--controls)))

(ert-deftest harness-ui-voice-live-retargets-without-restarting ()
  "Selecting another box retargets the call; the sidecar keeps running."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (let* ((process harness-voice-live--process)
           (other (harness-ui-voice-live-test--box "session-b")))
      (unwind-protect
          (progn
            (should (harness-voice-live-retarget other))
            ;; The same process, still listening, still the same generation
            ;; of sidecar: nothing restarted.
            (should (eq process harness-voice-live--process))
            (should (harness-voice-live--active-p))
            (should (eq 'listening harness-voice-live--state))
            (should (equal "session-b" harness-voice-live--session))
            (should (eq other harness-voice-live--buffer))
            ;; The words go to B now.
           (harness-ui-voice-live-test--delegate-after-grace
             (list :event "delegation" :id "d-b" :text "Check the tests."))
            (should (equal "session-b" (car (car harness-ui-voice-live-test--calls))))
            (should (equal "Check the tests."
                           (harness-ui-voice-live-test--latest-prompt)))
            ;; Selecting the same box again moves nothing.
            (let ((generation harness-voice-live--route-generation))
              (should-not (harness-voice-live-retarget other))
              (should (= generation harness-voice-live--route-generation))))
        (when (buffer-live-p other) (kill-buffer other))))))

(ert-deftest harness-ui-voice-live-switch-during-capture-keeps-the-target ()
  "An utterance captured before a switch goes to the target it was said in.
The transcript arrives after the person selected B; A is where the
words were spoken, so A is where they go, and the sidecar is answered."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (let ((other (harness-ui-voice-live-test--box "session-b")))
      (unwind-protect
          (progn
            ;; A burst is open in A when the person switches.
            (harness-voice-live--handle
             (list :event "hearing" :utterance 1))
            (should (harness-voice-live-retarget other))
            ;; Its transcript and delegation belong to A.
            (harness-voice-live--handle
             (list :event "user_delta" :text "Add a docstring." :final t
                   :utterance 1))
           (harness-ui-voice-live-test--delegate-after-grace
             (list :event "delegation" :id "d-a" :utterance 1
                   :text "Add a docstring."))
            ;; Nothing went to B, and the sidecar was told why.
            (should-not (cl-find "session-b" harness-ui-voice-live-test--calls
                                 :key #'car :test #'equal))
            (let ((result (harness-ui-voice-live-test--wait-event
                           harness-ui-voice-live-test--inbox "delegate_result")))
              (should (equal "d-a" (plist-get result :id)))
              (should (equal "retargeted" (plist-get result :message))))
            ;; The next words go to B.
           (harness-ui-voice-live-test--delegate-after-grace
             (list :event "delegation" :id "d-b" :utterance 2
                   :text "Now check the tests."))
            (should (equal "session-b" (car (car harness-ui-voice-live-test--calls))))
            (should (equal "Now check the tests."
                           (harness-ui-voice-live-test--latest-prompt))))
        (when (buffer-live-p other) (kill-buffer other))))))

(ert-deftest harness-ui-voice-live-switch-during-a-turn-keeps-its-reply ()
  "A turn that outlives a switch is answered where it was sent.
Its reply is not spoken into the thread the person selected, and the
sidecar is told the turn ended without one."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
   (harness-ui-voice-live-test--delegate-after-grace (list :event "delegation" :id "d-a"
                                      :text "Do the work." :utterance 1))
    (harness-voice--on-event "agent/turn-started" '("live-session"))
    (should harness-voice-live--working)
    (let ((other (harness-ui-voice-live-test--box "session-b")))
      (unwind-protect
          (progn
            (should (harness-voice-live-retarget other))
            (harness-ui-voice-live-test--chunk "The parser is ready. " "n-1")
            (harness-voice--on-event "agent/turn-ended" '("live-session" "end-turn"))
            (let ((result (harness-ui-voice-live-test--wait-event
                           harness-ui-voice-live-test--inbox "delegate_result")))
              (should (equal "d-a" (plist-get result :id)))
              (should (equal "retargeted" (plist-get result :message)))
              ;; Nothing was spoken: the old thread's reply is not B's.
              (should-not (string-search "The parser is ready."
                                         (harness-ui-voice-live-test--file-text
                                          harness-ui-voice-live-test--inbox))))
            (should-not harness-voice-live--working)
            (should (eq 'listening harness-voice-live--stage)))
        (when (buffer-live-p other) (kill-buffer other))))))

(ert-deftest harness-ui-voice-live-switch-takes-the-utterance-that-follows ()
  "The utterance after a switch is not held back by the queued one.
A burst already queued for A is answered as retargeted, and the next
delegation goes to B without waiting for a turn that will not start."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    ;; A turn runs for A, with one utterance queued behind it.
   (harness-ui-voice-live-test--delegate-after-grace (list :event "delegation" :id "d-a1"
                                      :text "First." :utterance 1))
   (harness-ui-voice-live-test--delegate-after-grace (list :event "delegation" :id "d-a2"
                                      :text "Second." :utterance 2))
    (should (= 1 (length harness-ui-voice-live-test--calls)))
    (let ((other (harness-ui-voice-live-test--box "session-b")))
      (unwind-protect
          (progn
            (should (harness-voice-live-retarget other))
            ;; The queued one is dropped, and its sidecar answered.
            (should-not harness-voice-live--delegations)
            (should (equal "d-a2" (plist-get
                                   (harness-ui-voice-live-test--wait-event
                                    harness-ui-voice-live-test--inbox
                                    "delegate_result")
                                   :id)))
            (harness-voice--on-event "agent/turn-ended" '("live-session" "end-turn"))
           (harness-ui-voice-live-test--delegate-after-grace (list :event "delegation" :id "d-b"
                                              :text "Third." :utterance 3))
            (should (equal "session-b" (car (car harness-ui-voice-live-test--calls))))
            (should (equal "Third." (harness-ui-voice-live-test--latest-prompt))))
        (when (buffer-live-p other) (kill-buffer other))))))

(ert-deftest harness-ui-voice-live-repeated-switches-keep-one-target ()
  "Switching back and forth many times leaves one target and one call.
The generation moves once per real move, nothing leaks between the
sessions, and the sidecar is never restarted."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (let ((process harness-voice-live--process)
          (a (current-buffer))
          (b (harness-ui-voice-live-test--box "session-b")))
      (unwind-protect
          (progn
            (dotimes (_ 4)
              (should (harness-voice-live-retarget b))
              ;; The same box again is not a move.
              (should-not (harness-voice-live-retarget b))
              (should (harness-voice-live-retarget a))
              (should-not (harness-voice-live-retarget a)))
            (should (harness-voice-live-retarget b))
            (should (eq process harness-voice-live--process))
            (should (eq 1 (cl-count-if #'identity
                                       (list (harness-voice-live--active-p)))))
            (should (equal "session-b" harness-voice-live--session))
           (harness-ui-voice-live-test--delegate-after-grace (list :event "delegation" :id "d-last"
                                              :text "One target."))
            (should (equal "session-b" (car (car harness-ui-voice-live-test--calls))))
            (should (= 1 (length harness-ui-voice-live-test--calls))))
        (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest harness-ui-voice-live-non-target-box-names-the-target ()
  "A box that is not the target says where the words go, and offers Use here.
The reported bug was an indicator that read Listening in a session the
microphone did not go to."
  (harness-ui-voice-live-test-with
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 500))
              ((symbol-function 'harness-compose--room)
               (lambda () (* 500 (frame-char-width))))
              ((symbol-function 'harness-voice-live--active-p) (lambda () t)))
      (setq harness-voice-live--buffer (current-buffer)
            harness-voice-live--session "session-a"
            harness-voice-live--route-name "Session A"
            harness-voice-live--state 'listening
            harness-voice-live--stage 'listening)
      ;; The target's own box: no name, every control.
      (should (equal "Live · Listening" (harness-voice-live--status)))
      (should (equal (concat " Live · Listening · [End] · [Interrupt C-c V]"
                             " · [Mute C-c v] · [Transcript] · [Setup]")
                     (nth 0 (harness-ui-voice-live-test--control-lines))))
      (should (eq (current-buffer) harness-voice-live--buffer))
      ;; Another box: it names the target and offers to move there.
      (let ((target harness-voice-live--buffer)
            (other (harness-ui-voice-live-test--box "session-b")))
        (unwind-protect
            (with-current-buffer other
              (should-not (harness-voice-live--here-p))
              (should (equal "Live · Listening · Session A"
                             (harness-voice-live--status)))
              (should (equal (concat " Live · Listening · Session A"
                                     " · [Use here] · [Transcript] · [Setup]")
                             (nth 0 (harness-ui-voice-live-test--control-lines))))
              (should (= 1 (length (harness-ui-voice-live-test--control-lines))))
              (let ((at (string-search "[Use here]"
                                       (harness-voice-live--controls))))
                (should at)
                (should (equal "Live voice · target"
                               (get-text-property
                                at 'help-echo (harness-voice-live--controls))))))
          (when (buffer-live-p other) (kill-buffer other)))
        (should (eq target harness-voice-live--buffer))))))

(ert-deftest harness-ui-voice-live-follow-selection-moves-the-route ()
  "With following on, the selected box is the target at the next utterance.
Looking at a buffer with no compose box moves nothing."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet")
          harness-voice-live-follow-selection t)
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (let ((a (current-buffer))
          (b (harness-ui-voice-live-test--box "session-b"))
          (readme (generate-new-buffer " *routing readme*")))
      (unwind-protect
          (progn
            (with-current-buffer readme (fundamental-mode))
            ;; A source buffer is not a target.
            (set-window-buffer (selected-window) readme)
            (should-not (harness-voice-live--follow-selection))
            (should (equal "live-session" harness-voice-live--session))
            ;; A compose box of another session is.
            (set-window-buffer (selected-window) b)
            (should (harness-voice-live--follow-selection))
            (should (equal "session-b" harness-voice-live--session))
            ;; And the utterance goes there.
           (harness-ui-voice-live-test--delegate-after-grace (list :event "delegation" :id "d-follow"
                                              :text "Follow me."))
            (should (equal "session-b" (car (car harness-ui-voice-live-test--calls))))
            ;; Following back to the first box works the same way.
            (set-window-buffer (selected-window) a)
            (harness-voice-live--follow-selection)
            (should (equal "live-session" harness-voice-live--session)))
        (when (buffer-live-p b) (kill-buffer b))
        (when (buffer-live-p readme) (kill-buffer readme))))))

(ert-deftest harness-ui-voice-live-workspace-target-uses-the-thread ()
  "A workspace target sends through the workspace, to its selected thread.
The workspace's own agent does the work; the voice adds no second model."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (let ((box (harness-ui-voice-live-test--box "episode-1" "thread-7" "workspace-3")))
      (unwind-protect
          (with-current-buffer box
            (harness-voice-live-start)
            (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                               5 "sidecar ready")
            (should (eq 'workspace harness-voice-live--route-kind))
            (should (equal "workspace-3" harness-voice-live--route-workspace))
            (should (equal "thread-7" harness-voice-live--route-thread))
           (harness-ui-voice-live-test--delegate-after-grace
             (list :event "delegation" :id "d-w" :text "Add a README."))
            ;; It went through the workspace, to that thread, and not
            ;; through a session prompt.
            (should-not harness-ui-voice-live-test--calls)
            (let* ((send (car harness-ui-voice-live-test--sends))
                   (params (cadr send)))
              (should (equal "_harness/workspace/prompt" (car send)))
              (should (equal "workspace-3" (plist-get params :id)))
              (should (equal "Add a README." (plist-get params :text)))
              (should (equal "thread-7" (plist-get (plist-get params :opts) :thread)))))
        (when (buffer-live-p box) (kill-buffer box))))))

(ert-deftest harness-ui-voice-live-many-utterances-one-screen ()
  "Several utterances in one call each reach the target once, in order.
Every burst gets its own prompt, its own turn, and its own reply, and
none of them is delivered twice."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (dotimes (index 3)
      (let ((n (1+ index)))
       (harness-ui-voice-live-test--delegate-after-grace
         (list :event "delegation" :id (format "d-%d" n) :utterance n
               :text (format "Request %d." n)))
        (harness-voice--on-event "agent/turn-started" '("live-session"))
        (harness-voice-live--finish-turn "end-turn")))
    (should (= 3 (length harness-ui-voice-live-test--calls)))
    (should (equal '("Request 1." "Request 2." "Request 3.")
                   (mapcar (lambda (call)
                             (plist-get (car (plist-get (nth 2 call) :prompt)) :text))
                           (reverse harness-ui-voice-live-test--calls))))
    ;; The same utterance twice is one prompt.
   (harness-ui-voice-live-test--delegate-after-grace
     (list :event "delegation" :id "d-3" :utterance 3 :text "Request 3."))
    (should (= 3 (length harness-ui-voice-live-test--calls)))))

;;;; A compose box with no target

;; The reported failure: voice mode would not start on a machine whose
;; voice controls were shown in the task board's compose box.  That box
;; names no session and no workspace thread, so the start had nowhere to
;; send its words and failed with "Live voice session unavailable"; the
;; box kept offering a Start control that could only fail.  A box is a
;; target exactly when the start has somewhere to go.

(defun harness-ui-voice-live-test--box-without-target ()
  "Make a compose box that names no session and no workspace thread.
It is what the task board's box and a popout's box are."
  (let ((buffer (generate-new-buffer " *live voice board*")))
    (with-current-buffer buffer
      (use-local-map harness-compose-map)
      (harness-compose-setup :project (lambda () default-directory)
                             :redraw #'ignore)
      (let ((inhibit-read-only t))
        (insert (propertize "Board\n" 'read-only t))
        (harness-compose-insert))
      (harness-compose-capture))
    buffer))

(ert-deftest harness-ui-voice-live-box-without-a-target-offers-no-start ()
  "A box that names no session shows no Start control, and says why.
The exact rendered copy is pinned: the status, its tooltip, and the
absence of both controls that could only fail there."
  (harness-ui-voice-live-test-with
    (let ((box (harness-ui-voice-live-test--box-without-target)))
      (unwind-protect
          (with-current-buffer box
            (should-not (harness-voice-live--target-p))
            (should-not (harness-voice-live--route-of-buffer (current-buffer)))
            (let* ((line (harness-voice-live--controls))
                   (text (substring-no-properties line)))
              ;; The words, exactly.
              (should (equal " Voice · no session · [Setup]" text))
              ;; No control that would fail, and no failed status.
              (should-not (string-search "[Start]" text))
              (should-not (string-search "[Use here]" text))
              (should-not (string-search "Live · Failed" text))
              ;; The tooltip is a noun phrase naming the missing target.
              (should (equal "Live voice · no session target"
                             (get-text-property (string-match "Voice · no session" line)
                                                'help-echo line)))))
        (when (buffer-live-p box) (kill-buffer box))))
    ;; A box that names a session is a target, and still offers Start.
    (should (harness-voice-live--target-p))
    (should (string-search "[Start]" (harness-voice-live--controls)))))

(ert-deftest harness-ui-voice-live-box-without-a-target-refuses-the-start ()
  "The start from a box with no target is one line, not a failure.
`harness-voice-dictate' and the mouse press name the missing target
before any process, sidecar or permission is touched."
  (harness-ui-voice-live-test-with
    (let ((box (harness-ui-voice-live-test--box-without-target)))
      (unwind-protect
          (with-current-buffer box
            (setq-local harness-compose-controls-functions (list #'harness-voice--controls))
            (should (equal "Live voice · no session target"
                           (error-message-string (should-error (harness-voice-dictate)))))
            (should (equal "Live voice · no session target"
                           (error-message-string (should-error (harness-voice-hold)))))
            ;; Nothing started, and the controls did not turn into a failure.
            (should-not (harness-voice-live--active-p))
            (should-not harness-voice-live--process)
            (should-not (eq harness-voice-live--state 'failed)))
        (when (buffer-live-p box) (kill-buffer box))))))

(ert-deftest harness-ui-voice-live-box-without-a-target-opens-a-voice-chat ()
  "`harness-voice' in a box with no target gets a voice chat instead.
That is where an ordinary buffer already goes; a compose box with no
session must not be a dead end."
  (harness-ui-voice-live-test-with
    (let ((box (harness-ui-voice-live-test--box-without-target))
          (opened nil))
      (unwind-protect
          (with-current-buffer box
            (cl-letf (((symbol-function 'harness-new-session)
                       (lambda (dir position _callback)
                         (push (list dir position) opened))))
              (harness-voice)
              (should (= 1 (length opened)))
              ;; The board's own box gained no controls of its own.
              (should-not (harness-voice-live--active-p))))
        (when (buffer-live-p box) (kill-buffer box))))))

;;;; End to end through the real sidecar

;; The scripted sidecar is a real process speaking the real protocol.
;; These tests drive a whole call through it, including the switch that
;; the reported failure was about, so the transport and the process are
;; checked together and not only each on its own.  Synthetic audio: no
;; microphone and no speech model is anywhere in this.

(ert-deftest harness-ui-voice-live-e2e-retargets-between-two-utterances ()
  "A whole call: the first utterance goes to A, the switch, then B.
The sidecar is a real process; its second burst comes after the first
turn's result, which is where a person would have switched threads."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "routing"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () harness-ui-voice-live-test--calls)
                       5 "the first delegation")
    (should (equal "live-session" (car (car harness-ui-voice-live-test--calls))))
    (should (equal "Add a docstring." (harness-ui-voice-live-test--latest-prompt)))
    ;; The measured level the sidecar sent reached the meter.
    (should (numberp (harness-voice-pipeline-dbfs harness-voice-live--pipeline)))
    (should (equal "Level · -30 dBFS"
                   (harness-voice-pipeline-level-label
                    harness-voice-live--pipeline)))
    (let ((other (harness-ui-voice-live-test--box "session-b")))
      (unwind-protect
          (progn
            ;; The first turn ends, and the person selects B.
            (harness-voice--on-event "agent/turn-started" '("live-session"))
            (harness-voice--on-event "agent/turn-ended" '("live-session" "end-turn"))
            (should (harness-voice-live-retarget other))
            (should (equal "session-b" harness-voice-live--session))
            ;; The second burst goes to B, once, as it was said.
            (harness-test-wait
             (lambda ()
               (cl-find "session-b" harness-ui-voice-live-test--calls
                        :key #'car :test #'equal))
             5 "the second delegation")
            (let ((call (car harness-ui-voice-live-test--calls)))
              (should (equal "session-b" (car call)))
              (should (equal "Now check the tests."
                             (plist-get (car (plist-get (nth 2 call) :prompt))
                                        :text))))
            (should (equal '("session-b" "live-session")
                           (mapcar #'car harness-ui-voice-live-test--calls))))
        (when (buffer-live-p other) (kill-buffer other))))))

(ert-deftest harness-ui-voice-live-e2e-keeps-the-target-through-a-turn ()
  "The switch happens while the first turn runs; its reply is not spoken.
The sidecar is told the turn ended without a reply to speak."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "routing"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () harness-ui-voice-live-test--calls)
                       5 "the first delegation")
    (harness-voice--on-event "agent/turn-started" '("live-session"))
    (let ((other (harness-ui-voice-live-test--box "session-b")))
      (unwind-protect
          (progn
            (harness-voice-live-retarget other)
            (harness-ui-voice-live-test--chunk "The docstring is in place. " "n-1")
            (harness-voice--on-event "agent/turn-ended" '("live-session" "end-turn"))
            (let ((result (harness-ui-voice-live-test--wait-event
                           harness-ui-voice-live-test--inbox "delegate_result")))
              (should (equal "d-1" (plist-get result :id)))
              (should (equal "retargeted" (plist-get result :message))))
            (should-not (string-search "The docstring is in place."
                                       (harness-ui-voice-live-test--file-text
                                        harness-ui-voice-live-test--inbox))))
        (when (buffer-live-p other) (kill-buffer other))))))

;;;; The shared pipeline

;; The local pipeline is the harness server's and every client shares
;; it.  A call attaches to one that runs or is already starting, starts
;; one that is stopped, says `Initializing' while it comes up, and turns
;; a failed start into one sentence with a Retry control instead of a
;; wait that ends in a timeout.

(ert-deftest harness-ui-voice-live-pipeline-ready-starts-the-sidecar ()
  "A running pipeline is used as it is: no start, no wait."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-provider 'unmute
          harness-voice-live-command (harness-ui-voice-live-test--command "quiet"))
    (let ((started nil))
      (cl-letf (((symbol-function 'harness-voice-pipeline-state) (lambda () 'running))
                ((symbol-function 'harness-voice-unmute-need) (lambda () nil))
                ((symbol-function 'harness-voice-pipeline-start)
                 (lambda (&optional _callback) (setq started t)))
                ((symbol-function 'harness-voice-unmute-command)
                 (lambda () harness-voice-live-command)))
        (harness-voice-live-start)
        (should-not started)
        (should (eq harness-voice-live--state 'starting))
        (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                           5 "sidecar ready")))))

(ert-deftest harness-ui-voice-live-pipeline-initializing-is-visible ()
  "A stopped pipeline is started, and the controls say Initializing.
The sidecar waits for it; the stage line animates so the wait is alive."
  (harness-ui-voice-live-test-with
    (setq harness-voice-provider 'unmute)
    (let ((started 0))
      (cl-letf (((symbol-function 'harness-voice-pipeline-state) (lambda () 'stopped))
                ((symbol-function 'harness-voice-unmute-need)
                 (lambda () "Local voice pipeline · stopped"))
                ((symbol-function 'harness-voice-pipeline-start)
                 (lambda (&optional _callback) (cl-incf started)))
                ((symbol-function 'harness-voice-unmute-command)
                 (lambda () '("python3" "-c" "pass"))))
        (harness-voice-live-start)
        (should (= 1 started))
        (should (eq harness-voice-live--state 'initializing))
        (should (eq harness-voice-live--stage 'initializing))
        (should (equal "Live · Initializing" (harness-voice-live--status)))
        (should (string-prefix-p "⠋ Initializing" (harness-voice-live--stage-text)))
        (should (timerp harness-voice-live--pipeline-timer))
        (should-not harness-voice-live--process)
        ;; When it reports running, the sidecar starts by itself.
        (cl-letf (((symbol-function 'harness-voice-pipeline-state) (lambda () 'running))
                  ((symbol-function 'harness-voice-unmute-need) (lambda () nil))
                  ((symbol-function 'harness-voice-live--command)
                   (lambda () '("python3" "-c" "import sys; sys.stdin.read()"))))
          (harness-voice-live--pipeline-tick)
          (should-not (timerp harness-voice-live--pipeline-timer))
          (should (harness-voice-live--active-p))
          (should (eq harness-voice-live--state 'starting)))))))

(ert-deftest harness-ui-voice-live-pipeline-failure-is-one-sentence ()
  "A failed start fails the call at once, with Retry, not after a wait.
The reported two-minute stop/start was the pipeline's own start
deadline; a failure the harness already knows should not be waited out."
  (harness-ui-voice-live-test-with
    (setq harness-voice-provider 'unmute)
    (cl-letf (((symbol-function 'harness-voice-pipeline-state) (lambda () 'starting))
              ((symbol-function 'harness-voice-unmute-need)
               (lambda () "Local voice pipeline · starting"))
              ((symbol-function 'harness-voice-pipeline-start)
               (lambda (&optional _callback) nil))
              ((symbol-function 'window-body-width) (lambda (&rest _) 500))
              ((symbol-function 'harness-compose--room)
               (lambda () (* 500 (frame-char-width))))
              ((symbol-function 'harness-voice-unmute-command)
               (lambda () '("python3" "-c" "pass"))))
      (harness-voice-live-start)
      (should (eq harness-voice-live--state 'initializing))
      ;; A start that failed while waiting is read now, with its reason.
      (cl-letf (((symbol-function 'harness-voice-pipeline-state) (lambda () 'failed))
                ((symbol-function 'harness-voice-pipeline-reason)
                 (lambda () "Local voice pipeline · failed · No answer in 120 s")))
        (harness-voice-live--pipeline-tick))
      (should (eq harness-voice-live--state 'failed))
      (should (equal "Local voice pipeline · failed · No answer in 120 s"
                     harness-voice-live--error))
      (should-not (timerp harness-voice-live--pipeline-timer))
      (should-not harness-voice-live--process)
      (should (string-search "[Start]"
                             (harness-voice-live--controls))))))

(ert-deftest harness-ui-voice-live-pipeline-starting-is-joined ()
  "A start already in flight is waited for, not started a second time.
Two starts of one stack leave two speech services on one port."
  (harness-ui-voice-live-test-with
    (setq harness-voice-provider 'unmute)
    (let ((started 0))
      (cl-letf (((symbol-function 'harness-voice-pipeline-state) (lambda () 'starting))
                ((symbol-function 'harness-voice-unmute-need)
                 (lambda () "Local voice pipeline · starting"))
                ((symbol-function 'harness-voice-pipeline-start)
                 (lambda (&optional _callback) (cl-incf started)))
                ((symbol-function 'harness-voice-unmute-command)
                 (lambda () '("python3" "-c" "pass"))))
        (harness-voice-live-start)
        (should (= 0 started))
        (should (eq harness-voice-live--state 'initializing))
        (should (timerp harness-voice-live--pipeline-timer))))))

(ert-deftest harness-ui-voice-live-stopping-keeps-the-shared-pipeline ()
  "Ending voice never stops the pipeline every client shares."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (let ((stopped 0))
      (cl-letf (((symbol-function 'harness-voice-pipeline-stop)
                 (lambda () (cl-incf stopped))))
        (harness-voice-live-stop)
        (harness-test-wait (lambda () (null harness-voice-live--state))
                           5 "the call to end")
        (should (= 0 stopped))
        (should-not harness-voice-live--process)))))

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
   (harness-ui-voice-live-test--delegate-after-grace (list :event "delegation" :id "d-1" :text "First."))
   (harness-ui-voice-live-test--delegate-after-grace (list :event "delegation" :id "d-2" :text "Second."))
    (should (= 1 (length harness-ui-voice-live-test--calls)))
    (harness-voice-live--finish-turn "end-turn")
    (should (= 2 (length harness-ui-voice-live-test--calls)))
    (let* ((params (nth 2 (car harness-ui-voice-live-test--calls)))
           (prompt (plist-get (car (plist-get params :prompt)) :text)))
      (should (string-search "Second." prompt)))))

(ert-deftest harness-ui-voice-live-sends-the-transcript-unchanged ()
  "The transcript reaches the session as the speech model returned it.
No distillation, no context block, no meta-instruction: the target's
own agent reads the words, and nothing is asked about them first."
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
     (harness-ui-voice-live-test--delegate-after-grace
       (list :event "delegation" :id "d-mumble" :utterance 1 :text raw))
      (let ((prompt (harness-ui-voice-live-test--latest-prompt)))
        (should (equal raw prompt))
        (should-not (string-search "<voice-turn-context>" prompt))
        (should-not (string-search "Voice conversation" prompt))
        (should-not (string-search "Voice request context" prompt)))
      (let ((turns (harness-voice-conversation-turns
                    harness-voice-live--conversation)))
        (should (= 1 (length turns)))
        (should (equal raw (plist-get (car turns) :raw)))
        (should (equal raw (plist-get (car turns) :text)))
        (should (equal raw (plist-get (car turns) :sent))))
      (let ((transcript (harness-ui-voice-live-test--transcript)))
        ;; The words are on screen once: what crossed is what was shown,
        ;; so a second `Sent' heading would only repeat the sentence.
        (should (string-search raw transcript))
        (should-not (string-search "Sent · " transcript))
        (should-not (string-search "Not sent · " transcript))))))

(ert-deftest harness-ui-voice-live-a-dependent-request-carries-nothing ()
  "A request that points at an earlier turn is sent as it was said.
The session's agent has the conversation; the voice does not repeat it
and does not add an envelope around the words."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
    (harness-voice-live--handle
     (list :event "assistant_delta" :final t
           :text "The timer wakes it every 200 ms."))
   (harness-ui-voice-live-test--delegate-after-grace
     (list :event "delegation" :id "d-ctx" :utterance 1
           :text "Do that instead."))
    (let ((prompt (harness-ui-voice-live-test--latest-prompt)))
      (should (equal "Do that instead." prompt))
      (should-not (string-search "Voice conversation before this request:" prompt))
      (should-not (string-search "The timer wakes it every 200 ms." prompt)))))

(ert-deftest harness-ui-voice-live-empty-transcript-sends-nothing ()
  "A burst the speech model made no words of is recorded, not forwarded.
The sidecar is answered so it does not wait for a turn that will never
come, and the burst says why it stopped."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
   (harness-ui-voice-live-test--delegate-after-grace
     (list :event "delegation" :id "d-noise" :utterance 1 :text "   "))
    (should-not harness-ui-voice-live-test--calls)
    (let ((result (harness-ui-voice-live-test--wait-event
                   harness-ui-voice-live-test--inbox "delegate_result")))
      (should (equal "d-noise" (plist-get result :id)))
      (should (equal "" (plist-get result :text)))
      (should-not (plist-get result :error)))
    (let ((segment (harness-voice-pipeline--segment
                    harness-voice-live--pipeline "u-1")))
      (should (eq 'dropped (plist-get segment :stage)))
      (should (eq 'no-words (plist-get segment :reason)))
      (should (equal "no words"
                     (harness-voice-pipeline--drop-label
                      (plist-get segment :reason)))))
    (let ((transcript (harness-ui-voice-live-test--transcript)))
      (should (string-search "Not sent · " transcript))
      (should (string-search "no words" transcript)))))

(ert-deftest harness-ui-voice-live-conversation-ends-with-the-call ()
  "Ending the call forgets the voice conversation; the chat keeps its history."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening))
                       5 "sidecar ready")
   (harness-ui-voice-live-test--delegate-after-grace
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
   (harness-ui-voice-live-test--delegate-after-grace (list :event "delegation" :id "d-2" :text "Announce it."))
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

(ert-deftest harness-ui-voice-live-a-camera-provider-is-paused-not-muted ()
  "A camera provider's controls and strip use a camera's words.
Its session closes the device rather than muting a microphone, so the
control is Pause, the status says Paused, and the pipeline is told the
input is a camera.  A microphone provider keeps Mute and Muted."
  (harness-ui-voice-live-test-with
    (harness-define-voice-provider 'camera-test
      :label "Camera test" :capability 'live :camera t :command '("true"))
    (setq harness-voice-provider 'camera-test)
    (cl-letf (((symbol-function 'harness-voice-live--active-p) (lambda () t)))
      ;; The controls that close the capture path are drawn only in the
      ;; call's own box, so this box must be the target for them to show.
      (setq harness-voice-live--buffer (current-buffer)
            harness-voice-live--state 'listening
            harness-voice-live--working nil
            harness-voice-live--muted nil
            harness-voice-live--error nil)
      (harness-voice-live--pipeline-bump 'live)
      (let ((line (harness-voice-live--controls)))
        (should (string-search "[Pause C-c v]" line))
        (should-not (string-search "[Mute C-c v]" line))
        (let ((at (string-search "[Pause C-c v]" line)))
          (should (equal "Camera · live capture" (get-text-property at 'help-echo line)))))
      (should (equal "Live · Listening" (harness-voice-live--status)))
      ;; Closing the device is a pause, in the status and in the pipeline.
      (setq harness-voice-live--muted t)
      (harness-voice-live--pipeline-muted t)
      (harness-voice-live--stage-set 'muted)
      (should (equal "Live · Paused" (harness-voice-live--status)))
      (should (equal 'paused (harness-voice-pipeline-capture
                              harness-voice-live--pipeline)))
      (should (equal "Camera · paused"
                     (harness-voice-pipeline-capture-label
                      harness-voice-live--pipeline)))
      (should (string-search "[Resume C-c v]" (harness-voice-live--controls)))
      (should-not (string-search "[Unmute C-c v]" (harness-voice-live--controls))))
    ;; A microphone provider is unchanged.
    (setq harness-voice-provider 'custom)
    (cl-letf (((symbol-function 'harness-voice-live--active-p) (lambda () t)))
      (setq harness-voice-live--state 'listening
            harness-voice-live--working nil
            harness-voice-live--muted nil
            harness-voice-live--error nil)
      (harness-voice-live--pipeline-bump 'live)
      (should (string-search "[Mute C-c v]" (harness-voice-live--controls)))
      (should (eq 'mic (harness-voice-pipeline-input harness-voice-live--pipeline))))))

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

(ert-deftest harness-ui-voice-live-notice-keeps-the-call ()
  "A notice is shown, and the session it happened in goes on."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "notice"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () harness-voice-live--notice) 5 "the notice")
    (should (equal "Live voice · Local speech · no audio"
                   harness-voice-live--notice))
    ;; The session is untouched: still listening, no failure, a Start
    ;; button nowhere.
    (should (harness-voice-live--active-p))
    (should (eq 'listening harness-voice-live--state))
    (should-not harness-voice-live--error)
    (should (equal "Live · Listening" (harness-voice-live--status)))
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 500))
              ((symbol-function 'harness-compose--room)
               (lambda () (* 500 (frame-char-width)))))
      (should (equal (concat " Live · Listening · [End] · [Interrupt C-c V]"
                             " · Live voice · Local speech · no audio"
                             " · [Mute C-c v] · [Transcript] · [Setup]")
                     (car (split-string
                           (substring-no-properties (harness-voice-live--controls))
                           "\n")))))
    ;; And the transcript says where it happened, in the caution face.
    (with-current-buffer harness-voice-live--transcript
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "^Live$" text))
        (should (string-match-p "^  Local speech · no audio$" text)))
      (goto-char (point-min))
      (when (search-forward "Local speech · no audio" nil t)
        (should (eq 'harness-caution-face
                    (get-text-property (match-beginning 0) 'face)))))))

(ert-deftest harness-ui-voice-live-unspeakable-piece-is-not-sent ()
  "A piece a voice cannot say is never handed to the sidecar.
The reply that ends in an emoji used to send the emoji on its own, which
a speech server answers with no audio at all."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (should-not (harness-voice-live--speakable-p "🙂"))
    (should-not (harness-voice-live--speakable-p "—"))
    (should-not (harness-voice-live--speakable-p "`"))
    (should (harness-voice-live--speakable-p "Hi 🙂"))
    (harness-voice-live--speak "🙂")
    (harness-voice-live--speak "Loud and clear. 🙂")
    (harness-test-wait
     (lambda ()
       (cl-find "Loud and clear. 🙂"
                (mapcar (lambda (e) (plist-get e :text))
                        (cl-remove-if-not (lambda (e) (equal (plist-get e :event) "commentary"))
                                          (harness-ui-voice-live-test--events
                                           harness-ui-voice-live-test--inbox)))
                :test #'equal))
     5 "the speakable commentary")
    (let ((texts (mapcar (lambda (e) (plist-get e :text))
                         (cl-remove-if-not (lambda (e) (equal (plist-get e :event) "commentary"))
                                           (harness-ui-voice-live-test--events
                                            harness-ui-voice-live-test--inbox)))))
      (should (equal '("Loud and clear. 🙂") texts)))))

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
   (should (equal "● Finishing thought" (harness-voice-live--stage-text)))
   (should-not harness-ui-voice-live-test--calls)
   ;; This is a renderer-only test with no sidecar.  The live tests cross
   ;; grace before agent delivery; render the subsequent stage explicitly.
   (harness-voice-live--pending-cancel "cancelled")
   (harness-voice-live--stage-set 'thinking)
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
   (harness-ui-voice-live-test--delegate-after-grace (list :event "delegation" :id "d-1"
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
   (harness-ui-voice-live-test--delegate-after-grace
     (list :event "delegation" :id "d-2" :utterance 2
           :text "Wait, also check the tests."
           :pending (list (list :id "sidecar-1" :text "The sidecar held this."))))
    (should (= 2 (length harness-ui-voice-live-test--calls)))
    ;; The held reply is not spoken and not repeated into the message:
    ;; the session's agent has the turn it wrote, and the voice sends
    ;; only what the person said.
    (let ((prompt (harness-ui-voice-live-test--latest-prompt)))
      (should (equal "Wait, also check the tests." prompt))
      (should-not (string-search "<voice-turn-context>" prompt))
      (should-not (string-search "The parser is ready." prompt))
      (should-not (string-search "The sidecar held this." prompt)))
    ;; The same utterance arriving twice is not a second prompt.
   (harness-ui-voice-live-test--delegate-after-grace
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
        (should (string-search "[Show details]" strip))
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

;;;; Conservative conversational turns, with deterministic deadlines

(defvar harness-ui-voice-live-test--timers nil)
(defvar harness-ui-voice-live-test--output nil)

(defmacro harness-ui-voice-live-test-clock (&rest body)
  "Run BODY with a live route, captured output and manually fired timers."
  (declare (indent 0))
  `(harness-ui-voice-live-test-with
    (let ((harness-voice-live-turn-grace 1.2)
          (harness-ui-voice-live-test--timers nil)
          (harness-ui-voice-live-test--output nil))
      (setq harness-voice-live--state 'listening
            harness-voice-live--stage 'listening
            harness-voice-live--buffer (current-buffer)
            harness-voice-live--session "live-session")
      (cl-letf (((symbol-function 'harness-voice-live--active-p) (lambda () t))
                ((symbol-function 'harness-voice-live--send)
                 (lambda (event) (push event harness-ui-voice-live-test--output) t))
                ((symbol-function 'run-at-time)
                 (lambda (delay repeat function &rest args)
                   (let ((timer (timer-create)))
                     (push (list timer delay repeat function args)
                           harness-ui-voice-live-test--timers)
                     timer))))
        ,@body))))

(defun harness-ui-voice-live-test--fire (timer)
  "Fire TIMER even when canceled, to exercise stale callback guards."
  (let ((entry (assq timer harness-ui-voice-live-test--timers)))
    (should entry)
    (apply (nth 3 entry) (nth 4 entry))))

(defun harness-ui-voice-live-test--utterance (id text &optional truncated)
  "Deliver a completed numbered local chunk ID with TEXT and TRUNCATED."
  (harness-voice-live--handle
   (list :event "transcribing" :utterance id))
  (harness-voice-live--handle
   (list :event "user_delta" :utterance id :text text :final t))
  (harness-voice-live--handle
   (list :event "delegation" :id (format "d-%s" id) :utterance id
         :text text :truncated truncated)))

(ert-deftest harness-ui-voice-live-turn-ordinary-grace-and-single-crossing ()
  (harness-ui-voice-live-test-clock
   (harness-ui-voice-live-test--utterance 1 "Run  the tests.")
   (should-not harness-ui-voice-live-test--calls)
   (should-not (harness-voice-conversation-turns harness-voice-live--conversation))
   (should (equal "Run  the tests." (harness-voice-live--pending-text)))
   (let ((timer harness-voice-live--pending-timer))
     (should (= 1.2 (nth 1 (assq timer harness-ui-voice-live-test--timers))))
     (should (equal '(:event "turn_hold" :active t)
                    (car harness-ui-voice-live-test--output)))
     (harness-ui-voice-live-test--fire timer)
     (should (equal "Run  the tests." (harness-ui-voice-live-test--latest-prompt)))
     (should (= 1 (length harness-ui-voice-live-test--calls)))
     (should (= 1 (length (harness-voice-conversation-turns harness-voice-live--conversation))))
     (should-not harness-voice-live--pending)
     (should-not harness-voice-live--turn-held)
     (harness-ui-voice-live-test--fire timer)
     (should (= 1 (length harness-ui-voice-live-test--calls))))))

(ert-deftest harness-ui-voice-live-turn-breath-and-slow-transcription ()
  (harness-ui-voice-live-test-clock
   (harness-ui-voice-live-test--utterance 1 "Fix the tests.")
   (let ((old harness-voice-live--pending-timer))
     (harness-voice-live--handle '(:event "speech" :utterance 2 :active t))
     (harness-voice-live--handle '(:event "segment" :id "u-2" :state "accepted"))
     (harness-voice-live--handle '(:event "speech" :utterance 2 :active nil))
     (harness-voice-live--handle '(:event "listening"))
     (harness-ui-voice-live-test--fire old)
     (should-not harness-ui-voice-live-test--calls)
     (should-not harness-voice-live--pending-timer)
     (harness-ui-voice-live-test--utterance 2 "Also check the parser.")
     (should-not harness-ui-voice-live-test--calls)
     (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
     (should (equal "Fix the tests. Also check the parser."
                    (harness-ui-voice-live-test--latest-prompt)))
     (let ((turn (harness-voice-pipeline--turn harness-voice-live--pipeline "d-1")))
       (should (equal '("u-1" "u-2") (plist-get turn :segments))))
     (harness-voice-live--finish-turn "end-turn")
     (dolist (source '("u-1" "u-2"))
       (should (eq 'answered (plist-get (harness-voice-pipeline--segment
                                         harness-voice-live--pipeline source) :stage)))))))

(ert-deftest harness-ui-voice-live-turn-indefinite-holds-and-output-safety ()
  (dolist (example '(("Fix it, one second." continuation nil)
                     ("Let me think." continuation nil)
                     ("Change the handler because." cut-off nil)
                     ("Complete request." cut-off t)))
    (harness-ui-voice-live-test-clock
     (harness-ui-voice-live-test--utterance 1 (nth 0 example) (nth 2 example))
     (should (eq (nth 1 example) (harness-voice-live--pending-reason)))
     (should-not harness-voice-live--pending-timer)
     (dotimes (_ 3) (harness-voice-live--handle '(:event "listening")))
     (harness-voice-live--speak "A previous answer." "n-1")
     (harness-voice-live--release-held)
     (should harness-voice-live--held)
     (should-not harness-voice-live--held-timer)
     (should-not (cl-find "commentary" harness-ui-voice-live-test--output
                          :key (lambda (event) (plist-get event :event)) :test #'equal))
     (should-not harness-ui-voice-live-test--calls)
     (harness-voice-live-send-now)
     (harness-voice-live-send-now)
     (should (= 1 (length harness-ui-voice-live-test--calls)))
     (should (equal (nth 0 example) (harness-ui-voice-live-test--latest-prompt))))))

(ert-deftest harness-ui-voice-live-turn-more-words-finish-a-hold ()
  (harness-ui-voice-live-test-clock
   (harness-ui-voice-live-test--utterance 1 "Fix it, hold on.")
   (should-not harness-voice-live--pending-timer)
   (harness-ui-voice-live-test--utterance 2 "The parser test is the failing one.")
   (should (eq 'grace (harness-voice-live--pending-reason)))
   (should-not harness-ui-voice-live-test--calls)
   (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
   (should (equal "Fix it, hold on. The parser test is the failing one."
                  (harness-ui-voice-live-test--latest-prompt)))))

(ert-deftest harness-ui-voice-live-turn-recovery-releases-unchanged ()
  (harness-ui-voice-live-test-clock
   (harness-ui-voice-live-test--utterance 1 "Use the new branch and")
   (harness-ui-voice-live-test--utterance 2 "Go on, please.")
   (should (= 1 (length harness-ui-voice-live-test--calls)))
   (should (equal "Use the new branch and" (harness-ui-voice-live-test--latest-prompt)))
   (should (string-search "Go on, please." (harness-ui-voice-live-test--transcript)))
   (harness-voice-live--handle '(:event "delegation" :id "retry" :utterance 2 :text "Go on, please."))
   (should (= 1 (length harness-ui-voice-live-test--calls)))
   (harness-voice-live--finish-turn "end-turn")
   (should (equal '("d-1" "d-2")
                  (sort (mapcar (lambda (event) (plist-get event :id))
                                (cl-remove-if-not
                                 (lambda (event) (equal "delegate_result" (plist-get event :event)))
                                 harness-ui-voice-live-test--output))
                        #'string<)))
   (harness-ui-voice-live-test--utterance 3 "Continue!")
   (should harness-voice-live--pending-timer)
   (should (= 1 (length harness-ui-voice-live-test--calls)))
   (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
   (should (equal "Continue!" (harness-ui-voice-live-test--latest-prompt)))))

(ert-deftest harness-ui-voice-live-turn-dedup-pending-and-repeated-words ()
  (harness-ui-voice-live-test-clock
   (harness-ui-voice-live-test--utterance 1 "yes")
   (harness-voice-live--handle '(:event "delegation" :id "retry" :utterance 1 :text "yes"))
   (should (equal "yes" (harness-voice-live--pending-text)))
   (harness-voice-live--handle '(:event "delegation" :text "yes"))
   (harness-voice-live--handle '(:event "delegation" :text "yes"))
   (should (equal "yes yes yes" (harness-voice-live--pending-text)))
   (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
   (should (= 1 (length harness-ui-voice-live-test--calls)))
   (should (equal "yes yes yes" (harness-ui-voice-live-test--latest-prompt)))))

(ert-deftest harness-ui-voice-live-turn-source-order-not-completion-order ()
  (harness-ui-voice-live-test-clock
   (harness-voice-live--handle '(:event "segment" :id "u-1" :state "accepted" :truncated t))
   (harness-voice-live--handle '(:event "segment" :id "u-2" :state "accepted"))
   (harness-ui-voice-live-test--utterance 2 "the parser test.")
   (should-not harness-voice-live--pending-timer)
   (harness-ui-voice-live-test--utterance 1 "Fix  only")
   (should (equal "Fix  only the parser test." (harness-voice-live--pending-text)))
   ;; A later complete chunk finishes an earlier hard boundary.
   (should (eq 'grace (harness-voice-live--pending-reason)))
   (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
   (should (equal "Fix  only the parser test." (harness-ui-voice-live-test--latest-prompt)))
   (should (equal '("u-1" "u-2") (plist-get harness-voice-live--delegation :segments)))))

(ert-deftest harness-ui-voice-live-turn-hard-cut-metadata-not-duration ()
  (harness-ui-voice-live-test-clock
   (harness-voice-live--handle '(:event "segment" :id "u-1" :state "accepted" :seconds 100))
   (harness-ui-voice-live-test--utterance 1 "Complete request.")
   (should (eq 'grace (harness-voice-live--pending-reason)))
   (let ((old harness-voice-live--pending-timer))
     ;; Metadata is authoritative even if it arrives after the delegation.
     (harness-voice-live--handle '(:event "segment" :id "u-1" :state "transcribed" :truncated t))
     (should (eq 'cut-off (harness-voice-live--pending-reason)))
     (should-not harness-voice-live--pending-timer)
     (harness-ui-voice-live-test--fire old)
     (should-not harness-ui-voice-live-test--calls))))

(ert-deftest harness-ui-voice-live-turn-failed-transcription-is-not-missing-silence ()
  (harness-ui-voice-live-test-clock
   (harness-ui-voice-live-test--utterance 1 "Fix the tests.")
   (harness-voice-live--handle '(:event "segment" :id "u-2" :state "accepted"))
   (harness-voice-live--handle '(:event "segment" :id "u-2" :state "failed" :reason "transcription failed"))
   (harness-voice-live--handle '(:event "notice" :message "Transcription failed"))
   (harness-voice-live--handle '(:event "listening"))
   (should (eq 'cut-off (harness-voice-live--pending-reason)))
   (should-not harness-voice-live--pending-timer)
   (should-not harness-ui-voice-live-test--calls)
   (should (equal "Live voice · Transcription failed" harness-voice-live--notice))))

(ert-deftest harness-ui-voice-live-turn-empty-and-dropped-chunks-unblock-grace ()
  (dolist (end '(empty dropped))
    (harness-ui-voice-live-test-clock
     (harness-ui-voice-live-test--utterance 1 "Fix the tests.")
     (harness-voice-live--handle '(:event "segment" :id "u-2" :state "accepted"))
     (if (eq end 'empty)
         (harness-voice-live--handle '(:event "delegation" :id "d-2" :utterance 2 :text ""))
       (harness-voice-live--handle '(:event "segment" :id "u-2" :state "dropped" :reason "no words")))
     (should harness-voice-live--pending-timer)
     (should (equal "Fix the tests." (harness-voice-live--pending-text)))
     (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
     (should (equal "Fix the tests." (harness-ui-voice-live-test--latest-prompt))))))

(ert-deftest harness-ui-voice-live-turn-manual-action-not-a-queued-override ()
  (harness-ui-voice-live-test-clock
   (harness-ui-voice-live-test--utterance 1 "Fix the tests.")
   (harness-voice-live--handle '(:event "segment" :id "u-2" :state "accepted"))
   (harness-voice-live-send-now)
   (should-not harness-ui-voice-live-test--calls)
   (should-not (string-search "[Submission]" (harness-voice-live--controls)))
   (harness-voice-live--handle '(:event "segment" :id "u-2" :state "dropped"))
   (should-not harness-ui-voice-live-test--calls)
   (should harness-voice-live--pending-timer)
   (harness-voice-live-send-now)
   (should (= 1 (length harness-ui-voice-live-test--calls)))))

(ert-deftest harness-ui-voice-live-turn-cancelled-lifecycles-invalidate-timers ()
  (dolist (end '(mute stop fail dispose reset closed session workspace))
    (harness-ui-voice-live-test-clock
     (harness-ui-voice-live-test--utterance 1 "Fix the tests.")
     (let ((timer harness-voice-live--pending-timer))
       (pcase end
         ('mute (harness-voice-live-mute))
         ('stop (harness-voice-live-stop))
         ('fail (harness-voice-live--fail "Live voice failed"))
         ('dispose (harness-voice-live--dispose))
         ('reset (harness-voice-live--reset))
         ('closed (harness-voice-live--handle '(:event "closed")))
         ('session (harness-voice-live--route-set '(:kind session :session "new")))
         ('workspace (harness-voice-live--route-set '(:kind workspace :workspace "w" :thread "new"))))
       (harness-ui-voice-live-test--fire timer)
       (should-not harness-ui-voice-live-test--calls)
       (should-not harness-voice-live--pending)
       (should-not harness-voice-live--pending-timer)
       (should-not harness-voice-live--held-timer)
       (should-not harness-voice-live--turn-held)
       (unless (eq end 'reset)
         (should (eq 'dropped (plist-get (harness-voice-pipeline--segment
                                          harness-voice-live--pipeline "u-1") :stage))))))))

(ert-deftest harness-ui-voice-live-turn-listening-cannot-release-a-real-draft ()
  (harness-ui-voice-live-test-clock
   (setq harness-voice-live--speech-active t)
   (harness-voice-live--speak "Old answer." "n-1")
   (setq harness-voice-live--speech-active nil)
   (harness-voice-live--handle '(:event "listening"))
   (let ((false-trigger harness-voice-live--held-timer))
     (should false-trigger)
     (harness-ui-voice-live-test--utterance 1 "Hold on.")
     (harness-ui-voice-live-test--fire false-trigger)
     (dotimes (_ 3) (harness-voice-live--handle '(:event "listening")))
     (should harness-voice-live--held)
     (should-not harness-voice-live--held-timer)
     (should-not (cl-find "commentary" harness-ui-voice-live-test--output
                          :key (lambda (event) (plist-get event :event)) :test #'equal)))))

(ert-deftest harness-ui-voice-live-turn-caption-only-hold-and-recovery ()
  (harness-ui-voice-live-test-clock
   (harness-voice-live--handle '(:event "user_delta" :utterance 1 :text "Hold on." :final t))
   (should harness-voice-live--turn-held)
   (should-not harness-voice-live--pending)
   (should-not (string-search "[Submission]" (harness-voice-live--controls)))
   (harness-voice-live--handle '(:event "listening"))
   (should (equal "Live · Waiting for continuation" (harness-voice-live--status)))
   (should-not harness-voice-live--held-timer)
   (harness-voice-live--handle '(:event "user_delta" :utterance 2 :text "Go on." :final t))
   (should-not harness-voice-live--turn-held)
   (should-not harness-voice-live--caption-hold)
   (should-not harness-ui-voice-live-test--calls)))

(ert-deftest harness-ui-voice-live-turn-autonomous-final-caption-not-unresolved-input ()
  (harness-ui-voice-live-test-clock
   (harness-voice-live--handle '(:event "user_delta" :utterance 1 :text "Hello" :final t))
   (should-not (harness-voice-live--input-busy-p))
   (should-not harness-voice-live--turn-held)
   (should-not harness-ui-voice-live-test--calls)
   (harness-ui-voice-live-test--utterance 2 "Run the tests.")
   (should harness-voice-live--pending-timer)
   (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
   (should (equal "Run the tests." (harness-ui-voice-live-test--latest-prompt)))))

(ert-deftest harness-ui-voice-live-turn-exact-rendered-copy ()
  (dolist (example '(("Complete request." "Finishing thought")
                     ("Hold on." "Waiting for continuation")
                     ("Because" "Possible cut-off")))
    (harness-ui-voice-live-test-clock
     (cl-letf (((symbol-function 'harness-compose--room)
                (lambda () (* 500 (frame-char-width)))))
       (harness-ui-voice-live-test--utterance 1 (car example))
       (should (equal (concat "Live · " (cadr example)) (harness-voice-live--status)))
       (should (equal (concat "● " (cadr example)) (harness-voice-live--stage-text)))
       (let* ((controls (harness-voice-live--controls))
              (lines (split-string (substring-no-properties controls) "\n"))
              (at (string-search "[Submission]" controls)))
         (should (equal (concat " Live · " (cadr example)
                                " · [End] · [Submission] · [Interrupt C-c V]"
                                " · [Mute C-c v] · [Transcript] · [Setup]")
                        (car lines)))
         (should (equal (concat "Unsent speech · " (car example)) (nth 2 lines)))
         (should at)
         (should (equal "Pending speech submission" (get-text-property at 'help-echo controls)))
         (should (member (concat "Unsent speech · " (car example))
                         (mapcar #'substring-no-properties
                                 (harness-voice-live--pipeline-block 500)))))))))

(ert-deftest harness-ui-voice-live-turn-bound-never-truncates-or-sends ()
  (harness-ui-voice-live-test-clock
   (let ((harness-voice-live-pending-limit 5))
     (harness-ui-voice-live-test--utterance 1 "Complete request.")
     (should (eq 'failed harness-voice-live--state))
     (should (equal "Unsent speech limit" harness-voice-live--error))
     (should (equal "Live · Failed" (harness-voice-live--status)))
     (should (string-search "Complete request." (harness-ui-voice-live-test--transcript)))
     (should-not harness-voice-live--pending)
     (should-not harness-voice-live--pending-timer)
     (should-not harness-ui-voice-live-test--calls))))

(ert-deftest harness-ui-voice-live-turn-recovery-completes-before-earlier-words ()
  (harness-ui-voice-live-test-clock
    (harness-voice-live--handle '(:event "segment" :id "u-1" :state "accepted"))
    (harness-voice-live--handle '(:event "segment" :id "u-2" :state "accepted"))
    (harness-ui-voice-live-test--utterance 2 "Go on.")
    (should-not harness-ui-voice-live-test--calls)
    (harness-ui-voice-live-test--utterance 1 "Change the handler because")
    (should (= 1 (length harness-ui-voice-live-test--calls)))
    (should (equal "Change the handler because" (harness-ui-voice-live-test--latest-prompt)))))

(ert-deftest harness-ui-voice-live-turn-failure-sticky-until-explicit-recovery ()
  (harness-ui-voice-live-test-clock
    (harness-ui-voice-live-test--utterance 1 "Fix the tests.")
    (harness-voice-live--handle '(:event "segment" :id "u-2" :state "failed"))
    (harness-ui-voice-live-test--utterance 3 "Also check the parser.")
    (should (eq 'cut-off (harness-voice-live--pending-reason)))
    (should-not harness-voice-live--pending-timer)
    (should-not harness-ui-voice-live-test--calls)
    (harness-ui-voice-live-test--utterance 4 "Continue.")
    (should (equal "Fix the tests. Also check the parser." (harness-ui-voice-live-test--latest-prompt)))
    (harness-voice-live--finish-turn "end-turn")
    (harness-ui-voice-live-test--utterance 5 "Another request.")
    (should (eq 'grace (harness-voice-live--pending-reason)))))

(ert-deftest harness-ui-voice-live-turn-mute-cancels-failed-input ()
  (harness-ui-voice-live-test-clock
    (harness-ui-voice-live-test--utterance 1 "First request.")
    (harness-voice-live--handle '(:event "segment" :id "u-2" :state "failed"))
    (should (eq 'cut-off (harness-voice-live--pending-reason)))
    (harness-voice-live-mute)
    (should (eq 'cancelled (plist-get (cdr (assoc "u-2" harness-voice-live--input-chunks)) :state)))
    (should-not harness-voice-live--pending)
    (harness-voice-live-mute)
    (harness-ui-voice-live-test--utterance 3 "Next request.")
    (should (equal "Next request." (harness-voice-live--pending-text)))
    (should (eq 'grace (harness-voice-live--pending-reason)))
    (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
    (should (equal "Next request." (harness-ui-voice-live-test--latest-prompt)))))

(ert-deftest harness-ui-voice-live-turn-successful-retry-restores-missing-words ()
  (harness-ui-voice-live-test-clock
    (harness-ui-voice-live-test--utterance 1 "Fix")
    (harness-voice-live--handle '(:event "segment" :id "u-2" :state "failed"))
    (harness-ui-voice-live-test--utterance 2 "the parser tests.")
    (should (equal "Fix the parser tests." (harness-voice-live--pending-text)))
    (should (eq 'grace (harness-voice-live--pending-reason)))
    (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
    (should (equal "Fix the parser tests." (harness-ui-voice-live-test--latest-prompt)))))

(ert-deftest harness-ui-voice-live-turn-old-route-agent-failure-keeps-new-draft ()
  (dolist (failure '(turn-error dispatch-error))
    (harness-ui-voice-live-test-clock
      (harness-ui-voice-live-test--utterance 1 "First request.")
      (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
      (harness-voice-live--route-set '(:kind session :session "session-b"))
      (harness-ui-voice-live-test--utterance 2 "Second request, hold on.")
      (if (eq failure 'turn-error) (harness-voice-live--finish-turn "cancelled")
        (harness-voice-live--delegate-error "d-1" '(error "old request failure")))
      (should (equal "Second request, hold on." (harness-voice-live--pending-text)))
      (should harness-voice-live--turn-held)
      (should (eq 'continuation (harness-voice-live--pending-reason)))
      (should-not harness-voice-live--pending-timer))))

(ert-deftest harness-ui-voice-live-turn-consumed-caption-retry-cannot-rehold ()
  (harness-ui-voice-live-test-clock
    (harness-ui-voice-live-test--utterance 1 "Hold on.")
    (harness-voice-live-send-now)
    (harness-voice-live--finish-turn "end-turn")
    (harness-voice-live--handle '(:event "user_delta" :utterance 1 :text "Hold on." :final t))
    (harness-voice-live--handle '(:event "delegation" :utterance 1 :id "retry" :text "Hold on."))
    (should-not harness-voice-live--turn-held)
    (should-not harness-voice-live--caption-hold)
    (should-not harness-voice-live--pending)
    (should (= 1 (length harness-ui-voice-live-test--calls)))))

(ert-deftest harness-ui-voice-live-turn-newer-caption-hold-blocks-older-draft ()
  (harness-ui-voice-live-test-clock
    (harness-voice-live--handle '(:event "hearing" :utterance 1))
    (harness-voice-live--handle '(:event "hearing" :utterance 2))
    (harness-voice-live--handle '(:event "user_delta" :utterance 2 :text "Hold on." :final t))
    (harness-voice-live--handle '(:event "user_delta" :utterance 1 :text "Run the tests." :final t))
    (harness-voice-live--handle '(:event "delegation" :utterance 1 :id "d-1" :text "Run the tests."))
    (should harness-voice-live--turn-held)
    (should (eq 'continuation (harness-voice-live--pending-reason)))
    (should-not harness-voice-live--pending-timer)
    (should-not harness-ui-voice-live-test--calls)
    (should (equal "Run the tests." (harness-voice-live--pending-text)))
    (harness-voice-live--handle '(:event "user_delta" :utterance 3 :text "Go on." :final t))
    (should (equal "Run the tests." (harness-ui-voice-live-test--latest-prompt)))
    (should (= 1 (length harness-ui-voice-live-test--calls)))
    ;; A delayed delegation of the caption-only control is acknowledged,
    ;; not appended to another request or sent again.
    (harness-voice-live--handle '(:event "delegation" :utterance 3 :id "d-3" :text "Go on."))
    (should (= 1 (length harness-ui-voice-live-test--calls)))
    (should-not harness-voice-live--pending)))

(ert-deftest harness-ui-voice-live-turn-unresolved-input-holds-provider-output ()
  (harness-ui-voice-live-test-clock
    (harness-voice-live--handle '(:event "transcribing" :utterance 1))
    (should (equal '(:event "turn_hold" :active t) (car harness-ui-voice-live-test--output)))
    (harness-voice-live--handle '(:event "user_delta" :utterance 1 :text "Hold on." :final t))
    (harness-voice-live--handle '(:event "transcribing" :utterance 2))
    (harness-voice-live--handle '(:event "user_delta" :utterance 2 :text "Complete thought." :final t))
    (should (harness-voice-live--input-busy-p))
    (should harness-voice-live--turn-held)
    (should-not (cl-find :false harness-ui-voice-live-test--output
                         :key (lambda (event) (plist-get event :active))))))

(ert-deftest harness-ui-voice-live-turn-empty-out-of-order-source-accounting ()
  (harness-ui-voice-live-test-clock
    (harness-voice-live--handle '(:event "transcribing" :utterance 1))
    (harness-voice-live--handle '(:event "transcribing" :utterance 2))
    (harness-voice-live--handle '(:event "delegation" :utterance 1 :id "d-1" :text ""))
    (should (eq 'dropped (plist-get (harness-voice-pipeline--segment harness-voice-live--pipeline "u-1") :stage)))
    (should (eq 'transcribing (plist-get (harness-voice-pipeline--segment harness-voice-live--pipeline "u-2") :stage)))
    (harness-ui-voice-live-test--utterance 2 "Complete thought.")
    (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
    (harness-voice-live--finish-turn "end-turn")
    (should (eq 'answered (plist-get (harness-voice-pipeline--segment harness-voice-live--pipeline "u-2") :stage)))))

(ert-deftest harness-ui-voice-live-turn-stale-false-trigger-cannot-release-new-output ()
  (harness-ui-voice-live-test-clock
    (setq harness-voice-live--speech-active t)
    (harness-voice-live--speak "Old answer." "n-old")
    (setq harness-voice-live--speech-active nil)
    (harness-voice-live--handle '(:event "listening"))
    (let ((old harness-voice-live--held-timer))
      (harness-voice-live--route-set '(:kind session :session "session-b"))
      (setq harness-voice-live--speech-active t)
      (harness-voice-live--speak "New answer." "n-new")
      (setq harness-voice-live--speech-active nil)
      (harness-voice-live--handle '(:event "listening"))
      (let ((current harness-voice-live--held-timer))
        (harness-ui-voice-live-test--fire old)
        (should harness-voice-live--held)
        (should (eq current harness-voice-live--held-timer))
        (harness-ui-voice-live-test--fire current)
        (should-not harness-voice-live--held)))))

(ert-deftest harness-ui-voice-live-turn-many-sources-one-count-each ()
  (harness-ui-voice-live-test-clock
    (dotimes (index 7) (harness-ui-voice-live-test--utterance (1+ index) "Complete thought."))
    (should (= 7 (harness-voice-pipeline-accepted harness-voice-live--pipeline)))
    (harness-ui-voice-live-test--fire harness-voice-live--pending-timer)
    (should (= 7 (length (plist-get harness-voice-live--delegation :segments))))
    (should (= 7 (harness-voice-pipeline-accepted harness-voice-live--pipeline)))
    (harness-voice-live--finish-turn "end-turn")
    (should (= 7 (harness-voice-pipeline-accepted harness-voice-live--pipeline)))
    (should (= 7 (length (cl-remove-if-not
                          (lambda (event) (equal "delegate_result" (plist-get event :event)))
                          harness-ui-voice-live-test--output))))))

;;;; The receipt of an accepted request

(defvar harness-ui-voice-live-test--order nil
  "What the acknowledgment tests saw happen, oldest first.")

(defun harness-ui-voice-live-test--acknowledgments ()
  "Return the acknowledge events the sidecar was sent, oldest first."
  (cl-remove-if-not (lambda (event) (equal "acknowledge" (plist-get event :event)))
                    (harness-ui-voice-live-test--events
                     harness-ui-voice-live-test--inbox)))

(defun harness-ui-voice-live-test--cancellations ()
  "Return the acknowledgment-cancel events the sidecar was sent, oldest first."
  (cl-remove-if-not (lambda (event)
                      (equal "acknowledgment-cancel" (plist-get event :event)))
                    (harness-ui-voice-live-test--events
                     harness-ui-voice-live-test--inbox)))

(defmacro harness-ui-voice-live-test-with-order (&rest body)
  "Run BODY with the prompt and the receipt recorded in the order they went out."
  (declare (indent 0))
  `(let ((harness-ui-voice-live-test--order nil))
     (harness-voice-live--handle (list :event "delegation" :id "d-1" :text "First."))
     ;; The words cross the ordinary turn grace before the prompt goes
     ;; out; the receipt follows the prompt, not the transcript.
     (harness-test-wait (lambda () (member "acknowledge" harness-ui-voice-live-test--order))
                        5 "the receipt")
     ,@body))

(ert-deftest harness-ui-voice-live-acknowledges-only-after-the-prompt ()
  "The receipt leaves after the prompt went out, for that delegation."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (let ((real-send (symbol-function 'harness-voice-live--send)))
      (cl-letf (((symbol-function 'harness-voice-live--send)
                 (lambda (object)
                   (push (plist-get object :event) harness-ui-voice-live-test--order)
                   (funcall real-send object)))
                ((symbol-function 'harness-ui-call-turn)
                 (lambda (id method _params _callback _on-error)
                   (push (list 'prompt id method) harness-ui-voice-live-test--order)
                   nil)))
        (harness-ui-voice-live-test-with-order
          ;; The hold the sidecar is told about travels with every event,
          ;; so the order is read from the prompt and the receipt.
          (should (equal '("thinking" (prompt "live-session" "session/prompt")
                           "acknowledge")
                         (seq-filter (lambda (event) (not (equal event "turn_hold")))
                                     (reverse harness-ui-voice-live-test--order)))))))
    ;; And it reached the sidecar as one object naming its delegation.
    (let ((acknowledgment
           (car (harness-ui-voice-live-test--wait-acknowledgment))))
      (should (equal "d-1" (plist-get acknowledgment :delegation)))
      (should-not (plist-get acknowledgment :text)))))

(defun harness-ui-voice-live-test--wait-acknowledgment ()
  "Wait for the acknowledge event and return it in a list."
  (let ((found nil))
    (harness-test-wait
     (lambda () (setq found (harness-ui-voice-live-test--acknowledgments)))
     5 "the acknowledge event")
    found))

(ert-deftest harness-ui-voice-live-acknowledgment-switches-off ()
  "Either setting off, or a muted or holding session, sends no receipt."
  (harness-ui-voice-live-test-with
    (let ((sent nil))
      (cl-letf (((symbol-function 'harness-ui-call-turn) (lambda (&rest _) nil))
                ((symbol-function 'harness-voice-live--active-p) (lambda () t))
                ((symbol-function 'harness-voice-live--send)
                 (lambda (object) (push object sent) t)))
        (dolist (case '((ack-off . nil) (live-off . nil) (muted . nil)
                        (holding . nil) (produced . nil)))
          (setq sent nil
                harness-voice-acknowledgment t
                harness-voice-live-acknowledgment t
                harness-voice-live--muted nil
                harness-voice-live--speech-active nil
                harness-voice-live--held nil
                harness-voice-live--nodes nil
                harness-voice-live--delegations (list (list :id "d-1" :text "Go."))
                harness-voice-live--delegation nil)
          (pcase (car case)
            ('ack-off (setq harness-voice-acknowledgment nil))
            ('live-off (setq harness-voice-live-acknowledgment nil))
            ('muted (setq harness-voice-live--muted t))
            ('holding (setq harness-voice-live--speech-active t))
            ('produced (puthash "n-1" (list :text "Working on it." :sent 0)
                                (setq harness-voice-live--nodes
                                      (make-hash-table :test 'equal)))))
          (harness-voice-live--delegate-next)
          (should-not (cl-find "acknowledge" sent :key (lambda (o) (plist-get o :event))
                               :test #'equal)))))))

(ert-deftest harness-ui-voice-live-acknowledgment-needs-its-own-turn ()
  "A receipt for another delegation, or without one, is not sent."
  (harness-ui-voice-live-test-with
    (let ((sent nil))
      (cl-letf (((symbol-function 'harness-ui-call-turn) (lambda (&rest _) nil))
                ((symbol-function 'harness-voice-live--active-p) (lambda () t))
                ((symbol-function 'harness-voice-live--send)
                 (lambda (object) (push object sent) t)))
        (setq harness-voice-live--delegation '(:id "d-2")
              harness-voice-live--nodes (make-hash-table :test 'equal))
        (harness-voice-live--acknowledge "d-1")
        (should-not sent)
        (harness-voice-live--acknowledge nil)
        (should-not sent)
        (harness-voice-live--acknowledge "d-2")
        (should (equal '((:event "acknowledge" :delegation "d-2")) sent))))))

(ert-deftest harness-ui-voice-live-acknowledgment-follows-a-cancelled-turn ()
  "C-c V drops a receipt the sidecar has not started, and nothing re-sends it."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (harness-voice-live-interrupt)
    (should (harness-ui-voice-live-test--wait-event
             harness-ui-voice-live-test--inbox "acknowledgment-cancel"))
    (should-not (harness-ui-voice-live-test--acknowledgments))))

(ert-deftest harness-ui-voice-live-acknowledgment-stops-with-the-session ()
  "Ending the session, or replacing the connection, sends no later receipt."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (harness-voice-live-stop)
    (harness-test-wait (lambda () (null harness-voice-live--state)) 5 "sidecar closed")
    ;; A request accepted after the end is heard nowhere.
    (harness-voice-live--acknowledge "d-1")
    (should-not (harness-ui-voice-live-test--acknowledgments))
    (should-not (harness-voice-live--acknowledge-possible-p "d-1"))))

(ert-deftest harness-ui-voice-live-acknowledgment-does-not-delay-the-queue ()
  "A receipt that the sidecar drops leaves the next delegation starting at once."
  (harness-ui-voice-live-test-with
    (unless (executable-find "python3") (ert-skip "Python 3 unavailable"))
    (setq harness-voice-live-command
          (harness-ui-voice-live-test--command "quiet"))
    (harness-voice-live-start)
    (harness-test-wait (lambda () (eq harness-voice-live--state 'listening)) 5 "sidecar ready")
    (let ((started (float-time)))
      (harness-voice-live--handle (list :event "delegation" :id "d-1" :text "First."))
      (harness-test-wait (lambda () (= 1 (length harness-ui-voice-live-test--calls)))
                         5 "the first prompt")
      (harness-voice-live--finish-turn "end-turn")
      (harness-voice-live--handle (list :event "delegation" :id "d-2" :text "Second."))
      (harness-test-wait (lambda () (= 2 (length harness-ui-voice-live-test--calls)))
                         5 "the second prompt")
      ;; The two turns were sent without waiting for any receipt.
      (should (< (- (float-time) started) 1.0)))
    (let ((delegations (mapcar (lambda (call)
                                 (plist-get (car (plist-get (nth 2 call) :prompt)) :text))
                               (reverse harness-ui-voice-live-test--calls))))
      (should (equal '("First." "Second.") delegations)))
    (harness-test-wait
     (lambda () (>= (length (harness-ui-voice-live-test--acknowledgments)) 2))
     5 "both receipts")))


(provide 'harness-ui-voice-live-test)
;;; harness-ui-voice-live-test.el ends here
