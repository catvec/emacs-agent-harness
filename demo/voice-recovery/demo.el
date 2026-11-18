;;; demo.el --- Mock-only live voice recovery walkthrough  -*- lexical-binding: t; -*-

;; Load only in a disposable development Emacs.  The compose host, live
;; transport and scripted sidecar are real.  Speech and the three agent
;; ACP replies below are fixtures: no device, network model or tool runs.

(require 'cl-lib)
(require 'harness-ui-voice)
(require 'harness-ui-workspace)

(defvar harness-voice-recovery-demo--root
  (expand-file-name "../.." (file-name-directory (or load-file-name buffer-file-name))))
(defvar harness-voice-recovery-demo--buffer nil)
(defvar harness-voice-recovery-demo--step 0)
(defvar harness-voice-recovery-demo--utterance 0)
(defvar harness-voice-recovery-demo--turn 0)
(defvar harness-voice-recovery-demo--requests nil)

(defun harness-voice-recovery-demo--request (original method params callback &optional on-error)
  "Answer only this demo's agent ACP requests; pass others to ORIGINAL."
  (cond
   ((and (equal method "_harness/workspace/prompt")
         (equal (plist-get params :id) "mock-voice-workspace"))
    (push (copy-tree params) harness-voice-recovery-demo--requests)
    (cl-incf harness-voice-recovery-demo--turn)
    ;; The actual producer emits a THREAD PLIST before the UI cache sees it.
    (harness-voice-live--on-event
     "workspace/episode-changed"
     '("mock-voice-workspace" (:id "mock-thread" :title "Parser test") "mock-episode" nil))
    (harness-voice-live--on-event "agent/turn-started" '("mock-episode"))
    (with-current-buffer harness-voice-recovery-demo--buffer
      (setq harness-ui-workspace--thread "mock-thread")
      (setf (plist-get harness-ui-workspace--data :threads)
            '((:id "mock-thread" :title "Parser test" :live "mock-episode"
                    :state "live" :model "demo:scripted")))
      (setq harness-ui-workspace--entries
            (append harness-ui-workspace--entries
                    (list (list :kind "message" :thread "mock-thread" :role "user"
                                :text (plist-get params :text)))))
      (harness-ui-workspace--render))
    (funcall callback nil))
   ((and (equal (plist-get params :session-id) "mock-episode")
         (equal method "_harness/agent/activity"))
    (funcall callback (list :phase "tool" :turn-id
                           (format "mock-turn-%s" harness-voice-recovery-demo--turn))))
   ((and (equal (plist-get params :session-id) "mock-episode")
         (equal method "_harness/agent/voice-control"))
    (when (equal (plist-get params :action) "cancel")
      (harness-voice-live--on-event "agent/turn-ended" '("mock-episode" "cancelled")))
    ;; These statuses demonstrate presentation, not a real tool cancellation.
    (funcall callback '(:status requested :tools ((:tool "bash" :status requested)
                                                 (:tool "read_file" :status completed)
                                                 (:tool "elisp" :status unavailable)))))
   (t (funcall original method params callback on-error))))

(defun harness-voice-recovery-demo--say (text)
  "Deliver a scripted utterance TEXT, never microphone audio."
  (let ((id (cl-incf harness-voice-recovery-demo--utterance)))
    (harness-voice-live--handle (list :event "transcribing" :utterance id))
    (harness-voice-live--handle (list :event "user_delta" :utterance id :text text :final t))
    (harness-voice-live--handle (list :event "delegation" :utterance id
                                    :id (format "mock-d-%s" id) :text text))))

(defun harness-voice-recovery-demo--layout ()
  "Show the real workspace and audio transcript side by side."
  (delete-other-windows)
  (set-window-buffer (selected-window) harness-voice-recovery-demo--buffer)
  (let ((other (split-window-right)))
    (set-window-buffer other (harness-voice-live--transcript-buffer)))
  (with-current-buffer harness-voice-recovery-demo--buffer
    (goto-char harness-compose-start)))

(defun harness-voice-recovery-demo-next ()
  "Advance the mock walkthrough: hold, send, interrupt, new work, cancel.
No speech service, model or physical audio device is used."
  (interactive)
  (with-current-buffer harness-voice-recovery-demo--buffer
    (pcase (cl-incf harness-voice-recovery-demo--step)
      (1
       (harness-voice-recovery-demo--say "Fix  only the parser test.")
       (harness-voice-recovery-demo--say "Hold on."))
      (2
       (harness-voice-recovery-demo--say "Oh, actually send it.")
       (harness-voice-live--speak "Synthetic reply in progress." "mock-reply"))
      (3
       (harness-voice-live-interrupt)
       (harness-voice-live--on-update
        "mock-episode" '(:sessionUpdate "agent_message_chunk" :_harness (:nodeId "mock-late")
                         :content (:text "Late synthetic reply.")))
       (harness-voice-live--on-event "agent/turn-ended" '("mock-episode" "end-turn")))
      (4
       (harness-voice-recovery-demo--say "Second request.")
       (harness-voice-live-send-now))
      (5 (harness-voice-live-cancel))
      (_ (user-error "Demo complete"))))
  (harness-voice-recovery-demo--layout))

(defun harness-voice-recovery-demo ()
  "Start the mock-only walkthrough in this disposable development Emacs.
C-c C-n advances; the ordinary live controls remain interactive."
  (interactive)
  (harness-voice-live-stop)
  (when (buffer-live-p harness-voice-recovery-demo--buffer)
    (kill-buffer harness-voice-recovery-demo--buffer))
  (when (buffer-live-p harness-voice-live--transcript)
    (kill-buffer harness-voice-live--transcript))
  (setq harness-voice-provider 'custom
        harness-voice-live-command
        (list "python3" "-u" (expand-file-name "scripts/harness-voice-live-fixture"
                                              harness-voice-recovery-demo--root)
              "--hold-speaking")
        harness-voice-live-follow-selection nil
        harness-voice-live-turn-grace 20
        harness-voice-recovery-demo--step 0 harness-voice-recovery-demo--utterance 0
        harness-voice-recovery-demo--turn 0 harness-voice-recovery-demo--requests nil)
  (unless (advice-member-p #'harness-voice-recovery-demo--request 'harness-ui-call)
    (advice-add 'harness-ui-call :around #'harness-voice-recovery-demo--request))
  (advice-add 'harness-compose-fetch-completions :override #'ignore)
  ;; Fixture catalogue: the walkthrough is independent of a server fetch.
  (setq harness-ui--tools (make-hash-table :test 'equal))
  (dolist (spec '((:name "bash" :label "Bash") (:name "read_file" :label "Read file")
                  (:name "elisp" :label "Emacs Lisp")))
    (puthash (plist-get spec :name) spec harness-ui--tools))
  (setq harness-voice-recovery-demo--buffer (get-buffer-create "*Voice recovery · Mock*"))
  (with-current-buffer harness-voice-recovery-demo--buffer
    (harness-ui-workspace-mode)
    (setq harness-ui-workspace--id "mock-voice-workspace"
          harness-ui-workspace--thread nil harness-ui-workspace--state 'ready
          harness-ui-workspace--data
          (list :id "mock-voice-workspace" :name "Voice recovery · Mock" :root default-directory
                :model "demo:scripted" :threads nil)
          harness-ui-workspace--entries nil)
    (local-set-key (kbd "C-c C-n") #'harness-voice-recovery-demo-next)
    (harness-ui-workspace--render)
    (harness-voice-mode 1)
    (harness-voice-live-start)
    (let ((deadline (+ (float-time) 5)))
      (while (and (not (eq harness-voice-live--state 'listening))
                  (< (float-time) deadline))
        (accept-process-output nil 0.02))
      (unless (eq harness-voice-live--state 'listening)
        (user-error "Demo sidecar unavailable"))))
  (harness-voice-recovery-demo--layout))

(provide 'voice-recovery-demo)
;;; demo.el ends here
