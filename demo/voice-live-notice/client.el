;;; client.el --- A live voice call whose reply the speech service fumbles  -*- lexical-binding: t; -*-

;;; Commentary:

;; The client half of the demo: a real compose box and the real local
;; sidecar process (`scripts/harness-voice-live-unmute'), with fake
;; pw-record and pw-play programs standing in for the sound server and
;; the stub speech service (speech_service.py) where whisper.cpp and
;; Kokoro would be.
;;
;; The one thing that is not real is the agent.  Instead of prompting a
;; session this file streams the reply the chat would stream.  MODE says
;; which reply:
;;
;;   emoji    "Loud and clear — 1, 2, 3 received. 🙂" -- the piece after
;;            the last full stop has nothing to say, and is never sent to
;;            the speech service at all.
;;   refused  a speakable sentence, which a stub started with --refuse
;;            answers with an empty body, as Kokoro answers text it has
;;            no phonemes for.  The sidecar reports a notice and the
;;            call goes on.
;;
;; Either way the next turn is spoken, which is the point: one reply the
;; speech service could not say used to end the whole call.

;;; Code:

(require 'cl-lib)
(require 'harness-ui-voice)
(require 'harness-ui-voice-providers)

(defvar harness-voice-live-notice-demo--sent nil
  "The events this client sent the sidecar, oldest first.")

(defvar harness-voice-live-notice-demo--send nil
  "The real `harness-voice-live--send', captured before the demo records it.")

(defun harness-voice-live-notice-demo--say (fmt &rest args)
  "Print FMT with ARGS on stdout, as the demo script reads it."
  (princ (apply #'format fmt args))
  (terpri)
  (flush-standard-output))

(defun harness-voice-live-notice-demo--wait (predicate seconds what)
  "Wait for PREDICATE, up to SECONDS, and signal WHAT on a timeout."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05)
      (sleep-for 0.02))
    (unless (funcall predicate)
      (error "Timed out waiting for %s" what))))

