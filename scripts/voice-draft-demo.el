;;; voice-draft-demo.el --- Scripted dictation into a compose draft -*- lexical-binding: t; -*-

;; Loaded only in the development harness by scripts/voice-draft-demo.sh.
;; Every speech event below is scripted by the bundled fixture sidecar; no
;; microphone, speech service or paid model is involved.  The board's real
;; compose box, its real route and its real submit path are what it drives.

(require 'harness-ui-voice)
(require 'harness-ui-voice-live)
(require 'harness-ui-tasks)

(defvar harness-voice-draft-demo--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
(defvar harness-voice-draft-demo--buffer nil)
(defvar harness-voice-draft-demo--frame nil)
(defvar harness-voice-draft-demo--error nil)

(defun harness-voice-draft-demo--say (text)
  "Report TEXT in the echo area and the messages buffer."
  (message "Voice draft demo · %s" text))

(defun harness-voice-draft-demo--frame ()
  "Return the demo frame, making it visible and selected for the walkthrough."
  (or (and (frame-live-p harness-voice-draft-demo--frame)
           harness-voice-draft-demo--frame)
      (setq harness-voice-draft-demo--frame (selected-frame))))

(defun harness-voice-draft-demo--ready (attempt)
  "Start the scripted call in the board's box, bounded by ATTEMPT."
  (let ((buffer harness-voice-draft-demo--buffer))
    (when (buffer-live-p buffer)
      (with-selected-frame (harness-voice-draft-demo--frame)
        (with-current-buffer buffer
          (cond
           ((not (harness-compose-live-p))
            (if (< attempt 100)
                (run-at-time 0.1 nil #'harness-voice-draft-demo--ready (1+ attempt))
              (setq harness-voice-draft-demo--error "Board box unavailable")))
           (t
            (setq harness-voice--controls t)
            (harness-voice--refresh)
            (harness-voice-live-start)
            (harness-voice-draft-demo--say
             (format "started · %s" (or harness-voice-live--route-name "no route"))))))))))

(defun harness-voice-draft-demo-start ()
  "Open the task board and start a scripted call in its compose box."
  (interactive)
  (setq harness-voice-provider 'fixture
        harness-voice--controls t
        harness-voice-draft-demo--error nil)
  (let ((buffer (harness-tasks (or (and (boundp 'harness-dev-root) harness-dev-root)
                                   default-directory))))
    (setq harness-voice-draft-demo--buffer buffer)
    (with-selected-frame (harness-voice-draft-demo--frame)
      (switch-to-buffer buffer)
      (goto-char (point-max)))
    (harness-voice-draft-demo--ready 0)
    buffer))

(defun harness-voice-draft-demo-state ()
  "Return what the call and the box say now, as a plist."
  (interactive)
  (let ((buffer harness-voice-draft-demo--buffer))
    (list :route harness-voice-live--route-kind
          :name harness-voice-live--route-name
          :draft harness-voice-live--route-draft
          :generation harness-voice-live--route-generation
          :state harness-voice-live--state
          :error (or harness-voice-live--error harness-voice-draft-demo--error)
          :notice harness-voice-live--notice
          :box (and (buffer-live-p buffer)
                    (with-current-buffer buffer (harness-compose-text)))
          :context (and (buffer-live-p buffer)
                        (with-current-buffer buffer (harness-compose-context)))
          :controls (and (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (substring-no-properties (harness-voice--controls)))))))

(defun harness-voice-draft-demo-show ()
  "Show the board's box and its voice transcript in the demo frame."
  (interactive)
  (let ((buffer harness-voice-draft-demo--buffer))
    (when (buffer-live-p buffer)
      (with-selected-frame (harness-voice-draft-demo--frame)
        (switch-to-buffer buffer)
        (goto-char (point-max))))
    buffer))

(defun harness-voice-draft-demo-submit ()
  "Submit what the box holds, as C-c C-c does, and report the task.
The board is shown again afterwards, so the walkthrough stays on the
surface the words became a task on."
  (interactive)
  (let ((buffer harness-voice-draft-demo--buffer))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (harness-ui-tasks-submit))
      (harness-voice-draft-demo-show)
      (harness-voice-draft-demo--say "submitted"))))

(defun harness-voice-draft-demo-end ()
  "End the scripted call."
  (interactive)
  (when (harness-voice-live--active-p) (harness-voice-live-stop)))

(defun harness-voice-draft-demo-switch ()
  "Switch the board's one box to a search, as the board's search key does.
It is the race the review reported: the same buffer, another draft."
  (interactive)
  (let ((buffer harness-voice-draft-demo--buffer))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (harness-ui-tasks--set-compose "" '(search)))
      (harness-voice-draft-demo--say "switched to search"))))

(defun harness-voice-draft-demo-restore ()
  "Give the board's box its new-task purpose back."
  (interactive)
  (let ((buffer harness-voice-draft-demo--buffer))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (harness-ui-tasks-compose-reset))
      (harness-voice-draft-demo--say "back to a new task"))))

(defun harness-voice-draft-demo-submit-reset ()
  "Submit what the box holds, as C-c C-c does, and show the next draft.
The lifecycle race: the box comes back to a new task, the purpose it
had, and only the draft's nonce says it is another draft."
  (interactive)
  (let ((buffer harness-voice-draft-demo--buffer))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (harness-ui-tasks-submit))
      (harness-voice-draft-demo-show)
      (harness-voice-draft-demo--say "submitted; the box is a new draft"))))

(provide 'voice-draft-demo)
;;; voice-draft-demo.el ends here
