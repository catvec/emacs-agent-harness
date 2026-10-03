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
;; The worktree is locked until its branch is merged, so a `git worktree
;; prune' run where it cannot be seen (in another session's sandbox)
;; keeps it; a merged task that goes back to work locks it again.
;;
;; Review: finished work is not done until the user has looked at it
;; (`harness-tasks-require-verification').  A task whose turn ends
;; cleanly waits in review instead, its branch not merged yet in a git
;; project.  `task/verify' accepts it: its branch goes through the merge
;; queue and the task is done once merged (outside git, at once).
;; `task/reject' sends it back with feedback: the feedback goes to the
;; same session, in its own worktree, as a new prompt, and the task
;; comes back to review when that turn ends.  Every round of feedback is
;; kept with the task (`:feedback'), and so is the verification
;; (`:verified', `:verified-at').
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
;;   merging   the agent finished (and, with review, the user verified
;;             the work); its branch is queued or merging, or its
;;             session resolves the merge's conflicts (`:merge-status'
;;             queued, merging or conflict; `:merge-queued' says when
;;             the branch joined the queue)
;;   review    the agent finished; the work waits for the user to
;;             verify it or send it back with feedback
;;   done      merged (or finished, outside git), and verified with
;;             review; a follow-up message moves the task back to active
;;
;; Every task a method returns or an event carries also has a derived
;; `:column', the kanban column it belongs in:
;;
;;   pending       waiting for a slot, being refined, or in the backlog
;;   needs-input   requires user input: its session is blocked on a
;;                 permission or a question, or it (or its refinement)
;;                 stopped part way
;;   review        finished, waiting for the user to verify it
;;   merging       its branch holds a place in the merge queue: queued,
;;                 merging, or its session resolving the conflicts
;;                 (unless that session waits on the user: needs-input)
;;   active        in progress
;;   done          completed
;;
;; Records are written shortly after every change and on exit; the
;; sessions persist as usual.  A git project keeps its tasks inside its
;; repository, in .git/harness/tasks.json of the main checkout: the git
;; directory every worktree shares, out of every working tree, so the
;; records never reach git status, a commit or the merge queue (see
;; Stores below and `harness-tasks-store-in-repository').  The tasks of
;; other projects are in tasks.json in the state directory, where git
;; projects' were before; they move by themselves.
;;
;; Such a git project's board is also a folder of markdown files in its
;; main checkout, docs/tasks by default (`harness-tasks-directory'): one
;; file per task, YAML frontmatter for the fields code reads, then the
;; prompt, the request it was written up from and the plan.  The harness
;; writes them as tasks change and reads back what people edit or add
;; (see Task files below).
;;
;; A harness that stops (Emacs quit, `harness-restart', a crash)
;; interrupts the tasks it was working on, so a start picks them up
;; again: one stopped before its session existed starts over, the others
;; are told to carry on (`harness-tasks-resume-interrupted'), a write-up
;; cut short is written again, and merges in flight are queued again.
;; Tasks in review simply wait on.  Events `task/changed' (TASK) and
;; `task/deleted' (ID) let a UI follow, `task/review' (TASK) tells it
;; when a task's work waits for the user to review it, and `task/done'
;; (TASK HOW) when a task becomes done: HOW is `merged' (its branch
;; merged), `finished' (its turn ended with nothing to merge or review),
;; `verified' (the user accepted it, with nothing left to merge) or
;; `completed' (marked done by hand).
;;
;; A board can also host BTW side conversations (`task/btw'), where the
;; user asks how the tasks are going.  Like every BTW, each is a new
;; `btw' session sharing nothing with any other; as the board has no
;; session to list it under, it has no parent, and it works at the
;; project root.  `harness-tasks-btw-prompt' tells it to answer from the
;; task and session tools.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)

(defcustom harness-tasks-max-running nil
  "Tasks that may work at the same time; the rest wait as pending.
nil (the default) means no limit."
  :type '(choice (const :tag "No limit" nil) integer) :group 'harness)

(defcustom harness-tasks-require-verification t
  "When non-nil, finished work waits for the user to review it.
A task whose turn ends cleanly goes to review instead of done, in a git
project with its branch not merged yet.  Verifying it (`task/verify')
merges the branch and completes the task; sending it back with
feedback (`task/reject') has its session work on it again.  With nil a
task is done once its branch merges, or outside git once its turn ends."
  :type 'boolean :group 'harness)

(defcustom harness-tasks-permission-mode 'auto
  "Permission mode of task sessions, or nil for the configured default."
  :type '(choice (const :tag "Configured default" nil)
                 (const ask) (const accept-edits) (const auto) (const yolo))
  :group 'harness)

(defcustom harness-tasks-non-interactive t
  "When non-nil, task sessions run non-interactive.
They never wait for the user: the auto-mode judge decides what would
ask them, and after a denial the agent is told to find another way, so
a task keeps working while nobody watches it."
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

(defcustom harness-tasks-reject-text
  "The user reviewed your work on this task and sent it back. Address their feedback below, then finish as before (commit your changes, if you work in a git worktree). Your work goes back to the user for review when your turn ends."
  "Opening of the message that sends a task back to its session after review.
The user's feedback follows it (`task/reject')."
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

(defcustom harness-tasks-store-in-repository t
  "When non-nil, a git project keeps its tasks inside its repository.
Their records go to harness/tasks.json in the git directory every
worktree of the repository shares -- .git/harness/tasks.json in the main
checkout, whichever worktree a task works in.  That is out of every
working tree, so the records never show in git status, never get
committed and never meet the merge queue.  The tasks of other projects,
and with nil every task, are kept in `harness-state-directory'.  Records
move to where they belong by themselves, at the next save.

A repository's store belongs to the harness whose state directory it
names, which holds the tasks' sessions.  Another harness (one with a
state directory of its own, like a test run) keeps its tasks of that
repository in its state directory instead."
  :type 'boolean :group 'harness)

(defcustom harness-tasks-directory-poll 2
  "Seconds between looks at the task folders for files changed by hand.
A folder is also read when a board lists its tasks and before every
save; nil only does that.  The folder is `harness-tasks-directory'."
  :type '(choice (const :tag "Only when listing and saving" nil) number) :group 'harness)

(defcustom harness-tasks-directory-archive "archive"
  "Subfolder of a task folder that the files of archived tasks move to.
Restoring a task moves its file back.  The folder's subfolders are not
read, so a file moved there by hand archives its task too.  nil deletes
the files of archived tasks instead.  The task folder is
`harness-tasks-directory'."
  :type '(choice (const :tag "Delete the files" nil) (string :tag "Subfolder")) :group 'harness)

(defcustom harness-tasks-directory-ignore
  "\\`\\(?:[._#~].*\\|readme\\.md\\|index\\.md\\|template\\.md\\)\\'"
  "Names of the files in a task folder that are no tasks, matched ignoring case.
The folder is `harness-tasks-directory'; only its .md files count."
  :type 'regexp :group 'harness)

(defvar harness-state-directory)

(defconst harness-tasks--store-name "tasks.json"
  "Store file in the state directory: the global store.
It keeps the tasks of projects outside git, and of every project when
`harness-tasks-store-in-repository' is nil.")

(defconst harness-tasks--repository-store-name "harness/tasks.json"
  "Store file of a repository's tasks, relative to its common git directory.")

(defconst harness-tasks--registry-name "task-stores.json"
  "File in the state directory listing the repository stores this harness keeps.
A start reads them all, so every board comes back and the work a stop
interrupted carries on.")

(defconst harness-tasks--backup-suffix ".bak"
  "Suffix of the copy of the global store from before records moved out of it.")

(defconst harness-tasks--symbol-keys '(:state :outcome :merge-status)
  "Keys whose values are symbols in memory and strings on disk.")

(defvar harness-tasks--table (make-hash-table :test 'equal)
  "Task id -> task plist.")

(defvar harness-tasks--loaded nil "Non-nil once the records were read from the stores.")

(defvar harness-tasks--dirty nil "Non-nil while a change waits to be written to the stores.")

(defvar harness-tasks--stores (make-hash-table :test 'equal)
  "Repository store path -> `mine' once read, or `foreign'.
A foreign store is not this harness's to write: another harness owns
it, or it could not be written.")

(defvar harness-tasks--written (make-hash-table :test 'equal)
  "Store path -> the JSON text it holds, as last read or written.
A save skips the stores whose text would not change.")

(defvar harness-tasks--backup-checked nil
  "Non-nil once this process checked whether the global store needs its copy.")

(defvar harness-tasks--loading nil
  "Non-nil while `harness-tasks--load' reads the stores.")

(defvar harness-tasks--starting (make-hash-table :test 'equal)
  "Task ids that are starting: worktree or session made, first turn not begun.
They hold a slot so a burst of submissions never overshoots the limit.")

(defvar harness-tasks--file-stamps (make-hash-table :test 'equal)
  "Task file path -> (MTIME SIZE) as this process last wrote or read it.
A folder read skips the files whose stamp did not change.")

(defvar harness-tasks--file-roots (make-hash-table :test 'equal)
  "Project -> the folder of its task files, for the projects this process reads.")

(defvar harness-tasks--poll-timer nil "Timer that runs `harness-tasks--poll'.")

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

(defun harness-tasks--oldest-first (tasks)
  "Return TASKS sorted oldest first (destructively)."
  (sort tasks (lambda (a b) (< (plist-get a :created) (plist-get b :created)))))

(defun harness-tasks--sorted (&optional pred)
  "Return the tasks matching PRED, oldest first."
  (let (out)
    (maphash (lambda (_ task) (when (or (null pred) (funcall pred task)) (push task out)))
             harness-tasks--table)
    (harness-tasks--oldest-first out)))

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

(defun harness-tasks--verified-p (task)
  "Non-nil when the user verified TASK's work."
  (harness-json-true-p (plist-get task :verified)))

(defun harness-tasks--needs-review-p (task)
  "Non-nil when TASK's finished work waits for the user's review.
That is with `harness-tasks-require-verification', until the user
verified the work."
  (and harness-tasks-require-verification (not (harness-tasks--verified-p task))))

(defun harness-tasks--merged-p (task)
  "Non-nil when TASK's branch is merged."
  (harness-json-true-p (plist-get task :merged)))

(defun harness-tasks--to-review (id &rest plist)
  "Put task ID in review with PLIST merged in; emit `task/review'.
Return the task's view."
  (let ((view (apply #'harness-tasks--set id :state 'review :merge-status nil :conflicts nil plist)))
    (harness-emit 'task/review view)
    view))

(defun harness-tasks--to-done (id how &rest plist)
  "Complete task ID with PLIST merged in; emit `task/done' if it was not done.
HOW says what completed it: `merged' (the merge queue merged its
branch), `finished' (its turn ended with nothing to merge or review),
`verified' (the user accepted its work, with nothing left to merge) or
`completed' (marked done by hand).  Return the task's view."
  (let* ((was (plist-get (harness-tasks--get id) :state))
         (view (apply #'harness-tasks--set id :state 'done plist)))
    (unless (eq was 'done)
      (harness-emit 'task/done view how))
    view))

;;;; Stores
;;
;; Every record is kept in one store, picked by its project.  A git
;; project's is its repository store: `harness-tasks--repository-store-name'
;; in the git directory all worktrees of the repository share.  The main
;; checkout and every task worktree resolve it to the same file, in the
;; main repository and out of every working tree, so git status, commits,
;; merges and the merge queue never see it.  The tasks of other projects,
;; and all of them when `harness-tasks-store-in-repository' is nil, are
;; in the global store in the state directory.  A repository store names
;; the state directory of the harness it belongs to, where the tasks'
;; sessions are, and another harness leaves it alone.  The registry lists
;; the repository stores, so a start reads them all.
;;
;; A save resolves the store of every record and writes the stores whose
;; text changes.  So a record kept where its project does not keep it
;; moves by itself: the first save after an upgrade takes git projects'
;; tasks out of the global store (copied aside first) into their
;; repositories, and turning the option off brings them back.

(defun harness-tasks--state-directory ()
  "Return the state directory, absolute: the owner repository stores name."
  (file-name-as-directory (expand-file-name harness-state-directory)))

(defun harness-tasks--global-store ()
  "Return the path of the global store."
  (expand-file-name harness-tasks--store-name (harness-tasks--state-directory)))

(defun harness-tasks--registry ()
  "Return the path of the registry of repository stores."
  (expand-file-name harness-tasks--registry-name (harness-tasks--state-directory)))

(defun harness-tasks--repository-store (project)
  "Return the path of the store in PROJECT's git repository, or nil outside git."
  (when-let* ((git (and project (harness-files-git-common-dir project))))
    (expand-file-name harness-tasks--repository-store-name git)))

(defun harness-tasks--read-json (path)
  "Return the JSON file PATH parsed, or nil when it does not exist.
Its text is remembered as what PATH holds, so writing the same is skipped."
  (when-let* ((text (harness-read-file path)))
    (puthash path text harness-tasks--written)
    (condition-case err
        (harness-json-parse text)
      (error (harness-log 'error "tasks: cannot parse %s: %S" path err) nil))))

(defun harness-tasks--write-json (path obj)
  "Write OBJ as JSON to PATH atomically, unless PATH holds that already.
The JSON is text, as `harness-read-file' reads it, so a store holding
non-ASCII text compares equal too."
  (let ((json (harness-json-encode-text obj)))
    (unless (equal json (gethash path harness-tasks--written))
      (harness-write-file-atomically path json)
      (puthash path json harness-tasks--written))))

(defun harness-tasks--delete-json (path)
  "Delete the file PATH if it exists."
  (remhash path harness-tasks--written)
  (when (file-exists-p path) (delete-file path)))

(defun harness-tasks--own-store-p (owner)
  "Non-nil when OWNER, the state directory a store names, is this harness's."
  (let ((mine (harness-tasks--state-directory)))
    (or (equal (file-name-as-directory (expand-file-name owner)) mine)
        (ignore-errors (file-equal-p owner mine)))))

(defun harness-tasks--add-records (records)
  "Add the stored RECORDS whose ids are not known yet; return the tasks added."
  (let (added)
    (dolist (record (and (listp records) records))
      (let ((id (and (consp record) (plist-get record :id))))
        (when (and id (not (gethash id harness-tasks--table)))
          (let ((task (harness-tasks--intern record)))
            (puthash id task harness-tasks--table)
            (push task added)))))
    (nreverse added)))

(defun harness-tasks--open-store (path)
  "Return non-nil when this harness keeps tasks in the repository store PATH.
The first time, read PATH and add its records.  A store naming another
state directory, one that still exists, is another harness's: it is
left alone and nil returned.  One whose owner is gone is taken over,
records and all.  Records found after a start are announced and picked
up like those of a start."
  (pcase (gethash path harness-tasks--stores)
    ('mine t)
    ('foreign nil)
    (_
     (let* ((data (harness-tasks--read-json path))
            ;; A bare array of records, like the global store's, names no owner.
            (store (cond ((keywordp (car-safe data)) data)
                         ((listp data) (list :tasks data))))
            (owner (plist-get store :state-directory)))
       (if (and (stringp owner) (not (harness-tasks--own-store-p owner)) (file-directory-p owner))
           (progn
             (harness-log 'warn "tasks: %s belongs to the harness of %s; this one keeps its tasks of that repository in %s"
                          path owner (harness-tasks--global-store))
             (puthash path 'foreign harness-tasks--stores)
             nil)
         (puthash path 'mine harness-tasks--stores)
         (let ((added (harness-tasks--add-records (plist-get store :tasks))))
           (when (and added (not harness-tasks--loading))
             (dolist (task added) (harness-emit 'task/changed (harness-tasks--view task)))
             (harness-tasks--save-soon)
             (harness-tasks--pick-up)))
         t)))))

(defun harness-tasks--drop-store (path)
  "Delete the repository store PATH, left without records.
Its directory goes too when nothing else is in it."
  (harness-tasks--delete-json path)
  (ignore-errors (delete-directory (file-name-directory path)))
  (remhash path harness-tasks--stores))

(defun harness-tasks--store-of (project)
  "Return the path of the store PROJECT's tasks are kept in."
  (or (and harness-tasks-store-in-repository
           (when-let* ((path (harness-tasks--repository-store project)))
             (and (harness-tasks--open-store path) path)))
      (harness-tasks--global-store)))

(defun harness-tasks--open-project (project)
  "Read the repository store of PROJECT unless this process has.
So a board shows its repository's tasks even when the registry missed them."
  (when-let* ((path (and harness-tasks-store-in-repository
                         (harness-tasks--repository-store project))))
    (harness-tasks--open-store path)))

(defun harness-tasks--backup-global (homes)
  "Copy the global store aside before a save first moves records out of it.
Before repository stores it held every task; the first save that moves
some into their repositories copies it to tasks.json.bak, once.  HOMES
maps projects to the stores they keep their tasks in."
  (unless harness-tasks--backup-checked
    (setq harness-tasks--backup-checked t)
    (let* ((global (harness-tasks--global-store))
           (backup (concat global harness-tasks--backup-suffix))
           (text (and (not (file-exists-p backup))
                      (or (gethash global harness-tasks--written) (harness-read-file global)))))
      (when (and text
                 (cl-some (lambda (record)
                            (when-let* ((task (and (consp record)
                                                   (gethash (plist-get record :id) harness-tasks--table))))
                              (not (equal (gethash (plist-get task :project) homes) global))))
                          (ignore-errors (harness-json-parse text))))
        (harness-write-file-atomically backup text)
        (harness-log 'info "tasks: git projects keep their tasks in their repositories now; %s is %s from before"
                     backup global)))))

(defun harness-tasks--save-repository (path groups global)
  "Write the repository store PATH with its records in GROUPS.
GROUPS maps store paths to their records, GLOBAL is the global store's.
A store without records is deleted.  One that cannot be written is not
this harness's to write any more: its records go to the global store."
  (let ((tasks (gethash path groups)))
    (condition-case err
        (if tasks
            (harness-tasks--write-json path (list :state-directory (harness-tasks--state-directory)
                                                  :tasks (harness-json-array tasks)))
          (harness-tasks--drop-store path))
      (error
       (harness-log 'error "tasks: cannot write %s; keeping its tasks in %s: %S" path global err)
       (puthash path 'foreign harness-tasks--stores)
       (remhash path groups)
       (puthash global (harness-tasks--oldest-first (append tasks (gethash global groups))) groups)))))

(defun harness-tasks--save ()
  "Write every task record now, each into the store of its project.
The task files go first (see Task files), so the stores record what
they hold.  Stores whose text would not change are skipped, and a
repository store left without records is deleted.  Repository stores go
first, so a record moving out of the global store stays there until its
repository has it; one that cannot be written leaves its records there."
  (harness-tasks--save-files)
  (let ((homes (make-hash-table :test 'equal))
        (groups (make-hash-table :test 'equal))
        (global (harness-tasks--global-store))
        (more t)
        (repositories nil))
    ;; Opening a store the first time adds its records, maybe of projects
    ;; not seen yet: resolve until every project has its store.
    (while more
      (setq more nil)
      (dolist (task (harness-tasks--sorted))
        (let ((project (plist-get task :project)))
          (unless (gethash project homes)
            (puthash project (harness-tasks--store-of project) homes)
            (setq more t)))))
    (dolist (task (reverse (harness-tasks--sorted)))
      (push task (gethash (gethash (plist-get task :project) homes) groups)))
    (harness-tasks--backup-global homes)
    (maphash (lambda (path state) (when (eq state 'mine) (push path repositories)))
             harness-tasks--stores)
    (setq repositories (sort repositories #'string<))
    (dolist (path repositories)
      (harness-tasks--save-repository path groups global))
    (let ((registered (cl-remove-if-not (lambda (path) (gethash path groups)) repositories)))
      (if registered
          (harness-tasks--write-json (harness-tasks--registry) (harness-json-array registered))
        (harness-tasks--delete-json (harness-tasks--registry))))
    (harness-tasks--write-json global (harness-json-array (gethash global groups)))
    (setq harness-tasks--dirty nil)))

(defun harness-tasks--save-soon ()
  "Write the task records once changes stop coming for a moment."
  (setq harness-tasks--dirty t)
  (harness-debounce 'harness-tasks-save 0.3 #'harness-tasks-flush))

(defun harness-tasks-flush ()
  "Write the task records now if a change is waiting (on exit and shutdown)."
  (when harness-tasks--dirty
    (condition-case err
        (harness-tasks--save)
      (error (harness-log 'error "tasks: could not save the task records: %S" err)))))

(defun harness-tasks--forget-stores ()
  "Forget what this process read and wrote of the stores and task files."
  (clrhash harness-tasks--stores)
  (clrhash harness-tasks--written)
  (clrhash harness-tasks--file-stamps)
  (clrhash harness-tasks--file-roots)
  (setq harness-tasks--backup-checked nil))

(defun harness-tasks--load ()
  "Read the task records from their stores once, then the task files.
The repository stores of the registry come first, then the global
store, so a record in both (a move a crash cut short) keeps its
repository copy.  The task folders of their projects follow: edits made
while the harness was down are taken and files nobody knows become
tasks, so the files alone bring a board back.  A save follows, which
moves the records kept where their project does not keep them, like git
projects' tasks from before repository stores."
  (unless harness-tasks--loaded
    (setq harness-tasks--loaded t)
    (harness-tasks--forget-stores)
    (let ((harness-tasks--loading t)
          (registry (harness-tasks--read-json (harness-tasks--registry))))
      (dolist (path (and (listp registry) registry))
        (when (stringp path)
          (condition-case err
              (harness-tasks--open-store path)
            (error (harness-log 'error "tasks: cannot read %s: %S" path err)))))
      (harness-tasks--add-records (harness-tasks--read-json (harness-tasks--global-store)))
      (harness-tasks--scan-roots (delete-dups (mapcar (lambda (task) (plist-get task :project))
                                                      (harness-tasks--sorted)))))
    (harness-tasks--save-soon)))

;;;; Task files
;;
;; Besides its store, a git project whose tasks this harness keeps in its
;; repository (see Stores) has a markdown file for every task on its
;; board in `harness-tasks-directory' (docs/tasks) of its main checkout,
;; so the board plays along with projects that keep their tasks and plans
;; as files.  A task file is YAML frontmatter with the fields code reads,
;; as in SKILL.md files, then the task: its prompt (the first line a
;; heading), the request it was written up from (`:note'), the feedback
;; of every time the user sent it back from review (`:feedback') and its
;; session's plan:
;;
;;   ---
;;   id: t-k3j9x2ab
;;   title: Add CSV export to reports
;;   state: pending
;;   column: pending
;;   backlog: true
;;   created: 2026-10-01T13:20:01Z
;;   updated: 2026-10-01T13:22:40Z
;;   ---
;;
;;   # Add CSV export to reports
;;
;;   Reports should ...
;;
;;   <!-- harness:request -->
;;   ## Request
;;
;;   > csv export for the reports page
;;
;; A task sent back from review has a review section after the request,
;; one round of feedback under each heading, and its verification in the
;; frontmatter (`verified: TIME') once the user accepts it:
;;
;;   <!-- harness:review -->
;;   ## Review
;;
;;   ### Sent back 2026-10-01T14:02:11Z
;;
;;   > Also export the totals row.
;;
;; The store keeps the whole record, with what only the harness needs
;; (attachments, worktree, merge target); the files show the rest and
;; take edits.  Only the main checkout gets files, never a task's
;; worktree, and the harness never commits them.
;;
;; - Writing: a save first reads what changed on disk, then writes the
;;   file of every task that changed since its file was last in step with
;;   it (`:file-synced'), before the stores.  A file keeps the name it got
;;   (`<id>-<slug>.md' when the harness makes it).  Archiving a task moves
;;   its file into the archive subfolder (`harness-tasks-directory-archive')
;;   and restoring it moves it back; deleting or cancelling a task deletes
;;   its file.
;; - Reading: on load, when a board lists the project's tasks, before
;;   every save and every `harness-tasks-directory-poll' seconds (file
;;   notifications never reach a batch Emacs), the files whose stamp
;;   changed are read.  The person's edits are what differs from what the
;;   file said last (`:file-base'), so a file the harness has yet to
;;   write again is no edit.  Taken are the prompt, the request, the
;;   title (the session's name), the model and thinking of a task that
;;   has not started, and `state: done' (completing it, or verifying a
;;   task in review).  The other known fields, and the review and plan
;;   sections, are the harness's: a file that contradicts them is written
;;   again.  Keys the harness does not know are kept as written.
;; - A file no task has becomes one: a backlog task, which only the user
;;   starts, or one in review or done, with its rounds of feedback.  With
;;   its session still there it is the task it was before the store lost
;;   it, except that it waits for the user if it was at work.  It stays
;;   as written until the task changes.
;; - A file deleted by hand, or moved out of the folder (into the archive
;;   subfolder, say), archives its task when the task waits (in pending
;;   or review) or is done; one in progress gets its file back.  A file
;;   that comes back brings its archived task back.

;;;;; A YAML subset
;;
;; Frontmatter needs one level of `key: value' entries whose values are
;; scalars -- plain, quoted, or | and > blocks -- or lists of scalars,
;; [a, b] or `- a' lines.  Emacs has no YAML parser, and that is all the
;; task files use.  Each entry keeps its lines as written too, so keys
;; the harness does not know (or values this does not read) survive a
;; rewrite unchanged.

(defconst harness-tasks--yaml-entry-re
  "\\`\\([A-Za-z0-9_][A-Za-z0-9_.-]*\\)[ \t]*:\\(?:[ \t]+\\(.*\\)\\)?[ \t]*\\'"
  "A top-level `key: value' line: group 1 is the key, 2 the value text.")

(defun harness-tasks--yaml-special-p (s)
  "Non-nil when S written plain would read back as something else than S.
That is a boolean, null or number, in YAML 1.1 or 1.2."
  (let ((case-fold-search t))
    (string-match-p
     (concat "\\`\\(?:~\\|null\\|true\\|false\\|yes\\|no\\|on\\|off\\|y\\|n"
             "\\|[-+]?\\(?:[0-9][0-9_]*\\(?:\\.[0-9_]*\\)?\\|\\.[0-9_]+\\)\\(?:e[-+]?[0-9]+\\)?"
             "\\|0x[0-9a-f]+\\|0o[0-7]+\\|[-+]?\\.inf\\|\\.nan\\|[0-9][0-9:]*:[0-9:.]*\\)\\'")
     s)))

(defun harness-tasks--yaml-plain-p (s)
  "Non-nil when the string S can be written as a plain YAML scalar."
  (and (not (string-empty-p s))
       (not (harness-tasks--yaml-special-p s))
       (not (string-match-p (rx (or (seq bos (any "] \t!\"#%&'*,:>?@[`{|}-"))
                                    (seq (any " \t") eos)
                                    (any (0 . 31) 127)
                                    ": " " #" (seq ":" eos)))
                            s))))

(defun harness-tasks--yaml-quote (s)
  "Return the string S as a double-quoted YAML scalar."
  (concat "\""
          (replace-regexp-in-string
           (rx (any ?\" ?\\ (0 . 31) 127))
           (lambda (c)
             (pcase (aref c 0)
               (?\" "\\\"") (?\\ "\\\\") (?\n "\\n") (?\t "\\t") (?\r "\\r")
               (ch (format "\\x%02x" ch))))
           s t t)
          "\""))

(defun harness-tasks--yaml-scalar (value &optional flow)
  "Return VALUE written as a YAML scalar, or a [list] when it is a vector.
Strings are plain when they read back the same, else double-quoted;
FLOW non-nil quotes the ones that would break a [list] too.  t and
`:false' are true and false, nil null, symbols their names."
  (cond ((eq value t) "true")
        ((eq value :false) "false")
        ((null value) "null")
        ((numberp value) (number-to-string value))
        ((vectorp value)
         (concat "[" (mapconcat (lambda (v) (harness-tasks--yaml-scalar v t)) value ", ") "]"))
        ((symbolp value) (harness-tasks--yaml-scalar (symbol-name value) flow))
        (t (let ((s (format "%s" value)))
             (if (and (harness-tasks--yaml-plain-p s)
                      (not (and flow (string-match-p "[],[{}]" s))))
                 s
               (harness-tasks--yaml-quote s))))))

(defun harness-tasks--yaml-plain (s)
  "Return the value of the plain YAML scalar S: a boolean, null, number or S."
  (let ((case-fold-search t))
    (cond ((string-match-p "\\`\\(?:~\\|null\\)?\\'" s) nil)
          ((string-match-p "\\`\\(?:true\\|yes\\|on\\)\\'" s) t)
          ((string-match-p "\\`\\(?:false\\|no\\|off\\)\\'" s) :false)
          ((string-match-p "\\`[-+]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)\\(?:e[-+]?[0-9]+\\)?\\'" s)
           (string-to-number s))
          (t s))))

(defun harness-tasks--yaml-uncomment (s)
  "Return the plain scalar text S without a trailing comment."
  (if (string-match "\\(?:\\`\\|[ \t]\\)#" s) (substring s 0 (match-beginning 0)) s))

(defun harness-tasks--yaml-quoted (text)
  "Read the quoted scalar TEXT opens with, its quote \" or \\='.
Return (STRING . REST), REST being the text after the closing quote, or
nil when the quote never closes.  Line breaks inside fold as YAML folds
them: one becomes a space, each empty line a newline."
  (let ((quote (aref text 0)) (n (length text)) (i 1) (out nil) (done nil))
    (while (and (not done) (< i n))
      (let ((c (aref text i)))
        (cond
         ((eq c quote)
          (if (and (eq quote ?') (< (1+ i) n) (eq (aref text (1+ i)) ?'))
              (progn (push ?' out) (cl-incf i))
            (setq done t)))
         ((and (eq c ?\\) (eq quote ?\"))
          (cl-incf i)
          (let ((e (and (< i n) (aref text i))))
            (pcase e
              (?n (push ?\n out)) (?t (push ?\t out)) (?\t (push ?\t out)) (?r (push ?\r out))
              (?0 (push 0 out)) (?a (push 7 out)) (?b (push 8 out)) (?e (push 27 out))
              (?f (push 12 out)) (?v (push 11 out)) (?\s (push ?\s out)) (?/ (push ?/ out))
              (?\" (push ?\" out)) (?\\ (push ?\\ out))
              (?N (push #x85 out)) (?_ (push #xa0 out)) (?L (push #x2028 out)) (?P (push #x2029 out))
              ((or ?x ?u ?U)
               (let* ((len (pcase e (?x 2) (?u 4) (_ 8)))
                      (hex (and (<= (+ i 1 len) n) (substring text (1+ i) (+ i 1 len))))
                      (code (and hex (string-match-p "\\`[0-9a-fA-F]+\\'" hex) (string-to-number hex 16))))
                 (if (and code (<= code (max-char)))
                     (progn (push code out) (cl-incf i len))
                   (push ?\\ out) (push e out))))
              (?\n ; an escaped line break joins the lines
               (while (and (< (1+ i) n) (memq (aref text (1+ i)) '(?\s ?\t))) (cl-incf i)))
              ('nil nil)
              (_ (push ?\\ out) (push e out)))))
         ((eq c ?\n)
          (while (memq (car out) '(?\s ?\t)) (pop out))
          (let ((breaks 0))
            (while (and (< (1+ i) n) (memq (aref text (1+ i)) '(?\s ?\t ?\n)))
              (cl-incf i)
              (when (eq (aref text i) ?\n) (cl-incf breaks)))
            (if (> breaks 0) (dotimes (_ breaks) (push ?\n out)) (push ?\s out))))
         (t (push c out))))
      (cl-incf i))
    (and done (cons (apply #'string (nreverse out)) (substring text i)))))

(defun harness-tasks--yaml-flow (text)
  "Read the [list] of scalars TEXT opens with.
Return (VECTOR . REST), or nil when it is no such list."
  (let ((rest (substring text 1)) (items nil) (done nil) (bad nil))
    (while (not (or done bad))
      (setq rest (string-trim-left rest "[ \t\n,]+"))
      (cond
       ((string-empty-p rest) (setq bad t))
       ((eq (aref rest 0) ?\]) (setq done t rest (substring rest 1)))
       ((memq (aref rest 0) '(?\" ?'))
        (let ((r (harness-tasks--yaml-quoted rest)))
          (if r (progn (push (car r) items) (setq rest (cdr r))) (setq bad t))))
       ((memq (aref rest 0) '(?\[ ?\{)) (setq bad t))
       (t (let ((end (or (string-match "[],\n]" rest) (length rest))))
            (push (harness-tasks--yaml-plain (string-trim (substring rest 0 end))) items)
            (setq rest (substring rest end))))))
    (and done (cons (vconcat (nreverse items)) rest))))

(defun harness-tasks--yaml-item (text)
  "Return the value of the scalar TEXT, a list item."
  (let ((text (string-trim text)))
    (cond ((string-match-p "\\`[\"']" text) (car (harness-tasks--yaml-quoted text)))
          ((string-prefix-p "[" text) (car (harness-tasks--yaml-flow text)))
          (t (harness-tasks--yaml-plain (string-trim (harness-tasks--yaml-uncomment text)))))))

(defun harness-tasks--yaml-block (header lines)
  "Return the block scalar of LINES, whose HEADER is | or > with its indicators."
  (let* ((header (string-trim (harness-tasks--yaml-uncomment header)))
         (folded (eq (aref header 0) ?>))
         (chomp (cond ((string-search "-" header) 'strip) ((string-search "+" header) 'keep) (t 'clip)))
         (indent (or (and (string-match "[1-9]" header) (string-to-number (match-string 0 header)))
                     (cl-loop for l in lines unless (string-blank-p l) return (string-match "[^ ]" l))
                     0))
         (body (mapcar (lambda (l) (if (string-blank-p l) "" (substring l (min indent (string-match "[^ ]" l)))))
                       lines))
         (text (if folded
                   (mapconcat (lambda (para) (string-join para " "))
                              (let (paras para)
                                (dolist (l body (nreverse (if para (cons (nreverse para) paras) paras)))
                                  (if (string-empty-p l)
                                      (progn (when para (push (nreverse para) paras)) (setq para nil))
                                    (push l para))))
                              "\n")
                 (string-join body "\n")))
         (text (string-trim-right text "\n+")))
    (if (or (eq chomp 'strip) (string-empty-p text)) text (concat text "\n"))))

(defun harness-tasks--yaml-nested (lines)
  "Return the value an entry gives on the indented LINES under it.
That is a `- item' list or a plain scalar over several lines; a nested
mapping is beyond this subset and gives nil."
  (let ((first (cl-find-if-not #'string-blank-p lines)))
    (cond
     ((null first) nil)
     ((string-match-p "\\`[ \t]*-\\(?:[ \t]\\|\\'\\)" first)
      (vconcat (delq 'harness-tasks--none
                     (mapcar (lambda (l)
                               (if (string-match "\\`[ \t]*-\\(?:[ \t]+\\(.*\\)\\)?\\'" l)
                                   (harness-tasks--yaml-item (or (match-string 1 l) ""))
                                 'harness-tasks--none))
                             lines))))
     ((string-match-p "\\`[ \t]*[^ \t#\"'][^:]*:\\(?:[ \t]\\|\\'\\)" first) nil)
     (t (harness-tasks--yaml-plain
         (string-join (delete "" (mapcar (lambda (l) (string-trim (harness-tasks--yaml-uncomment l))) lines))
                      " "))))))

(defun harness-tasks--yaml-value (value more)
  "Return the value of an entry: VALUE, the text after its colon, then lines MORE."
  (let ((v (string-trim value)))
    (condition-case nil
        (cond
         ((string-match-p "\\`[|>]" v) (harness-tasks--yaml-block v more))
         ((string-match-p "\\`[\"']" v) (car (harness-tasks--yaml-quoted (string-join (cons v more) "\n"))))
         ((string-prefix-p "[" v) (car (harness-tasks--yaml-flow (string-join (cons v more) "\n"))))
         ((string-match-p "\\`[{&*!]" v) nil)
         ((string-empty-p (string-trim (harness-tasks--yaml-uncomment v))) (harness-tasks--yaml-nested more))
         (t (harness-tasks--yaml-plain
             (string-join (delete "" (mapcar (lambda (l) (string-trim (harness-tasks--yaml-uncomment l)))
                                             (cons v more)))
                          " "))))
      (error nil))))

(defun harness-tasks--yaml-parse (text)
  "Parse TEXT, YAML frontmatter, into a list of entries (KEY VALUE RAW).
KEY is the key string; VALUE its value: a string, number, t, `:false',
nil (null) or a vector (a list); RAW the entry's lines as written.
Values beyond this subset (nested mappings, anchors, tags) are nil, and
a line that is no entry is one with KEY nil.  Comment lines are dropped."
  (let ((lines (split-string text "\n")) entries)
    (while lines
      (let ((line (pop lines)))
        (cond
         ((string-match-p "\\`[ \t]*\\(?:#.*\\)?\\'" line) nil)
         ((string-match harness-tasks--yaml-entry-re line)
          (let ((key (match-string 1 line))
                (value (or (match-string 2 line) ""))
                (more nil))
            ;; Its value goes on over indented lines, empty ones and `- item' lines.
            (while (and lines (string-match-p "\\`\\(?:[ \t]\\|-\\(?:[ \t]\\|\\'\\)\\|\\'\\)" (car lines)))
              (push (pop lines) more))
            ;; Empty lines at its end are no part of it.
            (while (and more (string-blank-p (car more)))
              (push (pop more) lines))
            (setq more (nreverse more))
            (push (list key (harness-tasks--yaml-value value more) (string-join (cons line more) "\n"))
                  entries)))
         (t (push (list nil nil line) entries)))))
    (nreverse entries)))

;;;;; The file format

(defconst harness-tasks--file-keys
  '("id" "title" "state" "column" "backlog" "outcome" "error" "session" "branch" "base"
    "merge" "model" "thinking" "created" "started" "refined" "finished" "verified" "updated")
  "Frontmatter keys of a task file, in the order the harness writes them.
Other keys are kept as written.")

(defconst harness-tasks--file-time-keys '("created" "started" "refined" "finished" "verified" "updated")
  "Frontmatter keys whose values are times, ISO 8601 in UTC.")

(defconst harness-tasks--section-re "\\`<!-- harness:\\([a-z-]+\\) -->[ \t]*\\'"
  "A line opening a section of a task file the harness keeps (request, plan).")

(defconst harness-tasks--file-max-size (* 1024 1024) "Larger files are no task files.")

(defun harness-tasks--hash (text)
  "Return a hash of the string TEXT."
  (secure-hash 'sha1 (encode-coding-string text 'utf-8-unix t)))

(defun harness-tasks--time-text (time)
  "Return TIME, a float, as a frontmatter time, or nil."
  (and (numberp time) (harness-iso-time time)))

(defun harness-tasks--parse-time (value)
  "Return the frontmatter time VALUE as a float, or nil.
It may be ISO 8601 (UTC unless it names a zone), a date (UTC midnight)
or seconds since the epoch."
  (cond ((numberp value) (float value))
        ((stringp value)
         (let ((s (string-trim value)))
           (ignore-errors
             (if (string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\'" s)
                 (float-time (encode-time (list 0 0 0 (string-to-number (match-string 3 s))
                                                (string-to-number (match-string 2 s))
                                                (string-to-number (match-string 1 s))
                                                nil nil t)))
               (let ((time (parse-iso8601-time-string s)))
                 (and time (float-time time)))))))))

(defun harness-tasks--canon (key value)
  "Return the frontmatter VALUE of KEY as the harness writes it, nil for none.
Times are in UTC to the second, booleans true (false is none), symbols
and numbers their names; strings are trimmed."
  (cond ((or (null value) (eq value :false)) nil)
        ((member key harness-tasks--file-time-keys)
         (let ((time (harness-tasks--parse-time value)))
           (if time (harness-iso-time time) (format "%s" value))))
        ((eq value t) "true")
        ((stringp value) (let ((s (string-trim value))) (and (not (string-empty-p s)) s)))
        ((symbolp value) (symbol-name value))
        ((numberp value) (number-to-string value))
        (t (format "%s" value))))

(defun harness-tasks--title (task &optional session)
  "Return TASK's title on the board.
That is its SESSION's name, else its prompt's first line."
  (let ((name (plist-get session :name)))
    (if (harness-string-blank-p name)
        (let ((line (harness-first-line (plist-get task :prompt))))
          (if (string-match "\\`#+[ \t]+" line) (substring line (match-end 0)) line))
      (string-trim name))))

(defun harness-tasks--note-shown-p (task)
  "Non-nil when TASK's file shows the request it was written up from.
It does once a write-up replaced it."
  (let ((note (plist-get task :note)))
    (and (stringp note) (not (string-blank-p note))
         (not (equal (string-trim note) (string-trim (or (plist-get task :prompt) "")))))))

(defun harness-tasks--file-fields (task session &optional sans-updated)
  "Return the frontmatter of TASK's file: (KEY . VALUE) pairs, in order.
SESSION is TASK's session or nil.  Fields without a value are left out,
and so is `updated' with SANS-UPDATED."
  (let ((err (plist-get task :error)))
    (cl-remove-if
     (lambda (field) (null (cdr field)))
     (list (cons "id" (plist-get task :id))
           (cons "title" (harness-tasks--title task session))
           (cons "state" (plist-get task :state))
           (cons "column" (harness-tasks--column task))
           (cons "backlog" (and (harness-tasks--backlog-p task) t))
           (cons "outcome" (plist-get task :outcome))
           (cons "error" (and (stringp err) (not (string-blank-p err))
                              (harness-truncate-end (string-trim err) 300)))
           (cons "session" (plist-get task :session))
           (cons "branch" (plist-get task :branch))
           (cons "base" (plist-get task :base))
           (cons "merge" (or (plist-get task :merge-status)
                             (and (harness-json-true-p (plist-get task :merged)) 'merged)))
           (cons "model" (plist-get task :model))
           (cons "thinking" (plist-get task :thinking))
           (cons "created" (harness-tasks--time-text (plist-get task :created)))
           (cons "started" (harness-tasks--time-text (plist-get task :started)))
           (cons "refined" (harness-tasks--time-text (plist-get task :refined)))
           (cons "finished" (harness-tasks--time-text (plist-get task :finished)))
           (cons "verified" (and (harness-tasks--verified-p task)
                                 (harness-tasks--time-text (plist-get task :verified-at))))
           (cons "updated" (and (not sans-updated) (harness-tasks--time-text (plist-get task :updated))))))))

(defun harness-tasks--title-line-p (line)
  "Non-nil when LINE, a prompt's first line, reads well as its heading.
Lines that are markdown of their own (headings, lists, quotes, code,
tables) or long stay as they are."
  (and (not (string-blank-p line))
       (<= (length line) 120)
       (not (string-match-p
             (concat "\\`\\(?:[ \t]\\|#\\|>\\||\\|<\\|```\\|~~~\\|[-*+][ \t]\\|[0-9]+[.)][ \t]"
                     "\\|[-*_=+]+[ \t]*\\'\\)\\|[ \t]#+[ \t]*\\'")
             line))))

(defun harness-tasks--render-description (prompt)
  "Return PROMPT as a task file shows it.
Its first line is a heading when it reads as a title."
  (let* ((nl (string-search "\n" prompt))
         (first (if nl (substring prompt 0 nl) prompt)))
    (if (harness-tasks--title-line-p first)
        (concat "# " (string-trim-right first) (if nl (substring prompt nl) ""))
      prompt)))

(defconst harness-tasks--feedback-heading-re
  "\\`###[ \t]+Sent back\\(?:[ \t]+\\(.*?\\)\\)?[ \t]*\\'"
  "A heading in a task file's review section: one round of feedback follows.
Group 1 is the time the task was sent back.")

(defun harness-tasks--feedback-text (task)
  "Return TASK's rounds of feedback as its file's review section has them.
That is a `### Sent back TIME' heading over each, quoted; nil for none."
  (when-let* ((feedback (plist-get task :feedback)))
    (mapconcat (lambda (round)
                 (concat "### Sent back"
                         (if-let* ((time (harness-tasks--time-text (plist-get round :at)))) (concat " " time) "")
                         "\n\n" (harness-tasks--quote (or (plist-get round :text) ""))))
               feedback "\n\n")))

(defun harness-tasks--parse-feedback (text)
  "Return the rounds of feedback in TEXT, a task file's review section.
Each is (:text TEXT :at TIME), oldest first; text before the first
heading, and a heading over nothing, are no round."
  (let (rounds current)
    (dolist (line (split-string (or text "") "\n"))
      (if (string-match harness-tasks--feedback-heading-re line)
          (progn (when current (push current rounds))
                 (setq current (list (harness-tasks--parse-time (match-string 1 line)))))
        (when current (setcdr current (cons line (cdr current))))))
    (when current (push current rounds))
    (delq nil (mapcar (lambda (round)
                        (let ((text (harness-tasks--unquote (string-join (reverse (cdr round)) "\n"))))
                          (and (not (string-empty-p text)) (list :text text :at (car round)))))
                      (nreverse rounds)))))

(defun harness-tasks--render (task &optional sans-updated)
  "Return the text of TASK's file; without its `updated' field with SANS-UPDATED."
  (let* ((session (harness-tasks--session task))
         (plan (plist-get session :plan))
         (feedback (harness-tasks--feedback-text task)))
    (concat "---\n"
            (mapconcat (lambda (field) (format "%s: %s\n" (car field) (harness-tasks--yaml-scalar (cdr field))))
                       (harness-tasks--file-fields task session sans-updated) "")
            (mapconcat (lambda (raw) (concat raw "\n")) (plist-get task :extra) "")
            "---\n\n"
            (harness-tasks--render-description (or (plist-get task :prompt) ""))
            (if (harness-tasks--note-shown-p task)
                (concat "\n\n<!-- harness:request -->\n## Request\n\n"
                        (harness-tasks--quote (plist-get task :note)))
              "")
            (if feedback (concat "\n\n<!-- harness:review -->\n## Review\n\n" feedback) "")
            (if (and (stringp plan) (not (string-blank-p plan)))
                (concat "\n\n<!-- harness:plan -->\n## Plan\n\n" (string-trim plan))
              "")
            "\n")))

(defun harness-tasks--split-frontmatter (text)
  "Split TEXT into (YAML . BODY).
YAML is nil when TEXT opens with no frontmatter, and `unterminated' when
its opening --- line has no closing one."
  (let ((text (string-remove-prefix "\ufeff" text)))
    (if (not (string-match "\\`---[ \t]*\\(?:\n\\|\\'\\)" text))
        (cons nil text)
      (let ((start (match-end 0)))
        (if (string-match "^\\(?:---\\|\\.\\.\\.\\)[ \t]*\\(?:\n\\|\\'\\)" text start)
            (cons (substring text start (match-beginning 0)) (substring text (match-end 0)))
          (cons 'unterminated text))))))

(defun harness-tasks--section-text (lines)
  "Return the text of a section's LINES, without the heading under its marker."
  (let ((lines (cl-member-if-not #'string-blank-p lines)))
    (when (and lines (string-match-p "\\`##[ \t]" (car lines)))
      (setq lines (cdr lines)))
    (string-trim (string-join lines "\n"))))

(defun harness-tasks--split-body (body)
  "Split a task file's BODY into (DESCRIPTION . SECTIONS).
SECTIONS maps the names of the sections the harness keeps to their text.
Markers inside code fences do not count."
  (let (fence current desc sections acc)
    (dolist (line (split-string body "\n"))
      (if (and (not fence) (string-match harness-tasks--section-re line))
          (progn (if current (push (cons current (nreverse acc)) sections) (setq desc (nreverse acc)))
                 (setq current (match-string 1 line) acc nil))
        (when (string-match "\\`[ ]\\{0,3\\}\\(```+\\|~~~+\\)" line)
          (let ((mark (match-string 1 line)))
            (cond ((null fence) (setq fence mark))
                  ((and (eq (aref mark 0) (aref fence 0)) (>= (length mark) (length fence)))
                   (setq fence nil)))))
        (push line acc)))
    (if current (push (cons current (nreverse acc)) sections) (setq desc (nreverse acc)))
    (cons (string-join desc "\n")
          (mapcar (lambda (s) (cons (car s) (harness-tasks--section-text (cdr s)))) (nreverse sections)))))

(defun harness-tasks--description-prompt (desc)
  "Return (PROMPT . HEADING) for DESC, the text a task file opens its body with.
A title heading at its top -- `# Title', or Title underlined with === --
is the prompt's first line, as plain text; HEADING is non-nil then."
  (let* ((desc (string-trim desc))
         (nl (string-search "\n" desc))
         (first (if nl (substring desc 0 nl) desc))
         (rest (if nl (substring desc nl) "")))
    (cond
     ((string-match "\\`#[ \t]+\\(.*?\\)\\(?:[ \t]+#+\\)?[ \t]*\\'" first)
      (cons (string-trim (concat (match-string 1 first) rest)) t))
     ((string-match "\\`\n=+[ \t]*\\(?:\n\\|\\'\\)" rest)
      (cons (string-trim (concat first "\n" (substring rest (match-end 0)))) t))
     (t (cons desc nil)))))

(defun harness-tasks--unquote (text)
  "Return the markdown quote TEXT without its > markers."
  (string-trim
   (mapconcat (lambda (line) (if (string-match "\\`[ \t]\\{0,3\\}> ?" line) (substring line (match-end 0)) line))
              (split-string text "\n") "\n")))

(defun harness-tasks--parse-file (text)
  "Parse the task file TEXT into a plist.
`:fields' maps the known frontmatter keys present (lowercase) to their
values, the file's last of each; `:extra' lists the raw entries of the
other keys; `:prompt' is the description with its title heading made
plain, `:heading' non-nil when it had one; `:note', `:review' and
`:plan' are the request, review and plan sections, nil when absent.  A
file whose frontmatter never ends is just (:unterminated t)."
  (let* ((split (harness-tasks--split-frontmatter text))
         (yaml (car split)))
    (if (eq yaml 'unterminated)
        (list :unterminated t)
      (let* ((parts (harness-tasks--split-body (cdr split)))
             (desc (harness-tasks--description-prompt (car parts)))
             (request (assoc "request" (cdr parts)))
             fields extra)
        (dolist (entry (reverse (and yaml (harness-tasks--yaml-parse yaml))))
          (let ((key (and (car entry) (downcase (car entry)))))
            (if (member key harness-tasks--file-keys)
                (unless (assoc key fields) (push (cons key (nth 1 entry)) fields))
              (push (nth 2 entry) extra))))
        (list :fields fields :extra extra
              :prompt (car desc) :heading (cdr desc)
              :note (and request (harness-tasks--unquote (cdr request)))
              :review (cdr (assoc "review" (cdr parts)))
              :plan (cdr (assoc "plan" (cdr parts))))))))

(defun harness-tasks--field (parsed key)
  "Return the value of frontmatter KEY in the PARSED file as the harness writes it."
  (harness-tasks--canon key (cdr (assoc key (plist-get parsed :fields)))))

(defun harness-tasks--file-prompt (parsed &optional own)
  "Return the prompt the PARSED task file holds.
A file the harness did not write (OWN nil) may give the task's title
only in its frontmatter: that title is then the prompt's first line."
  (let ((prompt (plist-get parsed :prompt))
        (title (harness-tasks--field parsed "title")))
    (cond ((or own (plist-get parsed :heading) (null title)) prompt)
          ((string-blank-p prompt) title)
          ((equal title (harness-first-line prompt)) prompt)
          (t (concat title "\n\n" prompt)))))

(defun harness-tasks--file-base (own title state model thinking prompt note)
  "Return what a task file says of the fields people edit, to tell edits apart.
OWN is non-nil when the harness wrote the file; TITLE, STATE, MODEL and
THINKING are canonical frontmatter values; PROMPT and NOTE are hashed."
  (list :own own :title title :state state :model model :thinking thinking
        :prompt (and prompt (harness-tasks--hash prompt)) :note (and note (harness-tasks--hash note))))

(defun harness-tasks--written-base (task session)
  "Return the base of the file the harness writes for TASK.
SESSION is TASK's session."
  (harness-tasks--file-base t (harness-tasks--title task session)
                            (harness-tasks--canon "state" (plist-get task :state))
                            (harness-tasks--canon "model" (plist-get task :model))
                            (harness-tasks--canon "thinking" (plist-get task :thinking))
                            (plist-get task :prompt)
                            (and (harness-tasks--note-shown-p task) (string-trim (plist-get task :note)))))

(defun harness-tasks--read-base (parsed prompt own)
  "Return the base of the PARSED task file, whose prompt is PROMPT, OWN as it was."
  (harness-tasks--file-base own (harness-tasks--field parsed "title") (harness-tasks--field parsed "state")
                            (harness-tasks--field parsed "model") (harness-tasks--field parsed "thinking")
                            prompt (plist-get parsed :note)))

(defun harness-tasks--snapshot (task)
  "Return a hash of what TASK's file shows, the time it was written aside."
  (harness-tasks--hash (harness-tasks--render task t)))

(defun harness-tasks--file-agrees-p (task parsed prompt)
  "Non-nil when nothing in TASK's file contradicts TASK.
PARSED is the file, PROMPT the prompt it holds.  Fields and sections it
leaves out contradict nothing."
  (let* ((session (harness-tasks--session task))
         (mine (harness-tasks--file-fields task session t))
         (plan (plist-get session :plan))
         (note (plist-get parsed :note))
         (file-review (plist-get parsed :review))
         (file-plan (plist-get parsed :plan)))
    (and (equal prompt (plist-get task :prompt))
         (or (null note) (equal note (and (harness-tasks--note-shown-p task) (string-trim (plist-get task :note)))))
         (or (null file-review) (equal file-review (harness-tasks--feedback-text task)))
         (or (null file-plan) (equal file-plan (and (stringp plan) (string-trim plan))))
         (cl-every (lambda (field)
                     (or (equal (car field) "updated")
                         (equal (harness-tasks--canon (car field) (cdr field))
                                (harness-tasks--canon (car field) (cdr (assoc (car field) mine))))))
                   (plist-get parsed :fields)))))

;;;;; Folders

(defun harness-tasks--folder (root)
  "Return the folder of project ROOT's task files, or nil when it keeps none.
Only a git project whose tasks this harness keeps in its repository
store has one, `harness-tasks-directory' as configured for ROOT.  A
folder new to this process, or another than ROOT had, gets a save soon,
which writes (or moves) the files there."
  (let ((folder (when (and root harness-tasks-store-in-repository (harness-tasks--repository-store root))
                  (let ((dir (harness-tasks--config 'harness-tasks-directory root)))
                    (and (stringp dir) (not (string-blank-p dir)) (harness-tasks--open-project root)
                         (file-name-as-directory (expand-file-name dir root)))))))
    (cond ((null folder) (remhash root harness-tasks--file-roots))
          ((not (equal folder (gethash root harness-tasks--file-roots)))
           (puthash root folder harness-tasks--file-roots)
           (harness-tasks--save-soon)))
    folder))

(defun harness-tasks--in-folder-p (folder path)
  "Non-nil when PATH is a file right in FOLDER (a directory name)."
  (and folder path (equal (file-name-directory path) folder)))

(defun harness-tasks--archive-folder (folder)
  "Return the subfolder of the task FOLDER for archived tasks' files, or nil."
  (and (stringp harness-tasks-directory-archive)
       (not (string-blank-p harness-tasks-directory-archive))
       (file-name-as-directory (expand-file-name harness-tasks-directory-archive folder))))

(defun harness-tasks--stamp (path &optional attrs)
  "Remember the stamp of the task file PATH (its ATTRS when given)."
  (when-let* ((attrs (or attrs (file-attributes path))))
    (puthash path (list (file-attribute-modification-time attrs) (file-attribute-size attrs))
             harness-tasks--file-stamps)))

(defun harness-tasks--note-file (id &rest plist)
  "Record PLIST, the bookkeeping of task ID's file, without announcing it."
  (when-let* ((task (gethash id harness-tasks--table)))
    (puthash id (harness-plist-merge task plist) harness-tasks--table)
    (harness-tasks--save-soon)))

(defun harness-tasks--new-file (folder task)
  "Return the path of a new file for TASK in FOLDER.
Its name is TASK's id and a slug of its title."
  (let* ((words (split-string (downcase (harness-tasks--title task (harness-tasks--session task)))
                              "[^a-z0-9]+" t))
         (slug (string-trim-right (harness-safe-substring (string-join (take 6 words) "-") 0 48) "-+")))
    (expand-file-name (concat (plist-get task :id) (if (string-empty-p slug) "" (concat "-" slug)) ".md")
                      folder)))

(defun harness-tasks--file-owner (root folder rel parsed)
  "Return the task of project ROOT whose file REL, as PARSED, is; nil for none.
That is the task with that file, else the one its id names when that
task's own file is not in the task FOLDER (renamed, deleted, archived
or moved there from another folder): a copy of a task file still in
the folder is a new task."
  (or (cl-find-if (lambda (task) (and (equal (plist-get task :project) root) (equal (plist-get task :file) rel)))
                  (hash-table-values harness-tasks--table))
      (when-let* ((id (harness-tasks--field parsed "id"))
                  (task (gethash id harness-tasks--table)))
        (and (equal (plist-get task :project) root)
             (let* ((file (plist-get task :file))
                    (path (and file (expand-file-name file root))))
               (not (and path (harness-tasks--in-folder-p folder path) (file-exists-p path))))
             task))))

(defun harness-tasks--apply-file (task parsed rel)
  "Take the edits of TASK's file REL, as PARSED, into TASK.
Edits are what differs from what the file said before; see Task files
for those taken.  A file come back to the folder (from the archive
subfolder, say) brings its archived task back."
  (let* ((id (plist-get task :id))
         (base (plist-get task :file-base))
         (own (plist-get base :own))
         (prompt (string-trim (harness-tasks--file-prompt parsed own)))
         (note (plist-get parsed :note))
         (title (harness-tasks--field parsed "title"))
         (state (harness-tasks--field parsed "state"))
         (unstarted (and (memq (plist-get task :state) '(pending refining)) (not (harness-tasks--turn-p task))))
         (changes nil))
    (when (and (plist-get task :archived) (not (equal (plist-get task :file) rel)))
      (harness-log 'info "tasks: %s is back, so task %s is too" rel id)
      (setq changes (list :archived nil)))
    (when (and (not (string-empty-p prompt))
               (not (equal (harness-tasks--hash prompt) (plist-get base :prompt)))
               (not (equal prompt (plist-get task :prompt))))
      (setq changes (plist-put changes :prompt prompt)))
    (when (and note (not (equal (harness-tasks--hash note) (plist-get base :note)))
               (not (equal note (plist-get task :note))))
      (setq changes (plist-put changes :note (and (not (string-empty-p note)) note))))
    (unless (equal (plist-get parsed :extra) (plist-get task :extra))
      (setq changes (plist-put changes :extra (plist-get parsed :extra))))
    (dolist (key '("model" "thinking"))
      (when (assoc key (plist-get parsed :fields))
        (let ((value (harness-tasks--field parsed key))
              (prop (intern (concat ":" key))))
          (when (and unstarted (not (equal value (plist-get base prop))) (not (equal value (plist-get task prop))))
            (setq changes (plist-put changes prop value))))))
    (when changes (apply #'harness-tasks--set id changes))
    (let* ((task (harness-tasks--get id))
           (session (harness-tasks--session task)))
      (when (and title session (not (equal title (plist-get base :title)))
                 (not (equal title (harness-tasks--title task session))))
        (condition-case err
            (harness-call 'session/update (plist-get session :id) :name title :silent t)
          (error (harness-log 'warn "tasks: %s: cannot rename the session of task %s: %S" rel id err))))
      ;; Done by hand: the user accepts the work, so a task in review is verified.
      (when (and (equal state "done") (not (equal state (plist-get base :state)))
                 (not (eq (plist-get task :state) 'done)))
        (condition-case err
            (harness-call (if (eq (plist-get task :state) 'review) 'task/verify 'task/complete) id)
          (error (harness-log 'warn "tasks: %s: cannot complete task %s: %S" rel id err)))))
    (let ((task (harness-tasks--get id)))
      (harness-tasks--note-file id :file rel
                                :file-base (harness-tasks--read-base parsed prompt own)
                                :file-synced (and (harness-tasks--file-agrees-p task parsed prompt)
                                                  (harness-tasks--snapshot task))))))

(defun harness-tasks--file-session (parsed root)
  "Return the session the PARSED task file of project ROOT names, or nil.
It must still exist, work in ROOT's project and be no other task's."
  (when-let* ((sid (harness-tasks--field parsed "session"))
              ((harness-method-exists-p 'session/exists-p))
              ((harness-call 'session/exists-p sid))
              ((not (harness-tasks--by-session sid)))
              (session (harness-call 'session/get sid)))
    (and (equal (harness-tasks--project (plist-get session :cwd)) root) session)))

(defun harness-tasks--add-from-file (root rel parsed mtime)
  "Add the task the file REL of project ROOT holds, as PARSED; return it.
MTIME, when the file was last changed, is its creation time unless it
says.  It is a backlog task, one in review or a done one, with the
rounds of feedback and the verification the file shows.  With its
session still around it is the task it was, session and all, except
that nothing carries on by itself: one that was at work waits for the
user, `interrupted'.  Return nil for a file without a prompt."
  (let ((prompt (string-trim (harness-tasks--file-prompt parsed))))
    (unless (string-empty-p prompt)
      (let* ((id (let ((id (harness-tasks--field parsed "id")))
                   (if (and id (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_.-]\\{0,63\\}\\'" id)
                            (not (gethash id harness-tasks--table)))
                       id
                     (concat "t-" (harness-short-id 8)))))
             (session (harness-tasks--file-session parsed root))
             (written (intern (or (harness-tasks--field parsed "state") "pending")))
             (state (cond ((not (memq written '(pending refining active merging review done))) 'pending)
                          ;; Both wait for nothing but the user.
                          ((memq written '(review done)) written)
                          ((null session) 'pending)
                          ;; A merge starts again only when the user says so.
                          ((eq written 'merging) 'active)
                          (t written)))
             (outcome (let ((outcome (and session (harness-tasks--field parsed "outcome"))))
                        (cond (outcome (intern outcome))
                              ((and session (memq state '(refining active))) 'interrupted))))
             (worktree (plist-get session :worktree))
             (time (lambda (key) (harness-tasks--parse-time (cdr (assoc key (plist-get parsed :fields))))))
             (verified (funcall time "verified"))
             (task (list :id id :project root :cwd root :prompt prompt
                         :note (plist-get parsed :note) :extra (plist-get parsed :extra)
                         :state state
                         :backlog (and (memq state '(pending refining))
                                       (or (null session) (harness-tasks--field parsed "backlog"))
                                       t)
                         :session (plist-get session :id)
                         :outcome outcome
                         :error (and session (harness-tasks--field parsed "error"))
                         :worktree worktree
                         :worktree-removed (and worktree (not (file-directory-p worktree)) t)
                         :branch (harness-tasks--field parsed "branch")
                         :base (harness-tasks--field parsed "base")
                         :merged (and (equal (harness-tasks--field parsed "merge") "merged") t)
                         :model (harness-tasks--field parsed "model")
                         :thinking (harness-tasks--field parsed "thinking")
                         :created (or (funcall time "created") mtime (float-time))
                         :started (funcall time "started")
                         :refined (funcall time "refined")
                         :finished (funcall time "finished")
                         :verified (and verified t)
                         :verified-at verified
                         :feedback (harness-tasks--parse-feedback (plist-get parsed :review))
                         :updated (funcall time "updated"))))
        (puthash id task harness-tasks--table)
        (harness-tasks--note-file id :file rel
                                  :file-base (harness-tasks--read-base parsed prompt nil)
                                  :file-synced (and (harness-tasks--file-agrees-p task parsed prompt)
                                                    (harness-tasks--snapshot task)))
        (harness-log 'info "tasks: %s is new, now task %s" rel id)
        (unless harness-tasks--loading
          (harness-emit 'task/changed (harness-tasks--view (gethash id harness-tasks--table)))
          (harness-tasks--pick-up))
        (gethash id harness-tasks--table)))))

(defun harness-tasks--file-gone (task folder)
  "Follow TASK's file leaving the task FOLDER by hand, deleted or moved.
A task that waits or is done is archived, its file moved into the
archive subfolder remembered; one in progress gets its file back at the
next save."
  (let ((id (plist-get task :id)))
    (if (and (memq (plist-get task :state) '(pending review done))
             (not (harness-tasks--turn-p task))
             (not (gethash id harness-tasks--starting)))
        (let* ((session (harness-tasks--session task))
               (archive (harness-tasks--archive-folder folder))
               (moved (and archive (expand-file-name (file-name-nondirectory (plist-get task :file)) archive))))
          (harness-log 'info "tasks: %s is gone from the task folder, so task %s is archived" (plist-get task :file) id)
          (harness-tasks--note-file id :file (and moved (file-exists-p moved)
                                                  (file-relative-name moved (plist-get task :project)))
                                    :file-base nil :file-synced nil)
          (harness-tasks--set id :archived t)
          (when (and session (not (eq (plist-get session :status) 'inactive)))
            (ignore-errors (harness-call 'session/deactivate (plist-get session :id)))))
      (harness-tasks--note-file id :file-synced nil))))

(defun harness-tasks--read-file (root folder path attrs)
  "Read the task file PATH in FOLDER of project ROOT, whose attributes are ATTRS."
  (let ((rel (file-relative-name path root)))
    (if (> (file-attribute-size attrs) harness-tasks--file-max-size)
        (harness-log 'warn "tasks: %s is too large for a task file" rel)
      (when-let* ((text (harness-read-file path)))
        (let ((parsed (harness-tasks--parse-file text)))
          (if (plist-get parsed :unterminated)
              (harness-log 'warn "tasks: %s opens frontmatter with --- but never closes it" rel)
            (if-let* ((task (harness-tasks--file-owner root folder rel parsed)))
                (harness-tasks--apply-file task parsed rel)
              (harness-tasks--add-from-file root rel parsed
                                            (float-time (file-attribute-modification-time attrs))))))))))

(defun harness-tasks--scan (root &optional folder)
  "Read the task files of project ROOT that changed since this process saw them.
FOLDER is ROOT's task folder when known.  Edits are taken, new files
become tasks and deleted files are followed (see Task files)."
  (when-let* ((folder (or folder (harness-tasks--folder root))))
    (let ((present (make-hash-table :test 'equal)))
      (when (file-directory-p folder)
        (dolist (entry (sort (directory-files-and-attributes folder t "\\.md\\'" t)
                             (lambda (a b) (string< (car a) (car b)))))
          (let ((path (car entry)) (attrs (cdr entry)))
            (unless (or (eq t (file-attribute-type attrs))
                        (let ((case-fold-search t))
                          (string-match-p harness-tasks-directory-ignore (file-name-nondirectory path))))
              (puthash path t present)
              (unless (equal (list (file-attribute-modification-time attrs) (file-attribute-size attrs))
                             (gethash path harness-tasks--file-stamps))
                (harness-tasks--stamp path attrs)
                (condition-case err
                    (harness-tasks--read-file root folder path attrs)
                  (error (harness-log 'error "tasks: cannot read %s: %S" path err))))))))
      (dolist (task (harness-tasks--sorted (lambda (task) (and (equal (plist-get task :project) root)
                                                                (plist-get task :file)
                                                                (not (plist-get task :archived))))))
        (let ((path (expand-file-name (plist-get task :file) root)))
          (when (and (harness-tasks--in-folder-p folder path) (not (gethash path present)))
            (remhash path harness-tasks--file-stamps)
            (harness-tasks--file-gone task folder)))))))

(defun harness-tasks--scan-roots (roots)
  "Read what changed in the task folders of the projects ROOTS."
  (dolist (root roots)
    (condition-case err
        (harness-tasks--scan root)
      (error (harness-log 'error "tasks: cannot read the task files of %s: %S" root err)))))

(defun harness-tasks--poll ()
  "Read what changed in the task folders.
It runs every `harness-tasks-directory-poll' seconds."
  (when (and harness-tasks--loaded harness-tasks-directory-poll)
    (harness-tasks--scan-roots (hash-table-keys harness-tasks--file-roots))))

(defun harness-tasks--start-polling ()
  "Start reading the task folders every `harness-tasks-directory-poll' seconds."
  (when (timerp harness-tasks--poll-timer) (cancel-timer harness-tasks--poll-timer))
  (setq harness-tasks--poll-timer
        (and (numberp harness-tasks-directory-poll) (> harness-tasks-directory-poll 0)
             (run-with-timer harness-tasks-directory-poll harness-tasks-directory-poll #'harness-tasks--poll))))

(defun harness-tasks--archive-file (task folder path)
  "Take the file PATH of archived TASK out of the task FOLDER.
It moves into the archive subfolder, or with none it is deleted."
  (let ((id (plist-get task :id))
        (root (plist-get task :project))
        (archive (harness-tasks--archive-folder folder)))
    (remhash path harness-tasks--file-stamps)
    (if (not archive)
        (progn (when (file-exists-p path) (delete-file path))
               (harness-log 'info "tasks: deleted %s of archived task %s" (file-relative-name path root) id)
               (harness-tasks--note-file id :file nil :file-base nil :file-synced nil))
      (let ((to (expand-file-name (file-name-nondirectory path) archive)))
        (when (file-exists-p path)
          (harness-ensure-directory archive)
          (rename-file path to t)
          (harness-log 'info "tasks: moved %s of archived task %s to %s"
                       (file-relative-name path root) id (file-relative-name to root)))
        (harness-tasks--note-file id :file (and (file-exists-p to) (file-relative-name to root))
                                  :file-base nil :file-synced nil)))))

(defun harness-tasks--sync-file (task folder)
  "Bring TASK's file in FOLDER in step with TASK.
It is written when TASK changed since the file was last in step, or
when the file is elsewhere: a file in the archive subfolder (TASK
restored) or in the folder the project had before moves back.  An
archived task's file moves out (`harness-tasks-directory-archive')."
  (let* ((id (plist-get task :id))
         (root (plist-get task :project))
         (file (plist-get task :file))
         (path (and file (expand-file-name file root)))
         (inside (harness-tasks--in-folder-p folder path)))
    (if (plist-get task :archived)
        (when inside (harness-tasks--archive-file task folder path))
      (let ((synced (harness-tasks--snapshot task)))
        (unless (and inside (equal synced (plist-get task :file-synced)))
          (let* ((back (and path (expand-file-name (file-name-nondirectory path) folder)))
                 (new (cond (inside path)
                            ((and back (file-exists-p path) (not (file-exists-p back))) back)
                            (t (harness-tasks--new-file folder task))))
                 (task (plist-put (copy-sequence task) :updated (float-time))))
            (harness-write-file-atomically new (harness-tasks--render task))
            (harness-tasks--stamp new)
            (harness-tasks--note-file id :file (file-relative-name new root) :updated (plist-get task :updated)
                                      :file-base (harness-tasks--written-base task (harness-tasks--session task))
                                      :file-synced synced)
            (when (and path (not inside) (file-exists-p path))
              (harness-log 'info "tasks: moved %s of task %s to %s" file id (file-relative-name new root))
              (remhash path harness-tasks--file-stamps)
              (delete-file path))))))))

(defun harness-tasks--save-files ()
  "Write the task files of the projects that keep them.
Their folders are read first, so no edit is written over."
  (let ((roots (make-hash-table :test 'equal)))
    (maphash (lambda (_ task) (puthash (plist-get task :project) t roots)) harness-tasks--table)
    (maphash (lambda (root _) (puthash root t roots)) harness-tasks--file-roots)
    (maphash
     (lambda (root _)
       (condition-case err
           (when-let* ((folder (harness-tasks--folder root)))
             (harness-tasks--scan root folder)
             (dolist (task (harness-tasks--sorted (lambda (task) (equal (plist-get task :project) root))))
               (condition-case err
                   (harness-tasks--sync-file task folder)
                 (error (harness-log 'error "tasks: cannot write the file of task %s: %S"
                                     (plist-get task :id) err)))))
         (error (harness-log 'error "tasks: cannot keep the task files of %s: %S" root err))))
     roots)))

(defun harness-tasks--delete-file (task)
  "Delete the file of TASK, which is going away, in the task folder or its archive."
  (when-let* ((file (plist-get task :file))
              (root (plist-get task :project))
              (path (expand-file-name file root))
              (folder (ignore-errors (harness-tasks--folder root)))
              ((or (harness-tasks--in-folder-p folder path)
                   (harness-tasks--in-folder-p (harness-tasks--archive-folder folder) path))))
    (remhash path harness-tasks--file-stamps)
    (condition-case err
        (when (file-exists-p path) (delete-file path))
      (error (harness-log 'warn "tasks: cannot delete %s: %S" path err)))))

;;;; Columns

(defun harness-tasks--column (task)
  "Return the kanban column of TASK, a symbol.
That is pending, needs-input, review, merging, active or done.
A task being refined shows in pending, where it ends up, unless the
refinement needs the user.  A task whose branch holds a place in the
merge queue shows in merging however it holds it: queued, merging, or
its session resolving the conflicts; unless that session waits on the
user, whose answer the queue then waits for too."
  (pcase (plist-get task :state)
    ('pending 'pending)
    ('done 'done)
    ('review 'review)
    ('refining (let ((session (harness-tasks--session task)))
                 (cond ((plist-get session :pending) 'needs-input)
                       ((harness-tasks--turn-p task) 'pending)
                       ((plist-get task :outcome) 'needs-input)
                       (t 'pending))))
    (_ (let ((session (harness-tasks--session task)))
         (cond ((gethash (plist-get task :id) harness-tasks--starting) 'active)
               ((plist-get session :pending) 'needs-input)
               ((plist-get task :merge-status) 'merging)
               ((eq (plist-get session :status) 'running) 'active)
               ((plist-get task :outcome) 'needs-input)
               (t 'active))))))

(defun harness-tasks--view (task)
  "Return TASK as methods and events show it: with its `:column'.
The bookkeeping of its file stays out."
  (append (harness-plist-remove task :file-base :file-synced)
          (list :column (harness-tasks--column task))))

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
            ;; A task file written by hand may name an id of its own.
            (string-remove-prefix "t-" (plist-get task :id)))))

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
  "Queue task ID's branch for the merge queue, or put the task before the user.
`:merge-queued' records when the branch joined the queue."
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
                                :merge-target target :merge-queued (float-time) :outcome nil :error nil)
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
  "Complete CHILD's task when STATUS is `merged'; otherwise let it be fixed.
A merged task is done, unless it still waits for the user's review: a
merge that started before verification was turned on, say.  A verified
task keeps the time its work finished."
  (when-let* ((task (harness-tasks--by-session child)))
    (let ((id (plist-get task :id)))
      (if (eq status 'merged)
          (if (harness-tasks--needs-review-p task)
              (harness-tasks--to-review id :merged t :outcome 'merged :finished (float-time))
            (harness-tasks--to-done id 'merged :merge-status nil :conflicts nil :merged t
                                    :outcome 'merged
                                    :finished (or (and (harness-tasks--verified-p task) (plist-get task :finished))
                                                  (float-time))))
        ;; The merge queue steers the agent when it can fix things itself
        ;; (uncommitted changes); its next clean turn merges again.
        (if (and (harness-method-exists-p 'agent/running) (harness-call 'agent/running child))
            (harness-tasks--set id :merge-status nil :error (format "merge %s" status))
          (harness-tasks--set id :state 'active :merge-status nil :outcome 'merge-failed
                              :error (format "merge %s" status)))))))

(defun harness-tasks--same-dir-p (a b)
  "Non-nil when directories A and B are the same."
  (or (string= (file-name-as-directory (expand-file-name a)) (file-name-as-directory (expand-file-name b)))
      (ignore-errors (file-equal-p a b))))

(defun harness-tasks--lock-existing-p (lock _root worktree)
  "Keep the worktree of a merged task out of the harness's locks.
A `worktree/lock-existing-p' filter: LOCK is the verdict so far and
WORKTREE the worktree plist of ROOT about to be locked.  The merge queue
unlocks a task's worktree when it merges the branch; this keeps the
worktrees of tasks merged before the harness locked worktrees the same."
  (and lock
       (not (cl-some (lambda (task)
                       (and (harness-tasks--merged-p task)
                            (plist-get task :worktree)
                            (harness-tasks--same-dir-p (plist-get task :worktree) (plist-get worktree :path))))
                     (hash-table-values harness-tasks--table)))))

(defun harness-tasks--relock-worktree (task)
  "Lock merged TASK's worktree again, as new work starts there.
The merge queue lifted the lock when it merged the branch; the new work
is not merged yet.  Return a promise, or nil when there is nothing to do."
  (let ((worktree (plist-get task :worktree)))
    (when (and worktree (harness-tasks--merged-p task) (not (plist-get task :worktree-removed))
               (harness-method-exists-p 'worktree/lock))
      (harness-catch (harness-call-async 'worktree/lock (plist-get task :project) worktree)
                     (lambda (err)
                       (harness-log 'warn "task %s: could not lock its worktree again: %s"
                                    (plist-get task :id) (harness-error-message err))
                       nil)))))

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
Those are the sessions `task/btw' starts: a BTW over a session is
listed under it (`session/btw'), so only the board's have no parent."
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
  "Non-nil when TASK waits for a slot: pending, not in the backlog, not archived."
  (and (eq (plist-get task :state) 'pending) (not (harness-tasks--backlog-p task))
       (not (plist-get task :archived))))

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
            ;; The task's own false is set, not unset: off whatever the
            ;; directory configures.
            (cond (non-interactive (list :non-interactive t))
                  ((plist-member task :non-interactive) (list :non-interactive :false))))))

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

(defun harness-tasks--reject-text (feedback)
  "Return the message that sends a task back to its session with FEEDBACK.
It opens with `harness-tasks-reject-text', unless that is blank."
  (if (harness-string-blank-p harness-tasks-reject-text)
      feedback
    (concat harness-tasks-reject-text "\n\n" feedback)))

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
Ask mode allows reads, and non-interactive the session never waits for
the user; whatever would ask `harness-tasks--write-up-gate' denies with
a hint, which keeps a write-up a write-up."
  (let ((model (or harness-tasks-refine-model (plist-get task :model) harness-tasks-model))
        (thinking (or harness-tasks-refine-thinking (plist-get task :thinking) harness-tasks-thinking)))
    (append (list :permission-mode 'ask :non-interactive t)
            (and model (list :model model))
            (and thinking (list :thinking thinking)))))

(defconst harness-tasks--write-up-hint
  "Write the task up from what you can read; put what you could not check in the write-up as an open question."
  "Hint of a call denied because a backlog write-up only reads.")

(defun harness-tasks--write-up-gate (decision next request)
  "Keep the turns that write a backlog task up read-only.
A `permission/decide' stage at 25, after the mode and its rules and
before the auto-mode judge: a call of such a turn (see
`harness-tasks--refinement-p') still undecided there would ask the
user, or, the session being non-interactive, go to the judge.  It is
denied instead, for good.  DECISION is the current value and NEXT
continues the chain with REQUEST's decision."
  (let ((task (and (eq (plist-get decision :behavior) 'ask)
                   (harness-tasks--by-session (plist-get (plist-get request :session) :id)))))
    (funcall next (if (and task (harness-tasks--refinement-p task))
                      (list :behavior 'deny :final t
                            :reason "this session writes a backlog task up rather than doing it, so it only reads"
                            :hint harness-tasks--write-up-hint)
                    decision))))

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
sent to an archived task's session brings the task back too.  New work
needs a new review, so a verification goes, unless the turn is part of
a merge: the merge queue steering the agent to commit, say.  A merged
task's worktree is locked again for the new work."
  (remhash session-id harness-tasks--refine-calls)
  (when-let* ((task (harness-tasks--by-session session-id)))
    (remhash (plist-get task :id) harness-tasks--starting)
    (cond
     ((harness-tasks--refinement-p task)
      (harness-tasks--set (plist-get task :id) :state 'refining :outcome nil :error nil :archived nil))
     ((and (eq (plist-get task :state) 'merging) (plist-get task :merge-status)) nil)
     (t (harness-tasks--relock-worktree task)
        (apply #'harness-tasks--set (plist-get task :id) :state 'active :outcome nil :error nil :finished nil
               :merged nil :archived nil
               (unless (eq (plist-get task :state) 'merging) (list :verified nil :verified-at nil)))))))

(defun harness-tasks--on-turn-ended (session-id reason)
  "Advance SESSION-ID's task when its turn ended with REASON.
`end-turn' puts the work in review (`harness-tasks-require-verification')
until the user verified it; after that, or without review, it completes
the task outside git and queues its merge inside.  A refinement turn
puts its write-up in the backlog."
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
       ;; Merged mid-turn: done, or in review when that merge needs one.
       ((and (memq (plist-get task :state) '(done review)) (harness-tasks--merged-p task)) nil)
       ((harness-tasks--needs-review-p task)
        (harness-tasks--to-review id :outcome reason :error nil :finished (float-time)))
       ((and (plist-get task :worktree) (not (plist-get task :worktree-removed)))
        (harness-tasks--enqueue-merge id))
       (t (harness-tasks--to-done id 'finished :outcome reason :finished (float-time))))
      (harness-run-soon #'harness-tasks--schedule))))

(defun harness-tasks--on-pending-changed (session-id &rest _)
  "Re-announce SESSION-ID's task: requests coming and going move its column.
Its file shows the column, so it is written again."
  (when-let* ((task (harness-tasks--by-session session-id)))
    (harness-tasks--save-soon)
    (harness-emit 'task/changed (harness-tasks--view task))))

(defun harness-tasks--on-session-updated (session-id changes)
  "Write the file of SESSION-ID's task again when CHANGES rename the session.
A task's title is its session's name."
  (when (and (plist-member changes :name) (harness-tasks--by-session session-id))
    (harness-tasks--save-soon)))

(defun harness-tasks--on-session-plan (session-id &rest _)
  "Write the file of SESSION-ID's task again: it shows the session's plan."
  (when (harness-tasks--by-session session-id)
    (harness-tasks--save-soon)))

(defun harness-tasks--on-session-deleted (session-id &rest _)
  "Forget the task of deleted SESSION-ID."
  (when-let* ((task (harness-tasks--by-session session-id)))
    (harness-tasks--remove (plist-get task :id))))

(defun harness-tasks--remove (id)
  "Drop task ID, delete its file and emit `task/deleted'."
  (let ((task (gethash id harness-tasks--table)))
    (remhash id harness-tasks--table)
    (remhash id harness-tasks--starting)
    (when task (harness-tasks--delete-file task)))
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

(defun harness-tasks--pick-up ()
  "Soon pick up the work a stopped harness left, then start waiting tasks.
Runs once the modules are up, and again when a store read later adds
records.  Each step leaves alone the tasks something already works on."
  (harness-run-soon #'harness-tasks--recover)
  (harness-run-soon #'harness-tasks--resume-merges)
  (harness-run-soon #'harness-tasks--recover-refinements)
  (harness-run-soon #'harness-tasks--schedule))

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
Return its session, where the user asks how the tasks are going: a new
`btw' session named NAME at the project root on every call, sharing
nothing with earlier ones, and without a parent (a BTW over a session is
listed under it instead, see `session/btw'), which
`harness-tasks-btw-prompt' tells to answer with the task and session
tools.  The caller sends the first question."
  (harness-call 'session/create :cwd (harness-tasks--project cwd) :kind 'btw :name name))

(harness-defmethod task/list (&optional cwd)
  "Return the tasks of CWD's project, oldest first; every task without CWD.
What changed in the project's task folder (every task folder without
CWD) is read first, so tasks written by hand show."
  (harness-tasks--load)
  (let ((project (and cwd (harness-tasks--project cwd))))
    (when project (harness-tasks--open-project project))
    (harness-tasks--scan-roots (if project (list project) (hash-table-keys harness-tasks--file-roots)))
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
  "Queue task ID's branch for the merge queue again (after a failed merge).
A task in review merges when the user verifies it (`task/verify')."
  (let ((task (harness-tasks--get id)))
    (unless (plist-get task :worktree) (error "Task %s has no worktree to merge" id))
    (when (eq (plist-get task :state) 'done) (error "Task %s is already merged" id))
    (when (eq (plist-get task :state) 'review)
      (error "Task %s waits for your review; verifying it merges it" id))
    (harness-tasks--set id :merge-attempts 0)
    (harness-tasks--enqueue-merge id)
    (harness-call 'task/get id)))

(harness-defmethod task/complete (id)
  "Mark task ID done by hand, merged or not.
That is the user accepting it, so it counts as verified."
  (let ((task (harness-tasks--get id)))
    (when (and (plist-get task :session) (harness-method-exists-p 'merge/cancel))
      (harness-call 'merge/cancel (plist-get task :session)))
    (prog1 (harness-tasks--to-done id 'completed :merge-status nil :finished (float-time)
                                   :verified t :verified-at (float-time))
      (harness-run-soon #'harness-tasks--schedule))))

(harness-defmethod task/verify (id)
  "Accept the work of task ID, which waits in review; return the task.
Its branch, in a git project, goes through the merge queue, and the
task is done once merged; otherwise, or when its branch is merged
already, it is done now."
  (let ((task (harness-tasks--get id)))
    (unless (eq (plist-get task :state) 'review)
      (error "Task %s is not waiting for review" id))
    (harness-tasks--set id :verified t :verified-at (float-time))
    (if (and (plist-get task :worktree) (not (plist-get task :worktree-removed))
             (not (harness-tasks--merged-p task)) (harness-method-exists-p 'merge/enqueue))
        (progn (harness-tasks--set id :merge-attempts 0)
               (harness-tasks--enqueue-merge id))
      (harness-tasks--to-done id 'verified :outcome (or (plist-get task :outcome) 'end-turn)
                              :finished (or (plist-get task :finished) (float-time))))
    (harness-run-soon #'harness-tasks--schedule)
    (harness-call 'task/get id)))

(harness-defmethod task/reject (id feedback &optional attachments)
  "Send task ID, which waits in review, back to work with FEEDBACK.
FEEDBACK and ATTACHMENTS go to the task's own session, in its own
worktree, as a new prompt opened by `harness-tasks-reject-text'.  The
round of feedback is kept in the task's `:feedback'.  The task is
active again and comes back to review when that turn ends.  Return the
task."
  (let ((task (harness-tasks--get id)))
    (unless (eq (plist-get task :state) 'review)
      (error "Task %s is not waiting for review" id))
    (when (harness-string-blank-p feedback) (error "Sending a task back needs feedback"))
    (unless (harness-tasks--session task) (error "Task %s has no session to send the feedback to" id))
    (when (plist-get task :worktree-removed)
      (error "Task %s was archived and its worktree removed; submit a new task" id))
    (let ((sid (plist-get task :session))
          (feedback (string-trim feedback)))
      (when (eq (plist-get (harness-call 'session/get sid) :status) 'inactive)
        (harness-call 'session/resume sid))
      (harness-tasks--set id :state 'active :outcome nil :error nil :finished nil :archived nil
                          :verified nil :verified-at nil :merge-attempts 0
                          :feedback (append (plist-get task :feedback)
                                            (list (list :text feedback :at (float-time)))))
      (harness-catch (harness-call-async 'agent/prompt sid
                                         (harness-tasks--blocks
                                          (list :prompt (harness-tasks--reject-text feedback)
                                                :attachments attachments)))
                     (lambda (e) (harness-tasks--fail id e)))
      (harness-call 'task/get id))))

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
  (harness-on 'session/updated #'harness-tasks--on-session-updated)
  (harness-on 'session/plan #'harness-tasks--on-session-plan)
  (harness-on 'merge/started #'harness-tasks--on-merge-started)
  (harness-on 'merge/conflict #'harness-tasks--on-merge-conflict)
  (harness-on 'merge/finished #'harness-tasks--on-merge-finished)
  (harness-add-filter 'worktree/lock-existing-p #'harness-tasks--lock-existing-p)
  (harness-add-filter 'agent/system-prompt #'harness-tasks--system-prompt 60)
  (harness-add-filter 'agent/system-prompt #'harness-tasks--btw-system-prompt 60)
  (harness-add-filter 'naming/system-prompt #'harness-tasks--naming-prompt 60)
  (harness-add-filter 'permission/decide #'harness-tasks--write-up-gate 25)
  (harness-tasks--start-polling)
  (harness-tasks--pick-up))

(defun harness-tasks--shutdown ()
  "Stop reading the task folders and write what waits to be written."
  (when (timerp harness-tasks--poll-timer) (cancel-timer harness-tasks--poll-timer))
  (setq harness-tasks--poll-timer nil)
  (harness-tasks-flush))

(harness-declare-event 'task/changed "(TASK) after a task is submitted or changes state or column.")
(harness-declare-event 'task/deleted "(ID) after a task is removed.")
(harness-declare-event 'task/review "(TASK) when a task's finished work starts waiting for the user's review.")
(harness-declare-event 'task/done "(TASK HOW) when a task becomes done; HOW is merged, finished, verified or completed.")

(harness-define-module 'tasks
  :doc "Task mode: one session per task, from backlog write-up or worktree through your review to merged, with a concurrency limit."
  :requires '(store project session agent)
  :init #'harness-tasks--init
  :shutdown #'harness-tasks--shutdown)

;; A reload does not initialise a running module again, and a write-up
;; must not go without the stage that keeps it read-only: install it now.
(when (harness-module-ready-p 'tasks)
  (harness-add-filter 'permission/decide #'harness-tasks--write-up-gate 25))

(provide 'harness-tasks)
;;; harness-tasks.el ends here
