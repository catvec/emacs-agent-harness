;;; harness-merge.el --- Merge queue for worktree sessions  -*- lexical-binding: t; -*-

;;; Commentary:

;; A child session working in a git worktree asks to be merged back
;; into its parent's working directory with `merge/enqueue'.  Requests
;; queue per parent and are served one at a time: the head of the queue
;; takes the parent's lock when the parent is idle, or when its running
;; turn reaches a step boundary (the `agent/step' and `agent/before-turn'
;; filters hold the parent until the lock is free again).
;;
;; The merge itself is `git merge --no-ff --no-edit CHILD-BRANCH' in the
;; parent's cwd.  A clean merge releases the lock at once.  A conflict
;; keeps the lock: the child is told which files conflict, its jail is
;; widened to the parent's directory, and it calls the `merge_done' tool
;; once it has resolved and committed the merge.  A safety timer aborts
;; a merge nobody finishes.
;;
;; Everything runs asynchronously through `harness-run-command'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

;;;; Customisation

(defcustom harness-merge-git-program "git"
  "Name of the git executable used for merges."
  :type 'string :group 'harness)

(defcustom harness-merge-hold-timeout 1800
  "Seconds a conflicted merge may hold the parent before it is aborted."
  :type 'number :group 'harness)

;;;; State

(defvar harness-merge--queues (make-hash-table :test 'equal)
  "Parent session id -> list of queue entries, oldest first.
An entry is (:child ID :parent ID :status queued|merging|conflict
:requested FLOAT :message STRING :branch NAME :files (…)).")

(defvar harness-merge--locks (make-hash-table :test 'equal)
  "Parent session id -> child session id holding the merge lock.")

(defvar harness-merge--holds (make-hash-table :test 'equal)
  "Parent session id -> list of NEXT continuations of held agent steps.")

(defvar harness-merge--timers (make-hash-table :test 'equal)
  "Parent session id -> safety timer of the merge in progress.")

;;;; Helpers

(defun harness-merge--session (id)
  "Return the session plist of ID or nil."
  (and id (harness-method-exists-p 'session/get)
       (ignore-errors (harness-call 'session/get id))))

(defun harness-merge--label (id)
  "Return a short label for session ID (its name or a short id)."
  (let ((s (harness-merge--session id)))
    (or (plist-get s :name) (substring id 0 (min 8 (length id))))))

(defun harness-merge--hint (id text)
  "Add hint TEXT to session ID when it exists."
  (when (harness-merge--session id)
    (ignore-errors (harness-call 'session/hint id text))))

(defun harness-merge--steer (id text)
  "Send TEXT to session ID as a steering (or fresh) prompt."
  (when (and (harness-merge--session id) (harness-method-exists-p 'agent/prompt))
    (harness-catch (harness-call-async 'agent/prompt id text)
                   (lambda (e) (harness-log 'warn "merge: steering %s failed: %s" id (harness-error-message e)) nil))))

(defun harness-merge--entry (child-id)
  "Return the queue entry of CHILD-ID, or nil."
  (let (found)
    (maphash (lambda (_ entries)
               (unless found
                 (setq found (cl-find child-id entries :key (lambda (e) (plist-get e :child)) :test #'equal))))
             harness-merge--queues)
    found))

(defun harness-merge--set (entry &rest props)
  "Set PROPS on the queue ENTRY in place (it is shared with the queue)."
  (cl-loop for (k v) on props by #'cddr do (plist-put entry k v))
  entry)

(defun harness-merge--git (cwd &rest args)
  "Run git ARGS in CWD; return a promise of (:exit :stdout :stderr)."
  (harness-run-command (append (list harness-merge-git-program "-C" (directory-file-name cwd)) args)
                       :cwd cwd :name "harness-merge-git"))

(defun harness-merge--in-git-repo-p (dir)
  "Non-nil when DIR is inside a git repository or worktree."
  (and dir (file-directory-p dir)
       (locate-dominating-file dir ".git")))

(defun harness-merge--parent-running-p (parent-id)
  "Non-nil while PARENT-ID has a running turn."
  (if (harness-method-exists-p 'agent/running)
      (harness-call 'agent/running parent-id)
    (eq (plist-get (harness-merge--session parent-id) :status) 'running)))

(defun harness-merge--public (entry position)
  "Return the public plist of queue ENTRY at POSITION."
  (list :child (plist-get entry :child) :parent (plist-get entry :parent)
        :position position :status (plist-get entry :status)
        :requested (plist-get entry :requested)))

;;;; Methods

(harness-defmethod merge/enqueue (child-id parent-id &rest opts)
  "Queue CHILD-ID's worktree branch for a merge into PARENT-ID's cwd.
OPTS may carry `:message' for the log.  The child must have a
`:worktree' and the parent a `:cwd' inside a git repository.  Return
the 1-based queue position.  Emits `merge/queued'."
  (let ((child (harness-merge--session child-id))
        (parent (harness-merge--session parent-id)))
    (unless child (signal 'harness-error (list (format "No session %s" child-id))))
    (unless parent (signal 'harness-error (list (format "No session %s" parent-id))))
    (unless (plist-get child :worktree)
      (signal 'harness-error (list (format "Session %s has no worktree; only worktree sessions can be merged" child-id))))
    (unless (harness-merge--in-git-repo-p (plist-get child :cwd))
      (signal 'harness-error (list (format "The child's directory %s is not a git worktree" (plist-get child :cwd)))))
    (unless (harness-merge--in-git-repo-p (plist-get parent :cwd))
      (signal 'harness-error (list (format "The parent's directory %s is not inside a git repository" (plist-get parent :cwd)))))
    (when (harness-merge--entry child-id)
      (signal 'harness-error (list (format "Session %s is already queued for a merge" child-id))))
    (let* ((entry (list :child child-id :parent parent-id :status 'queued
                        :requested (float-time) :message (plist-get opts :message)))
           (entries (append (gethash parent-id harness-merge--queues) (list entry)))
           (position (length entries)))
      (puthash parent-id entries harness-merge--queues)
      (harness-emit 'merge/queued child-id parent-id position)
      (harness-merge--hint parent-id (format "Merge requested by %s (queue position %d)"
                                             (harness-merge--label child-id) position))
      (unless (harness-merge--parent-running-p parent-id)
        (harness-run-soon #'harness-merge--pump parent-id))
      position)))

(harness-defmethod merge/queue (parent-id)
  "Return the merge queue of PARENT-ID.
Each item is (:child :parent :position :status :requested)."
  (cl-loop for e in (gethash parent-id harness-merge--queues) for i from 1
           collect (harness-merge--public e i)))

(harness-defmethod merge/status (child-id)
  "Return the merge status of CHILD-ID (queued, merging, conflict) or nil."
  (plist-get (harness-merge--entry child-id) :status))

(harness-defmethod merge/cancel (child-id)
  "Remove CHILD-ID from its merge queue.
A merge in progress is aborted with `git merge --abort'.  Return
non-nil when an entry was removed."
  (let ((entry (harness-merge--entry child-id)))
    (when entry
      (let ((parent-id (plist-get entry :parent)))
        (if (memq (plist-get entry :status) '(merging conflict))
            (harness-then (harness-merge--git (plist-get (harness-merge--session parent-id) :cwd) "merge" "--abort")
                          (lambda (_) (harness-merge--finish entry 'cancelled)))
          (harness-merge--finish entry 'cancelled)))
      t)))

;;;; Scheduling

(defun harness-merge--release-holds (parent-id)
  "Let every held step of PARENT-ID continue."
  (let ((nexts (gethash parent-id harness-merge--holds)))
    (remhash parent-id harness-merge--holds)
    (dolist (next (nreverse nexts))
      (condition-case err
          (funcall next (list :proceed t))
        (error (harness-log 'error "merge: releasing a held step failed: %S" err))))))

(defun harness-merge--pump (parent-id)
  "Start the next merge of PARENT-ID, or release its held steps when done."
  (cond
   ((gethash parent-id harness-merge--locks) nil)
   (t (let ((entry (cl-find 'queued (gethash parent-id harness-merge--queues)
                            :key (lambda (e) (plist-get e :status)))))
        (if entry
            (harness-merge--start entry)
          (harness-merge--release-holds parent-id))))))

(defun harness-merge--hold (value next session)
  "Hold the step of SESSION (a `agent/step' or `agent/before-turn' handler).
When merges are queued or in progress for the session, keep NEXT until
the queue drains; otherwise pass VALUE on.  Always returns nil: the
filter core would adopt a returned promise as the gate value."
  (let ((parent-id (plist-get session :id)))
    (if (or (gethash parent-id harness-merge--locks)
            (cl-some (lambda (e) (eq (plist-get e :status) 'queued))
                     (gethash parent-id harness-merge--queues)))
        (progn
          (push next (gethash parent-id harness-merge--holds))
          (let ((waiting (cl-find-if (lambda (e) (memq (plist-get e :status) '(queued merging conflict)))
                                     (gethash parent-id harness-merge--queues))))
            (when waiting
              (harness-merge--hint parent-id (format "Pausing for merge from %s…"
                                                     (harness-merge--label (plist-get waiting :child))))))
          (harness-merge--pump parent-id))
      (funcall next value))
    nil))

(defun harness-merge--on-turn-ended (session-id _reason)
  "Serve the merge queue of SESSION-ID now that it is idle."
  (when (and (gethash session-id harness-merge--queues)
             (not (gethash session-id harness-merge--locks)))
    (harness-run-soon #'harness-merge--pump session-id)))

;;;; The merge

(defun harness-merge--start (entry)
  "Take the lock for ENTRY and run its merge."
  (let* ((child-id (plist-get entry :child))
         (parent-id (plist-get entry :parent))
         (child (harness-merge--session child-id))
         (parent (harness-merge--session parent-id)))
    (cond
     ((or (null child) (null parent))
      (harness-merge--finish entry 'failed "a session disappeared"))
     (t
      (puthash parent-id child-id harness-merge--locks)
      (harness-merge--set entry :status 'merging)
      (harness-emit 'merge/started child-id parent-id)
      (let ((child-cwd (plist-get child :cwd))
            (parent-cwd (plist-get parent :cwd)))
        (harness-then
         (harness-merge--git child-cwd "status" "--porcelain")
         (lambda (status)
           (cond
            ((not (eql (plist-get status :exit) 0))
             (harness-merge--finish entry 'failed (format "git status failed in the worktree: %s"
                                                          (string-trim (plist-get status :stderr)))))
            ((not (string-empty-p (string-trim (plist-get status :stdout))))
             (harness-merge--steer child-id
                                   (format "Your merge into %s was not started: the worktree %s has uncommitted changes. Commit your changes in the worktree first, then request the merge again."
                                           parent-cwd child-cwd))
             (harness-merge--finish entry 'failed "commit your changes in the worktree first"))
            (t
             (harness-then
              (harness-merge--git child-cwd "rev-parse" "--abbrev-ref" "HEAD")
              (lambda (rev)
                (let ((branch (string-trim (plist-get rev :stdout))))
                  (if (or (not (eql (plist-get rev :exit) 0)) (string-empty-p branch) (string= branch "HEAD"))
                      (harness-merge--finish entry 'failed "the worktree has no branch checked out")
                    (harness-merge--set entry :branch branch)
                    (harness-merge--run-git-merge entry parent-cwd branch))))))))))))))

(defun harness-merge--run-git-merge (entry parent-cwd branch)
  "Merge BRANCH into PARENT-CWD for ENTRY and handle the outcome."
  (harness-then
   (harness-merge--git parent-cwd "merge" "--no-ff" "--no-edit" branch)
   (lambda (result)
     (if (eql (plist-get result :exit) 0)
         (harness-merge--finish entry 'merged)
       (harness-then
        (harness-merge--git parent-cwd "diff" "--name-only" "--diff-filter=U")
        (lambda (diff)
          (let ((files (split-string (plist-get diff :stdout) "\n" t)))
            (if files
                (harness-merge--conflict entry parent-cwd branch files)
              (harness-then
               (harness-merge--git parent-cwd "merge" "--abort")
               (lambda (_)
                 (harness-merge--finish entry 'failed
                                        (string-trim (concat (plist-get result :stdout) "\n"
                                                             (plist-get result :stderr))))))))))))))

(defun harness-merge--conflict (entry parent-cwd branch files)
  "Hand the conflicted merge of ENTRY (BRANCH into PARENT-CWD, FILES) to the child."
  (let ((child-id (plist-get entry :child))
        (parent-id (plist-get entry :parent)))
    (harness-merge--set entry :status 'conflict :files files)
    (harness-emit 'merge/conflict child-id parent-id files)
    (harness-merge--hint parent-id (format "Merge from %s has conflicts in %s; waiting for it to resolve them"
                                           (harness-merge--label child-id) (string-join files ", ")))
    (when (harness-method-exists-p 'permission/allow-dir)
      (ignore-errors (harness-call 'permission/allow-dir child-id parent-cwd)))
    (harness-merge--steer
     child-id
     (format "Merging your branch %s into %s produced conflicts in these files:\n%s\n\nResolve the conflicts in %s (you now have access to that directory; the parent session is paused until you finish). Then stage the resolved files with `git -C %s add <files>` and commit the merge with `git -C %s commit --no-edit`. When the merge is committed, call the merge_done tool."
             branch parent-cwd
             (mapconcat (lambda (f) (concat "- " f)) files "\n")
             parent-cwd (directory-file-name parent-cwd) (directory-file-name parent-cwd)))
    (puthash parent-id
             (run-at-time harness-merge-hold-timeout nil #'harness-merge--timeout entry)
             harness-merge--timers)))

(defun harness-merge--timeout (entry)
  "Abort the merge of ENTRY after `harness-merge-hold-timeout'."
  (when (and (eq (plist-get entry :status) 'conflict)
             (equal (gethash (plist-get entry :parent) harness-merge--locks) (plist-get entry :child)))
    (let ((parent (harness-merge--session (plist-get entry :parent))))
      (harness-then
       (if parent
           (harness-merge--git (plist-get parent :cwd) "merge" "--abort")
         (harness-resolved nil))
       (lambda (_)
         (harness-merge--finish entry 'aborted
                                (format "not resolved within %s" (harness-format-duration harness-merge-hold-timeout))))))))

(defun harness-merge--finish (entry status &optional reason)
  "Close ENTRY with STATUS (merged, failed, aborted, cancelled) and REASON.
Releases the lock, dequeues, hints both sessions and serves the queue."
  (let* ((child-id (plist-get entry :child))
         (parent-id (plist-get entry :parent))
         (timer (gethash parent-id harness-merge--timers)))
    (when timer (cancel-timer timer) (remhash parent-id harness-merge--timers))
    (puthash parent-id (cl-remove entry (gethash parent-id harness-merge--queues))
             harness-merge--queues)
    (when (null (gethash parent-id harness-merge--queues))
      (remhash parent-id harness-merge--queues))
    (when (equal (gethash parent-id harness-merge--locks) child-id)
      (remhash parent-id harness-merge--locks))
    (harness-merge--set entry :status status)
    (harness-emit 'merge/finished child-id parent-id status)
    (let ((suffix (if reason (format " (%s)" reason) "")))
      (harness-merge--hint parent-id (format "Merge from %s finished: %s%s" (harness-merge--label child-id) status suffix))
      (harness-merge--hint child-id (format "Merge into %s finished: %s%s" (harness-merge--label parent-id) status suffix)))
    (harness-run-soon #'harness-merge--pump parent-id)
    status))

;;;; The merge_done tool

(defun harness-merge--done (_input ctx)
  "Handler of the merge_done tool.
Verify and close the conflicted merge of the session in CTX."
  (let* ((child-id (plist-get ctx :session-id))
         (entry (harness-merge--entry child-id)))
    (cond
     ((null entry) (harness-tool-error "No merge is in progress for this session"))
     ((not (eq (plist-get entry :status) 'conflict))
      (harness-tool-error (format "The merge is %s, not waiting for conflict resolution" (plist-get entry :status))))
     (t
      (let ((parent-cwd (plist-get (harness-merge--session (plist-get entry :parent)) :cwd)))
        (harness-then
         (harness-merge--git parent-cwd "diff" "--name-only" "--diff-filter=U")
         (lambda (diff)
           (let ((files (split-string (plist-get diff :stdout) "\n" t)))
             (if files
                 (harness-tool-error (format "Conflicts remain in %s: %s. Resolve them in %s, git add them and commit the merge, then call merge_done again."
                                             parent-cwd (string-join files ", ") parent-cwd))
               (harness-then
                (harness-merge--git parent-cwd "rev-parse" "-q" "--verify" "MERGE_HEAD")
                (lambda (head)
                  (if (eql (plist-get head :exit) 0)
                      (harness-tool-error (format "The merge in %s is resolved but not committed. Run `git -C %s commit --no-edit`, then call merge_done again."
                                                  parent-cwd (directory-file-name parent-cwd)))
                    (harness-merge--finish entry 'merged)
                    (harness-tool-ok (format "Merge into %s completed; the parent session continues." parent-cwd))))))))))))))

(harness-define-tool "merge_done"
  :description "Call after resolving a merge conflict the merge queue handed to you: verifies the parent repository has no unmerged paths and that the merge is committed, then releases the parent session."
  :schema '(:type "object" :properties :empty)
  :kind 'meta
  :title (lambda (_input) "merge_done")
  :handler #'harness-merge--done)

;;;; Registration

(defun harness-merge--init ()
  "Register the module's filters and subscribers (idempotent)."
  (harness-add-filter 'agent/step #'harness-merge--hold 30)
  (harness-add-filter 'agent/before-turn #'harness-merge--hold 30)
  (harness-on 'agent/turn-ended #'harness-merge--on-turn-ended))

(harness-merge--init)

(harness-declare-event 'merge/queued "(CHILD-ID PARENT-ID POSITION) after a merge was requested.")
(harness-declare-event 'merge/started "(CHILD-ID PARENT-ID) when a merge takes the parent's lock.")
(harness-declare-event 'merge/conflict "(CHILD-ID PARENT-ID FILES) when a merge stops on conflicts.")
(harness-declare-event 'merge/finished "(CHILD-ID PARENT-ID STATUS) merged, failed, aborted or cancelled.")

(harness-define-module 'merge
  :doc "Merge queue: worktree branches merged back into the parent session."
  :requires '(session agent)
  :init #'harness-merge--init)

(provide 'harness-merge)
;;; harness-merge.el ends here
