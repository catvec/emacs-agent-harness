;;; harness-tasks.el --- Task mode: one session per task  -*- lexical-binding: t; -*-

;;; Commentary:

;; Task mode manages sessions by the task they are completing.  A task
;; is a prompt submitted for a project; it gets a session of its own
;; when it starts and the session does the work, usually in auto
;; permission mode so it is seldom held up waiting for the user.  It is
;; interactive, asking when it needs a permission, unless the
;; configuration makes it non-interactive (`harness-tasks-non-interactive',
;; or `harness-non-interactive' for its directory).  A task is named as
;; soon as it is submitted, while it may wait for a slot, and its session
;; takes that name: `harness-tasks--naming-instructions' asks the model
;; for a ticket title (see Titles).
;;
;; A task's session also runs on a shorter context than an interactive
;; one by default: `harness-tasks-context-limit' (256k tokens) caps the
;; session's context window, so the harness compacts a task sooner and
;; hands it a smaller transcript to carry on from.  Set it to nil to
;; give task sessions the whole window, like any other session, or to
;; another number of tokens to choose how often they compact.
;;
;; In a git project a task owns the whole life of its change: it starts
;; in a fresh worktree on a branch of its own (the `worktree' module),
;; its session is told to commit there, and when the agent finishes the
;; branch goes through the merge queue (the `merge' module) into the
;; branch checked out at the project root.  A task is complete only once
;; its changes are merged.  The merge queue needs a parent session to
;; merge into, so every project gets one quiet session at its root,
;; named by `harness-tasks--merge-session-name', that only ever receives
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
;; same session, in its own worktree (or the main tree, see below), as a
;; new prompt, and the task comes back to review when that turn ends.
;; Every round of feedback is kept with the task (`:feedback'), and so
;; is the verification (`:verified', `:verified-at').  Any other message
;; the user sends the session while its task waits for review sends it
;; back the same way, with the message as the feedback, wherever it was
;; written: the session's own chat, `task/prompt', another client, the
;; queue (`harness-tasks--on-message').  Only the user reviews.  The
;; harness's own messages do not count, and a message from another
;; session's agent (`session_send', task_control's message) is no review
;; either: it reaches the session as that session's, opened by
;; `harness-tasks--aside-message' rather than the reject text, keeps no
;; round of feedback, and the task works on it and comes back to review
;; when the turn ends, its report standing unless the session hands in
;; a new one.  What the user reviews is the report the session hands in
;; (`hand_in', `:report'); a round that ends without one gets a report
;; marked `:missing' that says so, holding the session's last message
;; (`harness-tasks--missing-report').
;;
;; Backlog refinement (once called grooming): a task submitted with
;; `:refine' is jotted down for later, not started.  An agent writes it
;; up first -- briefly, read-only, at the project's root, told so by
;; `harness-tasks--refine-prompt' -- and its final reply becomes the
;; task's prompt; the original words stay in `:note'.  The task then
;; waits in pending as a backlog task (`:backlog'): the scheduler never
;; starts it, only `task/start' does, so the backlog survives restarts
;; until someone picks a task.  Its session is the one that refined it:
;; starting moves that session into the task's worktree and tells it to
;; do the work.  A message to a backlog task's session is feedback on
;; the write-up, which the agent rewrites.
;;
;; Main tree: a task submitted with `:main-tree' (the `task_submit'
;; tool's `main_tree', or the board's worktree switch) gets no worktree
;; and no branch.  Its session works in the project's main checkout, so
;; the task can touch the checkout itself -- cleaning up uncommitted
;; changes, say -- and nothing merges when its turn ends.  A refined
;; task keeps the declaration for when it starts.
;;
;; Priority: every task has one of `harness-tasks-priorities', low,
;; medium (the default) or high, given at submission (`:priority') and
;; changed at any time (`task/set-priority').  It orders the queue: when
;; `harness-tasks-max-running' holds a project's tasks back, a free slot
;; goes to the highest priority waiting, the oldest of those first.  It
;; never stops a task at work, and backlog tasks still wait for someone
;; to start them.
;;
;; Duplicates: the agent first looks for related tasks on the board
;; (task_list).  When one already asks for exactly the same change it
;; refuses: its final reply is `Duplicate of ID' and a message for the
;; user, and the task waits for them, `duplicate' (with `:duplicate-of'
;; ID and the message as its `:error'), rather than in the backlog.
;; Dropping it is then one click away, and so is having it written up
;; all the same (`harness-tasks--refine-anyway-text').
;;
;; States:
;;
;;   pending   submitted, waiting for a free slot of its project (only
;;             when `harness-tasks-max-running' limits how many of a
;;             project's tasks run at once: each project has slots of
;;             its own, and only the tasks' own top-level sessions take
;;             them, never their sub-agents or the merge queue's work;
;;             higher priority first, then oldest first), or a backlog
;;             task waiting for someone to start it
;;   refining  an agent is writing a backlog task up, or stopped part
;;             way (`:outcome' says why: error, cancelled, duplicate…)
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
;; project root.  `harness-tasks--btw-prompt' tells it to answer from the
;; task and session tools.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)

(defcustom harness-tasks-max-running nil
  "Tasks of each project that may work at once; the rest wait as pending.
The limit is per project: every project has this many slots of its
own, and its pending tasks wait only for its own working ones, never
for another project's.  With 2, two projects may run four tasks
between them.  A task's project is the main checkout it was submitted
for, also when it works in a worktree.

Only top-level sessions are limited: a task takes a slot while its own
session works on it, running or waiting on the user mid-turn.  The
sessions working for it never take one -- its sub-agents and forks,
and the merge queue's conflict resolvers -- and neither does the merge
queue's work: a task whose branch is queued, merging or having its
conflicts resolved holds no slot, even while its own session commits
or resolves them.  `task/start' starts a task whatever the limit.
nil (the default) means no limit.  Waiting tasks start by priority,
then oldest first (see `harness-tasks-priorities')."
  :type '(choice (const :tag "No limit" nil) integer) :group 'harness)

(defconst harness-tasks-priorities '(low medium high)
  "The priorities a task may have, lowest first; `medium' is the default.
When `harness-tasks-max-running' makes a project's tasks wait, a free
slot goes to the highest priority waiting, the oldest of those first.")

(defcustom harness-tasks-require-verification t
  "When non-nil, finished work waits for the user to review it.
A task whose turn ends cleanly goes to review instead of done, in a git
project with its branch not merged yet.  Verifying it (`task/verify')
merges the branch and completes the task; sending it back with
feedback (`task/reject') has its session work on it again.  With nil a
task is done once its branch merges, or outside git once its turn ends.

The task board turns review off and on again with its Review switch,
for every project.  Turning it off leaves the tasks that already wait
for review where they are, for the user to verify."
  :type 'boolean :group 'harness)

(defcustom harness-tasks-permission-mode 'auto
  "Permission mode of task sessions, or nil for the configured default."
  :type '(choice (const :tag "Configured default" nil)
                 (const ask) (const accept-edits) (const auto) (const yolo))
  :group 'harness)

(defcustom harness-tasks-non-interactive nil
  "When non-nil, task sessions run non-interactive.
They never wait for the user: the auto-mode judge decides what would
ask them, and after a denial the agent is told to find another way, so
a task keeps working while nobody watches it.  With nil (the default) a
task's session starts like any other session, interactive unless
`harness-non-interactive' is on for its directory: what needs your
permission waits for you, and the task needs input meanwhile.  A task's
own setting, from the board or `task/submit', wins over both."
  :type 'boolean :group 'harness)

(defconst harness-tasks--thinking-levels
  '((const :tag "Low" "low") (const :tag "Medium" "medium") (const :tag "High" "high")
    (const :tag "Extra high" "xhigh") (const :tag "Max" "max") (string :tag "Other level"))
  "Customize types of the thinking levels a task setting may name.")

(defcustom harness-tasks-model nil
  "Model of task sessions, or nil for the configured default."
  :type '(choice (const :tag "Configured default" nil) (string :tag "Model" :names model))
  :group 'harness)

(defcustom harness-tasks-thinking nil
  "Thinking level of task sessions, or nil for the configured default."
  :type `(choice (const :tag "Configured default" nil) ,@harness-tasks--thinking-levels)
  :group 'harness)

(defcustom harness-tasks-context-limit 256000
  "Most tokens of context a task session uses, or nil for its whole window.
A task session compacts when its context comes within the usual reserve
of this limit, so unattended tasks compact earlier than interactive
sessions: the handoff summary keeps them working from a smaller
transcript, and the turn after a compaction starts cheap.  The limit
never raises a session above its model's own window.  With nil task
sessions use the whole window, like any other session, and compact at
the usual point.  A provider that compacts on its own side is asked to
compact at the same point where it can be (Claude Code, see the claude
provider)."
  :type '(choice (const :tag "The whole window" nil)
                 (integer :tag "Tokens of context"))
  :safe (lambda (v) (or (null v) (and (integerp v) (> v 0))))
  :group 'harness)

(defconst harness-tasks--naming-instructions
  "This conversation is a task the engineer handed to the agent to do unattended, tracked on a task board.  Title it like a ticket on that board: an imperative summary of the work to be done, such as \"Fix login redirect loop\" or \"Add CSV export to reports\"."
  "Text added to the naming system prompt of task sessions, or nil for none.
A task's session name is its title on the board, so by default the
model titles task sessions like tickets.")

(defconst harness-tasks--refine-prompt
  "## Task refinement
This session refines a task for the backlog: the engineer jotted it down to be done later, maybe by another agent that will not see this conversation.  Do not do the task: write it up.
- First, a quick search for related tasks: call task_list once with include_archived true and limit 50, the project's most recent tasks (the line of this one says \"(this task)\").  Read a task's session with session_read only when its line leaves you unsure what it changes.
- If a task there already asks for exactly the same feature or fix -- the same change, not merely a related one -- refuse this one instead of writing it up: your final message is then a first line \"Duplicate of ID\", ID being that task's id, and after a blank line a short message for the engineer saying which task it is (its title and where it stands) and what makes it the same.  Once the engineer asks for the write-up anyway, write it up.
- A related task is no reason to refuse.  The ones that work in the same code area (the same files or functions) go in a \"Related tasks\" section of the write-up: each one's id, title, branch, session and where it stands, and what it changes there.  Tell whoever does this task to coordinate with them rather than redo or undo their work: check where each stands first (task_list, session_read), message its session (session_send) while it is at work to agree who changes what, build on its commits (git cherry-pick from its branch) instead of writing the same code again, and keep to the approach it took.
- Be brief.  Look at the project only as far as you need to name the right files and functions: a handful of reads or searches at most.  This is a write-up, not the work, so do not plan, edit files, run commands or ask the user questions; put open questions in the write-up instead.
- End your turn with the complete write-up as your final message and nothing else.  Its first line is a short imperative title, plain text, no heading markup.  Then, after a blank line, in concise markdown: what is wanted and why, what to change (files, functions, behaviour), how to tell it is done, related tasks, and open questions or assumptions -- those two only if there are any.
- When the user replies, take it as feedback on the task and answer with the complete updated write-up."
  "System prompt section of a session that writes a backlog task up.
Its final reply becomes the task's prompt, so it asks for one complete,
self-contained write-up.  It also has the agent look for related tasks
first and refuse a task the board already has, with a reply whose
first line is \"Duplicate of ID\" (see `harness-tasks--refusal'), and
name the related tasks in the same code area in the write-up, with
how to coordinate with their sessions.")

(defcustom harness-tasks-refine-model nil
  "Model that writes backlog tasks up, or nil for the task's own model."
  :type '(choice (const :tag "The task's model" nil) (string :tag "Model" :names model))
  :group 'harness)

(defcustom harness-tasks-refine-thinking "low"
  "Thinking level of refining a backlog task, or nil for the task's own.
A write-up should be quick, so the default thinks little."
  :type `(choice (const :tag "The task's thinking level" nil) ,@harness-tasks--thinking-levels)
  :group 'harness)

(defconst harness-tasks--refine-tool-calls 8
  "Tool calls a write-up may make before the agent is told to finish it.
The agent is steered once, to write the task up with what it knows; nil
never tells it.  It keeps a backlog write-up brief.")

;;;; Recaps

;; A card's subtitle is a recap of the task, written by a cheap model
;; call (see harness-recap.el).  The recap is refreshed at the first of
;; `harness-tasks-recap-turns' turns, `harness-tasks-recap-seconds'
;; seconds or `harness-tasks-recap-tool-calls' tool calls since the
;; last one, whichever comes first, like a warranty's months or miles:
;; a card that sat in review for a week should not count that as work.

(defcustom harness-tasks-recap t
  "When non-nil, task cards get a recap subtitle from a short model call."
  :type 'boolean :group 'harness)

(defcustom harness-tasks-recap-turns 4
  "Turns since the last recap that make a new one due.
Whichever comes first of this, `harness-tasks-recap-seconds' and
`harness-tasks-recap-tool-calls'; nil never refreshes on turns."
  :type '(choice (const :tag "Never" nil) (integer :tag "Turns")) :group 'harness)

(defcustom harness-tasks-recap-seconds 120
  "Seconds of work since the last recap that make a new one due.
Whichever comes first of this, `harness-tasks-recap-turns' and
`harness-tasks-recap-tool-calls'; nil never refreshes on time."
  :type '(choice (const :tag "Never" nil) (number :tag "Seconds")) :group 'harness)

(defcustom harness-tasks-recap-tool-calls 8
  "Tool calls since the last recap that make a new one due.
Whichever comes first of this, `harness-tasks-recap-turns' and
`harness-tasks-recap-seconds'; nil never refreshes on tool calls."
  :type '(choice (const :tag "Never" nil) (integer :tag "Tool calls")) :group 'harness)

(defcustom harness-tasks-recap-model 'auto
  "Model that writes task recaps.
`auto' asks the session's provider for its cheap tier, falling back
to the session's own model; nil uses the session's own model."
  :type '(choice (const :tag "Provider's cheap tier" auto)
                 (const :tag "The task's model" nil)
                 (string :tag "Model" :names model))
  :group 'harness)

(defcustom harness-tasks-recap-thinking nil
  "Thinking level of a recap request, or nil for the provider's default."
  :type `(choice (const :tag "Provider default" nil) ,@harness-tasks--thinking-levels)
  :group 'harness)

(defcustom harness-tasks-recap-max-tokens 60
  "Most tokens a recap request may write."
  :type 'integer :group 'harness)

(defcustom harness-tasks-recap-max-length 160
  "Longest recap a card shows, in characters."
  :type 'integer :group 'harness)

(defcustom harness-tasks-recap-context 8000
  "Characters of transcript a recap request may carry.
The tail of the transcript, so the request stays short on a long task."
  :type 'integer :group 'harness)

(defcustom harness-tasks-recap-interval 30
  "Seconds between checks for a recap due on time while a task works."
  :type '(choice (const :tag "No timer" nil) (number :tag "Seconds")) :group 'harness)

(defcustom harness-tasks-recap-retry 60
  "Seconds before a new recap is tried again after one failed."
  :type '(choice (const :tag "No wait" nil) (number :tag "Seconds")) :group 'harness)

(defconst harness-tasks--start-message
  "Start working on this task now.  It was written up earlier without doing any of it; that is over, so change files, run commands and so on as the task requires.  If it names related tasks, see where they stand now and coordinate with them as it says before you change the same code."
  "Opening of the message that starts a backlog task's work.
The task's write-up follows it, then the request it was written from.
A write-up names the related tasks working on the same code, which the
work coordinates with (see `harness-tasks--refine-prompt').")

(defconst harness-tasks--reject-message
  "The user reviewed your work on this task and sent it back. Address their feedback below, then finish as before (commit your changes, if you work in a git worktree). Your work goes back to the user for review when your turn ends."
  "Opening of the message that sends a task back to its session after review.
The user's feedback follows it (`task/reject'), as it opens any message
the user sends the session while its task waits for review
\(`harness-tasks--on-message').  Only the user's: a message from another
session's agent is no review, and `harness-tasks--aside-message' opens it.")

(defconst harness-tasks--aside-message
  "Another session sent you the message below while your task was waiting for the user's review. It is not their review, and nothing was sent back: reply to it or act on it as it needs. Your work goes back to review when your turn ends. If you change it, finish as before (commit your changes, if you work in a git worktree) and hand it in again; otherwise the report you handed in stands."
  "Opening of a message another session sends a task's session in review.
That session's agent wrote it (`session_send', task_control's message),
not the user reviewing the work, so it does not send the task back
\(`harness-tasks--on-message'): it keeps no round of feedback, and the
report handed in stands unless the session hands in another.  The
message follows as it was sent, its sender's header first.")

(defconst harness-tasks--btw-prompt
  "## Task board
This is a side conversation the user opened from this project's task board to ask about its tasks: what each one is doing, how far along it is, what it changed, why it is stuck, which ones need the user. Answer from the live state and check it again for every question: task_list shows the board (each task's title, column, state, session, branch and what it waits on), session_read a task's session (its plan, todos, latest transcript and working directory, where git shows what it changed), session_search where something was said, and task_wait or session_wait wait for a task or a session to settle. Refer to tasks by title and id, and keep answers short. Change nothing (tasks, sessions or files) unless the user asks you to."
  "Text added to the system prompt of BTW conversations about a task board.
Such a conversation is opened from the board (`task/btw') to ask about
its tasks; nil adds nothing.")

(defcustom harness-tasks-worktrees t
  "When non-nil, tasks in a git project work in a worktree and merge back.
Each task gets a branch named after `harness-tasks-branch-prefix' and is
complete only when the merge queue has merged that branch."
  :type 'boolean :group 'harness)

(defcustom harness-tasks-branch-prefix "task/"
  "Prefix of the branches task worktrees are created on."
  :type 'string :group 'harness)

(defconst harness-tasks--merge-attempts 3
  "Merges a task may try before it waits for the user.")

(defconst harness-tasks--merge-session-name "Task merges"
  "Name of the session at a project's root that task branches merge into.")

(defcustom harness-tasks-resume-interrupted t
  "When non-nil, tasks a stopped harness interrupted carry on by themselves.
A task that was working when the harness stopped (Emacs quit,
`harness-restart', a crash) is sent `harness-tasks--resume-prompt' when the
harness starts again.  With nil it waits in needs-input instead, with
the outcome `interrupted', until you reply.  The same goes for a backlog
task's write-up: it is written again, or with nil waits for a retry."
  :type 'boolean :group 'harness)

(defconst harness-tasks--resume-prompt
  "The harness restarted while you were working on this task, so your last turn was cut short: tool calls that were still running did not finish. Check where you left off, then carry on with the task."
  "Message that resumes a task's session after a restart interrupted it.")

(defconst harness-tasks--retry-prompt
  "Your last turn on this task stopped before the task was finished: %s. Check where you left off, then carry on with the task."
  "Message that has a task's session work again after its turn stopped.
`task/retry' sends it; %s says how the turn stopped.")

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

(defconst harness-tasks--symbol-keys '(:state :outcome :merge-status :priority)
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

(defun harness-tasks--before-move (gate session _dir)
  "Keep the session of a task in the task's directory.
A `session/before-move' filter: GATE is (:proceed t) and SESSION the
plist of the session that is to move.  The board files a task under
its project and follows its work through its session, and a message to
that session brings the task back to work, so the session stays."
  (let ((task (and (plist-get gate :proceed)
                   (harness-tasks--by-session (plist-get session :id)))))
    (if task
        (list :proceed nil
              :reason (format "it works on task %s, which stays in %s; submit a task in the other directory instead"
                              (plist-get task :id) (abbreviate-file-name (plist-get task :cwd))))
      gate)))

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
  "Turn the string enum values of a stored TASK back into symbols.
Records from before the task files were removed lose their bookkeeping
of them (`:file', `:file-base', `:file-synced', `:updated', `:extra')."
  (let ((task (harness-plist-remove task :file :file-base :file-synced :updated :extra)))
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

(defun harness-tasks--main-tree-p (task)
  "Non-nil when TASK works in the project's main tree, without a worktree.
Set at submission (`task/submit' with `:main-tree'), for work that has
to touch the main checkout itself, such as cleaning up uncommitted
changes: the task runs where the project is checked out, on no branch,
and nothing merges when its turn ends."
  (harness-json-true-p (plist-get task :main-tree)))

(defun harness-tasks--read-priority (value)
  "Return VALUE as one of `harness-tasks-priorities', or signal.
VALUE is a symbol or a string in any case, \"med\" meaning medium, so
a priority can come from JSON, a tool or a person.  nil is medium."
  (let ((name (downcase (string-trim (cond ((null value) "medium")
                                           ((symbolp value) (symbol-name value))
                                           ((stringp value) value)
                                           (t (format "%s" value)))))))
    (or (car (memq (intern (if (equal name "med") "medium" name)) harness-tasks-priorities))
        (error "Unknown priority %s; it is low, medium or high" value))))

(defun harness-tasks--priority (task)
  "Return TASK's priority: one of `harness-tasks-priorities', medium unless set."
  (let ((value (plist-get task :priority)))
    (or (car (memq (if (stringp value) (intern value) value) harness-tasks-priorities))
        'medium)))

(defun harness-tasks--start-order (tasks)
  "Return TASKS in the order they get slots (destructively).
That is the highest priority first, the oldest first among equals."
  (sort tasks (lambda (a b)
                (let ((pa (cl-position (harness-tasks--priority a) harness-tasks-priorities))
                      (pb (cl-position (harness-tasks--priority b) harness-tasks-priorities)))
                  (if (= pa pb)
                      (< (plist-get a :created) (plist-get b :created))
                    (> pa pb))))))

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
Stores whose text would not change are skipped, and a repository store
left without records is deleted.  Repository stores go first, so a
record moving out of the global store stays there until its repository
has it; one that cannot be written leaves its records there."
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
  "Forget what this process read and wrote of the stores."
  (clrhash harness-tasks--stores)
  (clrhash harness-tasks--written)
  (setq harness-tasks--backup-checked nil))

(defun harness-tasks--load ()
  "Read the task records from their stores once.
The repository stores of the registry come first, then the global
store, so a record in both (a move a crash cut short) keeps its
repository copy.  A save follows, which moves the records kept where
their project does not keep them, like git projects' tasks from before
repository stores."
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
      (harness-tasks--add-records (harness-tasks--read-json (harness-tasks--global-store))))
    (harness-tasks--save-soon)))

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
Its `:priority' is always there: a record from before priorities shows
the default, medium."
  ;; `append' copies TASK, so `plist-put' changes only the view.
  (plist-put (append task (list :column (harness-tasks--column task)))
             :priority (harness-tasks--priority task)))

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
            ;; A record from an older store may name an id without the prefix.
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
  (let ((existing (cl-find-if (lambda (s) (and (equal (plist-get s :name) harness-tasks--merge-session-name)
                                               (equal (plist-get s :cwd) root)
                                               (null (plist-get s :worktree))))
                              (harness-call 'session/list (list :project root)))))
    (plist-get (or existing
                   (harness-call 'session/create :cwd root :name harness-tasks--merge-session-name))
               :id)))

(defun harness-tasks--enqueue-merge (id)
  "Queue task ID's branch for the merge queue, or put the task before the user.
`:merge-queued' records when the branch joined the queue."
  (let* ((task (harness-tasks--get id))
         (attempts (1+ (or (plist-get task :merge-attempts) 0))))
    (cond
     ((> attempts harness-tasks--merge-attempts)
      (harness-tasks--set id :state 'active :outcome 'merge-failed :merge-status nil
                          :error (format "gave up after %d merge attempts: %s"
                                         harness-tasks--merge-attempts (or (plist-get task :error) "?"))))
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
         (harness-run-command (list "git" "-C" (directory-file-name root) "branch" "-d" branch)
                              :cwd root :name "harness-tasks-git")))
     (lambda (err)
       (harness-log 'warn "task %s: keeping its worktree: %s" (plist-get task :id) (harness-error-message err))
       nil))))

;;;; The task prompts

(defconst harness-tasks-hand-in-prompt
  "Finish with the hand_in tool rather than a plain reply: it hands your summary and your evidence to the user and ends the turn, so the task waits for their review.  The evidence is required, and shows the work rather than describing it -- an image or a video of what you built whenever there is anything to see (take the screenshot first), and the tool call that proves a claim about a command (the tests pass, the command's output) quoted by its call id.  A file, a code block or a note is evidence for what cannot be shown.  Then stop; do not start more work."
  "What a task's session is told about handing its finished work in.")

(defun harness-tasks--system-prompt (prompt session)
  "Tell a task's SESSION what its turns are for (PROMPT filter).
Before the task starts they write it up (`harness-tasks--refine-prompt');
afterwards they learn how to hand the finished work in, and, in a
worktree, how it reaches the main branch -- or, in the main tree
(`harness-tasks--main-tree-p'), that the work takes effect there."
  (let ((task (harness-tasks--by-session (plist-get session :id))))
    (cond
     ((and task (harness-tasks--refinement-p task)
           (not (harness-string-blank-p harness-tasks--refine-prompt)))
      (concat prompt "\n\n" harness-tasks--refine-prompt "\n"))
     ((not task) prompt)
     (t
      (concat prompt "\n\n## Task mode\n"
              (cond
               ((plist-get task :worktree)
                (format "You are working on one task, unattended, in your own git worktree %s on branch %s. "
                        (plist-get task :worktree) (plist-get task :branch)))
               ((harness-tasks--main-tree-p task)
                (format "You are working on one task, unattended, directly in the project's main working tree %s.  There is no worktree and no branch, and nothing merges your work: what you change, commit or delete takes effect right there.  Do not create a branch or a worktree, and commit only if the task asks for it. "
                        (abbreviate-file-name (or (plist-get task :project) (plist-get task :cwd)))))
               (t "You are working on one task of a board, unattended. "))
              "Do the whole task there. "
              (if (plist-get task :worktree)
                  (concat "When you are done, commit all of your changes on that branch "
                          "(git add -A, then git commit with a message saying what the change does). "
                          (format "Do not merge, rebase onto or push %s yourself: when your turn ends the harness merges "
                                  (or (plist-get task :base) "the main branch"))
                          "your branch through the merge queue, and it will come back to you if the merge needs anything. ")
                "")
              harness-tasks-hand-in-prompt)))))



(defun harness-tasks--naming-prompt (prompt session)
  "Ask for a ticket title when naming a task or its SESSION (PROMPT filter).
SESSION is the session named, or the options of a task's own request
\(`naming/title'), which name the task with `:task'."
  (if (and (not (harness-string-blank-p harness-tasks--naming-instructions))
           (or (plist-get session :task)
               (harness-tasks--by-session (plist-get session :id))))
      (concat prompt "\n\n" harness-tasks--naming-instructions)
    prompt))

;;;; Titles
;;
;; A task is named as soon as it is submitted, while it may still wait
;; for a slot: its prompt goes out in the request that names a session
;; from its first message, to the cheap naming model (`naming/title'),
;; and the title comes back as the task's `:name'.  The board, task_list
;; and the session list show it until the task's session has a name of
;; its own.  The session takes it as the task starts (`session/create'
;; with `:name'; a written-up task's session as it moves to the work),
;; so it is not named again.  A session made while the request is out is
;; named by it when it comes back: `harness-tasks--auto-name-p' keeps the
;; naming of its first turn off meanwhile.  Nothing ever waits for a
;; title: a task starts with one or without, and when the request fails
;; its session is named the usual way, from the same message.  A backlog
;; task is named the same way, from the words it was written up from,
;; and so is every task of a board found without a title when the
;; harness starts or reloads.

(defvar harness-naming-auto)

(defconst harness-tasks--naming-concurrency 2
  "Naming requests of tasks that may be out at once; the others wait their turn.
A burst of submissions, or a board of nameless tasks found at start-up,
would otherwise send them all at once: a process each, with Claude Code.")

(defvar harness-tasks--naming (make-hash-table :test 'equal)
  "Task id -> the text its naming request asks a title for, while it is out.")

(defvar harness-tasks--naming-queue nil
  "Ids of the tasks whose naming request waits to go out, oldest first.")

(defun harness-tasks--naming-p ()
  "Non-nil when tasks are named as they are submitted.
That is when sessions are named automatically (`harness-naming-auto'),
and the naming module titles a message on its own (`naming/title')."
  (and (bound-and-true-p harness-naming-auto)
       (harness-method-exists-p 'naming/title)))

(defun harness-tasks--naming-text (task)
  "Return the text TASK is named from: the message its session opens with.
That is a backlog task's request (`:note'), which its write-up replaces
as the prompt, else the prompt."
  (or (plist-get task :note) (plist-get task :prompt)))

(defun harness-tasks--titled-p (task)
  "Non-nil when TASK has a title: a `:name', or a session with a name."
  (or (not (harness-string-blank-p (plist-get task :name)))
      (not (harness-string-blank-p (plist-get (harness-tasks--session task) :name)))))

(defun harness-tasks--wants-name-p (task)
  "Non-nil when TASK is to be named from its prompt.
That is a task with no title (`harness-tasks--titled-p'), not archived,
whose session, when it has one, runs no turn: the start of that turn
named its session from the same message, or will name it at the next."
  (and (not (harness-json-true-p (plist-get task :archived)))
       (not (harness-string-blank-p (harness-tasks--naming-text task)))
       (not (harness-tasks--titled-p task))
       (not (harness-tasks--turn-p task))))

(defun harness-tasks--name (id)
  "Have task ID named from its prompt, unless its title is already on its way.
The request waits its turn (`harness-tasks--naming-concurrency').  This
never signals and nothing waits for it: a task does not wait for, nor
fail with, its title."
  (condition-case err
      (when (and (harness-tasks--naming-p)
                 (not (member id harness-tasks--naming-queue))
                 (not (gethash id harness-tasks--naming)))
        (setq harness-tasks--naming-queue (append harness-tasks--naming-queue (list id)))
        (harness-tasks--naming-next))
    (error (harness-log 'warn "naming task %s failed: %s" id (harness-error-message err)))))

(defun harness-tasks--naming-next ()
  "Send the naming requests that wait while fewer than the limit are out.
A task that no longer wants a title is passed over: one that started
while it waited has its session named as the turn starts."
  (while (and harness-tasks--naming-queue
              (< (hash-table-count harness-tasks--naming) harness-tasks--naming-concurrency))
    (let ((task (gethash (pop harness-tasks--naming-queue) harness-tasks--table)))
      (when (and task (harness-tasks--wants-name-p task))
        (harness-tasks--ask-name task)))))

(defun harness-tasks--naming-model (task)
  "Return the model whose naming tier titles TASK: its session's, now or to be.
That is the model of the session it has, else the one it will get: a
backlog task's refining one, another's working one."
  (or (plist-get (harness-tasks--session task) :model)
      (plist-get (if (harness-tasks--backlog-p task)
                     (harness-tasks--refine-settings task)
                   (harness-tasks--work-settings task))
                 :model)
      (harness-tasks--config 'harness-model (plist-get task :cwd))))

(defun harness-tasks--ask-name (task)
  "Send the request naming TASK; `harness-tasks--named' takes its answer."
  (let ((id (plist-get task :id))
        (text (harness-tasks--naming-text task)))
    (puthash id text harness-tasks--naming)
    (harness-then (condition-case err
                      (harness-call 'naming/title text
                                    (list :task id :model (harness-tasks--naming-model task)
                                          :cwd (plist-get task :cwd)))
                    (error (harness-rejected err)))
                  (lambda (name) (harness-tasks--named id text name nil) nil)
                  (lambda (err) (harness-tasks--named id text nil err) nil))))

(defun harness-tasks--name-session (session-id)
  "Have SESSION-ID named from its first message, as its turn's start does."
  (when (harness-method-exists-p 'naming/name)
    (harness-catch (harness-call-async 'naming/name session-id '(:opening t)) #'ignore)))

(defun harness-tasks--named (id text name err)
  "Take NAME, the title of task ID from TEXT, or ERR, why there is none.
The task takes NAME as its `:name', and its session too when it has no
name.  A title of a prompt edited since is dropped, and the task named
again.  When the request failed, or its title was dropped, a nameless
session whose turn runs is named from its first message right away, as
the start of that turn left it to this request."
  (remhash id harness-tasks--naming)
  (harness-run-soon #'harness-tasks--naming-next)
  (condition-case problem
      (when-let* ((task (gethash id harness-tasks--table)))
        (let* ((session (harness-tasks--session task))
               (nameless (and session (harness-string-blank-p (plist-get session :name))))
               (current (equal text (harness-tasks--naming-text task))))
          (if (and name current)
              (progn
                (harness-tasks--set id :name name)
                (when nameless (harness-call 'session/update (plist-get session :id) :name name)))
            (if name
                (harness-log 'info "task %s: its prompt changed while it was named, so %S is dropped" id name)
              (harness-log 'warn "naming task %s failed: %s" id (harness-error-message err)))
            (cond ((and nameless (harness-tasks--turn-p task))
                   (harness-tasks--name-session (plist-get session :id)))
                  ((not current) (harness-tasks--name id))))))
    (error (harness-log 'warn "naming task %s failed: %s" id (harness-error-message problem)))))

(defun harness-tasks--auto-name-p (verdict session)
  "Keep the naming of SESSION's turn off while its task's title is on its way.
A `naming/auto-p' filter, VERDICT being the verdict so far: the title
names the session when it comes (`harness-tasks--named'), which names
the session the usual way should the request fail."
  (and verdict
       (not (when-let* ((task (harness-tasks--by-session (plist-get session :id))))
              (gethash (plist-get task :id) harness-tasks--naming)))))

(defun harness-tasks--name-untitled ()
  "Name the tasks found without a title (`harness-tasks--wants-name-p').
They come from before tasks were named as they were submitted, or
their naming failed."
  (when (harness-tasks--naming-p)
    (dolist (task (harness-tasks--sorted #'harness-tasks--wants-name-p))
      (harness-tasks--name (plist-get task :id)))))

(defun harness-tasks--name-option (task &optional session)
  "Return (:name NAME) to give a session of TASK its title, or nil.
That is when TASK has a `:name' and SESSION, the session as it is now
when there is one, has none."
  (let ((name (plist-get task :name)))
    (and (not (harness-string-blank-p name))
         (harness-string-blank-p (plist-get session :name))
         (list :name name))))

;;;; Side conversations about the board

(defun harness-tasks--btw-p (session)
  "Non-nil when SESSION is a BTW conversation about a task board.
Those are the sessions `task/btw' starts: a BTW over a session is
listed under it (`session/btw'), so only the board's have no parent."
  (and (eq (plist-get session :kind) 'btw)
       (null (plist-get session :parent-id))))

(defun harness-tasks--btw-system-prompt (prompt session)
  "Tell SESSION, when it is about a task board, how to answer (PROMPT filter)."
  (if (and (harness-tasks--btw-p session) (not (harness-string-blank-p harness-tasks--btw-prompt)))
      (concat prompt "\n\n" harness-tasks--btw-prompt "\n")
    prompt))

;;;; Scheduling
;;
;; `harness-tasks-max-running' limits each project on its own: every
;; project has that many slots, and its queued tasks wait only for its
;; own working tasks, so a busy board never holds up another project's.
;; Queued tasks take free slots by priority, the oldest first among
;; equals (`harness-tasks--start-order').
;;
;; Only top-level sessions take slots (`harness-tasks--holds-slot-p'): a
;; task holds one while its own session, which no other session started,
;; works on the task.  The sessions working for a task never take one of
;; their own: its sub-agents and forks are part of its work, the merge
;; queue's conflict resolvers part of the merge.  Nor does the merge
;; queue, which the limit does not hold up (`task/verify' queues a
;; branch at once): a task in it (merging) holds no slot, even while
;; its own session commits or resolves the conflicts.

(defun harness-tasks--working-p (task)
  "Non-nil when TASK is at work: starting, running or blocked mid-turn.
That includes its session's turns for the merge queue (state merging),
which `harness-tasks--holds-slot-p' leaves out: they take no slot."
  (or (gethash (plist-get task :id) harness-tasks--starting)
      (and (memq (plist-get task :state) '(active merging))
           (memq (plist-get (harness-tasks--session task) :status) '(running blocked)))))

(defun harness-tasks--top-level-p (session)
  "Non-nil when SESSION (a plist) is top-level: no other session started it.
Sub-agents and forks, BTWs over a session and the merge queue's
conflict resolvers name the session they work for in `:parent-id',
and the session list shows them under it."
  (and session (null (plist-get session :parent-id))))

(defun harness-tasks--holds-slot-p (task)
  "Non-nil when TASK takes one of its project's slots.
It does while it starts, and while it is active with its own session
running or blocked mid-turn: one waiting on the user keeps its slot, as
its turn goes on once answered.  Only that session counts, and only
when it is top-level (`harness-tasks--top-level-p'): the sub-agents,
forks and conflict resolvers working for a task take no slot of their
own, and neither does a sub-agent made a task (`task/adopt'), which
works for the session that started it.  A task in the merge queue
\(merging) holds none, even while its own session commits or resolves
the conflicts, and nor does writing a backlog task up (refining)."
  (or (gethash (plist-get task :id) harness-tasks--starting)
      (and (eq (plist-get task :state) 'active)
           (let ((session (harness-tasks--session task)))
             (and (harness-tasks--top-level-p session)
                  (memq (plist-get session :status) '(running blocked)))))))

(defun harness-tasks--slot-project (task)
  "Return the project whose slots TASK takes: its `:project', else its `:cwd'.
`:project' is the main checkout `harness-tasks--project' found for it,
the key boards, `task/list' and the stores group tasks by, so a task in
a worktree takes a slot of the project it merges into."
  (or (plist-get task :project) (plist-get task :cwd)))

(defun harness-tasks--free-slots (project)
  "Return how many more tasks of PROJECT may start now.
Each project has `harness-tasks-max-running' slots of its own, so only
PROJECT's tasks count, each one that holds a slot
\(`harness-tasks--holds-slot-p'): its top-level session at work, never a
sub-agent or the merge queue.  `most-positive-fixnum' without a limit."
  (if (null harness-tasks-max-running)
      most-positive-fixnum
    (- harness-tasks-max-running
       (cl-loop for task being the hash-values of harness-tasks--table
                count (and (equal (harness-tasks--slot-project task) project)
                           (harness-tasks--holds-slot-p task))))))

(defun harness-tasks--queued-p (task)
  "Non-nil when TASK waits for a slot: pending, not in the backlog, not archived."
  (and (eq (plist-get task :state) 'pending) (not (harness-tasks--backlog-p task))
       (not (plist-get task :archived))))

(defun harness-tasks--schedule ()
  "Start the queued tasks of every project while it has slots free.
They go by priority, highest first, the oldest first among equals
\(`harness-tasks--start-order').  Projects have slots of their own
\(`harness-tasks--free-slots'): the walk keeps what is left of each
one's, so a project at its limit holds up only its own tasks.  Backlog
tasks wait for `task/start' instead."
  (let ((free (make-hash-table :test 'equal)))
    (dolist (task (harness-tasks--start-order (harness-tasks--sorted #'harness-tasks--queued-p)))
      (let* ((project (harness-tasks--slot-project task))
             (left (or (gethash project free) (harness-tasks--free-slots project))))
        (when (> left 0)
          (cl-decf left)
          (harness-tasks--start task))
        (puthash project left free)))))

(defun harness-tasks--blocks (task)
  "Return the content blocks that open TASK's session."
  (cons (list :type "text" :text (plist-get task :prompt))
        (and (plist-get task :attachments) (fboundp 'harness-agent-attachments-to-blocks)
             (harness-agent-attachments-to-blocks (plist-get task :attachments)))))

(defun harness-tasks--from-harness ()
  "Return the `agent/prompt' options of a message task mode sends on its own.
Such a message (carry on after a restart, start the written-up work,
finish the write-up, write it up all the same after the agent called
it a duplicate) is not the user's, so it says it comes from the
harness.  The task's prompt and the user's feedback are the user's."
  (list :from (harness-sender-system "tasks")))

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
restart cut its start short keeps the worktree it got.  A task that
declared `:main-tree' gets no worktree: its session works in the
project's main checkout, where it was submitted from (`task/submit')."
  (let ((id (plist-get task :id))
        (worktree (plist-get task :worktree))
        (launch (if (harness-tasks--session task)
                    #'harness-tasks--continue-session
                  #'harness-tasks--open-session)))
    (puthash id t harness-tasks--starting)
    (harness-tasks--set id :state 'active :outcome nil :error nil :duplicate-of nil
                        :started (float-time) :finished nil)
    (cond
     ((harness-tasks--main-tree-p task)
      ;; No worktree even where the project has them: the main checkout.
      (funcall launch id (plist-get task :project) nil))
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
out, so the session gets what its directory configures.  The context
limit is `harness-tasks-context-limit', which caps a task's window and
so has it compact sooner."
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
                  ((plist-member task :non-interactive) (list :non-interactive :false)))
            (and harness-tasks-context-limit
                 (list :context-window-limit harness-tasks-context-limit)))))

(defconst harness-tasks-bulk-columns '(active pending needs-input)
  "Task columns a bulk update reaches by default.
They are the current work: running, pending and blocked tasks.  Review,
done and archived tasks are history and are left alone.")

(defconst harness-tasks-pref-keys '(:model :thinking :permission-mode :non-interactive)
  "Session settings a task carries until its next start.")

(defun harness-tasks--non-interactive-p (task)
  "Non-nil when TASK starts non-interactive.
Its own setting decides, an explicit false included; without one,
`harness-tasks-non-interactive', else what its directory configures
\(see `harness-tasks--work-settings').  A remote directory is not read:
the global `harness-non-interactive' stands for it."
  (if (plist-member task :non-interactive)
      (harness-json-true-p (plist-get task :non-interactive))
    (or harness-tasks-non-interactive
        (let ((cwd (plist-get task :cwd)))
          (harness-json-true-p
           (if (and cwd (not (file-remote-p cwd)))
               (harness-tasks--config 'harness-non-interactive cwd)
             (and (boundp 'harness-non-interactive) (symbol-value 'harness-non-interactive))))))))

(defun harness-tasks--prefs-differ-p (task settings)
  "Non-nil when SETTINGS would change TASK.
Non-interactive is compared with what the task would start with, so
turning it off reaches a task that has no setting of its own but would
start non-interactive all the same.  A `:priority' of nil is no
priority given: it changes nothing."
  (cl-some (lambda (k)
             (let ((want (plist-get settings k)) (have (plist-get task k)))
               (pcase k
                 (:non-interactive
                  (not (eq (and (harness-json-true-p want) t)
                           (and (harness-tasks--non-interactive-p task) t))))
                 (:priority
                  (and want (not (eq (harness-tasks--read-priority want) (harness-tasks--priority task)))))
                 (_ (not (equal want have))))))
           (harness-plist-keys settings)))

(declare-function harness-session-check-policy "harness-session" (settings &optional kind))

(defun harness-tasks--apply-prefs (task settings)
  "Merge SETTINGS into TASK and, when it has a session, into that session.
TASK's record carries what a later start would use; a started task's
session is what its next turn uses, so both change.  The session is
sent only the settings it does not have yet: each `session/update'
adds a hint to it, so a session something else already changed (`all'
commands change sessions and tasks alike) is not told twice.  A
setting the policy fixes for every session is refused before anything
changes (see `harness-session-check-policy').  A `:priority' is the
task's own, never its session's: it orders the queue.  Return TASK's
view."
  (let* ((id (plist-get task :id))
         (prefs (cl-loop for k in harness-tasks-pref-keys
                         when (plist-member settings k)
                         append (list k (plist-get settings k))))
         (priority (and (plist-get settings :priority)
                        (list :priority (harness-tasks--read-priority (plist-get settings :priority))))))
    (when (and prefs (fboundp 'harness-session-check-policy))
      (harness-session-check-policy prefs))
    (when (or prefs priority)
      (apply #'harness-tasks--set id (append prefs priority)))
    (when prefs
      (let* ((session (harness-tasks--session task))
             (changes (and session
                           (cl-loop for (k v) on prefs by #'cddr
                                    unless (harness-setting-equal-p k v (plist-get session k))
                                    append (list k v)))))
        (when (and changes (harness-method-exists-p 'session/update))
          (apply #'harness-call 'session/update (plist-get session :id) changes))))
    (harness-call 'task/get id)))

(defun harness-tasks--open-session (id cwd worktree)
  "Create task ID's session in CWD (in WORKTREE, when non-nil) and prompt it.
The session is named with the task's title when it has one by now, so
it is not named again; else the title still on its way names it."
  (condition-case err
      (let* ((task (harness-tasks--get id))
             (session (apply #'harness-call 'session/create
                             :cwd cwd
                             (append (and worktree (list :worktree worktree))
                                     (harness-tasks--name-option task)
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
    (concat harness-tasks--start-message "\n\n" prompt
            (if (and note (not (equal (string-trim note) (string-trim prompt))))
                (concat "\n\n---\nIt was written up from this request (the write-up above takes precedence):\n\n"
                        (harness-tasks--quote note))
              ""))))

(defun harness-tasks--opened-text (opening text)
  "Return TEXT opened by OPENING, a paragraph of its own, unless that is blank."
  (if (harness-string-blank-p opening)
      text
    (concat opening "\n\n" text)))

(defun harness-tasks--reject-text (feedback)
  "Return the message that sends a task back to its session with FEEDBACK.
It opens with `harness-tasks--reject-message', unless that is blank."
  (harness-tasks--opened-text harness-tasks--reject-message feedback))

(defun harness-tasks--aside-text (text)
  "Return TEXT, another session's message, as a task's session in review gets it.
It opens with `harness-tasks--aside-message', unless that is blank."
  (harness-tasks--opened-text harness-tasks--aside-message text))

(defun harness-tasks--text-block-p (block)
  "Non-nil when BLOCK is a text block that says something."
  (and (equal (plist-get block :type) "text")
       (not (harness-string-blank-p (plist-get block :text)))))

(defun harness-tasks--opened-blocks (opening blocks)
  "Return the message BLOCKS opened by OPENING, a paragraph of its own.
Its text, trimmed, opens with OPENING, as `harness-tasks--opened-text'
has it; a message of attachments alone gets a text block of its own
for it.  Blank text blocks are dropped; a blank OPENING adds nothing."
  (let ((blocks (cl-remove-if (lambda (b) (and (equal (plist-get b :type) "text")
                                               (not (harness-tasks--text-block-p b))))
                              blocks)))
    (cond
     ((harness-string-blank-p opening) blocks)
     ((harness-tasks--text-block-p (car blocks))
      (cons (plist-put (copy-sequence (car blocks)) :text
                       (harness-tasks--opened-text opening (string-trim (plist-get (car blocks) :text))))
            (cdr blocks)))
     (t (cons (list :type "text" :text opening) blocks)))))

(defun harness-tasks--reject-blocks (blocks)
  "Return the message BLOCKS as the one that sends a task back to its session.
It opens with `harness-tasks--reject-message', as
`harness-tasks--reject-text' has it (`harness-tasks--opened-blocks')."
  (harness-tasks--opened-blocks harness-tasks--reject-message blocks))

(defun harness-tasks--aside-blocks (blocks)
  "Return the message BLOCKS, another session's, as a task in review gets it.
It opens with `harness-tasks--aside-message', as
`harness-tasks--aside-text' has it (`harness-tasks--opened-blocks')."
  (harness-tasks--opened-blocks harness-tasks--aside-message blocks))

(defun harness-tasks--feedback-text (blocks)
  "Return what the message BLOCKS says, as its round of feedback keeps it.
That is its text, trimmed; a message of attachments alone is named by
them, such as \"[image]\" or \"[file notes.txt]\"."
  (let ((texts (cl-loop for b in blocks
                        when (harness-tasks--text-block-p b)
                        collect (string-trim (plist-get b :text)))))
    (if texts
        (string-join texts "\n\n")
      (mapconcat (lambda (b)
                   (let ((type (or (plist-get b :type) "attachment")))
                     (if (equal type "file")
                         (format "[file %s]" (or (plist-get b :name)
                                                 (file-name-nondirectory (or (plist-get b :path) ""))))
                       (format "[%s]" type))))
                 (cl-remove "text" blocks :key (lambda (b) (plist-get b :type)) :test #'equal)
                 " "))))

(defun harness-tasks--send-back (id feedback)
  "Put task ID, which waits for review, back to work on FEEDBACK.
The task is active again and its verification gone; FEEDBACK, what the
message that sends it back says, is kept as a new round of its
`:feedback'.  Delivering the message is the caller's: `task/reject'
prompts the session, `harness-tasks--on-message' lets the message
through.  Return the task's view."
  (let ((task (harness-tasks--get id)))
    (harness-tasks--set id :state 'active :outcome nil :error nil :finished nil :archived nil
                        :verified nil :verified-at nil :merge-attempts 0
                        :recap nil :recap-at nil :recap-turns nil :recap-tools nil
                        :feedback (append (plist-get task :feedback)
                                          (list (list :text feedback :at (float-time)))))))

(defun harness-tasks--aside (id)
  "Put task ID, which waits for review, to work on a message that is no review.
That is a message from another session's agent: the task is active
while its session deals with it, and comes back to review when that
turn ends.  No round of feedback is kept, and no new round begins (the
turn finds the task active, so it sets no `:reopened'): the report
handed in stands unless the session hands in a new one.  Return the
task's view."
  (harness-tasks--set id :state 'active :outcome nil :error nil :finished nil :archived nil))

(defun harness-tasks--on-message (blocks session-id info)
  "Send SESSION-ID's task back from review when the user wrote message BLOCKS.
An `agent/message' filter, INFO being (:from FROM :steering BOOL).  Only
the user reviews: a message the user sends the session while its task
waits for review is feedback on the work, wherever it was written --
the session's chat, `task/prompt', a phone or another client, the
queue that goes out when a turn ends.  It sends the task back as
`task/reject' does: the task is active at once, the round of feedback
is kept, and the message the agent gets opens with
`harness-tasks--reject-message'.

A message from another session's agent (FROM a session sender, as
`session_send' and task_control's message send it) is no review: no
round of feedback, no reject text.  The task is active while its
session deals with it (`harness-tasks--aside') and the message, its
sender kept, opens with `harness-tasks--aside-message' instead.  The
harness's own messages (FROM a system sender) are left alone, and so
is a task whose worktree was removed: a turn they start makes the task
active all the same (`harness-tasks--on-turn-started').  Return the
blocks to deliver."
  (let* ((task (harness-tasks--by-session session-id))
         (id (plist-get task :id))
         (from (plist-get info :from))
         (kind (harness-sender-kind from)))
    (cond
     ((not (and task
                (eq (plist-get task :state) 'review)
                (not (plist-get task :worktree-removed))))
      blocks)
     ((eq kind 'system) blocks)
     ((null kind)
      (harness-log 'info "task %s: a message to its session sends it back from review" id)
      (harness-tasks--send-back id (harness-tasks--feedback-text blocks))
      (harness-tasks--reject-blocks blocks))
     (t
      (harness-log 'info "task %s: a message from %s reaches it in review; not a review, it is not sent back"
                   id (harness-sender-description from))
      (harness-tasks--aside id)
      (harness-tasks--aside-blocks blocks)))))

(defun harness-tasks--continue-session (id cwd worktree)
  "Start task ID's work in the session that wrote it up, moved to CWD.
WORKTREE, when non-nil, is the task's worktree.  The session takes the
task's settings instead of the refinement's read-only ones.  When the
directory changes, the provider's conversation is dropped: the Claude
CLI keeps conversations per directory.  The start message carries
everything the work needs, and the new conversation gets the
transcript, which keeps the refinement, as text
\(`harness-provider-history-text').  A session that has no name yet
takes the task's title."
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
                (harness-tasks--name-option task session)
                (list :permission-mode (or (plist-get settings :permission-mode)
                                           (harness-tasks--config 'harness-permission-mode cwd) 'ask)
                      :thinking (or (plist-get settings :thinking) (harness-tasks--config 'harness-thinking cwd))
                      :non-interactive (or (plist-get settings :non-interactive)
                                           (and (not (plist-member task :non-interactive))
                                                (harness-tasks--config 'harness-non-interactive cwd) t))
                      ;; The task default applies from the start of the
                      ;; work on; nil, turned off, clears an earlier one.
                      :context-window-limit (plist-get settings :context-window-limit))
                (when-let* ((model (or (plist-get settings :model) (harness-tasks--config 'harness-model cwd))))
                  (list :model model))))
        (when (eq (plist-get (harness-call 'session/get sid) :status) 'inactive)
          (harness-call 'session/resume sid))
        (harness-call 'session/hint sid
                      (cond
                       (worktree (format "Task started in %s on branch %s"
                                         (abbreviate-file-name worktree) (plist-get task :branch)))
                       ((harness-tasks--main-tree-p task)
                        (format "Task started in the main tree %s" (abbreviate-file-name cwd)))
                       (t "Task started")))
        (harness-catch (harness-call-async 'agent/prompt sid
                                           (harness-tasks--blocks
                                            (list :prompt (harness-tasks--start-text task)
                                                  :attachments (plist-get task :attachments)))
                                           (harness-tasks--from-harness))
                       (lambda (e) (harness-tasks--fail id e))))
    (error (harness-tasks--fail id err))))

;;;; Refinement

(defconst harness-tasks--refine-again-text
  "Write the task up now: your final message is the complete write-up."
  "Message that asks a backlog task's session for its write-up again.")

(defconst harness-tasks--refine-anyway-text
  "The engineer wants this task written up all the same: write it up now, the complete write-up as your final message, and name the task it seemed to duplicate as a related one."
  "Message that has a task written up after its write-up refused it.
That is after the agent took it for a duplicate (`harness-tasks--refusal').")

(defconst harness-tasks--duplicate-re
  (rx bos (* (any " \t*_#>`")) "duplicate of" (+ (any " \t"))
      (? "task" (+ (any " \t")))
      (* (any "*_`\"'“‘"))
      (group (any "A-Za-z0-9") (* (any "A-Za-z0-9_.-"))))
  "The first line of a reply that refuses its task as a duplicate.
Group 1 is the id of the task it duplicates, maybe with a full stop.
Matched ignoring case, markdown around it allowed.")

(defconst harness-tasks--refine-enough-text
  "That is enough looking around: end the task now with what you know, as your final message -- the write-up, or the refusal when the board has it already."
  "Steering message for a write-up that looked around long enough.
That is once it made `harness-tasks--refine-tool-calls' tool calls.")

(defvar harness-tasks--refine-calls (make-hash-table :test 'equal)
  "Session id -> tool calls of the write-up turn running in it.")

(defun harness-tasks--on-tool-call (session-id &rest _)
  "Count the tool calls of a write-up in SESSION-ID; tell it to finish in time.
At `harness-tasks--refine-tool-calls' calls it is steered to write up now."
  (when-let* ((limit harness-tasks--refine-tool-calls)
              (task (harness-tasks--by-session session-id))
              ((eq (plist-get task :state) 'refining)))
    (let ((n (1+ (gethash session-id harness-tasks--refine-calls 0))))
      (puthash session-id n harness-tasks--refine-calls)
      (when (= n limit)
        (harness-catch (harness-call-async 'agent/prompt session-id harness-tasks--refine-enough-text
                                           (harness-tasks--from-harness))
                       #'ignore)))))

(defun harness-tasks--refine-settings (task)
  "Return the `session/create' settings of the session refining TASK.
Ask mode allows reads, and non-interactive the session never waits for
the user; whatever would ask `harness-tasks--write-up-gate' denies with
a hint, which keeps a write-up a write-up.  The task context limit
rides along, so a write-up that reads a lot compacts sooner too."
  (let ((model (or harness-tasks-refine-model (plist-get task :model) harness-tasks-model))
        (thinking (or harness-tasks-refine-thinking (plist-get task :thinking) harness-tasks-thinking)))
    (append (list :permission-mode 'ask :non-interactive t)
            (and model (list :model model))
            (and thinking (list :thinking thinking))
            (and harness-tasks-context-limit
                 (list :context-window-limit harness-tasks-context-limit)))))

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
    (harness-tasks--set id :state 'refining :outcome 'error :error (harness-error-message err)
                        :duplicate-of nil)))

(defun harness-tasks--refine-turn (id sid blocks &optional opts)
  "Prompt task ID's session SID with BLOCKS for a write-up.
OPTS are the `agent/prompt' options, such as who sends the message.
The turn's end finishes the refinement (`harness-tasks--on-turn-ended');
this only adds the error a failed turn reports."
  (harness-then (harness-call-async 'agent/prompt sid blocks opts)
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
The first time a session is made for it at the task's directory, named
with the task's title when it has one, and given the task; afterwards
TEXT, feedback on the write-up, goes to that
session (without it, a request to write it up again, or after the agent
refused it as a duplicate, to write it up all the same).  A session that
never received the task, cut short by a restart, gets the task itself."
  (condition-case err
      (let* ((task (harness-tasks--get id))
             (session (harness-tasks--session task)))
        (harness-tasks--set id :state 'refining :backlog t :outcome nil :error nil :duplicate-of nil
                            :note (or (plist-get task :note) (plist-get task :prompt)))
        (if session
            (let* ((sid (plist-get session :id))
                   (begun (cl-find 'user (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)))))
              (when (eq (plist-get session :status) 'inactive) (harness-call 'session/resume sid))
              (harness-tasks--refine-turn
               id sid
               (cond ((not begun) (harness-tasks--refine-blocks task text))
                     ((not (harness-string-blank-p text)) text)
                     ((eq (plist-get task :outcome) 'duplicate)
                      harness-tasks--refine-anyway-text)
                     (t harness-tasks--refine-again-text))
               ;; With no words from the user, the harness asks for the
               ;; write-up (again, or all the same after a duplicate).
               (and begun (harness-string-blank-p text) (harness-tasks--from-harness))))
          (let* ((sid (plist-get (apply #'harness-call 'session/create :cwd (plist-get task :cwd)
                                        (append (harness-tasks--name-option task)
                                                (harness-tasks--refine-settings task)))
                                 :id)))
            (harness-tasks--set id :session sid)
            (harness-tasks--refine-turn id sid (harness-tasks--refine-blocks task text)))))
    (error (harness-tasks--refine-failed id err))))

(defun harness-tasks--last-reply (session-id)
  "Return the text SESSION-ID's last turn ended on, or nil.
That is its last assistant message after the last message the user
sent; steering messages within the turn, and a note handing the
conversation over to another model after it, do not end the search."
  (catch 'found
    (dolist (node (reverse (harness-call 'session/nodes session-id)))
      (pcase (plist-get node :kind)
        ('assistant (throw 'found (plist-get node :content)))
        ('user (unless (or (plist-get (plist-get node :meta) :steering) (harness-node-handoff node))
                 (throw 'found nil)))))
    nil))

(defun harness-tasks--refusal (reply)
  "Return (ID . MESSAGE) when REPLY refuses its task as a duplicate, else nil.
Such a reply's first line is \"Duplicate of ID\" (`harness-tasks--duplicate-re');
MESSAGE is what follows it, for the user: which task ID is and why it
is the same.  With nothing after it, MESSAGE is the first line itself."
  (let ((text (string-trim (or reply "")))
        (case-fold-search t))
    (when (string-match harness-tasks--duplicate-re text)
      (let* ((id (string-trim-right (match-string 1 text) "[.]+"))
             (nl (string-search "\n" text))
             (message (if nl (string-trim (substring text nl)) "")))
        (cons id (if (string-empty-p message)
                     (string-trim (harness-first-line text) "[ \t#>*_`]+" "[ \t*_`]+")
                   message))))))

(defun harness-tasks--duplicate-of (task ref)
  "Return the id of the task REF names, unless that is TASK itself.
REF is what a refusing reply names: an id, or the start of one of
exactly one task of TASK's project.  Return nil when it names no task."
  (let ((id (if (gethash ref harness-tasks--table)
                ref
              (let ((ids (cl-loop for other being the hash-values of harness-tasks--table
                                  when (and (equal (plist-get other :project) (plist-get task :project))
                                            (string-prefix-p ref (plist-get other :id)))
                                  collect (plist-get other :id))))
                (and (= 1 (length ids)) (car ids))))))
    (and id (not (equal id (plist-get task :id))) id)))

(defun harness-tasks--finish-refinement (id reason)
  "Make the reply that ended task ID's refinement turn (with REASON) its prompt.
A complete turn puts the task in the backlog, unless its reply refuses
the task as a duplicate (`harness-tasks--refusal').  That, like any
other end, leaves it refining with an outcome, in front of the user: a
refusal is `duplicate', with `:duplicate-of' the task it names (nil
when it names none) and its message as `:error'.  Only a reply naming a
task of this harness, or what looks like one of its ids, refuses: a
write-up that merely opens \"Duplicate of a task …\" is a write-up."
  (let* ((task (harness-tasks--get id))
         (reply (and (eq reason 'end-turn) (plist-get task :session)
                     (harness-tasks--last-reply (plist-get task :session))))
         (refusal (and reply (harness-tasks--refusal reply)))
         (of (and refusal (harness-tasks--duplicate-of task (car refusal))))
         (refuse (and refusal (or of (string-match-p "\\`t-[A-Za-z0-9]+\\'" (car refusal))))))
    (cond
     ((harness-string-blank-p reply)
      (harness-tasks--set id :state 'refining :duplicate-of nil
                          :outcome (if (eq reason 'end-turn) 'error reason)
                          :error (and (eq reason 'end-turn) "the agent wrote no task description")))
     (refuse
      (harness-log 'info "task %s: its write-up refused it as a duplicate of %s" id (car refusal))
      (harness-tasks--set id :state 'refining :outcome 'duplicate
                          :duplicate-of of :error (cdr refusal)))
     (t (harness-tasks--set id :state 'pending :backlog t :prompt (string-trim reply)
                            :refined (float-time) :outcome nil :error nil :duplicate-of nil)))))

;;;; Reports
;;
;; What a round of work hands in (`hand_in', `task/hand-in') is the
;; task's `:report', which the user reviews.  A round whose turn ends
;; without one -- the model replied instead, or could not call the tool:
;; a provider that offers it no tools leaves it writing its calls as
;; text -- would leave the review with nothing to read, or with the
;; report of a round the user already sent back.  It gets a report
;; marked `:missing' instead: no evidence, and as its `:summary' the
;; last message the session wrote in the round.  The views say it was
;; not handed in, so the user sees at once that the work was not
;; reported, and what the session said.  A turn that starts no round of
;; its own -- one dealing with another session's message while the task
;; waited for review (`harness-tasks--aside') -- leaves the round's
;; report as it was, handed in or recorded missing: the reply it ends
;; with is to that session, not about the work.

(defconst harness-tasks--missing-summary-limit 20000
  "Characters of a session's last message a missing report keeps.")

(defun harness-tasks--round-start (task)
  "Return when TASK's current round of work began, a float time.
A round starts with the task (`:started'), with each round of feedback
that sends it back (`:feedback'), and with new work on a task that was
in review or done (`:reopened'): it is the work a report speaks for."
  (max (or (plist-get task :started) 0)
       (or (plist-get (car (last (plist-get task :feedback))) :at) 0)
       (or (plist-get task :reopened) 0)))

(defun harness-tasks--report-missing-p (report)
  "Non-nil when REPORT is one recorded for a round that handed none in."
  (harness-json-true-p (plist-get report :missing)))

(defun harness-tasks--handed-in-p (task)
  "Non-nil when TASK's current round handed its report in."
  (let ((report (plist-get task :report)))
    (and report
         (not (harness-tasks--report-missing-p report))
         (>= (or (plist-get task :report-at) (plist-get report :at) 0)
             (harness-tasks--round-start task)))))

(defun harness-tasks--last-message (sid since)
  "Return the last message session SID's model wrote at SINCE or later, or nil.
SINCE is a float time.  A fork's messages from its parent do not count."
  (when (and sid (harness-method-exists-p 'session/nodes))
    (cl-loop for n in (reverse (ignore-errors (harness-call 'session/nodes sid)))
             for text = (plist-get n :content)
             when (and (eq (plist-get n :kind) 'assistant)
                       (member (plist-get n :session) (list nil sid))
                       (>= (or (plist-get n :ts) 0) since)
                       (stringp text) (not (harness-string-blank-p text)))
             return (harness-truncate-end (string-trim text) harness-tasks--missing-summary-limit))))

(defun harness-tasks--missing-recorded-p (task)
  "Non-nil when TASK's current round has a report recorded missing already.
That is a report saying the round handed none in, made when an earlier
turn of the round ended: before a turn that starts no round of its
own, such as one dealing with another session's message while the
task waited for review (`harness-tasks--aside')."
  (let ((report (plist-get task :report)))
    (and (harness-tasks--report-missing-p report)
         (>= (or (plist-get report :at) 0) (harness-tasks--round-start task)))))

(defun harness-tasks--missing-report (task)
  "Return the fields recording that TASK's round handed no report in, or nil.
Nil when the round handed one in (`harness-tasks--handed-in-p'), or has
one recorded missing already (`harness-tasks--missing-recorded-p'),
which stands.  Otherwise (:report REPORT), REPORT marked `:missing',
with the session's last message of the round as its `:summary' when it
wrote one.  It replaces the report of an earlier round, which speaks
for work the user already sent back."
  (unless (or (harness-tasks--handed-in-p task) (harness-tasks--missing-recorded-p task))
    (let ((message (harness-tasks--last-message (plist-get task :session)
                                                (harness-tasks--round-start task))))
      (harness-log 'info "task %s: its turn ended without hand_in; no report to review"
                   (plist-get task :id))
      (list :report (append (and message (list :summary message))
                            (list :at (float-time) :missing t))))))

;;;; Following the sessions

(defun harness-tasks--on-turn-started (session-id)
  "Move SESSION-ID's task to active when a turn starts.
A turn during a merge (resolving a conflict) keeps the task merging; a
turn before the task started (a backlog task's) refines it.  A message
sent to an archived task's session brings the task back too.  New work
needs a new review, so a verification goes, unless the turn is part of
a merge: the merge queue steering the agent to commit, say.  New work
on a task that was in review or done starts a round that needs a report
of its own (`:reopened', see `harness-tasks--round-start').  A merged
task's worktree is locked again for the new work."
  (remhash session-id harness-tasks--refine-calls)
  (when-let* ((task (harness-tasks--by-session session-id)))
    (remhash (plist-get task :id) harness-tasks--starting)
    (cond
     ((harness-tasks--refinement-p task)
      (harness-tasks--set (plist-get task :id) :state 'refining :outcome nil :error nil :duplicate-of nil
                          :archived nil))
     ((and (eq (plist-get task :state) 'merging) (plist-get task :merge-status)) nil)
     (t (harness-tasks--relock-worktree task)
        (apply #'harness-tasks--set (plist-get task :id) :state 'active :outcome nil :error nil :finished nil
               :merged nil :archived nil
               (append
                (unless (eq (plist-get task :state) 'merging) (list :verified nil :verified-at nil))
                (when (memq (plist-get task :state) '(review done)) (list :reopened (float-time)))))))))

(defun harness-tasks--on-turn-ended (session-id reason)
  "Advance SESSION-ID's task when its turn ended with REASON.
`end-turn' puts the work in review (`harness-tasks-require-verification')
until the user verified it; after that, or without review, it completes
the task outside git -- in the main tree too, which has nothing to
merge -- and queues its merge inside.  A round that ends without a
report handed in gets one saying so (`harness-tasks--missing-report').
A refinement turn puts its write-up in the backlog."
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
        (apply #'harness-tasks--to-review id :outcome reason :error nil :finished (float-time)
               (harness-tasks--missing-report task)))
       ((and (plist-get task :worktree) (not (plist-get task :worktree-removed)))
        (when-let* ((missing (harness-tasks--missing-report task)))
          (apply #'harness-tasks--set id missing))
        (harness-tasks--enqueue-merge id))
       (t (apply #'harness-tasks--to-done id 'finished :outcome reason :finished (float-time)
                 (harness-tasks--missing-report task))))
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
  "Drop task ID, write the stores and emit `task/deleted'."
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
                                           (list (list :type "text" :text harness-tasks--resume-prompt))
                                         (harness-tasks--blocks task))
                                       ;; Carrying on after a restart is the
                                       ;; harness's doing; the task itself is
                                       ;; the user's.
                                       (and begun (harness-tasks--from-harness)))
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
`harness-tasks--resume-prompt', or waits for the user with the outcome
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
records.  Each step leaves alone the tasks something already works on.
Last, the tasks without a title are named."
  (harness-run-soon #'harness-tasks--recover)
  (harness-run-soon #'harness-tasks--resume-merges)
  (harness-run-soon #'harness-tasks--recover-refinements)
  (harness-run-soon #'harness-tasks--schedule)
  (harness-run-soon #'harness-tasks--name-untitled))

;;;; Methods

(harness-defmethod task/submit (cwd prompt &optional opts)
  "Submit PROMPT as a new task in directory CWD; return the task.
It starts at once when its project has a slot free, otherwise it waits
as pending: `harness-tasks-max-running' limits each project on its own.
OPTS: `:attachments' (ATTACHMENT list), `:model', `:permission-mode',
`:thinking', `:non-interactive' (an explicit false turns it off),
`:priority' (low, medium or high, as a symbol or a string; medium by
default: waiting tasks start by priority, see `harness-tasks-priorities')
and `:main-tree' (work in the project's main checkout, with no worktree,
no branch and nothing to merge; for work that has to touch the checkout
itself, such as cleaning up uncommitted changes); missing ones come
from the `harness-tasks-' defaults, else from what the directory
configures: a task is interactive unless `harness-tasks-non-interactive'
or the directory's `harness-non-interactive' is on.  With `:refine'
the task goes to the backlog instead: an agent writes it up (state
refining), then it waits in pending until `task/start' -- unless the
agent finds the board has it already, and refuses it as a duplicate.
A refined task keeps `:main-tree' for when it finally starts.
Either way the task is named from PROMPT at once, beside everything
else (see Titles above): its `:name' comes while it waits, and its
session takes it."
  (when (harness-string-blank-p prompt) (error "A task needs a prompt"))
  (harness-tasks--load)
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (refine (harness-json-true-p (plist-get opts :refine)))
         (main-tree (and (harness-json-true-p (plist-get opts :main-tree)) t))
         (priority (harness-tasks--read-priority (plist-get opts :priority)))
         (task (list :id (concat "t-" (harness-short-id 8))
                     :project (harness-tasks--project cwd) :cwd cwd
                     :prompt (string-trim prompt)
                     :attachments (plist-get opts :attachments)
                     :model (plist-get opts :model)
                     :permission-mode (let ((m (plist-get opts :permission-mode)))
                                        (if (stringp m) (intern m) m))
                     :thinking (plist-get opts :thinking)
                     :priority priority
                     :state 'pending :created (float-time))))
    (when (plist-member opts :non-interactive)
      (setq task (plist-put task :non-interactive
                            (if (harness-json-true-p (plist-get opts :non-interactive)) t :false))))
    (when main-tree
      (setq task (append task (list :main-tree t))))
    (when refine
      (setq task (append task (list :backlog t :note (string-trim prompt)))))
    (harness-tasks--put task)
    ;; Out before the task gets a session, so that session leaves its
    ;; naming to this request (`harness-tasks--auto-name-p').
    (harness-tasks--name (plist-get task :id))
    (if refine
        (harness-tasks--refine (plist-get task :id))
      (harness-tasks--schedule))
    (harness-tasks--view (gethash (plist-get task :id) harness-tasks--table))))

(harness-defmethod task/refine (id &optional text)
  "Have an agent write task ID up for the backlog; return the task.
A task waiting for a slot becomes a backlog task.  One written up
already, or whose write-up stopped, is written up again by the same
session, TEXT being feedback for it; without TEXT one the agent
refused as a duplicate is written up all the same.  Either way it then
waits in pending until `task/start'."
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
       (not (equal (plist-get session :name) harness-tasks--merge-session-name))
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
or blocked session is in progress; an idle one waits for the user.  The
task context limit applies from now on when there is one."
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
      ;; The task's shorter context applies from its next turn on; a
      ;; session adopted after long work may compact on it right away,
      ;; and nil (turned off) clears a limit the session carried.
      (harness-call 'session/update session-id
                    :context-window-limit harness-tasks-context-limit :silent t)
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
`harness-tasks--btw-prompt' tells to answer with the task and session
tools.  Like every BTW it thinks at `harness-btw-thinking' when its
model offers that level (see `session/create').  The caller sends the
first question."
  (harness-call 'session/create :cwd (harness-tasks--project cwd) :kind 'btw :name name))

(harness-defmethod task/list (&optional cwd)
  "Return the tasks of CWD's project, oldest first; every task without CWD."
  (harness-tasks--load)
  (let ((project (and cwd (harness-tasks--project cwd))))
    (when project (harness-tasks--open-project project))
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
Model, thinking and non-interactive are the values a new task would
really get: the task defaults, else what the project configures.  So
non-interactive is on only when `harness-tasks-non-interactive' is, or
`harness-non-interactive' for the project.  `:require-verification'
is t while finished work waits for the user's review, else false (not
nil, which JSON could not tell from a harness that does not say):
`harness-tasks-require-verification'."
  (let ((root (and cwd (harness-tasks--project cwd))))
    (list :max-running harness-tasks-max-running
          :permission-mode harness-tasks-permission-mode
          :non-interactive (and (or harness-tasks-non-interactive
                                    (harness-json-true-p (harness-tasks--config 'harness-non-interactive root)))
                                t)
          :require-verification (if harness-tasks-require-verification t :false)
          :model (or harness-tasks-model (harness-tasks--config 'harness-model root))
          :thinking (or harness-tasks-thinking (harness-tasks--config 'harness-thinking root))
          :worktrees (and root (harness-tasks--git-p root) t))))

(harness-defmethod task/set-all (settings &optional filter)
  "Apply SETTINGS to every current task FILTER selects; return the ids changed.
SETTINGS is a plist of `:model', `:thinking', `:permission-mode',
`:non-interactive' (an explicit false turns it off) and `:priority'
\(low, medium or high, as `task/set-priority' reads it).  Only the
settings given change: without `:priority' (or with nil) every task
keeps its own, so a bulk edit sets priorities only when asked to.  A
started task's session gets the session settings too, so its next turn
uses them; a pending task keeps them for when it starts.  A priority is
the task's own and orders the queue (it starts nothing).  FILTER:
`:columns' (default `harness-tasks-bulk-columns', the running, pending
and blocked tasks), `:ids' to name tasks outright, `:except' ids to
leave alone, and `:cwd' to stay inside one project; without it the
tasks of every project are selected.  Review, done and archived tasks
are history and are never touched.  A task already set so is left
alone (non-interactive counts as what the task would start with, see
`harness-tasks--prefs-differ-p'), and a session already holding a value
is not sent it again, so a session `session/set-all' changed first gets
no second hint.  Return the ids that changed, oldest first."
  ;; A bad priority is refused before any task changes.
  (when (plist-get settings :priority)
    (setq settings (plist-put (copy-sequence settings) :priority
                              (harness-tasks--read-priority (plist-get settings :priority)))))
  (let (changed)
    (dolist (task (harness-tasks--bulk-selected filter))
      (when (harness-tasks--prefs-differ-p task settings)
        (harness-tasks--apply-prefs task settings)
        (push (plist-get task :id) changed)))
    (nreverse changed)))

(harness-defmethod task/session-ids (&optional filter)
  "Return the ids of the sessions of the current tasks FILTER selects.
FILTER is the one of `task/set-all'; by default the running, pending
and blocked tasks of every project.  A task without a session yet adds
nothing.  Bulk changes use it to reach these sessions whatever their
status: a task's session can be inactive, after a restart or once
closed, and still be the one the task goes on in."
  (cl-loop for task in (harness-tasks--bulk-selected filter)
           for session = (harness-tasks--session task)
           when session collect (plist-get session :id)))

(defun harness-tasks--bulk-selected (filter)
  "Return the task records FILTER of `task/set-all' selects, oldest first."
  (let* ((columns (mapcar (lambda (c) (if (stringp c) (intern c) c))
                          (or (plist-get filter :columns) harness-tasks-bulk-columns)))
         (project (and (plist-get filter :cwd) (harness-tasks--project (plist-get filter :cwd))))
         (ids (plist-get filter :ids))
         (except (plist-get filter :except)))
    (harness-tasks--sorted
     (lambda (task)
       (and (or (null project) (equal project (plist-get task :project)))
            (or (null ids) (member (plist-get task :id) ids))
            (not (member (plist-get task :id) except))
            (not (harness-json-true-p (plist-get task :archived)))
            (memq (harness-tasks--column task) columns))))))

(harness-defmethod task/start (id)
  "Start pending task ID now, even when every slot of its project is taken.
A backlog task starts too, and so does one whose write-up stopped (with
the prompt it has), but not one an agent is writing up right now."
  (let ((task (harness-tasks--get id)))
    (unless (memq (plist-get task :state) '(pending refining)) (error "Task %s already started" id))
    (when (harness-tasks--turn-p task)
      (error "Task %s is still being written up; wait for it or stop it" id))
    (harness-tasks--start task)
    (harness-call 'task/get id)))

(harness-defmethod task/set-priority (id priority)
  "Give task ID priority PRIORITY: low, medium or high; return the task.
PRIORITY is a symbol or a string, \"med\" meaning medium.  Priority
orders the tasks waiting for a slot of their project, highest first
\(see `harness-tasks-priorities'), so raising a pending task moves it
up the queue and lowering it lets the others by.  It changes nothing
else: a task at work keeps its slot, a backlog task still waits for
`task/start', and a task that waits again later (after a restart)
waits with its priority."
  (let ((task (harness-tasks--get id))
        (priority (harness-tasks--read-priority priority)))
    (if (eq priority (harness-tasks--priority task))
        (harness-tasks--view task)
      (harness-tasks--set id :priority priority))))

(harness-defmethod task/update (id prompt &optional attachments)
  "Replace the prompt of pending task ID with PROMPT and its ATTACHMENTS.
A task whose write-up stopped can be written by hand this way; it then
waits in the backlog like a refined one.  A task named from its prompt
\(not a backlog task, named from the words it was written up from) is
named again from the new one."
  (let ((task (harness-tasks--get id)))
    (unless (memq (plist-get task :state) '(pending refining))
      (error "Only tasks that have not started can be edited"))
    (when (harness-tasks--turn-p task)
      (error "Task %s is being written up; wait for it or stop it" id))
    (when (harness-string-blank-p prompt) (error "A task needs a prompt"))
    (let* ((before (harness-tasks--naming-text task))
           (view (harness-tasks--set id :prompt (string-trim prompt) :attachments attachments
                                     :state 'pending :outcome nil :error nil :duplicate-of nil)))
      (if (equal before (harness-tasks--naming-text view))
          view
        (prog1 (harness-tasks--set id :name nil)
          (harness-tasks--name id))))))

(harness-defmethod task/prompt (id text &optional attachments opts)
  "Send TEXT and ATTACHMENTS to the session of task ID: a follow-up, or steering.
OPTS `:from' says who sent the message when the user did not, as
`agent/prompt' takes it: another session's agent
\(`harness-sender-session'), as task_control's message sends it.
Before a backlog task starts, TEXT is feedback on its write-up.  While
the task waits for review, the user's TEXT sends it back as the
feedback, as `task/reject' does; another session's is no review and
does not (`harness-tasks--on-message')."
  (let ((task (harness-tasks--get id))
        (from (let ((f (plist-get opts :from))) (and (harness-sender-kind f) f))))
    (unless (harness-tasks--session task) (error "Task %s has no session yet" id))
    (when (plist-get task :worktree-removed)
      (error "Task %s was archived and its worktree removed; submit a new task" id))
    (let ((sid (plist-get task :session))
          (blocks (harness-tasks--blocks (list :prompt text :attachments attachments)))
          (opts (and from (list :from from))))
      (when (eq (plist-get (harness-call 'session/get sid) :status) 'inactive)
        (harness-call 'session/resume sid))
      (when (plist-get task :archived) (harness-tasks--set id :archived nil))
      (harness-tasks--set id :merge-attempts 0
                          :recap nil :recap-at nil :recap-turns nil :recap-tools nil)
      (if (harness-tasks--refinement-p task)
          (harness-tasks--refine-turn id sid blocks opts)
        (harness-catch (harness-call-async 'agent/prompt sid blocks opts)
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
    ;; A task in the merge queue holds no slot, even with its session at work.
    (harness-run-soon #'harness-tasks--schedule)
    (harness-call 'task/get id)))

(defun harness-tasks--stopped-how (task)
  "Say how TASK's last turn stopped, for `harness-tasks--retry-prompt'."
  (let ((err (plist-get task :error)))
    (concat (pcase (plist-get task :outcome)
              ('error "it failed with an error")
              ('cancelled "it was cancelled")
              ('interrupted "the harness stopped while it was running")
              ('max-tokens "the model ran out of output tokens")
              ('nil "it ended")
              (outcome (format "it ended (%s)" outcome)))
            (if (harness-string-blank-p err)
                ""
              (concat " -- " (harness-truncate-end (string-trim err) 300))))))

(defun harness-tasks--retry-turn (task)
  "Have the session of stopped TASK work on it again.
A session that never got the work since the task started gets the task
itself; otherwise `harness-tasks--retry-prompt' from the harness tells
it to carry on.  The task holds its slot from now, as when it starts."
  (let ((id (plist-get task :id))
        (sid (plist-get task :session)))
    (when (plist-get task :worktree-removed)
      (error "Task %s was archived and its worktree removed; submit a new task" id))
    (puthash id t harness-tasks--starting)
    (harness-tasks--set id :merge-attempts 0)
    (let ((begun (harness-tasks--work-begun-p task)))
      (harness-catch (harness-call-async 'agent/prompt sid
                                         (if begun
                                             (list (list :type "text"
                                                         :text (format harness-tasks--retry-prompt
                                                                       (harness-tasks--stopped-how task))))
                                           (harness-tasks--blocks task))
                                         ;; Carrying on is the harness's doing;
                                         ;; the task itself is the user's.
                                         (and begun (harness-tasks--from-harness)))
                     (lambda (e) (harness-tasks--fail id e))))))

(harness-defmethod task/retry (id)
  "Have task ID, which stopped part way, work on it again; return the task.
What that means follows where it stopped: a failed merge is queued
again (`task/merge'), a write-up that stopped is written again, or
written up all the same after it refused the task as a duplicate
\(`task/refine'), and a task that has not started starts (`task/start').
A task whose turn stopped -- an error, cancelled, interrupted -- has its
session carry on, told so by the harness (`harness-tasks--retry-prompt');
one left without a session starts over.  A task at work, waiting for an
answer, merging, in review or done has nothing to retry."
  (let* ((task (harness-tasks--get id))
         (state (plist-get task :state))
         (session (harness-tasks--session task)))
    (cond
     ((plist-get session :pending)
      (error "Task %s waits for your answer to its %s" id
             (if (equal (format "%s" (plist-get (car (plist-get session :pending)) :kind)) "question")
                 "question" "permission request")))
     ((or (harness-tasks--turn-p task) (gethash id harness-tasks--starting))
      (error "Task %s is working already" id))
     ((eq state 'review) (error "Task %s waits for your review: verify it or send it back" id))
     ((eq state 'done) (error "Task %s is done; send it a message to reopen it" id))
     ((eq (plist-get task :outcome) 'merge-failed) (harness-call 'task/merge id))
     ((eq state 'merging) (error "Task %s is merging" id))
     ((eq state 'refining) (harness-call 'task/refine id))
     ((eq state 'pending) (harness-call 'task/start id))
     ((null session) (harness-tasks--start task))
     (t (harness-tasks--retry-turn task)))
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
worktree, as a new prompt opened by `harness-tasks--reject-message'.  The
round of feedback is kept in the task's `:feedback'.  The task is
active again and comes back to review when that turn ends.  Feedback
may be ATTACHMENTS alone, a screenshot say, but not nothing.  Any
message the user sends the session meanwhile does the same; one from
another session's agent does not (`harness-tasks--on-message').
Return the task."
  (let ((task (harness-tasks--get id)))
    (unless (eq (plist-get task :state) 'review)
      (error "Task %s is not waiting for review" id))
    (when (and (harness-string-blank-p feedback) (null attachments))
      (error "Sending a task back needs feedback"))
    (unless (harness-tasks--session task) (error "Task %s has no session to send the feedback to" id))
    (when (plist-get task :worktree-removed)
      (error "Task %s was archived and its worktree removed; submit a new task" id))
    (let ((sid (plist-get task :session))
          (blocks (harness-tasks--blocks (list :prompt (string-trim (or feedback ""))
                                               :attachments attachments))))
      (when (eq (plist-get (harness-call 'session/get sid) :status) 'inactive)
        (harness-call 'session/resume sid))
      ;; Active before the prompt goes out, so the message is not taken
      ;; for one more sending the task back (`harness-tasks--on-message').
      (harness-tasks--send-back id (harness-tasks--feedback-text blocks))
      (harness-catch (harness-call-async 'agent/prompt sid (harness-tasks--reject-blocks blocks))
                     (lambda (e) (harness-tasks--fail id e)))
      (harness-call 'task/get id))))

(harness-defmethod task/for-session (session-id)
  "Return the task of SESSION-ID, or nil.
Hand-in uses it, and the review banner: a session that is a task's has
exactly one."
  (let ((task (harness-tasks--by-session session-id)))
    (and task (harness-tasks--view task))))

(harness-defmethod task/set-recap (id &rest plist)
  "Store recap fields PLIST on task ID; return its view.
The recap module writes a card's subtitle with it: `:recap' the line
shown, `:recap-at' when it was made, and `:recap-turns' plus
`:recap-tools' the counters it was made at.  A nil `:recap' clears it."
  (apply #'harness-tasks--set id plist))

(harness-defmethod task/hand-in (id report)
  "Record REPORT as the work ID hands in, waiting for the user's review.
REPORT is what the hand_in tool validated: a plist of `:summary' and
`:evidence'.  The record is written and `task/changed' says so; the
turn that handed it in then ends cleanly, which the review step picks
up as usual (`harness-tasks--on-turn-ended')."
  (harness-tasks--get id)               ; signals for an unknown task
  ;; `harness-tasks--set' writes it soon and says `task/changed'.
  (harness-tasks--set id :report report :report-at (float-time) :archived nil))

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
  (harness-add-filter 'worktree/lock-existing-p #'harness-tasks--lock-existing-p)
  (harness-add-filter 'agent/system-prompt #'harness-tasks--system-prompt 60)
  (harness-add-filter 'agent/system-prompt #'harness-tasks--btw-system-prompt 60)
  (harness-add-filter 'naming/system-prompt #'harness-tasks--naming-prompt 60)
  (harness-add-filter 'naming/auto-p #'harness-tasks--auto-name-p)
  (harness-add-filter 'permission/decide #'harness-tasks--write-up-gate 25)
  (harness-add-filter 'agent/message #'harness-tasks--on-message)
  (harness-add-filter 'session/before-move #'harness-tasks--before-move)
  (harness-tasks--pick-up))

(defun harness-tasks--shutdown ()
  "Write what waits to be written."
  (harness-tasks-flush))

(harness-declare-event 'task/changed "(TASK) after a task is submitted or changes state or column.")
(harness-declare-event 'task/deleted "(ID) after a task is removed.")
(harness-declare-event 'task/review "(TASK) when a task's finished work starts waiting for the user's review.")
(harness-declare-event 'task/done "(TASK HOW) when a task becomes done; HOW is merged, finished, verified or completed.")

(harness-define-module 'tasks
  :doc "Task mode: one session per task on a shorter context, from backlog write-up or worktree through your review to merged, with a concurrency limit per project that starts waiting tasks by priority."
  :requires '(store project session agent)
  :init #'harness-tasks--init
  :shutdown #'harness-tasks--shutdown)

;; A reload does not initialise a running module again, and a write-up
;; must not go without the stage that keeps it read-only, nor a message
;; to a task in review without the filter that tells the user's
;; feedback, which sends it back, from another session's word: install
;; them now, with the filter that keeps a task's session in its task's
;; directory.  The session of a task whose title is on its way waits for
;; it, and the tasks of the boards without a title get one.
(when (harness-module-ready-p 'tasks)
  (harness-add-filter 'permission/decide #'harness-tasks--write-up-gate 25)
  (harness-add-filter 'agent/message #'harness-tasks--on-message)
  (harness-add-filter 'session/before-move #'harness-tasks--before-move)
  (harness-add-filter 'naming/auto-p #'harness-tasks--auto-name-p)
  (harness-run-soon #'harness-tasks--name-untitled))

(provide 'harness-tasks)
;;; harness-tasks.el ends here