(defun harness-voice-live-notice-demo--drawn ()
  "Draw the demo's compose box."
  (harness-compose-capture)
  (let ((inhibit-read-only t) (buffer-undo-list t)
        (offset (and (harness-compose-in-p) (- (point) harness-compose-start))))
    (erase-buffer)
    (insert (propertize "Transcript\n" 'read-only t))
    (harness-compose-insert)
    (when offset (goto-char (min harness-compose-end (+ harness-compose-start offset))))))

(defun harness-voice-live-notice-demo--of (kind)
  "Return the events of KIND this client sent the sidecar."
  (cl-remove-if-not (lambda (event) (equal (plist-get event :event) kind))
                    harness-voice-live-notice-demo--sent))

(defun harness-voice-live-notice-demo--recorded (object)
  "Record OBJECT and send it to the sidecar as `harness-voice-live--send' does."
  (push (copy-sequence object) harness-voice-live-notice-demo--sent)
  (funcall harness-voice-live-notice-demo--send object))

(defun harness-voice-live-notice-demo--spoke ()
  "Return the commentary pieces the sidecar was sent, oldest first."
  (mapcar (lambda (event) (plist-get event :text))
          (reverse (harness-voice-live-notice-demo--of "commentary"))))

(defun harness-voice-live-notice-demo--reply (text)
  "Stream TEXT as the reply of a new agent turn, and finish the turn.
What `agent/turn-started' and the streamed chunks do, without a session."
  (setq harness-voice-live--nodes (make-hash-table :test 'equal)
        harness-voice-live--order nil
        harness-voice-live--turn-active t
        harness-voice-live--turn-id "demo-turn")
  (harness-voice-live--add-chunk "n-reply" text)
  (harness-voice-live--finish-turn "end-turn"))

(defun harness-voice-live-notice-demo--transcript ()
  "Print the live transcript, one trimmed line each."
  (when (buffer-live-p harness-voice-live--transcript)
    (with-current-buffer harness-voice-live--transcript
      (dolist (line (split-string
                     (buffer-substring-no-properties (point-min) (point-max))
                     "\n"))
        (unless (string-blank-p line)
          (harness-voice-live-notice-demo--say "   %s" (string-trim line)))))))

(defun harness-voice-live-notice-demo-run (root stt-url tts-url mode)
  "Run the demo with the sidecar reading ROOT and the speech URLs.
MODE is `emoji' or `refused', as the commentary of this file says.
Print what Emacs does with the reply, and with the call afterwards."
  (setq harness-directory (file-name-as-directory root)
        harness-state-directory (file-name-as-directory
                                 (or (getenv "HARNESS_DEMO_STATE")
                                     (make-temp-file "voice-notice-demo-" t)))
        harness-voice-provider 'unmute
        harness-voice--enabled t
        harness-voice--controls t
        harness-voice-effort 'medium
        harness-voice-live-startup-timeout 20
        harness-voice-unmute-stt-url stt-url
        harness-voice-unmute-tts-url tts-url
        harness-voice-unmute-threshold 0.02
        harness-voice-live-notice-demo--sent nil
        harness-voice-live-notice-demo--send (symbol-function 'harness-voice-live--send))
  (let ((buffer (get-buffer-create " *voice notice demo*"))
        (reply (if (equal mode "refused")
                   "Nothing changed; it was only a read-only check."
                 "Loud and clear — 1, 2, 3 received. 🙂")))
    (with-current-buffer buffer
      (setq-local harness-ui-session-id "voice-notice-demo")
      (harness-compose-setup
       :project (lambda () harness-directory)
       :redraw #'harness-voice-live-notice-demo--drawn)
      (harness-voice-live-notice-demo--drawn)
      (harness-voice-live-notice-demo--say "== the call · %s" mode)
      ;; The session prompt is the one stand-in: no harness server runs
      ;; a turn here.  Everything else, the sidecar's own events
      ;; included, is the real thing.
      (cl-letf (((symbol-function 'harness-ui-call-turn)
                 (lambda (_id _method _params _callback _on-error) nil))
                ((symbol-function 'harness-ui-notify) (lambda (&rest _) nil))
                ((symbol-function 'harness-ui-refresh-sessions) (lambda (&rest _) nil))
                ((symbol-function 'harness-voice-live--send)
                 #'harness-voice-live-notice-demo--recorded))
        (harness-voice-live-start)
        (harness-voice-live-notice-demo--wait
         (lambda () (eq harness-voice-live--state 'listening)) 30 "the sidecar")
        (harness-voice-live-notice-demo--say "   status · %s"
                                             (harness-voice-live--status))
        ;; The fake recorder says one sentence; the sidecar transcribes
        ;; it and delegates it, as it does a person's.  No harness server
        ;; runs the turn here, so the delegation is where it stops.
        (harness-voice-live-notice-demo--wait
         (lambda () harness-voice-live--delegation) 40 "the delegation")
        (harness-voice-live-notice-demo--say "   heard · Add a docstring to parse.")
        (harness-voice-live-notice-demo--say "   sent · the request reached the chat")
        ;; The turn the chat would stream.
        (harness-voice-live-notice-demo--reply reply)
        (harness-voice-live-notice-demo--wait
         (if (equal mode "refused")
             (lambda () harness-voice-live--notice)
           (lambda ()
             (cl-find "Loud and clear — 1, 2, 3 received."
                      (harness-voice-live-notice-demo--spoke) :test #'equal)))
         30 "the reply")
        (harness-voice-live-notice-demo--wait
         (lambda () (not (harness-voice-live--holding-output-p))) 10 "the reply to settle")
        (harness-voice-live-notice-demo--say "   said · %s"
                                             (mapconcat #'identity
                                                        (harness-voice-live-notice-demo--spoke)
                                                        " | "))
        (harness-voice-live-notice-demo--say
         "   reply · %s"
         (if (equal mode "refused")
             "a normal sentence, which the service answered with an empty body"
           "one sentence, and an emoji with nothing to say in it"))
        (harness-voice-live-notice-demo--say "   notice · %s"
                                             (or harness-voice-live--notice "none"))
        (harness-voice-live-notice-demo--say "   error · %s"
                                             (or harness-voice-live--error "none"))
        (harness-voice-live-notice-demo--say "   call · %s"
                                             (if (harness-voice-live--active-p) "still up" "ended"))
        (harness-voice-live-notice-demo--say "   status · %s"
                                             (harness-voice-live--status))
        ;; The next turn is spoken as usual: the loss was one reply's.
        (harness-voice-live-notice-demo--reply "And the next reply is spoken.")
        (harness-voice-live-notice-demo--wait
         (lambda ()
           (cl-find "And the next reply is spoken."
                    (harness-voice-live-notice-demo--spoke) :test #'equal))
         30 "the next reply")
        (harness-voice-live-notice-demo--say "   spoke · And the next reply is spoken.")
        (harness-voice-live-notice-demo--say "   call · %s"
                                             (if (harness-voice-live--active-p) "still up" "ended"))
        (harness-voice-live-notice-demo--say "== the transcript")
        (harness-voice-live-notice-demo--transcript)
        (harness-voice-live-stop)
        (harness-voice-live-notice-demo--wait
         (lambda () (not (harness-voice-live--active-p))) 10 "the stop")))
    (harness-voice-live-notice-demo--say "== done")
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  nil)

(provide 'client)
;;; client.el ends here
