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
;; Backlog refinement (once called grooming): a task submitted with
;; `:refine' is jotted down for later, not started.  An agent writes it
;; up first -- briefly, read-only, at the project's root, told so by
;; `harness-tasks-refine-prompt' -- and its final reply becomes the
;; task's prompt; the original words stay in `:note'.  The task then
;; waits in pending as a backlog task (`:backlog'): the scheduler never
;; starts it, only `task/start' does, so the backlog survives restarts
;; until someone picks a task.  Its session is the one that refined it:
;; starting moves that session into the task's worktree and tells it to
;; do the work.  A message to a backlog task's session is feedback on
;; the write-up, which the agent rewrites.
;;
;; States:
;;
;;   pending   submitted, waiting for a free slot (only when
;;             `harness-tasks-max-running' limits how many run at once),
;;             or a backlog task waiting for someone to start it
;;   refining  an agent is writing a backlog task up, or stopped part
;;             way (`:outcome' says why)
;;   active    its session is working on it, or stopped part way
;;             (`:outcome' says why: error, cancelled, merge-failed…)
;;   merging   the agent finished; its branch is queued or merging
;;   done      merged (or finished, outside git); a follow-up message
;;             moves the task back to active
;;
;; Every task a method returns or an event carries also has a derived
;; `:column', the kanban column it belongs in:
;;
;;   pending       waiting for a slot, being refined, or in the backlog
;;   needs-input   requires user input: its session is blocked on a
;;                 permission or a question, or it (or its refinement)
;;                 stopped part way
;;   active        in progress, merging included
;;   done          completed
;;
;; Records persist in tasks.json, written shortly after every change and
;; on exit; the sessions persist as usual.  A harness that stops (Emacs
;; quit, `harness-restart', a crash) interrupts the tasks it was working
;; on, so a start picks them up again: one stopped before its session
;; existed starts over, the others are told to carry on
;; (`harness-tasks-resume-interrupted'), a write-up cut short is written
;; again, and merges in flight are queued again.  Events `task/changed'
;; (TASK) and `task/deleted' (ID) let a UI follow.
;;
;; A board can also host BTW side conversations (`task/btw'), where the
;; user asks how the tasks are going.  The board has no session to fork,
;; so such a conversation is a fresh `btw' session without a parent at
;; the project root; `harness-tasks-btw-prompt' tells it to answer from
;; the task and session tools.

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

(defcustom harness-tasks-refine-prompt
  "## Task refinement
This session refines a task for the backlog: the engineer jotted it down to be done later, maybe by another agent that will not see this conversation.  Do not do the task: write it up.
- Be brief.  Look at the project only as far as you need to name the right files and functions: a handful of reads or searches at most.  This is a write-up, not the work, so do not plan, edit files, run commands or ask the user questions; put open questions in the write-up instead.
- End your turn with the complete write-up as your final message and nothing else.  Its first line is a short imperative title, plain text, no heading markup.  Then, after a blank line, in concise markdown: what is wanted and why, what to change (files, functions, behaviour), how to tell it is done, and open questions or assumptions if there are any.
- When the user replies, take it as feedback on the task and answer with the complete updated write-up."
  "System prompt section of a session that writes a backlog task up.
Its final reply becomes the task's prompt, so it asks for one complete,
self-contained write-up."
  :type 'string :group 'harness)

(defcustom harness-tasks-refine-model nil
  "Model that writes backlog tasks up, or nil for the task's own model."
  :type '(choice (const :tag "The task's model" nil) string) :group 'harness)

(defcustom harness-tasks-refine-thinking "low"
  "Thinking level of refining a backlog task, or nil for the task's own.
A write-up should be quick, so the default thinks little."
  :type '(choice (const :tag "The task's thinking level" nil) string) :group 'harness)

(defcustom harness-tasks-refine-tool-calls 8
  "Tool calls a write-up may make before the agent is told to finish it.
The agent is steered once, to write the task up with what it knows; nil
never tells it.  It keeps a backlog write-up brief."
  :type '(choice (const :tag "Never" nil) integer) :group 'harness)

(defcustom harness-tasks-start-text
  "Start working on this task now.  It was written up earlier without doing any of it; that is over, so change files, run commands and so on as the task requires."
  "Opening of the message that starts a backlog task's work.
The task's write-up follows it, then the request it was written from."
  :type 'string :group 'harness)

(defcustom harness-tasks-btw-prompt
  "## Task board
This is a side conversation the user opened from this project's task board to ask about its tasks: what each one is doing, how far along it is, what it changed, why it is stuck, which ones need the user. Answer from the live state and check it again for every question: task_list shows the board (each task's title, column, state, session, branch and what it waits on), session_read a task's session (its plan, todos, latest transcript and working directory, where git shows what it changed), session_search where something was said, and task_wait or session_wait wait for a task or a session to settle. Refer to tasks by title and id, and keep answers short. Change nothing (tasks, sessions or files) unless the user asks you to."
  "Text added to the system prompt of BTW conversations about a task board.
Such a conversation is opened from the board (`task/btw') to ask about
its tasks; nil adds nothing."
  :type '(choice (const :tag "Nothing" nil) string) :group 'harness)

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

(defcustom harness-tasks-resume-interrupted t
  "When non-nil, tasks a stopped harness interrupted carry on by themselves.
A task that was working when the harness stopped (Emacs quit,
`harness-restart', a crash) is sent `harness-tasks-resume-prompt' when the
harness starts again.  With nil it waits in needs-input instead, with
the outcome `interrupted', until you reply.  The same goes for a backlog
task's write-up: it is written again, or with nil waits for a retry."
  :type 'boolean :group 'harness)

(defcustom harness-tasks-resume-prompt
  "The harness restarted while you were working on this task, so your last turn was cut short: tool calls that were still running did not finish. Check where you left off, then carry on with the task."
  "Message that resumes a task's session after a restart interrupted it."
  :type 'string :group 'harness)

(defconst harness-tasks--store-name "tasks.json" "Store file of the task records.")

(defconst harness-tasks--symbol-keys '(:state :outcome :merge-status)
  "Keys whose values are symbols in memory and strings on disk.")

(defvar harness-tasks--table (make-hash-table :test 'equal)
  "Task id -> task plist.")

(defvar harness-tasks--loaded nil "Non-nil once the records were read from the store.")

(defvar harness-tasks--dirty nil "Non-nil while a change waits to be written to the store.")

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
  (harness-call 'store/save harness-tasks--store-name (harness-tasks--sorted))
  (setq harness-tasks--dirty nil))

(defun harness-tasks--save-soon ()
  "Write the task records once changes stop coming for a moment."
  (setq harness-tasks--dirty t)
  (harness-debounce 'harness-tasks-save 0.3 #'harness-tasks--save))

(defun harness-tasks-flush ()
  "Write the task records now if a change is waiting (on exit and shutdown)."
  (when harness-tasks--dirty
    (condition-case err
        (harness-tasks--save)
      (error (harness-log 'error "tasks: could not save %s: %S" harness-tasks--store-name err)))))

(defun harness-tasks--put (task)
  "Store TASK, schedule a save and emit `task/changed'.  Return its view."
  (puthash (plist-get task :id) task harness-tasks--table)
  (harness-tasks--save-soon)
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

(defun harness-tasks--backlog-p (task)
  "Non-nil when TASK is a backlog task: only `task/start' starts it."
  (harness-json-true-p (plist-get task :backlog)))

(defun harness-tasks--refinement-p (task)
  "Non-nil when a turn of TASK's session refines it rather than doing it.
That is while it is refining, and while it waits in the backlog with
the session that wrote it up."
  (or (eq (plist-get task :state) 'refining)
      (and (eq (plist-get task :state) 'pending) (plist-get task :session) t)))

(defun harness-tasks--turn-p (task)
  "Non-nil while a turn of TASK's session runs (from the moment it is prompted)."
  (let ((sid (plist-get task :session)))
    (and sid (harness-method-exists-p 'agent/running) (harness-call 'agent/running sid) t)))

;;;; Columns

(defun harness-tasks--column (task)
  "Return the kanban column of TASK: pending, needs-input, active or done.
A task being refined shows in pending, where it ends up, unless the
refinement needs the user."
  (pcase (plist-get task :state)
    ('pending 'pending)
    ('done 'done)
    ('refining (let ((session (harness-tasks--session task)))
                 (cond ((plist-get session :pending) 'needs-input)
                       ((harness-tasks--turn-p task) 'pending)
                       ((plist-get task :outcome) 'needs-input)
                       (t 'pending))))
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
  "Tell a task's SESSION what its turns are for (PROMPT filter).
Before the task starts they write it up (`harness-tasks-refine-prompt');
afterwards, in a worktree, they learn how the work reaches the main branch."
  (let ((task (harness-tasks--by-session (plist-get session :id))))
    (cond
     ((and task (harness-tasks--refinement-p task)
           (not (harness-string-blank-p harness-tasks-refine-prompt)))
      (concat prompt "\n\n" harness-tasks-refine-prompt "\n"))
     ((not (and task (plist-get task :worktree))) prompt)
     (t
      (concat prompt "\n\n## Task mode\n"
              (format "You are working on one task, unattended, in your own git worktree %s on branch %s. "
                      (plist-get task :worktree) (plist-get task :branch))
              "Do the whole task there. When you are done, commit all of your changes on that branch "
              "(git add -A, then git commit with a message saying what the change does). "
              (format "Do not merge, rebase onto or push %s yourself: when your turn ends the harness merges "
                      (or (plist-get task :base) "the main branch"))
              "your branch through the merge queue, and it will come back to you if the merge needs anything.\n")))))

(defun harness-tasks--naming-prompt (prompt session)
  "Ask for a ticket title when naming a task's SESSION (PROMPT filter)."
  (if (and (not (harness-string-blank-p harness-tasks-naming-prompt))
           (harness-tasks--by-session (plist-get session :id)))
      (concat prompt "\n\n" harness-tasks-naming-prompt)
    prompt))

;;;; Side conversations about the board

(defun harness-tasks--btw-p (session)
  "Non-nil when SESSION is a BTW conversation about a task board.
Those are the sessions `task/btw' starts: a BTW about a session is a
fork of it, so only the board's have no parent."
  (and (eq (plist-get session :kind) 'btw)
       (null (plist-get session :parent-id))))

(defun harness-tasks--btw-system-prompt (prompt session)
  "Tell SESSION, when it is about a task board, how to answer (PROMPT filter)."
  (if (and (harness-tasks--btw-p session) (not (harness-string-blank-p harness-tasks-btw-prompt)))
      (concat prompt "\n\n" harness-tasks-btw-prompt "\n")
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

(defun harness-tasks--queued-p (task)
  "Non-nil when TASK waits for a slot: pending and not in the backlog."
  (and (eq (plist-get task :state) 'pending) (not (harness-tasks--backlog-p task))))

(defun harness-tasks--schedule ()
  "Start the oldest queued tasks while slots are free.
Backlog tasks wait for `task/start' instead."
  (let ((free (harness-tasks--free-slots)))
    (dolist (task (harness-tasks--sorted #'harness-tasks--queued-p))
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
  "Start TASK: make its worktree in a git project, then its session.
A backlog task already has the session that wrote it up; that session
moves into the worktree and does the work.  A task started again after a
restart cut its start short keeps the worktree it got."
  (let ((id (plist-get task :id))
        (worktree (plist-get task :worktree))
        (launch (if (harness-tasks--session task)
                    #'harness-tasks--continue-session
                  #'harness-tasks--open-session)))
    (puthash id t harness-tasks--starting)
    (harness-tasks--set id :state 'active :outcome nil :error nil :started (float-time) :finished nil)
    (cond
     ((not (harness-tasks--git-p (plist-get task :project)))
      (funcall launch id (plist-get task :cwd) nil))
     ((and worktree (not (plist-get task :worktree-removed)) (file-directory-p worktree))
      (funcall launch id worktree worktree))
     (t
      (harness-then (harness-tasks--make-worktree task)
                    (lambda (wt)
                      (let ((path (file-name-as-directory (plist-get wt :path))))
                        (harness-tasks--set id :worktree path :branch (plist-get wt :branch)
                                            :base (plist-get wt :base))
                        (funcall launch id path path)))
                    (lambda (err) (harness-tasks--fail id err)))))))

(defun harness-tasks--work-settings (task)
  "Return the settings TASK's work runs with, as `session/create' keys.
The task's own, else the `harness-tasks-' defaults; unset ones are left
out, so the session gets what its directory configures."
  (let ((mode (or (plist-get task :permission-mode) harness-tasks-permission-mode))
        (model (or (plist-get task :model) harness-tasks-model))
        (thinking (or (plist-get task :thinking) harness-tasks-thinking))
        (non-interactive (if (plist-member task :non-interactive)
                             (harness-json-true-p (plist-get task :non-interactive))
                           harness-tasks-non-interactive)))
    (append (and mode (list :permission-mode mode))
            (and model (list :model model))
            (and thinking (list :thinking thinking))
            (and non-interactive (list :non-interactive t)))))

(defun harness-tasks--open-session (id cwd worktree)
  "Create task ID's session in CWD (in WORKTREE, when non-nil) and prompt it."
  (condition-case err
      (let* ((task (harness-tasks--get id))
             (session (apply #'harness-call 'session/create
                             :cwd cwd
                             (append (and worktree (list :worktree worktree))
                                     (harness-tasks--work-settings task))))
             (sid (plist-get session :id)))
        (harness-tasks--set id :session sid)
        (harness-catch (harness-call-async 'agent/prompt sid (harness-tasks--blocks task))
                       (lambda (e) (harness-tasks--fail id e))))
    (error (harness-tasks--fail id err))))

(defun harness-tasks--quote (text)
  "Return TEXT as a markdown quote."
  (mapconcat (lambda (line) (if (string-empty-p line) ">" (concat "> " line)))
             (split-string (string-trim text) "\n") "\n"))

(defun harness-tasks--start-text (task)
  "Return the message that starts the work of backlog TASK.
It carries the write-up in full, as edited since, so the work never
depends on the provider remembering the refinement (after moving into a
worktree it does not), and the request it was written from, quoted."
  (let ((prompt (plist-get task :prompt))
        (note (plist-get task :note)))
    (concat harness-tasks-start-text "\n\n" prompt
            (if (and note (not (equal (string-trim note) (string-trim prompt))))
                (concat "\n\n---\nIt was written up from this request (the write-up above takes precedence):\n\n"
                        (harness-tasks--quote note))
              ""))))

(defun harness-tasks--continue-session (id cwd worktree)
  "Start task ID's work in the session that wrote it up, moved to CWD.
WORKTREE, when non-nil, is the task's worktree.  The session takes the
task's settings instead of the refinement's read-only ones.  When the
directory changes, the provider's conversation is dropped: the Claude
CLI keeps conversations per directory, and the start message carries
everything the work needs, while the transcript keeps the refinement."
  (condition-case err
      (let* ((task (harness-tasks--get id))
             (sid (plist-get task :session))
             (session (harness-call 'session/get sid))
             (cwd (file-name-as-directory (expand-file-name cwd)))
             (settings (harness-tasks--work-settings task)))
        (unless (equal cwd (plist-get session :cwd))
          ;; Deactivating closes the provider's process, so the next turn
          ;; starts a new conversation in the new directory.
          (unless (eq (plist-get session :status) 'inactive)
            (harness-call 'session/deactivate sid))
          (harness-call 'session/set-provider-state sid nil))
        (apply #'harness-call 'session/update sid :silent t :cwd cwd
               (append
                (and worktree (list :worktree worktree))
                (list :permission-mode (or (plist-get settings :permission-mode)
                                           (harness-tasks--config 'harness-permission-mode cwd) 'ask)
                      :thinking (or (plist-get settings :thinking) (harness-tasks--config 'harness-thinking cwd))
                      :non-interactive (or (plist-get settings :non-interactive)
                                           (and (not (plist-member task :non-interactive))
                                                (harness-tasks--config 'harness-non-interactive cwd) t)))
                (when-let* ((model (or (plist-get settings :model) (harness-tasks--config 'harness-model cwd))))
                  (list :model model))))
        (when (eq (plist-get (harness-call 'session/get sid) :status) 'inactive)
          (harness-call 'session/resume sid))
        (harness-call 'session/hint sid
                      (if worktree
                          (format "Task started in %s on branch %s"
                                  (abbreviate-file-name worktree) (plist-get task :branch))
                        "Task started"))
        (harness-catch (harness-call-async 'agent/prompt sid
                                           (harness-tasks--blocks
                                            (list :prompt (harness-tasks--start-text task)
                                                  :attachments (plist-get task :attachments))))
                       (lambda (e) (harness-tasks--fail id e))))
    (error (harness-tasks--fail id err))))

;;;; Refinement

(defconst harness-tasks--refine-again-text
  "Write the task up now: your final message is the complete write-up."
  "Message that asks a backlog task's session for its write-up again.")

(defconst harness-tasks--refine-enough-text
  "That is enough looking around: write the task up now with what you know, as your final message."
  "Steering message for a write-up that looked around long enough.
That is once it made `harness-tasks-refine-tool-calls' tool calls.")

(defvar harness-tasks--refine-calls (make-hash-table :test 'equal)
  "Session id -> tool calls of the write-up turn running in it.")

(defun harness-tasks--on-tool-call (session-id &rest _)
  "Count the tool calls of a write-up in SESSION-ID; tell it to finish in time.
At `harness-tasks-refine-tool-calls' calls it is steered to write up now."
  (when-let* ((limit harness-tasks-refine-tool-calls)
              (task (harness-tasks--by-session session-id))
              ((eq (plist-get task :state) 'refining)))
    (let ((n (1+ (gethash session-id harness-tasks--refine-calls 0))))
      (puthash session-id n harness-tasks--refine-calls)
      (when (= n limit)
        (harness-catch (harness-call-async 'agent/prompt session-id harness-tasks--refine-enough-text)
                       #'ignore)))))

(defun harness-tasks--refine-settings (task)
  "Return the `session/create' settings of the session refining TASK.
Asking with nobody to ask makes it read-only: reads are allowed, and
anything else is denied with a hint, which keeps a write-up a write-up."
  (let ((model (or harness-tasks-refine-model (plist-get task :model) harness-tasks-model))
        (thinking (or harness-tasks-refine-thinking (plist-get task :thinking) harness-tasks-thinking)))
    (append (list :permission-mode 'ask :non-interactive t)
            (and model (list :model model))
            (and thinking (list :thinking thinking)))))

(defun harness-tasks--refine-failed (id err)
  "Record ERR as the reason task ID's refinement stopped."
  (harness-log 'warn "refining task %s failed: %s" id (harness-error-message err))
  (when (gethash id harness-tasks--table)
    (harness-tasks--set id :state 'refining :outcome 'error :error (harness-error-message err))))

(defun harness-tasks--refine-turn (id sid blocks)
  "Prompt task ID's session SID with BLOCKS for a write-up.
The turn's end finishes the refinement (`harness-tasks--on-turn-ended');
this only adds the error a failed turn reports."
  (harness-then (harness-call-async 'agent/prompt sid blocks)
                (lambda (result)
                  (let ((task (gethash id harness-tasks--table)))
                    (when (and task (eq (plist-get task :state) 'refining)
                               (plist-get task :outcome) (not (plist-get task :error))
                               (plist-get result :error))
                      (harness-tasks--set id :error (format "%s" (plist-get result :error))))))
                (lambda (e) (harness-tasks--refine-failed id e))))

(defun harness-tasks--refine-blocks (task text)
  "Return the message that gives TASK to its write-up: the task, then TEXT."
  (harness-tasks--blocks (list :prompt (if (harness-string-blank-p text)
                                           (plist-get task :prompt)
                                         (concat (plist-get task :prompt) "\n\n" text))
                               :attachments (plist-get task :attachments))))

(defun harness-tasks--refine (id &optional text)
  "Have an agent write task ID up for the backlog.
The first time a session is made for it at the task's directory and
given the task; afterwards TEXT, feedback on the write-up, goes to that
session (or a request to write it up again).  A session that never
received the task, cut short by a restart, gets the task itself."
  (condition-case err
      (let* ((task (harness-tasks--get id))
             (session (harness-tasks--session task)))
        (harness-tasks--set id :state 'refining :backlog t :outcome nil :error nil
                            :note (or (plist-get task :note) (plist-get task :prompt)))
        (if session
            (let* ((sid (plist-get session :id))
                   (begun (cl-find 'user (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)))))
              (when (eq (plist-get session :status) 'inactive) (harness-call 'session/resume sid))
              (harness-tasks--refine-turn id sid (cond ((not begun) (harness-tasks--refine-blocks task text))
                                                       ((harness-string-blank-p text)
                                                        harness-tasks--refine-again-text)
                                                       (t text))))
          (let* ((sid (plist-get (apply #'harness-call 'session/create :cwd (plist-get task :cwd)
                                        (harness-tasks--refine-settings task))
                                 :id)))
            (harness-tasks--set id :session sid)
            (harness-tasks--refine-turn id sid (harness-tasks--refine-blocks task text)))))
    (error (harness-tasks--refine-failed id err))))

(defun harness-tasks--last-reply (session-id)
  "Return the text SESSION-ID's last turn ended on, or nil.
That is its last assistant message after the last message the user
sent; steering messages within the turn do not end the search."
  (catch 'found
    (dolist (node (reverse (harness-call 'session/nodes session-id)))
      (pcase (plist-get node :kind)
        ('assistant (throw 'found (plist-get node :content)))
        ('user (unless (plist-get (plist-get node :meta) :steering) (throw 'found nil)))))
    nil))

(defun harness-tasks--finish-refinement (id reason)
  "Make the reply that ended task ID's refinement turn (with REASON) its prompt.
A complete turn puts the task in the backlog; any other end leaves it
refining with REASON as its outcome, in front of the user."
  (let* ((task (harness-tasks--get id))
         (reply (and (eq reason 'end-turn) (plist-get task :session)
                     (harness-tasks--last-reply (plist-get task :session)))))
    (if (harness-string-blank-p reply)
        (harness-tasks--set id :state 'refining
                            :outcome (if (eq reason 'end-turn) 'error reason)
                            :error (and (eq reason 'end-turn) "the agent wrote no task description"))
      (harness-tasks--set id :state 'pending :backlog t :prompt (string-trim reply)
                          :refined (float-time) :outcome nil :error nil))))

;;;; Following the sessions

(defun harness-tasks--on-turn-started (session-id)
  "Move SESSION-ID's task to active when a turn starts.
A turn during a merge (resolving a conflict) keeps the task merging; a
turn before the task started (a backlog task's) refines it.  A message
sent to an archived task's session brings the task back too."
  (remhash session-id harness-tasks--refine-calls)
  (when-let* ((task (harness-tasks--by-session session-id)))
    (remhash (plist-get task :id) harness-tasks--starting)
    (cond
     ((harness-tasks--refinement-p task)
      (harness-tasks--set (plist-get task :id) :state 'refining :outcome nil :error nil :archived nil))
     ((and (eq (plist-get task :state) 'merging) (plist-get task :merge-status)) nil)
     (t (harness-tasks--set (plist-get task :id) :state 'active :outcome nil :error nil :finished nil
                            :merged nil :archived nil)))))

(defun harness-tasks--on-turn-ended (session-id reason)
  "Advance SESSION-ID's task when its turn ended with REASON.
`end-turn' completes the task outside git and queues its merge inside;
a refinement turn puts its write-up in the backlog."
  (remhash session-id harness-tasks--refine-calls)
  (when-let* ((task (harness-tasks--by-session session-id)))
    (let ((id (plist-get task :id)))
      (remhash id harness-tasks--starting)
      (cond
       ((harness-tasks--refinement-p task) (harness-tasks--finish-refinement id reason))
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
  (harness-tasks--save-soon)
  (harness-emit 'task/deleted id)
  (harness-run-soon #'harness-tasks--schedule))

;;;; Restarts

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

(defun harness-tasks--interrupted-p (task)
  "Non-nil when TASK was working when the harness last stopped.
An active task without an outcome is working on something; when nothing
in this process works on it, the process that did has stopped."
  (let ((sid (plist-get task :session)))
    (and (eq (plist-get task :state) 'active)
         (null (plist-get task :outcome))
         (not (plist-get task :archived))
         (not (gethash (plist-get task :id) harness-tasks--starting))
         (not (and sid (harness-method-exists-p 'agent/running) (harness-call 'agent/running sid))))))

(defun harness-tasks--resume (id)
  "Prompt the session of task ID to carry on after a restart interrupted it.
A session that never received the task gets the task itself."
  (let* ((task (harness-tasks--get id))
         (sid (plist-get task :session))
         (begun (progn (harness-call 'session/resume sid)
                       (cl-find 'user (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind))))))
    (harness-log 'info "task %s: resuming session %s after a restart" id sid)
    (puthash id t harness-tasks--starting)
    (harness-catch (harness-call-async 'agent/prompt sid
                                       (if begun
                                           (list (list :type "text" :text harness-tasks-resume-prompt))
                                         (harness-tasks--blocks task)))
                   (lambda (e) (harness-tasks--fail id e)))))

(defun harness-tasks--work-begun-p (task)
  "Non-nil when TASK's session got its work: a user message since it started.
A backlog task's session holds its write-up from before that, so any
message will not do."
  (let ((started (or (plist-get task :started) 0)))
    (cl-some (lambda (n) (and (eq (plist-get n :kind) 'user) (>= (or (plist-get n :ts) 0) started)))
             (harness-call 'session/nodes (plist-get task :session)))))

(defun harness-tasks--recover-refinements ()
  "Pick up the write-ups a stopped harness was working on.
A backlog task being written up is written up again by its session, or,
when `harness-tasks-resume-interrupted' is nil or the task is archived,
waits for the user with the outcome `interrupted'."
  (dolist (task (harness-tasks--sorted (lambda (task) (eq (plist-get task :state) 'refining))))
    (unless (or (plist-get task :outcome) (harness-tasks--turn-p task))
      (let ((id (plist-get task :id)))
        (if (and harness-tasks-resume-interrupted (not (plist-get task :archived)))
            (progn (harness-log 'info "task %s: writing it up again after a restart" id)
                   (harness-tasks--refine id))
          (harness-tasks--set id :outcome 'interrupted))))))

(defun harness-tasks--recover ()
  "Pick up the tasks a stopped harness was working on.
Runs once the modules are up, before the scheduler.  A task stopped
before it had a session starts over, in its worktree when it got that
far; a task whose session was at work carries on with
`harness-tasks-resume-prompt', or waits for the user with the outcome
`interrupted' when `harness-tasks-resume-interrupted' is nil.  A
backlog task stopped while its session was being handed the work starts
again, or with nil goes back to the backlog.  Working past the
concurrency limit is fine here: these tasks held their slots before the
restart."
  (dolist (task (harness-tasks--sorted #'harness-tasks--interrupted-p))
    (let ((id (plist-get task :id)))
      (condition-case err
          (cond
           ((plist-get task :session)
            (cond ((not (harness-tasks--session task))
                   (harness-tasks--set id :outcome 'error :error "its session no longer exists"))
                  ((and (harness-tasks--backlog-p task) (not (harness-tasks--work-begun-p task)))
                   (if harness-tasks-resume-interrupted
                       (progn (harness-log 'info "task %s: starting it again after a restart" id)
                              (harness-tasks--start task))
                     (harness-tasks--set id :state 'pending :started nil)))
                  (harness-tasks-resume-interrupted (harness-tasks--resume id))
                  (t (harness-tasks--set id :outcome 'interrupted
                                         :error "the harness stopped while it was working"))))
           ((plist-get task :worktree)
            (harness-log 'info "task %s: opening its session again after a restart" id)
            (puthash id t harness-tasks--starting)
            (harness-tasks--open-session id (plist-get task :worktree) (plist-get task :worktree)))
           (t
            (harness-log 'info "task %s: queued again after a restart" id)
            (harness-tasks--set id :state 'pending :started nil)))
        (error (harness-tasks--fail id err))))))

;;;; Methods

(harness-defmethod task/submit (cwd prompt &optional opts)
  "Submit PROMPT as a new task in directory CWD; return the task.
It starts at once when a slot is free, otherwise it waits as pending.
OPTS: `:attachments' (ATTACHMENT list), `:model', `:permission-mode',
`:thinking' and `:non-interactive' (an explicit false turns it off);
missing ones come from the `harness-tasks-' defaults.  With `:refine'
the task goes to the backlog instead: an agent writes it up (state
refining), then it waits in pending until `task/start'."
  (when (harness-string-blank-p prompt) (error "A task needs a prompt"))
  (harness-tasks--load)
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (refine (harness-json-true-p (plist-get opts :refine)))
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
    (when refine
      (setq task (append task (list :backlog t :note (string-trim prompt)))))
    (harness-tasks--put task)
    (if refine
        (harness-tasks--refine (plist-get task :id))
      (harness-tasks--schedule))
    (harness-tasks--view (gethash (plist-get task :id) harness-tasks--table))))

(harness-defmethod task/refine (id &optional text)
  "Have an agent write task ID up for the backlog; return the task.
A task waiting for a slot becomes a backlog task.  One written up
already, or whose write-up stopped, is written up again by the same
session, TEXT being feedback for it.  Either way it then waits in
pending until `task/start'."
  (let ((task (harness-tasks--get id)))
    (unless (memq (plist-get task :state) '(pending refining))
      (error "Task %s has started; only a task that has not can be refined" id))
    (when (harness-tasks--turn-p task) (error "Task %s is being refined already" id))
    (harness-tasks--refine id text)
    (harness-call 'task/get id)))

(defun harness-tasks--adoptable-p (session)
  "Non-nil when SESSION may become a task.
It must be open, not a task already, not a merge target and not a
conversation about the board."
  (and (not (eq (plist-get session :status) 'inactive))
       (not (harness-tasks--by-session (plist-get session :id)))
       (not (equal (plist-get session :name) harness-tasks-merge-session-name))
       (not (harness-tasks--btw-p session))))

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

(harness-defmethod task/btw (cwd &optional name)
  "Start a BTW conversation about the task board of CWD's project.
Return its session, where the user asks how the tasks are going: a
`btw' session named NAME at the project root, without a parent (a BTW
about a session is a fork of it instead), which
`harness-tasks-btw-prompt' tells to answer with the task and session
tools.  The caller sends the first question."
  (harness-call 'session/create :cwd (harness-tasks--project cwd) :kind 'btw :name name))

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
  "Start pending task ID now, even when every slot is taken.
A backlog task starts too, and so does one whose write-up stopped (with
the prompt it has), but not one an agent is writing up right now."
  (let ((task (harness-tasks--get id)))
    (unless (memq (plist-get task :state) '(pending refining)) (error "Task %s already started" id))
    (when (harness-tasks--turn-p task)
      (error "Task %s is still being written up; wait for it or stop it" id))
    (harness-tasks--start task)
    (harness-call 'task/get id)))

(harness-defmethod task/update (id prompt &optional attachments)
  "Replace the prompt of pending task ID with PROMPT and its ATTACHMENTS.
A task whose write-up stopped can be written by hand this way; it then
waits in the backlog like a refined one."
  (let ((task (harness-tasks--get id)))
    (unless (memq (plist-get task :state) '(pending refining))
      (error "Only tasks that have not started can be edited"))
    (when (harness-tasks--turn-p task)
      (error "Task %s is being written up; wait for it or stop it" id))
    (when (harness-string-blank-p prompt) (error "A task needs a prompt"))
    (harness-tasks--set id :prompt (string-trim prompt) :attachments attachments
                        :state 'pending :outcome nil :error nil)))

(harness-defmethod task/prompt (id text &optional attachments)
  "Send TEXT and ATTACHMENTS to the session of task ID: a follow-up, or steering.
Before a backlog task starts, TEXT is feedback on its write-up."
  (let ((task (harness-tasks--get id)))
    (unless (harness-tasks--session task) (error "Task %s has no session yet" id))
    (when (plist-get task :worktree-removed)
      (error "Task %s was archived and its worktree removed; submit a new task" id))
    (let ((sid (plist-get task :session))
          (blocks (harness-tasks--blocks (list :prompt text :attachments attachments))))
      (when (eq (plist-get (harness-call 'session/get sid) :status) 'inactive)
        (harness-call 'session/resume sid))
      (when (plist-get task :archived) (harness-tasks--set id :archived nil))
      (harness-tasks--set id :merge-attempts 0)
      (if (harness-tasks--refinement-p task)
          (harness-tasks--refine-turn id sid blocks)
        (harness-catch (harness-call-async 'agent/prompt sid blocks)
                       (lambda (e) (harness-tasks--fail id e))))
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
  "Cancel task ID: a pending task is dropped, a working one stops its turn.
A task being written up stops; once it has stopped, cancelling drops it.
Dropping a backlog task deletes the session that wrote it up, too: its
transcript is only the write-up, which goes with the task."
  (let* ((task (harness-tasks--get id))
         (state (plist-get task :state)))
    (if (or (eq state 'pending) (and (eq state 'refining) (not (harness-tasks--turn-p task))))
        (let ((sid (plist-get task :session)))
          (harness-tasks--remove id)
          (when (and sid (harness-call 'session/exists-p sid))
            (harness-call 'session/delete sid))
          nil)
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
  "Load the records, follow sessions and merges, then get work going.
Once every module is up, work a stopped harness interrupted is picked
up again, merges in flight are queued again and waiting tasks start."
  (harness-tasks--load)
  (add-hook 'kill-emacs-hook #'harness-tasks-flush)
  (harness-on 'agent/turn-started #'harness-tasks--on-turn-started)
  (harness-on 'agent/turn-ended #'harness-tasks--on-turn-ended)
  (harness-on 'agent/tool-call #'harness-tasks--on-tool-call)
  (harness-on 'session/deleted #'harness-tasks--on-session-deleted)
  (harness-on 'session/pending-changed #'harness-tasks--on-pending-changed)
  (harness-on 'merge/started #'harness-tasks--on-merge-started)
  (harness-on 'merge/conflict #'harness-tasks--on-merge-conflict)
  (harness-on 'merge/finished #'harness-tasks--on-merge-finished)
  (harness-add-filter 'agent/system-prompt #'harness-tasks--system-prompt 60)
  (harness-add-filter 'agent/system-prompt #'harness-tasks--btw-system-prompt 60)
  (harness-add-filter 'naming/system-prompt #'harness-tasks--naming-prompt 60)
  (harness-run-soon #'harness-tasks--recover)
  (harness-run-soon #'harness-tasks--resume-merges)
  (harness-run-soon #'harness-tasks--recover-refinements)
  (harness-run-soon #'harness-tasks--schedule))

(harness-declare-event 'task/changed "(TASK) after a task is submitted or changes state or column.")
(harness-declare-event 'task/deleted "(ID) after a task is removed.")

(harness-define-module 'tasks
  :doc "Task mode: one session per task, from backlog write-up or worktree to merged, with a concurrency limit."
  :requires '(store project session agent)
  :init #'harness-tasks--init
  :shutdown #'harness-tasks-flush)

(provide 'harness-tasks)
;;; harness-tasks.el ends here
