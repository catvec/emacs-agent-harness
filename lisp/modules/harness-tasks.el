;;; harness-tasks.el --- Task mode: one session per task  -*- lexical-binding: t; -*-

;;; Commentary:

;; Task mode manages sessions by the task they are completing.  A task
;; is a prompt submitted for a project; it gets a session of its own
;; when it starts and the session does the work, usually in auto
;; permission mode and non-interactive so it is not held up waiting for
;; the user.  The session's name is the task's title, so when the model
;; names it, `harness-tasks-naming-prompt' asks for a ticket title.
;;
;; In a git project a task owns the whole life of its change: it starts
;; in a fresh worktree on a branch of its own (the `worktree' module),
;; its session is told to commit there, and when the agent finishes the
;; branch goes through the merge queue (the `merge' module) into the
;; branch checked out at the project root.  A task is complete only once
;; its changes are merged.  The merge queue needs a parent session to
;; merge into, so every project gets one quiet session at its root,
;; named by `harness-tasks-merge-session-name', that only ever receives
;; merges.  Conflicts are handed back to the task's own session by the
;; merge queue; any other failure puts the task in front of the user.
;; Archiving a merged task removes its worktree and its merged branch.
;;
;; States:
;;
;;   pending   submitted, waiting for a free slot (only when
;;             `harness-tasks-max-running' limits how many run at once)
;;   active    its session is working on it, or stopped part way
;;             (`:outcome' says why: error, cancelled, merge-failed…)
;;   merging   the agent finished; its branch is queued or merging
;;   done      merged (or finished, outside git); a follow-up message
;;             moves the task back to active
;;
;; Every task a method returns or an event carries also has a derived
;; `:column', the kanban column it belongs in:
;;
;;   pending       waiting for a slot
;;   needs-input   requires user input: its session is blocked on a
;;                 permission or a question, or it stopped part way
;;   active        in progress, merging included
;;   done          completed
;;
;; Records persist in tasks.json; the sessions persist as usual.
;; Events `task/changed' (TASK) and `task/deleted' (ID) let a UI follow.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)

(defcustom harness-tasks-max-running nil
  "Tasks that may work at the same time; the rest wait as pending.
nil (the default) means no limit."
  :type '(choice (const :tag "No limit" nil) integer) :group 'harness)

(defcustom harness-tasks-permission-mode 'auto
  "Permission mode of task sessions, or nil for the configured default."
  :type '(choice (const :tag "Configured default" nil)
                 (const ask) (const accept-edits) (const auto) (const yolo))
  :group 'harness)

(defcustom harness-tasks-non-interactive t
  "When non-nil, task sessions run non-interactive.
Permission prompts become denials with a hint to find another way, so a
task keeps working while nobody watches it."
  :type 'boolean :group 'harness)

(defcustom harness-tasks-model nil
  "Model of task sessions, or nil for the configured default."
  :type '(choice (const :tag "Configured default" nil) string) :group 'harness)

(defcustom harness-tasks-thinking nil
  "Thinking level of task sessions, or nil for the configured default."
  :type '(choice (const :tag "Configured default" nil) string) :group 'harness)

(defcustom harness-tasks-naming-prompt
  "This conversation is a task the engineer handed to the agent to do unattended, tracked on a task board.  Title it like a ticket on that board: an imperative summary of the work to be done, such as \"Fix login redirect loop\" or \"Add CSV export to reports\"."
  "Text added to the naming system prompt of task sessions, or nil for none.
A task's session name is its title on the board, so by default the
model titles task sessions like tickets."
  :type '(choice (const :tag "Name tasks like other sessions" nil) string) :group 'harness)

(defcustom harness-tasks-worktrees t
  "When non-nil, tasks in a git project work in a worktree and merge back.
Each task gets a branch named after `harness-tasks-branch-prefix' and is
complete only when the merge queue has merged that branch."
  :type 'boolean :group 'harness)

(defcustom harness-tasks-branch-prefix "task/"
  "Prefix of the branches task worktrees are created on."
  :type 'string :group 'harness)

(defcustom harness-tasks-merge-attempts 3
  "Merges a task may try before it waits for the user."
  :type 'integer :group 'harness)

(defcustom harness-tasks-merge-session-name "Task merges"
  "Name of the session at a project's root that task branches merge into."
  :type 'string :group 'harness)

(defcustom harness-tasks-git-program "git"
  "Git executable used to delete merged task branches."
  :type 'string :group 'harness)

(defconst harness-tasks--store-name "tasks.json" "Store file of the task records.")

(defconst harness-tasks--symbol-keys '(:state :outcome :merge-status)
  "Keys whose values are symbols in memory and strings on disk.")

(defvar harness-tasks--table (make-hash-table :test 'equal)
  "Task id -> task plist.")

(defvar harness-tasks--loaded nil "Non-nil once the records were read from the store.")

(defvar harness-tasks--starting (make-hash-table :test 'equal)
  "Task ids that are starting: worktree or session made, first turn not begun.
They hold a slot so a burst of submissions never overshoots the limit.")

;;;; Records

(defun harness-tasks--get (id)
  "Return task ID or signal."
  (or (gethash id harness-tasks--table)
      (signal 'harness-error (list (format "No task %s" id)))))

(defun harness-tasks--by-session (session-id)
  "Return the task worked on by SESSION-ID, or nil."
  (and session-id
       (cl-loop for task being the hash-values of harness-tasks--table
                when (equal (plist-get task :session) session-id) return task)))

(defun harness-tasks--sorted (&optional pred)
  "Return the tasks matching PRED, oldest first."
  (let (out)
    (maphash (lambda (_ task) (when (or (null pred) (funcall pred task)) (push task out)))
             harness-tasks--table)
    (sort out (lambda (a b) (< (plist-get a :created) (plist-get b :created))))))

(defun harness-tasks--save ()
  "Write every task record now."
  (harness-call 'store/save harness-tasks--store-name (harness-tasks--sorted)))

(defun harness-tasks--put (task)
  "Store TASK, schedule a save and emit `task/changed'.  Return its view."
  (puthash (plist-get task :id) task harness-tasks--table)
  (harness-debounce 'harness-tasks-save 0.3 #'harness-tasks--save)
  (let ((view (harness-tasks--view task)))
    (harness-emit 'task/changed view)
    view))

(defun harness-tasks--set (id &rest plist)
  "Merge PLIST into task ID and store it.  Return its view."
  (harness-tasks--put (apply #'harness-plist-merge (harness-tasks--get id) (list plist))))

(defun harness-tasks--intern (task)
  "Turn the string enum values of a stored TASK back into symbols."
  (let ((task (copy-sequence task)))
    (dolist (k harness-tasks--symbol-keys task)
      (let ((v (plist-get task k)))
        (when (stringp v) (setq task (plist-put task k (intern v))))))))

(defun harness-tasks--load ()
  "Read the task records from the store once."
  (unless harness-tasks--loaded
    (setq harness-tasks--loaded t)
    (dolist (task (ignore-errors (harness-call 'store/load harness-tasks--store-name)))
      (when (plist-get task :id)
        (puthash (plist-get task :id) (harness-tasks--intern task) harness-tasks--table)))))

(defun harness-tasks--project (cwd)
  "Return the project root of CWD.
Inside a task's worktree that is the main checkout the task merges into,
so a board opened from a task's session shows the project's tasks."
  (let ((root (if (harness-method-exists-p 'project/root)
                  (harness-call 'project/root cwd)
                (file-name-as-directory (expand-file-name cwd)))))
    (harness-files-main-root root)))

(defun harness-tasks--session (task)
  "Return the session plist of TASK, or nil when it has none."
  (let ((sid (plist-get task :session)))
    (and sid (harness-call 'session/exists-p sid) (harness-call 'session/get sid))))

;;;; Columns

(defun harness-tasks--column (task)
  "Return the kanban column of TASK: pending, needs-input, active or done."
  (pcase (plist-get task :state)
    ('pending 'pending)
    ('done 'done)
    (_ (let ((session (harness-tasks--session task)))
         (cond ((gethash (plist-get task :id) harness-tasks--starting) 'active)
               ((plist-get session :pending) 'needs-input)
               ((eq (plist-get session :status) 'running) 'active)
               ((plist-get task :outcome) 'needs-input)
               (t 'active))))))

(defun harness-tasks--view (task)
  "Return TASK as methods and events show it: with its `:column'."
  (append task (list :column (harness-tasks--column task))))

;;;; Git

(defun harness-tasks--git-p (root)
  "Non-nil when tasks at project ROOT get worktrees and merge back."
  (and harness-tasks-worktrees
       (harness-method-exists-p 'worktree/create)
       (harness-method-exists-p 'merge/enqueue)
       (not (file-remote-p root))
       (locate-dominating-file root ".git")
       t))

(defun harness-tasks--branch-name (task)
  "Return a branch name for TASK: the prefix, a slug of its prompt, its id."
  (let* ((words (split-string (downcase (harness-first-line (plist-get task :prompt))) "[^a-z0-9]+" t))
         (slug (string-join (take 5 words) "-")))
    (concat harness-tasks-branch-prefix
            (if (string-empty-p slug) "" (concat (harness-truncate-end slug 40) "-"))
            (substring (plist-get task :id) 2))))

(defun harness-tasks--make-worktree (task)
  "Return a promise of TASK's worktree plist, with `:base' the root's branch."
  (let ((root (plist-get task :project)))
    (harness-then
     (harness-call-async 'worktree/branch root)
     (lambda (base)
       (harness-then
        (harness-call-async 'worktree/create root :branch (harness-tasks--branch-name task))
        (lambda (wt) (append (list :base base) wt)))))))

(defun harness-tasks--merge-target (root)
  "Return the id of the session at project ROOT that task branches merge into."
  (let ((existing (cl-find-if (lambda (s) (and (equal (plist-get s :name) harness-tasks-merge-session-name)
                                               (equal (plist-get s :cwd) root)
                                               (null (plist-get s :worktree))))
                              (harness-call 'session/list (list :project root)))))
    (plist-get (or existing
                   (harness-call 'session/create :cwd root :name harness-tasks-merge-session-name))
               :id)))

(defun harness-tasks--enqueue-merge (id)
  "Queue task ID's branch for the merge queue, or put the task before the user."
  (let* ((task (harness-tasks--get id))
         (attempts (1+ (or (plist-get task :merge-attempts) 0))))
    (cond
     ((> attempts harness-tasks-merge-attempts)
      (harness-tasks--set id :state 'active :outcome 'merge-failed :merge-status nil
                          :error (format "gave up after %d merge attempts: %s"
                                         harness-tasks-merge-attempts (or (plist-get task :error) "?"))))
     ((harness-call 'merge/status (plist-get task :session)) nil)
     (t
      (condition-case err
          (let ((target (harness-tasks--merge-target (plist-get task :project))))
            (harness-tasks--set id :state 'merging :merge-status 'queued :merge-attempts attempts
                                :merge-target target :outcome nil :error nil)
            (harness-call 'merge/enqueue (plist-get task :session) target
                          :message (format "task %s" (harness-first-line (plist-get task :prompt) 60))))
        (error (harness-tasks--set id :state 'active :outcome 'merge-failed :merge-status nil
                                   :error (harness-error-message err))))))))

(defun harness-tasks--on-merge-started (child _parent)
  "Mark CHILD's task as merging now."
  (when-let* ((task (harness-tasks--by-session child)))
    (harness-tasks--set (plist-get task :id) :merge-status 'merging)))

(defun harness-tasks--on-merge-conflict (child _parent files)
  "Record the FILES CHILD's task has to resolve."
  (when-let* ((task (harness-tasks--by-session child)))
    (harness-tasks--set (plist-get task :id) :merge-status 'conflict :conflicts files)))

(defun harness-tasks--on-merge-finished (child _parent status)
  "Complete CHILD's task when STATUS is `merged'; otherwise let it be fixed."
  (when-let* ((task (harness-tasks--by-session child)))
    (let ((id (plist-get task :id)))
      (if (eq status 'merged)
          (harness-tasks--set id :state 'done :merge-status nil :conflicts nil :merged t
                              :outcome 'merged :finished (float-time))
        ;; The merge queue steers the agent when it can fix things itself
        ;; (uncommitted changes); its next clean turn merges again.
        (if (and (harness-method-exists-p 'agent/running) (harness-call 'agent/running child))
            (harness-tasks--set id :merge-status nil :error (format "merge %s" status))
          (harness-tasks--set id :state 'active :merge-status nil :outcome 'merge-failed
                              :error (format "merge %s" status)))))))

(defun harness-tasks--remove-worktree (task)
  "Remove merged TASK's worktree and delete its branch; return a promise."
  (let ((root (plist-get task :project))
        (branch (plist-get task :branch)))
    (harness-then
     (harness-call-async 'worktree/remove root (plist-get task :worktree))
     (lambda (_)
       (harness-tasks--set (plist-get task :id) :worktree-removed t)
       (when branch
         (harness-run-command (list harness-tasks-git-program "-C" (directory-file-name root) "branch" "-d" branch)
                              :cwd root :name "harness-tasks-git")))
     (lambda (err)
       (harness-log 'warn "task %s: keeping its worktree: %s" (plist-get task :id) (harness-error-message err))
       nil))))

;;;; The task prompts

(defun harness-tasks--system-prompt (prompt session)
  "Tell a task's SESSION how its work reaches the main branch (PROMPT filter)."
  (let ((task (harness-tasks--by-session (plist-get session :id))))
    (if (not (and task (plist-get task :worktree)))
        prompt
      (concat prompt "\n\n## Task mode\n"
              (format "You are working on one task, unattended, in your own git worktree %s on branch %s. "
                      (plist-get task :worktree) (plist-get task :branch))
              "Do the whole task there. When you are done, commit all of your changes on that branch "
              "(git add -A, then git commit with a message saying what the change does). "
              (format "Do not merge, rebase onto or push %s yourself: when your turn ends the harness merges "
                      (or (plist-get task :base) "the main branch"))
              "your branch through the merge queue, and it will come back to you if the merge needs anything.\n"))))

(defun harness-tasks--naming-prompt (prompt session)
  "Ask for a ticket title when naming a task's SESSION (PROMPT filter)."
  (if (and (not (harness-string-blank-p harness-tasks-naming-prompt))
           (harness-tasks--by-session (plist-get session :id)))
      (concat prompt "\n\n" harness-tasks-naming-prompt)
    prompt))

;;;; Scheduling

(defun harness-tasks--working-p (task)
  "Non-nil when TASK holds a slot: starting, running or blocked mid-turn."
  (or (gethash (plist-get task :id) harness-tasks--starting)
      (and (memq (plist-get task :state) '(active merging))
           (memq (plist-get (harness-tasks--session task) :status) '(running blocked)))))

(defun harness-tasks--free-slots ()
  "Return how many more tasks may start now (most-positive-fixnum without a limit)."
  (if (null harness-tasks-max-running)
      most-positive-fixnum
    (- harness-tasks-max-running
       (cl-count-if #'harness-tasks--working-p (harness-tasks--sorted)))))

(defun harness-tasks--schedule ()
  "Start the oldest pending tasks while slots are free."
  (let ((free (harness-tasks--free-slots)))
    (dolist (task (harness-tasks--sorted (lambda (task) (eq (plist-get task :state) 'pending))))
      (when (> free 0)
        (cl-decf free)
        (harness-tasks--start task)))))

(defun harness-tasks--blocks (task)
  "Return the content blocks that open TASK's session."
  (cons (list :type "text" :text (plist-get task :prompt))
        (and (plist-get task :attachments) (fboundp 'harness-agent-attachments-to-blocks)
             (harness-agent-attachments-to-blocks (plist-get task :attachments)))))

(declare-function harness-agent-attachments-to-blocks "harness-agent")

(defun harness-tasks--fail (id err)
  "Record ERR as the outcome of task ID."
  (remhash id harness-tasks--starting)
  (harness-log 'warn "task %s failed: %s" id (harness-error-message err))
  (when (gethash id harness-tasks--table)
    (harness-tasks--set id :state 'active :outcome 'error :error (harness-error-message err)))
  (harness-run-soon #'harness-tasks--schedule))

(defun harness-tasks--start (task)
  "Start TASK: make its worktree in a git project, then its session."
  (let ((id (plist-get task :id)))
    (puthash id t harness-tasks--starting)
    (harness-tasks--set id :state 'active :outcome nil :error nil :started (float-time) :finished nil)
    (if (not (harness-tasks--git-p (plist-get task :project)))
        (harness-tasks--open-session id (plist-get task :cwd) nil)
      (harness-then (harness-tasks--make-worktree task)
                    (lambda (wt)
                      (let ((path (file-name-as-directory (plist-get wt :path))))
                        (harness-tasks--set id :worktree path :branch (plist-get wt :branch)
                                            :base (plist-get wt :base))
                        (harness-tasks--open-session id path path)))
                    (lambda (err) (harness-tasks--fail id err))))))

(defun harness-tasks--open-session (id cwd worktree)
  "Create task ID's session in CWD (in WORKTREE, when non-nil) and prompt it."
  (condition-case err
      (let* ((task (harness-tasks--get id))
             (mode (or (plist-get task :permission-mode) harness-tasks-permission-mode))
             (model (or (plist-get task :model) harness-tasks-model))
             (thinking (or (plist-get task :thinking) harness-tasks-thinking))
             (non-interactive (if (plist-member task :non-interactive)
                                  (harness-json-true-p (plist-get task :non-interactive))
                                harness-tasks-non-interactive))
             (session (apply #'harness-call 'session/create
                             :cwd cwd
                             (append (and worktree (list :worktree worktree))
                                     (and mode (list :permission-mode mode))
                                     (and model (list :model model))
                                     (and thinking (list :thinking thinking))
                                     (and non-interactive (list :non-interactive t)))))
             (sid (plist-get session :id)))
        (harness-tasks--set id :session sid)
        (harness-catch (harness-call-async 'agent/prompt sid (harness-tasks--blocks task))
                       (lambda (e) (harness-tasks--fail id e))))
    (error (harness-tasks--fail id err))))

;;;; Following the sessions

(defun harness-tasks--on-turn-started (session-id)
  "Move SESSION-ID's task to active when a turn starts.
A turn during a merge (resolving a conflict) keeps the task merging.  A
message sent to an archived task's session brings the task back too."
  (when-let* ((task (harness-tasks--by-session session-id)))
    (remhash (plist-get task :id) harness-tasks--starting)
    (unless (and (eq (plist-get task :state) 'merging) (plist-get task :merge-status))
      (harness-tasks--set (plist-get task :id) :state 'active :outcome nil :error nil :finished nil
                          :merged nil :archived nil))))

(defun harness-tasks--on-turn-ended (session-id reason)
  "Advance SESSION-ID's task when its turn ended with REASON.
`end-turn' completes the task outside git and queues its merge inside."
  (when-let* ((task (harness-tasks--by-session session-id)))
    (let ((id (plist-get task :id)))
      (remhash id harness-tasks--starting)
      (cond
       ((not (eq reason 'end-turn))
        (unless (plist-get task :merge-status)
          (harness-tasks--set id :state 'active :outcome reason)))
       ((plist-get task :merge-status) nil) ; a conflict turn; merge/finished decides
       ((and (eq (plist-get task :state) 'done) (plist-get task :merged)) nil) ; merged mid-turn
       ((and (plist-get task :worktree) (not (plist-get task :worktree-removed)))
        (harness-tasks--enqueue-merge id))
       (t (harness-tasks--set id :state 'done :outcome reason :finished (float-time))))
      (harness-run-soon #'harness-tasks--schedule))))

(defun harness-tasks--on-pending-changed (session-id &rest _)
  "Re-announce SESSION-ID's task: requests coming and going move its column."
  (when-let* ((task (harness-tasks--by-session session-id)))
    (harness-emit 'task/changed (harness-tasks--view task))))

(defun harness-tasks--on-session-deleted (session-id &rest _)
  "Forget the task of deleted SESSION-ID."
  (when-let* ((task (harness-tasks--by-session session-id)))
    (harness-tasks--remove (plist-get task :id))))

(defun harness-tasks--remove (id)
  "Drop task ID and emit `task/deleted'."
  (remhash id harness-tasks--table)
  (remhash id harness-tasks--starting)
  (harness-debounce 'harness-tasks-save 0.3 #'harness-tasks--save)
  (harness-emit 'task/deleted id)
  (harness-run-soon #'harness-tasks--schedule))

(defun harness-tasks--resume-merges ()
  "Queue the merges of tasks left merging by a restart again.
The merge queue lives in memory, so a restart forgets it."
  (dolist (task (harness-tasks--sorted (lambda (task) (eq (plist-get task :state) 'merging))))
    (when (and (harness-method-exists-p 'merge/status)
               (harness-tasks--session task)
               (not (harness-call 'merge/status (plist-get task :session))))
      (let ((id (plist-get task :id)))
        (harness-tasks--set id :merge-status nil
                            :merge-attempts (max 0 (1- (or (plist-get task :merge-attempts) 1))))
        (harness-tasks--enqueue-merge id)))))

;;;; Methods

(harness-defmethod task/submit (cwd prompt &optional opts)
  "Submit PROMPT as a new task in directory CWD; return the task.
It starts at once when a slot is free, otherwise it waits as pending.
OPTS: `:attachments' (ATTACHMENT list), `:model', `:permission-mode',
`:thinking' and `:non-interactive' (an explicit false turns it off);
missing ones come from the `harness-tasks-' defaults."
  (when (harness-string-blank-p prompt) (error "A task needs a prompt"))
  (harness-tasks--load)
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (task (list :id (concat "t-" (harness-short-id 8))
                     :project (harness-tasks--project cwd) :cwd cwd
                     :prompt (string-trim prompt)
                     :attachments (plist-get opts :attachments)
                     :model (plist-get opts :model)
                     :permission-mode (let ((m (plist-get opts :permission-mode)))
                                        (if (stringp m) (intern m) m))
                     :thinking (plist-get opts :thinking)
                     :state 'pending :created (float-time))))
    (when (plist-member opts :non-interactive)
      (setq task (plist-put task :non-interactive
                            (if (harness-json-true-p (plist-get opts :non-interactive)) t :false))))
    (harness-tasks--put task)
    (harness-tasks--schedule)
    (harness-tasks--view (gethash (plist-get task :id) harness-tasks--table))))

(defun harness-tasks--adoptable-p (session)
  "Non-nil when SESSION may become a task.
It must be open, not a task already and not a merge target."
  (and (not (eq (plist-get session :status) 'inactive))
       (not (harness-tasks--by-session (plist-get session :id)))
       (not (equal (plist-get session :name) harness-tasks-merge-session-name))))

(harness-defmethod task/adoptable (&optional cwd)
  "Return the open sessions of CWD's project (every project without CWD) that
are not tasks yet, newest first."
  (harness-tasks--load)
  (let ((project (and cwd (harness-tasks--project cwd))))
    ;; By the main checkout, so sessions in the project's worktrees count too.
    (cl-remove-if-not (lambda (s) (and (harness-tasks--adoptable-p s)
                                       (or (null project)
                                           (equal project (harness-tasks--project (plist-get s :cwd))))))
                      (harness-call 'session/list))))

(harness-defmethod task/adopt (session-id)
  "Make the ongoing session SESSION-ID a task and return the task.
Its first message becomes the task's prompt; a session in a git worktree
keeps it and is merged through the merge queue like any task.  A running
or blocked session is in progress; an idle one waits for the user."
  (harness-tasks--load)
  (let ((session (harness-call 'session/get session-id)))
    (unless (harness-tasks--adoptable-p session)
      (error "Session %s is already a task or cannot become one" session-id))
    (let* ((first (cl-find 'user (harness-call 'session/nodes session-id) :key (lambda (n) (plist-get n :kind))))
           (prompt (or (and first (not (harness-string-blank-p (plist-get first :content)))
                            (plist-get first :content))
                       (plist-get session :name) "Adopted session"))
           (worktree (plist-get session :worktree))
           (task (list :id (concat "t-" (harness-short-id 8))
                       :project (harness-tasks--project (plist-get session :cwd)) :cwd (plist-get session :cwd)
                       :prompt (string-trim prompt) :session session-id :adopted t
                       :worktree worktree
                       :state 'active
                       :outcome (unless (memq (plist-get session :status) '(running blocked)) 'adopted)
                       :created (plist-get session :created) :started (plist-get session :created))))
      (harness-tasks--put task)
      (when (and worktree (harness-method-exists-p 'worktree/branch))
        (let ((id (plist-get task :id)))
          (harness-then (harness-call-async 'worktree/branch worktree)
                        (lambda (branch) (when (gethash id harness-tasks--table)
                                           (harness-tasks--set id :branch branch)))
                        #'ignore)))
      (harness-tasks--view task))))

(harness-defmethod task/list (&optional cwd)
  "Return the tasks of CWD's project, oldest first; every task without CWD."
  (harness-tasks--load)
  (let ((project (and cwd (harness-tasks--project cwd))))
    (mapcar #'harness-tasks--view
            (harness-tasks--sorted (lambda (task) (or (null project) (equal project (plist-get task :project))))))))

(harness-defmethod task/get (id)
  "Return task ID."
  (harness-tasks--view (harness-tasks--get id)))

(defun harness-tasks--config (key root)
  "Return setting KEY as configured for a session at ROOT."
  (if (and root (harness-method-exists-p 'config/get))
      (ignore-errors (harness-call 'config/get key root))
    (and (boundp key) (symbol-value key))))

(harness-defmethod task/settings (&optional cwd)
  "Return the settings task sessions start with (for CWD's project).
Model and thinking are the values a new task would really get: the task
defaults, else what the project configures."
  (let ((root (and cwd (harness-tasks--project cwd))))
    (list :max-running harness-tasks-max-running
          :permission-mode harness-tasks-permission-mode
          :non-interactive harness-tasks-non-interactive
          :model (or harness-tasks-model (harness-tasks--config 'harness-model root)
                     (and (boundp 'harness-default-model) harness-default-model))
          :thinking (or harness-tasks-thinking (harness-tasks--config 'harness-thinking root))
          :worktrees (and root (harness-tasks--git-p root) t))))

(harness-defmethod task/start (id)
  "Start pending task ID now, even when every slot is taken."
  (let ((task (harness-tasks--get id)))
    (unless (eq (plist-get task :state) 'pending) (error "Task %s already started" id))
    (harness-tasks--start task)
    (harness-call 'task/get id)))

(harness-defmethod task/update (id prompt &optional attachments)
  "Replace the prompt of pending task ID with PROMPT and its ATTACHMENTS."
  (let ((task (harness-tasks--get id)))
    (unless (eq (plist-get task :state) 'pending) (error "Only pending tasks can be edited"))
    (when (harness-string-blank-p prompt) (error "A task needs a prompt"))
    (harness-tasks--set id :prompt (string-trim prompt) :attachments attachments)))

(harness-defmethod task/prompt (id text &optional attachments)
  "Send TEXT and ATTACHMENTS to the session of task ID: a follow-up, or steering."
  (let ((task (harness-tasks--get id)))
    (unless (harness-tasks--session task) (error "Task %s has no session yet" id))
    (when (plist-get task :worktree-removed)
      (error "Task %s was archived and its worktree removed; submit a new task" id))
    (let ((sid (plist-get task :session)))
      (when (eq (plist-get (harness-call 'session/get sid) :status) 'inactive)
        (harness-call 'session/resume sid))
      (when (plist-get task :archived) (harness-tasks--set id :archived nil))
      (harness-tasks--set id :merge-attempts 0)
      (harness-catch (harness-call-async 'agent/prompt sid
                                         (harness-tasks--blocks (list :prompt text :attachments attachments)))
                     (lambda (e) (harness-tasks--fail id e)))
      t)))

(harness-defmethod task/merge (id)
  "Queue task ID's branch for the merge queue again (after a failed merge)."
  (let ((task (harness-tasks--get id)))
    (unless (plist-get task :worktree) (error "Task %s has no worktree to merge" id))
    (when (eq (plist-get task :state) 'done) (error "Task %s is already merged" id))
    (harness-tasks--set id :merge-attempts 0)
    (harness-tasks--enqueue-merge id)
    (harness-call 'task/get id)))

(harness-defmethod task/complete (id)
  "Mark task ID done by hand, merged or not."
  (let ((task (harness-tasks--get id)))
    (when (and (plist-get task :session) (harness-method-exists-p 'merge/cancel))
      (harness-call 'merge/cancel (plist-get task :session)))
    (prog1 (harness-tasks--set id :state 'done :merge-status nil :finished (float-time))
      (harness-run-soon #'harness-tasks--schedule))))

(harness-defmethod task/archive (id &optional restore)
  "Archive done task ID, hiding it and deactivating its session; RESTORE undoes it.
A merged task's worktree is removed and its merged branch deleted."
  (let* ((task (harness-tasks--get id))
         (session (harness-tasks--session task)))
    (when (and (not restore) (harness-tasks--working-p task))
      (error "Task %s is still working" id))
    (when (and session (not restore) (not (eq (plist-get session :status) 'inactive)))
      (harness-call 'session/deactivate (plist-get session :id)))
    (when (and (not restore) (plist-get task :merged) (plist-get task :worktree)
               (not (plist-get task :worktree-removed)) (harness-method-exists-p 'worktree/remove))
      (harness-tasks--remove-worktree task))
    (harness-tasks--set id :archived (and (not restore) t))))

(harness-defmethod task/archive-done (&optional cwd)
  "Archive every done task of CWD's project (every project without CWD).
Return how many were archived."
  (let ((n 0))
    (dolist (task (harness-call 'task/list cwd) n)
      (when (and (eq (plist-get task :state) 'done) (not (plist-get task :archived)))
        (harness-call 'task/archive (plist-get task :id))
        (cl-incf n)))))

(harness-defmethod task/cancel (id)
  "Cancel task ID: a pending task is dropped, a working one stops its turn."
  (let ((task (harness-tasks--get id)))
    (if (eq (plist-get task :state) 'pending)
        (progn (harness-tasks--remove id) nil)
      (when (and (plist-get task :session) (harness-method-exists-p 'agent/cancel))
        (harness-call 'agent/cancel (plist-get task :session)))
      t)))

(harness-defmethod task/delete (id &optional delete-session)
  "Forget task ID; with DELETE-SESSION also cancel and delete its session.
Its worktree, if any, is kept: it may hold work nobody merged."
  (let* ((task (harness-tasks--get id))
         (sid (plist-get task :session)))
    (when (and sid (harness-method-exists-p 'merge/cancel)) (harness-call 'merge/cancel sid))
    (harness-tasks--remove id)
    (when (and delete-session sid (harness-call 'session/exists-p sid))
      (when (harness-method-exists-p 'agent/cancel) (harness-call 'agent/cancel sid))
      (harness-call 'session/delete sid))
    t))

;;;; Module

(defun harness-tasks--init ()
  "Load the records, follow sessions and merges, start waiting tasks."
  (harness-tasks--load)
  (harness-on 'agent/turn-started #'harness-tasks--on-turn-started)
  (harness-on 'agent/turn-ended #'harness-tasks--on-turn-ended)
  (harness-on 'session/deleted #'harness-tasks--on-session-deleted)
  (harness-on 'session/pending-changed #'harness-tasks--on-pending-changed)
  (harness-on 'merge/started #'harness-tasks--on-merge-started)
  (harness-on 'merge/conflict #'harness-tasks--on-merge-conflict)
  (harness-on 'merge/finished #'harness-tasks--on-merge-finished)
  (harness-add-filter 'agent/system-prompt #'harness-tasks--system-prompt 60)
  (harness-add-filter 'naming/system-prompt #'harness-tasks--naming-prompt 60)
  (harness-run-soon #'harness-tasks--resume-merges)
  (harness-run-soon #'harness-tasks--schedule))

(harness-declare-event 'task/changed "(TASK) after a task is submitted or changes state or column.")
(harness-declare-event 'task/deleted "(ID) after a task is removed.")

(harness-define-module 'tasks
  :doc "Task mode: one session per task, from worktree to merged, with a concurrency limit."
  :requires '(store project session agent)
  :init #'harness-tasks--init)

(provide 'harness-tasks)
;;; harness-tasks.el ends here
