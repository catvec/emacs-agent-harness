;;; notes-demo.el --- Watch who writes a workspace note  -*- lexical-binding: t; -*-
;;
;; A demo of the workspace's memory writing, with no scribe:
;;
;;   scripts/notes-demo.sh
;;
;; It runs three turns of one workspace against the demo provider and
;; prints, for each, the provider requests the turn made while it ran and
;; the requests made after it had ended -- zero, which is the point: no
;; second model reads a finished turn.  The first two turns settle
;; nothing, so they leave the thread's page empty.  The third one calls
;; `knowledge_write' the way an agent does when a decision is made, so
;; the note is on the page with its provenance, written by the turn that
;; decided it.

(require 'cl-lib)

;; The state the test helpers keep, as the workspace suite declares it.
(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-workspace--table)
(defvar harness-workspace-model)
(defvar harness-workspace-permission-mode)
(defvar harness-workspace-non-interactive)
(defvar harness-workspace--loaded)
(defvar harness-workspace--subscribed)
(defvar harness-logseq-directory)
(defvar harness-workspace-knowledge--pages)
(defvar harness-workspace-knowledge--pending)
(defvar harness-workspace-knowledge--status-cache)
(defvar harness-workspace-knowledge--vectors)
(defvar harness-workspace-knowledge--subscribed)
(defvar harness-workspace-knowledge-dream)

(defvar notes-demo--requests 0
  "How many provider requests the workspace made so far.")

(defvar notes-demo--turn 0
  "Which turn is running, counting from one.")

(defun notes-demo--reply (_request)
  "Answer a turn: a plain reply, or the third turn's decision.
The third turn's script is what an agent runs when it decides something
worth keeping: it calls `knowledge_write', reads the answer, and then
replies.  A tool call stops the turn for one more request, and that
request is still the agent's."
  (cl-incf notes-demo--requests)
  (if (= notes-demo--turn 3)
      '((:type text :delta "Quartz it is; I wrote that down.\n")
        (:type tool-call :id "demo-note-1" :name "knowledge_write"
         :input (:text "Chose quartz for the countertop."))
        (:type text :delta "Noted the choice on the thread's page.\n")
        (:type done :stop-reason end-turn))
    '((:type text :delta "Noted.\n")
      (:type done :stop-reason end-turn))))

(defun notes-demo--wait (pred &optional timeout)
  "Wait for PRED, or give up after TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (sit-for 0.005))))

(defun notes-demo--idle (id)
  "Wait until workspace ID's live episode has no turn running."
  (let ((thread (car (plist-get (harness-call 'workspace/get id) :threads))))
    (when (plist-get thread :live)
      (notes-demo--wait (lambda ()
                          (not (harness-call 'agent/running
                                             (plist-get thread :live))))
                        30))))

(defmacro notes-demo--with (&rest body)
  "Run BODY with a fresh workspace and the demo's own scripts."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-provider-demo-script-override #'notes-demo--reply)
           (harness-provider-demo--delay 0.002)
           (harness-workspace-model "demo:scripted")
           (harness-workspace-permission-mode 'auto)
           (harness-workspace-non-interactive t)
           (harness-naming-auto nil)
           (harness-workspace-knowledge-dream nil)
           (harness-logseq-directory (expand-file-name "graph/" harness-state-directory))
           (default-directory harness-state-directory))
       (setq harness-workspace--subscribed nil
             notes-demo--requests 0
             notes-demo--turn 0)
       (dolist (module '(store project config provider provider-demo tools session agent
                               acp logseq memory workspace-knowledge workspace-box workspace))
         (harness-test-load-module module))
       (clrhash harness-sessions)
       (clrhash harness-agent--turns)
       (clrhash harness-workspace--table)
       (setq harness-workspace--loaded nil
             harness-workspace-knowledge--subscribed nil)
       (clrhash harness-workspace-knowledge--pages)
       (clrhash harness-workspace-knowledge--pending)
       (clrhash harness-workspace-knowledge--status-cache)
       (clrhash harness-workspace-knowledge--vectors)
       (harness-add-filter 'permission/decide
                           (lambda (_details next &rest _)
                             (funcall next (list :behavior 'allow)))
                           10)
       (unwind-protect (progn ,@body)
         (harness-call 'store/sqlite-close)))))

(defun notes-demo--page-blocks (id page)
  "Return the blocks of PAGE in workspace ID that carry words."
  (cl-remove-if (lambda (block) (string-blank-p (or (plist-get block :text) "")))
                (plist-get (harness-call 'knowledge/page id page) :blocks)))

(defun notes-demo--send (id text)
  "Send TEXT to workspace ID, wait out the turn, and print what it left."
  (cl-incf notes-demo--turn)
  (let ((before notes-demo--requests))
    (harness-call 'workspace/prompt id text)
    (harness-workspace-test-wait-for
     (lambda () (harness-workspace-test-assistant-messages id)))
    (notes-demo--idle id)
    ;; The count when the turn ended, then again once anything the turn
    ;; left queued has had its chance to run.
    (let* ((during (- notes-demo--requests before))
           (at-end notes-demo--requests)
           (thread (car (plist-get (harness-call 'workspace/get id) :threads)))
           (page (plist-get thread :page)))
      (accept-process-output nil 0.5)
      (let ((after (- notes-demo--requests at-end))
            (blocks (notes-demo--page-blocks id page)))
        (princ (format "\n%s\n" text))
        (princ (format "  requests while the turn ran: %d\n" during))
        (princ (format "  requests after it ended:     %d\n" after))
        (if (null blocks)
            (princ "  the thread's page holds no note\n")
          (dolist (block blocks)
            (princ (format "  note: %s\n        from %s (role %s)\n"
                           (plist-get block :text)
                           (or (cdr (assoc "source-session"
                                           (plist-get block :properties)))
                               "no session")
                           (or (cdr (assoc "role" (plist-get block :properties)))
                               "?")))))))))

(defun notes-demo-main ()
  "Print the requests and the page of three workspace turns."
  (princ "\n=== who writes a workspace note\n")
  (notes-demo--with
    (let* ((workspace (harness-call 'workspace/create
                                    :name "Home"
                                    :root (expand-file-name "home/" harness-state-directory)
                                    :model "demo:scripted"))
           (id (plist-get workspace :id)))
      (notes-demo--send id "The tile is matte.")
      (notes-demo--send id "The grout is warm grey.")
      (notes-demo--send id "Let us go with quartz for the countertop.")
      (princ (format "\n%d provider requests for 3 turns, and none after one ended\n"
                     notes-demo--requests))
      (princ "the agent's own knowledge_write is the only writer\n"))))

;;; notes-demo.el ends here
