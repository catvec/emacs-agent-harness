;;; harness-merge.el --- Merge queue for forked sessions -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A session that works in a worktree (or a fork in general) can ask to
;; merge its changes back into its parent session's working directory.
;; Requests queue on the parent; only one child holds the merge window at
;; a time.  While it does, the parent refuses new turns (with a hint) so
;; the two agents never write over each other, and the child is told, in a
;; normal agent turn, to apply its changes and resolve any conflicts
;; itself.  When the child's turn ends the window is released and the next
;; request in the queue is granted.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-session)
(require 'harness-tools)

(defcustom harness-merge-lock-timeout 900
  "Seconds before a stuck merge window is released."
  :type 'natnum)

(defun harness-merge--session (session-id)
  "Load SESSION-ID, or nil."
  (ignore-errors (harness-session-load session-id)))

(defun harness-merge-queue (parent-id)
  "The pending merge requests of PARENT-ID."
  (let ((parent (harness-merge--session parent-id)))
    (append (and parent (harness-session-state-get parent 'merge-queue)) nil)))

(defun harness-merge-lock (parent-id)
  "The child currently merging into PARENT-ID, or nil."
  (let ((parent (harness-merge--session parent-id)))
    (and parent (harness-session-state-get parent 'merge-lock))))

(defun harness-merge--set-queue (parent queue)
  "Store QUEUE on PARENT."
  (harness-session-state-set parent 'merge-queue (vconcat queue)))

(defun harness-merge--hint (session-id text &optional level)
  "Add a system hint to SESSION-ID."
  (harness-service-call "session" 'system-hint
                        :session-id session-id :text text :level (or level "info")))

(defun harness-merge--status (session-id)
  "Session status string of SESSION-ID."
  (let ((info (ignore-errors (harness-service-call "session" 'info :session-id session-id))))
    (or (plist-get info :status) "idle")))

(defun harness-merge-request (child-id parent-id &optional message)
  "Queue a merge of CHILD-ID's work into PARENT-ID.
MESSAGE is shown to the child when its window opens."
  (let ((parent (harness-merge--session parent-id)))
    (if (null parent)
        (signal 'harness-user-error (list (format "No parent session %s" parent-id)))
      (let* ((queue (harness-merge-queue parent-id))
             (existing (seq-find (lambda (request)
                                   (equal (plist-get request :child) child-id))
                                 queue)))
        (unless existing
          (setq queue (append queue (list (list :child child-id
                                                :message message
                                                :time (harness-iso-time)
                                                :status "queued"))))
          (harness-merge--set-queue parent queue))
        (harness-merge--hint parent-id
                             (format "Session %s asked to merge its changes."
                                     (substring child-id 0 8)))
        (harness-merge-process parent-id)
        (let ((lock (harness-merge-lock parent-id)))
          (if (equal lock child-id)
              (list :granted t)
            (list :queued t :position (length (harness-merge-queue parent-id)))))))))

(defun harness-merge--release (parent-id child-id reason)
  "Release PARENT-ID's merge window if it belongs to CHILD-ID.
The event hook and the turn callback both release, so a stale release
must not clear a newer child's window."
  (let ((parent (harness-merge--session parent-id)))
    (when (and parent child-id
               (equal (harness-session-state-get parent 'merge-lock) child-id))
      (harness-session-state-delete parent 'merge-lock)
      (let ((child (harness-merge--session child-id)))
        (when child
          (harness-session-remove-directory child (harness-session-cwd parent))
          (harness-session-save child)))
      (harness-merge--hint parent-id
                           (format "Merge window closed (%s)." reason)))))

(defun harness-merge--grant (parent child-id request)
  "Give CHILD-ID the merge window into PARENT."
  (let* ((parent-id (harness-session-id parent))
         (child (harness-merge--session child-id)))
    (if (null child)
        (progn
          (harness-merge--hint parent-id
                               (format "Session %s vanished; dropping its merge request."
                                       (substring child-id 0 8))
               "warn")
          (harness-merge-process parent-id))
      (harness-session-state-set parent 'merge-lock child-id)
      (harness-session-add-directory child (harness-session-cwd parent))
      (harness-session-save child)
      (harness-merge--hint
       parent-id
       (format "Session %s is merging into %s now; this session pauses until it finishes."
               (substring child-id 0 8)
               (abbreviate-file-name (harness-session-cwd parent))))
      (harness-merge--hint child-id
                           (format "Merge window open: apply your changes to %s."
                                   (abbreviate-file-name (harness-session-cwd parent))))
      (run-at-time harness-merge-lock-timeout nil
                   (lambda ()
                     (when (equal (harness-merge-lock parent-id) child-id)
                       (harness-merge--release parent-id child-id "timed out")
                       (harness-merge-process parent-id))))
      (harness-deferred-then
       (harness-service-call
        "agent" 'prompt
        :session-id child-id
        :prompt (vector
                 (list :type "text"
                       :text (concat
                              (format "You have the merge window: apply your changes to the parent session's working directory %s.\n\n"
                                      (harness-session-cwd parent))
                              "Work there directly (it is now an allowed directory): copy or apply your edits, "
                              "run the tests, and resolve any conflicts yourself.  Do not touch unrelated files, "
                              "and finish with a short report of what you merged."
                              (if-let* ((message (plist-get request :message)))
                                  (format "\n\nNote from the queue: %s" message)
                                "")))))
       (lambda (_stop)
         (harness-merge--release parent-id child-id "merged")
         (harness-merge-process parent-id))
       (lambda (error)
         (harness-merge--hint parent-id
                              (format "Merge by %s failed: %S"
                                      (substring child-id 0 8) error)
                              "error")
         (harness-merge--release parent-id child-id "failed")
         (harness-merge-process parent-id))))))

(defun harness-merge-process (parent-id)
  "Grant the next merge request of PARENT-ID when the parent is idle."
  (let* ((parent (harness-merge--session parent-id))
         (queue (harness-merge-queue parent-id)))
    (when (and parent queue
               (null (harness-merge-lock parent-id))
               (equal (harness-merge--status parent-id) "idle"))
      (let* ((request (car queue))
             (child-id (plist-get request :child)))
        (harness-merge--set-queue parent (cdr queue))
        (harness-merge--grant parent child-id request)))
    queue))

(defun harness-merge-cancel (parent-id child-id)
  "Drop CHILD-ID's pending merge request from PARENT-ID."
  (let ((parent (harness-merge--session parent-id)))
    (when parent
      (harness-merge--set-queue
       parent
       (seq-remove (lambda (request)
                     (equal (plist-get request :child) child-id))
                   (harness-merge-queue parent-id))))
    (when (equal (harness-merge-lock parent-id) child-id)
      (harness-merge--release parent-id child-id "cancelled"))))

;;; Agent side

(defun harness-merge-tool (arguments context)
  "Tool handler: ask to merge this session into its parent."
  (let* ((child-id (harness-tool-context-session-id context))
         (info (ignore-errors (harness-service-call "session" 'info :session-id child-id)))
         (parent-id (plist-get info :parentId)))
    (cond
     ((null parent-id)
      (harness-tool-error-result
       "This session has no parent; merge requests need a session that was forked or spawned."))
     (t
      (let ((result (harness-merge-request child-id parent-id
                                           (plist-get arguments :message))))
        (if (plist-get result :granted)
            "You now have the merge window. Apply your changes to the parent's working directory and resolve conflicts."
          (format "Queued for merge (position %s in the parent's queue). You will be asked to merge when the window opens."
                  (or (plist-get result :position) 1))))))))

(defun harness-merge-service-request (&rest args)
  "Service: queue a merge request."
  (harness-merge-request (plist-get args :child-id)
                         (plist-get args :parent-id)
                         (plist-get args :message)))

(defun harness-merge-service-process (&rest args)
  "Service: grant the next merge request of a parent."
  (harness-merge-process (plist-get args :parent-id)))

(defun harness-merge-service-queue (&rest args)
  "Service: pending merge requests."
  (vconcat (harness-merge-queue (plist-get args :parent-id))))

(defun harness-merge-service-lock (&rest args)
  "Service: the child holding the merge window."
  (harness-merge-lock (plist-get args :parent-id)))

(defun harness-merge-service-cancel (&rest args)
  "Service: drop a merge request."
  (harness-merge-cancel (plist-get args :parent-id) (plist-get args :child-id)))

(defun harness-merge--on-turn-finished (payload)
  "React to PAYLOAD: keep the queue moving."
  (let ((session-id (plist-get payload :session-id)))
    (when session-id
      ;; A finished turn makes this session a possible parent, and a
      ;; locked child that just finished releases its window.
      (let ((info (ignore-errors (harness-service-call "session" 'info :session-id session-id))))
        (when-let* ((parent-id (plist-get info :parentId)))
          (when (equal (harness-merge-lock parent-id) session-id)
            (harness-merge--release parent-id session-id "finished")
            (harness-merge-process parent-id))))
      (harness-merge-process session-id))))

(defun harness-merge-setup ()
  "Set up the merge module."
  (harness-on 'agent-turn-finished #'harness-merge--on-turn-finished
              :module 'harness-merge)
  (harness-service-register
   "merge"
   :module 'harness-merge
   :doc "The merge queue: children request to write into a parent."
   :methods '((request . harness-merge-service-request)
              (process . harness-merge-service-process)
              (queue . harness-merge-service-queue)
              (lock . harness-merge-service-lock)
              (cancel . harness-merge-service-cancel)))
  (harness-tool-register
   "merge"
   :description (concat
                 "Ask the parent session for the merge window so your work is applied to its "
                 "working directory.  Only one child merges at a time; you will be told when "
                 "the window opens, and you resolve conflicts yourself.")
   :schema '(:type "object"
             :properties (:message (:type "string"
                                  :description "Optional note for the parent.")))
   :kind 'other
   :handler #'harness-merge-tool))

(defun harness-merge-teardown ()
  "Tear down the merge module."
  (harness-service-unregister "merge")
  (puthash 'agent-turn-finished
           (seq-remove (lambda (handler)
                         (eq (harness-event-handler-module handler) 'harness-merge))
                       (gethash 'agent-turn-finished harness-core--event-handlers))
           harness-core--event-handlers)
  (harness-tool-unregister "merge"))

(harness-module-define 'harness-merge
  :version harness-version
  :description "Merge queue for forked and worktree sessions."
  :requires '((harness-core "0.1.0")
              (harness-session "0.1.0")
              (harness-tools "0.1.0")
              (harness-agent "0.1.0"))
  :provides '(harness-merge)
  :setup #'harness-merge-setup
  :teardown #'harness-merge-teardown)

(provide 'harness-merge)
;;; harness-merge.el ends here
