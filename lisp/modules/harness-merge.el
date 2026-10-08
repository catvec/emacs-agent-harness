;;; harness-merge.el --- Merge queue for worktree sessions  -*- lexical-binding: t; -*-

;;; Commentary:

;; A child session working in a git worktree asks to be merged back
;; into its parent's working directory with `merge/enqueue'.  Requests
;; queue per parent and are served one at a time: the head of the queue
;; takes the parent's lock when the parent is idle, or when its running
;; turn reaches a step boundary (the `agent/step' and `agent/before-turn'
;; filters hold the parent until the lock is free again).
;;
;; A merge is a transaction: the parent's checkout only ever moves by
;; a fast-forward to a finished merge commit, never through a merge in
;; progress.  `git merge-tree --write-tree' merges the child's branch
;; into the parent's HEAD without touching any working tree or index;
;; a clean result becomes a merge commit (`git commit-tree'), and
;; `git merge --ff-only' moves the parent's checkout onto it.  The
;; fast-forward is all or nothing: git refuses it, changing nothing,
;; when it would overwrite uncommitted or untracked work in the
;; parent's checkout, or when a merge or rebase is in progress there.
;; When the parent's HEAD moved meanwhile, the merge is computed again.
;; So work someone left in the parent's checkout is never lost, and a
;; harness that stops mid-merge leaves the checkout as it was.
;;
;; A conflict never reaches the parent's checkout.  The lock goes at
;; once and the parent's HEAD has to be merged into the child's branch,
;; in the child's worktree, the conflicts resolved there and committed;
;; the `merge_done' tool then queues the branch again.  A safety timer
;; gives up on a conflict nobody resolves.
;;
;; Who resolves them is `harness-merge-conflict-resolver'.  By default
;; the harness starts a fresh session for it (a `subagent' child of the
;; child session, in the child's worktree) with only the conflict to go
;; on: a child that finished long ago and waited in a queue has a cold
;; prompt cache and a long context, so waking it up to resolve a few
;; files would pay for its whole history again.  When that session's
;; turn ends without `merge_done' having queued the branch again, the
;; merge fails.  With `child', the child session itself is steered to
;; resolve them, as before.
;;
;; The fresh session shows in the child's transcript as a spawn_agent
;; call, as a sub-agent the child started would: the call once its turn
;; starts, its result -- the resolver's last reply, an error unless
;; merge_done queued the branch again -- when it stops.  The merge
;; queue made that call, not the child's model, and both nodes say so
;; (`harness-outside-node-p'): they never reach the child's model, so
;; its conversation is the same as without them.
;;
;; The harness locks the worktrees it makes so that `git worktree
;; prune' keeps them (see harness-worktree.el).  Once a child's branch
;; is merged its work is safe on the parent's branch, so the lock goes
;; (`worktree/unlock', which lifts only the harness's own locks) and the
;; worktree can be pruned again.  A merge that fails, is aborted or is
;; cancelled leaves the lock on.
;;
;; Everything runs asynchronously through `harness-run-command'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

;;;; Options

(defcustom harness-merge-conflict-resolver 'fresh
  "Who resolves the conflicts of a merge the merge queue cannot make.
`fresh': a new session the harness starts in the child's worktree,
told only about the conflict; its context is small, so it does not
pay for the child's whole history on a cold prompt cache.
`child': the child session itself, steered to resolve them."
  :type '(choice (const :tag "A fresh session" fresh)
                 (const :tag "The child session itself" child))
  :group 'harness)

(defcustom harness-merge-resolver-model nil
  "Model of the fresh session that resolves merge conflicts.
Nil means the child session's model."
  :type '(choice (const :tag "The child's model" nil) (string :tag "Model" :names model))
  :group 'harness)

;;;; Constants

(defconst harness-merge--hold-timeout 1800
  "Seconds a child may take to resolve merge conflicts before it is aborted.")

;;;; State

(defvar harness-merge--queues (make-hash-table :test 'equal)
  "Parent session id -> list of queue entries, oldest first.
An entry is (:child ID :parent ID :status queued|merging|conflict
:requested FLOAT :message STRING :branch NAME :files (…) :resolver ID).
`:resolver' is the fresh session resolving the entry's conflicts.")

(defvar harness-merge--locks (make-hash-table :test 'equal)
  "Parent session id -> child session id holding the merge lock.")

(defvar harness-merge--holds (make-hash-table :test 'equal)
  "Parent session id -> list of NEXT continuations of held agent steps.")

(defvar harness-merge--timers (make-hash-table :test 'equal)
  "Child session id -> safety timer of its unresolved conflict.")

(defvar harness-merge--calls (make-hash-table :test 'equal)
  "Resolver session id -> its open spawn_agent call in the child's transcript.
A call is (:session CHILD-ID :name NAME :prompt PROMPT :call-id ID
:started FLOAT :done BOOL).  `:call-id' and `:started' are set once the
call shows, when the resolver's turn starts; `:done' once merge_done
queued the branch again.")

(defconst harness-merge--ff-retries 3
  "Times a merge is computed again when the parent's HEAD moves under it.")

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
  "Send TEXT to session ID as a steering (or fresh) prompt from the merge queue."
  (when (and (harness-merge--session id) (harness-method-exists-p 'agent/prompt))
    (harness-catch (harness-call-async 'agent/prompt id text (list :from (harness-sender-system "merge queue")))
                   (lambda (e) (harness-log 'warn "merge: steering %s failed: %s" id (harness-error-message e)) nil))))

(defun harness-merge--entry (child-id)
  "Return the queue entry of CHILD-ID, or nil."
  (let (found)
    (maphash (lambda (_ entries)
               (unless found
                 (setq found (cl-find child-id entries :key (lambda (e) (plist-get e :child)) :test #'equal))))
             harness-merge--queues)
    found))

(defun harness-merge--entry-of (session-id)
  "Return the queue entry SESSION-ID is the child or the conflict resolver of."
  (or (harness-merge--entry session-id)
      (let (found)
        (maphash (lambda (_ entries)
                   (unless found
                     (setq found (cl-find session-id entries :key (lambda (e) (plist-get e :resolver)) :test #'equal))))
                 harness-merge--queues)
        found)))

(defun harness-merge--set (entry &rest props)
  "Set PROPS on the queue ENTRY in place (it is shared with the queue)."
  (cl-loop for (k v) on props by #'cddr do (plist-put entry k v))
  entry)

(defun harness-merge--git (cwd &rest args)
  "Run git ARGS in CWD; return a promise of (:exit :stdout :stderr)."
  (harness-run-command (append (list "git" "-C" (directory-file-name cwd)) args)
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
        :requested (plist-get entry :requested) :resolver (plist-get entry :resolver)))

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
Each item is (:child :parent :position :status :requested :resolver)."
  (cl-loop for e in (gethash parent-id harness-merge--queues) for i from 1
           collect (harness-merge--public e i)))

(harness-defmethod merge/status (child-id)
  "Return the merge status of CHILD-ID (queued, merging, conflict) or nil."
  (plist-get (harness-merge--entry child-id) :status))

(harness-defmethod merge/cancel (child-id)
  "Remove CHILD-ID from its merge queue.
Nothing is in progress in the parent's checkout to undo: a merge in
flight finds its entry gone and stops before it moves the checkout.
Return non-nil when an entry was removed."
  (let ((entry (harness-merge--entry child-id)))
    (when entry
      (harness-merge--finish entry 'cancelled)
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

(defun harness-merge--on-turn-ended (session-id reason)
  "Serve the merge queue of SESSION-ID now that it is idle.
When SESSION-ID resolves a conflict and its turn ended (for REASON)
without the branch queued again, the merge fails.  Its spawn_agent
call in the child's transcript gets its result either way, first."
  (when (and (gethash session-id harness-merge--queues)
             (not (gethash session-id harness-merge--locks)))
    (harness-run-soon #'harness-merge--pump session-id))
  (harness-merge--close-call session-id (format "the sub-agent stopped (%s) without calling merge_done" reason))
  (let ((entry (harness-merge--entry-of session-id)))
    (when (and entry (equal (plist-get entry :resolver) session-id)
               (eq (plist-get entry :status) 'conflict))
      (harness-merge--finish entry 'failed
                             (format "the session resolving the conflicts stopped (%s) without merge_done" reason)))))

;;;; The merge

(defun harness-merge--live-p (entry)
  "Non-nil while ENTRY is still the merge holding its parent's lock.
An asynchronous step checks this first, so a cancelled merge stops."
  (and (eq (plist-get entry :status) 'merging)
       (equal (gethash (plist-get entry :parent) harness-merge--locks) (plist-get entry :child))))

(defun harness-merge--out (result)
  "Return the trimmed stdout and stderr of the git RESULT."
  (string-trim (concat (plist-get result :stdout) "\n" (plist-get result :stderr))))

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
            ((not (harness-merge--live-p entry)) nil)
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
                  (cond
                   ((not (harness-merge--live-p entry)) nil)
                   ((or (not (eql (plist-get rev :exit) 0)) (string-empty-p branch) (string= branch "HEAD"))
                    (harness-merge--finish entry 'failed "the worktree has no branch checked out"))
                   (t
                    (harness-merge--set entry :branch branch)
                    (harness-merge--run-git-merge entry parent-cwd branch harness-merge--ff-retries)))))))))))))))

(defun harness-merge--rev (cwd rev)
  "Return a promise of the commit id REV names in CWD, or nil."
  (harness-then (harness-merge--git cwd "rev-parse" "-q" "--verify" (concat rev "^{commit}"))
                (lambda (r) (and (eql (plist-get r :exit) 0) (string-trim (plist-get r :stdout))))))

(defun harness-merge--message (branch target)
  "Return the merge commit message of BRANCH into the branch TARGET.
It is what `git merge' writes: no \"into\" for main or master."
  (if (member target '("main" "master" "HEAD" ""))
      (format "Merge branch '%s'" branch)
    (format "Merge branch '%s' into %s" branch target)))

(defun harness-merge--run-git-merge (entry parent-cwd branch retries)
  "Merge BRANCH into PARENT-CWD for ENTRY as one transaction.
The merge is computed off to the side with `git merge-tree'; only a
clean result reaches the checkout, by fast-forward.  RETRIES counts
the fresh attempts left when the parent's HEAD moves meanwhile."
  (let ((fail (lambda (why) (when (harness-merge--live-p entry) (harness-merge--finish entry 'failed why)))))
    (harness-then
     (harness-all (list (harness-merge--rev parent-cwd "HEAD")
                                (harness-merge--rev parent-cwd branch)
                                (harness-merge--git parent-cwd "rev-parse" "--abbrev-ref" "HEAD")))
     (lambda (revs)
       (pcase-let ((`(,head ,tip ,target) revs))
         (cond
          ((not (harness-merge--live-p entry)) nil)
          ((null head) (funcall fail "the parent's checkout has no commit"))
          ((null tip) (funcall fail (format "branch %s not found" branch)))
          (t
           (harness-merge--set entry :base head)
           (harness-then
            (harness-merge--git parent-cwd "merge-base" "--is-ancestor" tip head)
            (lambda (ancestor)
              (if (eql (plist-get ancestor :exit) 0)
                  ;; Nothing to merge: the branch is in already.
                  (when (harness-merge--live-p entry) (harness-merge--finish entry 'merged))
                (harness-then
                 (harness-merge--git parent-cwd "merge-tree" "--write-tree" "--name-only" "--no-messages" head tip)
                 (lambda (tree)
                   (let ((lines (split-string (plist-get tree :stdout) "\n" t)))
                     (cond
                      ((not (harness-merge--live-p entry)) nil)
                      ((eql (plist-get tree :exit) 1)
                       (harness-merge--conflict entry parent-cwd branch head (string-trim (plist-get target :stdout))
                                                (delete-dups (cdr lines))))
                      ((not (eql (plist-get tree :exit) 0))
                       (funcall fail (harness-merge--out tree)))
                      (t
                       (harness-merge--commit-and-advance
                        entry parent-cwd branch retries head tip (car lines)
                        (harness-merge--message branch (string-trim (plist-get target :stdout)))))))))))))))))))

(defun harness-merge--commit-and-advance (entry parent-cwd branch retries head tip tree message)
  "Commit TREE as the merge of HEAD and TIP; fast-forward PARENT-CWD to it.
ENTRY, BRANCH and RETRIES are as for `harness-merge--run-git-merge';
MESSAGE is the commit message."
  (harness-then
   (harness-merge--git parent-cwd "commit-tree" "--no-gpg-sign" tree "-p" head "-p" tip "-m" message)
   (lambda (commit)
     (let ((sha (string-trim (plist-get commit :stdout))))
       (cond
        ((not (harness-merge--live-p entry)) nil)
        ((not (eql (plist-get commit :exit) 0))
         (harness-merge--finish entry 'failed (harness-merge--out commit)))
        (t
         (harness-then
          (harness-merge--git parent-cwd "merge" "--ff-only" "--no-edit" sha)
          (lambda (ff)
            (cond
             ((not (harness-merge--live-p entry)) nil)
             ((eql (plist-get ff :exit) 0) (harness-merge--finish entry 'merged))
             (t
              ;; Git changed nothing.  A HEAD that moved is merged again;
              ;; anything else (local changes in the way, a merge in
              ;; progress) is the parent checkout's to sort out.
              (harness-then
               (harness-merge--rev parent-cwd "HEAD")
               (lambda (now)
                 (cond
                  ((not (harness-merge--live-p entry)) nil)
                  ((and now (not (equal now head)) (> retries 0))
                   (harness-merge--run-git-merge entry parent-cwd branch (1- retries)))
                  (t
                   (harness-merge--finish
                    entry 'failed
                    (format "the parent's checkout %s was left untouched: %s"
                            (directory-file-name parent-cwd) (harness-merge--out ff)))))))))))))))))

(defun harness-merge--conflict (entry parent-cwd branch head target files)
  "Hand ENTRY's conflicts in FILES to be resolved; the parent is untouched.
BRANCH would have merged into PARENT-CWD at commit HEAD, the tip of the
branch TARGET.  The parent's lock goes at once; HEAD is merged into
the child's branch in its worktree, by a fresh session or the child
itself (`harness-merge-conflict-resolver'), and merge_done is called."
  (let* ((child-id (plist-get entry :child))
         (parent-id (plist-get entry :parent))
         (child (harness-merge--session child-id))
         (child-cwd (directory-file-name (or (plist-get child :cwd) "")))
         (short (substring head 0 (min 12 (length head))))
         (instructions
          (format "run `git merge %s` (the tip of %s), resolve the conflicts, `git add` the files and commit the merge with `git commit --no-edit`. Keep both sides' work. Do not touch %s. When the merge is committed, call the merge_done tool and the branch is merged again."
                  short (if (string-empty-p target) "the parent" target) (directory-file-name parent-cwd)))
         (listing (mapconcat (lambda (f) (concat "- " f)) files "\n")))
    (harness-merge--set entry :status 'conflict :files files :resolver nil)
    (when (equal (gethash parent-id harness-merge--locks) child-id)
      (remhash parent-id harness-merge--locks))
    (harness-emit 'merge/conflict child-id parent-id files)
    (puthash child-id
             (run-at-time harness-merge--hold-timeout nil #'harness-merge--timeout entry)
             harness-merge--timers)
    (let ((resolver (and (eq harness-merge-conflict-resolver 'fresh)
                         (harness-merge--start-resolver
                          entry child
                          (format "You resolve merge conflicts for the merge queue of the agent harness.\n\nThe branch %s, in the git worktree %s (your working directory), was to be merged into %s, but that would conflict in these files:\n%s\n\nNothing was changed there. Bring the parent's work into the branch instead, in the worktree %s: %s\n\nYou start fresh: read both sides first (`git log --oneline %s..HEAD` is the branch's own work, `git log --oneline HEAD..%s` the parent's) and understand what each change is for before you resolve. Change nothing beyond the merge itself.%s"
                                  branch child-cwd (directory-file-name parent-cwd) listing child-cwd instructions
                                  short short
                                  (if (plist-get entry :message)
                                      (format "\n\nThe branch's merge request said: %s" (plist-get entry :message))
                                    ""))))))
      (if resolver
          ;; The child heard from `harness-merge--start-resolver'.
          (harness-merge--hint parent-id (format "Merge from %s has conflicts in %s; a fresh session resolves them in its worktree"
                                                 (harness-merge--label child-id) (string-join files ", ")))
        (harness-merge--hint parent-id (format "Merge from %s has conflicts in %s; it resolves them in its worktree"
                                               (harness-merge--label child-id) (string-join files ", ")))
        (harness-merge--steer
         child-id
         (format "Merging your branch %s into %s would conflict in these files:\n%s\n\nNothing was changed there. Bring the parent's work into your branch instead, in your own worktree %s: %s"
                 branch (directory-file-name parent-cwd) listing child-cwd instructions))))
    (harness-run-soon #'harness-merge--pump parent-id)))

(defun harness-merge--start-resolver (entry child prompt)
  "Start a fresh session resolving ENTRY's conflicts with PROMPT; return its id.
The session works in the worktree of CHILD (the child's session plist),
with its settings, as its `subagent' child, and shows in the child's
transcript as a spawn_agent call (`harness-merge--add-call').  Return
nil when it cannot start; the child is then steered instead."
  (when (and (harness-method-exists-p 'session/create) (harness-method-exists-p 'agent/prompt))
    (condition-case err
        (let* ((child-id (plist-get child :id))
               (session (harness-call 'session/create
                                      :cwd (plist-get child :cwd) :kind 'subagent :parent-id child-id
                                      :name (format "Merge %s" (or (plist-get entry :branch) (harness-merge--label child-id)))
                                      :model (or harness-merge-resolver-model (plist-get child :model))
                                      :host (plist-get child :host)
                                      :permission-mode (plist-get child :permission-mode)
                                      :thinking (plist-get child :thinking)
                                      :allowed-dirs (plist-get child :allowed-dirs)
                                      :non-interactive (if (harness-json-true-p (plist-get child :non-interactive)) t :false)))
               (id (plist-get session :id)))
          (harness-merge--set entry :resolver id)
          (harness-emit 'merge/resolver child-id (plist-get entry :parent) id)
          (harness-merge--hint child-id (format "Merge into %s has conflicts in %s; session %s resolves them in this worktree"
                                                (harness-merge--label (plist-get entry :parent))
                                                (string-join (plist-get entry :files) ", ")
                                                (harness-merge--label id)))
          ;; Before the prompt: its turn starting shows the call, and a
          ;; prompt that fails, even at once, answers it.
          (harness-merge--add-call child-id id (plist-get session :name) prompt)
          (harness-catch (harness-call-async 'agent/prompt id prompt (list :from (harness-sender-system "merge queue")))
                         (lambda (e)
                           (harness-log 'warn "merge: the conflict resolver %s failed: %s" id (harness-error-message e))
                           (harness-merge--close-call id (format "the sub-agent failed: %s" (harness-error-message e)))
                           (when (and (equal (plist-get entry :resolver) id) (eq (plist-get entry :status) 'conflict))
                             (harness-merge--finish entry 'failed (format "the session resolving the conflicts failed: %s"
                                                                          (harness-error-message e))))
                           nil))
          id)
      (error (harness-log 'warn "merge: could not start a conflict resolver: %s" (error-message-string err))
             nil))))

;;;; The resolver's spawn_agent call

(defun harness-merge--add-call (child-id resolver-id name prompt)
  "Have RESOLVER-ID show in CHILD-ID's transcript as a spawn_agent call.
The call is the one that would have started a sub-agent named NAME
with PROMPT.  It shows when the resolver's turn starts
\(`harness-merge--on-turn-started'): a harness stopped from then on
finds the resolver running when it starts again, and answers the call
as it settles the resolver (`harness-session--settle').  It runs until
the resolver stops, which records its result
\(`harness-merge--close-call')."
  (puthash resolver-id (list :session child-id :name name :prompt prompt) harness-merge--calls))

(defun harness-merge--on-turn-started (session-id)
  "Show the spawn_agent call of SESSION-ID, a resolver whose turn started."
  (let ((call (gethash session-id harness-merge--calls)))
    (when (and call (not (plist-get call :call-id)))
      (harness-merge--open-call session-id call))))

(defun harness-merge--open-call (resolver-id call)
  "Append CALL, the spawn_agent call of RESOLVER-ID, to the child's transcript.
Return CALL with its `:call-id' and `:started', or nil when it could not
be shown.  Its `:meta' says the merge queue made it
\(`harness-outside-node-p'), so the child's model never sees it and
nothing waits for its result, and names the resolver as `:child-id'."
  (let* ((call-id (concat "merge-" (harness-short-id 10)))
         (input (list :name (plist-get call :name) :prompt (plist-get call :prompt))))
    (condition-case err
        (progn
          (harness-call 'session/append (plist-get call :session)
                        (list :kind 'tool-call :tool "spawn_agent" :call-id call-id :input input
                              :title (harness-tool-title "spawn_agent" input)
                              :meta (list :from (harness-sender-system "merge queue") :child-id resolver-id)))
          (puthash resolver-id (append (list :call-id call-id :started (float-time)) call)
                   harness-merge--calls))
      (error (harness-log 'warn "merge: could not show the resolver %s in %s: %s"
                          resolver-id (plist-get call :session) (error-message-string err))
             (remhash resolver-id harness-merge--calls)
             nil))))

(defun harness-merge--resolver-summary (resolver-id)
  "Return the result text of RESOLVER-ID's spawn_agent call.
That is its last reply and a footer with its tool calls and cost, as
spawn_agent's own result reads."
  (let* ((session (harness-merge--session resolver-id))
         (own (and session
                   (cl-remove-if-not (lambda (n) (equal (plist-get n :session) resolver-id))
                                     (ignore-errors (harness-call 'session/nodes resolver-id)))))
         (reply (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'assistant)
                                             (not (harness-string-blank-p (plist-get n :content)))))
                            own :from-end t))
         (calls (cl-count-if (lambda (n) (eq (plist-get n :kind) 'tool-call)) own)))
    (format "%s\n\n[sub-agent session: %s, %d tool calls, cost %s]"
            (or (plist-get reply :content) "(the sub-agent produced no answer)")
            resolver-id calls (harness-format-spend (plist-get session :usage)))))

(defun harness-merge--call-done (resolver-id)
  "Mark the spawn_agent call of RESOLVER-ID done: merge_done queued the branch."
  (let ((call (gethash resolver-id harness-merge--calls)))
    (when call
      (puthash resolver-id (plist-put call :done t) harness-merge--calls))))

(defun harness-merge--close-call (resolver-id why)
  "Record the result of RESOLVER-ID's spawn_agent call, if it is still open.
A call not shown yet, its resolver's turn never having started, shows
now.  The result is the resolver's last reply
\(`harness-merge--resolver-summary').  It succeeded when merge_done
queued the branch again; otherwise it is an error, and WHY says what
stopped it."
  (let ((call (gethash resolver-id harness-merge--calls)))
    (when (and call (not (plist-get call :call-id)))
      (setq call (harness-merge--open-call resolver-id call)))
    (when call
      (remhash resolver-id harness-merge--calls)
      (let ((done (plist-get call :done))
            (summary (condition-case err
                         (harness-merge--resolver-summary resolver-id)
                       (error (harness-log 'warn "merge: could not sum up the resolver %s: %s"
                                           resolver-id (error-message-string err))
                              "(the sub-agent produced no answer)"))))
        (condition-case err
            (harness-call 'session/append (plist-get call :session)
                          (list :kind 'tool-result :call-id (plist-get call :call-id)
                                :output (format "%s\n\n(%s)" summary
                                                (if done "merge_done queued the branch to merge again" why))
                                :is-error (not done)
                                :meta (list :from (harness-sender-system "merge queue") :child-id resolver-id
                                            :duration (- (float-time) (plist-get call :started)))))
          (error (harness-log 'warn "merge: could not record the result of the resolver %s: %s"
                              resolver-id (error-message-string err))))))))

(defun harness-merge--timeout (entry)
  "Give up on the unresolved conflict of ENTRY after `harness-merge--hold-timeout'."
  (when (eq (plist-get entry :status) 'conflict)
    (harness-merge--finish entry 'aborted
                           (format "not resolved within %s" (harness-format-duration harness-merge--hold-timeout)))))

(defun harness-merge--unlock-worktree (entry)
  "Lift the harness's lock on the worktree of ENTRY's child, now merged.
Return a promise, or nil without a worktree or the worktree module."
  (let* ((child (harness-merge--session (plist-get entry :child)))
         (parent (harness-merge--session (plist-get entry :parent)))
         (worktree (plist-get child :worktree)))
    (when (and worktree (harness-method-exists-p 'worktree/unlock))
      (harness-catch
       (harness-call-async 'worktree/unlock (or (plist-get parent :cwd) worktree) worktree)
       (lambda (err)
         (harness-log 'warn "merge: could not unlock the merged worktree %s: %s"
                      worktree (harness-error-message err))
         nil)))))

(defun harness-merge--finish (entry status &optional reason)
  "Close ENTRY with STATUS (merged, failed, aborted, cancelled) and REASON.
Releases the lock, dequeues, hints both sessions and serves the queue.
A merged child's worktree loses the harness's lock."
  (let* ((child-id (plist-get entry :child))
         (parent-id (plist-get entry :parent))
         (resolver (plist-get entry :resolver))
         (timer (gethash child-id harness-merge--timers))
         (suffix (if reason (format " (%s)" reason) "")))
    (when (eq status 'merged) (harness-merge--unlock-worktree entry))
    (when timer (cancel-timer timer) (remhash child-id harness-merge--timers))
    (puthash parent-id (cl-remove entry (gethash parent-id harness-merge--queues))
             harness-merge--queues)
    (when (null (gethash parent-id harness-merge--queues))
      (remhash parent-id harness-merge--queues))
    (when (equal (gethash parent-id harness-merge--locks) child-id)
      (remhash parent-id harness-merge--locks))
    ;; Set before the resolver is stopped: a turn that ends at once must
    ;; not fail the merge again (`harness-merge--on-turn-ended').
    (harness-merge--set entry :status status)
    ;; A resolver given up on stops, and its call says why; one that
    ;; finished is left to end its turn, which answers its call.
    (when (and resolver (memq status '(aborted cancelled)))
      (harness-merge--close-call resolver (format "the merge was %s%s, so the sub-agent was stopped" status suffix))
      (when (harness-method-exists-p 'agent/cancel)
        (ignore-errors (harness-call 'agent/cancel resolver))))
    (harness-emit 'merge/finished child-id parent-id status)
    (harness-merge--hint parent-id (format "Merge from %s finished: %s%s" (harness-merge--label child-id) status suffix))
    (harness-merge--hint child-id (format "Merge into %s finished: %s%s" (harness-merge--label parent-id) status suffix))
    (harness-run-soon #'harness-merge--pump parent-id)
    status))

;;;; The merge_done tool

(defun harness-merge--requeue (entry)
  "Put ENTRY, whose conflicts were resolved, back in its queue."
  (let* ((child-id (plist-get entry :child))
         (parent-id (plist-get entry :parent))
         (timer (gethash child-id harness-merge--timers)))
    (when timer (cancel-timer timer) (remhash child-id harness-merge--timers))
    (harness-merge--set entry :status 'queued :files nil :resolver nil)
    (harness-emit 'merge/queued child-id parent-id
                  (1+ (or (cl-position entry (gethash parent-id harness-merge--queues)) 0)))
    (unless (harness-merge--parent-running-p parent-id)
      (harness-run-soon #'harness-merge--pump parent-id))))

(defun harness-merge--done (_input ctx)
  "Handler of the merge_done tool.
Check that the child's worktree merged the parent's HEAD into its branch
and committed, then queue its branch again.  The session in CTX is the
child or the fresh session resolving its conflicts."
  (let* ((entry (harness-merge--entry-of (plist-get ctx :session-id)))
         (child-id (plist-get entry :child)))
    (cond
     ((null entry) (harness-tool-error "No merge is in progress for this session"))
     ((not (eq (plist-get entry :status) 'conflict))
      (harness-tool-error (format "The merge is %s, not waiting for conflict resolution" (plist-get entry :status))))
     (t
      (let ((cwd (plist-get (harness-merge--session child-id) :cwd))
            (base (plist-get entry :base)))
        (harness-then
         (harness-all (list (harness-merge--git cwd "diff" "--name-only" "--diff-filter=U")
                                    (harness-merge--git cwd "rev-parse" "-q" "--verify" "MERGE_HEAD")
                                    (harness-merge--git cwd "status" "--porcelain")
                                    (harness-merge--git cwd "merge-base" "--is-ancestor" base "HEAD")))
         (lambda (results)
           (pcase-let ((`(,diff ,head ,status ,ancestor) results))
             (let ((files (split-string (plist-get diff :stdout) "\n" t)))
               (cond
                (files
                 (harness-tool-error (format "Conflicts remain in %s. Resolve them in your worktree %s, git add them and commit the merge, then call merge_done again."
                                             (string-join files ", ") cwd)))
                ((eql (plist-get head :exit) 0)
                 (harness-tool-error "The merge is resolved but not committed. Run `git commit --no-edit` in your worktree, then call merge_done again."))
                ((not (eql (plist-get ancestor :exit) 0))
                 (harness-tool-error (format "Your branch does not contain the parent's commit %s yet. Run `git merge %s` in your worktree, resolve and commit, then call merge_done again."
                                             base base)))
                ((not (string-empty-p (string-trim (plist-get status :stdout))))
                 (harness-tool-error "Your worktree has uncommitted changes. Commit them, then call merge_done again."))
                ((not (eq (plist-get entry :status) 'conflict))
                 (harness-tool-error (format "The merge is %s, not waiting for conflict resolution" (plist-get entry :status))))
                (t
                 ;; The resolver's call succeeded, whoever called merge_done.
                 (when (plist-get entry :resolver)
                   (harness-merge--call-done (plist-get entry :resolver)))
                 (harness-merge--requeue entry)
                 (harness-tool-ok "The branch is queued to merge again; the merge queue takes it from here."))))))))))))

(harness-define-tool "merge_done"
  :label "Finish merge"
  :description "Call after resolving the merge conflicts the merge queue handed to you: verifies that your worktree merged the parent's commit and committed the result, then queues your branch to merge again."
  :schema '(:type "object" :properties :empty)
  :kind 'meta
  :subject #'ignore
  :handler #'harness-merge--done)

;;;; Moves

(defun harness-merge--before-move (gate session _dir)
  "Keep a session where the merges it takes part in expect it.
A `session/before-move' filter: GATE is (:proceed t) and SESSION the
plist of the session that is to move.  A queued merge goes into its
parent's working directory as it is when the merge starts, and the
session resolving a merge's conflicts works in the child's worktree."
  (let* ((id (plist-get session :id))
         (entries (gethash id harness-merge--queues)))
    (cond
     ((not (plist-get gate :proceed)) gate)
     (entries
      (list :proceed nil
            :reason (format "the merge queue has %s to merge into it (%s); move it after %s"
                            (if (cdr entries) (format "%d branches" (length entries)) "a branch")
                            (mapconcat (lambda (e) (harness-merge--label (plist-get e :child))) entries ", ")
                            (if (cdr entries) "those merges" "that merge"))))
     ((harness-merge--entry-of id)
      (list :proceed nil :reason "it takes part in a merge the merge queue has not finished"))
     (t gate))))

;;;; Registration

(defun harness-merge--init ()
  "Register the module's filters and subscribers (idempotent)."
  (harness-add-filter 'session/before-move #'harness-merge--before-move)
  (harness-add-filter 'agent/step #'harness-merge--hold 30)
  (harness-add-filter 'agent/before-turn #'harness-merge--hold 30)
  (harness-on 'agent/turn-started #'harness-merge--on-turn-started)
  (harness-on 'agent/turn-ended #'harness-merge--on-turn-ended))

(harness-merge--init)

(harness-declare-event 'merge/queued "(CHILD-ID PARENT-ID POSITION) after a merge was requested.")
(harness-declare-event 'merge/started "(CHILD-ID PARENT-ID) when a merge takes the parent's lock.")
(harness-declare-event 'merge/conflict "(CHILD-ID PARENT-ID FILES) when a merge would conflict; they are resolved in the child's worktree.")
(harness-declare-event 'merge/resolver "(CHILD-ID PARENT-ID RESOLVER-ID) when a fresh session starts resolving a merge's conflicts.")
(harness-declare-event 'merge/finished "(CHILD-ID PARENT-ID STATUS) merged, failed, aborted or cancelled.")

(harness-define-module 'merge
  :doc "Merge queue: worktree branches merged back into the parent session."
  :requires '(session agent)
  :init #'harness-merge--init)

(provide 'harness-merge)
;;; harness-merge.el ends here
